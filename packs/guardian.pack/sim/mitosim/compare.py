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
from dataclasses import dataclass, asdict, field
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from .effects import (ESTIMATED, NEGLIGIBLE, NUMERICALLY_UNRESOLVED,
                      STATUS_MEANINGS)
from .ensemble import run_ensemble, MODEL_VERSION
from .inputs import PersonInputs
from .outputs import RunOutputs
from .params import REGISTRY_VERSION
from .qc import run_qc
from .scenario import Scenario
from .sensitivity import rank_drivers, spearman

UNRESOLVED = "unresolved"

# What counts as a practically negligible paired difference: one per cent of
# the baseline arm's own median for that output. This is a stated convention,
# not a biological threshold, and it is reported alongside every contrast so a
# reader can apply their own. Where the baseline median sits at zero -- the
# ketone fractions do, in ordinary conditions -- the same one per cent is taken
# of the baseline's interquartile range instead, so that a near-zero median
# cannot make an arithmetically tiny difference look meaningful.
NEGLIGIBLE_FRACTION_OF_BASELINE = 0.01

# Above this share of failed members in the target arm the contrast is reported
# as numerically unresolved rather than estimated: the surviving members are a
# biased remnant of the ensemble, not a distribution over it.
FAILURE_FRACTION_UNRESOLVED = 0.25


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
    # Share of paired members whose difference is inside the negligibility
    # band, and the band itself in the output's own unit.
    p_negligible: float = 0.0
    negligible_band: float = 0.0
    # One of the shared effect statuses. It answers a question the direction
    # and the interval cannot: whether a small number here means the model
    # resolved a small effect, could not resolve anything, or has no pathway
    # for the effect at all.
    effect_status: str = ESTIMATED
    effect_status_reason: str = ""
    note: str = ""

    def to_dict(self):
        d = asdict(self)
        d["effect_status_meaning"] = STATUS_MEANINGS.get(self.effect_status, "")
        return d

    def render(self) -> str:
        pc = f" ({self.pct_change:+.1f}%)" if self.pct_change is not None else ""
        if self.effect_status == NEGLIGIBLE:
            return (f"{self.label}: negligible within the model. "
                    f"{self.p_negligible*100:.0f}% of paired samples differ by "
                    f"less than {self.negligible_band:.3g} {self.unit}. "
                    f"{self.effect_status_reason}")
        if self.effect_status != ESTIMATED:
            return (f"{self.label}: {self.effect_status}. "
                    f"{self.effect_status_reason or STATUS_MEANINGS.get(self.effect_status, '')}")
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
    # Present only when the two arms differ by a mechanism counterfactual.
    mechanism_report: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self):
        return {
            "scenario_a": self.scenario_a,
            "scenario_b": self.scenario_b,
            "contrasts": {k: v.to_dict() for k, v in self.contrasts.items()},
            "narrative": self.narrative,
            "metadata": self.metadata,
            "mechanism_report": self.mechanism_report,
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
    ma = {m.mechanism: m.to_dict() for m in a.mechanisms}
    mb = {m.mechanism: m.to_dict() for m in b.mechanisms}
    for name in sorted(set(ma) | set(mb)):
        if ma.get(name) == mb.get(name):
            continue
        if name not in ma:
            d.append(f"mechanism {name} (absent vs "
                     f"{mb[name]['settings']})")
        elif name not in mb:
            d.append(f"mechanism {name} ({ma[name]['settings']} vs absent)")
        else:
            d.append(f"mechanism {name} ({ma[name]['settings']} vs "
                     f"{mb[name]['settings']})")
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


def paired_positions(out_a: RunOutputs,
                     out_b: RunOutputs) -> Tuple[np.ndarray, np.ndarray]:
    """Positions in each arm's arrays that refer to the *same* member.

    Both arms are seeded identically, so member k of one is member k of the
    other -- but only the members that survived integration are kept, and the
    two arms do not necessarily lose the same ones. A depleted NAD pool pushes
    draws into physiological incoherence that the baseline arm survives, and
    from the first such member onward a positional pairing compares two
    different people. Intersecting the surviving indices is what keeps the
    contrast a contrast.

    Falls back to positional truncation only when an arm carries no index,
    which is the case for a ``RunOutputs`` built by hand rather than by
    ``run_ensemble``.
    """
    ia = np.asarray(out_a.member_index, dtype=int)
    ib = np.asarray(out_b.member_index, dtype=int)
    if ia.size == 0 or ib.size == 0:
        m = min(len(next(iter(out_a.member_values.values()), [])),
                len(next(iter(out_b.member_values.values()), [])))
        idx = np.arange(m)
        return idx, idx
    common = np.intersect1d(ia, ib)
    return (np.searchsorted(ia, common).astype(int),
            np.searchsorted(ib, common).astype(int))


def _negligible_band(xa: np.ndarray, median_a: float) -> float:
    """The band inside which a paired difference is called negligible."""
    scale = abs(median_a)
    if scale < 1e-9:
        q75, q25 = np.percentile(xa, [75, 25])
        scale = float(q75 - q25)
    return NEGLIGIBLE_FRACTION_OF_BASELINE * scale


def _mechanism_effect_status(out_a: RunOutputs, out_b: RunOutputs,
                             p_negligible: float) -> Tuple[str, str]:
    """Classify what a contrast between mechanism arms is actually saying.

    The order matters. A mechanism that never applied cannot have produced a
    small effect, and an ensemble that mostly failed has not produced a
    distribution at all. Only when neither of those is true does the size of
    the difference mean anything, and only then may a small number be reported
    as a small effect rather than as an absence of information.

    Both arms are inspected, not just the target: which arm carries the
    mechanism is the caller's choice, and a contrast run the other way round
    -- depleted as A, baseline as B -- must not report a transform that never
    applied as a small effect.
    """
    for out in (out_a, out_b):
        for rec in out.mechanism_assumptions:
            if rec["status"] != ESTIMATED:
                return (rec["status"],
                        f"The '{rec['mechanism']}' transform did not apply: " +
                        (rec["reasons"][0] if rec["reasons"] else
                         STATUS_MEANINGS.get(rec["status"], "")))
    for label, out in (("baseline", out_a), ("target", out_b)):
        n_ok = out.diagnostics.get("n_ok")
        n_failed = out.diagnostics.get("n_failed")
        if n_ok is None or n_failed is None:
            continue
        n_total = n_ok + n_failed
        if n_total and n_failed / n_total > FAILURE_FRACTION_UNRESOLVED:
            return (NUMERICALLY_UNRESOLVED,
                    f"Only {n_ok} of {n_total} members of the {label} arm "
                    "solved to a physiologically coherent state, so the "
                    "surviving members are a biased remnant rather than a "
                    "distribution.")
    if p_negligible >= 0.80:
        # The list of unrepresented paths is stated once, in the mechanism
        # report and the narrative, rather than repeated under every output it
        # applies to. Repeating it here would bury the contrasts in it.
        return (NEGLIGIBLE,
                "The transform was applied and the model resolved it; the "
                "paired effect on this output is inside the stated "
                "negligibility band. Read it with the unrepresented paths "
                "listed in the mechanism report: a null along any of those is "
                "a property of the model, not biological evidence.")
    return (ESTIMATED, "")


def _basis(diffs: List[str], a: Scenario, b: Scenario) -> str:
    if a.mechanisms != b.mechanisms:
        return ("mechanism -- the arms differ by a hypothetical tissue state, "
                "not by anything the person did, took, or was measured to "
                "have; no intervention mapping is implied")
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
    return contrast_runs(a, b, out_a, out_b, keys)


def contrast_runs(a: Scenario, b: Scenario, out_a: RunOutputs,
                  out_b: RunOutputs,
                  keys: Optional[List[str]] = None) -> ComparisonResult:
    """Contrast two runs that were already computed.

    Split out of ``compare`` so that a caller which already has both arms --
    the mechanism validation sweep does, and re-running them would double its
    cost -- can build the contrast without paying for the ensembles twice. The
    two runs must have been seeded identically or the pairing is meaningless,
    which is why this is not part of the public surface in ``__init__``.
    """
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
    mechanism_arms = a.mechanisms != b.mechanisms
    params = None
    pos_a, pos_b = paired_positions(out_a, out_b)

    for key in (keys or DEFAULT_KEYS):
        ea, eb = out_a.get(key), out_b.get(key)
        if ea is None or eb is None:
            continue
        if pos_a.size < 8 or (pos_a.size and
                              (pos_a.max() >= ea.n or pos_b.max() >= eb.n)):
            continue
        xa, xb = np.asarray(ea.samples)[pos_a], np.asarray(eb.samples)[pos_b]
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
        band = _negligible_band(xa, base)
        p_negl = float(np.mean(np.abs(d) <= band)) if band > 0 else 0.0
        if mechanism_arms:
            status, status_why = _mechanism_effect_status(out_a, out_b, p_negl)
        else:
            status, status_why = ESTIMATED, ""

        drivers: List[Dict[str, Any]] = []
        reversers: List[Dict[str, Any]] = []
        if params is None:
            params = _paired_params(out_a, out_b, pos_a, pos_b)
        if params:
            pr = {k: np.asarray(v)[finite] for k, v in params.items()
                  if len(v) == finite.size}
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
            reversers=reversers, p_negligible=p_negl, negligible_band=band,
            effect_status=status, effect_status_reason=status_why,
            note=ea.note)

    mech_report: Dict[str, Any] = {}
    if mechanism_arms:
        mech_report = {
            "paired": True,
            "baseline_arm": {"description": a.describe(),
                             "mechanisms": [m.to_dict() for m in a.mechanisms]},
            "target_arm": {"description": b.describe(),
                           "mechanisms": [m.to_dict() for m in b.mechanisms]},
            "assumptions": out_b.mechanism_assumptions,
            "baseline_assumptions": out_a.mechanism_assumptions,
            "negligibility_rule":
                f"A paired difference within {NEGLIGIBLE_FRACTION_OF_BASELINE:.0%} "
                "of the baseline arm's median for that output is counted "
                "negligible. This is a stated convention, not a biological "
                "threshold.",
            "by_output": {
                k: {"status": c.effect_status,
                    "p_negligible": c.p_negligible,
                    "negligible_band": c.negligible_band,
                    "reason": c.effect_status_reason}
                for k, c in contrasts.items()},
            "status_counts": _status_counts(contrasts),
            "not_an_intervention":
                "Both arms are simulated tissue states. The contrast does not "
                "estimate the effect of any supplement, drug, dose or "
                "behaviour, and no mapping from an intervention to this state "
                "is implied.",
        }

    narrative = build_narrative(a, b, contrasts, diffs, out_a, out_b)
    md = {
        "model_version": MODEL_VERSION,
        "registry_version": REGISTRY_VERSION,
        "n_samples": min(out_a.metadata["n_samples"], out_b.metadata["n_samples"]),
        "paired": True,
        "paired_members": int(pos_a.size),
        "pairing_note": "The two arms use identical draws of the personal "
                        "posterior and of every biochemical parameter, so the "
                        "contrast isolates the scenario difference. Members "
                        "that failed to integrate in either arm are excluded "
                        "from both, so the pairing is by member rather than "
                        "by position.",
        "inputs_that_differ": diffs,
        "conclusion_basis": basis,
        "not_measured": True,
    }
    return ComparisonResult({"description": a.describe(), **a.to_dict()},
                            {"description": b.describe(), **b.to_dict()},
                            contrasts, out_a, out_b, narrative, md,
                            mechanism_report=mech_report)


