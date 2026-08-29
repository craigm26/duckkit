# Skill: Choosing a Product

## When to Use

- Before writing the first `import` in an app that uses DuckKit
- A user asks "which one do I need?" or "why is my app 3 MB bigger?"
- An app's build suddenly compiles BoringSSL and nobody knows why
- Adding a new target to this package, and deciding where a type belongs

## Quick Check

Take `DuckKit`. Add another product only when you can name the thing it does
that DuckKit cannot: **draw** the robot (`DuckVisual`), draw it **in AR**
(`DuckRender`), or **attest** something (`DuckEvidence`).

---

## The Four Products

| Product | Depends on | Costs the app | Take it when |
|---|---|---|---|
| `DuckKit` | nothing | nothing | Always |
| `DuckVisual` | `DuckKit` | 2.4 MB legs + 0.6 MB rollers | You draw the robot's real shape |
| `DuckRender` | `DuckKit`, `DuckVisual` | RealityKit (Apple only) | You put it in a RealityKit scene |
| `DuckEvidence` | `DuckKit`, swift-crypto | BoringSSL | You sign or hash-chain something |

The declarations, with their reasoning, are in `Package.swift`.

---

## What Is In Each

**`DuckKit`** — the robot as data and arithmetic. Joint tables, the 61-float
observation, a hand-written ONNX reader and MLP, the 50 Hz gait pipeline,
forward kinematics, the JSON-RPC framing, `robot.state`, the depth sensor, the
seven sounds and their synthesis, the choreography, the recorded clips, the
authored-move format, MJCF scene writing. Everything is Foundation and
arithmetic.

**`DuckVisual`** — `DuckMesh` (one mesh per body, in that body's local frame,
keyed by `DuckKinematics.bodies` names) and `DuckGroundClearance` (how far off
the floor the robot is *as drawn*). Flat `[Float]` buffers, not `simd`, so the
geometry is checkable under `swift test` on Linux.

**`DuckRender`** — `DuckGhostEntity`, a RealityKit `Entity` that owns no
skeleton of its own: it asks `DuckKinematics` where each body is and puts that
body's mesh there. Entirely inside `#if canImport(RealityKit)`, so on Linux it
compiles to an empty module and the Pi test run is unaffected.

**`DuckEvidence`** — `CanonicalJSON` and its parser, `DuckChain` (the fold, and
only the fold), `DuckSigning` (Ed25519 over canonical bytes), `SigningKeyStore`,
`DuckSoccerMatch`, `DuckPolicy.fingerprint`, and `DuckOfficialPolicies`.

---

## The Dependency Arrow

```
DuckEvidence ──► DuckKit ◄── DuckVisual ◄── DuckRender
     │                                   
     └──► swift-crypto ──► BoringSSL     
```

`DuckEvidence` sees `DuckKit`, because it attests things DuckKit describes — a
policy's parameters, a match, a room. **`DuckKit` must never see `DuckEvidence`.**
That direction is the whole reason a soundboard app does not compile a TLS
library to make a duck noise, and it is why the real trained policy runs under
`swift test` on a Raspberry Pi with no toolchain.

Taking `DuckKit` from `DuckEvidence` costs nothing third-party: DuckKit has no
dependencies to inherit.

---

## Where a New Type Belongs

Ask what it needs, not what it is about.

| The type needs… | It goes in |
|---|---|
| Only Foundation and arithmetic | `DuckKit` |
| Vertex data | `DuckVisual` |
| RealityKit, ARKit, UIKit | `DuckRender`, or the app |
| A hash, a signature, a key | `DuckEvidence` |

The pattern for "a DuckKit thing that must be hashed" is already in the repo:
`DuckPolicy` produces `canonicalParameterBytes` (a fixed little-endian byte
order — robot truth, beside the parser that read it) and
`Sources/DuckEvidence/DuckPolicyFingerprint.swift` extends `DuckPolicy` to turn
those bytes into a digest. Copy that shape rather than moving the type.

---

## Common Mistakes

**Taking `DuckVisual` for a policy inspector.** A screen that shows layer widths
and a Jacobian does not draw a duck. It needs `DuckKit` alone.

**Taking `DuckEvidence` "just in case".** Nothing is signed until something is
signed. Add it in the commit that adds the signature, not before.

**Putting the mesh loader in the app.** `DuckMesh.bundled()` is a resource read
plus a decode. In the app it can only be exercised by a person holding a phone;
in `DuckVisual` it runs under `swift test` on a Pi, which is where the
"floating 116 mm" bug would have been caught.

**Expecting policy weights in the package.** There are none.
`alpha_walking.onnx` is a *test fixture* at
`Tests/DuckKitTests/Fixtures/duck/alpha_walking.onnx`. An app ships or downloads
its own and calls `DuckPolicy.load(contentsOf:)`.

**Assuming `DuckRender` works on Linux.** It compiles there — as nothing. Any
Linux-side test of ghost behaviour has to be written against `DuckKinematics`
and `DuckVisual`, which is why `GroundContactTests` lives in `DuckVisualTests`.

---

## Tips

- If a user reports a surprising binary size, ask which products their target
  lists. In xcodegen each product is a separate `dependencies` entry — see
  `skills/adding-duckkit.md`.
- `DuckKitTests` links `DuckKit` alone, deliberately. If you add a dependency to
  DuckKit, that target stops building. That is the alarm working.
