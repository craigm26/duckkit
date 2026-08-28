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
        // Rounded to the millimetre like every other measurement, so this is
        // 0.177 rather than 0.1767766952966369.
        XCTAssertEqual(capture.floorHalfX, 0.177, accuracy: 1e-12)
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

    // ── found on a real phone, 2026-08-28 ──────────────────────────────

    /// Names must not depend on the order the caller happened to store planes
    /// in. The app keeps them in a dictionary keyed by anchor id, so `values`
    /// arrives in no order at all — and a scene that renames its furniture
    /// between exports cannot be diffed against itself.
    func testNamingDoesNotDependOnInputOrder() throws {
        let planes = room()
        let forward = try DuckRoomReduction.reduce(planes: planes)
        let backward = try DuckRoomReduction.reduce(planes: planes.reversed())
        XCTAssertEqual(forward.obstacles.map(\.name), backward.obstacles.map(\.name),
                       "the same room must name its furniture the same way")
        for (a, b) in zip(forward.obstacles, backward.obstacles) {
            XCTAssertEqual(a.center.x, b.center.x, accuracy: 1e-12, a.name)
            XCTAssertEqual(a.size.z, b.size.z, accuracy: 1e-12, a.name)
        }
    }

    /// A shuffle is the real case — dictionary order is arbitrary, not merely
    /// reversed — so try a few and demand they all agree.
    func testEveryPermutationGivesTheSameScene() throws {
        let expected = DuckSceneMJCF.scene(from: try DuckRoomReduction.reduce(planes: room()))
        for _ in 0..<12 {
            let shuffled = room().shuffled()
            let actual = DuckSceneMJCF.scene(from: try DuckRoomReduction.reduce(planes: shuffled))
            XCTAssertEqual(actual, expected, "a shuffled scan produced a different scene")
        }
    }

    /// A phone reports a plane to a centimetre or two. Emitting `0.332041`
    /// claims microns, and a reader comparing two scans then sees six digits
    /// move and cannot tell noise from furniture.
    func testMeasurementsAreRoundedToMillimetres() throws {
        let capture = try DuckRoomReduction.reduce(planes: [
            .init(x: 0, y: 0, z: 0, extentX: 0.6640821, extentZ: 1.3374361, isHorizontal: true),
            .init(x: 0.1023391, y: 0.0772283, z: 0.0526556,
                  extentX: 0.7303762, extentZ: 1.0111641, yaw: 0.1490283, isHorizontal: true),
        ])
        XCTAssertEqual(capture.floorHalfX, 0.332, accuracy: 1e-12)
        XCTAssertEqual(capture.floorHalfY, 0.669, accuracy: 1e-12)
        let box = try XCTUnwrap(capture.obstacles.first)
        XCTAssertEqual(box.center.x, 0.102, accuracy: 1e-12)
        XCTAssertEqual(box.center.z, 0.077, accuracy: 1e-12)
        XCTAssertEqual(box.yaw, 0.149, accuracy: 1e-12)
        // And the emitted text carries no more digits than were measured. Note
        // this cannot assert the floor line reads 0.332: the DRAWN floor grows
        // to contain the table, which is a separate deliberate behaviour. The
        // invariant that actually matters is that nothing anywhere claims more
        // than millimetre precision.
        let xml = DuckSceneMJCF.scene(from: capture)
        XCTAssertFalse(xml.contains("0.332041"), "the false precision is gone")
        for match in xml.split(whereSeparator: { " \t\n\"=<>/".contains($0) }) {
            guard let dot = match.firstIndex(of: "."),
                  match.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) else { continue }
            let decimals = match.distance(from: match.index(after: dot), to: match.endIndex)
            // Four, not three: a box's HALF-extent is half of a
            // millimetre-rounded measurement, so 1.011 m wide is exactly
            // 0.5055 half-wide. That fourth digit is arithmetic, not a claim
            // about the instrument. Six digits would be the claim.
            XCTAssertLessThanOrEqual(decimals, 4,
                                     "\(match) claims precision the phone does not have")
        }
    }

    /// A scan routinely finds a tabletop wider than the patch of carpet the
    /// phone saw, and furniture hanging off the edge of the world looks like a
    /// geometry bug. The floor is DRAWN big enough to hold everything; the
    /// measured extent is untouched, because that is what the app reports.
    func testTheDrawnFloorContainsTheFurniture() throws {
        let capture = try DuckRoomReduction.reduce(planes: [
            .init(x: 0, y: 0, z: 0, extentX: 0.66, extentZ: 1.33, isHorizontal: true),
            .init(x: 0, y: 0.08, z: 0, extentX: 0.73, extentZ: 1.01, isHorizontal: true),
        ])
        XCTAssertEqual(capture.floorHalfX, 0.33, accuracy: 1e-9,
                       "the MEASURED floor is what was scanned and does not grow")
        let (renderX, renderY) = DuckSceneMJCF.renderedFloor(capture)
        let table = try XCTUnwrap(capture.obstacles.first)
        XCTAssertGreaterThanOrEqual(renderX, abs(table.center.x) + table.size.x / 2)
        XCTAssertGreaterThanOrEqual(renderY, abs(table.center.y) + table.size.y / 2)
        XCTAssertGreaterThan(renderX, capture.floorHalfX, "it had to grow for this room")
    }
}
