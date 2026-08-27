# DuckKit

The [Pollen Robotics Microduck](https://github.com/pollen-robotics/microduck), as
pure Swift. Zero dependencies, runs the robot's real trained policies, and tests
on Linux.

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

## What is in here

| | |
|---|---|
| `DuckModel` | Joint names and order, home pose, travel limits, action scale, the trained-in filter coefficients, the battery curve |
| `DuckObservation` | The 61-float contract and the 13-value command block, with every upstream trap preserved |
| `DuckPolicy` | A hand-written ONNX reader and an ELU multilayer perceptron. Loads the real policies, refuses anything else |
| `DuckGait` | Raw policy output to joint targets: scale, low-pass, travel stops that are named rather than silent |
| `DuckKinematics` | Forward kinematics over the robot's MuJoCo chain. Every body and named site, in metres |
| `DuckSimulation` | The 50 Hz loop — observation, policy, targets, observation |
| `DuckSceneMJCF` | A captured room written as a deterministic MuJoCo scene |

## Why it has no dependencies

Everything here is Foundation and arithmetic. That is not minimalism for its own
sake: it is what lets `swift test` run the real policy on a Raspberry Pi and get
the same floats an iPhone will, with no toolchain, no accelerator and no device
in the way.

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

Runs on Linux aarch64 (a Pi 5) and on macOS. 41 tests, no hardware, no network.

## License and provenance

Apache-2.0, matching upstream. `Tests/DuckKitTests/Fixtures/duck/` vendors
`alpha_walking.onnx` and `robot_walk.xml` verbatim from
[pollen-robotics/microduck](https://github.com/pollen-robotics/microduck).
DuckKit is not affiliated with Pollen Robotics.
