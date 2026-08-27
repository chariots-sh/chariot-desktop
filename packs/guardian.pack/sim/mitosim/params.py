"""The engine's parameter set, every entry registered with unit + source.

Concentration convention
------------------------
Intracellular species are in **mM referred to litres of cell water**.
Muscle is taken as 0.70 L cell water per kg wet weight, so a literature value in
mmol/kg wet weight is divided by 0.70 to enter the model.  Glycogen is reported
back to the user in mmol glucosyl units/kg wet weight because that is how the
biopsy literature reports it (glycogen_methods).

Flux convention
---------------
All fluxes are mmol/L cell water/s (written mM/s).

Honesty note
------------
Many kinetic constants below are *population* parameters with wide priors.  They
are not fitted to the user -- spec 2.8 states that would be unidentifiable from
wearable data.  The engine samples them and reports how much they matter.
"""

from __future__ import annotations

from .provenance import (Registry, Param, Equation, fixed, normal, lognormal,
                         uniform)

REGISTRY_VERSION = "0.2.0"
R = Registry(REGISTRY_VERSION)
_ = R.add

# ==========================================================================
# 0. Tissue geometry and conversions
# ==========================================================================
_(Param("cell_water_L_per_kg", 0.70, "L/kg", "structural", "glycogen_methods",
        "Intracellular water per kg wet muscle; used to convert biopsy units "
        "(mmol/kg ww) into model concentrations (mM cell water).",
        support="indirect", dist=normal(0.70, 0.02, 0.62, 0.78)))

_(Param("active_muscle_frac_of_lean", 0.24, "fraction", "inferred",
        "model_structure",
        "Fraction of lean mass acting as the running prime movers (quadriceps, "
        "hamstrings, glutes, triceps surae). Spec 2.3 requires this scaling to "
        "stay uncertain and visible in sensitivity analysis.",
        support="assumed", dist=normal(0.24, 0.045, 0.14, 0.36),
        tags=("sensitivity_key",)))

_(Param("nonmuscle_o2_frac", 0.17, "fraction", "population", "indirect_cal_review",
        "Share of exercise oxygen uptake attributable to cardiac, respiratory "
        "and other non-locomotor tissue; removed before mapping whole-body cost "
        "to the modelled muscle.",
        support="indirect", dist=normal(0.17, 0.04, 0.08, 0.28)))

_(Param("type1_fraction", 0.60, "fraction", "inferred", "fibertype_runners",
        "Prior centre for type I fraction of the running-muscle phenotype. The "
        "cited marathon group was ~62% type I but n is small; spec 2.2 requires "
        "a wide distribution because fibre type is not observable from consumer "
        "data.",
        support="adjacent", dist=normal(0.60, 0.10, 0.30, 0.85),
        tags=("sensitivity_key",)))

# ==========================================================================
# 1. Running demand model (spec 2.3)
# ==========================================================================
# Minetti et al. 2002 running cost polynomial, C(i) in J/kg/m for gradient i.
for nm, val, why in [
    ("minetti_c5", 155.4, "5th-order coefficient"),
    ("minetti_c4", -30.4, "4th-order coefficient"),
    ("minetti_c3", -43.3, "3rd-order coefficient"),
    ("minetti_c2", 46.3, "2nd-order coefficient"),
    ("minetti_c1", 19.5, "1st-order coefficient"),
    ("minetti_c0", 3.6, "level-running intercept, J/kg/m"),
]:
    _(Param(nm, val, "J/kg/m", "population", "minetti2002",
            f"Minetti running energy-cost polynomial, {why}. Valid for "
            "gradients -0.45..+0.45; outside that range the engine refuses.",
            support="direct", domain="gradient in [-0.45, 0.45]"))

_(Param("minetti_grade_min", -0.45, "fraction", "population", "minetti2002",
        "Lower gradient bound of the measured polynomial.", support="direct"))
_(Param("minetti_grade_max", 0.45, "fraction", "population", "minetti2002",
        "Upper gradient bound of the measured polynomial.", support="direct"))

_(Param("economy_factor", 1.06, "ratio", "inferred", "minetti2002",
        "Personal multiplier on the Minetti cost-of-running curve. The Minetti "
        "sample were mountain runners with a level cost near 3.4-3.6 J/kg/m, "
        "which is more economical than a general runner population (the ACSM "
        "walking/running equation implies about 4.1 J/kg/m). The prior is "
        "therefore centred slightly above 1.0 and shifted by training level in "
        "the state estimator; calibration runs narrow it.",
        support="direct", dist=lognormal(1.06, 1.10, 0.80, 1.42),
        tags=("sensitivity_key",)))

_(Param("resting_metabolic_rate", 1.25, "W/kg", "population", "indirect_cal_review",
        "Resting metabolic power per kg body mass (~1 MET). Subtracted so the "
        "muscle sees the exercise increment.",
        support="indirect", dist=normal(1.25, 0.12, 0.9, 1.7)))

_(Param("energy_per_mL_O2", 20.4, "J/mL", "population", "indirect_cal_review",
        "Caloric equivalent of oxygen at a mixed respiratory quotient (~0.90). "
        "Ranges 19.6 (fat) to 21.1 (carbohydrate) J/mL; sampled because the "
        "actual RQ is a model output, not an input.",
        support="direct", dist=uniform(19.7, 21.0)))

_(Param("o2_molar_volume", 22.414, "mL/mmol", "population", "textbook_bioenergetics",
        "Molar volume of oxygen at STPD; converts a volumetric oxygen cost into "
        "moles before ATP stoichiometry is applied.",
        support="direct"))

_(Param("atp_per_o2", 5.00, "mol/mol", "population", "textbook_bioenergetics",
        "Total ATP produced per O2 consumed, used to convert a whole-body oxygen "
        "cost into a muscle ATP demand set-point. This must be the same number "
        "the muscle model actually achieves, otherwise the demand model asks "
        "for more ATP than the person's oxygen ceiling can supply and every "
        "simulation invents a glycolytic contribution to make up the "
        "difference. Complete oxidation of a glycosyl unit yields about 33 ATP "
        "per 6 O2 before uncoupling and about 30 after it, so roughly 5.0; "
        "fatty acid is nearer 4.6. Substrate-level ATP from glycolysis and from "
        "the TCA cycle is included.", support="direct", dist=uniform(4.6, 5.4)))

_(Param("running_econ_grade_penalty", 1.0, "ratio", "population", "minetti2002",
        "Multiplier applied to graded cost to allow person-specific deviation "
        "from the population grade response.",
        support="adjacent", dist=normal(1.0, 0.07, 0.8, 1.25)))

R.add_equation(Equation(
    name="cost_of_running",
    expression="C(i) = c5*i^5 + c4*i^4 + c3*i^3 + c2*i^2 + c1*i + c0",
    produces="J/kg/m",
    factors=(("minetti_c0", 1),),
    source="minetti2002",
    rationale="Population prior for the metabolic cost of transport in running "
              "as a function of gradient.",
    support="direct"))

R.add_equation(Equation(
    name="metabolic_power",
    expression="P = C(i) * v * economy_factor + RMR",
    produces="W/kg",
    factors=(("minetti_c0", 1), ("m/s", 1), ("economy_factor", 1)),
    source="minetti2002",
    rationale="Cost of transport times speed gives mass-specific metabolic "
              "power; the personal economy factor scales the population curve.",
    support="direct"))

R.add_equation(Equation(
    name="muscle_atp_demand",
    expression="D_atp = (P_total - P_rest) * (1-nonmuscle_o2_frac) / "
               "energy_per_mL_O2 * atp_per_o2 / V_cellwater",
    produces="mmol/L/s",
    factors=(("W", 1), ("energy_per_mL_O2", -1), ("o2_molar_volume", -1),
             ("atp_per_o2", 1), ("L", -1)),
    source="model_structure",
    rationale="Maps whole-body exercise metabolic power onto an ATP hydrolysis "
              "set-point inside the modelled muscle volume. Spec 2.3: 'A pace is "
              "not a biochemical reaction rate.'",
    support="assumed",
    modified_from_source="Replaces the generic exercise activation of li2012 "
                         "with an externally computed running demand series "
                         "(spec 2.6 requirement 2)."))

