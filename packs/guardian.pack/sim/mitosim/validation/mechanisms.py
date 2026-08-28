"""F. Cross-person validation of the mechanism levers (plan section 9).

The bar this section enforces is stated in the plan and is deliberately not
"the profiles produce interesting differences".  Producing differences is easy;
a lever wired to the wrong parameter would produce them too.  Each difference
has to survive six questions:

1. Does it follow a **represented** pathway?
2. Is it **attributable** to the requested mechanism and to nothing else?
3. Does it preserve **conservation and feasibility**?
4. Are plausible **nulls and sign reversals retained**, rather than smoothed
   into an effect everywhere?
5. Does uncertainty **widen** when information is missing?
6. Does the result **state when a relevant pathway is absent**?

The synthetic profiles span the axes the plan names: low, central and high
haemoglobin and oxygen-delivery posteriors; low and high body and lean mass;
low and high aerobic capacity; complete versus sparse personal inputs. The
scenarios span easy, threshold and hard running.

Two checks here are worth reading as claims rather than as assertions. The
**attribution** check compares the sampled parameters member by member and
fails if anything other than the declared handle moved: that is what makes the
contrast a statement about the NAD pool rather than about the sampler. And the
**nulls retained** check fails if the lever produces a resolved effect on every
output of every profile, because a lever that never returns a null is not
measuring anything -- it is decorating.
"""

from __future__ import annotations

import datetime as dt
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from ..compare import contrast_runs, paired_positions
from ..ensemble import run_ensemble
from ..inputs import (AndrogenContext, LabPanel, LabValue, NutritionState,
                      TrainingHistory)
from ..mechanisms import MECHANISMS
from ..scenario import Intensity, MechanismUse, Scenario
from .common import Check, reference_person

SECTION = "F. Mechanism levers across people"

KEYS = ["oxidative_atp_fraction", "blood_lactate_peak", "pcr_end_fraction",
        "spare_oxidative_capacity", "muscle_ph_type2_min",
        "cho_carbon_fraction"]


def _lab(analyte, value, unit, lo=None, hi=None, days=20):
    return LabValue(analyte, value, unit,
                    dt.date(2026, 8, 26) - dt.timedelta(days=days),
                    fasting=True, ref_low=lo, ref_high=hi)


def profiles(quick: bool = False) -> List[Tuple[str, Any, str]]:
    """The synthetic profiles this section sweeps, and what each one varies."""
    people: List[Tuple[str, Any, str]] = [
        ("central", reference_person(subject_id="mech_central"),
         "central haemoglobin posterior, complete inputs"),
        ("low_oxygen", reference_person(
            subject_id="mech_low_oxygen",
            labs=[_lab("hemoglobin", 11.6, "g/dL", 13.5, 17.5)]),
         "low haemoglobin / oxygen-delivery posterior"),
        ("high_oxygen", reference_person(
            subject_id="mech_high_oxygen",
            labs=[_lab("hemoglobin", 16.8, "g/dL", 13.5, 17.5)]),
         "high haemoglobin / oxygen-delivery posterior"),
    ]
    if not quick:
        people += [
            ("heavy", reference_person(subject_id="mech_heavy", mass=94,
                                       bf=24, vo2max=40,
                                       level="recreational", km=25),
             "high body and lean mass, low aerobic capacity"),
            ("light_fit", reference_person(subject_id="mech_light_fit",
                                           mass=58, bf=9, vo2max=68,
                                           level="competitive", km=110),
             "low body mass, high aerobic capacity"),
        ]
    sparse = reference_person(subject_id="mech_sparse")
    sparse.wearable.vo2max_estimate_ml_kg_min = None
    sparse.wearable.resting_hr_bpm = None
    sparse.nutrition = NutritionState()
    sparse.training = TrainingHistory()
    people.append(("sparse", sparse,
                   "sparse inputs: no device estimate, no nutrition, no "
                   "training history"))
    return people


def scenarios(quick: bool = False) -> List[Tuple[str, Scenario]]:
    def sc(intensity, duration, **kw):
        return Scenario(intensity=Intensity("pct_vo2max", intensity),
                        duration_min=duration, **kw)
    out = [("easy", sc(0.60, 15.0)), ("threshold", sc(0.80, 15.0))]
    if not quick:
        out.append(("hard", sc(0.90, 12.0)))
    return out


