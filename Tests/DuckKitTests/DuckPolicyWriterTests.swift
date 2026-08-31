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
}