# ==========================================================================
# 2. Oxygen delivery (spec 2.5)
# ==========================================================================
_(Param("vo2max_device_bias", 1.0, "ratio", "inferred", "apple_cardio",
        "Multiplicative bias of a wrist cardio-fitness estimate relative to "
        "measured VO2max. Apple documents this as an estimate from heart and "
        "motion sensors, not respiratory gas analysis.",
        support="indirect", dist=lognormal(1.0, 1.11, 0.72, 1.35),
        tags=("sensitivity_key",)))

_(Param("vo2max_prior_ml_kg_min", 45.0, "mL/kg/min", "inferred", "lambe2026",
        "Fallback aerobic-capacity prior when no device estimate exists; wide "
        "because the wearable literature shows weak agreement for derived "
        "fitness metrics.",
        support="indirect", dist=normal(45.0, 9.0, 20.0, 80.0)))

_(Param("hb_reference_g_dL", 14.5, "g/dL", "population", "ekblom1975",
        "Reference haemoglobin. Arterial oxygen content is proportional to "
        "haemoglobin at a fixed saturation, so the modifier is applied as the "
        "ratio to this reference raised to hb_vo2max_exponent; the oxygen "
        "carried per gram of haemoglobin cancels out of the ratio and is not "
        "carried as a separate constant.", support="direct"))

_(Param("hb_vo2max_exponent", 0.75, "ratio", "population", "ekblom1975",
        "Exponent linking relative arterial O2 content to relative VO2max. "
        "Experimental CaO2 manipulation moves VO2max in the same direction, but "
        "ventilation, cardiac output, perfusion, diffusion and extraction also "
        "set the ceiling, so the mapping is sub-proportional and uncertain.",
        support="indirect", dist=normal(0.75, 0.20, 0.30, 1.10),
        tags=("sensitivity_key",)))

_(Param("altitude_vo2max_slope", 0.086, "1/km", "population", "ekblom1975",
        "Fractional VO2max decrement per km of elevation above the threshold, "
        "derived through the arterial-oxygen-content pathway. Sampled widely; "
        "individual altitude responses vary substantially.",
        support="indirect", dist=normal(0.086, 0.030, 0.03, 0.16)))

_(Param("altitude_threshold_m", 700.0, "m", "population", "ekblom1975",
        "Elevation below which the VO2max decrement is treated as negligible.",
        support="indirect", dist=uniform(400.0, 1000.0)))

_(Param("muscle_o2_capacity", 0.42, "mmol/L", "population", "textbook_bioenergetics",
        "Intracellular oxygen store (dissolved plus myoglobin-bound) at "
        "saturation; small, so oxygen supply is delivery-limited.",
        support="direct", dist=normal(0.42, 0.07, 0.25, 0.65)))

_(Param("perfusion_rest_frac", 0.05, "fraction", "population", "li2012",
        "Resting oxygen-delivery capability as a fraction of the maximum. "
        "Delivery is modelled as VO2max_muscle * g(t) * (1 - O2m/O2capacity): "
        "the back-pressure term means a well-oxygenated fibre draws little "
        "oxygen, and delivery approaches the ceiling only when intracellular "
        "oxygen has fallen. At rest this puts myoglobin near 85% saturation and "
        "at maximum it falls to single-digit percent, which is the measured "
        "behaviour of intracellular PO2 during heavy exercise.",
        support="adjacent", dist=normal(0.05, 0.015, 0.02, 0.11)))

_(Param("perfusion_tau_s", 22.0, "s", "population", "korzeniewski_eval",
        "Time constant of the blood-flow / oxygen-delivery response to a step "
        "change in workload; sets the oxygen-uptake kinetics.",
        support="direct", dist=normal(22.0, 6.0, 8.0, 45.0),
        tags=("sensitivity_key",)))

_(Param("km_o2_etc", 0.0007, "mmol/L", "population", "li2012",
        "Apparent Km of the electron transport chain for oxygen. Very low, so "
        "the limitation appears as delivery, not as terminal-oxidase affinity.",
        support="adjacent", dist=lognormal(0.0007, 1.6)))

# ==========================================================================
# 3. High-energy phosphate system
# ==========================================================================
_(Param("atp_total", 8.2, "mmol/L", "population", "textbook_bioenergetics",
        "Total adenine nucleotide (~5.7 mmol/kg ww). Held near-constant; the "
        "conservation checker asserts it.",
        support="direct", dist=normal(8.2, 0.5, 6.8, 9.6)))

_(Param("creatine_total", 42.0, "mmol/L", "population", "textbook_bioenergetics",
        "Total creatine pool (PCr + free Cr), ~29 mmol/kg ww.",
        support="direct", dist=normal(42.0, 4.0, 30.0, 55.0)))

_(Param("pi_rest", 3.0, "mmol/L", "population", "korzeniewski_eval",
        "Resting inorganic phosphate concentration.",
        support="direct", dist=normal(3.0, 0.5, 1.5, 5.0)))

_(Param("ck_keq_M", 1.66e9, "L/mol", "population", "textbook_bioenergetics",
        "Creatine kinase equilibrium constant "
        "K = [ATP][Cr]/([ADP][PCr][H+]); at pH 7.0 the apparent constant is "
        "~166, which fixes resting free ADP near 15-20 umol/L.",
        support="direct"))

_(Param("ck_rate", 300.0, "L/mmol/s", "population", "li2012",
        "Creatine-kinase mass-action rate constant. Large enough that the "
        "reaction stays near equilibrium, which is the physiological regime.",
        support="adjacent", dist=lognormal(300.0, 1.5)))

_(Param("ak_keq", 1.05, "ratio", "population", "textbook_bioenergetics",
        "Adenylate kinase equilibrium constant for 2ADP <-> ATP + AMP. AMP is "
        "computed from this fast equilibrium rather than integrated; it is the "
        "amplified low-energy signal that activates glycogenolysis and PFK.",
        support="direct"))

R.add_equation(Equation(
    name="creatine_kinase",
    expression="J_CK = k_ck * (PCr*ADP - Cr*ATP/Keq_app),  "
               "Keq_app = ck_keq_M * [H+]",
    produces="mmol/L/s",
    factors=(("ck_rate", 1), ("mmol/L", 2)),
    source="li2012",
    rationale="Near-equilibrium phosphocreatine buffering of cytosolic ATP; "
              "consumes a proton, which is why PCr breakdown is alkalinising.",
    support="direct"))

R.add_equation(Equation(
    name="adenylate_kinase_equilibrium",
    expression="AMP = ak_keq * ADP^2 / ATP",
    produces="mmol/L",
    factors=(("ak_keq", 1), ("mmol/L", 2), ("mmol/L", -1)),
    source="textbook_bioenergetics",
    rationale="Fast-equilibrium reduction: AMP is algebraic, not a state. "
              "Documented reduction of the source model.",
    support="direct",
    modified_from_source="li2012 integrates AMP; here it is a fast-equilibrium "
                         "algebraic variable (spec 2.6 requires the change be "
                         "recorded)."))

# ==========================================================================
# 4. Carbohydrate pathways
# ==========================================================================
_(Param("glycogen_rest_mmol_kg_ww", 100.0, "mmol/kg", "inferred", "glycogen_review",
        "Centre of the initial muscle-glycogen prior in glucosyl units per kg "
        "wet weight. Spec 2.4: this cannot be known from ordinary inputs, so it "
        "is estimated probabilistically and reported as low/moderate/high.",
        support="direct", dist=lognormal(100.0, 1.30, 25.0, 220.0),
        tags=("sensitivity_key",)))

_(Param("glycogen_floor_mmol_kg_ww", 12.0, "mmol/kg", "population", "glycogen_review",
        "Residual glycogen that is not mobilised even at exhaustion.",
        support="direct", dist=normal(12.0, 3.0, 4.0, 25.0)))

