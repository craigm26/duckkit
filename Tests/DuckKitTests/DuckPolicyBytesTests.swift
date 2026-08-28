import XCTest
@testable import DuckKit

/// The canonical parameter bytes are an identity contract: change the order or
/// the endianness and every fingerprint ever recorded stops matching, silently,
/// with no test failing anywhere else. So the order is pinned here by decoding
/// the bytes back rather than by comparing against a stored digest — a golden
/// hash copied out of the code under test only proves the code has not changed.
final class DuckPolicyBytesTests: XCTestCase {

    private func policy() throws -> DuckPolicy {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "alpha_walking", withExtension: "onnx", subdirectory: "Fixtures/duck"))
        return try DuckPolicy.load(contentsOf: url)
    }

    /// Every parameter, four bytes each, and nothing else in there.
    func testEveryParameterIsPresentAndNothingElseIs() throws {
        let p = try policy()
        let floats = p.parameterCount + p.normalization.mean.count + p.normalization.std.count
        XCTAssertEqual(floats, 197_896, "197,774 learned + 2 x 61 normalizer")
        XCTAssertEqual(p.canonicalParameterBytes.count, floats * 4,
                       "binary32 is four bytes; anything else means padding or a header crept in")
    }

    /// Same policy, same bytes. Obvious, and the whole thing rests on it.
    func testTheBytesAreDeterministic() throws {
        let p = try policy()
        XCTAssertEqual(p.canonicalParameterBytes, p.canonicalParameterBytes)
        XCTAssertEqual(try policy().canonicalParameterBytes, p.canonicalParameterBytes,
                       "a second load of the same file must serialize identically")
    }

    /// THE ORDER IS THE CONTRACT: mean, then std, then per layer weights then
    /// biases, outermost first. Decoded back out, so this fails if anyone
    /// reorders the serializer — which is the change that would otherwise be
    /// invisible until a year-old signed report stopped verifying.
    func testTheOrderIsMeanThenStdThenLayersOutermostFirst() throws {
        let p = try policy()
        let bytes = p.canonicalParameterBytes
        var cursor = 0
        func next(_ count: Int) -> [Float] {
            let slice = bytes[bytes.startIndex + cursor ..< bytes.startIndex + cursor + count * 4]
            cursor += count * 4
            return stride(from: 0, to: slice.count, by: 4).map { offset in
                let base = slice.startIndex + offset
                let word = UInt32(slice[base]) | UInt32(slice[base + 1]) << 8
                    | UInt32(slice[base + 2]) << 16 | UInt32(slice[base + 3]) << 24
                return Float(bitPattern: word)
            }
        }
        XCTAssertEqual(next(61), p.normalization.mean, "the mean comes first")
        XCTAssertEqual(next(61), p.normalization.std, "then the standard deviation")

        // Then each layer's weights and biases, in width order.
        for (index, width) in p.layerWidths.enumerated() {
            let weights = next(width.inputs * width.outputs)
            let biases = next(width.outputs)
            XCTAssertEqual(weights.count, width.inputs * width.outputs,
                           "layer \(index) weights are \(width.inputs)x\(width.outputs)")
            XCTAssertEqual(biases.count, width.outputs, "layer \(index) biases")
        }
        XCTAssertEqual(cursor, bytes.count, "the layers account for every remaining byte")
    }

    /// Little-endian, stated as bytes rather than trusted to the host. On the
    /// two platforms this ships to it happens to be the native order, which is
    /// exactly why an accidental `bigEndian` would never be noticed here.
    func testTheEncodingIsLittleEndianRegardlessOfHost() throws {
        let p = try policy()
        let first = p.normalization.mean[0]
        let bytes = p.canonicalParameterBytes
        let word = first.bitPattern
        XCTAssertEqual(bytes[bytes.startIndex + 0], UInt8(word & 0xff), "least significant byte first")
        XCTAssertEqual(bytes[bytes.startIndex + 3], UInt8((word >> 24) & 0xff))
    }
}

/// The forgery this reader used to accept.
///
/// An attribute whose value nothing read was an attribute anyone could set. A
/// 42-byte edit turning `Elu alpha=1` into `alpha=100` changes what every
/// negative activation computes, and it used to load AND fingerprint
/// identically to the genuine file — so a network with a different activation
/// function would have been reported as one of Pollen's releases.
final class DuckPolicyAttributeTests: XCTestCase {

    private func node(op: String, attributes: [DuckPolicy.Attribute]) -> String? {
        DuckPolicy.attributeProblem(op: op, attributes: attributes)
    }

    func testTheDefaultsTheRealPoliciesCarryAreAccepted() {
        XCTAssertNil(node(op: "Gemm", attributes: [
            .init(name: "alpha", float: 1.0, int: nil),
            .init(name: "beta", float: 1.0, int: nil),
            .init(name: "transB", float: nil, int: 1),
        ]), "every shipped policy carries exactly these")
        XCTAssertNil(node(op: "Elu", attributes: [.init(name: "alpha", float: 1.0, int: nil)]))
        XCTAssertNil(node(op: "Sub", attributes: []), "and some ops carry none at all")
    }

    /// The measured forgery.
    func testAnEluAlphaThatIsNotOneIsRefused() {
        let problem = node(op: "Elu", attributes: [.init(name: "alpha", float: 100, int: nil)])
        let text = try? XCTUnwrap(problem)
        XCTAssertNotNil(problem, "alpha=100 is a different activation function")
        XCTAssertTrue((text ?? "").contains("100"), "say what was found: \(problem ?? "nil")")
        XCTAssertTrue((text ?? "").contains("expected 1.0"), "and what was wanted")
    }

    func testAGemmScaleThatIsNotOneIsRefused() {
        XCTAssertNotNil(node(op: "Gemm", attributes: [.init(name: "alpha", float: 2, int: nil)]),
                        "alpha scales the product — 2 doubles every layer's output")
        XCTAssertNotNil(node(op: "Gemm", attributes: [.init(name: "beta", float: 0, int: nil)]),
                        "beta=0 drops the bias entirely")
    }

    /// An attribute nobody anticipated must be refused rather than ignored,
    /// because ignoring it is exactly how the alpha hole worked.
    func testAnUnrecognisedAttributeIsRefusedNotIgnored() {
        let problem = node(op: "Gemm", attributes: [.init(name: "transA", float: nil, int: 1)])
        XCTAssertNotNil(problem)
        XCTAssertTrue((problem ?? "").contains("transA"), problem ?? "nil")
    }

    func testTransBIsOnlyMeaningfulOnGemm() {
        XCTAssertNotNil(node(op: "Elu", attributes: [.init(name: "transB", float: nil, int: 1)]))
        XCTAssertNotNil(node(op: "Gemm", attributes: [.init(name: "transB", float: nil, int: 0)]),
                        "transB=0 means the weights are stored the other way round")
    }
}
