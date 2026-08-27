"""Scenario controls and the scenario compiler (spec 1.2).

A scenario is the counterfactual being simulated.  The compiler exists because
the discrete starter grid described in the spec (5 patterns x 5 intensities x
5 durations x 5 fasting states x 4 carbohydrate doses x 3 glycogen priors x
3 oxygen environments = 22,500) contains combinations that are contradictory or
physiologically impossible.  Those are removed *with a stated reason* rather
than silently simulated.
"""

from __future__ import annotations

import hashlib
import itertools
import json
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, Iterator, List, Optional, Tuple

# --------------------------------------------------------------------------
# Control vocabularies (spec 1.2 "Initial levels or representation")
# --------------------------------------------------------------------------

PATTERNS = ("continuous", "progression", "4x4", "10x1", "30:30")
DURATIONS_MIN = (10, 20, 40, 60, 90)
HOURS_SINCE_MEAL = (1, 3, 6, 12, 16)
PRE_RUN_CHO_G = (0, 25, 50, 100)
PREV_DAY_CHO = ("low", "mixed", "high")
GLYCOGEN_PRIOR = ("low", "moderate", "high")
OXYGEN_ENVIRONMENTS = (0, 1500, 3000)          # metres of elevation
INTENSITY_LEVELS = (0.55, 0.65, 0.75, 0.85, 0.95)   # fraction of VO2max

# Interval structure: (work_s, recovery_s, recovery_intensity_fraction_of_work,
#                      warmup_min)
INTERVAL_STRUCTURE = {
    "4x4":   (240.0, 180.0, 0.55, 10.0),
    "10x1":  (60.0, 60.0, 0.50, 10.0),
    "30:30": (30.0, 30.0, 0.50, 8.0),
}

# Minimum session length a pattern can physically occupy.
MIN_DURATION_MIN = {
    "continuous": 5.0,
    "progression": 15.0,
    "4x4": 30.0,     # warm-up + at least 2 work bouts
    "10x1": 20.0,
    "30:30": 12.0,
}


@dataclass(frozen=True)
class Intensity:
    """How the user specified effort.  All three forms are supported; the demand
    model resolves them to a running speed."""
    kind: str                 # "pct_vo2max" | "pace_s_per_km" | "hr_zone" | "speed_m_s"
    value: float

    def to_dict(self):
        return asdict(self)


@dataclass(frozen=True)
class ExperimentalUse:
    """A requested experimental adapter with its dose and timing (spec 1.3)."""
    adapter: str
    dose: float = 0.0
    dose_unit: str = "mg"
    timing_min_before: float = 60.0
    days_loaded: float = 0.0

    def to_dict(self):
        return asdict(self)


@dataclass(frozen=True)
class Scenario:
    pattern: str = "continuous"
    intensity: Intensity = field(default_factory=lambda: Intensity("pct_vo2max", 0.65))
    grade_pct: float = 0.0
    duration_min: float = 40.0
    hours_since_meal: float = 3.0
    pre_run_cho_g: float = 0.0
    prev_day_cho: str = "mixed"
    glycogen_prior: str = "derived"      # "derived" | low | moderate | high
    elevation_m: float = 0.0
    time_of_day: str = "08:00"
    experimental: Tuple[ExperimentalUse, ...] = ()
    label: str = ""

    # ---- identity -------------------------------------------------------
    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["intensity"] = self.intensity.to_dict()
        d["experimental"] = [e.to_dict() for e in self.experimental]
        return d

    def key(self) -> str:
        blob = json.dumps(self.to_dict(), sort_keys=True)
        return hashlib.sha256(blob.encode()).hexdigest()[:16]

    def describe(self) -> str:
        if self.label:
            return self.label
        i = self.intensity
        if i.kind == "pct_vo2max":
            eff = f"{i.value*100:.0f}% VO2max"
        elif i.kind == "pace_s_per_km":
            eff = f"{int(i.value)//60}:{int(i.value)%60:02d}/km"
        elif i.kind == "hr_zone":
            eff = f"HR zone {i.value:.0f}"
        else:
            eff = f"{i.value:.2f} m/s"
        bits = [f"{self.pattern}", eff, f"{self.duration_min:.0f} min"]
        if self.grade_pct:
            bits.append(f"{self.grade_pct:+.1f}% grade")
        bits.append(f"{self.hours_since_meal:.0f} h since meal")
        if self.pre_run_cho_g:
            bits.append(f"{self.pre_run_cho_g:.0f} g CHO pre-run")
        bits.append(f"prev-day CHO {self.prev_day_cho}")
        if self.elevation_m:
            bits.append(f"{self.elevation_m:.0f} m elevation")
        for e in self.experimental:
            bits.append(f"+{e.adapter}")
        return ", ".join(bits)


# --------------------------------------------------------------------------
# Compiler
# --------------------------------------------------------------------------

@dataclass
class Rejection:
    scenario: Scenario
    rule: str
    reason: str