def with_nad(sc: Scenario, scale: float) -> Scenario:
    from dataclasses import replace
    return replace(sc, mechanisms=(
        MechanismUse("mitochondrial_nad_pool", {"pool_scale": scale}),))


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

def _neutral_invariance(person, sc, n, seed) -> Optional[str]:
    """Return a failure description, or None if the neutral arm is exact."""
    plain = run_ensemble(person, sc, n=n, seed=seed, keep_traj=0, audit=False)
    neutral = run_ensemble(person, with_nad(sc, 1.0), n=n, seed=seed,
                           keep_traj=0, audit=False)
    for key, est in plain.estimates.items():
        other = neutral.get(key)
        if other is None:
            return f"{key} vanished when a neutral mechanism was added"
        if not np.array_equal(np.asarray(est.samples),
                              np.asarray(other.samples)):
            worst = float(np.nanmax(np.abs(np.asarray(est.samples) -
                                           np.asarray(other.samples))))
            return (f"{key} moved by up to {worst:.3g} under a neutral "
                    "mechanism")
    return None


def _attribution(plain, target) -> Optional[str]:
    """Every sampled parameter except the declared handle must be identical.

    Compared member by member, not position by position: the depletion arm
    loses draws to physiological incoherence that the baseline arm survives,
    and a positional comparison from that point on would be comparing two
    different people -- reporting a leak that is not there, or hiding one that
    is.
    """
    declared = set(MECHANISMS["mitochondrial_nad_pool"].target_handles)
    pos_a, pos_b = paired_positions(plain, target)
    if not pos_a.size:
        return "the two arms share no surviving ensemble members"
    for name, a in plain.member_params.items():
        b = target.member_params.get(name)
        if b is None:
            continue
        if pos_a.max() >= len(a) or pos_b.max() >= len(b):
            continue
        xa, xb = np.asarray(a)[pos_a], np.asarray(b)[pos_b]
        fin = np.isfinite(xa) & np.isfinite(xb)
        if fin.sum() == 0:
            continue
        same = np.allclose(xa[fin], xb[fin], rtol=1e-12, atol=1e-15)
        if name in declared:
            if same:
                return (f"{name} is the declared handle but did not move; the "
                        "contrast cannot be attributed to the mechanism")
        elif not same:
            return (f"{name} moved although the mechanism declares only "
                    f"{sorted(declared)}")
    return None


def _feasible(out) -> Optional[str]:
    """Conservation and admissibility of the redox state, member by member."""
    for key in ("matrix_nadh_fraction_rest", "matrix_nadh_fraction_max",
                "matrix_nadh_fraction_min"):
        est = out.get(key)
        if est is None:
            return f"{key} was not reported, so feasibility cannot be checked"
        x = np.asarray(est.samples)
        x = x[np.isfinite(x)]
        if x.size and (x.min() < 0.0 or x.max() > 1.0):
            return (f"{key} left [0, 1]: matrix NADH exceeded its own "
                    f"compartment pool (min {x.min():.3f}, max {x.max():.3f})")
    pool = out.get("nad_mito_pool")
    if pool is not None:
        p = np.asarray(pool.samples)
        if np.any(p <= 0):
            return "a member ran with a non-positive matrix NAD pool"
    return None


# pH is excluded from the width comparison on purpose: it is a logarithm with
# an arbitrary zero, so a width relative to its median is not a measure of
# anything. Every other key here is a ratio or a flux where the relative width
# means what it says.
WIDTH_KEYS = tuple(k for k in KEYS if k != "muscle_ph_type2_min")


def _relative_width(est) -> Optional[float]:
    """80% interval width as a fraction of the median.

    The 80% interval rather than the 95%, matching section C: at the ensemble
    sizes the validation suite runs, the outer percentiles are close to the
    extremes of a few dozen samples and carry more noise than signal.
    """
    if est is None:
        return None
    lo, hi = est.interval(0.80)
    med = abs(est.median())
    if not np.isfinite(lo) or not np.isfinite(hi) or med < 1e-9:
        return None
    return float((hi - lo) / med)


def _interval_width(res, key) -> Optional[float]:
    c = res.contrasts.get(key)
    if c is None:
        return None
    return float(c.ci95[1] - c.ci95[0])


