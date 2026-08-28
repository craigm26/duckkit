import XCTest
@testable import DuckKit

/// The reduction, held to exact integers.
///
/// EVERY ASSERTION HERE IS `XCTAssertEqual` ON AN `Int64`, AND THAT IS THE
/// POINT. This arithmetic has to be reimplementable in Python and in
/// JavaScript — a claim carries a summary, the ledger carries the entries, and
/// a verifier recomputes one from the other — so "close enough" is not a
/// passing result. A test that accepted a tolerance would accept exactly the
/// drift that makes a third-party verifier disagree with the app and have no
/// way to say which of them is wrong.
///
/// The numbers in these fixtures are chosen so that a reader can check them by
/// hand: a 3-4-5 triangle in millimetres, a walk of 3 mm a tick, a yaw that
/// steps by exactly 0.1 rad. A fixture a reader cannot check with arithmetic
/// pins nothing but whatever the code did on the day it was written.
final class DuckStateReducerTests: XCTestCase {

    private func sample(
        _ ms: Int64, x: Double? = nil, y: Double = 0, yaw: Double? = nil,
        fallen: Bool? = nil, volts: Double? = nil
    ) -> DuckStateReducer.Sample {
        DuckStateReducer.Sample(
            atMs: ms,
            xMicrometres: x.flatMap { DuckStateReducer.micrometres(metres: $0) },
            yMicrometres: x == nil ? nil : DuckStateReducer.micrometres(metres: y),
            yawMicroradians: yaw.flatMap { DuckStateReducer.microradians(radians: $0) },
            fallen: fallen,
            millivolts: volts.flatMap { DuckStateReducer.millivolts(volts: $0) })
    }

    private func reduce(_ samples: [DuckStateReducer.Sample]) -> DuckStateReducer.Totals {
        var reducer = DuckStateReducer()
        for sample in samples { reducer.ingest(sample) }
        return reducer.totals
    }

    // ── the units ────────────────────────────────────────────────────────

    /// One rounding rule, `floor(x + 0.5)`, chosen because it is the rule
    /// JavaScript's `Math.round` *is* and Python's `math.floor(x + 0.5)`
    /// spells directly. The negative half is where the alternatives part
    /// company: Swift's own `.rounded()` sends −2.5 to −3 and Python's
    /// `round()` sends 2.5 to 2, and either would put two ports of this file
    /// permanently one micrometre apart on values no fixture thinks to try.
    func testTheRoundingRuleIsFloorOfXPlusAHalfInEveryUnit() {
        XCTAssertEqual(DuckStateReducer.rounded(2.5), 3, "half rounds up")
        XCTAssertEqual(DuckStateReducer.rounded(-2.5), -2, "and up is towards +∞, as Math.round is")
        XCTAssertEqual(DuckStateReducer.rounded(-0.5), 0)
        XCTAssertEqual(DuckStateReducer.rounded(0.4999), 0)
        XCTAssertEqual(DuckStateReducer.micrometres(metres: 1), 1_000_000)
        XCTAssertEqual(DuckStateReducer.micrometres(metres: -0.0000004), 0,
                       "0.4 µm below zero rounds to zero, not to −1")
        XCTAssertEqual(DuckStateReducer.microradians(radians: 0.7853981), 785_398)
        XCTAssertEqual(DuckStateReducer.millivolts(volts: 7.42), 7_420)
        XCTAssertEqual(DuckStateReducer.millivolts(volts: DuckModel.batteryFullVolts), 8_200)
        XCTAssertEqual(DuckStateReducer.millivolts(volts: DuckModel.batteryEmptyVolts), 6_600,
                       "the usable span is 1600 mV, so 1% of a pack is 16 of them")
        XCTAssertEqual(DuckStateReducer.milliseconds(seconds: 1234.5678), 1_234_568)
    }

    /// Garbage is refused, not converted. A NaN volts reading that became 0 mV
    /// would be a flat battery in the record; a position of 10²⁰ m that became
    /// an Int64 would be a trap, which takes the whole recording session.
    func testValuesThatCannotBeAnExactIntegerAreRefusedRatherThanRounded() {
        XCTAssertNil(DuckStateReducer.rounded(.nan))
        XCTAssertNil(DuckStateReducer.rounded(.infinity))
        XCTAssertNil(DuckStateReducer.rounded(-.infinity))
        XCTAssertNil(DuckStateReducer.micrometres(metres: 1e18), "10¹⁸ m is not a duck")
        XCTAssertEqual(DuckStateReducer.rounded(Double(DuckStateReducer.exactIntegerLimit)),
                       DuckStateReducer.exactIntegerLimit,
                       "2⁵³ itself is exact, and is the last value that is")
        XCTAssertNil(DuckStateReducer.rounded(Double(DuckStateReducer.exactIntegerLimit) * 2),
                     "past it a JavaScript port could not agree, so nothing here pretends to")
    }

