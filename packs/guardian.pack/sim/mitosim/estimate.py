"""Input QC + state estimator: "distributions, not guesses" (spec 2.1, 2.8).

This module turns observations into a *sampler*.  Calling `sample_state` draws
one plausible personal state; the ensemble calls it hundreds of times.

Spec 2.8 splits parameters into three classes and this module respects the
split.  Observed quantities pass through.  Indirectly inferred quantities get a
posterior that is narrowed by good data and widened by QC findings.  Population
biochemical constants are sampled from their registered priors and are *not*
fitted to the person -- doing so would be unidentifiable from wearable data.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from .params import R
from .inputs import PersonInputs, CalibrationRun
from .qc import QCReport
from .demand import cost_of_running
from .scenario import Scenario

# Biochemical parameters resampled for every ensemble member.
BIOCHEM_PARAMS = [
    "atp_total", "creatine_total", "pi_rest", "ck_rate",
    "km_pi_phosphorylase", "km_amp_activation", "vmax_phosphorylase_I",
    "vmax_phosphorylase_II", "vmax_glycolysis_I", "vmax_glycolysis_II",
    "km_g6p", "ki_atp_pfk", "ph_pfk_half", "ph_pfk_slope",
    "vmax_glucose_uptake_I", "vmax_glucose_uptake_II", "km_glucose_transport",
    "contraction_glut4_gain", "vmax_pdh_I", "vmax_pdh_II", "km_pyruvate_pdh",
    "ki_randle_pfk", "ldh_rate_I", "ldh_rate_II", "vmax_mct_I", "vmax_mct_II",
    "km_mct", "mct_uptake_fraction", "vmax_beta_ox_I", "vmax_beta_ox_II", "km_ffa", "ki_g6p_beta_ox",
    "vmax_ketone_ox_I", "vmax_ketone_ox_II", "km_ketone", "nad_total_cyt",
    "nad_total_mito", "nadh_mito_rest_ratio", "vmax_oxphos_I", "vmax_oxphos_II",
    "km_adp_oxphos", "km_pi_oxphos", "km_nadh_oxphos", "po_ratio_nadh",
    "po_ratio_fadh2", "proton_leak_frac", "vmax_tca_I", "vmax_tca_II",
    "km_accoa_tca", "km_nad_tca", "k_shuttle_I", "k_shuttle_II", "shuttle_keq",
    "shuttle_fadh2_frac_I", "shuttle_fadh2_frac_II", 
    "ph_rest", "buffer_capacity",     "proton_per_lactate", "proton_per_ck",
    "perfusion_demand_exponent", "parallel_activation_exponent",
    "hill_adp_oxphos", "hill_amp_activation", "km_adp_glycolysis",
    "km_pi_glycolysis", 
    "vmax_glycogen_synthase", "km_g6p_synthase", "synthase_contraction_inhibition",
    "ki_g6p_phosphorylase", "ph_phosphorylase_half",
    "ca_activation_residual", "oxphos_activation_residual", "coa_total_mito", "km_coa_free",
    "ki_accoa_coa_ratio", "adp_free_rest",
    "recruit_I_threshold", "recruit_I_slope", "recruit_II_threshold",
    "recruit_II_slope", "type2_atpase_ratio", "muscle_o2_capacity",
    "km_o2_etc", "perfusion_rest_frac", "perfusion_tau_s",
    "lactate_clearance", "glucose_appearance_max", "insulin_glut4_gain_fed",
    "blood_lactate_rest", "resting_muscle_atp_demand", "cell_water_L_per_kg",
]


# --------------------------------------------------------------------------
# Personalisation from run history
# --------------------------------------------------------------------------

def hr_max_estimate(p: PersonInputs) -> float:
    if p.wearable.max_hr_bpm_observed:
        return float(p.wearable.max_hr_bpm_observed)
    # Tanaka: 208 - 0.7*age.  A population formula with ~10 bpm SD.
    return 208.0 - 0.7 * p.body.age_y


def infer_economy(p: PersonInputs, vo2max: float) -> Tuple[float, float, str]:
    """Estimate running economy from calibration runs (or ordinary runs).

    Reads oxygen cost off heart rate via the %HRR ~ %VO2R relation, then divides
    by the population cost-of-transport prediction for that speed and grade.
    Returns (median multiplier, geometric SD, explanation).
    """
    base = R.P("economy_factor")
    level_adjust = {"novice": 1.09, "recreational": 1.04, "trained": 0.99,
                    "competitive": 0.95}.get(p.training.self_described_level, 1.04)
    prior_median = base.value * level_adjust / 1.06
    prior_gsd = base.require_dist().b

    runs = [c.run for c in p.calibration_runs] or [
        r for r in p.wearable.runs if r.mean_hr_bpm and r.duration_s > 900]
    hr_rest = p.wearable.resting_hr_bpm
    hr_max = hr_max_estimate(p)
    if not runs or hr_rest is None or vo2max <= 0:
        return prior_median, prior_gsd, (
            "No usable calibration data; economy stays at the training-level "
            "adjusted population prior.")

    j_per_ml = R.value("energy_per_mL_O2")
    rmr_vo2 = R.value("resting_metabolic_rate") / j_per_ml * 60.0
    ests: List[float] = []
    for r in runs:
        if not r.mean_hr_bpm:
            continue
        grade = max(-0.45, min(0.45, r.mean_grade_pct / 100.0))
        v = r.speed_m_s
        if v < 1.5 or v > 7.0:
            continue
        hrr = (r.mean_hr_bpm - hr_rest) / max(hr_max - hr_rest, 1e-6)
        hrr = min(max(hrr, 0.05), 1.0)
        vo2_obs = rmr_vo2 + hrr * (vo2max - rmr_vo2)
        predicted_net_cost = cost_of_running(grade) * v * 60.0 / j_per_ml
        if predicted_net_cost <= 0:
            continue
        ests.append((vo2_obs - rmr_vo2) / predicted_net_cost)

    if not ests:
        return prior_median, prior_gsd, (
            "Run records present but none were usable for economy inference.")

    obs_median = float(np.exp(np.mean(np.log(np.clip(ests, 0.5, 2.0)))))
    per_run_gsd = R.P("hr_to_vo2_error").require_dist().b
    obs_gsd = max(1.04, per_run_gsd ** (1.0 / math.sqrt(len(ests))))

    # Log-space precision-weighted combination of prior and observation.
    wp = 1.0 / math.log(prior_gsd) ** 2
    wo = 1.0 / math.log(obs_gsd) ** 2
    mu = (wp * math.log(prior_median) + wo * math.log(obs_median)) / (wp + wo)
    gsd = math.exp(math.sqrt(1.0 / (wp + wo)))
    kind = "calibration runs" if p.calibration_runs else "run history"
    return (math.exp(mu), gsd,
            f"Economy inferred from {len(ests)} {kind} via the "
            f"%HRR-to-%VO2R mapping (observed multiplier {obs_median:.3f}), "
            f"combined with the population prior {prior_median:.3f}.")


def vo2max_posterior(p: PersonInputs, qc: QCReport) -> Tuple[float, float, str]:
    """Sea-level aerobic-capacity posterior as (median, gsd, explanation)."""
    dev = p.wearable.vo2max_estimate_ml_kg_min
    if dev is None:
        pr = R.P("vo2max_prior_ml_kg_min")
        med = pr.value
        lvl = {"novice": 0.80, "recreational": 0.95, "trained": 1.15,
               "competitive": 1.35}.get(p.training.self_described_level, 1.0)
        med *= lvl
        if p.training.weekly_km:
            med *= 1.0 + min(0.28, 0.0032 * p.training.weekly_km)
        gsd = 1.22
        why = ("No device estimate; aerobic ceiling from a population prior "
               "shaped by training history only.")
    else:
        bias = R.P("vo2max_device_bias")
        med = dev * bias.value
        gsd = bias.require_dist().b
        why = (f"Wrist cardio-fitness estimate {dev:.1f} mL/kg/min carried with "
               "a multiplicative device-bias model; it is an estimate from "
               "heart and motion sensors, not gas exchange.")
    # Widening factors act on the log spread, not on the geometric SD itself:
    # a "1.5x wider" finding should widen the interval by half, not multiply the
    # multiplicative spread by 1.5 (which would be enormous).
    gsd = gsd ** qc.widen_factors.get("vo2max", 1.0)
    med *= qc.prior_shifts.get("vo2max_multiplier", 1.0)
    return med, max(gsd, 1.02), why


def glycogen_posterior(p: PersonInputs, qc: QCReport,
                       sc: Optional[Scenario]) -> Tuple[float, float, str]:
    """Initial muscle glycogen in mmol glucosyl units/kg wet weight.

    Spec 2.4: "Muscle glycogen cannot be known from ordinary inputs. Version 1
    estimates it probabilistically."  The result is reported as a band, never as
    a biopsy-equivalent concentration.
    """
    base = R.P("glycogen_rest_mmol_kg_ww")
    med, gsd = base.value, base.require_dist().b
    bits: List[str] = []

    cho_24 = p.nutrition.prev_24h_cho_g
    if sc is not None and sc.prev_day_cho in ("low", "mixed", "high") and cho_24 is None:
        cho_24 = {"low": 1.2, "mixed": 4.2, "high": 8.0}[sc.prev_day_cho] * p.body.mass_kg
        bits.append(f"previous-day carbohydrate taken from the scenario "
                    f"({sc.prev_day_cho})")
    if cho_24 is not None:
        g_per_kg = cho_24 / max(p.body.mass_kg, 1e-6)
        # Anchor set: 0 -> 0.58, 5 -> 1.00, 10 -> 1.45 g/kg
        f = float(np.interp(g_per_kg, [0.0, 2.0, 5.0, 8.0, 12.0],
                            [0.58, 0.80, 1.00, 1.28, 1.48]))
        med *= f
        # The anchor set is a mapping with its own residual spread; combine it
        # with the rest of the prior in log space rather than treating the
        # anchors as exact.
        resp = R.P("glycogen_cho_response_gsd").require_dist().b
        gsd = math.exp(math.sqrt(math.log(gsd) ** 2 + math.log(resp) ** 2))
        bits.append(f"{g_per_kg:.1f} g/kg carbohydrate in the previous 24 h "
                    f"(x{f:.2f}, mapping spread x/{resp:.2f})")
    else:
        gsd = gsd ** 1.35
        bits.append("no carbohydrate history (prior widened)")

    if p.nutrition.exercise_since_last_high_cho_meal:
        f = R.value("glycogen_exercise_depletion")
        med *= f
        bits.append(f"exercise since the last high-carbohydrate meal (x{f:.2f})")
    if p.nutrition.hard_sessions_last_48h:
        f = 0.93 ** p.nutrition.hard_sessions_last_48h
        med *= f
        bits.append(f"{p.nutrition.hard_sessions_last_48h} hard session(s) in "
                    f"48 h (x{f:.2f})")
    if p.training.self_described_level in ("trained", "competitive"):
        f = R.value("glycogen_trained_bonus")
        med *= f
        bits.append(f"trained storage capacity (x{f:.2f})")

    hsm = sc.hours_since_meal if sc else p.nutrition.hours_since_last_meal
    if hsm is not None and hsm >= 10:
        f = 0.97 if hsm < 14 else 0.93
        med *= f
        bits.append(f"{hsm:.0f} h since the last meal (x{f:.2f}); an overnight "
                    "fast lowers liver glycogen far more than muscle glycogen")

    med *= qc.prior_shifts.get("glycogen_multiplier", 1.0)
    gsd = gsd ** qc.widen_factors.get("glycogen", 1.0)

    # Explicit scenario override bands (the spec's 3 glycogen priors axis).
    if sc is not None and sc.glycogen_prior in ("low", "moderate", "high"):
        target = {"low": 55.0, "moderate": 100.0, "high": 150.0}[sc.glycogen_prior]
        med = math.sqrt(med * target)      # geometric blend with the derived value
        bits.append(f"scenario sets a '{sc.glycogen_prior}' glycogen prior, "
                    "blended with the value derived from the person's history")

    med = float(np.clip(med, 20.0, 220.0))
    gsd = float(np.clip(gsd, 1.10, 1.90))
    return med, gsd, "Initial glycogen prior from: " + "; ".join(bits) + "."


def band_for_glycogen(mmol_kg_ww: float) -> str:
    if mmol_kg_ww < 70:
        return "low"
    if mmol_kg_ww < 125:
        return "moderate"
    return "high"


# --------------------------------------------------------------------------
# Fuel state from timing (spec 1.1 "Meals and current fuel state")
# --------------------------------------------------------------------------

def insulin_index(hours_since_meal: float, pre_run_cho_g: float,
                  timing_min_before: float = 30.0) -> float:
    """0 = deeply fasted, 1 = strongly insulinised.  A state index, not a
    hormone concentration -- the engine does not model the endocrine system."""
    base = float(np.interp(hours_since_meal, [0.5, 1, 2, 3, 5, 8, 12, 16],
                           [0.95, 0.90, 0.72, 0.52, 0.28, 0.12, 0.05, 0.02]))
    if pre_run_cho_g > 0:
        # A 30-60 min pre-run dose raises insulin substantially.
        decay = float(np.interp(timing_min_before, [0, 15, 30, 60, 120, 240],
                                [0.3, 0.8, 1.0, 0.85, 0.4, 0.1]))
        add = min(0.85, pre_run_cho_g / 100.0 * 0.8) * decay
        base = 1.0 - (1.0 - base) * (1.0 - add)
    return float(np.clip(base, 0.0, 1.0))


# --------------------------------------------------------------------------
# The sampled personal state
# --------------------------------------------------------------------------

@dataclass
class PersonalState:
    # whole-body / demand-model quantities
    body_mass_kg: float
    active_muscle_kg: float
    muscle_water_L: float
    economy: float
    grade_penalty: float
    rmr: float
    j_per_ml: float
    atp_per_o2: float
    nonmuscle_frac: float
    vo2max_sea: float
    vo2max_env: float
    vo2max_muscle_mM_s: float
    resting_atp_demand: float
    # muscle phenotype
    type1_frac: float
    mito_scale: float
    fat_ox_scale: float
    # initial conditions
    glycogen_mmol_kg_ww: float
    glycogen_mM: float
    glycogen_floor_mM: float
    blood_glucose: float
    blood_lactate: float
    blood_ffa: float
    blood_bhb: float
    insulin_idx: float
    glucose_appearance: float
    blood_volume_L: float
    glucose_space_L: float
    # sampled biochemical parameters
    bp: Dict[str, float] = field(default_factory=dict)
    # bookkeeping
    adapter_effects: Dict[str, Any] = field(default_factory=dict)
    notes: List[str] = field(default_factory=list)


def _oxygen_environment(p: PersonInputs, sc: Scenario, vo2max_sea: float,
                        rng, qc: QCReport,
                        median: bool = False) -> Tuple[float, List[str]]:
    """Apply haemoglobin and elevation to the aerobic ceiling (spec 2.5)."""
    notes: List[str] = []
    v = vo2max_sea

    hb = qc.constraints.get("oxygen_capacity")
    if hb is not None:
        ref = R.value("hb_reference_g_dL")
        exp_p = R.P("hb_vo2max_exponent")
        exponent = float(exp_p.value if median else exp_p.sample(rng))
        rel = (hb / ref) ** exponent
        rel = float(np.clip(rel, 0.72, 1.20))
        v *= rel
        notes.append(
            f"Haemoglobin {hb:.1f} g/dL scales the oxygen ceiling by "
            f"{rel:.3f} (exponent {exponent:.2f}). Arterial oxygen content is "
            "one uncertain modifier; ventilation, cardiac output, perfusion, "
            "diffusion and extraction also set this ceiling.")
    if "oxygen_capacity" in qc.widen_factors:
        notes.append("Oxygen-capacity uncertainty widened by a QC finding.")

    elev = sc.elevation_m
    thr = float(R.P("altitude_threshold_m").value if median
                else R.P("altitude_threshold_m").sample(rng))
    if elev > thr:
        slope = float(R.P("altitude_vo2max_slope").value if median
                      else R.P("altitude_vo2max_slope").sample(rng))
        dec = slope * (elev - thr) / 1000.0
        if abs(p.body.habitual_elevation_m - elev) < 500:
            acc = float(R.P("altitude_acclimatization").value if median
                        else R.P("altitude_acclimatization").sample(rng))
            dec *= (1.0 - acc)
            notes.append(
                f"The person habitually lives near {elev:.0f} m, so "
                f"{acc*100:.0f}% of the acute altitude decrement is offset.")
        dec = float(np.clip(dec, 0.0, 0.55))
        v *= (1.0 - dec)
        notes.append(f"Elevation {elev:.0f} m lowers the estimated aerobic "
                     f"ceiling by {dec*100:.1f}%.")
    return v, notes


def build_sampler(p: PersonInputs, qc: QCReport, sc: Scenario):
    """Return a closure that draws one PersonalState per call.

    The expensive, person-level inferences (economy, VO2max posterior, glycogen
    posterior) are computed once; only the draws vary.
    """
    vo2_med, vo2_gsd, vo2_why = vo2max_posterior(p, qc)
    econ_med, econ_gsd, econ_why = infer_economy(p, vo2_med)
    econ_gsd = econ_gsd ** qc.widen_factors.get("economy_factor", 1.0)
    gly_med, gly_gsd, gly_why = glycogen_posterior(p, qc, sc)

    lean = p.body.lean_mass()
    if lean is None:
        # Population body-composition fallback, deliberately wide.
        bf = 0.22 if p.body.sex_at_birth == "female" else 0.16
        lean = p.body.mass_kg * (1 - bf)

    static_notes = [vo2_why, econ_why, gly_why]

    def sample(rng, median: bool = False) -> PersonalState:
        """Draw one plausible personal state.

        ``median=True`` returns the central state with every distribution at its
        registered central value. That state is not a member of the ensemble --
        it is used for calibration and for reproducibility checks, because a
        model has to be judged at a defined parameter set before its spread
        means anything.
        """
        if median:
            class _Med:
                @staticmethod
                def normal(mu=0.0, sd=1.0, size=None):
                    import numpy as _np
                    return _np.zeros(size) if size else 0.0
            def _v(name):
                return float(R.P(name).value)
            bp = {name: _v(name) for name in BIOCHEM_PARAMS}
            rng = _Med()
        else:
            bp = {name: float(R.P(name).sample(rng)) for name in BIOCHEM_PARAMS}

        _P = (lambda n: float(R.P(n).value)) if median else (
            lambda n: float(R.P(n).sample(rng)))
        economy = float(econ_med * np.exp(rng.normal(0, math.log(econ_gsd))))
        economy = float(np.clip(economy, 0.72, 1.55))
        grade_pen = _P("running_econ_grade_penalty")
        rmr = _P("resting_metabolic_rate")
        j_per_ml = _P("energy_per_mL_O2")
        atp_o2 = _P("atp_per_o2")
        nonmuscle = _P("nonmuscle_o2_frac")

        vo2max_sea = float(vo2_med * np.exp(rng.normal(0, math.log(vo2_gsd))))
        vo2max_sea = float(np.clip(vo2max_sea, 15.0, 90.0))
        vo2max_env, env_notes = _oxygen_environment(p, sc, vo2max_sea, rng, qc,
                                                   median)

        act_frac = _P("active_muscle_frac_of_lean")
        active_kg = lean * act_frac
        water_L = active_kg * bp["cell_water_L_per_kg"]

        # Oxygen ceiling expressed inside the modelled muscle.
        vo2max_mL_s = vo2max_env * p.body.mass_kg / 60.0
        vo2max_muscle = (vo2max_mL_s * (1 - nonmuscle) /
                         R.value("o2_molar_volume") / water_L)

        # Muscle oxidative capacity is coupled to the sampled aerobic ceiling,
        # not drawn independently of it (see mito_vo2max_coupling).
        mito_scale = _P("mito_capacity_scale") * (
            (vo2max_sea / max(vo2_med, 1e-6)) ** _P("mito_vo2max_coupling"))
        mito_scale = float(np.clip(mito_scale, 0.40, 2.4))

        gly_ww = float(gly_med * np.exp(rng.normal(0, math.log(gly_gsd))))
        gly_ww = float(np.clip(gly_ww, 15.0, 240.0))
        gly_mM = gly_ww / bp["cell_water_L_per_kg"]
        floor_mM = (_P("glycogen_floor_mmol_kg_ww") /
                    bp["cell_water_L_per_kg"])

        hsm = sc.hours_since_meal
        ins = insulin_index(hsm, sc.pre_run_cho_g)
        fed_w = ins
        glc = (_P("blood_glucose_fed") * fed_w +
               _P("blood_glucose_fasted") * (1 - fed_w))
        if sc.pre_run_cho_g:
            glc += min(2.2, sc.pre_run_cho_g / 100.0 * 1.8)
        ffa_fed = _P("blood_ffa_fed")
        ffa_fast = _P("blood_ffa_fasted")
        ffa_t = float(np.interp(hsm, [1, 3, 6, 12, 16], [0.05, 0.18, 0.42, 0.85, 1.0]))
        ffa = ffa_fed + (ffa_fast - ffa_fed) * ffa_t
        if sc.pre_run_cho_g:
            supp = _P("insulin_ffa_suppression")
            ffa *= (1.0 - supp * min(1.0, sc.pre_run_cho_g / 75.0))
        bhb_fed = _P("blood_bhb_fed")
        bhb_fast = _P("blood_bhb_fasted")
        bhb = bhb_fed + (bhb_fast - bhb_fed) * ffa_t

        # Same-day laboratory constraints override the timing-based prior.
        if "blood_lactate_initial" in qc.constraints:
            lac = qc.constraints["blood_lactate_initial"]
        else:
            lac = bp["blood_lactate_rest"]
        if "blood_ketone_initial" in qc.constraints:
            bhb = qc.constraints["blood_ketone_initial"]
        if p.nutrition.cgm_glucose_mmol_l is not None:
            glc = p.nutrition.cgm_glucose_mmol_l
        if p.nutrition.capillary_bhb_mmol_l is not None:
            bhb = p.nutrition.capillary_bhb_mmol_l

        g_app = 0.0
        if sc.pre_run_cho_g:
            g_app = min(_P("glucose_appearance_max"),
                        sc.pre_run_cho_g / 100.0 *
                        _P("glucose_appearance_max"))

        st = PersonalState(
            body_mass_kg=p.body.mass_kg, active_muscle_kg=active_kg,
            muscle_water_L=water_L, economy=economy, grade_penalty=grade_pen,
            rmr=rmr, j_per_ml=j_per_ml, atp_per_o2=atp_o2,
            nonmuscle_frac=nonmuscle, vo2max_sea=vo2max_sea,
            vo2max_env=vo2max_env, vo2max_muscle_mM_s=vo2max_muscle,
            resting_atp_demand=bp["resting_muscle_atp_demand"],
            type1_frac=_P("type1_fraction"),
            mito_scale=mito_scale,
            fat_ox_scale=_P("fat_ox_personal_scale"),
            glycogen_mmol_kg_ww=gly_ww, glycogen_mM=gly_mM,
            glycogen_floor_mM=floor_mM,
            blood_glucose=float(np.clip(glc, 3.0, 12.0)),
            blood_lactate=float(np.clip(lac, 0.3, 4.0)),
            blood_ffa=float(np.clip(ffa, 0.03, 2.2)),
            blood_bhb=float(np.clip(bhb, 0.01, 6.0)),
            insulin_idx=ins,
            glucose_appearance=g_app,
            blood_volume_L=p.body.mass_kg * _P("blood_volume_frac"),
            glucose_space_L=p.body.mass_kg * _P("glucose_space_frac"),
            bp=bp, notes=list(static_notes) + env_notes)
        return st

    meta = {
        "vo2max_median": vo2_med, "vo2max_gsd": vo2_gsd,
        "economy_median": econ_med, "economy_gsd": econ_gsd,
        "glycogen_median_mmol_kg_ww": gly_med, "glycogen_gsd": gly_gsd,
        "glycogen_band": band_for_glycogen(gly_med),
        "explanations": static_notes,
    }
    return sample, meta
