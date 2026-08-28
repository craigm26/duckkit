import XCTest
@testable import DuckKit

/// The synthesizer, held to the four things a synthesized duck call has to be
/// able to promise: the same seed gives the same bytes, the seed actually
/// matters, the buffer is playable (in range, opening and closing on silence),
/// and the loop of a held sound can be butted against itself.
///
/// WHY THERE IS NO GOLDEN HASH IN HERE. The obvious test is to write down the
/// fingerprint of `render(.chirp, seed: 7)` and compare. It would be a lie:
/// the tone comes out of libm's `sin`, and glibc on this Pi and Darwin's
/// libm are entitled to differ in the last bit of a sample, so one of the two
/// platforms this package supports would go red for a reason that is not a
/// regression. What is pinned instead is the pair of properties a golden hash
/// was standing in for — render twice, get the same bytes; render with a
/// different seed, get different bytes — plus the *integer* part of the
/// determinism, `Random`, against SplitMix64's published outputs, which is
/// the same on every machine that has 64-bit arithmetic.
final class DuckVoiceTests: XCTestCase {

    /// An arbitrary but fixed seed. Rendering is the expensive thing this
    /// suite does (about four seconds of 48 kHz audio, twenty harmonics a
    /// sample), so the whole utterances are built once for the class rather
    /// than once per test method.
    private static let seed: UInt64 = 0xD0_0D_1234_5678

    private static let wholes: [DuckVoice.Rendering] =
        DuckSound.allCases.map { DuckVoice.render($0, part: .whole, seed: DuckVoiceTests.seed) }

    /// FNV-1a over the sample bit patterns. A hash the test owns, because
    /// `Hasher` is seeded per process and would compare unequal across two
    /// runs of the same binary.
    private func fingerprint(_ values: [Float]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for value in values {
            var bits = value.bitPattern
            for _ in 0..<4 {
                hash ^= UInt64(bits & 0xFF)
                hash = hash &* 0x0000_0100_0000_01B3
                bits >>= 8
            }
        }
        return hash
    }