def _status_counts(contrasts: Dict[str, Contrast]) -> Dict[str, int]:
    counts: Dict[str, int] = {}
    for c in contrasts.values():
        counts[c.effect_status] = counts.get(c.effect_status, 0) + 1
    return counts


def _paired_params(out_a: RunOutputs, out_b: RunOutputs,
                   pos_a: np.ndarray, pos_b: np.ndarray):
    """Per-member parameters shared by both arms, on the paired members only.

    Both ensembles are seeded identically, so the same ensemble member used the
    same personal state and the same biochemical draws in both arms -- but only
    the members that survived in *both* are comparable, which is what pos_a and
    pos_b select. Only the parameters that are genuinely identical across the
    two arms are usable for attributing a contrast; anything the scenario or a
    mechanism itself changes differs by construction and is excluded.
    """
    pa, pb = out_a.member_params, out_b.member_params
    shared: Dict[str, np.ndarray] = {}
    for k, va in pa.items():
        vb = pb.get(k)
        if vb is None or not pos_a.size:
            continue
        if pos_a.max() >= len(va) or pos_b.max() >= len(vb):
            continue
        a, b = np.asarray(va)[pos_a], np.asarray(vb)[pos_b]
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
    negligible = [c for c in ordered if c.effect_status == NEGLIGIBLE]
    blocked = [c for c in ordered
               if c.effect_status not in (ESTIMATED, NEGLIGIBLE)]
    ordered = [c for c in ordered
               if c.effect_status == ESTIMATED]
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
    if negligible:
        bits.append(
            "Negligible within this model: " +
            ", ".join(c.label for c in negligible[:5]) +
            ". The transform was applied and resolved; the paired difference "
            "sat inside the stated negligibility band. That is a statement "
            "about this model, not evidence that the biology is inert.")
    if blocked:
        bits.append(
            "Not estimated here: " +
            ", ".join(f"{c.label} ({c.effect_status})" for c in blocked[:5]) +
            ". " + (blocked[0].effect_status_reason or ""))
    if a.mechanisms != b.mechanisms:
        unrep = [pth for rec in out_b.mechanism_assumptions
                 for pth in rec["unrepresented_paths"]]
        if unrep:
            bits.append("Paths this model does not represent, along which any "
                        "real effect would be invisible here: " +
                        "; ".join(unrep) + ".")
        bits.append("Both arms are simulated tissue states. No intervention, "
                    "dose or behaviour is implied by either of them.")
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
    if res.mechanism_report:
        lines.append("Mechanism contrast: the arms differ by a hypothetical "
                     "tissue state.")
        for rec in res.mechanism_report["assumptions"]:
            settings = ", ".join(f"{k}={v}" for k, v in
                                 sorted(rec["settings"].items())) or "defaults"
            lines.append(f"  {rec['mechanism']} [{settings}] -> "
                         f"{rec['status']}; changed "
                         f"{', '.join(rec['changed_parameters']) or 'nothing'}")
            lines.append(f"      NOT in the model: " +
                         "; ".join(rec["unrepresented_paths"]))
            lines.append(f"      {rec['mapping_note']}")
        lines.append("  " + res.mechanism_report["negligibility_rule"])
        lines.append("")
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
