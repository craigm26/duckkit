import Foundation

/// A Microduck policy network, run in pure Swift.
///
/// EVERY SHIPPED POLICY IS THE SAME TINY MACHINE. Parsing the real ONNX files
/// shows one architecture, seven times over: normalize the observation with
/// trained statistics, then four dense layers with ELU between them —
///
///     (obs − mean) / std → 61×512 → ELU → 512×256 → ELU → 256×128 → ELU → 128×14
///
/// about two hundred thousand parameters, forty microseconds of arithmetic.
/// That is why this file exists instead of a dependency: onnxruntime is a
/// hundred-megabyte answer to a nine-operation question, and Core ML cannot
/// run under `swift test` on the Pi. The kit already hand-rolls byte parsers
/// where the format is small and the stakes are high (`CanonicalJSONParser`,
/// `MJPEGParser`); this is the same judgment applied to protobuf.
///
/// EVERYTHING IS VALIDATED AT LOAD, NOT AT INFERENCE — the robot's own
/// runtime's rule, kept on the phone. A file with the wrong op sequence, a
/// transposed weight or an unexpected width is refused with a reason while
/// nothing is moving, not sixty ticks later mid-stride. `infer` cannot fail;
/// `load` can only fail loudly.
///
/// `DuckPolicyTests` proves the forward pass against `golden_policies.json`:
/// observation→action pairs computed by onnxruntime over the vendored
/// `alpha_walking.onnx`. Same weights, same bytes in, near-identical floats
/// out — the only differences are accumulation order.
public struct DuckPolicy: Sendable {

    public enum LoadError: Error, Equatable {
        /// Not a protobuf we can walk, or truncated mid-field.
        case malformed(String)
        /// Parsed fine, but it is not the one architecture every alpha
        /// policy shares. Carries what was found so "wrong file" and "wrong
        /// build" are distinguishable.
        case unsupportedArchitecture(String)
        /// A tensor width disagrees with the 61→512→256→128→14 contract.
        case shape(String)
    }

    /// One dense layer, weights row-major `[outputs][inputs]` (the ONNX Gemm
    /// `transB=1` convention, which is also the cache-friendly order for the
    /// loop below).
    struct Layer: Sendable {
        let weights: [Float]
        let biases: [Float]
        let inputs: Int
        let outputs: Int
    }

    let mean: [Float]
    let std: [Float]
    let layers: [Layer]

    /// Expected layer widths, outermost first.
    static let expectedWidths = [(61, 512), (512, 256), (256, 128), (128, 14)]

    // ── loading ──────────────────────────────────────────────────────────

