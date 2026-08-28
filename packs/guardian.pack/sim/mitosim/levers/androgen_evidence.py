"""Versioned mediator-response table for sustained androgen exposure.

Serum testosterone is not a universal tissue-response coordinate.  The same
concentration means different things in a man treated for hypogonadism, a
eugonadal man given more, and an older man with high sex-hormone binding
globulin, and no single number maps exposure onto tissue.  So this table is not
"testosterone -> effect".  Every row is a *population, baseline status, achieved
exposure and duration* with a mediator-change distribution attached, and a row
only applies to a person the row's own inclusion criteria describe.

Each mediator carries its own gate.  A mediator whose evidence does not yet
support a quantitative delta is registered and disabled here rather than being
given a plausible-looking number, and the reason is the gate itself, so that
enabling it later is a change to this table rather than a change to the engine.
Two of them are disabled for exactly that reason today: the lean-mass and
fat-mass responses need a stronger randomised-trial or meta-analytic anchor
than the studies cited below provide, and until that anchor is extracted the
engine will not put a number on them.

Two mediators are permanently out of scope in this version, and not for want of
evidence.  Strength is context: more force does not make ATP cheaper, and the
engine has no route from it to a running-energy output.  Direct mitochondrial
volume or oxidative-phosphorylation capacity stays unchanged because the two
studies nearest the question do not support a direct capacity claim, and a
mechanism lever that silently raised oxidative capacity would manufacture the
performance benefit the whole design is meant to avoid asserting.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any, Dict, List, Optional, Tuple

from ..effects import EffectEvidence
from ..provenance import Source, add_source

EVIDENCE_VERSION = "androgen-mediators-0.1.0"

# --------------------------------------------------------------------------
# Sources
# --------------------------------------------------------------------------

add_source(Source(
    key="traverse_anemia",
    citation="TRAVERSE anaemia substudy: testosterone-replacement therapy and "
             "haemoglobin in middle-aged and older men with hypogonadism. "
             "(PMID 37889486)",
    url="https://pubmed.ncbi.nlm.nih.gov/37889486/",
    population="men 45-80 with hypogonadism and cardiovascular risk; anaemic "
               "and non-anaemic strata reported separately",
    tissue="whole blood (haemoglobin, haematocrit)",
    domain="transdermal testosterone to a mid-normal range, followed for "
           "months to years"))

add_source(Source(
    key="testosterone_lean_mito",
    citation="Testosterone administration, lean mass and skeletal-muscle "
             "mitochondrial volume in men. (PMID 29656500)",
    url="https://pubmed.ncbi.nlm.nih.gov/29656500/",
    population="men, trial setting",
    tissue="skeletal muscle biopsy and body composition",
    domain="testosterone administration; lean mass rises without a "
           "demonstrated proportional rise in mitochondrial volume"))

add_source(Source(
    key="testosterone_oxphos_markers",
    citation="Testosterone and skeletal-muscle oxidative-phosphorylation "
             "markers in humans. (PMID 24760536)",
    url="https://pubmed.ncbi.nlm.nih.gov/24760536/",
    population="men",
    tissue="skeletal muscle biopsy",
    domain="marker-level oxidative-phosphorylation endpoints; not a measured "
           "capacity change in exercising muscle"))

add_source(Source(
    key="endocrine_society_testosterone",
    citation="Endocrine Society clinical practice guidance on testosterone "
             "measurement and the diagnosis of hypogonadism: morning "
             "sampling, repeat measurement, and the effect of binding "
             "proteins on the free fraction.",
    url="", population="adult men", tissue="serum",
    domain="measurement context and diagnostic thresholds, not treatment "
           "effect sizes"))

add_source(Source(
    key="fda_testosterone_labeling",
    citation="FDA class-wide labeling changes for testosterone products.",
    url="https://www.fda.gov/drugs/drug-alerts-and-statements/fda-issues-"
        "class-wide-labeling-changes-testosterone-products",
    population="adults prescribed testosterone products",
    tissue="n/a",
    domain="regulatory labeling: risks and appropriate-use context, not a "
           "mediator effect size"))


# --------------------------------------------------------------------------
# Domain of the table
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class ApplicabilityDomain:
    """Who the table's rows were measured in, and where it refuses to speak."""
    sex_at_birth: Tuple[str, ...] = ("male",)
    age_range_y: Tuple[float, float] = (18.0, 80.0)
    # Achieved total testosterone the source trials actually reached. Above the
    # ceiling is supraphysiologic and outside every row.
    achieved_total_testosterone_ng_dL: Tuple[float, float] = (150.0, 800.0)
    # Below this the mediator responses have not saturated; above it the table
    # does not extrapolate further.
    horizon_days_range: Tuple[float, float] = (28.0, 730.0)
    exclusions: Tuple[str, ...] = (
        "pregnancy",
        "people whose baseline androgen exposure is already exogenous, where "
        "the observed concentration is a treatment consequence rather than a "
        "baseline phenotype",
        "androgen-sensitive malignancy",
        "erythrocytosis or a baseline haematocrit already above the reference "
        "range, where the haemoglobin response is a harm rather than a "
        "mediator",
    )

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


