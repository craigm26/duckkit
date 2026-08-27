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
public enum DuckGait {

    /// One tick's worth of joint targets.
    public struct Frame: Equatable, Sendable {
        /// Absolute joint targets, radians, all 15 joints. The mouth stays
        /// wherever the caller's mouth logic put it — no policy touches it.
        public let targets: [Double]
        /// Names of joints whose target was held at a travel stop this tick.
        public let limitedBy: [String]
    }

    /// Compute this tick's targets from a policy's raw 14-wide output.
    ///
    /// - Parameters:
    ///   - action: raw policy output, *before* scaling — the same value that
    ///     must be fed back as `lastAction` in the next observation.
    ///   - previousTargets: last tick's filtered targets, or nil on the first
    ///     tick (the filter then starts from this tick's own values).
    ///   - kind: which policy produced the action — selects the action scale.
    ///   - mouth: target for the mouth joint, which no policy commands.
    public static func frame(
        action: [Float],
        previousTargets: [Double]?,
        kind: DuckPolicyKind = .walk,
        mouth: Double = 0
    ) -> Frame {
        precondition(action.count == DuckModel.policyJointCount, "action is the 14-wide policy output")
        if let previousTargets {
            precondition(previousTargets.count == DuckModel.jointCount, "previous targets cover all 15 joints")
        }

        let offsets = DuckObservation.scatterAction(action)
        var targets = [Double](repeating: 0, count: DuckModel.jointCount)
        for joint in 0..<DuckModel.jointCount {
            targets[joint] = DuckModel.homePose[joint] + kind.actionScale * offsets[joint]
        }
        targets[DuckModel.mouthIndex] = mouth

        if let previous = previousTargets {
            for joint in 0..<DuckModel.jointCount where joint != DuckModel.mouthIndex {
                let isHead = joint > 4 && joint < DuckModel.mouthIndex
                let alpha = isHead ? DuckModel.headLowpass : DuckModel.legsLowpass
                targets[joint] = alpha * targets[joint] + (1 - alpha) * previous[joint]
            }
        }

        var limited: [String] = []
        for joint in 0..<DuckModel.jointCount {
            let travel = DuckModel.jointRanges[joint]
            if targets[joint] < travel.lower {
                targets[joint] = travel.lower
                limited.append(DuckModel.jointNames[joint])
            } else if targets[joint] > travel.upper {
                targets[joint] = travel.upper
                limited.append(DuckModel.jointNames[joint])
            }
        }
        return Frame(targets: targets, limitedBy: limited)
    }

    /// Which locomotion network a command selects — walking versus standing,
    /// on twist magnitude alone, at the runtime's own threshold. Skills
    /// (kicks, pick, roulade) are never selected here: they are explicit,
    /// scheduled choices, exactly as robotd treats them.
    public static func locomotion(for command: DuckCommand) -> DuckPolicyKind {
        command.twistMagnitude <= DuckModel.standingThreshold ? .stand : .walk
    }
}
