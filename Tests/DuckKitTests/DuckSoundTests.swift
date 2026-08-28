import XCTest
@testable import DuckKit

/// The vocabulary. Small enough to check by eye, which is exactly why it is
/// worth pinning: the seven tags are strings on the wire, a wrong one is a
/// silent no-op on the robot, and "silent no-op" is indistinguishable from a
/// broken speaker until somebody reads the daemon's source. These tests hold
/// the list, the one held tag, and the arithmetic of the hold protocol.
final class DuckSoundTests: XCTestCase {

    /// The tags robotd accepts, spelled out here so a rename has to happen
    /// twice — once in the enum and once in a test that says why.
    func testTheSevenTagsAreTheWireStrings() {
        XCTAssertEqual(DuckSound.allCases.map(\.tag),
                       ["alarm", "greet", "inquire", "peck", "chirp", "coo", "wheee"],
                       "these strings go on the wire; changing one is a protocol change")
        for sound in DuckSound.allCases {
            XCTAssertEqual(sound.tag, sound.rawValue, "the tag is the raw value, not a second table")
            XCTAssertEqual(DuckSound(rawValue: sound.tag), sound, "\(sound.tag) must round-trip")
        }
        XCTAssertNil(DuckSound(rawValue: "quack"),
                     "the obvious wrong guess must be refused rather than accepted as a duck noise")
        XCTAssertNil(DuckSound(rawValue: "wheeee"), "and so must the obvious typo")
    }

    /// One tag is a subscription and six are not. Everything about the hold
    /// path keys off this, so it is worth stating as a count rather than as
    /// six separate assertions nobody would notice going stale.
    func testExactlyOneTagIsHeldAndItIsWheee() {
        let held = DuckSound.allCases.filter(\.isHeld)
        XCTAssertEqual(held, [.wheee], "wheee is the only sound that has to be kept alive")

        for sound in DuckSound.allCases where !sound.isHeld {
            XCTAssertEqual(sound.parts, [.whole], "\(sound.tag) is sent whole, once")
            XCTAssertTrue(sound.supports(.whole))
            XCTAssertFalse(sound.supports(.loop), "\(sound.tag) has nothing to loop")
            XCTAssertFalse(sound.supports(.start))
            XCTAssertFalse(sound.supports(.end))
        }
        XCTAssertEqual(DuckSound.wheee.parts, [.start, .loop, .end],
                       "a held tag is sent as three parts, in play order")
        for part in DuckSound.Part.allCases {
            XCTAssertTrue(DuckSound.wheee.supports(part), "wheee supports every part, including .whole")
        }
    }

    /// Length does not predict the hold path, in either direction. `coo` is
    /// the longest one-shot and is still fire-and-forget; `wheee` is held and
    /// its *parts* are all shorter than `coo`. A client that reached for
    /// duration to decide whether to send holds would get both cases wrong —
    /// it would spend a second holding `coo` for nobody, and it would let a
    /// ride die because its start sounded brief.
    func testLengthDoesNotDecideWhetherASoundIsHeld() {
        let longestOneShot = DuckSound.allCases
            .filter { !$0.isHeld }
            .max { $0.nominalDuration < $1.nominalDuration }
        XCTAssertEqual(longestOneShot, DuckSound.coo, "coo is the longest one-shot")
        XCTAssertFalse(DuckSound.coo.isHeld, "and it is still not held")

        // The held tag's parts — the units actually sent — are every one of
        // them shorter than the longest thing sent whole.
        for part in [DuckSound.Part.start, .loop, .end] {
            XCTAssertLessThan(DuckSound.wheee.duration(of: part), DuckSound.coo.nominalDuration,
                              "wheee.\(part.rawValue) is shorter than coo, and is held anyway")
        }

        // `wheee.whole` outlasts `coo` only because it is one full ride —
        // start, one loop, end — and not because held sounds are long. It is
        // a floor on a length the client controls, which is the opposite of
        // a fixed duration a UI can budget against.
        XCTAssertGreaterThan(DuckSound.wheee.nominalDuration, DuckSound.coo.nominalDuration,
                             "the shortest complete ride still outlasts the longest one-shot")
    }

    /// Every length is a whole number of 50 Hz control ticks, so a
    /// performance timeline lands on a tick boundary and a rendered buffer is
    /// a whole number of samples. Nothing downstream ever has to round.
    func testEveryLengthIsAWholeNumberOfControlTicks() {
        for sound in DuckSound.allCases {
            for part in DuckSound.Part.allCases where sound.supports(part) {
                let ticks = sound.ticks(of: part)
                XCTAssertGreaterThan(ticks, 0, "\(sound.tag).\(part.rawValue) has to last")
                XCTAssertEqual(sound.duration(of: part), Double(ticks) / DuckModel.tickHz, accuracy: 1e-12,
                               "\(sound.tag).\(part.rawValue) seconds must be derived from its ticks")
            }
            XCTAssertEqual(sound.nominalDuration, sound.duration(of: .whole), accuracy: 1e-12)
        }
        XCTAssertEqual(DuckSound.peck.nominalDuration, 0.24, accuracy: 1e-12, "12 ticks")
        XCTAssertEqual(DuckSound.coo.nominalDuration, 1.00, accuracy: 1e-12, "50 ticks")
    }

    /// A held tag's `.whole` is one ride round: start, one loop, end. Held as
    /// arithmetic because both `DuckVoice` and `DuckPerformance` assemble
    /// `.whole` by concatenation and would otherwise be free to disagree
    /// about how long the result is.
    func testTheHeldWholeIsExactlyItsThreeParts() {
        let sum = DuckSound.wheee.parts.reduce(0) { $0 + DuckSound.wheee.ticks(of: $1) }
        XCTAssertEqual(DuckSound.wheee.ticks(of: .whole), sum,
                       "the shortest complete ride is start + one loop + end")
        XCTAssertEqual(DuckSound.wheee.nominalDuration, 1.10, accuracy: 1e-12, "12 + 25 + 18 = 55 ticks")
    }

    /// The hold cadence exists to survive packet loss, and the margin is the
    /// reason for the number: five holds fit in one deadman window, so four
    /// consecutive losses still keep the ride alive.
    func testTheHoldCadenceFitsFiveTimesInsideTheDeadman() {
        XCTAssertEqual(DuckSound.holdInterval, 0.1, accuracy: 1e-12)
        XCTAssertEqual(DuckSound.holdDeadline, 0.5, accuracy: 1e-12)
        XCTAssertEqual(DuckSound.holdsPerDeadline, 5, "0.5 / 0.1 — the packet-loss margin")
        XCTAssertEqual(Double(DuckSound.holdsPerDeadline) * DuckSound.holdInterval,
                       DuckSound.holdDeadline, accuracy: 1e-12,
                       "the margin has to be the two numbers it is derived from")
        XCTAssertLessThan(DuckSound.holdInterval, DuckSound.holdDeadline,
                          "a cadence slower than the deadman would end the ride it was keeping alive")
    }

    /// The shared decisions: what to say on the way down, and one distinct
    /// sentence per tag for whatever screen lists them.
    func testEverySoundCarriesItsOwnDescription() {
        XCTAssertEqual(DuckSound.goodbye, .peck, "the duck's goodbye, agreed once for every app")
        var seen = Set<String>()
        for sound in DuckSound.allCases {
            XCTAssertFalse(sound.character.isEmpty, "\(sound.tag) needs a sentence")
            XCTAssertTrue(seen.insert(sound.character).inserted,
                          "\(sound.tag) repeats another sound's description")
        }
    }
}
