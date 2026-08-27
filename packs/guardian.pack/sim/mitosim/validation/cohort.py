"""C. Virtual-person differentiation tests (spec 2.10.C).

A preregistered synthetic cohort spanning body mass and lean mass, running
economy, aerobic capacity, haemoglobin, training history, initial glycogen
uncertainty, glycaemic and lipid phenotypes, and fed / fasted / recently
exercised states is run through the same standardized scenario set.

The test succeeds when:

1. Mechanistically relevant input differences generate stable, attributable
   output differences.
2. Irrelevant input differences generate little or no difference.
3. Relationships are directionally plausible across the supported domain.
4. Conclusions degrade gracefully as inputs become missing or noisy.
5. A single uncertain lab result cannot dominate the output without evidence.
"""

from __future__ import annotations

import datetime as dt
from typing import Any, Dict, List, Tuple

import numpy as np

from ..ensemble import run_ensemble
from ..inputs import (LabPanel, LabValue, NutritionState, TrainingHistory,
                      ClinicalContext)
from ..scenario import Intensity
from .common import Check, base_scenario, reference_person, med, p_direction

N = 32
STANDARD_SCENARIOS = [
    ("easy_40min", dict(intensity=0.60, duration=40)),
    ("tempo_30min", dict(intensity=0.80, duration=30)),
    ("long_fasted_75min", dict(intensity=0.62, duration=75, hsm=14)),
    ("long_fed_120min", dict(intensity=0.65, duration=120, hsm=4)),
]


def _person(tag: str, **kw):
    p = reference_person(subject_id=tag, **{k: v for k, v in kw.items()
                                            if k in ("vo2max", "mass", "bf",
                                                     "level", "km", "age",
                                                     "sex", "labs", "elev")})
    if "nutrition" in kw:
        p.nutrition = kw["nutrition"]
    if "clinical" in kw:
        p.clinical = kw["clinical"]
    return p


def cohort() -> List[Tuple[str, Any, str]]:
    """(tag, person, what-varies) -- the preregistered synthetic cohort."""
    lab = lambda a, v, u, lo=None, hi=None, days=30: LabValue(
        a, v, u, dt.date(2026, 8, 26) - dt.timedelta(days=days),
        fasting=True, ref_low=lo, ref_high=hi)
    people = [
        ("reference", _person("reference"), "baseline trained runner"),
        ("low_capacity", _person("low_capacity", vo2max=40,
                                 level="recreational", km=20),
         "aerobic capacity"),
        ("high_capacity", _person("high_capacity", vo2max=68,
                                  level="competitive", km=110),
         "aerobic capacity"),
        ("heavier", _person("heavier", mass=92, bf=22), "body and lean mass"),
        ("lighter", _person("lighter", mass=57, bf=11), "body and lean mass"),
        ("female", _person("female", sex="female", mass=60, bf=23, vo2max=48),
         "sex at birth and body composition"),
        ("older", _person("older", age=58, vo2max=44), "age"),
        ("anaemic", _person("anaemic", labs=[lab("hemoglobin", 10.8, "g/dL",
                                                 13.5, 17.5)]),
         "haemoglobin"),
        ("polycythaemic", _person("polycythaemic",
                                  labs=[lab("hemoglobin", 17.4, "g/dL",
                                            13.5, 17.5)]),
         "haemoglobin"),
        ("prediabetic", _person("prediabetic", labs=[
            lab("fasting_glucose", 6.4, "mmol/L", 3.9, 5.5),
            lab("hba1c", 6.0, "%", 4.0, 5.6),
            lab("fasting_insulin", 18.0, "mIU/L", 2.0, 12.0),
            lab("triglycerides", 2.6, "mmol/L", 0.0, 1.7)]),
         "glycaemic and lipid phenotype"),
        ("glycogen_depleted", _person(
            "glycogen_depleted",
            nutrition=NutritionState(prev_24h_cho_g=90,
                                     hours_since_last_meal=3,
                                     exercise_since_last_high_cho_meal=True,
                                     hard_sessions_last_48h=2)),
         "initial glycogen"),
        ("carb_loaded", _person(
            "carb_loaded",
            nutrition=NutritionState(prev_24h_cho_g=760,
                                     hours_since_last_meal=2)),
         "initial glycogen"),
        ("altitude_native", _person("altitude_native", elev=2200),
         "habitual elevation"),
        ("no_data", _person("no_data"), "missing inputs"),
    ]
    # The no-data person keeps only body measurements.
    nd = people[-1][1]
    nd.wearable.vo2max_estimate_ml_kg_min = None
    nd.wearable.resting_hr_bpm = None
    nd.nutrition = NutritionState()
    nd.training = TrainingHistory()
    # Irrelevant-variation twins: identical mechanics, different inert facts.
    twin_a = _person("twin_a")
    twin_b = _person("twin_b")
    twin_b.labs = LabPanel([lab("vitamin_d", 22.0, "ng/mL", 30, 100),
                            lab("tsh", 2.1, "mIU/L", 0.4, 4.0),
                            lab("alt", 24.0, "U/L", 7, 55)])
    twin_b.subject_id = "twin_b"
    people += [("twin_a", twin_a, "irrelevant control"),
               ("twin_b", twin_b, "irrelevant control")]
    return people


