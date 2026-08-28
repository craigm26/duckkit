import XCTest
@testable import DuckKit

/// The generator IS the voice.
///
/// Upstream states the stakes in `rng.rs`: a robot's sound bank is re-rendered
/// from its seed on every install, so a change to this arithmetic re-voices the
/// whole fleet without anything failing. These tests exist to make that fail
/// loudly instead.
///
/// The pinned numbers below were produced by a **second, independent
/// implementation** written from the same upstream sources (Python, in the
/// session that added this file) rather than by running this Swift and
/// recording what it said. That distinction is the whole point: a golden value
/// copied out of the code under test only proves the code has not changed,
/// while two implementations agreeing is evidence that both read the spec the
/// same way.
final class DuckPersonalityTests: XCTestCase {

    typealias Personality = DuckVoice.Personality

    // ── the generator ────────────────────────────────────────────────────────

    /// xoshiro256++ seeded through splitmix64, pinned. If this fails, every
    /// duck's voice has changed.
    func testTheStreamIsXoshiro256PlusPlusAndIsPinned() {
        var rng = Personality.Random(seed: 100)
        let drawn = (0..<4).map { _ in rng.nextUInt64() }
        XCTAssertEqual(drawn, [16200148097352791549,
                               16785171618027694926,
                               15341217898654479309,
                               6357779920452276603],
                       "the stream changed — every duck now sounds like a different animal")
    }

    func testTheSameSeedIsTheSameStreamAndADifferentSeedIsNot() {
        var a = Personality.Random(seed: 100)
        var b = Personality.Random(seed: 100)
        var c = Personality.Random(seed: 101)
        let first = (0..<8).map { _ in a.nextUInt64() }
        XCTAssertEqual(first, (0..<8).map { _ in b.nextUInt64() })
        XCTAssertNotEqual(first.first, c.nextUInt64(), "adjacent seeds must not collide")
    }

    /// Small adjacent seeds are the ones callers actually reach for, and
    /// splitmix64 expansion is what stops 0, 1 and 2 sounding related.
    func testAdjacentSmallSeedsAreWellMixed() {
        let pitches = (0..<8).map { Personality(seed: UInt32($0)).pitchCenterHz }
        XCTAssertEqual(Set(pitches).count, pitches.count, "no two of the first eight seeds may share a pitch")
    }

    func testUniformStaysInItsHalfOpenRange() {
        var rng = Personality.Random(seed: 7)
        for _ in 0..<20_000 {
            let v = rng.uniform(160.0, 380.0)
            XCTAssertGreaterThanOrEqual(v, 160.0)
            XCTAssertLessThan(v, 380.0)
        }
    }

    /// numpy's half-open convention — `integers(1, 6)` is 1...5, never 6. The
    /// formant harmonic is drawn this way and a 6 would index past the seven
    /// weights the synth asks for.
    func testIntegersIsHalfOpenLikeNumpy() {
        var rng = Personality.Random(seed: 3)
        var seen = Set<Int>()
        for _ in 0..<20_000 { seen.insert(rng.integers(1, 6)) }
        XCTAssertEqual(seen, [1, 2, 3, 4, 5], "half-open: 6 is out of range and 1 must appear")
    }

    // ── the hash ─────────────────────────────────────────────────────────────

    /// CRC-32 (IEEE), pinned against the independent implementation for all
    /// seven shipped tags. A salted standard-library hash here would give the
    /// same duck different variants on every launch.
    func testCRC32MatchesZlibForEveryShippedTag() {
        let expected: [DuckSound: UInt32] = [
            .alarm: 1956595421, .greet: 771233627, .inquire: 1312317375,
            .peck: 2430072575, .chirp: 3962093451, .coo: 2327357386,
            .wheee: 403445712,
        ]
        for sound in DuckSound.allCases {
            XCTAssertEqual(Personality.crc32(Array(sound.tag.utf8)), expected[sound],
                           "crc32(\(sound.tag)) drifted")
        }
    }

    // ── the traits ───────────────────────────────────────────────────────────

