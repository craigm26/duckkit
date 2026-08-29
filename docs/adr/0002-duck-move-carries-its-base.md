# ADR-0002: A `.duckmove` must carry its base pose

**Status:** proposed · **Date:** 2026-08-29

## Context

`duck-move/1` records keyframe times and 15-wide poses
(`Sources/DuckKit/DuckMoveFile.swift:14–19`). It does **not** record what those
poses are relative to, and `DuckMove` reads them two different ways depending on
which method you call.

### The two call sites

`pose(at:from:)` treats a keyframe as an **absolute pose**. `base` is only where
the first segment interpolates *from*; the keyframe itself is returned unchanged
at the end of every segment — `Sources/DuckKit/DuckMove.swift:66–89`:

```swift
public func pose(at time: TimeInterval, from base: [Double] = DuckModel.homePose) -> [Double] {
    precondition(base.count == DuckModel.jointCount, "the base pose is all 15 joints")
    if time <= 0 { return base }
    …
            if u >= 1 { return frame.pose }
```

`applied(to:at:blend:base:)` treats the same array as an **offset from `base`** —
`Sources/DuckKit/DuckMove.swift:103–114`, via `offset(at:from:)` at lines 92–95:

```swift
    let delta = offset(at: time, from: base)          // = pose(at:from:) − base
    return (0..<DuckModel.jointCount).map { j in
        let want = policyTargets[j] + delta[j] * blend
```

Both parameters default to `DuckModel.homePose`, so the two readings agree today
and diverge the moment a move is authored from, or replayed against, anything
else.

### The file records neither

`DuckMoveFile.encode` writes exactly `format`, `name`, `joints`, `times`,
`poses`, and optionally `provenance` and `note`
(`Sources/DuckKit/DuckMoveFile.swift:116–122`). `decode` hands the poses straight
into the validating initializer with no base at all
(`Sources/DuckKit/DuckMoveFile.swift:100`):

```swift
    let move = try DuckMove(validating: name, times: times, poses: poses)
```

and `Contents` (lines 26–39) carries `name`, `move`, `provenance` and `note` —
nothing about a base, and nothing about which reading applies.

### The format's own validation disagrees with its own documented playback

The reader checks every keyframe value against `DuckModel.jointRanges`
(`Sources/DuckKit/DuckMove.swift:213–221`). That check is only meaningful if the
numbers are **absolute joint angles** — an offset of +0.9 rad is not out of
travel, it is a large offset.

Meanwhile the shipped move's own documentation says to play it the other way
(`Sources/DuckKit/DuckMove.swift:275`):

> Play it with `applied(to:at:blend:)` and `blend` = ``stepUpBlend``.

So the file format validates on the absolute reading and the documented playback
path consumes the relative one. Both are in the repository, both are tested
(`testAMoveStartsFromTheBasePose` and `testOffsetIsThePoseMinusTheBase` in
`Tests/DuckKitTests/DuckMoveTests.swift`), and neither test can catch the
disagreement because both use the default base.

Even the shipped `stepUp` is authored in both idioms at once:
`plantPose` writes `p[5] = 0.612201` (absolute) while `pushPose` writes
`p[2] = DuckModel.homePose[2] + 0.140355` (an offset that happens to be stored
absolute) — `Sources/DuckKit/DuckMove.swift:303–319`.

## The failure

A move authored from any pose other than home replays as a **constant bodily
distortion**, on every joint, for its whole duration, with nothing detecting it.

Concretely. Someone authors a celebration in Duck Studio while the duck is
seated, and the tool stores the poses it can see — absolute, seated, all legal
inside travel, so `encode` and `decode` both accept them. A player then does the
documented thing:

```swift
let targets = move.applied(to: policyTargets, at: t)   // base defaults to homePose
```

`delta` is now `seatedPose − homePose` at every joint of every keyframe, plus
whatever the author actually meant. A move that meant *"lift the neck 0.1 rad
from where you are"* becomes *"add (seated − home) and then 0.1"* on all fifteen
joints at once.

Three things make this worse than an ordinary bug:

1. **The clamp hides it.** `applied` holds the result inside the robot's travel
   (`Sources/DuckKit/DuckMove.swift:112–113`), so the output is always a pose the
   hardware could reach. It looks like a plausible motion, not like corruption.
