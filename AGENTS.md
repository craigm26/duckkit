# DuckKit Development Guide for AI Agents

DuckKit is the Pollen Robotics Microduck as a zero-dependency Swift package: the
robot's joint tables, its real trained ONNX policies, its 61-float observation
contract, its wire protocol, its voice, its choreography, its geometry, and the
signing that makes a claim about any of it checkable. This guide is how to build
on it without producing a duck that looks right and walks wrong.

Read it top to bottom the first time. The behaviour rules come first because
almost every mistake this package invites is a *judgement* mistake, not an API
one — the API is small and the compiler catches its misuse.

---

## Agent Behaviour

### Read the source before you write against it

Every public type here carries a doc comment stating what it refuses and why,
and several of them exist to record a bug that already shipped. Those comments
are the specification; the signatures are not. `Sources/DuckKit/DuckObservation.swift`
opens by calling itself "THE HIGHEST-RISK FILE IN THE DUCK FAMILY" and means it —
a wrong index there does not throw, it produces a plausible duck that falls over.

Before writing code that touches a type, read that type's file. It is between 46
and 803 lines and it will tell you the thing you were about to get wrong.

### Never claim more than was measured

This package's whole value is that its numbers are traceable. So:

- **Do not invent a number.** If you cannot point at a file, a fixture or an
  upstream source for a value, say you cannot rather than writing one down.
- **Do not upgrade a recording into a rate.** One clip is one run. Success rates
  come from `DuckIntentSuccess` (16 rollouts per intent under Pollen's own
  randomisation ranges) and from nowhere else. See `skills/upstream-numbers.md`.
- **Do not describe replayed motion as live inference.** `DuckSimulation` runs
  the real network on real observations, and it *cannot walk* — it has no ground.
  The AR ghost replays clips recorded in MuJoCo. Both facts go in the copy.
  See `skills/motion-philosophy.md`.

### Do not add a dependency to DuckKit

`DuckKit`, `DuckVisual` and `DuckRender` link nothing third-party. That is not
minimalism for its own sake: it is what lets `swift test` run the real trained
policy on a Raspberry Pi and get the floats an iPhone gets. Anything needing
crypto goes in `DuckEvidence`, which already has swift-crypto, and reaches back
into DuckKit as an extension (`Sources/DuckEvidence/DuckPolicyFingerprint.swift`
is the pattern). The arrow never points the other way.

If a task seems to need a package inside DuckKit, the answer is either a new
target or a hand-written parser. Both have precedent here: the ONNX reader and
`CanonicalJSONParser` are hand-written for exactly this reason.

### Pick the product before the first import

Four products, and taking the wrong one costs an app 2.4 MB of triangles or a
BoringSSL build it did not need. Decide first, then import.
See `skills/choosing-a-product.md`.

### Two action scales are both correct

`DuckModel.actionScale` is 0.9 — robotd's hardware value. Training and every
`.onnx` file's own metadata say 1.0, and the trajectory recorder uses 1.0.
**Do not reconcile them.** A "fix" in either direction silently changes what a
ghost draws or what a robot does. `Sources/DuckKit/DuckModel.swift:94-106`
states both; `docs/adr/0001-three-loops.md` says which tier each belongs to.

The same rule covers the low-pass filter (`headLowpass` 0.5, `legsLowpass` 0.7):
robotd applies it, training did not, so apply it when modelling the robot and
never in a replay of what a policy did in simulation.

### `homePose` is the robot's rest pose, not every policy's base

Each `.onnx` declares its own `metadata_props.default_joint_pos`. All of
Pollen's declare a pose equal to `DuckModel.homePose`, which is why treating it
as universal went unnoticed for so long — but a community policy need not.
The shipped `headspin.onnx` wants neck_pitch 0.220 and head_pitch 0.680 where
`homePose` has 0.3491 and 0.3491. DuckKit does not currently read that metadata
(`DuckGait.stages` hardcodes `DuckModel.homePose` at
`Sources/DuckKit/DuckGait.swift:137`), so anything replaying a third-party policy
must supply the base itself. See `docs/architecture.md`.

### Prose is British, comments say why, tests are sentences

Match the house style rather than your defaults. Comments explain the failure
they prevent, in prose, and never restate the code. Test names are sentences
(`testAMoveStartsFromTheBasePose`), and they assert the physical or contractual
claim rather than an incidental encoding.

### Build and test before you claim anything

```bash
swift build
SWIFT_BACKTRACE=enable=no swift test
```

