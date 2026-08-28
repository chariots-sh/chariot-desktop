"""Running-demand model (spec 2.3).

Converts pace, grade, body mass and interval structure into a time-varying
metabolic power estimate, then into an ATP-hydrolysis set-point inside the
modelled muscle.

The spec is emphatic that these are two different things: "A pace is not a
biochemical reaction rate; it must first be translated into a distribution over
metabolic demand."  Everything here is whole-body empirical energetics.  No
reaction kinetics appear until muscle.py.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

import numpy as np

from .params import R
from .scenario import Scenario, INTERVAL_STRUCTURE

# --------------------------------------------------------------------------
# Cost of transport
# --------------------------------------------------------------------------

_MINETTI = ("minetti_c5", "minetti_c4", "minetti_c3", "minetti_c2",
            "minetti_c1", "minetti_c0")


def cost_of_running(grade: float, coeffs: Optional[Dict[str, float]] = None) -> float:
    """Minetti et al. 2002 energy cost of running, J/kg/m, for gradient `grade`
    expressed as a fraction (0.10 = 10% uphill).

    Raises outside the measured -0.45..+0.45 domain: spec 2.10.A requires we do
    not silently extrapolate a fitted polynomial.
    """
    lo, hi = R.value("minetti_grade_min"), R.value("minetti_grade_max")
    if not (lo <= grade <= hi):
        raise ValueError(
            f"gradient {grade:+.3f} is outside the measured domain "
            f"[{lo}, {hi}] of the cost-of-running polynomial")
    c = coeffs or {n: R.value(n) for n in _MINETTI}
    g = grade
    return (c["minetti_c5"] * g**5 + c["minetti_c4"] * g**4 +
            c["minetti_c3"] * g**3 + c["minetti_c2"] * g**2 +
            c["minetti_c1"] * g + c["minetti_c0"])


def metabolic_power_w_per_kg(speed_m_s: float, grade: float, economy: float,
                             rmr: float, grade_penalty: float = 1.0) -> float:
    """Gross mass-specific metabolic power, W/kg.

    The Minetti cost is a net (above-resting) cost of transport, so resting
    metabolic rate is added to obtain the gross figure that a metabolic cart
    would report.
    """
    c_level = cost_of_running(0.0)
    c_grade = cost_of_running(grade)
    # Personal deviation from the population grade response is applied only to
    # the grade-dependent part of the cost, not to the level cost.
    c = c_level + (c_grade - c_level) * grade_penalty
    return c * economy * speed_m_s + rmr


def vo2_ml_kg_min(speed_m_s: float, grade: float, economy: float, rmr: float,
                  j_per_ml: float, grade_penalty: float = 1.0) -> float:
    p = metabolic_power_w_per_kg(speed_m_s, grade, economy, rmr, grade_penalty)
    return p / j_per_ml * 60.0


def speed_for_vo2(target_vo2: float, grade: float, economy: float, rmr: float,
                  j_per_ml: float, grade_penalty: float = 1.0) -> float:
    """Invert the cost model: what speed costs `target_vo2` mL/kg/min?"""
    c_level = cost_of_running(0.0)
    c_grade = cost_of_running(grade)
    c = (c_level + (c_grade - c_level) * grade_penalty) * economy
    p_target = target_vo2 * j_per_ml / 60.0
    if c <= 0:                       # steep downhill can give a negative cost
        return 0.0
    return max(0.0, (p_target - rmr) / c)


# --------------------------------------------------------------------------
# Intensity time series from the scenario pattern
# --------------------------------------------------------------------------

def intensity_series(sc: Scenario, dt: float = 1.0) -> Tuple[np.ndarray, np.ndarray]:
    """Relative-intensity trace (fraction of the scenario's target effort) over
    the session, sampled at `dt` seconds.

    Warm-up is included inside the stated duration for interval patterns, which
    is how people actually run them.
    """
    total_s = sc.duration_min * 60.0
    t = np.arange(0.0, total_s + dt, dt)
    y = np.zeros_like(t)

    if sc.pattern == "continuous":
        y[:] = 1.0

    elif sc.pattern == "progression":
        # Linear rise from 75% to 115% of the nominal target, so the mean effort
        # equals the target and the finish is genuinely harder.
        frac = t / max(total_s, 1e-9)
        y[:] = 0.75 + 0.40 * frac

    else:
        work_s, rec_s, rec_frac, warm_min = INTERVAL_STRUCTURE[sc.pattern]
        warm_s = min(warm_min * 60.0, 0.35 * total_s)
        cycle = work_s + rec_s
        in_warm = t < warm_s
        y[in_warm] = 0.55
        rel = t[~in_warm] - warm_s
        phase = np.mod(rel, cycle)
        y[~in_warm] = np.where(phase < work_s, 1.0, rec_frac)
        # cool-down: last 3 minutes easy if the session is long enough
        if total_s > 20 * 60:
            y[t > total_s - 180.0] = 0.5

    return t, y


def count_work_bouts(sc: Scenario) -> int:
    if sc.pattern not in INTERVAL_STRUCTURE:
        return 0
    work_s, rec_s, _, warm_min = INTERVAL_STRUCTURE[sc.pattern]
    total_s = sc.duration_min * 60.0
    warm_s = min(warm_min * 60.0, 0.35 * total_s)
    usable = total_s - warm_s - (180.0 if total_s > 1200 else 0.0)
    return max(0, int(usable // (work_s + rec_s)))


# --------------------------------------------------------------------------
# Full demand profile
# --------------------------------------------------------------------------

@dataclass
class DemandProfile:
    """One sampled realisation of the running demand for one scenario."""
    t: np.ndarray                  # s
    speed: np.ndarray              # m/s
    vo2: np.ndarray                # mL/kg/min, whole body gross
    rel_intensity: np.ndarray      # fraction of the person's VO2max
    atp_demand: np.ndarray         # mmol/L cell water/s in the modelled muscle
    muscle_water_L: float
    active_muscle_kg: float
    vo2max: float                  # mL/kg/min, after environment adjustment
    grade: float
    mean_vo2: float
    target_speed: float
    notes: List[str]

    def demand_at(self, tq: float) -> float:
        return float(np.interp(tq, self.t, self.atp_demand))

    def rel_at(self, tq: float) -> float:
        return float(np.interp(tq, self.t, self.rel_intensity))


def _smooth_step(y: np.ndarray, dt: float, tau: float = 2.5) -> np.ndarray:
    """First-order smoothing of workload transitions.

    Muscle ATPase follows contraction essentially instantly, but a runner takes
    a couple of seconds to change speed.  This also keeps the ODE from being
    handed a true discontinuity at every interval edge.
    """
    a = dt / (tau + dt)
    out = np.empty_like(y)
    acc = y[0]
    for i, v in enumerate(y):
        acc += a * (v - acc)
        out[i] = acc
    return out


def build_demand(sc: Scenario, state, dt: float = 1.0) -> DemandProfile:
    """Build the ATP-demand time series for one scenario and one sampled
    personal state (see estimate.PersonalState)."""
    notes: List[str] = []
    grade = sc.grade_pct / 100.0
    t, shape = intensity_series(sc, dt)

    # --- resolve the requested effort into a target speed ------------------
    vo2max = state.vo2max_env
    kind, val = sc.intensity.kind, sc.intensity.value
    if kind == "pct_vo2max":
        target_vo2 = val * vo2max
        target_speed = speed_for_vo2(target_vo2, grade, state.economy,
                                     state.rmr, state.j_per_ml,
                                     state.grade_penalty)
    elif kind == "speed_m_s":
        target_speed = val
    elif kind == "pace_s_per_km":
        target_speed = 1000.0 / val
    elif kind == "hr_zone":
        # Zones 1-5 mapped to fractions of VO2max reserve, then to speed.
        zone_frac = {1: 0.50, 2: 0.62, 3: 0.72, 4: 0.83, 5: 0.92}
        frac = zone_frac.get(int(round(val)), 0.65)
        target_speed = speed_for_vo2(frac * vo2max, grade, state.economy,
                                     state.rmr, state.j_per_ml,
                                     state.grade_penalty)
        notes.append("Heart-rate zones were converted to a metabolic target "
                     "through a population zone map; heart rate is a good "
                     "consumer signal but the zone-to-VO2 mapping is personal "
                     "and adds uncertainty.")
    else:
        raise ValueError(f"unknown intensity kind {kind!r}")

    speed = _smooth_step(shape * target_speed, dt)

    # --- whole-body oxygen cost -------------------------------------------
    c_level = cost_of_running(0.0)
    c_grade = cost_of_running(grade)
    c = (c_level + (c_grade - c_level) * state.grade_penalty) * state.economy
    power = c * speed + state.rmr                       # W/kg gross
    vo2 = power / state.j_per_ml * 60.0                 # mL/kg/min
    rel = vo2 / max(vo2max, 1e-9)

    if float(np.max(vo2)) > vo2max * 1.02:
        notes.append(
            f"Peak demand ({float(np.max(vo2)):.1f} mL/kg/min) exceeds the "
            f"estimated aerobic ceiling ({vo2max:.1f}); the run is only "
            "completable with a substantial non-oxidative contribution.")

    # --- map onto the modelled muscle -------------------------------------
    net_power_w = (power - state.rmr) * state.body_mass_kg      # W, exercise increment
    muscle_w = net_power_w * (1.0 - state.nonmuscle_frac)
    ml_o2_per_s = muscle_w / state.j_per_ml
    mmol_o2_per_s = ml_o2_per_s / R.value("o2_molar_volume")
    mmol_atp_per_s = mmol_o2_per_s * state.atp_per_o2
    atp_demand = mmol_atp_per_s / state.muscle_water_L + state.resting_atp_demand

    return DemandProfile(
        t=t, speed=speed, vo2=vo2, rel_intensity=rel, atp_demand=atp_demand,
        muscle_water_L=state.muscle_water_L,
        active_muscle_kg=state.active_muscle_kg,
        vo2max=vo2max, grade=grade,
        mean_vo2=float(np.mean(vo2)), target_speed=target_speed, notes=notes)
