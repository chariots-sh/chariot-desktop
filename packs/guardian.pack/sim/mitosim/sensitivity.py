"""Global sensitivity analysis (spec 2.8).

"Global sensitivity analysis identifies which uncertain parameters drive each
conclusion. If plausible parameter samples reverse the direction of a
comparison, the result is 'unresolved.'"

The ensemble already samples every uncertain parameter jointly, so the sample
itself is the design.  Rank correlation between a sampled parameter and an
output identifies drivers without assuming linearity or a particular functional
form; partial rank correlation removes the confounding between correlated
parameters.
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Optional

import numpy as np


def _rankdata(x: np.ndarray) -> np.ndarray:
    order = np.argsort(x, kind="mergesort")
    ranks = np.empty_like(order, dtype=float)
    ranks[order] = np.arange(1, len(x) + 1, dtype=float)
    # average ties
    _, inv, counts = np.unique(x, return_inverse=True, return_counts=True)
    if np.any(counts > 1):
        sums = np.zeros(len(counts))
        np.add.at(sums, inv, ranks)
        ranks = (sums / counts)[inv]
    return ranks


def spearman(x: np.ndarray, y: np.ndarray) -> float:
    m = np.isfinite(x) & np.isfinite(y)
    if m.sum() < 8:
        return 0.0
    rx, ry = _rankdata(x[m]), _rankdata(y[m])
    sx, sy = rx.std(), ry.std()
    if sx < 1e-12 or sy < 1e-12:
        return 0.0
    return float(np.corrcoef(rx, ry)[0, 1])


def prcc(params: Dict[str, np.ndarray], y: np.ndarray,
         names: Optional[List[str]] = None) -> Dict[str, float]:
    """Partial rank correlation coefficients.

    Regress the rank of each parameter and the rank of the output on the ranks
    of all the other parameters, then correlate the residuals.  This separates a
    parameter's own influence from influence it merely shares with correlated
    parameters.
    """
    names = names or [k for k, v in params.items()
                      if np.isfinite(v).sum() > 8 and np.nanstd(v) > 1e-12]
    if not names:
        return {}
    mask = np.isfinite(y)
    for n in names:
        mask &= np.isfinite(params[n])
    if mask.sum() < max(12, len(names) + 3):
        # Not enough samples for a stable partial correlation; fall back.
        return {n: spearman(params[n][mask], y[mask]) for n in names}

    X = np.column_stack([_rankdata(params[n][mask]) for n in names])
    yr = _rankdata(y[mask])
    X = (X - X.mean(0)) / (X.std(0) + 1e-12)
    yr = (yr - yr.mean()) / (yr.std() + 1e-12)
    ones = np.ones((X.shape[0], 1))
    out: Dict[str, float] = {}
    for j, n in enumerate(names):
        others = np.delete(X, j, axis=1)
        A = np.hstack([ones, others])
        try:
            coef_x, *_ = np.linalg.lstsq(A, X[:, j], rcond=None)
            coef_y, *_ = np.linalg.lstsq(A, yr, rcond=None)
        except np.linalg.LinAlgError:
            out[n] = 0.0
            continue
        rx = X[:, j] - A @ coef_x
        ry = yr - A @ coef_y
        sx, sy = rx.std(), ry.std()
        out[n] = 0.0 if sx < 1e-9 or sy < 1e-9 else float(
            np.corrcoef(rx, ry)[0, 1])
    return out


def noise_floor(n: int) -> float:
    """Approximate magnitude below which a rank correlation is indistinguishable
    from noise at this sample size.

    With around a hundred sampled parameters and a few tens of ensemble members,
    a rank correlation of 0.3 arises by chance routinely. Reporting those as
    drivers is worse than reporting nothing: it hands a reviewer a confident
    causal story about a parameter that may not even be used. The floor is
    roughly two and a half standard errors of a correlation estimate.
    """
    return max(0.18, 2.5 / math.sqrt(max(n, 4)))


def rank_drivers(params: Dict[str, np.ndarray], y: np.ndarray,
                 top: int = 8) -> List[Dict[str, Any]]:
    """Return the parameters that most drive an output, with direction.

    Correlations below the sample-size noise floor are dropped rather than
    ranked, so a short ensemble reports few drivers instead of confident
    nonsense.
    """
    from .params import R
    cors = prcc(params, y)
    n = int(np.isfinite(y).sum())
    floor = noise_floor(n)
    ranked = sorted(cors.items(), key=lambda kv: -abs(kv[1]))[:top]
    out = []
    for name, r in ranked:
        if abs(r) < floor:
            continue
        p = R.P(name) if name in R else None
        out.append({
            "parameter": name,
            "prcc": round(float(r), 3),
            "direction": "increases" if r > 0 else "decreases",
            "pclass": p.pclass if p else "inferred",
            "support": p.support if p else "assumed",
            "rationale": (p.rationale[:180] if p else
                          "Personal state variable sampled from its posterior."),
            "noise_floor": round(floor, 3),
            "n_samples": n,
        })
    return out


def sensitivity_report(params: Dict[str, np.ndarray],
                       outputs: Dict[str, np.ndarray],
                       top: int = 6) -> Dict[str, Any]:
    return {k: rank_drivers(params, v, top) for k, v in outputs.items()}
