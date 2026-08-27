"""D. External data contrasts (spec 2.10.D).

Compare simulated distributions against measured human ranges for:

* VO2 versus running speed and grade
* respiratory exchange / indirect-calorimetry fuel oxidation
* blood-lactate curves
* muscle-glycogen change
* phosphocreatine measured by 31P magnetic resonance spectroscopy

Indirect calorimetry infers whole-body carbohydrate and fat oxidation from gas
exchange; it is useful but has assumptions and is less reliable during
non-steady-state, very intense exercise, so the engine is validated against the
measurement's actual scope rather than treated as cellular ground truth.

Where the engine misses a band, that is reported as a failing check.  The
residuals are the honest description of what this version does and does not
reproduce.
"""

from __future__ import annotations

from typing import Any, Dict, List, Tuple

import numpy as np

from ..demand import cost_of_running, vo2_ml_kg_min
from ..ensemble import run_ensemble
from ..params import R
from ..scenario import Intensity
from .common import Check, base_scenario, reference_person, med

N = 40

# (intensity, phosphocreatine fraction of rest, arterial lactate mmol/L,
#  fat share of oxidised carbon, glycogen used mmol/kg ww per 30 min)
TARGETS: List[Tuple[float, Tuple[float, float], Tuple[float, float],
                    Tuple[float, float], Tuple[float, float]]] = [
    (0.55, (0.78, 0.90), (0.8, 2.0), (0.35, 0.58), (6, 26)),
    (0.70, (0.60, 0.78), (1.6, 3.6), (0.20, 0.40), (18, 48)),
    (0.85, (0.42, 0.65), (3.5, 8.5), (0.08, 0.24), (36, 85)),
]

TARGET_EVIDENCE = {
    "pcr": "31P magnetic resonance spectroscopy of human quadriceps across "
           "exercise intensity domains",
    "lactate": "Arterial and capillary blood-lactate curves during graded "
               "treadmill running",
    "fat": "Venables et al. 2005 (n=300) indirect calorimetry during graded "
           "treadmill exercise; whole-body substrate oxidation, not a cellular "
           "measurement",
    "glycogen": "Vastus lateralis biopsy glycogen depletion (PMC5872716, "
                "PMC6019055)",
}


def _cost_of_transport_checks() -> List[Check]:
    out = []
    level = cost_of_running(0.0)
    out.append(Check(
        "D. External contrasts", "level_cost_of_transport",
        3.3 <= level <= 3.9,
        f"The engine's level running cost of transport is {level:.2f} J/kg/m. "
        "Minetti et al. measured about 3.6 J/kg/m in their mountain-runner "
        "sample and the spec quotes 3.4.",
        expected="3.3-3.9 J/kg/m", observed=f"{level:.2f}",
        evidence="Minetti et al. 2002 (PMID 12183501)"))
    minimum_grade = min(np.arange(-0.45, 0.0, 0.01),
                        key=lambda g: cost_of_running(float(g)))
    out.append(Check(
        "D. External contrasts", "downhill_cost_minimum",
        bool(-0.30 <= minimum_grade <= -0.10),
        f"The cost of transport is minimised at a gradient of "
        f"{minimum_grade*100:.0f}%, matching the measured shallow-downhill "
        "minimum rather than at level or at the steepest descent.",
        expected="-30% to -10%", observed=f"{minimum_grade*100:.0f}%",
        evidence="Minetti et al. 2002"))
    econ = R.value("economy_factor")
    rmr = R.value("resting_metabolic_rate")
    j = R.value("energy_per_mL_O2")
    v = vo2_ml_kg_min(3.33, 0.0, econ, rmr, j)
    out.append(Check(
        "D. External contrasts", "vo2_at_5min_per_km",
        36.0 <= v <= 46.0,
        f"At 3.33 m/s (5:00/km) on the level the engine predicts "
        f"{v:.1f} mL/kg/min. The ACSM running equation gives 43.5 and the "
        "Minetti runner curve gives about 39, so a central runner should land "
        "between them.",
        expected="36-46 mL/kg/min", observed=f"{v:.1f}",
        evidence="Minetti et al. 2002; ACSM metabolic equations"))
    return out


