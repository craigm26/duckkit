import Foundation

/// The head depth sensor: an 8×8 grid of distances, decoded and interpreted.
///
/// The Microduck carries a VL53L5CX or VL53L8CX on the head's I²C bus, looking
/// where the head looks. `tofd` owns it and publishes frames as `tof.frame`
/// notifications on its OWN socket — not `robotd`'s — because nothing in the
/// control loop reads depth and putting perception in front of it would couple
/// two things the robot's architecture deliberately keeps apart. A client
/// subscribes with `tof.stream`.
///
/// THE STATUS BYTE IS THE POINT, AND COLLAPSING IT LOSES THE ANSWER THAT MATTERS.
/// JSON has no NaN, so a distance-only frame would have to encode "no
/// measurement" as a magic number. The sensor instead answers three ways, and
/// the difference between the second and third is what any automation actually
/// needs: there is something at 340 mm, there is *nothing* out to the sensor's
/// range, or the measurement failed and says nothing at all about the world.
/// Empty space is information. An unusable zone is not, and treating it as
/// "clear" is how a robot walks into a table leg it could not see.
///
/// The thresholds below are upstream's, from the `tof` crate whose own
/// documentation asks consumers to use its interpretation rather than
/// re-deriving them. They are not guesses.
public enum DuckToF {

    /// The sensor's fixed resolution — 8×8 is what `tofd` configures and what
    /// the wire format carries.
    public static let rows = 8
    public static let columns = 8
    public static var zoneCount: Int { rows * columns }

    /// Status codes ST documents as a usable range: valid, and valid with a
    /// large pulse — about 50% confidence, which the sensor still stands behind.
    public static let validStatuses: Set<UInt8> = [5, 9]
    /// "I measured, and there is nothing in range."
    public static let noTargetStatus: UInt8 = 255

    /// What one zone actually says.
    public enum Zone: Equatable, Sendable {
        /// A measurement, in metres.
        case range(Double)
        /// The sensor looked and found nothing in range. Empty space — which is
        /// a fact about the world, not a failure.
        case noTarget
        /// The measurement failed. Says nothing about what is out there, and
        /// carries the raw code because the codes mean specific things to
        /// anyone reading ST's table.
        case unusable(UInt8)

        /// The distance, or nil for the two cases that are not one. Deliberately
        /// makes a caller decide what "no reading" means rather than handing
        /// back a zero that reads as "touching the sensor".
        public var metres: Double? {
            if case .range(let d) = self { return d }
            return nil
        }
    }

    /// One 8×8 frame, exactly as `tof.frame` carries it.
    public struct Frame: Equatable, Sendable {
        /// Frames since `tofd` started, so a consumer can see a gap it did not
        /// cause.
        public let sequence: UInt64
        /// Microseconds on the sender's monotonic clock. NOT a wall clock —
        /// `tofd` has no business publishing one — so it is good for intervals
        /// and meaningless as a date.
        public let atMicroseconds: UInt64
        public let rows: Int
        public let columns: Int
        /// Row-major, `rows × columns` long. Millimetres, and signed: the sensor
        /// occasionally returns a negative on a failed convergence.
        public let distanceMillimetres: [Int]
        /// Row-major, parallel to the distances.
        public let status: [UInt8]

        public init(sequence: UInt64, atMicroseconds: UInt64, rows: Int, columns: Int,
                    distanceMillimetres: [Int], status: [UInt8]) {
            self.sequence = sequence
            self.atMicroseconds = atMicroseconds
            self.rows = rows
            self.columns = columns
            self.distanceMillimetres = distanceMillimetres
            self.status = status
        }

        /// The zone at an index, interpreted.
        public func zone(_ index: Int) -> Zone {
            guard index >= 0, index < status.count else { return .noTarget }
            let code = status[index]
            let millimetres = index < distanceMillimetres.count ? distanceMillimetres[index] : 0
            if validStatuses.contains(code) {
                // A negative distance is not a range whatever the status says.
                guard millimetres > 0 else { return .unusable(code) }
                return .range(Double(millimetres) / 1000)
            }
            return code == noTargetStatus ? .noTarget : .unusable(code)
        }

        public func zone(row: Int, column: Int) -> Zone { zone(row * columns + column) }

        /// Every zone, row-major.
        public var zones: [Zone] { (0..<status.count).map(zone) }

        // ── the numbers an automation actually reads ──────────────────────

        /// How many zones carry a usable range — the one number that says
        /// whether the sensor is seeing anything at all. Zero with a healthy
        /// sensor means an empty room, not a broken one.
        public var validCount: Int { zones.filter { $0.metres != nil }.count }

        /// How many zones failed. A frame that is mostly unusable is a frame to
        /// distrust as a whole, whatever its few valid readings say — bright
        /// sunlight and glass both do this.
        public var unusableCount: Int {
            zones.filter { if case .unusable = $0 { return true } else { return false } }.count
        }