def _check(s: Scenario) -> Optional[Tuple[str, str]]:
    """Return (rule, reason) if the scenario must be removed."""
    if s.pattern not in PATTERNS:
        return ("unknown_pattern", f"pattern {s.pattern!r} is not implemented")

    if s.duration_min < MIN_DURATION_MIN[s.pattern]:
        return ("pattern_too_short",
                f"a {s.pattern} session cannot fit in {s.duration_min:.0f} min "
                f"(needs at least {MIN_DURATION_MIN[s.pattern]:.0f} min "
                "including warm-up)")

    if abs(s.grade_pct) > 45.0:
        return ("grade_out_of_domain",
                "gradient is outside the -45%..+45% range measured by the "
                "cost-of-running source; the engine will not extrapolate it")

    if s.intensity.kind == "pct_vo2max":
        frac = s.intensity.value
        if frac > 1.05:
            return ("intensity_above_vo2max",
                    "sustained demand above VO2max is not a runnable steady "
                    "workload in this engine")
        # Tolerable-duration screen: continuous work near VO2max for a long
        # time is not a scenario a person can complete.
        if s.pattern in ("continuous", "progression"):
            if frac >= 0.95 and s.duration_min > 20:
                return ("intensity_duration_infeasible",
                        f"{frac*100:.0f}% VO2max cannot be held continuously for "
                        f"{s.duration_min:.0f} min")
            if frac >= 0.85 and s.duration_min > 60:
                return ("intensity_duration_infeasible",
                        f"{frac*100:.0f}% VO2max for {s.duration_min:.0f} min "
                        "exceeds a plausible continuous effort")
        if s.pattern == "progression" and frac >= 0.90:
            return ("progression_overshoot",
                    "a progression run finishing above 90% VO2max would need to "
                    "exceed VO2max in its final segment")
        if s.pattern in ("4x4", "10x1", "30:30") and frac < 0.70:
            return ("interval_intensity_too_low",
                    f"{frac*100:.0f}% VO2max work bouts do not constitute a "
                    f"{s.pattern} interval session; use 'continuous' instead")

    # Glycogen prior must be consistent with the carbohydrate history that
    # would produce it (spec 2.4 conditions the posterior on prior intake).
    if s.glycogen_prior == "high" and s.prev_day_cho == "low":
        return ("glycogen_history_contradiction",
                "a high initial glycogen prior contradicts low previous-day "
                "carbohydrate intake")
    if s.glycogen_prior == "low" and s.prev_day_cho == "high" and \
            s.hours_since_meal <= 3:
        return ("glycogen_history_contradiction",
                "a low initial glycogen prior contradicts high previous-day "
                "carbohydrate intake with a recent meal and no intervening "
                "exercise")

    # Pre-run carbohydrate is a gel/drink taken shortly before the run.  If the
    # scenario also says the last meal was under an hour ago, the two controls
    # are describing the same event twice.
    if s.pre_run_cho_g >= 50 and s.hours_since_meal < 1.0:
        return ("double_counted_intake",
                "a large pre-run carbohydrate dose plus a meal inside the last "
                "hour double-counts the same intake event")

    if s.elevation_m > 5500:
        return ("elevation_out_of_domain",
                "elevation beyond 5500 m is outside the supported oxygen "
                "environment")
    return None


def compile_scenarios(candidates) -> Tuple[List[Scenario], List[Rejection]]:
    """Filter a candidate iterable into (valid, rejected-with-reasons)."""
    ok: List[Scenario] = []
    bad: List[Rejection] = []
    for s in candidates:
        verdict = _check(s)
        if verdict is None:
            ok.append(s)
        else:
            bad.append(Rejection(s, verdict[0], verdict[1]))
    return ok, bad


def starter_grid() -> Iterator[Scenario]:
    """The discrete starter grid from spec 1.2 -- 22,500 raw combinations."""
    for (pat, inten, dur, hsm, cho, glyc, elev) in itertools.product(
            PATTERNS, INTENSITY_LEVELS, DURATIONS_MIN, HOURS_SINCE_MEAL,
            PRE_RUN_CHO_G, GLYCOGEN_PRIOR, OXYGEN_ENVIRONMENTS):
        yield Scenario(
            pattern=pat,
            intensity=Intensity("pct_vo2max", inten),
            duration_min=float(dur),
            hours_since_meal=float(hsm),
            pre_run_cho_g=float(cho),
            prev_day_cho={"low": "low", "moderate": "mixed", "high": "high"}[glyc],
            glycogen_prior=glyc,
            elevation_m=float(elev),
        )


def grid_report() -> Dict[str, Any]:
    """Counts and rejection reasons for the starter grid."""
    raw = list(starter_grid())
    ok, bad = compile_scenarios(raw)
    by_rule: Dict[str, int] = {}
    examples: Dict[str, str] = {}
    for r in bad:
        by_rule[r.rule] = by_rule.get(r.rule, 0) + 1
        examples.setdefault(r.rule, f"{r.scenario.describe()} -> {r.reason}")
    return {
        "raw_combinations": len(raw),
        "valid": len(ok),
        "removed": len(bad),
        "removed_by_rule": dict(sorted(by_rule.items(), key=lambda kv: -kv[1])),
        "example_per_rule": examples,
        "axes": {
            "patterns": list(PATTERNS),
            "intensities_pct_vo2max": [i * 100 for i in INTENSITY_LEVELS],
            "durations_min": list(DURATIONS_MIN),
            "hours_since_meal": list(HOURS_SINCE_MEAL),
            "pre_run_cho_g": list(PRE_RUN_CHO_G),
            "glycogen_priors": list(GLYCOGEN_PRIOR),
            "elevations_m": list(OXYGEN_ENVIRONMENTS),
        },
    }