    public static func load(from data: Data) throws -> DuckPolicy {
        let bytes = [UInt8](data)
        // ModelProto field 7 is the graph.
        guard let graph = try firstField(in: bytes[...], number: 7) else {
            throw LoadError.malformed("no graph in ModelProto")
        }
        var nodes: [(op: String, inputs: [String], transB: Bool)] = []
        var tensors: [String: (dims: [Int], floats: [Float])] = [:]
        try scan(graph) { field, wire, payload in
            switch field {
            case 1: nodes.append(try parseNode(payload))
            case 5:
                let t = try parseTensor(payload)
                tensors[t.name] = (t.dims, t.floats)
            default: break
            }
        }

        let ops = nodes.map(\.op)
        let expected = ["Sub", "Div", "Gemm", "Elu", "Gemm", "Elu", "Gemm", "Elu", "Gemm"]
        guard ops == expected else {
            throw LoadError.unsupportedArchitecture("op sequence \(ops)")
        }
        for node in nodes where node.op == "Gemm" && !node.transB {
            throw LoadError.unsupportedArchitecture("Gemm without transB=1")
        }

        func tensor(_ name: String, _ what: String) throws -> (dims: [Int], floats: [Float]) {
            guard let t = tensors[name] else { throw LoadError.malformed("missing initializer \(name) (\(what))") }
            return t
        }

        // Resolve constants through the graph rather than by name, so a
        // re-export with different tensor names still loads.
        let mean = try tensor(nodes[0].inputs[1], "normalizer mean")
        let std = try tensor(nodes[1].inputs[1], "normalizer std")
        guard mean.floats.count == DuckObservation.length, std.floats.count == DuckObservation.length else {
            throw LoadError.shape("normalizer is \(mean.floats.count)/\(std.floats.count) wide, expected 61")
        }
        for (i, s) in std.floats.enumerated() where !(s.isFinite && s != 0) {
            throw LoadError.shape("normalizer std[\(i)] is \(s) — division by it would poison every inference")
        }

        var layers: [Layer] = []
        for (which, node) in nodes.enumerated() where node.op == "Gemm" {
            let w = try tensor(node.inputs[1], "weight")
            let b = try tensor(node.inputs[2], "bias")
            let (inputs, outputs) = expectedWidths[layers.count]
            guard w.dims == [outputs, inputs], b.dims == [outputs] else {
                throw LoadError.shape("layer \(layers.count) (node \(which)) is \(w.dims)/\(b.dims), expected [\(outputs), \(inputs)]/[\(outputs)]")
            }
            layers.append(Layer(weights: w.floats, biases: b.floats, inputs: inputs, outputs: outputs))
        }
        return DuckPolicy(mean: mean.floats, std: std.floats, layers: layers)
    }

    public static func load(contentsOf url: URL) throws -> DuckPolicy {
        try load(from: Data(contentsOf: url))
    }

    // ── inference ────────────────────────────────────────────────────────

    /// One forward pass: 61 floats in, 14 raw actions out. Pure arithmetic,
    /// no allocation beyond the activations, safe at 50 Hz.
    public func infer(_ observation: DuckObservation) -> [Float] {
        var x = observation.values
        for i in 0..<x.count {
            x[i] = (x[i] - mean[i]) / std[i]
        }
        for (index, layer) in layers.enumerated() {
            var out = layer.biases
            layer.weights.withUnsafeBufferPointer { w in
                x.withUnsafeBufferPointer { xp in
                    out.withUnsafeMutableBufferPointer { op in
                        for row in 0..<layer.outputs {
                            var acc: Float = 0
                            let base = row * layer.inputs
                            for col in 0..<layer.inputs {
                                acc += w[base + col] * xp[col]
                            }
                            op[row] += acc
                        }
                    }
                }
            }
            if index < layers.count - 1 {
                // ELU, α = 1: identity above zero, exp(x)−1 below.
                for i in 0..<out.count where out[i] < 0 {
                    out[i] = expf(out[i]) - 1
                }
            }
            x = out
        }
        return x
    }

    // ── minimal protobuf wire reader ─────────────────────────────────────
    //
    // Just enough protobuf to walk ModelProto → GraphProto → Node/Tensor:
    // varints, length-delimited fields, packed floats. Anything surprising
    // throws rather than guesses.

