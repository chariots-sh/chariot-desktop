"""User-facing input schema (spec 1.1).

Design rule from the spec: "The user supplies observations, not biochemical
parameters. They should never be asked to enter 'Complex I activity',
'mitochondrial density', or 'proton leak'."

Nothing in this module is a rate constant.  Every field is something a person
can observe, export from a phone, or read off a lab report.  Each field that
carries measurement error also carries a *quality* tag, because spec 1.1 wants
different error distributions for heart rate vs energy expenditure vs sleep.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional, cast

# --------------------------------------------------------------------------
# Quality vocabularies
# --------------------------------------------------------------------------

# Ordered best -> worst.  Used to widen priors, never to reject silently.
MEAL_QUALITY = ("weighed", "measured", "label", "estimated", "photo", "recalled")
DEVICE_QUALITY = ("lab", "chest_strap", "wrist_optical", "phone_only", "unknown")

# Spec 1.1: Apple cardio fitness is *estimated*, not gas-exchange measured, and
# the living systematic review found agreement is better for heart rate than for
# energy expenditure and several sleep outputs.  These tiers carry that forward.
SIGNAL_TIER = {
    "heart_rate": "good",              # strongest consumer agreement
    "pace_distance": "good",
    "running_power": "moderate",
    "vo2max_estimate": "moderate",     # apple_cardio: estimate, not gas exchange
    "hr_recovery": "moderate",
    "resting_hr": "good",
    "sleep_duration": "moderate",
    "sleep_stages": "weak",            # lambe2026: weaker agreement
    "active_energy": "weak",           # lambe2026: weaker agreement
    "hrv": "weak",
    "wrist_temperature": "weak",
    "spo2_consumer": "weak",
    "rpe": "moderate",
}


def _iso(x):
    return x.isoformat() if isinstance(x, (dt.datetime, dt.date)) else x


class _Ser:
    def to_dict(self) -> Dict[str, Any]:
        def conv(v):
            if isinstance(v, (dt.datetime, dt.date)):
                return v.isoformat()
            if isinstance(v, list):
                return [conv(i) for i in v]
            if isinstance(v, dict):
                return {k: conv(i) for k, i in v.items()}
            return v
        # Subclasses are always dataclasses; the mixin itself is not, so guide
        # asdict past the dataclass-instance check without changing behavior.
        return {k: conv(v) for k, v in asdict(cast(Any, self)).items()}


# --------------------------------------------------------------------------
# Body and context (spec 1.1 "Body and context")
# --------------------------------------------------------------------------

@dataclass
class Body(_Ser):
    age_y: float
    sex_at_birth: str                      # "female" | "male" | "intersex" | "unspecified"
    height_cm: float
    mass_kg: float
    body_fat_pct: Optional[float] = None   # either this ...
    lean_mass_kg: Optional[float] = None   # ... or this
    habitual_elevation_m: float = 0.0

    def lean_mass(self) -> Optional[float]:
        if self.lean_mass_kg is not None:
            return self.lean_mass_kg
        if self.body_fat_pct is not None:
            return self.mass_kg * (1.0 - self.body_fat_pct / 100.0)
        return None


@dataclass
class TrainingHistory(_Ser):
    years_running: float = 0.0
    weekly_km: float = 0.0
    weekly_hours_total: float = 0.0
    longest_recent_run_km: float = 0.0
    sessions_above_threshold_per_week: float = 0.0
    self_described_level: str = "recreational"   # novice|recreational|trained|competitive


@dataclass
class ClinicalContext(_Ser):
    """Applicability and confounder flags (spec 1.1).  These do not become
    kinetic parameters; they gate and widen."""
    medications: List[str] = field(default_factory=list)
    diagnoses: List[str] = field(default_factory=list)
    recent_illness_days_ago: Optional[float] = None
    soreness_0_10: Optional[float] = None
    injury: Optional[str] = None
    pregnant: bool = False


# --------------------------------------------------------------------------
# Running and Apple Health data (spec 1.1)
# --------------------------------------------------------------------------

@dataclass
class RunRecord(_Ser):
    start: dt.datetime
    duration_s: float
    distance_km: float
    mean_hr_bpm: Optional[float] = None
    max_hr_bpm: Optional[float] = None
    mean_grade_pct: float = 0.0
    elevation_gain_m: float = 0.0
    mean_power_w: Optional[float] = None
    hr_recovery_60s_bpm: Optional[float] = None
    rpe_6_20: Optional[float] = None
    device_quality: str = "wrist_optical"
    elevation_m: float = 0.0
    splits: List[Dict[str, float]] = field(default_factory=list)
    notes: str = ""

    @property
    def speed_m_s(self) -> float:
        return (self.distance_km * 1000.0) / max(self.duration_s, 1e-9)


@dataclass
class CalibrationRun(_Ser):
    """Spec 1.1: the standardized repeated protocol -- the strongest accessible
    personalization input.  Same route, ~constant pace and grade, >=3 repeats."""
    run: RunRecord
    protocol_id: str
    hours_since_meal: Optional[float] = None
    prev_24h_cho_g: Optional[float] = None
    caffeine_mg: float = 0.0
    sleep_h: Optional[float] = None
    conditions_note: str = ""


@dataclass
class WearableData(_Ser):
    runs: List[RunRecord] = field(default_factory=list)
    vo2max_estimate_ml_kg_min: Optional[float] = None
    vo2max_source: str = "apple_watch_cardio_fitness"
    resting_hr_bpm: Optional[float] = None
    resting_hr_trend_bpm_per_30d: Optional[float] = None
    max_hr_bpm_observed: Optional[float] = None
    mean_sleep_h: Optional[float] = None
    last_night_sleep_h: Optional[float] = None
    hrv_ms: Optional[float] = None
    wrist_temp_dev_c: Optional[float] = None
    spo2_pct: Optional[float] = None
    active_energy_kcal_per_day: Optional[float] = None
    window_days: int = 90
    device: str = "Apple Watch"

    def n_runs(self) -> int:
        return len(self.runs)


# --------------------------------------------------------------------------
# Meals and fuel state (spec 1.1)
# --------------------------------------------------------------------------

@dataclass
class MealEvent(_Ser):
    """The basic timestamped intake event from the spec, verbatim fields."""
    timestamp: dt.datetime
    carbohydrate_g: float
    fat_g: float
    protein_g: float
    fiber_g: float = 0.0
    alcohol_g: float = 0.0
    caffeine_mg: float = 0.0
    estimation_quality: str = "estimated"

    def relative_error(self) -> float:
        """Spec: 'Meal estimates are ranges. A photographed or casually logged
        meal should not be treated as exact grams.'"""
        return {"weighed": 0.05, "measured": 0.10, "label": 0.15,
                "estimated": 0.25, "photo": 0.35, "recalled": 0.45}.get(
                    self.estimation_quality, 0.35)


