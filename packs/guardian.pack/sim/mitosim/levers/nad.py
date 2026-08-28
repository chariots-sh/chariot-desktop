"""Mitochondrial NAD pool: a state transform, not a supplement.

The question this lever answers is narrow and worth stating exactly:

    Holding the calibrated resting operating point and every non-NAD capacity
    constant, how does a different mitochondrial NAD pool change simulated
    skeletal-muscle behaviour under running load?

It is a model-state sensitivity experiment.  It is not an estimate of what NAD
injection, nicotinamide riboside, nicotinamide mononucleotide, or any other
intervention does, and the engine says so on every result.

Nothing biochemical is added here.  The engine already carries a matrix NAD
pool (``nad_total_mito``), a resting redox state (``nadh_mito_rest_ratio``),
compartment-specific conservation, NAD-sensitive pyruvate dehydrogenase,
beta-oxidation, ketone oxidation, TCA and respiratory-chain terms, the
reducing-equivalent shuttles, and a resting relaxation with fixed-point
polishing.  What this file adds is a *controlled transform* of one pool, the
diagnostics needed to read the result, and the refusals that keep it honest.

Two properties of the transform matter more than the numbers it produces.

**The resting operating point is preserved by construction.**  Scaling the pool
changes the resting activation the model solves for, and the engine
recalibrates to the same resting ATP demand.  So this contrast is not about
resting metabolism -- it is about reserve and transient behaviour under load,
and every result says that in its scope note rather than leaving a reader to
discover it.

**The requested resting redox state is preserved.**  ``nadh_mito_rest_ratio``
is a fraction of the pool, so scaling the pool scales matrix NADH and matrix
NAD+ together and leaves the resting reduced fraction where it was.  Changing
the redox state as well would confound two different experiments in one lever.
"""

from __future__ import annotations

from typing import List

from ..effects import (ESTIMATED, NOT_ESTIMABLE, EffectEvidence,
                       EffectOutcome)
from ..mechanisms import (MechanismContext, MechanismSpec, SettingSpec,
                          register)
from ..params import R
from ..provenance import SOURCES, Source, add_source

# --------------------------------------------------------------------------
# Evidence
# --------------------------------------------------------------------------
# The intervention literature below is registered because it explains why the
# *mappings* from a supplement to this state stay disabled. It does not
# calibrate the lever: the lever's domain comes from the registered
# physiological prior on the matrix pool itself.

add_source(Source(
    key="nad_iv_pilot",
    citation="Intravenous NAD+ infusion in humans: pharmacokinetics and "
             "metabolite appearance. (PMID 31572171)",
    url="https://pubmed.ncbi.nlm.nih.gov/31572171/",
    population="small healthy-adult pilot",
    tissue="plasma and urine metabolites; no muscle NAD measurement",
    domain="single intravenous infusion; no skeletal-muscle tissue endpoint"))

add_source(Source(
    key="nr_exercise",
    citation="Nicotinamide riboside supplementation and skeletal-muscle "
             "metabolism during exercise in humans. (PMID 33492681)",
    url="https://pubmed.ncbi.nlm.nih.gov/33492681/",
    population="healthy adults",
    tissue="skeletal muscle",
    domain="oral precursor supplementation over weeks; muscle NAD response "
           "small and inconsistent"))

add_source(Source(
    key="nad_metabolism_review",
    citation="NAD metabolism in health and disease: synthesis, consumption "
             "and compartmentation. (PMID 36331703)",
    url="https://pubmed.ncbi.nlm.nih.gov/36331703/",
    population="human and preclinical",
    tissue="multiple tissues",
    domain="review of NAD biosynthesis, consumption and compartmentation"))


# --------------------------------------------------------------------------
# Domain
# --------------------------------------------------------------------------
# The registered prior on nad_total_mito is normal(3.0, 0.5) clipped to
# [1.8, 4.5] mmol/L. That clip is the range the evidence covers, so a resulting
# pool inside it keeps the parameter's own support grade and a resulting pool
# outside it is labelled sensitivity-only: it explores the model's response
# and must not inherit biological support merely because the solver accepted
# the request.
_PRIOR = R.P("nad_total_mito").require_dist()
PRIOR_LO, PRIOR_HI = float(_PRIOR.lo), float(_PRIOR.hi)
CENTRAL = float(R.P("nad_total_mito").value)