    private static func scan(
        _ bytes: ArraySlice<UInt8>,
        _ visit: (Int, Int, ArraySlice<UInt8>) throws -> Void
    ) throws {
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let (tag, next) = try varint(bytes, at: i)
            let field = Int(tag >> 3)
            let wire = Int(tag & 7)
            i = next
            switch wire {
            case 0:
                let (value, after) = try varint(bytes, at: i)
                try visit(field, 0, bytes[i..<after].isEmpty ? bytes[i..<after] : bytes[i..<after])
                _ = value
                i = after
            case 2:
                let (length, after) = try varint(bytes, at: i)
                let end = after + Int(length)
                guard end <= bytes.endIndex else { throw LoadError.malformed("field \(field) runs past the end") }
                try visit(field, 2, bytes[after..<end])
                i = end
            case 5:
                guard i + 4 <= bytes.endIndex else { throw LoadError.malformed("truncated fixed32") }
                try visit(field, 5, bytes[i..<i + 4])
                i += 4
            case 1:
                guard i + 8 <= bytes.endIndex else { throw LoadError.malformed("truncated fixed64") }
                try visit(field, 1, bytes[i..<i + 8])
                i += 8
            default:
                throw LoadError.malformed("wire type \(wire) in field \(field)")
            }
        }
    }

    private static func varint(_ bytes: ArraySlice<UInt8>, at start: Int) throws -> (UInt64, Int) {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < bytes.endIndex {
            let byte = bytes[i]
            i += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (value, i) }
            shift += 7
            if shift > 63 { throw LoadError.malformed("varint too long") }
        }
        throw LoadError.malformed("truncated varint")
    }

    private static func varintValue(of payload: ArraySlice<UInt8>) throws -> UInt64 {
        try varint(payload, at: payload.startIndex).0
    }

    private static func firstField(in bytes: ArraySlice<UInt8>, number: Int) throws -> ArraySlice<UInt8>? {
        var found: ArraySlice<UInt8>?
        try scan(bytes) { field, wire, payload in
            if field == number, wire == 2, found == nil { found = payload }
        }
        return found
    }

    private static func parseNode(_ bytes: ArraySlice<UInt8>) throws -> (op: String, inputs: [String], transB: Bool) {
        var op = ""
        var inputs: [String] = []
        var transB = false
        try scan(bytes) { field, wire, payload in
            switch (field, wire) {
            case (1, 2): inputs.append(String(decoding: payload, as: UTF8.self))
            case (4, 2): op = String(decoding: payload, as: UTF8.self)
            case (5, 2): // AttributeProto
                var name = ""
                var intValue: UInt64 = 0
                try scan(payload) { af, aw, ap in
                    if af == 1, aw == 2 { name = String(decoding: ap, as: UTF8.self) }
                    if af == 3, aw == 0 { intValue = try varintValue(of: ap) }
                }
                if name == "transB", intValue != 0 { transB = true }
            default: break
            }
        }
        return (op, inputs, transB)
    }

    private static func parseTensor(_ bytes: ArraySlice<UInt8>) throws -> (name: String, dims: [Int], floats: [Float]) {
        var name = ""
        var dims: [Int] = []
        var floats: [Float] = []
        var raw: ArraySlice<UInt8>?
        var dataType: UInt64 = 1
        try scan(bytes) { field, wire, payload in
            switch (field, wire) {
            case (1, 0): dims.append(Int(try varintValue(of: payload)))
            case (1, 2): // packed dims
                var i = payload.startIndex
                while i < payload.endIndex {
                    let (v, next) = try varint(payload, at: i)
                    dims.append(Int(v))
                    i = next
                }
            case (2, 0): dataType = try varintValue(of: payload)
            case (4, 2): raw = payload
            case (8, 2): name = String(decoding: payload, as: UTF8.self)
            case (9, 2): // packed float_data
                floats.append(contentsOf: parseFloats(payload))
            case (9, 5):
                floats.append(contentsOf: parseFloats(payload))
            default: break
            }
        }
        guard dataType == 1 else { throw LoadError.unsupportedArchitecture("tensor \(name) is dtype \(dataType), not float32") }
        if let raw { floats = parseFloats(raw) }
        let expected = dims.reduce(1, *)
        guard floats.count == expected else {
            throw LoadError.shape("tensor \(name): \(floats.count) floats for dims \(dims)")
        }
        return (name, dims, floats)
    }

    private static func parseFloats(_ bytes: ArraySlice<UInt8>) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(bytes.count / 4)
        var i = bytes.startIndex
        while i + 4 <= bytes.endIndex {
            let bits = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            out.append(Float(bitPattern: bits))
            i += 4
        }
        return out
    }
}

#if canImport(Glibc)
import Glibc
#endif
