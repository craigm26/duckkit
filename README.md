# DuckKit

The [Pollen Robotics Microduck](https://github.com/pollen-robotics/microduck), as
pure Swift. Runs the robot's real trained policies, and tests on Linux.

Two products. **DuckKit** has zero dependencies — the robot, its policies, its
protocol, its voice and its choreography. **DuckEvidence** takes swift-crypto and
is the part that signs things. An app that just wants a walking duck does not
link BoringSSL to get one.

```swift
let policy = try DuckPolicy.load(contentsOf: walkingONNX)
var duck = DuckSimulation(walk: policy)

let tick = duck.step(command: DuckCommand(twist: (0.15, 0, 0)))
let sites = DuckKinematics.sitePositions(jointAngles: tick.jointAngles)
// sites["head_camera"] -> where to put the camera, 24 cm up, in metres
```

That is the actual `alpha_walking.onnx` from Pollen's repo, running the actual
61-float observation the robot's own daemon feeds it, at the robot's own 50 Hz.
Not an animation of a duck walking — the trained network walking.

## Using it

```swift
.package(url: "https://github.com/craigm26/duckkit.git", from: "1.0.0")
```

Then take the product you actually need — they are separate for a reason:

| You want | Depend on | Brings |
|---|---|---|
| A walking duck, a voice, choreography, the protocol | `DuckKit` | nothing |
| To sign, hash-chain, or attest something | `DuckEvidence` | swift-crypto → BoringSSL |

In xcodegen, a package that vends two products needs both spelled out:

```yaml
packages:
  DuckKit:
    url: https://github.com/craigm26/duckkit.git
    from: 1.0.0
targets:
  YourApp:
    dependencies:
      - package: DuckKit
        product: DuckKit
      - package: DuckKit
        product: DuckEvidence   # only if you sign something
```

**Depend on it by tag, not by path.** This repo is public, so a URL dependency
needs no deploy key and no credential on a rented build machine — which was the
only argument for a sibling-path dependency, and it no longer holds. A tag also
means an archive built today and one built in six months run the same policy.

Two things that are *not* in here, deliberately. There is no `Journal`:
OpenCastor's journal chains over a `Receipt`, which is a decision a robot's
gateway actually signed, and letting a phone-minted diary entry wear that shape
would be a lie about what happened. `DuckChain` moves the fold and leaves the
ledger behind, and each consumer keeps its own namespace. And there is no
`DuckBeak` type: the mouth is joint 9 in `DuckModel`, `DuckKinematics` gives you
the `mouth_tip` site, and `DuckPerformance` decides how far open it is — three
types that already exist, rather than a fourth that wraps them.

## What is in here

### DuckKit — the robot

| | |
|---|---|
| `DuckModel` | Joint names and order, home pose, travel limits, action scale, the trained-in filter coefficients, the battery curve |
| `DuckObservation` | The 61-float contract and the 13-value command block, with every upstream trap preserved |
| `DuckPolicy` | A hand-written ONNX reader and an ELU multilayer perceptron. Loads the real policies, refuses anything else. Describes and differentiates them too, and serializes its parameters in one fixed order so they can be identified |
| `DuckGait` | Raw policy output to joint targets: scale, low-pass, travel stops that are named rather than silent |
| `DuckKinematics` | Forward kinematics over the robot's MuJoCo chain. Every body and named site, in metres |
| `DuckSimulation` | The 50 Hz loop — observation, policy, targets, observation |
| `DuckSceneMJCF` | A captured room written as a deterministic MuJoCo scene |
| `DuckRoomReduction` | What a scanner saw, reduced to that room. Y-up to Z-up, and the floor is the lowest surface rather than the largest |
| `DuckClock` | A fixed 50 Hz accumulator with a catch-up clamp, so the gait does not run at the panel's refresh rate |
| `DuckRPC` | JSON-RPC 2.0 over NDJSON, with no transport underneath it. The framing is the hard part |
| `DuckState` | The `robot.state` notification, decoded. Every field optional, because a missing block must never read as a zero |
| `DuckStateReducer` | The stream reduced to cumulative integers — distance, falls, time upright — in micrometres, reproducibly |
| `DuckSkill` | The five skills and the twelve presses, including what `robotd` refuses and why |
| `DuckSound` | The seven wire tags, the one held tag, and the arithmetic of the hold protocol |
| `DuckVoice` | Duck calls synthesized from arithmetic — no asset, no AVFoundation, no license question |
| `DuckVoice.Personality` | What makes *this* duck sound like a different creature from that one. Ported from the robot's own seeded synth |
| `DuckPerformance` | What the body does while it makes a noise. One set of curves, so the ghost and the robot are the same animal |

### DuckEvidence — the part that signs

| | |
|---|---|
| `CanonicalJSON` | A JSON value model that keeps the int/float distinction canonical bytes depend on, identically on Linux and Apple |
| `DuckChain` | The fold, and only the fold: `head₀ = "GENESIS"`, `headᵢ = sha256(headᵢ₋₁ ‖ canonical(recordᵢ))` |
| `DuckSigning` | Ed25519 over canonical bytes — sign, verify, `kid(for:)` |
| `SigningKeyStore` | Keychain on device, in-memory on Linux, with the device-local invariant assertable under `swift test` |
| `DuckSoccerMatch` | A match as an append-only, hash-chained, signed record — a league table nobody can quietly edit |
| `DuckPolicy.fingerprint` | Which policy actually ran: SHA-256 over the parameters, not the file |

## Every duck sounds like itself

The Microduck's voice is not a set of WAV files — there are none to vendor. It
is a seedable synth: one integer derives a personality (register, harmonic tilt,
nasality, vibrato, quackiness, tempo) and the robot seeds itself from its own
SoC serial, so two Microducks on the same table sound like two animals.

DuckKit does the same thing, from a port of upstream's derivation:

```swift
let duck = DuckVoice.Personality(identifier: robotSerial)   // or (seed: 42)
let quack = DuckVoice.render(.chirp, part: .whole, seed: 1, as: duck)
```

`render(_:part:seed:)` without a personality still renders the tables as
written, unchanged. Adding one bends them: the same tag stays recognisably that
tag, and the animal underneath it changes.

What is ported is the *derivation* — the generator (xoshiro256++ through
splitmix64), the draw order, the trait ranges, the harmonic weighting, and the
CRC-32 variant hash. Upstream's own note explains why that has to be exact:
a robot's sound bank is re-rendered from its seed on every install, so **the
generator is the voice**, and a change to the arithmetic re-voices the fleet
silently. `DuckPersonalityTests` pins the stream, the CRC-32 of all seven tags,
every trait of seed 1 and its harmonic weights against values computed by a
*second, independent implementation* of the same spec — because a golden value
copied out of the code under test only proves the code has not changed.

What is **not** ported, and not claimed: byte-parity with a real robot's audio.
The recipes that turn traits into samples are upstream's; DuckVoice's own
oscillator stack renders them, and how it consumes each trait is ours. So the
traits for a seed match and the couplings are ours. Nothing has been checked
against a real bank, because no robot exists to check against yet.

One invariant survives all of it: **a personality never changes a length.**
Every buffer stays a whole number of 50 Hz control ticks, because
`DuckPerformance` choreographs against those counts and a duck that stretched
its own audio would slide out of its own gestures.

## Why DuckKit has no dependencies

Everything in DuckKit is Foundation and arithmetic. That is not minimalism for
its own sake: it is what lets `swift test` run the real policy on a Raspberry Pi
and get the same floats an iPhone will, with no toolchain, no accelerator and no
device in the way.

Two decisions follow from it. `DuckPolicy` parses the ONNX protobuf by hand
rather than taking onnxruntime, because every shipped alpha policy is the same
nine-operation graph —

```
obs[1,61] → (obs − mean)/std → 61×512 → ELU → 512×256 → ELU → 256×128 → ELU → 128×14
```

— about two hundred thousand parameters and forty microseconds of work.
onnxruntime is a hundred-megabyte answer to that question, and Core ML does not
run under `swift test`. And `DuckKinematics` carries its own quaternion type
because `simd` does not exist on Linux, and the whole computation is fifteen
multiplies.

`DuckPolicy` validates at load, never at inference — a file with the wrong op
sequence, a transposed weight or an unexpected width is refused while nothing is
moving, which is the rule the robot's own runtime follows.

It is also why signing lives next door rather than here. Ed25519 needs
swift-crypto, swift-crypto brings BoringSSL, and a soundboard should not compile
a TLS library to make a duck noise. So `DuckEvidence` is a separate product with
that one dependency, and anything in DuckKit that wants to be attested — the
policy weight fingerprint, for instance — is reached from there as an extension.
The cost is one extra import for the apps that sign, and nothing at all for the
apps that do not.

`DuckEvidence` uses swift-crypto rather than CryptoKit for the same reason
DuckKit uses no packages: the same `Curve25519.Signing` API compiles on Linux, so
the signer under `swift test` on the Pi is the signer on the phone.

## The numbers are not ours

Joint order, home pose, action scaling and the filter coefficients are ported
from the robot's runtime (`duck-control`, `robotd`), where they were measured
against hardware and trained into the policies. Re-deriving them from a
datasheet is the kind of change that looks right and walks wrong.

The kinematic chain is that repo's own MuJoCo model, vendored as a fixture, and
`DuckKinematicsTests` re-derives the tables from it — so the hardcoded values
cannot drift from upstream without a test going red. `DuckPolicyTests` proves the
forward pass against onnxruntime's own output over the vendored network: same
weights, same bytes in, same floats out to 1e-4.

## Testing

```bash
swift test
```

Runs on Linux aarch64 (a Pi 5) and on macOS. 248 tests, no hardware, no network,
no device — including the real trained policy, the synthesized voice, and the
signing.

The two products are tested apart, `DuckKitTests` against `DuckKit` alone, so a
dependency creeping into DuckKit fails the build rather than passing quietly.
`DuckEvidence` does depend on `DuckKit` — it attests things DuckKit describes, so
it has to see them — and that direction costs nothing, because DuckKit brings
nothing with it. The arrow never points the other way.

## License and provenance

Apache-2.0, matching upstream. `Tests/DuckKitTests/Fixtures/duck/` vendors
`alpha_walking.onnx` and `robot_walk.xml` verbatim from
[pollen-robotics/microduck](https://github.com/pollen-robotics/microduck).
DuckKit is not affiliated with Pollen Robotics.
