import XCTest
@testable import DuckKit

/// The loop's state, injected. The observation feeds the previous action and
/// last tick's targets back into the network every 20 ms, so this loop is a
/// dynamical system and not a function: what it does next depends on where it
/// has been. These tests hold the two halves of that claim — the same state
/// gives the same future, exactly, and a nudge in one slot gives a different
/// one — because that pair is what makes an A/B between two checkpoints mean
/// anything. Without it, a difference measured after twenty ticks of warm-up
/// is as much the warm-up as the network.
final class DuckSimulationStateTests: XCTestCase {

    private func simulation(state: DuckSimulation.State = DuckSimulation.State()) throws -> DuckSimulation {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "alpha_walking", withExtension: "onnx", subdirectory: "Fixtures/duck"))
        return DuckSimulation(walk: try DuckPolicy.load(contentsOf: url), state: state)
    }

    /// A steady forward walk. Well above the 0.05 standing threshold, so one
    /// network runs throughout, and gentle enough that no joint sits on a
    /// stop — a clamp would flatten two trajectories together and hide the
    /// very divergence these tests are measuring.
    private let walking = DuckCommand(twist: (0.15, 0, 0))

    /// Twenty ticks of walking: a mid-stride condition with a real history
    /// behind it, which is the interesting thing to inject and the thing a
    /// caller would otherwise have to spend 400 ms of loop to reach.
    private func midStride() throws -> DuckSimulation.State {
        var sim = try simulation()
        for _ in 0..<20 { _ = sim.step(command: walking) }
        return sim.state
    }

    func testAFreshLoopStartsAtHomeWithNothingRemembered() throws {
        let fresh = DuckSimulation.State()
        XCTAssertEqual(fresh.jointPositions, DuckModel.homePose, "a new loop stands at the home pose")
        XCTAssertNil(fresh.previousTargets, "there is no previous tick for the filter to lag behind")
        XCTAssertEqual(fresh.lastAction, [Float](repeating: 0, count: DuckModel.policyJointCount),
                       "nothing has been fed back yet")
        XCTAssertEqual(fresh.tickCount, 0, "and no time has passed")

        var sim = try simulation()
        XCTAssertEqual(sim.state, fresh, "the default state is what a loop built without one starts in")
        let tick = sim.step(command: walking)
        XCTAssertEqual(sim.state.tickCount, tick.tick, "the visible tick count is the reported one")
        XCTAssertEqual(sim.state.jointPositions, tick.jointAngles,
                       "and the visible joints are the ones just drawn")
        XCTAssertEqual(sim.state.jointPositions, sim.currentJointAngles,
                       "currentJointAngles is a view of the same state, not a second copy")
    }

    /// The A/B floor: identical state in, identical trajectory out, to the
    /// bit, for a hundred ticks. Any divergence in a checkpoint comparison
    /// has to come from the networks, and this is what says so.
    func testTwoLoopsFromAnIdenticalInjectedStateStayBitIdentical() throws {
        let start = try midStride()
        var left = try simulation(state: start)
        var right = try simulation(state: start)
        for tick in 0..<100 {
            let a = left.step(command: walking)
            let b = right.step(command: walking)
            XCTAssertEqual(a.jointAngles, b.jointAngles,
                           "two loops from one state parted at tick \(tick) with nothing to part over")
            XCTAssertEqual(a.tick, b.tick, "the injected tick count advances the same way in both")
            XCTAssertEqual(a.policy, b.policy, "and both pick the same network")
        }
        XCTAssertEqual(left.state, right.state, "including everything they carry forward")
        XCTAssertEqual(left.state.tickCount, start.tickCount + 100, "counting resumed from the injected state")
    }

    /// Nudge one slot and the futures separate. `jointPositions[2]` is
    /// left_hip_pitch; 0.05 rad is under three degrees, and it lands in the
    /// observation twice — as a joint position and, because the previous
    /// targets are left alone, as a velocity the loop differences out of it.
    ///
    /// The claim is made over the first ten ticks because that is where it is
    /// loudest: under one steady command the two runs are pulled back towards
    /// the same gait, so the gap shrinks with every tick and a hundred ticks
    /// later it is float noise. That is a real property of the system, not a
    /// weakness of the test — but it does mean "they diverge" is a statement
    /// about the ticks right after the nudge.
    func testNudgingOneStateSlotSendsTheTwoLoopsApart() throws {
        let start = try midStride()
        var nudged = start
        nudged.jointPositions[2] += 0.05

        var reference = try simulation(state: start)
        var perturbed = try simulation(state: nudged)
        var smallestGap = Double.infinity
        for _ in 0..<10 {
            let a = reference.step(command: walking)
            let b = perturbed.step(command: walking)
            let gap = zip(a.jointAngles, b.jointAngles).map { abs($0 - $1) }.max() ?? 0
            smallestGap = min(smallestGap, gap)
        }
        XCTAssertGreaterThan(smallestGap, 1e-3,
                             "a 0.05 rad nudge to one joint must keep the two ducks more than a "
                             + "milliradian apart for the ten ticks after it; smallest gap was \(smallestGap)")
    }

    /// Writable, not just readable: the point of exposing the state is being
    /// able to pin a slot in the middle of a run. Zeroing the fed-back action
    /// is the sharpest version — it is a lie about the previous tick that only
    /// the feedback path can carry, so a different next tick proves the loop
    /// really does read its own output back in.
    func testPinningTheFedBackActionMidLoopChangesWhatHappensNext() throws {
        let start = try midStride()
        XCTAssertGreaterThan(start.lastAction.map { abs($0) }.max() ?? 0, 1e-3,
                             "mid-stride the fed-back action is not already zero, or this proves nothing")

        var free = try simulation(state: start)
        var pinned = try simulation(state: start)
        pinned.state.lastAction = [Float](repeating: 0, count: DuckModel.policyJointCount)

        let a = free.step(command: walking)
        let b = pinned.step(command: walking)
        XCTAssertNotEqual(a.jointAngles, b.jointAngles,
                          "observation slots 34…48 are the previous action: erasing them must change the tick")

        pinned.state.tickCount = 1000
        XCTAssertEqual(pinned.step(command: walking).tick, 1001,
                       "the tick counter is the caller's too — a resumed loop keeps counting")
    }

    /// The mouth lives in the same state as everything else, so a caller who
    /// installs a state installs the beak with it.
    func testAnInjectedStateCarriesTheMouthAsWell() throws {
        var open = DuckSimulation.State()
        open.jointPositions[DuckModel.mouthIndex] = DuckModel.mouthOpen
        var sim = try simulation(state: open)
        XCTAssertEqual(sim.currentJointAngles[DuckModel.mouthIndex], DuckModel.mouthOpen, accuracy: 1e-12,
                       "the injected beak is where the loop starts")
        _ = sim.step(command: walking)
        XCTAssertEqual(sim.state.jointPositions[DuckModel.mouthIndex], DuckModel.mouthOpen, accuracy: 1e-12,
                       "and no policy takes it back — the mouth is in no policy's action")
    }
}
