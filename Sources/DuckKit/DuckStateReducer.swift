/// The state stream reduced to cumulative integers — distance walked, falls,
/// time upright — by arithmetic that a Python script and a JavaScript page can
/// reproduce exactly.
///
/// MICROMETRES, NOT MILLIMETRES, AND THE DIFFERENCE IS A QUARTER OF THE
/// ANSWER. The robot's envelope is 0.2 m/s and it reports at 50 Hz, so the
/// step between two consecutive samples is at most 0.2 / 50 = 4 mm. Convert
/// each position to whole millimetres the naive way — `Int(metres * 1000)`,
/// which truncates — and every step loses up to a whole millimetre; round it
/// and it loses up to half of one. There are 50 × 3600 = 180,000 steps in an
/// hour, so the loss over that hour is up to 180 m truncated or 90 m rounded,
/// against the 720 m the same hour covers at the full envelope. That is a 25%
/// error, or a 12.5% one, in the single number this whole package exists to
/// state truthfully. The same two worst cases in micrometres are 18 cm and
/// 9 cm — 0.025% and 0.0125% — comfortably under the odometry's own drift, and
/// drift is a claim about the robot rather than a defect in the arithmetic.
/// So metres become integer micrometres ON ARRIVAL, once, and every difference
/// after that is exact.
///
/// NO FLOAT EVER REACHES AN ACCUMULATOR. Not because floats are inaccurate,
/// but because they are not *portable*: summing 180,000 doubles gives an
/// answer that depends on the order they were summed in, so the app, the
/// verifier and the reference script would each produce a slightly different
/// total and no two of them could ever be said to disagree about anything
/// meaningful. Every accumulator here is `Int64`, and Int64 addition is Int64
/// addition in every language anyone will reimplement this in.
///
/// ONE ROUNDING RULE, CHOSEN FOR THE PORTS. Every float that becomes an
/// integer goes through `floor(x + 0.5)`. Not because it is the best rule —
/// it is biased upward on ties — but because it is the one rule that is a
/// single obvious expression in all three languages: Swift's
/// `(x + 0.5).rounded(.down)`, Python's `math.floor(x + 0.5)`, and
/// JavaScript's `Math.round(x)`, which is *defined* as floor(x + 0.5) and so
/// sends −2.5 to −2 exactly as the other two do. Swift's own `.rounded()` is
/// half-away-from-zero and Python's `round()` is half-to-even; picking either
/// would make three implementations disagree on precisely the values no test
/// thinks to try.
///
/// The one square root is safe for the same reason. `dx*dx + dy*dy` is
/// computed in Int64 and is at most 2 × 600,000² = 7.2 × 10¹¹ once the reset
/// guard has run, so converting it to a Double is exact (doubles are exact on
/// integers to 2⁵³ ≈ 9.0 × 10¹⁵), IEEE-754 requires `sqrt` to be correctly
/// rounded, and all three languages use the hardware's IEEE double sqrt. Same
/// bits in, same bits out, same integer after the floor.
///
/// A FALL IS AN EPISODE, NOT A SAMPLE. `safety.fallen` is a boolean sampled
/// fifty times a second, and a robot lying on its side produces a boolean that
/// flickers — the case this is written against is forty flickers in 800 ms,
/// where the right answer is one fall, not forty and not zero. So the machine
/// is deliberately asymmetric: a `true` opens an episode, the episode is
/// counted once it has been open for 200 ms, and it does not close until
/// `fallen` has read false for two continuous seconds. One bad IMU frame is
/// not a fall; a duck cannot get up and go down again inside two seconds.
///
/// INTEGRATIONS REFUSE TO CROSS A GAP; EDGE DETECTORS DO NOT INTEGRATE.
/// Distance, turn and time are integrals over intervals, and a three-second
/// hole in the stream — the phone was backgrounded, the wifi hiccuped — is
/// three seconds nobody watched. Joining its two ends is interpolation, and
/// interpolated metres in a signed diary are fabricated evidence, so an
/// interval longer than the gap threshold contributes nothing but a count.
/// The fall machine is not an integral: it advances only on the samples it is
/// handed, and a gap neither opens nor closes an episode.
///
/// THE THRESHOLDS ARE CHOSEN, NOT MEASURED, AND SAY SO. Nobody on earth has a
/// Microduck as this is written. Each number below is arithmetic over the
/// published envelope rather than an observation, which is why they live in a
/// named, versioned value: entries reduced under `Thresholds.v1` stay
/// interpretable after the first week of hardware replaces them, instead of
/// becoming a pile of integers nobody can recompute.
///
/// This file imports nothing. Int64 and a square root are all it needs, which
/// is the same reason it can be a page of Python.
public struct DuckStateReducer: Equatable, Sendable {

