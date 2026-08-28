/// A scanned room, reduced to a scene the duck can be trained in.
///
/// WHY THIS IS HERE AND NOT IN THE APP THAT SCANS. `DuckSceneMJCF` already
/// turns a `Capture` into MuJoCo XML; the step before it — turning what a
/// depth-and-plane scanner saw into that `Capture` — is the half where the
/// mistakes actually live, and it is pure arithmetic over a handful of floats.
/// Left in an iOS target it can only be exercised by a person holding a phone
/// in a room, which is no way to check geometry. Here it runs under
/// `swift test` on a Pi.
///
/// THE INPUT DELIBERATELY IS NOT AN ARKit TYPE. `ScannedPlane` is six floats
/// and a flag, so nothing in this file needs a session, a device, or an Apple
/// framework, and the same reduction serves any scanner that can report a
/// rectangle — ARKit's plane anchors today, a RealityKit mesh's bounding boxes
/// or somebody's ROS point cloud later.
///
/// COORDINATES. Scanners overwhelmingly report Y-up (ARKit, Unity, glTF);
/// MuJoCo is Z-up. The conversion is (x, y, z) → (x, −z, y), a rotation of −90°
/// about X, so handedness is preserved and there is no mirroring to undo. It
/// happens once, here, rather than at each call site.
public enum DuckRoomReduction {

    /// One flat rectangle a scanner found, in the scanner's own Y-up frame.
    public struct ScannedPlane: Equatable, Sendable {
        /// Centre of the rectangle, metres, in the scanner's world frame.
        public var x: Double
        public var y: Double
        public var z: Double
        /// Full extents along the plane's own two axes, metres.
        public var extentX: Double
        public var extentZ: Double
        /// Rotation about the vertical axis, radians.
        public var yaw: Double
        /// True for a floor or a tabletop, false for a wall.
        public var isHorizontal: Bool

        public init(x: Double, y: Double, z: Double,
                    extentX: Double, extentZ: Double,
                    yaw: Double = 0, isHorizontal: Bool) {
            self.x = x
            self.y = y
            self.z = z
            self.extentX = extentX
            self.extentZ = extentZ
            self.yaw = yaw
            self.isHorizontal = isHorizontal
        }

        /// Area of the rectangle, which is what decides whether a plane is big
        /// enough to be considered a floor at all.
        public var area: Double { extentX * extentZ }
    }

    /// How thick a plane becomes when it has to be a box.
    ///
    /// A plane has no thickness and a MuJoCo geom must have one. 20 mm is small
    /// enough not to swallow a gap the duck could walk through — its stance is
    /// wider than that by an order of magnitude — and large enough that the
    /// solver is never handed a degenerate box.
    public static let planeThickness = 0.02

    /// A plane smaller than this in square metres cannot be the floor.
    /// Half a square metre is about the smallest patch of carpet a scanner
    /// reports that a person would still call "the floor".
    public static let minimumFloorArea = 0.5

    public enum Failure: Error, Equatable {
        /// Nothing horizontal was found, so there is no floor and no scene.
        case noHorizontalSurface
    }

    /// Planes in, scene description out.
    ///
    /// THE FLOOR IS THE LOWEST QUALIFYING HORIZONTAL PLANE, NOT THE LARGEST.
    /// A dining table easily presents more area to a scanner than the strip of
    /// carpet visible around it, so picking by area stands the duck on the
    /// table and files the floor as an obstacle — a scene that looks plausible
    /// and is upside down. Lowest wins; everything above it is furniture.
    ///
    /// If nothing clears `minimumFloorArea` the smallest-area rule is dropped
    /// rather than the whole scan: a scanner that has only seen one small patch
    /// of floor has still seen the floor, and refusing there would fail exactly
    /// when a person is pointing the phone at their feet waiting for something
    /// to happen.
    ///
    /// Obstacle heights are measured FROM the floor plane, not from the
    /// scanner's origin, because that origin is wherever tracking happened to
    /// start. A scene whose floor sits at z = −1.37 is one nobody can reason
    /// about, and the duck's own model puts the ground at zero.
    public static func reduce(
        planes: [ScannedPlane],
        namePrefixes: (horizontal: String, vertical: String) = ("surface", "wall")
    ) throws -> DuckSceneMJCF.Capture {
        let horizontals = planes.filter(\.isHorizontal)
        guard !horizontals.isEmpty else { throw Failure.noHorizontalSurface }

        let qualifying = horizontals.filter { $0.area >= minimumFloorArea }
        // `min(by:)` on ties returns the first, so a stable input gives a
        // stable floor; two planes at exactly the same height is a scanner
        // reporting one surface twice and either choice is the same scene.
        let floor = (qualifying.isEmpty ? horizontals : qualifying)
            .min(by: { $0.y < $1.y })!

        var obstacles: [DuckSceneMJCF.Obstacle] = []
        for (index, plane) in planes.enumerated() where plane != floor {
            // A horizontal plane is a slab: thin in the vertical. A vertical
            // one is a panel: thin in the direction it faces, and its second
            // extent is a HEIGHT rather than a depth, which is why the two
            // cases cannot share a line.
            let size: (x: Double, y: Double, z: Double) = plane.isHorizontal
                ? (plane.extentX, plane.extentZ, planeThickness)
                : (plane.extentX, planeThickness, plane.extentZ)

            obstacles.append(DuckSceneMJCF.Obstacle(
                name: name(prefixes: namePrefixes, isHorizontal: plane.isHorizontal, index: index),
                center: (x: plane.x - floor.x,
                         y: -(plane.z - floor.z),
                         z: plane.y - floor.y),
                size: size,
                yaw: plane.yaw))
        }

        return DuckSceneMJCF.Capture(
            floorHalfX: floor.extentX / 2,
            floorHalfY: floor.extentZ / 2,
            obstacles: obstacles)
    }

    /// Zero-padded so the names sort the way a person reads them —
    /// `wall_02` before `wall_10`, which plain interpolation gets backwards and
    /// `DuckSceneMJCF` sorts by name to keep its output deterministic.
    private static func name(prefixes: (horizontal: String, vertical: String),
                             isHorizontal: Bool, index: Int) -> String {
        let prefix = isHorizontal ? prefixes.horizontal : prefixes.vertical
        let digits = String(index)
        let padded = index < 10 ? "0" + digits : digits
        return prefix + "_" + padded
    }
}
