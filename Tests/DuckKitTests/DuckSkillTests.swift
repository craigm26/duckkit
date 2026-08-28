import XCTest
@testable import DuckKit

/// The catalogue, and the prediction built on it.
///
/// TWO CLAIMS, AND THE SECOND ONE IS THE DANGEROUS ONE. The first is
/// bookkeeping: twelve names, five durations that are `DuckModel`'s rather
/// than a second copy of them, and which of the twelve take the whole robot
/// instead of a speaker. The second is that a button may say "busy" before the
/// round trip — and every test of that is really a test that it does NOT say
/// "busy" for the wrong reason. A companion app that greys out a control on a
/// state which never said anything is unfalsifiable from the outside: the
/// robot is fine, the app is certain it is not, and nothing in the UI can tell
/// them apart. So the refusals here are asserted in both directions, and there
/// are more assertions about what is *not* predicted than about what is.
final class DuckSkillTests: XCTestCase {

    private let stamp = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(policy: DuckPolicyKind? = nil, fallen: Bool? = nil, limp: Bool? = nil) -> DuckState {
        DuckState(
            policy: policy?.rawValue,
            safety: (fallen == nil && limp == nil) ? nil : DuckState.Safety(fallen: fallen, limp: limp),
            receivedAt: stamp)
    }

    // ── the catalogue ────────────────────────────────────────────────────

    func testTheCatalogueIsTheRuntimesOwnNames() {
        XCTAssertEqual(DuckSkill.allCases.map(\.tag),
                       ["ground_pick", "kick_left", "kick_right", "sit_toggle", "roulade"])
        XCTAssertEqual(DuckSkill(rawValue: "kick_left"), .kickLeft, "and they round-trip as written")
        XCTAssertEqual(DuckSound.allCases.map(\.tag),
                       ["alarm", "greet", "inquire", "peck", "chirp", "coo", "wheee"],
                       "the other seven are DuckSound's, and DuckPress.allCases is built on this order")
    }

    /// The five skills are exactly the five networks that are not locomotion.
    /// That is what makes `holding(_:)` possible at all: `robot.state` reports
    /// a policy, never a skill, so the policy is the only evidence there is
    /// that a move has the robot.
    func testTheFiveSkillsMapOntoTheFiveNonLocomotionPolicies() {
        let skillPolicies = Set(DuckSkill.allCases.map(\.policy))
        XCTAssertEqual(skillPolicies.count, 5, "no two skills share a network")
        XCTAssertEqual(skillPolicies.union([.walk, .stand]), Set(DuckPolicyKind.allCases),
                       "and the seven shipped policies are the five skills plus walking and standing")
        XCTAssertEqual(DuckSkill.sitToggle.policy, .sitStand)
        XCTAssertEqual(DuckSkill.kickLeft.policy.rawValue, "ball_kick_left")
    }

    /// The durations are `DuckModel`'s. A second copy of 0.5 is a copy that
    /// eventually disagrees with the network trained against it.
    func testTheDurationsAreDuckModelsAndNotASecondCopyOfThem() {
        XCTAssertEqual(DuckSkill.kickLeft.nominalDuration, DuckModel.kickDuration)
        XCTAssertEqual(DuckSkill.kickRight.nominalDuration, DuckModel.kickDuration)
        XCTAssertEqual(DuckSkill.roulade.nominalDuration, DuckModel.rouladeDuration)
        XCTAssertEqual(DuckSkill.groundPick.nominalDuration, DuckModel.groundPickPeriod)
        XCTAssertEqual(DuckModel.kickDuration, 0.5, accuracy: 1e-12, "half a second of kick")
        XCTAssertEqual(DuckModel.rouladeDuration, 1.0, accuracy: 1e-12, "one forward roll")
        XCTAssertEqual(DuckModel.groundPickPeriod, 4.0, accuracy: 1e-12, "one pick cycle")
    }

    /// The same windows in control ticks, at the loop's own 50 Hz.
    func testTheSameWindowsInControlTicks() {
        XCTAssertEqual(DuckSkill.kickLeft.nominalTicks, 25, "0.5 s × 50 Hz")
        XCTAssertEqual(DuckSkill.roulade.nominalTicks, 50)
        XCTAssertEqual(DuckSkill.groundPick.nominalTicks, 200)
    }

    /// Sit has no published window, and a guessed one would be a progress bar
    /// that lies: it is a move between two held poses, and the second lasts
    /// until somebody presses the button again.
    func testSitToggleHasNoPublishedDurationAndDoesNotInventOne() {
        XCTAssertNil(DuckSkill.sitToggle.nominalDuration)
        XCTAssertNil(DuckSkill.sitToggle.nominalTicks)
    }

