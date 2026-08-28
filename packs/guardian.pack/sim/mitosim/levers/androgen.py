"""Sustained androgen exposure, through mediators the engine can actually use.

The question this lever answers:

    If sustained androgen exposure produced the specified chronic changes in
    supported mediators, how would those mediator changes affect the
    running-energy model?

It does not claim that a serum testosterone target deterministically produces a
particular mediator response, and it converts nothing into a dose.  The chain
it represents is exposure -> mediator -> energetics, and only the second arrow
is modelled here; the first is a versioned evidence table with its own domain,
and the step from any treatment to an exposure is not represented at all.

**Baseline and target semantics.**  Observed values set the *baseline* arm.
Modelled deltas change the *target* arm.  Those are different jobs and
conflating them is the mistake this lever is built to avoid:

    baseline mediator = the observed baseline value when there is one
    target mediator   = observed baseline + sampled target delta

A measured baseline stops the baseline arm being invented; it does not suppress
the target-arm delta.  And where a *follow-up* mediator has actually been
measured, that measurement replaces the sampled target value outright, because
a measurement beats a model.

**The tradeoff is the point.**  Higher haemoglobin raises the modelled oxygen
ceiling.  More active mass means more tissue sharing that oxygen and a higher
metabolic cost of running at the same pace.  The engine applies both and
reports where they land; it does not add a performance multiplier on top, and
at a fixed pace the net result may be small, mixed, or unfavourable.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from ..effects import (ESTIMATED, NEGLIGIBLE, NOT_ESTIMABLE, OUTSIDE_DOMAIN,
                       EffectEvidence, EffectOutcome)
from ..mechanisms import (MechanismContext, MechanismSpec, SettingSpec,
                          register)
from ..params import R
from .androgen_evidence import (DOMAIN, EVIDENCE_VERSION, MEDIATORS,
                                MediatorEffect)


def _exposure_gap(baseline_ng_dL: float, target_ng_dL: float) -> float:
    """How far the requested exposure moves, as a fraction of the studied one.

    The table's rows come from trials that raised men from a hypogonadal
    baseline into a mid-normal range.  A request that moves less than that gets
    proportionally less of the mediator response; a request that moves more
    does not get more, because the trials do not say what happens past their
    own achieved concentrations.
    """
    lo, hi = DOMAIN.achieved_total_testosterone_ng_dL
    studied_span = hi - lo
    move = target_ng_dL - baseline_ng_dL
    if move <= 0.0:
        return 0.0
    return float(min(1.0, move / studied_span))


def _duration_fraction(horizon_days: float, saturation_days: float) -> float:
    """A saturating exponential approach, capped at the evidence horizon.

    Mediator responses do not switch on at the end of a study and they do not
    keep growing after it. This rises to about 63% of the response at the
    saturation time and is clamped at 1.0, so a five-year horizon gets the same
    answer as a two-year one rather than an extrapolated one.
    """
    if saturation_days <= 0.0:
        return 0.0
    lo, hi = DOMAIN.horizon_days_range
    d = float(min(max(horizon_days, 0.0), hi))
    return float(1.0 - np.exp(-d / saturation_days))


def _screen(ctx: MechanismContext) -> Optional[Tuple[str, str]]:
    """Applicability screen. Returns (status, reason) when the lever refuses.

    Every one of these is a fail-closed: the mediator table was measured in a
    defined population over a defined exposure range, and running it outside
    that is not a wider answer, it is a different one.
    """
    person = ctx.person
    body = person.body
    ac = person.androgen

    if body.sex_at_birth not in DOMAIN.sex_at_birth:
        return (NOT_ESTIMABLE,
                "The mediator evidence table was extracted from trials in "
                f"adult men, and this profile records sex at birth as "
                f"'{body.sex_at_birth}'. Applying those mediator responses "
                "here would be extrapolation across the population the effect "
                "sizes came from, so the engine declines rather than widening "
                "an interval around a number that does not apply.")
    lo, hi = DOMAIN.age_range_y
    if not (lo <= body.age_y <= hi):
        return (OUTSIDE_DOMAIN,
                f"Age {body.age_y:.0f} is outside the {lo:.0f}-{hi:.0f} range "
                "the source trials covered.")
    if person.clinical.pregnant:
        return (NOT_ESTIMABLE, "Excluded population: pregnancy.")
    dx = {d.strip().lower() for d in person.clinical.diagnoses}
    if dx & {"erythrocytosis", "polycythemia", "polycythaemia"}:
        return (NOT_ESTIMABLE,
                "Excluded: an existing erythrocytosis makes the haemoglobin "
                "response a harm rather than a mediator, and this engine "
                "models the oxygen consequence, not the risk.")
    if ac.exposure_source == "exogenous":
        return (NOT_ESTIMABLE,
                "The recorded baseline androgen exposure is already exogenous, "
                "so the observed concentration is a consequence of treatment "
                "rather than a baseline phenotype. The table's rows start from "
                "an untreated baseline and there is no defensible way to "
                "re-anchor them here.")

    baseline = ac.total_testosterone_ng_dL
    if baseline is None:
        return (NOT_ESTIMABLE,
                "No baseline total testosterone. The target arm is defined as "
                "the observed baseline plus a delta, so without the baseline "
                "there is nothing to move away from.")
    target = ctx.settings.get("target_total_testosterone")
    if target is None or isinstance(target, str):
        return (NOT_ESTIMABLE,
                "No target total testosterone was requested, so there is no "
                "counterfactual exposure to model.")
    t_lo, t_hi = DOMAIN.achieved_total_testosterone_ng_dL
    if float(target) > t_hi:
        return (OUTSIDE_DOMAIN,
                f"A target of {float(target):.0f} ng/dL is above the "
                f"{t_hi:.0f} ng/dL the source trials achieved. Supraphysiologic "
                "exposure is a different question with different evidence, and "
                "this table does not extrapolate into it.")
    h_lo, h_hi = DOMAIN.horizon_days_range
    if ctx.horizon_days < h_lo:
        # Including a horizon of zero, which is the default. A chronic
        # mediator response over no time at all is not a small effect, it is
        # an incoherent request -- and reporting it as a null would read as
        # "this state change does almost nothing", which is the opposite of
        # what happened.
        return (OUTSIDE_DOMAIN,
                f"A horizon of {ctx.horizon_days:.0f} days is shorter than the "
                f"{h_lo:.0f} days over which these mediator responses were "
                "measured. These are chronic responses; there is nothing in "
                "the table describing the approach to them, and at a horizon "
                "of zero there is no counterfactual at all. Set "
                f"horizon_days to at least {h_lo:.0f}.")
    return None


def _measurement_caveats(ctx: MechanismContext) -> List[str]:
    """What the baseline measurement itself cannot carry."""
    ac = ctx.person.androgen
    out: List[str] = []
    morning = ac.morning_draw()
    if morning is False:
        out.append(
            "The baseline testosterone was drawn outside the 07:00-11:00 "
            "window reference ranges assume. Total testosterone has a strong "
            "diurnal rhythm, so this baseline is lower-quality than the "
            "single number suggests.")
    elif morning is None:
        out.append(
            "No collection time was recorded for the baseline testosterone, "
            "so the diurnal rhythm cannot be accounted for.")
    if ac.repeat_measurements < 2:
        out.append(
            "Fewer than two baseline measurements. Day-to-day variation in "
            "total testosterone is substantial and a single draw can misplace "
            "the baseline by more than the counterfactual moves it.")
    if ac.shbg_nmol_L is None:
        out.append(
            "No sex-hormone binding globulin, so the free fraction is not "
            "constrained. Two people with the same total testosterone can "
            "have materially different free concentrations.")
    return out


def _apply(ctx: MechanismContext) -> EffectOutcome:
    refusal = _screen(ctx)
    if refusal is not None:
        status, reason = refusal
        return EffectOutcome(
            name=SPEC.name, status=status, reason=reason,
            represented_paths=SPEC.represented_paths,
            unrepresented_paths=SPEC.unrepresented_paths,
            provenance={"kind": "mechanism",
                        "evidence_version": EVIDENCE_VERSION})

    st = ctx.state
    person = ctx.person
    ac = person.androgen
    baseline_t = float(ac.total_testosterone_ng_dL or 0.0)
    target_t = ctx.f("target_total_testosterone")
    gap = _exposure_gap(baseline_t, target_t)

    # One shared draw per member, reused across mediators. Drawing each
    # mediator independently would let a member have the largest plausible
    # haemoglobin response alongside the smallest plausible lean-mass one,
    # which no person is; the source trials do not report the joint
    # distribution, so a shared responder draw is the conservative assumption
    # and is labelled as such.
    responder = float(ctx.rng.random())

    notes: List[str] = list(_measurement_caveats(ctx))
    mediator_changes: Dict[str, Any] = {}
    parameter_changes: Dict[str, float] = {}

    def _delta(m: MediatorEffect) -> float:
        span = _duration_fraction(ctx.horizon_days, m.saturation_days)
        # Triangular by inverse transform on the shared responder draw, so the
        # correlation between mediators is exactly the stated assumption.
        lo, mid, hi = m.delta_lo, m.delta_mid, m.delta_hi
        c = (mid - lo) / (hi - lo) if hi > lo else 0.0
        u = responder if m.correlation_with_hemoglobin >= 0 else 1.0 - responder
        if hi <= lo:
            raw = mid
        elif u < c:
            raw = lo + float(np.sqrt(u * (hi - lo) * (mid - lo)))
        else:
            raw = hi - float(np.sqrt((1.0 - u) * (hi - lo) * (hi - mid)))
        strength = abs(m.correlation_with_hemoglobin)
        # A weakly correlated mediator is pulled toward its own central value
        # rather than tracking the haemoglobin draw one for one.
        raw = mid + (raw - mid) * (0.4 + 0.6 * strength)
        return raw * gap * span

    for m in MEDIATORS.values():
        if not m.enabled:
            mediator_changes[m.name] = {
                "status": NOT_ESTIMABLE,
                "applied": False,
                "reason": m.gate_reason,
                "would_land_on": m.engine_landing_point,
                "evidence_grade": m.evidence.evidence_grade,
            }
            continue
        mediator_changes[m.name] = {
            "status": ESTIMATED, "applied": True,
            "delta": _delta(m), "unit": m.unit,
            "lands_on": m.engine_landing_point,
            "evidence_grade": m.evidence.evidence_grade,
        }

    # ---- haemoglobin -> oxygen ceiling ----------------------------------
    hb_rec = mediator_changes.get("hemoglobin", {})
    oxygen = st.oxygen
    if hb_rec.get("applied") and oxygen is not None:
        hb_base = oxygen.hb_g_dL
        assert hb_base is not None, "required_context guarantees an observation"
        if ac.followup_hemoglobin_g_dL is not None:
            hb_target = float(ac.followup_hemoglobin_g_dL)
            hb_rec["observed_followup"] = True
            hb_rec["delta"] = hb_target - hb_base
            notes.append(
                "An observed follow-up haemoglobin replaces the modelled "
                "target value: a measurement beats a sampled delta.")
        else:
            hb_target = hb_base + float(hb_rec["delta"])
            hb_rec["observed_followup"] = False
        hb_rec["baseline"] = hb_base
        hb_rec["target"] = hb_target
        # The same clipped mapping and the same sampled exponent the baseline
        # arm used, so the contrast is not partly a redraw of the exponent.
        factor = (oxygen.hb_factor_for(hb_target) /
                  max(oxygen.hb_factor_for(hb_base), 1e-9))
        hb_rec["oxygen_ceiling_factor"] = factor
        if factor != 1.0:
            st.vo2max_env *= factor
            parameter_changes["vo2max_env_hb_factor"] = factor
        # The note is deliberately free of this member's numbers: those are in
        # the mediator record, where they are summarised as a distribution
        # across the ensemble instead of repeated once per draw.
        notes.append(
            "Haemoglobin is raised toward the target and scales the modelled "
            "oxygen ceiling through the same clipped mapping and the same "
            "sampled exponent this member's baseline arm used. Arterial "
            "oxygen content is one uncertain modifier of that ceiling among "
            "several; ventilation, cardiac output, perfusion, diffusion and "
            "extraction also set it.")

    # ---- lean and fat mass -> demand and active tissue -------------------
    lean_rec = mediator_changes.get("lean_mass", {})
    fat_rec = mediator_changes.get("fat_mass", {})
    d_lean = float(lean_rec.get("delta", 0.0)) if lean_rec.get("applied") else 0.0
    d_fat = float(fat_rec.get("delta", 0.0)) if fat_rec.get("applied") else 0.0
    if lean_rec.get("applied") and ac.followup_lean_mass_kg is not None:
        d_lean = float(ac.followup_lean_mass_kg) - st.lean_mass_kg
        lean_rec["observed_followup"] = True
        lean_rec["delta"] = d_lean
    if d_lean or d_fat:
        lean_base = st.lean_mass_kg
        mass_base = st.body_mass_kg
        lean_target = max(lean_base + d_lean, 1.0)
        mass_target = max(mass_base + d_lean + d_fat, 1.0)
        lean_ratio = lean_target / lean_base
        mass_ratio = mass_target / mass_base

        st.lean_mass_kg = lean_target
        st.body_mass_kg = mass_target
        st.active_muscle_kg *= lean_ratio
        st.muscle_water_L *= lean_ratio
        # Blood volume and the glucose distribution space track lean mass.
        st.blood_volume_L *= lean_ratio
        st.glucose_space_L *= lean_ratio
        # The neutral assumption, stated rather than tuned: absolute aerobic
        # capacity per kilogram of lean mass is held constant. Mass-specific
        # VO2max therefore rises with lean mass and falls with total mass, and
        # no free performance multiplier is added anywhere.
        st.vo2max_env *= lean_ratio / mass_ratio
        parameter_changes["lean_mass_kg"] = lean_target
        parameter_changes["body_mass_kg"] = mass_target
        lean_rec["baseline"] = lean_base
        lean_rec["target"] = lean_target
        notes.append(
            "Lean and body mass move together. Absolute aerobic capacity per "
            "kilogram of lean mass is held constant -- the neutral "
            "assumption, stated rather than tuned -- so the mass-specific "
            "ceiling moves only through the composition change and no free "
            "performance multiplier is added. Added mass is not free: it "
            "raises the metabolic cost of running at the same pace, and more "
            "tissue shares the same whole-body oxygen.")

    # The oxygen ceiling inside the modelled muscle has to be rebuilt from the
    # pieces that just moved, or the muscle would keep the old ceiling while
    # the whole-body one changed.
    if oxygen is not None and parameter_changes:
        st.vo2max_muscle_mM_s = (
            st.vo2max_env * st.body_mass_kg / 60.0 *
            (1.0 - st.nonmuscle_o2_frac) / R.value("o2_molar_volume") /
            max(st.muscle_water_L, 1e-9))
        parameter_changes["vo2max_env"] = st.vo2max_env

    if not parameter_changes:
        # The transform ran and moved nothing. That is a different statement
        # from "this could not be estimated": the requested exposure change,
        # after the gates and the saturation, simply came to zero, and the
        # mediator record says which mediators were gated and by how much the
        # rest moved.
        return EffectOutcome(
            name=SPEC.name, status=NEGLIGIBLE,
            reason="Every supported mediator is either gated in the evidence "
                   "table or produced no change at this exposure and horizon, "
                   "so nothing downstream moved. See the mediator record for "
                   "which, and why.",
            mediator_changes=mediator_changes,
            represented_paths=SPEC.represented_paths,
            unrepresented_paths=SPEC.unrepresented_paths,
            notes=tuple(notes),
            provenance={"kind": "mechanism",
                        "evidence_version": EVIDENCE_VERSION,
                        "exposure_gap": gap})

    notes.append(
        "Both the beneficial and the costly consequences above are applied. "
        "The engine does not choose a preferred state, and at a fixed pace the "
        "net effect may be small, mixed, or unfavourable.")

    return EffectOutcome(
        name=SPEC.name, status=ESTIMATED,
        parameter_changes=parameter_changes,
        mediator_changes=mediator_changes,
        represented_paths=SPEC.represented_paths,
        unrepresented_paths=SPEC.unrepresented_paths,
        notes=tuple(notes),
        provenance={
            "kind": "mechanism",
            "evidence_version": EVIDENCE_VERSION,
            "baseline_total_testosterone_ng_dL": baseline_t,
            "target_total_testosterone_ng_dL": target_t,
            "exposure_gap_fraction_of_studied_span": gap,
            "horizon_days": ctx.horizon_days,
            "responder_draw": responder,
            "evidence": SPEC.evidence.to_dict(),
        })


SPEC = register(MechanismSpec(
    name="sustained_androgen_exposure",
    label="Sustained androgen exposure (through mediators)",
    question="If sustained androgen exposure produced the specified chronic "
             "changes in supported mediators, how would those mediator "
             "changes affect the running-energy model?",
    target_handles=("vo2max_env", "vo2max_muscle_mM_s", "lean_mass_kg",
                    "body_mass_kg", "active_muscle_kg"),
    settings=(
        SettingSpec(
            name="target_total_testosterone", unit="ng/dL",
            description="The sustained total-testosterone concentration the "
                        "counterfactual asks about. Not a dose and not a "
                        "prescription: the engine models what supported "
                        "mediators would do at that exposure, and says "
                        "nothing about how anyone would reach it.",
            default=0.0, lo=0.0,
            hi=DOMAIN.achieved_total_testosterone_ng_dL[1],
            prior_lo=DOMAIN.achieved_total_testosterone_ng_dL[0],
            prior_hi=DOMAIN.achieved_total_testosterone_ng_dL[1]),
        SettingSpec(
            name="target_free_testosterone", unit="pg/mL",
            description="Recorded for provenance. The mediator table is "
                        "anchored on achieved total testosterone, so a free "
                        "target does not currently change the transform.",
            default=0.0, lo=0.0, hi=500.0),
        SettingSpec(
            name="exposure_pattern", unit="category",
            description="Whether the exposure is held stable or cycles. Only "
                        "'stable' is supported: the mediator responses were "
                        "measured under continuous exposure.",
            default="stable", choices=("stable",)),
    ),
    required_context=("androgen_context", "observed_hemoglobin",
                      "body_composition"),
    evidence=EffectEvidence(
        source_keys=("traverse_anemia", "testosterone_lean_mito",
                     "testosterone_oxphos_markers",
                     "endocrine_society_testosterone",
                     "fda_testosterone_labeling"),
        population="adult men, 18-80, with an observed untreated baseline",
        tissue="whole blood and whole-body composition, landing on skeletal "
               "muscle through the existing demand and oxygen models",
        domain="sustained exposure within the concentrations the source "
               "trials achieved, over 28 to 730 days",
        support="indirect", evidence_grade="moderate",
        confounders=(
            "serum testosterone is not a universal tissue-response "
            "coordinate: the same concentration means different things in "
            "different baseline states",
            "the mediator responses were measured in men treated for "
            "hypogonadism and do not transfer to eugonadal men given more",
            "concurrent training dominates the body-composition response and "
            "is not an input to this engine",
            "the joint distribution of the mediator responses is not "
            "reported, so their correlation here is an assumption")),
    represented_paths=(
        "haemoglobin -> arterial oxygen content -> the modelled aerobic "
        "ceiling, through the same mapping and the same sampled exponent the "
        "baseline arm used",
        "lean and fat mass -> body mass -> the metabolic cost of running at a "
        "given pace",
        "lean mass -> active muscle mass and muscle water -> the tissue "
        "sharing that oxygen and the concentration basis of every "
        "intracellular state"),
    unrepresented_paths=(
        "any mapping from a treatment, dose or regimen to an achieved "
        "exposure: that arrow is not modelled at all",
        "direct mitochondrial volume or oxidative-phosphorylation capacity, "
        "deliberately left unchanged",
        "insulin sensitivity, glucose disposal and any endocrine feedback",
        "strength, neuromuscular function and running economy: more force "
        "does not make ATP cheaper in this model",
        "where added lean mass is distributed; only locomotor muscle would "
        "carry running demand and the engine cannot tell the difference",
        "every risk and every adverse effect: this engine models energetics, "
        "not safety"),
    scope_note="A mediator counterfactual: what supported mediator changes "
               "would do to the running-energy model, not what any treatment "
               "would do to a person.",
    mapping_note="This answers what the model predicts if the stated "
                 "mediators changed by the stated amounts. It does not "
                 "estimate the effect of testosterone therapy, convert an "
                 "exposure into a dose, or say whether treatment is "
                 "appropriate for anyone.",
    apply=_apply))

__all__ = ["SPEC"]
