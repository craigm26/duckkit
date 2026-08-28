import XCTest
@testable import DuckKit

/// The reduction is the half of room capture where mistakes hide: a scene that
/// is upside down, or a metre off, or mirrored, still looks like a room. These
/// tests are the reason it lives in a package instead of an iOS target — every
/// one of them runs on a Pi with no phone and no room.
final class DuckRoomReductionTests: XCTestCase {

    /// A floor at y = 0 and a tabletop 0.75 m above it, plus a wall.
    private func room() -> [DuckRoomReduction.ScannedPlane] {
        [
            .init(x: 0, y: 0, z: 0, extentX: 4, extentZ: 3, isHorizontal: true),
            .init(x: 1, y: 0.75, z: -0.5, extentX: 1.2, extentZ: 0.8, isHorizontal: true),
            .init(x: 0, y: 1.2, z: 1.5, extentX: 4, extentZ: 2.4, isHorizontal: false),
        ]
    }

    func testFloorIsTheLowestSurfaceNotTheLargest() throws {
        // A table with MORE area than the visible floor. Picking by area would
        // stand the duck on the table; this is the bug the rule exists for.
        let planes: [DuckRoomReduction.ScannedPlane] = [
            .init(x: 0, y: 0, z: 0, extentX: 1.0, extentZ: 0.8, isHorizontal: true),   // floor patch
            .init(x: 0, y: 0.75, z: 0, extentX: 3.0, extentZ: 2.0, isHorizontal: true) // big table
        ]
        let capture = try DuckRoomReduction.reduce(planes: planes)
        XCTAssertEqual(capture.floorHalfX, 0.5, accuracy: 1e-12, "the floor is the LOW one")
        XCTAssertEqual(capture.floorHalfY, 0.4, accuracy: 1e-12)
        XCTAssertEqual(capture.obstacles.count, 1, "the table is furniture, not the floor")
        XCTAssertEqual(capture.obstacles[0].center.z, 0.75, accuracy: 1e-12,
                       "and it sits three quarters of a metre up")
    }

    /// The floor lands at zero even when the scanner's origin is nowhere near
    /// it — the case that happens every single time in practice, because the
    /// origin is wherever tracking started (roughly where the phone was held).
    func testHeightsAreMeasuredFromTheFloorNotTheScannerOrigin() throws {
        let offset = -1.37
        let planes: [DuckRoomReduction.ScannedPlane] = [
            .init(x: 2, y: offset, z: -3, extentX: 4, extentZ: 3, isHorizontal: true),
            .init(x: 2, y: offset + 0.45, z: -3, extentX: 0.5, extentZ: 0.5, isHorizontal: true)
        ]
        let capture = try DuckRoomReduction.reduce(planes: planes)
        let box = try XCTUnwrap(capture.obstacles.first)
        XCTAssertEqual(box.center.z, 0.45, accuracy: 1e-12, "height is above the FLOOR")
        XCTAssertEqual(box.center.x, 0, accuracy: 1e-12, "and the floor is the origin in x")
        XCTAssertEqual(box.center.y, 0, accuracy: 1e-12, "and in y")
    }

    /// Y-up in, Z-up out, with the sign on the horizontal axis that gets
    /// flipped. Getting this wrong mirrors the room, which is invisible in a
    /// symmetric one and catastrophic in a real one.
    func testTheAxisConversionIsYUpToZUp() throws {
        let planes: [DuckRoomReduction.ScannedPlane] = [
            .init(x: 0, y: 0, z: 0, extentX: 4, extentZ: 4, isHorizontal: true),
            // 1 m to the scanner's +x, 2 m along its +z, 0.5 m up.
            .init(x: 1, y: 0.5, z: 2, extentX: 0.3, extentZ: 0.3, isHorizontal: true)
        ]
        let box = try XCTUnwrap(DuckRoomReduction.reduce(planes: planes).obstacles.first)
        XCTAssertEqual(box.center.x, 1, accuracy: 1e-12, "x is carried straight through")
        XCTAssertEqual(box.center.y, -2, accuracy: 1e-12, "the scanner's +z becomes the model's −y")
        XCTAssertEqual(box.center.z, 0.5, accuracy: 1e-12, "the scanner's +y becomes the model's +z")
    }

