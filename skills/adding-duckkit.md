# Skill: Adding DuckKit to an App

## When to Use

- Wiring DuckKit into an iOS/macOS app, an xcodegen spec, or another package
- A build fails with "no such module DuckVisual" or "product not found"
- Deciding between a URL dependency and a sibling-path one
- Pinning or bumping the version an app builds against

## Quick Check

URL dependency, by tag, one entry per product you actually use. Never a path
dependency, and never a branch.

---

## Swift Package Manager

```swift
.package(url: "https://github.com/craigm26/duckkit.git", from: "1.0.0")
```

Then, per target, name each product separately:

```swift
.target(
    name: "YourFeature",
    dependencies: [
        .product(name: "DuckKit", package: "duckkit"),
        .product(name: "DuckVisual", package: "duckkit"),   // only if you draw it
    ]
)
```

Platform floor is iOS 17 / macOS 13 (`Package.swift`). Swift tools 5.9.

---

## xcodegen

A package that vends four products needs each one spelled out. This is the
single most common wiring mistake — declaring the package and then importing a
module the target never asked for.

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
        product: DuckVisual    # only if you draw the robot
      - package: DuckKit
        product: DuckRender    # only if you draw it in RealityKit
      - package: DuckKit
        product: DuckEvidence  # only if you sign something
```

Which products you actually need: `skills/choosing-a-product.md`.

---

## By Tag, Not By Path

**Depend on it by tag.** The repo is public, so a URL dependency needs no deploy
key and no credential on a rented build machine — which was the only argument
for a sibling-path dependency, and it no longer holds.

A tag also means an archive built today and one built in six months run the same
policy. That matters more here than in an ordinary library: the numbers in
`DuckModel` and the clips in `Resources/` are what a ghost draws and what a
robot is sent, so "latest main" is a silently moving robot.

| Form | Use it |
|---|---|
| `from: "1.0.0"` | Normal case. Takes the newest compatible tag. |
| `exact: "1.27.0"` | A build whose motion must be bit-identical to a previous one. |
| `branch:` / `.package(path:)` | Only while developing this package itself. |

Ship kit changes through **one consumer build**, not one per tag: tag duckkit as
often as needed, and let the app pick up the latest tag in a single build.

---

## What You Have To Supply

**The policy weights.** The package ships none — `alpha_walking.onnx` under
`Tests/DuckKitTests/Fixtures/duck/` is a test fixture, not a resource. An app
bundles or downloads its own `.onnx` and calls:

```swift
let policy = try DuckPolicy.load(contentsOf: url)
```

which validates at load and refuses with a reason while nothing is moving. See
`skills/running-a-policy.md`.

**Everything else is already in the package.** Recorded trajectories, the 17
intent clips, measured success rates and both meshes ship as resources, reached
through `DuckTrajectory.bundled(_:)`, `DuckIntentClip.bundled()`,
`DuckIntentSuccess.bundled()` and `DuckMesh.bundled(variant:)`.

---

## First Working Code

```swift
import DuckKit

let policy = try DuckPolicy.load(contentsOf: walkingONNX)
var duck = DuckSimulation(walk: policy)

let tick = duck.step(command: DuckCommand(twist: (0.15, 0, 0)))
let sites = DuckKinematics.sitePositions(jointAngles: tick.jointAngles)
// sites["head_camera"] -> where to put the camera, 24 cm up, in metres
```

That runs the real trained network on the real 61-float observation at the
robot's own 50 Hz. It does **not** produce a walking gait — read
`skills/motion-philosophy.md` before you draw anything with it.

---

## Common Mistakes

**Importing `DuckVisual` without adding it.** The error names the module, not
the missing xcodegen entry, so it reads like a package problem. Add the second
`- package:` block.

**Stepping the duck from a `CADisplayLink`.** A 120 Hz panel then walks the duck
140% fast, and nothing crashes. Use `DuckClock` — `skills/the-50-hz-loop.md`.

**Adding `DuckEvidence` for a fingerprint you display but never sign.** You
still need it: `DuckPolicy.fingerprint` is an extension declared in
`Sources/DuckEvidence/DuckPolicyFingerprint.swift`. That is the intended cost,
one import, and the reason `canonicalParameterBytes` is free in `DuckKit`.

**Vendoring a copy of a type instead of importing it.** `DuckSound`'s seven tags
retyped as string literals in a view layer is exactly the rot the enum exists to
stop: `robot.sound` takes a string and answers a typo with silence.

---

## Tips

- Building for Linux (CI, a Pi): `DuckRender` compiles to an empty module, so a
  target may import it unconditionally. `DuckVisual` and `DuckEvidence` both
  build and test there.
- If a consumer needs a number that lives here, import it rather than copying
  it. Every constant in `DuckModel` is public for that reason.
