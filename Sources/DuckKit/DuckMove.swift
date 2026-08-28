import Foundation

/// An authored move: keyframed joint offsets, played on top of a policy.
///
/// NOT A REPLACEMENT FOR A POLICY, AND THAT IS THE WHOLE DESIGN. The obvious
/// way to script a robot is to drive its joints to a sequence of poses. On this
/// robot that does not work, and it fails in a way worth stating plainly: the
/// servos run at `kp` 0.55 with a force limit under 1 N·m, far too soft to hold
/// a pose against gravity. Balance is not a property of a pose here — it is
/// something the policy is actively doing every 20 ms. An open-loop version of
/// the move below was measured falling over on a *flat floor*, with nothing to
/// trip on.
///
/// So a `DuckMove` is a set of **offsets**. The policy keeps its job; the move
/// adds to what the policy asked for. That also happens to describe the idea it
/// was built for better than "scripted animation" does: reach the head out and
/// lean on it, while the legs carry on balancing.
///
/// The one shipped move, `stepUp`, was found by search rather than by hand —
/// twenty parameters, scored by the tallest step the duck could get onto in
/// simulation. What the search chose is more interesting than the number: it
/// approaches below the speed at which the walking policy engages at all, so
/// the duck is standing rather than walking into the step, and it finishes with
/// the neck pulling *up* rather than pressing down — the head is not propping,
/// it is hauling the body over the edge.
public struct DuckMove: Equatable, Sendable {

    /// One pose in the move, at a time from the start.
    public struct Keyframe: Equatable, Sendable {
        public let time: TimeInterval
        /// All 15 joints, in `DuckModel.jointNames` order, radians.
        public let pose: [Double]

        public init(time: TimeInterval, pose: [Double]) {
            precondition(pose.count == DuckModel.jointCount, "a keyframe is all 15 joints")
            precondition(time >= 0, "a keyframe cannot happen before the move starts")
            self.time = time
            self.pose = pose
        }
    }

    public let name: String
    /// In time order, first to last. The pose before the first keyframe is the
    /// base pose, so a move always begins from wherever the duck already is.
    public let keyframes: [Keyframe]

    public init(name: String, keyframes: [Keyframe]) {
        precondition(!keyframes.isEmpty, "a move needs at least one keyframe")
        precondition(zip(keyframes, keyframes.dropFirst()).allSatisfy { $0.time < $1.time },
                     "keyframes must be in strictly increasing time order")
        self.name = name
        self.keyframes = keyframes
    }

    /// How long the move lasts.
    public var duration: TimeInterval { keyframes.last!.time }

    // ── sampling ─────────────────────────────────────────────────────────

    /// The pose at a time, interpolated with smoothstep.
    ///
    /// Smoothstep rather than linear because the derivative matters: a linear
    /// blend arrives at every keyframe with a velocity step, and a servo asked
    /// to change speed instantaneously answers with a jolt the balance
    /// controller then has to absorb.
    public func pose(at time: TimeInterval, from base: [Double] = DuckModel.homePose) -> [Double] {
        precondition(base.count == DuckModel.jointCount, "the base pose is all 15 joints")
        if time <= 0 { return base }
        var previousTime = 0.0
        var previousPose = base
        for frame in keyframes {
            if time <= frame.time {
                let span = max(frame.time - previousTime, 1e-9)
                let u = (time - previousTime) / span
                // Exact at the ends. `a + (b - a) * 1` is not reliably `b` in
                // floating point, and a keyframe that lands a hair short of the
                // pose it names makes every downstream equality test lie.
                if u >= 1 { return frame.pose }
                if u <= 0 { return previousPose }
                let s = u * u * (3 - 2 * u)
                return (0..<DuckModel.jointCount).map {
                    previousPose[$0] + (frame.pose[$0] - previousPose[$0]) * s
                }
            }
            previousTime = frame.time
            previousPose = frame.pose
        }
        return keyframes.last!.pose
    }

    /// What this move adds, relative to the base pose it is written against.
    public func offset(at time: TimeInterval, from base: [Double] = DuckModel.homePose) -> [Double] {
        let p = pose(at: time, from: base)
        return (0..<DuckModel.jointCount).map { p[$0] - base[$0] }
    }

