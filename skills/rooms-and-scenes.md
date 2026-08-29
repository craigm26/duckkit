# Skill: Rooms and Scenes

## When to Use

- Turning a room a phone scanned into something the duck can be trained in
- Writing MJCF from an app
- A user asks "can I train the duck on my own stairs?"
- Two scans of the same room produce different files

## Quick Check

`DuckRoomReduction.reduce(planes:)` → `DuckSceneMJCF.Capture` →
`DuckSceneMJCF.scene(from:)`. Two steps, both pure arithmetic, both testable on
a Pi.

---

## The Inversion Is the Point

The sandbox everyone gets trains policies in Pollen's rooms. This writes
**yours**: the phone's LiDAR reduces a room to a floor plus boxes — couch, table
legs, the step that will actually defeat the robot — and the output is an MJCF
file whose numbers are true to your house at 1:1, ready to drop next to
`robot_walk.xml` in the upstream training setup or the Hugging Face sandbox.

The emitted scene `<include>`s `robot_walk.xml` rather than inlining the duck,
which keeps the robot's numbers upstream's problem and this file's numbers the
room's.

---

## Step One: Reduce

```swift
let capture = try DuckRoomReduction.reduce(planes: scanned)
```

The input is deliberately **not** an ARKit type. `ScannedPlane` is six floats and
a flag, so nothing here needs a session, a device, or an Apple framework — and
the same reduction serves ARKit plane anchors today, a RealityKit mesh's bounding
boxes or somebody's ROS point cloud later.

**Coordinates convert once, here.** Scanners overwhelmingly report Y-up (ARKit,
Unity, glTF); MuJoCo is Z-up. The conversion is (x, y, z) → (x, −z, y), a −90°
rotation about X, so handedness is preserved and there is no mirroring to undo.

### The floor is the lowest qualifying plane, not the largest

A dining table easily presents more area to a scanner than the strip of carpet
visible around it. Picking by area stands the duck **on the table** and files the
floor as an obstacle — a scene that looks plausible and is upside down. Lowest
wins; everything above it is furniture.

If nothing clears `minimumFloorArea` (0.5 m², about the smallest patch of carpet
a person would still call "the floor") the area rule is dropped rather than the
whole scan: a scanner that has seen only one small patch has still seen the
floor, and refusing there fails exactly when a person is pointing the phone at
their feet waiting for something to happen.

`Failure.noHorizontalSurface` is the only refusal: nothing horizontal means no
floor and no scene.

### Heights are measured from the floor, not the scanner

The scanner's origin is wherever tracking happened to start. A scene whose floor
sits at z = −1.37 is one nobody can reason about, and the duck's own model puts
the ground at zero.

### Determinism, and why sorting comes before naming

Obstacle names carry the index they were found at, and `DuckSceneMJCF` sorts its
output by name to be deterministic — which is worth nothing if the names
themselves came from an arbitrary order. Planes usually arrive from a dictionary
keyed by anchor id, so the same room scanned twice produced
`surface_01`/`wall_00`/`wall_02` one run and a different assignment the next, and
a scene that renames its furniture between exports cannot be diffed against
itself.

So `reduce` sorts first, by a total order that does not depend on how the caller
stored anything: walls after surfaces, then height, position, size. Names are
zero-padded so `wall_02` sorts before `wall_10`.

### Quantisation is honesty, not tidiness

Everything is rounded to three decimals — millimetres for a length, about 0.06°
for a yaw. A phone's plane estimate is good to a centimetre or two on a good day,
so `0.332041` claims micron precision the measurement does not have. Worse than
untidy: a reader comparing two scans sees six digits change and cannot tell noise
from movement.

---

## Step Two: Write

```swift
let xml = DuckSceneMJCF.scene(from: capture, modelName: "living-room")
```

Same capture in, byte-identical XML out — obstacles sorted by name, fixed
formatting, six significant decimals with no scientific notation and no locale.
So a scene file can be hashed, diffed and re-shared.

Two shapes, and they cannot share a line: a horizontal plane is a **slab** (thin
in the vertical); a vertical one is a **panel** (thin in the direction it faces,
and its second extent is a height rather than a depth).

**The rendered floor is grown to contain the furniture, and only the rendered
one.** A MuJoCo plane is an infinite half-space for collision — its `size`
attribute drives rendering alone — so this changes no physics. It exists because
a real scan routinely reports a tabletop wider than the carpet the phone actually
saw, and a scene whose sofa hangs off the edge of the world looks broken in a way
that sends people hunting for a geometry bug. `floorHalfX`/`floorHalfY` stay as
measured, because that is the honest answer to "how much floor did I scan" and it
is what the app reports.

The growth uses the obstacle's half-**diagonal**, not its half-width, because
obstacles carry a yaw and a rotated box reaches further than its own half-width.
Bounding the rotation rather than computing it errs outward, which is the safe
direction for a number whose only job is to make the picture contain the objects.

---

## Why This Lives in the Kit

`DuckSceneMJCF` already turned a `Capture` into XML. The step before it — turning
what a scanner saw into that `Capture` — is the half where the mistakes actually
live, and it is pure arithmetic over a handful of floats. Left in an iOS target
it can only be exercised by a person holding a phone in a room, which is no way
to check geometry. Here it runs under `swift test` on a Pi.

That is the general rule for this package: if it is arithmetic, it belongs where
a test can reach it.

---

## Common Mistakes

**Passing planes straight from a dictionary and expecting stable names.**
`reduce` sorts, so that is handled — but do not re-sort afterwards or re-name
from your own indices.

**Assuming the floor is at the scanner's origin.** It is not, and `reduce`
subtracts it. Do not subtract it twice.

**Treating `planeThickness` as tunable.** 20 mm is small enough not to swallow a
gap the duck could walk through — its stance is wider by an order of magnitude —
and large enough that the solver is never handed a degenerate box.

**Rounding the output again.** The numbers are already quantised to the
instrument's honest precision. Rounding a second time in a formatter loses the
diffability the fixed formatting exists to give.

**Expecting the scene to run without the robot.** It `<include>`s
`robot_walk.xml`; put the file next to it.
