import XCTest
import DuckKit
@testable import DuckVisual

/// The geometry is only useful if it lines up with the skeleton that poses it,
/// so most of these check the join between the two rather than the triangles.
final class DuckMeshTests: XCTestCase {

    func testEveryMeshBelongsToARealBody() throws {
        let known = Set(DuckKinematics.bodies.map(\.name))
        for name in try DuckMesh.bundledBodyNames() {
            XCTAssertTrue(known.contains(name),
                          "\(name) has geometry but no body to hang it on — the exporter's "
                          + "name mapping and DuckKinematics have drifted apart")
        }
    }

    /// Every body the kinematics know about has something to draw. A missing
    /// one is a limb that vanishes, which reads as a rendering bug rather than
    /// a missing asset.
    func testEveryBodyHasGeometry() throws {
        let drawn = Set(try DuckMesh.bundledBodyNames())
        for body in DuckKinematics.bodies {
            XCTAssertTrue(drawn.contains(body.name), "\(body.name) has no mesh")
        }
    }

    func testTheBuffersAreConsistent() throws {
        var triangles = 0
        for body in try DuckMesh.bundled() {
            XCTAssertEqual(body.positions.count % 3, 0, "\(body.name) positions")
            XCTAssertEqual(body.normals.count, body.positions.count,
                           "\(body.name) needs one normal per vertex")
            XCTAssertEqual(body.indices.count % 3, 0, "\(body.name) is a triangle list")
            XCTAssertFalse(body.indices.isEmpty, "\(body.name) has no faces")
            for index in body.indices {
                XCTAssertLessThan(Int(index), body.vertexCount,
                                  "\(body.name) indexes past its own vertices")
            }
            triangles += body.triangleCount
        }
        XCTAssertGreaterThan(triangles, 50_000, "this should be the real shape, not a stand-in")
        XCTAssertLessThan(triangles, 200_000, "and it should still fit in a phone's frame budget")
    }

    /// Normals must be unit length or lighting is wrong in a way that looks
    /// like a bad material rather than bad data.
    func testNormalsAreUnitLength() throws {
        for body in try DuckMesh.bundled() {
            for i in stride(from: 0, to: body.normals.count, by: 3 * 97) {
                let x = body.normals[i], y = body.normals[i+1], z = body.normals[i+2]
                XCTAssertEqual((x*x + y*y + z*z).squareRoot(), 1, accuracy: 1e-3, body.name)
            }
        }
    }

    /// A 25 cm robot. Any single part further than 30 cm from its own body
    /// origin means a transform was skipped and the part is somewhere else in
    /// the room.
    func testEveryPartSitsNearItsOwnBodyOrigin() throws {
        for body in try DuckMesh.bundled() {
            var worst: Float = 0
            for i in stride(from: 0, to: body.positions.count, by: 3) {
                let x = body.positions[i], y = body.positions[i+1], z = body.positions[i+2]
                worst = max(worst, (x*x + y*y + z*z).squareRoot())
            }
            XCTAssertLessThan(worst, 0.30,
                              "\(body.name) reaches \(worst) m from its origin")
        }
    }

    /// The head shell is the largest part, then the trunk — checked because a
    /// swap between bodies is otherwise invisible until someone looks at a
    /// duck with its head where its hip should be.
    ///
    /// The head being biggest is not what one would guess and is why this
    /// asserts the measured order rather than the expected one: it is a
    /// single moulded shell covering the whole head, while the trunk is
    /// several smaller parts and the legs are thin.
    func testTheHeadAndTrunkAreTheLargestParts() throws {
        let ranked = try DuckMesh.bundled()
            .sorted { $0.triangleCount > $1.triangleCount }
            .map(\.name)
        XCTAssertEqual(Array(ranked.prefix(2)), ["bottom_head_shell", "trunk_base"])
    }

    /// Left and right should be near mirror images. A large asymmetry means one
    /// side picked up a geom the other did not — the exact failure the per-body
    /// correction between the two model revisions exists to prevent.
    func testTheLegsAreSymmetric() throws {
        let bodies = try DuckMesh.bundled()
        func count(_ name: String) throws -> Int {
            try XCTUnwrap(bodies.first { $0.name == name }).triangleCount
        }
        let left = try count("ankle_left"), right = try count("ankle_right")
        XCTAssertEqual(Double(left), Double(right), accuracy: Double(left) * 0.05,
                       "the ankles differ by more than 5%: left \(left), right \(right)")
    }

    func testColoursComeFromTheModel() throws {
        let bodies = try DuckMesh.bundled()
        let distinct = Set(bodies.map { "\($0.rgba.r),\($0.rgba.g),\($0.rgba.b)" })
        XCTAssertGreaterThan(distinct.count, 1,
                             "the parts are not all one colour in the real model")
        for body in bodies {
            for channel in [body.rgba.r, body.rgba.g, body.rgba.b, body.rgba.a] {
                XCTAssertTrue((0...1).contains(channel), "\(body.name) has a colour out of range")
            }
        }
    }

    func testGarbageIsRefusedRatherThanDecoded() {
        XCTAssertThrowsError(try DuckMesh.decode(Data("not a mesh at all".utf8)))
        XCTAssertThrowsError(try DuckMesh.decode(Data()))
    }
}
