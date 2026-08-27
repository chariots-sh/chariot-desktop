"""Scenario contrasts -- the primary unit of product value (spec 3.3).

    "How might the mechanism differ between scenario A and scenario B for this
     person?"

Each comparison returns median change, 80% and 95% intervals, the probability
the change has the displayed direction, which inputs caused it, which unmeasured
parameters could reverse it, whether the conclusion is personal,
population-derived or experimental, and evidence/support labels.

Crucially, the two scenarios are run on the *same* draws of the personal
posterior.  Pairing the samples removes the person-level uncertainty that is
common to both arms, which is what makes a contrast far better resolved than
either absolute number -- and it is also why an unpaired implementation would
declare almost every real difference "unresolved".
"""

from __future__ import annotations

import math
from dataclasses import dataclass, asdict
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from .ensemble import run_ensemble, MODEL_VERSION
from .inputs import PersonInputs
from .outputs import RunOutputs
from .params import REGISTRY_VERSION
from .qc import run_qc
from .scenario import Scenario
from .sensitivity import rank_drivers, spearman

UNRESOLVED = "unresolved"


@dataclass
class Contrast:
    key: str
    label: str
    unit: str
    median_a: float
    median_b: float
    median_change: float
    pct_change: Optional[float]
    ci80: Tuple[float, float]
    ci95: Tuple[float, float]
    p_direction: float
    direction: str
    verdict: str
    conclusion_basis: str
    support: str
    drivers: List[Dict[str, Any]]
    reversers: List[Dict[str, Any]]
    note: str = ""

    def to_dict(self):
        return asdict(self)

    def render(self) -> str:
        pc = f" ({self.pct_change:+.1f}%)" if self.pct_change is not None else ""
        if self.verdict == UNRESOLVED:
            return (f"{self.label}: UNRESOLVED. Median change "
                    f"{self.median_change:+.3g} {self.unit}{pc}, but plausible "
                    f"parameter samples reverse the direction "
                    f"(P(direction) = {self.p_direction:.2f}).")
        return (f"{self.label}: {self.median_change:+.3g} {self.unit}{pc} "
                f"[80% {self.ci80[0]:+.3g} to {self.ci80[1]:+.3g}; "
                f"95% {self.ci95[0]:+.3g} to {self.ci95[1]:+.3g}], "
                f"P({self.direction}) = {self.p_direction:.2f} "
                f"(simulated; basis: {self.conclusion_basis}; "
                f"support: {self.support})")


@dataclass
class ComparisonResult:
    scenario_a: Dict[str, Any]
    scenario_b: Dict[str, Any]
    contrasts: Dict[str, Contrast]
    a: RunOutputs
    b: RunOutputs
    narrative: str
    metadata: Dict[str, Any]

    def to_dict(self):
        return {
            "scenario_a": self.scenario_a,
            "scenario_b": self.scenario_b,
            "contrasts": {k: v.to_dict() for k, v in self.contrasts.items()},
            "narrative": self.narrative,
            "metadata": self.metadata,
            "a": self.a.to_dict(),
            "b": self.b.to_dict(),
        }


# Which inputs differ between two scenarios, in user-facing language.
def scenario_diff(a: Scenario, b: Scenario) -> List[str]:
    d = []
    if a.pattern != b.pattern:
        d.append(f"session pattern ({a.pattern} vs {b.pattern})")
    if a.intensity != b.intensity:
        d.append(f"intensity ({a.intensity.kind} {a.intensity.value} vs "
                 f"{b.intensity.value})")
    if a.grade_pct != b.grade_pct:
        d.append(f"gradient ({a.grade_pct:+.1f}% vs {b.grade_pct:+.1f}%)")
    if a.duration_min != b.duration_min:
        d.append(f"duration ({a.duration_min:.0f} vs {b.duration_min:.0f} min)")
    if a.hours_since_meal != b.hours_since_meal:
        d.append(f"time since last meal ({a.hours_since_meal:.0f} vs "
                 f"{b.hours_since_meal:.0f} h)")
    if a.pre_run_cho_g != b.pre_run_cho_g:
        d.append(f"pre-run carbohydrate ({a.pre_run_cho_g:.0f} vs "
                 f"{b.pre_run_cho_g:.0f} g)")
    if a.prev_day_cho != b.prev_day_cho:
        d.append(f"previous-day carbohydrate ({a.prev_day_cho} vs "
                 f"{b.prev_day_cho})")
    if a.glycogen_prior != b.glycogen_prior:
        d.append(f"initial glycogen prior ({a.glycogen_prior} vs "
                 f"{b.glycogen_prior})")
    if a.elevation_m != b.elevation_m:
        d.append(f"elevation ({a.elevation_m:.0f} vs {b.elevation_m:.0f} m)")
    ea = {e.adapter for e in a.experimental}
    eb = {e.adapter for e in b.experimental}
    if ea != eb:
        d.append("experimental inputs (" +
                 (", ".join(sorted(ea)) or "none") + " vs " +
                 (", ".join(sorted(eb)) or "none") + ")")
    return d


