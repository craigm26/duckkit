/// The Pollen Robotics Microduck, as data.
///
/// EVERY NUMBER HERE IS SOMEONE ELSE'S NUMBER. The joint order, home pose,
/// action scaling and filter coefficients are ported from the robot's own
/// runtime (`pollen-robotics/microduck`, `duck-control/src/model.rs` and
/// `robotd/src/control.rs`), where they were measured against hardware and
/// trained into the policies. Re-deriving any of them from a datasheet is
/// exactly the kind of change that looks right and walks wrong — a policy
/// observes joint positions *relative to this home pose* and its output is
/// multiplied by *this action scale*, so a discrepancy is not a preference,
/// it is a constant error on fourteen observation slots.
///
/// The kinematic side (body chain, joint ranges) comes from the same repo's
/// MuJoCo model (`kinematics/assets/alpha/robot_walk.xml`), vendored under
/// Tests fixtures; `DuckModelTests` re-derives these tables from that file so
/// the hardcoded values below cannot drift from upstream unnoticed.
public enum DuckModel {

    /// Left leg (5) · neck/head/mouth (5) · right leg (5). The wire, the
    /// policies and the MuJoCo model all index joints in exactly this order.
    public static let jointNames: [String] = [
        "left_hip_yaw", "left_hip_roll", "left_hip_pitch", "left_knee", "left_ankle",
        "neck_pitch", "head_pitch", "head_yaw", "head_roll", "mouth",
        "right_hip_yaw", "right_hip_roll", "right_hip_pitch", "right_knee", "right_ankle",
    ]

    public static let jointCount = 15

    /// The mouth is absent from every alpha policy — all of them are 61-D
    /// observation, 14 actions, and the action vector skips this index. Named
    /// so the omission is deliberate rather than an off-by-one someone has to
    /// rediscover.
    public static let mouthIndex = 9

    /// Joints a policy sees and commands: all but the mouth.
    public static let policyJointCount = 14

    /// THE POSE AN ACTION IS AN OFFSET FROM IS THE POLICY'S, NOT THIS ONE.
    /// Every `.onnx` states its own in `metadata_props.default_joint_pos`, and
    /// all ten of Pollen's declare a pose equal to this one — which is why
    /// treating `homePose` as universal went unnoticed. A community file need
    /// not: `headspin.onnx` wants neck_pitch 0.220 and head_pitch 0.680 where
    /// this has 0.349 and 0.349. Anything replaying a policy has to read the
    /// file's own declaration; this is the robot's rest pose, not a contract.
    ///
    /// Home pose, radians, in joint order. The trunk sits ~5 mm further
    /// forward than the earlier prototype pose so the centre of mass is over
    /// the ankle axis — `DuckKinematicsTests` proves that claim literally, by
    /// forward kinematics: at this pose the feet sit directly under the trunk.
    public static let homePose: [Double] = [
        0.0, -0.0873, -0.4579, -0.0049, 0.4530,
        0.3491, 0.3491, 0.0, 0.0, 0.0,
        0.0, 0.0873, 0.4579, 0.0049, -0.4530,
    ]

    /// Joint travel, radians, `(lower, upper)`, in joint order. The fourteen
    /// policy joints carry the MuJoCo model's ranges; the mouth carries the
    /// runtime's −5°..+30°.
    public static let jointRanges: [(lower: Double, upper: Double)] = [
        (-0.4363323129985824, 0.5235987755982988),   // left_hip_yaw
        (-0.3839724354387516, 0.38397243543875337),  // left_hip_roll
        (-1.5707963267949037, 1.5707963267948895),   // left_hip_pitch
        (-1.570796326794901, 1.5707963267948921),    // left_knee
        (-1.5707963267949019, 1.5707963267948912),   // left_ankle
        (-1.5707963267948966, 1.0471975511965976),   // neck_pitch
        (-1.5707963267948966, 1.5707963267948966),   // head_pitch
        (-2.967059728390364, 2.967059728390357),     // head_yaw
        (-0.4363323129986037, 0.43633231299856107),  // head_roll
        (mouthClosed, mouthOpen),                    // mouth
        (-0.5235987755982988, 0.4363323129985824),   // right_hip_yaw
        (-0.3839724354387525, 0.3839724354387525),   // right_hip_roll
        (-1.5707963267949, 1.570796326794893),       // right_hip_pitch
        (-1.570796326794901, 1.5707963267948921),    // right_knee
        (-1.5707963267949028, 1.5707963267948903),   // right_ankle
    ]

    /// Mouth travel: −5° closed, +30° open.
    public static let mouthClosed = -5.0 * Double.pi / 180.0
    public static let mouthOpen = 30.0 * Double.pi / 180.0