2. **It cannot be detected from the file.** There is no field to check, and both
   readings produce travel-legal numbers. A reader cannot tell a seated-base file
   from a home-base one.
3. **It is silent across programs.** Duck Studio writes these files, OpenCastor
   plays them, and the sim harness takes the same shape. One door, three
   consumers, and the door does not carry the fact that decides what the numbers
   mean.

Today nothing in this repository authors from a non-home base, so nothing is
broken *yet*. That is exactly when a format defect is cheap to fix.

## Related: 15-wide against 14-wide

The same file pair carries a second silent narrowing, and a `duck-move/2` should
close both at once.

| Format | Width | Mouth |
|---|---|---|
| `.duckmove` (`duck-move/1`) | **15** | included — a person can open the beak, and no policy can |
| `.duckintent` (`duck-intent-clips/3`) | **14** | excluded — the mouth is outside every policy's action space |

Narrowing a draft is lossy and unannounced: `DuckObservation.policyJoints(_:)`
(`Sources/DuckKit/DuckObservation.swift:133`) drops index 9 without complaint, so
a 15-wide authored move round-tripped through a 14-wide format loses whatever the
author did to the beak.

Widening back has a default that is not obviously right either.
`init(validatingPolicyPoses:times:poses:)`
(`Sources/DuckKit/DuckMove.swift:235–237`) fills the mouth with
`DuckModel.homePose[DuckModel.mouthIndex]` = **0.0 rad**. Mouth travel is −5°…+30°
(`Sources/DuckKit/DuckModel.swift:78–79`), so 0.0 rad is 5/35 = **one seventh
open**, not closed. A move imported "with the mouth left alone" therefore arrives
with the beak slightly ajar for its whole length.

## Decision (proposed)

Introduce `duck-move/2`, in which a move carries its base explicitly, and keep
`duck-move/1` readable forever.

**New required keys:**

| Key | Type | Meaning |
|---|---|---|
| `base` | 15 doubles | The pose the keyframes are written against |
| `poses_are` | `"absolute"` \| `"offsets"` | Which reading applies. No default. |

**Optional, and better than `base` when it is available:**

| Key | Type | Meaning |
|---|---|---|
| `base_policy` | string | Fingerprint of the policy whose `default_joint_pos` is the base |
| `mouth` | double | The authored mouth angle, so a 14-wide narrowing states what it dropped |

`base_policy` is the form that survives a policy's base changing, and it links
this ADR to the gap named in
[`../architecture.md`](../architecture.md#homepose-is-not-universally-the-base):
`homePose` is the robot's rest pose, not every policy's base
(`Sources/DuckKit/DuckModel.swift:38–44`).

**Type changes that follow:**

- `DuckMove` gains stored `base: [Double]` and `posesAre` properties.
- `pose(at:)` and `applied(to:at:blend:)` lose their `base:` parameters. The move
  knows its own base; a caller cannot supply a wrong one because it cannot supply
  one at all.
- `DuckMoveFile.encode` writes the base; `decode` reads it.

**Migration, which costs nothing:** a `duck-move/1` file decodes as
`base = DuckModel.homePose, posesAre = .absolute`. That is precisely today's
behaviour, so every file already written keeps playing identically — but the
assumption becomes a *recorded* one that a later reader can see, rather than a
silent one it has to guess.

**Until then**, the only mitigation available is prose: write `provenance` and
`note` on every emitted file and say in them which pose the move was authored
from. That is documented in `skills/authored-moves.md`.

## Consequences

- One more required field in a format three programs share, and one migration
  branch in the reader. Both are small; the alternative is a class of bug that
  produces a plausible-looking motion and cannot be diagnosed from the artefact.
- `applied(to:at:blend:base:)` losing a parameter is a source-breaking change for
  any caller passing `base:` explicitly. Nothing in this repository does.
- The travel check keeps its meaning under `posesAre == .absolute` and needs a
  different one under `.offsets` — `base[j] + pose[j]` against the range. That is
  a change to `init(validating:times:poses:)` and is part of the work.
- `DuckMove.stepUp` should be re-expressed in one idiom when this lands, rather
  than the mixed absolute/`home +` form it carries now.

**No Swift is changed by this ADR.** It records the defect and the shape of the
fix so that whoever implements it does not have to rediscover which of the two
readings the file meant.
