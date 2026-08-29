import XCTest
import DuckKit
@testable import DuckVisual

final class DuckGroundClearanceTests: XCTestCase {

    /// The exact answer, over every vertex of every body.
    private func exact(_ bodies: [DuckMesh.Body], jointAngles: [Double],
                       root: DuckIntentClip.Root) -> Double {
        let quaternion = DuckQuaternion(w: root.quaternion.0, x: root.quaternion.1,
                                        y: root.quaternion.2, z: root.quaternion.3)
        let placement = DuckKinematics.placement(
            forRoot: DuckVector(root.x, root.y, root.z), orientation: quaternion)
        let poses = DuckKinematics.bodyPoses(jointAngles: jointAngles)
        var lowest = Double.greatestFiniteMagnitude
        for body in bodies {
            guard let pose = poses[body.name] else { continue }
            for i in stride(from: 0, to: body.positions.count, by: 3) {
                let local = DuckVector(Double(body.positions[i]),
                                       Double(body.positions[i + 1]),
                                       Double(body.positions[i + 2]))
                let inModel = pose.position + pose.orientation.rotate(local)
                let world = placement.position + placement.orientation.rotate(inModel)
                lowest = min(lowest, world.z)
            }
        }
        return lowest
    }

    /// THE CLAIM IN THE DOC COMMENT, ASSERTED. The sample is worth having only
    /// if it agrees with the exact answer, and "agrees" has to be a number.
    func testTheSampleAgreesWithEveryVertexAcrossTheWholeCorpus() throws {
        let bodies = try DuckMesh.bundled()
        let probe = DuckGroundClearance(bodies: bodies)
        var worstError = 0.0, worstWhere = ""
        for (name, clip) in try DuckIntentClip.bundled() {
            for tick in stride(from: 0, to: clip.frames.count, by: 13) {
                let pose = clip.pose(at: Double(tick) / clip.hz)
                let sampled = probe.clearance(jointAngles: pose.jointAngles, root: pose.root)
                let truth = exact(bodies, jointAngles: pose.jointAngles, root: pose.root)
                // The sample can only ever be HIGHER than the truth — it is a
                // minimum over a subset — so a negative error would mean the
                // two computations disagree about more than which vertices.
                XCTAssertGreaterThanOrEqual(sampled, truth - 1e-9, "\(name) tick \(tick)")
                if sampled - truth > worstError {
                    worstError = sampled - truth
                    worstWhere = "\(name) tick \(tick)"
                }
            }
        }
        // Small enough that the legend cannot lie, measured rather than
        // wished: the first cut sampled 3.1 mm high on `climb`; the current
        // sampler's worst across re-recorded corpora has landed at 1.0-1.1 mm
        // (lever_up), so the bar sits just past that. It exists to catch a
        // sampling regression, which would blow through it by millimetres —
        // not to chase the last half-millimetre of a fallen clip.
        XCTAssertLessThan(worstError, 0.0015,
                          "worst sampling error is \(String(format: "%.2f", worstError * 1000)) mm at \(worstWhere)")
    }

    /// The number a stage prints. On a standing recording it is zero, and that
    /// is the whole point: the build that floated would have printed +116.
    func testAStandingRecordingReadsAsOnTheFloor() throws {
        let probe = try DuckGroundClearance.bundled()
        let hold = try XCTUnwrap(try DuckIntentClip.bundled()["hold"])
        for tick in [0, hold.frames.count / 2, hold.frames.count - 1] {
            let pose = hold.pose(at: Double(tick) / hold.hz)
            let clearance = probe.clearance(jointAngles: pose.jointAngles, root: pose.root)
            XCTAssertEqual(clearance, 0, accuracy: 0.01)
            XCTAssertTrue(DuckGroundClearance.summary(clearanceMetres: clearance)
                            .contains("on the floor"),
                          DuckGroundClearance.summary(clearanceMetres: clearance))
        }
    }

    /// And the sentence for the bug it exists to catch — plus the one it must
    /// NOT call a bug. A toppled duck sinking through the floor is seven
    /// bodies with no collision shape, not a fault, and colouring it as one
    /// taught the reader that a correct render was broken.
    func testOnlyFloatingIsReportedAsWrong() {
        XCTAssertTrue(DuckGroundClearance.summary(clearanceMetres: 0.1162)
                        .contains("nothing should be floating"))
        XCTAssertTrue(DuckGroundClearance.isWrong(clearanceMetres: 0.1162))

        let sunk = DuckGroundClearance.summary(clearanceMetres: -0.025)
        XCTAssertTrue(sunk.contains("through the floor"), sunk)
        XCTAssertTrue(sunk.contains("no collision shape"), sunk)
        XCTAssertTrue(sunk.hasPrefix("25 mm"), "the depth reads positive: \(sunk)")
        XCTAssertFalse(DuckGroundClearance.isWrong(clearanceMetres: -0.025))

        XCTAssertFalse(DuckGroundClearance.isWrong(clearanceMetres: 0.001))
    }

    /// It has to be cheap enough to run on every frame.
    func testItIsFastEnoughForFiftyHertz() throws {
        let probe = try DuckGroundClearance.bundled()
        let clip = try XCTUnwrap(try DuckIntentClip.bundled()["roulade"])
        let poses = (0..<clip.frames.count).map { clip.pose(at: Double($0) / clip.hz) }
        let start = Date()
        for pose in poses {
            _ = probe.clearance(jointAngles: pose.jointAngles, root: pose.root)
        }
        let perFrame = Date().timeIntervalSince(start) / Double(poses.count)
        // A frame at 50 Hz is 20 ms. A debug build on a Raspberry Pi is far
        // slower than an iPhone, so 4 ms here is a generous ceiling that still
        // fails if somebody drops the sampling and transforms every vertex.
        XCTAssertLessThan(perFrame, 0.004,
                          "\(String(format: "%.2f", perFrame * 1000)) ms per frame")
    }
}