    /// WHY MICROMETRES. At 0.02 m/s a tick covers 0.4 mm, and every one of
    /// those steps truncates to zero whole millimetres — a duck that pottered
    /// 40 cm across a room and, in millimetre arithmetic, went nowhere at all.
    func testStepsSmallerThanAMillimetreAreDistanceRatherThanRoundingError() {
        let samples = (0...1000).map { sample(Int64($0) * 20, x: Double($0) * 0.0004) }
        let totals = reduce(samples)
        XCTAssertEqual(totals.micrometresTravelled, 400_000,
                       "a thousand 400 µm steps is 0.4 m, exactly")
        XCTAssertEqual(totals.metresTravelled, 0.4, accuracy: 1e-12, "and 0.4 m is what it renders as")
        XCTAssertEqual(totals.odometryResets, 0)
    }

    func testAStraightWalkAccumulatesExactlyTheMicrometresItCovered() {
        let samples = (0...100).map { sample(Int64($0) * 20, x: Double($0) * 0.003, fallen: false) }
        let totals = reduce(samples)
        XCTAssertEqual(totals.micrometresTravelled, 300_000,
                       "100 steps of 3 mm at 0.15 m/s — 0.3 m over two seconds")
        XCTAssertEqual(totals.millisecondsObserved, 2_000, "and the two seconds are observed time")
        XCTAssertEqual(totals.millisecondsUpright, 2_000, "all of it seen upright")
        XCTAssertEqual(totals.samples, 101)
        XCTAssertEqual(totals.streamGaps, 0)
        XCTAssertEqual(totals.falls, 0)
    }

    /// `floor(sqrt(dx² + dy²) + 0.5)` over Int64. The 3-4-5 case is exact by
    /// construction; the diagonal one is not, and is here because a rounding
    /// rule is only pinned by a value that has something to round.
    func testAStepIsTheIntegerHypotenuseOfItsTwoAxes() {
        XCTAssertEqual(reduce([sample(0, x: 0, y: 0), sample(20, x: 0.003, y: 0.004)])
            .micrometresTravelled, 5_000, "3 mm across and 4 mm along is a 5 mm step")
        XCTAssertEqual(reduce([sample(0, x: 0, y: 0), sample(20, x: 0.001, y: 0.001)])
            .micrometresTravelled, 1_414,
                       "√2 mm is 1414.21… µm, and floor(x + 0.5) makes that 1414")
        XCTAssertEqual(DuckStateReducer.length(dx: 3_000, dy: -4_000), 5_000,
                       "the sign of an axis cannot shorten a step")
    }

    // ── resets ───────────────────────────────────────────────────────────

    /// 0.6 m between two samples is three seconds of travel at the full
    /// envelope arriving in one 20 ms tick. It is a daemon that restarted its
    /// odometry, and integrating it would credit the duck with a metre it did
    /// not walk.
    func testAJumpTooLongToBeAStepIsAResetAndNotDistance() {
        let totals = reduce([
            sample(0, x: 0), sample(20, x: 0.003), sample(40, x: 0.703), sample(60, x: 0.706),
        ])
        XCTAssertEqual(totals.odometryResets, 1, "the 0.7 m jump is a reset")
        XCTAssertEqual(totals.micrometresTravelled, 6_000,
                       "the two real 3 mm steps count, the jump between them does not")
    }

    /// The rule the length test cannot catch: 0.5 m is a legal step length by
    /// the cap and still obviously a restart when it lands exactly on the
    /// origin the duck left half a metre ago.
    func testAJumpToExactlyTheOriginIsAResetEvenWhenItIsShortEnoughToWalk() {
        let totals = reduce([sample(0, x: 0.5), sample(20, x: 0), sample(40, x: 0.003)])
        XCTAssertEqual(totals.odometryResets, 1, "(0.5, 0) → (0, 0) is a daemon restart")
        XCTAssertEqual(totals.micrometresTravelled, 3_000, "and only the step after it is walking")

        let nearOrigin = reduce([sample(0, x: 0.05), sample(20, x: 0)])
        XCTAssertEqual(nearOrigin.odometryResets, 0,
                       "a duck genuinely 5 cm out may walk through the origin")
        XCTAssertEqual(nearOrigin.micrometresTravelled, 50_000)
    }