    /// A wall is thin in the direction it faces and its second extent is a
    /// height; a tabletop is thin vertically. The two cannot share a formula,
    /// and swapping them gives a wall lying on the floor like a rug.
    func testWallsAreThinSidewaysAndSurfacesAreThinVertically() throws {
        let capture = try DuckRoomReduction.reduce(planes: room())
        let table = try XCTUnwrap(capture.obstacles.first { $0.name.hasPrefix("surface") })
        let wall = try XCTUnwrap(capture.obstacles.first { $0.name.hasPrefix("wall") })

        XCTAssertEqual(table.size.z, DuckRoomReduction.planeThickness, accuracy: 1e-12,
                       "a tabletop is a slab")
        XCTAssertEqual(table.size.x, 1.2, accuracy: 1e-12)
        XCTAssertEqual(table.size.y, 0.8, accuracy: 1e-12)

        XCTAssertEqual(wall.size.y, DuckRoomReduction.planeThickness, accuracy: 1e-12,
                       "a wall is a panel")
        XCTAssertEqual(wall.size.z, 2.4, accuracy: 1e-12,
                       "and its second extent is a HEIGHT, not a depth")
    }

    /// Names are zero-padded so that sorting them — which `DuckSceneMJCF` does
    /// to keep its output deterministic — puts 2 before 10.
    func testObstacleNamesSortNumerically() throws {
        var planes: [DuckRoomReduction.ScannedPlane] = [
            .init(x: 0, y: 0, z: 0, extentX: 6, extentZ: 6, isHorizontal: true)
        ]
        for i in 1...11 {
            planes.append(.init(x: Double(i) * 0.2, y: 0.3, z: 0,
                                extentX: 0.1, extentZ: 0.1, isHorizontal: false))
        }
        let names = try DuckRoomReduction.reduce(planes: planes).obstacles.map(\.name)
        XCTAssertEqual(names, names.sorted(), "already in order")
        XCTAssertTrue(names.contains("wall_02"))
        XCTAssertTrue(names.contains("wall_10"))
        XCTAssertLessThan("wall_02", "wall_10", "the padding is what makes this true")
    }

    /// A scanner that has only seen one small patch of floor has still seen the
    /// floor. Refusing there would fail exactly when someone is pointing the
    /// phone at their feet waiting for something to happen.
    func testASmallFloorIsStillAFloor() throws {
        let tiny = DuckRoomReduction.minimumFloorArea / 4
        let side = tiny.squareRoot()
        let capture = try DuckRoomReduction.reduce(planes: [
            .init(x: 0, y: 0, z: 0, extentX: side, extentZ: side, isHorizontal: true)
        ])
        XCTAssertEqual(capture.floorHalfX, side / 2, accuracy: 1e-12)
        XCTAssertTrue(capture.obstacles.isEmpty)
    }

    /// Walls alone are not a room. Refusing is right: emitting a scene with no
    /// floor would put the duck in freefall on the first step.
    func testWallsWithoutAFloorAreRefused() {
        let walls: [DuckRoomReduction.ScannedPlane] = [
            .init(x: 0, y: 1, z: 2, extentX: 3, extentZ: 2.4, isHorizontal: false)
        ]
        XCTAssertThrowsError(try DuckRoomReduction.reduce(planes: walls)) { error in
            XCTAssertEqual(error as? DuckRoomReduction.Failure, .noHorizontalSurface)
        }
    }

    /// The whole point of the type: what comes out goes straight into the MJCF
    /// emitter and produces a scene with the floor and every obstacle in it.
    func testTheCaptureEmitsAScene() throws {
        let xml = DuckSceneMJCF.scene(from: try DuckRoomReduction.reduce(planes: room()))
        XCTAssertTrue(xml.contains("<mujoco"), "it is a MuJoCo scene")
        XCTAssertTrue(xml.contains("name=\"floor\""))
        XCTAssertTrue(xml.contains("surface_01"), "the table survived the round trip")
        XCTAssertTrue(xml.contains("wall_02"), "and so did the wall")
    }
}
