import XCTest
@testable import DuckKit

/// Folding a per-joint gain and trim into a policy, and the one test that
/// settles whether doing so is legitimate.
///
/// A ONE-STEP COMPARISON WOULD PROVE ALMOST NOTHING, which is why this file is
/// built around a two-hundred-tick closed loop instead. `folding` claims that
/// searching over a residual applied OUTSIDE a network and then shipping that
/// residual folded INTO the network are the same experiment. One forward pass
/// cannot distinguish those, because the interesting coupling is not in the
/// arithmetic of a single step — it is in the feedback: the raw policy output
/// occupies observation slots 34..47 on the very next tick
/// (`DuckObservation`'s previous-action block), so a residual changes what the
/// network SEES as well as what it emits, and a fold that were merely
/// approximately right would walk away from the thing it was tuned against
/// over a few seconds of ducking. Two hundred ticks is four seconds at 50 Hz —
/// longer than any of the bench's own six-second episodes spends before its
/// answer is decided.
///
/// THE PLANT HERE IS A SURROGATE AND IS NOT PRETENDING OTHERWISE. There is no
/// MuJoCo in this package and there never will be; what closes the loop below
/// is `DuckGait`'s real pipeline — the same scale, low-pass and travel clamp
/// robotd applies — driving a first-order servo lag, with the gyro and the
/// gravity vector derived from the resulting joint motion. It is not a duck.
/// It does not have to be: the claim under test is that TWO WAYS OF COMPUTING
/// THE SAME ACTION agree when fed back through an identical plant, and any
/// deterministic plant that exercises every observation block settles that.
/// Whether the tuned duck walks is a bench question and is answered on a
/// bench.
///
/// AND THIS LOOP IS CHAOTIC, WHICH CHANGED THE SHAPE OF THE TEST. The first
/// version asserted that two INDEPENDENT 200-tick runs — folded network on one
/// plant, residual-outside network on another — stayed within 1e-5 of each
/// other. They do not, and neither does anything else: running the same network
/// with the same residual spelled two mathematically identical ways separates
/// just as far. A float32 rounding difference of 1e-8 grows about tenfold every
/// twenty-five ticks here, so no correct implementation could pass that
/// assertion and passing it would have meant the loop was not closed. What is
/// asserted instead is stricter where it can be and honest where it cannot: the
/// fold is exact to 1e-5 at every one of two hundred states a closed run
/// actually visits, and two independent runs separate no faster than the
/// arithmetic alone separates them. `testTwoIndependentClosedLoops…` carries
/// the measurements.
final class DuckPolicyWriterFoldTests: XCTestCase {

