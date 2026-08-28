import Foundation

/// JSON-RPC 2.0 over NDJSON, with no transport underneath it.
///
/// THE PROTOCOL IS TRIVIAL AND THE FRAMING IS NOT. `robotd` speaks JSON-RPC
/// 2.0 as newline-delimited JSON — one object, one line — and a phone reaches
/// that socket across a LAN bridge, so the bytes arrive in whatever chunks TCP
/// felt like producing. A `robot.state` notification carrying all twelve
/// documented fields is 319 bytes; at the control loop's 50 Hz that is about
/// 16 KB a second, so a single 1500-byte segment holds four whole lines and
/// part of a fifth — *always*, not occasionally. A decoder that assumes one
/// read is one message is correct on loopback, correct against a unit test
/// that hands it a whole file at once, and wrong on a wifi network: splitting
/// each read on newlines and discarding the leftover tail throws away 0.7 of
/// every 4.7 lines, roughly one message in seven. It throws them away
/// silently, which is the real damage — a discarded tail is not marked
/// anywhere, so a fall reported in one simply never happened, and the diary
/// reads like a robot that did less rather than like a parser that ate the
/// evidence.
///
/// So `StreamDecoder` is written against the five things that actually
/// happen — a message split across two reads, two messages in one read, CRLF
/// from a bridge that rewrote the stream, a partial line at the end of every
/// read, and a line that never ends.
///
/// AND IT MUST REFUSE TO GROW. The last of those is the dangerous one. A
/// wedged serializer, a binary frame delivered to the wrong port, a bridge
/// that forwards a file — any of them produces bytes with no newline in them,
/// and a decoder that simply buffers until the next terminator will hold
/// every one of those bytes until iOS kills the app and takes the recording
/// session with it. Past `maxLineBytes` — 256 KB, which is 821 state lines,
/// sixteen seconds of the entire stream arriving as ONE line — the line is
/// discarded, the buffer's memory is handed back, and the decoder hunts
/// forward to the next newline and carries on. Refusing one line loses one
/// line. Buffering it loses the hour.
///
/// TRANSPORT-FREE, ON PURPOSE: `Data` in, `Message` out. `NWConnection` stays
/// in the app, which is what lets the hard part — the framing — be tested on a
/// Pi against a recorded stream, and what lets one decoder read a socket, a
/// file and a fixture without knowing which it is.
///
/// A message keeps its own bytes. That is deliberate too: the alternative is a
/// general JSON value type in a package that has deliberately never grown one,
/// and the bytes are the evidence anyway — a line that produced a diary entry
/// can be written back out exactly as the robot wrote it.
public enum DuckRPC {

    /// The one version string this decoder claims to read. A line that names
    /// a different one is refused; see `StreamDecoder`.
    public static let version = "2.0"

    // ── the pieces of a message ──────────────────────────────────────────

