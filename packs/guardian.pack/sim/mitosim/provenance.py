"""Machine-readable registry of parameters, equations and evidence.

Spec 2.6 requires: "Preserve every original equation, modified equation,
parameter source, unit, and rationale in a machine-readable registry."

Every number the engine uses must be registered here.  A parameter carries:

* its value and *parsed* unit (units.py refuses nonsense),
* an uncertainty distribution -- the engine samples, it does not use points,
* a ``pclass`` from spec 2.8 (observed / inferred / population),
* a source with a resolvable citation,
* a rationale explaining why this number is defensible for *running muscle*,
* a ``support`` grade recording how far the use is from the evidence.

``support`` is the honesty dial.  ``direct`` means human skeletal muscle during
running-like exercise.  ``extrapolated`` means we are outside the domain the
source validated and the output must be labelled accordingly.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, Iterator, List, Optional, Tuple

from . import units as U

# --------------------------------------------------------------------------
# Evidence and support grading
# --------------------------------------------------------------------------

SUPPORT_GRADES = (
    "direct",         # human skeletal muscle, exercise, matching intensity domain
    "adjacent",       # human muscle but different intensity/duration domain
    "indirect",       # human whole-body or non-muscle tissue
    "extrapolated",   # outside the validated domain of the source
    "assumed",        # structural modelling choice, no direct measurement
)

PARAM_CLASSES = (
    "observed",       # spec 2.8 class 1: pace, grade, mass, meal timing
    "inferred",       # spec 2.8 class 2: aerobic ceiling, glycogen, recruitment
    "population",     # spec 2.8 class 3: kinetic constants, transport constants
    "structural",     # model topology / reduction choices
)


@dataclass(frozen=True)
class Source:
    key: str
    citation: str
    url: str = ""
    population: str = ""      # who was studied
    tissue: str = ""          # what tissue
    domain: str = ""          # what exercise/measurement domain

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


SOURCES: Dict[str, Source] = {}


def add_source(src: Source) -> Source:
    SOURCES[src.key] = src
    return src


# ---- Sources cited by the spec -------------------------------------------

add_source(Source(
    key="minetti2002",
    citation="Minetti AE, Moia C, Roi GS, Susta D, Ferretti G. Energy cost of "
             "walking and running at extreme uphill and downhill slopes. "
             "J Appl Physiol 93:1039-1046, 2002.",
    url="https://pubmed.ncbi.nlm.nih.gov/12183501/",
    population="10 male mountain runners",
    tissue="whole body (indirect calorimetry)",
    domain="treadmill running, gradients -0.45 to +0.45, submaximal steady state",
))

add_source(Source(
    key="li2012",
    citation="Li Y, Dash RK, Kim J, Saidel GM, Cabrera ME. Computational model "
             "of cellular metabolic dynamics in skeletal muscle fibers during "
             "moderate intensity exercise. (PMC3431029)",
    url="https://pmc.ncbi.nlm.nih.gov/articles/PMC3431029/",
    population="human model, parameterised from human exercise studies",
    tissue="skeletal muscle, type I and type II fibers + capillary blood",
    domain="rest and moderate-intensity exercise, short duration",
))

add_source(Source(
    key="korzeniewski_eval",
    citation="Evaluation of a computational model of human skeletal muscle "
             "bioenergetics reproducing PCr, pH and pulmonary VO2 kinetics. "
             "(PMC4704516)",
    url="https://pmc.ncbi.nlm.nih.gov/articles/PMC4704516/",
    population="human",
    tissue="skeletal muscle",
    domain="exercise and recovery, including severe intensity",
))

add_source(Source(
    key="mitocore",
    citation="Smith AC, Eyassu F, Mazat J-P, Robinson AJ. MitoCore: a curated "
             "constraint-based model of human mitochondrial metabolism. "
             "BMC Syst Biol, 2017. (PMC5702245)",
    url="https://pmc.ncbi.nlm.nih.gov/articles/PMC5702245/",
    population="human",
    tissue="cardiomyocyte-parameterised central + mitochondrial metabolism",
    domain="constraint-based (FBA); stoichiometry and feasibility, not kinetics",
))

add_source(Source(
    key="venables2005",
    citation="Venables MC, Achten J, Jeukendrup AE. Determinants of fat "
             "oxidation during exercise in healthy men and women: a "
             "cross-sectional study. J Appl Physiol 98:160-167, 2005.",
    url="https://paulogentil.com/pdf/Determinants%20of%20fat%20oxidation%20during%20exercise%20in%20healthy%20men%20and%20women%20-%20A%20cross-sectional%20study.pdf",
    population="300 healthy adults (157 M / 143 F)",
    tissue="whole body (indirect calorimetry)",
    domain="graded treadmill exercise to exhaustion",
))

add_source(Source(
    key="glycogen_methods",
    citation="Review of muscle glycogen determination methods. (PMC6019055)",
    url="https://pmc.ncbi.nlm.nih.gov/articles/PMC6019055/",
    population="human",
    tissue="vastus lateralis biopsy",
    domain="glycogen quantification methodology",
))

add_source(Source(
    key="glycogen_review",
    citation="Muscle glycogen metabolism and resynthesis review. (PMC5872716)",
    url="https://pmc.ncbi.nlm.nih.gov/articles/PMC5872716/",
    population="human",
    tissue="skeletal muscle",
    domain="glycogen depletion and recovery with diet and exercise",
))

add_source(Source(
    key="supercompensation",
    citation="Running vs cycling glycogen supercompensation synthesis. "
             "(PMC12399638)",
    url="https://pmc.ncbi.nlm.nih.gov/articles/PMC12399638/",
    population="human",
    tissue="skeletal muscle",
    domain="carbohydrate loading protocols, running and cycling",
))

add_source(Source(
    key="fibertype_runners",
    citation="Fiber type composition in sprint vs marathon runners "
             "(~62% type I in the marathon group). (PMC11945673)",
    url="https://pmc.ncbi.nlm.nih.gov/articles/PMC11945673/",
    population="small cohort of sprint and marathon runners",
    tissue="vastus lateralis biopsy",
    domain="cross-sectional fiber typing -- small n, not a population definition",
))

add_source(Source(
    key="ekblom1975",
    citation="Effect of changes in arterial oxygen content on circulation and "
             "physical performance. (PMID 1150596)",
    url="https://pubmed.ncbi.nlm.nih.gov/1150596/",
    population="healthy men",
    tissue="whole body",
    domain="experimental manipulation of arterial O2 content, VO2max",
))

add_source(Source(
    key="apple_cardio",
    citation="Apple Support: Cardio fitness levels and VO2 max on Apple Watch.",
    url="https://support.apple.com/en-ie/108790",
    population="consumer",
    tissue="n/a (heart-rate and motion derived estimate)",
    domain="estimated VO2max, not respiratory gas measurement",
))

add_source(Source(
    key="lambe2026",
    citation="Lambe et al. Living systematic review of consumer wearable "
             "validity. (PMC12823594)",
    url="https://pmc.ncbi.nlm.nih.gov/articles/PMC12823594/",
    population="consumer wearable validation studies",
    tissue="n/a",
    domain="agreement stronger for heart rate than energy expenditure/sleep",
))

add_source(Source(
    key="indirect_cal_review",
    citation="Review of indirect calorimetry assumptions and limitations. "
             "(PMID 9416437)",
    url="https://pubmed.ncbi.nlm.nih.gov/9416437/",
    population="human",
    tissue="whole body",
    domain="substrate oxidation estimation; weaker in non-steady-state and "
           "very intense exercise",
))

add_source(Source(
    key="model_structure",
    citation="Structural choice of this engine; no single external measurement. "
             "Documented reduction of the source model topology.",
    url="",
    population="n/a",
    tissue="n/a",
    domain="model reduction / numerical implementation",
))

add_source(Source(
    key="textbook_bioenergetics",
    citation="Standard human bioenergetics constants (equilibrium constants, "
             "P/O ratios, buffering capacity) as used across the cited "
             "skeletal-muscle modelling literature.",
    url="",
    population="human",
    tissue="skeletal muscle",
    domain="consensus biochemical constants",
))


# --------------------------------------------------------------------------
# Distributions
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Dist:
    """An uncertainty distribution for a registered parameter.

    ``kind`` is one of normal, lognormal, uniform, triangular, fixed, beta.
    ``lo``/``hi`` clip the sample to a physically admissible range.
    """

    kind: str
    a: float = 0.0
    b: float = 0.0
    lo: float = -math.inf
    hi: float = math.inf

    def sample(self, rng, size=None):
        import numpy as np
        k = self.kind
        if k == "fixed":
            v = np.full(size, self.a) if size else self.a
            return v
        if k == "normal":
            v = rng.normal(self.a, self.b, size)
        elif k == "lognormal":
            # a = median, b = geometric sd (multiplicative)
            v = self.a * np.exp(rng.normal(0.0, math.log(self.b), size))
        elif k == "uniform":
            v = rng.uniform(self.a, self.b, size)
        elif k == "triangular":
            mid = (self.a + self.b) / 2.0
            v = rng.triangular(self.a, mid, self.b, size)
        elif k == "beta":
            v = rng.beta(self.a, self.b, size)
        else:
            raise ValueError(f"unknown distribution kind {k!r}")
        import numpy as np
        return np.clip(v, self.lo, self.hi)

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        for key in ("lo", "hi"):
            if math.isinf(d[key]):
                d[key] = None
        return d


def fixed(v: float) -> Dist:
    return Dist("fixed", v)


def lognormal(median: float, gsd: float, lo=0.0, hi=math.inf) -> Dist:
    return Dist("lognormal", median, gsd, lo, hi)


def normal(mean: float, sd: float, lo=-math.inf, hi=math.inf) -> Dist:
    return Dist("normal", mean, sd, lo, hi)


def uniform(lo: float, hi: float) -> Dist:
    return Dist("uniform", lo, hi, lo, hi)


# --------------------------------------------------------------------------
# Parameters
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Param:
    name: str
    value: float
    unit: str
    pclass: str
    source: str
    rationale: str
    support: str = "assumed"
    dist: Optional[Dist] = None
    domain: str = ""            # where this parameter is valid
    tags: Tuple[str, ...] = ()

    def __post_init__(self):
        U.parse(self.unit)                       # raises on nonsense units
        if self.pclass not in PARAM_CLASSES:
            raise ValueError(f"{self.name}: bad pclass {self.pclass!r}")
        if self.support not in SUPPORT_GRADES:
            raise ValueError(f"{self.name}: bad support {self.support!r}")
        if self.source not in SOURCES:
            raise ValueError(f"{self.name}: unregistered source {self.source!r}")

    @property
    def dim(self) -> U.Dim:
        return U.parse(self.unit)

    def require_dist(self) -> Dist:
        """The parameter's distribution, or a degenerate one at its value.

        Mirrors the fallback used by :meth:`sample`, giving call sites a
        non-optional ``Dist`` to read ``.a/.b/.lo/.hi/.kind`` from.
        """
        return self.dist or fixed(self.value)

    def sample(self, rng, size=None):
        d = self.dist or fixed(self.value)
        return d.sample(rng, size)

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["dist"] = self.dist.to_dict() if self.dist else None
        d["dimension"] = str(self.dim)
        d["source_detail"] = SOURCES[self.source].to_dict()
        return d


class Registry:
    """Ordered, immutable-ish store of every parameter the engine can use."""

    def __init__(self, version: str):
        self.version = version
        self._params: Dict[str, Param] = {}
        self._equations: Dict[str, "Equation"] = {}

    def add(self, p: Param) -> Param:
        if p.name in self._params:
            raise ValueError(f"duplicate parameter {p.name!r}")
        self._params[p.name] = p
        return p

    def P(self, name: str) -> Param:
        return self._params[name]

    def value(self, name: str) -> float:
        return self._params[name].value

    def __contains__(self, name: str) -> bool:
        return name in self._params

    def __iter__(self) -> Iterator[Param]:
        return iter(self._params.values())

    def __len__(self) -> int:
        return len(self._params)

    def names(self) -> List[str]:
        return list(self._params)

    def by_class(self, pclass: str) -> List[Param]:
        return [p for p in self._params.values() if p.pclass == pclass]

    def add_equation(self, eq: "Equation") -> "Equation":
        if eq.name in self._equations:
            raise ValueError(f"duplicate equation {eq.name!r}")
        self._equations[eq.name] = eq
        return eq

    def equations(self) -> List["Equation"]:
        return list(self._equations.values())

    def to_dict(self) -> Dict[str, Any]:
        return {
            "registry_version": self.version,
            "sources": {k: v.to_dict() for k, v in SOURCES.items()},
            "parameters": {k: v.to_dict() for k, v in self._params.items()},
            "equations": {k: v.to_dict() for k, v in self._equations.items()},
        }

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent)

    # ---- unit auditing ----------------------------------------------------
    def audit_units(self) -> List[str]:
        """Every parameter unit must parse; every equation must be dimensionally
        consistent with the quantity it produces."""
        problems: List[str] = []
        for p in self._params.values():
            try:
                U.parse(p.unit)
            except ValueError as e:
                problems.append(f"parameter {p.name}: {e}")
        for eq in self._equations.values():
            problems.extend(eq.audit(self))
        return problems


@dataclass(frozen=True)
class Equation:
    """A declared model equation, its units and its provenance.

    ``produces`` is the unit of the quantity the expression evaluates to.
    ``factors`` lists ``(parameter_or_unit, exponent)`` terms whose product must
    have the same dimension as ``produces``.  This is a genuine check: it caught
    two unit slips while this engine was being written.
    """

    name: str
    expression: str
    produces: str
    factors: Tuple[Tuple[str, float], ...]
    source: str
    rationale: str
    support: str = "assumed"
    modified_from_source: str = ""

    def audit(self, reg: Registry) -> List[str]:
        out: List[str] = []
        try:
            target = U.parse(self.produces)
        except ValueError as e:
            return [f"equation {self.name}: bad produces unit: {e}"]
        acc = U.DIMENSIONLESS
        for sym, power in self.factors:
            if sym in reg:
                d = reg.P(sym).dim
            else:
                try:
                    d = U.parse(sym)
                except ValueError as e:
                    out.append(f"equation {self.name}: bad factor {sym!r}: {e}")
                    continue
            acc = acc * (d ** power)
        if not acc.same_dimension(target):
            out.append(
                f"equation {self.name}: factors give {acc} but produces "
                f"{self.produces} ({target})")
        return out

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["source_detail"] = SOURCES[self.source].to_dict()
        return d
