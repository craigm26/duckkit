import XCTest
@testable import DuckKit

/// `robot.state`, decoded, and held to the one property that makes it safe to
/// ship against a daemon whose schema is going to move: NOTHING MISSING IS
/// EVER ZERO. Most of these tests are the same claim from a different angle,
/// because it is the claim that decides whether a year of signed diary is
/// evidence or fiction — `fallen: false` for a robot whose safety block was
/// renamed is a hash-chained record that the duck never fell.
final class DuckStateTests: XCTestCase {

    /// A complete notification with all twelve documented fields. Also the
    /// line `DuckRPC` sizes its 256 KB cap against, so its length is asserted
    /// rather than described.
    private let fullLine = #"{"jsonrpc":"2.0","method":"robot.state","params":{"policy":"alpha_walking","safety":{"fallen":false,"limp":false},"loop":{"hz":50.0,"missed":0},"battery":{"volts":7.42,"percent":51.2},"odom":{"position":[1.234567,-0.891234],"yaw":0.7853981},"move":{"requested":[0.15,0.0,0.0],"applied":[0.15,0.0,0.0],"limited_by":[]}}}"#

    private let stamp = Date(timeIntervalSince1970: 1_800_000_000)

    /// Decode one line the way a socket would: through the stream decoder,
    /// then through `DuckState`. No shortcut, so these tests cover the seam.
    private func decode(_ line: String, at receivedAt: Date? = nil) -> DuckState? {
        var decoder = DuckRPC.StreamDecoder()
        guard let message = decoder.append(Data((line + "\n").utf8)).first else { return nil }
        return DuckState(message, receivedAt: receivedAt ?? stamp)
    }

    /// Wrap a params object in a `robot.state` envelope.
    private func line(params: String) -> String {
        #"{"jsonrpc":"2.0","method":"robot.state","params":"# + params + "}"
    }

    func testAFullNotificationDecodesEveryDocumentedField() throws {
        XCTAssertEqual(fullLine.utf8.count, 319,
                       "the 319-byte state line DuckRPC's cap arithmetic is written against")

        let state = try XCTUnwrap(decode(fullLine))
        XCTAssertEqual(state.policy, "alpha_walking")
        XCTAssertEqual(state.policyKind, .walk, "and it is one of the seven shipped networks")
        XCTAssertEqual(state.safety?.fallen, false)
        XCTAssertEqual(state.safety?.limp, false)
        XCTAssertEqual(state.loop?.hz ?? 0, DuckModel.tickHz, accuracy: 1e-9,
                       "the loop reports the rate the policies were trained at")
        XCTAssertEqual(state.loop?.missed, 0)
        XCTAssertEqual(state.battery?.volts ?? 0, 7.42, accuracy: 1e-9)
        XCTAssertEqual(state.battery?.percent ?? 0, 51.2, accuracy: 1e-9)
        XCTAssertEqual(state.odom?.x ?? 0, 1.234567, accuracy: 1e-12)
        XCTAssertEqual(state.odom?.y ?? 0, -0.891234, accuracy: 1e-12)
        XCTAssertEqual(state.odom?.yaw ?? 0, 0.7853981, accuracy: 1e-12)
        XCTAssertEqual(state.move?.limitedBy, [], "limited_by arrived, and nothing was limiting")
        let twist = try XCTUnwrap(state.move?.requestedTwist)
        XCTAssertEqual(twist.0, 0.15, accuracy: 1e-12, "vx, in the order DuckCommand.twist uses")
        XCTAssertEqual(twist.1, 0, accuracy: 1e-12)
        XCTAssertEqual(twist.2, 0, accuracy: 1e-12)
        XCTAssertFalse(state.isEmpty, "a full state is not the schema-drift canary")
        XCTAssertEqual(state.receivedAt, stamp, "stamped with the caller's clock, not the decoder's")
    }