# Hard supported domain of the control itself. Outside this the request is
# refused rather than extrapolated: a quarter of the matrix pool is already
# well past anything the source model was solved at, and doubling it leaves
# every NAD-dependent term saturated so the run stops being informative.
SCALE_LO, SCALE_HI = 0.25, 2.0


def _apply(ctx: MechanismContext) -> EffectOutcome:
    scale = ctx.f("pool_scale")
    st = ctx.state
    before = float(st.bp["nad_total_mito"])
    after = before * scale
    st.bp["nad_total_mito"] = after

    notes: List[str] = []
    rest_ratio = float(st.bp["nadh_mito_rest_ratio"])
    sensitivity_only = not (PRIOR_LO <= after <= PRIOR_HI)
    if sensitivity_only:
        notes.append(
            f"The transformed matrix pool is {after:.2f} mmol/L, outside the "
            f"registered physiological prior of {PRIOR_LO:.1f}-{PRIOR_HI:.1f} "
            "mmol/L. This member is sensitivity-only: it shows how the model "
            "responds, and it does not inherit the prior's biological support.")
    if scale > 1.0:
        notes.append(
            "Enlarging the pool may legitimately do very little. At the "
            "registered constants the matrix NADH and NAD+ terms are already "
            "substantially saturated at running workloads, so the depletion "
            "direction is where this lever has room to act.")

    return EffectOutcome(
        name=SPEC.name,
        status=ESTIMATED,
        parameter_changes={"nad_total_mito": after},
        represented_paths=SPEC.represented_paths,
        unrepresented_paths=SPEC.unrepresented_paths,
        notes=tuple(notes),
        provenance={
            "kind": "mechanism",
            "pool_scale": scale,
            "nad_total_mito_before_mmol_L": before,
            "nad_total_mito_after_mmol_L": after,
            "nadh_mito_rest_ratio_preserved": rest_ratio,
            "registered_prior_mmol_L": [PRIOR_LO, PRIOR_HI],
            "sensitivity_only": sensitivity_only,
            "evidence": SPEC.evidence.to_dict(),
        })


SPEC = register(MechanismSpec(
    name="mitochondrial_nad_pool",
    label="Mitochondrial NAD pool",
    question="Holding the calibrated resting operating point and all non-NAD "
             "capacities constant, how does a different mitochondrial NAD pool "
             "affect simulated skeletal-muscle behaviour under running load?",
    target_handles=("nad_total_mito",),
    settings=(
        SettingSpec(
            name="pool_scale", unit="ratio",
            description="Multiplier on this ensemble member's own sampled "
                        "matrix NAD pool. 1.0 reproduces the run without the "
                        "mechanism exactly.",
            default=1.0, lo=SCALE_LO, hi=SCALE_HI,
            prior_lo=round(PRIOR_LO / CENTRAL, 2),
            prior_hi=round(PRIOR_HI / CENTRAL, 2)),
    ),
    required_context=(),
    evidence=EffectEvidence(
        source_keys=("li2012", "nad_metabolism_review"),
        population="human model parameterised from human exercise studies",
        tissue="skeletal muscle, type I and type II fibres",
        domain=f"matrix NAD pool {PRIOR_LO:.1f}-{PRIOR_HI:.1f} mmol/L at rest "
               "and during running-type exercise",
        support="adjacent", evidence_grade="moderate",
        confounders=(
            "the matrix pool cannot be measured in an intact exercising "
            "person, so no input to this product constrains it",
            "the resting redox state and the pool size are separately "
            "uncertain and this lever moves only the pool",
            "matrix and cytosolic pools are distinct compartments; changing "
            "one is not a whole-cell NAD change")),
    represented_paths=(
        "pyruvate dehydrogenase (NAD+ substrate term)",
        "beta-oxidation (NAD+ substrate term)",
        "ketone oxidation (NAD+ substrate term)",
        "TCA cycle (NAD+ substrate term, km_nad_tca)",
        "respiratory chain (matrix NADH substrate term, km_nadh_oxphos)",
        "malate-aspartate and glycerol-phosphate shuttles (mass action on "
        "both compartments' pools)",
        "resting dehydrogenase and respiratory-control calibration, which is "
        "re-solved at the transformed pool"),
    unrepresented_paths=(
        "NAD consumption and resynthesis (NAMPT, sirtuins, PARPs, CD38): the "
        "pool is conserved within a run and has no turnover",
        "NAD-dependent signalling and transcription, and therefore any "
        "training-adaptation response",
        "compartment transport of NAD itself between cytosol and matrix",
        "an available-NAD+ gate on GAPDH, so glycolytic rate does not depend "
        "on cytosolic NAD+ availability in this model"),
    scope_note="Resting demand is recalibrated at the transformed pool, so "
               "this contrast concerns behaviour under load rather than "
               "resting metabolism.",
    mapping_note="This answers what the current muscle model predicts if the "
                 "mitochondrial NAD pool is changed by the stated amount. It "
                 "does not estimate the effect of NAD injection, NR, NMN, or "
                 "another intervention.",
    apply=_apply))

