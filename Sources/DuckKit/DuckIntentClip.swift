import Foundation

/// One recorded intent: a motion that happens once, and then is over.
///
/// SEPARATE FROM `DuckTrajectory` ON PURPOSE. A gait loops, and
/// `DuckTrajectory.pose(at:)` is built for that — it wraps time modulo the
/// clip's duration and ACCUMULATES root motion per completed loop, which is
/// what makes a looping turn go round in a circle. Ask it for a kick at four
/// times the clip length and you get a duck that has kicked four times and
/// teleported forward three. Almost nothing here loops: a kick happens once, a
/// roll happens once, sitting down ends sat. So this type clamps instead of
/// wrapping, and carries the root as recorded rather than as a per-loop delta.
///
/// The clips are recorded in MuJoCo from the real trained policies, because the
/// policy cannot run live on a phone — it locks its gait phase to contact, and
/// on a device the gyro, projected gravity and joint velocities are constants.
public struct DuckIntentClip: Equatable, Sendable {

    /// Where the trunk is and how it is oriented, at one tick.
    public struct Root: Equatable, Sendable {
        public let x, y, z: Double
        /// Trunk orientation, (w, x, y, z). NOT a yaw scalar — a duck that
        /// rolls or flips has an orientation one angle cannot carry, and
        /// `roulade` and `back_roll` both roll.
        public let quaternion: (Double, Double, Double, Double)

        public static func == (l: Root, r: Root) -> Bool {
            l.x == r.x && l.y == r.y && l.z == r.z && l.quaternion == r.quaternion
        }
    }

    public struct Pose: Equatable, Sendable {
        /// All 15 joints, ready for `DuckKinematics`.
        public let jointAngles: [Double]
        public let root: Root
        /// True once the clip has run out and is being held at its last frame.
        public let hasFinished: Bool
    }

    /// What posture the clip starts and ends in — MEASURED from the recording's
    /// own trunk height and orientation, never asserted from its name.
    public enum Posture: String, Equatable, Sendable {
        case standing, crouched, seated, fallen, toppled, inverted
    }

    public let name: String
    public let hz: Double
    /// 14 policy joints per frame, mouth excluded.
    public let frames: [[Double]]
    public let roots: [Root]
    /// Total rotation, UNWRAPPED by summing per-tick deltas. Cannot be
    /// recovered from the last quaternion, which only gives an angle modulo 2π
    /// — `step_up` turns −4.783 rad, which no single atan2 can express.
    public let netYaw: Double
    /// Only `hold` loops. Everything else happens once.
    public let loops: Bool
    public let startsFrom: Posture
    public let endsIn: Posture
    /// The ONNX file this motion was recorded from.
    public let policy: String
    /// True when the motion is a keyframe track riding on that policy rather
    /// than the policy's own output.
    public let authored: Bool
    /// What the motion was performed against.
    ///
    /// A clip played in an empty void cannot be judged. `step_up` ends toppled
    /// because it fails to climb A STAIR, and `wall_flip` pushes off A WALL —
    /// without the prop on screen a viewer sees a duck falling over for no
    /// reason and cannot tell a bad recording from a bad move. The ground is
    /// always present because it is the single most useful piece of context:
    /// it is what says whether the feet are on the floor.
    public let environment: Environment

    /// Who contributed it, for display only. Provenance is decided by the
    /// policy's fingerprint, never by this string.
    public let credit: String?

    /// The props a clip was recorded against, in the clip's own frame — the
    /// same de-origined frame as `roots`, so a renderer draws the world and the
    /// robot together without reconciling anything.
    public struct Environment: Equatable, Sendable {
        /// A block of the staircase. `top` is the height its upper face sits
        /// at; it extends `halfHeight` below that, which is how a 10 mm step
        /// still has a solid body under it rather than floating.
        public struct Step: Equatable, Sendable {
            public let x, y, top: Double
            public let halfDepth, halfWidth, halfHeight: Double
        }
        public struct Wall: Equatable, Sendable {
            public let x, y, halfThickness, height, halfLength: Double
        }
        public let ground: Bool
        /// How far the world is rotated relative to the clip's frame.
        public let yaw: Double
        public let steps: [Step]
        public let walls: [Wall]

        /// True when there is something to draw beyond the floor — what a UI
        /// checks before offering to show or hide the props.
        public var hasProps: Bool { !steps.isEmpty || !walls.isEmpty }
    }

    /// A one-shot spans `count − 1` intervals: its last frame IS its end. A
    /// loop spans `count`, because it hands back to its first frame.
    public var duration: TimeInterval {
        Double(loops ? frames.count : max(frames.count - 1, 0)) / hz
    }