        /// The closest thing the sensor can see, in metres.
        public var nearest: Double? { zones.compactMap(\.metres).min() }

        /// Where the closest thing is, as a zone index.
        public var nearestZone: Int? {
            var best: (index: Int, distance: Double)?
            for (index, zone) in zones.enumerated() {
                guard let d = zone.metres else { continue }
                if best == nil || d < best!.distance { best = (index, d) }
            }
            return best?.index
        }

        /// The nearest range within the middle of the field of view.
        ///
        /// THE USEFUL TRIGGER, and not the same as `nearest`. A duck standing on
        /// a floor sees the floor in its bottom rows from a few hundred
        /// millimetres away, permanently — so "is anything close?" is answered
        /// "yes" forever and is worthless as a condition. Asking only about the
        /// middle asks about what is in FRONT of the robot.
        public func nearestInCentre(margin: Int = 2) -> Double? {
            var best: Double?
            for row in margin..<(rows - margin) {
                for column in margin..<(columns - margin) {
                    guard let d = zone(row: row, column: column).metres else { continue }
                    if best == nil || d < best! { best = d }
                }
            }
            return best
        }

        /// Mean range per column, left to right — nil where a column saw
        /// nothing usable. What a "which way is clearer?" turn decides on.
        public var columnMeans: [Double?] {
            (0..<columns).map { column in
                let values = (0..<rows).compactMap { zone(row: $0, column: column).metres }
                return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            }
        }

        /// Whether the frame is worth acting on at all.
        ///
        /// A frame where most zones failed is not a measurement of an empty
        /// room; it is a sensor that could not see. An automation that cannot
        /// tell those apart will confidently drive into whatever it failed to
        /// range.
        public func isTrustworthy(minimumUsableFraction: Double = 0.5) -> Bool {
            guard !status.isEmpty else { return false }
            let usable = status.count - unusableCount
            return Double(usable) / Double(status.count) >= minimumUsableFraction
        }
    }

    /// What `tof.stream` answers with, before any frame arrives.
    public struct Stream: Equatable, Sendable {
        public let accepted: Bool
        /// The generation that answered, e.g. `VL53L8CX`. Both are fitted in the
        /// field and which one is present is decided at runtime by an ID read,
        /// so a client must not assume either.
        public let sensor: String?
        /// Why there is no sensor: not fitted, wrong generation, bus unreadable.
        public let unavailable: String?
        public let rows: Int
        public let columns: Int
        /// The rate the sensor was started at, Hz.
        public let hz: Int

        public init(accepted: Bool, sensor: String?, unavailable: String?,
                    rows: Int, columns: Int, hz: Int) {
            self.accepted = accepted
            self.sensor = sensor
            self.unavailable = unavailable
            self.rows = rows
            self.columns = columns
            self.hz = hz
        }
    }

    public enum DecodeError: Error, Equatable {
        case notAnObject
        case missing(String)
        case lengthMismatch(expected: Int, distances: Int, status: Int)
    }

    // MARK: - decoding

    /// Decode a `tof.frame` notification's params.
    ///
    /// The two arrays are checked against `rows × cols` rather than trusted.
    /// They are parallel and row-major, and a short one would silently shift
    /// every zone after the gap into the wrong place — a depth map that is
    /// plausible and rotated.
    public static func frame(from params: [String: Any]) throws -> Frame {
        guard let rows = params["rows"] as? Int, let columns = params["cols"] as? Int else {
            throw DecodeError.missing("rows/cols")
        }
        guard let distances = params["distance_mm"] as? [Int] else {
            throw DecodeError.missing("distance_mm")
        }
        guard let raw = params["status"] as? [Int] else { throw DecodeError.missing("status") }
        let expected = rows * columns
        guard distances.count == expected, raw.count == expected else {
            throw DecodeError.lengthMismatch(expected: expected,
                                             distances: distances.count, status: raw.count)
        }
        return Frame(
            sequence: UInt64(params["seq"] as? Int ?? 0),
            atMicroseconds: UInt64(params["at_us"] as? Int ?? 0),
            rows: rows, columns: columns,
            distanceMillimetres: distances,
            status: raw.map { UInt8(clamping: $0) })
    }

    public static func frame(fromJSON data: Data) throws -> Frame {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.notAnObject
        }
        // Accept either the params object itself or a whole JSON-RPC
        // notification, because both turn up: one from a decoded envelope, one
        // straight off the socket.
        if let params = object["params"] as? [String: Any] { return try frame(from: params) }
        return try frame(from: object)
    }

    public static func stream(from params: [String: Any]) throws -> Stream {
        guard let rows = params["rows"] as? Int, let columns = params["cols"] as? Int else {
            throw DecodeError.missing("rows/cols")
        }
        return Stream(accepted: params["accepted"] as? Bool ?? false,
                      sensor: params["sensor"] as? String,
                      unavailable: params["unavailable"] as? String,
                      rows: rows, columns: columns,
                      hz: params["hz"] as? Int ?? 0)
    }
}
