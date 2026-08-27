"""Validation suite (spec 2.10).

The engine is exploratory, so success does not require biopsy-level prediction
for a specific user. It requires scientific coherence, directional validity, and
honest uncertainty. These modules test exactly that, and they report what fails
as prominently as what passes.
"""
from .runner import run_all, VALIDATION_VERSION   # noqa: F401