DOMAIN = ApplicabilityDomain()


# --------------------------------------------------------------------------
# Mediators
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class MediatorEffect:
    """One mediator's response to a defined exposure change.

    ``delta_lo/mid/hi`` is a triangular distribution over the change in the
    mediator's own unit, at full exposure change and full duration.  It is
    scaled down by how far the requested exposure actually moves and by how
    much of the response time has elapsed, and it saturates at the edge of the
    evidence domain rather than continuing linearly.
    """
    name: str
    label: str
    unit: str
    engine_landing_point: str
    delta_lo: float
    delta_mid: float
    delta_hi: float
    saturation_days: float
    evidence: EffectEvidence
    enabled: bool = True
    gate_reason: str = ""
    # Direction of correlation with the haemoglobin response, used to draw
    # mediators together rather than independently.
    correlation_with_hemoglobin: float = 0.0
    note: str = ""

    def to_dict(self) -> Dict[str, Any]:
        d = {k: v for k, v in asdict(self).items() if k != "evidence"}
        d["evidence"] = self.evidence.to_dict()
        return d


MEDIATORS: Dict[str, MediatorEffect] = {}


def _add(m: MediatorEffect) -> MediatorEffect:
    MEDIATORS[m.name] = m
    return m


_add(MediatorEffect(
    name="hemoglobin",
    label="Haemoglobin",
    unit="g/dL",
    engine_landing_point="arterial oxygen content, through the registered "
                         "haemoglobin-to-oxygen-ceiling mapping the baseline "
                         "arm already uses",
    # TRAVERSE's anaemia substudy is a quantitative anchor in a defined
    # population: correcting hypogonadism raises haemoglobin by on the order of
    # a gram per decilitre, more in men who started anaemic and less in men who
    # did not. The spread here is deliberately wide, and the upper end is where
    # the same response stops being a benefit and becomes erythrocytosis.
    delta_lo=0.2, delta_mid=1.0, delta_hi=2.0,
    saturation_days=180.0,
    evidence=EffectEvidence(
        source_keys=("traverse_anemia", "fda_testosterone_labeling"),
        population="men 45-80 with hypogonadism",
        tissue="whole blood",
        domain="testosterone raised into a mid-normal range over months",
        support="indirect", evidence_grade="moderate",
        confounders=(
            "the response is larger in men who started anaemic, and the "
            "engine has no way to know why a given person's haemoglobin is "
            "where it is",
            "iron availability limits the response and is not an input here",
            "the same rise is an adverse effect above the reference range; "
            "the engine models the oxygen consequence, not the risk",
            "altitude residence, smoking and plasma-volume changes move "
            "haemoglobin without changing red-cell mass")),
    correlation_with_hemoglobin=1.0,
    note="Modelled through the existing oxygen-ceiling mapping, on this "
         "ensemble member's own sampled exponent, so the target arm is "
         "compared with its own baseline rather than with a population one."))

_add(MediatorEffect(
    name="lean_mass",
    label="Lean mass",
    unit="kg",
    engine_landing_point="active muscle mass, muscle water, and therefore "
                         "both the running demand and the concentration basis "
                         "of every intracellular state",
    delta_lo=0.5, delta_mid=1.8, delta_hi=3.5,
    saturation_days=180.0,
    evidence=EffectEvidence(
        source_keys=("testosterone_lean_mito",),
        population="men, trial setting",
        tissue="whole-body composition",
        domain="testosterone administration over months",
        support="indirect", evidence_grade="insufficient",
        confounders=(
            "the response depends on concurrent resistance training, which is "
            "not an input to this engine",
            "measured lean mass includes water; part of an acute rise is not "
            "contractile tissue",
            "the distribution of any gain between locomotor and "
            "non-locomotor muscle is unknown, and only the locomotor share "
            "would carry running demand")),
    enabled=False,
    gate_reason=(
        "Gated pending a stronger quantitative anchor. The cited trial "
        "supports the direction and the rough scale of a lean-mass response "
        "but is not the randomised or meta-analytic effect-size source this "
        "mediator needs, and the numbers above are a placeholder extraction, "
        "not a calibrated distribution. The engine will not put a number on "
        "this mediator until that anchor is extracted into this table; the "
        "transform and its energetic cost are implemented and tested, so "
        "enabling it is a change to this row rather than to the engine."),
    correlation_with_hemoglobin=0.4,
    note="Added mass is not free: it raises the metabolic cost of running at "
         "a fixed pace as well as the tissue available to do the work."))

