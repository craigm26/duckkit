import Foundation

/// Writing a policy back out as ONNX — the exact inverse of `DuckPolicy`'s
/// reader, and the thing that lets a network leave this phone.
///
/// WHY THIS EXISTS AT ALL. Everything in this family could READ a policy and
/// nothing could write one, so a network could be inspected, fingerprinted and
/// argued about but never produced. That closed off the only interesting thing
/// a phone can do with a set of trained networks it cannot retrain: combine
/// them. Blending is arithmetic — the whole family shares one architecture,
/// 61-512-256-128-14 with ELU throughout, because `DuckPolicy.load` refuses
/// anything else — so a weighted average of two policies is a valid policy in
/// the only sense the loader recognises. Whether it WORKS is a separate
/// question and a measured one; whether it loads is settled here.
///
/// AND IT IS THE STEP ONTO THE ROBOT. robotd takes an ONNX pointed at by
/// `[policy]` in its config and nothing else — no over-the-air, no upload RPC.
/// A file is the whole interface, so a file is what this writes.
///
/// THERE IS A PROVEN REFERENCE FOR IT, WHICH IS WHY THIS IS NOT A GAMBLE.
/// duck-studio's `scripts/make_refusal_corpus.py` has been synthesising ONNX
/// files from nothing for months — with no onnx dependency, and with its field
/// numbers cross-checked against this very parser. This is that writer in
/// Swift, against the same wire format:
///
///     ModelProto     7 = graph
///     GraphProto     1 = node   5 = initializer   11 = input   12 = output
///     NodeProto      1 = input(str)   4 = op_type(str)   5 = attribute
///     AttributeProto 1 = name   3 = int
///     TensorProto    1 = dims   2 = data_type   8 = name   9 = raw_data
///
/// The only claim that matters is the round trip, and `DuckPolicyWriterTests`
/// makes it: load a real policy, write it, load it again, and get the same
/// actions on the golden vectors. A writer that produced a file this package
/// refused would be worse than no writer.
public enum DuckPolicyWriter {

    public enum WriteError: Error, Equatable {
        case wrongShape(String)

        public var message: String {
            switch self {
            case .wrongShape(let what):
                return "That is not a Microduck policy: \(what)."
            }
        }
    }

    // MARK: - protobuf, the four pieces of it this needs