    /// A request id. JSON-RPC 2.0 allows a number or a string, and this
    /// package only ever mints numbers — but a daemon is free to echo an id
    /// as text, and a correlation table that could not hold the echo would
    /// silently strand every response.
    public enum ID: Hashable, Sendable, Codable {
        case number(Int64)
        case string(String)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) {
                self = .number(number)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "a JSON-RPC id is a number or a string")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let number): try container.encode(number)
            case .string(let string): try container.encode(string)
            }
        }
    }

    /// The `error` member of a response. Both fields are optional for the
    /// same reason every field of `DuckState` is: a daemon that ships a
    /// refusal with no code is still telling you it refused, and dropping the
    /// whole message over a missing integer would turn "the robot said no"
    /// into "the robot said nothing".
    public struct Failure: Equatable, Sendable, Decodable {
        public let code: Int?
        public let message: String?

        public init(code: Int?, message: String?) {
            self.code = code
            self.message = message
        }

        private enum CodingKeys: String, CodingKey { case code, message }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.code = (try? container.decodeIfPresent(Int.self, forKey: .code)) ?? nil
            self.message = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? nil
        }
    }

    /// One decoded line: its envelope, plus the bytes it came from.
    ///
    /// The envelope is all this type reads. `params` and `result` carry
    /// shapes that only their method knows, so they are left in `line` and
    /// decoded on demand by whoever knows what they should be —
    /// `DuckState.init(_:receivedAt:)` is the first caller and not the last.
    public struct Message: Equatable, Sendable {
        /// Present on requests and responses, absent on notifications. A
        /// `robot.state` line has no id, which is exactly what makes it a
        /// notification rather than an answer to something.
        public let id: ID?
        /// Present on requests and notifications, absent on responses.
        public let method: String?
        /// Present when the daemon refused. Mutually exclusive with a result
        /// in a well-formed response; this type does not enforce that,
        /// because a decoder is not the place to argue with a daemon.
        public let failure: Failure?
        /// Whether the line carried a `result` member at all — the difference
        /// between "the call succeeded and returned null" and "this is not a
        /// response".
        public let carriesResult: Bool
        /// The line as it arrived, terminator and any carriage return
        /// removed. Byte-for-byte what the sender wrote.
        public let line: Data

        public init(
            id: ID?, method: String?, failure: Failure? = nil,
            carriesResult: Bool = false, line: Data
        ) {
            self.id = id
            self.method = method
            self.failure = failure
            self.carriesResult = carriesResult
            self.line = line
        }

        /// A method with no id: the robot talking, not answering.
        public var isNotification: Bool { method != nil && id == nil }
        /// A method with an id: somebody expecting an answer.
        public var isRequest: Bool { method != nil && id != nil }
        /// No method: an answer, successful or refused.
        public var isResponse: Bool { method == nil }
        /// The daemon said no.
        public var failed: Bool { failure != nil }

        /// The `params` member, decoded as whatever the caller knows it to
        /// be. Returns nil rather than throwing: a params block that does not
        /// match its method is a schema change, and the caller who asked is
        /// the one who can count it.
        public func params<Decoded: Decodable>(as type: Decoded.Type) -> Decoded? {
            (try? JSONDecoder().decode(ParamsBox<Decoded>.self, from: line))?.params
        }

        /// The `result` member, decoded the same way.
        public func result<Decoded: Decodable>(as type: Decoded.Type) -> Decoded? {
            (try? JSONDecoder().decode(ResultBox<Decoded>.self, from: line))?.result
        }

        private struct ParamsBox<Decoded: Decodable>: Decodable {
            let params: Decoded?
        }

        private struct ResultBox<Decoded: Decodable>: Decodable {
            let result: Decoded?
        }
    }

    // ── writing ──────────────────────────────────────────────────────────

    /// Params for a call that takes none. JSON-RPC lets the member be
    /// omitted, and this is how you say so in a type system.
    public struct NoParams: Encodable, Equatable, Sendable {
        public init() {}
    }

    /// A request, framed and ready to write: canonical bytes, then the
    /// newline that ends the line.
    ///
    /// Keys are sorted, so the same call produces the same bytes on every
    /// platform and in every process. That is not tidiness — a recorded
    /// stream is a fixture, and a fixture whose key order depends on a
    /// dictionary's seed is not one.
    public static func request<Params: Encodable>(
        id: ID, method: String, params: Params
    ) throws -> Data {
        try line(Envelope(id: id, method: method, params: params))
    }

    /// A request with no params.
    public static func request(id: ID, method: String) throws -> Data {
        try line(Envelope<NoParams>(id: id, method: method, params: nil))
    }

    /// A notification — a method with no id, so no answer is expected and
    /// none will be correlated.
    public static func notification<Params: Encodable>(
        method: String, params: Params
    ) throws -> Data {
        try line(Envelope(id: nil, method: method, params: params))
    }

    /// A notification with no params.
    public static func notification(method: String) throws -> Data {
        try line(Envelope<NoParams>(id: nil, method: method, params: nil))
    }

    private struct Envelope<Params: Encodable>: Encodable {
        var jsonrpc: String = DuckRPC.version
        let id: ID?
        let method: String
        let params: Params?

        private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(jsonrpc, forKey: .jsonrpc)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        }
    }

    private static func line<Params: Encodable>(_ envelope: Envelope<Params>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(envelope)
        bytes.append(newline)
        return bytes
    }

    /// `\n`, the frame. Not a parameter: NDJSON has exactly one terminator,
    /// and a decoder that could be configured with another would be a decoder
    /// somebody eventually configures wrong.
    static let newline: UInt8 = 0x0A
    /// `\r`, which is not a frame but does turn up in front of one.
    static let carriageReturn: UInt8 = 0x0D

    // ── correlation ──────────────────────────────────────────────────────

    /// Hands out request ids and remembers what each one asked for.
    ///
    /// A RESPONSE CARRIES AN ID AND NOTHING ELSE — no method, no hint of what
    /// it is answering. Two calls in flight (a sound and a skill, say, pressed
    /// half a second apart) come back as two objects distinguishable only by
    /// an integer, so the table that maps that integer back to a method is the
    /// difference between "the kick was refused" and "something was refused".
    ///
    /// Ids are never reused, not even across a reconnect. A late answer to a
    /// request from a previous connection would otherwise land on a live id
    /// and be reported as the answer to a question nobody asked; monotonic ids
    /// make that stale answer simply unknown, which is the truth.
    public struct Correlator: Equatable, Sendable {
        private var nextID: Int64 = 1
        private var inFlight: [ID: String] = [:]

        public init() {}

        /// How many requests are still waiting for an answer.
        public var inFlightCount: Int { inFlight.count }

        /// The method a given id is waiting on, without consuming it.
        public func method(for id: ID) -> String? { inFlight[id] }

        /// Mint an id, remember the method, and return the bytes to write.
        public mutating func request<Params: Encodable>(
            _ method: String, params: Params
        ) throws -> (id: ID, bytes: Data) {
            let id = ID.number(nextID)
            let bytes = try DuckRPC.request(id: id, method: method, params: params)
            // Only recorded once the encoding succeeded: a request that was
            // never written must not occupy a slot forever.
            nextID += 1
            inFlight[id] = method
            return (id, bytes)
        }

        /// Mint an id for a call with no params.
        public mutating func request(_ method: String) throws -> (id: ID, bytes: Data) {
            try request(method, params: NoParams())
        }

        /// The method this response answers, removed from the table.
        ///
        /// Returns nil for a notification, for an id nobody minted, and for a
        /// second copy of an answer already matched — all three are cases
        /// where the honest answer is "this is not the reply to anything I am
        /// waiting for".
        public mutating func method(answering message: Message) -> String? {
            guard let id = message.id else { return nil }
            return inFlight.removeValue(forKey: id)
        }

        /// Forget everything still waiting, and say what it was.
        ///
        /// Call it when a connection drops: those answers are not coming, and
        /// a UI with four buttons stuck on "sent…" is worse than four buttons
        /// that admit the socket died.
        @discardableResult
        public mutating func abandonAll() -> [ID: String] {
            let abandoned = inFlight
            inFlight.removeAll()
            return abandoned
        }
    }

    // ── reading ──────────────────────────────────────────────────────────

    /// Bytes in, messages out, across as many reads as it takes.
    ///
    /// The decoder holds at most one partial line. Every complete line is
    /// decoded and handed back in arrival order; anything that is not a
    /// JSON-RPC message increments a counter instead of being guessed at,
    /// because a diary that records a zero for a field `robotd` renamed is
    /// worse than one that records that it stopped understanding the stream.
    ///
    /// Three counters, three different failures:
    /// `malformedLines` is a line that arrived whole and was not a message —
    /// a schema change, a log line on the wrong stream, half a message after
    /// a truncated write. `refusedLines` is a line that breached
    /// `maxLineBytes` and was discarded unread. `pendingBytes` is what is
    /// held right now waiting for a terminator, which is how you tell "the
    /// robot is quiet" from "the robot is mid-sentence".
    public struct StreamDecoder: Sendable {

        /// The most bytes one line may occupy before it is refused: 256 KB.
        ///
        /// A `robot.state` line is 319 bytes, so the cap is 821 of them —
        /// sixteen seconds of a 50 Hz stream in a single line. Nothing this
        /// daemon emits can be that big, which is the point: the cap is not a
        /// budget for real messages, it is the ceiling above which the sender
        /// is definitionally broken and the phone's memory stops being its
        /// hostage.
        public static let maxLineBytes = 256 * 1024

        private var buffer = Data()
        /// True while hunting for the terminator of a line already refused.
        private var resynchronizing = false

        /// Lines that arrived intact and were not JSON-RPC messages.
        public private(set) var malformedLines = 0
        /// Lines discarded unread for breaching `maxLineBytes`.
        public private(set) var refusedLines = 0

        public init() {}

        /// Bytes held right now waiting for a newline.
        public var pendingBytes: Int { buffer.count }
        /// True while the tail of a refused line is still being skipped.
        public var isResynchronizing: Bool { resynchronizing }

        /// Feed the decoder whatever just arrived — one segment, one read,
        /// one whole file — and take back every message that completed.
        public mutating func append(_ data: Data) -> [Message] {
            var messages: [Message] = []
            var cursor = data.startIndex
            while cursor < data.endIndex {
                guard let terminator = data[cursor...].firstIndex(of: DuckRPC.newline) else {
                    // No terminator in what is left: it is a partial line.
                    // Hold it — unless holding it would breach the cap, or
                    // unless we are still skipping a line already refused.
                    if !resynchronizing { absorb(data[cursor...]) }
                    break
                }
                let line = data[cursor..<terminator]
                cursor = data.index(after: terminator)

                if resynchronizing {
                    // That newline ends the refused line. The stream is
                    // usable again from here, and this line's bytes were
                    // never kept.
                    resynchronizing = false
                    continue
                }

                absorb(line)
                if resynchronizing {
                    // `absorb` refused this line for breaching the cap — but
                    // its terminator is the newline just consumed, so there
                    // is nothing left to hunt for.
                    resynchronizing = false
                    continue
                }

                if let message = Self.message(from: buffer) {
                    messages.append(message)
                } else if !Self.isBlank(buffer) {
                    // An empty line is a keepalive, not a defect.
                    malformedLines += 1
                }
                buffer.removeAll(keepingCapacity: true)
            }
            return messages
        }

        /// Drop the partial line and stop skipping — what a reconnect means.
        /// The counters survive: they describe the stream that has been read,
        /// not the buffer, and they belong in the session record.
        public mutating func reset() {
            buffer.removeAll(keepingCapacity: false)
            resynchronizing = false
        }

        /// Add bytes to the partial line, or refuse the line outright.
        ///
        /// The cap is checked BEFORE the append, never after: appending first
        /// and trimming afterwards would mean a single 8 MB read is 8 MB
        /// resident, which is the exact failure the cap exists to prevent.
        private mutating func absorb(_ bytes: Data) {
            guard buffer.count + bytes.count <= Self.maxLineBytes else {
                refusedLines += 1
                buffer.removeAll(keepingCapacity: false)
                resynchronizing = true
                return
            }
            buffer.append(bytes)
        }

        /// Decode one complete line. Nil for anything that is not a JSON-RPC
        /// message this decoder is willing to claim it read.
        private static func message(from line: Data) -> Message? {
            let body = line.last == DuckRPC.carriageReturn ? Data(line.dropLast()) : line
            guard !body.isEmpty else { return nil }
            guard let wire = try? JSONDecoder().decode(Wire.self, from: body) else { return nil }
            // Tolerant about a missing version, strict about a wrong one. A
            // daemon announcing 2.1 is speaking a protocol nobody here has
            // read; a daemon announcing nothing is being terse, and dropping
            // an entire state stream over the one field that carries no
            // information would be failing closed on the wrong thing.
            if let jsonrpc = wire.jsonrpc, jsonrpc != DuckRPC.version { return nil }
            // Structure, not vocabulary: a message names a method, answers an
            // id, or reports a failure. `{"hello": 1}` does none of those.
            guard wire.method != nil || wire.id != nil || wire.error != nil else { return nil }
            return Message(
                id: wire.id, method: wire.method, failure: wire.error,
                carriesResult: wire.carriesResult, line: body)
        }

        private static func isBlank(_ line: Data) -> Bool {
            line.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == DuckRPC.carriageReturn }
        }

        /// The envelope, and only the envelope.
        private struct Wire: Decodable {
            let jsonrpc: String?
            let id: ID?
            let method: String?
            let error: Failure?
            let carriesResult: Bool

            private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, error, result }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.jsonrpc = (try? container.decodeIfPresent(String.self, forKey: .jsonrpc)) ?? nil
                self.id = (try? container.decodeIfPresent(ID.self, forKey: .id)) ?? nil
                self.method = (try? container.decodeIfPresent(String.self, forKey: .method)) ?? nil
                self.error = (try? container.decodeIfPresent(Failure.self, forKey: .error)) ?? nil
                self.carriesResult = container.contains(.result)
            }
        }
    }
}
