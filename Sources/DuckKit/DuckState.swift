import Foundation

/// The `robot.state` notification, decoded.
///
/// EVERY FIELD IS OPTIONAL, AND THAT IS THE WHOLE DESIGN. `robotd` ships with
/// a robot that reaches customers around Christmas 2026, which means its
/// schema will move — a key renamed, a block added, a nested object promoted —
/// while apps that read it are already installed on phones. The two ways of
/// coping are not equally bad. An app that throws on an unknown key is
/// annoying: it stops working, and everyone can see that it has. An app that
/// decodes a *missing* block as zeros is dangerous: `fallen: false` for a
/// robot whose safety block was renamed is a diary that says, in signed and
/// hash-chained form, that the duck never fell. A zero is a lie that looks
/// exactly like data, and the only structural defence is to have no zero to
/// fall back to. Absent is `nil` here, everywhere, at every depth.
///
/// So this type is strict about shape and tolerant about extras: a key it does
/// not know is ignored, and a key whose *type* changed reads as nil rather
/// than taking the rest of the notification down with it. `isEmpty` is the
/// alarm — a state where every leaf is nil means a line arrived, parsed as
/// JSON, and contained nothing this package recognized, which is the loudest
/// possible signal that the daemon's schema moved. Count those. Never average
/// them.
///
/// IT CARRIES ITS OWN CLOCK. `receivedAt` is a stored property rather than
/// something a view remembers, because staleness is a fact about this value
/// and not about whoever happens to be displaying it. At 50 Hz a state is
/// 20 ms old by the time its successor lands; a screen showing a three-second-
/// old "walking" is describing a robot that may have been on its side for two
/// and a half of them. `isStale(now:after:)` lets the value answer that
/// question wherever it has got to — a view, a reducer, a share card rendered
/// an hour later — instead of it being answered by a timer that happens to be
/// running next to a label.
///
/// The clock is the phone's. `robot.state` as documented carries no timestamp
/// of its own, so network jitter sits inside every duration computed from
/// these, and any honest summary of them says so out loud.
public struct DuckState: Equatable, Sendable {

    /// The notification method these arrive as.
    public static let method = "robot.state"

    /// Which network the robot is running, verbatim — `"alpha_walking"`,
    /// `"alpha_stand"`, and the skill nets. Kept as the daemon's own string
    /// so a policy this build has never heard of survives into the diary
    /// intact rather than being rounded down to "unknown".
    public var policy: String?
    public var safety: Safety?
    public var loop: Loop?
    public var battery: Battery?
    public var odom: Odometry?
    public var move: Move?

    /// When this line reached the phone. Set to the moment of decoding, or to
    /// whatever the caller stamped its read with — which is what a caller
    /// replaying a capture should pass, because a replay's real timestamps
    /// are in the capture and not on the wall clock.
    public var receivedAt: Date

    public init(
        policy: String? = nil,
        safety: Safety? = nil,
        loop: Loop? = nil,
        battery: Battery? = nil,
        odom: Odometry? = nil,
        move: Move? = nil,
        receivedAt: Date
    ) {
        self.policy = policy
        self.safety = safety
        self.loop = loop
        self.battery = battery
        self.odom = odom
        self.move = move
        self.receivedAt = receivedAt
    }

    // ── the blocks ───────────────────────────────────────────────────────

    /// `safety` — the two facts that stop everything else from mattering.
    public struct Safety: Equatable, Sendable, Decodable {
        /// The robot believes it is down. Nil means it did not say, which is
        /// not the same as standing and must never be counted as such.
        public var fallen: Bool?
        /// Torque is off: the servos are not holding. A limp duck is not
        /// broken and not walking.
        public var limp: Bool?

        public init(fallen: Bool? = nil, limp: Bool? = nil) {
            self.fallen = fallen
            self.limp = limp
        }

        public var isEmpty: Bool { fallen == nil && limp == nil }

