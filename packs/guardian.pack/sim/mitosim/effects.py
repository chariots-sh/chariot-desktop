"""Shared evidence, status and outcome primitives for declared effects.

Two different kinds of thing are allowed to change this engine's parameters:

* an **experimental adapter** (``adapters.py``) -- a *dose-shaped* intervention
  such as caffeine at 3 mg/kg taken 60 minutes before the run, and
* a **mechanism** (``mechanisms.py``) -- a *state-shaped* counterfactual such as
  a mitochondrial NAD pool 20% smaller than the sampled one.

They must not be conflated: a dose is something a person takes, a state is
something a tissue is in, and the step between them is exactly the uncertain
mapping this product refuses to fake.  What they do share is everything about
honesty -- who was studied, in which tissue, over what domain, how strong the
evidence is, what actually changed, which paths carry the change, which
plausible paths this model does not represent at all, and what the engine is
entitled to say when it cannot answer.

Those shared parts live here so that there is one vocabulary for them rather
than two that drift apart.  ``AdapterSpec`` keeps its dose and timing fields;
``MechanismSpec`` keeps its settings and supported domain; both carry an
``EffectEvidence`` and both report an ``EffectOutcome``.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, Literal, Tuple

from .provenance import SOURCES, SUPPORT_GRADES

# --------------------------------------------------------------------------
# Status vocabulary
# --------------------------------------------------------------------------
# One vocabulary, shared. The first three are the ways an effect can be
# reported; the rest are the ways it can decline to be reported, and the
# distinctions between them are the point. "Nothing happened" and "this model
# has no pathway for it to happen through" are completely different claims, and
# only one of them is about biology.

ESTIMATED = "estimated"
ACTIVE = "active"
NEGLIGIBLE = "negligible_within_model"
PATHWAY_NOT_REPRESENTED = "pathway_not_represented"
OUTSIDE_DOMAIN = "outside_supported_domain"
NOT_ESTIMABLE = "not_estimable"
NUMERICALLY_UNRESOLVED = "numerically_unresolved"
DISABLED = "disabled"

MechanismStatus = Literal[
    "estimated",
    "negligible_within_model",
    "pathway_not_represented",
    "outside_supported_domain",
    "not_estimable",
    "numerically_unresolved",
]

# Adapters additionally use "active" (the dose was applied) and "disabled" (the
# adapter is registered but has no defensible mapping).
EFFECT_STATUSES: Tuple[str, ...] = (
    ESTIMATED, ACTIVE, NEGLIGIBLE, PATHWAY_NOT_REPRESENTED, OUTSIDE_DOMAIN,
    NOT_ESTIMABLE, NUMERICALLY_UNRESOLVED, DISABLED,
)

STATUS_MEANINGS: Dict[str, str] = {
    ESTIMATED: "The requested change was applied to the model and its "
               "consequences were simulated.",
    ACTIVE: "The requested experimental input was applied to the model and its "
            "consequences were simulated.",
    NEGLIGIBLE: "The change was applied and the model resolved it, but the "
                "paired effect on the reported outputs was too small to "
                "matter. This is a statement about this model, not evidence "
                "that the biology is inert.",
    PATHWAY_NOT_REPRESENTED: "A biologically plausible route for this effect "
                             "is absent from the model, so a null result here "
                             "is a property of the model and must not be read "
                             "as biological evidence.",
    OUTSIDE_DOMAIN: "The requested value lies outside the domain the "
                    "supporting evidence covers, so the engine will not "
                    "extrapolate into it.",
    NOT_ESTIMABLE: "No defensible mapping exists from what was asked to "
                   "anything this model represents, so nothing was changed.",
    NUMERICALLY_UNRESOLVED: "The change was admissible but the model could not "
                            "be solved to a physiologically coherent state at "
                            "that setting.",
    DISABLED: "Registered but not enabled: the evidence needed to map it onto "
              "a modelled quantity does not exist yet.",
}

# The sentence every state-shaped counterfactual carries. It is the whole
# reason mechanisms and adapters are separate types.
NO_INTERVENTION_MAPPING = (
    "Hypothetical tissue state; no intervention mapping is implied. This does "
    "not estimate the effect of any supplement, drug or dose."
)


# --------------------------------------------------------------------------
# Evidence
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class EffectEvidence:
    """Who was studied, in what tissue, over what domain, and how strongly.

    Every field is required because every one of them is a way the effect can
    fail to apply to the person in front of us.  ``source_keys`` are resolved
    against the shared provenance registry at construction, so an effect cannot
    cite a study that does not exist.
    """
    source_keys: Tuple[str, ...]
    population: str
    tissue: str
    domain: str
    support: str
    evidence_grade: str
    confounders: Tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not self.source_keys:
            raise ValueError("an effect must cite at least one source")
        missing = [k for k in self.source_keys if k not in SOURCES]
        if missing:
            raise KeyError(f"unregistered evidence source(s): {missing}")
        if self.support not in SUPPORT_GRADES:
            raise ValueError(
                f"support {self.support!r} is not one of {SUPPORT_GRADES}")
        for name in ("population", "tissue", "domain", "evidence_grade"):
            if not getattr(self, name):
                raise ValueError(f"an effect must declare its {name}")

    def to_dict(self) -> Dict[str, Any]:
        return {
            "source_keys": list(self.source_keys),
            "population": self.population,
            "tissue": self.tissue,
            "domain": self.domain,
            "support": self.support,
            "evidence_grade": self.evidence_grade,
            "confounders": list(self.confounders),
            "sources": [SOURCES[k].to_dict() for k in self.source_keys],
        }


# --------------------------------------------------------------------------
# Outcome
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class EffectOutcome:
    """What one adapter or mechanism did to one ensemble member.

    ``parameter_changes`` records model handles and registered parameters that
    actually moved, so a reader can see the transform rather than infer it from
    the outputs.  ``represented_paths`` and ``unrepresented_paths`` are what
    make a null interpretable: the second list is the reason a null is not
    evidence.
    """
    name: str
    status: str
    parameter_changes: Dict[str, float] = field(default_factory=dict)
    mediator_changes: Dict[str, Any] = field(default_factory=dict)
    represented_paths: Tuple[str, ...] = ()
    unrepresented_paths: Tuple[str, ...] = ()
    notes: Tuple[str, ...] = ()
    confounds: Tuple[str, ...] = ()
    reason: str = ""
    provenance: Dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.status not in EFFECT_STATUSES:
            raise ValueError(
                f"{self.name}: status {self.status!r} is not one of "
                f"{EFFECT_STATUSES}")

    @property
    def applied(self) -> bool:
        """Did this effect actually change the simulation?"""
        return self.status in (ESTIMATED, ACTIVE)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "status": self.status,
            "status_meaning": STATUS_MEANINGS.get(self.status, ""),
            "parameter_changes": dict(self.parameter_changes),
            "mediator_changes": dict(self.mediator_changes),
            "represented_paths": list(self.represented_paths),
            "unrepresented_paths": list(self.unrepresented_paths),
            "notes": list(self.notes),
            "confounds": list(self.confounds),
            "reason": self.reason,
            "provenance": dict(self.provenance),
        }


__all__ = [
    "EffectEvidence", "EffectOutcome", "MechanismStatus", "EFFECT_STATUSES",
    "STATUS_MEANINGS", "NO_INTERVENTION_MAPPING", "ESTIMATED", "ACTIVE",
    "NEGLIGIBLE", "PATHWAY_NOT_REPRESENTED", "OUTSIDE_DOMAIN", "NOT_ESTIMABLE",
    "NUMERICALLY_UNRESOLVED", "DISABLED",
]