    /// Joint angle for a mouth opening fraction. 0 closed, 1 open; anything
    /// outside — including NaN from a broken caller — is treated as closed or
    /// clamped rather than sent past a servo's travel.
    public static func mouthTarget(open: Double) -> Double {
        let f = open.isFinite ? min(max(open, 0.0), 1.0) : 0.0
        return mouthClosed + f * (mouthOpen - mouthClosed)
    }

    // ── control-loop tuning, trained-in ──────────────────────────────────

    /// The control loop's rate. One tick is 20 ms.
    public static let tickHz = 50.0

    /// Scales raw policy output before it becomes a joint offset:
    /// `target = defaultPose + actionScale × action`.
    ///
    /// TRAINING USED 1.0, AND EVERY POLICY FILE SAYS SO. Each `.onnx` carries
    /// `action_scale = 1.0` in its metadata, and all six `microduck_rl` env
    /// configs set the action term's scale to 1.0. 0.9 is this project's own
    /// de-rating for the physical robot; a replay that wants to reproduce what
    /// the network actually did must use 1.0, which is what the recorder does.
    public static let actionScale = 0.9

    /// The standing policy is trained to be applied whole.
    public static let standingActionScale = 1.0

    /// Below this twist magnitude the standing policy takes over.
    public static let standingThreshold = 0.05

    /// First-order low-pass coefficients applied on the way to the servos:
    /// `target = α·new + (1−α)·previous`.
    ///
    /// NOT A TRAINING CONSTANT, WHATEVER THIS COMMENT USED TO SAY. It claimed
    /// these were "the coefficients the alpha policies were *trained with* —
    /// they must match or sim-to-real transfer degrades", and there is no
    /// support for that anywhere. Training applies no filter at all: mjlab's
    /// joint-position action term is `raw × scale + offset` and nothing else,
    /// its action manager contains no smoothing, and all six of Pollen's
    /// `microduck_rl` env configs leave it that way.
    ///
    /// So this is a HARDWARE choice — smoothing what reaches a real servo —
    /// and it belongs nowhere near a replay of what the policy did. The
    /// recorder deliberately does not apply it.
    public static let headLowpass = 0.5
    public static let legsLowpass = 0.7

    /// How long a kick window stays on the kick network, seconds.
    public static let kickDuration = 0.5

    /// One roulade — one forward roll, seconds.
    public static let rouladeDuration = 1.0

    /// One ground-pick cycle, seconds.
    public static let groundPickPeriod = 4.0

    // ── battery ──────────────────────────────────────────────────────────

    /// Usable-under-load span of the NP-F550 pack as the servo bus sees it —
    /// not the cell chemistry's range. 6.6 V is where the robot starts
    /// struggling, well before the pack's own protection trips.
    public static let batteryFullVolts = 8.2
    public static let batteryEmptyVolts = 6.6

    /// Fraction of a pack, 0–100, for a bus voltage. A non-finite or
    /// non-positive reading means "no answer from the bus" and reads as 0 —
    /// the caller should report that as unknown rather than display it.
    public static func batteryPercent(volts: Double) -> Double {
        guard volts.isFinite, volts > 0 else { return 0.0 }
        let f = (volts - batteryEmptyVolts) / (batteryFullVolts - batteryEmptyVolts)
        return min(max(f, 0.0), 1.0) * 100.0
    }

    /// Index of a joint by name.
    public static func jointIndex(of name: String) -> Int? {
        jointNames.firstIndex(of: name)
    }

    /// The joint a policy slot refers to: slots below the mouth map straight
    /// through; at and above, everything shifts up by one. Used in both
    /// directions — reading joints out for the observation, scattering
    /// actions back over targets — so the two cannot disagree about where the
    /// policy's n-th value belongs.
    public static func jointOfPolicySlot(_ slot: Int) -> Int {
        slot < mouthIndex ? slot : slot + 1
    }
}

/// The seven shipped alpha policies. Walking and standing are chosen by
/// command magnitude; the skills are chosen explicitly by whoever schedules
/// them. Every network shares the one 61-D observation contract, so a skill
/// is a session choice plus a command encoding — never a new contract.
public enum DuckPolicyKind: String, CaseIterable, Equatable, Sendable {
    case walk = "alpha_walking"
    case stand = "alpha_stand"
    case sitStand = "alpha_sitstand"
    case groundPick = "alpha_ground_pick"
    case kickLeft = "ball_kick_left"
    case kickRight = "ball_kick_right"
    case roulade = "roulade"

    /// The ONNX file this policy ships as, in the upstream repo's `policies/`.
    public var fileName: String { rawValue + ".onnx" }

    /// The action scale this policy runs at.
    public var actionScale: Double {
        switch self {
        case .stand: return DuckModel.standingActionScale
        default: return DuckModel.actionScale
        }
    }
}