KEYS = ["oxidative_atp_fraction", "fat_carbon_fraction", "glycogen_used",
        "blood_lactate_peak", "spare_oxidative_capacity", "muscle_vo2",
        "pcr_end_fraction", "time_to_glycogen_limit"]


def run(n: int = N, quick: bool = False) -> Tuple[List[Check], Dict[str, Any]]:
    people = cohort()
    scenarios = [s for s in STANDARD_SCENARIOS
                 if not (quick and s[0] == "long_fed_120min")]
    results: Dict[str, Dict[str, Any]] = {}
    for tag, person, _ in people:
        results[tag] = {}
        for sname, kw in scenarios:
            out = run_ensemble(person, base_scenario(**kw), n=n, seed=1234)
            results[tag][sname] = out

    checks: List[Check] = []

    def contrast(tag_a, tag_b, sname, key, expect_increase, statement, evidence):
        a, b = results[tag_a][sname], results[tag_b][sname]
        p = p_direction(a, b, key, expect_increase)
        if p is None:
            return Check("C. Virtual cohort", f"{tag_a}_vs_{tag_b}:{key}", False,
                         "output missing", evidence=evidence)
        ok = p >= 0.80
        return Check(
            "C. Virtual cohort", f"{tag_a}_vs_{tag_b}:{key}", ok,
            f"{statement} Median {med(a, key):.4g} -> {med(b, key):.4g}; "
            f"direction holds in {p*100:.0f}% of paired samples.",
            expected="P >= 0.80", observed=f"{p:.2f}", evidence=evidence)

    # 1. Relevant differences produce attributable differences -- but only in
    #    the quantities that should differ. Spare oxidative capacity at a
    #    matched *relative* effort is defined against each person's own ceiling,
    #    so it must NOT separate the two; asserting that it does would be
    #    asserting an artefact.
    ea = results["low_capacity"]["easy_40min"].get("spare_oxidative_capacity")
    eb = results["high_capacity"]["easy_40min"].get("spare_oxidative_capacity")
    rel = abs(eb.median() - ea.median()) / max(abs(ea.median()), 1e-9)
    checks.append(Check(
        "C. Virtual cohort",
        "relative_effort_normalises_spare_capacity", rel < 0.15,
        f"At a matched fraction of each person's own aerobic ceiling, spare "
        f"oxidative capacity differs between a 40 and a 68 mL/kg/min runner by "
        f"only {rel*100:.1f}%. That is the correct behaviour: relative effort is "
        "defined against the ceiling, so the quantity that must separate them "
        "is the absolute oxygen flux, checked next.",
        expected="< 15%", observed=f"{rel*100:.1f}%",
        evidence="Definition of relative intensity"))
    checks.append(contrast(
        "low_capacity", "high_capacity", "easy_40min", "muscle_vo2", True,
        "The fitter person sustains a higher absolute muscle oxygen flux at the "
        "same relative effort.", "Aerobic capacity"))
    checks.append(contrast(
        "anaemic", "polycythaemic", "tempo_30min", "muscle_vo2", True,
        "Higher haemoglobin raises arterial oxygen content and therefore the "
        "feasible oxidative flux.",
        "Ekblom 1975 (PMID 1150596): experimental changes in arterial oxygen "
        "content change maximal oxygen consumption"))
    checks.append(contrast(
        "glycogen_depleted", "carb_loaded", "long_fasted_75min",
        "glycogen_remaining", True,
        "A carbohydrate-loaded runner finishes a long run with more glycogen "
        "left than a depleted one.",
        "Glycogen review PMC5872716; supercompensation PMC12399638"))
    long_key = ("long_fed_120min" if "long_fed_120min" in results["reference"]
                else "long_fasted_75min")
    checks.append(contrast(
        "carb_loaded", "glycogen_depleted", long_key,
        "fat_carbon_fraction", True,
        "Over a two-hour run, where the depleted store is actually approached, "
        "less available carbohydrate pushes the muscle further onto fat. The "
        "contrast is deliberately tested on the long run: when both stores are "
        "comfortably adequate, glycogen content has only a modest influence on "
        "fuel selection and the engine should not manufacture a large one.",
        "Substrate availability and fuel selection; glycogen review "
        "PMC5872716"))
    checks.append(contrast(
        "carb_loaded", "glycogen_depleted", long_key,
        "time_to_glycogen_limit", False,
        "A depleted runner reaches glycogen limitation sooner on a long run.",
        "Glycogen review PMC5872716"))
    checks.append(contrast(
        "heavier", "lighter", "easy_40min", "muscle_vo2", False,
        "Mass-specific muscle oxygen flux is not strongly mass-dependent at a "
        "matched relative effort; the absolute cost is.",
        "Cost of transport scales with body mass", ))

    # 2. Irrelevant differences produce no difference.
    for key in ("oxidative_atp_fraction", "glycogen_used", "muscle_vo2",
                "blood_lactate_peak"):
        a, b = results["twin_a"]["easy_40min"], results["twin_b"]["easy_40min"]
        ma, mb = med(a, key), med(b, key)
        assert ma is not None and mb is not None
        rel = abs(mb - ma) / max(abs(ma), 1e-9)
        checks.append(Check(
            "C. Virtual cohort", f"irrelevant_labs_no_effect:{key}", rel < 0.02,
            f"Adding a vitamin D, TSH and ALT panel with no defensible mapping "
            f"to a modelled quantity changes {key} by {rel*100:.3f}%. "
            "Routine bloodwork that the engine cannot map must not move the "
            "simulation.",
            expected="< 2%", observed=f"{rel*100:.3f}%",
            evidence="Spec 1.1: 'If no defensible mapping exists, a laboratory "
                     "value should not change the simulation.'"))

    # 3. A single uncertain lab must not dominate.
    a = results["reference"]["tempo_30min"]
    b = results["prediabetic"]["tempo_30min"]
    for key in ("oxidative_atp_fraction", "glycogen_used"):
        ma, mb = med(a, key), med(b, key)
        assert ma is not None and mb is not None
        rel = abs(mb - ma) / max(abs(ma), 1e-9)
        checks.append(Check(
            "C. Virtual cohort", f"single_lab_not_dominant:{key}", rel < 0.25,
            f"A glycaemic and lipid phenotype graded low-to-moderate strength "
            f"moves {key} by {rel*100:.1f}%. A weak prior must shift the "
            "posterior, not determine it.",
            expected="< 25%", observed=f"{rel*100:.1f}%",
            evidence="Spec 1.1 strength column; spec 2.10.C criterion 5"))

    # 4. Graceful degradation with missing inputs.
    a = results["reference"]["easy_40min"]
    b = results["no_data"]["easy_40min"]
    widened = 0
    total = 0
    for key in KEYS:
        ea, eb = a.get(key), b.get(key)
        if ea is None or eb is None:
            continue
        wa = np.subtract(*reversed(ea.interval(0.80)))
        wb = np.subtract(*reversed(eb.interval(0.80)))
        ra = abs(wa / max(abs(ea.median()), 1e-9))
        rb = abs(wb / max(abs(eb.median()), 1e-9))
        total += 1
        if rb >= ra * 0.98:
            widened += 1
    checks.append(Check(
        "C. Virtual cohort", "missing_inputs_widen_not_sharpen",
        widened >= max(1, int(0.75 * total)),
        f"Stripping the wearable, training and nutrition inputs widens or holds "
        f"the relative 80% interval for {widened} of {total} outputs. "
        "Conclusions must degrade gracefully as inputs go missing, never "
        "acquire false precision.",
        expected=">= 75% of outputs", observed=f"{widened}/{total}",
        evidence="Spec 2.10.C criterion 4 and 2.10.E"))

    # An input that should not matter must not matter.
    for key in ("muscle_vo2", "oxidative_atp_fraction", "glycogen_used"):
        a = results["reference"]["easy_40min"].get(key)
        b = results["altitude_native"]["easy_40min"].get(key)
        rel_d = abs(b.median() - a.median()) / max(abs(a.median()), 1e-9)
        checks.append(Check(
            "C. Virtual cohort", f"habitual_elevation_no_effect_at_sea_level:{key}",
            rel_d < 0.02,
            f"Living at 2200 m changes {key} by {rel_d*100:.3f}% for a run at "
            "sea level. Habitual elevation is only supposed to matter when the "
            "run is itself at altitude, where it offsets part of the acute "
            "decrement; leaking into a sea-level run would mean the engine is "
            "using an input it has no business using here.",
            expected="< 2%", observed=f"{rel_d*100:.3f}%",
            evidence="Spec 2.10.C criterion 2"))

    # 5. Differentiation index: do mechanistically distinct people separate?
    sep = _separation(results, "tempo_30min")
    checks.append(Check(
        "C. Virtual cohort", "cohort_separates_on_relevant_axes",
        sep["relevant_median"] > 3.0 * max(sep["irrelevant_median"], 1e-6),
        f"Median standardised separation between people who differ on a "
        f"mechanistically relevant axis is {sep['relevant_median']:.2f}, against "
        f"{sep['irrelevant_median']:.4f} for the irrelevant-control twins. The "
        "engine reveals defensible differences between plausible people and "
        "stays quiet where it should.",
        expected="relevant >> irrelevant",
        observed=f"{sep['relevant_median']:.2f} vs {sep['irrelevant_median']:.4f}",
        evidence="Spec 2.10.C: first product-level validation target"))

    summary = {
        "scenarios": [s for s, _ in scenarios],
        "people": [{"tag": t, "varies": v} for t, _, v in cohort()],
        "separation": sep,
        "table": _table(results),
    }
    return checks, summary


