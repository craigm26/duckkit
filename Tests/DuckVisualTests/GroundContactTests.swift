import XCTest
import DuckKit
@testable import DuckVisual

/// Does the robot, as it will be DRAWN, actually reach the floor?
///
/// THE ASSERTION THAT WAS MISSING. Duck Studio shipped a build in which every
/// recorded motion played with the robot floating 116 mm above the ground — the
/// exact height of the trunk — because `DuckKinematics.bodyPoses` works in the
/// model's world frame, where `trunk_base` already sits at (0, 0, 0.12), while
/// a recorded root IS the trunk. Placing an entity of those poses at the root
/// adds the offset twice.
///
/// Nothing caught it because every existing test asked about poses, and a pose
/// is right in whichever frame you assume. This asks the question the eye asks:
/// take the vertices, put them where the renderer puts them, and find the
/// lowest one. On a robot standing on the floor that number is zero.
final class GroundContactTests: XCTestCase {

    private func bodies() throws -> [DuckMesh.Body] {
        let loaded = try DuckMesh.bundled()
        XCTAssertFalse(loaded.isEmpty)
        return loaded
    }

    /// The lowest vertex of the whole robot, in whatever frame `place` puts it.
    ///
    /// EVERY vertex, not every eleventh. `DuckGhostEntity`'s own floor
    /// measurement samples with a stride, which is defensible for a one-off
    /// AR offset and is not defensible in the test that has to catch a
    /// millimetre.
    private func lowestPoint(_ bodies: [DuckMesh.Body], jointAngles: [Double],
                             place: (DuckVector) -> DuckVector = { $0 }) -> Double {
        let poses = DuckKinematics.bodyPoses(jointAngles: jointAngles)
        var lowest = Double.greatestFiniteMagnitude
        for body in bodies {
            guard let pose = poses[body.name] else { continue }
            for i in stride(from: 0, to: body.positions.count, by: 3) {
                let local = DuckVector(Double(body.positions[i]),
                                       Double(body.positions[i + 1]),
                                       Double(body.positions[i + 2]))
                let world = pose.position + pose.orientation.rotate(local)
                lowest = min(lowest, place(world).z)
            }
        }
        return lowest
    }

    /// In the frame `bodyPoses` works in, the floor is z = 0 and the robot is
    /// standing on it. This is the fact everything else here depends on.
    func testTheKinematicFrameHasItsOriginOnTheFloor() throws {
        let lowest = lowestPoint(try bodies(), jointAngles: DuckModel.homePose)
        XCTAssertEqual(lowest, 0, accuracy: 0.005,
                       "in the model frame the home pose stands on z = 0")
        let trunk = try XCTUnwrap(
            DuckKinematics.bodyPoses(jointAngles: DuckModel.homePose)["trunk_base"])
        XCTAssertEqual(trunk.position.z, DuckKinematics.trunkOriginInModelFrame.z)
        XCTAssertEqual(trunk.position.z, 0.12, accuracy: 1e-12)
    }

    /// THE REGRESSION. Place the robot by a recorded root the way a renderer
    /// does, and its feet must be on the floor — not 116 mm above it.
    func testARecordedStandingFrameIsDrawnOnTheFloor() throws {
        let meshes = try bodies()
        let clips = try DuckIntentClip.bundled()
        let hold = try XCTUnwrap(clips["hold"])

        for tick in [0, hold.frames.count / 2, hold.frames.count - 1] {
            let pose = hold.pose(at: Double(tick) / hold.hz)
            let root = pose.root
            let quaternion = DuckQuaternion(w: root.quaternion.0, x: root.quaternion.1,
                                            y: root.quaternion.2, z: root.quaternion.3)
            let placement = DuckKinematics.placement(
                forRoot: DuckVector(root.x, root.y, root.z), orientation: quaternion)
            let lowest = lowestPoint(meshes, jointAngles: pose.jointAngles) { local in
                placement.position + placement.orientation.rotate(local)
            }
            XCTAssertEqual(lowest, 0, accuracy: 0.01,
                           "standing at tick \(tick), the lowest point should be on the floor "
                         + "and is at \(String(format: "%.1f", lowest * 1000)) mm")
        }
    }

    /// The naive placement — entity position straight from the root — is the
    /// bug, and it is wrong by exactly the trunk height. Asserted so nobody
    /// "simplifies" the helper back into it.
    func testPlacingStraightFromTheRootFloatsByTheTrunkHeight() throws {
        let meshes = try bodies()
        let hold = try XCTUnwrap(try DuckIntentClip.bundled()["hold"])
        let pose = hold.pose(at: 0)
        let naive = lowestPoint(meshes, jointAngles: pose.jointAngles) { local in
            DuckVector(local.x + pose.root.x, local.y + pose.root.y, local.z + pose.root.z)
        }
        XCTAssertEqual(naive, pose.root.z, accuracy: 0.01,
                       "the naive placement floats by the whole trunk height")
        XCTAssertGreaterThan(naive, 0.10, "which is over 100 mm on a 250 mm robot")
    }

