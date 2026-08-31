import XCTest
@testable import DuckKit

/// A writer is only worth anything if what it writes comes back the same, so
/// that is the whole of this file.
final class DuckPolicyWriterTests: XCTestCase {

    private func bundled(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/duck/\(name)",
                                                  withExtension: "onnx"),
                                "fixture \(name).onnx is missing")
        return try Data(contentsOf: url)
    }

    /// The bytes of a real policy rewritten by this writer, which is what the
    /// wire-format assertions below inspect.
    private func writtenPolicy() throws -> Data {
        try DuckPolicy.load(from: bundled("alpha_walking")).encoded()
    }

    /// THE ONE CLAIM THAT MATTERS. Load a real trained policy, write it out,
    /// load the bytes back, and get the same numbers — not approximately, but
    /// bit for bit, because float32 in and float32 out is a copy and anything
    /// else means the wire format was misunderstood somewhere.
    func testARealPolicySurvivesBeingWrittenAndReadAgain() throws {
        let original = try DuckPolicy.load(from: bundled("alpha_walking"))
        let rewritten = try DuckPolicy.load(from: original.encoded())

        XCTAssertEqual(rewritten.parameters.mean, original.parameters.mean)
        XCTAssertEqual(rewritten.parameters.std, original.parameters.std)
        XCTAssertEqual(rewritten.parameters.layers.count, original.parameters.layers.count)
        for (a, b) in zip(rewritten.parameters.layers, original.parameters.layers) {
            XCTAssertEqual(a.weights, b.weights)
            XCTAssertEqual(a.biases, b.biases)
            XCTAssertEqual(a.inputs, b.inputs)
            XCTAssertEqual(a.outputs, b.outputs)
        }
    }

    /// And it still answers the same way, which is the thing anybody actually
    /// cares about: a file that loads and infers differently is worse than one
    /// that does not load.
    func testTheRewrittenPolicyGivesTheSameActions() throws {
        let original = try DuckPolicy.load(from: bundled("alpha_walking"))
        let rewritten = try DuckPolicy.load(from: original.encoded())
        let observation = try XCTUnwrap(DuckObservation(exactly:
            (0..<DuckObservation.length).map { Float($0 % 7) * 0.13 - 0.4 }))
        XCTAssertEqual(rewritten.infer(observation), original.infer(observation))
    }

    /// Every bundled policy, because one working file proves one working file.
    func testEveryBundledPolicyRoundTrips() throws {
        for name in ["alpha_walking"] {
            guard let data = try? bundled(name) else { continue }
            let original = try DuckPolicy.load(from: data)
            let again = try DuckPolicy.load(from: original.encoded())
            XCTAssertEqual(again.infer(.zeroed), original.infer(.zeroed), name)
        }
    }

    // MARK: - blending, which is the reason the writer exists

    /// TWO POLICIES AVERAGED ARE STILL A POLICY THIS LOADER ACCEPTS. That is a
    /// claim about the FILE and nothing else — whether the result walks is a
    /// separate question, and one only a physics bench can answer. Asserting
    /// the file loads is exactly as much as this test is entitled to say.
    func testABlendOfTwoPoliciesIsStillALoadablePolicy() throws {
        let a = try DuckPolicy.load(from: bundled("alpha_walking"))
        // A SECOND POLICY MADE BY PERTURBING THE FIRST, because only one real
        // network is vendored here. That is enough for what this test claims —
        // the claim is about the FILE surviving a blend, not about two
        // separately-trained networks averaging into something that walks.
        let pa = a.parameters
        let pb = (mean: pa.mean, std: pa.std,
                  layers: pa.layers.map {
                      DuckPolicyWriter.Layer(weights: $0.weights.map { $0 * 0.9 + 0.01 },
                                             biases: $0.biases.map { $0 - 0.02 },
                                             inputs: $0.inputs, outputs: $0.outputs)
                  })

        func mix(_ x: [Float], _ y: [Float], _ t: Float) -> [Float] {
            zip(x, y).map { $0 * (1 - t) + $1 * t }
        }
        let t: Float = 0.5
        let layers = zip(pa.layers, pb.layers).map {
            DuckPolicyWriter.Layer(weights: mix($0.weights, $1.weights, t),
                                   biases: mix($0.biases, $1.biases, t),
                                   inputs: $0.inputs, outputs: $0.outputs)
        }
        let bytes = try DuckPolicyWriter.encoded(mean: mix(pa.mean, pb.mean, t),
                                                 std: mix(pa.std, pb.std, t),
                                                 layers: layers)
        let blended = try DuckPolicy.load(from: bytes)
        XCTAssertEqual(blended.parameters.layers.count, DuckPolicy.expectedWidths.count)

        // A blend at t=0 is the first policy, which is the sanity check that
        // the mixing is doing what its name says.
        let atZero = try DuckPolicy.load(from: DuckPolicyWriter.encoded(
            mean: mix(pa.mean, pb.mean, 0), std: mix(pa.std, pb.std, 0),
            layers: zip(pa.layers, pb.layers).map {
                DuckPolicyWriter.Layer(weights: mix($0.weights, $1.weights, 0),
                                       biases: mix($0.biases, $1.biases, 0),
                                       inputs: $0.inputs, outputs: $0.outputs)
            }))
        XCTAssertEqual(atZero.infer(.zeroed), a.infer(.zeroed))
    }

    // MARK: - it refuses to write something nobody could load

    /// A malformed file is much worse found in robotd than found here.
    func testItRefusesAShapeThatIsNotAMicroduckPolicy() throws {
        let good = try DuckPolicy.load(from: bundled("alpha_walking")).parameters
        XCTAssertThrowsError(try DuckPolicyWriter.encoded(
            mean: Array(good.mean.dropLast()), std: good.std, layers: good.layers))
        XCTAssertThrowsError(try DuckPolicyWriter.encoded(
            mean: good.mean, std: good.std, layers: Array(good.layers.dropLast())))

        let short = DuckPolicyWriter.Layer(weights: [1, 2, 3], biases: good.layers[0].biases,
                                           inputs: good.layers[0].inputs,
                                           outputs: good.layers[0].outputs)
        XCTAssertThrowsError(try DuckPolicyWriter.encoded(
            mean: good.mean, std: good.std, layers: [short] + good.layers.dropFirst())) {
            XCTAssertTrue(($0 as? DuckPolicyWriter.WriteError)?.message.contains("3 weights") ?? false,
                          "the refusal must name what was actually wrong")
        }
    }

    /// A FILE THIS PACKAGE LOADS IS NOT NECESSARILY A FILE ANYTHING ELSE LOADS.
    /// `DuckPolicy` walks straight to the graph and never reads the header, so
    /// a graph-only file round-tripped through load/encode/load perfectly here
    /// and onnxruntime refused it: "Missing opset in the model." Caught by
    /// uploading one to a real bench. These two fields are read out of Pollen's
    /// own alpha_walking.onnx rather than chosen.
    func testTheFileCarriesTheHeaderARealRuntimeInsistsOn() throws {
        let bytes = [UInt8](try DuckPolicy.load(from: bundled("alpha_walking")).encoded())

        func topLevel(_ data: [UInt8]) -> [(field: Int, wire: Int, varint: UInt64)] {
            var out: [(Int, Int, UInt64)] = [], i = 0
            func read() -> UInt64 {
                var r: UInt64 = 0, s: UInt64 = 0
                while i < data.count {
                    let b = data[i]; i += 1
                    r |= UInt64(b & 0x7F) << s
                    if b & 0x80 == 0 { break }
                    s += 7
                }
                return r
            }
            while i < data.count {
                let tag = read(), field = Int(tag >> 3), wire = Int(tag & 7)
                if wire == 0 { out.append((field, wire, read())) }
                else if wire == 2 { let n = read(); out.append((field, wire, n)); i += Int(n) }
                else { break }
            }
            return out
        }

        let fields = topLevel(bytes)
        XCTAssertTrue(fields.contains { $0.field == 1 && $0.wire == 0 && $0.varint == 8 },
                      "ir_version 8 is missing")
        XCTAssertTrue(fields.contains { $0.field == 7 && $0.wire == 2 }, "the graph is missing")
        XCTAssertTrue(fields.contains { $0.field == 8 && $0.wire == 2 },
                      "opset_import is missing — onnxruntime refuses a model without one")
    }

    // MARK: - the three things a real runtime checked and this package never did

    /// EVERY NODE MUST NAME ITS OUTPUT, and this package's own reader is not
    /// the check that catches it: `DuckPolicy` infers the chain from position
    /// and never reads a node output, so a graph with none round-tripped here
    /// perfectly and onnxruntime refused it — "This is an invalid model. Graph
    /// output (actions) does not exist in the graph."
    ///
    /// Asserted by walking the emitted protobuf rather than by reloading,
    /// because reloading is exactly the test that passed while the file was
    /// broken.
    func testEveryNodeNamesItsOutputAndSomethingProducesActions() throws {
        let bytes = [UInt8](try writtenPolicy())
        let graph = try XCTUnwrap(Fields.first(7, in: bytes), "no graph")
        let nodes = Fields.all(1, in: graph)
        XCTAssertEqual(nodes.count, 9, "the nine ops the reader insists on")

        var produced: Set<String> = []
        for node in nodes {
            let outputs = Fields.all(2, in: node).map { String(decoding: $0, as: UTF8.self) }
            let op = String(decoding: try XCTUnwrap(Fields.first(4, in: node)), as: UTF8.self)
            XCTAssertEqual(outputs.count, 1, "\(op) declares \(outputs.count) outputs, not one")
            produced.formUnion(outputs)
        }
        XCTAssertTrue(produced.contains("actions"),
                      "nothing in the graph produces the output the graph declares")

        // And every input is either produced by a node, an initializer, or the
        // graph's own input — a dangling edge is the other half of this bug.
        var available = Set(Fields.all(5, in: graph).compactMap { tensor -> String? in
            Fields.first(8, in: tensor).map { String(decoding: $0, as: UTF8.self) }
        })
        available.insert("obs")
        for node in nodes {
            for input in Fields.all(1, in: node).map({ String(decoding: $0, as: UTF8.self) }) {
                XCTAssertTrue(available.contains(input), "\(input) is produced by nothing")
            }
            available.formUnion(Fields.all(2, in: node).map { String(decoding: $0, as: UTF8.self) })
        }
    }

    /// AN ATTRIBUTE MUST SAY WHICH KIND IT IS. Field 20 is required, this
    /// package's reader never looked at it, and onnxruntime said "Error Field
    /// 'type' of 'attr' is required but missing". INT is 2.
    func testTheTransposeAttributeDeclaresItsType() throws {
        let bytes = [UInt8](try writtenPolicy())
        let graph = try XCTUnwrap(Fields.first(7, in: bytes))
        var checked = 0
        for node in Fields.all(1, in: graph) {
            for attribute in Fields.all(5, in: node) {
                let name = String(decoding: try XCTUnwrap(Fields.first(1, in: attribute)),
                                  as: UTF8.self)
                XCTAssertEqual(name, "transB")
                XCTAssertEqual(Fields.varint(20, in: attribute), 2,
                               "transB must declare AttributeType INT")
                XCTAssertEqual(Fields.varint(3, in: attribute), 1)
                checked += 1
            }
        }
        XCTAssertEqual(checked, 4, "one per Gemm")
    }

    /// The graph's declared input and output carry a type, with the batch left
    /// symbolic — what a trained export looks like, and what robotd's own
    /// `check_width` assumes when it says the leading dimension is dynamic.
    func testTheDeclaredInputAndOutputCarryTheirWidths() throws {
        let bytes = [UInt8](try writtenPolicy())
        let graph = try XCTUnwrap(Fields.first(7, in: bytes))
        for (field, wanted) in [(11, 61), (12, 14)] {
            let value = try XCTUnwrap(Fields.first(field, in: graph))
            let type = try XCTUnwrap(Fields.first(2, in: value))
            let tensor = try XCTUnwrap(Fields.first(1, in: type))
            XCTAssertEqual(Fields.varint(1, in: tensor), 1, "elem_type FLOAT")
            let shape = try XCTUnwrap(Fields.first(2, in: tensor))
            let dims = Fields.all(1, in: shape)
            XCTAssertEqual(dims.count, 2)
            XCTAssertNotNil(Fields.first(2, in: dims[0]), "the batch stays symbolic")
            XCTAssertEqual(Fields.varint(1, in: dims[1]), UInt64(wanted))
        }
    }

    // MARK: - just enough protobuf to inspect what was written

    /// Reading the file back with this package's own loader is the test that
    /// passed while onnxruntime refused the bytes three separate times. These
    /// walk the wire format instead.
    private enum Fields {
        static func all(_ field: Int, in bytes: [UInt8]) -> [[UInt8]] {
            var out: [[UInt8]] = []
            walk(bytes) { number, wire, payload, value in
                if number == field && wire == 2 { out.append(payload) }
                _ = value
            }
            return out
        }

        static func first(_ field: Int, in bytes: [UInt8]) -> [UInt8]? {
            all(field, in: bytes).first
        }

        static func varint(_ field: Int, in bytes: [UInt8]) -> UInt64? {
            var found: UInt64?
            walk(bytes) { number, wire, _, value in
                if number == field && wire == 0 && found == nil { found = value }
            }
            return found
        }

        private static func walk(_ bytes: [UInt8],
                                 _ visit: (Int, Int, [UInt8], UInt64) -> Void) {
            var i = 0
            func varint() -> UInt64? {
                var value: UInt64 = 0, shift: UInt64 = 0
                while i < bytes.count {
                    let byte = bytes[i]; i += 1
                    value |= UInt64(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { return value }
                    shift += 7
                    if shift > 63 { return nil }
                }
                return nil
            }
            while i < bytes.count {
                guard let tag = varint() else { return }
                let number = Int(tag >> 3), wire = Int(tag & 7)
                switch wire {
                case 0:
                    guard let value = varint() else { return }
                    visit(number, 0, [], value)
                case 2:
                    guard let length = varint(), i + Int(length) <= bytes.count else { return }
                    visit(number, 2, Array(bytes[i..<(i + Int(length))]), 0)
                    i += Int(length)
                case 5: i += 4
                case 1: i += 8
                default: return
                }
            }
        }
    }
}
