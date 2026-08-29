import Foundation

/// Forward kinematics for the Microduck — 15 joint angles in, every body and
/// sensor pose out, at the robot's true scale.
///
/// The chain below is the robot's own MuJoCo model (`robot_walk.xml`),
/// vendored under Tests fixtures and re-derived by `DuckKinematicsTests` so
/// these numbers cannot drift from upstream. This is what lets an AR view
/// place a 25 cm duck on a real floor with the camera site 24 cm up — because
/// that is where the model says it is, not because an artist eyeballed it.
///
/// The maths is deliberately dependency-free: `simd` does not exist on Linux,
/// and the whole computation is fifteen quaternion multiplies. At home pose
/// the feet land directly under the trunk (x ≈ 0.00002 m) — the upstream
/// authors' claim that the home pose puts the centre of mass over the ankle
/// axis, reproduced here as arithmetic and pinned as a test.
public enum DuckKinematics {

    public struct Body: Sendable {
        public let name: String
        public let parent: String?
        /// The hinge that articulates this body, or nil for the trunk root.
        /// Every hinge in this model rotates about its body-local Z axis.
        public let joint: String?
        public let position: DuckVector
        public let orientation: DuckQuaternion
        public let sites: [Site]
    }

    public struct Site: Sendable {
        public let name: String
        public let position: DuckVector
    }

    /// One body's pose in the trunk's world frame.
    public struct Pose: Equatable, Sendable {
        public let position: DuckVector
        public let orientation: DuckQuaternion
    }

