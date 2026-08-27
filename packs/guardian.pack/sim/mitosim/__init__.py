"""Mitochondria In Silico -- possible skeletal-muscle energy mechanisms during
running, computed as distributions with explicit uncertainty.

The engine does not measure anyone's mitochondria. It computes mechanisms
consistent with a published physiological model, the supplied observations, and
explicitly represented uncertainty. It is intended for mechanistic exploration
and hypothesis generation, and is not intended for diagnosis, treatment
selection, or autonomous medical advice.

Typical use::

    from mitosim.profiles import load_person
    from mitosim.scenario import Scenario, Intensity
    from mitosim.ensemble import run_ensemble
    from mitosim.outputs import render_report

    person = load_person("examples/runner.json")
    scenario = Scenario(intensity=Intensity("pct_vo2max", 0.70),
                        duration_min=45, hours_since_meal=3)
    print(render_report(run_ensemble(person, scenario, n=200)))
"""

__all__ = [
    "units", "provenance", "params", "inputs", "qc", "estimate", "demand",
    "muscle", "guardrails", "adapters", "ensemble", "sensitivity", "compare",
    "outputs", "scenario", "profiles", "validation",
]

__version__ = "0.2.0"
INTENDED_USE = "mechanistic exploration and hypothesis generation"
NOT_INTENDED_FOR = ("diagnosis, treatment selection, or autonomous medical "
                    "advice")
