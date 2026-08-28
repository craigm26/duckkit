import XCTest
@testable import DuckKit

/// The framing, held against the ways a byte stream actually arrives.
///
/// A DECODER THAT IS TESTED ONLY WITH WHOLE MESSAGES IS UNTESTED. Every bug
/// this file exists to catch lives at a boundary somebody's test data never
/// crossed: the split inside a message, the two messages in one read, the CR
/// before the LF, the partial tail that is present after literally every read
/// of a live socket. So the central test is not an example, it is a table —
/// the same stream cut at every single one of its byte positions, and then cut
/// again by an adversarial list of chunkings — with one invariant: the
/// messages that come out, and their order, do not depend on how the bytes
/// came in. That invariant is all there is to hold on to, because the
/// transport preserves nothing else: not the boundaries, not the sizes, not
/// the timing.
final class DuckRPCTests: XCTestCase {

    // ── the stream under test ────────────────────────────────────────────

    /// Four lines chosen to be different in every way the envelope can be:
    /// a notification with no id, a successful response with no method, a
    /// refusal carrying a code and prose, and a line with multi-byte UTF-8 in
    /// it — because a split that lands in the middle of a `—` or a duck emoji
    /// must be held as bytes and not decoded as half a character.
    private let lines = [
        #"{"jsonrpc":"2.0","method":"robot.state","params":{"policy":"alpha_walking","safety":{"fallen":false,"limp":false}}}"#,
        #"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#,
        #"{"jsonrpc":"2.0","id":8,"error":{"code":-32000,"message":"kick_left is holding the robot"}}"#,
        #"{"jsonrpc":"2.0","method":"duck.named","params":{"name":"Café — 🦆"}}"#,
    ]

    /// What every chunking must produce: one descriptor per message, in order.
    private let expected = ["robot.state", "#7", "!8", "duck.named"]

    private func describe(_ message: DuckRPC.Message) -> String {
        if let method = message.method { return method }
        guard case .number(let id)? = message.id else { return "?" }
        return message.failed ? "!\(id)" : "#\(id)"
    }

    private func stream(terminator: String = "\n") -> Data {
        Data(lines.map { $0 + terminator }.joined().utf8)
    }

    /// Feed `chunks` in order and describe everything that came back.
    private func decode(_ chunks: [Data]) -> (messages: [String], decoder: DuckRPC.StreamDecoder) {
        var decoder = DuckRPC.StreamDecoder()
        var out: [String] = []
        for chunk in chunks {
            out.append(contentsOf: decoder.append(chunk).map(describe))
        }
        return (out, decoder)
    }

    // ── the table ────────────────────────────────────────────────────────

    /// Every single-byte split point of the same 329-byte stream: 330 cases,
    /// each one a message cut in a different place — inside a key, inside a
    /// number, inside a UTF-8 continuation byte, and, four times, exactly on a
    /// terminator, which is the split most likely to be handled by accident.
    func testEverySingleBytePositionIsASafePlaceToSplitTheStream() {
        let bytes = stream()
        for cut in 0...bytes.count {
            let head = bytes.prefix(cut)
            let tail = bytes.suffix(from: bytes.startIndex + cut)
            let result = decode([Data(head), Data(tail)])
            XCTAssertEqual(result.messages, expected,
                           "splitting after byte \(cut) of \(bytes.count) changed what came out")
            XCTAssertEqual(result.decoder.pendingBytes, 0,
                           "splitting after byte \(cut) left the decoder holding a partial line")
            XCTAssertEqual(result.decoder.malformedLines, 0, "no line here is malformed")
            XCTAssertEqual(result.decoder.refusedLines, 0, "no line here is over the cap")
        }
    }

