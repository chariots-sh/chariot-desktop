"""Command-line interface."""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict, List, Optional

from . import guardrails
from .compare import compare, render_comparison
from .ensemble import run_ensemble, MODEL_VERSION
from .outputs import render_report
from .params import R, REGISTRY_VERSION
from .profiles import load_person, load_scenario, scenario_from_dict
from .qc import run_qc
from .mechanisms import MECHANISMS, catalogue as mechanism_catalogue, validate_use
from .scenario import (Scenario, Intensity, MechanismUse, grid_report,
                       compile_scenarios, starter_grid)


def _parse_mechanisms(specs: Optional[List[str]]) -> tuple:
    """Parse ``NAME:key=value,key=value`` into MechanismUse objects.

    Values that parse as numbers become numbers and everything else stays a
    string, so a mechanism with a categorical setting works from the shell
    without a second flag.  Nothing is coerced into a dose.
    """
    out: List[MechanismUse] = []
    for spec in specs or []:
        name, _, rest = spec.partition(":")
        settings: Dict[str, Any] = {}
        horizon = 0.0
        for item in (x for x in rest.split(",") if x.strip()):
            key, _, value = item.partition("=")
            key, value = key.strip(), value.strip()
            if key == "horizon_days":
                horizon = float(value)
                continue
            try:
                settings[key] = float(value)
            except ValueError:
                settings[key] = value
        out.append(MechanismUse(name.strip(), settings, horizon))
    return tuple(out)


def _reject_bad_mechanisms(sc: Scenario) -> Optional[str]:
    """Fail closed before any work is done, with the reason the user needs."""
    for use in sc.mechanisms:
        verdict = validate_use(use)
        if verdict is not None:
            rule, reason = verdict
            known = ", ".join(sorted(MECHANISMS)) or "none registered"
            return (f"Mechanism rejected ({rule}): {reason}\n"
                    f"Registered mechanisms: {known}\n"
                    "Run 'mitosim mechanisms' for each one's settings and "
                    "supported domain.")
    return None


def _scenario_from_args(a) -> Scenario:
    if a.scenario:
        return load_scenario(a.scenario)
    kind, val = "pct_vo2max", a.intensity
    if a.pace:
        m, _, s = a.pace.partition(":")
        kind, val = "pace_s_per_km", float(m) * 60 + float(s or 0)
    elif a.speed:
        kind, val = "speed_m_s", a.speed
    elif a.hr_zone:
        kind, val = "hr_zone", float(a.hr_zone)
    return Scenario(pattern=a.pattern, intensity=Intensity(kind, val),
                    grade_pct=a.grade, duration_min=a.duration,
                    hours_since_meal=a.hours_since_meal,
                    pre_run_cho_g=a.pre_run_cho,
                    prev_day_cho=a.prev_day_cho,
                    glycogen_prior=a.glycogen_prior,
                    elevation_m=a.elevation,
                    mechanisms=_parse_mechanisms(getattr(a, "mechanism", None)))