    /// The pose at a time.
    ///
    /// A one-shot CLAMPS at its final frame and reports `hasFinished`, rather
    /// than wrapping. A caller that keeps asking gets a duck standing where the
    /// motion left it, which is what the robot would actually be doing.
    public func pose(at time: TimeInterval) -> Pose {
        precondition(!frames.isEmpty, "an empty clip has no pose")
        let exact = max(time, 0) * hz
        if loops {
            let index = Int(exact.truncatingRemainder(dividingBy: Double(frames.count)))
            return sample(index, next: (index + 1) % frames.count,
                          fraction: exact - exact.rounded(.down), finished: false)
        }
        guard exact < Double(frames.count - 1) else {
            return sample(frames.count - 1, next: frames.count - 1, fraction: 0, finished: true)
        }
        let index = Int(exact.rounded(.down))
        return sample(index, next: index + 1, fraction: exact - Double(index), finished: false)
    }

    private func sample(_ i: Int, next j: Int, fraction f: Double, finished: Bool) -> Pose {
        let a = frames[i], b = frames[j]
        var angles = [Double](repeating: 0, count: DuckModel.jointCount)
        for slot in 0..<min(a.count, DuckModel.policyJointCount) {
            let value = a[slot] + (slot < b.count ? (b[slot] - a[slot]) * f : 0)
            angles[DuckModel.jointOfPolicySlot(slot)] = value
        }
        // The mouth is outside every policy's action space, so a recording
        // carries nothing for it. Home is the honest default.
        angles[DuckModel.mouthIndex] = DuckModel.homePose[DuckModel.mouthIndex]
        return Pose(jointAngles: angles, root: roots[min(i, roots.count - 1)], hasFinished: finished)
    }

    // MARK: - loading

    public enum LoadError: Error, Equatable { case missingResource, malformed(String) }

    public static func bundled() throws -> [String: DuckIntentClip] {
        guard let url = Bundle.module.url(forResource: "duck-intent-clips", withExtension: "json") else {
            throw LoadError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    static func environment(from raw: [String: Any]?) -> Environment {
        guard let raw else { return Environment(ground: true, yaw: 0, steps: [], walls: []) }
        let steps = (raw["steps"] as? [[String: Any]] ?? []).compactMap { s -> Environment.Step? in
            guard let x = s["x"] as? Double, let y = s["y"] as? Double,
                  let top = s["top"] as? Double else { return nil }
            return Environment.Step(x: x, y: y, top: top,
                                    halfDepth: s["halfDepth"] as? Double ?? 0.17,
                                    halfWidth: s["halfWidth"] as? Double ?? 0.17,
                                    halfHeight: s["halfHeight"] as? Double ?? 0.10)
        }
        let walls = (raw["walls"] as? [[String: Any]] ?? []).compactMap { w -> Environment.Wall? in
            guard let x = w["x"] as? Double, let y = w["y"] as? Double else { return nil }
            return Environment.Wall(x: x, y: y,
                                    halfThickness: w["halfThickness"] as? Double ?? 0.025,
                                    height: w["height"] as? Double ?? 0.6,
                                    halfLength: w["halfLength"] as? Double ?? 1.5)
        }
        return Environment(ground: raw["ground"] as? Bool ?? true,
                           yaw: raw["yaw"] as? Double ?? 0,
                           steps: steps, walls: walls)
    }

    static func decode(_ data: Data) throws -> [String: DuckIntentClip] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hz = root["hz"] as? Double,
              let clips = root["clips"] as? [String: Any] else {
            throw LoadError.malformed("expected hz and clips")
        }
        var out: [String: DuckIntentClip] = [:]
        for (name, raw) in clips {
            guard let c = raw as? [String: Any],
                  let frames = c["frames"] as? [[Double]],
                  let rawRoots = c["roots"] as? [[Double]] else {
                throw LoadError.malformed("\(name) has no frames or roots")
            }
            let roots = rawRoots.map {
                Root(x: $0[0], y: $0[1], z: $0[2],
                     quaternion: ($0.count > 6 ? $0[3] : 1, $0.count > 6 ? $0[4] : 0,
                                  $0.count > 6 ? $0[5] : 0, $0.count > 6 ? $0[6] : 0))
            }
            out[name] = DuckIntentClip(
                name: name, hz: hz, frames: frames, roots: roots,
                netYaw: c["netYaw"] as? Double ?? 0,
                loops: c["loops"] as? Bool ?? false,
                startsFrom: Posture(rawValue: c["startsFrom"] as? String ?? "") ?? .standing,
                endsIn: Posture(rawValue: c["endsIn"] as? String ?? "") ?? .standing,
                policy: c["policy"] as? String ?? "unknown",
                authored: c["authored"] as? Bool ?? false,
                environment: environment(from: c["environment"] as? [String: Any]),
                credit: c["credit"] as? String)
        }
        return out
    }
}
