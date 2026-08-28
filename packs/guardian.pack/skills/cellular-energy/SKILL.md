# Skill: cellular-energy

When your person asks how their cellular energy works — fueling for a run,
glycogen, "should I run fasted", why they fade late, zone 2, altitude, what
a lab value means for their endurance — answer with the mitochondria
simulator instead of guessing. It lives at `/workspace/sim` (mitosim) and
computes **possible mechanisms** of skeletal-muscle energy metabolism during
running, as distributions with explicit uncertainty, from whatever real
observations you can supply about your person.

Scope honesty first: the engine models **running skeletal muscle**. It never
measures anyone's mitochondria, and it is not diagnosis or treatment advice.
For general "how are my mitochondria?" questions, say plainly that you can
explore mechanisms for their running muscle from their data, then do that.

## How to run it

```
bash /workspace/tools/mitosim.sh run <profile.json> --intensity 0.65 --duration 45
```

The first call ever bootstraps a venv (numpy/scipy — a couple of minutes);
after that it starts instantly. Useful subcommands:

- `run <profile> [scenario flags]` — one scenario; `--pace MM:SS`,
  `--hr-zone 1..5`, `--duration min`, `--grade pct`, `--hours-since-meal`,
  `--elevation m`, `--pattern 4x4|10x1|30:30|progression`.
- `compare <profile> --a a.json --b b.json` — paired contrast of two
  scenario JSONs (see `/workspace/sim/examples/fed.json` for the shape).
  This is the right tool for every "X vs Y" question.
- `qc <profile>` — how each supplied input is used, and what's missing.
- `validate`, `audit`, `registry`, `adapters` — the engine's own checks and
  catalogues, when you need to explain where a number comes from.

## Mechanism levers (counterfactuals)

The engine can also answer "what if one internal mechanism were different"
— a counterfactual on a mediator, not on a treatment. `mechanisms` lists the
available levers, each with its scope, what it does and does **not** model,
and whether it's enabled or gated. Apply one with `--mechanism SPEC` on `run`
or `compare`, e.g. `--mechanism 'mitochondrial_nad_pool:pool_scale=1.3'`.
`identifiability` reports which levers are currently distinguishable.

Use these only for genuine mechanism questions ("how would a bigger
mitochondrial NAD pool change my energy under load?"), and honour the hard
line the engine draws: a lever models what happens **if a mediator changed**,
never what a drug, supplement, dose, or therapy would do to your person, and
never whether they should take one. That's treatment advice — out of bounds
for you (see AGENTS.md). Pass through the engine's own scope and
"NOT modelled" caveats; when a chunk of the ensemble goes "sensitivity-only"
(outside the registered prior), say the result shows model behaviour, not
biological support.

Keep interactive replies snappy: pass `-n 80` (samples) for chat-turn
answers; only use the default 200 when precision genuinely matters and you
warned them it takes a while.

## Building your person's profile

Keep a profile at `/workspace/sim/profile.json`, modeled on
`/workspace/sim/examples/runner.json`. Rebuild the fields from **their real
data** each time before an important answer:

- `/workspace/data/healthkit-records.json` — VO2max estimate, resting HR,
  max HR observed, HRV, sleep hours, body mass, workouts (runs with
  duration/distance/HR → the `wearable.runs` array).
- `/workspace/data/alist-archive.json` — logged meals (→ `nutrition`),
  supplements/medications (→ `clinical.medications`), and anything they told
  you (age, height, training history) that you keep in `MEMORY.md`.
- `/workspace/data/files/` — lab PDFs; extract analytes into `labs[]` with
  value, unit, and collection date.

**Never invent a value.** Omit what you don't have — the engine widens its
intervals instead; that widening is the honest answer. Three fields are the
exception: the engine refuses to run without `body.age_y`, `body.height_cm`,
and `body.mass_kg`. Mass is usually in HealthKit; age and height you ask
your person once and keep in `MEMORY.md`.

## When you're missing what you need — ask for it

A vague answer they can't act on is worse than a smaller answer plus a
concrete next step. When their question needs data you don't have, still give
the best honest answer you can from what you do have (general physiology if
that's all), then **make exactly one targeted ask** for the input that would
make the *next* answer real. One ask per reply — never a form to fill out.

Let the engine choose the ask for you. Assemble the profile from whatever you
have and run `qc /workspace/sim/profile.json`; it names the missing input
that would tighten this person's answer most. Ask for that, specifically, in
plain language — not "send me your health data".

- **Bloodwork.** If labs are what's missing, ask them to add their most
  recent blood panel: they can **attach the PDF or a photo right here in the
  chat**, or drop it into **Health Docs** in the app — either way it syncs to
  you (chat files land in `/workspace/data/attachments/`, Health Docs in
  `/workspace/data/files/`) and you read it on your next turn. Name why it
  helps and which lines matter most for running energy — hemoglobin and
  ferritin (oxygen carrying and iron), and glucose / HbA1c for fuel — so they
  know it's not a fishing expedition. Tell them to black out anything they'd
  rather you not see; you only need those values.
- **A same-day capillary lactate** is the single measurement that narrows the
  hardest contrasts (fasted vs fed depth, fitness at a matched pace) more than
  anything else. It needs a cheap fingerstick meter, so only raise it when
  they're clearly invested and the question actually hinges on it — one
  sentence, not a sell.
- **No data at all.** Don't stall. Answer from general physiology, say plainly
  it isn't personalized yet, and ask for the smallest unlock: their age,
  height, and weight (the three the simulator can't run without), and whether
  they've done any running your HealthKit sync would have. That alone gets a
  first real simulation next turn.

Close the loop. Note what you asked for in `MEMORY.md` or `/workspace/log/` so
you don't ask twice, and when it arrives, use it and acknowledge it landed
("got your panel — your ferritin's on the low side, which fits…"). If they
decline, respect it and keep working from what you have.

## Reading the output back to them

- Every number is simulated, with an 80% interval. Give the central value
  and the honest spread in plain words ("probably around 100, could be 70 to
  135"), not false precision.
- Lead with the mechanism that answers their question (limiting mechanism,
  glycogen time, fat-vs-carb split), not the whole report.
- The report's own warnings (few runs supplied, excluded ensemble members)
  are worth one honest sentence when they materially weaken the answer.
- As always: no diagnosis, one nudge per reply, and anything alarming goes
  to a real clinician.
