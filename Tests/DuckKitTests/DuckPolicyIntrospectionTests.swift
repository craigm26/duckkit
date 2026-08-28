import XCTest
@testable import DuckKit

/// The three things you can ask a loaded policy that a black box cannot
/// answer: what was in the file, what the network computed on the way to an
/// action, and how much each input slot actually mattered.
///
/// EACH OF THESE IS PROVED AGAINST SOMETHING THAT ALREADY EXISTED. `describe`
/// is checked against the same vendored `alpha_walking.onnx` the forward pass
/// is proved on, so its widths and its parameter count are the real network's
/// and not a fixture's. `inferTrace` is checked for *exact* equality with
/// `infer` — not approximate, because both are supposed to be one function.
/// And `jacobian` is checked against central differences, which is the whole
/// reason the analytic version is allowed to exist: an exact derivative that
/// nobody compared to a numerical one is just a confident opinion.
final class DuckPolicyIntrospectionTests: XCTestCase {

    private func vendoredURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(
            forResource: "alpha_walking", withExtension: "onnx", subdirectory: "Fixtures/duck"))
    }

    private func vendoredPolicy() throws -> DuckPolicy {
        try DuckPolicy.load(contentsOf: vendoredURL())
    }

    /// The sentence a refusal carries, whatever kind of refusal it is.
    private func message(of error: Error) -> String {
        guard let refusal = error as? DuckPolicy.LoadError else { return "\(error)" }
        switch refusal {
        case .malformed(let text), .unsupportedArchitecture(let text), .shape(let text): return text
        }
    }

    /// Three observations that put the network in visibly different places:
    /// the all-zero warm-up input (32 σ out of distribution on gravity z), an
    /// ordinary forward walk near the home pose, and a tilted robot with
    /// joints off their home pose and every command axis in use.
    private func observations() -> [(name: String, observation: DuckObservation)] {
        var walkingPositions = DuckModel.homePose
        walkingPositions[2] += 0.08   // left_hip_pitch
        walkingPositions[13] -= 0.06  // right_knee
        var walkingVelocities = [Double](repeating: 0, count: DuckModel.jointCount)
        walkingVelocities[3] = 0.4
        walkingVelocities[12] = -0.3
        var walkingLast = [Float](repeating: 0, count: DuckModel.policyJointCount)
        walkingLast[0] = 0.12
        walkingLast[7] = -0.2
        walkingLast[13] = 0.05

        var tiltedPositions = DuckModel.homePose
        tiltedPositions[0] = 0.2
        tiltedPositions[1] = -0.25
        tiltedPositions[10] = -0.2
        tiltedPositions[14] = -0.5
        let tiltedVelocities = (0..<DuckModel.jointCount).map { Double($0 % 5) * 0.25 - 0.5 }
        let tiltedLast = (0..<DuckModel.policyJointCount).map { Float($0 % 4) * 0.15 - 0.2 }

        return [
            (name: "zeroed", observation: DuckObservation.zeroed),
            (name: "walking", observation: DuckObservation.build(
                gyro: [0.05, -0.02, 0.10],
                gravity: [0.02, -0.01, -0.99],
                jointPositions: walkingPositions,
                jointVelocities: walkingVelocities,
                lastAction: walkingLast,
                command: DuckCommand(twist: (0.15, 0.0, 0.3), head: (0.1, -0.1, 0.25, 0.0),
                                     bodyZ: -0.01, bodyRoll: 0.0, bodyPitch: 0.05))),
            (name: "tilted", observation: DuckObservation.build(
                gyro: [-0.4, 0.3, 0.6],
                gravity: [-0.3, 0.1, -0.95],
                jointPositions: tiltedPositions,
                jointVelocities: tiltedVelocities,
                lastAction: tiltedLast,
                command: DuckCommand(twist: (-0.1, 0.2, -0.4), head: (-0.3, 0.4, -0.5, 0.15),
                                     bodyZ: 0.03, bodyRoll: -0.08, bodyPitch: 0.12))),
        ]
    }

    // ── describe ─────────────────────────────────────────────────────────

    func testDescribeReadsTheVendoredFilesWholeStructure() throws {
        let structure = try DuckPolicy.describe(contentsOf: vendoredURL())

        XCTAssertEqual(structure.ops,
                       ["Sub", "Div", "Gemm", "Elu", "Gemm", "Elu", "Gemm", "Elu", "Gemm"],
                       "the nine ops every alpha policy is made of, in graph order")
        XCTAssertEqual(structure.inputs, ["obs"], "the graph's own input tensor name")
        XCTAssertEqual(structure.outputs, ["actions"], "the graph's own output tensor name")

        XCTAssertEqual(structure.initializers.map(\.name), [
            "obs_normalizer._mean",
            "mlp.0.weight", "mlp.0.bias",
            "mlp.2.weight", "mlp.2.bias",
            "mlp.4.weight", "mlp.4.bias",
            "mlp.6.weight", "mlp.6.bias",
            "onnx::Div_24",
        ], "four weights, four biases, a mean and a std — in the file's own order")

        func dims(_ name: String) -> [Int]? {
            structure.initializers.first { $0.name == name }?.dims
        }
        // Gemm transB=1 stores [outputs, inputs]: a weight that reads
        // [61, 512] here is a transposed export, not a duck policy.
        XCTAssertEqual(dims("mlp.0.weight"), [512, 61], "layer 0 weight")
        XCTAssertEqual(dims("mlp.2.weight"), [256, 512], "layer 1 weight")
        XCTAssertEqual(dims("mlp.4.weight"), [128, 256], "layer 2 weight")
        XCTAssertEqual(dims("mlp.6.weight"), [14, 128], "layer 3 weight")
        XCTAssertEqual(dims("mlp.6.bias"), [14], "one bias per action")
        XCTAssertEqual(dims("obs_normalizer._mean"), [1, 61],
                       "the normalizer ships as a 1×61 row, not a bare 61")
        XCTAssertEqual(structure.initializers.first { $0.name == "mlp.2.weight" }?.count, 131_072,
                       "count is what the dims declare: 256 × 512")

        XCTAssertEqual(structure.parameterCount, 197_896,
                       "61×512+512 + 512×256+256 + 256×128+128 + 128×14+14 = 197,774 learned "
                       + "weights and biases, plus the 61-float mean and 61-float std")
    }

    /// `load` is `describe` plus judgment, so the widths it enforces are the
    /// widths `describe` reports off the tensors themselves. If these two ever
    /// disagree, one of them is reading a different file than it is talking
    /// about.
    func testDescribeAndLoadCannotDisagreeAboutTheVendoredFile() throws {
        let url = try vendoredURL()
        let structure = try DuckPolicy.describe(contentsOf: url)
        let policy = try DuckPolicy.load(contentsOf: url)

        let weightDims = structure.initializers.filter { $0.name.hasSuffix(".weight") }.map(\.dims)
        XCTAssertEqual(weightDims, policy.layerWidths.map { [$0.outputs, $0.inputs] },
                       "the weight tensors describe() saw are the layers load() built")
        XCTAssertEqual(structure.ops.filter { $0 == "Gemm" }.count, policy.layerWidths.count,
                       "one Gemm per dense layer")
        XCTAssertEqual(policy.layerWidths.map { [$0.inputs, $0.outputs] },
                       [[61, 512], [512, 256], [256, 128], [128, 14]])
        XCTAssertEqual(policy.parameterCount, 197_774,
                       "the learned map alone: weights and biases, no normalizer statistics")
        XCTAssertEqual(structure.parameterCount - policy.parameterCount, 2 * DuckObservation.length,
                       "the file carries exactly 61 mean and 61 std floats beyond the learned map")
    }

    /// The screen this exists for: a file DuckKit will not run, described in
    /// full next to the sentence explaining why it will not run it. The
    /// vendored graph with its three `Elu` op strings overwritten by `Abs` —
    /// a real ONNX op, the same three bytes wide — is still a network
    /// onnxruntime would happily execute, and still not a duck policy.
    func testDescribeStillReadsAFileThatLoadRefuses() throws {
        let original = try Data(contentsOf: vendoredURL())
        var bytes = [UInt8](original)
        // NodeProto field 4 is op_type: tag 0x22, length 0x03, then "Elu".
        var swapped = 0
        var i = 0
        while i + 5 <= bytes.count {
            if bytes[i] == 0x22, bytes[i + 1] == 0x03,
               bytes[i + 2] == 0x45, bytes[i + 3] == 0x6c, bytes[i + 4] == 0x75 {
                bytes[i + 2] = 0x41  // A
                bytes[i + 3] = 0x62  // b
                bytes[i + 4] = 0x73  // s
                swapped += 1
                i += 5
            } else {
                i += 1
            }
        }
        XCTAssertEqual(swapped, 3, "the vendored graph has exactly three Elu nodes to rename")

        let data = Data(bytes)
        let structure = try DuckPolicy.describe(from: data)
        XCTAssertEqual(structure.ops,
                       ["Sub", "Div", "Gemm", "Abs", "Gemm", "Abs", "Gemm", "Abs", "Gemm"],
                       "describe reports the activation the file actually names")
        XCTAssertEqual(structure.initializers.count, 10,
                       "the weights are untouched and still fully readable")
        XCTAssertEqual(structure.parameterCount, 197_896, "and still fully counted")
        XCTAssertEqual(structure.inputs, ["obs"])
        XCTAssertEqual(structure.outputs, ["actions"])

        XCTAssertThrowsError(try DuckPolicy.load(from: data)) { error in
            XCTAssertEqual(error as? DuckPolicy.LoadError,
                           DuckPolicy.LoadError.unsupportedArchitecture("op sequence \(structure.ops)"),
                           "the refusal is a statement about the same description")
            XCTAssertTrue(message(of: error).contains("Abs"),
                          "a refusal must name what it found: \(message(of: error))")
        }
    }

    /// The smallest thing that is a walkable ONNX model and not a network:
    /// ModelProto field 7 (graph), wire type 2, length 0. Describing it
    /// succeeds and says "nothing"; loading it refuses and says why.
    func testAnEmptyGraphDescribesAsEmptyAndIsRefusedWithASentence() throws {
        let data = Data([0x3a, 0x00])
        let structure = try DuckPolicy.describe(from: data)
        XCTAssertTrue(structure.ops.isEmpty, "no ops to report")
        XCTAssertTrue(structure.initializers.isEmpty, "no initializers to report")
        XCTAssertTrue(structure.inputs.isEmpty)
        XCTAssertTrue(structure.outputs.isEmpty)
        XCTAssertEqual(structure.parameterCount, 0)

        XCTAssertThrowsError(try DuckPolicy.load(from: data)) { error in
            XCTAssertEqual(error as? DuckPolicy.LoadError,
                           DuckPolicy.LoadError.unsupportedArchitecture("op sequence []"),
                           "an empty graph is refused for its op sequence, like any other file")
        }
    }

    /// Describing is allowed to fail in exactly one way: the bytes are not
    /// protobuf that can be walked. Anything that parses, describes.
    func testDescribeThrowsOnlyWhenTheBytesAreNotWalkableProtobuf() throws {
        XCTAssertThrowsError(try DuckPolicy.describe(from: Data("not a network".utf8)),
                             "ASCII is not a wire format")
        XCTAssertThrowsError(try DuckPolicy.describe(from: Data()),
                             "an empty file has no ModelProto, let alone a graph")
        let whole = try Data(contentsOf: vendoredURL())
        XCTAssertThrowsError(try DuckPolicy.describe(from: whole.prefix(whole.count / 2)),
                             "a half-downloaded policy declares a graph longer than the file")
    }

    // ── the trace ────────────────────────────────────────────────────────

    /// Not "close to" — equal. Both paths are one function with one flag, so
    /// any difference at all would mean the traced pass is not the pass that
    /// drives the robot.
    func testTheTracedActionsAreExactlyWhatInferReturns() throws {
        let policy = try vendoredPolicy()
        for (name, observation) in observations() {
            XCTAssertEqual(policy.inferTrace(observation).actions, policy.infer(observation),
                           "\(name): the traced forward pass must be the same forward pass")
        }
    }

    func testTheTraceExposesTheNormalizedInputAndEveryHiddenLayer() throws {
        let policy = try vendoredPolicy()
        let (mean, std) = policy.normalization

        for (name, observation) in observations() {
            let trace = policy.inferTrace(observation)
            XCTAssertEqual(trace.normalized.count, DuckObservation.length, "\(name): 61 in")
            XCTAssertEqual(trace.hidden.map(\.count), [512, 256, 128],
                           "\(name): three hidden layers, outermost first")
            XCTAssertEqual(trace.actions.count, DuckModel.policyJointCount, "\(name): 14 out")

            for i in 0..<DuckObservation.length {
                XCTAssertEqual(trace.normalized[i], (observation.values[i] - mean[i]) / std[i],
                               "\(name): normalized[\(i)] must be the trained z-score of slot \(i)")
            }

            // What the trace is for: counting units in the exponential
            // regime. ELU is floored at −1 there, and on a real policy a
            // couple of hundred units per layer sit below zero at any moment.
            XCTAssertNil(trace.hidden.flatMap { $0 }.first { $0 < -1 },
                         "\(name): ELU cannot produce a value below −1")
            for (layer, activations) in trace.hidden.enumerated() {
                let dead = activations.filter { $0 <= 0 }.count
                XCTAssertGreaterThan(dead, 0,
                                     "\(name): hidden layer \(layer) has no units in the "
                                     + "exponential regime, which no trained ELU net does")
                XCTAssertLessThan(dead, activations.count,
                                  "\(name): hidden layer \(layer) is entirely dead")
            }
        }
    }

    // ── the jacobian ─────────────────────────────────────────────────────

    /// The test that earns the analytic implementation.
    ///
    /// The step is 0.003 *in normalized space*, and the choice is measured
    /// rather than guessed: at 0.001 the difference of two float32 forward
    /// passes has lost enough significant digits that the numerical answer is
    /// off by 6.6e-4, and at 0.02 the step is wide enough to straddle the ELU
    /// kink at zero and average two different slopes, off by 1.5e-3. At 0.003
    /// the worst entry over these observations is 1.8e-4. That U-shaped error
    /// curve, with no single step that is right for every slot, is the reason
    /// `jacobian` differentiates instead of nudging.
    func testTheJacobianMatchesCentralDifferencesAtSeveralObservations() throws {
        let policy = try vendoredPolicy()
        let step: Float = 0.003

        for (name, observation) in observations() {
            let analytic = policy.jacobian(at: observation)
            XCTAssertEqual(analytic.count, DuckModel.policyJointCount,
                           "\(name): one row per action")
            XCTAssertEqual(analytic.map(\.count),
                           [Int](repeating: DuckObservation.length, count: DuckModel.policyJointCount),
                           "\(name): one column per observation slot")

            let base = policy.inferTrace(observation).normalized
            for slot in 0..<DuckObservation.length {
                var up = base, down = base
                up[slot] += step
                down[slot] -= step
                let high = policy.evaluate(normalized: up)
                let low = policy.evaluate(normalized: down)
                for action in 0..<DuckModel.policyJointCount {
                    let numeric = (high[action] - low[action]) / (2 * step)
                    XCTAssertEqual(analytic[action][slot], numeric, accuracy: 1e-3,
                                   "\(name): ∂action[\(action)] / ∂normalized[\(slot)]")
                }
            }
        }
    }

    /// A jacobian of zeros would pass a sloppy tolerance check against a
    /// network that barely responds, so pin the scale too: the trained policy
    /// really does move its actions when its observation moves.
    func testTheJacobianIsNotTriviallyZero() throws {
        let policy = try vendoredPolicy()
        for (name, observation) in observations() {
            let largest = policy.jacobian(at: observation).flatMap { $0 }.map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(largest, 0.05,
                                 "\(name): the network's strongest slot barely moves its action")
        }
    }

    // ── the normalizer ───────────────────────────────────────────────────

    func testTheTrainedNormalizerIsReachableAndHasNoZeroStandardDeviations() throws {
        let policy = try vendoredPolicy()
        let (mean, std) = policy.normalization
        XCTAssertEqual(mean.count, DuckObservation.length, "one mean per observation slot")
        XCTAssertEqual(std.count, DuckObservation.length, "one std per observation slot")

        for (slot, deviation) in std.enumerated() {
            XCTAssertTrue(deviation.isFinite,
                          "std[\(slot)] is \(deviation) — every inference after it would be NaN")
            XCTAssertGreaterThan(deviation, 0,
                                 "std[\(slot)] is \(deviation) — dividing slot \(slot) by it "
                                 + "would poison every inference")
        }

        // The spread across slots is the argument for the analytic jacobian:
        // there is no one epsilon that is small in slot 23 and large in slot 55.
        let smallest = try XCTUnwrap(std.min())
        let largest = try XCTUnwrap(std.max())
        XCTAssertEqual(smallest, 0.0129, accuracy: 5e-4,
                       "the unbound body axes barely move in training")
        XCTAssertEqual(largest, 3.029, accuracy: 5e-3, "a joint velocity moves a great deal")
        XCTAssertGreaterThan(largest / smallest, 200,
                             "the trained scales differ by more than two orders of magnitude")

        // And the sentence the normalizer makes possible, on the one
        // observation the kit ships as a constant: all-zero gravity is not a
        // pose, it is free fall, 32 standard deviations from anything trained.
        XCTAssertEqual((0 - mean[5]) / std[5], 31.96, accuracy: 0.05,
                       "DuckObservation.zeroed is far out of distribution on projected gravity z")
    }
}
