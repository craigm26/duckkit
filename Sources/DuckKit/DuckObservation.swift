/// The observation vector a Microduck policy sees.
///
/// THIS IS THE HIGHEST-RISK FILE IN THE DUCK FAMILY. It is a flat array of 61
/// floats whose every index must match what the policy was trained against. A
/// wrong offset does not fail loudly — it produces a plausible-looking duck
/// that falls over, and the symptom looks like a tuning problem rather than
/// an indexing one. The layout, ported from the robot's own runtime
/// (`duck-control/src/obs.rs`) and pinned by the same tests it pins itself
/// with:
///
///     index   width  contents
///     0..3        3  gyro, trunk frame, rad/s
///     3..6        3  projected gravity, trunk frame, unit vector
///     6..20      14  joint position minus home pose, mouth excluded
///     20..34     14  joint velocity, mouth excluded
///     34..48     14  previous action, mouth excluded
///     48..61     13  command
///
/// And the command block, the part with no second source of truth:
///
///     48..51      3  vx, vy, vyaw
///     51..55      4  neck_pitch, head_pitch, head_yaw, head_roll
///     55..57      2  body x, y   — ALWAYS ZERO, unbound in training
///     57..60      3  body z, roll, pitch — in that order, not z, pitch, roll
///     60          1  body yaw    — ALWAYS ZERO, unbound in training
///
/// Two traps the upstream authors flag explicitly, preserved here: the
/// unbound body axes are the *nominal* encoding, not placeholders; and head
/// targets ride in the command — they are not added on top of the policy
/// output afterwards. Doing both would bend the head twice.
public struct DuckObservation: Equatable, Sendable {

    public static let length = 61
    public static let commandLength = 13

    /// The built vector, ready for `DuckPolicy.infer`.
    public let values: [Float]

    /// An all-zero observation — not a valid robot state, only ever fed to an
    /// inference whose output is discarded, to pay a first-call cost off the
    /// hot path.
    public static let zeroed = DuckObservation(values: [Float](repeating: 0, count: length))

    private init(values: [Float]) {
        self.values = values
    }

    /// Assemble the observation. `jointPositions` are absolute; the policy
    /// sees them relative to the home pose, because that is what it was
    /// trained on. `lastAction` is the previous *raw* policy output, before
    /// action scaling, in 14-wide policy order.
    ///
    /// Array widths are structural, so a wrong count is a programmer error
    /// and traps — a silently short block would leave its tail at zero, and a
    /// zero in the observation is a joint sitting at its home pose: the
    /// policy would act on a plausible robot that does not exist.
    public static func build(
        gyro: [Double],
        gravity: [Double],
        jointPositions: [Double],
        jointVelocities: [Double],
        homePose: [Double] = DuckModel.homePose,
        lastAction: [Float],
        command: DuckCommand
    ) -> DuckObservation {
        precondition(gyro.count == 3, "gyro must be 3-wide")
        precondition(gravity.count == 3, "gravity must be 3-wide")
        precondition(jointPositions.count == DuckModel.jointCount, "jointPositions must cover all 15 joints")
        precondition(jointVelocities.count == DuckModel.jointCount, "jointVelocities must cover all 15 joints")
        precondition(homePose.count == DuckModel.jointCount, "homePose must cover all 15 joints")
        precondition(lastAction.count == DuckModel.policyJointCount, "lastAction is the 14-wide policy output")

        var data = [Float]()
        data.reserveCapacity(length)
        data.append(contentsOf: gyro.map(Float.init))
        data.append(contentsOf: gravity.map(Float.init))

        let angles = policyJoints(jointPositions)
        let home = policyJoints(homePose)
        for i in 0..<DuckModel.policyJointCount {
            data.append(Float(angles[i] - home[i]))
        }
        data.append(contentsOf: policyJoints(jointVelocities).map(Float.init))
        data.append(contentsOf: lastAction)

        // The command block, in the table's order — kept literal so it can be
        // checked against the docs by eye.
        data.append(Float(command.twist.0))
        data.append(Float(command.twist.1))
        data.append(Float(command.twist.2))
        data.append(Float(command.head.0))
        data.append(Float(command.head.1))
        data.append(Float(command.head.2))
        data.append(Float(command.head.3))
        data.append(0.0) // body x — unbound in training
        data.append(0.0) // body y — unbound
        data.append(Float(command.bodyZ))
        data.append(Float(command.bodyRoll))
        data.append(Float(command.bodyPitch))
        data.append(0.0) // body yaw — unbound

        precondition(data.count == length, "observation layout drifted from 61")
        return DuckObservation(values: data)
    }

    /// The 14 policy joints read out of a 15-joint array, mouth skipped.
    public static func policyJoints(_ values: [Double]) -> [Double] {
        precondition(values.count == DuckModel.jointCount)
        return (0..<DuckModel.policyJointCount).map { values[DuckModel.jointOfPolicySlot($0)] }
    }

    /// A policy's 14 outputs mapped onto the 15 joints, mouth left at zero.
    /// Getting this wrong shifts every joint after index 9 by one — both
    /// catastrophic and completely silent, which is why `jointOfPolicySlot`
    /// is the single mapping used in both directions.
    public static func scatterAction(_ action: [Float]) -> [Double] {
        precondition(action.count == DuckModel.policyJointCount)
        var out = [Double](repeating: 0, count: DuckModel.jointCount)
        for (slot, value) in action.enumerated() {
            out[DuckModel.jointOfPolicySlot(slot)] = Double(value)
        }
        return out
    }
}

/// What a client is asking the duck to do, in the form the policy consumes —
/// physical units, trunk frame. The conversion to the flat command block
/// happens in `DuckObservation.build` and nowhere else.
public struct DuckCommand: Equatable, Sendable {
    /// Forward m/s, left m/s, yaw rad/s.
    public var twist: (Double, Double, Double)
    /// neck_pitch, head_pitch, head_yaw, head_roll — radians, trunk frame.
    public var head: (Double, Double, Double, Double)
    /// Standing body-pose offsets. Zero is the nominal stance.
    public var bodyZ: Double
    public var bodyRoll: Double
    public var bodyPitch: Double

    public init(
        twist: (Double, Double, Double) = (0, 0, 0),
        head: (Double, Double, Double, Double) = (0, 0, 0, 0),
        bodyZ: Double = 0, bodyRoll: Double = 0, bodyPitch: Double = 0
    ) {
        self.twist = twist
        self.head = head
        self.bodyZ = bodyZ
        self.bodyRoll = bodyRoll
        self.bodyPitch = bodyPitch
    }

    /// Magnitude of the velocity command — what selects walking versus
    /// standing. The twist alone: head and body motion must not make the
    /// robot think it is walking.
    public var twistMagnitude: Double {
        (twist.0 * twist.0 + twist.1 * twist.1 + twist.2 * twist.2).squareRoot()
    }

    public static func == (lhs: DuckCommand, rhs: DuckCommand) -> Bool {
        lhs.twist == rhs.twist && lhs.head == rhs.head
            && lhs.bodyZ == rhs.bodyZ && lhs.bodyRoll == rhs.bodyRoll && lhs.bodyPitch == rhs.bodyPitch
    }
}
