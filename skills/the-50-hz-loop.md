# Skill: The 50 Hz Loop

## When to Use

- Stepping `DuckSimulation` or a replay from a render loop, timer or `CADisplayLink`
- The duck moves faster on one device than another
- The app hitches for a frame after coming back from the background
- Anything that has to report how long the duck has been doing something

## Quick Check

`for _ in 0..<clock.advance(by: dt) { … }`. If `step` is called once per drawn
frame, it is a bug — even though nothing crashes and nothing looks broken.

---

## The Bug This Prevents

`DuckSimulation.step` advances the robot's own 20 ms control tick.
A `CADisplayLink` fires at whatever the panel does. Call one from the other and
the gait runs at the refresh rate:

| Panel | Ticks per second | Duck runs at |
|---|---|---|
| 60 Hz | 60 | 120% speed |
| 120 Hz ProMotion | 120 | 240% speed |

Nothing errors. The duck simply moves like a more caffeinated robot on the newer
device, and the two are hard to compare because nobody holds both.

**And then the phone gets backgrounded.** The naive fix is an accumulator, and an
accumulator with no ceiling hands you every tick that "should" have happened
while the app was suspended. Ten seconds in the app switcher is 500 ticks — 500
policy forward passes and 500 gait frames in one runloop turn, on the frame the
user is watching. It also makes no sense: the duck did not walk anywhere while
the screen was off.

---

## The Loop

```swift
var clock = DuckClock()                 // 20 ms interval, catch-up limit 8
var duck = DuckSimulation(walk: policy)

func frame(delta: Double) {
    for _ in 0..<clock.advance(by: delta) {
        _ = duck.step(command: command)
    }
    draw(duck.currentJointAngles, blend: clock.blend)
}
```

| Member | What it is for |
|---|---|
| `advance(by:)` | Whole ticks to run now. Returns 0 on a non-finite or negative delta. |
| `blend` | 0…1 into the next tick — the interpolation factor for drawing |
| `elapsed` | `ticks × 20 ms`. **The duck's clock.** |
| `droppedSeconds` | What the clamp threw away |
| `accumulator` | Sub-tick phase, always under one interval after an `advance` |
| `reset()` | New scene, new duck; the dropped-time counter goes too |

---

## Why Eight, and Why Dropped Rather Than Owed

`catchUpLimit` is 8, derived rather than picked. It has to be at least 2, because
a 30 fps frame is 33.3 ms = 1.67 ticks and a clock dropping ticks during ordinary
slow rendering would be a slow-motion duck. It wants to be small, because the
burst runs inside one frame: eight ticks is eight policy forward passes at
roughly 40 µs each, so 0.32 ms — comfortably inside a 120 Hz frame's 8.3 ms
budget, where 500 ticks would be 20 ms and a dropped frame. Eight is 160 ms of
duck: enough to ride out four missed frames at 30 fps, short enough that nobody
sees the catch-up happen.

**Surplus time is dropped, not banked.** It is not paid back over the next few
frames — that would spread the same hitch out and leave the duck permanently
owing time. It is thrown away and counted.

The consequence, stated plainly because callers have to live with it: after a
stall the simulation is permanently behind the wall clock, by exactly that much.
**Anything that needs to know how long the duck has been walking must ask
`elapsed`, never the phone's clock**, or it will believe the ghost took a hundred
steps it never took.

The sub-tick remainder is always kept, which is what makes the rate right at
every refresh rate rather than merely close: at 120 Hz five frames out of every
twelve produce a tick and seven do not, and the phase left in `accumulator`
decides which.

---

## What One Tick Does

`DuckSimulation.step` runs, in this order:

1. Difference `jointPositions` against `previousPositions` — the tick *before*
   last — for velocities.
2. Build the 61-float observation.
3. `policy.infer` → 14 raw actions.
4. `DuckGait.frame` → scale, low-pass, clamp to travel, name what was clamped.
5. Roll the state forward: today's positions become yesterday's *before* they
   are overwritten.

Step 5's order is the whole velocity estimate. The loop used to difference
`jointPositions` against `previousTargets`, and both were assigned the same array
at the end of every tick — so the difference was structurally zero, forever, and
fourteen of sixty-one floats were dead. The policy could not tell a joint
sweeping at 2 rad/s from one bolted in place, and settled into a period-2
flip-flop at 25 Hz. It read as a gait only if you never plotted it.

---

## The Gait Pipeline

`DuckGait` mirrors robotd's own control path:

```
targets ← defaultPose + actionScale × scatter(action)
targets ← first-order low-pass (head α = 0.5, legs α = 0.7)
targets ← held inside each joint's travel, and the holds *named*
```

`stages(...)` keeps every intermediate; `frame(...)` is `stages` with them thrown
away. One pipeline, not two — a second copy is a copy that drifts, and "was that
pose the network's idea, the filter's lag, or a joint stop?" is answered by
comparing `scaled`, `filtered` and `clamped`, never by re-deriving them.

`clamped − filtered` is non-zero at exactly the joints named in `limitedBy`,
which is how "the policy wants to be at the stop" is told apart from "the policy
is being held at the stop" — the first is a gait, the second is a duck grinding a
servo against its own travel.

---

## Common Mistakes

**Passing a wall-clock delta across a suspend.** `advance` guards non-finite and
negative input and returns 0, because a NaN in the accumulator would poison every
future frame rather than this one. Do not remove that guard.

**Reporting distance from `Date()`.** Use `elapsed`, or `DuckStateReducer` for a
real robot's odometry.

**Changing `Alphas` to taste.** `.robotd` (head 0.5, legs 0.7) is the only
setting that describes the shipped robot. Any other value is a different plant
than the network learned to drive. The parameter exists so a *sweep* does not
need a second copy of the filter, not as a tuning surface.

**Applying the low-pass in a replay.** Recorded clips already went through
training's path — scale 1.0, no filter. See `skills/upstream-numbers.md`.
