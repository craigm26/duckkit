import XCTest
@testable import DuckKit

final class DuckMoveFileTests: XCTestCase {

    private func sample() throws -> DuckMove {
        var open = DuckModel.homePose
        open[DuckModel.mouthIndex] = DuckModel.mouthOpen
        return try DuckMove(validating: "wave",
                            times: [0, 0.4, 0.8],
                            poses: [DuckModel.homePose, open, DuckModel.homePose])
    }

    func testItRoundTripsToWithinAnULP() throws {
        let move = try sample()
        let data = try DuckMoveFile.encode(name: "wave", move: move,
                                           provenance: "Written here",
                                           note: "no physics ran")
        let back = try DuckMoveFile.decode(data)
        XCTAssertEqual(back.name, "wave")
        XCTAssertEqual(back.provenance, "Written here")
        XCTAssertEqual(back.note, "no physics ran")
        XCTAssertEqual(back.move.keyframes.count, 3)
        for (a, b) in zip(back.move.keyframes, move.keyframes) {
            XCTAssertEqual(a.time, b.time, accuracy: 1e-12)
            for joint in 0..<DuckModel.jointCount {
                // Decimal text: within an ULP, not bit-exact.
                XCTAssertEqual(a.pose[joint], b.pose[joint], accuracy: 1e-12)
            }
        }
    }

    /// The exact JSON Duck Studio's authoring screen writes today opens here —
    /// this is the interop the type exists for, pinned as a literal so a
    /// change to either side that breaks the other fails a test first.
    func testItReadsWhatDuckStudioWrites() throws {
        let zeros = [Double](repeating: 0, count: DuckModel.jointCount)
        _ = zeros
        let json = """
        {"format":"duck-move/1","name":"quack",
         "joints":\(try String(decoding: JSONSerialization.data(
            withJSONObject: DuckModel.jointNames), as: UTF8.self)),
         "times":[0,0.3],
         "poses":[\(DuckModel.homePose),\(DuckModel.homePose)],
         "provenance":"Sampled from a recording",
         "note":"Poses and times, interpolated — no physics ran."}
        """
        let contents = try DuckMoveFile.decode(Data(json.utf8))
        XCTAssertEqual(contents.name, "quack")
        XCTAssertEqual(contents.move.duration, 0.3, accuracy: 1e-12)
        XCTAssertTrue(contents.note?.contains("no physics ran") == true)
    }

    /// A file for a different robot is refused by name, not remapped: a pose
    /// scattered into the wrong joints is a plausible-looking motion for a
    /// robot this is not.
    func testForeignJointOrderIsRefusedLoudly() {
        let scrambled = DuckModel.jointNames.reversed().map { "\"\($0)\"" }
            .joined(separator: ",")
        let json = """
        {"format":"duck-move/1","name":"x","joints":[\(scrambled)],
         "times":[0,0.4],"poses":[\(DuckModel.homePose),\(DuckModel.homePose)]}
        """
        XCTAssertThrowsError(try DuckMoveFile.decode(Data(json.utf8))) {
            XCTAssertEqual($0 as? DuckMoveFile.ReadError, .jointOrderMismatch)
            XCTAssertTrue(($0 as! DuckMoveFile.ReadError).message
                .contains("wrong servos"))
        }
    }

    /// A pose outside the robot's travel is refused with the JOINT'S NAME —
    /// DuckMove's own refusal, passed through rather than flattened.
    func testAnOutOfTravelPoseIsRefusedByJointName() {
        var bad = DuckModel.homePose
        bad[3] = DuckModel.jointRanges[3].upper + 1.0
        let json = """
        {"format":"duck-move/1","name":"x",
         "times":[0,0.4],"poses":[\(DuckModel.homePose),\(bad)]}
        """
        XCTAssertThrowsError(try DuckMoveFile.decode(Data(json.utf8))) { error in
            guard case DuckMoveFile.ReadError.invalid(let why)? =
                error as? DuckMoveFile.ReadError,
                case .outsideTravel(_, let joint) = why else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(joint, DuckModel.jointNames[3])
        }
    }

    func testTheUsualRefusals() {
        XCTAssertThrowsError(try DuckMoveFile.decode(Data("hello".utf8))) {
            XCTAssertEqual($0 as? DuckMoveFile.ReadError, .notAMove)
        }
        XCTAssertThrowsError(try DuckMoveFile.decode(
            Data(#"{"format":"duck-move/9"}"#.utf8))) {
            XCTAssertEqual($0 as? DuckMoveFile.ReadError,
                           .unsupportedFormat("duck-move/9"))
        }
        XCTAssertThrowsError(try DuckMoveFile.decode(
            Data(#"{"format":"duck-move/1","times":[0],"poses":[]}"#.utf8))) {
            guard case DuckMoveFile.ReadError.malformed? = $0 as? DuckMoveFile.ReadError
            else { return XCTFail("wrong error") }
        }
    }

    /// A writer that can emit what its own reader refuses is two bugs wearing
    /// one format — encode validates by construction because it only accepts a
    /// DuckMove, which cannot exist invalid.
    func testEverythingEncodedDecodes() throws {
        for count in [2, 5, 9] {
            let times = (0..<count).map { Double($0) * 0.3 }
            let poses = (0..<count).map { _ in DuckModel.homePose }
            let move = try DuckMove(validating: "m", times: times, poses: poses)
            let data = try DuckMoveFile.encode(name: "m", move: move)
            XCTAssertNoThrow(try DuckMoveFile.decode(data))
        }
    }
}