    /// THE HEADLINE. A firmware that drops or renames `safety` must leave
    /// `fallen` unknown — not false, which is a robot that never fell.
    func testAMissingBlockReadsAsUnknownAndNeverAsAZero() throws {
        let state = try XCTUnwrap(decode(line(params: #"{"policy":"alpha_stand"}"#)))
        XCTAssertNil(state.safety, "no safety block means no answer about safety")
        XCTAssertNil(state.safety?.fallen, "and certainly not 'the duck is fine'")
        XCTAssertNil(state.odom, "the same for odometry, which would otherwise read as the origin")
        XCTAssertNil(state.battery?.volts, "and for the pack, which would otherwise read as flat")
        XCTAssertEqual(state.policyKind, .stand, "everything that did arrive still decoded")
        XCTAssertFalse(state.isEmpty, "one recognized field is not nothing")
    }

    /// A field whose *type* changed costs that field and nothing else. The
    /// alternative — one throw for the whole notification — would turn a
    /// renamed battery reading into a stream that has stopped reporting
    /// odometry, falls and policy as well.
    func testAMistypedFieldCostsOnlyThatFieldAndNotItsNeighbours() throws {
        let state = try XCTUnwrap(decode(line(params: """
            {"policy":"alpha_walking","safety":{"fallen":"yes","limp":false},\
            "battery":{"volts":"7.4V","percent":51.2},"odom":{"position":[1.0,2.0],"yaw":0.5}}
            """)))
        XCTAssertNil(state.safety?.fallen, "a string where a bool was is not a fall and not a stand")
        XCTAssertEqual(state.safety?.limp, false, "the field beside it is untouched")
        XCTAssertNil(state.battery?.volts, "a volts reading with a unit in it is not a number")
        XCTAssertEqual(state.battery?.percent ?? 0, 51.2, accuracy: 1e-9)
        XCTAssertEqual(state.odom?.x ?? 0, 1.0, accuracy: 1e-12, "and a whole other block survives")
    }

    /// Tolerant about extras: a firmware that adds a field must not break an
    /// app that shipped before it existed.
    func testFieldsThisBuildHasNeverHeardOfAreIgnored() throws {
        let state = try XCTUnwrap(decode(line(params: """
            {"policy":"alpha_walking","temperature":{"servo_c":41.5},"uptime_s":9312,\
            "safety":{"fallen":true,"limp":false,"tilted":true}}
            """)))
        XCTAssertEqual(state.safety?.fallen, true, "the fields that exist still decode")
        XCTAssertEqual(state.policy, "alpha_walking")
    }

    /// The canary: a line arrived, parsed as JSON, and contained nothing this
    /// build understands. That is a schema change, and it must be countable
    /// rather than silently averaged into a diary as an ordinary sample.
    func testAStateWithNothingRecognizableIsEmptyRatherThanAnErrorOrAZero() throws {
        let renamed = try XCTUnwrap(decode(line(params: """
            {"gait":"alpha_walking","health":{"down":false},"pose":{"xy":[1.0,2.0]}}
            """)))
        XCTAssertTrue(renamed.isEmpty, "every leaf is nil: the daemon renamed everything")
        XCTAssertEqual(renamed.receivedAt, stamp, "and the one fact it still carries is that it arrived")

        let bare = try XCTUnwrap(decode(line(params: "{}")))
        XCTAssertTrue(bare.isEmpty)

        let blocksPresentButEmpty = try XCTUnwrap(decode(line(params: #"{"safety":{},"odom":{}}"#)))
        XCTAssertTrue(blocksPresentButEmpty.isEmpty,
                      "blocks that arrived carrying nothing are still nothing")
    }

    func testOnlyARobotStateNotificationWithAnObjectForParamsDecodes() {
        XCTAssertNil(decode(#"{"jsonrpc":"2.0","method":"robot.health","params":{"policy":"x"}}"#),
                     "another method's params are not a state this decoder failed to read")
        XCTAssertNil(decode(#"{"jsonrpc":"2.0","method":"robot.state","params":[1,2,3]}"#),
                     "params that are not an object are not a state")
        XCTAssertNil(decode(#"{"jsonrpc":"2.0","method":"robot.state"}"#),
                     "and a state notification with no params at all is not one")
    }

    /// Staleness belongs to the value. A view's timer cannot know when a state
    /// arrived; the state can.
    func testStalenessIsAPropertyOfTheValueAndNotOfAViewsTimer() throws {
        let state = try XCTUnwrap(decode(fullLine))
        XCTAssertEqual(state.age(at: stamp.addingTimeInterval(0.5)), 0.5, accuracy: 1e-9)
        XCTAssertFalse(state.isStale(now: stamp.addingTimeInterval(0.1), after: 0.2),
                       "100 ms is five control ticks: fresh by any tolerance worth naming")
        XCTAssertTrue(state.isStale(now: stamp.addingTimeInterval(3), after: 2),
                      "three seconds is 150 missed samples")
        XCTAssertFalse(state.isStale(now: stamp.addingTimeInterval(-5), after: 2),
                       "a state stamped in the future is a clock problem, not a stale state")
        XCTAssertEqual(state.age(at: stamp.addingTimeInterval(-5)), -5, accuracy: 1e-9,
                       "and the negative age is reported rather than clamped away")
    }

    /// The robot's own pack fraction wins; the curve is only ever a fallback,
    /// and the two are never blended into a third number that is nobody's.
    func testTheDerivedBatteryFractionPrefersTheRobotsOwnReading() throws {
        let both = try XCTUnwrap(decode(line(params: #"{"battery":{"volts":7.4,"percent":42.0}}"#)))
        XCTAssertEqual(both.batteryPercentOrDerived ?? 0, 42.0, accuracy: 1e-9,
                       "the daemon owns the pack, so its number is the number")

        let voltsOnly = try XCTUnwrap(decode(line(params: #"{"battery":{"volts":7.4}}"#)))
        XCTAssertEqual(voltsOnly.batteryPercentOrDerived ?? 0, DuckModel.batteryPercent(volts: 7.4),
                       accuracy: 1e-12, "with no percent reported, DuckModel's curve fills in")

        let nothing = try XCTUnwrap(decode(line(params: #"{"policy":"alpha_stand"}"#)))
        XCTAssertNil(nothing.batteryPercentOrDerived, "and with no pack reading at all, no number")
    }

    /// Half a position is not a position. A one- or three-element array is a
    /// schema change, and reading `[0]` out of it would put the duck on the
    /// x axis of a map it is not on.
    func testAPositionThatIsNotExactlyTwoNumbersIsNotAPosition() throws {
        let three = try XCTUnwrap(decode(line(params: #"{"odom":{"position":[1.0,2.0,3.0],"yaw":0.5}}"#)))
        XCTAssertNil(three.odom?.x, "three coordinates are not the two this build knows how to read")
        XCTAssertNil(three.odom?.y)
        XCTAssertEqual(three.odom?.position?.count, 3, "but the array itself is kept, visibly")
        XCTAssertEqual(three.odom?.yaw ?? 0, 0.5, accuracy: 1e-12, "and yaw is unaffected")
    }

    /// The raw policy string survives even when this build has never heard of
    /// it — a diary recorded against next year's firmware should still say
    /// which network was running.
    func testAnUnknownPolicyNameIsCarriedEvenThoughItMatchesNoShippedNetwork() throws {
        let state = try XCTUnwrap(decode(line(params: #"{"policy":"alpha_swimming"}"#)))
        XCTAssertEqual(state.policy, "alpha_swimming", "verbatim")
        XCTAssertNil(state.policyKind, "and not forced onto one of the seven that exist")
        XCTAssertFalse(state.isEmpty, "an unrecognized value is not an unrecognized schema")
    }

    /// `move` is snake_case on the wire and camelCase in Swift, which is
    /// exactly the sort of mapping that is silently wrong until something
    /// asserts it.
    func testTheLimitedByListSurvivesTheSnakeCaseBoundary() throws {
        let state = try XCTUnwrap(decode(line(params: """
            {"move":{"requested":[0.2,0.0,0.0],"applied":[0.12,0.0,0.0],\
            "limited_by":["left_knee","right_ankle"]}}
            """)))
        XCTAssertEqual(state.move?.limitedBy, ["left_knee", "right_ankle"],
                       "the same joint names DuckGait reports when it holds one at a stop")
        let applied = try XCTUnwrap(state.move?.appliedTwist)
        XCTAssertEqual(applied.0, 0.12, accuracy: 1e-12,
                       "and the applied twist is not the requested one, which is the point of the block")
    }

    /// The clock crosses into the reducer's integer world through exactly one
    /// rule, and it is the reducer's.
    func testTheReceiveClockConvertsThroughTheReducersOneRoundingRule() throws {
        var state = try XCTUnwrap(decode(fullLine))
        state.receivedAt = Date(timeIntervalSince1970: 1234.5678)
        XCTAssertEqual(state.receivedAtMilliseconds, 1_234_568,
                       "floor(x + 0.5), the same rule every other unit in the reduction uses")
        state.receivedAt = Date(timeIntervalSince1970: .nan)
        XCTAssertNil(state.receivedAtMilliseconds, "a clock that is NaN is not a millisecond")
    }

    /// A state can be built rather than decoded — a simulated source is a
    /// first-class source, and it must be able to say "I do not know whether
    /// this duck fell" by leaving the field out.
    func testASynthesizedStateCanLeaveEverythingItDoesNotKnowUnknown() {
        let simulated = DuckState(
            policy: DuckPolicyKind.walk.rawValue,
            odom: DuckState.Odometry(position: [0.5, 0], yaw: 0),
            receivedAt: stamp)
        XCTAssertNil(simulated.safety?.fallen,
                     "a simulation with no physics cannot fall, and must not claim it did not")
        XCTAssertEqual(simulated.policyKind, .walk)
        XCTAssertEqual(simulated.odom?.x ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertFalse(simulated.isEmpty)
    }
}