    // ── the knobs, versioned ─────────────────────────────────────────────

    /// The five numbers this reduction depends on, as one value with a name.
    ///
    /// The name goes in the record. A statistic computed under one set of
    /// thresholds and compared against another is not a comparison, and the
    /// only way to keep that from happening quietly is to make the threshold
    /// set something a record can carry.
    public struct Thresholds: Equatable, Sendable {

        /// What this set is called, verbatim, in whatever record it produced.
        public let name: String

        /// A step longer than this is an odometry reset, not motion. At 600,000
        /// µm — 0.6 m between two consecutive samples — this is three full
        /// seconds of travel at the 0.2 m/s envelope arriving in one 20 ms
        /// tick: generous enough to survive a stall and a burst of catch-up,
        /// tight enough to catch a daemon restart.
        public let resetMicrometres: Int64

        /// A jump to exactly the origin from further than this out is a reset
        /// whatever its length. 100,000 µm = 0.1 m: a robot genuinely standing
        /// within 10 cm of where it started can pass through (0,0) legitimately,
        /// and one a metre away cannot.
        public let originResetMicrometres: Int64

        /// How long `fallen` must have been open before the episode counts.
        /// 200 ms is ten control ticks — long enough that a single bad IMU
        /// frame is not a fall.
        public let fallConfirmMilliseconds: Int64

        /// How long `fallen` must read false before another fall can be
        /// counted. Two seconds; a duck cannot stand up and go down again
        /// inside it.
        public let fallRearmMilliseconds: Int64

        /// An interval longer than this is a hole in the stream, and nothing
        /// is integrated across it. Two seconds is a hundred missing samples:
        /// far past jitter, far short of the two minutes that end a session.
        public let gapMilliseconds: Int64

        public init(
            name: String,
            resetMicrometres: Int64,
            originResetMicrometres: Int64,
            fallConfirmMilliseconds: Int64,
            fallRearmMilliseconds: Int64,
            gapMilliseconds: Int64
        ) {
            self.name = name
            self.resetMicrometres = resetMicrometres
            self.originResetMicrometres = originResetMicrometres
            self.fallConfirmMilliseconds = fallConfirmMilliseconds
            self.fallRearmMilliseconds = fallRearmMilliseconds
            self.gapMilliseconds = gapMilliseconds
        }

        /// The first published set. Chosen from the envelope, not measured.
        public static let v1 = Thresholds(
            name: "v1",
            resetMicrometres: 600_000,
            originResetMicrometres: 100_000,
            fallConfirmMilliseconds: 200,
            fallRearmMilliseconds: 2_000,
            gapMilliseconds: 2_000)
    }

    // ── what comes out ───────────────────────────────────────────────────

    /// Everything the reduction knows, as integers.
    ///
    /// The counters are not padding. Each one names a distinct way the stream
    /// failed, and a diary that cannot say *how* it came up short is a diary
    /// whose shortfall looks like a robot that did less.
    public struct Totals: Equatable, Sendable {
        /// Distance walked, integer micrometres, resets excluded.
        public var micrometresTravelled: Int64 = 0
        /// Absolute rotation, integer microradians, unwrapped. Turning left
        /// and back again is two turns here and zero on a compass; a body
        /// turned twice, so this counts twice. Net heading is deliberately
        /// not recoverable from it.
        public var microradiansTurned: Int64 = 0
        /// Milliseconds spanned by intervals that were actually observed —
        /// gaps and out-of-order jumps excluded. The denominator for every
        /// rate, and the honest version of "how long you were watching".
        public var millisecondsObserved: Int64 = 0
        /// Of those, the milliseconds during which the robot was *seen* not
        /// to be fallen. A stream that stops reporting `safety` stops earning
        /// upright time, which is what makes the number falsifiable.
        public var millisecondsUpright: Int64 = 0
        /// Completed fall episodes.
        public var falls: Int = 0
        /// Position jumps rejected as odometry resets rather than integrated.
        public var odometryResets: Int = 0
        /// Intervals longer than the gap threshold: holes nothing crossed.
        public var streamGaps: Int = 0
        /// Samples that arrived stamped before their predecessor — a capture
        /// replayed out of order, or a clock that stepped backwards. Counted
        /// and not integrated; a negative duration is never subtracted from
        /// anything.
        public var outOfOrderSamples: Int = 0
        /// States whose receive clock could not be expressed as an integer
        /// millisecond. A counter rather than a trap: a reducer that crashes
        /// on one NaN takes the whole hour of diary with it.
        public var rejectedSamples: Int = 0
        /// Samples reduced, including ones that carried nothing usable.
        public var samples: Int = 0
        /// Lowest and highest bus voltage seen, integer millivolts. 1% of the
        /// 6.6–8.2 V usable span is 16 mV, so a millivolt is two orders finer
        /// than any distinction anyone will draw.
        ///
        /// There is deliberately no resting voltage and no battery-cycle
        /// count here. The pack is read through the servo bus, it sags under
        /// load, and there is no measured sag figure for this robot — a
        /// "cycle" derived without one would be a guess wearing an integer's
        /// clothes. Min and max are facts; the interpretation belongs to
        /// whoever has hardware.
        public var minMillivolts: Int64?
        public var maxMillivolts: Int64?