def run(n: int = N) -> Tuple[List[Check], Dict[str, Any]]:
    checks = _cost_of_transport_checks()
    person = reference_person()
    table: List[Dict[str, Any]] = []

    for intensity, pcr_b, lac_b, fat_b, gly_b in TARGETS:
        out = run_ensemble(person, base_scenario(intensity=intensity,
                                                 duration=30), n=n, seed=606)
        row: Dict[str, Any] = {"intensity_pct_vo2max": intensity * 100}
        for key, band, tag, label, ev in (
                ("pcr_end_fraction", pcr_b, "pcr",
                 "phosphocreatine at the end of the run, as a fraction of "
                 "resting", TARGET_EVIDENCE["pcr"]),
                ("blood_lactate_peak", lac_b, "lactate",
                 "peak arterial lactate", TARGET_EVIDENCE["lactate"]),
                ("fat_carbon_fraction", fat_b, "fat",
                 "fat share of oxidised carbon", TARGET_EVIDENCE["fat"]),
                ("glycogen_used", gly_b, "glycogen",
                 "muscle glycogen consumed over 30 minutes",
                 TARGET_EVIDENCE["glycogen"])):
            e = out.get(key)
            if e is None:
                continue
            m = e.median()
            lo, hi = e.interval(0.80)
            in_band = band[0] <= m <= band[1]
            # An interval that overlaps the band is a partial success worth
            # distinguishing from a median that misses it entirely.
            overlaps = not (hi < band[0] or lo > band[1])
            row[key] = {"median": round(m, 4),
                        "ci80": [round(lo, 4), round(hi, 4)],
                        "band": list(band), "in_band": in_band,
                        "overlaps": overlaps}
            checks.append(Check(
                "D. External contrasts",
                f"{tag}_at_{int(intensity*100)}pct", in_band,
                f"Simulated {label} at {intensity:.0%} of the aerobic ceiling is "
                f"{m:.3g} (80% interval {lo:.3g}-{hi:.3g}); measured human "
                f"values fall in {band[0]:g}-{band[1]:g}."
                + ("" if in_band else
                   (" The median misses the band, though the uncertainty "
                    "interval overlaps it." if overlaps else
                    " The median and the whole 80% interval miss the band; "
                    "this is a genuine calibration gap in version 1.")),
                expected=f"{band[0]:g}-{band[1]:g}", observed=f"{m:.3g}",
                severity="error" if not overlaps else "warning",
                evidence=ev))
        table.append(row)

    # VO2 kinetics: the oxygen-uptake time constant at a step in workload.
    out = run_ensemble(person, base_scenario(intensity=0.70, duration=12),
                       n=n, seed=607, keep_traj=n)
    tau_ok, tau = _vo2_tau(out)
    checks.append(Check(
        "D. External contrasts", "vo2_kinetics_time_constant", tau_ok,
        f"The simulated oxygen-uptake time constant at the onset of moderate "
        f"running is {tau:.0f} s. Measured values in trained adults are "
        "roughly 20-45 s.",
        expected="15-55 s", observed=f"{tau:.0f} s",
        evidence="Pulmonary oxygen-uptake kinetics; Korzeniewski-model "
                 "evaluation PMC4704516"))
    return checks, {"table": table, "targets": [
        {"intensity": t[0], "pcr": t[1], "lactate": t[2], "fat": t[3],
         "glycogen": t[4]} for t in TARGETS]}


def _vo2_tau(out) -> Tuple[bool, float]:
    tr = out.trajectories
    if not tr or "vo2" not in tr:
        return False, float("nan")
    t = np.array(tr["t_min"]) * 60.0
    y = np.array(tr["vo2"]["median"])
    if y.size < 6:
        return False, float("nan")
    base, plateau = float(y[0]), float(np.median(y[-max(3, y.size // 5):]))
    if plateau <= base:
        return False, float("nan")
    target = base + 0.632 * (plateau - base)
    idx = np.argmax(y >= target)
    tau = float(t[idx]) if y[idx] >= target else float(t[-1])
    return (15.0 <= tau <= 55.0), tau