    /// A skill takes the body; a sound takes a speaker. This is the whole
    /// reason the two live in one type.
    func testOnlySkillsHoldTheRobot() {
        for skill in DuckSkill.allCases {
            XCTAssertTrue(DuckPress.skill(skill).holdsTheRobot, "\(skill.tag) is exclusive")
        }
        for sound in DuckSound.allCases {
            XCTAssertFalse(DuckPress.sound(sound).holdsTheRobot, "\(sound.tag) is a speaker")
            XCTAssertNil(DuckPress.sound(sound).nominalHold,
                         "a sound holds nothing, however long it plays for")
        }
        XCTAssertEqual(DuckPress.skill(.kickLeft).nominalHold, DuckModel.kickDuration,
                       "a kick holds the robot for exactly as long as the kick lasts")
    }

    func testEveryPressAppearsInAllCasesExactlyOnceWithAUniqueTag() {
        let presses = DuckPress.allCases
        XCTAssertEqual(presses.count, 12, "five skills and seven sounds")
        XCTAssertEqual(Set(presses.map(\.tag)).count, 12, "and no two of them are the same button")
        XCTAssertEqual(presses.first, .skill(.groundPick), "skills first, in a fixed order")
        XCTAssertEqual(presses.last, .sound(.wheee))
    }

    // ── prediction: what is refused ──────────────────────────────────────

    /// A fallen duck cannot be asked to kick — and can still be asked to
    /// quack, which is the whole reason the sounds are exempt. Greying out the
    /// quack button because the duck is on its side would be lying about the
    /// robot at the moment its owner most wants to hear from it.
    func testAFallenDuckRefusesEverySkillAndStillQuacks() {
        let fallen = state(policy: .walk, fallen: true)
        for skill in DuckSkill.allCases {
            XCTAssertEqual(DuckPress.skill(skill).predictedRefusal(given: fallen), .fallen,
                           "\(skill.tag) on a duck that is down")
        }
        for sound in DuckSound.allCases {
            XCTAssertNil(DuckPress.sound(sound).predictedRefusal(given: fallen),
                         "\(sound.tag) is a speaker, and the speaker did not fall over")
        }
    }

    func testALimpDuckRefusesEverySkill() {
        let limp = state(policy: .stand, limp: true)
        XCTAssertEqual(DuckPress.skill(.roulade).predictedRefusal(given: limp), .limp,
                       "torque is off; nothing moves until it is on")
        XCTAssertNil(DuckPress.sound(.coo).predictedRefusal(given: limp))
    }

    /// An exclusive move already holding the robot, named — which is also
    /// what `robotd`'s own refusal does, and what lets a button say how long
    /// rather than merely "busy".
    func testAnExclusiveMoveNamesItselfAsTheHolderIncludingWhenItIsPressedTwice() {
        let kicking = state(policy: .kickLeft, fallen: false, limp: false)
        XCTAssertEqual(DuckPress.skill(.kickRight).predictedRefusal(given: kicking), .busy(.kickLeft))
        XCTAssertEqual(DuckPress.skill(.kickLeft).predictedRefusal(given: kicking), .busy(.kickLeft),
                       "pressing the move that is already holding the robot is refused like any other")
        if case .busy(let holder)? = DuckPress.skill(.roulade).predictedRefusal(given: kicking) {
            XCTAssertEqual(holder.nominalDuration, DuckModel.kickDuration,
                           "and the holder carries how long the wait is expected to be")
        } else {
            XCTFail("a kicking duck is busy")
        }

        let picking = state(policy: .groundPick, fallen: false)
        XCTAssertEqual(DuckPress.skill(.kickLeft).predictedRefusal(given: picking), .busy(.groundPick))
        XCTAssertNil(DuckPress.sound(.peck).predictedRefusal(given: picking),
                     "a sound is not competing for the body")
    }

    /// THE EXCEPTION, AND THE REASON FOR IT. `alpha_sitstand` is both the
    /// network that performs the toggle and, as far as a policy name can
    /// tell, the one that keeps a seated duck seated. Treating it as a hold
    /// would grey out the only button that gets a sitting duck back on its
    /// feet, for as long as it sits — a robot rendered unusable by its own
    /// remote control. The stated cost is that the other skills are not
    /// predicted busy during the toggle itself, and go to the robot to be
    /// refused there.
    func testSitToggleIsNeverTheHolderBecauseItsPolicyIsAlsoTheSeatedPose() {
        let seated = state(policy: .sitStand, fallen: false, limp: false)
        XCTAssertNil(DuckSkill.holding(seated), "sitting is a pose, not a move in progress")
        XCTAssertNil(DuckPress.skill(.sitToggle).predictedRefusal(given: seated),
                     "pressing sit again is how a seated duck stands up, and must never be blocked")
        XCTAssertNil(DuckPress.skill(.kickLeft).predictedRefusal(given: seated),
                     "the cost of the exception: one round trip, refused by the robot rather than here")
    }

