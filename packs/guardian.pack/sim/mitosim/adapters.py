"""Experimental input adapters (spec 1.3).

The rule from the spec: "Experimental inputs are optional model adapters, not
free-form multipliers."  Every adapter must declare:

* the biological parameter it changes
* the human population and tissue supporting the change
* dose and timing range
* effect-size distribution
* known measurement confounders
* interactions and contraindication flags
* the conditions under which the result becomes "not estimable"

An adapter that cannot satisfy those requirements is *registered as disabled*
rather than quietly given a plausible-looking multiplier.  Asking for a disabled
adapter returns a NOT_ESTIMABLE verdict, and the scenario still runs -- it just
runs without the claimed effect and says so.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, asdict
from typing import Any, Callable, Dict, List, Optional, Tuple

import numpy as np

from .effects import (ACTIVE, DISABLED, NOT_ESTIMABLE, EffectEvidence,
                      EffectOutcome)
from .provenance import SOURCES, Source, add_source

# Additional sources used only by adapters.
add_source(Source(
    key="nitrate_reviews",
    citation="Dietary nitrate and the oxygen cost of submaximal exercise: "
             "meta-analytic evidence in humans.",
    url="", population="healthy adults, mostly recreationally active",
    tissue="whole body", domain="submaximal steady-state exercise"))
add_source(Source(
    key="creatine_reviews",
    citation="Creatine supplementation and muscle total creatine / "
             "phosphocreatine content in humans.",
    url="", population="healthy adults", tissue="vastus lateralis biopsy",
    domain="loading and maintenance dosing over days to weeks"))
add_source(Source(
    key="caffeine_reviews",
    citation="Caffeine pharmacokinetics and endurance-performance effects in "
             "humans, including its effect on heart rate and perceived "
             "exertion.",
    url="", population="healthy adults", tissue="whole body",
    domain="acute dosing 3-6 mg/kg, 30-90 min before exercise"))
add_source(Source(
    key="ketone_ester_studies",
    citation="Exogenous ketone ester ingestion: circulating beta-hydroxybutyrate "
             "and muscle substrate use during exercise in humans.",
    url="", population="trained adults", tissue="whole body and muscle biopsy",
    domain="acute ingestion, submaximal exercise"))
add_source(Source(
    key="heat_cold_exercise",
    citation="Thermoregulatory demand, skin blood flow and cardiovascular "
             "drift during exercise in the heat and in the cold.",
    url="", population="healthy adults", tissue="whole body",
    domain="exercise in ambient temperature extremes"))
add_source(Source(
    key="coq10_evidence",
    citation="Coenzyme Q10 supplementation in humans without a documented "
             "deficiency: no established effect on skeletal-muscle "
             "respiratory-chain capacity during exercise.",
    url="", population="mixed", tissue="mixed",
    domain="insufficient for a defensible parameter mapping"))
add_source(Source(
    key="antioxidant_evidence",
    citation="Antioxidant supplementation and exercise redox signalling in "
             "humans: contested effects, no quantitative mapping to a "
             "modelled "
             "flux.", url="", population="mixed", tissue="mixed",
    domain="research-only"))
add_source(Source(
    key="pbm_evidence",
    citation="Photobiomodulation and human skeletal-muscle performance: no "
             "defensible mapping from device output to a modelled metabolic "
             "quantity.", url="", population="mixed", tissue="mixed",
    domain="research-only"))

@dataclass
class AdapterSpec:
    """The complete declaration spec 1.3 requires of every adapter.

    Who was studied, in what tissue, over what domain, how well supported it is
    and what confounds it are *not* fields of this class: they live in the
    shared ``EffectEvidence`` that mechanisms use too, so that the two kinds of
    declared effect describe their evidence in one vocabulary rather than two
    that can drift.  What stays here is what is specific to a dose-shaped
    intervention -- the dose range, its unit, the timing window, the
    contraindications, and the conditions that make it not estimable.
    """
    name: str
    parameter_changed: str
    evidence: EffectEvidence
    dose_range: Tuple[float, float]
    dose_unit: str
    timing_range_min: Tuple[float, float]
    effect_summary: str
    effect_distribution: str
    interactions: List[str]
    contraindications: List[str]
    not_estimable_when: List[str]
    enabled: bool = True
    # apply(dose, timing_min, days_loaded, rng, state) -> dict of model handles
    apply: Optional[Callable] = None

    # Read-through accessors, so call sites and the catalogue keep speaking the
    # names they always did while there is exactly one place the value lives.
    @property
    def population(self) -> str:
        return self.evidence.population

    @property
    def tissue(self) -> str:
        return self.evidence.tissue

    @property
    def support(self) -> str:
        return self.evidence.support

    @property
    def evidence_grade(self) -> str:
        return self.evidence.evidence_grade

    @property
    def confounders(self) -> List[str]:
        return list(self.evidence.confounders)

    @property
    def source(self) -> str:
        return self.evidence.source_keys[0]

    def to_dict(self) -> Dict[str, Any]:
        d = {k: v for k, v in asdict(self).items()
             if k not in ("apply", "evidence")}
        d.update(population=self.population, tissue=self.tissue,
                 support=self.support, evidence_grade=self.evidence_grade,
                 confounders=self.confounders, source=self.source,
                 evidence=self.evidence.to_dict())
        d["source_detail"] = SOURCES[self.source].to_dict()
        return d


ADAPTERS: Dict[str, AdapterSpec] = {}


def register(spec: AdapterSpec) -> AdapterSpec:
    ADAPTERS[spec.name] = spec
    return spec


def _tri(rng, lo, mid, hi):
    return float(rng.triangular(lo, mid, hi))


# --------------------------------------------------------------------------
# Caffeine
# --------------------------------------------------------------------------

def _caffeine(dose_mg_per_kg, timing_min, days, rng, state):
    """Caffeine does not act on the electron transport chain.

    Spec 1.3 is explicit that the caffeine adapter is a pharmacokinetic /
    performance and heart-rate-confounding adapter with "no direct ETC boost".
    What is represented here is (a) a small reduction in the perceived cost of a
    given workload, modelled as a modest fall in the ATP demand needed to hold a
    pace, and (b) the fact that caffeine raises heart rate and thereby corrupts
    heart-rate-derived personalisation.
    """
    mg_per_kg = dose_mg_per_kg   # the adapter's declared dose unit is mg/kg
    # First-order absorption / elimination, peak near 45-60 min.
    ka, ke = 1.0 / 25.0, 1.0 / 300.0
    t = max(timing_min, 0.0)
    conc = (math.exp(-ke * t) - math.exp(-ka * t)) if t > 0 else 0.0
    conc = max(conc, 0.0) / 0.72                     # normalise the peak to 1
    dose_eff = min(1.0, mg_per_kg / 5.0) * conc
    effect = _tri(rng, 0.0, 0.020, 0.040) * dose_eff
    return {
        "demand_scale": 1.0 - effect,
        "_notes": [
            f"Caffeine {mg_per_kg:.1f} mg/kg taken {timing_min:.0f} min before "
            f"the run reduces the simulated metabolic cost of holding the pace "
            f"by {effect*100:.1f}%. No direct effect on the electron transport "
            "chain is represented, because none is supported.",
            "Caffeine raises heart rate at a given workload, so any "
            "heart-rate-derived personalisation in this scenario is "
            "confounded.",
        ],
        "_confounds": ["heart_rate"],
    }


register(AdapterSpec(
    name="caffeine",
    parameter_changed="whole-body metabolic cost of holding a given pace "
                      "(demand_scale); no mitochondrial parameter",
    evidence=EffectEvidence(
        source_keys=("caffeine_reviews",),
        population="healthy adults, habitual and non-habitual consumers",
        tissue="whole body / central nervous system",
        domain="acute dosing 1-6 mg/kg, 30-90 min before running",
        support="indirect", evidence_grade="moderate",
        confounders=(
            "raises heart rate at matched workload, corrupting "
            "heart-rate-derived intensity and cardio-fitness "
            "estimates",
            "habituation reduces the acute effect",
            "often co-ingested with carbohydrate")),
    dose_range=(1.0, 6.0),
    dose_unit="mg/kg",
    timing_range_min=(30.0, 90.0),
    effect_summary="Small reduction in the metabolic and perceptual cost of a "
                   "fixed workload; no direct respiratory-chain effect.",
    effect_distribution="triangular(0%, 2.0%, 4.0%) of demand at 5 mg/kg peak "
                        "concentration, scaled by a one-compartment "
                        "pharmacokinetic profile",
    interactions=["additive perceptual effect with pre-run carbohydrate",
                  "compounds the heart-rate confounding of beta blockade in "
                  "the "
                  "opposite direction"],
    contraindications=["arrhythmia", "pregnancy", "anxiety disorder"],
    not_estimable_when=["dose above 9 mg/kg", "timing more than 6 h before the "
                        "run", "person takes a beta blocker (heart-rate "
                        "personalisation already invalid)"],
    apply=_caffeine))


# --------------------------------------------------------------------------
# Creatine
# --------------------------------------------------------------------------

def _creatine(dose_g, timing_min, days, rng, state):
    """Creatine acts on the phosphocreatine pool and the creatine-kinase system,
    which are both explicit state variables here."""
    if days < 3:
        return {"_status": NOT_ESTIMABLE,
                "_notes": ["Muscle total creatine rises over days of loading. "
                           "With fewer than three days of loading there is no "
                           "defensible pool change to apply, so the effect is "
                           "reported as not estimable rather than guessed."]}
    saturation = 1.0 - math.exp(-days / 6.0)
    dose_f = min(1.0, dose_g / 20.0)
    gain = _tri(rng, 0.02, 0.10, 0.20) * saturation * dose_f
    return {
        "cr_pool_scale": 1.0 + gain,
        "_notes": [f"Creatine loading raises the modelled total creatine pool "
                   f"by {gain*100:.1f}%, which enlarges the phosphocreatine "
                   "buffer and the creatine-kinase flux available at the "
                   "onset "
                   "of exercise and between intervals.",
                   "Responders and non-responders differ substantially; "
                   "people "
                   "with already-high muscle creatine gain little."],
    }


register(AdapterSpec(
    name="creatine",
    parameter_changed="creatine_total (the phosphocreatine/creatine pool) and "
                      "hence creatine-kinase buffering capacity",
    evidence=EffectEvidence(
        source_keys=("creatine_reviews",),
        population="healthy adults, mixed training status",
        tissue="vastus lateralis",
        domain="oral loading and maintenance dosing over days to weeks",
        support="direct", evidence_grade="strong",
        confounders=(
            "baseline muscle creatine strongly predicts response",
            "acute water retention changes body mass and therefore "
            "the running-demand calculation",
            "co-ingested carbohydrate increases uptake")),
    dose_range=(3.0, 25.0),
    dose_unit="g/day",
    timing_range_min=(0.0, 0.0),
    effect_summary="Raises muscle total creatine by roughly 2-20% depending on "
                   "baseline content, dose and loading duration.",
    effect_distribution="triangular(2%, 10%, 20%) increase in the total "
                        "creatine pool, scaled by loading saturation "
                        "1 - exp(-days/6)",
    interactions=["larger effect on interval sessions than on continuous runs "
                  "because the phosphocreatine buffer is reused each bout"],
    contraindications=["chronic kidney disease", "reduced eGFR"],
    not_estimable_when=["fewer than 3 days of loading",
                        "no information on loading duration"],
    apply=_creatine))


# --------------------------------------------------------------------------
# Dietary nitrate
# --------------------------------------------------------------------------

def _nitrate(dose_mmol, timing_min, days, rng, state):
    if not (90.0 <= timing_min <= 360.0) and days < 3:
        return {"_status": NOT_ESTIMABLE,
                "_notes": ["Plasma nitrite peaks roughly 2-3 h after an acute "
                           "dose. Outside that window, and without several "
                           "days "
                           "of loading, the effect is not estimable."]}
    dose_f = min(1.0, dose_mmol / 8.0)
    window = 1.0 if days >= 3 else float(np.interp(
        timing_min, [90, 150, 180, 240, 360], [0.5, 1.0, 1.0, 0.8, 0.3]))
    reduction = _tri(rng, 0.0, 0.024, 0.05) * dose_f * window
    trained_damping = 1.0 if state.vo2max_sea < 60 else 0.45
    reduction *= trained_damping
    return {
        "o2_cost_scale": 1.0 - reduction,
        "_notes": [f"Dietary nitrate lowers the modelled oxygen cost of the run "
                   f"by {reduction*100:.1f}%.",
                   "The effect is consistently smaller, and often absent, in "
                   "highly trained endurance athletes; this scenario applies "
                   "a "
                   f"damping factor of {trained_damping:.2f}.",
                   "Antibacterial mouthwash abolishes the oral "
                   "nitrate-reducing step and with it most of the effect."],
    }


register(AdapterSpec(
    name="nitrate",
    parameter_changed="o2_cost_scale -- the oxygen consumed per unit of "
                      "respiratory-chain flux (mitochondrial efficiency and "
                      "contractile efficiency combined)",
    evidence=EffectEvidence(
        source_keys=("nitrate_reviews",),
        population="healthy adults; effect attenuated in highly trained endurance "
               "athletes",
        tissue="whole body, with skeletal-muscle mechanisms proposed",
        domain="acute dosing 90-360 min before exercise, or multi-day loading",
        support="indirect", evidence_grade="moderate",
        confounders=(
            "antibacterial mouthwash abolishes the effect",
            "effect attenuated or absent in highly trained athletes",
            "background dietary nitrate intake is rarely recorded")),
    dose_range=(4.0, 12.0),
    dose_unit="mmol nitrate",
    timing_range_min=(90.0, 360.0),
    effect_summary="Reduces the oxygen cost of submaximal exercise by roughly "
                   "1-5%.",
    effect_distribution="triangular(0%, 2.4%, 5%) reduction in oxygen cost, "
                        "scaled by dose, timing window and training status",
    interactions=["no established interaction with carbohydrate availability"],
    contraindications=["nitrate-containing vasodilator medication",
                       "hypotension"],
    not_estimable_when=["timing outside 90-360 min without multi-day loading",
                        "dose above 16 mmol"],
    apply=_nitrate))


# --------------------------------------------------------------------------
# Exogenous ketones
# --------------------------------------------------------------------------

def _ketones(dose_g, timing_min, days, rng, state):
    if timing_min > 120:
        return {"_status": NOT_ESTIMABLE,
                "_notes": ["Circulating beta-hydroxybutyrate from an oral ester "
                           "returns to baseline within about two hours; an "
                           "earlier dose leaves nothing to model."]}
    dose_f = min(1.0, dose_g / 30.0)
    decay = float(np.interp(timing_min, [0, 15, 30, 60, 90, 120],
                            [0.4, 0.9, 1.0, 0.85, 0.55, 0.2]))
    bhb = _tri(rng, 0.8, 2.2, 4.5) * dose_f * decay
    return {
        "blood_bhb_override": float(state.blood_bhb + bhb),
        "_notes": [f"An exogenous ketone dose raises the modelled arterial "
                   f"beta-hydroxybutyrate by {bhb:.2f} mmol/L at the start of "
                   "the run, giving the muscle an additional oxidisable "
                   "substrate.",
                   "Ketone availability is modelled; a performance benefit is "
                   "not asserted, and the evidence for one during running is "
                   "mixed.",
                   "Gastrointestinal intolerance is common at higher doses "
                   "and "
                   "is not represented."],
    }


register(AdapterSpec(
    name="exogenous_ketones",
    parameter_changed="blood beta-hydroxybutyrate available for uptake and "
                      "oxidation (blood_bhb)",
    evidence=EffectEvidence(
        source_keys=("ketone_ester_studies",),
        population="trained adults",
        tissue="whole body; muscle uptake inferred",
        domain="acute oral ester ingestion within 2 h of exercise",
        support="adjacent", evidence_grade="moderate",
        confounders=(
            "gastrointestinal symptoms alter pacing and are not "
            "modelled",
            "ketones suppress glycolysis and lipolysis, so the net "
            "substrate effect is not simply additive",
            "acid load of ketone salts differs from esters")),
    dose_range=(10.0, 40.0),
    dose_unit="g ketone ester",
    timing_range_min=(0.0, 120.0),
    effect_summary="Raises circulating beta-hydroxybutyrate by roughly "
                   "1-4.5 mmol/L for one to two hours.",
    effect_distribution="triangular(0.8, 2.2, 4.5) mmol/L at a 30 g dose, "
                        "scaled by a time-course profile",
    interactions=["interacts with pre-run carbohydrate: insulin suppresses "
                  "endogenous ketogenesis and alters clearance",
                  "compounds with a fasted state, where baseline ketones are "
                  "already raised"],
    contraindications=["type 1 diabetes", "pregnancy"],
    not_estimable_when=["dose taken more than 2 h before the run",
                        "ketone salts rather than esters, where the sodium "
                        "load "
                        "changes the response"],
    apply=_ketones))


# --------------------------------------------------------------------------
# Heat and cold exposure
# --------------------------------------------------------------------------

def _thermal(dose_c, timing_min, days, rng, state):
    """dose is ambient temperature in degrees Celsius."""
    t = dose_c
    if t > 35.0 or t < -15.0:
        return {"_status": NOT_ESTIMABLE,
                "_notes": ["Ambient temperature outside -15 to 35 degrees "
                           "Celsius is beyond the represented "
                           "thermoregulatory "
                           "range."]}
    if t > 20.0:
        excess = (t - 20.0) / 15.0
        demand_up = _tri(rng, 0.0, 0.035, 0.08) * excess
        perf_down = _tri(rng, 0.0, 0.05, 0.12) * excess
        note = (f"Running at {t:.0f} C raises the modelled metabolic demand by "
                f"{demand_up*100:.1f}% and diverts {perf_down*100:.1f}% of "
                "muscle blood flow to skin, lowering the oxygen delivered to "
                "working muscle.")
    else:
        excess = (10.0 - t) / 25.0 if t < 10.0 else 0.0
        demand_up = _tri(rng, 0.0, 0.02, 0.05) * max(excess, 0.0)
        perf_down = 0.0
        note = (f"Running at {t:.0f} C raises the modelled metabolic demand by "
                f"{demand_up*100:.1f}% through shivering and added clothing "
                "and clothing mass; muscle perfusion is not reduced.")
    return {"demand_scale": 1.0 + demand_up,
            "perfusion_scale": 1.0 - perf_down,
            "_notes": [note,
                       "Core temperature, sweat rate and progressive "
                       "dehydration are not modelled dynamically, so long hot "
                       "runs are represented less well than short ones."]}


register(AdapterSpec(
    name="thermal_environment",
    parameter_changed="demand_scale (thermoregulatory metabolic cost) and "
                      "perfusion_scale (muscle blood-flow share lost to skin)",
    evidence=EffectEvidence(
        source_keys=("heat_cold_exercise",),
        population="healthy adults, unacclimatised",
        tissue="whole body",
        domain="running in ambient temperatures of -15 to 35 degC",
        support="indirect", evidence_grade="moderate",
        confounders=(
            "humidity, wind and solar load dominate the real thermal "
            "strain and are not inputs here",
            "heat acclimatisation substantially reduces the effect",
            "hydration status interacts strongly")),
    dose_range=(-15.0, 35.0),
    dose_unit="degC ambient",
    timing_range_min=(0.0, 0.0),
    effect_summary="Heat raises metabolic demand and competes for blood flow; "
                   "cold raises demand modestly without reducing muscle "
                   "perfusion.",
    effect_distribution="triangular effects scaled linearly by the departure "
                        "from a 20 degC reference",
    interactions=["compounds with dehydration flagged in input QC",
                  "heat effects grow with run duration in a way this static "
                  "adapter understates"],
    contraindications=["history of exertional heat illness"],
    not_estimable_when=["ambient temperature outside -15 to 35 degC",
                        "runs longer than 90 min in heat, where progressive "
                        "hyperthermia dominates"],
    apply=_thermal))


# --------------------------------------------------------------------------
# Disabled adapters (spec 1.3 requires these be present but not enabled)
# --------------------------------------------------------------------------

register(AdapterSpec(
    name="coq10",
    parameter_changed="would be a respiratory-chain parameter",
    evidence=EffectEvidence(
        source_keys=("coq10_evidence",),
        population="not established for people without a documented deficiency",
        tissue="not established for exercising human skeletal muscle",
        domain="no applicable dosing domain: nothing supports a mapping",
        support="assumed", evidence_grade="insufficient",
        confounders=(
            "plasma coenzyme Q10 does not track muscle content",
            "statin users are a distinct population with different "
            "evidence")),
    dose_range=(0.0, 0.0),
    dose_unit="mg",
    timing_range_min=(0.0, 0.0),
    effect_summary="Disabled. Spec 1.3 permits a context-specific electron "
                   "transport chain parameter adapter but requires it to be "
                   "disabled without applicable evidence. No defensible "
                   "mapping "
                   "exists from supplementation in a person without a "
                   "documented deficiency to a respiratory-chain parameter in "
                   "running muscle.",
    effect_distribution="none",
    interactions=[],
    contraindications=[],
    not_estimable_when=["always, in the absence of a documented deficiency"],
    enabled=False))

register(AdapterSpec(
    name="antioxidants",
    parameter_changed="would be a redox-signalling parameter",
    evidence=EffectEvidence(
        source_keys=("antioxidant_evidence",),
        population="mixed",
        tissue="mixed",
        domain="no applicable dosing domain: nothing supports a mapping",
        support="assumed", evidence_grade="insufficient",
        confounders=(
            "chronic high-dose antioxidants may blunt training "
            "adaptation, which is a different question from acute "
            "run mechanism",)),
    dose_range=(0.0, 0.0),
    dose_unit="mg",
    timing_range_min=(0.0, 0.0),
    effect_summary="Research-only. The engine models no reactive-oxygen-species "
                   "concentration and spec 3.4 forbids reporting one, so "
                   "there "
                   "is no modelled quantity for an antioxidant adapter to "
                   "change.",
    effect_distribution="none",
    interactions=[],
    contraindications=[],
    not_estimable_when=["always in version 1"],
    enabled=False))

register(AdapterSpec(
    name="photobiomodulation",
    parameter_changed="would be a respiratory-chain or perfusion parameter",
    evidence=EffectEvidence(
        source_keys=("pbm_evidence",),
        population="mixed",
        tissue="mixed",
        domain="no applicable dosing domain: nothing supports a mapping",
        support="assumed", evidence_grade="insufficient",
        confounders=(
            "device parameters are rarely reported consistently",
            "skin and adipose thickness change delivered dose")),
    dose_range=(0.0, 0.0),
    dose_unit="J/cm2",
    timing_range_min=(0.0, 0.0),
    effect_summary="Research-only. No defensible mapping exists from device "
                   "wavelength, irradiance and dose to any quantity this "
                   "model "
                   "represents.",
    effect_distribution="none",
    interactions=[],
    contraindications=[],
    not_estimable_when=["always in version 1"],
    enabled=False))


# --------------------------------------------------------------------------
# Intervention-to-state mappings: registered, disabled, and separate
# --------------------------------------------------------------------------
# The Mechanism Lab can set a tissue state. These are the interventions people
# reach for when they want that state, and the arrow between them is the
# uncertain mapping this product refuses to fake:
#
#     TRT --------------?-------------- androgen exposure
#     NAD+ / NR / NMN --?-------------- tissue NAD state
#     glutathione / NAC ?-------------- tissue redox state
#
# Each is registered here as a *disabled adapter* rather than left out, so that
# a user who asks for one gets the reason instead of a silence. And they are
# adapters, not mechanisms, which is what guarantees the important property:
# the two registries do not reach into each other, so a disabled mapping cannot
# quietly activate a mechanism transform. A test asserts exactly that.

add_source(Source(
    key="nad_intervention_evidence",
    citation="Intravenous NAD+ and oral NAD precursors (nicotinamide "
             "riboside, nicotinamide mononucleotide): no established mapping "
             "from a dose to a skeletal-muscle mitochondrial NAD state in an "
             "exercising person.",
    url="https://pubmed.ncbi.nlm.nih.gov/33492681/",
    population="healthy adults; small pilot and short-course trials",
    tissue="plasma metabolites, with limited muscle measurement",
    domain="insufficient for a defensible dose-to-tissue-state mapping"))

add_source(Source(
    key="glutathione_intervention_evidence",
    citation="Injectable and oral glutathione and N-acetylcysteine: no "
             "established mapping from a dose to a skeletal-muscle redox "
             "state, and no modelled redox quantity in this engine to map "
             "onto. See docs/RFC-REDOX.md.",
    url="", population="mixed", tissue="mixed",
    domain="research-only; blocked on both evidence and model structure"))

add_source(Source(
    key="trt_mapping_evidence",
    citation="Prescribed testosterone therapy: the dose-to-achieved-exposure "
             "step depends on formulation, route, adherence and individual "
             "pharmacokinetics, and is not modelled here. Achieved exposure "
             "and observed mediators are inputs to the Mechanism Lab instead.",
    url="https://www.fda.gov/drugs/drug-alerts-and-statements/fda-issues-"
        "class-wide-labeling-changes-testosterone-products",
    population="adults prescribed testosterone products",
    tissue="serum and whole-body composition",
    domain="no defensible dose-to-exposure mapping in this engine"))


def _disabled_mapping(name: str, would_change: str, source: str,
                      population: str, tissue: str, summary: str,
                      confounders: tuple, reason: str,
                      dose_unit: str = "mg") -> None:
    register(AdapterSpec(
        name=name,
        parameter_changed=would_change,
        evidence=EffectEvidence(
            source_keys=(source,), population=population, tissue=tissue,
            domain="no defensible dose-to-tissue-state mapping",
            support="assumed", evidence_grade="insufficient",
            confounders=confounders),
        dose_range=(0.0, 0.0), dose_unit=dose_unit,
        timing_range_min=(0.0, 0.0),
        effect_summary=summary,
        effect_distribution="none",
        interactions=[],
        contraindications=[],
        not_estimable_when=[reason],
        enabled=False))


_disabled_mapping(
    name="nad_iv",
    would_change="would be the mitochondrial or cytosolic NAD state",
    source="nad_intervention_evidence",
    population="small healthy-adult pilots",
    tissue="plasma metabolites; skeletal-muscle NAD rarely measured",
    summary="Disabled. Intravenous NAD+ raises circulating metabolites, but "
            "nothing establishes what it does to the mitochondrial NAD pool "
            "of running muscle. The Mechanism Lab can set that pool directly "
            "as a hypothetical state; it does not claim any intervention "
            "produces it.",
    confounders=("plasma NAD metabolites do not track muscle matrix NAD",
                 "the matrix pool cannot be measured in an intact exercising "
                 "person"),
    reason="always: no mapping from a dose to a muscle NAD state exists")

_disabled_mapping(
    name="nad_precursor",
    would_change="would be the mitochondrial or cytosolic NAD state",
    source="nad_intervention_evidence",
    population="healthy adults in short-course trials",
    tissue="skeletal muscle, with small and inconsistent NAD responses",
    summary="Disabled. Oral nicotinamide riboside and nicotinamide "
            "mononucleotide produce small and inconsistent muscle NAD "
            "responses, and none of them has been mapped onto a matrix pool "
            "size in exercising muscle.",
    confounders=("muscle NAD responses to oral precursors are small and "
                 "inconsistent across trials",
                 "whole-tissue NAD does not resolve the matrix compartment "
                 "this engine models"),
    reason="always: no mapping from a dose to a muscle NAD state exists")

_disabled_mapping(
    name="glutathione",
    would_change="would be a muscle or mitochondrial redox state",
    source="glutathione_intervention_evidence",
    population="mixed", tissue="mixed",
    summary="Disabled twice over. There is no established mapping from a "
            "glutathione dose to a muscle redox state, and this engine models "
            "no redox quantity for such a mapping to land on. See "
            "docs/RFC-REDOX.md.",
    confounders=("oral glutathione is largely hydrolysed before absorption",
                 "the engine has no reactive-oxygen-species source flux, so "
                 "there is nothing for a redox change to act through"),
    reason="always: no dose-to-state mapping and no modelled redox quantity")

_disabled_mapping(
    name="nac",
    would_change="would be a muscle or mitochondrial redox state",
    source="glutathione_intervention_evidence",
    population="mixed", tissue="mixed",
    summary="Disabled for the same two reasons as glutathione: no defensible "
            "dose-to-state mapping, and no modelled redox quantity in this "
            "engine. Chronic high-dose antioxidant use may also blunt "
            "training adaptation, which is a different question from acute "
            "run mechanism and equally unmodelled here.",
    confounders=("N-acetylcysteine effects on exercise are contested and "
                 "dose-dependent in both directions",
                 "the engine has no reactive-oxygen-species source flux"),
    reason="always: no dose-to-state mapping and no modelled redox quantity")

_disabled_mapping(
    name="testosterone_therapy",
    would_change="would be a sustained androgen exposure, and through it the "
                 "mediators the Mechanism Lab already models",
    source="trt_mapping_evidence",
    population="adults prescribed testosterone products",
    tissue="serum and whole-body composition",
    summary="Disabled as a dose adapter, and deliberately so. The step from a "
            "prescription to an achieved exposure depends on formulation, "
            "route, adherence and individual pharmacokinetics, none of which "
            "this engine models. What it can do instead is take an *observed* "
            "baseline exposure and observed mediators and ask what a "
            "different sustained exposure would mean -- that is the "
            "sustained_androgen_exposure mechanism, and it converts nothing "
            "into a dose.",
    confounders=("achieved concentrations vary widely between formulations "
                 "and between people on the same regimen",
                 "trough and peak concentrations differ substantially on "
                 "injectable regimens, and a single draw may catch either"),
    reason="always: use the sustained_androgen_exposure mechanism with an "
           "observed baseline instead; no dose-to-exposure mapping exists here")


# --------------------------------------------------------------------------
# Application
# --------------------------------------------------------------------------

def apply_adapters(uses, state, rng, person=None) -> Tuple[Dict[str, float],
                                                           List[EffectOutcome]]:
    """Apply the requested experimental inputs to one sampled personal state.

    Returns the model handles the muscle core understands, plus a per-adapter
    outcome record.  Handles are multiplicative and default to 1.0, so an
    adapter that is disabled or not estimable changes nothing.

    The outcome record is the shared ``EffectOutcome`` that mechanisms also
    report, so a caller can render an adapter and a mechanism through one code
    path instead of two.
    """
    handles: Dict[str, float] = {}
    outcomes: List[EffectOutcome] = []
    for use in uses:
        spec = ADAPTERS.get(use.adapter)
        if spec is None:
            outcomes.append(EffectOutcome(
                use.adapter, NOT_ESTIMABLE,
                reason="No adapter is registered for this input, so it cannot "
                       "change the simulation."))
            continue
        if not spec.enabled:
            outcomes.append(EffectOutcome(
                use.adapter, DISABLED, notes=(spec.effect_summary,),
                reason=f"Adapter is registered but disabled: "
                       f"{spec.not_estimable_when[0] if spec.not_estimable_when else 'no applicable evidence'}."))
            continue
        lo, hi = spec.dose_range
        if use.dose and not (lo * 0.5 <= use.dose <= hi * 1.5):
            outcomes.append(EffectOutcome(
                use.adapter, NOT_ESTIMABLE,
                reason=f"Dose {use.dose} {use.dose_unit} is outside the "
                       f"supported range {lo}-{hi} {spec.dose_unit}."))
            continue
        # Contraindication screen against the person's clinical context.
        if person is not None:
            dx = {d.strip().lower().replace(" ", "_")
                  for d in person.clinical.diagnoses}
            if person.clinical.pregnant:
                dx.add("pregnancy")
            hit = dx.intersection({c.lower().replace(" ", "_")
                                   for c in spec.contraindications})
            if hit:
                outcomes.append(EffectOutcome(
                    use.adapter, NOT_ESTIMABLE,
                    reason=f"Contraindication flag: {', '.join(sorted(hit))}. "
                           "The engine will not simulate this experimental "
                           "input for this person."))
                continue
        assert spec.apply is not None, "registered adapters always define apply"
        res = spec.apply(use.dose, use.timing_min_before, use.days_loaded,
                         rng, state)
        if res.get("_status") == NOT_ESTIMABLE:
            outcomes.append(EffectOutcome(
                use.adapter, NOT_ESTIMABLE,
                notes=tuple(res.get("_notes", [])),
                reason=res.get("_notes", ["not estimable"])[0]))
            continue
        hs = {k: v for k, v in res.items() if not k.startswith("_")}
        for k, v in hs.items():
            if k.endswith("_override"):
                handles[k] = v
            else:
                handles[k] = handles.get(k, 1.0) * v
        outcomes.append(EffectOutcome(
            use.adapter, ACTIVE, parameter_changes=hs,
            notes=tuple(res.get("_notes", [])),
            confounds=tuple(res.get("_confounds", [])),
            represented_paths=(spec.parameter_changed,),
            provenance={"kind": "experimental_adapter",
                        "dose": use.dose, "dose_unit": use.dose_unit,
                        "timing_min_before": use.timing_min_before,
                        "days_loaded": use.days_loaded,
                        "evidence": spec.evidence.to_dict()}))
    return handles, outcomes


def catalogue() -> List[Dict[str, Any]]:
    return [s.to_dict() for s in ADAPTERS.values()]
