"""Phase 1b: are the cytosolic NAD pool and shuttle capacity distinguishable?

This is an analysis deliverable, not a product control.  It exists to answer
one question before either axis is offered to anyone:

    Across the scenarios this engine actually simulates, do a change in the
    free cytosolic NAD pool and a change in reducing-equivalent shuttle
    capacity move the reported outputs in *different* directions, or in the
    same one?

The concern is concrete.  Both axes act on the same reducing-equivalent
transfer, and near lactate-dehydrogenase equilibrium they can produce nearly
proportional responses.  Two controls that turn out to be one control are worse
than one honest control, because a user who moves both believes they have
explored two hypotheses.

The study measures a two-column local Jacobian.  For every scenario, output and
ensemble member it takes a paired central difference along each axis, scales
each output by its own baseline dispersion so that quantities in different
units can share a matrix, and then asks how close the two columns are to
collinear -- by cosine similarity and by the condition number of the pair.

Three verdicts, and the third one matters as much as the other two:

``distinguishable``
    The two responses are not collinear and both are large enough to see.
    Expose both, with a warning that they are correlated.

``practically_non_identifiable``
    The responses are collinear, or the pair is badly conditioned. Expose one
    composite reducing-equivalent-transfer control instead of two that pretend
    to be independent.

``both_effects_negligible``
    Neither axis moves anything measurably in this regime. That is *not* a
    finding that the axes are equivalent, and it is not evidence that cytosolic
    NAD does not matter biologically -- it means this study cannot separate
    them because there is nothing to separate them by.

One limitation dominates the interpretation of any cytosolic-NAD result here
and is repeated in the report itself: this engine's glycolytic rate law has no
available-NAD+ gate at glyceraldehyde-3-phosphate dehydrogenase.  The most
commonly assumed route by which cytosolic NAD+ would constrain running
metabolism is absent from the model, so a null along it is
``pathway_not_represented`` rather than evidence.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict, field
from typing import Any, Callable, Dict, List, Optional, Tuple

import numpy as np

from .compare import paired_positions
from .ensemble import run_ensemble
from .inputs import PersonInputs
from .levers.nad import (GLYCOLYTIC_GATE_MISSING, apply_cytosolic_pool_scale,
                         apply_shuttle_capacity_scale)
from .qc import run_qc
from .scenario import Intensity, Scenario

STUDY_VERSION = "1.0"

# Outputs the two axes could plausibly move. Deliberately spans the redox
# state, the lactate context, the fuel partition and the acid-base state: two
# axes that look identical in one of those and different in another are
# distinguishable, and a study that watched only one output would miss it.
OUTPUT_KEYS: Tuple[str, ...] = (
    "oxidative_atp_fraction",
    "nonoxidative_atp_fraction",
    "blood_lactate_peak",
    "lactate_production",
    "muscle_ph_type2_min",
    "cho_carbon_fraction",
    "fat_carbon_fraction",
    "pcr_end_fraction",
    "matrix_nadh_fraction_max",
    "spare_oxidative_capacity",
)

# Central difference. Wide enough to lift the response out of solver noise,
# narrow enough that "local" still means something.
STEP_LO, STEP_HI = 0.70, 1.30

# A standardised response smaller than this is treated as no response: it is
# below the scale of the ensemble's own spread on that output.
NEGLIGIBLE_RESPONSE = 0.05
# Above this cosine the two columns are doing the same thing. The bar is set
# at 0.90 rather than at something nearer 1.0 because the question is not
# whether the responses are literally parallel -- it is whether a second
# control buys a user a distinguishable dimension. At |cos| = 0.9 the axes
# already share nine tenths of their response direction, and the tenth that is
# left is not a hypothesis anyone can meaningfully explore by hand.
COLLINEAR_COSINE = 0.90
# Above this condition number the pair cannot be inverted stably.
ILL_CONDITIONED = 30.0


@dataclass(frozen=True)
class Axis:
    """One sweepable model axis and the transform that moves it."""
    name: str
    label: str
    handles: Tuple[str, ...]
    transform: Callable[[Any, float], float]

    def at(self, scale: float) -> Callable[[Any], None]:
        def _apply(state) -> None:
            self.transform(state, scale)
        return _apply


AXES: Tuple[Axis, ...] = (
    Axis("cytosolic_nad_pool", "Free cytosolic NAD pool", ("nad_total_cyt",),
         apply_cytosolic_pool_scale),
    Axis("reducing_equivalent_shuttle", "Shuttle capacity",
         ("k_shuttle_I", "k_shuttle_II"), apply_shuttle_capacity_scale),
)


@dataclass(frozen=True)
class ScenarioCase:
    """One point in the operating regime the study sweeps."""
    name: str
    description: str
    scenario: Scenario


def default_cases() -> Tuple[ScenarioCase, ...]:
    """Easy, threshold and hard running, plus a long fasted run.

    The lactate context is the reason for the spread: the two axes are most
    likely to look alike where lactate dehydrogenase sits near equilibrium and
    most likely to separate where it does not.
    """
    def sc(**kw) -> Scenario:
        return Scenario(intensity=Intensity("pct_vo2max", kw.pop("intensity")),
                        **kw)
    return (
        ScenarioCase("easy", "easy continuous running, fed",
                     sc(intensity=0.60, duration_min=20.0,
                        hours_since_meal=3.0)),
        ScenarioCase("threshold", "threshold continuous running",
                     sc(intensity=0.80, duration_min=20.0,
                        hours_since_meal=3.0)),
        ScenarioCase("hard", "hard continuous running",
                     sc(intensity=0.90, duration_min=15.0,
                        hours_since_meal=3.0)),
        ScenarioCase("long_fasted", "long fasted running, low lactate",
                     sc(intensity=0.62, duration_min=25.0,
                        hours_since_meal=14.0)),
    )


@dataclass
class AxisResponse:
    """The standardised response of every output to one axis, per member."""
    axis: str
    per_output: Dict[str, List[float]] = field(default_factory=dict)
    # Which ensemble members this axis actually resolved, so the two axes can
    # be compared on the members they share rather than on whatever happened
    # to survive each of them.
    member_index: List[int] = field(default_factory=list)

    def column(self, keys: Tuple[str, ...]) -> np.ndarray:
        """Flatten to one column of the local Jacobian."""
        return np.concatenate([np.asarray(self.per_output[k]) for k in keys
                               if k in self.per_output]) \
            if self.per_output else np.zeros(0)

    def rms(self, keys: Tuple[str, ...]) -> float:
        col = self.column(keys)
        return float(np.sqrt(np.mean(col ** 2))) if col.size else 0.0


@dataclass
class CaseFinding:
    """What one scenario says about the two axes."""
    case: str
    description: str
    n_members: int
    keys: List[str]
    rms_response: Dict[str, float]
    cosine: Optional[float]
    condition_number: Optional[float]
    verdict: str
    detail: str

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass
class StudyReport:
    study_version: str
    verdict: str
    recommendation: str
    cases: List[CaseFinding]
    caveats: List[str]
    settings: Dict[str, Any]
    product_decision: str = ""

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["cases"] = [c.to_dict() for c in self.cases]
        return d


# --------------------------------------------------------------------------
# Measurement
# --------------------------------------------------------------------------

def _paired(person: PersonInputs, case: ScenarioCase, axis: Axis, n: int,
            seed: int, qc) -> AxisResponse:
    """Central difference along one axis, paired member by member."""
    lo = run_ensemble(person, case.scenario, n=n, seed=seed, qc=qc, workers=1,
                      keep_traj=0, audit=False,
                      state_transform=axis.at(STEP_LO))
    hi = run_ensemble(person, case.scenario, n=n, seed=seed, qc=qc, workers=1,
                      keep_traj=0, audit=False,
                      state_transform=axis.at(STEP_HI))
    resp = AxisResponse(axis.name)
    # The two step arms are seeded identically but need not survive
    # identically, so pair them by member rather than by position.
    pos_lo, pos_hi = paired_positions(lo, hi)
    resp.member_index = [int(i) for i in np.asarray(lo.member_index,
                                                    dtype=int)[pos_lo]] \
        if pos_lo.size and len(lo.member_index) else []
    for key in OUTPUT_KEYS:
        a, b = lo.get(key), hi.get(key)
        if a is None or b is None or not pos_lo.size:
            continue
        if pos_lo.max() >= a.n or pos_hi.max() >= b.n:
            continue
        xa, xb = np.asarray(a.samples)[pos_lo], np.asarray(b.samples)[pos_hi]
        d = (xb - xa) / (STEP_HI - STEP_LO)
        # Standardise by the baseline arm's own dispersion, so outputs in
        # different units can share one matrix and a response is measured
        # against the spread it has to be visible above.
        scale = float(np.nanstd(xa))
        if not np.isfinite(scale) or scale < 1e-12:
            scale = max(abs(float(np.nanmedian(xa))), 1e-9)
        finite = np.isfinite(d)
        if finite.sum() < 4:
            continue
        resp.per_output[key] = (d[finite] / scale).tolist()
    return resp


def _compare(case: ScenarioCase, responses: Dict[str, AxisResponse],
             n: int) -> CaseFinding:
    # Only outputs both axes resolved, and only if they resolved them over the
    # same number of members: a ragged pair of columns cannot be stacked into a
    # Jacobian, and silently truncating one to fit the other would compare
    # different people.
    keys = tuple(k for k in OUTPUT_KEYS
                 if all(k in r.per_output for r in responses.values())
                 and len({len(r.per_output[k])
                          for r in responses.values()}) == 1)
    rms = {name: r.rms(keys) for name, r in responses.items()}
    if not keys or len(responses) < 2:
        return CaseFinding(
            case.name, case.description, n, list(keys), rms, None, None,
            "not_measurable",
            "No output was resolvable in both arms of both axes, so nothing "
            "about identifiability can be concluded from this scenario.")

    cols = [responses[a.name].column(keys) for a in AXES]
    J = np.column_stack(cols)
    norms = [float(np.linalg.norm(c)) for c in cols]
    if max(rms.values()) < NEGLIGIBLE_RESPONSE:
        return CaseFinding(
            case.name, case.description, n, list(keys), rms, None, None,
            "both_effects_negligible",
            "Neither axis moved any reported output by more than "
            f"{NEGLIGIBLE_RESPONSE:g} of the ensemble's own spread. This does "
            "not mean the axes are equivalent, and it is not evidence that "
            "either quantity is biologically inert; it means this scenario "
            "cannot separate them because there is nothing to separate them "
            "by.")
    if min(norms) <= 1e-12:
        cos = None
    else:
        cos = float(abs(np.dot(cols[0], cols[1]) / (norms[0] * norms[1])))
    sv = np.linalg.svd(J, compute_uv=False)
    cond = float(sv[0] / sv[-1]) if sv[-1] > 1e-15 else float("inf")

    if cos is not None and cos > COLLINEAR_COSINE:
        verdict = "practically_non_identifiable"
        detail = (f"The two response columns are collinear (|cos| = {cos:.3f} "
                  f"> {COLLINEAR_COSINE}). In this scenario the axes are one "
                  "degree of freedom wearing two names.")
    elif cond > ILL_CONDITIONED:
        verdict = "practically_non_identifiable"
        detail = (f"The two-column Jacobian is ill-conditioned "
                  f"(condition number {cond:.1f} > {ILL_CONDITIONED:g}), so "
                  "the axes cannot be separated stably even though their "
                  "directions differ slightly.")
    else:
        verdict = "distinguishable"
        detail = (f"The responses are not collinear (|cos| = "
                  f"{cos if cos is not None else float('nan'):.3f}) and the "
                  f"pair is adequately conditioned (condition number "
                  f"{cond:.1f}).")
    return CaseFinding(case.name, case.description, n, list(keys), rms, cos,
                       cond, verdict, detail)


def run_study(person: PersonInputs, cases: Optional[Tuple[ScenarioCase, ...]]
              = None, n: int = 16, seed: int = 20260826) -> StudyReport:
    """Sweep both gated axes across the scenario set and decide."""
    qc = run_qc(person)
    cases = cases or default_cases()
    findings: List[CaseFinding] = []
    for case in cases:
        responses = {axis.name: _paired(person, case, axis, n, seed, qc)
                     for axis in AXES}
        findings.append(_compare(case, responses, n))

    # A single separating scenario does not license two controls everywhere.
    # The verdict is taken over the scenarios where the question could be
    # answered at all, and a partial result says so and names where the axes
    # collapse rather than rounding itself up.
    sep = [f.case for f in findings if f.verdict == "distinguishable"]
    collapsed = [f.case for f in findings
                 if f.verdict == "practically_non_identifiable"]
    if not sep and not collapsed:
        overall = "both_effects_negligible"
        rec = ("Keep both axes gated. Neither moves the reported outputs "
               "enough to be worth a control in this operating regime, and "
               "shipping a control that does nothing visible would invite a "
               "user to read a null as biology.")
    elif not collapsed:
        overall = "distinguishable"
        rec = ("The axes separate in every scenario measured. If they are "
               "exposed, expose both, each carrying a warning that they are "
               "correlated and that moving both is not two independent "
               "hypotheses. Any glycolytic reading of a cytosolic-NAD result "
               "stays pathway_not_represented.")
    elif not sep:
        overall = "practically_non_identifiable"
        rec = ("Do not expose two controls. Offer one composite "
               "reducing-equivalent-transfer control instead, and say in the "
               "product that it stands for both the cytosolic pool and "
               "shuttle capacity because this engine cannot separate them.")
    else:
        overall = "distinguishable_in_part"
        rec = ("The axes separate in " + ", ".join(sep) + " and collapse into "
               "one direction in " + ", ".join(collapsed) + ". Two independent "
               "controls would therefore be honest in part of the operating "
               "regime and misleading in the rest. The conservative reading is "
               "a single composite reducing-equivalent-transfer control, or "
               "two controls that are shown as correlated and disabled where "
               "they collapse. Either way this is a design decision, not "
               "something this study settles on its own.")

    return StudyReport(
        study_version=STUDY_VERSION,
        verdict=overall, recommendation=rec, cases=findings,
        product_decision=(
            "Both axes remain gated. This study is an analysis deliverable; "
            "exposing either axis is a separate product decision that also "
            "has to answer what a user would do with it, and it does not "
            "follow automatically from a verdict here."),
        caveats=[
            GLYCOLYTIC_GATE_MISSING,
            "A null here is a statement about this model in this operating "
            "regime. It is not evidence about human muscle.",
            "The two axes are compared as a local central difference around "
            f"the sampled state ({STEP_LO:g} to {STEP_HI:g}); a strongly "
            "non-linear response outside that window would not be seen.",
            "Both pools are conserved within a run: NAD consumption and "
            "resynthesis are absent from the model, so nothing here speaks to "
            "turnover.",
        ],
        settings={"n_members": n, "seed": seed, "step": [STEP_LO, STEP_HI],
                  "outputs": list(OUTPUT_KEYS),
                  "negligible_response": NEGLIGIBLE_RESPONSE,
                  "collinear_cosine": COLLINEAR_COSINE,
                  "ill_conditioned": ILL_CONDITIONED})


def render(report: StudyReport) -> str:
    lines = ["=" * 78,
             "NAD AXIS IDENTIFIABILITY STUDY (analysis, not a product control)",
             "=" * 78,
             f"study version {report.study_version}   "
             f"n = {report.settings['n_members']} members per arm   "
             f"step {report.settings['step'][0]}-{report.settings['step'][1]}",
             ""]
    for f in report.cases:
        lines.append(f"  {f.case:<14s} {f.verdict}")
        lines.append(f"      {f.description}")
        rms = ", ".join(f"{k} {v:.3f}" for k, v in sorted(f.rms_response.items()))
        lines.append(f"      standardised response (RMS): {rms}")
        if f.cosine is not None:
            lines.append(f"      |cos| = {f.cosine:.3f}   condition number = "
                         f"{f.condition_number:.1f}")
        lines.append(f"      {f.detail}")
        lines.append("")
    lines += ["-" * 78, f"VERDICT: {report.verdict}", "-" * 78,
              report.recommendation, "",
              f"Product decision: {report.product_decision}", "", "Caveats"]
    for c in report.caveats:
        lines.append(f"  ! {c}")
    return "\n".join(lines)


__all__ = ["Axis", "AXES", "ScenarioCase", "AxisResponse", "CaseFinding",
           "StudyReport", "default_cases", "run_study", "render",
           "OUTPUT_KEYS", "STUDY_VERSION"]