# --------------------------------------------------------------------------
# Gated axes: cytosolic pool and shuttle capacity
# --------------------------------------------------------------------------
# Two further NAD axes exist in the engine and are deliberately *not* exposed.
# Both are registered so that they are visible, documented and testable rather
# than merely absent, and both are gated shut until the identifiability study
# in ``mitosim/identifiability.py`` says which of them -- if either -- is worth
# offering as a control.
#
# The reason is not caution for its own sake. Near lactate-dehydrogenase
# equilibrium, scaling the cytosolic pool and scaling shuttle capacity can move
# the same reducing-equivalent transfer in nearly the same way, and two
# controls that do one thing are worse than one control that says so. The
# cytosolic pool is not simply a duplicate of shuttle capacity either -- it
# also sets lactate-dehydrogenase mass action and the free NAD+/NADH ratio --
# so equivalence must be tested, not assumed in either direction.
#
# And there is a harder limit on what a cytosolic-NAD result could mean. This
# engine's glycolytic rate law has no available-NAD+ gate at
# glyceraldehyde-3-phosphate dehydrogenase, so the single most-cited route by
# which cytosolic NAD+ would constrain running metabolism is absent from the
# model. A null on that route is ``pathway_not_represented``, and no amount of
# sweeping will turn it into biological evidence.

GLYCOLYTIC_GATE_MISSING = (
    "This model's glycolytic rate law has no available-NAD+ gate at "
    "glyceraldehyde-3-phosphate dehydrogenase, so glycolytic rate does not "
    "depend on cytosolic NAD+ availability here. Any cytosolic-NAD result "
    "read as a statement about glycolysis is pathway_not_represented, not "
    "evidence."
)

_GATE_REASON = (
    "Gated pending the identifiability study in mitosim/identifiability.py. "
    "Near lactate-dehydrogenase equilibrium this axis and the shuttle-capacity "
    "axis can move reducing-equivalent transfer in nearly the same way, so "
    "exposing both before testing whether they are distinguishable would offer "
    "two controls for one degree of freedom. Run 'mitosim identifiability' for "
    "the current verdict."
)

_SHARED_UNREPRESENTED = (
    "NAD consumption and resynthesis: both pools are conserved within a run",
    "an available-NAD+ gate on GAPDH, so glycolytic rate does not depend on "
    "cytosolic NAD+ availability in this model",
    "transport of NAD itself between the cytosolic and matrix compartments",
)


def apply_cytosolic_pool_scale(state, scale: float) -> float:
    """Scale the free cytosolic NAD pool. Research entry point.

    Reachable from the identifiability study, not from a scenario: the
    mechanism that would expose it is registered gated shut.
    """
    before = float(state.bp["nad_total_cyt"])
    state.bp["nad_total_cyt"] = before * scale
    return before * scale


def apply_shuttle_capacity_scale(state, scale: float) -> float:
    """Scale both reducing-equivalent shuttles together. Research entry point."""
    for key in ("k_shuttle_I", "k_shuttle_II"):
        state.bp[key] = float(state.bp[key]) * scale
    return float(state.bp["k_shuttle_I"])


def _apply_cytosolic(ctx: MechanismContext) -> EffectOutcome:
    after = apply_cytosolic_pool_scale(ctx.state, ctx.f("pool_scale"))
    return EffectOutcome(
        name=CYTOSOLIC_SPEC.name, status=ESTIMATED,
        parameter_changes={"nad_total_cyt": after},
        represented_paths=CYTOSOLIC_SPEC.represented_paths,
        unrepresented_paths=CYTOSOLIC_SPEC.unrepresented_paths,
        notes=(GLYCOLYTIC_GATE_MISSING,),
        provenance={"kind": "mechanism", "gated_axis": True})