    /// A duck mid-roulade is upside down, and an unrotated offset would push it
    /// through the floor exactly when it is most visible. The placement rotates
    /// the offset, so the trunk lands on the recorded root whatever the
    /// orientation.
    func testTheTrunkLandsOnTheRootEvenWhenTheRobotIsInverted() throws {
        let clips = try DuckIntentClip.bundled()
        for name in ["roulade", "back_roll", "headspin"] {
            let clip = try XCTUnwrap(clips[name])
            for tick in stride(from: 0, to: clip.frames.count, by: 17) {
                let pose = clip.pose(at: Double(tick) / clip.hz)
                let root = pose.root
                let quaternion = DuckQuaternion(w: root.quaternion.0, x: root.quaternion.1,
                                                y: root.quaternion.2, z: root.quaternion.3)
                let placement = DuckKinematics.placement(
                    forRoot: DuckVector(root.x, root.y, root.z), orientation: quaternion)
                // Where the entity puts its own trunk, back in the world.
                let poses = DuckKinematics.bodyPoses(jointAngles: pose.jointAngles)
                let trunk = try XCTUnwrap(poses["trunk_base"])
                let drawn = placement.position + placement.orientation.rotate(trunk.position)
                XCTAssertEqual(drawn.x, root.x, accuracy: 1e-9, "\(name) at \(tick)")
                XCTAssertEqual(drawn.y, root.y, accuracy: 1e-9, "\(name) at \(tick)")
                XCTAssertEqual(drawn.z, root.z, accuracy: 1e-9, "\(name) at \(tick)")
            }
        }
    }

    /// Across the whole corpus, no drawn frame sinks further under the floor
    /// than the visual meshes already explain.
    ///
    /// WHY THIS IS NOT ZERO, stated correctly at the second attempt. It is not
    /// that MuJoCo contacts simplified primitives inside these shells — all
    /// eleven of the model's collision geoms are meshes, sitting on their
    /// visual counterparts to within half a millimetre. It is that SEVEN OF THE
    /// FIFTEEN DRAWN BODIES HAVE NO COLLISION GEOMETRY: `yaw2roll`, both upper
    /// legs, `neck`, `neck_pitch`, `yaw_roll_motion`, `bearing_roll`. Those
    /// parts are drawn and cannot touch anything, so a duck on its side rests
    /// on the shells that do collide while a thigh passes through the floor.
    /// The worst case in the corpus is `step_up`, a clip that ends fallen after
    /// failing to climb. That is a rendering fact about which bodies collide,
    /// not a placement error: the placement is proved exact by
    /// `testTheTrunkLandsOnTheRootEvenWhenTheRobotIsInverted`, which puts the
    /// trunk on the recorded root to nine decimal places.
    ///
    /// The bar is a RATCHET, set just past what is measured today. It is here
    /// to catch a placement regression, which would blow past it by a hundred
    /// millimetres, not to police the mesh.
    func testNoRecordedFrameIsDrawnDeeperThanTheMeshesExplain() throws {
        let meshes = try bodies()
        var worst = 0.0, where_ = ""
        for (name, clip) in try DuckIntentClip.bundled() {
            for tick in stride(from: 0, to: clip.frames.count, by: 11) {
                let pose = clip.pose(at: Double(tick) / clip.hz)
                let root = pose.root
                let quaternion = DuckQuaternion(w: root.quaternion.0, x: root.quaternion.1,
                                                y: root.quaternion.2, z: root.quaternion.3)
                let placement = DuckKinematics.placement(
                    forRoot: DuckVector(root.x, root.y, root.z), orientation: quaternion)
                let lowest = lowestPoint(meshes, jointAngles: pose.jointAngles) { local in
                    placement.position + placement.orientation.rotate(local)
                }
                if lowest < worst { worst = lowest; where_ = "\(name) tick \(tick)" }
            }
        }
        XCTAssertGreaterThan(worst, -0.03,
                             "deepest penetration is \(String(format: "%.1f", worst * 1000)) mm at \(where_)")
        // And the deepest case is a clip that ends on the floor, not one that
        // is supposed to be standing on it.
        XCTAssertTrue(where_.hasPrefix("step_up") || where_.hasPrefix("headspin")
                      || where_.hasPrefix("roulade") || where_.hasPrefix("back_roll"),
                      "the deepest dip should be a motion that ends down, not \(where_)")
    }
}