    /// An adversarial table of chunkings: the whole stream at once, one byte
    /// at a time, aligned to the terminators, deliberately misaligned by one,
    /// empty reads interleaved, and a deterministic pseudorandom shredding.
    /// The seed is fixed so that a failure on the Pi is a failure that can be
    /// reproduced on a laptop.
    func testAnAdversarialTableOfChunkingsAllProduceTheSameMessages() {
        let bytes = stream()
        var cases: [(name: String, chunks: [Data])] = []

        cases.append(("the whole stream in one read", [bytes]))
        cases.append(("one byte per read", bytes.map { Data([$0]) }))
        cases.append(("nothing but empty reads, then everything", [Data(), Data(), bytes]))

        var lineAligned: [Data] = []
        for line in lines { lineAligned.append(Data((line + "\n").utf8)) }
        cases.append(("one whole line per read", lineAligned))

        var offByOne: [Data] = []
        var carry = Data()
        for line in lines {
            let framed = Data((line + "\n").utf8)
            offByOne.append(carry + framed.prefix(framed.count - 1))
            carry = Data(framed.suffix(1))
        }
        offByOne.append(carry)
        cases.append(("every read ends one byte before its terminator", offByOne))

        let cut = bytes.startIndex + 140
        cases.append(("the four lines in two reads, cut mid-message",
                      [Data(bytes[..<cut]), Data(bytes[cut...])]))

        // xorshift64*, so the shredding is identical on every machine.
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next(_ bound: Int) -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % UInt64(bound)) + 1
        }
        var shredded: [Data] = []
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            let take = min(next(23), bytes.endIndex - cursor)
            shredded.append(Data(bytes[cursor..<cursor + take]))
            cursor += take
        }
        cases.append(("pseudorandom chunks of 1…23 bytes", shredded))

        for test in cases {
            let result = decode(test.chunks)
            XCTAssertEqual(result.messages, expected, "chunking: \(test.name)")
            XCTAssertEqual(result.decoder.pendingBytes, 0,
                           "chunking: \(test.name) left a partial line behind")
        }
    }

    /// Two messages in one read is the normal case, not the exotic one: at
    /// 319 bytes a line and 50 Hz, a 1500-byte segment carries four of them.
    func testTwoMessagesInOneReadComeBackInArrivalOrder() {
        var decoder = DuckRPC.StreamDecoder()
        let both = Data((lines[0] + "\n" + lines[1] + "\n").utf8)
        let messages = decoder.append(both)
        XCTAssertEqual(messages.count, 2, "one read, two lines, two messages")
        XCTAssertEqual(messages.map(describe), ["robot.state", "#7"], "and in the order they were written")
    }

    /// The partial tail. `pendingBytes` is how a caller tells "the robot has
    /// gone quiet" from "the robot is mid-sentence", so it is part of the
    /// contract rather than a debugging aid.
    func testATrailingPartialLineIsHeldUntilItsTerminatorArrives() {
        var decoder = DuckRPC.StreamDecoder()
        let half = Data(lines[0].prefix(40).utf8)
        XCTAssertTrue(decoder.append(half).isEmpty, "half a line is not a message")
        XCTAssertEqual(decoder.pendingBytes, 40, "and it is being held, not dropped")
        let rest = Data((lines[0].dropFirst(40) + "\n").utf8)
        XCTAssertEqual(decoder.append(rest).map(describe), ["robot.state"], "the other half completes it")
        XCTAssertEqual(decoder.pendingBytes, 0, "and nothing is left over")
        XCTAssertEqual(decoder.malformedLines, 0, "a line in two halves is not a malformed line")
    }

    /// CRLF, which a bridge or a terminal-oriented relay can introduce. The
    /// CR is not part of the JSON and must not reach the parser — and must not
    /// reach `line` either, since those bytes are what a capture writes back
    /// out.
    func testCarriageReturnsAreStrippedFromLineEndings() {
        var decoder = DuckRPC.StreamDecoder()
        let messages = decoder.append(stream(terminator: "\r\n"))
        XCTAssertEqual(messages.map(describe), expected, "CRLF frames exactly as LF does")
        XCTAssertEqual(decoder.malformedLines, 0, "a carriage return is not a defect")
        XCTAssertEqual(messages[0].line, Data(lines[0].utf8),
                       "the kept bytes are the sender's, with no terminator and no CR")
    }

    // ── the cap ──────────────────────────────────────────────────────────

    /// A valid JSON-RPC line of exactly `total` bytes.
    private func padded(to total: Int) -> String {
        let prefix = #"{"jsonrpc":"2.0","method":"duck.pad","params":{"pad":""#
        let suffix = #""}}"#
        return prefix + String(repeating: "x", count: total - prefix.utf8.count - suffix.utf8.count) + suffix
    }

    /// The boundary, both sides of it. Exactly at the cap is kept; one byte
    /// past is refused. A cap that is only tested a megabyte past its limit
    /// is a cap whose comparison could be off by one in either direction.
    func testALineOfExactlyTheCapIsKeptAndOneByteMoreIsRefused() {
        let cap = DuckRPC.StreamDecoder.maxLineBytes
        XCTAssertEqual(padded(to: cap).utf8.count, cap, "the fixture is the size it claims")

        var atCap = DuckRPC.StreamDecoder()
        let kept = atCap.append(Data((padded(to: cap) + "\n").utf8))
        XCTAssertEqual(kept.map(describe), ["duck.pad"], "a line of exactly 262,144 bytes is a line")
        XCTAssertEqual(atCap.refusedLines, 0, "and it was not refused")

        var overCap = DuckRPC.StreamDecoder()
        let dropped = overCap.append(Data((padded(to: cap + 1) + "\n").utf8))
        XCTAssertTrue(dropped.isEmpty, "262,145 bytes is one byte too many")
        XCTAssertEqual(overCap.refusedLines, 1, "and the refusal is counted, not silent")
        XCTAssertEqual(overCap.malformedLines, 0, "a refused line was never read, so it is not malformed")
        XCTAssertEqual(overCap.pendingBytes, 0, "and none of it is still resident")
    }

    /// The failure the cap exists for: a sender that never emits a newline.
    /// The decoder must hold nothing and must recover the moment the stream
    /// makes sense again — a robot emitting garbage may not cost a phone its
    /// recording session.
    func testAnEndlessLineIsRefusedWithoutBufferingAndTheStreamResynchronizes() {
        var decoder = DuckRPC.StreamDecoder()
        let chunk = Data(repeating: 0x78, count: 64 * 1024) // "x", no terminator anywhere
        for read in 1...8 {
            XCTAssertTrue(decoder.append(chunk).isEmpty, "read \(read) of garbage produced a message")
            XCTAssertLessThanOrEqual(decoder.pendingBytes, DuckRPC.StreamDecoder.maxLineBytes,
                                     "the decoder is buffering past its own cap at read \(read)")
        }
        XCTAssertGreaterThanOrEqual(decoder.refusedLines, 1, "the endless line must have been refused")
        XCTAssertTrue(decoder.isResynchronizing, "and the decoder must be hunting for a terminator")

        // The tail of the refused line, then a good one, in the same read.
        let recovery = Data(("xxxx\n" + lines[0] + "\n").utf8)
        XCTAssertEqual(decoder.append(recovery).map(describe), ["robot.state"],
                       "the first newline after the refusal ends it and the next line decodes")
        XCTAssertFalse(decoder.isResynchronizing, "and the decoder is back in sync")
        XCTAssertEqual(decoder.pendingBytes, 0)
    }

    /// The refused line's tail spread over several reads: the hunt for a
    /// terminator has to survive the same chunking everything else does.
    func testTheTailOfARefusedLineIsSkippedAcrossHoweverManyReadsItTakes() {
        var decoder = DuckRPC.StreamDecoder()
        _ = decoder.append(Data(repeating: 0x78, count: DuckRPC.StreamDecoder.maxLineBytes + 1))
        XCTAssertEqual(decoder.refusedLines, 1)
        for _ in 0..<5 {
            XCTAssertTrue(decoder.append(Data(repeating: 0x78, count: 1024)).isEmpty,
                          "more of the refused line is still not a message")
            XCTAssertEqual(decoder.pendingBytes, 0, "and none of it is being held")
        }
        XCTAssertEqual(decoder.append(Data(("\n" + lines[1] + "\n").utf8)).map(describe), ["#7"],
                       "the terminator ends the refusal and the next line is read normally")
        XCTAssertEqual(decoder.refusedLines, 1, "one endless line is one refusal, not six")
    }

    // ── what is and is not a message ─────────────────────────────────────

    /// Blank lines are keepalives; garbage is counted. The difference matters
    /// because `malformedLines` ends up in a session record, where a number
    /// inflated by every heartbeat would mean nothing.
    func testBlankLinesAreKeepalivesAndUnreadableLinesAreCounted() {
        var decoder = DuckRPC.StreamDecoder()
        let mixed = "\n\r\n   \n" + lines[0] + "\n" + #"{"hello":1}"# + "\n" + "not json at all\n"
        let messages = decoder.append(Data(mixed.utf8))
        XCTAssertEqual(messages.map(describe), ["robot.state"], "one line in there was a message")
        XCTAssertEqual(decoder.malformedLines, 2,
                       "an object that is not JSON-RPC and a line that is not JSON, and nothing else")
    }

    /// Structure, not vocabulary. A JSON object with neither a method, an id
    /// nor an error is not a JSON-RPC message whatever else it contains — and
    /// a response to a parse error, which carries a null id and an error, is.
    func testAMessageMustNameAMethodAnswerAnIdOrReportAFailure() {
        var decoder = DuckRPC.StreamDecoder()
        let messages = decoder.append(Data((
            #"{"jsonrpc":"2.0","params":{"policy":"alpha_walking"}}"# + "\n"
            + #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"# + "\n"
        ).utf8))
        XCTAssertEqual(messages.count, 1, "params alone is not a message; a null-id refusal is")
        XCTAssertNil(messages[0].id, "the id really was null")
        XCTAssertEqual(messages[0].failure?.code, -32700)
        XCTAssertEqual(decoder.malformedLines, 1)
    }

    /// Tolerant about a missing version, strict about a wrong one.
    func testAVersionThisDecoderHasNotReadIsRefusedButAMissingOneIsNot() {
        var decoder = DuckRPC.StreamDecoder()
        let messages = decoder.append(Data((
            #"{"jsonrpc":"2.1","method":"robot.state","params":{}}"# + "\n"
            + #"{"method":"robot.state","params":{}}"# + "\n"
        ).utf8))
        XCTAssertEqual(messages.map(describe), ["robot.state"],
                       "2.1 is a protocol nobody here has read; a missing version is a terse daemon")
        XCTAssertEqual(decoder.malformedLines, 1)
    }

    func testTheEnvelopeTellsRequestsNotificationsAndResponsesApart() {
        var decoder = DuckRPC.StreamDecoder()
        let messages = decoder.append(Data((
            lines[0] + "\n" + lines[1] + "\n" + lines[2] + "\n"
            + #"{"jsonrpc":"2.0","id":9,"method":"robot.health"}"# + "\n"
        ).utf8))
        XCTAssertEqual(messages.count, 4)
        XCTAssertTrue(messages[0].isNotification, "a method with no id is the robot talking")
        XCTAssertTrue(messages[1].isResponse, "no method is an answer")
        XCTAssertTrue(messages[1].carriesResult, "and this one carried a result")
        XCTAssertFalse(messages[1].failed)
        XCTAssertTrue(messages[2].failed, "an error member is a refusal")
        XCTAssertFalse(messages[2].carriesResult, "which is not a result")
        XCTAssertEqual(messages[2].failure?.message, "kick_left is holding the robot")
        XCTAssertTrue(messages[3].isRequest, "a method with an id expects an answer")
    }

    /// A message keeps its own bytes, and `params` is decoded on demand by
    /// whoever knows the shape — the reason this file needs no JSON value type.
    func testAMessageKeepsItsOwnBytesAndDecodesParamsOnDemand() {
        struct Named: Decodable, Equatable { let name: String }
        var decoder = DuckRPC.StreamDecoder()
        let messages = decoder.append(Data((lines[3] + "\n").utf8))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].line, Data(lines[3].utf8), "byte for byte what the sender wrote")
        XCTAssertEqual(messages[0].params(as: Named.self), Named(name: "Café — 🦆"),
                       "including the multi-byte characters a split may have landed inside")
        XCTAssertNil(messages[0].params(as: Int.self), "a params block that is not what you asked for is nil")
    }

    // ── writing ──────────────────────────────────────────────────────────

    /// Sorted keys, one line, one terminator. A recorded stream is a fixture,
    /// and a fixture whose key order depends on a dictionary seed is not one.
    func testRequestsAndNotificationsEncodeAsOneSortedTerminatedLine() throws {
        struct Params: Encodable { let tag: String; let ms: Int }
        let request = try DuckRPC.request(id: .number(3), method: "duck.sound",
                                          params: Params(tag: "chirp", ms: 250))
        XCTAssertEqual(String(decoding: request, as: UTF8.self),
                       #"{"id":3,"jsonrpc":"2.0","method":"duck.sound","params":{"ms":250,"tag":"chirp"}}"# + "\n")

        let notification = try DuckRPC.notification(method: "duck.ping")
        XCTAssertEqual(String(decoding: notification, as: UTF8.self),
                       #"{"jsonrpc":"2.0","method":"duck.ping"}"# + "\n",
                       "no params member at all, rather than a null one")

        let bare = try DuckRPC.request(id: .string("abc"), method: "robot.health")
        XCTAssertEqual(String(decoding: bare, as: UTF8.self),
                       #"{"id":"abc","jsonrpc":"2.0","method":"robot.health"}"# + "\n",
                       "a string id survives the round trip it will be echoed on")
    }

    /// Everything this package writes must be readable by the thing that
    /// reads the robot — one decoder, both directions, no second parser.
    func testAnythingThisPackageWritesItsOwnDecoderCanRead() throws {
        struct Params: Encodable { let topic: String }
        var written = try DuckRPC.request(id: .number(1), method: "robot.subscribe",
                                          params: Params(topic: "state"))
        written.append(try DuckRPC.notification(method: "duck.ping"))
        var decoder = DuckRPC.StreamDecoder()
        let messages = decoder.append(written)
        XCTAssertEqual(messages.map(\.method), ["robot.subscribe", "duck.ping"])
        XCTAssertEqual(messages[0].id, .number(1))
        XCTAssertNil(messages[1].id, "a notification has no id to answer")
        XCTAssertEqual(decoder.malformedLines, 0)
    }

    // ── correlation ──────────────────────────────────────────────────────

    /// A response carries an id and nothing else, so the table is the only
    /// thing that can turn "-32000" into "the kick was refused".
    func testTheCorrelatorMatchesAnAnswerToTheMethodThatAskedForIt() throws {
        var correlator = DuckRPC.Correlator()
        let sound = try correlator.request("duck.sound")
        let skill = try correlator.request("duck.skill")
        XCTAssertNotEqual(sound.id, skill.id, "two calls in flight must be distinguishable")
        XCTAssertEqual(correlator.inFlightCount, 2)

        var decoder = DuckRPC.StreamDecoder()
        let answers = decoder.append(Data((
            #"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"kick_left is holding the robot"}}"# + "\n"
            + #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"# + "\n"
            + #"{"jsonrpc":"2.0","method":"robot.state","params":{}}"# + "\n"
        ).utf8))
        XCTAssertEqual(correlator.method(answering: answers[0]), "duck.skill",
                       "the second answer arrived first, which is why ids exist")
        XCTAssertEqual(correlator.method(answering: answers[1]), "duck.sound")
        XCTAssertNil(correlator.method(answering: answers[2]), "a notification answers nothing")
        XCTAssertEqual(correlator.inFlightCount, 0, "and both are off the table once matched")
        XCTAssertNil(correlator.method(answering: answers[0]),
                     "a duplicate answer is not the reply to anything still waiting")
    }

    /// Ids are never reused, not even after everything in flight is abandoned.
    /// A late answer from a dead connection must land on an id nobody holds,
    /// or it becomes the answer to a question somebody else asked.
    func testIdsAreNeverReusedAcrossAnAbandonedConnection() throws {
        var correlator = DuckRPC.Correlator()
        let first = try correlator.request("duck.skill")
        XCTAssertEqual(first.id, .number(1))
        let abandoned = correlator.abandonAll()
        XCTAssertEqual(abandoned, [.number(1): "duck.skill"], "and it says what it dropped")
        XCTAssertEqual(correlator.inFlightCount, 0)

        let second = try correlator.request("duck.skill")
        XCTAssertEqual(second.id, .number(2), "the next id is the next id, not the first one again")

        var decoder = DuckRPC.StreamDecoder()
        let stale = decoder.append(Data((#"{"jsonrpc":"2.0","id":1,"result":{}}"# + "\n").utf8))
        XCTAssertNil(correlator.method(answering: stale[0]),
                     "the dead connection's answer matches nothing, which is the truth")
    }
}
