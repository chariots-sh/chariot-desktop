"""Dimensional analysis for every parameter and flux in the engine.

The validation plan (spec 2.10.A) requires "test units on every equation and
parameter".  This module gives us a small, dependency-free unit algebra so that
the parameter registry can refuse to hold a value whose declared unit does not
parse, and so that flux declarations can be checked against the dimension of the
state variable they act on.

Dimensions are tracked as an exponent vector over SI base dimensions we need:

    (length, mass, time, amount, temperature)

Concentrations are ``amount / length**3`` and fluxes are
``amount / length**3 / time``; that is what the mass-balance checker asserts.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Dict, Tuple

BASE = ("m", "kg", "s", "mol", "K")
_ZERO: Tuple[int, ...] = (0, 0, 0, 0, 0)


@dataclass(frozen=True)
class Dim:
    """A dimension vector with a scale factor to SI base units."""

    exps: Tuple[float, ...] = _ZERO
    scale: float = 1.0

    def __mul__(self, other: "Dim") -> "Dim":
        return Dim(tuple(a + b for a, b in zip(self.exps, other.exps)),
                   self.scale * other.scale)

    def __truediv__(self, other: "Dim") -> "Dim":
        return Dim(tuple(a - b for a, b in zip(self.exps, other.exps)),
                   self.scale / other.scale)

    def __pow__(self, n: float) -> "Dim":
        return Dim(tuple(a * n for a in self.exps), self.scale ** n)

    def same_dimension(self, other: "Dim") -> bool:
        return self.exps == other.exps

    def __str__(self) -> str:
        parts = [f"{b}^{e:g}" for b, e in zip(BASE, self.exps) if e]
        body = "*".join(parts) if parts else "1"
        return body if self.scale == 1.0 else f"{self.scale:g}*{body}"


def _d(**kw: float) -> Dim:
    return Dim(tuple(float(kw.get(b, 0)) for b in BASE))


DIMENSIONLESS = Dim()

# Unit symbol -> Dim.  Scale is relative to SI base units.
UNITS: Dict[str, Dim] = {
    "1": DIMENSIONLESS,
    "fraction": DIMENSIONLESS,
    "ratio": DIMENSIONLESS,
    "pH": DIMENSIONLESS,
    "count": DIMENSIONLESS,
    # length
    "m": _d(m=1),
    "cm": Dim(_d(m=1).exps, 1e-2),
    "km": Dim(_d(m=1).exps, 1e3),
    "L": Dim(_d(m=3).exps, 1e-3),
    "dL": Dim(_d(m=3).exps, 1e-4),
    "mL": Dim(_d(m=3).exps, 1e-6),
    # mass
    "kg": _d(kg=1),
    "g": Dim(_d(kg=1).exps, 1e-3),
    "mg": Dim(_d(kg=1).exps, 1e-6),
    "ug": Dim(_d(kg=1).exps, 1e-9),
    # time
    "s": _d(s=1),
    "min": Dim(_d(s=1).exps, 60.0),
    "h": Dim(_d(s=1).exps, 3600.0),
    "d": Dim(_d(s=1).exps, 86400.0),
    "y": Dim(_d(s=1).exps, 365.25 * 86400.0),
    # amount
    "mol": _d(mol=1),
    "mmol": Dim(_d(mol=1).exps, 1e-3),
    "umol": Dim(_d(mol=1).exps, 1e-6),
    "nmol": Dim(_d(mol=1).exps, 1e-9),
    # temperature
    "K": _d(K=1),
    "degC": _d(K=1),
    # derived
    "J": _d(m=2, kg=1, s=-2),
    "kJ": Dim(_d(m=2, kg=1, s=-2).exps, 1e3),
    "W": _d(m=2, kg=1, s=-3),
    "Pa": _d(m=-1, kg=1, s=-2),
    "mmHg": Dim(_d(m=-1, kg=1, s=-2).exps, 133.322),
    "beat": DIMENSIONLESS,
    "bpm": Dim(_d(s=-1).exps, 1 / 60.0),
}

_TOKEN = re.compile(r"([A-Za-z_]+[A-Za-z_0-9]*|\d+\.?\d*)")


def parse(unit: str) -> Dim:
    """Parse a unit string such as ``mmol/L/s`` or ``J/kg/m`` into a Dim.

    Supported syntax: symbols joined by ``*``, ``/`` and ``^`` with integer or
    decimal exponents.  ``%`` is treated as a dimensionless 1/100 scale.
    """
    u = unit.strip()
    if u in ("", "-", "none"):
        return DIMENSIONLESS
    if u == "%":
        return Dim(_ZERO, 0.01)
    # normalise "per" spelling and superscripts
    u = u.replace("·", "*").replace("−", "-")
    result = DIMENSIONLESS
    # split on * and / keeping operators
    tokens = re.split(r"([*/])", u)
    op = "*"
    for tok in tokens:
        tok = tok.strip()
        if tok in ("*", "/"):
            op = tok
            continue
        if not tok:
            continue
        if "^" in tok:
            sym, _, exp = tok.partition("^")
            power = float(exp)
        else:
            sym, power = tok, 1.0
        sym = sym.strip()
        if sym not in UNITS:
            raise ValueError(f"unknown unit symbol {sym!r} in {unit!r}")
        d = UNITS[sym] ** power
        result = result * d if op == "*" else result / d
    return result


def convert(value: float, frm: str, to: str) -> float:
    """Convert a value between two commensurable units."""
    a, b = parse(frm), parse(to)
    if not a.same_dimension(b):
        raise ValueError(f"cannot convert {frm!r} -> {to!r}: {a} vs {b}")
    return value * a.scale / b.scale


def compatible(a: str, b: str) -> bool:
    try:
        return parse(a).same_dimension(parse(b))
    except ValueError:
        return False


CONCENTRATION = parse("mmol/L")
FLUX = parse("mmol/L/s")