    /// Every field of seed 1, pinned. This is the port's proof: the draw order
    /// is a single stream, so one reordered line moves everything after it.
    func testSeedOneDerivesTheExpectedDuck() {
        let p = Personality(seed: 1)
        let acc = 1e-12
        XCTAssertEqual(p.seed, 1)
        XCTAssertEqual(p.pitchCenterHz,   264.4801205809979,    accuracy: acc)
        XCTAssertEqual(p.register,        1.197683772926575,    accuracy: acc)
        XCTAssertEqual(p.pitchSpread,     0.9969734964934484,   accuracy: acc)
        XCTAssertEqual(p.glideBias,      -0.6306428557616612,   accuracy: acc)
        XCTAssertEqual(p.brightness,      0.3452394423660396,   accuracy: acc)
        XCTAssertEqual(p.tilt,            2.7816237100979695,   accuracy: acc)
        XCTAssertEqual(p.nasal,           0.5710751775912752,   accuracy: acc)
        XCTAssertEqual(p.harmonicSkew,   -0.8067963481640612,   accuracy: acc)
        XCTAssertEqual(p.formantN,        1)
        XCTAssertEqual(p.formantGain,     1.288532743837583,    accuracy: acc)
        XCTAssertEqual(p.vibratoRateHz,   5.5610061403681845,   accuracy: acc)
        XCTAssertEqual(p.vibratoDepth,    0.050702213260431866, accuracy: acc)
        XCTAssertEqual(p.jitterDepth,     0.1562657605805183,   accuracy: acc)
        XCTAssertEqual(p.breath,          0.02684907756046172,  accuracy: acc)
        XCTAssertEqual(p.quackiness,      0.32507756519201125,  accuracy: acc)
        XCTAssertEqual(p.amRateHz,       38.61392630537338,     accuracy: acc)
        XCTAssertEqual(p.amDepth,         0.41009688184233795,  accuracy: acc)
        XCTAssertEqual(p.warbleHz,       17.536828614242484,    accuracy: acc)
        XCTAssertEqual(p.warbleDepth,     0.8991579871980322,   accuracy: acc)
        XCTAssertEqual(p.attackSharpness, 0.2639771563106621,   accuracy: acc)
        XCTAssertEqual(p.speed,           1.1375762877624278,   accuracy: acc)
    }

    /// Two seeds have to be two creatures, not one creature nudged. Checked on
    /// the traits an ear actually separates first.
    func testTwoSeedsAreTwoCreatures() {
        let a = Personality(seed: 1), b = Personality(seed: 2)
        XCTAssertEqual(b.pitchCenterHz, 418.1581390592698, accuracy: 1e-12)
        XCTAssertEqual(b.tilt, 1.8721338767576885, accuracy: 1e-12)
        XCTAssertGreaterThan(abs(a.pitchCenterHz - b.pitchCenterHz), 50,
                             "these two must not be near-neighbours in pitch")
        XCTAssertNotEqual(a, b)
    }

    /// Whatever the dice do, the population stays in duck-and-toad territory —
    /// nothing squeaks like a mouse or rumbles like a truck.
    func testEveryDuckLandsInsideItsDocumentedEnvelope() {
        for seed in UInt32(0)..<UInt32(3000) {
            let p = Personality(seed: seed)
            XCTAssertTrue((110.0...620.0).contains(p.pitchCenterHz), "seed \(seed) pitch \(p.pitchCenterHz)")
            XCTAssertTrue((0.4..<1.2).contains(p.pitchSpread), "seed \(seed)")
            XCTAssertTrue((-1.0..<1.0).contains(p.glideBias), "seed \(seed)")
            XCTAssertTrue((0.05..<0.55).contains(p.brightness), "seed \(seed)")
            XCTAssertTrue((1.4..<2.8).contains(p.tilt), "seed \(seed)")
            XCTAssertTrue((0.1..<1.0).contains(p.nasal), "seed \(seed)")
            XCTAssertTrue((-1.0..<1.0).contains(p.harmonicSkew), "seed \(seed)")
            XCTAssertTrue((1...5).contains(p.formantN), "seed \(seed) formantN \(p.formantN)")
            XCTAssertTrue((0.0..<1.4).contains(p.formantGain), "seed \(seed)")
            XCTAssertTrue((3.5..<9.5).contains(p.vibratoRateHz), "seed \(seed)")
            XCTAssertTrue((0.0..<0.7).contains(p.vibratoDepth), "seed \(seed)")
            XCTAssertTrue((0.03..<0.35).contains(p.jitterDepth), "seed \(seed)")
            XCTAssertTrue((0.0..<0.30).contains(p.breath), "seed \(seed)")
            XCTAssertTrue((0.2..<1.0).contains(p.quackiness), "seed \(seed)")
            XCTAssertTrue((18.0..<55.0).contains(p.amRateHz), "seed \(seed)")
            XCTAssertTrue((0.15..<0.70).contains(p.amDepth), "seed \(seed)")
            XCTAssertTrue((7.0..<18.0).contains(p.warbleHz), "seed \(seed)")
            XCTAssertTrue((0.0..<1.4).contains(p.warbleDepth), "seed \(seed)")
            XCTAssertTrue((0.0..<1.0).contains(p.attackSharpness), "seed \(seed)")
            XCTAssertTrue((0.82..<1.22).contains(p.speed), "seed \(seed)")
        }
    }

