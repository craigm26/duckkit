# Skill: Where the Upstream Numbers Come From

## When to Use

- About to write down a constant, a rate, a threshold or a percentage
- A number here disagrees with a datasheet, a paper, or your memory
- Deciding whether an action scale, a filter or a base pose applies
- Someone asks "how accurate is this?"

## Quick Check

If you cannot point at a file, a fixture or an upstream source for a value, say
you cannot. Do not write one down.

---

## Three Kinds of Number in This Package

| Kind | Example | Rule |
|---|---|---|
| **Ported** | joint order, home pose, action scale, filter α, ToF status codes | Never re-derive. Change only to track upstream. |
| **Measured here** | 26 mm step-up, 16/16 rollout rates, ~0.11 m/s recorded | Cite the harness and its conditions in the same breath. |
| **Chosen here** | sound durations, `catchUpLimit` = 8, `planeThickness` = 20 mm | Say they are ours, and say what would change them. |

Conflating them is the failure. "The duck climbs 26 mm" is a property of *this*
simulation — Pollen's physics model, our floor, our step, our friction — and
saying it flatly is a claim about hardware nobody has measured.

---

## Ported: The Robot's Own Constants

`Sources/DuckKit/DuckModel.swift`, from `pollen-robotics/microduck`
(`duck-control/src/model.rs`, `robotd/src/control.rs`), where they were measured
against hardware and trained into the policies.

Re-deriving any of them from a datasheet is exactly the kind of change that looks
right and walks wrong: a policy observes joint positions *relative to this home
pose* and its output is multiplied by *this action scale*, so a discrepancy is
not a preference, it is a constant error on fourteen observation slots.

The kinematic side comes from that repo's MuJoCo model
(`kinematics/assets/alpha/robot_walk.xml`), vendored under
`Tests/DuckKitTests/Fixtures/duck/`, and `DuckModelTests` /
`DuckKinematicsTests` re-derive the tables from it. **The hardcoded values cannot
drift from upstream without a test going red.**

---

## Two Action Scales, Both Correct

| Domain | Scale | Source |
|---|---|---|
| The robot (robotd) | **0.9** | robotd's `control.rs` default |
| Training / sim replay | **1.0** | every `.onnx`'s own metadata, and all six `microduck_rl` env configs |

**Do not reconcile them.** `DuckModel.actionScale` is 0.9 because this package
mirrors robotd; the trajectory recorder uses 1.0 because it reproduces what the
network did in simulation. Two truths, two domains.

Per network on the robot, `DuckPolicyKind.actionScale` — and the first cut of it
got three wrong. robotd pins roulade and ground-pick at 1.0 and the whole
sit/rise cycle at a literal 1.0; only walking and the kicks-in-motion run de-rated
at 0.9. A package that claims to model the runtime and quietly de-rates a roulade
by 10% is modelling a different robot.

---

## The Low-Pass, and Pollen's Own Comment Being Wrong

`headLowpass` 0.5, `legsLowpass` 0.7 mirror robotd's defaults. robotd's doc
comment says the alpha policies "are trained with 0.5 — it must match training or
transfer degrades". **The training code contradicts it:** mjlab's joint-position
action term is `raw × scale + offset` with no filter anywhere, and all six
`microduck_rl` env configs leave it that way.

What training *does* model is actuator lag — the BAM friction actuator delays
actions by several physics steps — so the hardware filter is best read as
standing in for dynamics the sim gets from its actuator model instead.

The rule is unchanged either way: **apply these when modelling what robotd sends
to servos; never in a replay of what a policy did in simulation.** The recorder
deliberately does not.

---

## `homePose` Is Not Every Policy's Base

Every `.onnx` states its own base in `metadata_props.default_joint_pos`. All ten
of Pollen's declare a pose equal to `DuckModel.homePose`, which is why treating it
as universal went unnoticed. A community file need not: `headspin.onnx` wants
neck_pitch 0.220 and head_pitch 0.680 where `homePose` has 0.3491 and 0.3491 —
and one of the 17 shipped intent clips was recorded from it.

`DuckModel.homePose` is documented as the robot's rest pose, **not a contract**.
DuckKit does not currently read that metadata: `DuckGait.stages` hardcodes
`DuckModel.homePose`, and `DuckObservation.build` takes a `homePose:` parameter
that `DuckSimulation.step` leaves at its default. Anything replaying a
third-party policy has to supply the base itself. See `docs/architecture.md`.

---

## Measured Here: Rates, Not Anecdotes

**A recording cannot carry a success rate.** A clip is one run. "Ends toppled"
says what happened that time and nothing about whether it happens every time, and
a screen printing a rate from one recording is printing 0% or 100% and calling it
a measurement.

```swift
let success = try DuckIntentSuccess.bundled()
success.rollouts                        // 16
success.intents["roller_crouch"]        // an Outcome
success.randomisation.lines             // the ranges, in words
```

**16 rollouts per intent**, under ranges read out of Pollen's own
`microduck_velocity_env_cfg.py` — drop height 0.12–0.13 m, footpad friction scale
0.7–1.3, shove ±0.3 m/s every 3–6 s, trunk centre of mass ±0.003 m. Those are the
perturbations the policies were trained against, which makes the rate a
measurement of the same thing training was optimising.

**Two rates, because there are two questions.** `achieves` asks whether the move
did what it is *for* — a stair move ending neatly upright on the floor has
failed, however tidy it looks. `repeats` asks only whether it did again what it
did the day it was recorded, which says whether the clip on file is
representative or a lucky take. They come apart badly on exactly the clips that
matter, and a single "success rate" would have to pick one silently.

`unstable` is counted separately: a rollout MuJoCo could not finish, an extreme
contact impulse taking the state to NaN. Neither a success nor a failure of the
move; Pollen's config terminates on it too.

---

## Known Limits, Stated

These are in the source and belong in any honest write-up:

- **The recorded gait's actuator is simplified.** A position servo stands in for
  training's friction-and-lag motor model. The policy walks straight with the
  correct turn sign but covers less ground than commanded — 0.25 m/s commanded
  records about 0.11 m/s — and turns left far more readily than right, which is
  why `turn_right` is a mirror rather than a clip.
- **`skate_stand` is not still.** At vx = 0 the roller policy drifts about
  0.09 m/s on this plant, and the clip's `deltaX` says so.
- **`skate_turn` spins.** Recorded at +0.6 rad/s commanded, the policy turns the
  commanded way at about 3.3 rad/s — five times what was asked. Take the swizzle
  from the clip and the heading from whatever drives the robot.
- **The voice is not the robot's.** Traits for a seed match upstream's
  derivation; the waveform is ours, and nothing has been checked against a real
  bank because none exists yet.
- **The sound durations are ours**, quantised to the 50 Hz tick. When hardware
  lands, measure the bank and correct the tick counts; every timeline and every
  buffer follows from them.

---

## Common Mistakes

**Averaging a percentage over intents.** They measure different criteria.

**Quoting 26 mm as the robot's stair limit.** It is `DuckMove.stepUp`'s number in
*this* simulation, with our floor, our step and our friction. The figure a scene
editor must put in front of someone building a staircase is the **measured 10 mm
ceiling** recorded on `DuckIntentClip.Environment.Step.riseAbove(_:)`, and
`DuckIntentClipTests` asserts that `step_up` does not get up a flight because of
it.

**"Fixing" 0.9 to 1.0, or the reverse.** See above.

**Copying a constant into an app.** Import it. Everything in `DuckModel` is
public so there is one copy; `ZZExport` exists so even the web simulator reads
the same numbers rather than a retyped set.
