import XCTest
@testable import DuckKit

/// A policy that is not the alpha shape, loaded and run for real.
///
/// `duckbatch_128x128.onnx` is a 26,254-parameter walker distilled from
/// Pollen's velstand by craigm26/duckbatch: the same graph as every release,
/// `(obs − mean)/std → Gemm → Elu → Gemm → Elu → Gemm`, with two hidden layers
/// of 128 instead of three of 512, 256 and 128. Pollen's browser simulator
/// loads it from the Hub; until 2026-09-24 this package refused it for its
/// widths. `golden_student.json` holds onnxruntime's actions for it on the same
/// four observations as `golden_policies.json`.
final class DuckPolicyStudentTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext,
                                        subdirectory: "Fixtures/duck"))
    }

    private func student() throws -> DuckPolicy {
        try DuckPolicy.load(contentsOf: fixture("duckbatch_128x128", "onnx"))
    }

    private func alpha() throws -> DuckPolicy {
        try DuckPolicy.load(contentsOf: fixture("alpha_walking", "onnx"))
    }

    /// The fixture's cases, as observations built through the public path.
    private func goldenCases() throws -> [(name: String, obs: DuckObservation, actions: [Double])] {
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture("golden_student", "json"))) as? [String: Any])
        let policies = try XCTUnwrap(doc["policies"] as? [String: Any])
        let entry = try XCTUnwrap(policies["duckbatch_128x128.onnx"] as? [String: Any])
        let cases = try XCTUnwrap(entry["cases"] as? [String: [String: [Double]]])
        return try cases.sorted { $0.key < $1.key }.map { name, body in
            var values = [Float](repeating: 0, count: DuckObservation.length)
            for (i, v) in try XCTUnwrap(body["obs"]).enumerated() { values[i] = Float(v) }
            return (name, try XCTUnwrap(DuckObservation(exactly: values)), try XCTUnwrap(body["actions"]))
        }
    }

    func testADistilledStudentLoadsWithItsOwnWidths() throws {
        let policy = try student()
        XCTAssertEqual(policy.layerWidths.map { [$0.inputs, $0.outputs] },
                       [[61, 128], [128, 128], [128, 14]])
        XCTAssertEqual(policy.parameterCount, 26_254,
                       "61×128+128 + 128×128+128 + 128×14+14")
        XCTAssertFalse(policy.isAlphaShape, "a student is not the shape the releases share")
    }

    func testTheAlphaShapeStillKnowsItIsTheAlphaShape() throws {
        XCTAssertTrue(try alpha().isAlphaShape)
    }

    func testTheStudentsForwardPassReproducesOnnxruntime() throws {
        let policy = try student()
        let cases = try goldenCases()
        XCTAssertEqual(cases.count, 4, "the same four observations as the alpha goldens")
        for (name, obs, expected) in cases {
            let actions = policy.infer(obs)
            XCTAssertEqual(actions.count, DuckModel.policyJointCount)
            for (i, e) in expected.enumerated() {
                XCTAssertEqual(Double(actions[i]), e, accuracy: 1e-4,
                               "\(name): action[\(i)] diverged from onnxruntime")
            }
        }
    }

    /// Two hidden layers means two traced activations, not three: the trace
    /// describes the network that ran, whatever its depth.
    func testTheTraceHasOneEntryPerHiddenLayer() throws {
        let policy = try student()
        let (_, obs, _) = try goldenCases()[0]
        XCTAssertEqual(policy.inferTrace(obs).hidden.map(\.count), [128, 128])
        XCTAssertEqual(policy.inferTrace(obs).actions, policy.infer(obs))
    }

    func testAStudentSurvivesTheWriterBitForBit() throws {
        let policy = try student()
        let reloaded = try DuckPolicy.load(from: try policy.encoded())
        XCTAssertEqual(reloaded.layerWidths.map { [$0.inputs, $0.outputs] },
                       policy.layerWidths.map { [$0.inputs, $0.outputs] })
        XCTAssertEqual(reloaded.canonicalParameterBytes, policy.canonicalParameterBytes)
        for (name, obs, _) in try goldenCases() {
            XCTAssertEqual(reloaded.infer(obs), policy.infer(obs), "\(name): same weights, same floats")
        }
    }

    /// Folding touches only the last layer, so depth never mattered to it; a
    /// unit gain and zero offset must hand back the same network.
    func testFoldingANeutralTrimIntoAStudentChangesNothing() throws {
        let policy = try student()
        let folded = try DuckPolicyWriter.folding(
            policy: policy,
            gain: Array(repeating: 1, count: DuckModel.policyJointCount),
            offset: Array(repeating: 0, count: DuckModel.policyJointCount))
        for (name, obs, _) in try goldenCases() {
            let a = policy.infer(obs), b = folded.infer(obs)
            for i in 0..<a.count {
                XCTAssertEqual(a[i], b[i], accuracy: 1e-6, "\(name): action[\(i)]")
            }
        }
    }

    // ── what stays refused ──────────────────────────────────────────────────

    func testTheShapeRuleRefusesEveryWayAChainCanBeWrong() {
        let refusals: [(String, [(inputs: Int, outputs: Int)], String)] = [
            ("no layers", [], "no layers"),
            ("a linear map", [(61, 14)], "0 hidden layers"),
            ("too deep", [(61, 64), (64, 64), (64, 64), (64, 64), (64, 64), (64, 14)], "5 hidden layers"),
            ("no command block", [(48, 128), (128, 14)], "48 inputs"),
            ("the mouth as an output", [(61, 128), (128, 15)], "15 outputs"),
            ("a broken chain", [(61, 128), (64, 14)], "layer 0 gives 128 outputs but layer 1 takes 64"),
            ("too wide", [(61, 2_048), (2_048, 14)], "widths run from 1 to 1024"),
            ("too many parameters", [(61, 1_024), (1_024, 1_024), (1_024, 14)], "parameters"),
        ]
        for (what, widths, fragment) in refusals {
            let problem = DuckPolicy.shapeProblem(widths)
            XCTAssertNotNil(problem, "\(what) must be refused")
            XCTAssertTrue(problem?.contains(fragment) ?? false,
                          "\(what): the sentence should say \(fragment), said \(problem ?? "nothing")")
        }
        XCTAssertNil(DuckPolicy.shapeProblem(DuckPolicy.expectedWidths.map { ($0.0, $0.1) }),
                     "the alpha shape is inside every bound")
        XCTAssertNil(DuckPolicy.shapeProblem([(61, 32), (32, 32), (32, 14)]),
                     "a 3,502-parameter student is a network, however small")
    }

    /// One rule, two doors: what the reader refuses, the writer will not write.
    func testTheWriterRefusesAChainWithTheReadersSentence() {
        let mean = [Float](repeating: 0, count: DuckObservation.length)
        let std = [Float](repeating: 1, count: DuckObservation.length)
        let layers = [
            DuckPolicyWriter.Layer(weights: [Float](repeating: 0, count: 61 * 128),
                                   biases: [Float](repeating: 0, count: 128), inputs: 61, outputs: 128),
            DuckPolicyWriter.Layer(weights: [Float](repeating: 0, count: 64 * 14),
                                   biases: [Float](repeating: 0, count: 14), inputs: 64, outputs: 14),
        ]
        let widths = layers.map { (inputs: $0.inputs, outputs: $0.outputs) }
        XCTAssertThrowsError(try DuckPolicyWriter.encoded(mean: mean, std: std, layers: layers)) { error in
            XCTAssertEqual(error as? DuckPolicyWriter.WriteError,
                           .wrongShape(DuckPolicy.shapeProblem(widths) ?? ""))
        }
    }

    /// A trailing activation, a missing normaliser, a Relu: the op pattern is
    /// still exact, only its length varies.
    func testTheOpPatternIsExactEvenThoughItsLengthVaries() throws {
        var bytes = [UInt8](try Data(contentsOf: fixture("duckbatch_128x128", "onnx")))
        // NodeProto op_type "Elu" (tag 0x22, length 3) → "Abs", as the alpha
        // refusal test does: a real op, the same width, not a duck policy.
        var i = 0, swapped = 0
        while i + 5 <= bytes.count {
            if bytes[i] == 0x22, bytes[i + 1] == 0x03,
               bytes[i + 2] == 0x45, bytes[i + 3] == 0x6c, bytes[i + 4] == 0x75 {
                bytes[i + 2] = 0x41; bytes[i + 3] = 0x62; bytes[i + 4] = 0x73
                swapped += 1; i += 5
            } else { i += 1 }
        }
        XCTAssertEqual(swapped, 2, "the student has exactly two Elu nodes")
        let data = Data(bytes)
        let ops = try DuckPolicy.describe(from: data).ops
        XCTAssertThrowsError(try DuckPolicy.load(from: data)) { error in
            XCTAssertEqual(error as? DuckPolicy.LoadError, .unsupportedArchitecture("op sequence \(ops)"))
        }
    }

    // ── identity ────────────────────────────────────────────────────────────

    func testTheAlphaShapeKeepsTheV1IdentityByteForByte() throws {
        let policy = try alpha()
        let identity = policy.canonicalIdentityBytes
        XCTAssertEqual(identity.scheme, "canonical-parameter-bytes-v1")
        XCTAssertEqual(identity.bytes, policy.canonicalParameterBytes,
                       "the recorded official fingerprints are digests of exactly these bytes")
    }

    func testAStudentsIdentityCarriesItsShapeUpFront() throws {
        let policy = try student()
        let identity = policy.canonicalIdentityBytes
        XCTAssertEqual(identity.scheme, "canonical-parameter-bytes-v2")
        let header = identity.bytes.prefix(4 + 4 + 3 * 8)
        XCTAssertEqual(Data(header.prefix(4)), Data("DPv2".utf8))
        let words = stride(from: 4, to: header.count, by: 4).map { offset -> UInt32 in
            header.dropFirst(offset).prefix(4).enumerated()
                .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
        XCTAssertEqual(words, [3, 61, 128, 128, 128, 128, 14], "layer count, then inputs and outputs")
        XCTAssertEqual(identity.bytes.dropFirst(header.count), policy.canonicalParameterBytes,
                       "after the header, the v1 bytes unchanged")
    }
}
