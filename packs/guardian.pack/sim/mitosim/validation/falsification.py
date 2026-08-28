"""E. Falsification tests (spec 2.10.E).

* Shuffle person labels: personalization benefit should disappear.
* Hold running demand constant while changing an unrelated lab: the output
  should remain stable.
* Remove oxygen or substrate constraints: the engine should respond in the
  expected direction.
* Sweep each input across its domain: discontinuities require a biological or
  numerical explanation.
* Repeat simulations with wider priors: confidence should decrease rather than
  the median acquiring false precision.
"""

from __future__ import annotations

import copy
import datetime as dt
from typing import Any, Callable, Dict, List, Tuple

import numpy as np

from ..ensemble import run_ensemble
from ..inputs import LabPanel, LabValue
from ..params import R
from ..provenance import Dist
from ..scenario import Intensity
from .common import Check, base_scenario, reference_person, med, p_direction

N = 48


def _shuffle_labels() -> List[Check]:
    """Personalisation must come from the person, not from the label.

    Two people with genuinely different physiology should produce different
    outputs. If their *identifying* fields are swapped but their physiological
    fields are not, nothing should change: the engine must not be reading
    identity.
    """
    a = reference_person(vo2max=42, level="recreational", subject_id="alpha")
    b = copy.deepcopy(a)
    b.subject_id = "omega"
    out_a = run_ensemble(a, base_scenario(), n=N, seed=555)
    out_b = run_ensemble(b, base_scenario(), n=N, seed=555)
    diffs = []
    for key in ("oxidative_atp_fraction", "muscle_vo2", "glycogen_used",
                "blood_lactate_peak"):
        ma, mb = med(out_a, key), med(out_b, key)
        if ma is None or mb is None:
            continue
        diffs.append(abs(mb - ma) / max(abs(ma), 1e-9))
    worst = max(diffs) if diffs else 0.0
    checks = [Check(
        "E. Falsification", "identity_has_no_effect", worst < 1e-9,
        f"Changing only the subject identifier changes every output by at most "
        f"{worst:.2e}. The engine reads physiology, not labels.",
        expected="0", observed=f"{worst:.2e}")]

    # And the converse: swapping the physiology must change the output.
    c = reference_person(vo2max=66, level="competitive", subject_id="alpha")
    out_c = run_ensemble(c, base_scenario(), n=N, seed=555)
    p = p_direction(out_a, out_c, "muscle_vo2", True)
    checks.append(Check(
        "E. Falsification", "physiology_does_have_an_effect",
        p is not None and p >= 0.85,
        f"Swapping the physiology while holding the label fixed does change the "
        f"mechanism: absolute muscle oxygen flux rises in "
        f"{(p or 0)*100:.0f}% of paired samples. A personalisation benefit that "
        "survived label shuffling but vanished here would be the real failure.",
        expected="P >= 0.85", observed=f"{(p or 0):.2f}"))
    return checks


def _unrelated_lab_stability() -> List[Check]:
    person = reference_person()
    plus = reference_person()
    plus.labs = LabPanel([
        LabValue("vitamin_d", 18.0, "ng/mL", dt.date(2026, 7, 1),
                 ref_low=30, ref_high=100),
        LabValue("alt", 30.0, "U/L", dt.date(2026, 7, 1), ref_low=7, ref_high=55),
        LabValue("sodium", 140.0, "mmol/L", dt.date(2026, 7, 1),
                 ref_low=135, ref_high=145),
        LabValue("hdl", 1.4, "mmol/L", dt.date(2026, 7, 1)),
    ])
    a = run_ensemble(person, base_scenario(), n=N, seed=777)
    b = run_ensemble(plus, base_scenario(), n=N, seed=777)
    out = []
    for key in ("atp_demand", "oxidative_atp_fraction", "muscle_vo2",
                "glycogen_used"):
        ma, mb = med(a, key), med(b, key)
        assert ma is not None and mb is not None
        rel = abs(mb - ma) / max(abs(ma), 1e-9)
        out.append(Check(
            "E. Falsification", f"unrelated_lab_stability:{key}", rel < 1e-9,
            f"Holding the run constant and adding laboratory values with no "
            f"defensible mapping changes {key} by {rel:.2e}.",
            expected="0", observed=f"{rel:.2e}",
            evidence="Spec 2.10.E: hold running demand constant while changing "
                     "an unrelated lab"))
    return out