def _apply_shuttle(ctx: MechanismContext) -> EffectOutcome:
    after = apply_shuttle_capacity_scale(ctx.state, ctx.f("capacity_scale"))
    return EffectOutcome(
        name=SHUTTLE_SPEC.name, status=ESTIMATED,
        parameter_changes={"k_shuttle_I": after, "k_shuttle_II": after},
        represented_paths=SHUTTLE_SPEC.represented_paths,
        unrepresented_paths=SHUTTLE_SPEC.unrepresented_paths,
        provenance={"kind": "mechanism", "gated_axis": True})


CYTOSOLIC_SPEC = register(MechanismSpec(
    name="cytosolic_nad_pool",
    label="Cytosolic NAD pool (gated)",
    question="How does a different free cytosolic NAD pool change simulated "
             "skeletal-muscle behaviour under running load?",
    target_handles=("nad_total_cyt",),
    settings=(
        SettingSpec("pool_scale", "ratio",
                    "Multiplier on the sampled free cytosolic NAD pool.",
                    default=1.0, lo=0.25, hi=2.0, prior_lo=0.6, prior_hi=1.6),
    ),
    required_context=(),
    evidence=EffectEvidence(
        source_keys=("li2012",),
        population="human model parameterised from human exercise studies",
        tissue="skeletal muscle, type I and type II fibres",
        domain="free cytosolic NAD pool 0.3-0.8 mmol/L",
        support="adjacent", evidence_grade="moderate",
        confounders=(
            "only the free fraction participates; most cellular NAD is "
            "enzyme-bound and the free fraction is not measurable in a person",
            "this axis and shuttle capacity may not be separately "
            "identifiable in the operating regime this product simulates")),
    represented_paths=(
        "lactate dehydrogenase mass action, and hence the lactate/pyruvate "
        "ratio and the free cytosolic NAD+/NADH ratio",
        "both reducing-equivalent shuttles, through the mass-action term on "
        "the cytosolic pool"),
    unrepresented_paths=_SHARED_UNREPRESENTED,
    scope_note="Gated: registered and documented, not offered as a control.",
    mapping_note="This would answer what the model predicts at a different "
                 "cytosolic NAD pool. It does not estimate the effect of NAD "
                 "injection, NR, NMN, or another intervention.",
    enabled=False, disabled_status=NOT_ESTIMABLE,
    disabled_reason=_GATE_REASON + " " + GLYCOLYTIC_GATE_MISSING,
    apply=_apply_cytosolic))


SHUTTLE_SPEC = register(MechanismSpec(
    name="reducing_equivalent_shuttle",
    label="Reducing-equivalent shuttle capacity (gated)",
    question="How does a different malate-aspartate and glycerol-phosphate "
             "shuttle capacity change simulated skeletal-muscle behaviour "
             "under running load?",
    target_handles=("k_shuttle_I", "k_shuttle_II"),
    settings=(
        SettingSpec("capacity_scale", "ratio",
                    "Multiplier on both fibre populations' shuttle rate "
                    "constants.",
                    default=1.0, lo=0.25, hi=2.0, prior_lo=0.7, prior_hi=1.4),
    ),
    required_context=(),
    evidence=EffectEvidence(
        source_keys=("li2012",),
        population="human model parameterised from human exercise studies",
        tissue="skeletal muscle, type I and type II fibres",
        domain="reducing-equivalent transfer at rest and moderate exercise",
        support="adjacent", evidence_grade="moderate",
        confounders=(
            "the shuttle is written as one reversible mass-action process "
            "standing for two biochemically distinct systems",
            "this axis and the cytosolic pool may not be separately "
            "identifiable in the operating regime this product simulates")),
    represented_paths=(
        "transfer of cytosolic reducing equivalents into the matrix, and so "
        "the matrix redox state and respiratory-chain substrate supply",
        "the cytosolic NAD+/NADH ratio, and through it lactate dehydrogenase"),
    unrepresented_paths=_SHARED_UNREPRESENTED,
    scope_note="Gated: registered and documented, not offered as a control.",
    mapping_note="This would answer what the model predicts at a different "
                 "shuttle capacity. It does not estimate the effect of any "
                 "intervention.",
    enabled=False, disabled_status=NOT_ESTIMABLE,
    disabled_reason=_GATE_REASON,
    apply=_apply_shuttle))

__all__ = ["SPEC", "CYTOSOLIC_SPEC", "SHUTTLE_SPEC", "PRIOR_LO", "PRIOR_HI",
           "SCALE_LO", "SCALE_HI", "GLYCOLYTIC_GATE_MISSING",
           "apply_cytosolic_pool_scale", "apply_shuttle_capacity_scale"]