        public init() {}

        /// Display only. Never feed one of these back into an accumulator —
        /// the integers are the record and these are a rendering of it.
        public var metresTravelled: Double { Double(micrometresTravelled) / 1_000_000 }
        public var radiansTurned: Double { Double(microradiansTurned) / 1_000_000 }
        public var secondsObserved: Double { Double(millisecondsObserved) / 1_000 }
        public var secondsUpright: Double { Double(millisecondsUpright) / 1_000 }
    }

    // ── what goes in ─────────────────────────────────────────────────────

    /// One state, already converted to the integers the reduction runs on.
    ///
    /// This type is the seam. Above it are doubles from a daemon; below it
    /// there is nothing but Int64, which is what makes the algorithm
    /// restatable in a page of another language. Every field except the clock
    /// is optional, for the same reason every field of `DuckState` is: a
    /// missing measurement must not enter the arithmetic as a zero.
    public struct Sample: Equatable, Sendable {
        /// Phone receive clock, whole milliseconds since the epoch.
        public let atMs: Int64
        public let xMicrometres: Int64?
        public let yMicrometres: Int64?
        public let yawMicroradians: Int64?
        public let fallen: Bool?
        public let millivolts: Int64?

        public init(
            atMs: Int64,
            xMicrometres: Int64? = nil,
            yMicrometres: Int64? = nil,
            yawMicroradians: Int64? = nil,
            fallen: Bool? = nil,
            millivolts: Int64? = nil
        ) {
            self.atMs = atMs
            self.xMicrometres = xMicrometres
            self.yMicrometres = yMicrometres
            self.yawMicroradians = yawMicroradians
            self.fallen = fallen
            self.millivolts = millivolts
        }

        /// Convert a decoded state. This is the only place in the reduction
        /// where a float is read, and every one of them is rounded by the
        /// single rule above. Nil only when the clock itself is unusable —
        /// a state with no odometry is a perfectly good sample that
        /// contributes no distance.
        public init?(_ state: DuckState) {
            guard let atMs = state.receivedAtMilliseconds else { return nil }
            self.init(
                atMs: atMs,
                xMicrometres: state.odom?.x.flatMap(DuckStateReducer.micrometres(metres:)),
                yMicrometres: state.odom?.y.flatMap(DuckStateReducer.micrometres(metres:)),
                yawMicroradians: state.odom?.yaw.flatMap(DuckStateReducer.microradians(radians:)),
                fallen: state.safety?.fallen,
                millivolts: state.battery?.volts.flatMap(DuckStateReducer.millivolts(volts:)))
        }
    }

    // ── the unit conversions, which are the specification ────────────────

    /// The largest integer a Double represents exactly, 2⁵³. Past it the
    /// conversion stops being reproducible in a language whose only number is
    /// a double, so anything that lands beyond it is refused rather than
    /// rounded to something a JavaScript port would disagree with.
    public static let exactIntegerLimit: Int64 = 9_007_199_254_740_992

    /// `floor(x + 0.5)`, the one rounding rule. Nil for a value that is not
    /// finite or that lands outside the exactly-representable range.
    public static func rounded(_ value: Double) -> Int64? {
        guard value.isFinite else { return nil }
        let floored = (value + 0.5).rounded(.down)
        guard floored.magnitude <= Double(exactIntegerLimit) else { return nil }
        return Int64(floored)
    }

