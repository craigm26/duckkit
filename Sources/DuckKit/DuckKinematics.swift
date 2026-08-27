import Foundation

/// Forward kinematics for the Microduck — 14 joint angles in, every body and
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
             sites: [Site(name: "head_camera", position: DuckVector(0.01175, 0.0, -0.0735)), Site(name: "mouth_tip", position: DuckVector(-0.00829334, 0.0, -0.0777383)), Site(name: "tof", position: DuckVector(0.0143, 0.0225, -0.0735)), Site(name: "head_imu", position: DuckVector(0.0114823, 0.000202447, -0.05126))]),
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
    /// standard joint order (the mouth is accepted and ignored — it is not in
    /// the walk model). The trunk sits at the model's rest height, 0.12 m.
    public static func bodyPoses(jointAngles: [Double]) -> [String: Pose] {
        precondition(jointAngles.count == DuckModel.jointCount, "expected all 15 joints")
        var poses: [String: Pose] = [:]
        for body in bodies {
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
            }
            poses[body.name] = Pose(position: position, orientation: orientation)
        }
        return poses
    }

    /// World positions of the model's sites — head camera, ToF, IMUs, feet,
    /// mouth tip — for 15 joint angles in standard order.
    public static func sitePositions(jointAngles: [Double]) -> [String: DuckVector] {
        let poses = bodyPoses(jointAngles: jointAngles)
        var sites: [String: DuckVector] = [:]
        for body in bodies {
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