        private enum CodingKeys: String, CodingKey { case fallen, limp }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.fallen = (try? c.decodeIfPresent(Bool.self, forKey: .fallen)) ?? nil
            self.limp = (try? c.decodeIfPresent(Bool.self, forKey: .limp)) ?? nil
        }
    }

    /// `loop` — how the control loop itself is doing. `DuckModel.tickHz` is
    /// the 50 it is supposed to be reporting, and `missed` is the count of
    /// deadlines it did not make; a robot whose loop is slipping produces
    /// observations the policy was not trained on, so this block is the
    /// difference between "the gait looks wrong" and "the gait *is* wrong".
    public struct Loop: Equatable, Sendable, Decodable {
        public var hz: Double?
        public var missed: Int?

        public init(hz: Double? = nil, missed: Int? = nil) {
            self.hz = hz
            self.missed = missed
        }

        public var isEmpty: Bool { hz == nil && missed == nil }

        private enum CodingKeys: String, CodingKey { case hz, missed }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.hz = (try? c.decodeIfPresent(Double.self, forKey: .hz)) ?? nil
            self.missed = (try? c.decodeIfPresent(Int.self, forKey: .missed)) ?? nil
        }
    }

    /// `battery` — bus volts, and the daemon's own reading of what fraction
    /// of a pack that is.
    public struct Battery: Equatable, Sendable, Decodable {
        /// Volts at the servo bus. Note that this sags under load; it is not
        /// a resting cell voltage and cannot be read as one.
        public var volts: Double?
        /// 0–100, as the robot computes it.
        public var percent: Double?

        public init(volts: Double? = nil, percent: Double? = nil) {
            self.volts = volts
            self.percent = percent
        }

        public var isEmpty: Bool { volts == nil && percent == nil }

        private enum CodingKeys: String, CodingKey { case volts, percent }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.volts = (try? c.decodeIfPresent(Double.self, forKey: .volts)) ?? nil
            self.percent = (try? c.decodeIfPresent(Double.self, forKey: .percent)) ?? nil
        }
    }

    /// `odom` — where the robot thinks it is, in metres and radians, in the
    /// frame it started in.
    ///
    /// Dead reckoning on a walking robot drifts, and this package makes no
    /// claim about how much: that is a tape measure and ten straight walks,
    /// and nobody has hardware yet. What it does guarantee is that the number
    /// is carried without being smoothed, scaled or reset on the way past.
    public struct Odometry: Equatable, Sendable, Decodable {
        /// `[x, y]`, metres. Kept as the array that arrived so that a
        /// three-element position from some future firmware is visible rather
        /// than silently truncated.
        public var position: [Double]?
        /// Heading, radians. May arrive wrapped into (−π, π] or accumulated
        /// without bound; `DuckStateReducer` is written so that either works.
        public var yaw: Double?

        public init(position: [Double]? = nil, yaw: Double? = nil) {
            self.position = position
            self.yaw = yaw
        }

        public var isEmpty: Bool { position == nil && yaw == nil }

        /// The x coordinate, if the position is exactly the pair it should
        /// be. A one- or three-element array reads as nil at both axes,
        /// because half a position is not a position.
        public var x: Double? { position?.count == 2 ? position?[0] : nil }
        public var y: Double? { position?.count == 2 ? position?[1] : nil }

        private enum CodingKeys: String, CodingKey { case position, yaw }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.position = (try? c.decodeIfPresent([Double].self, forKey: .position)) ?? nil
            self.yaw = (try? c.decodeIfPresent(Double.self, forKey: .yaw)) ?? nil
        }
    }

    /// `move` — what was asked for, what the robot actually did with it, and
    /// what got in the way.
    ///
    /// The gap between `requested` and `applied` is the interesting part: a
    /// duck that will not turn left is a different bug depending on whether
    /// the yaw command reached the loop and was clipped, or never arrived.
    /// `limitedBy` names it rather than flagging it — the same choice
    /// `DuckGait.Frame.limitedBy` makes with joint stops, and for the same
    /// reason: "limited" is a light on a dashboard, a name is a diagnosis.
    public struct Move: Equatable, Sendable, Decodable {
        /// `[vx, vy, vyaw]` — the triple `DuckCommand.twist` carries, in the
        /// same units and the same order.
        public var requested: [Double]?
        public var applied: [Double]?
        /// Names of whatever held the applied twist away from the requested
        /// one. Empty means nothing did; nil means the robot did not say.
        public var limitedBy: [String]?

        public init(requested: [Double]? = nil, applied: [Double]? = nil, limitedBy: [String]? = nil) {
            self.requested = requested
            self.applied = applied
            self.limitedBy = limitedBy
        }

        public var isEmpty: Bool { requested == nil && applied == nil && limitedBy == nil }

        /// The requested twist as the triple the rest of the package speaks,
        /// or nil if it did not arrive as exactly three numbers.
        public var requestedTwist: (Double, Double, Double)? { Self.triple(requested) }
        public var appliedTwist: (Double, Double, Double)? { Self.triple(applied) }

        private static func triple(_ values: [Double]?) -> (Double, Double, Double)? {
            guard let values, values.count == 3 else { return nil }
            return (values[0], values[1], values[2])
        }

        private enum CodingKeys: String, CodingKey {
            case requested, applied
            case limitedBy = "limited_by"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.requested = (try? c.decodeIfPresent([Double].self, forKey: .requested)) ?? nil
            self.applied = (try? c.decodeIfPresent([Double].self, forKey: .applied)) ?? nil
            self.limitedBy = (try? c.decodeIfPresent([String].self, forKey: .limitedBy)) ?? nil
        }
    }

    // ── reading one ──────────────────────────────────────────────────────

    /// Decode a `robot.state` notification.
    ///
    /// Returns nil for any other method and for a params block that is not an
    /// object — both are somebody else's message, not a state this package
    /// failed to read. A `robot.state` whose params *are* an object always
    /// decodes, even if nothing in it is recognized; that case is `isEmpty`,
    /// and it is a fact worth recording rather than an error worth throwing.
    ///
    /// - Parameter receivedAt: when the line arrived. Pass the instant the
    ///   read completed if you have it, or a capture's own timestamp when
    ///   replaying one; the default is now, which is right for a live socket
    ///   and wrong for everything else.
    public init?(_ message: DuckRPC.Message, receivedAt: Date = Date()) {
        guard message.method == DuckState.method else { return nil }
        guard var decoded = message.params(as: DuckState.self) else { return nil }
        decoded.receivedAt = receivedAt
        self = decoded
    }

    /// True when a line arrived, parsed, and contained not one field this
    /// package understands. The schema-drift canary — see the type's note.
    public var isEmpty: Bool {
        policy == nil
            && (safety?.isEmpty ?? true)
            && (loop?.isEmpty ?? true)
            && (battery?.isEmpty ?? true)
            && (odom?.isEmpty ?? true)
            && (move?.isEmpty ?? true)
    }

    // ── derived, without inventing anything ──────────────────────────────

    /// `policy` matched against the seven shipped networks, or nil for a name
    /// this build has never heard of. The raw string stays in `policy`
    /// either way.
    public var policyKind: DuckPolicyKind? {
        policy.flatMap(DuckPolicyKind.init(rawValue:))
    }

    /// How old this state is at `now`. Negative when the state is stamped in
    /// the future, which happens when a clock steps and is reported as-is
    /// rather than clamped — a negative age is a clock problem, and rounding
    /// it to zero would hide the only evidence of one.
    public func age(at now: Date) -> TimeInterval {
        now.timeIntervalSince(receivedAt)
    }

    /// Whether this state is too old to speak for the robot.
    ///
    /// There is no default tolerance, deliberately: the right number depends
    /// entirely on what the answer is for. The arithmetic to pick one is
    /// `DuckModel.tickHz` — the loop runs at 50 Hz, so one tick is 20 ms and
    /// ten missed ticks is 200 ms. A live "what is it doing" label wants a
    /// tolerance measured in ticks. A reducer deciding whether two samples
    /// belong to the same walk wants seconds. Naming a single constant here
    /// would mean one of those two callers is quietly wrong.
    public func isStale(now: Date, after tolerance: TimeInterval) -> Bool {
        age(at: now) > tolerance
    }

    /// The pack fraction the robot reported — or, only if it reported none,
    /// the one `DuckModel`'s curve derives from the bus voltage.
    ///
    /// Precedence in that order and never blended: the robot's own number
    /// comes from the daemon that owns the pack, and this package's curve is
    /// a straight line across a usable-under-load span. They will disagree,
    /// and averaging two disagreeing estimates produces a third number that
    /// is nobody's.
    public var batteryPercentOrDerived: Double? {
        if let percent = battery?.percent { return percent }
        guard let volts = battery?.volts, volts.isFinite, volts > 0 else { return nil }
        return DuckModel.batteryPercent(volts: volts)
    }

    /// `receivedAt` as whole milliseconds since the epoch, which is the only
    /// form `DuckStateReducer` will look at.
    ///
    /// The rounding rule is the reducer's, on purpose: there is exactly one
    /// place in this package where a float becomes an integer, and it is the
    /// file whose entire job is being reimplementable in two other languages.
    /// Nil for a clock that is NaN or beyond ±2⁵³ ms, which is not a date.
    public var receivedAtMilliseconds: Int64? {
        DuckStateReducer.milliseconds(seconds: receivedAt.timeIntervalSince1970)
    }
}

extension DuckState: Decodable {

    private enum CodingKeys: String, CodingKey {
        case policy, safety, loop, battery, odom, move
    }

    /// Decoded straight from a params object. Each block is read with its own
    /// `try?`, so one block whose type changed costs exactly that block —
    /// a renamed `battery` must not cost the odometry standing next to it.
    ///
    /// `receivedAt` is stamped at decode, because a decoder has no other
    /// clock. A caller with a better one overwrites it; `init(_:receivedAt:)`
    /// is that caller.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            policy: (try? c.decodeIfPresent(String.self, forKey: .policy)) ?? nil,
            safety: (try? c.decodeIfPresent(Safety.self, forKey: .safety)) ?? nil,
            loop: (try? c.decodeIfPresent(Loop.self, forKey: .loop)) ?? nil,
            battery: (try? c.decodeIfPresent(Battery.self, forKey: .battery)) ?? nil,
            odom: (try? c.decodeIfPresent(Odometry.self, forKey: .odom)) ?? nil,
            move: (try? c.decodeIfPresent(Move.self, forKey: .move)) ?? nil,
            receivedAt: Date())
    }
}
