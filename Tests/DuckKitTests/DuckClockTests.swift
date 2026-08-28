import XCTest
@testable import DuckKit

/// Four lines of arithmetic, three claims, and one bug that has shipped in
/// every hand-rolled game loop ever written.
///
/// The table below is the whole point: 24, 30, 60, 90, 120 and 144 Hz are the
/// refresh rates a phone or a Mac actually presents at, and the duck has to
/// walk at exactly one speed across all of them. The naive loop — one
/// `DuckSimulation.step` per display frame — instead walks the duck at the
/// refresh rate, which is 20% fast on a 60 Hz phone and 140% fast on a 120 Hz
/// one, and the second test here computes those two numbers rather than
/// quoting them. The rest is about the clamp: what it runs, what it throws
/// away, and the fact that the thrown-away time is never paid back.
final class DuckClockTests: XCTestCase {

    /// Refresh rates worth supporting, and the frame time each one hands the
    /// clock. 90 is in here because it is neither a multiple nor a divisor of
    /// 50 and lands the accumulator somewhere awkward.
    private let refreshRates: [Double] = [24, 30, 60, 90, 120, 144]

    /// Whatever the display does, the duck ticks fifty times a second — to
    /// within the one tick still sitting in the accumulator as phase. The
    /// second half of this is the important half: the error at ten seconds is
    /// the same as the error at one, so it is rounding and not drift. A clock
    /// that was 1% fast would pass the first check and fail this one.
    func testTheTickRateIsFiftyHertzWhateverTheDisplayIsDoing() {
        for rate in refreshRates {
            for seconds in [1.0, 10.0] {
                var clock = DuckClock()
                var ticks = 0
                for _ in 0..<Int(rate * seconds) {
                    ticks += clock.advance(by: 1.0 / rate)
                }
                let expected = DuckModel.tickHz * seconds
                XCTAssertEqual(Double(ticks), expected, accuracy: 1.0,
                               "\(rate) Hz for \(seconds)s produced \(ticks) ticks, wanted \(expected)")
                XCTAssertEqual(clock.ticks, ticks, "the clock's own count must be what it handed out")
                XCTAssertEqual(clock.droppedSeconds, 0, accuracy: 1e-12,
                               "ordinary rendering at \(rate) Hz must never trip the catch-up clamp")
                XCTAssertLessThan(clock.accumulator, clock.interval,
                                  "what is left over is phase, not a backlog")
            }
        }
    }

    /// The bug, computed rather than asserted from memory: stepping once per
    /// display frame runs the gait at the refresh rate. 60/50 is 1.2 and
    /// 120/50 is 2.4 — 20% and 140% fast — and the same second of frames
    /// through a `DuckClock` produces fifty ticks at both.
    func testSteppingOncePerFrameIsExactlyTheBugThisTypeExistsToPrevent() {
        for (rate, excess) in [(60.0, 0.20), (120.0, 1.40)] {
            let naive = rate                        // one tick per frame, for one second
            XCTAssertEqual(naive / DuckModel.tickHz - 1, excess, accuracy: 1e-12,
                           "\(rate) Hz once-per-frame runs the duck \(excess * 100)% fast")

            var clock = DuckClock()
            var ticks = 0
            for _ in 0..<Int(rate) { ticks += clock.advance(by: 1.0 / rate) }
            XCTAssertEqual(Double(ticks), DuckModel.tickHz, accuracy: 1.0,
                           "and through the clock the same frames are fifty ticks, not \(Int(naive))")
        }
    }

    /// A stall runs the clamp's worth of ticks and no more. Ten seconds in
    /// the app switcher must not become five hundred policy forward passes on
    /// the frame the user is looking at.
    func testAStallRunsAtMostTheCatchUpLimitAndDropsTheRest() {
        var clock = DuckClock()
        let stall = 5.0
        let ran = clock.advance(by: stall)

        XCTAssertEqual(ran, clock.catchUpLimit, "a five-second stall runs the clamp and stops")
        XCTAssertEqual(ran, 8, "eight ticks — 160 ms of duck, 0.32 ms of policy")
        XCTAssertEqual(clock.elapsed, 0.16, accuracy: 1e-12, "8 × 20 ms of simulated time")
        XCTAssertEqual(clock.droppedSeconds, 4.84, accuracy: 1e-9, "5.00 − 0.16 went in the bin")
        XCTAssertEqual(clock.elapsed + clock.droppedSeconds, stall, accuracy: 1e-9,
                       "every second is either simulated or explicitly dropped; none is unaccounted for")
        XCTAssertLessThan(clock.accumulator, clock.interval,
                          "and nothing is banked for next frame")
    }

    /// Dropped time is dropped. The frame after a stall is an ordinary frame,
    /// not the start of a catch-up that spreads the same hitch over the next
    /// second — and the simulation stays behind the wall clock for good,
    /// which is why `elapsed` exists and why callers must use it.
    func testDroppedTimeIsNeverPaidBack() {
        var clock = DuckClock()
        _ = clock.advance(by: 5.0)
        let dropped = clock.droppedSeconds

        var ticks = 0
        for _ in 0..<60 { ticks += clock.advance(by: 1.0 / 60.0) }
        XCTAssertEqual(Double(ticks), DuckModel.tickHz, accuracy: 1.0,
                       "the second after a stall is an ordinary second: fifty ticks, not two hundred")
        XCTAssertEqual(clock.droppedSeconds, dropped, accuracy: 1e-12,
                       "and nothing further is dropped once the burst is over")
        XCTAssertLessThan(clock.elapsed, 5.0 + 1.0,
                          "the duck is permanently behind the wall clock by the time that was dropped")
    }

