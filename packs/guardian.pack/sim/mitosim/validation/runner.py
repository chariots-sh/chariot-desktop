"""Run the whole validation suite and produce a machine-readable report."""

from __future__ import annotations

import json
import platform
import sys
import time
from typing import Any, Dict, List

from ..ensemble import MODEL_VERSION
from ..params import REGISTRY_VERSION, R
from ..scenario import grid_report
from .common import Check
from . import (gates, directional, cohort, external, falsification,
               mechanisms)

VALIDATION_VERSION = "0.2.0"


def run_all(quick: bool = False, verbose: bool = True) -> Dict[str, Any]:
    t0 = time.time()
    n = 16 if quick else 32
    checks: List[Check] = []
    extra: Dict[str, Any] = {}

    def say(msg):
        if verbose:
            print(msg, flush=True)

    say("A. equation, conservation and stability verification ...")
    checks += gates.run()

    say("B. published directional contrasts ...")
    checks += directional.run()

    say("C. virtual-person differentiation ...")
    c_checks, c_summary = cohort.run(n=n, quick=quick)
    checks += c_checks
    extra["cohort"] = c_summary
    extra["quick"] = quick

    say("D. external data contrasts ...")
    d_checks, d_summary = external.run(n=n + 8)
    checks += d_checks
    extra["external"] = d_summary

    say("E. falsification tests ...")
    e_checks, e_summary = falsification.run()
    checks += e_checks
    extra["falsification"] = e_summary

    say("F. mechanism levers across people ...")
    f_checks, f_summary = mechanisms.run(n=12 if quick else 16, quick=quick)
    checks += f_checks
    extra["mechanisms"] = f_summary

    extra["scenario_grid"] = grid_report()
    extra["open_gates"] = gates.OPEN_GATES

    by_section: Dict[str, Dict[str, int]] = {}
    for c in checks:
        s = by_section.setdefault(c.section, {"passed": 0, "failed": 0,
                                              "warnings": 0})
        if c.passed:
            s["passed"] += 1
        else:
            s["failed"] += 1
        if c.severity == "warning":
            s["warnings"] += 1

    failed = [c for c in checks if not c.passed]
    hard_failed = [c for c in failed if c.severity == "error"]
    report = {
        "validation_version": VALIDATION_VERSION,
        "model_version": MODEL_VERSION,
        "registry_version": REGISTRY_VERSION,
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "elapsed_s": round(time.time() - t0, 1),
        "n_checks": len(checks),
        "n_passed": len(checks) - len(failed),
        "n_failed": len(failed),
        "n_hard_failed": len(hard_failed),
        "all_hard_checks_passed": not hard_failed,
        "by_section": by_section,
        "checks": [c.to_dict() for c in checks],
        "parameters_registered": len(R),
        **extra,
    }
    return report


def render(report: Dict[str, Any]) -> str:
    lines = ["=" * 78,
             "MITOCHONDRIA IN SILICO -- validation report",
             "=" * 78,
             f"model {report['model_version']}   registry "
             f"{report['registry_version']}   suite "
             f"{report['validation_version']}",
             f"{report['n_passed']}/{report['n_checks']} checks passed "
             f"({report['n_hard_failed']} hard failures) in "
             f"{report['elapsed_s']}s",
             ""]
    for section, s in report["by_section"].items():
        lines.append(f"  {section:<40s} {s['passed']:>3d} passed  "
                     f"{s['failed']:>3d} failed")
    lines.append("")
    fails = [c for c in report["checks"] if not c["passed"]]
    if fails:
        lines.append("-" * 78)
        lines.append("FAILING CHECKS")
        lines.append("-" * 78)
        for c in fails:
            lines.append(f"  [{c['severity']}] {c['section']} / {c['name']}")
            lines.append(f"      expected {c['expected']}, observed "
                         f"{c['observed']}")
            lines.append(f"      {c['detail']}")
    lines.append("")
    lines.append("-" * 78)
    lines.append("OPEN VALIDATION GATES (not claimed as passed)")
    lines.append("-" * 78)
    for g in report["open_gates"]:
        lines.append(f"  {g['gate']}: {g['status']}")
        lines.append(f"      {g['why']}")
    return "\n".join(lines)