_(Param("vmax_phosphorylase_I", 0.55, "mmol/L/s", "population", "li2012",
        "Glycogen phosphorylase capacity in type I fibres.",
        support="adjacent", dist=lognormal(0.55, 1.35)))
_(Param("vmax_phosphorylase_II", 2.2, "mmol/L/s", "population", "li2012",
        "Glycogen phosphorylase capacity in type II fibres; higher glycogenolytic "
        "capacity is a defining property of the faster fibre population.",
        support="adjacent", dist=lognormal(2.2, 1.35)))

_(Param("km_pi_phosphorylase", 6.0, "mmol/L", "population", "li2012",
        "Phosphate Km of glycogen phosphorylase; couples glycogenolysis to the "
        "phosphate rise that accompanies PCr breakdown.",
        support="adjacent", dist=lognormal(6.0, 1.3)))

_(Param("km_amp_activation", 0.0020, "mmol/L", "population", "li2012",
        "Half-activation free AMP for glycogenolysis and phosphofructokinase. "
        "Because AMP scales with ADP squared, this produces the steep "
        "intensity dependence of glycolytic flux. The prior is deliberately "
        "not as wide as the raw spread of reported values: because glycolytic "
        "flux depends on roughly the fourth power of the energy state, a "
        "geometric spread of 70% on this constant generates ensemble members "
        "whose glycolysis fires at rest and who show threshold lactate at a "
        "modest fraction of their own aerobic ceiling. That is an incoherent "
        "person, not an honest uncertainty, and the sensitivity analysis still "
        "reports this constant as a leading driver.",
        support="adjacent", dist=lognormal(0.0020, 1.35),
        tags=("sensitivity_key",)))

_(Param("vmax_glycolysis_I", 1.2, "mmol/L/s", "population", "li2012",
        "Type I glycolytic capacity expressed as hexose-phosphate throughput.",
        support="adjacent", dist=lognormal(1.2, 1.35)))
_(Param("vmax_glycolysis_II", 4.0, "mmol/L/s", "population", "li2012",
        "Type II glycolytic capacity; supports the high non-oxidative ATP rates "
        "seen in severe-intensity exercise.",
        support="adjacent", dist=lognormal(4.0, 1.35)))

_(Param("km_g6p", 0.60, "mmol/L", "population", "li2012",
        "Hexose-phosphate Km of the lumped glycolytic segment.",
        support="adjacent", dist=lognormal(0.60, 1.3)))

_(Param("ki_atp_pfk", 9.5, "mmol/L", "population", "li2012",
        "ATP inhibition constant of phosphofructokinase.",
        support="adjacent", dist=lognormal(9.5, 1.2)))

_(Param("ph_pfk_half", 6.75, "pH", "population", "korzeniewski_eval",
        "pH at which glycolytic flux is half-inhibited; the acidosis brake.",
        support="direct", dist=normal(6.75, 0.10, 6.5, 7.0)))
_(Param("ph_pfk_slope", 0.18, "pH", "population", "korzeniewski_eval",
        "Steepness of the pH inhibition of glycolysis.",
        support="direct", dist=normal(0.18, 0.05, 0.08, 0.35)))

_(Param("vmax_glucose_uptake_I", 0.00050, "mmol/L/s", "population", "li2012",
        "Maximal sarcolemmal glucose transport in type I fibres (GLUT4). Scaled "
        "so that leg glucose uptake during moderate running lands near 1 g/min "
        "whole body rather than at the transporter's isolated capacity.",
        support="adjacent", dist=lognormal(0.00050, 1.4)))
_(Param("vmax_glucose_uptake_II", 0.00032, "mmol/L/s", "population", "li2012",
        "Maximal sarcolemmal glucose transport in type II fibres.",
        support="adjacent", dist=lognormal(0.00032, 1.4)))
_(Param("km_glucose_transport", 5.0, "mmol/L", "population", "li2012",
        "Km of GLUT4-mediated glucose transport.",
        support="adjacent", dist=lognormal(5.0, 1.25)))
_(Param("contraction_glut4_gain", 25.0, "ratio", "population", "li2012",
        "Fold increase in muscle glucose transport with contraction, "
        "independent of insulin. Contraction translocates GLUT4 and raises "
        "muscle glucose uptake by more than an order of magnitude above basal; "
        "the basal capacity is set so that resting uptake is a small fraction "
        "of whole-body glucose disposal and exercising uptake approaches "
        "1 g/min.", support="adjacent", dist=normal(25.0, 6.0, 10.0, 45.0)))

_(Param("vmax_pdh_I", 2.0, "mmol/L/s", "population", "li2012",
        "Pyruvate dehydrogenase capacity, type I.",
        support="adjacent", dist=lognormal(2.0, 1.35)))
_(Param("vmax_pdh_II", 1.524, "mmol/L/s", "population", "li2012",
        "Pyruvate dehydrogenase capacity, type II.",
        support="adjacent", dist=lognormal(1.524, 1.35)))
_(Param("km_pyruvate_pdh", 0.075, "mmol/L", "population", "li2012",
        "Pyruvate half-saturation of the pyruvate dehydrogenase complex. Low "
        "relative to exercising cytosolic pyruvate, so the complex is largely "
        "substrate-saturated during running and its flux is set by activation "
        "state and by product inhibition rather than by pyruvate supply.",
        support="adjacent", dist=lognormal(0.075, 1.4)))
_(Param("ldh_keq_app", 1.1e4, "ratio", "population", "textbook_bioenergetics",
        "Apparent lactate dehydrogenase equilibrium constant at pH 7.0, "
        "K = [lac][NAD]/([pyr][NADH]).", support="direct"))
_(Param("ldh_rate_I", 900.0, "L/mmol/s", "population", "li2012",
        "LDH mass-action rate constant, type I (H-isoform dominant).",
        support="adjacent", dist=lognormal(900.0, 1.5)))
_(Param("ldh_rate_II", 2600.0, "L/mmol/s", "population", "li2012",
        "LDH mass-action rate constant, type II (M-isoform dominant); the "
        "kinetic reason type II fibres export more lactate at a given pyruvate.",
        support="adjacent", dist=lognormal(2600.0, 1.5)))

_(Param("vmax_mct_I", 0.13, "mmol/L/s", "population", "li2012",
        "Monocarboxylate transport capacity, type I (MCT1-rich, and the fibre "
        "type that also takes lactate up and oxidises it). Sized against "
        "measured limb lactate exchange rates. An unrealistically high value "
        "here does not just move lactate around: it lets the slow fibres run "
        "almost entirely on lactate exported by the fast fibres, so their own "
        "glycogen is never touched and the intracellular lactate that drives "
        "acidosis never accumulates.",
        support="adjacent", dist=lognormal(0.13, 1.45)))
_(Param("vmax_mct_II", 0.16, "mmol/L/s", "population", "li2012",
        "Monocarboxylate transport capacity, type II (MCT4-rich, export "
        "biased).", support="adjacent", dist=lognormal(0.16, 1.45)))
_(Param("mct_uptake_fraction", 0.45, "fraction", "population", "li2012",
        "Lactate uptake capacity of a fibre relative to its export capacity at "
        "the same concentration difference. Monocarboxylate transport is a "
        "proton symport and the outward proton gradient biases it towards "
        "export; a symmetric transporter lets the slow fibres strip arterial "
        "lactate below its resting concentration during moderate running.",
        support="adjacent", dist=normal(0.45, 0.12, 0.15, 0.8)))
_(Param("km_mct", 8.0, "mmol/L", "population", "li2012",
        "Km of monocarboxylate transport.", support="adjacent",
        dist=lognormal(8.0, 1.3)))

# ==========================================================================
# 5. Lipid and ketone pathways
# ==========================================================================
_(Param("vmax_beta_ox_I", 0.22, "mmol/L/s", "population", "li2012",
        "Beta-oxidation capacity in palmitate equivalents, type I. Each "
        "palmitate yields 8 acetyl-CoA, 7 NADH and 7 FADH2 at a cost of 2 ATP "
        "equivalents for activation.",
        support="adjacent", dist=lognormal(0.22, 1.45),
        tags=("sensitivity_key",)))