def _add_scenario_args(p, prefix=""):
    g = p.add_argument_group(f"{prefix}scenario controls (spec 1.2)")
    g.add_argument("--pattern", default="continuous",
                   choices=["continuous", "progression", "4x4", "10x1", "30:30"])
    g.add_argument("--intensity", type=float, default=0.65,
                   help="fraction of VO2max (default 0.65)")
    g.add_argument("--pace", help="pace as MM:SS per km")
    g.add_argument("--speed", type=float, help="speed in m/s")
    g.add_argument("--hr-zone", type=int, choices=[1, 2, 3, 4, 5])
    g.add_argument("--grade", type=float, default=0.0, help="percent gradient")
    g.add_argument("--duration", type=float, default=40.0, help="minutes")
    g.add_argument("--hours-since-meal", type=float, default=3.0)
    g.add_argument("--pre-run-cho", type=float, default=0.0, help="grams")
    g.add_argument("--prev-day-cho", default="mixed",
                   choices=["low", "mixed", "high"])
    g.add_argument("--glycogen-prior", default="derived",
                   choices=["derived", "low", "moderate", "high"])
    g.add_argument("--elevation", type=float, default=0.0, help="metres")
    g.add_argument("--mechanism", action="append", metavar="SPEC",
                   help="mechanism counterfactual as NAME:key=value[,key=value] "
                        "(repeatable). A mechanism is a hypothetical tissue "
                        "state, not a dose. Example: --mechanism "
                        "mitochondrial_nad_pool:pool_scale=0.8")
    g.add_argument("--scenario", help="path to a scenario JSON file (overrides "
                                      "the flags above)")


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        prog="mitosim",
        description="Mitochondria In Silico -- explore possible mechanisms of "
                    "skeletal-muscle energy metabolism during running. "
                    "Simulated mechanisms only; not for diagnosis, treatment "
                    "selection, or autonomous medical advice.")
    ap.add_argument("--version", action="version",
                    version=f"{MODEL_VERSION} (registry {REGISTRY_VERSION})")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("run", help="simulate one scenario")
    p.add_argument("profile", help="person profile JSON/YAML")
    p.add_argument("-n", "--samples", type=int, default=200)
    p.add_argument("--json", help="write the full result to this path")
    p.add_argument("--seed", type=int, default=20260826)
    _add_scenario_args(p)

    c = sub.add_parser("compare", help="contrast two scenarios (spec 3.3)")
    c.add_argument("profile")
    c.add_argument("--a", required=True, help="scenario A JSON path")
    c.add_argument("--b", required=True, help="scenario B JSON path")
    c.add_argument("-n", "--samples", type=int, default=200)
    c.add_argument("--json")
    c.add_argument("--seed", type=int, default=20260826)

    q = sub.add_parser("qc", help="show input QC and how each input is used")
    q.add_argument("profile")

    v = sub.add_parser("validate", help="run the validation suite (spec 2.10)")
    v.add_argument("--quick", action="store_true")
    v.add_argument("--json", default="out/validation.json")

    sub.add_parser("audit", help="stoichiometry and feasibility audit")
    g = sub.add_parser("grid", help="scenario grid report (spec 1.2)")
    g.add_argument("--json")
    r = sub.add_parser("registry", help="dump the parameter registry")
    r.add_argument("--json", default="out/registry.json")
    ad = sub.add_parser("adapters", help="list experimental adapters (spec 1.3)")
    sub.add_parser("mechanisms", help="list mechanism counterfactual levers")
    ident = sub.add_parser(
        "identifiability",
        help="NAD axis identifiability study (analysis, not a product control)")
    ident.add_argument("profile", nargs="?", default="examples/runner.json")
    ident.add_argument("-n", "--samples", type=int, default=16)
    ident.add_argument("--seed", type=int, default=20260826)
    ident.add_argument("--json", default="out/identifiability.json")

    s = sub.add_parser("serve", help="start the local review web app")
    s.add_argument("--port", type=int, default=8765)
    s.add_argument("--profile", default="examples/runner.json")
    s.add_argument("--validation", default="out/validation.json")
    s.add_argument("--no-browser", action="store_true")

    a = ap.parse_args(argv)

    if a.cmd == "run":
        person = load_person(a.profile)
        sc = _scenario_from_args(a)
        bad = _reject_bad_mechanisms(sc)
        if bad:
            print(bad, file=sys.stderr)
            return 2
        out = run_ensemble(person, sc, n=a.samples, seed=a.seed)
        print(render_report(out))
        if a.json:
            os.makedirs(os.path.dirname(a.json) or ".", exist_ok=True)
            with open(a.json, "w") as f:
                json.dump(out.to_dict(), f, indent=1, default=float)
            print(f"\nFull result written to {a.json}")
        return 0

    if a.cmd == "compare":
        person = load_person(a.profile)
        sc_a, sc_b = load_scenario(a.a), load_scenario(a.b)
        for sc in (sc_a, sc_b):
            bad = _reject_bad_mechanisms(sc)
            if bad:
                print(bad, file=sys.stderr)
                return 2
        res = compare(person, sc_a, sc_b, n=a.samples, seed=a.seed)
        print(render_comparison(res))
        if a.json:
            os.makedirs(os.path.dirname(a.json) or ".", exist_ok=True)
            with open(a.json, "w") as f:
                json.dump(res.to_dict(), f, indent=1, default=float)
        return 0

    if a.cmd == "qc":
        person = load_person(a.profile)
        rep = run_qc(person)
        print(json.dumps(rep.to_dict(), indent=1, default=str))
        return 0

    if a.cmd == "validate":
        from .validation import run_all
        from .validation.runner import render
        val_rep = run_all(quick=a.quick)
        print(render(val_rep))
        os.makedirs(os.path.dirname(a.json) or ".", exist_ok=True)
        with open(a.json, "w") as f:
            json.dump(val_rep, f, indent=1, default=float)
        print(f"\nMachine-readable report written to {a.json}")
        return 0 if val_rep["all_hard_checks_passed"] else 1

    if a.cmd == "audit":
        summary = guardrails.summarise(guardrails.audit_network())
        print(json.dumps(summary, indent=1))
        return 0 if summary["all_passed"] else 1

    if a.cmd == "grid":
        grid_rep = grid_report()
        print(json.dumps(grid_rep, indent=1))
        if a.json:
            with open(a.json, "w") as f:
                json.dump(grid_rep, f, indent=1)
        return 0

    if a.cmd == "registry":
        os.makedirs(os.path.dirname(a.json) or ".", exist_ok=True)
        with open(a.json, "w") as f:
            f.write(R.to_json())
        print(f"{len(R)} parameters and {len(R.equations())} equations written "
              f"to {a.json}")
        return 0

    if a.cmd == "adapters":
        from .adapters import catalogue
        for spec in catalogue():
            status = "ENABLED " if spec["enabled"] else "DISABLED"
            print(f"[{status}] {spec['name']}")
            print(f"    changes    : {spec['parameter_changed']}")
            print(f"    population : {spec['population']} / {spec['tissue']}")
            print(f"    dose       : {spec['dose_range'][0]}-"
                  f"{spec['dose_range'][1]} {spec['dose_unit']}, "
                  f"{spec['timing_range_min'][0]:.0f}-"
                  f"{spec['timing_range_min'][1]:.0f} min before")
            print(f"    effect     : {spec['effect_distribution']}")
            print(f"    evidence   : {spec['evidence_grade']} "
                  f"(support {spec['support']})")
            if spec["confounders"]:
                print(f"    confounders: {'; '.join(spec['confounders'])}")
            if spec["contraindications"]:
                print(f"    contra     : {', '.join(spec['contraindications'])}")
            print(f"    not estimable when: "
                  f"{'; '.join(spec['not_estimable_when'])}")
            print()
        return 0

    if a.cmd == "mechanisms":
        for spec in mechanism_catalogue():
            status = "ENABLED " if spec["enabled"] else "GATED   "
            print(f"[{status}] {spec['name']} -- {spec['label']}")
            print(f"    answers    : {spec['question']}")
            if not spec["enabled"]:
                print(f"    gated as   : {spec['disabled_status']}")
                print(f"    because    : {spec['disabled_reason']}")
            for st in spec["settings"]:
                dom = st["supported_domain"]
                pri = st["prior_range"]
                rng = (f"{st['choices']}" if st["choices"]
                       else f"{dom[0]:g} to {dom[1]:g} {st['unit']}")
                extra = ("" if None in pri else
                         f"; registered prior {pri[0]:g}-{pri[1]:g}, outside "
                         "it the run is sensitivity-only")
                print(f"    setting    : {st['name']} = {st['default']} "
                      f"(supported {rng}{extra})")
            print(f"    changes    : {', '.join(spec['target_handles'])}")
            print(f"    through    : {'; '.join(spec['represented_paths'])}")
            print(f"    NOT modelled: {'; '.join(spec['unrepresented_paths'])}")
            if spec["required_context"]:
                print(f"    requires   : {', '.join(spec['required_context'])}")
            ev = spec["evidence"]
            print(f"    population : {ev['population']} / {ev['tissue']}")
            print(f"    evidence   : {ev['evidence_grade']} "
                  f"(support {ev['support']})")
            print(f"    scope      : {spec['scope_note']}")
            print(f"    {spec['mapping_note']}")
            print()
        return 0

    if a.cmd == "identifiability":
        from .identifiability import run_study, render as render_study
        study = run_study(load_person(a.profile), n=a.samples, seed=a.seed)
        print(render_study(study))
        if a.json:
            os.makedirs(os.path.dirname(a.json) or ".", exist_ok=True)
            with open(a.json, "w") as f:
                json.dump(study.to_dict(), f, indent=1, default=float)
            print(f"\nMachine-readable report written to {a.json}")
        return 0

    if a.cmd == "serve":
        from .webapp import serve
        serve(port=a.port, profile_path=a.profile,
              validation_path=a.validation, open_browser=not a.no_browser)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
