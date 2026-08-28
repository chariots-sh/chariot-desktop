"""Mechanism counterfactuals: state-shaped levers, not doses.

A *mechanism* answers a question of the form "if this tissue were in a
different biological state, what would the model predict under load?".  It is
deliberately not an intervention.  The step from a supplement, a drug or a
behaviour to a tissue state is an uncertain mapping this engine refuses to
fake, so mechanisms and experimental adapters are separate types with separate
inputs::

    TRT ---------------?--------------- androgen exposure
    NAD+ / NR / NMN ---?--------------- tissue NAD state
    glutathione / NAC -?--------------- tissue redox state
                                              |
                                              v
                                    SKELETAL-MUSCLE ENGINE

Everything to the left of the question marks belongs in ``adapters.py`` with a
dose and a timing.  Everything to the right belongs here with a state setting
and a horizon.  A mechanism never converts a state into a dose, and a
registered-but-unmapped intervention can never quietly activate a mechanism
transform: the two registries do not reach into each other.

What a mechanism must declare is in ``MechanismSpec``: which model handles it
touches, the domain of settings it supports, what context it requires of the
person, its shared ``EffectEvidence``, which downstream paths in *this* model
carry the change, and -- the field that makes a null result interpretable --
which biologically plausible paths this model does not represent at all.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple, Union

from .effects import (NO_INTERVENTION_MAPPING, NOT_ESTIMABLE, OUTSIDE_DOMAIN,
                      EffectEvidence, EffectOutcome)

SettingValue = Union[float, str]


# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class SettingSpec:
    """One control a mechanism accepts, with the domain it is allowed to take.

    Two ranges, and the difference between them is the whole point.
    ``(lo, hi)`` is the *supported domain*: outside it the engine refuses the
    request rather than extrapolating.  ``(prior_lo, prior_hi)`` is the range
    the registered physiological prior actually covers, and it is what the
    catalogue shows a reader: a value inside the supported domain but outside
    the prior still runs, and must not inherit biological support merely
    because the solver accepted it.

    Whether a particular *member* is sensitivity-only is decided by the lever
    itself, against the value the transform actually produced -- the NAD lever
    compares the resulting matrix pool with the registered parameter clip,
    which is not the same test as comparing the requested scale with this
    range. ``outside_prior`` is the catalogue-level approximation of it, for
    describing the control before anyone runs it.
    """
    name: str
    unit: str
    description: str
    default: SettingValue = 0.0
    lo: float = float("-inf")
    hi: float = float("inf")
    prior_lo: Optional[float] = None
    prior_hi: Optional[float] = None
    choices: Tuple[str, ...] = ()

    @property
    def is_choice(self) -> bool:
        return bool(self.choices)

    def check(self, value: SettingValue) -> Optional[str]:
        """Return a reason the value is unusable, or None if it is fine."""
        if self.is_choice:
            if value not in self.choices:
                return (f"{self.name}={value!r} is not one of "
                        f"{', '.join(self.choices)}")
            return None
        if isinstance(value, str):
            return (f"{self.name} is a number in {self.unit}; the string "
                    f"{value!r} carries no unit this engine can interpret")
        v = float(value)
        if not (self.lo <= v <= self.hi):
            return (f"{self.name}={v:g} {self.unit} is outside the supported "
                    f"domain {self.lo:g} to {self.hi:g} {self.unit}; the "
                    "engine will not extrapolate into it")
        return None

    def outside_prior(self, value: SettingValue) -> bool:
        """Inside the supported domain but outside the registered prior."""
        if self.is_choice or isinstance(value, str):
            return False
        v = float(value)
        return ((self.prior_lo is not None and v < self.prior_lo) or
                (self.prior_hi is not None and v > self.prior_hi))

    def to_dict(self) -> Dict[str, Any]:
        # An unbounded side of the domain becomes null, not an infinity:
        # json.dumps writes Infinity, which is not JSON and which every
        # standards-conforming parser -- including the web app's -- rejects.
        # Dist.to_dict does the same thing for the same reason.
        def finite(x: Optional[float]) -> Optional[float]:
            return None if x is None or math.isinf(x) else float(x)

        return {
            "name": self.name, "unit": self.unit,
            "description": self.description, "default": self.default,
            "supported_domain": [finite(self.lo), finite(self.hi)],
            "prior_range": [finite(self.prior_lo), finite(self.prior_hi)],
            "choices": list(self.choices),
        }


# --------------------------------------------------------------------------
# Context passed to a transform
# --------------------------------------------------------------------------

@dataclass
class MechanismContext:
    """Everything a transform is allowed to see for one ensemble member.

    It carries the sampled personal state it may mutate, the person's own
    observations, the input-QC report (which is where observed constraints such
    as haemoglobin land), an independent random stream, and the requested
    horizon.  The stream is independent by construction so that adding a
    mechanism to a scenario cannot shift any other draw in the member -- which
    is what makes "neutral mechanism equals no mechanism" exactly true rather
    than approximately true.
    """
    state: Any
    rng: Any
    settings: Dict[str, SettingValue]
    horizon_days: float = 0.0
    person: Any = None
    qc: Any = None
    label: str = ""

    def f(self, name: str) -> float:
        v = self.settings[name]
        assert not isinstance(v, str), f"{name} is a numeric setting"
        return float(v)

    def s(self, name: str) -> str:
        return str(self.settings[name])


# --------------------------------------------------------------------------
# Specification
# --------------------------------------------------------------------------

@dataclass
class MechanismSpec:
    """The complete declaration required of every mechanism lever.

    Evidence, status vocabulary and outcome serialisation are the shared
    primitives in ``effects.py`` -- the same ones ``AdapterSpec`` uses -- so a
    mechanism and an adapter are described in one vocabulary.  What is specific
    here is the state: the handles it changes, the settings it accepts, and the
    scope note saying what the contrast is and is not about.
    """
    name: str
    label: str
    question: str
    target_handles: Tuple[str, ...]
    settings: Tuple[SettingSpec, ...]
    required_context: Tuple[str, ...]
    evidence: EffectEvidence
    represented_paths: Tuple[str, ...]
    unrepresented_paths: Tuple[str, ...]
    scope_note: str
    mapping_note: str = NO_INTERVENTION_MAPPING
    enabled: bool = True
    disabled_status: str = NOT_ESTIMABLE
    disabled_reason: str = ""
    # apply(ctx) -> EffectOutcome
    apply: Optional[Callable[[MechanismContext], EffectOutcome]] = None

    def __post_init__(self) -> None:
        if self.enabled and self.apply is None:
            raise ValueError(f"{self.name}: an enabled mechanism needs apply()")
        if not self.enabled and not self.disabled_reason:
            raise ValueError(
                f"{self.name}: a disabled mechanism must say why, so that the "
                "reason travels with every result instead of being folded into "
                "a silent no-op")

    def setting(self, name: str) -> Optional[SettingSpec]:
        for s in self.settings:
            if s.name == name:
                return s
        return None

    @property
    def supported_domain(self) -> Dict[str, Any]:
        return {s.name: s.to_dict()["supported_domain"] for s in self.settings}

    def defaults(self) -> Dict[str, SettingValue]:
        return {s.name: s.default for s in self.settings}

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "label": self.label,
            "question": self.question,
            "enabled": self.enabled,
            "disabled_status": self.disabled_status,
            "disabled_reason": self.disabled_reason,
            "target_handles": list(self.target_handles),
            "settings": [s.to_dict() for s in self.settings],
            "supported_domain": self.supported_domain,
            "required_context": list(self.required_context),
            "represented_paths": list(self.represented_paths),
            "unrepresented_paths": list(self.unrepresented_paths),
            "scope_note": self.scope_note,
            "mapping_note": self.mapping_note,
            "evidence": self.evidence.to_dict(),
        }


MECHANISMS: Dict[str, MechanismSpec] = {}


def register(spec: MechanismSpec) -> MechanismSpec:
    MECHANISMS[spec.name] = spec
    return spec


def catalogue() -> List[Dict[str, Any]]:
    return [s.to_dict() for s in MECHANISMS.values()]


# --------------------------------------------------------------------------
# Validation and application
# --------------------------------------------------------------------------

def validate_use(use) -> Optional[Tuple[str, str]]:
    """Return (rule, reason) if this requested mechanism cannot be run.

    Used by the scenario compiler, which rejects a scenario outright, and by
    ``apply_mechanisms``, which fails closed on the same conditions at run
    time.  Both paths share this function so that a setting the compiler would
    have rejected cannot slip in through the API instead.
    """
    spec = MECHANISMS.get(use.mechanism)
    if spec is None:
        return ("unknown_mechanism",
                f"no mechanism named {use.mechanism!r} is registered, so the "
                "engine has no transform to apply and will not invent one")
    unknown = [k for k in use.settings if spec.setting(k) is None]
    if unknown:
        known = ", ".join(s.name for s in spec.settings) or "none"
        return ("unknown_mechanism_setting",
                f"{use.mechanism} does not accept {', '.join(sorted(unknown))}; "
                f"its settings are: {known}")
    for key, value in use.settings.items():
        s = spec.setting(key)
        assert s is not None
        bad = s.check(value)
        if bad:
            return ("mechanism_setting_out_of_domain", bad)
    if use.horizon_days < 0:
        return ("mechanism_horizon_negative",
                "a mechanism horizon cannot be negative")
    return None


def _missing_context(spec: MechanismSpec, person, qc) -> List[str]:
    missing: List[str] = []
    for req in spec.required_context:
        if req == "androgen_context":
            ctx = getattr(person, "androgen", None)
            if ctx is None or not ctx.observed():
                missing.append(
                    "a baseline androgen context with at least one observed "
                    "concentration")
        elif req == "observed_hemoglobin":
            if qc is None or "oxygen_capacity" not in getattr(
                    qc, "constraints", {}):
                missing.append("an observed haemoglobin or haematocrit")
        elif req == "body_composition":
            if person is None or person.body.lean_mass() is None:
                missing.append("an observed lean mass or body-fat percentage")
    return missing


def apply_mechanisms(uses, state, rng, person=None,
                     qc=None) -> List[EffectOutcome]:
    """Apply every requested mechanism to one sampled personal state.

    Transforms mutate the state in place and report exactly what they changed.
    Anything that cannot be applied returns a status saying *why* rather than a
    silent no-op, because "the model has no pathway for this" and "the effect
    was zero" are different claims and only one of them is about biology.
    """
    outcomes: List[EffectOutcome] = []
    for use in uses:
        spec = MECHANISMS.get(use.mechanism)
        verdict = validate_use(use)
        if verdict is not None:
            rule, reason = verdict
            status = (OUTSIDE_DOMAIN
                      if rule == "mechanism_setting_out_of_domain"
                      else NOT_ESTIMABLE)
            outcomes.append(EffectOutcome(
                use.mechanism, status, reason=reason,
                unrepresented_paths=(spec.unrepresented_paths
                                     if spec else ()),
                provenance={"kind": "mechanism", "rule": rule,
                            "settings": dict(use.settings)}))
            continue
        assert spec is not None
        if not spec.enabled:
            outcomes.append(EffectOutcome(
                use.mechanism, spec.disabled_status,
                reason=spec.disabled_reason,
                notes=(spec.scope_note, spec.mapping_note),
                represented_paths=spec.represented_paths,
                unrepresented_paths=spec.unrepresented_paths,
                provenance={"kind": "mechanism", "enabled": False,
                            "settings": dict(use.settings),
                            "evidence": spec.evidence.to_dict()}))
            continue
        missing = _missing_context(spec, person, qc)
        if missing:
            outcomes.append(EffectOutcome(
                use.mechanism, NOT_ESTIMABLE,
                reason="This mechanism needs " + "; ".join(missing) +
                       ". Without it the baseline arm has nothing to anchor "
                       "to, and a counterfactual against an invented baseline "
                       "is not a counterfactual.",
                unrepresented_paths=spec.unrepresented_paths,
                provenance={"kind": "mechanism", "settings": dict(use.settings)}))
            continue
        settings = spec.defaults()
        settings.update(use.settings)
        ctx = MechanismContext(state=state, rng=rng, settings=settings,
                               horizon_days=use.horizon_days, person=person,
                               qc=qc, label=use.label)
        assert spec.apply is not None
        outcomes.append(spec.apply(ctx))
    return outcomes


__all__ = ["SettingSpec", "MechanismSpec", "MechanismContext", "MECHANISMS",
           "register", "catalogue", "validate_use", "apply_mechanisms"]


# The registered levers live in their own modules under ``levers/``; importing
# the package here is what populates ``MECHANISMS``. The import sits at the
# bottom because those modules need the types defined above.
from . import levers  # noqa: E402,F401