DEFAULT_KEYS = [
    "oxidative_atp_fraction", "glycolytic_atp_fraction",
    "nonoxidative_atp_fraction", "cho_carbon_fraction", "fat_carbon_fraction",
    "fat_g_per_min", "cho_g_per_min", "glycogen_used", "glycogen_remaining",
    "blood_lactate_peak", "muscle_ph_type2_min", "pcr_end_fraction",
    "spare_oxidative_capacity", "muscle_vo2", "atp_coverage",
    "time_to_glycogen_limit", "atp_per_oxygen", "type2_atp_share",
]


def _basis(diffs: List[str], a: Scenario, b: Scenario) -> str:
    if any(e for e in (a.experimental, b.experimental)):
        return ("experimental -- at least one arm uses an evidence-adapter "
                "whose effect size is itself uncertain")
    personal = {"time since last meal", "previous-day carbohydrate",
                "initial glycogen prior"}
    if any(any(p in d for p in personal) for d in diffs):
        return ("personal -- the difference runs through this person's "
                "estimated fuel state, which is inferred rather than measured")
    return ("population-derived -- the difference runs through the "
            "population running-demand and muscle model rather than through "
            "anything specific to this person")


def compare(person: PersonInputs, a: Scenario, b: Scenario, n: int = 200,
            seed: int = 20260826, keys: Optional[List[str]] = None,
            workers: Optional[int] = None) -> ComparisonResult:
    qc = run_qc(person)
    # Same seed for both arms: the k-th member of each ensemble uses the same
    # draw of the personal posterior and the same biochemical parameter set.
    out_a = run_ensemble(person, a, n=n, seed=seed, qc=qc, workers=workers)
    out_b = run_ensemble(person, b, n=n, seed=seed, qc=qc, workers=workers)

    contrasts: Dict[str, Contrast] = {}
    if not out_a.estimates or not out_b.estimates:
        return ComparisonResult(
            {"description": a.describe()}, {"description": b.describe()},
            contrasts, out_a, out_b,
            "No contrast is estimable: at least one scenario produced no "
            "output. See the warnings on each arm.",
            {"model_version": MODEL_VERSION, "blocked": True})

    diffs = scenario_diff(a, b)
    basis = _basis(diffs, a, b)
    params = None

    for key in (keys or DEFAULT_KEYS):
        ea, eb = out_a.get(key), out_b.get(key)
        if ea is None or eb is None:
            continue
        m = min(ea.n, eb.n)
        if m < 8:
            continue
        xa, xb = np.asarray(ea.samples)[:m], np.asarray(eb.samples)[:m]
        d = xb - xa
        finite = np.isfinite(d)
        d = d[finite]
        if d.size < 8:
            continue
        med = float(np.median(d))
        direction = "increase" if med > 0 else "decrease"
        p_dir = float(np.mean(d > 0) if med > 0 else np.mean(d < 0))
        ci80 = (float(np.percentile(d, 10)), float(np.percentile(d, 90)))
        ci95 = (float(np.percentile(d, 2.5)), float(np.percentile(d, 97.5)))
        base = float(np.median(xa))
        pct = (med / base * 100.0) if abs(base) > 1e-12 else None
        verdict = UNRESOLVED if p_dir < 0.80 else "resolved"

        drivers: List[Dict[str, Any]] = []
        reversers: List[Dict[str, Any]] = []
        if params is None:
            params = _paired_params(out_a, out_b, m)
        if params:
            pr = {k: np.asarray(v)[:finite.size][finite]
                  for k, v in params.items()
                  if len(v) >= finite.size}
            try:
                ranked = rank_drivers(pr, d, top=6)
            except Exception:
                ranked = []
            drivers = ranked
            # A reverser is a parameter whose extremes flip the sign of d.
            for item in ranked:
                nm = item["parameter"]
                pv = pr.get(nm)
                if pv is None or pv.size != d.size:
                    continue
                lo = d[pv <= np.percentile(pv, 20)]
                hi = d[pv >= np.percentile(pv, 80)]
                if lo.size < 4 or hi.size < 4:
                    continue
                if np.sign(np.median(lo)) != np.sign(np.median(hi)) and \
                        np.sign(np.median(lo)) != 0:
                    reversers.append({
                        "parameter": nm,
                        "low_quintile_median": float(np.median(lo)),
                        "high_quintile_median": float(np.median(hi)),
                        "note": "Plausible values of this parameter reverse the "
                                "direction of the contrast.",
                        "support": item.get("support", "assumed"),
                    })
        support = ea.support if ea.support == eb.support else \
            f"{ea.support}/{eb.support}"
        contrasts[key] = Contrast(
            key=key, label=ea.label, unit=ea.unit,
            median_a=float(np.median(xa)), median_b=float(np.median(xb)),
            median_change=med, pct_change=pct, ci80=ci80, ci95=ci95,
            p_direction=p_dir, direction=direction, verdict=verdict,
            conclusion_basis=basis, support=support, drivers=drivers,
            reversers=reversers, note=ea.note)

    narrative = build_narrative(a, b, contrasts, diffs, out_a, out_b)
    md = {
        "model_version": MODEL_VERSION,
        "registry_version": REGISTRY_VERSION,
        "n_samples": min(out_a.metadata["n_samples"], out_b.metadata["n_samples"]),
        "paired": True,
        "pairing_note": "The two arms use identical draws of the personal "
                        "posterior and of every biochemical parameter, so the "
                        "contrast isolates the scenario difference.",
        "inputs_that_differ": diffs,
        "conclusion_basis": basis,
        "not_measured": True,
    }
    return ComparisonResult({"description": a.describe(), **a.to_dict()},
                            {"description": b.describe(), **b.to_dict()},
                            contrasts, out_a, out_b, narrative, md)