    private static func varint(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private static func tag(_ field: Int, _ wire: Int) -> [UInt8] {
        varint(UInt64(field << 3 | wire))
    }

    private static func delimited(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(UInt64(payload.count)) + payload
    }

    private static func stringField(_ field: Int, _ text: String) -> [UInt8] {
        delimited(field, Array(text.utf8))
    }

    private static func varintField(_ field: Int, _ value: UInt64) -> [UInt8] {
        tag(field, 0) + varint(value)
    }

    // MARK: - the pieces of a graph

    /// One float32 initializer. `raw_data` is little-endian, which is what the
    /// reader's `packedFloats` expects and what every ONNX exporter emits.
    private static func tensor(_ name: String, dims: [Int], floats: [Float]) -> [UInt8] {
        var body: [UInt8] = []
        for d in dims { body += varintField(1, UInt64(d)) }
        body += varintField(2, 1)                     // data_type 1 = FLOAT
        body += stringField(8, name)
        var raw: [UInt8] = []
        raw.reserveCapacity(floats.count * 4)
        for f in floats {
            let bits = f.bitPattern.littleEndian
            raw.append(UInt8(truncatingIfNeeded: bits))
            raw.append(UInt8(truncatingIfNeeded: bits >> 8))
            raw.append(UInt8(truncatingIfNeeded: bits >> 16))
            raw.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        body += delimited(9, raw)
        return body
    }

    /// One node. **The output name is field 2 and it is not optional**, however
    /// much this package's own reader gets by without it: `DuckPolicy` infers
    /// the chain from position and never reads an output, so a graph with none
    /// loaded here and onnxruntime said "This is an invalid model. Graph output
    /// (actions) does not exist in the graph." A graph is a graph because its
    /// edges are named.
    private static func node(_ op: String, inputs: [String], output: String,
                             transB: Bool = false) -> [UInt8] {
        var body: [UInt8] = []
        for i in inputs { body += stringField(1, i) }
        body += stringField(2, output)
        body += stringField(4, op)
        if transB {
            // AttributeProto: name "transB", i = 1, AND type = INT.
            //
            // FIELD 20 IS REQUIRED AND THIS PACKAGE'S READER NEVER LOOKED AT
            // IT. Without it onnxruntime says "Error Field 'type' of 'attr' is
            // required but missing" — an attribute has to say which of its
            // several value fields is the real one, even when only one is set.
            // AttributeType: FLOAT = 1, INT = 2.
            body += delimited(5, stringField(1, "transB")
                                 + varintField(3, 1)
                                 + varintField(20, 2))
        }
        return body
    }

    /// A graph input or output, WITH ITS TYPE. A bare name is enough for this
    /// package's reader and not for a real one: ONNX requires a ValueInfoProto
    /// to carry a TypeProto, and the leading dimension is left symbolic —
    /// robotd's own `check_width` says "the leading dimension is the batch and
    /// is usually dynamic, so only the last one is checked", which is exactly
    /// the shape a trained export has.
    ///
    ///     ValueInfoProto   1 = name  2 = type
    ///     TypeProto        1 = tensor_type
    ///     Tensor           1 = elem_type  2 = shape
    ///     TensorShapeProto 1 = dim
    ///     Dimension        1 = dim_value  2 = dim_param
    private static func valueInfo(_ name: String, width: Int) -> [UInt8] {
        let batch = delimited(1, stringField(2, "batch"))     // dim_param
        let fixed = delimited(1, varintField(1, UInt64(width)))
        let shape = delimited(2, batch + fixed)
        let tensor = delimited(1, varintField(1, 1) + shape)  // elem_type 1 = FLOAT
        return stringField(1, name) + delimited(2, tensor)
    }

    // MARK: - writing a policy

    /// The bytes of an ONNX file this package will load.
    ///
    /// THE SHAPE IS NOT NEGOTIABLE and is checked before a byte is written,
    /// because a file that leaves here malformed is one somebody else's runtime
    /// has to refuse — and `robotd` refusing a file is a much worse place to
    /// find out than this function refusing to write one.
    public static func encoded(mean: [Float], std: [Float], layers: [Layer]) throws -> Data {
        guard mean.count == DuckObservation.length, std.count == mean.count else {
            throw WriteError.wrongShape(
                "the normaliser is \(mean.count) and \(std.count) wide, not "
                + "\(DuckObservation.length)")
        }
        let widths = DuckPolicy.expectedWidths
        guard layers.count == widths.count else {
            throw WriteError.wrongShape("it has \(layers.count) layers, not \(widths.count)")
        }
        for (i, (layer, want)) in zip(layers, widths).enumerated() {
            guard layer.inputs == want.0, layer.outputs == want.1 else {
                throw WriteError.wrongShape(
                    "layer \(i) is \(layer.inputs) to \(layer.outputs), not \(want.0) to \(want.1)")
            }
            guard layer.weights.count == want.0 * want.1 else {
                throw WriteError.wrongShape(
                    "layer \(i) carries \(layer.weights.count) weights, not \(want.0 * want.1)")
            }
            guard layer.biases.count == want.1 else {
                throw WriteError.wrongShape(
                    "layer \(i) carries \(layer.biases.count) biases, not \(want.1)")
            }
        }

        var initializers: [[UInt8]] = [
            tensor("mean", dims: [mean.count], floats: mean),
            tensor("std", dims: [std.count], floats: std),
        ]
        // The normaliser, then four Gemm/ELU pairs with the last ELU dropped —
        // the same nine ops in the same order the reader insists on.
        var nodes: [[UInt8]] = [
            node("Sub", inputs: ["obs", "mean"], output: "sub_out"),
            node("Div", inputs: ["sub_out", "std"], output: "h0"),
        ]
        for (i, layer) in layers.enumerated() {
            initializers.append(tensor("w\(i)", dims: [layer.outputs, layer.inputs],
                                       floats: layer.weights))
            initializers.append(tensor("b\(i)", dims: [layer.outputs], floats: layer.biases))
            let last = i == layers.count - 1
            // The final Gemm writes straight to `actions`; there is no ELU
            // after it, which is the ninth op and the end of the chain.
            nodes.append(node("Gemm", inputs: ["h\(i)", "w\(i)", "b\(i)"],
                              output: last ? "actions" : "g\(i)", transB: true))
            if !last { nodes.append(node("Elu", inputs: ["g\(i)"], output: "h\(i + 1)")) }
        }

        var graph: [UInt8] = []
        for n in nodes { graph += delimited(1, n) }
        for t in initializers { graph += delimited(5, t) }
        graph += delimited(11, valueInfo("obs", width: mean.count))
        graph += delimited(12, valueInfo("actions", width: layers[layers.count - 1].outputs))

        // THE GRAPH ALONE IS NOT A FILE ANY OTHER RUNTIME WILL OPEN, and this
        // package's own reader is not the check that catches it. `DuckPolicy`
        // walks straight to field 7 and never looks at the header, so a file
        // with only a graph round-tripped through load/encode/load perfectly —
        // and onnxruntime refused it outright: "Missing opset in the model. All
        // ModelProtos MUST have at least one entry that specifies which version
        // of the ONNX OperatorSet is being imported." Found by uploading one to
        // a real bench, which is the only place that question gets asked
        // honestly.
        //
        // Both numbers are what Pollen's own `alpha_walking.onnx` carries, read
        // out of its bytes rather than chosen: ir_version 8, and a single
        // opset_import with no domain — the default ONNX domain — at version
        // 18. Emitting what the trained files emit is the only defensible way
        // to pick these.
        var model: [UInt8] = []
        model += varintField(1, 8)                          // ir_version
        model += delimited(7, graph)
        model += delimited(8, varintField(2, 18))           // opset_import: default domain, v18
        return Data(model)
    }

    /// One dense layer, in the order the file wants it: weights row-major
    /// `[outputs][inputs]`, which is the ONNX `transB=1` convention.
    public struct Layer: Equatable, Sendable {
        public let weights: [Float]
        public let biases: [Float]
        public let inputs: Int
        public let outputs: Int

        public init(weights: [Float], biases: [Float], inputs: Int, outputs: Int) {
            self.weights = weights; self.biases = biases
            self.inputs = inputs; self.outputs = outputs
        }
    }
}
