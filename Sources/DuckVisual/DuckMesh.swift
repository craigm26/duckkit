import Foundation
import DuckKit

/// The Microduck's actual shape, one mesh per body, ready to be posed by
/// `DuckKinematics`.
///
/// WHY THIS IS A SEPARATE PRODUCT. It is 2.4 MB of triangles. Most things that
/// need a duck do not need to draw one — a soundboard, a telemetry reducer, a
/// policy inspector — and none of them should carry a hundred thousand
/// triangles to do their job. `DuckKit` stays the lean description of the
/// robot; this is the picture of it.
///
/// HOW IT LINES UP WITH THE KINEMATICS. Every mesh is expressed in its own
/// body's local frame, keyed by the body names `DuckKinematics.bodies` uses. So
/// drawing the robot is: ask `DuckKinematics.bodyPoses(jointAngles:)` where each
/// body is, then put that body's mesh there. There is no second skeleton and no
/// separate rig — the thing that decides where a foot is remains the thing that
/// decided it before there were any meshes.
///
/// The geometry is Pollen Robotics' own, from the Apache-2.0
/// `pollen-robotics/microduck_rl`. See `Resources/PROVENANCE.md` for why that
/// source and not the visually identical one in their Hugging Face Space.
public enum DuckMesh {

    /// One body's drawable geometry, in that body's local frame, metres.
    ///
    /// Flat `[Float]` rather than a vector type on purpose: `simd` does not
    /// exist on Linux, and the whole point of keeping this package free of
    /// Apple frameworks is that the geometry can be checked by `swift test` on
    /// a Pi. Every renderer worth using takes a flat buffer anyway.
    public struct Body: Equatable, Sendable {
        /// Matches a name in `DuckKinematics.bodies`.
        public let name: String
        /// `x, y, z` per vertex — `count / 3` vertices.
        public let positions: [Float]
        /// One unit normal per vertex, same layout and count as `positions`.
        public let normals: [Float]
        /// Triangle list into those vertices.
        public let indices: [UInt32]
        /// The part's colour from the model's own material, 0…1.
        public let rgba: (r: Float, g: Float, b: Float, a: Float)

        public var vertexCount: Int { positions.count / 3 }
        public var triangleCount: Int { indices.count / 3 }

        public static func == (l: Body, r: Body) -> Bool {
            l.name == r.name && l.positions == r.positions
                && l.normals == r.normals && l.indices == r.indices
                && l.rgba == r.rgba
        }
    }

    public enum LoadError: Error, Equatable {
        case missingResource
        case malformed(String)
    }

    /// Every body, in the model's own tree order.
    ///
    /// Decoded on each call — it allocates a few megabytes, so a renderer
    /// should hold the result rather than ask per frame.
    public static func bundled() throws -> [Body] {
        guard let url = Bundle.module.url(forResource: "duck-mesh", withExtension: "bin") else {
            throw LoadError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    /// The robot's shape in a variant: the walker, or the walker with its two
    /// ankle bodies swapped for Pollen's roller blades and wheels
    /// (`duck-mesh-rollers.bin`, from `robot_allcollisions_rollers.xml`). The
    /// body names line up with `DuckKinematics.bodies(for:)`.
    public static func bundled(variant: DuckKinematics.Variant) throws -> [Body] {
        let base = try bundled()
        guard variant == .rollers else { return base }
        guard let url = Bundle.module.url(forResource: "duck-mesh-rollers", withExtension: "bin") else {
            throw LoadError.missingResource
        }
        let dropped = DuckKinematics.bodyNames(onlyIn: .legs)
        return base.filter { !dropped.contains($0.name) } + (try decode(Data(contentsOf: url)))
    }

    /// The bodies that have geometry, as a set of names — useful for asserting
    /// against `DuckKinematics.bodies` without decoding megabytes.
    public static func bundledBodyNames() throws -> [String] {
        guard let url = Bundle.module.url(forResource: "duck-mesh", withExtension: "bin") else {
            throw LoadError.missingResource
        }
        return try header(Data(contentsOf: url)).map { $0.name }
    }

    // MARK: - the file

    struct Entry {
        let name: String
        let vertexOffset: Int, vertexCount: Int
        let indexOffset: Int, indexCount: Int
        let rgba: [Float]
    }

    static func header(_ data: Data) throws -> [Entry] {
        guard data.count > 8 else { throw LoadError.malformed("shorter than a header") }
        guard data.prefix(4) == Data("DKM1".utf8) else {
            throw LoadError.malformed("not a duck-mesh file")
        }
        let headerLength = Int(data[data.startIndex + 4 ..< data.startIndex + 8]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        let start = data.startIndex + 8
        guard data.count >= 8 + headerLength else {
            throw LoadError.malformed("header runs past the end")
        }
        let json = try JSONSerialization.jsonObject(with: data[start ..< start + headerLength])
        guard let root = json as? [String: Any],
              let bodies = root["bodies"] as? [[String: Any]] else {
            throw LoadError.malformed("no bodies in header")
        }
        return try bodies.map { raw in
            guard let name = raw["body"] as? String,
                  let vo = raw["vertexOffset"] as? Int, let vc = raw["vertexCount"] as? Int,
                  let io = raw["indexOffset"] as? Int, let ic = raw["indexCount"] as? Int,
                  let rgba = raw["rgba"] as? [Double] else {
                throw LoadError.malformed("a body entry is incomplete")
            }
            return Entry(name: name, vertexOffset: vo, vertexCount: vc,
                         indexOffset: io, indexCount: ic, rgba: rgba.map(Float.init))
        }
    }

    static func decode(_ data: Data) throws -> [Body] {
        let entries = try header(data)
        let headerLength = Int(data[data.startIndex + 4 ..< data.startIndex + 8]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })

        let totalVertices = entries.reduce(0) { $0 + $1.vertexCount }
        let totalIndices = entries.reduce(0) { $0 + $1.indexCount }
        let positionsStart = data.startIndex + 8 + headerLength
        let normalsStart = positionsStart + totalVertices * 12
        let indicesStart = normalsStart + totalVertices * 12
        guard data.count >= (indicesStart - data.startIndex) + totalIndices * 4 else {
            throw LoadError.malformed("the buffers are shorter than the header claims")
        }

        // `loadUnaligned` throughout: the header is padded to a 4-byte boundary
        // by the exporter, but a Data slice carries no alignment guarantee of
        // its own and an aligned load on a misaligned address is a crash on
        // some platforms and silently wrong on others.
        func floats(at offset: Int, count: Int) -> [Float] {
            data.withUnsafeBytes { raw in
                (0..<count).map {
                    Float(bitPattern: raw.loadUnaligned(
                        fromByteOffset: offset - data.startIndex + $0 * 4,
                        as: UInt32.self).littleEndian)
                }
            }
        }

        return entries.map { entry in
            let floatCount = entry.vertexCount * 3
            let positions = floats(at: positionsStart + entry.vertexOffset * 12, count: floatCount)
            let normals = floats(at: normalsStart + entry.vertexOffset * 12, count: floatCount)
            let indices: [UInt32] = data.withUnsafeBytes { raw in
                (0..<entry.indexCount).map {
                    raw.loadUnaligned(
                        fromByteOffset: indicesStart - data.startIndex + (entry.indexOffset + $0) * 4,
                        as: UInt32.self).littleEndian
                }
            }
            let c = entry.rgba
            return Body(name: entry.name, positions: positions, normals: normals,
                        indices: indices,
                        rgba: (c.count > 3 ? (c[0], c[1], c[2], c[3]) : (0.8, 0.8, 0.8, 1)))
        }
    }
}