343 tests, 0 failures, measured on Linux aarch64 at the time of writing; the
package supports macOS too, and neither run needs hardware, a network or a
device. Report the count you actually saw, on the platform you actually ran. If
a change segfaults after you touched a stored property, that is a stale
incremental build — clean and rebuild before believing it. See
`skills/testing-on-linux.md`.

---

## What DuckKit Is

Four products in one package, deliberately separate.

| Product | Brings | Take it when |
|---|---|---|
| `DuckKit` | nothing | Always. The robot, its policies, its protocol, its voice, its choreography. |
| `DuckVisual` | 2.4 MB of triangles (+0.6 MB rollers) | You draw the robot's actual shape. |
| `DuckRender` | RealityKit (Apple-only; empty module on Linux) | You draw it in AR or RealityKit. |
| `DuckEvidence` | swift-crypto → BoringSSL | You sign, hash-chain or attest something. |

`DuckEvidence` depends on `DuckKit`; nothing depends on `DuckEvidence`. That
direction is what keeps a soundboard app from compiling a TLS library to make a
duck noise. Details and the xcodegen spelling: `skills/choosing-a-product.md`
and `skills/adding-duckkit.md`.

**The package ships no policy weights.** `alpha_walking.onnx` lives under
`Tests/DuckKitTests/Fixtures/duck/` as a test fixture. An app supplies its own
`.onnx` and loads it with `DuckPolicy.load(contentsOf:)`.

---

## The Robot, As Data

Everything below is `Sources/DuckKit/DuckModel.swift`, ported from
`pollen-robotics/microduck`. Do not re-derive any of it from a datasheet.

**15 joints, in this order and no other** — left leg (5), neck/head/mouth (5),
right leg (5):

```
left_hip_yaw  left_hip_roll  left_hip_pitch  left_knee  left_ankle
neck_pitch    head_pitch     head_yaw        head_roll  mouth
right_hip_yaw right_hip_roll right_hip_pitch right_knee right_ankle
```

**The mouth is joint 9 and no policy commands it.** Policies are 14-wide;
`DuckModel.jointOfPolicySlot(_:)` is the single mapping used in both directions,
because getting it wrong shifts every joint after index 9 by one — catastrophic
and completely silent. There is no `DuckBeak` type: the mouth is joint 9,
`DuckKinematics` gives you the `mouth_tip` site, and `DuckPerformance` decides
how far open it is.

**One observation contract, 61 floats, for every policy:**

```
0..3    gyro (trunk frame, rad/s)         34..48  previous action (14)
3..6    projected gravity (unit vector)   48..51  vx, vy, vyaw
6..20   joint position − home pose (14)   51..55  neck/head pitch, yaw, roll
20..34  joint velocity (14)               55..61  body pose block (13 total)
```

Head targets ride **in the command**, and are not added on top of the policy's
output afterwards. Doing both bends the head twice.

**The networks** — `DuckPolicyKind` carries seven; `DuckOfficialPolicies` carries
nine fingerprinted releases (the extra two are the roller policies). Every one is
the same nine-operation graph: `(obs − mean)/std → 61×512 → ELU → 512×256 → ELU
→ 256×128 → ELU → 128×14`, 197,774 learned parameters, about forty microseconds.
See `skills/running-a-policy.md`.

---

## Three Loops

