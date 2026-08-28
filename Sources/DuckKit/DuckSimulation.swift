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

    /// Everything the loop carries from one tick into the next — and the
    /// whole of it, so that setting this is the same as being there.
    ///
    /// A POLICY IS NOT A FUNCTION, IT IS A DYNAMICAL SYSTEM. Slots 34…48 of
    /// the observation are the *previous* action, and joint positions and
    /// velocities are last tick's targets and their difference, so the
    /// network's output is fed back into its own input every 20 ms. Two
    /// ducks given the same command from different histories do different
    /// things, permanently and legitimately, which means "run this
    /// observation through the policy" answers almost nothing on its own.
    /// The questions worth asking are about trajectories: does this
    /// checkpoint walk differently from that one *from the same starting
    /// condition*, and how fast does a nudge wash out?
    ///
    /// None of that is askable if the loop's memory is private. Exposing it
    /// buys three things at once: a caller can start mid-stride instead of
    /// spending twenty ticks warming up to it, can pin one slot mid-loop
    /// (zero the fed-back action, freeze a joint) and watch what the next
    /// tick does about it, and can hand two simulations *identical* state so
    /// that any divergence afterwards is the networks and nothing else.
    /// Without that last one, comparing two checkpoints measures the warm-up
    /// as much as the policy.
    ///
    /// The widths are structural and checked: 15 joints, 14 actions. A short
    /// array here would be a zero somewhere in the observation, and a zero in
    /// the observation is a joint sitting at home — a plausible robot that
    /// does not exist.
    public struct State: Equatable, Sendable {
        /// Where the loop believes the joints are, radians, all 15. This is
        /// last tick's targets — with no physics there is nothing else it
        /// could be — and it is what the mouth is stored in.
        public var jointPositions: [Double]
        /// The targets the low-pass lags against, or nil to have the filter
        /// start from the next tick's own values — the first-tick behaviour
        /// `DuckGait` documents, available here for any tick.
        public var previousTargets: [Double]?
        /// The previous *raw* policy output, before action scaling, 14 wide.
        /// This is the feedback path: observation slots 34…48.
        public var lastAction: [Float]
        /// Ticks elapsed. Reported as `Tick.tick`; carried here so a resumed
        /// loop can keep counting from where it left off.
        public var tickCount: Int

        /// The condition a fresh loop starts in: standing at the home pose,
        /// nothing remembered, no action fed back, tick zero.
        public init(
            jointPositions: [Double] = DuckModel.homePose,
            previousTargets: [Double]? = nil,
            lastAction: [Float] = [Float](repeating: 0, count: DuckModel.policyJointCount),
            tickCount: Int = 0
        ) {
            precondition(jointPositions.count == DuckModel.jointCount, "jointPositions must cover all 15 joints")
            if let previousTargets {
                precondition(previousTargets.count == DuckModel.jointCount, "previousTargets must cover all 15 joints")
            }
            precondition(lastAction.count == DuckModel.policyJointCount, "lastAction is the 14-wide policy output")
            self.jointPositions = jointPositions
            self.previousTargets = previousTargets
            self.lastAction = lastAction
            self.tickCount = tickCount
        }
    }

    /// Simulated gravity direction is fixed: this loop has no physics, and
    /// says so rather than pretending. Trunk frame, unit vector, down.
    public static let assumedGravity: [Double] = [0, 0, -1]

    private let walk: DuckPolicy
    private let stand: DuckPolicy?

    /// The loop's memory, readable and writable at any tick. Reading it after
    /// a run captures a starting condition; writing it installs one.
    public var state: State

    /// The seconds one tick represents — the robot's own 20 ms.
    public static let tickInterval = 1.0 / DuckModel.tickHz

    /// - Parameters:
    ///   - walk: the walking network, required.
    ///   - stand: the standing network. Optional: without it, a zero command
    ///     runs the walking policy at rest, which is what the robot's own
    ///     runtime falls back to when the standing net is absent.
    ///   - state: the condition to start from. The default is a duck standing
    ///     at home with no history, which is what a fresh loop means.
    public init(walk: DuckPolicy, stand: DuckPolicy? = nil, state: State = State()) {
        self.walk = walk
        self.stand = stand
        self.state = state
    }

    /// This simulation never falls, and does not pretend otherwise.
    public var isGrounded: Bool { true }

    /// Advance one 20 ms tick under `command`.
    public mutating func step(command: DuckCommand) -> Tick {
        let kind = DuckGait.locomotion(for: command)
        let network = (kind == .stand ? stand : nil) ?? walk

        // Velocity by differencing: the only estimate available without
        // physics, and the one the policy is least sensitive to.
        let previous = state.previousTargets ?? state.jointPositions
        let velocities = (0..<DuckModel.jointCount).map {
            (state.jointPositions[$0] - previous[$0]) / Self.tickInterval
        }

        let observation = DuckObservation.build(
            gyro: [0, 0, command.twist.2],
            gravity: Self.assumedGravity,
            jointPositions: state.jointPositions,
            jointVelocities: velocities,
            lastAction: state.lastAction,
            command: command)

        let action = network.infer(observation)
        let frame = DuckGait.frame(
            action: action, previousTargets: state.previousTargets, kind: kind,
            mouth: state.jointPositions[DuckModel.mouthIndex])

        state.lastAction = action
        state.previousTargets = frame.targets
        state.jointPositions = frame.targets
        state.tickCount += 1

        return Tick(jointAngles: frame.targets, limitedBy: frame.limitedBy,
                    policy: kind, tick: state.tickCount)
    }

    /// Open or close the beak. No policy commands the mouth, so it is simply
    /// set — the same division of labour the robot has.
    public mutating func setMouth(open: Double) {
        state.jointPositions[DuckModel.mouthIndex] = DuckModel.mouthTarget(open: open)
    }

    /// The current joint angles, for a caller that wants to draw without
    /// stepping (a paused ghost).
    public var currentJointAngles: [Double] { state.jointPositions }
}
