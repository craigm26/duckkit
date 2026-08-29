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

    // MARK: - the base a move is written against

    /// THE DEFECT THIS FORMAT VERSION EXISTS FOR. `pose(at:)` read a keyframe
    /// as an absolute pose and `applied(to:)` read the same array as an offset
    /// from a base handed to it separately. Both defaulted to the home pose, so
    /// they agreed by luck. Authored against anything else, they disagreed —
    /// and a motion downloaded from a hub is authored by somebody else.
    func testTheTwoReadingsAgreeForAMoveAuthoredAgainstAnotherBase() throws {
        var crouch = DuckModel.homePose
        crouch[DuckModel.jointIndex(of: "left_knee")!] += 0.5
        crouch[DuckModel.jointIndex(of: "right_knee")!] -= 0.5
        var reached = crouch
        reached[DuckModel.jointIndex(of: "neck_pitch")!] += 0.3

        let move = try DuckMove(validating: "reach from a crouch",
                                times: [0.4], poses: [reached], base: crouch)
        // Read one way: the keyframe is where the joints end up.
        XCTAssertEqual(move.pose(at: 0.4), reached)
        // Read the other way: the offset added to a policy holding the crouch
        // must land on the same place. Before the base was recorded, this
        // arrived at reached + (crouch - homePose) — wrong by the crouch.
        let applied = move.applied(to: crouch, at: 0.4)
        for joint in 0..<DuckModel.jointCount {
            XCTAssertEqual(applied[joint], reached[joint], accuracy: 1e-12,
                           DuckModel.jointNames[joint])
        }
    }

    /// A version-1 file has no base and never did: it means absolute poses
    /// against the home pose, and must keep meaning exactly that.
    func testAVersionOneFileStillReadsAsItAlwaysDid() throws {
        var pose = DuckModel.homePose
        pose[DuckModel.jointIndex(of: "head_yaw")!] = 0.4
        let json = """
        {"format":"duck-move/1","name":"look left","joints":\(
            try String(data: JSONSerialization.data(withJSONObject: DuckModel.jointNames),
                       encoding: .utf8)!),
         "times":[0.5],"poses":[\(
            try String(data: JSONSerialization.data(withJSONObject: pose), encoding: .utf8)!)]}
        """
        let contents = try DuckMoveFile.decode(Data(json.utf8))
        XCTAssertEqual(contents.move.base, DuckModel.homePose)
        XCTAssertEqual(contents.move.posesAre, .absolute)
        XCTAssertEqual(contents.move.pose(at: 0.5), pose)
    }

    /// A version-2 file says what it means, and round-trips saying it.
    func testTheBaseRoundTripsThroughTheFile() throws {
        var crouch = DuckModel.homePose
        crouch[DuckModel.jointIndex(of: "left_knee")!] += 0.4
        let move = try DuckMove(validating: "x", times: [0.2],
                                poses: [[Double](repeating: 0, count: DuckModel.jointCount)],
                                base: crouch, posesAre: .offset)
        let data = try DuckMoveFile.encode(name: "x", move: move)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "duck-move/2")
        XCTAssertEqual(object["posesAre"] as? String, "offset")
        let back = try DuckMoveFile.decode(data)
        XCTAssertEqual(back.move.base, crouch)
        XCTAssertEqual(back.move.posesAre, .offset)
        // An all-zero offset against the crouch resolves to the crouch itself.
        XCTAssertEqual(back.move.pose(at: 0.2), crouch)
    }

    /// A base of the wrong width, or a reading mode nobody has heard of, is
    /// refused in words rather than half-read.
    func testAMalformedBaseIsRefusedByName() throws {
        var pose = DuckModel.homePose
        pose[0] = 0.1
        func file(_ extra: String) -> Data {
            let joints = try! String(data: JSONSerialization.data(
                withJSONObject: DuckModel.jointNames), encoding: .utf8)!
            let poses = try! String(data: JSONSerialization.data(
                withJSONObject: pose), encoding: .utf8)!
            return Data("""
            {"format":"duck-move/2","name":"x","joints":\(joints),
             "times":[0.2],"poses":[\(poses)]\(extra)}
            """.utf8)
        }
        XCTAssertThrowsError(try DuckMoveFile.decode(file(",\"base\":[0.0,1.0]"))) {
            XCTAssertTrue("\($0)".contains("2 joints"), "\($0)")
        }
        XCTAssertThrowsError(try DuckMoveFile.decode(file(",\"posesAre\":\"sideways\""))) {
            XCTAssertTrue("\($0)".contains("neither absolute nor offset"), "\($0)")
        }
    }
}