def _separation(results, sname) -> Dict[str, Any]:
    """Standardised difference in medians, pooled over the key outputs."""
    def dist(ta, tb):
        vals = []
        for key in KEYS:
            ea = results[ta][sname].get(key)
            eb = results[tb][sname].get(key)
            if ea is None or eb is None:
                continue
            pooled = np.sqrt((np.nanstd(ea.samples) ** 2 +
                              np.nanstd(eb.samples) ** 2) / 2.0)
            if pooled < 1e-12:
                continue
            vals.append(abs(ea.median() - eb.median()) / pooled)
        return float(np.median(vals)) if vals else 0.0

    relevant_pairs = [("low_capacity", "high_capacity"),
                      ("anaemic", "polycythaemic"),
                      ("glycogen_depleted", "carb_loaded"),
                      ("heavier", "lighter")]
    # Habitual elevation belongs with the controls, not with the relevant axes.
    # The standardized scenarios are all run at sea level, and where a person
    # usually lives is only supposed to matter when the run itself is at
    # altitude, where it offsets part of the acute decrement. Expecting it to
    # separate a sea-level run would be expecting the engine to leak an input
    # that should have no effect; finding no separation is the correct result,
    # so it is scored as a control.
    control_pairs = [("twin_a", "twin_b", "identical physiology, different "
                      "laboratory values the engine cannot map"),
                     ("reference", "altitude_native", "habitual elevation, "
                      "with the run itself at sea level")]
    rel = [dist(a, b) for a, b in relevant_pairs]
    irr = [dist(a, b) for a, b, _ in control_pairs]
    return {
        "relevant_pairs": [{"pair": f"{a} vs {b}",
                            "separation": round(dist(a, b), 3)}
                           for a, b in relevant_pairs],
        "control_pairs": [{"pair": f"{a} vs {b}", "why": why,
                           "separation": round(dist(a, b), 3)}
                          for a, b, why in control_pairs],
        "relevant_median": float(np.median(rel)),
        "irrelevant_median": float(np.median(irr)),
    }


def _table(results) -> List[Dict[str, Any]]:
    rows = []
    for tag, per_scenario in results.items():
        for sname, out in per_scenario.items():
            row = {"person": tag, "scenario": sname}
            for key in KEYS:
                e = out.get(key)
                if e is not None:
                    row[key] = round(e.median(), 4)
            rows.append(row)
    return rows
