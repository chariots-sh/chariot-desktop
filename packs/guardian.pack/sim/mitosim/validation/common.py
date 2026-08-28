"""Shared helpers and the reference virtual people used across the suite."""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, asdict
from typing import Any, Dict, List, Optional

import numpy as np

from ..inputs import (Body, TrainingHistory, ClinicalContext, WearableData,
                      NutritionState, LabPanel, LabValue, PersonInputs,
                      RunRecord, CalibrationRun)
from ..scenario import Scenario, Intensity


@dataclass
class Check:
    section: str
    name: str
    passed: bool
    detail: str
    expected: str = ""
    observed: str = ""
    severity: str = "error"        # error | warning | info
    evidence: str = ""

    def to_dict(self):
        return asdict(self)


def reference_person(**kw) -> PersonInputs:
    """A well-characterised trained runner used as the calibration reference."""
    body = Body(age_y=kw.get("age", 35), sex_at_birth=kw.get("sex", "male"),
                height_cm=kw.get("height", 178), mass_kg=kw.get("mass", 72),
                body_fat_pct=kw.get("bf", 14),
                habitual_elevation_m=kw.get("elev", 0))
    return PersonInputs(
        body=body,
        training=TrainingHistory(years_running=9, weekly_km=kw.get("km", 55),
                                 self_described_level=kw.get("level", "trained")),
        wearable=WearableData(vo2max_estimate_ml_kg_min=kw.get("vo2max", 54),
                              resting_hr_bpm=48, max_hr_bpm_observed=186),
        nutrition=NutritionState(prev_24h_cho_g=kw.get("cho24", 380),
                                 hours_since_last_meal=3),
        labs=LabPanel(kw.get("labs", [])),
        subject_id=kw.get("subject_id", "reference"),
        as_of=dt.date(2026, 8, 26))


def base_scenario(**kw) -> Scenario:
    return Scenario(
        pattern=kw.get("pattern", "continuous"),
        intensity=Intensity("pct_vo2max", kw.get("intensity", 0.65)),
        grade_pct=kw.get("grade", 0.0),
        duration_min=kw.get("duration", 40.0),
        hours_since_meal=kw.get("hsm", 3.0),
        pre_run_cho_g=kw.get("cho", 0.0),
        prev_day_cho=kw.get("prev_cho", "mixed"),
        glycogen_prior=kw.get("gly", "derived"),
        elevation_m=kw.get("elev", 0.0),
        experimental=tuple(kw.get("experimental", ())))


def med(out, key) -> Optional[float]:
    e = out.get(key)
    return None if e is None else e.median()


def p_direction(out_a, out_b, key: str, expect_increase: bool) -> Optional[float]:
    """Paired probability that key moves in the expected direction from A to B."""
    ea, eb = out_a.get(key), out_b.get(key)
    if ea is None or eb is None:
        return None
    m = min(ea.n, eb.n)
    d = np.asarray(eb.samples)[:m] - np.asarray(ea.samples)[:m]
    d = d[np.isfinite(d)]
    if d.size < 8:
        return None
    return float(np.mean(d > 0) if expect_increase else np.mean(d < 0))