    // ── falls ────────────────────────────────────────────────────────────

    /// The case this machine exists for: a duck on its side produces a
    /// boolean that flickers, and the answer is one fall — not forty, which
    /// is what edge counting gives, and not zero, which is what a naive
    /// "true for 200 continuous ms" gives.
    func testAFallThatFlickersFortyTimesInEightHundredMillisecondsCountsOnce() {
        var samples: [DuckStateReducer.Sample] = []
        for i in 0..<40 {
            samples.append(sample(Int64(i) * 20, fallen: i.isMultiple(of: 2)))
        }
        let totals = reduce(samples)
        XCTAssertEqual(totals.falls, 1, "one duck, on the ground, once")
        XCTAssertEqual(totals.millisecondsObserved, 780, "the whole flicker is still observed time")
        XCTAssertEqual(totals.millisecondsUpright, 380,
                       "of which the intervals that began upright are 19 × 20 ms")
    }

    /// The rearm. Two continuous seconds the right way up before another fall
    /// can be counted — a duck cannot stand and go down again inside that.
    func testASecondFallOnlyCountsAfterTwoWholeSecondsTheRightWayUp() {
        var samples: [DuckStateReducer.Sample] = []
        for ms in stride(from: Int64(0), through: 400, by: 20) { samples.append(sample(ms, fallen: true)) }
        for ms in stride(from: Int64(420), through: 1_000, by: 20) { samples.append(sample(ms, fallen: false)) }
        for ms in stride(from: Int64(1_020), through: 1_400, by: 20) { samples.append(sample(ms, fallen: true)) }
        XCTAssertEqual(reduce(samples).falls, 1,
                       "600 ms upright is a wobble in one fall, not the end of it")

        var recovered = samples
        for ms in stride(from: Int64(1_420), through: 4_000, by: 20) { recovered.append(sample(ms, fallen: false)) }
        for ms in stride(from: Int64(4_020), through: 4_400, by: 20) { recovered.append(sample(ms, fallen: true)) }
        XCTAssertEqual(reduce(recovered).falls, 2,
                       "two and a half seconds upright ends the episode, and the next fall is a fall")
    }

    /// Under the confirm window nothing is counted: a single bad IMU frame is
    /// not a fall, and 200 ms is ten control ticks of agreeing that it is.
    func testAFallShorterThanTheConfirmWindowIsNotAFall() {
        let totals = reduce([
            sample(0, fallen: false), sample(20, fallen: true), sample(40, fallen: true),
            sample(60, fallen: false), sample(80, fallen: false),
        ])
        XCTAssertEqual(totals.falls, 0, "40 ms of `fallen` is a frame, not an event")
    }

    /// Unknown is not upright and not down. A stream that stops reporting
    /// `safety` stops earning upright time, which is what makes the number
    /// falsifiable rather than merely large.
    func testAnUnknownSafetyFieldNeitherFallsNorEarnsUprightTime() {
        let totals = reduce((0...50).map { sample(Int64($0) * 20, fallen: nil) })
        XCTAssertEqual(totals.falls, 0)
        XCTAssertEqual(totals.millisecondsObserved, 1_000, "the samples were still observed")
        XCTAssertEqual(totals.millisecondsUpright, 0, "but not one millisecond of them was seen upright")
    }

    /// An interval is credited to the state at its start — the state this
    /// stream knew to be true for the whole of it.
    func testAnIntervalIsCreditedToTheStateThatWasTrueForIt() {
        let totals = reduce([
            sample(0, fallen: false), sample(100, fallen: true), sample(200, fallen: true),
        ])
        XCTAssertEqual(totals.millisecondsObserved, 200)
        XCTAssertEqual(totals.millisecondsUpright, 100,
                       "the first interval began upright; the second did not")
    }

    // ── gaps and disorder ────────────────────────────────────────────────