    /// The body chain, exactly as `robot_walk.xml` declares it — positions in
    /// metres, orientations as (w, x, y, z) quaternions, both in the parent's
    /// frame. Every hinge in this model rotates about its body-local Z axis.
    /// Generated mechanically from the vendored MJCF; `DuckKinematicsTests`
    /// re-derives it from the fixture so it cannot drift.
    public static let bodies: [Body] = [
        Body(name: "trunk_base", parent: nil, joint: nil,
             position: DuckVector(0.0, 0.0, 0.12),
             orientation: DuckQuaternion(w: 1.0, x: 0.0, y: 0.0, z: 0.0),
             sites: [Site(name: "imu_bno", position: DuckVector(-0.032, 0.0140011, 0.0430618)), Site(name: "imu", position: DuckVector(-0.021, 6.53121e-05, -0.0148911))]),
        Body(name: "yaw2roll", parent: "trunk_base", joint: "left_hip_yaw",
             position: DuckVector(0.006, 0.0175, -0.005),
             orientation: DuckQuaternion(w: 0.0, x: -0.707107, y: -0.707107, z: -0.0),
             sites: []),
        Body(name: "hip_l", parent: "yaw2roll", joint: "left_hip_roll",
             position: DuckVector(-0.0, 0.0165, 0.0125),
             orientation: DuckQuaternion(w: 0.707107, x: -0.707107, y: -0.0, z: 0.0),
             sites: []),
        Body(name: "left_upper_leg", parent: "hip_l", joint: "left_hip_pitch",
             position: DuckVector(0.025, 0.0, -0.0185),
             orientation: DuckQuaternion(w: 0.5, x: -0.5, y: 0.5, z: -0.5),
             sites: []),
        Body(name: "leg", parent: "left_upper_leg", joint: "left_knee",
             position: DuckVector(0.022, 0.0357771, -0.004),
             orientation: DuckQuaternion(w: 0.0, x: 0.707107, y: 0.707107, z: -0.0),
             sites: []),
        Body(name: "ankle_left", parent: "leg", joint: "left_ankle",
             position: DuckVector(-0.0, 0.042, -0.026),
             orientation: DuckQuaternion(w: 0.0, x: 1.0, y: 0.0, z: -0.0),
             sites: [Site(name: "left_foot", position: DuckVector(-0.0, -0.0237879, -0.0140852))]),
        Body(name: "neck", parent: "trunk_base", joint: "neck_pitch",
             position: DuckVector(0.026, 0.0145011, 0.0324424),
             orientation: DuckQuaternion(w: 0.0, x: -0.0, y: -0.707107, z: 0.707107),
             sites: []),
        Body(name: "neck_pitch", parent: "neck", joint: "head_pitch",
             position: DuckVector(0.0, -0.05, 0.0),
             orientation: DuckQuaternion(w: 0.0, x: 1.0, y: 0.0, z: 0.0),
             sites: []),
        Body(name: "yaw_roll_motion", parent: "neck_pitch", joint: "head_yaw",
             position: DuckVector(-0.0, 0.0186931, -0.0145),
             orientation: DuckQuaternion(w: 0.0, x: -0.0, y: -0.707107, z: -0.707107),
             sites: []),
        Body(name: "bottom_head_shell", parent: "yaw_roll_motion", joint: "head_roll",
             position: DuckVector(-0.0179, 0.0, 0.0145),
             orientation: DuckQuaternion(w: 0.707107, x: -0.0, y: -0.707107, z: 0.0),
             sites: [Site(name: "head_camera", position: DuckVector(0.01175, 0.0, -0.0735)), Site(name: "tof", position: DuckVector(0.0143, 0.0225, -0.0735)), Site(name: "head_imu", position: DuckVector(0.0114823, 0.000202447, -0.05126))]),
                // THE JAW — the one body here that Pollen's MJCF does not have, and
        // an APPROXIMATION, labelled as such.
        //
        // The real robot has a fifteenth servo, `mouth`, and a moving lower
        // beak; Pollen's simulation plant fuses the beak into the head ("a
        // servo without an MJCF joint — the jaw is a fixed geom", their own
        // bake script says), because no policy drives it. Their plant also
        // says what the real mechanism is: "the closed loop linkage positions
        // it inside the head" (robot_allcollisions.xml, the contact-exclude
        // comment) — a linkage, not a bare hinge. onshape-to-robot cannot
        // export a closed loop, which is why the jaw came out fused.
        //
        // So this is a SINGLE-PIVOT STAND-IN for that linkage, built from
        // the one thing the file does place: the mouth servo. Its XL330 sits
        // in the head at (0.003, 0.0255, −0.018) with its horn toward the
        // head's +Y (servo-local −X, as at every other joint, where the horn
        // is 14.5 mm from the servo origin), which puts the horn — and this
        // pivot — at (0.003, 0.040, −0.018); the bearing at (0.0032, −0.040,
        // −0.018) is the axle's other end. The `jaw` mesh carries a hub of
        // vertices 3–9 mm from that line. Sense: +angle lowers the beak tip,
        // so the runtime's −5° closed … +30° open reads as pressed-shut to
        // wide. The angle→tip map is the hinge's, not the linkage's: treat the
        // opening as indicative, not as a measurement of the real beak.
        //
        // Hinge axis is body-local Z like every other joint; the orientation
        // is a −90° turn about X so that local Z is the head's +Y.
        Body(name: "jaw", parent: "bottom_head_shell", joint: "mouth",
             position: DuckVector(0.003, 0.040, -0.018),
             orientation: DuckQuaternion(w: 0.7071067811865476, x: -0.7071067811865476, y: 0.0, z: 0.0),
             sites: [Site(name: "mouth_tip", position: DuckVector(-0.01129334, 0.0597383, -0.040))]),
        Body(name: "bearing_roll", parent: "trunk_base", joint: "right_hip_yaw",
             position: DuckVector(0.006, -0.0175, -0.005),
             orientation: DuckQuaternion(w: 0.0, x: -0.707107, y: -0.707107, z: -0.0),
             sites: []),
        Body(name: "hip_l_2", parent: "bearing_roll", joint: "right_hip_roll",
             position: DuckVector(-0.0, 0.0165, 0.0125),
             orientation: DuckQuaternion(w: 0.0, x: -0.0, y: 0.707107, z: 0.707107),
             sites: []),
        Body(name: "right_upper_leg", parent: "hip_l_2", joint: "right_hip_pitch",
             position: DuckVector(0.025, 0.0, -0.0185),
             orientation: DuckQuaternion(w: 0.5, x: -0.5, y: 0.5, z: -0.5),
             sites: []),
        Body(name: "leg_2", parent: "right_upper_leg", joint: "right_knee",
             position: DuckVector(-0.022, 0.0357771, -0.004),
             orientation: DuckQuaternion(w: 0.0, x: 1.0, y: -0.0, z: -0.0),
             sites: []),
        Body(name: "ankle_right", parent: "leg_2", joint: "right_ankle",
             position: DuckVector(-0.042, -0.0, -0.026),
             orientation: DuckQuaternion(w: 0.0, x: -0.707107, y: 0.707107, z: 0.0),
             sites: [Site(name: "right_foot", position: DuckVector(-0.0, 0.0237879, -0.0140852))]),
    ]