    /// The move applied on top of what a policy asked for.
    ///
    /// `blend` scales the offset — the shipped `stepUp` uses 1.245, i.e. it
    /// deliberately over-drives what was authored, which the search preferred.
    /// The result is clamped to the robot's own travel, so no combination of a
    /// policy and a move can ask for an angle the joint does not have.
    public func applied(to policyTargets: [Double],
                        at time: TimeInterval,
                        blend: Double = 1,
                        base: [Double] = DuckModel.homePose) -> [Double] {
        precondition(policyTargets.count == DuckModel.jointCount,
                     "policy targets are all 15 joints")
        let delta = offset(at: time, from: base)
        return (0..<DuckModel.jointCount).map { j in
            let want = policyTargets[j] + delta[j] * blend
            let range = DuckModel.jointRanges[j]
            return min(max(want, range.lower), range.upper)
        }
    }

    /// Whether the move has finished by this time.
    public func hasFinished(at time: TimeInterval) -> Bool { time >= duration }

    // ── mirroring ────────────────────────────────────────────────────────

    /// The same move, led by the other leg.
    ///
    /// Uses the same swap-and-negate as `DuckTrajectory`, which is right
    /// because the robot's home pose is exactly antisymmetric — every left
    /// joint is the negation of its right counterpart.
    // MARK: - building one from data you did not write

    public enum Invalid: Error, Equatable {
        case empty
        case wrongWidth(keyframe: Int, got: Int, expected: Int)
        case timesNotIncreasing(keyframe: Int)
        case negativeTime(keyframe: Int)
        case outsideTravel(keyframe: Int, joint: String)

        public var message: String {
            switch self {
            case .empty: return "A move needs at least one keyframe."
            case .wrongWidth(let k, let got, let expected):
                return "Keyframe \(k) has \(got) joints; the robot has \(expected)."
                     + (got == expected - 1
                        ? " A 14-wide pose is the policy's joints with the mouth left out — use `init(validatingPolicyPoses:)`."
                        : "")
            case .timesNotIncreasing(let k): return "Keyframe \(k) does not come after the one before it."
            case .negativeTime(let k): return "Keyframe \(k) has a negative time."
            case .outsideTravel(let k, let joint):
                return "Keyframe \(k) puts \(joint) outside its travel."
            }
        }
    }

    /// A move from keyframes somebody else supplied.
    ///
    /// THROWS WHERE THE OTHER INITIALIZER TRAPS, and that difference is the
    /// whole point. `init(name:keyframes:)` uses preconditions, which is right
    /// for a move written as a literal in this package — a mistake there is a
    /// bug and should stop the build's tests. It is exactly wrong for the cases
    /// that actually matter now: a file somebody shared, a clip imported from
    /// another owner, or a pose sequence drafted by a language model. Those are
    /// untrusted by definition, and an authoring tool that crashes on a
    /// malformed import is one nobody can use to import anything.
    public init(validating name: String, keyframes: [Keyframe],
                enforceTravel: Bool = true) throws {
        guard !keyframes.isEmpty else { throw Invalid.empty }
        for (index, frame) in keyframes.enumerated() {
            guard frame.pose.count == DuckModel.jointCount else {
                throw Invalid.wrongWidth(keyframe: index, got: frame.pose.count,
                                         expected: DuckModel.jointCount)
            }
            guard frame.time >= 0 else { throw Invalid.negativeTime(keyframe: index) }
            if index > 0, frame.time <= keyframes[index - 1].time {
                throw Invalid.timesNotIncreasing(keyframe: index)
            }
            if enforceTravel {
                for joint in 0..<DuckModel.jointCount {
                    let range = DuckModel.jointRanges[joint]
                    if frame.pose[joint] < range.lower - 1e-6
                        || frame.pose[joint] > range.upper + 1e-6 {
                        throw Invalid.outsideTravel(keyframe: index,
                                                    joint: DuckModel.jointNames[joint])
                    }
                }
            }
        }
        self.name = name
        self.keyframes = keyframes
    }