_(Param("vmax_beta_ox_II", 0.1335, "mmol/L/s", "population", "li2012",
        "Beta-oxidation capacity in palmitate equivalents, type II.",
        support="adjacent", dist=lognormal(0.1335, 1.45)))
_(Param("km_ffa", 0.03, "mmol/L", "population", "li2012",
        "Half-saturating plasma fatty-acid concentration for muscle uptake and "
        "activation. Plasma fatty acids sit near 0.2-0.3 mmol/L a few hours "
        "after a meal, so a Km near the fasted concentration would make fat "
        "oxidation collapse in the fed state, which indirect calorimetry does "
        "not show.", support="adjacent", dist=lognormal(0.03, 1.4)))
_(Param("ki_g6p_beta_ox", 6.0, "mmol/L", "population", "venables2005",
        "Inhibition of fat oxidation by glycolytic flux, represented through "
        "hexose phosphate as a malonyl-CoA proxy. This is the mechanism behind "
        "the carbohydrate-fat crossover.",
        support="indirect", dist=lognormal(6.0, 1.6),
        tags=("sensitivity_key",)))
_(Param("fat_ox_personal_scale", 1.0, "ratio", "inferred", "venables2005",
        "Personal multiplier on maximal fat-oxidation capacity. Venables found "
        "large interindividual variation only partly explained by sex, activity "
        "and VO2max, so this stays wide rather than collapsing to the "
        "population mean.",
        support="direct", dist=lognormal(1.0, 1.35, 0.45, 2.4),
        tags=("sensitivity_key",)))

_(Param("vmax_ketone_ox_I", 0.020, "mmol/L/s", "population", "li2012",
        "Beta-hydroxybutyrate oxidation capacity, type I. Each BHB gives 1 NADH "
        "and 2 acetyl-CoA and costs one GTP equivalent at SCOT.",
        support="extrapolated", dist=lognormal(0.020, 1.7)))
_(Param("vmax_ketone_ox_II", 0.010, "mmol/L/s", "population", "li2012",
        "Beta-hydroxybutyrate oxidation capacity, type II.",
        support="extrapolated", dist=lognormal(0.010, 1.7)))
_(Param("km_ketone", 0.8, "mmol/L", "population", "li2012",
        "Km for ketone uptake and oxidation.",
        support="extrapolated", dist=lognormal(0.8, 1.5)))

# ==========================================================================
# 6. Mitochondrial oxidation
# ==========================================================================
_(Param("nad_total_cyt", 0.50, "mmol/L", "population", "li2012",
        "Free cytosolic NAD pool. Only the free fraction participates; most "
        "cellular NAD is enzyme-bound. Together with the shuttle equilibrium "
        "this sets the free NAD+/NADH ratio near 500, which is what fixes the "
        "lactate/pyruvate ratio.",
        support="adjacent", dist=normal(0.50, 0.08, 0.3, 0.8)))
_(Param("nad_total_mito", 3.0, "mmol/L", "population", "li2012",
        "Mitochondrial matrix NAD pool.", support="adjacent",
        dist=normal(3.0, 0.5, 1.8, 4.5)))
_(Param("nadh_mito_rest_ratio", 0.22, "ratio", "population", "li2012",
        "Resting NADH fraction of the mitochondrial NAD pool.",
        support="adjacent", dist=normal(0.22, 0.05, 0.08, 0.45)))

_(Param("vmax_oxphos_I", 1.35, "mmol/L/s", "population", "li2012",
        "Maximal NADH oxidation by the respiratory chain in type I fibres. "
        "Reflects the higher mitochondrial volume density of the slow "
        "oxidative population.",
        support="adjacent", dist=lognormal(1.35, 1.32),
        tags=("sensitivity_key",)))
_(Param("vmax_oxphos_II", 0.95, "mmol/L/s", "population", "li2012",
        "Maximal NADH oxidation by the respiratory chain in the lumped type II "
        "population. Version 1 combines the faster fibres into one population "
        "(spec 2.2), and in a trained runner that population is dominated by "
        "type IIa, whose mitochondrial volume density is roughly 70% of type I "
        "rather than the much lower density of type IIx. Using a IIx-like value "
        "makes the fast population resort to glycolysis at moderate running "
        "intensities, which is not what indirect calorimetry or muscle lactate "
        "measurements show. The type I / type II contrast in this engine is "
        "carried by glycolytic capacity, lactate dehydrogenase isoform, "
        "recruitment threshold and ATPase rate, not by crippling oxidative "
        "capacity.", support="adjacent", dist=lognormal(0.95, 1.32),
        tags=("sensitivity_key",)))
_(Param("mito_capacity_scale", 1.0, "ratio", "inferred", "model_structure",
        "Personal scaling of oxidative capacity, inferred jointly with VO2max "
        "so that muscle capacity and whole-body ceiling stay consistent. This "
        "is NOT a measurement of the person's mitochondria.",
        support="assumed", dist=lognormal(1.0, 1.18, 0.55, 1.9),
        tags=("sensitivity_key",)))

_(Param("km_adp_oxphos", 0.075, "mmol/L", "population", "korzeniewski_eval",
        "Half-activating free ADP for oxidative phosphorylation, used with the "
        "cooperative exponent hill_adp_oxphos. Reported values for the apparent "
        "ADP Km of muscle respiration span roughly 20-100 umol/L depending on "
        "preparation and on whether free or total ADP is meant; this value with "
        "the registered cooperativity reproduces the measured rest-to-maximum "
        "range of muscle oxygen consumption. The prior spread is kept moderate "
        "for the same reason as km_amp_activation: this constant sets how far "
        "the phosphorylation potential must fall to drive a given oxidative "
        "flux, and a very wide prior manufactures ensemble members who deplete "
        "phosphocreatine to threshold-level ADP at an easy pace.",
        support="adjacent", dist=lognormal(0.075, 1.22), tags=("sensitivity_key",)))
_(Param("km_pi_oxphos", 1.6, "mmol/L", "population", "korzeniewski_eval",
        "Phosphate Km of oxidative phosphorylation.",
        support="direct", dist=lognormal(1.6, 1.4)))
_(Param("km_nadh_oxphos", 0.35, "mmol/L", "population", "li2012",
        "NADH Km of the respiratory chain.", support="adjacent",
        dist=lognormal(0.35, 1.4)))

_(Param("po_ratio_nadh", 2.5, "mol/mol", "population", "textbook_bioenergetics",
        "ATP synthesised per NADH oxidised (P/O 2.5).", support="direct",
        dist=normal(2.5, 0.10, 2.2, 2.8)))
_(Param("po_ratio_fadh2", 1.5, "mol/mol", "population", "textbook_bioenergetics",
        "ATP synthesised per FADH2 oxidised (P/O 1.5).", support="direct",
        dist=normal(1.5, 0.08, 1.25, 1.75)))
_(Param("proton_leak_frac", 0.08, "fraction", "population", "li2012",
        "Fraction of respiratory flux not coupled to ATP synthesis. Present in "
        "the model because it changes ATP per oxygen, but the engine must NOT "
        "report it as a measured personal property (spec 3.4).",
        support="assumed", dist=normal(0.08, 0.035, 0.02, 0.20)))

_(Param("vmax_tca_I", 0.7225, "mmol/L/s", "population", "li2012",
        "Tricarboxylic-acid-cycle capacity, type I. Per acetyl-CoA: 3 NADH, "
        "1 FADH2, 1 GTP.", support="adjacent", dist=lognormal(0.7225, 1.35)))
_(Param("vmax_tca_II", 0.5737, "mmol/L/s", "population", "li2012",
        "Tricarboxylic-acid-cycle capacity, type II.",
        support="adjacent", dist=lognormal(0.5737, 1.35)))
_(Param("km_accoa_tca", 0.025, "mmol/L", "population", "li2012",
        "Acetyl-CoA Km of the TCA cycle.", support="adjacent",
        dist=lognormal(0.025, 1.4)))
_(Param("km_nad_tca", 0.9, "mmol/L", "population", "li2012",
        "NAD+ Km of the TCA cycle; redox state feeds back on carbon flux.",
        support="adjacent", dist=lognormal(0.9, 1.35)))

