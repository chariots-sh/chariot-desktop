"""Muscle redox state: registered, gated, and answering with a refusal.

Glutathione is not an implementation milestone in this engine. It is a
design-review milestone, and the review is ``docs/RFC-REDOX.md``. This module
exists so that the refusal is a visible, documented, testable object rather
than a silence a reader has to infer from the absence of a control.

The gate is structural, not cautious. The engine has no superoxide or
hydrogen-peroxide source flux anywhere; ``proton_leak_frac`` is energetic
uncoupling, not electron leak, and reusing it as a ROS source would be a
category error that happens to produce a plausible curve; and
``FORBIDDEN_OUTPUTS`` forbids reporting a reactive-oxygen-species concentration
or an oxidative-stress score. A glutathione pool control added to these
equations would be a control wired to nothing, reporting a number derived from
nothing.

So there is one answer, and it is the one the plan specifies:

    not_estimable: no validated redox source-and-scavenging model at this
    resolution
"""

from __future__ import annotations

# Imported for its source registrations: the antioxidant adapter is disabled
# for the same structural reason this lever is gated, and citing one evidence
# entry from both is the point of a shared provenance registry.
from .. import adapters as _adapters  # noqa: F401
from ..effects import NOT_ESTIMABLE, EffectEvidence
from ..mechanisms import MechanismSpec, SettingSpec, register
from ..provenance import Source, add_source

REFUSAL = ("not_estimable: no validated redox source-and-scavenging model at "
           "this resolution")

add_source(Source(
    key="redox_rfc",
    citation="Design review of a skeletal-muscle redox module for this "
             "engine: source term, compartments, glutathione and thioredoxin "
             "systems, NADPH recycling, calibration and falsifiability. "
             "docs/RFC-REDOX.md.",
    url="",
    population="n/a -- a design decision, not a study",
    tissue="n/a",
    domain="open review; no module approved"))


SPEC = register(MechanismSpec(
    name="muscle_redox_state",
    label="Muscle redox state (gated pending review)",
    question="If skeletal-muscle redox state were different, how would that "
             "change simulated running energetics? This engine cannot ask "
             "that question yet, and this lever exists to say so.",
    target_handles=(),
    settings=(
        SettingSpec(
            name="glutathione_pool_scale", unit="ratio",
            description="Declared so that the refusal is specific rather than "
                        "a missing key. There is no modelled glutathione pool "
                        "for this to scale.",
            default=1.0, lo=0.25, hi=2.0),
    ),
    required_context=(),
    evidence=EffectEvidence(
        source_keys=("redox_rfc", "antioxidant_evidence"),
        population="n/a",
        tissue="n/a",
        domain="no approved model at this resolution",
        support="assumed", evidence_grade="insufficient",
        confounders=(
            "exercise redox signalling is part of the adaptive response, so "
            "'less is better' is not a supported reading and a module that "
            "implied it would be actively misleading",
            "peroxiredoxins and catalase handle much of the physiological "
            "hydrogen-peroxide flux, so a glutathione-only model would "
            "attribute their work to glutathione and over-respond to it")),
    represented_paths=(),
    unrepresented_paths=(
        "superoxide and hydrogen-peroxide production: the engine has no "
        "source flux for either",
        "the glutathione system: GSH, GSSG, glutathione peroxidase, "
        "glutathione reductase and the NADPH recycling behind them",
        "thioredoxin, peroxiredoxin and catalase, which carry much of the "
        "physiological peroxide flux",
        "compartmentation of redox species between matrix and cytosol",
        "any feedback from redox state to ATP production",
        "recovery, adaptation, longevity and disease risk, none of which "
        "follow from a within-run flux"),
    scope_note="Nothing is modelled. This lever reports why, and what would "
               "have to be true for it to be modelled.",
    mapping_note="Injectable and oral glutathione and N-acetylcysteine remain "
                 "not_estimable regardless of whether a future redox state "
                 "model is approved: the state model and the intervention "
                 "mapping are different problems. This does not estimate the "
                 "effect of any of them.",
    enabled=False,
    disabled_status=NOT_ESTIMABLE,
    disabled_reason=(
        REFUSAL + ". The engine models no reactive-oxygen-species production "
        "at all: proton_leak_frac is energetic uncoupling, not electron leak, "
        "and repurposing it would be a category error rather than a model. "
        "See docs/RFC-REDOX.md for what an approved module would have to "
        "supply, including a source term independent of proton leak, at least "
        "one falsification target, and a demonstration that pool size, enzyme "
        "capacity and NADPH recycling produce distinguishable bottlenecks."),
    apply=None))

__all__ = ["SPEC", "REFUSAL"]