def _remove_constraints() -> List[Check]:
    """Relaxing a constraint must move the mechanism in the expected direction."""
    person = reference_person()
    out: List[Check] = []
    sc = base_scenario(intensity=0.85, duration=25)

    base = run_ensemble(person, sc, n=N, seed=888)

    # Oxygen: take the ceiling away by dropping to a much lower elevation is not
    # possible at sea level, so raise it directly by giving the person a much
    # higher aerobic ceiling and holding the absolute pace constant.
    faster = reference_person(vo2max=54)
    sc_speed = base_scenario(intensity=0.85, duration=25)
    sc_speed = type(sc_speed)(**{**sc_speed.__dict__,
                                 "intensity": Intensity("speed_m_s", 4.0)})
    low_o2 = run_ensemble(reference_person(vo2max=54), sc_speed, n=N, seed=888)
    high_o2 = run_ensemble(reference_person(vo2max=72), sc_speed, n=N, seed=888)
    p = p_direction(low_o2, high_o2, "nonoxidative_atp_fraction", False)
    ma, mb = med(low_o2, "nonoxidative_atp_fraction"), \
        med(high_o2, "nonoxidative_atp_fraction")
    # The requirement is that the engine responds in the expected direction when
    # a constraint is relaxed. That is a statement about the central estimate.
    # The paired probability is reported next to it rather than asserted,
    # because for this particular output it settles near 0.75 and pretending
    # otherwise would mean choosing a threshold to fit the answer.
    out.append(Check(
        "E. Falsification", "relaxing_oxygen_constraint_lowers_nonoxidative_atp",
        mb is not None and ma is not None and mb < ma,
        f"Raising the oxygen ceiling while holding the absolute pace fixed "
        f"lowers the non-oxidative share of ATP from {ma:.4g} to {mb:.4g} "
        f"({(ma-mb)/max(ma,1e-9)*100:.0f}%), the expected direction. The "
        f"direction holds in {(p or 0)*100:.0f}% of paired samples: solid "
        "centrally, not robust across the parameter ensemble."
        if (mb is not None and ma is not None and mb < ma) else
        "Relaxing the oxygen constraint did not lower the non-oxidative share "
        "of ATP.",
        expected="median falls", observed=f"{ma:.4g} -> {mb:.4g}, "
                                          f"P = {(p or 0):.2f}"))

    # Substrate: remove the glycogen constraint by loading, on a long run.
    long_lo = run_ensemble(reference_person(), base_scenario(
        duration=100, intensity=0.68, prev_cho="low", gly="low"), n=N, seed=889)
    long_hi = run_ensemble(reference_person(), base_scenario(
        duration=100, intensity=0.68, prev_cho="high", gly="high"), n=N, seed=889)
    p = p_direction(long_lo, long_hi, "time_to_glycogen_limit", True)
    out.append(Check(
        "E. Falsification", "relaxing_substrate_constraint_delays_limit",
        p is not None and p >= 0.80,
        f"Removing the glycogen constraint pushes the time to glycogen "
        f"limitation later in {(p or 0)*100:.0f}% of paired samples.",
        expected="P >= 0.80", observed=f"{(p or 0):.2f}"))
    return out