    /// SplitMix64's published outputs from a zero seed. This is the part of
    /// the determinism that is genuinely portable — integer arithmetic, no
    /// libm — so it is the part that gets pinned to constants.
    func testTheGeneratorIsSplitMix64AndNotSomethingThatDrifted() {
        var random = DuckVoice.Random(seed: 0)
        XCTAssertEqual(random.next(), 0xE220_A839_7B1D_CDAF, "SplitMix64's first output from zero")
        XCTAssertEqual(random.next(), 0x6E78_9E6A_A1B9_65F4, "its second")
        XCTAssertEqual(random.next(), 0x06C4_5D18_8009_454F, "its third")

        var unit = DuckVoice.Random(seed: 99)
        for _ in 0..<1000 {
            let value = unit.nextUnit()
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1, "nextUnit is a half-open [0, 1)")
            let symmetric = unit.nextSymmetric()
            XCTAssertGreaterThanOrEqual(symmetric, -1)
            XCTAssertLessThan(symmetric, 1, "nextSymmetric is [−1, 1)")
        }
    }

    /// Same seed, same bytes; different seed, different bytes. The first half
    /// is what makes a rendered buffer cacheable and testable at all; the
    /// second is what says the seed is wired to something rather than being
    /// an ignored parameter that only looks like determinism.
    func testTheSameSeedRendersTheSameBufferAndADifferentSeedDoesNot() {
        for sound in DuckSound.allCases {
            let once = DuckVoice.render(sound, part: .whole, seed: 4242)
            let again = DuckVoice.render(sound, part: .whole, seed: 4242)
            XCTAssertEqual(fingerprint(once.samples), fingerprint(again.samples),
                           "\(sound.tag) rendered twice from one seed must be identical")
            XCTAssertEqual(once.samples, again.samples, "and identical sample for sample")
            XCTAssertEqual(once.envelope, again.envelope, "envelope included")

            let other = DuckVoice.render(sound, part: .whole, seed: 4243)
            XCTAssertNotEqual(fingerprint(once.samples), fingerprint(other.samples),
                              "\(sound.tag) must not ignore its seed — every voice carries breath")
        }
    }

    /// Lengths come from `DuckSound`'s tick counts and the 960 samples a tick
    /// holds at 48 kHz, so nothing is ever rounded and a buffer is never a
    /// sample short of the gesture it has to line up with.
    func testEveryBufferIsAWholeNumberOfControlTicks() {
        XCTAssertEqual(DuckVoice.samplesPerTick, 960, "48000 / 50")
        XCTAssertEqual(Double(DuckVoice.samplesPerTick) * DuckModel.tickHz, DuckVoice.sampleRate,
                       accuracy: 1e-9, "the two rates have to agree")

        for sound in DuckSound.allCases {
            for part in DuckSound.Part.allCases where sound.supports(part) {
                let rendering = DuckVoice.render(sound, part: part, seed: 1)
                XCTAssertEqual(rendering.samples.count,
                               sound.ticks(of: part) * DuckVoice.samplesPerTick,
                               "\(sound.tag).\(part.rawValue) is the wrong length")
                XCTAssertEqual(rendering.envelope.count, rendering.samples.count,
                               "the haptics track is parallel to the audio, not a summary of it")
                XCTAssertEqual(rendering.duration, sound.duration(of: part), accuracy: 1e-9)
                XCTAssertEqual(rendering.sampleRate, 48_000, accuracy: 1e-9)
            }
        }
    }

    /// Playable: nothing outside ±1, an envelope that is never negative and
    /// never above full scale, and a sound that begins and ends in silence.
    /// The last one is not an aesthetic preference — a buffer that starts
    /// mid-waveform clicks on every play, and a haptic track that starts at
    /// full intensity is a jolt.
    func testEveryUtteranceIsInRangeAndOpensAndClosesOnSilence() {
        for rendering in Self.wholes {
            let tag = rendering.sound.tag
            let loudest = rendering.samples.map { abs($0) }.max() ?? 0
            XCTAssertLessThanOrEqual(loudest, 1, "\(tag) clips")
            XCTAssertGreaterThan(loudest, 0.1, "\(tag) is silent — this is supposed to be a duck")

            let quietest = rendering.envelope.min() ?? -1
            XCTAssertGreaterThanOrEqual(quietest, 0, "\(tag) has a negative amplitude somewhere")
            XCTAssertLessThanOrEqual(rendering.envelope.max() ?? 0, 1, "\(tag) exceeds full scale")

            XCTAssertEqual(Double(rendering.envelope.first ?? 1), 0, accuracy: 1e-6,
                           "\(tag) must start from silence")
            XCTAssertEqual(Double(rendering.envelope.last ?? 1), 0, accuracy: 0.01,
                           "\(tag) must end in silence")
            XCTAssertEqual(Double(rendering.samples.first ?? 1), 0, accuracy: 1e-6,
                           "and the audio starts where the envelope does")
        }
    }

    /// A held sound's `.whole` is exactly its three parts laid end to end, so
    /// the preview button and the live hold path play the same audio rather
    /// than two takes that drifted apart.
    func testTheHeldWholeIsItsThreePartsConcatenated() {
        let parts = DuckVoice.renderParts(.wheee, seed: Self.seed)
        XCTAssertEqual(parts.map(\.part), [.start, .loop, .end], "in play order")

        let whole = DuckVoice.render(.wheee, part: .whole, seed: Self.seed)
        XCTAssertEqual(whole.samples, parts.flatMap { $0.samples },
                       "the ride assembled from its parts must be the ride")
        XCTAssertEqual(whole.envelope, parts.flatMap { $0.envelope })
        XCTAssertEqual(whole.samples.count,
                       DuckSound.wheee.ticks(of: .whole) * DuckVoice.samplesPerTick)
    }

    /// The loop has to be able to butt against itself: it neither opens from
    /// silence nor closes to it, its first and last amplitudes match, and the
    /// 8 Hz shimmer fits the 0.5 s loop a whole four times so it lands back
    /// where it started. A loop that faded at its edges would pulse audibly
    /// once every half second for as long as the ride lasted.
    func testTheRideLoopIsSeamlessAtItsOwnJoin() {
        let loop = DuckVoice.render(.wheee, part: .loop, seed: Self.seed)
        let first = Double(loop.envelope.first ?? 0)
        let last = Double(loop.envelope.last ?? 0)
        XCTAssertEqual(first, last, accuracy: 1e-4,
                       "the loop's amplitude must arrive back where it began")
        XCTAssertGreaterThan(first, 0.9, "and it must not have faded on the way — a loop is not a swell")

        let start = DuckVoice.render(.wheee, part: .start, seed: Self.seed)
        let end = DuckVoice.render(.wheee, part: .end, seed: Self.seed)
        XCTAssertEqual(Double(start.envelope.first ?? 1), 0, accuracy: 1e-6,
                       "the ride still opens from silence")
        XCTAssertEqual(Double(start.envelope.last ?? 0), first, accuracy: 1e-4,
                       "and hands over to the loop at the loop's own level")
        XCTAssertEqual(Double(end.envelope.first ?? 0), first, accuracy: 1e-4,
                       "the end picks up at that same level")
        XCTAssertEqual(Double(end.envelope.last ?? 1), 0, accuracy: 0.01,
                       "and only then goes to silence")
    }

    /// The seed decides more than hiss: half of `greet`'s renderings are a
    /// double wak-wak, which is a different *layout* — two syllables with a
    /// gap — not the same syllable with different noise under it. Sampled at
    /// 0.22 s, which falls inside the single quack and inside the double's
    /// gap, so the two layouts are told apart by whether anything is sounding
    /// there at all.
    func testGreetIsSometimesADoubleWakWakAndTheSeedDecides() {
        let probe = 11 * DuckVoice.samplesPerTick  // 0.22 s
        var singles = 0
        var doubles = 0
        for seed in UInt64(0)..<16 {
            let greet = DuckVoice.render(.greet, part: .whole, seed: seed)
            if greet.envelope[probe] == 0 { doubles += 1 } else { singles += 1 }
        }
        XCTAssertGreaterThan(singles, 0, "sixteen seeds produced no single quack at all")
        XCTAssertGreaterThan(doubles, 0, "sixteen seeds produced no wak-wak at all")
        XCTAssertEqual(singles + doubles, 16)
    }

    /// The pitch contour is the character, so it has to actually be in the
    /// buffer: `inquire` rises most of an octave and `chirp` falls. Measured
    /// by autocorrelation over a 20 ms window — a real, if crude, pitch
    /// detector, and deliberately an independent one: it reads the samples
    /// back rather than re-reading the table that produced them, so a
    /// contour that was written down but never reached the oscillator would
    /// show up here.
    func testTheContoursGoTheWayTheirCharacterSays() {
        let inquire = DuckVoice.render(.inquire, part: .whole, seed: Self.seed).samples
        let opening = pitch(of: inquire, at: 3 * DuckVoice.samplesPerTick)
        let closing = pitch(of: inquire, at: 20 * DuckVoice.samplesPerTick)
        XCTAssertGreaterThan(closing, opening * 1.3,
                             "inquire is the rising one: \(opening) Hz → \(closing) Hz")
        XCTAssertTrue((340.0...460.0).contains(opening), "inquire opens near 360 Hz, measured \(opening)")
        XCTAssertTrue((550.0...700.0).contains(closing), "and climbs towards 640 Hz, measured \(closing)")

        let chirp = DuckVoice.render(.chirp, part: .whole, seed: Self.seed).samples
        let quackOpen = pitch(of: chirp, at: 1 * DuckVoice.samplesPerTick)
        let quackClose = pitch(of: chirp, at: 7 * DuckVoice.samplesPerTick)
        XCTAssertLessThan(quackClose, quackOpen * 0.95,
                          "a quack falls: \(quackOpen) Hz → \(quackClose) Hz")
        XCTAssertTrue((490.0...600.0).contains(quackOpen), "chirp opens near 560 Hz, measured \(quackOpen)")
        XCTAssertTrue((420.0...530.0).contains(quackClose), "and lands near 430 Hz, measured \(quackClose)")
    }

    /// Fundamental frequency at a point in a buffer, by autocorrelation over
    /// a 20 ms window and lags covering 150–900 Hz. Takes the *first* lag
    /// within 15% of the best score rather than the best one, which is the
    /// standard guard against answering an octave too low: a harmonic signal
    /// correlates nearly as well against two of its own periods as against
    /// one.
    private func pitch(of samples: [Float], at offset: Int) -> Double {
        let window = 960
        let minLag = 53   // 48000 / 900 Hz
        let maxLag = 320  // 48000 / 150 Hz
        precondition(offset + window + maxLag <= samples.count, "window runs off the end of the buffer")
        var scores = [Double](repeating: 0, count: maxLag + 1)
        var best = 0.0
        for lag in minLag...maxLag {
            var sum = 0.0
            for i in 0..<window {
                sum += Double(samples[offset + i]) * Double(samples[offset + i + lag])
            }
            scores[lag] = sum
            best = max(best, sum)
        }
        guard best > 0 else { return 0 }
        for lag in minLag...maxLag where scores[lag] >= 0.85 * best {
            return DuckVoice.sampleRate / Double(lag)
        }
        return 0
    }
}
