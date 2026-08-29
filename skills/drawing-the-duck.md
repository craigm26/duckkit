# Skill: Drawing the Duck

## When to Use

- Rendering the robot, in AR or anywhere else
- Placing a ghost on a real floor, or on a scanned plane
- The duck floats, sinks, lies on its side, or is the wrong size
- Adding a variant, a wheel, or a second AR screen

## Quick Check

There is one skeleton: `DuckKinematics`. Ask it where each body is, put that
body's mesh there. If you are writing a second transform chain, stop.

---

## Kinematics Is the Only Rig

`DuckKinematics.bodies` is the robot's own MuJoCo chain (`robot_walk.xml`),
vendored under `Tests/DuckKitTests/Fixtures/duck/` and **re-derived from that
file by `DuckKinematicsTests`**, so the hardcoded table cannot drift from
upstream without a test going red. Positions are metres, orientations are
(w, x, y, z) quaternions in the parent's frame, and every hinge rotates about its
body-local Z.

```swift
let poses = DuckKinematics.bodyPoses(jointAngles: angles)      // [String: Pose]
let sites = DuckKinematics.sitePositions(jointAngles: angles)  // [String: DuckVector]
// sites["head_camera"] — where to put the camera, 24 cm up, in metres
```

At the home pose the feet land directly under the trunk (x ≈ 0.00002 m). That is
the upstream authors' claim that the home pose puts the centre of mass over the
ankle axis, reproduced here as arithmetic and pinned as a test.

The maths carries its own `DuckVector` and `DuckQuaternion` because `simd` does
not exist on Linux and the whole computation is fifteen quaternion multiplies.

---

## Meshes

`DuckVisual.DuckMesh` gives one `Body` per part **in that body's local frame**,
keyed by the names `DuckKinematics.bodies` uses. Flat `[Float]` buffers, because
every renderer worth using takes one and because flat arrays are checkable under
`swift test`.

```swift
let bodies = try DuckMesh.bundled(variant: .legs)   // or .rollers
for body in bodies {
    place(body, at: poses[body.name]!)
}
```

Geometry is Pollen Robotics' own, from the Apache-2.0 `microduck_rl`; see
`Sources/DuckVisual/Resources/PROVENANCE.md` for why that source and not the
visually identical one in their Hugging Face Space.

---

## Placing It on a Floor

The entity's internal trunk sits at `DuckKinematics.trunkOriginInModelFrame`
(0, 0, 0.12) with identity orientation. To move that point onto a root position
under a rotation:

```swift
let (p, q) = DuckKinematics.placement(forRoot: root.position,
                                      orientation: root.orientation)
```

**The rotation matters.** A duck mid-roulade is upside down, and subtracting an
unrotated 120 mm would push it through the floor exactly when it is most obvious.
Placing straight from the root instead floats the duck by the trunk height —
`GroundContactTests` pins both behaviours.

---

## Ground Clearance, and the Bug It Exists For

Duck Studio shipped a build in which **every recorded motion played with the
robot floating 116 mm above the floor**, and it took a person looking at a
screenshot to notice. The tests were blind to it because they all asked about
*poses*, and a pose is correct in whichever frame you assume. The question nobody
could ask in code was the one the eye asks immediately: is it standing on the
floor?

```swift
let clearance = try DuckGroundClearance.bundled()
let metres = clearance.clearance(jointAngles: angles, root: root)
DuckGroundClearance.summary(clearanceMetres: metres)   // the sentence to show
DuckGroundClearance.isWrong(clearanceMetres: metres)   // true above +5 mm
```

The eight named sites, for anything that needs a sensor or a beak tip:
`imu`, `imu_bno`, `head_imu`, `head_camera`, `tof`, `mouth_tip`, `left_foot`,
`right_foot`.

**Floating is wrong; sinking is the meshes.** Seven of the fifteen drawn parts
have no collision shape, so they are drawn and cannot touch anything — a duck
lying down rests on the parts that collide while a thigh or the neck passes
through. Use `summary(_:)` rather than writing your own sentence; the first
version of that string blamed "simplified collision shapes", which was wrong, and
colouring a sinking value as a fault taught readers that a correct render was
broken.

It is sampled, and the error is **measured rather than assumed**: 45,348 vertices
at 50 Hz is not free, so it keeps a stride of up to 400 points per body **union**
the 16 most extreme vertices per direction — the ones that can become the lowest
under some rotation, which a uniform stride can miss.
`DuckGroundClearanceTests` compares this against the exact minimum over every
vertex of every frame in the corpus and asserts the gap.

---

## Variants

Pollen ship two robot descriptions from the same CAD. Everything above the ankles
is identical, so `.rollers` is a **substitution of six bodies**, not a second
robot: two roller blades and four passive wheels replacing `ankle_left` and
`ankle_right`.

```swift
DuckKinematics.bodies(for: .rollers)
DuckKinematics.bodyNames(onlyIn: .rollers)     // what a renderer must swap
DuckKinematics.bodyPoses(jointAngles:variant:wheelSpin:)
```

**The wheels are passive and not in the 15-wide pose.** A renderer rolls them
from distance covered, via `wheelSpin` (radians, positive for forward travel).

Every clip declares which feet it wore: `DuckIntentClip.variant`, and
`DuckTrajectory.Clip.variant` derived from the `skate` prefix. Rendering a rollers
clip on leg meshes is a duck skating on its ankles.

---

## In RealityKit

`DuckRender.DuckGhostEntity` is the shared one, and it exists so there is not a
second place to get the coordinate conversion wrong — an error that looks like a
duck lying on its side rather than like a bug.

```swift
let ghost = DuckGhostEntity(variant: .legs)
ghost.place(root: clip.pose(at: t).root, jointAngles: pose.jointAngles)
ghost.apply(jointAngles: angles, wheelSpin: rolled)
```

It holds no skeleton: it asks `DuckKinematics.bodyPoses` and puts each mesh
there. Meshes are cached once per process and per variant, because decoding a few
megabytes of triangles twice for two screens is waste. `DuckGhostEntity.rk(_:)`
converts `DuckVector` / `DuckQuaternion` to `SIMD3<Float>` / `simd_quatf` — use
it rather than writing the conversion inline.

Entirely inside `#if canImport(RealityKit)`, so it compiles to nothing on Linux.

---

## Common Mistakes

**Building a second transform chain.** The thing that decides where a foot is
must stay the only thing that decides it. That is why there is no rig and no
second skeleton.

**Scaling to taste.** The model is 1:1 in metres. A 25 cm duck on a real floor
with the camera site 24 cm up is what the model says, not what an artist
eyeballed.

**Testing the renderer only on a device.** `GroundContactTests` and
`DuckMeshTests` run on a Pi. Any geometry claim can be asserted there; put it
there.

**Ignoring `hasFinished` and drawing past a clip's end.** A one-shot clamps, so
you get a duck standing where the motion left it — which is right, but the app
usually wants to know.