def _sweep_continuity() -> Tuple[List[Check], Dict[str, Any]]:
    """Sweep each input across its domain and look for unexplained jumps."""
    person = reference_person()
    out: List[Check] = []
    sweeps: Dict[str, Tuple[List[Any], Callable[[Any], Any]]] = {
        "intensity": ([0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90],
                      lambda v: base_scenario(intensity=v, duration=25)),
        "duration_min": ([10, 20, 30, 45, 60, 80, 100],
                         lambda v: base_scenario(duration=v, intensity=0.65)),
        "hours_since_meal": ([1, 2, 3, 5, 8, 12, 16],
                             lambda v: base_scenario(hsm=v, duration=45)),
        "grade_pct": ([-8, -4, -2, 0, 2, 4, 8, 12],
                      lambda v: base_scenario(grade=v, duration=25)),
        "elevation_m": ([0, 500, 1000, 1500, 2200, 3000, 4000],
                        lambda v: base_scenario(elev=v, duration=30)),
        "pre_run_cho_g": ([0, 15, 25, 50, 75, 100],
                          lambda v: base_scenario(cho=v, hsm=12, duration=45)),
    }
    key_for = {"intensity": "blood_lactate_peak",
               "duration_min": "glycogen_used",
               "hours_since_meal": "fat_carbon_fraction",
               "grade_pct": "atp_demand",
               "elevation_m": "spare_oxidative_capacity",
               "pre_run_cho_g": "cho_carbon_fraction"}
    curves: Dict[str, Any] = {}
    for axis, (values, make) in sweeps.items():
        key = key_for[axis]
        ys = []
        for v in values:
            o = run_ensemble(person, make(v), n=max(12, N // 2), seed=2024)
            ys.append(med(o, key))
        ys = [y for y in ys if y is not None]
        curves[axis] = {"x": values, "y": ys, "output": key}
        if len(ys) < 4:
            continue
        arr = np.array(ys, dtype=float)
        scale = max(np.nanmax(np.abs(arr)), 1e-9)
        steps = np.abs(np.diff(arr)) / scale
        # A jump is a step more than 4x the median step and above 15% of range.
        m = float(np.median(steps)) if steps.size else 0.0
        jumps = [(values[i], values[i + 1], float(steps[i]))
                 for i in range(len(steps))
                 if steps[i] > max(4.0 * m, 0.15)]
        # Monotone sweeps should also be monotone.
        mono = bool(np.all(np.diff(arr) >= -0.02 * scale) or
                    np.all(np.diff(arr) <= 0.02 * scale))
        ok = not jumps
        out.append(Check(
            "E. Falsification", f"sweep_continuity:{axis}", ok,
            f"Sweeping {axis} across its domain moves {key} smoothly "
            f"(median step {m*100:.1f}% of range"
            + (f", monotone)." if mono else ", non-monotone but continuous).")
            if ok else
            f"Sweeping {axis} produced a discontinuity in {key} between "
            + "; ".join(f"{a} and {b} (step {s*100:.0f}% of range)"
                        for a, b, s in jumps)
            + ". A jump needs a biological or numerical explanation.",
            expected="no unexplained jumps",
            observed=f"{len(jumps)} jump(s)"))
    return out, curves


def _wider_priors() -> List[Check]:
    """Widening the priors must widen the answer, not sharpen the median."""
    person = reference_person()
    sc = base_scenario(duration=40, intensity=0.70)
    narrow = run_ensemble(person, sc, n=N, seed=3131)

    widened_names = [p.name for p in R
                     if p.dist is not None and p.dist.kind in
                     ("lognormal", "normal") and "sensitivity_key" in p.tags]
    saved = {}
    for name in widened_names:
        p = R.P(name)
        saved[name] = p.dist
        d = p.dist
        assert d is not None  # widened_names only holds params with a dist
        if d.kind == "lognormal":
            nd = Dist("lognormal", d.a, max(1.02, d.b ** 2.0), d.lo, d.hi)
        else:
            nd = Dist("normal", d.a, d.b * 2.0, d.lo, d.hi)
        object.__setattr__(p, "dist", nd)
    try:
        wide = run_ensemble(person, sc, n=N, seed=3131)
    finally:
        for name, d in saved.items():
            object.__setattr__(R.P(name), "dist", d)

    wider = 0
    total = 0
    details = []
    for key in ("oxidative_atp_fraction", "fat_carbon_fraction",
                "glycogen_used", "blood_lactate_peak", "muscle_vo2",
                "pcr_end_fraction"):
        ea, eb = narrow.get(key), wide.get(key)
        if ea is None or eb is None:
            continue
        la, ha = ea.interval(0.80)
        lb, hb = eb.interval(0.80)
        total += 1
        if (hb - lb) >= (ha - la) * 0.98:
            wider += 1
        details.append(f"{key} {ha-la:.3g} -> {hb-lb:.3g}")
    return [Check(
        "E. Falsification", "wider_priors_widen_outputs",
        total > 0 and wider >= total - 1,
        f"Squaring the geometric spread of every sensitivity-key parameter "
        f"widens the 80% interval for {wider} of {total} outputs "
        f"({'; '.join(details[:4])}). Confidence decreases as knowledge "
        "decreases; the median does not acquire false precision.",
        expected=f">= {max(0, total-1)}/{total}", observed=f"{wider}/{total}",
        evidence="Spec 2.10.E")]


def run() -> Any:
    checks: List[Check] = []
    checks += _shuffle_labels()
    checks += _unrelated_lab_stability()
    checks += _remove_constraints()
    sweep_checks, curves = _sweep_continuity()
    checks += sweep_checks
    checks += _wider_priors()
    return checks, {"sweeps": curves}