    /// No single advance may exceed the clamp, whatever it is handed. Swept
    /// from a fast frame to an overnight suspend (86 400 s is 4.3 million
    /// ticks) and on to 10¹⁸ — a plausible garbage timestamp, and the one
    /// that would trap on the way to an `Int` if the surplus were not folded
    /// away before the conversion rather than after it.
    func testNoAdvanceEverExceedsTheCatchUpLimit() {
        for delta in [0.001, 0.02, 0.05, 0.16, 0.5, 5.0, 60.0, 3_600.0, 86_400.0, 1e18] {
            var clock = DuckClock()
            let ran = clock.advance(by: delta)
            XCTAssertLessThanOrEqual(ran, clock.catchUpLimit, "\(delta)s ran \(ran) ticks in one go")
            XCTAssertGreaterThanOrEqual(ran, 0)
            XCTAssertTrue(clock.droppedSeconds.isFinite, "\(delta)s produced a non-finite drop count")
            XCTAssertEqual(clock.elapsed + clock.droppedSeconds + clock.accumulator, delta,
                           accuracy: delta * 1e-9 + 1e-12,
                           "\(delta)s must still add up: simulated, dropped, or waiting as phase")
        }
    }

    /// The clamp is at least two ticks, because a 30 fps frame is 1.67 of
    /// them and a clock that dropped ticks during ordinary slow rendering
    /// would be a slow-motion duck rather than a smooth one.
    func testTheClampIsBigEnoughForTheSlowestFrameWeSupport() {
        let clock = DuckClock()
        let slowestFrame = 1.0 / 30.0
        XCTAssertGreaterThanOrEqual(Double(clock.catchUpLimit), (slowestFrame / clock.interval).rounded(.up),
                                    "a 30 fps frame is 1.67 ticks; the clamp must absorb at least two")
        XCTAssertEqual(Double(clock.catchUpLimit) * clock.interval, 0.16, accuracy: 1e-12,
                       "eight ticks is 160 ms of duck time")
        XCTAssertEqual(clock.interval, 1.0 / DuckModel.tickHz, accuracy: 1e-12, "the robot's own 20 ms")
    }

    /// A delta that is not a duration changes nothing at all. A NaN in the
    /// accumulator would poison every frame after it, not just the one it
    /// arrived on, and NaN is exactly what a clock subtraction across a
    /// suspend can produce.
    func testNonsenseDeltasAreRefusedWithoutTouchingTheClock() {
        var clock = DuckClock()
        _ = clock.advance(by: 0.05)
        let before = clock

        for delta in [Double.nan, -1.0, -0.0, 0.0, -.infinity] {
            XCTAssertEqual(clock.advance(by: delta), 0, "\(delta) is not a frame time")
            XCTAssertEqual(clock, before, "\(delta) must leave the clock exactly as it was")
        }

        XCTAssertEqual(clock.advance(by: .infinity), 0, "an infinite frame is not a frame either")
        XCTAssertEqual(clock, before, "and it must not have moved the clock")
    }

    /// The leftover is the phase, and `blend` is how a renderer reads it:
    /// 0.03 s is one tick plus half of another, so the drawing code should be
    /// halfway between the pose it just computed and the next one.
    func testTheRemainderIsPhaseAndBlendReadsItBack() {
        var clock = DuckClock()
        XCTAssertEqual(clock.advance(by: 0.03), 1, "one whole tick out of 30 ms")
        XCTAssertEqual(clock.blend, 0.5, accuracy: 1e-9, "with half a tick left as phase")
        XCTAssertEqual(clock.elapsed, 0.02, accuracy: 1e-12, "simulated time is whole ticks only")

        XCTAssertEqual(clock.advance(by: 0.025), 1, "the phase carries into the next frame")
        XCTAssertEqual(clock.blend, 0.75, accuracy: 1e-9,
                       "half a tick of phase plus a 25 ms frame is one tick and three quarters")
        XCTAssertEqual(clock.ticks, 2)
        XCTAssertEqual(clock.elapsed, 0.04, accuracy: 1e-12)
    }

    /// Both parameters are real: a clock built at 100 Hz with a four-tick
    /// clamp ticks twice as often and bursts half as far. Without this the
    /// defaults could be hardcoded three lines lower and nothing would notice.
    func testTheIntervalAndTheClampAreBothParameters() {
        var fast = DuckClock(interval: 0.01, catchUpLimit: 4)
        var ticks = 0
        for _ in 0..<60 { ticks += fast.advance(by: 1.0 / 60.0) }
        XCTAssertEqual(Double(ticks), 100, accuracy: 1.0, "a 100 Hz clock ticks a hundred times a second")

        fast.reset()
        XCTAssertEqual(fast.advance(by: 5.0), 4, "and its own clamp is what bounds the burst")
        XCTAssertEqual(fast.elapsed, 0.04, accuracy: 1e-12, "four ticks of 10 ms")
    }

    /// A new scene is a new clock: the dropped-time counter describes a run
    /// that is over, so it goes with the rest of it.
    func testResetPutsTheClockBackToAStandingStart() {
        var clock = DuckClock()
        _ = clock.advance(by: 5.0)
        XCTAssertGreaterThan(clock.ticks, 0)
        XCTAssertGreaterThan(clock.droppedSeconds, 0)

        clock.reset()
        XCTAssertEqual(clock, DuckClock(), "a reset clock is a fresh one, counters and all")
        XCTAssertEqual(clock.elapsed, 0)
        XCTAssertEqual(clock.blend, 0)
    }
}