@dataclass
class NutritionState(_Ser):
    meals: List[MealEvent] = field(default_factory=list)
    prev_24h_cho_g: Optional[float] = None
    prev_48h_cho_g: Optional[float] = None
    hours_since_last_meal: Optional[float] = None
    exercise_since_last_high_cho_meal: bool = False
    hard_sessions_last_48h: int = 0
    cgm_glucose_mmol_l: Optional[float] = None
    capillary_bhb_mmol_l: Optional[float] = None
    hydration_pct_body_mass_deficit: Optional[float] = None


# --------------------------------------------------------------------------
# Bloodwork (spec 1.1)
# --------------------------------------------------------------------------

@dataclass
class LabValue(_Ser):
    """Spec: 'The engine must preserve collection date, fasting state, units,
    reference range, and source.'"""
    analyte: str
    value: float
    unit: str
    collected: dt.date
    fasting: Optional[bool] = None
    ref_low: Optional[float] = None
    ref_high: Optional[float] = None
    source: str = "clinical_lab"
    same_day_as_run: bool = False
    collection_note: str = ""

    def age_days(self, today: dt.date) -> int:
        return (today - self.collected).days


@dataclass
class LabPanel(_Ser):
    values: List[LabValue] = field(default_factory=list)

    def get(self, analyte: str) -> Optional[LabValue]:
        hits = [v for v in self.values if v.analyte == analyte]
        if not hits:
            return None
        return max(hits, key=lambda v: v.collected)


