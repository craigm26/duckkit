# Skill: Motion Philosophy

## When to Use

- Deciding how a duck moves in an app, a ghost, a preview or a demo
- A user asks "why doesn't the simulation walk?"
- Before writing any copy, caption or README line about what is being shown
- Choosing between a looping clip and a one-shot one

## Quick Check

If the motion has to travel across a floor, replay a recording. If it has to
answer a state, run the policy. Do not close the policy loop and expect a gait.

---

## Four Mechanisms

| Mechanism | Type | Frames | Behaviour past the end |
|---|---|---|---|
| Recorded gait | `DuckTrajectory` | 15-wide | **Loops**, accumulating root motion |
| Recorded one-shot | `DuckIntentClip` | 14-wide | **Clamps** at the last frame, reports `hasFinished` |
| Live inference | `DuckSimulation.step` | 15-wide targets | Runs forever; does not walk |
| Authored offset | `DuckMove` | 15-wide | Holds the last keyframe |

---

## `DuckSimulation` Does Not Produce a Gait

This is the single most important sentence in the package, and a previous
version of its own doc comment got it wrong. Closed on itself the loop settles
into a fixed point or an oscillation, never a walk, and `DuckSimulationTests`
pins that so the claim cannot come back.

Why, which is the useful part. Three of the 61 observation channels cannot be
supplied without physics:

| Channel | On a robot | In this loop |
|---|---|---|
| Gyro | measured body rotation | a constant built from the commanded yaw |
| Projected gravity | world-down in the trunk's *actual* orientation | fixed `[0, 0, −1]` |
| Joint velocity | read from the servos | differenced from the loop's own targets |

A walking policy is a feedback controller around contact. Its phase — when a
foot lands, how far the body has fallen onto it — arrives entirely through those
three. Freeze them and there is no phase to lock to. Measured: with velocities
dead the loop flip-flops between two values every tick (25 Hz, the control
loop's own Nyquist frequency); with them live it drives joints into their travel
stops. A first-order servo lag does not rescue it — swept across its whole useful
range the loop either oscillates at 6–25 Hz or goes completely still.

**What it is genuinely for:**

- Running the real network on an observation **somebody else measured** — a
  robot over `DuckRPC`, a recorded trace, a fixture. This is the real job.
- Single-step inference: given this state and this command, what does the
  trained policy ask for?
- Exercising `DuckGait`'s scaling, filtering and travel stops.

`isGrounded` is always `true` and the type says so rather than pretending.

---

## Replaying, Which Is What a Ghost Draws

The clips were recorded off-device, in MuJoCo, stepping Pollen's own robot model
(`robot_allcollisions.xml`, vendored byte-identical) with training's solver,
floor friction and torque ceiling at a 0.005 s timestep, running the policy every
fourth step — the robot's 50 Hz — through the **training** control path: target =
home + action at scale 1.0, no filter.

So what an AR ghost draws is still the trained network's walk. It simply was not
computed on the phone: the same bargain every game engine makes with motion
capture, except the actor was a neural network. **Say that, rather than "the
policy is walking on your floor".**

```swift
let walk = try DuckTrajectory.bundled(.walk)
let pose = walk.pose(at: elapsed)      // loops; root motion accumulates
```

Shipped gaits: `stand`, `walk`, `walk_fast`, `turn_left` on legs;
`skate_stand`, `skate`, `skate_fast`, `skate_back`, `skate_turn` on rollers.
`turn_right` does not exist — it is `turnLeft.mirrored()`, because the position
servo standing in for training's friction motor turns left far more readily than
right, and a clip of something the policy does badly is worse than a mirror.

---

## Looping Versus Clamping

`DuckIntentClip` is separate from `DuckTrajectory` on purpose. Ask a looping type
for a kick at four times the clip length and you get a duck that has kicked four
times and teleported forward three. Almost nothing here loops: a kick happens
once, a roll happens once, sitting down ends sat.

```swift
let clips = try DuckIntentClip.bundled()      // 17 of them, by name
let pose = clips["kick_left"]!.pose(at: t)    // clamps; pose.hasFinished
```

A clip carries its root as a **quaternion**, not a yaw scalar, because `roulade`
and `back_roll` both roll and one angle cannot carry that. It also carries
`startsFrom` / `endsIn` postures **measured** from the recording's own trunk
height and orientation, never asserted from its name.

Clip frames are 14-wide — the mouth is outside every policy's action space, so
`pose(at:)` fills joint 9 with `DuckModel.homePose[9]` and says so.

---

## Authored Motion Adds; It Does Not Replace

The obvious way to script a robot is to drive its joints to a sequence of poses.
On this robot that does not work: the servos run at `kp` 0.55 with a force limit
under 1 N·m, far too soft to hold a pose against gravity. Balance is not a
property of a pose here — it is something the policy is actively doing every
20 ms. An open-loop version of the shipped `stepUp` was measured **falling over
on a flat floor**, with nothing to trip on.

So a `DuckMove` is a set of offsets played on top of what a policy asked for.
See `skills/authored-moves.md`, and read
`docs/adr/0002-duck-move-carries-its-base.md` before writing a file format
around it.

---

## Common Mistakes

**Writing "the trained policy walking" over a replayed clip.** It is the trained
policy's walk, replayed. The distinction is the whole honesty claim of the
package.

**Using `DuckTrajectory` for a kick.** It wraps. Use `DuckIntentClip`.

**Reading a success rate off a recording.** A clip is one run. `back_roll`
ending toppled says what happened that time. Rates come from
`DuckIntentSuccess` — 16 rollouts each, under Pollen's own randomisation ranges.

**Mixing widths.** `DuckTrajectory.frames` are 15-wide, `DuckIntentClip.frames`
are 14-wide. They are not interchangeable arrays.

**Rendering a rollers clip with leg meshes.** Every clip carries a `variant`;
`DuckTrajectory.Clip.variant` derives it from the `skate` prefix. See
`skills/drawing-the-duck.md`.
