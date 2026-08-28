/// Raw policy output → joint targets, exactly as the robot's own control loop
/// does it.
///
/// The pipeline, ported from `robotd/src/control.rs` and run here so an AR
/// ghost's joints move through the *same* arithmetic as the real duck's:
///
///     targets ← homePose + actionScale × scatter(action)
///     targets ← first-order low-pass (head α=0.5, legs α=0.7 — trained-in)
///     targets ← held inside each joint's travel, and the holds *named*
///
/// The low-pass coefficients are not a smoothing preference: the policies
/// were trained against them, and running without them is a different robot.
/// The filter starts from the first frame's own targets rather than dragging
/// up from zero — the upstream comment says "the filter starts from reality",
/// and so does this one.
///
/// Travel limiting mirrors robotd, which clamps to actuator range and reports
/// the binding limit in `robot.state.limited_by` — the caller gets the same
/// list here, so a policy leaning on a joint stop is visible rather than
/// silent. (The authoritative envelope always lives on the robot; this one
/// exists so the ghost cannot show a pose the hardware could never reach.)
///
/// THERE IS ONE PIPELINE HERE, NOT TWO. `stages` runs those three steps and
/// keeps each intermediate; `frame` is `stages` with the intermediates thrown
/// away. That split is deliberate. The arithmetic is nine lines long and
/// tempting to restate — once for the 50 Hz loop, once for whatever wants to
/// show a human where a target came from — and a second copy is a copy that
/// drifts: a ghost whose knees lag differently from the duck's for an entire
/// release, with nothing failing anywhere. Asking "was that pose the
/// network's idea, the filter's lag, or a joint stop?" is answered by
/// comparing `scaled`, `filtered` and `clamped`, never by re-deriving them.
public enum DuckGait {

    /// One tick's worth of joint targets.
    public struct Frame: Equatable, Sendable {
        /// Absolute joint targets, radians, all 15 joints. The mouth stays
        /// wherever the caller's mouth logic put it — no policy touches it.
        public let targets: [Double]
        /// Names of joints whose target was held at a travel stop this tick.
        public let limitedBy: [String]
    }

    /// The same tick, with the pipeline opened up: the three arrays the
    /// control loop passes through on its way to an answer, kept rather than
    /// overwritten in place.
    ///
    /// The differences are the useful part. `filtered − scaled` is what the
    /// low-pass held back this tick, and it is zero on the very first tick
    /// because there is nothing yet to lag behind. `clamped − filtered` is
    /// non-zero at exactly the joints named in `limitedBy` and nowhere else,
    /// which is how "the policy wants to be at the stop" is told apart from
    /// "the policy is being held at the stop" — the first is a gait, the
    /// second is a duck grinding a servo against its own travel.
    public struct Stages: Equatable, Sendable {
        /// `homePose + actionScale × action`, all 15 joints, with the
        /// caller's mouth already in place. What the policy asked for this
        /// tick, before any smoothing or holding.
        public let scaled: [Double]
        /// `scaled` blended with the previous tick's targets by `alphas`.
        /// Identical to `scaled` when there is no previous tick.
        public let filtered: [Double]
        /// `filtered` held inside every joint's travel. These are the targets
        /// that go on the wire: `frame(...).targets` is exactly this array.
        public let clamped: [Double]
        /// Names of joints whose target was held at a travel stop this tick.
        public let limitedBy: [String]
    }

    /// The first-order low-pass coefficients — one for the four head joints,
    /// one for the ten leg joints — applied as `α·new + (1−α)·previous`.
    ///
    /// This is a parameter for one reason: so a caller can sweep α without a
    /// second copy of the filter living somewhere else in the codebase. It is
    /// not a tuning surface. `.trained` (head 0.5, legs 0.7) is the only
    /// setting that describes the shipped robot, because the alpha policies
    /// were trained with that filter inside the loop; any other value is a
    /// different plant than the one the network learned to drive, so a ghost
    /// rendered with it is no longer showing what the duck will do, and a
    /// robot driven with it is a sim-to-real gap nobody measured. α = 1 is
    /// the degenerate end: the previous target is ignored and the filter is
    /// off entirely.
    public struct Alphas: Equatable, Sendable {
        /// Coefficient for neck_pitch, head_pitch, head_yaw and head_roll —
        /// joints 5…8, the block sitting between the left leg and the mouth.
        public let head: Double
        /// Coefficient for the ten leg joints, 0…4 and 10…14.
        public let legs: Double