DuckKit sits across a tiered architecture borrowed from
[quackd](https://github.com/rokbenko/quackd): reflexes at 50 Hz, steering at
5–20 Hz, deliberation at 0.2–1 Hz. Where DuckKit's types land — and where our
claim differs from quackd's, because DuckKit *re-implements* the reflex tier in
Swift where quackd never touches it — is `docs/architecture.md`, with the
decision recorded in `docs/adr/0001-three-loops.md`.

The short version an agent needs: **the steering tier is essentially empty in
this package today.** If you are asked to build perception-driven behaviour, you
are building it above DuckKit, not inside it.

---

## Making A Duck Move

Four mechanisms, and choosing wrongly is the most expensive mistake available.

| You want | Use | Notes |
|---|---|---|
| A looping gait for a ghost | `DuckTrajectory` | Recorded in MuJoCo, 15-wide frames, loops and accumulates root motion. |
| A one-shot motion (kick, roll, sit) | `DuckIntentClip` | 17 clips, 14-wide frames, **clamps** rather than wrapping. |
| The network's answer to one state | `DuckSimulation.step` | Real inference. Does not produce a gait — see below. |
| An authored offset on top of a policy | `DuckMove` | Offsets, never a replacement pose. |

`DuckSimulation` closed on itself settles into a fixed point or a 25 Hz
flip-flop, never a walk, and `DuckSimulationTests` pins that so the claim cannot
come back. The reason is in the type's own comment and worth reading before you
write any copy about it. Full decision guidance: `skills/motion-philosophy.md`.
Authoring and importing `.duckmove` files: `skills/authored-moves.md` — and read
`docs/adr/0002-duck-move-carries-its-base.md` first, because the format has a
known ambiguity.

Anything stepping the loop yourself must use `DuckClock`, not the display link.
See `skills/the-50-hz-loop.md`.

---

## Talking To A Robot

`robotd` speaks JSON-RPC 2.0 as newline-delimited JSON. `DuckRPC` is
transport-free: `Data` in, `Message` out, so the framing can be tested on a Pi
against a recorded stream. **Do not write a second decoder** — splitting each
read on newlines and dropping the tail loses roughly one message in seven on a
real network, silently.

| Type | Answers |
|---|---|
| `DuckRPC.StreamDecoder` | Where does one message end? (and refuses to grow past 256 KB) |
| `DuckRPC.Correlator` | Which request is this the answer to? |
| `DuckState` | What is the robot doing? Every field optional, at every depth. |
| `DuckToF` | What can the head see? Three-way status, never collapsed. |
| `DuckSkill` / `DuckPress` | What can be pressed, and what will be refused? |
| `DuckStateReducer` | What did the whole session add up to, reproducibly? |

Every `DuckState` field is optional because a missing block decoded as zeros is
a signed, hash-chained diary saying a duck never fell. See
`skills/talking-to-a-robot.md`.

---

## Sound Is a Performance

`robot.sound` plays one of seven tags through the speaker; it moves nothing.
Something still has to decide that the beak opens on the quack and shuts a beat
before it ends — and that lives in `DuckPerformance` rather than in an app,
because an AR ghost animating one set of curves while the robot is driven by
another set is two ducks with the same name.

Six tags are fire-and-forget. `wheee` is **held**: re-send about every 100 ms, and
robotd's deadman ends it 0.5 s after the last hold. Reimplementing that per app
produces four timers with four different off-by-a-frame bugs, one of which leaves
a non-zero twist commanded and the duck quietly walking away. Use
`DuckPerformance.Playback`.

`DuckVoice` synthesises the audio from arithmetic — no asset, no AVFoundation, no
licence question — and a `Personality` makes each duck a different animal from a
seed. Neither is claimed to match the robot's own bank, which nobody here has
heard. See `skills/voice-and-performance.md`.

---

## Drawing It, and Scanning a Room

`DuckKinematics` places every body and named site from 15 joint angles, in
metres, over the robot's own MuJoCo chain. `DuckVisual` supplies one mesh per
body in that body's local frame, keyed by the same names — so drawing the robot
is "ask where each body is, put that body's mesh there". There is no second
skeleton and no separate rig, on purpose.

Two variants: `.legs` and `.rollers`, the latter swapping six bodies.
`DuckGroundClearance` exists because a build shipped with every recorded motion
floating 116 mm above the floor and only a human looking at a screenshot caught
it. See `skills/drawing-the-duck.md`.

The same geometry runs the other way too: `DuckRoomReduction` turns what a
scanner saw into a floor plus boxes, and `DuckSceneMJCF` writes that as a
deterministic MuJoCo scene — so the duck can be trained in *your* room rather
than Pollen's. The floor is the **lowest** qualifying plane, not the largest,
because picking by area stands the duck on the dining table. See
`skills/rooms-and-scenes.md`.

---

## Attesting Something

Canonical bytes → chain → signature, each with exactly one implementation.
`CanonicalJSON` keeps the `50` / `50.0` distinction that signatures depend on and
that `JSONSerialization` collapses differently on Apple and on Linux.
`DuckChain` is the fold and only the fold — `head₀ = "GENESIS"`,
`headᵢ = sha256(headᵢ₋₁ ‖ canonical(recordᵢ))` — deliberately without
OpenCastor's `Receipt` container, so a phone-minted record cannot wear the shape
of a decision a robot's gateway signed. See `skills/evidence-and-signing.md`.

The claim worth attesting most often is **which network ran**, and its identity
is the parameter fingerprint, never the file digest, never the filename, never
where the file came from — because a re-export under a newer opset is the same
policy and a renamed file is not. `DuckOfficialPolicies` makes "official" a thing
the phone can check offline against nine recorded fingerprints, and its
vocabulary is `released` / `unrecognised` rather than trusted / untrusted:
someone's own training run is a miss, and so is a release newer than this build.
See `skills/policy-provenance.md`.

---

## Files And Formats

| Extension / format | Width | Read/written by |
|---|---|---|
| `.duckmove` (`duck-move/1`) | **15** joints, mouth included | `DuckMoveFile` |
| `.duckintent` (`duck-intent-clips/3`) | **14** joints, mouth excluded | `DuckIntentClip` |
| `duck-trajectories.json` | 15 joints | `DuckTrajectory` |
| `.onnx` | 61 in, 14 out | `DuckPolicy` |
| MJCF (`.xml`) | — | `DuckSceneMJCF` writes; `DuckKinematics` mirrors one |

**The 15/14 split is a live trap.** Narrowing a 15-wide draft to 14 silently
drops the mouth, and widening back inserts `DuckModel.homePose[9]` = 0.0 rad,
which is one seventh open rather than closed. `DuckMove` has a door for each
width; use `init(validatingPolicyPoses:...)` for anything 14-wide.

---

## Testing

`swift test` runs everything, on Linux and macOS, with no hardware. The two
products are tested apart — `DuckKitTests` links `DuckKit` alone — so a
dependency creeping into DuckKit fails the build rather than passing quietly.
The real trained policy runs in the test suite against onnxruntime's own outputs
to 1e-4. See `skills/testing-on-linux.md`.

---

## Skills Reference

Read the file in `skills/` when its trigger fires. They are plain markdown, not
Claude Code skills — no frontmatter, nothing to install.

| Skill | When to use |
|---|---|
| **choosing-a-product.md** | Before the first `import`, or when an app's binary or dependency graph grew unexpectedly |
| **adding-duckkit.md** | Wiring the package into an app, an xcodegen spec, or another Swift package |
| **running-a-policy.md** | Loading an `.onnx`, inspecting one that was refused, or asking what a network is sensitive to |
| **motion-philosophy.md** | Choosing how a duck moves, or before writing any copy that says "the policy is walking" |
| **the-50-hz-loop.md** | Stepping the simulation from a render loop, a timer, or a `CADisplayLink` |
| **authored-moves.md** | Recording, importing, exporting or validating a `.duckmove`, or handling pose data a user or model supplied |
| **policy-provenance.md** | Showing whether a policy is an official release, or recording which network ran |
| **voice-and-performance.md** | Making duck noises, giving ducks distinct voices, or animating a body around a sound |
| **talking-to-a-robot.md** | Anything over the socket: framing, requests, `robot.state`, depth frames, button enablement |
| **drawing-the-duck.md** | Rendering the robot, placing it on a floor, or debugging a duck that floats or sinks |
| **rooms-and-scenes.md** | Turning a scanned room into a MuJoCo scene the duck can be trained in |
| **evidence-and-signing.md** | Signing, hash-chaining, canonical bytes, or the signing key's storage posture |
| **testing-on-linux.md** | Adding tests, running the suite, or diagnosing a failure that only happens on one platform |
| **upstream-numbers.md** | Any time you are about to write down a constant, a rate, or a success percentage |

---

## Quick Reference

**Rates.** Control tick 50 Hz / 20 ms (`DuckModel.tickHz`). Hold re-send 100 ms,
deadman 0.5 s (`DuckSound.holdInterval`, `.holdDeadline`). Audio 48 kHz, exactly
960 samples per tick.

**Scales.** Action scale 0.9 on the robot, 1.0 in sim. Standing, sit/stand,
ground-pick and roulade run at 1.0 on the robot too (`DuckPolicyKind.actionScale`).

**Battery.** 8.2 V full, 6.6 V empty, as the servo bus sees it.

**Skills** (exclusive, one-shot): `ground_pick`, `kick_left`, `kick_right`,
`sit_toggle`, `roulade`.
**Sounds** (not exclusive): `alarm`, `greet`, `inquire`, `peck`, `chirp`, `coo`,
`wheee` — the last is held.

**Methods seen on the wire:** `robot.state`, `robot.health`, `robot.subscribe`,
`tof.frame`.

---

## Provenance

Apache-2.0, matching upstream. `Tests/DuckKitTests/Fixtures/duck/` vendors
`alpha_walking.onnx` and `robot_walk.xml` verbatim from
[pollen-robotics/microduck](https://github.com/pollen-robotics/microduck); the
meshes come from `pollen-robotics/microduck_rl` (see
`Sources/DuckVisual/Resources/PROVENANCE.md`). DuckKit is not affiliated with
Pollen Robotics.
