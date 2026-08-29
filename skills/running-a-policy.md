# Skill: Running a Policy

## When to Use

- Loading an `.onnx` and running inference
- A file was refused and the user wants to know what was actually in it
- Building an observation editor, a policy inspector, or a sensitivity view
- Comparing two checkpoints, or asking "why did the duck do that?"

## Quick Check

`DuckPolicy.load` validates everything and can only fail loudly; `infer` cannot
fail at all. If you are writing a `try` around inference, you have the wrong
function.

---

## The One Architecture

Every shipped alpha policy is the same nine-operation graph:

```
(obs − mean)/std → 61×512 → ELU → 512×256 → ELU → 256×128 → ELU → 128×14
```

197,774 learned weights and biases, about forty microseconds a pass. That is why
`Sources/DuckKit/DuckPolicy.swift` hand-writes a protobuf reader instead of
taking onnxruntime: a hundred-megabyte answer to a nine-operation question, and
Core ML cannot run under `swift test` on a Pi.

`Description.parameterCount` reports 197,896 for the same file — the extra
2 × 61 are the normalizer's mean and std, which PyTorch would call buffers.

---

## Load, Then Infer

```swift
let policy = try DuckPolicy.load(contentsOf: url)

let observation = DuckObservation.build(
    gyro: gyro, gravity: gravity,
    jointPositions: positions, jointVelocities: velocities,
    lastAction: previousRawAction,      // 14-wide, BEFORE action scaling
    command: command)

let action = policy.infer(observation)  // 14 raw floats
```

**Everything is validated at load, never at inference** — the robot's own
runtime's rule. A wrong op sequence, a transposed weight, an unexpected width or
a zero in the normalizer's std is refused while nothing is moving, not sixty
ticks later mid-stride.

| `LoadError` | Means |
|---|---|
| `.malformed(String)` | Not walkable protobuf, truncated, or an initializer the graph references is absent |
| `.unsupportedArchitecture(String)` | Parsed fine, wrong network — carries what was found |
| `.shape(String)` | A tensor width disagrees with the 61→512→256→128→14 contract |

---

## Showing Someone Why It Was Refused

A refusal is only half an answer. `describe` reads any walkable ONNX file and
refuses to judge it, so the same read of the same bytes produces both the
sentence and the dump beside it.

```swift
let structure = try DuckPolicy.describe(contentsOf: url)
structure.ops             // ["Sub","Div","Gemm","Relu",...] — Relu, not Elu
structure.initializers    // name, dims as declared, element count
structure.inputs          // a duck policy declares exactly one: "obs"
structure.outputs         // and one: "actions"
structure.parameterCount
```

`load` is built as `describe`-then-validate, so the two cannot disagree.
Things `describe` will happily show you and `load` will refuse: a Relu export,
a 48-wide first weight (trained without the command block), an input tensor
named `observations`, a `Gemm` without `transB=1`.

A first-layer weight reads `[512, 61]`, not `[61, 512]` — that is the ONNX
`transB=1` convention, and a transposed export is visible in `dims` before it is
a refusal.

---

## Opening the Forward Pass

| Want | Call | Cost |
|---|---|---|
| The action | `infer(_:)` | ~40 µs |
| The normalized input and three hidden layers | `inferTrace(_:)` | three array retains |
| ∂action/∂normalized-observation, 14×61 | `jacobian(at:)` | ~14 forward passes |
| The trained statistics | `normalization` | free |
| Layer widths, parameter count | `layerWidths`, `parameterCount` | free |

`inferTrace(o).actions` equals `infer(o)` **bit for bit** — one function runs
both, and the only difference is whether the activations are retained on the way
out.

The Jacobian is analytic (reverse mode through the ELU stack) rather than finite
difference, because there is no ε to choose: on the vendored walking policy the
trained std runs from 0.0129 on the unbound body axes to 3.03 on a joint
velocity, a 235× spread. One raw-space ε of 0.01 is 0.8 σ in one slot and 0.003 σ
in another — one straddles the ELU kink and averages two slopes, the other
vanishes into float32 cancellation, and neither announces itself.

The derivative is with respect to the **normalized** input. Divide column *j* by
`normalization.std[j]` for sensitivity in raw physical units.

---

## Reading the Numbers Honestly

**Dead units are normal.** An ELU unit at or below zero is in the exponential
regime, floored at −1. On the vendored walking policy an ordinary standing
observation leaves roughly 250 of 512, 225 of 256 and 105 of 128 down there.
Report it as a count, not as a fault.

**`(value − mean) / std` is the only scale on which the 61 slots compare.** Slot
27 is rad/s, slot 3 is a dimensionless gravity component. "4.2 training standard
deviations out of distribution on slot 27" is the useful sentence.

**`DuckObservation.zeroed` is not a robot state.** It sits 32 σ off the training
mean on slot 5 — projected gravity z, mean −0.995, std 0.031 — because an
all-zero gravity vector describes a robot in free fall. It exists only to pay a
first-call cost off the hot path, with its output discarded.

---

## Common Mistakes

**Treating a policy as a function.** It is a dynamical system: slots 34…48 are
the *previous* action, and joint positions and velocities are last tick's
targets and their difference. Two ducks given the same command from different
histories do different things, permanently and legitimately. Questions worth
asking are about trajectories from the *same* starting condition — which is why
`DuckSimulation.State` is public and writable.

**Feeding back the scaled action.** `lastAction` is the raw 14 floats `infer`
returned, before `DuckGait` multiplies by the action scale.

**Assuming `homePose` is the policy's base.** Every `.onnx` declares its own
`metadata_props.default_joint_pos`, and DuckKit does not currently read it. See
`skills/upstream-numbers.md` and `docs/architecture.md`.

**Hashing the file to identify a policy.** Two exports of the same learned map
differ in producer string, opset and node order. Use
`skills/policy-provenance.md`.
