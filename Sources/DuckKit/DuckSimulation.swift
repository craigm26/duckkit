import Foundation

/// The real policy, on real observations — but NOT a walking simulator.
///
/// THIS LOOP DOES NOT PRODUCE A GAIT, AND THE VERSION OF THIS COMMENT THAT
/// SAID IT DID WAS WRONG. It claimed "a ghost on your floor is not an
/// animation of walking, it is the trained policy walking." It is not. Closed
/// on itself, this loop settles into a fixed point or an oscillation, never a
/// walk, and `DuckSimulationTests` pins that so the claim cannot come back.
///
/// WHY, WHICH IS THE USEFUL PART. The policy's 61-float observation carries
/// three things this loop cannot supply:
///
///   * **Gyro** — here a constant built from the yaw you commanded, not a
///     measurement of what the body is doing.
///   * **Projected gravity** — here a fixed `[0, 0, −1]`. On a robot it is
///     world-down rotated into the *trunk's actual orientation*, so it tells
///     the policy how it is tilted. A constant tells it nothing.
///   * **Joint velocity** — here differenced from the loop's own targets.
///     On a robot it is read from the servos.
///
/// A walking policy is a feedback controller around contact. Its phase — when
/// a foot lands, how far the body has fallen onto it — arrives entirely
/// through those three channels. Freeze them and there is no phase to lock
/// to, so the network has nothing to walk against. Measured: with velocities
/// dead the loop flip-flops between two values every tick (25 Hz, the control
/// loop's own Nyquist frequency); with them live it drives joints into their
/// travel stops. A first-order servo lag does not rescue it either — swept
/// across its whole useful range, the loop either oscillates at 6–25 Hz or
/// goes completely still. There is no setting in between.
///
/// This is not a gap that a better estimator closes. Pollen's own browser
/// simulator runs **MuJoCo** (compiled to WASM) at a 0.005 s timestep with
/// decimation 4, and builds the observation from `sensordata` for the gyro,
/// the trunk's real orientation for gravity, and `qvel` for joint velocity.
/// That is the shape of the thing. A pure-Swift package with no dependencies
/// is not going to contain it.
///
/// SO WHAT IS THIS FOR. Everything that does not need contact:
///
///   * Running the real network on an observation **somebody else measured** —
///     a robot over `DuckRPC`, a recorded trace, a fixture. This is the real
///     job, and the one the golden tests exercise.
///   * Single-step inference: given this state and this command, what does the
///     trained policy actually ask for?
///   * `DuckGait`'s scaling, filtering and travel stops, which are real and
///     tested independently.
///
/// FOR AN AR GHOST THAT WALKS, replay a trajectory recorded from a real
/// physics run rather than closing this loop live. The motion is then still
/// the trained network's — it just was not computed on the phone. Anything
/// else is an animation wearing a policy's name.
///
/// `isGrounded` is always true and says so.
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
        ///
        /// This is the FILTER's memory and nothing else. It is deliberately not
        /// the velocity estimate's memory: the two are updated at different
        /// moments in a tick, and conflating them is what made every velocity
        /// in the observation exactly zero. See `previousPositions`.
        public var previousTargets: [Double]?
        /// Where the joints were on the tick *before* last, which is what makes
        /// a velocity a velocity.
        ///
        /// WITHOUT THIS FIELD THE POLICY IS BLIND TO ITS OWN MOTION. The loop
        /// used to difference `jointPositions` against `previousTargets`, and
        /// both were assigned the same array at the end of every tick — so the
        /// difference was structurally zero, forever, and fourteen of the
        /// observation's sixty-one floats were dead. The policy could not tell
        /// a joint sweeping at 2 rad/s from one bolted in place, and settled
        /// into a period-2 flip-flop at 25 Hz: every joint alternating between
        /// two values on every tick, which is the Nyquist frequency of the
        /// control loop and the classic signature of a feedback path with no
        /// damping in it. It read as a gait only if you never plotted it.
        public var previousPositions: [Double]?
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
            previousPositions: [Double]? = nil,
            lastAction: [Float] = [Float](repeating: 0, count: DuckModel.policyJointCount),
            tickCount: Int = 0
        ) {
            precondition(jointPositions.count == DuckModel.jointCount, "jointPositions must cover all 15 joints")
            if let previousTargets {
                precondition(previousTargets.count == DuckModel.jointCount, "previousTargets must cover all 15 joints")
            }
            if let previousPositions {
                precondition(previousPositions.count == DuckModel.jointCount, "previousPositions must cover all 15 joints")
            }
            precondition(lastAction.count == DuckModel.policyJointCount, "lastAction is the 14-wide policy output")
            self.jointPositions = jointPositions
            self.previousTargets = previousTargets
            self.previousPositions = previousPositions
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

        // Velocity by differencing, against where the joints were on the tick
        // BEFORE last — not against `previousTargets`, which by this point in
        // the tick holds the same array as `jointPositions` and would make
        // every velocity zero.
        let previous = state.previousPositions ?? state.jointPositions
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
        // Order matters: today's positions become yesterday's before they are
        // overwritten, which is the whole velocity estimate.
        state.previousPositions = state.jointPositions
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