# The reducing-equivalent shuttle is written as a reversible mass-action
# process rather than a saturable one-way flux.  It is thermodynamically driven,
# and writing it one-way lets it pump the mitochondrial NAD pool into a
# non-physiological, almost fully reduced state at rest.  Reversibility also
# gives the correct coupling: cytosolic redox, and therefore the
# lactate/pyruvate ratio, is set by the mitochondrial redox state.
_(Param("k_shuttle_I", 40.0, "L/mmol/s", "population", "li2012",
        "Reducing-equivalent shuttle rate constant, type I (malate-aspartate "
        "dominant, NADH-conserving).",
        support="adjacent", dist=lognormal(40.0, 1.5)))
_(Param("k_shuttle_II", 25.0, "L/mmol/s", "population", "li2012",
        "Shuttle rate constant, type II (more glycerol-phosphate, entering at "
        "the FADH2 level and yielding less ATP).",
        support="adjacent", dist=lognormal(25.0, 1.5)))
_(Param("shuttle_keq", 220.0, "ratio", "population", "li2012",
        "Apparent equilibrium bias of the shuttle, K = ([NADH]c/[NAD]c) "
        "divided by ([NADH]m/[NAD]m) inverted -- the electrogenic "
        "aspartate-glutamate carrier lets the shuttle hold the cytosol far more "
        "oxidised than the matrix. A value near 60 reproduces the measured free "
        "cytosolic NAD/NADH ratio of roughly 400-1000 alongside a matrix NADH "
        "fraction near 0.2-0.3.", support="adjacent",
        dist=lognormal(220.0, 1.5), tags=("sensitivity_key",)))
_(Param("shuttle_fadh2_frac_I", 0.25, "fraction", "population", "li2012",
        "Share of shuttled reducing equivalents entering at the FADH2 level, "
        "type I.", support="adjacent", dist=normal(0.25, 0.08, 0.05, 0.5)))
_(Param("shuttle_fadh2_frac_II", 0.60, "fraction", "population", "li2012",
        "Share entering at the FADH2 level, type II.",
        support="adjacent", dist=normal(0.60, 0.12, 0.25, 0.9)))
_(Param("ph_rest", 7.05, "pH", "population", "korzeniewski_eval",
        "Resting intracellular pH of skeletal muscle.",
        support="direct", dist=normal(7.05, 0.04, 6.9, 7.2)))
_(Param("buffer_capacity", 55.0, "mmol/L", "population", "korzeniewski_eval",
        "Total in vivo proton buffering of muscle cell water in mmol/L per pH "
        "unit, including protein, carnosine, inorganic phosphate and "
        "bicarbonate. Non-bicarbonate buffering alone is nearer 30-40; using "
        "that figure for a whole-cell balance overstates the pH swing.",
        support="direct", dist=normal(55.0, 11.0, 32.0, 85.0),
        tags=("sensitivity_key",)))
_(Param("recruit_I_threshold", 0.10, "fraction", "population", "li2012",
        "Relative intensity at which half of the type I pool is active; slow "
        "fibres are recruited first.", support="adjacent",
        dist=normal(0.10, 0.04, 0.02, 0.25)))
_(Param("recruit_I_slope", 0.07, "fraction", "population", "li2012",
        "Steepness of type I recruitment.", support="adjacent",
        dist=normal(0.07, 0.02, 0.03, 0.15)))
_(Param("recruit_II_threshold", 0.58, "fraction", "inferred", "li2012",
        "Relative intensity at which half of the type II pool is active. Spec "
        "2.2: increasing intensity recruits more type II fibres. Calibration "
        "range is uncertain (spec 2.6 requirement 5).",
        support="adjacent", dist=normal(0.58, 0.09, 0.35, 0.85),
        tags=("sensitivity_key",)))
_(Param("recruit_II_slope", 0.13, "fraction", "inferred", "li2012",
        "Steepness of type II recruitment.", support="adjacent",
        dist=normal(0.13, 0.04, 0.05, 0.28)))
_(Param("type2_atpase_ratio", 1.25, "ratio", "population", "li2012",
        "ATP cost per unit volume of an active type II fibre relative to an "
        "active type I fibre; faster myosin isoforms have higher ATPase rates. "
        "During submaximal running the recruited fast fibres do not sustain "
        "their peak duty cycle, so the effective ratio in a steady-state run is "
        "lower than the isolated-fibre ATPase ratio.",
        support="adjacent", dist=normal(1.25, 0.16, 1.0, 1.7)))

# ==========================================================================
# 9. Circulating substrates
# ==========================================================================
_(Param("blood_glucose_fed", 5.6, "mmol/L", "population", "li2012",
        "Arterial glucose a few hours after a mixed meal.",
        support="direct", dist=normal(5.6, 0.6, 4.0, 8.5)))
_(Param("blood_glucose_fasted", 4.7, "mmol/L", "population", "li2012",
        "Arterial glucose after an overnight-plus fast.",
        support="direct", dist=normal(4.7, 0.5, 3.4, 6.5)))
_(Param("blood_ffa_fed", 0.22, "mmol/L", "population", "venables2005",
        "Plasma free fatty acids in the fed state.",
        support="direct", dist=lognormal(0.22, 1.5, 0.05, 0.9)))
_(Param("blood_ffa_fasted", 0.65, "mmol/L", "population", "venables2005",
        "Plasma free fatty acids after prolonged fasting.",
        support="direct", dist=lognormal(0.65, 1.4, 0.2, 1.8)))
_(Param("blood_bhb_fed", 0.08, "mmol/L", "population", "venables2005",
        "Circulating beta-hydroxybutyrate in the fed state.",
        support="indirect", dist=lognormal(0.08, 1.8, 0.02, 0.5)))
_(Param("blood_bhb_fasted", 0.45, "mmol/L", "population", "venables2005",
        "Circulating beta-hydroxybutyrate after prolonged fasting.",
        support="indirect", dist=lognormal(0.45, 2.0, 0.05, 3.0)))
_(Param("blood_lactate_rest", 0.9, "mmol/L", "population", "li2012",
        "Resting arterial lactate.", support="direct",
        dist=normal(0.9, 0.25, 0.4, 2.0)))
_(Param("blood_volume_frac", 0.30, "L/kg", "structural", "model_structure",
        "Effective distribution volume for exported lactate over the timescale "
        "of a single run, per kg of body mass: blood plus the extracellular "
        "and rapidly exchanging tissue space, not total body water. Using total "
        "body water buffers arterial lactate so heavily that the simulated "
        "curve is flat.", support="assumed", dist=normal(0.30, 0.05, 0.2, 0.45)))
_(Param("glucose_space_frac", 0.20, "L/kg", "structural", "model_structure",
        "Distribution volume for arterial glucose, per kg of body mass. Smaller "
        "than the lactate space, which is why the simulation can show arterial "
        "glucose falling during a long fasted run.",
        support="assumed", dist=normal(0.20, 0.03, 0.13, 0.30)))
_(Param("lactate_clearance", 0.00153, "1/s", "population", "li2012",
        "First-order clearance of arterial lactate to tissue outside the "
        "modelled muscle (liver, heart, kidney, inactive muscle). Calibrated "
        "against measured lactate rate-of-disappearance: roughly 1 mmol/min at "
        "a resting concentration near 1 mmol/L and a few mmol/min at exercising "
        "concentrations. A faster constant flattens the simulated lactate curve "
        "at every intensity.", support="indirect", dist=lognormal(0.00153, 1.6),
        tags=("sensitivity_key",)))
_(Param("glucose_appearance_max", 0.020, "mmol/L/s", "population", "li2012",
        "Maximum rate of exogenous glucose appearance into blood, expressed in "
        "muscle-model units; caps how fast pre-run carbohydrate can help.",
        support="indirect", dist=lognormal(0.020, 1.4)))
