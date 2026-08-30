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
    /// THE HARDWARE VALUE, FROM POLLEN'S OWN RUNTIME — robotd's `control.rs`
    /// defaults `action_scale: 0.9`, and this package mirrors robotd. It is
    /// NOT what training used: each `.onnx` carries `action_scale = 1.0` in
    /// its metadata and all six `microduck_rl` env configs agree, so a replay
    /// reproducing what the network did in simulation uses 1.0 (the recorder
    /// does). Two truths, two domains: 0.9 on the robot, 1.0 in the sim.
    public static let actionScale = 0.9

    /// The standing policy is trained to be applied whole.
    public static let standingActionScale = 1.0

    /// Below this twist magnitude the standing policy takes over.
    public static let standingThreshold = 0.05

    /// First-order low-pass coefficients applied on the way to the servos:
    /// `target = α·new + (1−α)·previous`.
    ///
    /// POLLEN'S OWN, AND POLLEN'S OWN COMMENT IS WRONG ABOUT WHY. These values
    /// mirror robotd's `control.rs` defaults (`head_lowpass: Some(0.5)`,
    /// `legs_lowpass: Some(0.7)`), whose doc comment says the alpha policies
    /// "are trained with 0.5 — it must match training or transfer degrades".
    /// The training code contradicts it: mjlab's joint-position action term is
    /// `raw × scale + offset` with no filter anywhere, and all six
    /// `microduck_rl` env configs leave it that way. What training DOES model
    /// is actuator lag — the BAM friction actuator delays actions by several
    /// physics steps — so the hardware filter is best read as standing in for
    /// dynamics the sim gets from its actuator model instead.
    ///
    /// Either way the rule for this package is unchanged: apply these when
    /// modelling what robotd sends to servos; never in a replay of what a
    /// policy did in simulation. The recorder deliberately does not.
    public static let headLowpass = 0.5
    public static let legsLowpass = 0.7

    /// How long a kick window stays on the kick network, seconds.
    public static let kickDuration = 0.5

    /// One roulade — one forward roll, seconds.
    public static let rouladeDuration = 1.0

    /// One ground-pick cycle, seconds. `GP_PERIOD` in microduck_rl's
    /// `microduck_ground_pick_env_cfg.py` and `ground_pick_period` in the
    /// robot's `robotd/src/control.rs`; both say 4.0.
    public static let groundPickPeriod = 4.0

    /// The phase at which the ROBOT stops driving ground pick.
    /// `GROUND_PICK_END_PHASE` in `robotd/src/control.rs`.
    ///
    /// THE RUN IS CUT BEFORE THE RETURN FINISHES, and upstream knows it. The
    /// training config's rise does not complete until phase 0.80, and its own
    /// comment flags the gap: "⚠️ RISE_END=0.80 > coupure φ=0.7 du script
    /// infer_policy". So a real ground pick ends with the head a few degrees
    /// short of home — our recording of the policy ends with the mouth tip
    /// 7 mm higher than it started. Anything sequencing a pick has to allow
    /// for that rather than assume a clean stand.
    public static let groundPickEndPhase = 0.7

    /// How long a ground pick actually runs on the robot: 2.8 s, not the 4 s
    /// period. This is the number a progress bar should use.
    public static let groundPickDuration = groundPickPeriod * groundPickEndPhase

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

    /// The action scale this policy runs at on the ROBOT.
    ///
    /// MIRRORS robotd's `control.rs`, per network, and the first cut got three
    /// of them wrong. It returned 0.9 for everything but standing; robotd pins
    /// roulade at `roulade_action_scale` (default 1.0), ground-pick at
    /// `ground_pick_action_scale` (default 1.0), and the whole sit/rise cycle
    /// at a literal 1.0 — "the prototype's `start_sit_toggle` pins the scale at
    /// 1.0 for the whole sit/rise cycle", in its own words. Only walking and
    /// the kicks-in-motion run de-rated at 0.9. A package that claims to model
    /// the runtime and quietly de-rates a roulade by 10% is modelling a
    /// different robot.
    public var actionScale: Double {
        switch self {
        case .stand: return DuckModel.standingActionScale
        case .sitStand, .groundPick, .roulade: return 1.0
        default: return DuckModel.actionScale
        }
    }
}