    /// A hole in the stream is time nobody watched, and joining its ends is
    /// interpolation. Interpolated metres in a signed diary are fabricated
    /// evidence, so the gap contributes a count and nothing else.
    func testNothingIsIntegratedAcrossAStreamGap() {
        let totals = reduce([
            sample(0, x: 0, yaw: 0, fallen: false),
            sample(100, x: 0.1, yaw: 0.1, fallen: false),
            sample(5_100, x: 0.2, yaw: 0.2, fallen: false),
            sample(5_200, x: 0.3, yaw: 0.3, fallen: false),
        ])
        XCTAssertEqual(totals.streamGaps, 1, "five seconds of silence is one hole")
        XCTAssertEqual(totals.micrometresTravelled, 200_000,
                       "two 0.1 m steps were watched; the one across the hole was not")
        XCTAssertEqual(totals.microradiansTurned, 200_000, "and the same for the turn")
        XCTAssertEqual(totals.millisecondsObserved, 200,
                       "0.2 s of the 5.2 s that elapsed was actually observed")
        XCTAssertEqual(totals.millisecondsUpright, 200)
    }

    /// A capture replayed out of order, or a clock that stepped backwards. A
    /// negative interval is never subtracted from anything.
    func testSamplesThatArriveOutOfOrderAreCountedAndNeverSubtracted() {
        let totals = reduce([
            sample(0, x: 0, fallen: false),
            sample(100, x: 0.1, fallen: false),
            sample(50, x: 0.2, fallen: false),
        ])
        XCTAssertEqual(totals.outOfOrderSamples, 1)
        XCTAssertEqual(totals.millisecondsObserved, 100, "and no time ran backwards")
        XCTAssertEqual(totals.micrometresTravelled, 100_000, "nor did any distance")
        XCTAssertEqual(totals.samples, 3, "the sample still arrived, and is still counted")
    }

    // ── turning ──────────────────────────────────────────────────────────

    /// π is a boundary in the representation, not in the robot. Half a turn
    /// between two 20 ms samples would be 157 rad/s — 25 revolutions a
    /// second — so a difference that big is wraparound every time.
    func testYawUnwrapsAcrossThePiBoundary() {
        let wrapped = reduce([sample(0, yaw: 3.0), sample(20, yaw: -3.0)])
        XCTAssertEqual(wrapped.microradiansTurned, 283_185,
                       "3.0 → −3.0 is 0.283185 rad the short way, not 6 rad backwards")

        let quarter = reduce((0...5).map { sample(Int64($0) * 20, yaw: Double($0) * 0.1) })
        XCTAssertEqual(quarter.microradiansTurned, 500_000, "five clean 0.1 rad steps")

        let unbounded = reduce([sample(0, yaw: 100.0), sample(20, yaw: 100.1)])
        XCTAssertEqual(unbounded.microradiansTurned, 100_000,
                       "a daemon that reports yaw unwrapped works too: no difference is ever big enough")
    }

    /// Absolute, not net: a body that turned left and back turned twice, and
    /// a compass that reads zero is answering a different question.
    func testTurningIsAbsoluteSoThereAndBackIsTwoTurnsRatherThanNone() {
        let totals = reduce([sample(0, yaw: 0), sample(20, yaw: 0.5), sample(40, yaw: 0)])
        XCTAssertEqual(totals.microradiansTurned, 1_000_000, "0.5 rad out and 0.5 rad back")
    }

    // ── the pack ─────────────────────────────────────────────────────────

    /// Millivolts, and only as a minimum and a maximum. There is deliberately
    /// no resting voltage and no cycle count: the pack is read through the
    /// servo bus, it sags under load, and no sag figure has ever been measured
    /// on this robot.
    func testVoltageIsKeptAsMillivoltsAndOnlyAsAMinimumAndMaximum() {
        var reducer = DuckStateReducer()
        XCTAssertNil(reducer.totals.minMillivolts, "no reading is not zero volts")
        for (index, volts) in [7.9, 7.42, 8.2, 7.6].enumerated() {
            reducer.ingest(sample(Int64(index) * 20, volts: volts))
        }
        XCTAssertEqual(reducer.totals.minMillivolts, 7_420)
        XCTAssertEqual(reducer.totals.maxMillivolts, 8_200)
    }

    // ── invariance ───────────────────────────────────────────────────────

