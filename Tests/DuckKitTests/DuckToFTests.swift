import XCTest
@testable import DuckKit

/// The status byte is the whole point of this type, so most of these are about
/// the difference between "nothing there" and "I could not tell" — which is the
/// distinction any automation built on depth actually depends on.
final class DuckToFTests: XCTestCase {

    private func frame(distances: [Int], status: [UInt8]) -> DuckToF.Frame {
        DuckToF.Frame(sequence: 1, atMicroseconds: 1000, rows: 8, columns: 8,
                      distanceMillimetres: distances, status: status)
    }

    /// A uniform frame at one distance, with every zone valid.
    private func flat(_ millimetres: Int, status: UInt8 = 5) -> DuckToF.Frame {
        frame(distances: Array(repeating: millimetres, count: 64),
              status: Array(repeating: status, count: 64))
    }

    // MARK: - the three answers

    func testStatusFiveAndNineAreBothRanges() {
        XCTAssertEqual(flat(340, status: 5).zone(0), .range(0.34))
        XCTAssertEqual(flat(340, status: 9).zone(0), .range(0.34),
                       "status 9 is valid-with-large-pulse — still a range")
    }

    /// Empty space is information, and must not read as a failure.
    func testNoTargetIsDistinctFromAFailure() {
        let empty = flat(0, status: DuckToF.noTargetStatus)
        XCTAssertEqual(empty.zone(0), .noTarget)
        XCTAssertNil(empty.zone(0).metres, "there is no distance to report")
        XCTAssertEqual(empty.validCount, 0)
        XCTAssertEqual(empty.unusableCount, 0, "nothing FAILED — the room is empty")
        XCTAssertTrue(empty.isTrustworthy(), "a frame that saw nothing still saw")
    }

    func testAnUnusableZoneCarriesItsRawCode() {
        let bad = flat(200, status: 4)
        XCTAssertEqual(bad.zone(0), .unusable(4), "the code means something to ST's table")
        XCTAssertNil(bad.zone(0).metres)
        XCTAssertEqual(bad.unusableCount, 64)
    }

    /// The sensor occasionally returns a negative on a failed convergence. It
    /// is not a range whatever the status byte says, and a signed millimetre
    /// divided by 1000 would otherwise become a confident distance behind the
    /// robot's own head.
    func testANegativeDistanceIsNotARangeEvenWhenTheStatusIsValid() {
        let odd = frame(distances: [-1] + Array(repeating: 300, count: 63),
                        status: Array(repeating: 5, count: 64))
        XCTAssertEqual(odd.zone(0), .unusable(5))
        XCTAssertEqual(odd.nearest, 0.3, "and it does not become the nearest thing")
    }

    // MARK: - what an automation reads

    func testNearestFindsTheClosestUsableZone() throws {
        var distances = Array(repeating: 800, count: 64)
        distances[37] = 120
        let f = frame(distances: distances, status: Array(repeating: 5, count: 64))
        XCTAssertEqual(try XCTUnwrap(f.nearest), 0.12, accuracy: 1e-12)
        XCTAssertEqual(f.nearestZone, 37)
    }

    /// The trigger a custom intent should actually use.
    ///
    /// A duck on a floor sees that floor in its bottom rows permanently, so
    /// "is anything close?" answers yes forever and is worthless as a
    /// condition. The centre asks what is in FRONT of the robot.
    func testTheCentreIgnoresTheFloorTheEdgeAlwaysSees() throws {
        var distances = Array(repeating: 900, count: 64)
        // The bottom two rows are the floor, close and always there.
        for row in 6..<8 { for column in 0..<8 { distances[row * 8 + column] = 90 } }
        let f = frame(distances: distances, status: Array(repeating: 5, count: 64))
        XCTAssertEqual(try XCTUnwrap(f.nearest), 0.09, accuracy: 1e-12,
                       "the floor IS the nearest thing")
        XCTAssertEqual(try XCTUnwrap(f.nearestInCentre()), 0.9, accuracy: 1e-12,
                       "but nothing is in front of the duck")
    }

