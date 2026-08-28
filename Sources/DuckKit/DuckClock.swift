/// A fixed 50 Hz accumulator with a catch-up clamp.
///
/// STEPPING THE DUCK ONCE PER DISPLAY FRAME IS A BUG, AND IT IS THE EASIEST
/// BUG IN THIS PACKAGE TO WRITE. `DuckSimulation.step` advances the robot's
/// own 20 ms control tick; a `CADisplayLink` fires at whatever the panel does.
/// Call one from the other and the gait runs at the refresh rate: 60/50 = 1.2,
/// so a 60 Hz phone walks the duck 20% fast, and 120/50 = 2.4, so a ProMotion
/// phone walks it 140% fast. Nothing crashes and nothing looks broken — the
/// duck simply moves like a different, more caffeinated robot on the newer
/// device, and the two are hard to compare because nobody holds both.
///
/// AND THEN THE PHONE GETS BACKGROUNDED. The other half of the same bug: the
/// naive fix is an accumulator, and an accumulator with no ceiling will hand
/// you every tick that "should" have happened while the app was suspended. Ten
/// seconds in the app switcher is 500 ticks — 500 policy forward passes and
/// 500 gait frames in one runloop turn, on the frame the user is watching,
/// which is a visible hitch at best and a watchdog kill at worst. It also
/// makes no sense: the duck did not walk anywhere while the screen was off.
///
/// So: accumulate, run whole ticks, and clamp the burst. THE CLAMP IS THE
/// IMPORTANT PART, AND WHAT IT DOES WITH THE LEFTOVER TIME IS THE WHOLE
/// DESIGN. Surplus time is *dropped*, not banked. It is not paid back over the
/// next few frames — that would just spread the same hitch out and leave the
/// duck permanently owing time — it is thrown away and counted in
/// `droppedSeconds`. The consequence, stated plainly because callers have to
/// live with it: after a stall the simulation is permanently behind the wall
/// clock, by exactly that much. Anything that needs to know how long the duck
/// has been walking must ask `elapsed` (ticks × 20 ms), never the phone's
/// clock, or it will believe the ghost took a hundred steps it never took.
///
/// The sub-tick remainder is kept, always, which is the part that makes the
/// rate right at every refresh rate rather than merely close: at 120 Hz five
/// frames out of every twelve produce a tick and seven do not, and the phase
/// left in `accumulator` is what decides which. It is also what `blend` is for.
public struct DuckClock: Equatable, Sendable {

    /// Seconds per tick — the robot's own 20 ms by default. It is a parameter
    /// because a caller may be stepping something other than the control loop
    /// (a replay at half speed, a test whose answers are obvious by
    /// inspection), not because the duck has a second rate. It does not.
    public let interval: Double

    /// The most ticks one `advance` may run. Everything past this is dropped.
    ///
    /// Eight, derived rather than picked. It has to be at least 2, because a
    /// 30 fps frame is 33.3 ms = 1.67 ticks and a clock that dropped ticks
    /// during ordinary slow rendering would be a slow-motion duck. It wants
    /// to be small, because the burst runs inside one frame: eight ticks is
    /// eight policy forward passes at roughly 40 µs each (`DuckPolicy`), so
    /// 0.32 ms — comfortably inside even a 120 Hz frame's 8.3 ms budget,
    /// where 500 ticks would be 20 ms and a dropped frame. Eight is 160 ms of
    /// duck: long enough to ride out a garbage-collection-sized hiccup or
    /// four missed frames at 30 fps, short enough that nobody sees the
    /// catch-up happen.
    public let catchUpLimit: Int

    /// Time waiting to become a tick, always less than one interval after an
    /// `advance`. This is the phase, not a debt.
    public private(set) var accumulator: Double

    /// Ticks run since this clock was made. The duck's own time base.
    public private(set) var ticks: Int

    /// Time the clamp threw away, in seconds. Non-zero means the app was
    /// stalled and the simulation skipped that much of the world; it is the
    /// difference between wall time and `elapsed`, and it is worth showing in
    /// a debug overlay exactly once, because a number that only grows while
    /// backgrounded is telling the truth.
    public private(set) var droppedSeconds: Double

    public init(interval: Double = 1.0 / DuckModel.tickHz, catchUpLimit: Int = 8) {
        precondition(interval > 0, "a tick has to have a length")
        precondition(catchUpLimit >= 1, "a clock that can never tick is not a clock")
        self.interval = interval
        self.catchUpLimit = catchUpLimit
        self.accumulator = 0
        self.ticks = 0
        self.droppedSeconds = 0
    }

    /// Feed in one frame's worth of wall time; get back how many 20 ms ticks
    /// to run before drawing. The caller's whole loop is
    /// `for _ in 0..<clock.advance(by: dt) { _ = duck.step(command: c) }`.
    ///
    /// A non-finite or negative delta returns zero and changes nothing. That
    /// is not defensive programming for its own sake: `CACurrentMediaTime`
    /// differences across a suspend, and any clock subtraction done in the
    /// wrong order, are exactly where a NaN gets into a render loop, and a
    /// NaN in the accumulator would poison every future frame rather than
    /// this one.
    public mutating func advance(by seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        accumulator += seconds

        // Fold away anything past what a single advance could ever run,
        // before it becomes an Int. Two reasons, one ordinary and one nasty:
        // an overnight suspend is tens of thousands of seconds, which is
        // millions of ticks to divide out and throw away, and a garbage
        // timestamp — a difference taken against a clock that was never
        // started — is 10¹⁸ seconds, which over 20 ms is 5 × 10¹⁹ and does
        // not fit in an Int at all. `Int(_:)` on a Double that large traps.
        let ceiling = Double(catchUpLimit + 1) * interval
        if accumulator > ceiling {
            droppedSeconds += accumulator - ceiling
            accumulator = ceiling
        }

        // Whole ticks out, sub-tick phase left behind. The subtraction takes
        // *every* pending tick out of the accumulator, including the ones the
        // clamp refuses to run: dropped time is dropped, never owed.
        let pending = Int(accumulator / interval)
        accumulator -= Double(pending) * interval
        let run = min(pending, catchUpLimit)
        if pending > run {
            droppedSeconds += Double(pending - run) * interval
        }
        ticks += run
        return run
    }

    /// How far into the next tick we are, 0…1 — the interpolation factor for
    /// drawing between two simulation states. Without it a 120 Hz display
    /// shows each pose twice and the motion judders at exactly the rate the
    /// panel was bought to avoid.
    public var blend: Double { accumulator / interval }

    /// Simulated time: ticks × 20 ms. The clock a ghost should use for
    /// anything it reports, because it excludes the time the clamp dropped.
    public var elapsed: Double { Double(ticks) * interval }

    /// Back to a standing start — a new scene, a new duck. The dropped-time
    /// counter goes with it, because it describes a run that is over.
    public mutating func reset() {
        accumulator = 0
        ticks = 0
        droppedSeconds = 0
    }
}
