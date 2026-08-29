import Foundation

/// The `.duckmove` file: an authored motion on disk, read and written in one
/// place.
///
/// WHY THE READER LIVES HERE AND NOT IN AN APP. Duck Studio writes these files
/// (its authoring screen exports them), OpenCastor plays them (a goal
/// celebration you wrote yourself), and the sim harness takes the same shape.
/// Three programs, one format — and the day two of them carry their own
/// parsers is the day a file works in one and silently misloads in another.
/// This is the format's single door, tested on Linux, and both apps go
/// through it.
///
/// WHAT THE FORMAT IS. `duck-move/1`, JSON: keyframe times and FIFTEEN-wide
/// poses — all fifteen joints, mouth included, because a person can open the
/// beak and no policy can. That width is the telltale difference from a
/// `.duckintent`, which is 14-wide because it records what a policy did.
/// Decimal text, so values round-trip to within an ULP rather than
/// bit-exactly; the validating initializer's tolerance absorbs that.
public enum DuckMoveFile {

    public static let format = "duck-move/2"

    /// Formats this reader accepts. `duck-move/1` recorded times and poses and
    /// nothing about what the poses were measured against; every such file
    /// meant absolute joint angles read against the home pose, because that is
    /// the only base any writer ever used. It still reads, and it still means
    /// that — the difference is that a `duck-move/2` file SAYS so.
    public static let readableFormats: Set<String> = ["duck-move/1", "duck-move/2"]
    public static let fileExtension = "duckmove"

    /// What a file holds once read: the motion, and where it came from.
    public struct Contents: Equatable, Sendable {
        public let name: String
        public let move: DuckMove
        /// Where the motion came from, in the author's tool's words.
        public let provenance: String?
        /// The caveat that travels with the file — typically "no physics ran".
        public let note: String?

        public init(name: String, move: DuckMove,
                    provenance: String?, note: String?) {
            self.name = name; self.move = move
            self.provenance = provenance; self.note = note
        }
    }

    public enum ReadError: Error, Equatable {
        case notAMove
        case unsupportedFormat(String)
        case malformed(String)
        /// The file names its joints and they are not this robot's, in this
        /// order. REFUSED LOUDLY rather than remapped: a pose scattered into
        /// the wrong joints is not garbage, it is a plausible-looking motion
        /// for a different robot, and playing it teaches the viewer something
        /// false about this one.
        case jointOrderMismatch
        /// The keyframes themselves are invalid — out of travel, out of
        /// order. Carries `DuckMove`'s own refusal, which names the joint.
        case invalid(DuckMove.Invalid)

        public var message: String {
            switch self {
            case .notAMove:
                return "That file is not an authored motion."
            case .unsupportedFormat(let f):
                return "This motion is in format \"\(f)\", which this version does not read."
            case .malformed(let what):
                return what
            case .jointOrderMismatch:
                return "This motion names its joints differently from the Microduck's, so its "
                     + "poses would land on the wrong servos. It was probably authored for a "
                     + "different robot or a different app version."
            case .invalid(let why):
                return why.message
            }
        }
    }

    // MARK: - reading

    public static func decode(_ data: Data) throws -> Contents {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError.notAMove
        }
        guard let declared = object["format"] as? String else { throw ReadError.notAMove }
        guard readableFormats.contains(declared) else {
            throw ReadError.unsupportedFormat(declared)
        }

        // The joints array is the file's own claim about its pose layout.
        // Absent is tolerated (the order is then this package's, which is what
        // every writer to date produced); PRESENT AND DIFFERENT is refused.
        if let joints = object["joints"] as? [String], joints != DuckModel.jointNames {
            throw ReadError.jointOrderMismatch
        }

        guard let times = object["times"] as? [Double],
              let poses = object["poses"] as? [[Double]] else {
            throw ReadError.malformed("The motion has no keyframes in it.")
        }
        guard times.count == poses.count, !times.isEmpty else {
            throw ReadError.malformed(
                "The motion has \(times.count) times and \(poses.count) poses.")
        }

        let name = object["name"] as? String ?? "shared motion"
        // A version-1 file carries no base, and its poses are absolute against
        // the home pose — that is what every writer of that format meant.
        let base = object["base"] as? [Double] ?? DuckModel.homePose
        guard base.count == DuckModel.jointCount else {
            throw ReadError.malformed(
                "The motion's base pose has \(base.count) joints; the robot has "
              + "\(DuckModel.jointCount).")
        }
        let posesAre = DuckMove.PosesAre(rawValue: object["posesAre"] as? String ?? "absolute")
        guard let posesAre else {
            throw ReadError.malformed(
                "The motion says its poses are \"\(object["posesAre"] as? String ?? "")\", "
              + "which is neither absolute nor offset.")
        }
        do {
            let move = try DuckMove(validating: name, times: times, poses: poses,
                                    base: base, posesAre: posesAre)
            return Contents(name: name, move: move,
                            provenance: object["provenance"] as? String,
                            note: object["note"] as? String)
        } catch let refusal as DuckMove.Invalid {
            throw ReadError.invalid(refusal)
        }
    }

    // MARK: - writing

    /// The move validates on the way OUT as well as in — a writer that can
    /// emit a file its own reader refuses is two bugs wearing one format.
    public static func encode(name: String, move: DuckMove,
                              provenance: String? = nil,
                              note: String? = nil) throws -> Data {
        var object: [String: Any] = [
            "format": format,
            "name": name,
            "joints": DuckModel.jointNames,
            "times": move.keyframes.map(\.time),
            "poses": move.keyframes.map(\.pose),
            // Written every time, even when it is the home pose: a reader that
            // has to infer the base is the bug this format version exists for.
            "base": move.base,
            "posesAre": move.posesAre.rawValue,
        ]
        if let provenance { object["provenance"] = provenance }
        if let note { object["note"] = note }
        return try JSONSerialization.data(withJSONObject: object,
                                          options: [.prettyPrinted, .sortedKeys])
    }
}