    /// Metres to integer micrometres.
    public static func micrometres(metres: Double) -> Int64? { rounded(metres * 1_000_000) }

    /// Radians to integer microradians.
    public static func microradians(radians: Double) -> Int64? { rounded(radians * 1_000_000) }

    /// Volts to integer millivolts.
    public static func millivolts(volts: Double) -> Int64? { rounded(volts * 1_000) }

    /// Seconds since the epoch to whole milliseconds. A date in 2026 is about
    /// 1.79 × 10⁹ s, so this lands near 1.79 × 10¹² — where consecutive
    /// doubles are 2⁻¹² ms apart, a quarter of a microsecond. The millisecond
    /// survives the multiplication with room to spare.
    public static func milliseconds(seconds: Double) -> Int64? { rounded(seconds * 1_000) }

    /// One full turn in microradians: `round(2π × 10⁶)`.
    ///
    /// Note that this is 6,283,185 and *not* twice `round(π × 10⁶)`, which is
    /// 6,283,186. The half-turn test below is therefore written as integer
    /// division of this constant — 3,141,592 — so that a reimplementation has
    /// one number to copy and no opportunity to derive a second one that is
    /// off by a microradian.
    public static let turnMicroradians: Int64 = 6_283_185

    // ── the reduction ────────────────────────────────────────────────────

    public let thresholds: Thresholds
    public private(set) var totals = Totals()

    /// Carried between samples. All of it is either an integer or a boolean,
    /// so a port can hold the same seven values and get the same answers.
    private var lastMs: Int64?
    private var lastFallen: Bool?
    private var lastPositionMs: Int64?
    private var lastX: Int64?
    private var lastY: Int64?
    private var lastYawMs: Int64?
    private var lastYaw: Int64?
    private var downSinceMs: Int64?
    private var downCounted = false
    private var upSinceMs: Int64?

    public init(thresholds: Thresholds = .v1) {
        self.thresholds = thresholds
    }

    /// Reduce a decoded state. A state whose clock is unusable is counted in
    /// `rejectedSamples` and changes nothing else.
    public mutating func ingest(_ state: DuckState) {
        guard let sample = Sample(state) else {
            totals.rejectedSamples += 1
            return
        }
        ingest(sample)
    }

    /// Reduce one already-integer sample.
    public mutating func ingest(_ sample: Sample) {
        totals.samples += 1
        accumulateTime(sample)
        accumulateDistance(sample)
        accumulateTurn(sample)
        accumulateVoltage(sample)
        advanceFallMachine(sample)

        lastMs = sample.atMs
        lastFallen = sample.fallen
    }

    /// Observed time, and the part of it the robot was seen upright for.
    ///
    /// An interval is credited to the state at its START, because that is the
    /// state this stream knew to be true for the whole of it. Crediting it to
    /// the end would let one late frame retroactively rewrite the two seconds
    /// before it.
    private mutating func accumulateTime(_ sample: Sample) {
        guard let last = lastMs else { return }
        let elapsed = sample.atMs - last
        if elapsed < 0 {
            totals.outOfOrderSamples += 1
            return
        }
        if elapsed > thresholds.gapMilliseconds {
            totals.streamGaps += 1
            return
        }
        totals.millisecondsObserved += elapsed
        if lastFallen == false {
            totals.millisecondsUpright += elapsed
        }
    }

    /// Distance, with resets rejected rather than walked.
    private mutating func accumulateDistance(_ sample: Sample) {
        guard let x = sample.xMicrometres, let y = sample.yMicrometres else { return }
        defer {
            lastX = x
            lastY = y
            lastPositionMs = sample.atMs
        }
        guard let previousX = lastX, let previousY = lastY, let previousMs = lastPositionMs else { return }
        let elapsed = sample.atMs - previousMs
        // The position reference carries its own clock: a state that arrived
        // with no odometry must not let the next one integrate across the
        // hole it left.
        guard elapsed >= 0, elapsed <= thresholds.gapMilliseconds else { return }

        let dx = x - previousX
        let dy = y - previousY

        // Checked before the multiply, and that order is load-bearing twice
        // over: `sqrt(dx² + dy²) ≥ max(|dx|, |dy|)`, so either component
        // exceeding the cap already means the step does — and a garbage
        // position of 10⁹ m would overflow Int64 when squared, which is a
        // trap rather than a wrong answer.
        if abs(dx) > thresholds.resetMicrometres || abs(dy) > thresholds.resetMicrometres {
            totals.odometryResets += 1
            return
        }
        // A jump to exactly the origin from somewhere else is a daemon that
        // restarted its odometry, whatever the distance says.
        if x == 0, y == 0, isAwayFromOrigin(previousX, previousY) {
            totals.odometryResets += 1
            return
        }
        let step = Self.length(dx: dx, dy: dy)
        if step > thresholds.resetMicrometres {
            totals.odometryResets += 1
            return
        }
        totals.micrometresTravelled += step
    }

