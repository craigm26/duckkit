# Skill: Authored Moves

## When to Use

- Building a screen where someone records, edits or exports a motion
- Reading or writing a `.duckmove` file
- Handling pose data from a file, a share sheet, or a language model's draft
- A user reports "the move I imported plays wrong"

## Quick Check

Untrusted poses go through `init(validating:times:poses:)` or
`init(validatingPolicyPoses:times:poses:)`. Those take **raw arrays**. Anything
that builds a `Keyframe` first has already crashed on bad input.

---

## A Move Is Offsets, Not Poses

The shipped `stepUp` reaches the head down onto a step, leans on it, and hauls a
foot over — while the walking policy carries on balancing underneath. That
division is the design, not a convenience: with `kp` 0.55 and a force limit under
1 N·m the servos cannot hold a pose against gravity, and an open-loop version of
this move was measured falling over on a flat floor.

```swift
let targets = DuckMove.stepUp.applied(
    to: policyTargets,                  // what the network asked for, 15-wide
    at: elapsed,
    blend: DuckMove.stepUpBlend,        // 1.245066 — over-drives on purpose
    base: DuckModel.homePose)
```

The result is clamped to the robot's own travel, so no combination of a policy
and a move can ask for an angle the joint does not have.

`stepUp`'s two surprising choices are pinned by tests so a re-tune has to
acknowledge them: the approach command is 0.118254, *below* the speed at which
the walking policy engages, so the duck is standing into the step rather than
walking at it; and the neck pulls **up** at transfer rather than pressing down —
the head is hauling, not propping. Measured in simulation: 26 mm, against 2 mm
for the walking policy alone. That number is a property of this simulation, not
of the robot — the physics model is Pollen's, the floor and friction are ours.

---

## Read `docs/adr/0002-duck-move-carries-its-base.md` First

`duck-move/1` records keyframe times and 15-wide poses and **records nothing
about what those poses are relative to.** `pose(at:from:)` reads them as absolute
poses; `applied(to:at:blend:base:)` reads the same array as offsets from `base`.
Both default `base` to `DuckModel.homePose`, so the two agree today and diverge
the moment a move is authored from any other starting pose.

Until `duck-move/2` exists: **write `provenance` and `note` on every file you
emit, and say in them which pose the move was authored from.** That is prose, not
a contract, but it is the only place the fact currently fits.

---

## Two Doors, and Why Both Exist

| Initializer | Input | On bad data |
|---|---|---|
| `init(name:keyframes:)` | trusted literal | **traps** |
| `init(validating:keyframes:)` | keyframes you already built | throws |
| `init(validating:times:poses:)` | raw 15-wide arrays | throws |
| `init(validatingPolicyPoses:times:poses:)` | raw **14**-wide arrays | throws |

Preconditions are right for a move written as a literal in this package — a
mistake there is a bug and should stop the tests. They are exactly wrong for a
file somebody shared, a clip imported from another owner, or a pose sequence a
model drafted. An authoring tool that crashes on a malformed import is one nobody
can use to import anything.

Note the trap that shape closes: `Keyframe.init` itself traps on anything but
fifteen joints. So handing a malformed pose to `init(validating:keyframes:)` to
see whether the move refuses it kills the process **before** the function is
entered. That is why the raw-array doors exist and why the width check lives in
them.

`DuckMove.Invalid` names the problem, and `wrongWidth` with `got == expected − 1`
appends the way out by name: *"use `init(validatingPolicyPoses:)`"*.

---

## The 15 / 14 Split

| Format | Width | Mouth |
|---|---|---|
| `.duckmove` (`duck-move/1`) | 15 | included — a person can open the beak |
| `.duckintent` (`duck-intent-clips/3`) | 14 | excluded — no policy commands it |

`init(validatingPolicyPoses:)` widens a 14-wide file, scattering through
`DuckModel.jointOfPolicySlot(_:)` and filling joint 9 with the `mouth:` argument.
Its default is `DuckModel.homePose[9]` = **0.0 rad**, which is *not* the closed
position: travel is −5°…+30°, so 0 rad is 5/35 = **one seventh open**. If a move
should import with the beak shut, pass `DuckModel.mouthClosed` explicitly.

Narrowing runs the other way and is lossy: `DuckObservation.policyJoints(_:)`
drops index 9 with no complaint. A 15-wide draft round-tripped through a 14-wide
format loses whatever the author did to the mouth.

---

## The File

```swift
let data = try DuckMoveFile.encode(
    name: "goal celebration", move: move,
    provenance: "authored in Duck Studio, from the home pose",
    note: "no physics ran")

let contents = try DuckMoveFile.decode(data)   // Contents: name, move, provenance, note
```

One door for three programs — Duck Studio writes them, OpenCastor plays them, the
sim harness takes the same shape. The day two of them carry their own parsers is
the day a file works in one and silently misloads in another.

The move validates on the way **out** as well as in: a writer that can emit a
file its own reader refuses is two bugs wearing one format.

| `ReadError` | Means |
|---|---|
| `.notAMove` | Not JSON, or no `format` key |
| `.unsupportedFormat(String)` | A version this build does not read |
| `.jointOrderMismatch` | The file names its joints and they are not this robot's, in this order |
| `.malformed(String)` | No keyframes, or times and poses of different lengths |
| `.invalid(DuckMove.Invalid)` | The keyframes themselves — carries the joint's name |

`joints` absent is tolerated (the order is then this package's, which is what
every writer to date produced). **Present and different is refused loudly rather
than remapped**: a pose scattered into the wrong joints is not garbage, it is a
plausible-looking motion for a different robot, and playing it teaches the viewer
something false about this one.

---

## Common Mistakes

**Interpolating linearly.** `pose(at:)` uses smoothstep because the derivative
matters: a linear blend arrives at every keyframe with a velocity step, and a
servo asked to change speed instantaneously answers with a jolt the balance
controller then has to absorb. The ends are exact — `a + (b − a) × 1` is not
reliably `b` in floating point, and a keyframe landing a hair short makes every
downstream equality test lie.

**Turning off `enforceTravel` for convenience.** It is the check that keeps an
imported file from asking for an angle the joint does not have, and it names the
joint when it fires.

**Building `Keyframe`s from untrusted numbers.** See the two doors above.

**Assuming `mirrored()` validates.** It uses the trapping initializer. The
swap-and-negate is the same one `DuckTrajectory` uses, and it is right because
the robot's home pose is exactly antisymmetric — every left joint is the negation
of its right counterpart — but nothing re-checks travel afterwards, so mirror
moves you built, not moves you were handed.
