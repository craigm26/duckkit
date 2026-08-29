import Foundation

/// Recorded walking, for the ghost on your floor.
///
/// WHY THIS EXISTS AT ALL. `DuckSimulation` cannot walk — it has no ground to
/// walk on, and a walking policy times itself against contact, so closing that
/// loop live gives a twitch rather than a gait (see that type's own comment).
/// The alternative is to put a physics engine on the phone, which is not going
/// into a package whose whole claim is that it depends on nothing. So the
/// motion is recorded off-device, from the real trained policy in real physics,
/// and replayed here.
///
/// What an AR ghost draws is therefore still the trained network's walk. It
/// simply was not computed on the phone — the same bargain every game engine
/// makes with motion capture, except the actor was a neural network.
///
/// HOW THE CLIPS WERE MADE, so you can judge them. MuJoCo steps POLLEN'S OWN
/// robot model — `robot_allcollisions.xml`, vendored byte-identical, full
/// collision geometry and their measured servo class — with training's solver,
/// floor friction and torque ceiling applied on top, at 0.005 s;
/// `alpha_walking.onnx` runs every fourth step, which is the robot's 50 Hz,
/// through the TRAINING control path: target = home + action at scale 1.0,
/// no filter, exactly what mjlab drove during training. The recorder is
/// `sim/record.mjs` in the `duck-sounds` repo.
///
/// AN EARLIER GENERATION OF THESE CLIPS WAS NON-CANON THREE WAYS — a
/// hand-tuned stiffness-sweep plant (Pollen had not yet published their
/// collision model), the HARDWARE control path (0.9 scale plus robotd's
/// low-pass), and commands inside the policy's low-command dead band, where it
/// marches in place. The old walk also veered a full radian per loop; this one
/// runs straight to within ~0.1 rad.
///
/// WHAT IS HONESTLY LIMITED NOW. The one knowingly simplified part left is
/// the actuator — a position servo standing in for the friction-and-lag motor
/// model training used. Under it the policy walks straight with the correct
/// turn sign but covers less ground than commanded (0.25 m/s commanded
/// records ~0.11 m/s), and it turns left far more readily than right — so
/// right-turn is still `turn_left.mirrored()` rather than a clip of something
/// the policy does badly, keeping both directions exactly as symmetric as the
/// mirror.
public struct DuckTrajectory: Equatable, Sendable {

    /// The clips that ship with the package.
    public enum Clip: String, CaseIterable, Sendable {
        /// Standing still, breathing on its stance. The idle.
        case stand
        /// Walking forward at the ordinary command.
        case walk
        /// Walking forward at the top of the envelope.
        case walkFast = "walk_fast"
        /// Turning on the spot. Mirror it for the other direction.
        case turnLeft = "turn_left"
    }

    public let name: String
    /// Ticks per second — always the robot's 50.
    public let hz: Double
    /// One entry per tick: all 15 joints, in `DuckModel.jointNames` order.
    public let frames: [[Double]]
    /// Ticks in one stride, from the autocorrelation of the ankle. The clip is
    /// trimmed to a whole number of these so it loops without a hitch.
    public let period: Int
    /// Where the body ends up after one full clip, relative to where it
    /// started — carried as a delta so a looping walk keeps travelling instead
    /// of snapping home.
    public let deltaX: Double
    public let deltaY: Double
    public let deltaYaw: Double
    /// Mean trunk height over the clip, metres.
    public let height: Double

    /// One instant: the joints, and where the body has got to.
    public struct Pose: Equatable, Sendable {
        /// All 15 joints in `DuckModel.jointNames` order, radians.
        public let jointAngles: [Double]
        /// Metres, on the ground plane, from where the clip began.
        public let x: Double
        public let y: Double
        /// Trunk height, metres.
        public let z: Double
        /// Heading, radians, accumulated across loops.
        public let yaw: Double
    }

    /// How long one loop of the clip lasts.
    public var duration: TimeInterval { Double(frames.count) / hz }

    // ── sampling ─────────────────────────────────────────────────────────