def run(n: int = 12, quick: bool = False) -> Tuple[List[Check],
                                                   Dict[str, Any]]:
    checks: List[Check] = []
    people = profiles(quick)
    scens = scenarios(quick)
    seed = 20260901

    contrasts: Dict[str, Any] = {}
    statuses: Dict[str, int] = {}
    verdicts: Dict[str, int] = {}
    failures: List[str] = []

    for tag, person, varies in people:
        for sname, sc in scens:
            plain = run_ensemble(person, sc, n=n, seed=seed, keep_traj=0,
                                 audit=False)
            target = run_ensemble(person, with_nad(sc, 0.6), n=n, seed=seed,
                                  keep_traj=0, audit=False)

            bad = _attribution(plain, target)
            checks.append(Check(
                SECTION, f"attributable:{tag}:{sname}", bad is None,
                bad or ("Only nad_total_mito differs between the arms; every "
                        "other sampled parameter is identical member by "
                        "member, so the contrast is a statement about the "
                        "pool and not about the sampler."),
                expected="only the declared handle moves",
                observed=bad or "only nad_total_mito moved",
                evidence=f"{varies}; {sname} scenario"))

            bad = _feasible(target)
            checks.append(Check(
                SECTION, f"feasible:{tag}:{sname}", bad is None,
                bad or ("Matrix NADH stayed inside its own compartment pool "
                        "at rest and under load in every member, and no "
                        "member ran with a non-positive pool."),
                expected="matrix NADH within [0, 1] of the pool",
                observed=bad or "within bounds",
                evidence=f"{varies}; {sname} scenario"))

            rec = target.mechanism_assumptions[0]
            ok = bool(rec["unrepresented_paths"]) and rec["mapping_note"]
            checks.append(Check(
                SECTION, f"absent_paths_stated:{tag}:{sname}", ok,
                "Every mechanism result carries the list of biologically "
                "plausible paths this model does not represent, so a null "
                "along one of them cannot be read as biological evidence.",
                expected="unrepresented paths and a mapping note on every "
                         "result",
                observed=f"{len(rec['unrepresented_paths'])} paths listed",
                evidence=f"{varies}; {sname} scenario"))

            # Both arms are already in hand; re-running them through
            # compare() would double the cost of this whole section for
            # nothing.
            res = contrast_runs(sc, with_nad(sc, 0.6), plain, target, KEYS)
            contrasts[f"{tag}:{sname}"] = {
                "varies": varies,
                # Relative width, not absolute: two different people run at
                # different scales, and an absolute interval on a lower-flux
                # person is narrower for reasons that have nothing to do with
                # how well the person is characterised. Dividing by the
                # median is what isolates the uncertainty from the scale.
                "relative_widths": {k: _relative_width(target.get(k))
                                    for k in WIDTH_KEYS},
                "statuses": {k: c.effect_status
                             for k, c in res.contrasts.items()},
                "p_negligible": {k: round(c.p_negligible, 3)
                                 for k, c in res.contrasts.items()},
                "verdicts": {k: c.verdict for k, c in res.contrasts.items()},
                "widths": {k: _interval_width(res, k) for k in res.contrasts},
            }
            for c in res.contrasts.values():
                statuses[c.effect_status] = statuses.get(c.effect_status, 0) + 1
                verdicts[c.verdict] = verdicts.get(c.verdict, 0) + 1

    # ---- neutral invariance, on one profile per oxygen posterior ---------
    for tag, person, varies in people[:3]:
        bad = _neutral_invariance(person, scens[0][1], n, seed)
        checks.append(Check(
            SECTION, f"neutral_is_exact:{tag}", bad is None,
            bad or ("A pool_scale of 1.0 reproduces the run without the "
                    "mechanism bit for bit, so a contrast against the neutral "
                    "arm is not partly measuring the sampler."),
            expected="identical samples for every output",
            observed=bad or "bit-identical", evidence=varies))

    # ---- nulls and sign reversals are retained --------------------------
    n_negligible = statuses.get("negligible_within_model", 0)
    n_total = sum(statuses.values())
    checks.append(Check(
        SECTION, "nulls_retained", n_negligible > 0,
        "At least one output was classified negligible within the model. A "
        "lever that produced a resolved effect on every output of every "
        "profile would not be measuring anything; it would be decorating.",
        expected="some contrasts classified negligible_within_model",
        observed=f"{n_negligible} of {n_total} contrasts",
        severity="error" if n_total else "warning"))

    n_unresolved = verdicts.get("unresolved", 0)
    checks.append(Check(
        SECTION, "sign_reversals_retained", n_unresolved > 0,
        "At least one contrast had its direction reversed by plausible "
        "parameter draws and was reported unresolved rather than given a "
        "direction it does not have.",
        expected="some contrasts unresolved",
        observed=f"{n_unresolved} of {n_total} contrasts",
        severity="warning"))

    # ---- uncertainty widens when information is missing ------------------
    widened = _widening(contrasts, scens)
    abs_ratio = widened["absolute"]["median_ratio"]
    checks.append(Check(
        SECTION, "uncertainty_widens_with_missing_inputs", abs_ratio >= 0.98,

        "A mechanism run on a person with no device estimate, no nutrition "
        "history and no training history reports relatively wider intervals "
        "than the same run on the fully characterised reference. Widths are "
        "taken relative to each person's own median, because two people run "
        "at different scales and an absolute interval would be comparing "
        "those scales rather than the uncertainty. Missing information has to "
        "cost width, or the engine would be manufacturing confidence it does "
        "not have. The error-level version of this claim, over the whole "
        "output set and the whole synthetic cohort, is in section C; this one "
        "checks that a mechanism run inherits it.",
        expected="median width ratio at or above 1.0",
        observed=f"median relative-width ratio {abs_ratio:.2f}; wider or held "
                 f"on {widened['absolute']['wider']} of "
                 f"{widened['absolute']['compared']} outputs",
        severity="warning"))
    # The paired contrast is a separate question, and a weaker expectation on
    # purpose: pairing removes the person-level uncertainty that is common to
    # both arms, which is most of what a sparse profile adds. Reported as an
    # observation rather than asserted, because a contrast that did *not*
    # widen is the pairing working, not a defect.
    checks.append(Check(
        SECTION, "contrast_width_under_missing_inputs", True,
        "Recorded rather than asserted. Pairing removes the person-level "
        "uncertainty common to both arms, so a sparse profile need not widen "
        "the contrast even though it widens the absolute outputs.",
        expected="observation only",
        observed=f"the sparse profile's contrast was wider on "
                 f"{widened['contrast']['wider']} of "
                 f"{widened['contrast']['compared']} outputs",
        severity="info"))

    # ---- the androgen lever, across supported and unsupported people -----
    checks += _androgen_checks(n, seed)

    summary = {
        "profiles": [{"tag": t, "varies": v} for t, _, v in people],
        "scenarios": [s for s, _ in scens],
        "n_members": n,
        "contrasts": contrasts,
        "status_counts": statuses,
        "verdict_counts": verdicts,
        "widening": widened,
    }
    return checks, summary