_(Param("insulin_glut4_gain_fed", 2.6, "ratio", "population", "li2012",
        "Insulin-driven fold increase in glucose transport shortly after a "
        "carbohydrate-containing meal.", support="adjacent",
        dist=normal(2.6, 0.7, 1.0, 4.5)))

R.add_equation(Equation(
    name="oxidative_phosphorylation",
    expression="J_ox = Vmax_ox * NADH/(Km+NADH) * ADP/(Km+ADP) * Pi/(Km+Pi) "
               "* O2/(Km+O2)",
    produces="mmol/L/s",
    factors=(("vmax_oxphos_I", 1),),
    source="li2012",
    rationale="Respiratory control: oxidative ATP synthesis rises with ADP and "
              "phosphate (the products of ATP hydrolysis) and falls when oxygen "
              "delivery cannot keep intracellular O2 above the chain's Km.",
    support="adjacent"))

R.add_equation(Equation(
    name="atp_from_oxphos",
    expression="J_ATP_ox = (1-leak) * (po_nadh*J_ox_NADH + po_fadh2*J_ox_FADH2)",
    produces="mmol/L/s",
    factors=(("po_ratio_nadh", 1), ("mmol/L/s", 1)),
    source="textbook_bioenergetics",
    rationale="P/O stoichiometry with an uncoupled fraction; also yields the "
              "ATP-per-oxygen output required by spec 3.2.",
    support="direct"))

R.add_equation(Equation(
    name="proton_balance",
    expression="d(pH)/dt = -(h_lac*(J_LDH - J_MCT) - h_CK*J_CK) "
               "/ buffer_capacity",
    produces="mmol/L/s",
    factors=(("proton_per_lactate", 1), ("mmol/L/s", 1)),
    source="korzeniewski_eval",
    rationale="Acid accumulates with lactate that is retained in the cytosol. "
              "Monocarboxylate transport is a proton symport, so exported "
              "lactate removes its own proton, and glycolytic flux whose "
              "pyruvate is fully oxidised produces no net acid. "
              "Phosphocreatine breakdown consumes a net proton per turnover "
              "once the simultaneous hydrolysis of the ATP it regenerates is "
              "counted, which is the measured alkalinisation at exercise "
              "onset.",
    support="direct",
    modified_from_source="An earlier formulation charged acid to "
                         "non-oxidatively regenerated ATP directly. That "
                         "acidified the fibre during moderate running in which "
                         "no lactate accumulates, so it was replaced."))

R.add_equation(Equation(
    name="fibre_recruitment",
    expression="a_f(x) = 1/(1+exp(-(x - threshold_f)/slope_f))",
    produces="fraction",
    factors=(("fraction", 1),),
    source="li2012",
    rationale="Orderly recruitment: type I first, type II progressively as "
              "relative intensity rises (spec 2.2).",
    support="adjacent",
    modified_from_source="li2012 uses a fixed exercise activation; here the "
                         "recruitment is driven by the running-demand series "
                         "(spec 2.6 requirements 2 and 5)."))

__all__ = ["R", "REGISTRY_VERSION"]

# ==========================================================================
# 10. Initial-state estimation (spec 2.4) -- appended section
# ==========================================================================
_(Param("resting_muscle_atp_demand", 0.0025, "mmol/L/s", "population", "li2012",
        "Resting ATP turnover of the modelled muscle, added underneath the "
        "exercise increment so the fibre is never at zero demand. Resting "
        "muscle consumes roughly 0.3-0.5 mL O2 per kg per minute, which at "
        "about 5 ATP per O2 is a turnover near 0.002-0.003 mmol/L cell water "
        "per second -- two and a half orders of magnitude below hard running.",
        support="adjacent", dist=lognormal(0.0025, 1.3)))

_(Param("glycogen_cho_response_gsd", 1.22, "ratio", "inferred", "glycogen_review",
        "Multiplier on the glycogen prior from previous-day carbohydrate "
        "intake in g/kg: anchored at 0.58 for ~0 g/kg, 1.00 near 5 g/kg and up "
        "to ~1.45 for a loading intake. Biopsy studies show large diet effects "
        "with considerable between-person variation, so the mapping is an "
        "anchor set with a wide residual, not a calibration curve. This entry "
        "is the residual spread of that mapping, combined in log space with the "
        "rest of the glycogen posterior.",
        support="direct", dist=lognormal(1.0, 1.22)))

_(Param("glycogen_exercise_depletion", 0.72, "ratio", "inferred", "glycogen_review",
        "Multiplier applied when hard exercise has occurred since the last "
        "high-carbohydrate meal. Magnitude varies by exercise mode and "
        "protocol.", support="direct", dist=normal(0.72, 0.12, 0.40, 0.98)))

_(Param("glycogen_trained_bonus", 1.12, "ratio", "inferred", "supercompensation",
        "Higher storage capacity in trained runners. The supercompensation "
        "literature differs between running and cycling protocols, so this is "
        "modest and uncertain.", support="adjacent",
        dist=normal(1.12, 0.09, 0.92, 1.40)))

_(Param("altitude_acclimatization", 0.40, "fraction", "inferred", "ekblom1975",
        "Share of the acute altitude VO2max decrement that is offset when the "
        "person habitually lives at that elevation.",
        support="indirect", dist=normal(0.40, 0.15, 0.0, 0.75)))

_(Param("insulin_ffa_suppression", 0.45, "fraction", "population", "venables2005",
        "Fractional suppression of circulating fatty acids at a high insulin "
        "index (recent carbohydrate).", support="indirect",
        dist=normal(0.45, 0.12, 0.15, 0.75)))

_(Param("hr_to_vo2_error", 1.0, "ratio", "inferred", "lambe2026",
        "Multiplicative error of the %heart-rate-reserve to %VO2-reserve "
        "mapping used to read oxygen cost off a calibration run. Heart rate is "
        "the strongest consumer signal, but the mapping itself is a population "
        "approximation.", support="indirect", dist=lognormal(1.0, 1.09)))

# ==========================================================================
# 11. Reductions specific to this implementation (spec 2.6 requirement 7)
# ==========================================================================
_(Param("fad_total_mito", 2.0, "mmol/L", "structural", "model_structure",
        "Lumped FAD/FADH2 pool. Flavin cofactors are enzyme-bound rather than a "
        "free pool, so this is a structural device that lets succinate- and "
        "beta-oxidation-derived reducing equivalents be conserved explicitly "
        "instead of being assumed instantaneously oxidised. Its size is not a "
        "measured quantity; sensitivity analysis reports how much it matters.",
        support="assumed", dist=lognormal(2.0, 1.5)))
_(Param("km_fadh2_oxphos", 0.15, "mmol/L", "structural", "model_structure",
        "Half-saturation of the lumped complex-II/ETF entry point.",
        support="assumed", dist=lognormal(0.15, 1.4)))
_(Param("vmax_oxphos_fadh2_frac", 0.75, "fraction", "structural", "model_structure",
        "Capacity of the FADH2 entry point relative to the NADH entry point.",
        support="assumed", dist=normal(0.75, 0.12, 0.25, 0.85)))

_(Param("capillarity_I", 1.15, "ratio", "population", "li2012",
        "Relative capillary supply of type I fibres; slow oxidative fibres are "
        "more densely capillarised, so they receive a larger share of oxygen "
        "delivery per unit volume.", support="adjacent",
        dist=normal(1.15, 0.12, 1.0, 1.5)))
_(Param("capillarity_II", 0.88, "ratio", "population", "li2012",
        "Relative capillary supply of type II fibres. Oxygen delivery is shared "
        "between the fibre populations in proportion to capillarity weighted by "
        "current activation, because functional hyperaemia directs flow to the "
        "fibres that are actually contracting. A purely static split starves "
        "the fast population at high intensity and drives it anoxic and "
        "glycolytic at workloads where that is not observed.",
        support="adjacent",
        dist=normal(0.88, 0.10, 0.6, 1.1)))

_(Param("atp_critical_frac", 0.55, "fraction", "structural", "korzeniewski_eval",
        "Fraction of the adenine pool at which ATP hydrolysis is progressively "
        "curtailed. Real muscle protects its ATP by losing force rather than by "
        "running the pool to zero; without this the equations would produce "
        "non-physiological negative concentrations instead of task failure.",
        support="assumed", dist=normal(0.55, 0.05, 0.42, 0.68)))