    /// The pose at a time, looping for as long as you keep asking.
    ///
    /// Joint angles are interpolated between the two neighbouring ticks, so a
    /// 120 Hz display gets smooth motion out of a 50 Hz recording rather than
    /// the same frame twice. Root motion accumulates: each completed loop adds
    /// its delta, rotated by the heading built up so far, which is what makes a
    /// looping turn go round in a circle instead of jittering in place.
    public func pose(at time: TimeInterval) -> Pose {
        precondition(!frames.isEmpty, "an empty trajectory has no pose")
        let loopLength = duration
        let loops = (time / loopLength).rounded(.down)
        let within = time - loops * loopLength

        // Accumulated root transform from whole loops.
        var x = 0.0, y = 0.0, yaw = 0.0
        var completed = Int(loops)
        // Compounding in closed form is not worth it: a ghost runs for
        // minutes, and this is a handful of additions per frame.
        if completed > 0 {
            // Guard a caller that hands us a huge time (a backgrounded app
            // waking up) rather than spinning for millions of iterations.
            completed = min(completed, 100_000)
            for _ in 0..<completed {
                let c = cos(yaw), s = sin(yaw)
                x += deltaX * c - deltaY * s
                y += deltaX * s + deltaY * c
                yaw += deltaYaw
            }
        }

        let exact = within * hz
        let i = Int(exact.rounded(.down))
        let f = exact - Double(i)
        let a = frames[min(i, frames.count - 1)]
        let b = frames[(i + 1) % frames.count]
        let angles = (0..<a.count).map { a[$0] + ($0 < b.count ? (b[$0] - a[$0]) * f : 0) }

        // Where the body has got to inside this loop, as a fraction of the
        // clip's own delta. Linear is right here: the deltas are per-loop
        // totals, and a stride is short enough that finer detail would be
        // inventing information the recording does not carry.
        let t = within / loopLength
        let c = cos(yaw), s = sin(yaw)
        let ix = deltaX * t, iy = deltaY * t
        return Pose(jointAngles: angles,
                    x: x + ix * c - iy * s,
                    y: y + ix * s + iy * c,
                    z: height,
                    yaw: yaw + deltaYaw * t)
    }

    // ── mirroring ────────────────────────────────────────────────────────

    /// The same motion, the other way round.
    ///
    /// The robot's home pose is exactly antisymmetric — every left joint is the
    /// negation of its right counterpart, which falls out of the 180° body
    /// rotations in the MJCF. So mirroring is *swap the legs and negate*, and
    /// the home pose is a fixed point of it. `DuckTrajectoryTests` checks that,
    /// because it is the cheapest way to catch this going wrong.
    ///
    /// Used for turning right, which this package does not ship a recording of:
    /// no actuator model we could build turned symmetrically without falling
    /// over, so a right-turn clip would have been a recording of the wrong
    /// thing. A mirrored left turn is at least exactly as true as the left one.
    public func mirrored() -> DuckTrajectory {
        DuckTrajectory(
            name: name + "_mirrored", hz: hz,
            frames: frames.map(DuckTrajectory.mirror(pose:)),
            period: period,
            deltaX: deltaX, deltaY: -deltaY, deltaYaw: -deltaYaw,
            height: height)
    }

    /// Swap left and right, and negate — see `mirrored()`.
    static func mirror(pose: [Double]) -> [Double] {
        precondition(pose.count == DuckModel.jointCount, "a pose is all 15 joints")
        var out = pose
        for (l, r) in zip(0..<5, 10..<15) {
            out[l] = -pose[r]
            out[r] = -pose[l]
        }
        // The neck and head pitch straight ahead and are unchanged; yaw and
        // roll are sideways and flip.
        out[7] = -pose[7]   // head_yaw
        out[8] = -pose[8]   // head_roll
        return out
    }

    // ── loading ──────────────────────────────────────────────────────────

    public enum LoadError: Error, Equatable {
        case missingResource
        case malformed(String)
    }

    /// A clip that ships with the package.
    public static func bundled(_ clip: Clip) throws -> DuckTrajectory {
        try all()[clip.rawValue] ?? { throw LoadError.missingResource }()
    }

    /// Every shipped clip, by name. Decoded once per call — a caller that
    /// wants them all should hold the result.
    public static func all() throws -> [String: DuckTrajectory] {
        guard let url = Bundle.module.url(forResource: "duck-trajectories", withExtension: "json") else {
            throw LoadError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> [String: DuckTrajectory] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hz = root["hz"] as? Double,
              let clips = root["clips"] as? [String: Any] else {
            throw LoadError.malformed("expected an object with hz and clips")
        }
        var out: [String: DuckTrajectory] = [:]
        for (name, raw) in clips {
            guard let c = raw as? [String: Any],
                  let frames = c["frames"] as? [[Double]],
                  let period = c["period"] as? Int,
                  let dx = c["deltaX"] as? Double,
                  let dy = c["deltaY"] as? Double,
                  let dyaw = c["deltaYaw"] as? Double,
                  let height = c["height"] as? Double else {
                throw LoadError.malformed("clip \(name) is missing a field")
            }
            guard frames.allSatisfy({ $0.count == DuckModel.jointCount }) else {
                throw LoadError.malformed("clip \(name) has a frame that is not 15 joints")
            }
            out[name] = DuckTrajectory(name: name, hz: hz, frames: frames, period: period,
                                       deltaX: dx, deltaY: dy, deltaYaw: dyaw, height: height)
        }
        return out
    }
}