_add(MediatorEffect(
    name="fat_mass",
    label="Fat mass",
    unit="kg",
    engine_landing_point="body mass, and therefore the running demand",
    delta_lo=-2.5, delta_mid=-1.2, delta_hi=-0.2,
    saturation_days=180.0,
    evidence=EffectEvidence(
        source_keys=("testosterone_lean_mito",),
        population="men, trial setting",
        tissue="whole-body composition",
        domain="testosterone administration over months",
        support="indirect", evidence_grade="insufficient",
        confounders=(
            "energy balance dominates fat mass and is not an input here",
            "reported fat-mass changes are smaller and less consistent than "
            "lean-mass changes")),
    enabled=False,
    gate_reason=(
        "Gated for the same reason as lean mass, and with lower confidence. "
        "It is also only meaningful alongside a lean-mass delta, because "
        "applying one without the other produces a target body mass that is "
        "not internally consistent with the composition it claims."),
    correlation_with_hemoglobin=-0.2,
    note=""))

_add(MediatorEffect(
    name="strength",
    label="Maximal strength",
    unit="context only",
    engine_landing_point="none: this engine has no route from force capacity "
                         "to the ATP cost of running at a given pace",
    delta_lo=0.0, delta_mid=0.0, delta_hi=0.0,
    saturation_days=0.0,
    evidence=EffectEvidence(
        source_keys=("testosterone_lean_mito",),
        population="men, trial setting", tissue="whole body",
        domain="testosterone administration over months",
        support="indirect", evidence_grade="moderate"),
    enabled=False,
    gate_reason=(
        "Context only, permanently in this version. A strength response is "
        "well described, but more force does not make ATP cheaper, and there "
        "is no represented path from it to any running-energy output. "
        "Applying it would be inventing a benefit, not modelling one."),
    note=""))

_add(MediatorEffect(
    name="insulin_sensitivity",
    label="Insulin sensitivity",
    unit="index",
    engine_landing_point="would be the glucose-uptake and fuel-partition "
                         "terms",
    delta_lo=0.0, delta_mid=0.0, delta_hi=0.0,
    saturation_days=0.0,
    evidence=EffectEvidence(
        source_keys=("endocrine_society_testosterone",),
        population="mixed", tissue="whole body",
        domain="not established as a quantitative mediator response",
        support="assumed", evidence_grade="insufficient"),
    enabled=False,
    gate_reason=(
        "Disabled in this version. The reported effects are inconsistent and "
        "confounded by the body-composition change, so there is no defensible "
        "delta to apply and no automatic state change is made."),
    note=""))

_add(MediatorEffect(
    name="mitochondrial_capacity",
    label="Direct mitochondrial volume or oxidative-phosphorylation capacity",
    unit="ratio",
    engine_landing_point="would be mito_scale and the oxidative Vmax terms",
    delta_lo=0.0, delta_mid=0.0, delta_hi=0.0,
    saturation_days=0.0,
    evidence=EffectEvidence(
        source_keys=("testosterone_lean_mito", "testosterone_oxphos_markers"),
        population="men", tissue="skeletal muscle biopsy",
        domain="mitochondrial volume and marker-level endpoints",
        support="indirect", evidence_grade="insufficient",
        confounders=(
            "marker-level endpoints are not a measured capacity change in "
            "exercising muscle",
            "a lean-mass rise without a proportional mitochondrial-volume "
            "rise means capacity per kilogram of muscle can fall rather than "
            "rise")),
    enabled=False,
    gate_reason=(
        "Unchanged in this version, deliberately. The two studies nearest the "
        "question restrain a direct capacity claim rather than supporting "
        "one, and a lever that silently raised oxidative capacity would "
        "manufacture exactly the performance benefit this design refuses to "
        "assert."),
    note=""))


def active_mediators() -> List[MediatorEffect]:
    return [m for m in MEDIATORS.values() if m.enabled]


def gated_mediators() -> List[MediatorEffect]:
    return [m for m in MEDIATORS.values() if not m.enabled]


def table() -> Dict[str, Any]:
    """The whole table, versioned, for the report and the web payload."""
    return {
        "version": EVIDENCE_VERSION,
        "domain": DOMAIN.to_dict(),
        "mediators": [m.to_dict() for m in MEDIATORS.values()],
        "correlation_note":
            "Mediator deltas are drawn from one shared exposure-response draw "
            "rather than independently, so a member with a large haemoglobin "
            "response also has a large lean-mass response. The correlation is "
            "a conservative assumption, not a measured covariance: the source "
            "trials do not report the joint distribution.",
    }


__all__ = ["EVIDENCE_VERSION", "ApplicabilityDomain", "DOMAIN",
           "MediatorEffect", "MEDIATORS", "active_mediators",
           "gated_mediators", "table"]