    /// Poses for every body, keyed by body name, for 15 joint angles in
    /// standard joint order (the mouth drives the `jaw` body — ours, derived; see its comment). The trunk sits at the model's rest height, 0.12 m.
    /// Where `bodyPoses` puts the trunk, in the frame it works in.
    ///
    /// READ THIS BEFORE PLACING THE ROBOT ANYWHERE. `bodyPoses` does NOT return
    /// trunk-relative poses. Its root is the parentless body taken verbatim
    /// from the MJCF, which puts `trunk_base` at (0, 0, 0.12) — so the frame it
    /// works in is the MODEL WORLD, whose origin is the FLOOR with the robot
    /// standing 120 mm above it. An entity built by hanging these poses off a
    /// single parent therefore has its origin ON THE FLOOR, not at the trunk.
    ///
    /// A recording's root, by contrast, IS the trunk: it is the free joint's
    /// qpos for `trunk_base`. Setting an entity's position straight from a
    /// recorded root adds this offset on top of the one already baked in, and
    /// the robot is drawn floating by exactly the trunk height — 116 mm, which
    /// on a 250 mm robot is unmistakable and was shipped anyway. Use
    /// `placement(forRoot:)` rather than doing the arithmetic at a call site.
    public static let trunkOriginInModelFrame = DuckVector(0.0, 0.0, 0.12)

    /// Where to put an entity whose children came from `bodyPoses`, so that its
    /// trunk lands on a recorded root.
    ///
    /// The entity's internal trunk sits at `trunkOriginInModelFrame` with
    /// identity orientation, so to move that point onto `position` under
    /// rotation `orientation` the entity itself goes to
    /// `position − orientation·trunkOriginInModelFrame`. The rotation matters:
    /// a duck mid-roulade is upside down, and subtracting an unrotated 120 mm
    /// would push it through the floor exactly when it is most obvious.
    public static func placement(forRoot position: DuckVector,
                                 orientation: DuckQuaternion)
        -> (position: DuckVector, orientation: DuckQuaternion) {
        (position - orientation.rotate(trunkOriginInModelFrame), orientation)
    }

    /// Which feet the robot is wearing.
    ///
    /// Pollen ship two robot descriptions from the same CAD: the walker, and
    /// `robot_allcollisions_rollers.xml`, where each ankle body becomes a
    /// roller blade carrying two passive wheels. Everything above the ankles is
    /// identical, so the variant is a substitution of six bodies, not a second
    /// robot.
    public enum Variant: String, Sendable, CaseIterable {
        case legs, rollers
    }

