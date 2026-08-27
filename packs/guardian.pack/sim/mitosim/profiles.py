"""Loading and saving person profiles and scenarios from plain files.

Profiles are YAML-ish/JSON so a person can keep their observations in a file
they can read.  Only the standard library is used, so a JSON profile always
works; YAML is accepted when PyYAML happens to be installed.
"""

from __future__ import annotations

import datetime as dt
import json
import os
from typing import Any, Dict, List, Optional

from .inputs import (Body, TrainingHistory, ClinicalContext, WearableData,
                     RunRecord, CalibrationRun, MealEvent, NutritionState,
                     LabValue, LabPanel, PersonInputs)
from .scenario import Scenario, Intensity, ExperimentalUse


def _date(v, default=None):
    if v is None:
        return default
    if isinstance(v, dt.date) and not isinstance(v, dt.datetime):
        return v
    if isinstance(v, dt.datetime):
        return v.date()
    return dt.date.fromisoformat(str(v)[:10])


def _dt(v):
    if isinstance(v, dt.datetime):
        return v
    return dt.datetime.fromisoformat(str(v))


def load_raw(path: str) -> Dict[str, Any]:
    with open(path) as f:
        text = f.read()
    if path.endswith((".yaml", ".yml")):
        try:
            import yaml
            return yaml.safe_load(text)
        except ImportError as e:
            raise RuntimeError(
                "This profile is YAML but PyYAML is not installed. Either "
                "install PyYAML or save the profile as .json.") from e
    return json.loads(text)


def person_from_dict(d: Dict[str, Any]) -> PersonInputs:
    b = d.get("body", {})
    body = Body(age_y=b["age_y"], sex_at_birth=b.get("sex_at_birth",
                                                     "unspecified"),
                height_cm=b["height_cm"], mass_kg=b["mass_kg"],
                body_fat_pct=b.get("body_fat_pct"),
                lean_mass_kg=b.get("lean_mass_kg"),
                habitual_elevation_m=b.get("habitual_elevation_m", 0.0))
    t = d.get("training", {})
    training = TrainingHistory(**{k: v for k, v in t.items()
                                 if k in TrainingHistory.__dataclass_fields__})
    c = d.get("clinical", {})
    clinical = ClinicalContext(**{k: v for k, v in c.items()
                                 if k in ClinicalContext.__dataclass_fields__})
    w = d.get("wearable", {})
    runs = [RunRecord(start=_dt(r["start"]),
                      **{k: v for k, v in r.items()
                         if k != "start" and k in RunRecord.__dataclass_fields__})
            for r in w.get("runs", [])]
    wearable = WearableData(
        runs=runs,
        **{k: v for k, v in w.items()
           if k != "runs" and k in WearableData.__dataclass_fields__})
    n = d.get("nutrition", {})
    meals = [MealEvent(timestamp=_dt(m["timestamp"]),
                       **{k: v for k, v in m.items()
                          if k != "timestamp" and
                          k in MealEvent.__dataclass_fields__})
             for m in n.get("meals", [])]
    nutrition = NutritionState(
        meals=meals,
        **{k: v for k, v in n.items()
           if k != "meals" and k in NutritionState.__dataclass_fields__})
    labs = LabPanel([LabValue(analyte=l["analyte"], value=l["value"],
                              unit=l["unit"], collected=_date(l["collected"]),
                              fasting=l.get("fasting"),
                              ref_low=l.get("ref_low"),
                              ref_high=l.get("ref_high"),
                              source=l.get("source", "clinical_lab"),
                              same_day_as_run=l.get("same_day_as_run", False),
                              collection_note=l.get("collection_note", ""))
                     for l in d.get("labs", [])])
    cals: List[CalibrationRun] = []
    for cr in d.get("calibration_runs", []):
        r = cr["run"]
        cals.append(CalibrationRun(
            run=RunRecord(start=_dt(r["start"]),
                          **{k: v for k, v in r.items()
                             if k != "start" and
                             k in RunRecord.__dataclass_fields__}),
            protocol_id=cr.get("protocol_id", "protocol"),
            **{k: v for k, v in cr.items()
               if k not in ("run", "protocol_id") and
               k in CalibrationRun.__dataclass_fields__}))
    return PersonInputs(
        body=body, training=training, clinical=clinical, wearable=wearable,
        nutrition=nutrition, labs=labs, calibration_runs=cals,
        subject_id=d.get("subject_id", "anonymous"),
        as_of=_date(d.get("as_of"), dt.date.today()))


def scenario_from_dict(d: Dict[str, Any]) -> Scenario:
    i = d.get("intensity", {})
    if isinstance(i, (int, float)):
        intensity = Intensity("pct_vo2max", float(i))
    else:
        intensity = Intensity(i.get("kind", "pct_vo2max"),
                              float(i.get("value", 0.65)))
    exp = tuple(ExperimentalUse(
        adapter=e["adapter"], dose=float(e.get("dose", 0.0)),
        dose_unit=e.get("dose_unit", "mg"),
        timing_min_before=float(e.get("timing_min_before", 60.0)),
        days_loaded=float(e.get("days_loaded", 0.0)))
        for e in d.get("experimental", []))
    return Scenario(
        pattern=d.get("pattern", "continuous"), intensity=intensity,
        grade_pct=float(d.get("grade_pct", 0.0)),
        duration_min=float(d.get("duration_min", 40.0)),
        hours_since_meal=float(d.get("hours_since_meal", 3.0)),
        pre_run_cho_g=float(d.get("pre_run_cho_g", 0.0)),
        prev_day_cho=d.get("prev_day_cho", "mixed"),
        glycogen_prior=d.get("glycogen_prior", "derived"),
        elevation_m=float(d.get("elevation_m", 0.0)),
        time_of_day=d.get("time_of_day", "08:00"),
        experimental=exp, label=d.get("label", ""))


def load_person(path: str) -> PersonInputs:
    return person_from_dict(load_raw(path))


def load_scenario(path: str) -> Scenario:
    return scenario_from_dict(load_raw(path))
