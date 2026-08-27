import XCTest
@testable import DuckKit

/// The pure-Swift forward pass, proved against the robot's own network: the
/// vendored `alpha_walking.onnx` is the real trained policy, and the golden
/// file holds what onnxruntime computes for it. Same weights, same bytes in,
/// the same floats out — to within accumulation order.
final class DuckPolicyTests: XCTestCase {

    private func vendoredPolicy() throws -> DuckPolicy {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "alpha_walking", withExtension: "onnx", subdirectory: "Fixtures/duck"))
        return try DuckPolicy.load(contentsOf: url)
    }

    func testTheVendoredPolicyLoadsWithTheOneSharedArchitecture() throws {
        let policy = try vendoredPolicy()
        XCTAssertEqual(policy.layers.map { [$0.inputs, $0.outputs] }, [[61, 512], [512, 256], [256, 128], [128, 14]])
        XCTAssertEqual(policy.mean.count, 61)
        XCTAssertEqual(policy.std.count, 61)
    }

    func testTheForwardPassReproducesOnnxruntimeOnTheGoldenCases() throws {
        let policy = try vendoredPolicy()
        let goldenURL = try XCTUnwrap(Bundle.module.url(
            forResource: "golden_policies", withExtension: "json", subdirectory: "Fixtures/duck"))
        let doc = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: goldenURL)) as? [String: Any])
        let policies = try XCTUnwrap(doc["policies"] as? [String: Any])
        let walking = try XCTUnwrap(policies["alpha_walking.onnx"] as? [String: Any])
        let cases = try XCTUnwrap(walking["cases"] as? [String: [String: [Double]]])
        XCTAssertEqual(cases.count, 4, "four golden cases were generated")

        for (name, body) in cases {
            let obsValues = try XCTUnwrap(body["obs"]).map(Float.init)
            let expected = try XCTUnwrap(body["actions"])
            var full = [Float](repeating: 0, count: 61)
            for (i, v) in obsValues.enumerated() { full[i] = v }
            // Rebuild through the public path to also exercise the layout:
            // slice the flat fixture back into its blocks.
            let obs = DuckObservation.build(
                gyro: full[0..<3].map(Double.init),
                gravity: full[3..<6].map(Double.init),
                jointPositions: DuckObservation.scatterAction(Array(full[6..<20])).enumerated().map {
                    $1 + DuckModel.homePose[$0]
                },
                jointVelocities: DuckObservation.scatterAction(Array(full[20..<34])),
                lastAction: Array(full[34..<48]),
                command: DuckCommand(
                    twist: (Double(full[48]), Double(full[49]), Double(full[50])),
                    head: (Double(full[51]), Double(full[52]), Double(full[53]), Double(full[54])),
                    bodyZ: Double(full[57]), bodyRoll: Double(full[58]), bodyPitch: Double(full[59])))
            XCTAssertEqual(obs.values, [Float](full), "the fixture obs must survive the build round-trip — \(name)")

            let actions = policy.infer(obs)
            XCTAssertEqual(actions.count, 14)
            for (i, e) in expected.enumerated() {
                XCTAssertEqual(Double(actions[i]), e, accuracy: 1e-4,
                               "\(name): action[\(i)] diverged from onnxruntime")
            }
        }
    }

    func testGarbageIsRefusedAtLoadNotAtInference() {
        XCTAssertThrowsError(try DuckPolicy.load(from: Data("not a network".utf8)))
        XCTAssertThrowsError(try DuckPolicy.load(from: Data()))
    }

    func testATruncatedFileIsRefused() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "alpha_walking", withExtension: "onnx", subdirectory: "Fixtures/duck"))
        let whole = try Data(contentsOf: url)
        XCTAssertThrowsError(try DuckPolicy.load(from: whole.prefix(whole.count / 2)))
    }
}