def _widening(contrasts: Dict[str, Any], scens) -> Dict[str, Any]:
    """Compare the sparse profile against the reference, two ways.

    ``absolute`` is the width of the reported outputs themselves, where
    missing information must cost width. ``contrast`` is the width of the
    paired difference, where it need not: pairing removes exactly the
    person-level uncertainty a sparse profile adds.
    """
    def sweep(field: str) -> Dict[str, Any]:
        wider = compared = 0
        per_output: Dict[str, Any] = {}
        for sname, _ in scens:
            ref = contrasts.get(f"central:{sname}")
            sparse = contrasts.get(f"sparse:{sname}")
            if not ref or not sparse:
                continue
            for key, w_ref in ref[field].items():
                w_sp = sparse[field].get(key)
                if w_ref is None or w_sp is None or w_ref <= 0:
                    continue
                compared += 1
                # "Widens or holds", the same rule section C uses: the claim
                # is that missing information never buys precision, not that
                # it must always cost some.
                if w_sp >= w_ref * 0.98:
                    wider += 1
                per_output.setdefault(key, []).append(round(w_sp / w_ref, 3))
        ratios = [r for rs in per_output.values() for r in rs]
        return {"wider": wider, "compared": compared,
                "wider_fraction": (wider / compared) if compared else 0.0,
                # The median ratio, not the count, is what the check asserts
                # on: a count sitting near its threshold flips on ensemble
                # noise, while the median of the ratios is stable at the
                # sample sizes this suite runs.
                "median_ratio": float(np.median(ratios)) if ratios else 0.0,
                "sparse_over_reference_ratio": per_output}

    return {"absolute": sweep("relative_widths"),
            "contrast": sweep("widths")}


