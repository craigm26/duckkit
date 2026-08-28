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
///
/// THREE THINGS A DEPENDENCY WOULD NOT GIVE YOU, and the reason this file is
/// worth its size. `describe` reads any ONNX file structurally and refuses to
/// judge it, so a screen can show someone what was actually inside the export
/// that was just rejected, next to the sentence rejecting it. `inferTrace`
/// hands back the 512, 256 and 128 floats `infer` computes and then throws
/// away, which turns "how many units are dead" into a question with an
/// answer. And `jacobian` differentiates the network analytically rather than
/// by nudging inputs, because the 61 slots do not share a unit: the trained
/// std spans 0.0129 (the unbound body axes) to 3.03 (a joint velocity), a
/// 235× spread, so any one finite-difference epsilon is simultaneously too
/// coarse for one slot and too fine for another.
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

    /// What is actually in an ONNX file, with no opinion about whether it is
    /// a duck policy.
    ///
    /// A REFUSAL IS ONLY HALF AN ANSWER. "op sequence [Sub, Div, Gemm, Relu,
    /// …]" tells someone their export was rejected; it does not tell them
    /// their exporter emitted Relu where PPO trained Elu, that their input
    /// tensor is called `observations` rather than `obs`, or that their first
    /// weight is 48 wide because they trained without the command block. This
    /// is the structure that goes on screen beside the sentence — the op
    /// sequence, every initializer with its dims, the graph's own input and
    /// output names, and the total float count.
    ///
    /// It is deliberately non-judgmental: anything walkable describes,
    /// including files this kit will never run. `load` is built on top of it
    /// (`describe`, then validate), so the two cannot end up disagreeing
    /// about what a file contains — the refusal and the dump are the same
    /// read of the same bytes.
    public struct Description: Equatable, Sendable {

        /// One tensor of constants the graph carries: weights, biases, and
        /// the normalizer's mean and std.
        public struct Initializer: Equatable, Sendable {
            public let name: String
            /// As the file declares them. A Gemm weight with `transB=1`
            /// stores `[outputs, inputs]`, so the first layer of a duck
            /// policy reads `[512, 61]` and not `[61, 512]` — a transposed
            /// export is visible here before it is a refusal.
            public let dims: [Int]
            /// The element count `dims` declares. Whether that many floats
            /// are actually present is a question for `load`, which says so
            /// with a `.shape` error.
            public let count: Int
        }

        /// Op types in graph order — the nine that matter here are
        /// `Sub, Div, Gemm, Elu, Gemm, Elu, Gemm, Elu, Gemm`.
        public let ops: [String]
        /// Initializers in the file's own order.
        public let initializers: [Initializer]
        /// Graph input names. A duck policy declares exactly one: `obs`.
        public let inputs: [String]
        /// Graph output names. A duck policy declares exactly one: `actions`.
        public let outputs: [String]
        /// Every float in every initializer. For `alpha_walking.onnx` that is
        /// 197,896 — the 197,774 learned weights and biases plus the 61+61
        /// floats the normalizer divides by. See `DuckPolicy.parameterCount`,
        /// which answers the other question.
        public let parameterCount: Int
    }

    /// One forward pass with its working shown.
    ///
    /// `infer` COMPUTES ALL OF THIS AND DROPS IT ON THE FLOOR. The normalized
    /// input and the three hidden activations exist for a few microseconds
    /// inside the loop and are then overwritten; keeping them costs three
    /// array retains and answers questions nothing else can. Dead units, for
    /// one: an ELU unit whose value is ≤ 0 is in the exponential regime,
    /// floored at −1, and contributes a derivative of e^z rather than 1. On
    /// the vendored walking policy an ordinary standing observation leaves
    /// roughly 250 of 512, 225 of 256 and 105 of 128 units down there — that
    /// is normal, and knowing it is normal is only possible if you can count
    /// it.
    public struct Trace: Equatable, Sendable {
        /// `(observation − mean) / std`, 61 wide. In units of training
        /// standard deviations, which is the only scale on which the 61 slots
        /// are comparable to one another.
        public let normalized: [Float]
        /// Post-ELU activations, outermost first: 512, then 256, then 128.
        public let hidden: [[Float]]
        /// The same 14 floats `infer` returns, bit for bit — both paths run
        /// the identical arithmetic in the identical order.
        public let actions: [Float]
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

    // ── what a loaded policy is made of ───────────────────────────────────

    /// The trained input statistics, exactly as the file carries them: the
    /// running mean and standard deviation accumulated over training, which
    /// every inference divides by before the first Gemm sees a number.
    ///
    /// THESE ARE THE ONLY SCALE ON WHICH AN OBSERVATION CAN BE JUDGED. Slot 27
    /// is a joint velocity in rad/s and slot 3 is a gravity component with no
    /// unit at all; `(value − mean) / std` is what makes them comparable, and
    /// "4.2 training standard deviations out of distribution on slot 27" is
    /// the most useful sentence a policy debugger can say. Until now these
    /// numbers were parsed, used once per tick, and unreachable.
    ///
    /// The scale of what they reveal: `DuckObservation.zeroed` sits 32 σ off
    /// the training mean on slot 5 — projected gravity z, mean −0.995, std
    /// 0.031 — because an all-zero gravity vector describes a robot in free
    /// fall. That is exactly why that constant is documented as a warm-up
    /// input and never as a robot state.
    public var normalization: (mean: [Float], std: [Float]) {
        (mean, std)
    }

    /// The four dense layers as widths, outermost first:
    /// `[(61, 512), (512, 256), (256, 128), (128, 14)]` for every alpha
    /// policy. `load` refuses anything else, so this is a description of what
    /// ran rather than a thing to branch on — but a debug screen that prints
    /// the network it is about to drive a robot with should print the network
    /// it actually holds, not a constant it hopes matches.
    public var layerWidths: [(inputs: Int, outputs: Int)] {
        layers.map { ($0.inputs, $0.outputs) }
    }

    /// The learned map, counted: 61×512+512 + 512×256+256 + 256×128+128 +
    /// 128×14+14 = 197,774 weights and biases.
    ///
    /// `Description.parameterCount` reports 197,896 for the same file. Both
    /// are right: that one counts the file's initializers, which include the
    /// 61 mean and 61 std floats the normalizer carries and PyTorch would
    /// call buffers, not parameters. The difference is exactly 2 × 61.
    public var parameterCount: Int {
        layers.reduce(0) { $0 + $1.inputs * $1.outputs + $1.outputs }
    }

    // ── reading a file ────────────────────────────────────────────────────

    /// Read an ONNX file's structure without deciding whether it is usable.
    ///
    /// Throws only when the bytes are not walkable protobuf — truncated,
    /// garbage, or carrying no graph at all. Everything else describes: a
    /// half-precision export, a Relu network, a 48-wide observation, a
    /// transposed weight. That is the point. The screen that tells someone
    /// their own PPO export was refused should be able to show them what was
    /// in it, and a describer that also refuses things is no use there.
    public static func describe(from data: Data) throws -> Description {
        let file = try parse(data)
        return summarize(file)
    }

    public static func describe(contentsOf url: URL) throws -> Description {
        try describe(from: Data(contentsOf: url))
    }

    /// Parse and validate: describe the file, then check that description
    /// against the one architecture every alpha policy shares.
    ///
    /// Built as describe-then-validate on purpose. Every sentence in a
    /// `LoadError` is a statement about the same `Description` a caller can
    /// hold in its hand, from the same walk of the same bytes, so the refusal
    /// and the dump beside it can never tell different stories.
    public static func load(from data: Data) throws -> DuckPolicy {
        let file = try parse(data)
        let structure = summarize(file)

        let expected = ["Sub", "Div", "Gemm", "Elu", "Gemm", "Elu", "Gemm", "Elu", "Gemm"]
        guard structure.ops == expected else {
            throw LoadError.unsupportedArchitecture("op sequence \(structure.ops)")
        }
        for node in file.nodes where node.op == "Gemm" && !node.transB {
            throw LoadError.unsupportedArchitecture("Gemm without transB=1")
        }

        // The n-th input of a node the op sequence says must have one. A
        // hand-edited file can name the right ops and still hand a Sub a
        // single operand; that is a refusal, not a crash.
        func operand(_ node: (op: String, inputs: [String], transB: Bool), _ index: Int, _ what: String) throws -> String {
            guard index < node.inputs.count else {
                throw LoadError.unsupportedArchitecture("\(node.op) node has \(node.inputs.count) inputs, no \(what)")
            }
            return node.inputs[index]
        }

        // Constants are checked where they are used, not everywhere they
        // appear: dtype and payload size matter for the ten tensors this
        // network multiplies by, and an unused int64 constant left behind by
        // an exporter is not a reason to refuse a walking robot.
        func tensor(_ name: String, _ what: String) throws -> (dims: [Int], floats: [Float]) {
            guard let t = file.byName[name] else {
                throw LoadError.malformed("missing initializer \(name) (\(what))")
            }
            guard t.dataType == 1 else {
                throw LoadError.unsupportedArchitecture("tensor \(name) is dtype \(t.dataType), not float32")
            }
            guard t.floats.count == saturatingProduct(t.dims) else {
                throw LoadError.shape("tensor \(name): \(t.floats.count) floats for dims \(t.dims)")
            }
            return (t.dims, t.floats)
        }

        // Resolve constants through the graph rather than by name, so a
        // re-export with different tensor names still loads.
        let meanName = try operand(file.nodes[0], 1, "normalizer mean")
        let stdName = try operand(file.nodes[1], 1, "normalizer std")
        let mean = try tensor(meanName, "normalizer mean")
        let std = try tensor(stdName, "normalizer std")
        guard mean.floats.count == DuckObservation.length, std.floats.count == DuckObservation.length else {
            throw LoadError.shape("normalizer is \(mean.floats.count)/\(std.floats.count) wide, expected 61")
        }
        for (i, s) in std.floats.enumerated() where !(s.isFinite && s != 0) {
            throw LoadError.shape("normalizer std[\(i)] is \(s) — division by it would poison every inference")
        }

        var layers: [Layer] = []
        for (which, node) in file.nodes.enumerated() where node.op == "Gemm" {
            let weightName = try operand(node, 1, "weight")
            let biasName = try operand(node, 2, "bias")
            let w = try tensor(weightName, "weight")
            let b = try tensor(biasName, "bias")
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

    // ── inference ─────────────────────────────────────────────────────────

    /// One forward pass: 61 floats in, 14 raw actions out. Pure arithmetic,
    /// no allocation beyond the activations, safe at 50 Hz.
    public func infer(_ observation: DuckObservation) -> [Float] {
        forward(normalize(observation), capturing: false).actions
    }

    /// The same forward pass, keeping what it computed on the way through.
    ///
    /// Identical arithmetic to `infer` in an identical order — one function
    /// runs both, and the only difference is whether the activations are
    /// retained on their way out of the loop, so `inferTrace(o).actions` and
    /// `infer(o)` are equal bit for bit rather than merely close.
    public func inferTrace(_ observation: DuckObservation) -> Trace {
        let x = normalize(observation)
        let pass = forward(x, capturing: true)
        return Trace(normalized: x, hidden: pass.hidden, actions: pass.actions)
    }

    /// The network below the normalizer: 61 already-normalized floats in, 14
    /// actions out.
    ///
    /// Internal, not public — callers should hand over an observation and let
    /// the trained statistics apply themselves. It exists because `jacobian`
    /// is defined against exactly this function, and a finite-difference
    /// check that had to reach the input through `DuckObservation.build`
    /// could not perturb slots 55, 56 and 60 at all (they are structurally
    /// zero in every real observation), leaving three of sixty-one columns of
    /// the derivative unproven.
    func evaluate(normalized x: [Float]) -> [Float] {
        precondition(x.count == DuckObservation.length, "the network takes 61 normalized floats")
        return forward(x, capturing: false).actions
    }

    /// `(observation − mean) / std`, slot by slot.
    private func normalize(_ observation: DuckObservation) -> [Float] {
        var x = observation.values
        for i in 0..<x.count {
            x[i] = (x[i] - mean[i]) / std[i]
        }
        return x
    }

    /// The MLP itself. `capturing` costs one array retain per hidden layer
    /// and nothing else — the activations are already materialized, and
    /// copy-on-write means holding a reference does not copy them.
    private func forward(_ normalized: [Float], capturing: Bool) -> (actions: [Float], hidden: [[Float]]) {
        var x = normalized
        var hidden: [[Float]] = []
        if capturing { hidden.reserveCapacity(layers.count - 1) }
        for (index, layer) in layers.enumerated() {
            var out = DuckPolicy.linear(layer, x)
            if index < layers.count - 1 {
                // ELU, α = 1: identity above zero, exp(x)−1 below.
                for i in 0..<out.count where out[i] < 0 {
                    out[i] = expf(out[i]) - 1
                }
                if capturing { hidden.append(out) }
            }
            x = out
        }
        return (x, hidden)
    }

    /// `W·x + b`, row-major over the `[outputs][inputs]` weights.
    ///
    /// One function so that every caller — `infer`, `inferTrace`, `jacobian`
    /// and the finite-difference test that judges them — accumulates in the
    /// same order and therefore cannot drift from one another in the last
    /// bits of a float.
    private static func linear(_ layer: Layer, _ x: [Float]) -> [Float] {
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
        return out
    }

    /// `Wᵀ·g` — the reverse-mode partner of `linear`: a gradient on a layer's
    /// outputs becomes a gradient on its inputs. The bias plays no part; it
    /// is a constant and differentiates away.
    private static func linearTransposed(_ layer: Layer, _ gradient: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: layer.inputs)
        layer.weights.withUnsafeBufferPointer { w in
            gradient.withUnsafeBufferPointer { g in
                out.withUnsafeMutableBufferPointer { op in
                    for row in 0..<layer.outputs {
                        let scale = g[row]
                        let base = row * layer.inputs
                        for col in 0..<layer.inputs {
                            op[col] += scale * w[base + col]
                        }
                    }
                }
            }
        }
        return out
    }

    // ── sensitivity ───────────────────────────────────────────────────────

    /// The exact 14×61 matrix of ∂action / ∂normalized-observation at this
    /// point, by reverse mode through the ELU stack.
    ///
    /// ANALYTIC BECAUSE THE ALTERNATIVE IS PLAUSIBLY WRONG. The obvious
    /// implementation nudges each input slot by ε and divides — and there is
    /// no ε to choose. The 61 slots are radians, radians per second, and
    /// dimensionless gravity components; on the vendored walking policy the
    /// trained std runs from 0.0129 on the unbound body axes to 3.03 on a
    /// joint velocity, so a single raw-space ε of 0.01 is 0.8 σ of movement
    /// in one slot and 0.003 σ in another. Both ends are bad in the ordinary
    /// way — one straddles the ELU kink at zero and reports the average of
    /// two different slopes, the other vanishes into float32 cancellation —
    /// and neither announces itself. The output is a matrix of numbers that
    /// look fine.
    ///
    /// The derivative of ELU with α = 1 is 1 for z > 0 and e^z for z ≤ 0,
    /// which is why the pre-activations are kept here rather than recovered
    /// from the trace: for a strongly negative unit, ELU(z) + 1 loses most of
    /// its significant digits to cancellation, and e^z is the derivative.
    ///
    /// Cost: one forward pass, then fourteen backward passes of 196,864
    /// multiply-adds each — the same count as the forward pass itself, so
    /// about fourteen times forty microseconds. Central differences would
    /// need 122 forward passes to be slower *and* wrong.
    ///
    /// The derivative is with respect to the **normalized** input, which is
    /// the space the network actually operates in and the space in which the
    /// slots are comparable. Divide column *j* by `normalization.std[j]` for
    /// sensitivity to a raw observation in its own physical units.
    public func jacobian(at observation: DuckObservation) -> [[Float]] {
        // Forward, keeping the ELU slope at each hidden layer.
        var x = normalize(observation)
        var slopes: [[Float]] = []
        slopes.reserveCapacity(layers.count - 1)
        for (index, layer) in layers.enumerated() {
            var out = DuckPolicy.linear(layer, x)
            if index < layers.count - 1 {
                var slope = [Float](repeating: 1, count: out.count)
                for i in 0..<out.count where out[i] < 0 {
                    let e = expf(out[i])  // e^z, with z still in out[i]
                    slope[i] = e          // ELU′(z) = e^z for z ≤ 0
                    out[i] = e - 1        // ELU(z)
                }
                slopes.append(slope)
            }
            x = out
        }

        // Backward, once per action, seeded with a one-hot on that action.
        let outputs = layers[layers.count - 1].outputs
        var rows: [[Float]] = []
        rows.reserveCapacity(outputs)
        for output in 0..<outputs {
            var g = [Float](repeating: 0, count: outputs)
            g[output] = 1
            for index in stride(from: layers.count - 1, through: 0, by: -1) {
                g = DuckPolicy.linearTransposed(layers[index], g)
                if index > 0 {
                    let slope = slopes[index - 1]
                    for i in 0..<g.count { g[i] *= slope[i] }
                }
            }
            rows.append(g)
        }
        return rows
    }

    // ── minimal protobuf wire reader ─────────────────────────────────────
    //
    // Just enough protobuf to walk ModelProto → GraphProto → Node/Tensor:
    // varints, length-delimited fields, packed floats. Anything surprising
    // throws rather than guesses — and nothing traps, because `describe` is
    // pointed at files nobody vouched for.

    /// One walk of one file: what was there, before anyone decides whether it
    /// is a duck. `load` and `describe` both start here and neither one gets
    /// a second opinion.
    private struct Parse {
        struct Tensor {
            let name: String
            let dims: [Int]
            let dataType: UInt64
            let floats: [Float]
        }
        var nodes: [(op: String, inputs: [String], transB: Bool)] = []
        var tensors: [Tensor] = []
        var byName: [String: Tensor] = [:]
        var inputs: [String] = []
        var outputs: [String] = []
    }

    private static func parse(_ data: Data) throws -> Parse {
        let bytes = [UInt8](data)
        // ModelProto field 7 is the graph.
        guard let graph = try firstField(in: bytes[...], number: 7) else {
            throw LoadError.malformed("no graph in ModelProto")
        }
        var file = Parse()
        try scan(graph) { field, wire, payload in
            switch (field, wire) {
            case (1, 2): file.nodes.append(try parseNode(payload))
            case (5, 2):
                let t = try parseTensor(payload)
                file.tensors.append(t)
                file.byName[t.name] = t
            case (11, 2): file.inputs.append(try valueInfoName(payload))
            case (12, 2): file.outputs.append(try valueInfoName(payload))
            default: break
            }
        }
        return file
    }

    private static func summarize(_ file: Parse) -> Description {
        let initializers = file.tensors.map {
            Description.Initializer(name: $0.name, dims: $0.dims, count: saturatingProduct($0.dims))
        }
        var total = 0
        for initializer in initializers {
            let (sum, overflowed) = total.addingReportingOverflow(initializer.count)
            total = overflowed ? Int.max : sum
        }
        return Description(
            ops: file.nodes.map(\.op),
            initializers: initializers,
            inputs: file.inputs,
            outputs: file.outputs,
            parameterCount: total)
    }

    /// Dims come out of a file nobody vouched for, so their product saturates
    /// instead of trapping: `[2^62, 4]` is a thing to put on screen, not a
    /// reason to take the app down with an overflow.
    private static func saturatingProduct(_ dims: [Int]) -> Int {
        var product = 1
        for dim in dims {
            let (next, overflowed) = product.multipliedReportingOverflow(by: dim)
            product = overflowed ? Int.max : next
        }
        return product
    }

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
                let (_, after) = try varint(bytes, at: i)
                try visit(field, 0, bytes[i..<after])
                i = after
            case 2:
                let (length, after) = try varint(bytes, at: i)
                // Compared in UInt64 before any conversion: a declared length
                // of 2^40 must be a refusal, not a trap on `Int(length)`.
                guard length <= UInt64(bytes.endIndex - after) else {
                    throw LoadError.malformed("field \(field) runs past the end")
                }
                let end = after + Int(length)
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

    /// A dimension out of an untrusted file. Anything that will not fit in an
    /// `Int` is corruption rather than a shape, and lands as `Int.max` so it
    /// can be reported instead of trapping on conversion.
    private static func dimension(_ value: UInt64) -> Int {
        value > UInt64(Int.max) ? Int.max : Int(value)
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

    /// ValueInfoProto, of which only field 1 — the name — matters here.
    private static func valueInfoName(_ bytes: ArraySlice<UInt8>) throws -> String {
        var name = ""
        try scan(bytes) { field, wire, payload in
            if field == 1, wire == 2, name.isEmpty {
                name = String(decoding: payload, as: UTF8.self)
            }
        }
        return name
    }

    /// Structural only, and deliberately uncritical: dtype and payload size
    /// are recorded, not judged. `load` is where a half-precision weight
    /// becomes an error; `describe` has to be able to say what it saw.
    private static func parseTensor(_ bytes: ArraySlice<UInt8>) throws -> Parse.Tensor {
        var name = ""
        var dims: [Int] = []
        var floats: [Float] = []
        var raw: ArraySlice<UInt8>?
        var dataType: UInt64 = 1
        try scan(bytes) { field, wire, payload in
            switch (field, wire) {
            case (1, 0): dims.append(dimension(try varintValue(of: payload)))
            case (1, 2): // packed dims
                var i = payload.startIndex
                while i < payload.endIndex {
                    let (v, next) = try varint(payload, at: i)
                    dims.append(dimension(v))
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
        if let raw { floats = parseFloats(raw) }
        return Parse.Tensor(name: name, dims: dims, dataType: dataType, floats: floats)
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
