"""Input QC, applicability guardrails and the bloodwork role table (spec 1.1).

The governing rule from the spec:

    "Routine bloodwork cannot directly reveal intracellular flux,
     respiratory-complex capacity, mitochondrial count, or proton leak. If no
     defensible mapping exists, a laboratory value should not change the
     simulation."

So every analyte gets an explicit role.  Only three roles can move a number:
CONSTRAINT (enters the model), PRIOR (shifts a posterior), FLAG (changes
applicability/confidence only).  Anything unmapped is recorded and ignored.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional

from .inputs import PersonInputs, LabValue, SIGNAL_TIER

CONSTRAINT, PRIOR, FLAG, IGNORED = "constraint", "prior", "flag", "ignored"


@dataclass(frozen=True)
class LabRole:
    analyte: str
    role: str
    target: str            # what it touches, "" for flags
    strength: str          # spec column "Strength in version 1"
    note: str
    max_age_days: Optional[int] = None   # older than this -> phenotype only


# Spec 1.1 bloodwork table, transcribed as executable policy.
LAB_ROLES: Dict[str, LabRole] = {r.analyte: r for r in [
    LabRole("hemoglobin", CONSTRAINT, "oxygen_capacity", "moderate, wide uncertainty",
            "Modifies arterial oxygen content, one uncertain modifier among "
            "ventilation, cardiac output, perfusion, diffusion and extraction.",
            max_age_days=180),
    LabRole("hematocrit", CONSTRAINT, "oxygen_capacity", "moderate, wide uncertainty",
            "Used only if haemoglobin is absent; converted with a wide "
            "haemoglobin-hematocrit relation.", max_age_days=180),
    LabRole("fasting_glucose", PRIOR, "glycemic_phenotype", "low-moderate",
            "Shifts the resting blood-glucose and insulin-sensitivity priors "
            "slightly. Does not set today's substrate concentrations."),
    LabRole("hba1c", PRIOR, "glycemic_phenotype", "low-moderate",
            "Longer-term glucose-regulation prior."),
    LabRole("fasting_insulin", PRIOR, "insulin_sensitivity", "low-moderate",
            "Adjusts the insulin-dependent glucose-transport gain prior."),
    LabRole("triglycerides", PRIOR, "metabolic_phenotype", "low",
            "Weak metabolic-phenotype prior; widened, never decisive."),
    LabRole("hdl", PRIOR, "metabolic_phenotype", "low",
            "Weak metabolic-phenotype prior."),
    LabRole("ferritin", FLAG, "", "contextual unless deficient",
            "Iron status. Below the deficiency threshold this becomes an "
            "applicability warning, not a flux parameter."),
    LabRole("transferrin_saturation", FLAG, "", "contextual unless deficient",
            "Iron status flag."),
    LabRole("creatinine", FLAG, "", "not a flux parameter",
            "Applicability guardrail only."),
    LabRole("egfr", FLAG, "", "not a flux parameter",
            "Applicability guardrail only."),
    LabRole("ast", FLAG, "", "not a flux parameter", "Applicability guardrail only."),
    LabRole("alt", FLAG, "", "not a flux parameter", "Applicability guardrail only."),
    LabRole("sodium", FLAG, "", "not a flux parameter", "Context / abnormal-result flag."),
    LabRole("potassium", FLAG, "", "not a flux parameter", "Context / abnormal-result flag."),
    LabRole("bicarbonate", FLAG, "", "not a flux parameter", "Context / abnormal-result flag."),
    LabRole("hs_crp", FLAG, "", "contextual",
            "Inflammation/illness modifier; widens uncertainty and can suspend "
            "applicability."),
    LabRole("tsh", FLAG, "", "contextual",
            "Energy-metabolism confounder; flags applicability if abnormal."),
    LabRole("lactate", CONSTRAINT, "blood_lactate_initial", "potentially strong",
            "Only when drawn the same day under documented conditions; "
            "otherwise it describes a different physiological state.",
            max_age_days=1),
    LabRole("bhb", CONSTRAINT, "blood_ketone_initial", "potentially strong",
            "Same-day ketone availability constraint.", max_age_days=1),
]}

# Diagnoses and drug classes that change what the engine may claim.
APPLICABILITY_BLOCKS = {
    "mitochondrial_myopathy": "The version 1 muscle phenotype is a healthy "
        "mixed running muscle. A primary mitochondrial myopathy is outside the "
        "represented population.",
    "mcardle_disease": "Myophosphorylase deficiency removes the glycogenolytic "
        "pathway the model assumes is intact.",
    "heart_failure": "Central oxygen delivery is outside the modelled range.",
    "copd": "Ventilatory limitation is not represented; the oxygen ceiling here "
        "assumes ventilation is not the constraint.",
    "sickle_cell_disease": "Oxygen transport is outside the modelled range.",
    "pregnancy": "Cardiovascular and substrate physiology differ from the "
        "modelled population and version 1 has no pregnancy adaptation.",
}

CONFOUNDING_DRUGS = {
    "beta_blocker": ("heart_rate", "Beta blockade decouples heart rate from "
                     "relative intensity, so heart-rate-derived personalisation "
                     "and cardio-fitness estimates are unreliable."),
    "metformin": ("lactate", "May raise resting and exercise lactate slightly; "
                  "lactate outputs carry extra uncertainty."),
    "sglt2_inhibitor": ("ketones", "Raises circulating ketones; the ketone "
                        "prior is shifted and widened."),
    "corticosteroid": ("glycemic_phenotype", "Alters glucose handling; glycaemic "
                       "priors widened."),
    "thyroid_hormone": ("metabolic_rate", "Alters resting metabolic rate; the "
                        "resting prior is widened."),
    "statin": ("muscle", "Occasional myopathy; if symptoms are reported the run "
               "outputs carry a confidence penalty."),
}


@dataclass
class QCFinding:
    severity: str          # "info" | "widen" | "warn" | "block"
    code: str
    message: str
    affects: str = ""

    def to_dict(self):
        return asdict(self)


@dataclass
class QCReport:
    findings: List[QCFinding] = field(default_factory=list)
    lab_disposition: List[Dict[str, Any]] = field(default_factory=list)
    widen_factors: Dict[str, float] = field(default_factory=dict)
    prior_shifts: Dict[str, float] = field(default_factory=dict)
    constraints: Dict[str, float] = field(default_factory=dict)
    blocked: bool = False
    signal_quality: Dict[str, str] = field(default_factory=dict)

    def add(self, severity, code, message, affects=""):
        self.findings.append(QCFinding(severity, code, message, affects))
        if severity == "block":
            self.blocked = True

    def widen(self, key: str, factor: float):
        self.widen_factors[key] = self.widen_factors.get(key, 1.0) * factor

    def confidence_penalty(self) -> float:
        """Aggregate multiplicative widening applied to all outputs."""
        p = 1.0
        for f in self.findings:
            if f.severity == "widen":
                p *= 1.06
            elif f.severity == "warn":
                p *= 1.15
        return min(p, 2.2)

    def to_dict(self):
        return {
            "findings": [f.to_dict() for f in self.findings],
            "lab_disposition": self.lab_disposition,
            "widen_factors": self.widen_factors,
            "prior_shifts": self.prior_shifts,
            "constraints": self.constraints,
            "blocked": self.blocked,
            "signal_quality": self.signal_quality,
            "confidence_penalty": round(self.confidence_penalty(), 3),
        }


def _abnormal(v: LabValue) -> Optional[str]:
    if v.ref_low is not None and v.value < v.ref_low:
        return "below reference range"
    if v.ref_high is not None and v.value > v.ref_high:
        return "above reference range"
    return None


def run_qc(p: PersonInputs, today: Optional[dt.date] = None) -> QCReport:
    today = today or p.as_of
    rep = QCReport()

    # ---- signal quality tiers -------------------------------------------
    rep.signal_quality = dict(SIGNAL_TIER)
    if p.wearable.vo2max_estimate_ml_kg_min is not None:
        rep.add("info", "vo2max_is_estimate",
                "Cardio fitness from a wrist wearable is an estimate derived "
                "from heart-rate and motion sensors, not respiratory gas "
                "analysis. It is carried with a multiplicative error model.",
                affects="vo2max")
    else:
        rep.add("widen", "no_vo2max",
                "No cardio-fitness estimate supplied; the aerobic ceiling falls "
                "back to a population prior and every capacity-related output "
                "widens.", affects="vo2max")
        rep.widen("vo2max", 1.6)

    n_runs = p.wearable.n_runs()
    if n_runs == 0:
        rep.add("widen", "no_runs",
                "No run history supplied; running economy cannot be "
                "personalised and stays at the population prior.",
                affects="economy_factor")
        rep.widen("economy_factor", 1.5)
    elif n_runs < 8:
        rep.add("widen", "few_runs",
                f"Only {n_runs} runs supplied; economy and pace-heart-rate "
                "personalisation are weak.", affects="economy_factor")
        rep.widen("economy_factor", 1.25)

    cal = p.calibration_runs
    if len(cal) >= 3:
        rep.add("info", "calibration_ok",
                f"{len(cal)} standardized calibration runs available; the "
                "personal demand-to-response relationship is constrained by the "
                "strongest accessible input.", affects="economy_factor")
        rep.widen("economy_factor", 0.62)
        rep.widen("vo2max", 0.80)
    elif cal:
        rep.add("widen", "calibration_incomplete",
                f"Only {len(cal)} calibration run(s); the protocol asks for at "
                "least three in comparable conditions before the personal "
                "relationship is treated as constrained.")

    # ---- clinical applicability -----------------------------------------
    for dx in p.clinical.diagnoses:
        k = dx.strip().lower().replace(" ", "_").replace("-", "_")
        if k in APPLICABILITY_BLOCKS:
            rep.add("block", f"applicability_{k}", APPLICABILITY_BLOCKS[k],
                    affects="whole_simulation")
    if p.clinical.pregnant:
        rep.add("block", "applicability_pregnancy",
                APPLICABILITY_BLOCKS["pregnancy"], affects="whole_simulation")

    for med in p.clinical.medications:
        k = med.strip().lower().replace(" ", "_").replace("-", "_")
        if k in CONFOUNDING_DRUGS:
            target, msg = CONFOUNDING_DRUGS[k]
            rep.add("warn", f"confounder_{k}", msg, affects=target)
            rep.widen(target, 1.35)

    if p.clinical.recent_illness_days_ago is not None and \
            p.clinical.recent_illness_days_ago <= 14:
        rep.add("warn", "recent_illness",
                f"Illness {p.clinical.recent_illness_days_ago:.0f} days ago. "
                "Aerobic capacity, glycogen status and the heart-rate response "
                "are all disturbed; confidence is reduced and the glycogen "
                "prior is lowered.", affects="whole_simulation")
        rep.widen("vo2max", 1.25)
        rep.widen("glycogen", 1.25)
        rep.prior_shifts["glycogen_multiplier"] = 0.85

    if p.clinical.soreness_0_10 and p.clinical.soreness_0_10 >= 5:
        rep.add("warn", "soreness",
                f"Reported soreness {p.clinical.soreness_0_10:.0f}/10 suggests "
                "recent muscle damage; glycogen resynthesis is impaired and the "
                "glycogen prior is lowered.", affects="glycogen")
        rep.widen("glycogen", 1.3)
        rep.prior_shifts["glycogen_multiplier"] = min(
            rep.prior_shifts.get("glycogen_multiplier", 1.0), 0.82)

    if p.clinical.injury:
        rep.add("warn", "injury",
                f"Reported injury ({p.clinical.injury}). Running mechanics and "
                "muscle recruitment may differ from the modelled phenotype.",
                affects="recruitment")

    if p.genetics_enabled:
        rep.add("info", "genetics_excluded",
                "Genetics is excluded from version 1 by design; any supplied "
                "genetic data is ignored rather than used as a weak prior.")

    # ---- bloodwork -------------------------------------------------------
    for v in p.labs.values:
        role = LAB_ROLES.get(v.analyte)
        disp: Dict[str, Any] = {
            "analyte": v.analyte, "value": v.value, "unit": v.unit,
            "collected": v.collected.isoformat(),
            "age_days": v.age_days(today), "fasting": v.fasting,
            "reference": [v.ref_low, v.ref_high], "source": v.source,
        }
        if role is None:
            disp.update(role=IGNORED, target="", strength="none",
                        reason="No defensible mapping from this analyte to a "
                               "modelled quantity, so it does not change the "
                               "simulation.")
            rep.lab_disposition.append(disp)
            rep.add("info", f"lab_ignored_{v.analyte}",
                    f"{v.analyte} recorded but not used: no defensible mapping "
                    "to a modelled quantity.")
            continue

        age = v.age_days(today)
        effective_role = role.role
        reason = role.note
        if role.max_age_days is not None and age > role.max_age_days:
            if role.role == CONSTRAINT and role.max_age_days <= 1:
                effective_role = IGNORED
                reason = (f"Collected {age} days ago. This analyte is only a "
                          "state observation when drawn the same day; an old "
                          "value describes a different physiological state, "
                          "not today's substrate concentration.")
            else:
                effective_role = PRIOR
                reason = (f"Collected {age} days ago; downgraded from a model "
                          "constraint to a phenotype prior. Old bloodwork "
                          "describes phenotype, not today's state.")

        disp.update(role=effective_role, target=role.target,
                    strength=role.strength, reason=reason)
        rep.lab_disposition.append(disp)

        ab = _abnormal(v)
        if ab:
            rep.add("warn", f"lab_abnormal_{v.analyte}",
                    f"{v.analyte} is {ab} ({v.value} {v.unit}). Flagged for "
                    "applicability; this engine is not a diagnostic tool and "
                    "the result should be interpreted clinically.",
                    affects="applicability")

        if effective_role == CONSTRAINT:
            rep.constraints[role.target] = v.value
        elif effective_role == PRIOR:
            rep.prior_shifts.setdefault(role.target, v.value)

        if v.analyte == "ferritin" and v.value < 30:
            rep.add("warn", "iron_deficiency",
                    "Ferritin below 30 ug/L suggests iron deficiency, which "
                    "affects oxygen carriage and is a clinical matter. Oxygen "
                    "outputs are widened and flagged.", affects="oxygen_capacity")
            rep.widen("oxygen_capacity", 1.4)
        if v.analyte == "hs_crp" and v.value > 3.0:
            rep.add("warn", "inflammation",
                    "hs-CRP above 3 mg/L indicates an inflammatory state that "
                    "confounds exercise metabolism; confidence reduced.",
                    affects="whole_simulation")
            rep.widen("vo2max", 1.2)

    # ---- nutrition -------------------------------------------------------
    nut = p.nutrition
    if nut.prev_24h_cho_g is None and not nut.meals:
        rep.add("widen", "no_nutrition",
                "No meal records or 24-hour carbohydrate total; the initial "
                "glycogen posterior falls back to a broad training-status "
                "prior.", affects="glycogen")
        rep.widen("glycogen", 1.5)
    poor = [m for m in nut.meals if m.estimation_quality in ("photo", "recalled")]
    if poor:
        rep.add("widen", "meal_estimate_quality",
                f"{len(poor)} of {len(nut.meals)} meals were photographed or "
                "recalled rather than weighed. Meal estimates are treated as "
                "ranges, not exact grams.", affects="glycogen")
        rep.widen("glycogen", 1.0 + 0.10 * min(len(poor), 4))

    if nut.hydration_pct_body_mass_deficit and \
            nut.hydration_pct_body_mass_deficit >= 2.0:
        rep.add("warn", "dehydration",
                f"{nut.hydration_pct_body_mass_deficit:.1f}% body-mass fluid "
                "deficit reduces plasma volume and cardiac output; the oxygen "
                "ceiling is lowered and widened.", affects="oxygen_capacity")
        rep.widen("oxygen_capacity", 1.2)
        rep.prior_shifts["vo2max_multiplier"] = 0.95

    sleep = p.wearable.last_night_sleep_h
    if sleep is not None and sleep < 5.5:
        rep.add("widen", "short_sleep",
                f"{sleep:.1f} h sleep last night. Sleep duration is a moderate "
                "quality consumer signal; the effect on substrate use is "
                "represented only as widened uncertainty, not a mechanism.",
                affects="whole_simulation")

    return rep
