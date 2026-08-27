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
        .library(name: "DuckKit", targets: ["DuckKit"])
    ],
    targets: [
        .target(name: "DuckKit"),
        .testTarget(
            name: "DuckKitTests",
            dependencies: ["DuckKit"],
            // The vendored alpha_walking.onnx, the MuJoCo model, the extracted
            // chain, and onnxruntime's own outputs for eight observations. The
            // forward pass is proved against the real network, not a synthetic
            // one — only the real weights can show that this runs what the
            // robot runs.
            resources: [.copy("Fixtures")]
        )
    ]
)
