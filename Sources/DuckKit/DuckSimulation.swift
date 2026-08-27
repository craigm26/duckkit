import Foundation

/// The duck, walking, with no duck present.
///
/// This is the loop the AR view watches: observation → policy → targets →
/// observation again, fifty times a second, exactly the cycle `robotd` runs
/// on the robot. Feed it a command and it produces the pose the real duck
/// would hold for that command — so a ghost on your floor is not an animation
/// of walking, it is the trained policy walking.
///
/// WHAT IS REAL HERE AND WHAT IS NOT. The policy is real, the observation
/// layout is real, the scaling and filtering are real. What is missing is
/// physics: nothing here integrates forces, so joint *velocity* is estimated
/// by differencing targets and gravity is assumed to point down at the pose
/// the policy is holding. The result is a duck that moves its legs the way
/// the network says to — correct as a gait, not as a fall. A ghost that
/// walks convincingly and cannot tip over is exactly the right amount of
/// simulation for an AR preview, and exactly the wrong amount for predicting
/// whether the real robot will make it up the step. `isGrounded` is always
/// true and says so.
///
/// For real physics, this loop's inputs come from somewhere else: on the
/// robot they come from the IMU and the servo bus. The type is written so
/// that swap is a different `step` caller, not a different pipeline.
public struct DuckSimulation {

    /// One tick's result — what to draw, and what the policy asked for.
    public struct Tick: Equatable, Sendable {
        /// Absolute joint targets, radians, all 15 joints. Feed these to
        /// `DuckKinematics` to place bodies in the world.
        public let jointAngles: [Double]
        /// Names of joints held at a travel stop this tick.
        public let limitedBy: [String]
        /// Which network produced it.
        public let policy: DuckPolicyKind
        /// Ticks elapsed since the loop started.
        public let tick: Int
    }

    /// Simulated gravity direction is fixed: this loop has no physics, and
    /// says so rather than pretending. Trunk frame, unit vector, down.
    public static let assumedGravity: [Double] = [0, 0, -1]

    private let walk: DuckPolicy
    private let stand: DuckPolicy?
    private var previousTargets: [Double]?
    private var lastAction = [Float](repeating: 0, count: DuckModel.policyJointCount)
    private var jointPositions = DuckModel.homePose
    private var tickCount = 0

    /// The seconds one tick represents — the robot's own 20 ms.
    public static let tickInterval = 1.0 / DuckModel.tickHz

    /// - Parameters:
    ///   - walk: the walking network, required.
    ///   - stand: the standing network. Optional: without it, a zero command
    ///     runs the walking policy at rest, which is what the robot's own
    ///     runtime falls back to when the standing net is absent.
    public init(walk: DuckPolicy, stand: DuckPolicy? = nil) {
        self.walk = walk
        self.stand = stand
    }

    /// This simulation never falls, and does not pretend otherwise.
    public var isGrounded: Bool { true }

    /// Advance one 20 ms tick under `command`.
    public mutating func step(command: DuckCommand) -> Tick {
        let kind = DuckGait.locomotion(for: command)
        let network = (kind == .stand ? stand : nil) ?? walk

        // Velocity by differencing: the only estimate available without
        // physics, and the one the policy is least sensitive to.
        let previous = previousTargets ?? jointPositions
        let velocities = (0..<DuckModel.jointCount).map {
            (jointPositions[$0] - previous[$0]) / Self.tickInterval
        }

        let observation = DuckObservation.build(
            gyro: [0, 0, command.twist.2],
            gravity: Self.assumedGravity,
            jointPositions: jointPositions,
            jointVelocities: velocities,
            lastAction: lastAction,
            command: command)

        let action = network.infer(observation)
        let frame = DuckGait.frame(
            action: action, previousTargets: previousTargets, kind: kind,
            mouth: jointPositions[DuckModel.mouthIndex])

        lastAction = action
        previousTargets = frame.targets
        jointPositions = frame.targets
        tickCount += 1

        return Tick(jointAngles: frame.targets, limitedBy: frame.limitedBy,
                    policy: kind, tick: tickCount)
    }

    /// Open or close the beak. No policy commands the mouth, so it is simply
    /// set — the same division of labour the robot has.
    public mutating func setMouth(open: Double) {
        jointPositions[DuckModel.mouthIndex] = DuckModel.mouthTarget(open: open)
    }

    /// The current joint angles, for a caller that wants to draw without
    /// stepping (a paused ghost).
    public var currentJointAngles: [Double] { jointPositions }
}