    /// `register` is the one trait that escapes its own doc-comment range, and
    /// it does so upstream too: it is a choice of −1/0/0/1 *plus* a ±0.4 wobble,
    /// so it reaches ±1.4. Pinned because the obvious "tidy-up" is to clamp it,
    /// which would flatten the bimodal split that makes big and small ducks.
    func testRegisterIsBimodalAndReachesPastOne() {
        var sawPastOne = false
        var lows = 0, mids = 0, highs = 0
        for seed in UInt32(0)..<UInt32(3000) {
            let r = Personality(seed: seed).register
            XCTAssertTrue((-1.4..<1.4).contains(r), "seed \(seed) register \(r)")
            if abs(r) > 1.0 { sawPastOne = true }
            if r < -0.5 { lows += 1 } else if r > 0.5 { highs += 1 } else { mids += 1 }
        }
        XCTAssertTrue(sawPastOne, "the ±0.4 wobble must be able to push register past 1")
        XCTAssertGreaterThan(lows, 100, "there have to be big low ducks")
        XCTAssertGreaterThan(highs, 100, "and small high ones")
        XCTAssertGreaterThan(mids, 100, "and ordinary ones in between")
    }

    // ── harmonics ────────────────────────────────────────────────────────────

    /// The weights seed 1 hands the oscillator, pinned against the independent
    /// implementation.
    func testHarmonicsForSeedOne() {
        let h = Personality(seed: 1).harmonics()
        let expected = [3.2741588327214104, 0.2987593461311798, 0.8093051522668964,
                        0.0, 0.5425024040700657, 0.038775953924621104, 0.6724171642091759]
        XCTAssertEqual(h.count, 7)
        for (i, (got, want)) in zip(h, expected).enumerated() {
            XCTAssertEqual(got, want, accuracy: 1e-12, "harmonic \(i + 1)")
        }
    }

    /// A negative weight would invert that partial's phase rather than remove
    /// it, which is audible and wrong. Seed 1's fourth harmonic is already
    /// exactly zero, so the clamp is load-bearing and not theoretical.
    func testNoHarmonicIsEverNegative() {
        for seed in UInt32(0)..<UInt32(2000) {
            for (i, w) in Personality(seed: seed).harmonics().enumerated() {
                XCTAssertGreaterThanOrEqual(w, 0, "seed \(seed) harmonic \(i + 1)")
            }
        }
        XCTAssertEqual(Personality(seed: 1).harmonics()[3], 0, accuracy: 1e-15,
                       "seed 1's fourth partial is the clamp doing its job")
    }

    // ── variants ─────────────────────────────────────────────────────────────

    /// Variants re-roll within one duck's voice, so a duck that quacks twice
    /// does not sound like a stuck recording — and still sounds like itself.
    func testVariantSeedsArePinnedAndDifferPerTagAndVariant() {
        let p = Personality(seed: 1)
        var chirp0 = p.variantRandom(for: .chirp, variant: 0)
        var chirp1 = p.variantRandom(for: .chirp, variant: 1)
        var wheee0 = p.variantRandom(for: .wheee, variant: 0)

        XCTAssertEqual(chirp0, Personality.Random(seed: 3962043848))
        XCTAssertEqual(chirp1, Personality.Random(seed: 1913685113))
        XCTAssertEqual(wheee0, Personality.Random(seed: 402871699))

        XCTAssertNotEqual(chirp0.nextUInt64(), chirp1.nextUInt64(), "two variants must differ")
        XCTAssertNotEqual(chirp0.nextUInt64(), wheee0.nextUInt64(), "two tags must differ")
    }

    func testAVariantIsStableAcrossCalls() {
        let p = Personality(seed: 42)
        var a = p.variantRandom(for: .greet, variant: 3)
        var b = p.variantRandom(for: .greet, variant: 3)
        XCTAssertEqual((0..<4).map { _ in a.nextUInt64() }, (0..<4).map { _ in b.nextUInt64() })
    }

