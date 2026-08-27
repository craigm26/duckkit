import XCTest
@testable import DuckKit

/// The gait loop, driven by the real network. These tests assert the loop is
/// alive and bounded — that a command makes the legs move, that the duck
/// stays inside its own joint travel, and that it does not run away.
final class DuckSimulationTests: XCTestCase {

    private func simulation() throws -> DuckSimulation {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "alpha_walking", withExtension: "onnx", subdirectory: "Fixtures/duck"))
        return DuckSimulation(walk: try DuckPolicy.load(contentsOf: url))
    }

    func testAWalkCommandMovesTheLegs() throws {
        var sim = try simulation()
        let start = sim.currentJointAngles
        for _ in 0..<50 { _ = sim.step(command: DuckCommand(twist: (0.15, 0, 0))) }
        let moved = zip(sim.currentJointAngles, start).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(moved, 0.01, "a second of walking should move some joint appreciably")
    }

    /// Whatever the policy asks for, no joint may leave its travel — the ghost
    /// must not show a pose the hardware could never hold.
    func testEveryJointStaysInsideItsTravelForAThousandTicks() throws {
        var sim = try simulation()
        for tick in 0..<1000 {
            let command = DuckCommand(
                twist: (0.2 * sin(Double(tick) / 40), 0.05, 0.3 * cos(Double(tick) / 25)),
                head: (0.2, 0.2, sin(Double(tick) / 30), 0))
            let result = sim.step(command: command)
            for (joint, angle) in result.jointAngles.enumerated() {
                let travel = DuckModel.jointRanges[joint]
                XCTAssertGreaterThanOrEqual(angle, travel.lower - 1e-9,
                                            "\(DuckModel.jointNames[joint]) below travel at tick \(tick)")
                XCTAssertLessThanOrEqual(angle, travel.upper + 1e-9,
                                         "\(DuckModel.jointNames[joint]) above travel at tick \(tick)")
                XCTAssertTrue(angle.isFinite, "\(DuckModel.jointNames[joint]) went non-finite at tick \(tick)")
            }
        }
    }

    func testTheLoopSelectsStandingForAZeroCommand() throws {
        var sim = try simulation()
        XCTAssertEqual(sim.step(command: DuckCommand()).policy, .stand)
        XCTAssertEqual(sim.step(command: DuckCommand(twist: (0.5, 0, 0))).policy, .walk)
    }

    func testTheTickCounterAdvances() throws {
        var sim = try simulation()
        XCTAssertEqual(sim.step(command: DuckCommand()).tick, 1)
        XCTAssertEqual(sim.step(command: DuckCommand()).tick, 2)
    }

    /// The mouth belongs to the caller, and survives the policy's ticks.
    func testTheMouthIsSetByTheCallerAndPersists() throws {
        var sim = try simulation()
        sim.setMouth(open: 1.0)
        XCTAssertEqual(sim.currentJointAngles[DuckModel.mouthIndex], DuckModel.mouthOpen, accuracy: 1e-12)
        _ = sim.step(command: DuckCommand(twist: (0.2, 0, 0)))
        XCTAssertEqual(sim.currentJointAngles[DuckModel.mouthIndex], DuckModel.mouthOpen, accuracy: 1e-12)
    }

    /// The ghost's feet must stay near the floor: forward kinematics over the
    /// loop's own output is what an AR view will place, so a runaway pose
    /// shows up here rather than as a duck standing in the ceiling.
    func testTheGhostStaysOnTheFloorWhileWalking() throws {
        var sim = try simulation()
        for _ in 0..<300 {
            let tick = sim.step(command: DuckCommand(twist: (0.15, 0, 0)))
            let sites = DuckKinematics.sitePositions(jointAngles: tick.jointAngles)
            let lowest = min(sites["left_foot"]!.z, sites["right_foot"]!.z)
            XCTAssertLessThan(lowest, 0.10, "a foot should stay near the floor")
            XCTAssertGreaterThan(sites["head_camera"]!.z, 0.12, "the head should stay up")
        }
    }

    /// Fifty ticks is one second of duck. It must cost far less than a second
    /// of phone — this is what makes a 50 Hz AR ghost affordable.
    func testASecondOfDuckCostsFarLessThanASecond() throws {
        var sim = try simulation()
        let started = Date()
        for _ in 0..<50 { _ = sim.step(command: DuckCommand(twist: (0.15, 0, 0))) }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5, "50 ticks took \(elapsed)s on this machine")
    }
}
