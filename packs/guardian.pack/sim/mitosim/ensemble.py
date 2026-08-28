"""Uncertainty ensemble: many plausible personal states x each scenario.

Spec 2.8:

    one scenario
        x 200-1,000 plausible personal states
        x alternate biochemical parameter samples
        -> output distribution, not a point answer

Each ensemble member draws a personal state and a biochemical parameter set,
builds the running demand, applies any experimental adapters, integrates the
muscle model, and records the outputs.  Members that fail to integrate are
recorded as failures rather than silently dropped.
"""

from __future__ import annotations

import atexit
import hashlib
import json
import math
import os
import threading
import time
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple, cast

import numpy as np

from . import guardrails
from .adapters import apply_adapters
from .effects import NO_INTERVENTION_MAPPING, STATUS_MEANINGS, EffectOutcome
from .demand import build_demand
from .estimate import build_sampler, band_for_glycogen
from .inputs import PersonInputs
from .mechanisms import MECHANISMS, apply_mechanisms
from .muscle import (MuscleModel, IDX, NSP, I_LACB, free_adp,
                     IntegrationBudgetExceeded)
from .outputs import Estimate, RunOutputs
from .params import R, REGISTRY_VERSION
from .qc import QCReport, run_qc
from .scenario import Scenario

MODEL_VERSION = "mitosim-0.2.0"
TISSUE = "mixed human vastus-lateralis-type running muscle (type I + type II)"
ACTIVITY = "running"


@dataclass
class MemberResult:
    ok: bool
    values: Dict[str, float] = field(default_factory=dict)
    params: Dict[str, float] = field(default_factory=dict)
    traj: Dict[str, Any] = field(default_factory=dict)
    guard_failures: List[str] = field(default_factory=list)
    error: str = ""
    # What each requested mechanism did to *this* member. Kept per member
    # rather than computed once for the ensemble, because a transform can
    # succeed for one draw of the biochemical priors and be refused for
    # another, and the report must be able to say how often.
    mechanisms: List[EffectOutcome] = field(default_factory=list)


# --------------------------------------------------------------------------
# Worker-side sampler cache
# --------------------------------------------------------------------------
# The sampler is a closure over the person-level inferences, so it cannot be
# pickled and shipped with each task. It is instead rebuilt on first use inside
# each worker and memoised there. Building it costs a few milliseconds against
# a per-member integration of a few hundred, and unlike a pool initialiser it
# lets one long-lived pool serve every scenario.
_SAMPLER_CACHE: Dict[Any, Any] = {}


def _person_key(person: PersonInputs, qc: QCReport) -> str:
    """Content hash of everything that can change the sampler.

    Keying on an identifier is not safe: two different virtual people can share
    a subject id, and then one silently inherits the other's posterior. That is
    exactly the kind of error a personalisation engine must not make, and it is
    invisible in the output.
    """
    blob = json.dumps({"person": person.to_dict(),
                       "qc": qc.to_dict()},
                      sort_keys=True, default=str)
    return hashlib.sha256(blob.encode()).hexdigest()


def _cached_sampler(person: PersonInputs, qc: QCReport, sc: Scenario):
    key = (_person_key(person, qc), sc.key())
    hit = _SAMPLER_CACHE.get(key)
    if hit is None:
        hit, _ = build_sampler(person, qc, sc)
        if len(_SAMPLER_CACHE) > 64:
            _SAMPLER_CACHE.clear()
        _SAMPLER_CACHE[key] = hit
    return hit


def _run_member_task(person: PersonInputs, qc: QCReport, sc: Scenario,
                     seed: int, keep_traj: bool, audit: bool) -> MemberResult:
    """Self-contained task: everything it needs travels with it."""
    return _run_member(person, qc, sc, _cached_sampler(person, qc, sc),
                       seed, keep_traj, audit)


# --------------------------------------------------------------------------
# One long-lived process pool
# --------------------------------------------------------------------------
# Creating and tearing down a pool per scenario deadlocks on macOS once a few
# dozen pools have been through their spawn/shutdown cycle, which is exactly
# what a validation sweep does. One pool for the life of the process avoids it
# and removes the per-scenario spawn cost as well.
_POOL: Dict[str, Any] = {"ex": None, "workers": 0}
_POOL_LOCK = threading.Lock()


def _get_pool(workers: int):
    import __main__ as _m
    if not getattr(_m, "__file__", None):
        return None            # no importable __main__: spawning cannot work
    with _POOL_LOCK:
        if _POOL["ex"] is None:
            try:
                _POOL["ex"] = ProcessPoolExecutor(max_workers=workers)
                _POOL["workers"] = workers
            except Exception:
                _POOL["ex"] = None
        return _POOL["ex"]


def shutdown_pool() -> None:
    with _POOL_LOCK:
        ex = _POOL["ex"]
        _POOL["ex"] = None
    if ex is not None:
        ex.shutdown(wait=False, cancel_futures=True)


atexit.register(shutdown_pool)


