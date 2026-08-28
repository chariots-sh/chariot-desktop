"""Dynamic human skeletal-muscle core (spec 2.6).

A reduced reimplementation, in the topology of Li et al. 2012, of a two-fibre
skeletal-muscle metabolic model with a shared capillary blood compartment.

What is represented
-------------------
* type I and type II fibre populations, each with a cytosolic and a
  mitochondrial compartment
* a shared blood compartment carrying glucose, lactate, fatty acids and ketones
* high-energy phosphate metabolism (ATP / ADP / AMP / PCr / Cr / Pi)
* glycogenolysis, glucose transport and glycolysis
* lactate dehydrogenase and monocarboxylate transport
* beta-oxidation and ketone oxidation
* the TCA cycle, reducing-equivalent shuttles, and oxidative phosphorylation
* proton balance and intracellular pH
* delivery-limited intracellular oxygen

Honest statement of scope (spec 2.6 "Required extensions and limitations")
--------------------------------------------------------------------------
This is a *reduced* model in the source topology, not a line-by-line
reproduction of the published equation set.  Every reduction is registered in
params.py with support grade "assumed" or "structural" and is listed by
`reductions()` below.  Requirement 1 of spec 2.6 -- reproducing the source
paper's published resting and moderate-exercise behaviour against its own
figures -- is an open validation gate, tracked in validation/gates.py, not a
completed claim.  Severe-intensity and sprint simulations are marked higher
uncertainty (requirement 6).

All intracellular concentrations are mM referred to litres of cell water; all
fluxes are mM/s.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional, Tuple

import numpy as np
from scipy.integrate import solve_ivp
from scipy.optimize import root

from .params import R

# --------------------------------------------------------------------------
# State layout
# --------------------------------------------------------------------------

FIBER_SPECIES = ("ATP", "PCr", "Pi", "GLY", "G6P", "PYR", "LAC",
                 "NADHc", "NADHm", "FADH2", "ACCOA", "PH", "O2")
NSP = len(FIBER_SPECIES)
IDX = {s: i for i, s in enumerate(FIBER_SPECIES)}

BLOOD_SPECIES = ("GLC_b", "LAC_b", "FFA_b", "BHB_b")
B0 = 2 * NSP
I_GLC, I_LACB, I_FFA, I_BHB = B0, B0 + 1, B0 + 2, B0 + 3
I_PERF = B0 + 4

ACC = ("atp_ox", "atp_gly", "atp_pcr", "o2", "cho_ox", "fat_ox", "ket_ox",
       "atp_demand", "atp_supplied", "lac_prod", "gly_used", "atp_leakloss")
A0 = B0 + 5
ACC_IDX = {n: A0 + i for i, n in enumerate(ACC)}
NSTATE = A0 + len(ACC)

# Stoichiometry per palmitate and per beta-hydroxybutyrate.
ACCOA_PER_PALMITATE = 8.0
NADH_PER_PALMITATE = 7.0
FADH2_PER_PALMITATE = 7.0
ATP_COST_PER_PALMITATE = 2.0
ACCOA_PER_BHB = 2.0
NADH_PER_BHB = 1.0
ATP_COST_PER_BHB = 1.0
NADH_PER_ACCOA_TCA = 3.0
FADH2_PER_ACCOA_TCA = 1.0
GTP_PER_ACCOA_TCA = 1.0
CARBONS = {"glucosyl": 6.0, "palmitate": 16.0, "bhb": 4.0}


class IntegrationBudgetExceeded(RuntimeError):
    """Raised when a single realisation exceeds its right-hand-side budget.

    A small fraction of parameter draws make the system stiff enough that the
    solver takes minutes rather than milliseconds. Without a bound, one such
    draw stalls an entire ensemble, and in a worker process it looks
    indistinguishable from a deadlock. Bounding the work turns it into an
    ordinary recorded failure with a reason attached.
    """


def reductions() -> List[Dict[str, str]]:
    """Every documented departure from a full mechanistic reimplementation."""
    return [
        {"item": "AMP", "change": "algebraic fast equilibrium via adenylate "
         "kinase rather than an integrated state", "why": "AMP equilibrates far "
         "faster than the exercise transients of interest; keeping it algebraic "
         "removes stiffness without changing the amplified low-energy signal."},
        {"item": "TCA cycle", "change": "lumped into one acetyl-CoA-consuming "
         "flux with fixed NADH/FADH2/GTP stoichiometry",
         "why": "Individual TCA intermediates are not observable from any input "
         "this product accepts, and their pool sizes would be unidentifiable."},
        {"item": "beta-oxidation", "change": "lumped to palmitate equivalents",
         "why": "Chain-length distribution of the fatty-acid pool is not an "
         "available input."},
        {"item": "FAD pool", "change": "explicit lumped FAD/FADH2 pool",
         "why": "Keeps redox conservation exact under oxygen limitation instead "
         "of assuming FADH2 is oxidised instantaneously."},
        {"item": "liver", "change": "hepatic glucose output is a regulation stub",
         "why": "The liver is outside the modelled tissue; without a stub, "
         "arterial glucose would either be pinned or collapse."},
        {"item": "glycogen synthesis", "change": "represented as a single "
         "insulin-sensitive, contraction-inhibited flux",
         "why": "Needed for a stable resting state: without a hexose-phosphate "
         "sink, basal glucose uptake traps inorganic phosphate and stalls "
         "oxidative phosphorylation. It is not calibrated for multi-day "
         "glycogen-resynthesis questions and the engine does not answer them."},
        {"item": "endocrine system", "change": "insulin represented as a scalar "
         "state index, not a hormone concentration",
         "why": "The engine does not model endocrine dynamics and must not "
         "imply it measures them."},
        {"item": "task failure", "change": "ATP hydrolysis is curtailed below a "
         "critical adenine-pool fraction",
         "why": "Real muscle loses force rather than running ATP to zero; "
         "without this the equations produce negative concentrations."},
    ]


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def _mm(x: float, k: float) -> float:
    return x / (k + x) if x > 0.0 else 0.0


def _pos(x: float) -> float:
    return x if x > 0.0 else 0.0


def _hill(x: float, k: float, n: float) -> float:
    """Cooperative saturation x^n / (k^n + x^n), guarded for x <= 0."""
    if x <= 0.0:
        return 0.0
    r = (x / k) ** n
    return r / (1.0 + r)


def _sigmoid(x: float) -> float:
    if x < -40.0:
        return 0.0
    if x > 40.0:
        return 1.0
    return 1.0 / (1.0 + math.exp(-x))


def free_adp(atp: float, atp_total: float, ak_keq: float) -> float:
    """Free ADP from the conserved adenine pool with AMP at adenylate-kinase
    equilibrium.  Solves  ADP + Keq*ADP^2/ATP = T - ATP  in closed form."""
    atp = max(atp, 1e-6)
    rest = atp_total - atp
    if rest <= 0.0:
        return 1e-9
    a = ak_keq / atp
    return (-1.0 + math.sqrt(1.0 + 4.0 * a * rest)) / (2.0 * a)


@dataclass
class FiberParams:
    """Per-fibre-type parameter bundle, resolved once per simulation."""
    vmax_gp: float
    vmax_gly: float
    vmax_glut: float
    vmax_pdh: float
    ldh_rate: float
    vmax_mct: float
    vmax_box: float
    vmax_ket: float
    vmax_tca: float
    k_shuttle: float
    shuttle_fadh2: float
    vmax_ox: float
    vmax_ox_f: float
    recruit_thr: float
    recruit_slope: float
    atpase_ratio: float
    vol_frac: float
    capillarity: float


def _fiber_params(state, which: str) -> FiberParams:
    bp = state.bp
    sfx = "I" if which == "I" else "II"
    vol = state.type1_frac if which == "I" else 1.0 - state.type1_frac
    return FiberParams(
        vmax_gp=bp[f"vmax_phosphorylase_{sfx}"],
        vmax_gly=bp[f"vmax_glycolysis_{sfx}"],
        vmax_glut=bp[f"vmax_glucose_uptake_{sfx}"],
        vmax_pdh=bp[f"vmax_pdh_{sfx}"] * state.mito_scale,
        ldh_rate=bp[f"ldh_rate_{sfx}"],
        vmax_mct=bp[f"vmax_mct_{sfx}"],
        vmax_box=bp[f"vmax_beta_ox_{sfx}"] * state.fat_ox_scale * state.mito_scale,
        vmax_ket=bp[f"vmax_ketone_ox_{sfx}"] * state.mito_scale,
        vmax_tca=bp[f"vmax_tca_{sfx}"] * state.mito_scale,
        k_shuttle=bp[f"k_shuttle_{sfx}"],
        shuttle_fadh2=bp[f"shuttle_fadh2_frac_{sfx}"],
        vmax_ox=bp[f"vmax_oxphos_{sfx}"] * state.mito_scale,
        vmax_ox_f=(bp[f"vmax_oxphos_{sfx}"] * state.mito_scale *
                   R.value("vmax_oxphos_fadh2_frac")),
        recruit_thr=bp["recruit_I_threshold"] if which == "I"
        else bp["recruit_II_threshold"],
        recruit_slope=bp["recruit_I_slope"] if which == "I"
        else bp["recruit_II_slope"],
        atpase_ratio=1.0 if which == "I" else bp["type2_atpase_ratio"],
        vol_frac=vol,
        capillarity=R.value("capillarity_I") if which == "I"
        else R.value("capillarity_II"),
    )


# --------------------------------------------------------------------------
# The model
# --------------------------------------------------------------------------

class MuscleModel:
    """One realisation: one sampled personal state + one demand profile."""

    def __init__(self, state, demand_t: np.ndarray, demand_v: np.ndarray,
                 rel_intensity: np.ndarray, hours_since_meal: float,
                 insulin_idx: float, adapters: Optional[Dict[str, Any]] = None):
        self.st = state
        self.bp = state.bp
        self.fI = _fiber_params(state, "I")
        self.fII = _fiber_params(state, "II")
        self.demand_t = demand_t
        self.demand_v = demand_v
        self.rel = rel_intensity
        self.hsm = hours_since_meal
        self.insulin = insulin_idx
        self.ad = adapters or {}

        self.atp_total = self.bp["atp_total"]
        self.cr_total = self.bp["creatine_total"] * self.ad.get("cr_pool_scale", 1.0)
        self.nad_c = self.bp["nad_total_cyt"]
        self.nad_m = self.bp["nad_total_mito"]
        self.fad = R.value("fad_total_mito")
        self.km_fad = R.value("km_fadh2_oxphos")
        self.ak_keq = R.value("ak_keq")
        self.ck_keq_M = R.value("ck_keq_M")
        self.ldh_keq = R.value("ldh_keq_app")
        self.o2_cap = self.bp["muscle_o2_capacity"]
        self.km_o2 = self.bp["km_o2_etc"] * self.ad.get("km_o2_scale", 1.0)
        self.buffer = self.bp["buffer_capacity"]
        self.leak = self.bp["proton_leak_frac"] * self.ad.get("leak_scale", 1.0)
        self.po_n = self.bp["po_ratio_nadh"]
        self.po_f = self.bp["po_ratio_fadh2"]
        self.atp_crit = R.value("atp_critical_frac") * self.atp_total
        self.atp_crit_w = R.value("atp_critical_width") * self.atp_total
        self.ck_rate = self.bp["ck_rate"] * self.ad.get("ck_rate_scale", 1.0)
        self.hill_adp = self.bp["hill_adp_oxphos"]
        self.hill_amp = self.bp["hill_amp_activation"]
        self.km_adp_gly = self.bp["km_adp_glycolysis"]
        self.km_pi_gly = self.bp["km_pi_glycolysis"]
        self.vmax_gs = self.bp["vmax_glycogen_synthase"]
        self.km_g6p_gs = self.bp["km_g6p_synthase"]
        self.gs_inhib = self.bp["synthase_contraction_inhibition"]
        self.atp_per_stored = R.value("atp_per_glucosyl_stored")
        self.lac_set = state.blood_lactate
        # Derived rather than sampled: solved from the measured resting state
        # in _calibrate_dehydrogenase_activation. The registered value is the
        # documented plausibility bound on that solution and the fallback if it
        # cannot be solved.
        self.ca_floor = R.value("ca_activation_floor")
        self.coa_total = self.bp["coa_total_mito"]
        self.km_coa = self.bp["km_coa_free"]
        self.ki_ratio = self.bp["ki_accoa_coa_ratio"]
        self.shuttle_keq = self.bp["shuttle_keq"]
        self.ki_randle = self.bp["ki_randle_pfk"]
        # Derived rather than sampled, like ca_activation_floor: solved from
        # the measured resting state, with the registered value as the
        # plausibility bound and the fallback.
        self.ox_floor = R.value("oxphos_activation_floor")
        self.h_lac = self.bp["proton_per_lactate"]
        self.h_ck = self.bp["proton_per_ck"]
        self.perf_exp = self.bp["perfusion_demand_exponent"]
        self.mct_uptake_frac = self.bp["mct_uptake_fraction"]
        self.act_exp = self.bp["parallel_activation_exponent"]
        self.o2_min_frac = 0.05

        # oxygen-cost modifier from an evidence-backed adapter (e.g. nitrate)
        self.o2_cost_scale = self.ad.get("o2_cost_scale", 1.0)
        self.perf_scale = self.ad.get("perfusion_scale", 1.0)
        self.demand_scale = self.ad.get("demand_scale", 1.0)

        # blood coupling: mmol/s from a fibre -> mM/s in the blood compartment
        self.blood_couple = state.muscle_water_L / max(state.blood_volume_L, 1e-6)
        self.glc_couple = state.muscle_water_L / max(state.glucose_space_L, 1e-6)

        self.vo2max_muscle = state.vo2max_muscle_mM_s
        self.demand_at_vo2max = self.vo2max_muscle * state.atp_per_o2
        self.perf_rest = self.bp["perfusion_rest_frac"]
        self.perf_tau = self.bp["perfusion_tau_s"]

        self._fiber_demand_at_ceiling()
        self._calibrate_dehydrogenase_activation()
        self._calibrate_respiratory_control()

        self._cap_static = (self.fI.capillarity * self.fI.vol_frac +
                            self.fII.capillarity * self.fII.vol_frac)

        self.liver_avail0 = math.exp(-hours_since_meal /
                                     R.value("liver_glycogen_hours"))
        self.hgo_k = R.value("hepatic_glucose_k")
        self.hgo_max = R.value("hepatic_glucose_max")
        self.glc_set = state.blood_glucose
        self.ffa_set0 = state.blood_ffa
        self.lipo_tau = R.value("lipolysis_tau_s")
        self.lipo_gain = R.value("lipolysis_exercise_gain")
        self.lac_clear = self.bp["lactate_clearance"]

        self._demand_note: List[str] = []
        self._nfev = 0
        self._budget = 0

    # ---- resting operating point ------------------------------------------
    def _calibrate_respiratory_control(self) -> None:
        """Pin the half-activating ADP of oxidative phosphorylation so that the
        fibre's resting operating point is the measured one.

        Resting muscle is jointly characterised by three observations that are
        not independent: free ADP near 15 umol/L, phosphocreatine near 75-80% of
        the creatine pool, and phosphate near 3 mmol/L. Creatine kinase links
        them, so if oxidative phosphorylation is not tuned to supply exactly the
        resting ATP demand at that ADP, the model relaxes to a different ADP and
        creatine kinase then moves several mmol/L of phosphate between the free
        and phosphocreatine pools. Phosphate is a substrate of respiration, so
        that drift silently throttles the whole oxidative system before the run
        even starts.

        Rather than hope the sampled constants line up, the half-activating ADP
        is solved from the constraint. The registered prior for
        ``km_adp_oxphos`` is retained as a plausibility range and any solution
        outside it is clipped and recorded.
        """
        adp_rest = self.bp["adp_free_rest"]
        n = self.hill_adp
        nadh_m = self.nad_m * self.bp["nadh_mito_rest_ratio"]
        fadh2 = self.fad * 0.10
        pi = self.bp["pi_rest"]
        target = self.bp["resting_muscle_atp_demand"] * 0.90
        km_adp = self.bp["km_adp_oxphos"]
        self.km_adp = {"I": km_adp, "II": km_adp}
        self.ox_floor_fiber = {}
        self.km_adp_clipped = {}
        self.oxidative_capacity_short = False
        for tag, fp in (("I", self.fI), ("II", self.fII)):
            gain = ((1.0 - self.leak) *
                    (self.po_n * fp.vmax_ox * _mm(nadh_m, self.bp["km_nadh_oxphos"]) +
                     self.po_f * fp.vmax_ox_f * _mm(fadh2, self.km_fad)) *
                    _mm(pi, self.bp["km_pi_oxphos"]) *
                    _hill(adp_rest, km_adp, n))
            if gain <= target:
                # This draw gives a fibre less oxidative capacity than its own
                # resting demand. That is not a person; it is a corner of the
                # prior that the sampler should not have reached.
                self.ox_floor_fiber[tag] = 1.0
                self.km_adp_clipped[tag] = "capacity_below_resting_demand"
                self.oxidative_capacity_short = True
                continue
            f = target / gain * self.bp["oxphos_activation_residual"]
            lo, hi = self.ox_floor / 6.0, min(self.ox_floor * 6.0, 0.5)
            fc = float(min(max(f, lo), hi))
            self.ox_floor_fiber[tag] = fc
            self.km_adp_clipped[tag] = "" if abs(fc - f) < 1e-12 else (
                f"solved resting activation {f:.4f} clipped to {fc:.4f}")

    def _fiber_demand_at_ceiling(self) -> None:
        """Per-fibre ATP demand when the whole muscle is at its oxygen ceiling.

        This is the reference for parallel activation. Using the *fibre's own*
        relative demand rather than a saturating function of running intensity
        matters: with a saturating signal every workload above about 60% of
        VO2max arrives fully activated, oxidative capacity stops tracking the
        workload, and the simulated phosphocreatine response goes flat across
        the whole intensity range instead of falling progressively the way
        31P magnetic resonance spectroscopy shows.
        """
        basal = self.bp["resting_muscle_atp_demand"]
        aI = _sigmoid((1.0 - self.fI.recruit_thr) / self.fI.recruit_slope)
        aII = _sigmoid((1.0 - self.fII.recruit_thr) / self.fII.recruit_slope)
        wsum = (self.fI.atpase_ratio * aI * self.fI.vol_frac +
                self.fII.atpase_ratio * aII * self.fII.vol_frac)
        excess = max(self.demand_at_vo2max - basal, 1e-6)
        self.dmax = {
            "I": basal + excess * self.fI.atpase_ratio * aI / max(wsum, 1e-9),
            "II": basal + excess * self.fII.atpase_ratio * aII / max(wsum, 1e-9),
        }

    def _calibrate_dehydrogenase_activation(self) -> None:
        """Pin the resting activity of the calcium-sensitive dehydrogenases so
        that the matrix NAD pool sits at its measured resting redox state.

        The matrix of resting muscle is roughly 20-30% reduced. If the
        dehydrogenases idle even slightly faster than the respiratory chain can
        oxidise their product, NADH accumulates until the redox term alone
        throttles them, and the model then starts every run from a nearly fully
        reduced matrix that no measurement supports. Solving for the resting
        activation from the resting oxygen consumption keeps the two consistent.
        """
        nadh_m = self.nad_m * self.bp["nadh_mito_rest_ratio"]
        nad_m = self.nad_m - nadh_m
        fadh2 = self.fad * 0.10
        fad = self.fad - fadh2
        accoa = self.coa_total * 0.25
        target_atp = self.bp["resting_muscle_atp_demand"] * 0.90
        # atp_ox = (1-leak)(2.5 J_NADH + 1.5 J_FADH2); with TCA supplying NADH and
        # FADH2 in a 3:1 ratio this is 3(1-leak) J_NADH.
        j_nadh = target_atp / max(3.0 * (1.0 - self.leak), 1e-9)
        # Roughly 3.4 NADH reach the chain per TCA turnover once the
        # beta-oxidation that supplies the acetyl unit is counted.
        j_tca = j_nadh / 3.4
        self.ca_floor_fiber = {}
        for tag, fp in (("I", self.fI), ("II", self.fII)):
            gate = (fp.vmax_tca * _mm(accoa, self.bp["km_accoa_tca"]) *
                    _mm(nad_m, self.bp["km_nad_tca"]) * _mm(fad, 0.15))
            ca = j_tca / gate if gate > 0 else self.ca_floor
            # The registered prior bounds the solution to a plausibility band.
            ca *= self.bp["ca_activation_residual"]
            lo, hi = self.ca_floor / 6.0, self.ca_floor * 6.0
            self.ca_floor_fiber[tag] = float(min(max(ca, lo), hi))

    # ---- interpolation ---------------------------------------------------
    def _demand(self, t: float) -> float:
        return float(np.interp(t, self.demand_t, self.demand_v)) * self.demand_scale

    def _rel(self, t: float) -> float:
        return float(np.interp(t, self.demand_t, self.rel))

    # ---- initial condition ----------------------------------------------
    def initial_state(self) -> np.ndarray:
        y = np.zeros(NSTATE)
        st = self.st
        ph = self.bp["ph_rest"]
        # Build the phosphate system so that the adenine pool, the
        # creatine-kinase equilibrium and resting phosphate all agree.  Setting
        # PCr and Pi independently of ADP makes the model shuffle several mM of
        # phosphate out of the free pool in the first minutes, which then
        # throttles oxidative phosphorylation through its phosphate term.
        adp_rest = self.bp["adp_free_rest"]
        amp_rest = self.ak_keq * adp_rest ** 2 / self.atp_total
        atp_rest = self.atp_total - adp_rest - amp_rest
        keq_app = self.ck_keq_M * (10.0 ** -ph)
        pcr_over_cr = atp_rest / (adp_rest * keq_app)
        pcr_rest = self.cr_total * pcr_over_cr / (1.0 + pcr_over_cr)
        for off, fp in ((0, self.fI), (NSP, self.fII)):
            y[off + IDX["ATP"]] = atp_rest
            y[off + IDX["PCr"]] = pcr_rest
            y[off + IDX["Pi"]] = self.bp["pi_rest"]
            y[off + IDX["GLY"]] = st.glycogen_mM
            y[off + IDX["G6P"]] = 0.30
            y[off + IDX["PYR"]] = 0.08
            y[off + IDX["LAC"]] = st.blood_lactate * 1.15
            # cytosolic NADH from the lactate/pyruvate ratio at LDH equilibrium
            lac, pyr = y[off + IDX["LAC"]], y[off + IDX["PYR"]]
            y[off + IDX["NADHc"]] = lac * self.nad_c / (self.ldh_keq * pyr + lac)
            y[off + IDX["NADHm"]] = self.nad_m * self.bp["nadh_mito_rest_ratio"]
            y[off + IDX["FADH2"]] = self.fad * 0.10
            y[off + IDX["ACCOA"]] = self.coa_total * 0.25
            y[off + IDX["PH"]] = ph
            y[off + IDX["O2"]] = self.o2_cap * 0.85
        y[I_GLC] = st.blood_glucose
        y[I_LACB] = st.blood_lactate
        y[I_FFA] = st.blood_ffa
        y[I_BHB] = st.blood_bhb
        y[I_PERF] = self.perf_rest
        return y

    # ---- per-fibre flux computation -------------------------------------
    def _fiber_fluxes(self, y: np.ndarray, off: int, fp: FiberParams,
                      atpase: float, recruit: float, glc_b: float,
                      lac_b: float, ffa_b: float, bhb_b: float,
                      rel: float, km_adp: float,
                      ca_floor: float, dmax: float,
                      ox_floor: float) -> Dict[str, float]:
        atp = _pos(y[off + IDX["ATP"]])
        pcr = _pos(y[off + IDX["PCr"]])
        pi = _pos(y[off + IDX["Pi"]])
        gly = _pos(y[off + IDX["GLY"]])
        g6p = _pos(y[off + IDX["G6P"]])
        pyr = _pos(y[off + IDX["PYR"]])
        lac = _pos(y[off + IDX["LAC"]])
        # Clamp exactly at the pool size, not at 99% of it. A 1% floor on the
        # oxidised fraction leaves every NAD-dependent dehydrogenase running at
        # a few percent of capacity even when the pool is fully reduced, so
        # production never actually stops and the pool drifts past its own
        # ceiling. Clamping exactly makes the redox gate close.
        nadh_c = min(max(y[off + IDX["NADHc"]], 1e-12), self.nad_c)
        nadh_m = min(max(y[off + IDX["NADHm"]], 1e-9), self.nad_m)
        fadh2 = min(max(y[off + IDX["FADH2"]], 1e-9), self.fad)
        accoa = min(_pos(y[off + IDX["ACCOA"]]), self.coa_total)
        ph = min(max(y[off + IDX["PH"]], 5.8), 7.6)
        o2 = _pos(y[off + IDX["O2"]])

        cr = _pos(self.cr_total - pcr)
        nad_c = _pos(self.nad_c - nadh_c)
        nad_m = _pos(self.nad_m - nadh_m)
        fad = _pos(self.fad - fadh2)
        coa_free = _pos(self.coa_total - accoa)
        adp = free_adp(atp, self.atp_total, self.ak_keq)
        amp = self.ak_keq * adp * adp / max(atp, 1e-6)
        h_M = 10.0 ** (-ph)

        # --- ATP protection: force is lost before the pool empties ---------
        cover = _sigmoid((atp - self.atp_crit) / self.atp_crit_w)
        j_atpase = atpase * cover

        # --- creatine kinase ----------------------------------------------
        keq_app = self.ck_keq_M * h_M
        j_ck = self.ck_rate * (pcr * adp - cr * atp / keq_app)

        # --- glycogenolysis ------------------------------------------------
        f_amp = _hill(amp, self.bp["km_amp_activation"], self.hill_amp)
        gly_avail = _mm(_pos(gly - self.st.glycogen_floor_mM), 20.0)
        ki_gp = self.bp["ki_g6p_phosphorylase"]
        f_ph_gp = _sigmoid((ph - self.bp["ph_phosphorylase_half"]) /
                           self.bp["ph_pfk_slope"])
        j_gp = (fp.vmax_gp * recruit * f_amp *
                _mm(pi, self.bp["km_pi_phosphorylase"]) * gly_avail *
                (ki_gp / (ki_gp + g6p)) * f_ph_gp)

        # --- glucose uptake + hexokinase -----------------------------------
        # Parallel activation signal: how large this fibre's exercise
        # increment is relative to the increment it would carry at the person's
        # oxygen ceiling. It is built from the increment above resting turnover
        # rather than from total turnover, so that a quiescent fibre really is
        # unactivated. Using total turnover with a fractional exponent gives a
        # resting fibre tens of percent of its exercising activation, which
        # floods the matrix with reducing equivalents at rest.
        basal_d = self.bp["resting_muscle_atp_demand"]
        span = max(dmax - basal_d, 1e-9)
        contract = min(1.0, max(0.0, (atpase - basal_d) / span)) ** self.act_exp
        # Calcium/contraction activation of the mitochondrial dehydrogenases,
        # of fatty-acid entry, and of oxidative phosphorylation itself.
        ca_act = ca_floor + (1.0 - ca_floor) * contract
        # Acetyl-CoA/free-CoA ratio: the shared signal behind both arms of the
        # glucose-fatty-acid cycle.
        ratio = accoa / max(coa_free, 1e-5)
        f_randle = self.ki_randle / (self.ki_randle + ratio)
        gain = (1.0 + self.insulin * (self.bp["insulin_glut4_gain_fed"] - 1.0) +
                contract * (self.bp["contraction_glut4_gain"] - 1.0))
        j_glc = (fp.vmax_glut * gain * _mm(glc_b, self.bp["km_glucose_transport"])
                 * _mm(atp, 0.5))

        # --- glycogen synthesis (G6P + 2 ATP -> glycogen + 2 ADP + 3 Pi) ---
        j_gs = (self.vmax_gs * _mm(g6p, self.km_g6p_gs) *
                (0.25 + 0.75 * self.insulin) *
                (1.0 - self.gs_inhib * contract) * _mm(atp, 1.0))

        # --- glycolysis (G6P -> 2 pyruvate) --------------------------------
        f_ph = _sigmoid((ph - self.bp["ph_pfk_half"]) / self.bp["ph_pfk_slope"])
        ki = self.bp["ki_atp_pfk"]
        f_atp = (ki / (ki + atp)) / (ki / (ki + self.atp_total))
        j_gly = (fp.vmax_gly * _mm(g6p, self.bp["km_g6p"]) * f_amp * f_ph *
                 f_atp * _mm(adp, self.km_adp_gly) * _mm(pi, self.km_pi_gly) *
                 f_randle)

        # --- lactate dehydrogenase and transport ----------------------------
        j_ldh = fp.ldh_rate * (pyr * nadh_c - lac * nad_c / self.ldh_keq)
        # Monocarboxylate transport is asymmetric: it is a proton symporter and
        # the outward proton gradient favours export, so uptake into a fibre is
        # slower than export from it at the same concentration difference.
        j_mct = fp.vmax_mct * (_mm(lac, self.bp["km_mct"]) -
                               _mm(lac_b, self.bp["km_mct"]))
        if j_mct < 0.0:
            j_mct *= self.mct_uptake_frac

        # --- pyruvate dehydrogenase ----------------------------------------
        j_pdh = (fp.vmax_pdh * ca_act * _mm(pyr, self.bp["km_pyruvate_pdh"]) *
                 _mm(nad_m, self.bp["km_nad_tca"]) * _mm(coa_free, self.km_coa))

        # --- beta-oxidation and ketone oxidation ----------------------------
        f_accoa = self.ki_ratio / (self.ki_ratio + ratio)
        # Fatty-acid entry into the mitochondrion is itself exercise-gated:
        # carnitine palmitoyltransferase 1 activity rises with contraction as
        # malonyl-CoA falls. Without this, resting beta-oxidation runs at a
        # sizeable fraction of its exercising capacity and floods the matrix
        # with reducing equivalents that the resting respiratory chain cannot
        # oxidise.
        j_box = (fp.vmax_box * ca_act * _mm(ffa_b, self.bp["km_ffa"]) *
                 (self.bp["ki_g6p_beta_ox"] / (self.bp["ki_g6p_beta_ox"] + g6p)) *
                 _mm(nad_m, self.bp["km_nad_tca"]) * _mm(fad, 0.15) * f_accoa *
                 _mm(coa_free, self.km_coa))
        j_ket = (fp.vmax_ket * ca_act * _mm(bhb_b, self.bp["km_ketone"]) *
                 _mm(nad_m, self.bp["km_nad_tca"]) * f_accoa *
                 _mm(coa_free, self.km_coa))

        # --- TCA cycle -------------------------------------------------------
        j_tca = (fp.vmax_tca * ca_act * _mm(accoa, self.bp["km_accoa_tca"]) *
                 _mm(nad_m, self.bp["km_nad_tca"]) * _mm(fad, 0.15))

        # --- reducing-equivalent shuttle (reversible) ------------------------
        j_sh = fp.k_shuttle * (nadh_c * nad_m -
                               nad_c * nadh_m / self.shuttle_keq)
        if j_sh >= 0.0:
            sh_fadh2 = j_sh * fp.shuttle_fadh2
            sh_nadh = j_sh * (1.0 - fp.shuttle_fadh2)
        else:
            # Running backwards, reducing equivalents return to the cytosol
            # through the NADH-linked arm only.
            sh_fadh2 = 0.0
            sh_nadh = j_sh

        # --- oxidative phosphorylation -----------------------------------------
        respctl = (_hill(adp, km_adp, self.hill_adp) *
                   _mm(pi, self.bp["km_pi_oxphos"]) * _mm(o2, self.km_o2))
        ox_act = ox_floor + (1.0 - ox_floor) * contract
        j_ox_n = fp.vmax_ox * ox_act * _mm(nadh_m, self.bp["km_nadh_oxphos"]) * respctl
        j_ox_f = fp.vmax_ox_f * ox_act * _mm(fadh2, self.km_fad) * respctl
        atp_ox = (1.0 - self.leak) * (self.po_n * j_ox_n + self.po_f * j_ox_f)
        o2_use = 0.5 * (j_ox_n + j_ox_f) * self.o2_cost_scale

        return dict(
            atp=atp, adp=adp, amp=amp, pcr=pcr, cr=cr, pi=pi, gly=gly, g6p=g6p,
            pyr=pyr, lac=lac, nadh_c=nadh_c, nadh_m=nadh_m, fadh2=fadh2,
            accoa=accoa, coa_free=coa_free, ca_act=ca_act, ph=ph, o2=o2,
            cover=cover, contract=contract, ox_act=ox_act, ratio=ratio,
            f_randle=f_randle,
            j_atpase=j_atpase, j_atpase_demand=atpase, j_ck=j_ck, j_gp=j_gp,
            j_glc=j_glc, j_gs=j_gs, j_gly=j_gly, j_ldh=j_ldh, j_mct=j_mct, j_pdh=j_pdh,
            j_box=j_box, j_ket=j_ket, j_tca=j_tca, j_sh=j_sh,
            sh_nadh=sh_nadh, sh_fadh2=sh_fadh2,
            j_ox_n=j_ox_n, j_ox_f=j_ox_f, atp_ox=atp_ox, o2_use=o2_use,
            recruit=recruit)

    # ---- right-hand side --------------------------------------------------
    def rhs(self, t: float, y: np.ndarray) -> np.ndarray:
        self._nfev += 1
        if self._budget and self._nfev > self._budget:
            raise IntegrationBudgetExceeded(
                f"exceeded {self._budget} right-hand-side evaluations; this "
                "parameter draw makes the system too stiff to integrate in "
                "bounded time")
        dy = np.zeros(NSTATE)
        demand = self._demand(t)
        rel = self._rel(t)

        aI = _sigmoid((rel - self.fI.recruit_thr) / self.fI.recruit_slope)
        aII = _sigmoid((rel - self.fII.recruit_thr) / self.fII.recruit_slope)

        basal = self.bp["resting_muscle_atp_demand"]
        excess = max(demand - basal, 0.0)
        wsum = (self.fI.atpase_ratio * aI * self.fI.vol_frac +
                self.fII.atpase_ratio * aII * self.fII.vol_frac)
        if wsum < 1e-9:
            dI = dII = basal
        else:
            dI = basal + excess * self.fI.atpase_ratio * aI / wsum
            dII = basal + excess * self.fII.atpase_ratio * aII / wsum

        glc_b = _pos(y[I_GLC])
        lac_b = _pos(y[I_LACB])
        ffa_b = _pos(y[I_FFA])
        bhb_b = _pos(y[I_BHB])
        perf = min(max(y[I_PERF], 0.0), 1.0)

        fx = self._fiber_fluxes(y, 0, self.fI, dI, aI, glc_b, lac_b, ffa_b,
                                bhb_b, rel, self.km_adp["I"],
                                self.ca_floor_fiber["I"], self.dmax["I"],
                                self.ox_floor_fiber["I"])
        gx = self._fiber_fluxes(y, NSP, self.fII, dII, aII, glc_b, lac_b, ffa_b,
                                bhb_b, rel, self.km_adp["II"],
                                self.ca_floor_fiber["II"], self.dmax["II"],
                                self.ox_floor_fiber["II"])

        blood_dglc = 0.0
        blood_dlac = 0.0
        blood_dffa = 0.0
        blood_dbhb = 0.0
        tot_o2 = 0.0

        # Oxygen delivery is shared between the populations in proportion to
        # capillary density weighted by each population's current ATP demand:
        # functional hyperaemia matches flow to metabolic rate. The weights are
        # renormalised so total delivery capability still equals the person's
        # oxygen ceiling.
        wI = self.fI.capillarity * max(dI, 1e-6)
        wII = self.fII.capillarity * max(dII, 1e-6)
        wnorm = wI * self.fI.vol_frac + wII * self.fII.vol_frac
        capI = wI / wnorm if wnorm > 1e-9 else 1.0
        capII = wII / wnorm if wnorm > 1e-9 else 1.0

        for off, fp, f, cap in ((0, self.fI, fx, capI),
                                (NSP, self.fII, gx, capII)):
            # oxygen delivery, back-pressure limited (see params.perfusion_rest_frac)
            # Delivery falls to zero in a fully oxygenated fibre and reaches
            # its capability when intracellular oxygen has been drawn down.
            deliv = (self.vo2max_muscle * perf * self.perf_scale * cap *
                     max(0.0, (self.o2_cap - f["o2"]) /
                         (self.o2_cap * (1.0 - self.o2_min_frac))))
            dy[off + IDX["O2"]] = deliv - f["o2_use"]

            atp_gain = (f["j_ck"] + f["atp_ox"] + 3.0 * f["j_gly"] +
                        GTP_PER_ACCOA_TCA * f["j_tca"] -
                        f["j_glc"] - self.atp_per_stored * f["j_gs"] -
                        ATP_COST_PER_PALMITATE * f["j_box"] -
                        ATP_COST_PER_BHB * f["j_ket"])
            dy[off + IDX["ATP"]] = atp_gain - f["j_atpase"]
            dy[off + IDX["PCr"]] = -f["j_ck"]
            dy[off + IDX["Pi"]] = (f["j_atpase"] - f["j_gp"] - 2.0 * f["j_gly"]
                                   + (self.atp_per_stored + 1.0) * f["j_gs"]
                                   - (f["atp_ox"] + GTP_PER_ACCOA_TCA * f["j_tca"])
                                   + ATP_COST_PER_PALMITATE * f["j_box"]
                                   + ATP_COST_PER_BHB * f["j_ket"])
            dy[off + IDX["GLY"]] = -f["j_gp"] + f["j_gs"]
            dy[off + IDX["G6P"]] = f["j_gp"] + f["j_glc"] - f["j_gly"] - f["j_gs"]
            dy[off + IDX["PYR"]] = 2.0 * f["j_gly"] - f["j_ldh"] - f["j_pdh"]
            dy[off + IDX["LAC"]] = f["j_ldh"] - f["j_mct"]
            dy[off + IDX["NADHc"]] = 2.0 * f["j_gly"] - f["j_ldh"] - f["j_sh"]
            dy[off + IDX["NADHm"]] = (f["j_pdh"] +
                                      NADH_PER_ACCOA_TCA * f["j_tca"] +
                                      NADH_PER_PALMITATE * f["j_box"] +
                                      NADH_PER_BHB * f["j_ket"] +
                                      f["sh_nadh"] - f["j_ox_n"])
            dy[off + IDX["FADH2"]] = (FADH2_PER_ACCOA_TCA * f["j_tca"] +
                                      FADH2_PER_PALMITATE * f["j_box"] +
                                      f["sh_fadh2"] - f["j_ox_f"])
            dy[off + IDX["ACCOA"]] = (f["j_pdh"] +
                                      ACCOA_PER_PALMITATE * f["j_box"] +
                                      ACCOA_PER_BHB * f["j_ket"] - f["j_tca"])
            # Proton balance. Acid accumulates with retained lactate (proton
            # symport means exported lactate carries its proton out), and
            # phosphocreatine breakdown consumes a proton per reaction, which is
            # the measured early alkalinisation at the onset of exercise.
            atp_ox_total = f["atp_ox"] + GTP_PER_ACCOA_TCA * f["j_tca"]
            dlac_cyt = f["j_ldh"] - f["j_mct"]
            h_prod = self.h_lac * dlac_cyt - self.h_ck * f["j_ck"]
            dy[off + IDX["PH"]] = -h_prod / self.buffer

            vw = fp.vol_frac * self.blood_couple
            blood_dlac += f["j_mct"] * vw
            blood_dglc -= f["j_glc"] * fp.vol_frac * self.glc_couple
            blood_dffa -= f["j_box"] * vw
            blood_dbhb -= f["j_ket"] * vw
            tot_o2 += f["o2_use"] * fp.vol_frac

            dy[ACC_IDX["atp_ox"]] += atp_ox_total * fp.vol_frac
            dy[ACC_IDX["atp_gly"]] += 3.0 * f["j_gly"] * fp.vol_frac
            dy[ACC_IDX["atp_pcr"]] += max(f["j_ck"], 0.0) * fp.vol_frac
            dy[ACC_IDX["cho_ox"]] += (f["j_pdh"]) * fp.vol_frac
            dy[ACC_IDX["fat_ox"]] += f["j_box"] * fp.vol_frac
            dy[ACC_IDX["ket_ox"]] += f["j_ket"] * fp.vol_frac
            dy[ACC_IDX["atp_demand"]] += f["j_atpase_demand"] * fp.vol_frac
            dy[ACC_IDX["atp_supplied"]] += f["j_atpase"] * fp.vol_frac
            dy[ACC_IDX["lac_prod"]] += max(f["j_ldh"], 0.0) * fp.vol_frac
            dy[ACC_IDX["gly_used"]] += (f["j_gp"] - f["j_gs"]) * fp.vol_frac
            dy[ACC_IDX["atp_leakloss"]] += (
                self.leak * (self.po_n * f["j_ox_n"] + self.po_f * f["j_ox_f"])
                * fp.vol_frac)

        dy[ACC_IDX["o2"]] = tot_o2

        # ---- blood compartment ----------------------------------------------
        liver = self.liver_avail0 * math.exp(-t / (R.value("liver_glycogen_hours")
                                                   * 3600.0))
        hgo = min(self.hgo_max,
                  self.hgo_k * max(0.0, self.glc_set - glc_b) * 60.0) * liver
        hgo += self.st.glucose_appearance
        dy[I_GLC] = blood_dglc + hgo
        dy[I_LACB] = (blood_dlac + self.lac_clear * self.lac_set
                      - self.lac_clear * lac_b)

        ffa_target = self.ffa_set0 * (1.0 + (self.lipo_gain - 1.0) *
                                      (1.0 - self.insulin) * min(1.0, rel / 0.75)
                                      * max(0.0, 1.0 - max(0.0, rel - 0.80) * 3.0))
        dy[I_FFA] = blood_dffa + (ffa_target - ffa_b) / self.lipo_tau
        dy[I_BHB] = blood_dbhb + (self.st.blood_bhb - bhb_b) / 900.0

        rel_demand = min(1.0, demand / max(self.demand_at_vo2max, 1e-9))
        target_perf = min(1.0, self.perf_rest + (1.0 - self.perf_rest) *
                          rel_demand ** self.perf_exp)
        dy[I_PERF] = (target_perf - perf) / self.perf_tau
        return dy

    # ---- integration -------------------------------------------------------
    # Species used to decide whether the resting relaxation has converged.
    # Glycogen is excluded: at rest it drifts slowly as synthesis and
    # breakdown trade places, and that drift is physiological rather than a
    # sign of an unconverged state.
    _REST_WATCH = ("ATP", "PCr", "Pi", "G6P", "PYR", "LAC", "NADHc", "NADHm",
                   "FADH2", "ACCOA", "PH", "O2")

    def relax_to_rest(self, seconds: float = 600.0, chunk: float = 400.0,
                      max_chunks: int = 4, tol: float = 2e-3) -> np.ndarray:
        """Integrate at resting demand until the state stops moving.

        A fixed relaxation time is not enough. The flavin and coenzyme A pools
        are large relative to the resting fluxes that fill them, so their time
        constants at rest run to tens of minutes; stopping after a fixed
        interval leaves the run starting from a state that is still drifting,
        and the drift then shows up as spurious early transients.
        """
        y = self.initial_state()
        saved_t, saved_v, saved_r = self.demand_t, self.demand_v, self.rel
        basal = self.bp["resting_muscle_atp_demand"]
        self._nfev, self._budget = 0, 400_000
        span = max(seconds, chunk)
        self.demand_t = np.array([0.0, span * (max_chunks + 1)])
        self.demand_v = np.array([basal, basal])
        self.rel = np.array([0.0, 0.0])
        try:
            elapsed = 0.0
            for i in range(max_chunks):
                step = seconds if i == 0 else chunk
                try:
                    sol = solve_ivp(self.rhs, (0.0, step), y, method="LSODA",
                                    rtol=1e-6, atol=1e-9)
                except IntegrationBudgetExceeded:
                    self.rest_budget_exceeded = True
                    break
                if not sol.success:
                    break
                y_new = sol.y[:, -1].copy()
                elapsed += step
                worst = 0.0
                for nm in self._REST_WATCH:
                    for off in (0, NSP):
                        a, b = y[off + IDX[nm]], y_new[off + IDX[nm]]
                        worst = max(worst, abs(b - a) / max(abs(a), 1e-3))
                y = y_new
                if i > 0 and worst < tol:
                    break
            self.rest_relax_s = elapsed
        finally:
            self.demand_t, self.demand_v, self.rel = saved_t, saved_v, saved_r
            self._budget = 0
        y = self._polish_rest(y)
        y[A0:] = 0.0                      # reset accumulators for the run itself
        return y

    # State indices that are solved for at the resting fixed point. Glycogen is
    # excluded because it has no resting fixed point in this model (synthesis
    # and phosphorylase do not exactly cancel), and so are the accumulators.
    _REST_SOLVE = ("ATP", "PCr", "Pi", "G6P", "PYR", "LAC", "NADHc", "NADHm",
                   "FADH2", "ACCOA", "PH", "O2")

    def _polish_rest(self, y: np.ndarray) -> np.ndarray:
        """Solve the resting steady state directly instead of integrating to it.

        The matrix NAD, flavin and coenzyme A pools are large relative to the
        resting fluxes that turn them over, so their relaxation time constants
        at rest run into hours. Integrating that far is wasteful and, if it is
        stopped early, leaves the run starting from a state that is still
        drifting. Root-finding on the same right-hand side reaches the fixed
        point in milliseconds. If it fails, the integrated state is kept.
        """
        idx_list = [off + IDX[nm] for off in (0, NSP) for nm in self._REST_SOLVE]
        idx_list += [I_GLC, I_LACB, I_FFA, I_BHB, I_PERF]
        idx = np.array(idx_list)
        saved = (self.demand_t, self.demand_v, self.rel)
        basal = self.bp["resting_muscle_atp_demand"]
        self.demand_t = np.array([0.0, 1.0])
        self.demand_v = np.array([basal, basal])
        self.rel = np.array([0.0, 0.0])
        base = y.copy()
        scale = np.maximum(np.abs(base[idx]), 1e-4)

        # Two directions in this state space are conserved at rest, so the
        # steady-state condition alone does not pin them and a root solver will
        # slide along them to an arbitrary point.
        #
        #  * Total exchangeable phosphate. Free phosphate, phosphocreatine,
        #    hexose phosphate and the adenine phosphates trade with each other,
        #    and every reaction that moves phosphate between them conserves the
        #    sum, so d[Pi]/dt = 0 holds along a whole line of phosphate
        #    partitions.
        #  * Intracellular pH. At rest, with lactate and phosphocreatine
        #    stationary, the proton balance is satisfied at any pH.
        #
        # Both are pinned to their measured anchors: the registered resting
        # phosphate and phosphocreatine content, and the registered resting pH.
        anchor = self.initial_state()

        def phosphate_total(vec, off):
            atp = vec[off + IDX["ATP"]]
            adp = free_adp(atp, self.atp_total, self.ak_keq)
            amp = self.ak_keq * adp * adp / max(atp, 1e-9)
            return (vec[off + IDX["Pi"]] + vec[off + IDX["PCr"]] +
                    vec[off + IDX["G6P"]] + 3.0 * atp + 2.0 * adp + amp)

        p_anchor = {off: phosphate_total(anchor, off) for off in (0, NSP)}
        ph_anchor = self.bp["ph_rest"]
        pos = {v: k for k, v in enumerate(idx)}

        def resid(u):
            full = base.copy()
            full[idx] = u * scale
            r = self.rhs(0.0, full)[idx] / scale
            for off in (0, NSP):
                i_pi = pos[off + IDX["Pi"]]
                r[i_pi] = ((phosphate_total(full, off) - p_anchor[off]) /
                           max(p_anchor[off], 1e-6))
                i_ph = pos[off + IDX["PH"]]
                r[i_ph] = full[off + IDX["PH"]] - ph_anchor
            return r

        # Accept whichever state has the smaller residual rather than demanding
        # an absolute tolerance: the solvers report success on step size, not on
        # the residual, and a residual small in absolute terms can still move a
        # slow pool by a few percent over a quarter of an hour.
        u0 = base[idx] / scale
        base_resid = float(np.max(np.abs(resid(u0))))
        best_u, best_r = u0, base_resid
        # The work here is bounded explicitly. These solvers build the Jacobian
        # by finite differences, so an unbounded search costs tens of thousands
        # of right-hand-side evaluations for the occasional badly conditioned
        # parameter draw -- far more than the simulation it is preparing for,
        # and enough to look like a hang inside a worker process.
        try:
            for method, opts in (("hybr", {"maxfev": 900}),
                                 ("lm", {"maxiter": 900})):
                if best_r < 1e-8:
                    break
                try:
                    sol = root(resid, best_u, method=method, options=opts)
                except Exception:
                    continue
                r = float(np.max(np.abs(resid(sol.x))))
                if r < best_r:
                    best_u, best_r = np.asarray(sol.x).copy(), r
            cand = base.copy()
            cand[idx] = best_u * scale
            ok = best_r < base_resid
            self.rest_residual = best_r
            self.rest_residual_before = base_resid
        except Exception:
            ok = False
            cand = base
            self.rest_residual = base_resid
            self.rest_residual_before = base_resid
        finally:
            self.demand_t, self.demand_v, self.rel = saved
        if not ok:
            self.rest_polished = False
            return base
        # Reject a solution that is not physically admissible.
        for off in (0, NSP):
            if (cand[off + IDX["ATP"]] <= 0 or
                    cand[off + IDX["ATP"]] > self.atp_total * 1.001 or
                    cand[off + IDX["PCr"]] < 0 or
                    cand[off + IDX["PCr"]] > self.cr_total * 1.001 or
                    cand[off + IDX["Pi"]] <= 0 or
                    cand[off + IDX["NADHm"]] < 0 or
                    cand[off + IDX["NADHm"]] > self.nad_m * 1.001 or
                    cand[off + IDX["FADH2"]] < 0 or
                    cand[off + IDX["FADH2"]] > self.fad * 1.001 or
                    cand[off + IDX["ACCOA"]] < 0 or
                    cand[off + IDX["ACCOA"]] > self.coa_total * 1.001 or
                    not (5.5 < cand[off + IDX["PH"]] < 7.8) or
                    cand[off + IDX["O2"]] < 0):
                self.rest_polished = False
                return base
        self.rest_polished = True
        return cand

    def continue_at_rest(self, y: np.ndarray, seconds: float) -> np.ndarray:
        """Integrate an existing state further at resting demand.

        Used by the validation suite to test that a relaxed state really is
        stationary, without re-running the relaxation from scratch (which would
        compare two independent approaches to the same fixed point rather than
        testing the fixed point itself).
        """
        saved = (self.demand_t, self.demand_v, self.rel)
        basal = self.bp["resting_muscle_atp_demand"]
        self.demand_t = np.array([0.0, seconds])
        self.demand_v = np.array([basal, basal])
        self.rel = np.array([0.0, 0.0])
        try:
            sol = solve_ivp(self.rhs, (0.0, seconds), y, method="LSODA",
                            rtol=1e-6, atol=1e-9)
        finally:
            self.demand_t, self.demand_v, self.rel = saved
        return sol.y[:, -1].copy()

    def run(self, duration_s: float, n_out: int = 200,
            relax_s: float = 900.0) -> "MuscleResult":
        y0 = self.relax_to_rest(relax_s) if relax_s > 0 else self.initial_state()
        t_eval = np.linspace(0.0, duration_s, n_out)
        # Budget scaled to the length of the run. A normal 25-minute
        # realisation uses a few tens of thousands of evaluations.
        self._nfev = 0
        self._budget = int(60_000 + 900 * duration_s / 60.0 * 60)
        try:
            sol = solve_ivp(self.rhs, (0.0, duration_s), y0, method="LSODA",
                            t_eval=t_eval, rtol=2e-6, atol=1e-9, max_step=20.0)
        finally:
            self._budget = 0
        return MuscleResult(self, sol, y0)


# --------------------------------------------------------------------------
# Result container
# --------------------------------------------------------------------------

class MuscleResult:
    def __init__(self, model: MuscleModel, sol, y0: np.ndarray):
        self.m = model
        self.sol = sol
        self.ok = bool(sol.success)
        self.t = sol.t
        self.y = sol.y
        self.y0 = y0
        self.message = sol.message

    # convenience accessors -------------------------------------------------
    def sp(self, name: str, fiber: str = "I") -> np.ndarray:
        off = 0 if fiber == "I" else NSP
        return self.y[off + IDX[name]]

    def mixed(self, name: str) -> np.ndarray:
        """Volume-weighted value across the two fibre populations.

        This is the state of the *recruited* fibres in each population. For
        comparison with a measurement it is usually the wrong quantity -- see
        `homogenate`.
        """
        f1 = self.m.fI.vol_frac
        return f1 * self.sp(name, "I") + (1 - f1) * self.sp(name, "II")

    def recruitment(self) -> Tuple[np.ndarray, np.ndarray]:
        """Recruited fraction of each fibre population over the run."""
        rel = np.array([self.m._rel(float(t)) for t in self.t])
        aI = np.array([_sigmoid((r - self.m.fI.recruit_thr) /
                                self.m.fI.recruit_slope) for r in rel])
        aII = np.array([_sigmoid((r - self.m.fII.recruit_thr) /
                                 self.m.fII.recruit_slope) for r in rel])
        return aI, aII

    def homogenate(self, name: str) -> np.ndarray:
        """What a biopsy or a magnetic-resonance voxel would actually report.

        A needle biopsy homogenises the whole sample and a 31P spectrum
        integrates the whole voxel, so both average recruited and unrecruited
        fibres together. The model integrates the state of the recruited
        fibres, because those are the ones carrying the ATP demand. Comparing
        that directly against a measured value is an apples-to-oranges error:
        at a moderate running intensity less than half the fast population is
        recruited, and the unrecruited remainder still holds resting
        phosphocreatine and resting glycogen. Reporting the recruited state as
        if it were the homogenate makes the simulated phosphocreatine fall far
        further than magnetic resonance spectroscopy shows, and flattens its
        response across the intensity range.
        """
        aI, aII = self.recruitment()
        f1 = self.m.fI.vol_frac
        if name == "PH":
            # pH is a logarithm, so the homogenate averages proton
            # concentration, not pH. Averaging pH directly would understate the
            # acidity of a sample containing a strongly acidified subpopulation.
            def h(arr):
                return 10.0 ** (-np.asarray(arr))
            restI = h(self.y0[IDX[name]])
            restII = h(self.y0[NSP + IDX[name]])
            hI = aI * h(self.sp(name, "I")) + (1.0 - aI) * restI
            hII = aII * h(self.sp(name, "II")) + (1.0 - aII) * restII
            return -np.log10(f1 * hI + (1 - f1) * hII)
        restI = float(self.y0[IDX[name]])
        restII = float(self.y0[NSP + IDX[name]])
        vI = aI * self.sp(name, "I") + (1.0 - aI) * restI
        vII = aII * self.sp(name, "II") + (1.0 - aII) * restII
        return f1 * vI + (1 - f1) * vII

    def acc(self, name: str) -> np.ndarray:
        return self.y[ACC_IDX[name]]

    def final(self, name: str) -> float:
        return float(self.y[ACC_IDX[name]][-1])

    def fluxes_at(self, i: int) -> Dict[str, Dict[str, float]]:
        y = self.y[:, i]
        t = self.t[i]
        rel = self.m._rel(t)
        demand = self.m._demand(t)
        aI = _sigmoid((rel - self.m.fI.recruit_thr) / self.m.fI.recruit_slope)
        aII = _sigmoid((rel - self.m.fII.recruit_thr) / self.m.fII.recruit_slope)
        basal = self.m.bp["resting_muscle_atp_demand"]
        excess = max(demand - basal, 0.0)
        wsum = (self.m.fI.atpase_ratio * aI * self.m.fI.vol_frac +
                self.m.fII.atpase_ratio * aII * self.m.fII.vol_frac)
        dI = basal + (excess * self.m.fI.atpase_ratio * aI / wsum if wsum > 1e-9 else 0)
        dII = basal + (excess * self.m.fII.atpase_ratio * aII / wsum if wsum > 1e-9 else 0)
        return {
            "I": self.m._fiber_fluxes(y, 0, self.m.fI, dI, aI, y[I_GLC],
                                      y[I_LACB], y[I_FFA], y[I_BHB], rel,
                                      self.m.km_adp["I"],
                                      self.m.ca_floor_fiber["I"], self.m.dmax["I"],
                                      self.m.ox_floor_fiber["I"]),
            "II": self.m._fiber_fluxes(y, NSP, self.m.fII, dII, aII, y[I_GLC],
                                       y[I_LACB], y[I_FFA], y[I_BHB], rel,
                                       self.m.km_adp["II"],
                                       self.m.ca_floor_fiber["II"], self.m.dmax["II"],
                                       self.m.ox_floor_fiber["II"]),
        }