_(Param("atp_critical_width", 0.05, "fraction", "structural", "model_structure",
        "Smoothing width of the ATP-protection term.", support="assumed"))

_(Param("hepatic_glucose_k", 0.010, "1/s", "structural", "model_structure",
        "Rate at which hepatic glucose output defends arterial glucose against "
        "muscle uptake. The liver is not modelled mechanistically; this is a "
        "regulation stub so that blood glucose neither is pinned constant nor "
        "collapses unphysiologically. Flagged as a reduction.",
        support="assumed", dist=lognormal(0.010, 1.5)))
_(Param("hepatic_glucose_max", 0.055, "mmol/L/s", "structural", "model_structure",
        "Ceiling on hepatic glucose output expressed in muscle-model units.",
        support="assumed", dist=lognormal(0.055, 1.4)))
_(Param("liver_glycogen_hours", 14.0, "h", "structural", "glycogen_review",
        "Time constant over which fasting erodes the liver's ability to defend "
        "arterial glucose. This is why long fasted runs show falling blood "
        "glucose in the simulation.", support="indirect",
        dist=normal(14.0, 4.0, 6.0, 26.0)))

_(Param("lipolysis_tau_s", 600.0, "s", "structural", "venables2005",
        "Time constant of the rise in circulating fatty acids during exercise.",
        support="indirect", dist=normal(600.0, 180.0, 200.0, 1400.0)))
_(Param("lipolysis_exercise_gain", 1.9, "ratio", "population", "venables2005",
        "Fold rise in the plasma fatty-acid set-point during prolonged "
        "submaximal exercise in the fasted state; blunted by insulin and by "
        "high-intensity acidosis.", support="indirect",
        dist=normal(1.9, 0.5, 1.0, 3.2)))

# ==========================================================================
# 12. Metabolic control: cooperativity and product feedback
# ==========================================================================
# Without these, the model has no way to be quiet at rest.  Resting muscle
# respires at roughly 1-2% of its maximum while free ADP is only ~10x below its
# exercising value, so the respiratory-control term has to be cooperative; and
# substrate-supplying pathways have to be shut off by their own products when
# the chain downstream is not consuming them.
_(Param("hill_adp_oxphos", 2.6, "1", "population", "korzeniewski_eval",
        "Cooperativity of the ADP dependence of oxidative phosphorylation. A "
        "first-order Michaelis term cannot reproduce the ~50-100 fold range of "
        "muscle respiration between rest and maximum given only a ~10 fold rise "
        "in free ADP; the sigmoidal respiratory-control characteristic is a "
        "well described property of the system rather than of a single enzyme.",
        support="direct", dist=normal(2.6, 0.35, 1.4, 3.0),
        tags=("sensitivity_key",)))

_(Param("hill_amp_activation", 2.0, "1", "population", "li2012",
        "Cooperativity of AMP activation of glycogenolysis and "
        "phosphofructokinase. Combined with AMP scaling as ADP squared, this "
        "gives glycolytic flux a fourth-power dependence on the energy state, "
        "which is why glycolysis is nearly silent at rest and switches on "
        "steeply with intensity.", support="adjacent",
        dist=normal(2.0, 0.35, 1.2, 3.0), tags=("sensitivity_key",)))

_(Param("km_adp_glycolysis", 0.020, "mmol/L", "population", "li2012",
        "ADP requirement of the ATP-generating glycolytic steps "
        "(phosphoglycerate kinase and pyruvate kinase). Prevents the pathway "
        "from generating ATP when there is no ADP to phosphorylate.",
        support="adjacent", dist=lognormal(0.020, 1.4)))

_(Param("km_pi_glycolysis", 1.0, "mmol/L", "population", "li2012",
        "Phosphate requirement of glyceraldehyde-3-phosphate dehydrogenase; two "
        "inorganic phosphates enter per hexose phosphate.",
        support="adjacent", dist=lognormal(1.0, 1.35)))

_(Param("vmax_glycogen_synthase", 0.0012, "mmol/L/s", "population", "glycogen_review",
        "Glycogen synthase capacity at rest, sized so that resting hexose "
        "phosphate settles near 0.2 mmol/L while absorbing basal glucose "
        "uptake.", support="adjacent", dist=lognormal(0.0012, 1.4)))
_(Param("km_g6p_synthase", 0.35, "mmol/L", "population", "glycogen_review",
        "Hexose-phosphate half-saturation of glycogen synthase.",
        support="adjacent", dist=lognormal(0.35, 1.3)))
_(Param("synthase_contraction_inhibition", 0.90, "fraction", "population",
        "glycogen_review",
        "Fractional inhibition of glycogen synthase during contraction; the "
        "enzyme is phosphorylated and inactivated by the same signals that "
        "activate phosphorylase.", support="adjacent",
        dist=normal(0.90, 0.05, 0.7, 0.99)))
_(Param("atp_per_glucosyl_stored", 2.0, "mol/mol", "population",
        "textbook_bioenergetics",
        "ATP equivalents consumed per glucosyl unit added to glycogen "
        "(UTP regeneration plus pyrophosphate hydrolysis).", support="direct"))
_(Param("ca_activation_floor", 0.0007, "fraction", "population", "li2012",
        "Activity of the calcium-sensitive mitochondrial dehydrogenases in a "
        "quiescent fibre, as a fraction of their fully activated capacity. "
        "The engine solves this from the measured resting state rather than "
        "using the registered number directly, and the registered number then "
        "bounds that solution to a plausibility band; a solution outside the "
        "band is clipped and recorded. It "
        "has to be this low: the tricarboxylic-acid cycle in resting muscle "
        "turns over some two orders of magnitude below its exercising rate, and "
        "if the floor is set higher the dehydrogenases outrun the respiratory "
        "chain and drive the matrix NAD pool to a nearly fully reduced state "
        "that is not observed.", support="adjacent",
        dist=lognormal(0.0007, 1.8), tags=("derived", "plausibility_bound")))
_(Param("coa_total_mito", 0.6, "mmol/L", "population", "li2012",
        "Total mitochondrial coenzyme A pool. Making it finite is what lets the "
        "acetyl-CoA/CoA ratio act as the brake on beta-oxidation when the TCA "
        "cycle is not consuming acetyl units.", support="adjacent",
        dist=lognormal(0.6, 1.4)))
_(Param("km_coa_free", 0.020, "mmol/L", "population", "li2012",
        "Free coenzyme A half-saturation for pyruvate dehydrogenase and for the "
        "thiolase step of beta-oxidation. This term carries the product "
        "inhibition of pyruvate dehydrogenase on its own: acetyl-CoA inhibits "
        "the complex by consuming the free coenzyme A it needs as a substrate, "
        "so adding a separate acetyl-CoA inhibition term on top double-counts "
        "the same mechanism. Doing so braked pyruvate oxidation harder than it "
        "braked glycolysis, and the engine then predicted more lactate in the "
        "fasted state than the fed one -- the opposite of what is measured.",
        support="adjacent", dist=lognormal(0.020, 1.4)))
_(Param("ki_accoa_coa_ratio", 6.0, "ratio", "population", "li2012",
        "Acetyl-CoA/free-CoA ratio at which beta-oxidation and ketone "
        "oxidation are half-inhibited.", support="adjacent",
        dist=lognormal(6.0, 1.5), tags=("sensitivity_key",)))
_(Param("adp_free_rest", 0.015, "mmol/L", "population", "korzeniewski_eval",
        "Resting free cytosolic ADP. Used to build a self-consistent initial "
        "condition: adenine pool, creatine-kinase equilibrium and resting "
        "phosphate must agree, or the model silently moves phosphate out of the "
        "free pool during the first minutes and throttles respiration.",
        support="direct", dist=normal(0.015, 0.004, 0.007, 0.030)))