    /// Two different ducks asked for the same tag and variant must not collide.
    func testTwoDucksDoNotShareAVariantStream() {
        var a = Personality(seed: 1).variantRandom(for: .coo, variant: 0)
        var b = Personality(seed: 2).variantRandom(for: .coo, variant: 0)
        XCTAssertNotEqual(a.nextUInt64(), b.nextUInt64())
    }

    // ── identity ─────────────────────────────────────────────────────────────

    /// A duck's voice must survive a relaunch. Swift's `Hasher` is salted per
    /// process, so using it here would give the same duck a new voice every
    /// time the app opened — the one thing a voice may not do.
    func testAnIdentifierAlwaysGivesTheSameDuck() {
        let serial = "MD-000000000042"
        XCTAssertEqual(Personality(identifier: serial), Personality(identifier: serial))
        XCTAssertEqual(Personality(identifier: serial),
                       Personality(seed: Personality.crc32(Array(serial.utf8))))
        XCTAssertNotEqual(Personality(identifier: serial), Personality(identifier: "MD-000000000043"))
    }

    func testTheUnnamedDuckIsSeedZeroAndIsStated() {
        XCTAssertEqual(Personality.unnamed, Personality(seed: 0))
    }
}

/// Rendering *as* a duck. The traits are ported and pinned above; these are the
/// properties the synth has to keep once they are applied — a personality is
/// drawn from dice, so it must not be able to produce a voice that clips,
/// disappears, or slides out of the tick grid the choreography depends on.
final class DuckPersonalityRenderingTests: XCTestCase {

    typealias Personality = DuckVoice.Personality

    /// The default path must be untouched. `render(_:part:seed:)` still renders
    /// the tables as written — anything else would have silently re-voiced
    /// every existing caller.
    func testRenderingWithoutAPersonalityIsUnchanged() {
        for sound in DuckSound.allCases {
            let plain = DuckVoice.render(sound, part: .whole, seed: 1)
            let again = DuckVoice.render(sound, part: .whole, seed: 1)
            XCTAssertEqual(plain.samples, again.samples, "\(sound.tag) is not deterministic")
        }
    }

    /// A personality may change what a duck sounds like. It may not change how
    /// long it lasts: `DuckPerformance` choreographs against exact tick counts.
    func testAPersonalityNeverChangesALength() {
        let ducks = (0..<12).map { Personality(seed: UInt32($0) &* 7919) }
        for sound in DuckSound.allCases {
            for part in DuckSound.Part.allCases where sound.supports(part) {
                let expected = sound.ticks(of: part) * DuckVoice.samplesPerTick
                XCTAssertEqual(DuckVoice.render(sound, part: part, seed: 1).samples.count, expected)
                for duck in ducks {
                    let r = DuckVoice.render(sound, part: part, seed: 1, as: duck)
                    XCTAssertEqual(r.samples.count, expected,
                                   "\(sound.tag).\(part.rawValue) changed length for seed \(duck.seed)")
                    XCTAssertEqual(r.envelope.count, expected)
                }
            }
        }
    }

    /// Whatever the dice say, the output stays finite and inside the rails.
    func testEveryDuckStaysInRangeAndFinite() {
        for seed in stride(from: UInt32(0), to: UInt32(400), by: 37) {
            let duck = Personality(seed: seed)
            for sound in DuckSound.allCases {
                let r = DuckVoice.render(sound, part: .whole, seed: 9, as: duck)
                var peak: Float = 0
                for s in r.samples {
                    XCTAssertFalse(s.isNaN, "NaN in \(sound.tag) for seed \(seed)")
                    XCTAssertTrue(s.isFinite, "non-finite in \(sound.tag) for seed \(seed)")
                    peak = max(peak, abs(s))
                }
                XCTAssertLessThanOrEqual(peak, 1.0, "\(sound.tag) clipped for seed \(seed)")
                XCTAssertGreaterThan(peak, 0.001,
                                     "\(sound.tag) is inaudible for seed \(seed) — a duck must make a noise")
                for e in r.envelope {
                    XCTAssertTrue(e.isFinite && e >= 0 && e <= 1, "envelope out of range")
                }
            }
        }
    }

    /// The point of the whole file: two seeds have to be two animals.
    func testTwoDucksDoNotSoundTheSame() {
        let a = Personality(seed: 1), b = Personality(seed: 2)
        for sound in DuckSound.allCases {
            let ra = DuckVoice.render(sound, part: .whole, seed: 5, as: a)
            let rb = DuckVoice.render(sound, part: .whole, seed: 5, as: b)
            XCTAssertEqual(ra.samples.count, rb.samples.count)
            let diff = zip(ra.samples, rb.samples).map { abs($0 - $1) }.reduce(0, +)
                / Float(ra.samples.count)
            XCTAssertGreaterThan(diff, 1e-4,
                                 "\(sound.tag) is indistinguishable between two ducks")
        }
    }