    /// The six bodies that differ on rollers, from
    /// `robot_allcollisions_rollers.xml` (pollen-robotics/microduck_rl), read
    /// mechanically like the walker's table. The wheel joints are passive —
    /// not in the 15-wide pose — and turn with `wheelSpin`.
    public static let rollerBodies: [Body] = [
        Body(name: "ankle_l_v1", parent: "leg", joint: "left_ankle",
             position: DuckVector(0.0, 0.042, -0.026),
             orientation: DuckQuaternion(w: 0.0, x: 1.0, y: -0.0, z: 0.0),
             sites: [Site(name: "left_foot", position: DuckVector(-0.0, -0.0475, -0.0147))]),
        Body(name: "tire", parent: "ankle_l_v1", joint: "passive_LF_wheel",
             position: DuckVector(-0.0395, -0.0325, -0.0147),
             orientation: DuckQuaternion(w: 1.0, x: -0.0, y: 0.0, z: -0.0),
             sites: []),
        Body(name: "tire_2", parent: "ankle_l_v1", joint: "passive_LR_wheel",
             position: DuckVector(0.0255, -0.0325, -0.0147),
             orientation: DuckQuaternion(w: 1.0, x: -0.0, y: 0.0, z: -0.0),
             sites: []),
        Body(name: "ankle_r_v1", parent: "leg_2", joint: "right_ankle",
             position: DuckVector(-0.042, 0.0, -0.026),
             orientation: DuckQuaternion(w: 0.0, x: -0.707107, y: -0.707107, z: 0.0),
             sites: [Site(name: "right_foot", position: DuckVector(0.0, -0.0475, -0.0144819))]),
        Body(name: "tire_3", parent: "ankle_r_v1", joint: "passive_RF_wheel",
             position: DuckVector(0.0395, -0.0325, -0.0144819),
             orientation: DuckQuaternion(w: 0.0, x: -0.0, y: 1.0, z: -0.0),
             sites: []),
        Body(name: "tire_4", parent: "ankle_r_v1", joint: "passive_RR_wheel",
             position: DuckVector(-0.0255, -0.0325, -0.0144819),
             orientation: DuckQuaternion(w: 0.0, x: -0.0, y: 1.0, z: -0.0),
             sites: []),
    ]

    /// The body chain for a variant: the walker's table, or that table with
    /// both ankle bodies swapped for the roller blades and their wheels.
    public static func bodies(for variant: Variant) -> [Body] {
        switch variant {
        case .legs:
            return bodies
        case .rollers:
            let replaced: Set<String> = ["ankle_left", "ankle_right"]
            return bodies.filter { !replaced.contains($0.name) } + rollerBodies
        }
    }

    /// Body names that exist only in one variant — what a renderer must swap.
    public static func bodyNames(onlyIn variant: Variant) -> Set<String> {
        variant == .legs ? ["ankle_left", "ankle_right"] : Set(rollerBodies.map(\.name))
    }

    public static func bodyPoses(jointAngles: [Double]) -> [String: Pose] {
        bodyPoses(jointAngles: jointAngles, variant: .legs, wheelSpin: 0)
    }

    /// Where every body is, for a variant.
    ///
    /// `wheelSpin` is the wheels' rolled angle in radians, positive for
    /// forward travel: each passive wheel turns about its own axle in the
    /// sense that rolls the robot forward, whichever way that axle happens to
    /// point in its parent's frame — the right blade is a mirrored part, so
    /// its axles point the other way and a naive shared angle would spin one
    /// side backwards.
    public static func bodyPoses(jointAngles: [Double], variant: Variant,
                                 wheelSpin: Double = 0) -> [String: Pose] {
        precondition(jointAngles.count == DuckModel.jointCount, "expected all 15 joints")
        var poses: [String: Pose] = [:]
        for body in bodies(for: variant) {
            let parentPose: Pose
            if let parent = body.parent {
                guard let p = poses[parent] else { continue }
                parentPose = p
            } else {
                parentPose = Pose(position: DuckVector(0, 0, 0), orientation: DuckQuaternion.identity)
            }
            var position = parentPose.position + parentPose.orientation.rotate(body.position)
            var orientation = (parentPose.orientation * body.orientation).normalized
            if body.parent == nil {
                position = body.position
                orientation = body.orientation.normalized
            }
            if let joint = body.joint, let index = DuckModel.jointIndex(of: joint) {
                orientation = (orientation * DuckQuaternion(aboutZ: jointAngles[index])).normalized
            } else if let joint = body.joint, joint.hasPrefix("passive_"), wheelSpin != 0 {
                // Forward rolling is angular velocity along the world's +Y:
                // with +X forward and +Z up, ω = +Y carries the top of the
                // wheel (r = +Z) by ω × r = +X. (The first version said −Y and
                // every wheel moonwalked — the test now checks a rim point
                // moves forward, not an axis sign.) An axle whose local Z
                // points +Y takes +spin, one pointing −Y takes −spin.
                let axle = orientation.rotate(DuckVector(0, 0, 1))
                let sense: Double = axle.y > 0 ? 1 : -1
                orientation = (orientation * DuckQuaternion(aboutZ: wheelSpin * sense)).normalized
            }
            poses[body.name] = Pose(position: position, orientation: orientation)
        }
        return poses
    }