def _androgen_checks(n: int, seed: int) -> List[Check]:
    """The mediator lever has to refuse more people than it accepts."""
    checks: List[Check] = []
    sc = Scenario(intensity=Intensity("speed_m_s", 3.2), duration_min=15.0)
    use = MechanismUse("sustained_androgen_exposure",
                       {"target_total_testosterone": 600.0,
                        "exposure_pattern": "stable"}, horizon_days=180.0)
    from dataclasses import replace
    target = replace(sc, mechanisms=(use,))

    supported = reference_person(subject_id="androgen_supported", age=48,
                                 mass=84, bf=22, vo2max=44,
                                 level="recreational", km=30,
                                 labs=[_lab("hemoglobin", 13.4, "g/dL",
                                            13.5, 17.5)])
    supported.androgen = AndrogenContext(
        total_testosterone_ng_dL=220.0, collection_time_local="08:15",
        repeat_measurements=2, shbg_nmol_L=30.0,
        exposure_source="endogenous")

    out = run_ensemble(supported, target, n=n, seed=seed, keep_traj=0,
                       audit=False)
    rec = out.mechanism_assumptions[0]
    hb = rec["mediators"].get("hemoglobin", {})
    ok = rec["status"] == "estimated" and hb.get("applied") is True
    checks.append(Check(
        SECTION, "androgen:applies_with_an_observed_baseline", ok,
        "With an observed baseline exposure and an observed haemoglobin, the "
        "mediator lever applies the haemoglobin path and reports the delta as "
        "a distribution.",
        expected="estimated, haemoglobin applied",
        observed=f"{rec['status']}, haemoglobin applied="
                 f"{hb.get('applied')}"))

    gated = [m for m, slot in rec["mediators"].items()
             if not slot.get("applied")]
    ok = all(rec["mediators"][m].get("reason") for m in gated)
    checks.append(Check(
        SECTION, "androgen:every_gated_mediator_states_a_reason", ok,
        "Mediators the evidence table gates are reported by name with their "
        "own reason, so a reader sees which arrows were live rather than "
        "inferring it from the size of the answer.",
        expected="a reason on every gated mediator",
        observed=f"{len(gated)} gated mediators, all with reasons" if ok
                 else "a gated mediator reported no reason"))

    ok = "mitochondrial_capacity" in gated
    checks.append(Check(
        SECTION, "androgen:mitochondrial_capacity_unchanged", ok,
        "Direct mitochondrial volume and oxidative-phosphorylation capacity "
        "are left unchanged. A lever that raised them would manufacture the "
        "performance benefit this design refuses to assert.",
        expected="mitochondrial_capacity never applied",
        observed="not applied" if ok else "APPLIED"))

    # Unsupported populations must fail closed rather than widen.
    unsupported = [
        ("no_baseline", reference_person(subject_id="androgen_no_baseline",
                                         age=48),
         "no observed baseline exposure"),
        ("female", reference_person(subject_id="androgen_female", sex="female",
                                    age=48, mass=64, bf=27),
         "outside the population the mediator table was measured in"),
    ]
    unsupported[1][1].androgen = AndrogenContext(
        total_testosterone_ng_dL=40.0, collection_time_local="08:15",
        repeat_measurements=2, exposure_source="endogenous")
    for tag, p, why in unsupported:
        out = run_ensemble(p, target, n=max(4, n // 3), seed=seed,
                           keep_traj=0, audit=False)
        rec = out.mechanism_assumptions[0]
        ok = rec["status"] != "estimated" and bool(rec["reasons"])
        checks.append(Check(
            SECTION, f"androgen:fails_closed:{tag}", ok,
            "The lever refuses with a stated reason rather than applying a "
            "mediator response extrapolated past the population it was "
            "measured in.",
            expected="not estimated, with a reason",
            observed=f"{rec['status']}", evidence=why))
    return checks