    /// The same walk sampled at 50 Hz and at 10 Hz is the same walk. It has to
    /// be: a phone that drops frames under load, or a verifier reading a
    /// downsampled capture, must not produce a different distance from the
    /// same robot.
    func testDownsamplingAStraightWalkDoesNotChangeItsLength() {
        let full = (0...100).map { sample(Int64($0) * 20, x: Double($0) * 0.003, fallen: false) }
        let fifth = full.enumerated().filter { $0.offset.isMultiple(of: 5) }.map(\.element)
        XCTAssertEqual(reduce(full).micrometresTravelled, reduce(fifth).micrometresTravelled,
                       "twenty 15 mm steps are the hundred 3 mm steps they are made of")
        XCTAssertEqual(reduce(fifth).millisecondsObserved, 2_000, "and the same two seconds passed")
    }

    // ── the seam ─────────────────────────────────────────────────────────

    /// Decoded states reduce through exactly the same integers as
    /// hand-built samples: `Sample.init(_:)` is the only float boundary, and
    /// it is one conversion, not a second implementation.
    func testDecodedStatesReduceThroughTheSameIntegersAsHandBuiltSamples() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var fromStates = DuckStateReducer()
        var fromSamples = DuckStateReducer()
        for tick in 0...50 {
            let seconds = Double(tick) * 0.02
            let state = DuckState(
                policy: DuckPolicyKind.walk.rawValue,
                safety: DuckState.Safety(fallen: false, limp: false),
                battery: DuckState.Battery(volts: 7.42),
                odom: DuckState.Odometry(position: [Double(tick) * 0.003, 0], yaw: 0),
                receivedAt: base.addingTimeInterval(seconds))
            fromStates.ingest(state)
            fromSamples.ingest(sample(
                Int64(1_800_000_000_000) + Int64(tick) * 20, x: Double(tick) * 0.003,
                fallen: false, volts: 7.42))
        }
        XCTAssertEqual(fromStates.totals, fromSamples.totals,
                       "one path through the arithmetic, whichever door you came in by")
        XCTAssertEqual(fromStates.totals.micrometresTravelled, 150_000)
        XCTAssertEqual(fromStates.totals.minMillivolts, 7_420)
    }

    /// A clock that is not a number is counted, not fatal. A reducer that
    /// trapped on one bad `Date` would take the hour of diary with it.
    func testAStateWithAnUnusableClockIsCountedRatherThanFatal() {
        var reducer = DuckStateReducer()
        reducer.ingest(DuckState(receivedAt: Date(timeIntervalSince1970: .nan)))
        reducer.ingest(DuckState(
            odom: DuckState.Odometry(position: [1, 1]),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(reducer.totals.rejectedSamples, 1)
        XCTAssertEqual(reducer.totals.samples, 1, "and the usable one still went through")
    }

    /// A state with no odometry is a perfectly good sample. It contributes
    /// time and no distance, and the position reference carries its own clock
    /// so the sample after the hole cannot integrate across it.
    func testAStateWithNoOdometryContributesTimeButNoDistance() {
        let totals = reduce([
            sample(0, x: 0, fallen: false),
            sample(20, fallen: false),
            sample(40, x: 0.003, fallen: false),
        ])
        XCTAssertEqual(totals.millisecondsObserved, 40, "all three samples were observed")
        XCTAssertEqual(totals.micrometresTravelled, 3_000,
                       "and the 3 mm covered between the two positions is 3 mm, once")
    }

    /// The thresholds are a value with a name because they are chosen rather
    /// than measured, and the name has to reach the record: a statistic
    /// computed under one set and compared against another is not a
    /// comparison.
    func testTheThresholdSetIsNamedAndCarriesTheNumbersTheDocumentationQuotes() {
        let v1 = DuckStateReducer.Thresholds.v1
        XCTAssertEqual(v1.name, "v1")
        XCTAssertEqual(v1.resetMicrometres, 600_000, "0.6 m — three seconds at the 0.2 m/s envelope")
        XCTAssertEqual(v1.originResetMicrometres, 100_000)
        XCTAssertEqual(v1.fallConfirmMilliseconds, 200, "ten control ticks at 50 Hz")
        XCTAssertEqual(v1.fallRearmMilliseconds, 2_000)
        XCTAssertEqual(v1.gapMilliseconds, 2_000, "a hundred missing samples")
        XCTAssertEqual(DuckStateReducer().thresholds, v1, "and v1 is what a reducer uses unasked")
        XCTAssertEqual(DuckStateReducer.turnMicroradians, 6_283_185,
                       "round(2π × 10⁶), which is not twice round(π × 10⁶)")
    }
}