    /// The same, from the 14-wide poses every exported intent file actually
    /// carries.
    ///
    /// The authored moves on disk are POLICY-wide — fourteen joints, the mouth
    /// left out, because the mouth is outside every policy's action space. Every
    /// one of them would be rejected by a 15-wide check, so the format that
    /// exists needs a door of its own rather than a caller who remembers to
    /// insert a mouth angle at index nine.
    public init(validatingPolicyPoses name: String,
                times: [TimeInterval], poses: [[Double]],
                mouth: Double = DuckModel.homePose[DuckModel.mouthIndex],
                enforceTravel: Bool = true) throws {
        guard times.count == poses.count else { throw Invalid.empty }
        let frames = try zip(times, poses).enumerated().map { index, pair -> Keyframe in
            let (time, pose) = pair
            guard pose.count == DuckModel.policyJointCount else {
                throw Invalid.wrongWidth(keyframe: index, got: pose.count,
                                         expected: DuckModel.policyJointCount)
            }
            var full = [Double](repeating: 0, count: DuckModel.jointCount)
            for slot in 0..<DuckModel.policyJointCount {
                full[DuckModel.jointOfPolicySlot(slot)] = pose[slot]
            }
            full[DuckModel.mouthIndex] = mouth
            return Keyframe(time: time, pose: full)
        }
        try self.init(validating: name, keyframes: frames, enforceTravel: enforceTravel)
    }

    public func mirrored() -> DuckMove {
        DuckMove(name: name + "_mirrored",
                 keyframes: keyframes.map {
                     Keyframe(time: $0.time, pose: DuckTrajectory.mirror(pose: $0.pose))
                 })
    }
}

extension DuckMove {

    /// The searched step-up: plant the head, lean on it, and get a foot up.
    ///
    /// Twenty parameters, tuned by search against a ladder of step heights.
    /// Measured in simulation: **26 mm**, against 2 mm for the walking policy
    /// alone — and 18, 22 and 26 mm each succeeded three times out of three
    /// while 30 mm failed three out of three. Those numbers are a property of
    /// this simulation, not of the robot: the physics model is Pollen's, but
    /// the floor, the step and the friction are ours.
    ///
    /// Play it with `applied(to:at:blend:)` and `blend` = ``stepUpBlend``.
    public static let stepUp = DuckMove(name: "step_up", keyframes: [
        // 1. PLANT — reach the head down and forward onto the tread.
        Keyframe(time: 0.629170, pose: plantPose),
        // 2. PUSH — press through the head while both knees flex, so the head
        //    carries load the legs would otherwise have to lift.
        Keyframe(time: 1.487255, pose: pushPose),
        // 3. SWING — the lead foot comes up and over the riser.
        Keyframe(time: 1.862245, pose: swingPose),
        // 4. TRANSFER — plant that foot on the tread and unweight the head.
        Keyframe(time: 2.090336, pose: transferPose),
        // 5. RECOVER — trailing foot up, back to a stance.
        Keyframe(time: 2.659836,
                 pose: DuckModel.homePose),
    ])

    /// The blend the search settled on. Above 1 on purpose: it over-drives what
    /// was authored, and scored better for doing so.
    public static let stepUpBlend = 1.245066

    /// The forward command to hold while `stepUp` plays.
    ///
    /// Below the threshold at which the walking policy engages, which is the
    /// search's own choice and the surprising one: the duck is *standing* into
    /// the step rather than walking at it.
    public static let stepUpApproach = 0.118254

    // The five poses, built from the home pose. Left leg leads.
    private static var plantPose: [Double] {
        var p = DuckModel.homePose
        p[5] = 0.612201      // neck_pitch
        p[6] = 0.866988      // head_pitch
        return p
    }

    private static var pushPose: [Double] {
        var p = plantPose
        p[5] = 0.618400
        p[6] = 0.940081
        p[2] = DuckModel.homePose[2] + 0.140355   // left_hip_pitch
        p[3] = DuckModel.homePose[3] + 1.000000  // left_knee
        p[12] = DuckModel.homePose[12] - 0.885565  // right_hip_pitch
        p[13] = DuckModel.homePose[13] - 0.674717 // right_knee
        return p
    }

    private static var swingPose: [Double] {
        var p = pushPose
        p[2] = DuckModel.homePose[2] + 0.796411
        p[3] = DuckModel.homePose[3] + 0.099923
        p[4] = DuckModel.homePose[4] + 0.254604   // left_ankle
        return p
    }

    private static var transferPose: [Double] {
        var p = swingPose
        p[2] = DuckModel.homePose[2] + 0.047928
        p[3] = DuckModel.homePose[3] + 0.282867
        p[5] = -0.400000
        p[6] = 0.311865
        return p
    }
}