    private func walking() throws -> DuckPolicy {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/duck/alpha_walking",
                                                  withExtension: "onnx"),
                                "fixture alpha_walking.onnx is missing")
        return try DuckPolicy.load(from: Data(contentsOf: url))
    }

    /// A gain and a trim with nothing round about them, so an off-by-one or a
    /// transposed row cannot cancel out. Fourteen wide, policy order, mouth
    /// excluded — this is the shape `folding` takes.
    private let gain: [Double] = (0..<DuckModel.policyJointCount).map { 0.82 + 0.031 * Double($0) }
    private let offset: [Double] = (0..<DuckModel.policyJointCount).map { (slot: Int) -> Double in
        let sign: Double = slot % 2 == 0 ? 1.0 : -1.0
        let size: Double = 0.004 + 0.0017 * Double(slot)
        return sign * size
    }

    // MARK: - the closed loop

    /// One deterministic plant, driven by whatever action it is handed.
    ///
    /// Both runs below hold one of these and they are stepped with identical
    /// inputs, so any divergence in the recorded trajectory came from the
    /// networks and from nowhere else.
    private struct Plant {
        var joints = DuckModel.homePose
        var velocities = [Double](repeating: 0, count: DuckModel.jointCount)
        var previousTargets: [Double]?
        var lastAction = [Float](repeating: 0, count: DuckModel.policyJointCount)

        /// Every observation block moves: the previous-action slots from the
        /// action itself, the joint blocks from the servo, the gyro from the
        /// head's motion and the gravity vector from how far the hips have
        /// leaned. A loop that only fed back slots 34..47 would leave the other
        /// forty-seven inputs frozen and prove less than it looks like.
        var observation: DuckObservation {
            let lean = 0.6 * (joints[2] - DuckModel.homePose[2])
            let gravity = [sin(lean), 0.15 * sin(2 * lean), -cos(lean)]
            let gyro = [0.1 * velocities[5], 0.1 * velocities[6], 0.1 * velocities[7]]
            return DuckObservation.build(
                gyro: gyro, gravity: gravity,
                jointPositions: joints, jointVelocities: velocities,
                lastAction: lastAction,
                command: DuckCommand(twist: (0.5, 0, 0)))
        }

        /// `action` is the value that reaches the runtime — post-residual on
        /// the base side, the folded network's own output on the other. The
        /// pipeline below is `DuckGait`'s, unmodified, at robotd's own scale
        /// and filter.
        mutating func step(applying action: [Float]) -> [Double] {
            let stages = DuckGait.stages(action: action, previousTargets: previousTargets,
                                         kind: .walk, alphas: .robotd)
            let targets = stages.clamped
            var next = joints
            for j in 0..<DuckModel.jointCount {
                next[j] = joints[j] + 0.35 * (targets[j] - joints[j])
            }
            for j in 0..<DuckModel.jointCount {
                velocities[j] = (next[j] - joints[j]) * DuckModel.tickHz
            }
            joints = next
            previousTargets = targets
            lastAction = action
            return targets
        }
    }

    private static let ticks = 200

    /// Run `policy` for 200 ticks, applying `residual` to its output before it
    /// reaches the plant and before it is fed back. `residual` is the identity
    /// for the folded network — the whole question is whether that changes the
    /// answer.
    private func trajectory(_ policy: DuckPolicy,
                            residual: ((_ action: [Float]) -> [Float])? = nil)
        -> (targets: [[Double]], actions: [[Float]]) {
        var plant = Plant()
        var targets: [[Double]] = [], actions: [[Float]] = []
        for _ in 0..<Self.ticks {
            var action = policy.infer(plant.observation)
            if let residual { action = residual(action) }
            actions.append(action)
            targets.append(plant.step(applying: action))
        }
        return (targets, actions)
    }

    /// THE TEST THE FOLD EXISTS TO PASS. Two hundred ticks of the folded
    /// network driving the plant with ITS OWN output in slots 34..47 — a
    /// genuine closed loop, not two hundred fresh starts — and at every one of
    /// those two hundred states the original network is evaluated as well, with
    /// the residual applied outside it. Agreement everywhere along a trajectory
    /// the folded network chose for itself is what makes a search over the
    /// residual-outside network a search over the folded one, which is the
    /// whole claim: what was measured is what ships.
    ///
    /// THE STATES ARE THE POINT. A one-step comparison from a hand-written
    /// observation proves the arithmetic and nothing about the feedback — the
    /// raw action lands in the previous-action block on the next tick, so a
    /// residual changes what the network SEES as well as what it emits, and the
    /// states four seconds into a tuned run are nowhere near the ones a fresh
    /// observation describes. These are those states.
    func testTheFoldIsExactAtEveryStateOfATwoHundredTickClosedRun() throws {
        let base = try walking()
        let folded = try DuckPolicyWriter.folding(policy: base, gain: gain, offset: offset)

        var plant = Plant()
        var worst = 0.0
        var lowest = DuckModel.homePose, highest = DuckModel.homePose
        for _ in 0..<Self.ticks {
            let observation = plant.observation
            let tuned = folded.infer(observation)
            let raw = base.infer(observation)
            for k in 0..<DuckModel.policyJointCount {
                let outside = gain[k] * Double(raw[k]) + offset[k]
                worst = max(worst, abs(Double(tuned[k]) - outside))
            }
            let targets = plant.step(applying: tuned)
            for j in 0..<DuckModel.jointCount {
                lowest[j] = min(lowest[j], targets[j])
                highest[j] = max(highest[j], targets[j])
            }
        }
        XCTAssertLessThan(worst, 1e-5,
                          "the fold and the outside residual disagreed somewhere in \(Self.ticks) ticks")
        // A frozen duck would pass the line above trivially.
        let span = (0..<DuckModel.jointCount).map { highest[$0] - lowest[$0] }.max() ?? 0
        XCTAssertGreaterThan(span, 0.05, "no joint moved 50 mrad in four seconds")
    }

    /// AND THAT CHECK CAN FAIL, which is the only reason to trust it passing:
    /// the same two hundred closed-loop states against a residual that differs
    /// by one part in a thousand on a single slot.
    func testTheClosedRunSeparatesResidualsThatDifferSlightly() throws {
        let base = try walking()
        let folded = try DuckPolicyWriter.folding(policy: base, gain: gain, offset: offset)
        var nudged = gain
        nudged[3] += 0.001

        var plant = Plant()
        var worst = 0.0
        for _ in 0..<Self.ticks {
            let observation = plant.observation
            let tuned = folded.infer(observation)
            let raw = base.infer(observation)
            for k in 0..<DuckModel.policyJointCount {
                worst = max(worst, abs(Double(tuned[k]) - (nudged[k] * Double(raw[k]) + offset[k])))
            }
            _ = plant.step(applying: tuned)
        }
        XCTAssertGreaterThan(worst, 1e-5, "a 0.1% gain change on one slot vanished")
    }

    /// WHAT TWO SEPARATE RUNS DO INSTEAD, AND WHY THE TEST ABOVE IS SHAPED THE
    /// WAY IT IS.
    ///
    /// Let the folded network drive one plant while the residual-outside
    /// network drives its own, and the two trajectories agree for four ticks
    /// and then walk away from each other — 2.5 rad apart by tick 200 on this
    /// toolchain. THAT IS NOT A FOLD ERROR. Running the SAME network with the
    /// SAME residual, spelled two mathematically identical ways —
    /// `Float(g)·a + Float(o)` against `Float(g·Double(a) + o)` — separates the
    /// same way: it holds to 1e-5 for twenty-one ticks and is 1.2 rad out by
    /// tick 200. A float32 rounding difference of 1e-8 grows by roughly a
    /// factor of ten every twenty-five ticks in this loop.
    ///
    /// So "two independent 200-tick trajectories agree to 1e-5" is not a claim
    /// ANY implementation of this fold can make, correct or otherwise; a test
    /// asserting it would be asserting that float32 addition is associative.
    /// The claims that survive are the one above — the fold is exact at every
    /// state a closed run visits — and the one here: the two runs separate no
    /// faster than the arithmetic alone separates them. The measured
    /// running-maximum ratio peaks at 56; the bound below is loose because the
    /// rounding is architecture-dependent and this package runs on a Pi, a Mac
    /// and a phone.
    ///
    /// It also says something about the bench, and it is what the bench already
    /// believes: one rollout settles nothing. `/measure` runs sixteen at
    /// randomised drop heights and reports a count, because physics has this
    /// property too — and a tuning result that rested on a single trajectory
    /// would be resting on the least reproducible number in the building.
    func testTwoIndependentClosedLoopsSeparateOnlyAsFastAsFloat32Rounding() throws {
        let base = try walking()
        let folded = try DuckPolicyWriter.folding(policy: base, gain: gain, offset: offset)

        let inside = trajectory(folded)
        let outside = trajectory(base) { action in
            (0..<action.count).map { Float(self.gain[$0]) * action[$0] + Float(self.offset[$0]) }
        }
        // The control: one network, one residual, two spellings of one sum.
        let spelledOneWay = trajectory(base) { action in
            (0..<action.count).map { Float(self.gain[$0]) * action[$0] + Float(self.offset[$0]) }
        }
        let spelledAnother = trajectory(base) { action in
            (0..<action.count).map { Float(self.gain[$0] * Double(action[$0]) + self.offset[$0]) }
        }

        func apart(_ a: [[Double]], _ b: [[Double]], _ t: Int) -> Double {
            (0..<DuckModel.jointCount).map { abs(a[t][$0] - b[t][$0]) }.max() ?? 0
        }

        var foldRunning = 0.0, controlRunning = 0.0, worstRatio = 0.0
        var foldHeldUntil = -1, controlHeldUntil = -1
        for t in 0..<Self.ticks {
            foldRunning = max(foldRunning, apart(inside.targets, outside.targets, t))
            controlRunning = max(controlRunning, apart(spelledOneWay.targets, spelledAnother.targets, t))
            if foldRunning < 1e-5 { foldHeldUntil = t }
            if controlRunning < 1e-5 { controlHeldUntil = t }
            if controlRunning > 0 { worstRatio = max(worstRatio, foldRunning / controlRunning) }
        }

        // The two runs do agree at first: the fold is not wrong at tick zero.
        XCTAssertGreaterThanOrEqual(foldHeldUntil, 3,
                                    "the fold and the outside residual disagreed immediately")
        // And the horizon belongs to float32, not to the fold — identical
        // arithmetic, reordered, loses 1e-5 inside the same 200 ticks.
        XCTAssertLessThan(controlHeldUntil, Self.ticks - 1,
                          "float32 rounding held under 1e-5 for the whole run, so the assertion "
                          + "this test exists to justify was achievable after all")
        XCTAssertLessThan(worstRatio, 1000,
                          "the fold separated far faster than rounding alone does")
    }

    // MARK: - the arithmetic, one step at a time

    /// The identity the fold is built on, checked directly: the folded
    /// network's output is the original's, times the gain, plus the offset —
    /// with no action scale anywhere in it.
    func testOneStepMatchesGainTimesActionPlusOffset() throws {
        let base = try walking()
        let folded = try DuckPolicyWriter.folding(policy: base, gain: gain, offset: offset)
        let observation = try XCTUnwrap(DuckObservation(exactly:
            (0..<DuckObservation.length).map { Float($0 % 11) * 0.09 - 0.5 }))

        let a = base.infer(observation)
        let b = folded.infer(observation)
        for k in 0..<DuckModel.policyJointCount {
            XCTAssertEqual(Double(b[k]), gain[k] * Double(a[k]) + offset[k], accuracy: 1e-5)
        }
    }

    /// An identity fold changes nothing — and it is worth asserting, because a
    /// fold that quietly scaled the wrong axis of a row-major matrix would
    /// still produce fourteen plausible numbers.
    func testAnIdentityFoldLeavesThePolicyAlone() throws {
        let base = try walking()
        let folded = try DuckPolicyWriter.folding(
            policy: base,
            gain: [Double](repeating: 1, count: DuckModel.policyJointCount),
            offset: [Double](repeating: 0, count: DuckModel.policyJointCount))
        XCTAssertEqual(folded.infer(.zeroed), base.infer(.zeroed))
        XCTAssertEqual(folded.canonicalParameterBytes, base.canonicalParameterBytes)
    }

    /// Only the last layer moves. Every other weight in the file is the one it
    /// came in with, because a fold anywhere else would be sitting behind an
    /// ELU and would not be this arithmetic at all.
    func testOnlyTheLastLayerChanges() throws {
        let base = try walking()
        let folded = try DuckPolicyWriter.folding(policy: base, gain: gain, offset: offset)
        XCTAssertEqual(folded.parameters.mean, base.parameters.mean)
        XCTAssertEqual(folded.parameters.std, base.parameters.std)
        XCTAssertEqual(folded.parameters.layers.count, base.parameters.layers.count)
        for i in 0..<(base.parameters.layers.count - 1) {
            XCTAssertEqual(folded.parameters.layers[i].weights, base.parameters.layers[i].weights, "layer \(i)")
            XCTAssertEqual(folded.parameters.layers[i].biases, base.parameters.layers[i].biases, "layer \(i)")
        }
        XCTAssertEqual(folded.parameterCount, base.parameterCount)
        XCTAssertEqual(folded.layerWidths.map { [$0.inputs, $0.outputs] },
                       base.layerWidths.map { [$0.inputs, $0.outputs] })
    }

    // MARK: - action_scale stays a robotd key

    /// `action_scale` IS NOT FOLDED AND MUST NOT BE. The runtime multiplies
    /// this network's output by its own scale on the way to a joint target; a
    /// fold that absorbed the scale would have the file and the config both
    /// claiming it, and the robot would apply the product.
    ///
    /// Two things are asserted. First that the scale is still live after a fold
    /// — the same folded action run through `DuckGait` at 0.9 and at 1.0 gives
    /// different targets. Second, and more precisely, that the runtime scale
    /// multiplies ON TOP of the gain rather than instead of it: targets come
    /// out at `home + scale × (gain ⊙ a + offset)`.
    func testTheActionScaleIsNotFoldedAndStaysLive() throws {
        let base = try walking()
        let folded = try DuckPolicyWriter.folding(policy: base, gain: gain, offset: offset)
        let observation = try XCTUnwrap(DuckObservation(exactly:
            (0..<DuckObservation.length).map { Float($0 % 5) * 0.21 - 0.3 }))

        let raw = base.infer(observation)
        let tuned = folded.infer(observation)

        let atNine = DuckGait.stages(action: tuned, previousTargets: nil, scale: 0.9).scaled
        let atOne = DuckGait.stages(action: tuned, previousTargets: nil, scale: 1.0).scaled
        var moved = false
        for j in 0..<DuckModel.jointCount where j != DuckModel.mouthIndex {
            if abs(atNine[j] - atOne[j]) > 1e-9 { moved = true }
        }
        XCTAssertTrue(moved, "the action scale stopped mattering after a fold — it was absorbed")

        for scale in [0.9, 1.0] {
            let stages = DuckGait.stages(action: tuned, previousTargets: nil, scale: scale).scaled
            for slot in 0..<DuckModel.policyJointCount {
                let joint = DuckModel.jointOfPolicySlot(slot)
                let want = DuckModel.homePose[joint]
                         + scale * (gain[slot] * Double(raw[slot]) + offset[slot])
                XCTAssertEqual(stages[joint], want, accuracy: 1e-5,
                               "slot \(slot) at scale \(scale)")
            }
        }
    }

    // MARK: - the file

    /// A folded policy is a FILE, not a struct: written by this package's
    /// writer and read back by its loader, giving the same actions bit for bit.
    /// `folding` already goes out and back once; this proves the second trip is
    /// stable too, which is what a bench that uploads the bytes depends on.
    func testAFoldedPolicyRoundTripsThroughTheWriter() throws {
        let folded = try DuckPolicyWriter.folding(policy: try walking(), gain: gain, offset: offset)
        let again = try DuckPolicy.load(from: folded.encoded())
        let observation = try XCTUnwrap(DuckObservation(exactly:
            (0..<DuckObservation.length).map { Float($0 % 7) * 0.13 - 0.4 }))
        XCTAssertEqual(again.infer(observation), folded.infer(observation))
        XCTAssertEqual(again.canonicalParameterBytes, folded.canonicalParameterBytes)
    }

    // MARK: - refusals

    /// FIFTEEN IS THE TRAP. The robot has fifteen joints, the policy has
    /// fourteen outputs, and a 15-wide array handed over as if it were 14-wide
    /// would shift every joint past the mouth by one — the exact silent
    /// off-by-one `DuckModel.jointOfPolicySlot` exists to prevent. It is
    /// refused, with the fix named.
    func testAFifteenWideGainIsRefused() throws {
        let base = try walking()
        XCTAssertThrowsError(try DuckPolicyWriter.folding(
            policy: base,
            gain: [Double](repeating: 1, count: DuckModel.jointCount),
            offset: [Double](repeating: 0, count: DuckModel.policyJointCount))) { error in
            let message = (error as? DuckPolicyWriter.WriteError)?.message ?? ""
            XCTAssertTrue(message.contains("15 wide"), message)
            XCTAssertTrue(message.contains("mouth"), message)
        }
        XCTAssertThrowsError(try DuckPolicyWriter.folding(
            policy: base,
            gain: [Double](repeating: 1, count: DuckModel.policyJointCount),
            offset: [Double](repeating: 0, count: DuckModel.jointCount)))
    }

    /// A NaN in the search's own state is how a whole tuning run turns into a
    /// file full of holes. It is refused here, while nothing is moving.
    func testANonFiniteGainIsRefused() throws {
        let base = try walking()
        var bad = [Double](repeating: 1, count: DuckModel.policyJointCount)
        bad[4] = .nan
        XCTAssertThrowsError(try DuckPolicyWriter.folding(
            policy: base, gain: bad,
            offset: [Double](repeating: 0, count: DuckModel.policyJointCount)))
    }
}