# --------------------------------------------------------------------------
# Androgen context (baseline observations for the mechanism lab)
# --------------------------------------------------------------------------

@dataclass
class AndrogenContext(_Ser):
    """Observed baseline androgen exposure, and any observed follow-up state.

    This is an *observation* block, like the lab panel: nothing here is a dose,
    a prescription or a plan.  It exists so that a sustained-androgen-exposure
    counterfactual has a measured baseline to move away from, because a
    counterfactual against an invented baseline is not a counterfactual.

    Serum testosterone is not a universal tissue-response coordinate, which is
    why the collection context travels with the number.  Total testosterone has
    a strong diurnal rhythm and substantial day-to-day variation, so a single
    afternoon draw is a much weaker anchor than two morning draws; sex-hormone
    binding globulin and albumin change the free fraction without changing the
    total; and an exogenous source makes the concentration a treatment
    consequence rather than a baseline phenotype.  All of that widens or
    disqualifies a counterfactual rather than being silently averaged in.
    """
    total_testosterone_ng_dL: Optional[float] = None
    free_testosterone_pg_mL: Optional[float] = None
    shbg_nmol_L: Optional[float] = None
    albumin_g_dL: Optional[float] = None
    collection_time_local: Optional[str] = None     # "07:30"
    repeat_measurements: int = 0
    # "endogenous" | "exogenous" | "unknown"
    exposure_source: str = "unknown"
    collected: Optional[dt.date] = None
    # Observed *follow-up* mediators, if the person has them. An observed
    # follow-up value replaces the modelled target rather than being added to
    # it: a measurement beats a sampled delta.
    followup_hemoglobin_g_dL: Optional[float] = None
    followup_lean_mass_kg: Optional[float] = None
    followup_total_testosterone_ng_dL: Optional[float] = None

    def observed(self) -> bool:
        """Is there any measured baseline concentration at all?"""
        return (self.total_testosterone_ng_dL is not None or
                self.free_testosterone_pg_mL is not None)

    def morning_draw(self) -> Optional[bool]:
        """Was the sample taken in the window reference ranges assume?"""
        if not self.collection_time_local:
            return None
        try:
            hour = int(str(self.collection_time_local).split(":")[0])
        except (ValueError, IndexError):
            return None
        return 7 <= hour <= 11


# --------------------------------------------------------------------------
# Assembly
# --------------------------------------------------------------------------

@dataclass
class PersonInputs(_Ser):
    body: Body
    training: TrainingHistory = field(default_factory=TrainingHistory)
    clinical: ClinicalContext = field(default_factory=ClinicalContext)
    wearable: WearableData = field(default_factory=WearableData)
    nutrition: NutritionState = field(default_factory=NutritionState)
    labs: LabPanel = field(default_factory=LabPanel)
    calibration_runs: List[CalibrationRun] = field(default_factory=list)
    androgen: AndrogenContext = field(default_factory=AndrogenContext)
    subject_id: str = "anonymous"
    as_of: dt.date = field(default_factory=dt.date.today)

    # Spec 1.1 "Genetics": excluded from version 1 by design.
    genetics_enabled: bool = False


__all__ = [
    "Body", "TrainingHistory", "ClinicalContext", "RunRecord", "CalibrationRun",
    "WearableData", "MealEvent", "NutritionState", "LabValue", "LabPanel",
    "AndrogenContext", "PersonInputs", "MEAL_QUALITY", "DEVICE_QUALITY",
    "SIGNAL_TIER",
]
