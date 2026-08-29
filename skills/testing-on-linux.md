# Skill: Testing on Linux

## When to Use

- Running the suite, or reporting whether it passed
- Adding a test, and deciding which target it belongs in
- A failure that only happens on one platform
- A crash immediately after changing a stored property

## Quick Check

```bash
SWIFT_BACKTRACE=enable=no swift test
```

343 tests across 40 classes, no hardware, no network, no device. Gate on the
**exit code**, not on the last `Executed …` line you happened to see.

---

## Why It Runs on a Pi at All

Everything in `DuckKit` is Foundation and arithmetic. That is not minimalism for
its own sake: it is what lets `swift test` run the real trained policy on a
Raspberry Pi and get the same floats an iPhone will, with no toolchain, no
accelerator and no device in the way.

Two consequences you will meet:

- `DuckPolicy` parses the ONNX protobuf by hand, because onnxruntime is a
  hundred-megabyte answer to a nine-operation question and Core ML does not run
  under `swift test`.
- `DuckKinematics` carries its own quaternion type, because `simd` does not exist
  on Linux and the whole computation is fifteen multiplies.

`DuckEvidence` uses swift-crypto rather than CryptoKit for exactly the same
reason: the signer under `swift test` on the Pi is the signer on the phone.

---

## Which Target

| Target | Links | Put a test here when |
|---|---|---|
| `DuckKitTests` | `DuckKit` **alone** | It is about the robot, the protocol, the voice, the clips |
| `DuckEvidenceTests` | `DuckEvidence` + `DuckKit` | It is about bytes, chains, signatures, fingerprints |
| `DuckVisualTests` | `DuckVisual` | It is about geometry, meshes, or where the duck is drawn |

**`DuckKitTests` links `DuckKit` alone on purpose.** A dependency creeping into
DuckKit fails the build rather than passing quietly. That is the alarm working;
do not "fix" it by adding the dependency to the test target.

There is no `DuckRenderTests`: `DuckRender` is inside
`#if canImport(RealityKit)` and compiles to an empty module on Linux. Anything
about ghost geometry is therefore written against `DuckKinematics` and
`DuckVisual` — which is exactly why `GroundContactTests` lives in
`DuckVisualTests`.

---

## The Fixtures Are the Argument

`Tests/DuckKitTests/Fixtures/duck/` holds four files, vendored under Apache-2.0:

| File | Proves |
|---|---|
| `alpha_walking.onnx` | The forward pass runs the network the robot runs |
| `golden_policies.json` | observation→action pairs from onnxruntime 1.29.0, matched to 1e-4 |
| `robot_walk.xml` | Pollen's MuJoCo model, so the joint tables cannot drift |
| `duck_chain.json` | The kinematic tree extracted mechanically from that XML |

The point of vendoring the **real** network rather than a synthetic one: only
the real weights can show that this runs what the robot runs.
`DuckKinematicsTests` and `DuckModelTests` re-derive the hardcoded tables from
the MJCF, so an upstream change shows up as a red test rather than as a duck that
walks slightly wrong.

Reach them with `Bundle.module.url(forResource:withExtension:subdirectory:)` and
`subdirectory: "Fixtures/duck"`.

---

## How to Write One

Test names are sentences, and they assert the **physical or contractual claim**,
not an incidental encoding:

```swift
func testAMoveStartsFromTheBasePose()
func testTheSearchChoseToStandIntoTheStepAndToPullUpAtTheEnd()
func testTheRollersVariantSwapsExactlyTheAnkleBodies()
```

A few patterns already in the repo worth reusing:

- **Assert against a second implementation, not a golden copy.**
  `DuckPersonalityTests` pins the RNG stream, the CRC-32 of all seven tags and
  every trait of seed 1 against values computed by an independent implementation
  of the same spec — because a golden value copied out of the code under test
  only proves the code has not changed.
- **Pin render-against-render where the platform can differ.** `DuckVoice` uses
  `sin` from libm, so two *platforms* can differ in the last bit. Determinism
  here means "the same machine gives the same answer forever", and
  `DuckVoiceTests` pins that rather than a constant that would be a lie on one of
  the two supported OSes.
- **Assert the claim you cannot see.** `DuckGroundClearanceTests` compares the
  sampled minimum against the exact minimum over every vertex of every frame,
  and asserts the gap — the number the eye would have caught and no pose test
  could.
- **Construction preconditions are not catchable in-process.** Where a type
  traps, assert the guarantee on a shipped value instead (`DuckMoveTests` checks
  `stepUp`'s times are sorted and unique rather than trying to build a bad move).

---

## Known Quirks

**`ZZExport` writes outside the repo.** `Tests/DuckKitTests/ZZExport.swift`
exports DuckKit's verified constants to
`/home/craigm26/projects/duck-sounds/sim/duckkit-constants.json` so the web
simulator uses the same numbers rather than a retyped copy. It is named `ZZ` so
it sorts last. On any machine without that directory it will fail — that is a
path assumption, not a defect in the code under test, and it is not evidence that
your change broke anything.

**A segfault right after a stored-property change is a stale build.** Signal 11
after adding or reordering a stored property means an incremental build that no
longer matches. Clean and rebuild before believing anything:

```bash
rm -rf .build && SWIFT_BACKTRACE=enable=no swift test
```

**`DuckGait.Alphas.trained` is deprecated**, renamed to `.robotd`. The old name
encoded a claim ("what the policies were trained against") that turned out to be
false. It is kept so nothing breaks; do not introduce new uses.

---

## Reporting a Run

Say the real number. "343 tests, 0 failures, on Linux aarch64" is a report;
"tests pass" is not. If something fails, name it and say whether you fixed it.
Never claim green on a run you did not see finish — the suite takes about
45 seconds and the exit code is the only thing that settles it.