# ==========================================================================
# 15. Glycogenolysis product inhibition
# ==========================================================================
# Glucose-6-phosphate is an allosteric inhibitor of glycogen phosphorylase.
# Leaving it out is not conservative: phosphorylase then outruns glycolysis
# whenever acidosis slows phosphofructokinase, hexose phosphate climbs to tens
# of mmol/L, and because each hexose phosphate holds an esterified phosphate the
# free phosphate pool empties -- which shuts down oxidative phosphorylation
# through its own phosphate term. Measured muscle G6P stays in the 1-2 mmol/L
# range even in heavy exercise, which is what this term enforces.
_(Param("ki_g6p_phosphorylase", 1.6, "mmol/L", "population", "li2012",
        "Glucose-6-phosphate inhibition constant of glycogen phosphorylase.",
        support="adjacent", dist=lognormal(1.6, 1.4), tags=("sensitivity_key",)))
_(Param("ph_phosphorylase_half", 6.45, "pH", "population", "korzeniewski_eval",
        "pH at which glycogenolysis is half-inhibited. Acidosis slows "
        "phosphorylase as well as phosphofructokinase; modelling only the "
        "latter makes the pathway produce hexose phosphate it cannot consume.",
        support="adjacent", dist=normal(6.45, 0.12, 6.2, 6.8)))

# ==========================================================================
# 16. Parallel activation and the proton balance
# ==========================================================================
# Muscle ATP turnover spans roughly two and a half orders of magnitude between
# rest and hard running while free ADP moves only about four-fold. Respiratory
# control by ADP alone cannot cover that range at any plausible cooperativity.
# The resolution in the human skeletal-muscle bioenergetic modelling literature
# is parallel activation: the same signal that activates the contractile
# apparatus and the dehydrogenases also directly activates oxidative
# phosphorylation itself, so that oxygen consumption can rise steeply without a
# large fall in the phosphorylation potential.
_(Param("oxphos_activation_floor", 0.10, "fraction", "population",
        "korzeniewski_eval",
        "Activity of oxidative phosphorylation in a resting fibre as a fraction "
        "of its exercise-activated capacity. As with the dehydrogenase floor, "
        "the engine solves this from the measured resting state and uses the "
        "registered number to bound the solution: it is the resting activation "
        "the solve produces for a central parameter set, and a solution more "
        "than a factor of six away from it is clipped and recorded. Without "
        "this term the model "
        "has to "
        "deplete phosphocreatine far more than 31P magnetic resonance "
        "spectroscopy shows in order to reach moderate-intensity oxygen uptake.",
        support="direct", dist=lognormal(0.10, 1.7), tags=("derived", "plausibility_bound")))

_(Param("proton_per_lactate", 1.0, "mol/mol", "population", "korzeniewski_eval",
        "Protons accumulating in the cytosol per lactate retained. Monocarboxylate "
        "transport is a proton symport, so exported lactate takes its proton "
        "with it and only the lactate that accumulates acidifies the fibre. "
        "This replaces charging acid to glycolytic ATP turnover as such: "
        "glycolytic flux whose pyruvate is fully oxidised produces no net acid, "
        "and modelling it otherwise made the simulation acidify during "
        "moderate running in which no lactate accumulates at all.",
        support="direct", dist=normal(1.0, 0.12, 0.7, 1.35)))

_(Param("parallel_activation_exponent", 0.56, "1", "population",
        "korzeniewski_eval",
        "Exponent relating the direct activation of oxidative phosphorylation "
        "and the mitochondrial dehydrogenases to a fibre's relative ATP demand. "
        "Exactly proportional activation (exponent 1) is the degenerate case: "
        "it cancels the rise in demand, so the phosphorylation potential never "
        "moves and the simulated phosphocreatine response is flat across the "
        "whole intensity range. A sub-proportional exponent leaves the "
        "remainder to be met by a rising ADP concentration, which is what "
        "produces the measured progressive fall in phosphocreatine.",
        support="adjacent", dist=normal(0.56, 0.10, 0.35, 0.85),
        tags=("sensitivity_key",)))

_(Param("perfusion_demand_exponent", 0.65, "1", "population", "li2012",
        "Exponent relating oxygen-delivery capability to relative metabolic "
        "demand. Delivery rises faster than demand at low intensity, which is "
        "why resting muscle extracts only about a quarter of the oxygen "
        "presented to it while maximal exercise extracts almost all of it. "
        "Setting delivery capability equal to relative demand instead would "
        "force complete extraction at every intensity and make intracellular "
        "oxygen fall to near zero during easy running.",
        support="adjacent", dist=normal(0.65, 0.10, 0.4, 0.9)))

_(Param("proton_per_ck", 0.40, "mol/mol", "population", "korzeniewski_eval",
        "Net protons consumed per phosphocreatine consumed. This is not the "
        "creatine-kinase stoichiometry on its own: the reaction takes up one "
        "proton, but the ATP it regenerates is simultaneously being hydrolysed, "
        "which releases about 0.6 of a proton near pH 7. The net near 0.4 is "
        "what reproduces the small alkalinisation of roughly 0.05-0.09 pH units "
        "that 31P magnetic resonance spectroscopy shows at the onset of "
        "exercise, rather than the large alkaline swing that the bare "
        "stoichiometry would predict.", support="direct",
        dist=normal(0.40, 0.09, 0.2, 0.65)))

# ==========================================================================
# 17. The Randle cycle, both directions
# ==========================================================================
# Version 0.2 represented only one arm of the glucose-fatty-acid cycle:
# hexose phosphate inhibiting fat oxidation. With only that arm, raising fatty
# acid availability raises mitochondrial acetyl-CoA, which inhibits pyruvate
# dehydrogenase, but nothing slows glycolysis upstream -- so pyruvate keeps
# arriving and is pushed to lactate. The engine then predicted that a fasted run
# produces MORE lactate than a fed one at the same workload, which is the
# opposite of what is measured. Both arms are now represented.
_(Param("ki_randle_pfk", 2.2, "ratio", "population", "venables2005",
        "Mitochondrial acetyl-CoA/free-CoA ratio at which glycolytic flux is "
        "half-inhibited. Citrate is the proximate inhibitor of "
        "phosphofructokinase and tracks this ratio; representing it here keeps "
        "carbohydrate and fat oxidation moving in opposite directions rather "
        "than letting fat oxidation dam pyruvate up behind an inhibited "
        "pyruvate dehydrogenase complex.",
        support="indirect", dist=lognormal(2.2, 1.6),
        tags=("sensitivity_key",)))


_(Param("mito_vo2max_coupling", 0.80, "1", "inferred", "model_structure",
        "Exponent coupling a person's muscle oxidative capacity to their "
        "sampled aerobic ceiling. Sampling the two independently is not "
        "conservative: it manufactures people whose cardiovascular system "
        "delivers oxygen their muscle cannot use, and those draws then show "
        "threshold-level lactate at an intensity defined as a modest fraction "
        "of their own ceiling -- a contradiction, not an uncertainty. Coupling "
        "them keeps the ensemble inside the space of physiologically coherent "
        "people while leaving genuine residual variation in the relationship.",
        support="assumed", dist=normal(0.80, 0.15, 0.4, 1.1),
        tags=("sensitivity_key",)))

# ==========================================================================
# 18. Residual uncertainty on the two solved activation levels
# ==========================================================================
# The resting activation of the mitochondrial dehydrogenases and of oxidative
# phosphorylation are solved from the measured resting state rather than read
# from the registry. A solved quantity is not therefore exact: these carry the
# residual uncertainty of that solve, so the ensemble still explores it.
_(Param("ca_activation_residual", 1.0, "ratio", "inferred", "li2012",
        "Multiplicative residual on the solved resting activation of the "
        "calcium-sensitive mitochondrial dehydrogenases.",
        support="assumed", dist=lognormal(1.0, 1.45),
        tags=("sensitivity_key",)))
_(Param("oxphos_activation_residual", 1.0, "ratio", "inferred",
        "korzeniewski_eval",
        "Multiplicative residual on the solved resting activation of oxidative "
        "phosphorylation.", support="assumed", dist=lognormal(1.0, 1.35),
        tags=("sensitivity_key",)))