        public init(head: Double, legs: Double) {
            self.head = head
            self.legs = legs
        }

        /// What every shipped alpha policy was trained against.
        public static let trained = Alphas(head: DuckModel.headLowpass, legs: DuckModel.legsLowpass)
    }

    /// Run the tick and keep every intermediate result.
    ///
    /// - Parameters:
    ///   - action: raw policy output, *before* scaling — the same value that
    ///     must be fed back as `lastAction` in the next observation.
    ///   - previousTargets: last tick's filtered targets, or nil on the first
    ///     tick (the filter then starts from this tick's own values).
    ///   - kind: which policy produced the action — selects the action scale.
    ///   - mouth: target for the mouth joint, which no policy commands; it is
    ///     placed in `scaled` and then carried through untouched by the
    ///     filter, exactly as the runtime carries it.
    ///   - alphas: low-pass coefficients. Leaving this alone is what matches
    ///     the robot; passing anything else departs from what the policy was
    ///     trained against, deliberately.
    public static func stages(
        action: [Float],
        previousTargets: [Double]?,
        kind: DuckPolicyKind = .walk,
        mouth: Double = 0,
        alphas: Alphas = .trained
    ) -> Stages {
        precondition(action.count == DuckModel.policyJointCount, "action is the 14-wide policy output")
        if let previousTargets {
            precondition(previousTargets.count == DuckModel.jointCount, "previous targets cover all 15 joints")
        }

        let offsets = DuckObservation.scatterAction(action)
        var scaled = [Double](repeating: 0, count: DuckModel.jointCount)
        for joint in 0..<DuckModel.jointCount {
            scaled[joint] = DuckModel.homePose[joint] + kind.actionScale * offsets[joint]
        }
        scaled[DuckModel.mouthIndex] = mouth

        var filtered = scaled
        if let previous = previousTargets {
            for joint in 0..<DuckModel.jointCount where joint != DuckModel.mouthIndex {
                let isHead = joint > 4 && joint < DuckModel.mouthIndex
                let alpha = isHead ? alphas.head : alphas.legs
                filtered[joint] = alpha * scaled[joint] + (1 - alpha) * previous[joint]
            }
        }

        var clamped = filtered
        var limited: [String] = []
        for joint in 0..<DuckModel.jointCount {
            let travel = DuckModel.jointRanges[joint]
            if clamped[joint] < travel.lower {
                clamped[joint] = travel.lower
                limited.append(DuckModel.jointNames[joint])
            } else if clamped[joint] > travel.upper {
                clamped[joint] = travel.upper
                limited.append(DuckModel.jointNames[joint])
            }
        }
        return Stages(scaled: scaled, filtered: filtered, clamped: clamped, limitedBy: limited)
    }

    /// Compute this tick's targets from a policy's raw 14-wide output — the
    /// end of the pipeline, with the intermediates dropped. Identical work to
    /// `stages`, because it *is* `stages`; see there for the parameters.
    public static func frame(
        action: [Float],
        previousTargets: [Double]?,
        kind: DuckPolicyKind = .walk,
        mouth: Double = 0,
        alphas: Alphas = .trained
    ) -> Frame {
        let result = stages(
            action: action, previousTargets: previousTargets, kind: kind,
            mouth: mouth, alphas: alphas)
        return Frame(targets: result.clamped, limitedBy: result.limitedBy)
    }

    /// Which locomotion network a command selects — walking versus standing,
    /// on twist magnitude alone, at the runtime's own threshold. Skills
    /// (kicks, pick, roulade) are never selected here: they are explicit,
    /// scheduled choices, exactly as robotd treats them.
    public static func locomotion(for command: DuckCommand) -> DuckPolicyKind {
        command.twistMagnitude <= DuckModel.standingThreshold ? .stand : .walk
    }
}