    // ── prediction: what is NOT refused ──────────────────────────────────

    /// Silence predicts nothing. `DuckState` makes every field optional so a
    /// renamed `safety` cannot arrive as `fallen: false`; the same care runs
    /// the other way here, so a missing block cannot arrive as "busy".
    func testAStateThatDoesNotSayPredictsNothing() {
        XCTAssertNil(DuckPress.skill(.roulade).predictedRefusal(given: nil),
                     "no state at all — a fresh connection, or one already ruled stale")
        XCTAssertNil(DuckPress.skill(.roulade).predictedRefusal(given: state()),
                     "a state with no safety block and no policy")
        XCTAssertNil(DuckPress.skill(.roulade).predictedRefusal(given: state(policy: .walk)),
                     "a walking duck with nothing said about safety")
        XCTAssertNil(DuckPress.skill(.roulade).predictedRefusal(given: DuckState(
            policy: "alpha_swimming", safety: DuckState.Safety(fallen: false), receivedAt: stamp)),
                     "a policy this build has never heard of holds nothing it can name")
    }

    /// False is an answer, and the answer is yes.
    func testAStandingDuckThatSaysSoRefusesNothing() {
        let standing = state(policy: .stand, fallen: false, limp: false)
        for press in DuckPress.allCases {
            XCTAssertNil(press.predictedRefusal(given: standing), "\(press.tag) on a duck that is fine")
        }
        for press in DuckPress.allCases {
            XCTAssertNil(press.predictedRefusal(given: state(policy: .walk, fallen: false)),
                         "\(press.tag) on a duck that is walking")
        }
    }

    /// The order is the order of causes. A duck that is both on its side and
    /// mid-roulade is on its side, and reporting the roulade would send
    /// somebody to fix the wrong thing.
    func testTheOrderOfCausesIsFallenThenLimpThenBusy() {
        let everything = DuckState(
            policy: DuckPolicyKind.roulade.rawValue,
            safety: DuckState.Safety(fallen: true, limp: true),
            receivedAt: stamp)
        XCTAssertEqual(DuckPress.skill(.kickLeft).predictedRefusal(given: everything), .fallen)

        let limpAndBusy = DuckState(
            policy: DuckPolicyKind.roulade.rawValue,
            safety: DuckState.Safety(fallen: false, limp: true),
            receivedAt: stamp)
        XCTAssertEqual(DuckPress.skill(.kickLeft).predictedRefusal(given: limpAndBusy), .limp,
                       "torque being off explains the roulade going nowhere, not the other way round")
    }

    // ── reading a refusal back ───────────────────────────────────────────

    /// `robotd` refuses a second exclusive move by naming the one holding the
    /// robot, so the tag is usually in the prose. This reads it back for a
    /// label only — an error string is prose, not an API — and when two tags
    /// appear the earliest in the message wins, so the answer depends on the
    /// message rather than on the order these cases happen to be declared in.
    func testTheSkillNamedInARefusalIsReadBackForALabel() {
        XCTAssertEqual(DuckSkill.mentioned(in: "kick_left is holding the robot"), .kickLeft)
        XCTAssertEqual(DuckSkill.mentioned(in: "busy: ground_pick"), .groundPick)
        XCTAssertNil(DuckSkill.mentioned(in: "the robot is busy"), "no tag, no guess")
        XCTAssertEqual(DuckSkill.mentioned(in: "roulade refused while ground_pick runs"), .roulade,
                       "the first tag in the text, not the first case in the enumeration")
    }

    /// The vocabulary a refusal comes back in is the vocabulary a button
    /// predicted it in, so a UI never needs a translation table between the
    /// guess and the answer.
    func testAPredictedRefusalAndAReportedOneUseTheSameVocabulary() throws {
        var decoder = DuckRPC.StreamDecoder()
        let messages = decoder.append(Data((
            #"{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"kick_left is holding the robot"}}"#
            + "\n").utf8))
        let reported = DuckSkill.mentioned(in: try XCTUnwrap(messages.first?.failure?.message))
        let predicted = DuckPress.skill(.roulade)
            .predictedRefusal(given: state(policy: .kickLeft, fallen: false))
        XCTAssertEqual(predicted, .busy(try XCTUnwrap(reported)),
                       "the button's guess and the robot's answer are the same value")
    }
}
