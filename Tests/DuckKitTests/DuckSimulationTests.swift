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

    /// The loop stays inside the robot's own travel limits and stays finite,
    /// however long it runs.
    ///
    /// THIS TEST USED TO CLAIM SOMETHING IT COULD NOT. It was
    /// `testTheGhostStaysOnTheFloorWhileWalking`, and it asserted that a foot
    /// stayed near the floor and the head stayed up — i.e. that this loop
    /// produces a pose an AR view could place. It passed only because a
    /// separate bug pinned every joint velocity at exactly zero, which froze
    /// the loop a few degrees from the home pose. With the velocities live the
    /// policy drives joints onto their travel stops and a foot passes 0.109 m,
    /// so the old assertion fails — correctly. The loop was never producing a
    /// walk to stay grounded during; see `DuckSimulationClosedLoopTests`.
    ///
    /// What is genuinely worth guarding is what remains true: the output is
    /// bounded by the robot's own limits and never goes non-finite, so a
    /// caller gets a physically-expressible pose rather than a NaN or a joint
    /// wound past its stop.
    func testTheLoopStaysInsideTheRobotsTravelLimits() throws {
        var sim = try simulation()
        for tickIndex in 0..<300 {
            let tick = sim.step(command: DuckCommand(twist: (0.15, 0, 0)))
            for (j, angle) in tick.jointAngles.enumerated() {
                XCTAssertTrue(angle.isFinite, "\(DuckModel.jointNames[j]) went non-finite at tick \(tickIndex)")
                let range = DuckModel.jointRanges[j]
                XCTAssertGreaterThanOrEqual(angle, range.lower - 1e-9,
                    "\(DuckModel.jointNames[j]) below its stop at tick \(tickIndex)")
                XCTAssertLessThanOrEqual(angle, range.upper + 1e-9,
                    "\(DuckModel.jointNames[j]) above its stop at tick \(tickIndex)")
            }
            // Forward kinematics over that pose must still resolve.
            let sites = DuckKinematics.sitePositions(jointAngles: tick.jointAngles)
            XCTAssertTrue(sites["head_camera"]!.z.isFinite)
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

/// What the closed loop actually does, pinned.
///
/// `DuckSimulation`'s doc comment used to claim that closing this loop gave you
/// "the trained policy walking". It does not, and the failure was invisible
/// because nobody plotted it — the joint angles moved, so it looked alive.
/// These tests exist so the claim cannot come back without a red test, and so
/// the two distinct failure modes are on the record with numbers.
final class DuckSimulationClosedLoopTests: XCTestCase {

    private func walkPolicy() throws -> DuckPolicy {
        let url = Bundle.module.url(forResource: "Fixtures/duck/alpha_walking", withExtension: "onnx")!
        return try DuckPolicy.load(contentsOf: url)
    }

    /// The velocity block of the observation must not be structurally dead.
    ///
    /// It was: `previousTargets` and `jointPositions` were assigned the same
    /// array at the end of every tick, so differencing them gave exactly zero
    /// forever, and fourteen of the sixty-one observation floats carried no
    /// information at all. The policy could not distinguish a joint sweeping
    /// at 2 rad/s from one bolted in place.
    func testTheVelocityBlockIsNotStructurallyZero() throws {
        var sim = DuckSimulation(walk: try walkPolicy())
        let command = DuckCommand(twist: (0.15, 0, 0))
        for _ in 0..<50 { _ = sim.step(command: command) }

        let previous = try XCTUnwrap(sim.state.previousPositions,
                                     "the loop must remember where the joints were")
        XCTAssertNotEqual(previous, sim.state.jointPositions,
                          "previousPositions must lag jointPositions by a tick, or velocity is always zero")

        let velocities = (0..<DuckModel.jointCount).map {
            (sim.state.jointPositions[$0] - previous[$0]) / DuckSimulation.tickInterval
        }
        // The mouth is the one joint no policy drives, so it is legitimately still.
        let driven = velocities.enumerated().filter { $0.offset != DuckModel.mouthIndex }
        XCTAssertTrue(driven.contains { abs($0.element) > 1e-9 },
                      "every driven joint reported zero velocity — the feedback path is dead again")
    }

    /// The loop does not walk, and this is the test that says so out loud.
    ///
    /// A gait is roughly 1–2 Hz. What this loop produces is neither that nor
    /// anything near it, whatever you do to it — which is expected, because the
    /// gyro and projected-gravity blocks are constants here and a walking
    /// policy locks its phase to contact through exactly those channels.
    func testTheClosedLoopDoesNotProduceAGait() throws {
        var sim = DuckSimulation(walk: try walkPolicy())
        let command = DuckCommand(twist: (0.15, 0, 0))
        for _ in 0..<200 { _ = sim.step(command: command) }

        let ankle = DuckModel.jointNames.firstIndex(of: "left_ankle")!
        var trace: [Double] = []
        for _ in 0..<100 { trace.append(sim.step(command: command).jointAngles[ankle]) }

        var turningPoints = 0
        for i in 1..<(trace.count - 1) {
            let before: Double = trace[i] - trace[i - 1]
            let after: Double = trace[i + 1] - trace[i]
            if before * after < 0 { turningPoints += 1 }
        }
        // Two turning points per cycle; 100 ticks is two seconds.
        let hz = Double(turningPoints) / 2.0 / (Double(trace.count) / DuckModel.tickHz)

        XCTAssertGreaterThan(hz, 4.0, """
            The ankle is oscillating at \(hz) Hz. If this has dropped into the \
            1–2 Hz band, the loop may have started genuinely walking — which \
            would be excellent news and means this test, and DuckSimulation's \
            doc comment, both need rewriting rather than silencing.
            """)
    }

    /// The one honest use: run the real network on an observation somebody else
    /// measured. No contact needed, nothing fabricated, fully deterministic.
    func testInferenceOnASuppliedStateIsDeterministic() throws {
        let policy = try walkPolicy()
        let command = DuckCommand(twist: (0.1, 0, 0))
        var a = DuckSimulation(walk: policy)
        var b = DuckSimulation(walk: policy)
        for _ in 0..<20 {
            XCTAssertEqual(a.step(command: command).jointAngles,
                           b.step(command: command).jointAngles)
        }
    }
}
