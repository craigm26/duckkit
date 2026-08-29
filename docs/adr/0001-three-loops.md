# ADR-0001: Three loops, three rates, three owners

**Status:** accepted · **Date:** 2026-08-29

## Context

DuckKit has grown into thirty-odd types spanning inference at 50 Hz, a depth
sensor, a wire protocol, a voice synthesiser, choreography, recorded clips,
geometry and signing. Nothing wrote down what belongs together and what must not
touch, so three questions kept coming back with different answers:

- Is `DuckSimulation` a simulator? (No, and a previous version of its own doc
  comment said yes — `Sources/DuckKit/DuckSimulation.swift:5`.)
- Which action scale is right? (Both. `Sources/DuckKit/DuckModel.swift:99–103`.)
- Where does perception go? (Nowhere, currently, and nobody had noticed.)

[quackd](https://github.com/rokbenko/quackd) — an LLM brain daemon for the same
robot, Apache-2.0 — had already answered the general form of this in its own
ADR-0003, from the constraint that actually forces the answer: an LLM takes
1–10 s to reply and a biped falls over in 0.3 s. Upstream's own note agrees:
*"LLM latency means the agent is a high-level controller"*, and `robotd` stops the
robot itself when commands stall.

Adopting somebody else's separation is cheaper than inventing a worse one, and it
means a DuckKit app and a quackd script describe the same robot the same way.

## Decision

Adopt quackd's three-tier separation as DuckKit's own vocabulary, and place every
type in it. The placements, with anchors, are in
[`../architecture.md`](../architecture.md).

| Loop | Rate | Owner |
|---|---|---|
| Reflexes | 50 Hz | RL policies — balance, gait, stand-up |
| Steering | 5–20 Hz | perception + composite behaviours |
| Deliberation | 0.2–1 Hz | an LLM: reads a summary, picks ONE action, judges it |

Adopt quackd's four defending rules, with two departures recorded below:

1. The LLM emits one tool call per turn.
2. Composites never call the LLM.
3. Built-ins send **intents**, never joint targets.
4. The transport owns time.

### Departure 1 — we implement the reflex tier; quackd does not

quackd's rule is *"quackd never touches this"*, because a real `robotd` owns the
50 Hz loop on the robot in front of it. DuckKit deliberately does the opposite:
`DuckGait` (`Sources/DuckKit/DuckGait.swift:122`) ports
`robotd/src/control.rs`, and `DuckSimulation.step`
(`Sources/DuckKit/DuckSimulation.swift:188`) runs the real network through the
real observation at the real rate.

This is legitimate because both consumers run the arithmetic **with no robot in
the loop**: an AR ghost has to draw joint angles on a phone, and a bench has to
compare two checkpoints from an identical starting condition — which is why
`DuckSimulation.State` is public and writable. The alternative to porting is
animating, and an animation wearing a policy's name is the dishonesty this whole
package exists to avoid.

It is risky because there are now two implementations of a safety-relevant
control path in two languages, and only one moves a robot. Accepted with three
mitigations, all already in place: every ported constant names its upstream file;
`DuckPolicyTests` matches onnxruntime to 1e-4 over the vendored network;
`DuckModelTests` and `DuckKinematicsTests` re-derive the tables from Pollen's own
MJCF. There is **no** automatic check against a live robotd, and this ADR does
not pretend otherwise.

### Departure 2 — "the transport owns time" becomes "the clock owns time"

DuckKit has no transport by design: `DuckRPC` is `Data` in, `Message` out with no
socket underneath, which is what lets the hard part — the framing — be tested on
a Pi against a recorded stream. Time is therefore owned by `DuckClock`
(`Sources/DuckKit/DuckClock.swift:41`), and the rule that replaces quackd's is
`Sources/DuckKit/DuckClock.swift:3`: stepping the duck once per display frame is
a bug.

We are weaker than quackd in one place, and it is worth stating: `robot.state`
carries no timestamp, so `DuckState.receivedAt`
(`Sources/DuckKit/DuckState.swift:58`) is the phone's clock and network jitter
sits inside every duration derived from a state stream.

### What this ADR does not decide

It does not add a steering tier. It names the absence.

## Consequences

- **The steering tier is empty, and that is now a documented gap** rather than an
  oversight. `DuckToF` decodes frames and `DuckPress.predictedRefusal` guesses at
  a refusal; nothing closes a loop on a detection. Every app that wants
  `walk_to` builds its own, and they will not agree.
- **The two action scales stop being a bug report.** 0.9 is the reflex tier on
  hardware; 1.0 is the reflex tier as training ran it, which is what a replay
  reproduces. The same reasoning covers the low-pass. Neither may be "fixed".
- **`DuckSimulation` is reflex-tier inference, not a world.** Anything that needs
  contact replays a clip. `skills/motion-philosophy.md` is the guidance that
  follows from this line.
- **The deliberation tier has a vocabulary waiting for it.** `DuckPress` (twelve
  actions), `DuckIntentClip` (17 one-shots with measured start and end postures)
  and `DuckIntentSuccess` (how often each works, over 16 rollouts) are exactly
  the three things a tool-calling planner needs, and they already exist.
- **Reading the base pose from a policy's own metadata becomes a tier question,
  not a nicety.** A reflex-tier constant that belongs to the *policy* is
  currently taken from `DuckModel` — see
  [`../architecture.md`](../architecture.md#homepose-is-not-universally-the-base)
  and `Sources/DuckKit/DuckGait.swift:137`.

## References

- quackd ADR-0003, "Three loops, three rates, three owners" —
  <https://github.com/rokbenko/quackd/blob/main/docs/adr/0003-three-loops.md>
- quackd architecture — <https://github.com/rokbenko/quackd/blob/main/docs/architecture.md>
- `pollen-robotics/microduck` — `robotd/src/control.rs`, `duck-control/src/model.rs`
