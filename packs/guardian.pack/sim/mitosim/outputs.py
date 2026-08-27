"""Output types with mandatory metadata (spec 3.1, 3.2, 3.5).

Spec 3.5: "No number appears without: units, simulated tissue and activity,
scenario definition, personal-input date and quality, median and uncertainty
interval, model version, parameter sources, active constraints, sensitivity
summary, evidence/support grade, 'not measured' label."

``Estimate`` enforces that.  It cannot be constructed without units and a
support grade, and its renderer always emits the "simulated, not measured"
label.  Spec 3.4's forbidden outputs are checked by name.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional, Sequence

import numpy as np

# Spec 3.4 -- outputs version 1 must never produce.
FORBIDDEN_OUTPUTS = {
    "mitochondrial_health_score": "a universal mitochondrial-health score",
    "mitochondrial_count": "an exact mitochondrial count or density",
    "mitochondrial_density": "an exact mitochondrial count or density",
    "complex_i_capacity": "exact respiratory-complex capacity",
    "respiratory_complex_capacity": "exact respiratory-complex capacity",
    "ros": "reactive-oxygen-species concentration",
    "oxidative_stress": "oxidative stress as a measured quantity",
    "membrane_potential": "mitochondrial membrane potential",
    "mitophagy_rate": "mitophagy rate",
    "fusion_rate": "mitochondrial fusion rate",
    "fission_rate": "mitochondrial fission rate",
    "biological_age": "biological age",
    "lifespan": "expected lifespan",
    "diagnosis": "a diagnosis",
    "energy_feeling": "how energised the user will feel",
    "treatment_recommendation": "a treatment recommendation",
}


class ForbiddenOutputError(ValueError):
    pass


@dataclass(frozen=True)
class Estimate:
    """One simulated quantity as a distribution, with its provenance."""
    name: str
    label: str
    unit: str
    samples: np.ndarray = field(repr=False)
    support: str = "assumed"
    drivers: Sequence[str] = ()
    note: str = ""
    kind: str = "model_computed"      # model_computed | derived | comparison
    measured: bool = False            # always False in version 1

    def __post_init__(self):
        key = self.name.lower()
        if key in FORBIDDEN_OUTPUTS:
            raise ForbiddenOutputError(
                f"{self.name!r} is on the version 1 forbidden-output list "
                f"({FORBIDDEN_OUTPUTS[key]}); the engine must not report it.")
        if not self.unit:
            raise ValueError(f"{self.name}: every reported number needs a unit")
        if self.measured:
            raise ForbiddenOutputError(
                f"{self.name}: version 1 outputs are simulated, never measured")

    # ---- statistics ------------------------------------------------------
    @property
    def n(self) -> int:
        return int(np.size(self.samples))

    def median(self) -> float:
        return float(np.nanmedian(self.samples))

    def mean(self) -> float:
        return float(np.nanmean(self.samples))

    def interval(self, level: float = 0.80) -> tuple:
        lo = (1.0 - level) / 2.0 * 100.0
        return (float(np.nanpercentile(self.samples, lo)),
                float(np.nanpercentile(self.samples, 100.0 - lo)))

    def to_dict(self, intervals=(0.80, 0.95)) -> Dict[str, Any]:
        d = {
            "name": self.name,
            "label": self.label,
            "unit": self.unit,
            "kind": self.kind,
            "median": self.median(),
            "n_samples": self.n,
            "support": self.support,
            "drivers": list(self.drivers),
            "note": self.note,
            "measured": False,
            "status_label": "simulated - not measured",
        }
        for lv in intervals:
            lo, hi = self.interval(lv)
            d[f"ci{int(lv*100)}"] = [lo, hi]
        cf = self.censored_fraction()
        if cf > 0:
            d["censored_fraction"] = cf
            d["censored_note"] = ("Samples at the ceiling value mean the event "
                                  "did not occur within the simulated run.")
        return d

    CENSOR = 1e4   # sentinel for "the event never happened in the run"

    def censored_fraction(self) -> float:
        return float(np.mean(np.asarray(self.samples) >= self.CENSOR * 0.999))

    def render(self, level: float = 0.80) -> str:
        cf = self.censored_fraction()
        if cf >= 0.5:
            return (f"{self.label}: not reached in {cf*100:.0f}% of plausible "
                    "states within the simulated run (simulated, not measured; "
                    f"support: {self.support})")
        lo, hi = self.interval(level)
        return (f"{self.label}: {self.median():.3g} {self.unit} "
                f"[{lo:.3g}-{hi:.3g}, {int(level*100)}% interval] "
                f"(simulated, not measured; support: {self.support})")


@dataclass
class RunOutputs:
    """Everything one scenario produces, with the metadata spec 3.5 demands."""
    scenario: Dict[str, Any]
    estimates: Dict[str, Estimate]
    metadata: Dict[str, Any]
    mechanism: Dict[str, Any] = field(default_factory=dict)
    diagnostics: Dict[str, Any] = field(default_factory=dict)
    warnings: List[str] = field(default_factory=list)
    trajectories: Dict[str, Any] = field(default_factory=dict)
    # Per-ensemble-member sampled parameters and raw outputs. Kept so that a
    # paired contrast can attribute the difference to specific parameters and
    # find the ones that could reverse it.
    member_params: Dict[str, Any] = field(default_factory=dict, repr=False)
    member_values: Dict[str, Any] = field(default_factory=dict, repr=False)

    def get(self, name: str) -> Optional[Estimate]:
        return self.estimates.get(name)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "scenario": self.scenario,
            "metadata": self.metadata,
            "estimates": {k: v.to_dict() for k, v in self.estimates.items()},
            "mechanism": self.mechanism,
            "diagnostics": self.diagnostics,
            "warnings": self.warnings,
            "trajectories": self.trajectories,
        }


# --------------------------------------------------------------------------
# Human-readable renderer
# --------------------------------------------------------------------------

SECTIONS = [
    ("Model-computed acute outputs (spec 3.1)", [
        "atp_demand", "atp_coverage", "oxidative_atp_fraction",
        "glycolytic_atp_fraction", "pcr_atp_fraction", "muscle_vo2",
        "carbohydrate_oxidation", "fat_oxidation", "ketone_oxidation",
        "glycogen_used", "glycogen_remaining", "pcr_end_fraction",
        "pcr_minimum_fraction", "lactate_production", "blood_lactate_peak",
        "muscle_ph_min", "tca_flux", "etc_flux"]),
    ("Derived mechanism outputs (spec 3.2)", [
        "spare_oxidative_capacity", "oxidative_ceiling_workload",
        "crossover_intensity", "time_to_glycogen_limit",
        "time_to_lactate_pressure", "type1_atp_share", "type2_atp_share",
        "atp_per_oxygen", "first_limiting_mechanism_certainty"]),
]


def render_report(out: RunOutputs, level: float = 0.80) -> str:
    lines: List[str] = []
    md = out.metadata
    lines.append("=" * 78)
    lines.append("MITOCHONDRIA IN SILICO -- simulated mechanism report")
    lines.append("=" * 78)
    lines.append(f"Tissue simulated : {md.get('tissue')}")
    lines.append(f"Activity         : {md.get('activity')}")
    lines.append(f"Scenario         : {out.scenario.get('description')}")
    lines.append(f"Model version    : {md.get('model_version')}  "
                 f"registry {md.get('registry_version')}")
    lines.append(f"Personal inputs  : as of {md.get('personal_input_date')} "
                 f"(quality: {md.get('input_quality')})")
    lines.append(f"Ensemble         : {md.get('n_samples')} personal states x "
                 f"biochemical parameter draws")
    lines.append("")
    lines.append("Every number below is SIMULATED. Nothing here is a "
                 "measurement of this person's mitochondria.")
    lines.append("")
    for title, keys in SECTIONS:
        present = [k for k in keys if k in out.estimates]
        if not present:
            continue
        lines.append("-" * 78)
        lines.append(title)
        lines.append("-" * 78)
        for k in present:
            lines.append("  " + out.estimates[k].render(level))
        lines.append("")
    if out.mechanism:
        lines.append("-" * 78)
        lines.append("Limiting mechanism")
        lines.append("-" * 78)
        for k, v in out.mechanism.items():
            lines.append(f"  {k}: {v}")
        lines.append("")
    if out.warnings:
        lines.append("-" * 78)
        lines.append("Warnings and applicability")
        lines.append("-" * 78)
        for w in out.warnings:
            lines.append(f"  ! {w}")
        lines.append("")
    lines.append("-" * 78)
    lines.append("Active constraints: " + ", ".join(md.get("active_constraints", [])
                                                    or ["none recorded"]))
    lines.append("Support grades present: " +
                 ", ".join(sorted({e.support for e in out.estimates.values()})))
    lines.append("This engine is for mechanistic exploration and hypothesis "
                 "generation. It is not intended for diagnosis, treatment "
                 "selection, or autonomous medical advice.")
    return "\n".join(lines)
