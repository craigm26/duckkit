import Foundation

/// A scanned room, written as a MuJoCo scene the duck can train in.
///
/// THE INVERSION IS THE POINT. The sandbox everyone gets trains policies in
/// Pollen's rooms; this writes *yours*. The phone's LiDAR reduces a room to
/// floor + boxes (couch, table legs, the step that will actually defeat the
/// robot), and this type turns that summary into an MJCF file whose numbers
/// are true to your house at 1:1 scale — ready to drop next to
/// `robot_walk.xml` in the upstream training setup or the HF sandbox.
///
/// Deterministic on purpose: same capture in, byte-identical XML out
/// (obstacles sorted by name, fixed formatting), so a scene file can be
/// hashed, diffed and re-shared. Pure string assembly — no ARKit here; the
/// app-side capture reduces mesh anchors to `Obstacle` values and the kit
/// never sees a camera frame.
public enum DuckSceneMJCF {

    /// An axis-aligned-ish box in the room, metres, yaw about vertical.
    public struct Obstacle: Equatable, Sendable {
        public let name: String
        /// Box centre in the scene frame, metres.
        public let center: (x: Double, y: Double, z: Double)
        /// Full extents, metres.
        public let size: (x: Double, y: Double, z: Double)
        /// Rotation about vertical, radians.
        public let yaw: Double

        public init(name: String, center: (x: Double, y: Double, z: Double),
                    size: (x: Double, y: Double, z: Double), yaw: Double = 0) {
            self.name = name
            self.center = center
            self.size = size
            self.yaw = yaw
        }

        public static func == (l: Obstacle, r: Obstacle) -> Bool {
            l.name == r.name && l.center == r.center && l.size == r.size && l.yaw == r.yaw
        }
    }

    /// A captured room: a floor extent and the obstacles found on it.
    public struct Capture: Equatable, Sendable {
        /// Half-extents of the walkable floor, metres.
        public let floorHalfX: Double
        public let floorHalfY: Double
        public let obstacles: [Obstacle]

        public init(floorHalfX: Double, floorHalfY: Double, obstacles: [Obstacle]) {
            self.floorHalfX = floorHalfX
            self.floorHalfY = floorHalfY
            self.obstacles = obstacles
        }
    }

    /// Write the scene. `modelName` becomes the MJCF model attribute;
    /// obstacles are emitted sorted by name so output is deterministic.
    ///
    /// The duck itself is not inlined — the emitted scene `<include>`s the
    /// upstream `robot_walk.xml`, which keeps the robot's numbers upstream's
    /// problem and this file's numbers the room's.
    public static func scene(from capture: Capture, modelName: String = "captured-room") -> String {
        var lines: [String] = []
        lines.append("<?xml version='1.0' encoding='utf-8'?>")
        lines.append("<mujoco model=\"\(escaped(modelName))\">")
        lines.append("  <compiler angle=\"radian\" autolimits=\"true\" />")
        lines.append("  <include file=\"robot_walk.xml\" />")
        lines.append("  <worldbody>")
        lines.append(String(
            format: "    <geom name=\"floor\" type=\"plane\" size=\"%@ %@ 0.05\" rgba=\"0.9 0.9 0.9 1\" />",
            number(capture.floorHalfX), number(capture.floorHalfY)))
        for obstacle in capture.obstacles.sorted(by: { $0.name < $1.name }) {
            let halfX = number(obstacle.size.x / 2)
            let halfY = number(obstacle.size.y / 2)
            let halfZ = number(obstacle.size.z / 2)
            let pos = "\(number(obstacle.center.x)) \(number(obstacle.center.y)) \(number(obstacle.center.z))"
            let euler = "0 0 \(number(obstacle.yaw))"
            lines.append(
                "    <geom name=\"\(escaped(obstacle.name))\" type=\"box\" size=\"\(halfX) \(halfY) \(halfZ)\" "
                + "pos=\"\(pos)\" euler=\"\(euler)\" rgba=\"0.6 0.6 0.65 1\" />")
        }
        lines.append("  </worldbody>")
        lines.append("</mujoco>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Six significant decimals, no scientific notation, no locale — a
    /// number that means the same thing in every MuJoCo build.
    static func number(_ value: Double) -> String {
        let formatted = String(format: "%.6f", value)
        // Trim trailing zeros but keep at least one decimal digit, so 0.5
        // reads 0.5 and 0 reads 0.0 — stable, human-checkable output.
        var trimmed = formatted
        while trimmed.hasSuffix("0") && !trimmed.hasSuffix(".0") {
            trimmed.removeLast()
        }
        return trimmed
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