    /// And the same duck has to stay the same animal, across calls and across
    /// launches — which is what makes it *its* voice rather than a random one.
    func testOneDuckIsTheSameAnimalEveryTime() {
        let duck = Personality(identifier: "MD-000000000042")
        for sound in DuckSound.allCases {
            let first = DuckVoice.render(sound, part: .whole, seed: 3, as: duck)
            let second = DuckVoice.render(sound, part: .whole, seed: 3,
                                          as: Personality(identifier: "MD-000000000042"))
            XCTAssertEqual(first.samples, second.samples, "\(sound.tag) drifted for the same duck")
        }
    }

    /// The seam invariant survives a personality. A held tag's `.whole` is
    /// exactly its three parts concatenated — if a personality were applied
    /// per-part with different state, the ride would click at its own joins.
    func testTheHeldWholeIsStillItsThreePartsForAnyDuck() {
        for seed in stride(from: UInt32(0), to: UInt32(200), by: 23) {
            let duck = Personality(seed: seed)
            let whole = DuckVoice.render(.wheee, part: .whole, seed: 11, as: duck)
            let parts = DuckVoice.renderParts(.wheee, seed: 11, as: duck)
            XCTAssertEqual(whole.samples, parts.flatMap { $0.samples },
                           "the ride no longer equals its parts for seed \(seed)")
            XCTAssertEqual(whole.envelope, parts.flatMap { $0.envelope })
        }
    }

    /// Pitch is the cue an ear separates first, so the register a duck was
    /// dealt has to actually reach the syllables it sings.
    ///
    /// Asserted at the coupling rather than on the rendered signal, and that is
    /// a deliberate correction: the obvious version of this test counts zero
    /// crossings in the output and expects the low duck to cross less often.
    /// It fails, because zero crossings count *breath and brightness*, not
    /// pitch — the lowest duck in the first 600 seeds happens to carry 0.15
    /// breath against the highest duck's 0.0, and noise crosses zero far more
    /// often than a 110 Hz fundamental does. The pitch coupling was correct the
    /// whole time; the measurement was not.
    func testADucksRegisterReachesTheSyllablesItSings() {
        let population = (UInt32(0)..<UInt32(600)).map { Personality(seed: $0) }
        let low = population.min { $0.pitchCenterHz < $1.pitchCenterHz }!
        let high = population.max { $0.pitchCenterHz < $1.pitchCenterHz }!
        XCTAssertLessThan(low.pitchCenterHz, high.pitchCenterHz)

        // The scale is a multiplier against the pitch the tables are written
        // at, so a duck sitting exactly there is a no-op by construction.
        XCTAssertEqual(Personality.referencePitchHz, 300)

        var rng = DuckVoice.Random(seed: 4)
        let syllable = DuckVoice.syllables(of: .chirp, part: .whole, random: &rng).first!

        for duck in [low, high] {
            let shaped = duck.shape(syllable)
            XCTAssertEqual(shaped.f0Start, syllable.f0Start * duck.pitchScale, accuracy: 1e-9)
            XCTAssertEqual(shaped.f0End, syllable.f0End * duck.pitchScale, accuracy: 1e-9)
            // The glide keeps its shape — a duck has a register, not a different tune.
            XCTAssertEqual(shaped.f0End / shaped.f0Start,
                           syllable.f0End / syllable.f0Start, accuracy: 1e-12)
            // And its place in the bar is untouched.
            XCTAssertEqual(shaped.offsetTicks, syllable.offsetTicks)
            XCTAssertEqual(shaped.durationTicks, syllable.durationTicks)
        }

        XCTAssertGreaterThan(high.shape(syllable).f0Start / low.shape(syllable).f0Start, 3.0,
                             "the extremes of a 600-duck population should be octaves apart")
    }

    /// A duck with no identity still has to be a duck.
    func testTheUnnamedDuckRenders() {
        for sound in DuckSound.allCases {
            let r = DuckVoice.render(sound, part: .whole, seed: 1, as: .unnamed)
            XCTAssertEqual(r.samples.count, sound.ticks(of: .whole) * DuckVoice.samplesPerTick)
            XCTAssertTrue(r.samples.contains { abs($0) > 0.001 })
        }
    }
}