def _run_member(person: PersonInputs, qc: QCReport, sc: Scenario,
                sampler, seed: int, keep_traj: bool, audit: bool,
                state_transform: Optional[Any] = None) -> MemberResult:
    rng = np.random.default_rng(seed)
    mech_out: List[EffectOutcome] = []
    try:
        st = sampler(rng)
        handles, outcomes = apply_adapters(sc.experimental, st, rng, person)
        if "blood_bhb_override" in handles:
            st.blood_bhb = float(handles.pop("blood_bhb_override"))
        # Mechanism transforms draw from their own stream, seeded off this
        # member's seed but disjoint from it. That is what makes the neutral
        # case exact: adding a mechanism to a scenario cannot shift the
        # personal-state or adapter draws, so a pool_scale of 1.0 reproduces
        # the no-mechanism run bit for bit rather than merely closely.
        if sc.mechanisms:
            mech_rng = np.random.default_rng([seed, 0x4D454348])
            mech_out = apply_mechanisms(sc.mechanisms, st, mech_rng, person, qc)
        if state_transform is not None:
            state_transform(st)
        dp = build_demand(sc, st)
        mm = MuscleModel(st, dp.t, dp.atp_demand, dp.rel_intensity,
                         sc.hours_since_meal, st.insulin_idx, handles)
        if getattr(mm, "oxidative_capacity_short", False):
            return MemberResult(
                False, error="parameter draw gives a fibre less oxidative "
                             "capacity than its own resting demand; excluded "
                             "as physiologically incoherent",
                mechanisms=mech_out)
        dur = sc.duration_min * 60.0
        res = mm.run(dur, n_out=max(40, min(180, int(sc.duration_min * 3))))
        if not res.ok:
            return MemberResult(False, error=f"integration failed: {res.message}",
                                mechanisms=mech_out)

        v: Dict[str, float] = {}
        cw = st.bp["cell_water_L_per_kg"]
        f1 = st.type1_frac

        ox = res.final("atp_ox")
        gly = res.final("atp_gly")
        pcr = res.final("atp_pcr")
        tot = ox + gly + pcr
        dem = res.final("atp_demand")
        sup = res.final("atp_supplied")

        v["atp_demand"] = float(np.mean(dp.atp_demand))
        v["atp_coverage"] = sup / dem if dem > 0 else 1.0
        v["oxidative_atp_fraction"] = ox / tot if tot > 0 else 0.0
        v["glycolytic_atp_fraction"] = gly / tot if tot > 0 else 0.0
        v["pcr_atp_fraction"] = pcr / tot if tot > 0 else 0.0

        o2_total = res.final("o2")                      # mmol/L cell water
        o2_mmol = o2_total * st.muscle_water_L
        v["muscle_vo2"] = (o2_mmol * R.value("o2_molar_volume") /
                           dur / st.active_muscle_kg * 60.0)   # mL/kg-muscle/min
        v["whole_body_vo2_equiv"] = (o2_mmol * R.value("o2_molar_volume") /
                                     (1 - st.nonmuscle_frac) / dur /
                                     st.body_mass_kg * 60.0)
        v["atp_per_oxygen"] = (ox / o2_total) if o2_total > 0 else 0.0

        cho = res.final("cho_ox")          # mmol pyruvate oxidised /L
        fat = res.final("fat_ox")          # mmol palmitate /L
        ket = res.final("ket_ox")          # mmol BHB /L
        cc, fc, kc = 3.0 * cho, 16.0 * fat, 4.0 * ket
        carbon = cc + fc + kc
        v["carbohydrate_oxidation"] = cho / dur * 1000.0    # umol/L/s
        v["fat_oxidation"] = fat / dur * 1000.0
        v["ketone_oxidation"] = ket / dur * 1000.0
        v["fat_carbon_fraction"] = fc / carbon if carbon > 0 else 0.0
        v["cho_carbon_fraction"] = cc / carbon if carbon > 0 else 0.0
        v["ketone_carbon_fraction"] = kc / carbon if carbon > 0 else 0.0
        # whole-body-equivalent gram rates for interpretability
        v["fat_g_per_min"] = (fat * st.muscle_water_L * 256.4 / dur * 60.0 /
                              1000.0)
        v["cho_g_per_min"] = (cho * 0.5 * st.muscle_water_L * 180.2 / dur *
                              60.0 / 1000.0)

        gly0 = st.glycogen_mM
        gly_end = float(res.homogenate("GLY")[-1])
        v["glycogen_start"] = gly0 * cw
        v["glycogen_remaining"] = gly_end * cw
        v["glycogen_used"] = (gly0 - gly_end) * cw
        v["glycogen_used_pct"] = (gly0 - gly_end) / max(gly0, 1e-9) * 100.0
        v["glycogen_floor"] = st.glycogen_floor_mM * cw

        pcr_series = res.homogenate("PCr")
        pcr0 = f1 * res.y0[IDX["PCr"]] + (1 - f1) * res.y0[NSP + IDX["PCr"]]
        v["pcr_end_fraction"] = float(pcr_series[-1] / max(pcr0, 1e-9))
        v["pcr_minimum_fraction"] = float(np.min(pcr_series) / max(pcr0, 1e-9))

        lac_made = res.final("lac_prod")
        v["lactate_production"] = lac_made / dur * 1000.0
        # ATP attributable to lactate production: the genuinely non-oxidative
        # contribution. This is not the same as the glycolytic ATP fraction,
        # which counts substrate-level ATP from glycolytic flux whose pyruvate
        # was subsequently oxidised. Glycogen to lactate yields 3 ATP per two
        # lactate, so 1.5 per lactate.
        v["nonoxidative_atp_fraction"] = (1.5 * lac_made / tot) if tot > 0 else 0.0
        v["blood_lactate_peak"] = float(np.max(res.y[I_LACB]))
        v["blood_lactate_end"] = float(res.y[I_LACB][-1])
        v["muscle_lactate_end"] = float(res.homogenate("LAC")[-1])
        v["muscle_ph_min"] = float(np.min(res.homogenate("PH")))
        v["muscle_ph_type2_min"] = float(np.min(res.sp("PH", "II")))

        fl = res.fluxes_at(len(res.t) - 1)
        v["tca_flux"] = f1 * fl["I"]["j_tca"] + (1 - f1) * fl["II"]["j_tca"]
        v["etc_flux"] = (f1 * (fl["I"]["j_ox_n"] + fl["I"]["j_ox_f"]) +
                         (1 - f1) * (fl["II"]["j_ox_n"] + fl["II"]["j_ox_f"]))

        # ---- derived mechanism outputs (spec 3.2) -----------------------
        # Spare oxidative capacity: how much more oxidative ATP the muscle
        # could make if the respiratory control terms went to saturation,
        # bounded by the person's oxygen ceiling.
        ox_rate = ox / dur
        ceiling_atp = st.vo2max_muscle_mM_s * st.atp_per_o2
        v["spare_oxidative_capacity"] = max(0.0, 1.0 - ox_rate / ceiling_atp)
        v["oxidative_ceiling_workload"] = ceiling_atp
        v["relative_intensity"] = float(np.mean(dp.rel_intensity))

        atp_I = fl["I"]["j_atpase"] * f1
        atp_II = fl["II"]["j_atpase"] * (1 - f1)
        tt = atp_I + atp_II
        v["type1_atp_share"] = atp_I / tt if tt > 0 else 0.0
        v["type2_atp_share"] = atp_II / tt if tt > 0 else 0.0

        # Time to glycogen limitation: when mixed glycogen would reach the
        # non-mobilisable floor at the observed depletion rate.
        rate = (gly0 - gly_end) / dur
        floor = st.glycogen_floor_mM
        if rate > 1e-9 and gly_end > floor:
            v["time_to_glycogen_limit"] = (gly_end - floor) / rate / 60.0 + \
                sc.duration_min
        elif gly_end <= floor:
            v["time_to_glycogen_limit"] = sc.duration_min
        else:
            v["time_to_glycogen_limit"] = 1e4
        v["time_to_glycogen_limit"] = min(v["time_to_glycogen_limit"], 1e4)

        # Time to lactate-accumulation pressure: first crossing of 4 mmol/L
        lacb = res.y[I_LACB]
        idx = np.argmax(lacb >= 4.0) if np.any(lacb >= 4.0) else -1
        v["time_to_lactate_pressure"] = (float(res.t[idx]) / 60.0 if idx >= 0
                                         else 1e4)

        # Crossover: relative intensity at which carbohydrate carbon exceeds fat
        v["crossover_reached"] = 1.0 if cc > fc else 0.0

        # ---- mitochondrial redox-state diagnostics ----------------------
        # Reported on every run, not only when a mechanism is requested: the
        # matrix redox state is what a NAD counterfactual acts through, and a
        # reader cannot judge such a contrast without seeing where the pool sat
        # before it. The fractions are of the *recruited* fibres, which is a
        # model construct -- no measurement can separate them in a person.
        nadh_series = res.mixed("NADHm")
        nadh_rest = (f1 * res.y0[IDX["NADHm"]] +
                     (1 - f1) * res.y0[NSP + IDX["NADHm"]])
        v["nad_mito_pool"] = mm.nad_m
        v["matrix_nadh_fraction_rest"] = float(nadh_rest / mm.nad_m)
        v["matrix_nadh_fraction_max"] = float(np.max(nadh_series) / mm.nad_m)
        v["matrix_nadh_fraction_min"] = float(np.min(nadh_series) / mm.nad_m)
        v["rest_polished"] = 1.0 if getattr(mm, "rest_polished", False) else 0.0
        v["rest_residual"] = float(getattr(mm, "rest_residual", np.nan))
        v["rest_activation_clipped"] = (
            1.0 if any(mm.km_adp_clipped.values()) else 0.0)

        adp_end = free_adp(float(res.mixed("ATP")[-1]), mm.atp_total, mm.ak_keq)
        v["free_adp_end"] = adp_end
        v["o2_min_type2"] = float(np.min(res.sp("O2", "II")))
        v["o2_saturation_type2"] = v["o2_min_type2"] / mm.o2_cap
        # How much the respiratory chain was actually slowed by low oxygen: 1.0
        # means oxygen never limited it, lower values mean it did.
        o2t2 = res.sp("O2", "II")
        v["o2_limitation_factor"] = float(np.min(o2t2 / (mm.km_o2 + o2t2)))

        params = dict(st.bp)
        params.update({
            "vo2max_env": st.vo2max_env, "vo2max_sea": st.vo2max_sea,
            "economy": st.economy, "type1_frac": st.type1_frac,
            "mito_scale": st.mito_scale, "fat_ox_scale": st.fat_ox_scale,
            "active_muscle_kg": st.active_muscle_kg,
            "glycogen_start_mmol_kg": st.glycogen_mmol_kg_ww,
            "blood_ffa": st.blood_ffa, "blood_glucose": st.blood_glucose,
            "blood_bhb": st.blood_bhb, "insulin_idx": st.insulin_idx,
            "grade_penalty": st.grade_penalty, "atp_per_o2": st.atp_per_o2,
            "nonmuscle_frac": st.nonmuscle_frac,
        })

        gf: List[str] = []
        if audit:
            for f in guardrails.audit_simulation(res, mm):
                if not f.passed:
                    gf.append(f"{f.check}: {f.detail}")

        traj: Dict[str, Any] = {}
        if keep_traj:
            k = max(1, len(res.t) // 48)
            traj = {
                "t_min": (res.t[::k] / 60.0).tolist(),
                "vo2": (np.gradient(res.acc("o2"), res.t)[::k] *
                        st.muscle_water_L * R.value("o2_molar_volume") /
                        (1 - st.nonmuscle_frac) / st.body_mass_kg * 60.0).tolist(),
                "pcr_frac": (res.homogenate("PCr")[::k] / max(pcr0, 1e-9)).tolist(),
                "blood_lactate": res.y[I_LACB][::k].tolist(),
                "ph": res.homogenate("PH")[::k].tolist(),
                "glycogen": (res.homogenate("GLY")[::k] * cw).tolist(),
                "ph_type2": res.sp("PH", "II")[::k].tolist(),
                "o2_type2": res.sp("O2", "II")[::k].tolist(),
                "rel_intensity": np.interp(res.t[::k], dp.t,
                                           dp.rel_intensity).tolist(),
            }
        return MemberResult(True, v, params, traj, gf, mechanisms=mech_out)
    except IntegrationBudgetExceeded as e:
        return MemberResult(False, error=f"integration budget exceeded: {e}",
                            mechanisms=mech_out)
    except Exception as e:  # keep the ensemble alive, record the failure
        return MemberResult(False, error=f"{type(e).__name__}: {e}",
                            mechanisms=mech_out)


# --------------------------------------------------------------------------
# Estimate definitions
# --------------------------------------------------------------------------

EST_DEFS: List[Tuple[str, str, str, str, str, str]] = [
    # key, label, unit, kind, support, note
    ("atp_demand", "ATP demand", "mmol/L cell water/s", "model_computed",
     "assumed", "Mean ATP hydrolysis rate imposed on the modelled muscle."),
    ("atp_coverage", "ATP demand coverage", "fraction", "model_computed",
     "adjacent", "Fraction of the demanded ATP the fibres actually supplied; "
     "below 1 means the simulated muscle had to lose force."),
    ("oxidative_atp_fraction", "Oxidative ATP fraction", "fraction",
     "model_computed", "adjacent",
     "Counts the tricarboxylic-acid cycle's own substrate-level GTP alongside "
     "the respiratory chain's ATP, since both depend on oxygen arriving."),
    ("glycolytic_atp_fraction", "Glycolytic ATP fraction", "fraction",
     "model_computed", "adjacent",
     "Substrate-level ATP from glycolysis, including flux whose pyruvate was "
     "subsequently oxidised."),
    ("pcr_atp_fraction", "Phosphocreatine ATP contribution", "fraction",
     "model_computed", "direct",
     "Share of ATP buffered through the phosphocreatine/creatine-kinase system."),
    ("muscle_vo2", "Muscle oxygen consumption", "mL/kg muscle/min",
     "model_computed", "adjacent",
     "Depends on how much muscle is assumed to be working, which is inferred "
     "rather than measured. The same total oxygen use spread over more or less "
     "muscle moves this number without anything about the run changing."),
    ("whole_body_vo2_equiv", "Whole-body VO2 equivalent", "mL/kg/min",
     "model_computed", "indirect",
     "Only an equivalent: it assumes the fixed share of oxygen uptake that "
     "goes to non-locomotor tissue, so it should be compared with a "
     "cardio-fitness estimate loosely rather than matched to it."),
    ("carbohydrate_oxidation", "Carbohydrate oxidation (pyruvate flux)",
     "umol/L/s", "model_computed", "adjacent",
     "Pyruvate entering the mitochondrion, from glycogen and blood glucose."),
    ("fat_oxidation", "Fatty-acid oxidation", "umol palmitate-eq/L/s",
     "model_computed", "adjacent", "Beta-oxidation flux in palmitate "
     "equivalents."),
    ("ketone_oxidation", "Ketone oxidation", "umol/L/s", "model_computed",
     "extrapolated", "Beta-hydroxybutyrate oxidation; the weakest-supported "
     "pathway in version 1."),
    ("fat_carbon_fraction", "Fat share of oxidised carbon", "fraction",
     "model_computed", "indirect",
     "This is a share of carbon, not of energy. Fat carries roughly a third "
     "more energy per carbon atom than carbohydrate does, so fat's "
     "contribution to the energy of the run is larger than this number."),
    ("cho_carbon_fraction", "Carbohydrate share of oxidised carbon", "fraction",
     "model_computed", "indirect",
     "Carbon entering the TCA cycle as pyruvate, from glycogen and blood "
     "glucose."),
    ("ketone_carbon_fraction", "Ketone share of oxidised carbon", "fraction",
     "model_computed", "extrapolated",
     "Carbon entering the TCA cycle from beta-hydroxybutyrate."),
    ("fat_g_per_min", "Fat oxidation (whole-body equivalent)", "g/min",
     "model_computed", "indirect",
     "For comparison with indirect calorimetry, which measures whole-body "
     "substrate use and is less reliable in non-steady-state or very intense "
     "exercise."),
    ("cho_g_per_min", "Carbohydrate oxidation (whole-body equivalent)", "g/min",
     "model_computed", "indirect", "As above."),
    ("glycogen_used", "Muscle glycogen consumed", "mmol glucosyl/kg wet weight",
     "model_computed", "direct",
     "Reported as a homogenate: recruited and unrecruited fibres averaged the "
     "way a needle biopsy homogenises a sample, rather than the state of the "
     "recruited fibres alone."),
    ("glycogen_remaining", "Muscle glycogen remaining",
     "mmol glucosyl/kg wet weight", "model_computed", "direct",
     "The engine reports a compatible-with band rather than a "
     "biopsy-equivalent concentration, because muscle glycogen cannot be known "
     "from any input this product accepts."),
    ("glycogen_used_pct", "Glycogen store consumed", "%", "model_computed",
     "direct", ""),
    ("pcr_end_fraction", "Phosphocreatine at end of run",
     "fraction of resting", "model_computed", "direct",
     "Reported as a homogenate: recruited and unrecruited fibres averaged the "
     "way a 31P magnetic resonance voxel averages them, which is what makes it "
     "comparable with a measurement at all."),
    ("pcr_minimum_fraction", "Lowest phosphocreatine during run",
     "fraction of resting", "model_computed", "direct", ""),
    ("nonoxidative_atp_fraction", "Non-oxidative ATP fraction", "fraction",
     "derived", "adjacent",
     "ATP attributable to lactate production, at 1.5 ATP per lactate. This is "
     "the 'anaerobic' contribution in the usual sense, and it is smaller than "
     "the glycolytic ATP fraction, which also counts substrate-level ATP from "
     "glycolytic flux whose pyruvate was fully oxidised."),
    ("lactate_production", "Lactate production", "umol/L/s", "model_computed",
     "adjacent", "Forward lactate dehydrogenase flux in the muscle."),
    ("blood_lactate_peak", "Peak arterial lactate", "mmol/L", "model_computed",
     "direct",
     "Comparable in principle with a fingertip lactate curve. The interval on "
     "this output is wide and right-skewed, and deliberately so: it is set by "
     "the half-activating ADP of oxidative phosphorylation and the "
     "half-activating AMP of glycolysis, two population kinetic constants that "
     "no wearable or routine laboratory input can constrain. A single "
     "same-day capillary lactate measurement, entered as a same-day lab value, "
     "narrows this more than any other input this engine accepts."),
    ("muscle_ph_min", "Lowest mixed-muscle pH", "pH", "model_computed",
     "direct", ""),
    ("muscle_ph_type2_min", "Lowest type II fibre pH", "pH", "model_computed",
     "adjacent", "Fibre-specific pH is not measurable in an intact person; "
     "this is a model construct."),
    ("tca_flux", "TCA-cycle flux", "mmol/L/s", "model_computed", "adjacent", ""),
    ("etc_flux", "Electron transport chain flux",
     "mmol reducing equivalents/L/s", "model_computed", "adjacent", ""),
    # derived
    ("spare_oxidative_capacity", "Spare oxidative capacity", "fraction",
     "derived", "assumed",
     "Measured against an aerobic ceiling that is itself inferred, largely "
     "from a wrist cardio-fitness estimate rather than from gas exchange. It "
     "inherits all of that estimate's uncertainty, which is why its support "
     "grade is the weakest on this page."),
    ("oxidative_ceiling_workload", "Workload at the oxidative ceiling",
     "mmol ATP/L/s", "derived", "indirect",
     "A ceiling on ATP turnover, not on pace. Reaching it in the model means "
     "oxygen supply can no longer grow, not that the person must stop."),
    ("time_to_glycogen_limit", "Time to glycogen limitation", "min", "derived",
     "adjacent", "Extrapolated from the observed depletion rate; capped at "
     "10000 min when no limit is approached."),
    ("time_to_lactate_pressure", "Time to 4 mmol/L arterial lactate", "min",
     "derived", "direct", "Capped at 10000 min when never reached."),
    ("type1_atp_share", "Type I fibre share of ATP turnover", "fraction",
     "derived", "adjacent", ""),
    ("type2_atp_share", "Type II fibre share of ATP turnover", "fraction",
     "derived", "adjacent", ""),
    ("atp_per_oxygen", "ATP per oxygen consumed", "mol/mol", "derived",
     "direct", "Efficiency of the modelled oxidative system. This is a model "
     "quantity, not a measurement of coupling in this person."),
    ("free_adp_end", "Free cytosolic ADP at end of run", "mmol/L", "derived",
     "adjacent", ""),
    ("o2_limitation_factor", "Oxygen sufficiency for the respiratory chain "
     "(type II)", "fraction of unlimited rate", "derived", "adjacent",
     "1.0 means intracellular oxygen never slowed the chain; lower values mean "
     "delivery genuinely limited it."),
    ("o2_saturation_type2", "Type II intracellular oxygen at its lowest",
     "fraction of capacity", "derived", "adjacent",
     "Low values indicate the fast fibres became delivery-limited."),
    ("relative_intensity", "Relative intensity", "fraction of VO2max",
     "derived", "indirect", ""),
    ("blood_lactate_end", "Arterial lactate at end of run", "mmol/L",
     "model_computed", "direct", ""),
    # ---- mitochondrial redox state ----------------------------------------
    ("nad_mito_pool", "Mitochondrial NAD pool applied", "mmol/L matrix water",
     "model_computed", "adjacent",
     "The matrix NAD pool each ensemble member actually ran with, after any "
     "mechanism transform. It is a sampled population parameter, not a "
     "measurement: nothing this product accepts as input can constrain it."),
    ("matrix_nadh_fraction_rest", "Matrix NADH fraction before the run",
     "fraction of the matrix NAD pool", "model_computed", "adjacent",
     "The resting redox state the run actually started from. The engine "
     "initialises the matrix at the registered resting ratio and then relaxes "
     "to a fixed point, and the fixed point is set by the balance of "
     "dehydrogenase and respiratory-chain fluxes rather than by that initial "
     "value. It generally settles somewhat more reduced than the registered "
     "ratio, and more so in the faster fibres, whose oxidative capacity is "
     "lower relative to their resting demand. Compare it against the sampled "
     "nadh_mito_rest_ratio in the member parameters rather than against the "
     "measured 20-30% band."),
    ("matrix_nadh_fraction_max", "Most reduced matrix NADH fraction under load",
     "fraction of the matrix NAD pool", "derived", "adjacent",
     "The fibre-level redox state is a model construct: no measurement can "
     "separate recruited from unrecruited fibres in an intact person."),
    ("matrix_nadh_fraction_min", "Least reduced matrix NADH fraction under load",
     "fraction of the matrix NAD pool", "derived", "adjacent", ""),
    ("muscle_lactate_end", "Muscle lactate at end of run", "mmol/L",
     "model_computed", "adjacent", ""),
]


# --------------------------------------------------------------------------
# Plain-language meanings
# --------------------------------------------------------------------------
# EST_DEFS carries each output's label, unit and caveats. These are the
# separate thing a reader needs first: what the quantity actually is, and how
# to read a value of it. They live here rather than in the web page so that
# there is one description of each output rather than two that can drift.

OUTPUT_MEANINGS: Dict[str, str] = {
    "atp_demand":
        "How much ATP the modelled muscle must break down each second to hold "
        "this pace. It comes from the running-demand model -- pace, gradient "
        "and body mass -- before any biochemistry is involved. Roughly 0.5 is "
        "easy running and 1.2 is close to this person's ceiling.",
    "atp_coverage":
        "The fraction of that demand the fibres actually managed to supply. "
        "One means the run was completable as specified. Below one means the "
        "simulated muscle had to give up force to protect its ATP, which is "
        "what task failure looks like in this model.",
    "oxidative_atp_fraction":
        "The share of ATP made by burning fuel with oxygen in the "
        "mitochondria. For a run you could hold for an hour this is normally "
        "close to nine tenths; it falls as the effort gets harder.",
    "glycolytic_atp_fraction":
        "The share of ATP made directly within glycolysis, the pathway that "
        "breaks sugar down to pyruvate. It counts glycolysis whose pyruvate "
        "was afterwards burned with oxygen, so it is larger than the "
        "'anaerobic' contribution people usually mean.",
    "nonoxidative_atp_fraction":
        "The genuinely anaerobic share: the ATP attributable to lactate "
        "actually being produced. This is the number that corresponds to what "
        "is normally called the anaerobic contribution.",
    "pcr_atp_fraction":
        "The share of ATP buffered through phosphocreatine, the muscle's "
        "instant energy reserve. It matters most in the first seconds of a run "
        "and at the start of every interval, and is small when averaged over a "
        "long steady effort.",
    "muscle_vo2":
        "Oxygen used per kilogram of working muscle per minute. This is much "
        "larger than the whole-body figure a watch reports, because most of "
        "the body is not doing the running.",
    "whole_body_vo2_equiv":
        "The same oxygen use scaled back up to a whole-body figure, so it can "
        "be compared with a cardio-fitness estimate or a metabolic cart.",
    "carbohydrate_oxidation":
        "The rate at which pyruvate -- the product of breaking down sugar and "
        "stored glycogen -- enters the mitochondria to be burned.",
    "fat_oxidation":
        "The rate at which fatty acids are broken down for fuel, expressed in "
        "palmitate equivalents because the model lumps fats into one "
        "representative chain length.",
    "ketone_oxidation":
        "The rate at which ketone bodies are burned. Normally negligible, but "
        "it rises with prolonged fasting and with a ketone supplement.",
    "fat_carbon_fraction":
        "Of the carbon arriving in the mitochondria to be burned, the share "
        "that came from fat rather than from carbohydrate. Higher means more "
        "fat-fuelled. It rises with fasting and falls as the pace gets harder.",
    "ketone_carbon_fraction":
        "The share of burned carbon that arrived as ketone bodies. Close to "
        "zero in ordinary conditions; it becomes visible only after a long "
        "fast or a ketone supplement.",
    "cho_carbon_fraction":
        "The mirror image of the fat share: the proportion of burned carbon "
        "that came from carbohydrate, whether from muscle glycogen or from "
        "blood glucose.",
    "fat_g_per_min":
        "Fat burned per minute, scaled to a whole-body figure so it can be "
        "compared with a metabolic cart. Trained runners peak around "
        "0.5-0.7 g per minute.",
    "cho_g_per_min":
        "Carbohydrate burned per minute, as a whole-body figure. This is the "
        "number that determines how long you can go before needing to eat.",
    "glycogen_used":
        "How much of the muscle's own stored carbohydrate the run consumed, "
        "per kilogram of muscle. This is what a needle biopsy measures. The "
        "starting level is estimated rather than known, so the change is more "
        "trustworthy than the level.",
    "glycogen_remaining":
        "What is left in the store at the end of the run. Treat it as a band "
        "-- low, moderate or high -- rather than as a precise concentration.",
    "glycogen_used_pct":
        "The same depletion expressed as a percentage of the store the run "
        "started with.",
    "pcr_end_fraction":
        "Phosphocreatine remaining at the end of the run, as a fraction of the "
        "resting amount. It falls further the harder the effort, and it is one "
        "of the few quantities here that can be measured in a living person, "
        "by magnetic resonance spectroscopy.",
    "pcr_minimum_fraction":
        "The lowest phosphocreatine reached at any point, which for an "
        "interval session is deeper than the value at the end.",
    "lactate_production":
        "The rate at which lactate is being formed inside the muscle. Lactate "
        "is a fuel the body makes and reuses, not a waste product.",
    "blood_lactate_peak":
        "The highest lactate concentration reached in the blood during the "
        "run. Lactate builds up when the muscle produces it faster than the "
        "body clears it, so the number marks how hard the effort was relative "
        "to this person's own threshold rather than in absolute terms. As a "
        "rough guide: around 1-2 mmol/L is easy running, about 4 is the "
        "concentration often used to mark threshold, and 8 or more is hard. "
        "This is measurable with a fingertip test strip.",
    "blood_lactate_end":
        "Blood lactate at the moment the run finishes, which is lower than the "
        "peak if the effort eased off or the body caught up with clearance.",
    "muscle_lactate_end":
        "Lactate inside the muscle itself, which runs several times higher "
        "than the blood concentration during hard efforts because export takes "
        "time.",
    "muscle_ph_min":
        "The most acidic the muscle became. Resting muscle sits near pH 7.05; "
        "hard running can push it toward 6.5, and the acidity itself slows the "
        "enzymes that release energy.",
    "muscle_ph_type2_min":
        "The same, but inside the faster fibres alone, which acidify further "
        "than the muscle as a whole. No measurement can separate the fibre "
        "types in a living person, so this is a model construct.",
    "tca_flux":
        "Throughput of the tricarboxylic acid cycle, the hub that oxidises "
        "carbon from every fuel and feeds the respiratory chain.",
    "etc_flux":
        "Throughput of the electron transport chain: the rate at which "
        "reducing equivalents are being handed to oxygen to make ATP.",
    "spare_oxidative_capacity":
        "How much of the aerobic ceiling is still unused. A value of 0.4 means "
        "the run is drawing about 60% of the maximum oxygen this person's "
        "muscle could take up, leaving 40% in reserve. Zero means there is "
        "nothing left.",
    "oxidative_ceiling_workload":
        "The ATP turnover the oxidative system could sustain at this person's "
        "estimated aerobic ceiling -- the roof the demand is being compared "
        "against.",
    "time_to_glycogen_limit":
        "How long this pace could continue before muscle carbohydrate runs "
        "low, extrapolated from the rate it is being used. Very large values "
        "mean the store is not being meaningfully approached.",
    "time_to_lactate_pressure":
        "How long until blood lactate reaches 4 mmol/L, a concentration often "
        "used to mark threshold. Reported as not reached when it never gets "
        "there.",
    "type1_atp_share":
        "The share of the work being done by the slow, fatigue-resistant "
        "fibres. They are recruited first and carry most of an easy run.",
    "type2_atp_share":
        "The share carried by the faster fibres. They are recruited "
        "progressively as the pace rises, and they are more glycolytic, which "
        "is why lactate climbs with intensity.",
    "atp_per_oxygen":
        "How much ATP the mitochondria produced per oxygen molecule consumed. "
        "It reflects which fuel is being burned and how tightly coupled the "
        "modelled system is. It is a property of the model, not a measurement "
        "of this person's mitochondria.",
    "o2_limitation_factor":
        "Whether oxygen supply itself was holding the respiratory chain back. "
        "One means it never did; lower values mean delivery genuinely limited "
        "the rate.",
    "o2_saturation_type2":
        "How much oxygen was left inside the faster fibres at their most "
        "depleted, as a fraction of what they can hold. Low values mean those "
        "fibres were working close to their oxygen supply.",
    "free_adp_end":
        "Free ADP in the cytosol at the end of the run. It is the signal that "
        "tells the mitochondria to make more ATP, and it rises as "
        "phosphocreatine falls.",
    "relative_intensity":
        "The average effort as a fraction of this person's own aerobic "
        "ceiling, which is what makes the same scenario comparable across "
        "people of different fitness.",
    "nad_mito_pool":
        "How much NAD, oxidised and reduced together, the model gave the "
        "mitochondrial matrix to work with. NAD is the carrier that collects "
        "electrons from fuel and hands them to the respiratory chain, so the "
        "size of this pool sets how much traffic the handover can carry at "
        "once. It is drawn from a population range, not measured.",
    "matrix_nadh_fraction_rest":
        "What share of that pool was already carrying electrons -- in the "
        "reduced NADH form -- when the run started. Resting muscle sits "
        "around a fifth to a third reduced. Higher means the carriers are "
        "fuller and less able to accept more.",
    "matrix_nadh_fraction_max":
        "The fullest the carriers got during the run. Approaching one means "
        "the chain could not clear electrons as fast as fuel oxidation "
        "delivered them, which slows the dehydrogenases feeding it.",
    "matrix_nadh_fraction_min":
        "The emptiest the carriers got, which is when the respiratory chain "
        "was clearing electrons faster than fuel oxidation supplied them.",
}


# Below this, nothing was really close to binding.
LIMITING_THRESHOLD = 0.30


def _limiting_scores(v: Dict[str, float], duration_min: float) -> Dict[str, float]:
    """Score each candidate mechanism by how close it came to binding.

    Ordering candidates by a fixed priority is wrong: more than one condition
    is usually partly true, and a fixed list reports whichever happens to sit
    first. A runner who exhausted muscle glycogen on a two-hour run, whose
    phosphocreatine collapsed and whose ATP demand stopped being covered, was
    being reported as limited by oxygen delivery, because a routine
    oxygen-sufficiency flag sat above glycogen in the list. Each candidate is
    now scored on a common scale of how hard it is biting, and the strongest
    wins.
    """
    def clamp(x):
        return float(min(max(x, 0.0), 1.5))

    floor = v.get("glycogen_floor", 0.0)
    remaining = v.get("glycogen_remaining", 1e9)
    headroom = max(remaining - floor, 0.0)
    # 1.0 once the store is at its non-mobilisable floor.
    gly_score = clamp(1.0 - headroom / 25.0)
    t_gly = v.get("time_to_glycogen_limit", 1e4)
    if t_gly < 1e3:
        gly_score = max(gly_score, clamp(1.4 - t_gly / max(duration_min, 1e-9)))

    # Upstream causes: things that can actually run out or bind.
    upstream = {
        "muscle glycogen availability": gly_score,
        "acidosis from non-oxidative ATP supply":
            clamp((6.95 - v.get("muscle_ph_type2_min", 7.1)) / 0.40),
        # Calibrated against what the model actually produces: type II
        # intracellular oxygen sufficiency runs near 0.93 at an easy pace and
        # near 0.39 at the aerobic ceiling. Referencing this against 0.90 would
        # make oxygen the nominated limit at Zone 2, which over-claims; 0.75
        # makes it fire only where oxygen genuinely starts to bind.
        "oxygen delivery to type II fibres":
            clamp((0.75 - v.get("o2_limitation_factor", 1.0)) / 0.45),
        "oxidative capacity relative to demand":
            clamp((0.12 - v.get("spare_oxidative_capacity", 1.0)) / 0.12),
        "phosphocreatine buffer depletion":
            clamp((0.35 - v.get("pcr_minimum_fraction", 1.0)) / 0.30),
    }
    # Failing to cover ATP demand is a symptom, not a cause. When it happens
    # alongside an identifiable upstream cause, report the cause and let the
    # coverage failure raise its score; only report the symptom when nothing
    # upstream explains it.
    cov = clamp((1.0 - v.get("atp_coverage", 1.0)) / 0.06)
    scores = dict(upstream)
    top, top_score = max(upstream.items(), key=lambda kv: kv[1])
    if cov >= LIMITING_THRESHOLD and top_score >= LIMITING_THRESHOLD:
        scores[top] = top_score + cov
    else:
        scores["ATP demand exceeded what the fibres could supply"] = cov
    return scores


def _limiting(v: Dict[str, float], duration_min: float) -> str:
    scores = _limiting_scores(v, duration_min)
    name, score = max(scores.items(), key=lambda kv: kv[1])
    if score < LIMITING_THRESHOLD:
        return "no mechanism became limiting in this scenario"
    return name


# --------------------------------------------------------------------------
# Mechanism reporting
# --------------------------------------------------------------------------

def _mechanism_assumptions(sc: Scenario,
                           results: List[MemberResult]) -> List[Dict[str, Any]]:
    """One machine-readable record per requested mechanism.

    The status is reported per ensemble member and then summarised, because a
    transform can be applied to most draws and refused for a few -- and a
    report that showed only the majority status would hide exactly the members
    whose biochemistry could not accommodate the requested state.
    """
    if not sc.mechanisms:
        return []
    records: List[Dict[str, Any]] = []
    for use in sc.mechanisms:
        spec = MECHANISMS.get(use.mechanism)
        seen = [o for r in results for o in r.mechanisms
                if o.name == use.mechanism]
        counts: Dict[str, int] = {}
        for o in seen:
            counts[o.status] = counts.get(o.status, 0) + 1
        changed: List[str] = []
        notes: List[str] = []
        reasons: List[str] = []
        for o in seen:
            for k in o.parameter_changes:
                if k not in changed:
                    changed.append(k)
            for n in o.notes:
                if n not in notes:
                    notes.append(n)
            if o.reason and o.reason not in reasons:
                reasons.append(o.reason)
        status = (max(counts.items(), key=lambda kv: kv[1])[0]
                  if counts else "not_estimable")
        mediators = _summarise_mediators(seen)
        # A stable subset of the per-member provenance. The version of the
        # evidence a lever used has to travel with its result -- a number
        # produced under one extraction of the literature is not the same
        # claim as the same number produced under the next one.
        versions = {str(o.provenance["evidence_version"]) for o in seen
                    if o.provenance.get("evidence_version")}
        sens = [bool(o.provenance.get("sensitivity_only")) for o in seen
                if "sensitivity_only" in o.provenance]
        rec: Dict[str, Any] = {
            "mechanism": use.mechanism,
            "settings": dict(use.settings),
            "horizon_days": use.horizon_days,
            "status": status,
            "status_counts": counts,
            "n_members": len(seen),
            "changed_parameters": changed,
            "mediators": mediators,
            "evidence_version": sorted(versions)[0] if versions else None,
            "sensitivity_only_fraction": (
                round(sum(sens) / len(sens), 3) if sens else None),
            "represented_paths": list(spec.represented_paths) if spec else [],
            "unrepresented_paths": list(spec.unrepresented_paths) if spec else [],
            "scope_note": spec.scope_note if spec else "",
            "mapping_note": (spec.mapping_note if spec
                             else NO_INTERVENTION_MAPPING),
            "notes": notes,
            "reasons": reasons,
        }
        if spec is not None:
            rec["evidence"] = spec.evidence.to_dict()
            rec["question"] = spec.question
        records.append(rec)
    return records


def _summarise_mediators(seen: List[EffectOutcome]) -> Dict[str, Any]:
    """Collapse per-member mediator records into one distribution each.

    A mediator delta is drawn per member, so reporting the raw records would
    repeat the same sentence with a different number for every draw. What a
    reader needs is the distribution, plus -- for the mediators that are gated
    -- the single reason they are, stated once.
    """
    out: Dict[str, Any] = {}
    for outcome in seen:
        for name, rec in outcome.mediator_changes.items():
            if not isinstance(rec, dict):
                continue
            slot = out.setdefault(name, {"status": rec.get("status"),
                                         "applied": rec.get("applied", False),
                                         "deltas": []})
            for key in ("reason", "unit", "lands_on", "would_land_on",
                        "evidence_grade", "observed_followup"):
                if key in rec and key not in slot:
                    slot[key] = rec[key]
            if rec.get("applied") and isinstance(rec.get("delta"), (int, float)):
                slot["deltas"].append(float(rec["delta"]))
    for name, slot in out.items():
        deltas = slot.pop("deltas", [])
        if deltas:
            a = np.asarray(deltas, dtype=float)
            slot["delta_median"] = float(np.median(a))
            slot["delta_ci80"] = [float(np.percentile(a, 10)),
                                  float(np.percentile(a, 90))]
            slot["n_members"] = int(a.size)
    return out


def _mechanism_warnings(records: List[Dict[str, Any]]) -> List[str]:
    out: List[str] = []
    for rec in records:
        name = rec["mechanism"]
        if rec["status"] not in ("estimated",):
            out.append(
                f"Mechanism '{name}': {rec['status']}. " +
                (rec["reasons"][0] if rec["reasons"] else
                 STATUS_MEANINGS.get(rec["status"], "")))
        else:
            out.append(f"Mechanism '{name}' changed "
                       f"{', '.join(rec['changed_parameters']) or 'nothing'}. "
                       f"{rec['scope_note']} {rec['mapping_note']}")
            frac = rec.get("sensitivity_only_fraction")
            if frac:
                out.append(
                    f"In {frac*100:.0f}% of ensemble members the requested "
                    f"state for '{name}' fell outside the registered "
                    "physiological prior. Those members are sensitivity-only: "
                    "they show how the model responds and do not inherit the "
                    "prior's biological support.")
            if rec["unrepresented_paths"]:
                out.append(
                    f"Not represented in this model for '{name}': " +
                    "; ".join(rec["unrepresented_paths"]) +
                    ". A null result along any of those routes is a property "
                    "of the model, not biological evidence.")
        for n in rec["notes"]:
            if n not in out:
                out.append(n)
        gated = [m for m, slot in rec.get("mediators", {}).items()
                 if not slot.get("applied")]
        if gated:
            out.append(
                f"Mediators declared by '{name}' but not applied: " +
                ", ".join(sorted(gated)) +
                ". Each is gated in the evidence table with its own reason; "
                "nothing was changed along those paths, so the result says "
                "nothing about them.")
        mixed = {k: v for k, v in rec["status_counts"].items()
                 if k != rec["status"]}
        if mixed:
            out.append(
                f"Mechanism '{name}' did not reach the same status in every "
                "ensemble member: " +
                ", ".join(f"{k} in {v}" for k, v in sorted(mixed.items())) +
                f" of {rec['n_members']}.")
    return out


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------

def run_ensemble(person: PersonInputs, sc: Scenario, n: int = 200,
                 seed: int = 20260826, qc: Optional[QCReport] = None,
                 workers: Optional[int] = None, keep_traj: int = 48,
                 audit: bool = True,
                 state_transform: Optional[Any] = None) -> RunOutputs:
    """Run one scenario across `n` plausible personal states.

    ``state_transform`` is a research seam, not a product control.  It applies
    a callable to each drawn personal state after any registered mechanism, and
    exists so that the identifiability study in ``identifiability.py`` can
    sweep axes the product deliberately does not expose.  Nothing a user can
    reach -- the CLI, the scenario schema, the web API -- can set it, and a run
    that uses it stays serial so the transform never has to be shipped to a
    worker process.
    """
    t0 = time.time()
    qc = qc or run_qc(person)
    sampler, meta = build_sampler(person, qc, sc)

    warnings: List[str] = []
    if qc.blocked:
        blockers = [f.message for f in qc.findings if f.severity == "block"]
        return RunOutputs(
            scenario={"description": sc.describe(), **sc.to_dict()},
            estimates={},
            metadata=_metadata(person, sc, qc, meta, 0, 0.0),
            warnings=["NOT ESTIMABLE for this person: " + " ".join(blockers)],
            mechanism_assumptions=_mechanism_assumptions(sc, []),
            diagnostics={"blocked": True})

    seeds = [seed + i for i in range(n)]
    results: List[MemberResult] = []
    workers = workers if workers is not None else min(
        8, max(1, (os.cpu_count() or 2) - 1))

    ex = (_get_pool(workers)
          if (workers > 1 and n >= 8 and state_transform is None) else None)
    if ex is not None:
        try:
            futs = [ex.submit(_run_member_task, person, qc, sc, s,
                              i < keep_traj, audit)
                    for i, s in enumerate(seeds)]
            # A hung pool must not hang the caller: fall back to serial. The
            # budget is deliberately tight, because the serial path is only a
            # few times slower and a long wait on a stalled pool is far worse
            # than simply doing the work here.
            budget = 25.0 + 1.5 * n
            deadline = time.time() + budget
            results = []
            for f in futs:
                results.append(f.result(timeout=max(5.0, deadline - time.time())))
        except Exception:
            shutdown_pool()
            results = []
    if not results:
        results = [_run_member(person, qc, sc, sampler, s, i < keep_traj, audit,
                               state_transform)
                   for i, s in enumerate(seeds)]

    good = [r for r in results if r.ok]
    failed = [r for r in results if not r.ok]
    # Which ensemble members survived, by position in the seed order. Two arms
    # of a contrast are seeded identically but need not fail identically, so
    # the surviving positions are what makes them pairable afterwards.
    member_index = [i for i, r in enumerate(results) if r.ok]
    mech_records = _mechanism_assumptions(sc, results)
    if not good:
        return RunOutputs(
            scenario={"description": sc.describe(), **sc.to_dict()},
            estimates={},
            metadata=_metadata(person, sc, qc, meta, 0, time.time() - t0),
            warnings=["Every ensemble member failed to integrate; no output is "
                      "estimable for this scenario."] +
                     _mechanism_warnings(mech_records),
            mechanism_assumptions=mech_records,
            diagnostics={"failures": [r.error for r in failed[:5]]})

    keys = sorted(good[0].values)
    arr = {k: np.array([r.values.get(k, np.nan) for r in good]) for k in keys}
    params = {k: np.array([r.params.get(k, np.nan) for r in good])
              for k in good[0].params}

    estimates: Dict[str, Estimate] = {}
    for key, label, unit, kind, support, note in EST_DEFS:
        if key not in arr:
            continue
        estimates[key] = Estimate(key, label, unit, arr[key], support=support,
                                  kind=kind, note=note)

    from .sensitivity import rank_drivers
    sens = {}
    for key in ("oxidative_atp_fraction", "fat_carbon_fraction",
                "glycogen_used", "blood_lactate_peak", "pcr_end_fraction",
                "spare_oxidative_capacity", "muscle_ph_type2_min",
                "time_to_glycogen_limit"):
        if key in arr:
            sens[key] = rank_drivers(params, arr[key], top=6)
    for key, ranked in sens.items():
        if key in estimates:
            e = estimates[key]
            object.__setattr__(e, "drivers", [d["parameter"] for d in ranked])

    limiting = [_limiting(r.values, sc.duration_min) for r in good]
    counts: Dict[str, int] = {}
    for L in limiting:
        counts[L] = counts.get(L, 0) + 1
    ordered = sorted(counts.items(), key=lambda kv: -kv[1])
    mechanism = {
        "first_limiting_mechanism": ordered[0][0],
        "probability": round(ordered[0][1] / len(limiting), 3),
        "alternate_feasible_mechanisms": [
            {"mechanism": k, "probability": round(c / len(limiting), 3)}
            for k, c in ordered[1:] if c > 0],
        "glycogen_band": band_for_glycogen(
            float(np.median(arr["glycogen_start"]))
            if "glycogen_start" in arr else 100.0),
    }

    guard_fail: Dict[str, int] = {}
    for r in good:
        for g in r.guard_failures:
            k = g.split(":")[0] + ":" + g.split(":")[1] if ":" in g else g
            guard_fail[k] = guard_fail.get(k, 0) + 1

    cov = arr.get("atp_coverage")
    if cov is not None and float(np.median(cov)) < 0.98:
        warnings.append(
            f"In {(cov < 0.98).mean()*100:.0f}% of plausible states the "
            "simulated muscle could not fully cover the demanded ATP turnover; "
            "this scenario may not be completable as specified.")
    for f in qc.findings:
        if f.severity in ("warn", "widen"):
            warnings.append(f.message)
    # "_notes" is an out-of-band list smuggled through the float-valued dict.
    for note in cast(List[str], good[0].values.get("_notes", []) or []):
        warnings.append(note)
    warnings.extend(_mechanism_warnings(mech_records))
    if sc.experimental:
        rng = np.random.default_rng(seed)
        st = sampler(rng)
        _, outcomes = apply_adapters(sc.experimental, st, rng, person)
        for o in outcomes:
            if o.status != "active":
                warnings.append(f"Experimental input '{o.name}': {o.status}. "
                                f"{o.reason}")
            else:
                warnings.extend(o.notes)
    if failed:
        incoherent = sum(1 for r in failed
                         if "physiologically incoherent" in r.error)
        budget = sum(1 for r in failed if "budget exceeded" in r.error)
        other = len(failed) - incoherent - budget
        bits = []
        if incoherent:
            bits.append(f"{incoherent} drew a parameter set in which a fibre "
                        "has less oxidative capacity than its own resting "
                        "demand, which is a corner of the priors rather than a "
                        "person")
        if budget:
            bits.append(f"{budget} were too stiff to integrate within their "
                        "computational budget")
        if other:
            bits.append(f"{other} failed for other reasons recorded in the "
                        "diagnostics block")
        warnings.append(
            f"{len(failed)} of {n} ensemble members were excluded: " +
            "; ".join(bits) + ". The distributions above are over the "
            f"{len(good)} members that remained.")
    if guard_fail:
        warnings.append("Conservation or feasibility checks failed in some "
                        "ensemble members: " + "; ".join(
                            f"{k} ({v} members)" for k, v in guard_fail.items()))

    trajs = [r.traj for r in good if r.traj]
    traj_summary = _summarise_trajectories(trajs)

    md = _metadata(person, sc, qc, meta, len(good), time.time() - t0)
    md["sensitivity"] = sens
    md["ensemble_failures"] = len(failed)

    # How the resting operating point behaved. A mechanism that moves a pool
    # forces the resting calibration to be re-solved, so a reader has to be
    # able to see whether it still held before trusting the contrast.
    rest_diag = {
        "polished_fraction": _frac(arr.get("rest_polished")),
        "activation_clipped_fraction": _frac(arr.get("rest_activation_clipped")),
        "median_residual": (float(np.nanmedian(arr["rest_residual"]))
                            if "rest_residual" in arr else None),
        "note": "The resting state is re-solved for every member. 'Clipped' "
                "means the solved resting activation fell outside its "
                "registered plausibility band and was clamped, which is "
                "recorded rather than hidden.",
    }

    return RunOutputs(
        scenario={"description": sc.describe(), **sc.to_dict()},
        estimates=estimates, metadata=md, mechanism=mechanism,
        mechanism_assumptions=mech_records,
        diagnostics={"failures": [r.error for r in failed[:10]],
                     "guardrail_failures": guard_fail,
                     "rest_calibration": rest_diag,
                     "n_ok": len(good), "n_failed": len(failed)},
        warnings=warnings, trajectories=traj_summary,
        member_params=params, member_values=arr,
        member_index=member_index)


def _frac(a) -> Optional[float]:
    """Fraction of finite members whose 0/1 flag is set."""
    if a is None:
        return None
    x = np.asarray(a, dtype=float)
    x = x[np.isfinite(x)]
    return float(np.mean(x)) if x.size else None


def _summarise_trajectories(trajs: List[Dict[str, Any]]) -> Dict[str, Any]:
    if not trajs:
        return {}
    t = trajs[0]["t_min"]
    n = len(t)
    out: Dict[str, Any] = {"t_min": t, "n_members": len(trajs)}
    for key in ("vo2", "pcr_frac", "blood_lactate", "ph", "glycogen",
                "ph_type2", "o2_type2", "rel_intensity"):
        rows = [tr[key] for tr in trajs if key in tr and len(tr[key]) == n]
        if not rows:
            continue
        a = np.array(rows)
        out[key] = {
            "median": np.nanmedian(a, axis=0).tolist(),
            "p10": np.nanpercentile(a, 10, axis=0).tolist(),
            "p90": np.nanpercentile(a, 90, axis=0).tolist(),
        }
    return out


def _metadata(person, sc, qc, meta, n_ok, elapsed) -> Dict[str, Any]:
    return {
        "model_version": MODEL_VERSION,
        "registry_version": REGISTRY_VERSION,
        "tissue": TISSUE,
        "activity": ACTIVITY,
        "personal_input_date": person.as_of.isoformat(),
        "input_quality": _input_quality(person, qc),
        "n_samples": n_ok,
        "elapsed_s": round(elapsed, 2),
        "active_constraints": sorted(qc.constraints) or [],
        "confidence_penalty": round(qc.confidence_penalty(), 3),
        "posterior_summary": {k: v for k, v in meta.items()
                              if k != "explanations"},
        "state_explanations": meta.get("explanations", []),
        "lab_disposition": qc.lab_disposition,
        "qc_findings": [f.to_dict() for f in qc.findings],
        "not_measured": True,
        "intended_use": "mechanistic exploration and hypothesis generation",
        "not_intended_for": "diagnosis, treatment selection, or autonomous "
                            "medical advice",
    }


def _input_quality(person, qc) -> str:
    score = 0
    if person.wearable.vo2max_estimate_ml_kg_min is not None:
        score += 1
    if person.wearable.n_runs() >= 8:
        score += 1
    if len(person.calibration_runs) >= 3:
        score += 2
    if person.nutrition.prev_24h_cho_g is not None or person.nutrition.meals:
        score += 1
    if person.labs.values:
        score += 1
    return {0: "very low", 1: "low", 2: "low", 3: "moderate", 4: "moderate",
            5: "good", 6: "good"}.get(score, "moderate")