    /// World positions of the model's sites — head camera, ToF, IMUs, feet,
    /// mouth tip — for 15 joint angles in standard order.
    public static func sitePositions(jointAngles: [Double]) -> [String: DuckVector] {
        sitePositions(jointAngles: jointAngles, variant: .legs)
    }

    /// Site positions for a variant — the rollers' foot sites sit lower and
    /// further back than the walker's, at the blade rather than the sole.
    public static func sitePositions(jointAngles: [Double], variant: Variant) -> [String: DuckVector] {
        let poses = bodyPoses(jointAngles: jointAngles, variant: variant)
        var sites: [String: DuckVector] = [:]
        for body in bodies(for: variant) {
            guard let pose = poses[body.name] else { continue }
            for site in body.sites {
                sites[site.name] = pose.position + pose.orientation.rotate(site.position)
            }
        }
        return sites
    }
}

/// A 3-vector in metres. Not simd: simd does not exist on Linux, and the kit
/// tests there.
public struct DuckVector: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func + (a: DuckVector, b: DuckVector) -> DuckVector {
        DuckVector(a.x + b.x, a.y + b.y, a.z + b.z)
    }

    public static func - (a: DuckVector, b: DuckVector) -> DuckVector {
        DuckVector(a.x - b.x, a.y - b.y, a.z - b.z)
    }

    public var length: Double { (x * x + y * y + z * z).squareRoot() }
}

/// A unit quaternion, (w, x, y, z) — MuJoCo's component order.
public struct DuckQuaternion: Equatable, Sendable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = DuckQuaternion(w: 1, x: 0, y: 0, z: 0)

    /// Rotation by `angle` radians about the local Z axis — the only axis any
    /// joint in this model uses.
    public init(aboutZ angle: Double) {
        self.init(w: cos(angle / 2), x: 0, y: 0, z: sin(angle / 2))
    }

    public var normalized: DuckQuaternion {
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        guard n > 0 else { return .identity }
        return DuckQuaternion(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    public static func * (a: DuckQuaternion, b: DuckQuaternion) -> DuckQuaternion {
        DuckQuaternion(
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w
        )
    }

    /// Rotate a vector by this quaternion.
    public func rotate(_ v: DuckVector) -> DuckVector {
        let ux = x, uy = y, uz = z
        let dotUV = ux * v.x + uy * v.y + uz * v.z
        let dotUU = ux * ux + uy * uy + uz * uz
        let crossX = uy * v.z - uz * v.y
        let crossY = uz * v.x - ux * v.z
        let crossZ = ux * v.y - uy * v.x
        return DuckVector(
            2 * dotUV * ux + (w * w - dotUU) * v.x + 2 * w * crossX,
            2 * dotUV * uy + (w * w - dotUU) * v.y + 2 * w * crossY,
            2 * dotUV * uz + (w * w - dotUU) * v.z + 2 * w * crossZ
        )
    }
}