    func testColumnMeansAnswerWhichWayIsClearer() throws {
        var distances = Array(repeating: 1000, count: 64)
        for row in 0..<8 { distances[row * 8 + 1] = 200 }   // an obstacle to the left
        let f = frame(distances: distances, status: Array(repeating: 5, count: 64))
        let means = f.columnMeans
        XCTAssertEqual(try XCTUnwrap(means[1]), 0.2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(means[6]), 1.0, accuracy: 1e-12)
    }

    func testAColumnThatSawNothingUsableIsNilNotZero() throws {
        var status = Array(repeating: UInt8(5), count: 64)
        for row in 0..<8 { status[row * 8 + 3] = 4 }
        let f = frame(distances: Array(repeating: 500, count: 64), status: status)
        XCTAssertNil(f.columnMeans[3], "zero would read as 'touching the sensor'")
        XCTAssertNotNil(f.columnMeans[4])
    }

    /// A frame that mostly failed is not a measurement of an empty room. Glass
    /// and bright sun both do this, and an automation that cannot tell will
    /// drive into what it could not range.
    func testAMostlyFailedFrameIsNotTrustworthy() {
        var status = Array(repeating: UInt8(4), count: 64)
        for i in 0..<10 { status[i] = 5 }
        let f = frame(distances: Array(repeating: 400, count: 64), status: status)
        XCTAssertFalse(f.isTrustworthy())
        XCTAssertNotNil(f.nearest, "it still has readings — they are just not enough")
    }

    // MARK: - the wire

    func testItDecodesATofFrameNotification() throws {
        let json = """
        {"jsonrpc":"2.0","method":"tof.frame","params":{
          "seq":42,"at_us":123456,"rows":8,"cols":8,
          "distance_mm":\(Array(repeating: 250, count: 64)),
          "status":\(Array(repeating: 5, count: 64))}}
        """
        let f = try DuckToF.frame(fromJSON: Data(json.utf8))
        XCTAssertEqual(f.sequence, 42)
        XCTAssertEqual(f.atMicroseconds, 123456)
        XCTAssertEqual(f.rows, 8)
        XCTAssertEqual(f.validCount, 64)
        XCTAssertEqual(try XCTUnwrap(f.nearest), 0.25, accuracy: 1e-12)
    }

    /// A short array would shift every zone after the gap into the wrong place —
    /// a depth map that is plausible and rotated, which is worse than an error.
    func testAShortArrayIsRefusedRatherThanShiftingTheMap() {
        let params: [String: Any] = [
            "seq": 1, "at_us": 2, "rows": 8, "cols": 8,
            "distance_mm": Array(repeating: 100, count: 63),
            "status": Array(repeating: 5, count: 64),
        ]
        XCTAssertThrowsError(try DuckToF.frame(from: params)) { error in
            XCTAssertEqual(error as? DuckToF.DecodeError,
                           .lengthMismatch(expected: 64, distances: 63, status: 64))
        }
    }

    func testTheStreamAnswerCanSayThereIsNoSensor() throws {
        let s = try DuckToF.stream(from: [
            "accepted": false, "unavailable": "not fitted", "rows": 8, "cols": 8, "hz": 0])
        XCTAssertFalse(s.accepted)
        XCTAssertEqual(s.unavailable, "not fitted")
        XCTAssertNil(s.sensor, "and it does not invent a generation")
    }

    /// Both generations are in the field and which one answers is decided at
    /// runtime by an ID read, so nothing may assume either.
    func testTheStreamAnswerNamesWhicheverGenerationAnswered() throws {
        for generation in ["VL53L5CX", "VL53L8CX"] {
            let s = try DuckToF.stream(from: [
                "accepted": true, "sensor": generation, "rows": 8, "cols": 8, "hz": 15])
            XCTAssertEqual(s.sensor, generation)
            XCTAssertEqual(s.hz, 15)
        }
    }
}
