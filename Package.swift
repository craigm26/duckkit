// swift-tools-version:5.9
import PackageDescription

// DuckKit — the Pollen Robotics Microduck, as pure Swift.
//
// ZERO DEPENDENCIES, ON PURPOSE. Everything here is Foundation and arithmetic:
// the joint tables, the 61-float observation contract, a hand-written ONNX
// reader, a multilayer perceptron, forward kinematics over the robot's own
// MuJoCo model, and a 50 Hz gait loop. Nothing needs a package, a framework, or
// a device — which is what lets `swift test` run the real trained policy on a
// Raspberry Pi and get the same floats an iPhone will.
//
// The numbers are not ours. Joint order, home pose, action scaling and the
// filter coefficients are ported from the robot's own runtime
// (github.com/pollen-robotics/microduck, Apache-2.0), where they were measured
// against hardware and trained into the policies. The kinematic chain is that
// repo's MuJoCo model, vendored as a test fixture so the tables here cannot
// drift from upstream without a test going red.
let package = Package(
    name: "DuckKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "DuckKit", targets: ["DuckKit"]),
        // Signing, canonical bytes and hash chains. A SEPARATE product on
        // purpose: an app that wants a walking duck should not link BoringSSL
        // to get one, and DuckKit's zero-dependency claim is the reason it
        // tests on a Pi. Take this one only if you have something to attest.
        .library(name: "DuckEvidence", targets: ["DuckEvidence"]),
        // The robot's actual shape, 2.4 MB of it. Its own product because most
        // things that need a duck do not need to DRAW one, and a soundboard
        // should not carry a hundred thousand triangles to make a noise.
        .library(name: "DuckVisual", targets: ["DuckVisual"]),
        // The duck as a RealityKit entity. Apple-only by nature, and therefore
        // entirely inside `#if canImport(RealityKit)` — on Linux it compiles to
        // an empty module so `swift test` on the Pi is unaffected. It exists
        // because OpenCastor and Duck Studio both need to draw the same robot,
        // and a copy per app is a fork per app.
        .library(name: "DuckRender", targets: ["DuckRender"]),
    ],
    dependencies: [
        // Ed25519 from swift-crypto, NOT CryptoKit: the same Curve25519.Signing
        // API, but one that compiles on Linux, so the signer under `swift test`
        // on the Pi is the signer on the phone. Used only by DuckEvidence.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "DuckKit",
            // Recorded walking, so a ghost duck has real motion to draw. Not a
            // dependency — a resource; DuckKit still links nothing.
            resources: [.copy("Resources/duck-trajectories.json"),
                        .copy("Resources/duck-intent-clips.json")]
        ),
        .target(
            name: "DuckVisual",
            dependencies: ["DuckKit"],
            resources: [.copy("Resources/duck-mesh.bin")]
        ),
        .target(
            name: "DuckRender",
            dependencies: ["DuckKit", "DuckVisual"]
        ),
        .target(
            name: "DuckEvidence",
            // DuckKit, and swift-crypto. The arrow points THIS WAY on purpose:
            // DuckEvidence attests things DuckKit describes — a policy's
            // parameters, a match, a room — so it has to see them, while DuckKit
            // must never see this target, because that is what keeps a
            // soundboard app from compiling BoringSSL to make a duck noise.
            // Taking DuckKit costs nothing third-party: it has no dependencies.
            dependencies: ["DuckKit", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "DuckKitTests",
            dependencies: ["DuckKit"],
            // The vendored alpha_walking.onnx, the MuJoCo model, the extracted
            // chain, and onnxruntime's own outputs for eight observations. The
            // forward pass is proved against the real network, not a synthetic
            // one — only the real weights can show that this runs what the
            // robot runs.
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "DuckEvidenceTests", dependencies: ["DuckEvidence", "DuckKit"]),
        .testTarget(name: "DuckVisualTests", dependencies: ["DuckVisual"]),
    ]
)
