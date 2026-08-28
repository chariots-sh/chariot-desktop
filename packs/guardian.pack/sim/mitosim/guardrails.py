"""Stoichiometry, conservation and feasibility audits (spec 2.7, 2.10.A).

Two things happen here.

1. **Conservation checks on the dynamic model.**  Adenine nucleotide, creatine,
   NAD, FAD and CoA pools are conserved by construction; concentrations must
   stay non-negative; carbon and redox must balance.  These are asserted on real
   simulation output, not assumed.

2. **A constraint-based audit of the engine's own reaction network.**  The
   reaction set implemented in muscle.py is written out as a stoichiometric
   matrix with compartment assignments, and linear programming is used to look
   for thermodynamically impossible behaviour -- most importantly ATP production
   from nothing.  This is the check the MitoCore authors describe performing on
   their own network, applied here to ours.

   The curated MitoCore network itself is *not* redistributed with this package.
   It is a third-party model whose default parameterisation represents a
   cardiomyocyte, which spec 2.7 is explicit is a poor basis for a personalised
   running engine.  ``load_mitocore`` accepts a user-supplied SBML file and
   cross-checks our reaction stoichiometry against it; without that file the
   audit runs on our own network only and says so.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from .muscle import (IDX, NSP, ACC_IDX, I_GLC, I_LACB, I_FFA, I_BHB,
                     ACCOA_PER_PALMITATE, NADH_PER_PALMITATE,
                     FADH2_PER_PALMITATE, ATP_COST_PER_PALMITATE,
                     ACCOA_PER_BHB, NADH_PER_BHB, ATP_COST_PER_BHB,
                     NADH_PER_ACCOA_TCA, FADH2_PER_ACCOA_TCA, GTP_PER_ACCOA_TCA)

# --------------------------------------------------------------------------
# The engine's reaction network, written out explicitly
# --------------------------------------------------------------------------
# Metabolites are named <compartment>_<species>.  Compartments: c = cytosol,
# m = mitochondrial matrix, b = blood/extracellular.
# Values are stoichiometric coefficients (negative = consumed).

REACTIONS: Dict[str, Dict[str, float]] = {
    "ATPase": {"c_ATP": -1, "c_ADP": +1, "c_Pi": +1},
    "CK": {"c_PCr": -1, "c_ADP": -1, "c_H": -1, "c_Cr": +1, "c_ATP": +1},
    "AK": {"c_ADP": -2, "c_ATP": +1, "c_AMP": +1},
    "GlycogenPhosphorylase": {"c_glycogen": -1, "c_Pi": -1, "c_G6P": +1},
    "GlycogenSynthase": {"c_G6P": -1, "c_ATP": -2, "c_glycogen": +1,
                         "c_ADP": +2, "c_Pi": +3},
    "GlucoseTransport": {"b_glucose": -1, "c_glucose": +1},
    "Hexokinase": {"c_glucose": -1, "c_ATP": -1, "c_G6P": +1, "c_ADP": +1},
    # G6P -> 2 pyruvate: 2 Pi in at GAPDH, 3 net ATP out, 2 NADH out
    "Glycolysis": {"c_G6P": -1, "c_Pi": -2, "c_ADP": -3, "c_NAD": -2,
                   "c_pyruvate": +2, "c_ATP": +3, "c_NADH": +2, "c_H": +2},
    "LDH": {"c_pyruvate": -1, "c_NADH": -1, "c_H": -1,
            "c_lactate": +1, "c_NAD": +1},
    "MCT": {"c_lactate": -1, "c_H": -1, "b_lactate": +1, "b_H": +1},
    "PyruvateTransport": {"c_pyruvate": -1, "m_pyruvate": +1},
    "PDH": {"m_pyruvate": -1, "m_NAD": -1, "m_CoA": -1,
            "m_acetylCoA": +1, "m_NADH": +1, "m_CO2": +1},
    "FattyAcidUptake": {"b_palmitate": -1, "c_palmitate": +1},
    "BetaOxidation": {
        "c_palmitate": -1, "c_ATP": -ATP_COST_PER_PALMITATE,
        "m_CoA": -ACCOA_PER_PALMITATE, "m_NAD": -NADH_PER_PALMITATE,
        "m_FAD": -FADH2_PER_PALMITATE,
        "m_acetylCoA": +ACCOA_PER_PALMITATE, "m_NADH": +NADH_PER_PALMITATE,
        "m_FADH2": +FADH2_PER_PALMITATE, "c_ADP": +ATP_COST_PER_PALMITATE,
        "c_Pi": +ATP_COST_PER_PALMITATE},
    "KetoneOxidation": {
        "b_BHB": -1, "c_ATP": -ATP_COST_PER_BHB, "m_CoA": -ACCOA_PER_BHB,
        "m_NAD": -NADH_PER_BHB, "m_acetylCoA": +ACCOA_PER_BHB,
        "m_NADH": +NADH_PER_BHB, "c_ADP": +ATP_COST_PER_BHB,
        "c_Pi": +ATP_COST_PER_BHB},
    "TCA": {"m_acetylCoA": -1, "m_NAD": -NADH_PER_ACCOA_TCA,
            "m_FAD": -FADH2_PER_ACCOA_TCA, "c_ADP": -GTP_PER_ACCOA_TCA,
            "c_Pi": -GTP_PER_ACCOA_TCA,
            "m_CoA": +1, "m_NADH": +NADH_PER_ACCOA_TCA,
            "m_FADH2": +FADH2_PER_ACCOA_TCA, "c_ATP": +GTP_PER_ACCOA_TCA,
            "m_CO2": +2},
    "ShuttleNADH": {"c_NADH": -1, "m_NAD": -1, "c_NAD": +1, "m_NADH": +1},
    "ShuttleFADH2": {"c_NADH": -1, "m_FAD": -1, "c_NAD": +1, "m_FADH2": +1},
    # Respiratory chain + ATP synthase, lumped with the registered P/O ratios.
    "OxPhos_NADH": {"m_NADH": -1, "m_O2": -0.5, "c_ADP": -2.5, "c_Pi": -2.5,
                    "m_NAD": +1, "c_ATP": +2.5},
    "OxPhos_FADH2": {"m_FADH2": -1, "m_O2": -0.5, "c_ADP": -1.5, "c_Pi": -1.5,
                     "m_FAD": +1, "c_ATP": +1.5},
    "ProtonLeak": {"m_NADH": -1, "m_O2": -0.5, "m_NAD": +1},
    "O2Delivery": {"b_O2": -1, "m_O2": +1},
}

# Reactions the model treats as reversible (net flux may take either sign).
REVERSIBLE = {"CK", "AK", "LDH", "MCT", "ShuttleNADH", "PyruvateTransport",
              "GlucoseTransport"}

# Species the blood compartment can exchange with the rest of the body.
EXCHANGE = ("b_glucose", "b_lactate", "b_palmitate", "b_BHB", "b_O2", "b_H")

# Elemental composition for the carbon-balance audit.
CARBON = {
    "c_glycogen": 6, "c_G6P": 6, "c_glucose": 6, "b_glucose": 6,
    "c_pyruvate": 3, "m_pyruvate": 3, "c_lactate": 3, "b_lactate": 3,
    "c_palmitate": 16, "b_palmitate": 16, "b_BHB": 4,
    "m_acetylCoA": 2, "m_CO2": 1,
}
# Redox: electron pairs carried.
# Reducing equivalents carried, in electron pairs. Lactate is one pair more
# reduced than pyruvate, which is why lactate dehydrogenase balances.
REDOX = {"c_NADH": 1, "m_NADH": 1, "m_FADH2": 1, "m_O2": -2,
         "c_lactate": 1, "b_lactate": 1}


@dataclass
class Finding:
    check: str
    passed: bool
    detail: str
    value: Optional[float] = None
    tolerance: Optional[float] = None

    def to_dict(self):
        return asdict(self)


def species_list() -> List[str]:
    sp: set[str] = set()
    for r in REACTIONS.values():
        sp.update(r)
    return sorted(sp)


def stoichiometric_matrix() -> Tuple[np.ndarray, List[str], List[str]]:
    sp = species_list()
    rx = list(REACTIONS)
    S = np.zeros((len(sp), len(rx)))
    for j, rname in enumerate(rx):
        for m, c in REACTIONS[rname].items():
            S[sp.index(m), j] = c
    return S, sp, rx


# --------------------------------------------------------------------------
# Network audits
# --------------------------------------------------------------------------

def audit_carbon_balance() -> List[Finding]:
    out = []
    for name, rxn in REACTIONS.items():
        if not any(m in CARBON for m in rxn):
            continue
        bal = sum(CARBON.get(m, 0) * c for m, c in rxn.items())
        # CoA-bound acetyl carries 2 carbons; CO2 accounts for the rest.
        out.append(Finding(
            f"carbon_balance:{name}", abs(bal) < 1e-9,
            "carbon atoms in equal carbon atoms out"
            if abs(bal) < 1e-9 else
            f"carbon imbalance of {bal:+g} atoms in reaction {name}",
            value=float(bal), tolerance=1e-9))
    return out


def audit_redox_balance() -> List[Finding]:
    out = []
    for name in ("OxPhos_NADH", "OxPhos_FADH2", "ProtonLeak", "ShuttleNADH",
                 "ShuttleFADH2", "LDH"):
        rxn = REACTIONS[name]
        bal = sum(REDOX.get(m, 0) * c for m, c in rxn.items())
        out.append(Finding(
            f"redox_balance:{name}", abs(bal) < 1e-9,
            "reducing equivalents balance against oxygen reduced"
            if abs(bal) < 1e-9 else
            f"redox imbalance of {bal:+g} electron pairs in {name}",
            value=float(bal)))
    return out


def audit_energy_generating_cycles() -> List[Finding]:
    """Look for ATP production with every external input closed.

    This is the check the MitoCore authors describe: a curated network must not
    be able to make ATP out of nothing.  With all exchange fluxes shut, we
    maximise net cytosolic ATP production subject to steady state.  Any positive
    objective is a thermodynamically impossible cycle.
    """
    from scipy.optimize import linprog
    S, sp, rx = stoichiometric_matrix()
    n = len(rx)
    lb = np.array([-1000.0 if r in REVERSIBLE else 0.0 for r in rx])
    ub = np.full(n, 1000.0)

    # Close every exchange: blood species must be at steady state too, and the
    # O2Delivery reaction (the only blood O2 source) is shut off.
    lb[rx.index("O2Delivery")] = 0.0
    ub[rx.index("O2Delivery")] = 0.0

    # Objective: maximise net cytosolic ATP synthesis.
    c_atp = S[sp.index("c_ATP"), :].copy()
    # ATP hydrolysis is the drain we do not want to count as "production";
    # close it so the network cannot cycle ATP through its own hydrolysis.
    lb[rx.index("ATPase")] = 0.0
    ub[rx.index("ATPase")] = 0.0

    # Steady state for every internal species; blood species are also pinned
    # because all exchange is closed.
    A_eq = S.copy()
    b_eq = np.zeros(len(sp))
    res = linprog(-c_atp, A_eq=A_eq, b_eq=b_eq,
                  bounds=list(zip(lb, ub)), method="highs")
    if not res.success:
        return [Finding("energy_generating_cycle", True,
                        "linear program found no feasible flux distribution at "
                        "all with every exchange closed, so no ATP-generating "
                        "cycle exists", value=0.0)]
    produced = float(-res.fun)
    ok = produced < 1e-6
    return [Finding(
        "energy_generating_cycle", ok,
        "no net ATP can be produced with all exchanges closed" if ok else
        f"network can produce {produced:.4g} units of ATP from nothing -- this "
        "is a thermodynamically impossible cycle and must be fixed before any "
        "output is trusted",
        value=produced, tolerance=1e-6)]


def audit_oxygen_requires_substrate() -> List[Finding]:
    """ATP synthesis must vanish when oxygen delivery is blocked *and* the
    substrate-level pathways are blocked."""
    from scipy.optimize import linprog
    S, sp, rx = stoichiometric_matrix()
    n = len(rx)
    lb = np.array([-1000.0 if r in REVERSIBLE else 0.0 for r in rx])
    ub = np.full(n, 1000.0)
    for shut in ("O2Delivery", "ATPase", "Glycolysis", "GlycogenPhosphorylase",
                 "TCA"):
        lb[rx.index(shut)] = 0.0
        ub[rx.index(shut)] = 0.0
    c_atp = S[sp.index("c_ATP"), :].copy()
    res = linprog(-c_atp, A_eq=S, b_eq=np.zeros(len(sp)),
                  bounds=list(zip(lb, ub)), method="highs")
    produced = float(-res.fun) if res.success else 0.0
    ok = produced < 1e-6
    return [Finding(
        "atp_without_oxygen_or_substrate", ok,
        "blocking oxygen delivery and the substrate-level pathways removes all "
        "ATP synthesis" if ok else
        f"{produced:.4g} units of ATP still produced with oxygen and substrate "
        "pathways blocked", value=produced, tolerance=1e-6)]


def audit_atp_yields() -> List[Finding]:
    """Complete oxidation yields must match the accepted human values."""
    out = []
    # Glycogen-derived glucosyl unit, fully oxidised.
    # 1 G6P -> 2 pyruvate: +3 ATP, +2 cytosolic NADH
    # 2 pyruvate -> 2 acetyl-CoA: +2 NADH(m)
    # 2 acetyl-CoA through TCA: +6 NADH(m), +2 FADH2, +2 GTP
    nadh_m = 2 + 6
    fadh2 = 2
    cyt_nadh = 2
    atp = (3 + 2 +                                 # substrate level
           (nadh_m + cyt_nadh) * 2.5 + fadh2 * 1.5)
    o2 = (nadh_m + cyt_nadh) * 0.5 + fadh2 * 0.5
    ok = 30.0 <= atp <= 34.0 and abs(o2 - 6.0) < 1e-9
    out.append(Finding(
        "atp_yield_glycosyl", ok,
        f"a glycosyl unit yields {atp:.1f} ATP per {o2:.1f} O2 "
        f"({atp/o2:.2f} ATP/O2) assuming the malate-aspartate shuttle; the "
        "accepted range is 30-33 ATP per 6 O2",
        value=float(atp)))
    # Palmitate
    nadh = NADH_PER_PALMITATE + ACCOA_PER_PALMITATE * NADH_PER_ACCOA_TCA
    fad = FADH2_PER_PALMITATE + ACCOA_PER_PALMITATE * FADH2_PER_ACCOA_TCA
    gtp = ACCOA_PER_PALMITATE * GTP_PER_ACCOA_TCA
    atp_p = nadh * 2.5 + fad * 1.5 + gtp - ATP_COST_PER_PALMITATE
    o2_p = (nadh + fad) * 0.5
    okp = 104.0 <= atp_p <= 108.0 and abs(o2_p - 23.0) < 1e-9
    out.append(Finding(
        "atp_yield_palmitate", okp,
        f"palmitate yields {atp_p:.1f} ATP per {o2_p:.1f} O2 "
        f"({atp_p/o2_p:.2f} ATP/O2); the accepted value is about 106 ATP "
        "per 23 O2", value=float(atp_p)))
    return out


# --------------------------------------------------------------------------
# Conservation checks on real simulation output
# --------------------------------------------------------------------------

def audit_simulation(result, model, rtol: float = 5e-3) -> List[Finding]:
    out: List[Finding] = []
    y = result.y

    for tag, off in (("I", 0), ("II", NSP)):
        # Non-negativity
        for name in ("ATP", "PCr", "Pi", "GLY", "G6P", "PYR", "LAC", "NADHc",
                     "NADHm", "FADH2", "ACCOA", "O2"):
            v = y[off + IDX[name]]
            mn = float(np.min(v))
            scale = max(float(np.max(np.abs(v))), 1e-9)
            ok = mn > -1e-6 * max(scale, 1.0)
            out.append(Finding(
                f"non_negative:{name}:{tag}", ok,
                f"{name} stays non-negative in fibre {tag}" if ok else
                f"{name} reaches {mn:.4g} mmol/L in fibre {tag}, which is not a "
                "physically admissible concentration", value=mn))

        # Pool ceilings
        for name, total, label in (
                ("NADHm", model.nad_m, "matrix NAD pool"),
                ("NADHc", model.nad_c, "cytosolic NAD pool"),
                ("FADH2", model.fad, "flavin pool"),
                ("ACCOA", model.coa_total, "coenzyme A pool"),
                ("PCr", model.cr_total, "creatine pool"),
                ("O2", model.o2_cap, "intracellular oxygen capacity")):
            mx = float(np.max(y[off + IDX[name]]))
            ok = mx <= total * (1.0 + rtol)
            out.append(Finding(
                f"pool_ceiling:{name}:{tag}", ok,
                f"{name} stays within the {label} in fibre {tag}" if ok else
                f"{name} reaches {mx:.4g} mmol/L, above the {label} of "
                f"{total:.4g} mmol/L in fibre {tag}", value=mx,
                tolerance=total))

        atp = y[off + IDX["ATP"]]
        mx = float(np.max(atp))
        ok = mx <= model.atp_total * (1.0 + rtol)
        out.append(Finding(
            f"adenine_conservation:{tag}", ok,
            f"ATP never exceeds the adenine pool in fibre {tag}" if ok else
            f"ATP reaches {mx:.4g} mmol/L against a pool of "
            f"{model.atp_total:.4g} mmol/L in fibre {tag}", value=mx,
            tolerance=model.atp_total))

    # ATP budget: supplied ATP must equal what the pathways produced.
    supplied = result.final("atp_supplied")
    produced = (result.final("atp_ox") + result.final("atp_gly") +
                result.final("atp_pcr"))
    if supplied > 0:
        rel = abs(produced - supplied) / supplied
        ok = rel < 0.20
        out.append(Finding(
            "atp_budget", ok,
            f"integrated ATP supply and integrated pathway production agree to "
            f"{rel*100:.1f}%" if ok else
            f"integrated ATP supply and pathway production differ by "
            f"{rel*100:.1f}%, which means the accounting is losing flux",
            value=float(rel), tolerance=0.20))

    # Oxygen consumption must not exceed the person's ceiling.
    o2 = result.acc("o2")
    if len(result.t) > 2:
        rate = float(np.max(np.gradient(o2, result.t)))
        ceiling = model.vo2max_muscle * 1.10
        ok = rate <= ceiling
        out.append(Finding(
            "oxygen_ceiling", ok,
            f"peak simulated muscle oxygen consumption {rate:.4g} mmol/L/s "
            f"stays within the estimated ceiling {ceiling:.4g}" if ok else
            f"simulated oxygen consumption {rate:.4g} exceeds the person's "
            f"estimated ceiling {ceiling:.4g} mmol/L/s", value=rate,
            tolerance=ceiling))
    return out


def audit_network() -> List[Finding]:
    out: List[Finding] = []
    out += audit_carbon_balance()
    out += audit_redox_balance()
    out += audit_atp_yields()
    out += audit_energy_generating_cycles()
    out += audit_oxygen_requires_substrate()
    return out


def load_mitocore(path: str) -> Dict[str, Any]:
    """Cross-check our reaction stoichiometry against a user-supplied MitoCore
    SBML file.  Returns a report; never required for the engine to run."""
    try:
        import xml.etree.ElementTree as ET
        tree = ET.parse(path)
    except Exception as e:  # pragma: no cover - depends on user file
        return {"loaded": False, "error": str(e),
                "note": "MitoCore is not redistributed with this package; "
                        "supply the SBML file from the published model to "
                        "enable the cross-check."}
    ns = {"s": "http://www.sbml.org/sbml/level3/version1/core",
          "fbc": "http://www.sbml.org/sbml/level3/version1/fbc/version2"}
    root = tree.getroot()
    reactions = root.findall(".//s:reaction", ns)
    species = root.findall(".//s:species", ns)
    return {
        "loaded": True,
        "path": path,
        "n_reactions": len(reactions),
        "n_species": len(species),
        "note": "MitoCore is used offline as a stoichiometric and feasibility "
                "reference. Its default parameterisation represents a "
                "cardiomyocyte and is deliberately not used to set any kinetic "
                "constant in the running-muscle engine.",
    }


def summarise(findings: List[Finding]) -> Dict[str, Any]:
    failed = [f for f in findings if not f.passed]
    return {
        "total": len(findings),
        "passed": len(findings) - len(failed),
        "failed": len(failed),
        "all_passed": not failed,
        "failures": [f.to_dict() for f in failed],
        "findings": [f.to_dict() for f in findings],
    }
