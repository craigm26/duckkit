# Architecture

DuckKit is a library, not a daemon, so it has no architecture of its own — it has
a *position* in somebody else's. This page says which position, using the
three-loop separation [quackd](https://github.com/rokbenko/quackd) wrote down,
and is honest about the two places our claim is not theirs.

The reasoning is in [`adr/0001-three-loops.md`](adr/0001-three-loops.md); the
known format defect it turned up is in
[`adr/0002-duck-move-carries-its-base.md`](adr/0002-duck-move-carries-its-base.md).

## Three loops

An LLM takes 1–10 s to answer. A biped falls over in 0.3 s. That gap is not
closable by being clever about prompting; it is closed by having three loops at
three rates with three owners.

| Loop | Rate | Owner | quackd's rule |
|---|---|---|---|
| **Reflexes** | 50 Hz | onboard `robotd`, running ONNX policies | quackd never touches this |
| **Steering** | 5–20 Hz | the brain process | perception + composite behaviours |
| **Deliberation** | 0.2–1 Hz | the LLM | reads a summary, picks ONE action, judges the result |

Four rules defend the separation, and they are quackd's, quoted so ours can be
compared against them:

1. The LLM emits **one tool call per turn**.
2. **Composites never call the LLM.**
3. Built-in verbs send **intents**, never joint targets.
4. **The transport owns time**, so the steering loop runs at sim speed in a
   simulator and at real time on hardware without changing behaviour code.

## Where DuckKit's types land

### Reflex tier — 50 Hz

| Type | Anchor | Does |
|---|---|---|
| `DuckModel.tickHz` | `Sources/DuckKit/DuckModel.swift:92` | The rate itself: 50 Hz, 20 ms |
| `DuckPolicy.infer` | `Sources/DuckKit/DuckPolicy.swift:337` | One forward pass, ~40 µs |
| `DuckObservation.build` | `Sources/DuckKit/DuckObservation.swift:83` | The 61-float contract |
| `DuckGait.stages` | `Sources/DuckKit/DuckGait.swift:122` | scale → low-pass → clamp, holds named |
| `DuckGait.locomotion` | `Sources/DuckKit/DuckGait.swift:185` | Walk vs stand, on twist magnitude alone |
| `DuckSimulation.step` | `Sources/DuckKit/DuckSimulation.swift:188` | One whole tick, with the loop's memory exposed |
| `DuckClock.advance` | `Sources/DuckKit/DuckClock.swift:91` | Turns wall time into whole ticks, and clamps the burst |

### Steering tier — 5–20 Hz

| Type | Anchor | Does |
|---|---|---|
| `DuckToF.frame(from:)` | `Sources/DuckKit/DuckToF.swift:210` | Decodes 8×8 depth. Perception **input**, not a behaviour |
| `DuckToF.Frame.nearestInCentre` | `Sources/DuckKit/DuckToF.swift:138` | The one reduction that could feed an approach loop |
| `DuckPress.predictedRefusal` | `Sources/DuckKit/DuckSkill.swift:190` | Whether an action can be attempted at all |
| `DuckPerformance.Playback` | `Sources/DuckKit/DuckPerformance.swift:389` | The hold/deadman state machine for `wheee` |

**This tier is essentially empty, and naming that is the point of this
document.** DuckKit decodes what a sensor said and predicts what the robot will
refuse. It closes no loop on a detection. There is no `walk_to`, no approach
controller, no "keep the ball at bearing zero", and nothing that reads a `Frame`
and emits a `DuckCommand`. Anything of that shape is built *above* DuckKit today,
in the app, and each app builds its own.

`Playback` is the closest thing here to a composite: it runs at the sound's own
rate, sequences start → loop → end, and honours robotd's deadman without asking
anyone. It is a composite over a *speaker*, not over the world.

### Deliberation tier — 0.2–1 Hz

**Nothing in this package.** DuckKit has no LLM, no planner and no scheduler.
What it does supply is the vocabulary such a tier would pick from:

| Type | Anchor | The verb it names |
|---|---|---|
| `DuckPress` | `Sources/DuckKit/DuckSkill.swift:137` | Twelve buttons — five exclusive skills, seven sounds |
| `DuckIntentClip` | `Sources/DuckKit/DuckIntentClip.swift:17` | 17 recorded one-shots, with measured start and end postures |
| `DuckIntentSuccess` | `Sources/DuckKit/DuckIntentSuccess.swift` | How often each of them actually works, over 16 rollouts |
| `DuckMove` | `Sources/DuckKit/DuckMove.swift:26` | An authored offset played on top of a policy |

That last table is the useful shape: a deliberation tier needs a list of actions,
what each one starts from and ends in, and how often it works. All three exist
here already.

## Where we differ from quackd, and why

### 1. We re-implement the reflex tier; quackd never touches it

quackd's rule is absolute — *"quackd never touches this"* — because quackd talks
to a real robot whose `robotd` already owns the 50 Hz loop. DuckKit does the
opposite: `DuckGait` is a port of `robotd/src/control.rs`, and `DuckSimulation`
runs the real `.onnx` through the real 61-float observation at the real rate.

**Why that is legitimate.** Neither consumer has a robot in the loop at the
moment the arithmetic runs:

- An **AR ghost** must draw joint angles on a phone with no robot present. The
  only alternatives are to invent an animation — which would be a different
  animal wearing the policy's name — or to run the pipeline the robot runs.
- A **bench** must answer "what does this checkpoint do differently from that
  one, from the same starting condition". That requires the arithmetic locally
  and requires `DuckSimulation.State` to be settable, which it is.

The port is also defended: `DuckPolicyTests` matches onnxruntime's own outputs
over the vendored network to 1e-4, and `DuckModelTests` re-derives the tables
from Pollen's own MJCF, so drift shows up red.

**Why it is risky, stated plainly.** There are now two implementations of a
safety-relevant control path, in two languages, and only one of them moves a real
robot. They can disagree in three ways:

| Risk | Where it bites |
|---|---|
| robotd changes a constant | `DuckModel.actionScale`, `headLowpass`, `legsLowpass` silently describe an older robot |
| A per-policy scale is missed | Already happened: three of the seven were wrong at first (`Sources/DuckKit/DuckModel.swift:199`) |
| The ghost is mistaken for a simulator | `DuckSimulation` **cannot walk** (`Sources/DuckKit/DuckSimulation.swift:5`), and a previous version of its own comment claimed it could |

The mitigation is that every ported constant names its upstream file and is
pinned by a test, and that the "cannot walk" claim is asserted by
`DuckSimulationTests` so it cannot come back. The mitigation that does **not**
exist is any automatic check against a live robotd.

### 2. Our steering tier is empty

Named above. Consequence: the four defending rules land unevenly on us. Rule 1
and rule 2 are about a tier we do not have. Rule 3 we keep. Rule 4 we keep in a
different form.

### 3. "Intents, never joint targets" — we keep it, with an asterisk

`DuckPerformance` emits `DuckCommand`s, and `DuckObservation` feeds head targets
to the policy **inside the command block** rather than adding them to its output.
That is quackd's rule, structurally: an app asks for a pose and the network
decides what the joints do.

The asterisk is `DuckMove` (`Sources/DuckKit/DuckMove.swift:103`), which does add
to joint targets after the policy has spoken. It is deliberate and bounded — the
result is clamped to the robot's own travel, and the type's opening comment
explains why an open-loop replacement pose falls over on a flat floor with `kp`
0.55 servos. Read it as "an offset on top of an intent", not as a second control
path.

### 4. "The transport owns time" — we say the *clock* owns time

quackd's transport supplies `now()`/`sleep()` so verb code is rate-agnostic.
DuckKit has no transport: `DuckRPC` is deliberately `Data` in, `Message` out with
no socket underneath. So time is owned by `DuckClock` instead
(`Sources/DuckKit/DuckClock.swift:41`), and the rule that replaces quackd's is
stated at `Sources/DuckKit/DuckClock.swift:3`: **stepping the duck once per
display frame is a bug.** A 120 Hz panel otherwise walks the duck 140% fast, and
nothing errors.

The corollary is the same shape as quackd's: anything reporting how long the duck
has been doing something asks `DuckClock.elapsed` (ticks × 20 ms), never the
phone's clock, because the catch-up clamp drops time rather than banking it.

One place we are weaker: `DuckState.receivedAt`
(`Sources/DuckKit/DuckState.swift:58`) is stamped by the *phone*, because
`robot.state` as documented carries no timestamp of its own. Network jitter
therefore sits inside every duration computed from a state stream, and the type
says so rather than hiding it.

## Two action scales, both correct

This is not a bug and must not be "fixed" in either direction. It is the clearest
example of a number belonging to a *tier* rather than to the robot.

| Domain | Scale | Anchor |
|---|---|---|
| The robot, via robotd | **0.9** | `Sources/DuckKit/DuckModel.swift:103` |
| Training, and any replay of what a policy did in sim | **1.0** | `Sources/DuckKit/DuckModel.swift:99–102`; recorder at `Sources/DuckKit/DuckTrajectory.swift:22` |

Per network on the robot, `DuckPolicyKind.actionScale`
(`Sources/DuckKit/DuckModel.swift:199`) pins standing, sit/stand, ground-pick and
roulade at 1.0 too; only walking and the kicks-in-motion run de-rated at 0.9.

The low-pass follows the same rule and carries the same warning
(`Sources/DuckKit/DuckModel.swift:111–129`): robotd applies α 0.5 / 0.7, training
applied no filter at all, and robotd's own comment about *why* is contradicted by
the training code. Apply it when modelling the robot; never in a replay.

## `homePose` is not universally the base

`DuckModel.homePose` is the robot's rest pose. The pose an action is an offset
from belongs to the **policy**, which declares its own in
`metadata_props.default_joint_pos` — and the header at
`Sources/DuckKit/DuckModel.swift:38–44` says so explicitly, naming
`headspin.onnx`, which wants neck_pitch 0.220 and head_pitch 0.680 where
`homePose` has 0.3491 and 0.3491. One of the 17 shipped intent clips was recorded
from that policy (`Sources/DuckKit/DuckIntentClip.swift:65` carries each clip's
policy name).

**The gap is real and currently unmitigated in code:**

- `DuckGait.stages` hardcodes `DuckModel.homePose` as the base
  (`Sources/DuckKit/DuckGait.swift:137`).
- `DuckObservation.build` at least *parameterises* it
  (`Sources/DuckKit/DuckObservation.swift:88`) — but
  `DuckSimulation.step` calls it without passing one
  (`Sources/DuckKit/DuckSimulation.swift:201`), so the default applies.
- `DuckPolicy` does not parse `metadata_props` at all. `Description`
  (`Sources/DuckKit/DuckPolicy.swift:70`) carries ops, initializers, input and
  output names and a parameter count — no metadata.

So today: correct for all of Pollen's releases, silently wrong for a community
policy with a different base, and the only defence is the comment. Anything
replaying a third-party policy must supply the base itself. Making
`DuckPolicy.Description` carry `default_joint_pos`, and `DuckGait` take it, is
the obvious next change and is not made here.

## Reading order for an agent

1. This page, for where things sit.
2. [`adr/0001-three-loops.md`](adr/0001-three-loops.md) for the decision.
3. `skills/motion-philosophy.md` before writing anything that moves.
4. `skills/upstream-numbers.md` before writing down any constant.
