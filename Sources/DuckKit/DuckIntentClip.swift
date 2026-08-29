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

        public init(x: Double, y: Double, z: Double,
                    quaternion: (Double, Double, Double, Double)) {
            self.x = x; self.y = y; self.z = z; self.quaternion = quaternion
        }

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
    /// Which feet the recording was made on. Absent from every file before
    /// the rollers existed, so it defaults to legs.
    public let variant: DuckKinematics.Variant

    /// Who contributed it, for display only. Provenance is decided by the
    /// policy's fingerprint, never by this string.
    public let credit: String?

    /// What the policy emitted, what it was asked for, and how the trunk moved.
    ///
    /// WHY THE JOINT ANGLES ARE NOT ENOUGH. `frames` holds the robot's ACHIEVED
    /// joint positions, and most of Pollen's reward terms are not written
    /// against those: `action_rate_l2` differences the network's raw output,
    /// and the two velocity-tracking terms compare a commanded twist against
    /// the base's actual one. None of the three can be recovered afterwards —
    /// a target that a travel stop clipped is indistinguishable from one the
    /// policy never asked for, and the command is not a function of the pose at
    /// all. So they are recorded, or they are honestly absent.
    public struct Telemetry: Equatable, Sendable {
        /// The network's fourteen outputs per tick, before the gait scales them
        /// and before the travel stops clamp them.
        public let actions: [[Double]]
        /// (vx, vy, wz), as handed to the policy. What they MEAN is the
        /// policy's business — a velocity for the walkers, a phase clock for
        /// ground_pick, a flag for sitstand — so a reader must know which
        /// policy produced the clip before treating these as a velocity.
        public let commands: [[Double]]
        /// The trunk's own twist in its own frame: (vx, vy, vz, wx, wy, wz).
        public let twists: [[Double]]

        public init(actions: [[Double]], commands: [[Double]], twists: [[Double]]) {
            self.actions = actions; self.commands = commands; self.twists = twists
        }

        /// Nothing was recorded. TRUE for every clip written before format 3,
        /// and the reason anything reading this has to say "not recorded"
        /// rather than showing a column of zeros.
        public var isEmpty: Bool {
            actions.isEmpty && commands.isEmpty && twists.isEmpty
        }

        public static let none = Telemetry(actions: [], commands: [], twists: [])
    }

    public let telemetry: Telemetry

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

            public init(x: Double, y: Double, top: Double,
                        halfDepth: Double, halfWidth: Double, halfHeight: Double) {
                self.x = x; self.y = y; self.top = top
                self.halfDepth = halfDepth; self.halfWidth = halfWidth
                self.halfHeight = halfHeight
            }

            /// How far the top of this block stands above the top of another —
            /// the number that decides whether a duck can get up onto it. The
            /// robot has been MEASURED at a 10 mm ceiling, so this is the
            /// figure any scene editor has to put in front of someone before
            /// they build a staircase the robot cannot use.
            public func riseAbove(_ other: Step?) -> Double { top - (other?.top ?? 0) }
        }
        public struct Wall: Equatable, Sendable {
            public let x, y, halfThickness, height, halfLength: Double

            public init(x: Double, y: Double, halfThickness: Double,
                        height: Double, halfLength: Double) {
                self.x = x; self.y = y; self.halfThickness = halfThickness
                self.height = height; self.halfLength = halfLength
            }
        }
        public let ground: Bool
        /// How far the world is rotated relative to the clip's frame.
        public let yaw: Double
        public let steps: [Step]
        public let walls: [Wall]

        public init(ground: Bool, yaw: Double, steps: [Step], walls: [Wall]) {
            self.ground = ground; self.yaw = yaw; self.steps = steps; self.walls = walls
        }

        /// Bare floor — what a motion recorded with nothing in front of it was
        /// performed against, and the starting point for a scene somebody
        /// builds.
        public static let bareFloor = Environment(ground: true, yaw: 0, steps: [], walls: [])

        /// True when there is something to draw beyond the floor — what a UI
        /// checks before offering to show or hide the props.
        public var hasProps: Bool { !steps.isEmpty || !walls.isEmpty }
    }

    /// A clip assembled from somewhere other than the bundle — an imported
    /// `.duckintent`, or a motion recorded by another owner and shared.
    ///
    /// UNCHECKED ON PURPOSE, and the caller has to have checked. The decoder
    /// that reads a shared file is where the widths, the postures and the frame
    /// count get validated, and it refuses with a message naming what was
    /// wrong; putting a second set of preconditions here would turn that
    /// message into a crash. The rule is the same one `DuckMove` follows:
    /// untrusted numbers are validated at the door they come through, and the
    /// type is built only once they pass.
    public init(name: String, hz: Double, frames: [[Double]], roots: [Root],
                netYaw: Double, loops: Bool, startsFrom: Posture, endsIn: Posture,
                policy: String, authored: Bool, environment: Environment,
                credit: String? = nil, telemetry: Telemetry = .none,
                variant: DuckKinematics.Variant = .legs) {
        self.name = name; self.hz = hz; self.frames = frames; self.roots = roots
        self.netYaw = netYaw; self.loops = loops
        self.startsFrom = startsFrom; self.endsIn = endsIn
        self.policy = policy; self.authored = authored
        self.environment = environment; self.credit = credit
        self.telemetry = telemetry; self.variant = variant
    }

    /// The rate to compute with.
    ///
    /// ONE PLACE, because every consumer of `hz` divides or multiplies by it
    /// and every one of them breaks differently on a bad value: `pose(at:)`
    /// produced a negative index and trapped, `duration` produced infinity,
    /// and an infinite duration is a Slider range a view cannot draw. The
    /// decoder refuses a bad rate outright; this is what keeps a clip built
    /// through the public initializer from taking a renderer down with it.
    var rate: Double { hz.isFinite && hz > 0 ? hz : DuckModel.tickHz }

    /// A one-shot spans `count − 1` intervals: its last frame IS its end. A
    /// loop spans `count`, because it hands back to its first frame.
    public var duration: TimeInterval {
        Double(loops ? frames.count : max(frames.count - 1, 0)) / rate
    }

    /// The pose at a time.
    ///
    /// A one-shot CLAMPS at its final frame and reports `hasFinished`, rather
    /// than wrapping. A caller that keeps asking gets a duck standing where the
    /// motion left it, which is what the robot would actually be doing.
    public func pose(at time: TimeInterval) -> Pose {
        precondition(!frames.isEmpty, "an empty clip has no pose")
        // A NON-POSITIVE OR NON-FINITE RATE CANNOT PRODUCE AN INDEX, AND THIS
        // IS A RENDER-LOOP FUNCTION. A shared `.duckintent` carrying
        // `"hz": -50` made `exact` negative; the one-sided `guard exact <
        // frames.count - 1` below let it through, `index` came out −1, and
        // `frames[-1]` trapped about twenty milliseconds after the clip opened
        // — the playhead timer's first tick. Refusing the file is the
        // decoder's job; not crashing on one that got past it is this
        // function's, because a renderer has nowhere to put an error.
        let exact = max(time, 0) * rate
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
        // Clamped at BOTH ends. `roots[min(i, roots.count - 1)]` below only
        // ever guarded the upper one, so a negative index trapped there too.
        let last = frames.count - 1
        let i = min(max(i, 0), last), j = min(max(j, 0), last)
        let a = frames[i], b = frames[j]
        var angles = [Double](repeating: 0, count: DuckModel.jointCount)
        for slot in 0..<min(a.count, DuckModel.policyJointCount) {
            let value = a[slot] + (slot < b.count ? (b[slot] - a[slot]) * f : 0)
            angles[DuckModel.jointOfPolicySlot(slot)] = value
        }
        // The mouth is outside every policy's action space, so a recording
        // carries nothing for it. Home is the honest default.
        angles[DuckModel.mouthIndex] = DuckModel.homePose[DuckModel.mouthIndex]
        return Pose(jointAngles: angles,
                    root: roots[min(max(i, 0), max(roots.count - 1, 0))],
                    hasFinished: finished)
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
        // The decoder is where a bad rate gets a message. `pose(at:)` cannot
        // give one — it is called from a render loop and has nowhere to put it.
        guard hz.isFinite, hz > 0 else {
            throw LoadError.malformed("a rate of \(hz) frames a second is not a rate")
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
                credit: c["credit"] as? String,
                // ABSENT, NOT ZERO, on a format-2 file. A missing key here has
                // to stay missing all the way to the screen: a reward panel
                // that silently reads zeros would report a perfectly smooth
                // policy for a recording that never measured smoothness.
                telemetry: Telemetry(actions: c["actions"] as? [[Double]] ?? [],
                                     commands: c["commands"] as? [[Double]] ?? [],
                                     twists: c["twists"] as? [[Double]] ?? []),
                variant: DuckKinematics.Variant(rawValue: c["variant"] as? String ?? "legs") ?? .legs)
        }
        return out
    }
}