def _paired_params(out_a: RunOutputs, out_b: RunOutputs, m: int):
    """Per-member parameters shared by both arms.

    Both ensembles are seeded identically, so member k of arm A and member k of
    arm B used the same personal state and the same biochemical draws. Only the
    parameters that are genuinely identical across the two arms are usable for
    attributing a contrast; anything the scenario itself changes (initial fuel
    state, oxygen environment) differs by construction and is excluded.
    """
    pa, pb = out_a.member_params, out_b.member_params
    shared: Dict[str, np.ndarray] = {}
    for k, va in pa.items():
        vb = pb.get(k)
        if vb is None or len(va) < m or len(vb) < m:
            continue
        a, b = np.asarray(va)[:m], np.asarray(vb)[:m]
        fin = np.isfinite(a) & np.isfinite(b)
        if fin.sum() < 8:
            continue
        if np.allclose(a[fin], b[fin], rtol=1e-9, atol=1e-12):
            shared[k] = a
    return shared


def build_narrative(a: Scenario, b: Scenario, contrasts: Dict[str, Contrast],
                    diffs: List[str], out_a: RunOutputs,
                    out_b: RunOutputs) -> str:
    if not contrasts:
        return "No contrast could be computed."
    bits: List[str] = []
    bits.append(f"Compared with {a.describe()}, the scenario "
                f"{b.describe()} differs in: " +
                (", ".join(diffs) if diffs else "nothing") + ".")
    ordered = sorted(contrasts.values(),
                     key=lambda c: -(abs(c.pct_change or 0)
                                     if c.verdict != UNRESOLVED else 0))
    resolved = [c for c in ordered if c.verdict != UNRESOLVED]
    unresolved = [c for c in ordered if c.verdict == UNRESOLVED]
    for c in resolved[:4]:
        arrow = "rises" if c.median_change > 0 else "falls"
        pc = f" by {abs(c.pct_change):.0f}%" if c.pct_change is not None else ""
        bits.append(f"{c.label} {arrow}{pc} "
                    f"(median {c.median_b:.3g} vs {c.median_a:.3g} {c.unit}; "
                    f"the direction holds in {c.p_direction*100:.0f}% of "
                    "plausible parameter samples).")
    if unresolved:
        bits.append("Unresolved in this comparison: " +
                    ", ".join(c.label for c in unresolved[:5]) +
                    ". Plausible parameter samples reverse the direction, so "
                    "the engine does not claim one.")
    cov = contrasts.get("atp_coverage")
    if cov is not None and cov.median_b < 0.98:
        bits.append("ATP demand is not fully covered in the second scenario "
                    "across the sampled states, so it may not be completable "
                    "as specified.")
    bits.append("All values are simulated mechanisms consistent with the model "
                "and the supplied observations. None of them is a measurement "
                "of this person's mitochondria.")
    return " ".join(bits)


def render_comparison(res: ComparisonResult) -> str:
    lines = ["=" * 78, "SCENARIO CONTRAST (simulated)", "=" * 78,
             f"A: {res.scenario_a['description']}",
             f"B: {res.scenario_b['description']}",
             f"Paired ensemble of {res.metadata.get('n_samples')} personal "
             "states per arm.",
             f"Conclusion basis: {res.metadata.get('conclusion_basis')}", ""]
    for c in res.contrasts.values():
        lines.append("  " + c.render())
        if c.drivers:
            lines.append("      driven by: " +
                         ", ".join(f"{d['parameter']} ({d['direction']})"
                                   for d in c.drivers[:4]))
        if c.reversers:
            lines.append("      could be reversed by: " +
                         ", ".join(r["parameter"] for r in c.reversers[:3]))
    lines += ["", "-" * 78, "Narrative", "-" * 78, res.narrative]
    return "\n".join(lines)