    private func isAwayFromOrigin(_ x: Int64, _ y: Int64) -> Bool {
        let limit = thresholds.originResetMicrometres
        if abs(x) > limit || abs(y) > limit { return true }
        return x * x + y * y > limit * limit
    }

    /// `floor(sqrt(dx² + dy²) + 0.5)`, exact for every step the reset guard
    /// lets through: both axes are inside ±600,000 µm there, so the sum of
    /// squares is at most 7.2 × 10¹¹ and the square root of it at most
    /// 848,529 — finite, well inside the exactly-representable range, and
    /// therefore never the nil case.
    static func length(dx: Int64, dy: Int64) -> Int64 {
        let squared = dx * dx + dy * dy
        return Self.rounded(Double(squared).squareRoot()) ?? 0
    }

    /// Turn, unwrapped across the π boundary.
    ///
    /// A difference over half a turn between consecutive samples is
    /// wraparound, not rotation: half a turn in one 20 ms tick is 157 rad/s,
    /// which is 25 revolutions a second and not a thing this robot does. The
    /// rule works whether the daemon reports yaw wrapped into (−π, π] or
    /// accumulated without bound, because in the second case no difference is
    /// ever big enough to trigger it.
    ///
    /// Beware what this integral does to a stationary robot: it accumulates
    /// the ABSOLUTE difference, so yaw noise of j radians per sample becomes
    /// 50 × j rad/s of rotation that never happened — at j = 0.001 that is a
    /// phantom full turn every two minutes. The fix is a deadband, and a
    /// deadband cannot be chosen without a measured noise floor, which is why
    /// `Thresholds` is a versioned value and this is a question for the week
    /// there is hardware rather than a number invented today.
    private mutating func accumulateTurn(_ sample: Sample) {
        guard let yaw = sample.yawMicroradians else { return }
        defer {
            lastYaw = yaw
            lastYawMs = sample.atMs
        }
        guard let previous = lastYaw, let previousMs = lastYawMs else { return }
        let elapsed = sample.atMs - previousMs
        guard elapsed >= 0, elapsed <= thresholds.gapMilliseconds else { return }

        let halfTurn = Self.turnMicroradians / 2
        var delta = yaw - previous
        if delta > halfTurn {
            delta -= Self.turnMicroradians
        } else if delta < -halfTurn {
            delta += Self.turnMicroradians
        }
        // `delta` is bounded by twice the exact-integer limit, so `abs` cannot
        // overflow and the accumulator has room for 10¹² turns.
        totals.microradiansTurned += abs(delta)
    }

    private mutating func accumulateVoltage(_ sample: Sample) {
        guard let millivolts = sample.millivolts else { return }
        totals.minMillivolts = min(totals.minMillivolts ?? millivolts, millivolts)
        totals.maxMillivolts = max(totals.maxMillivolts ?? millivolts, millivolts)
    }

    /// The fall episode machine described at the top of the file. It reads
    /// nothing but `(atMs, fallen)` pairs, and an unknown `fallen` moves
    /// neither timer: not knowing is not the same as being up.
    private mutating func advanceFallMachine(_ sample: Sample) {
        guard let fallen = sample.fallen else { return }
        if fallen {
            upSinceMs = nil
            if downSinceMs == nil {
                downSinceMs = sample.atMs
                downCounted = false
            }
            if let since = downSinceMs, !downCounted,
               sample.atMs - since >= thresholds.fallConfirmMilliseconds {
                totals.falls += 1
                downCounted = true
            }
            return
        }
        guard downSinceMs != nil else { return }
        if upSinceMs == nil {
            upSinceMs = sample.atMs
        }
        if let up = upSinceMs, sample.atMs - up >= thresholds.fallRearmMilliseconds {
            // Two continuous seconds the right way up: the episode is over
            // and the next `true` starts a new one.
            downSinceMs = nil
            downCounted = false
            upSinceMs = nil
        }
    }
}
