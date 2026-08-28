import Foundation

/// Duck calls, synthesized from arithmetic.
///
/// POLLEN'S VOICE BANK LIVES ON THE ROBOT. It is not in this repo, it is not
/// in the policies, and it does not ship with the SDK — so an app that wants
/// to make duck noises before the hardware arrives has exactly two options:
/// record something, or compute something. This file computes something. It
/// turns a `DuckSound` into a mono `[Float]` at 48 kHz with no AVFoundation,
/// no asset, no license question and no download, which also means it runs
/// under `swift test` on a Pi like everything else here.
///
/// WHAT THIS IS: a procedural duck call — a buzzy nasal honk built from an
/// oscillator stack, a resonance and a couple of envelopes. WHAT IT IS NOT: a
/// reproduction of the real duck. Nobody involved has heard the real bank, so
/// this cannot be a copy of it and is not claimed to be one; it is a
/// placeholder with the right *shape*, and when the hardware lands the honest
/// move is to compare the two and change the numbers here, or throw the file
/// away and play the robot's own.
///
/// HOW A DUCK CALL IS BUILT, and what each parameter is doing. A quack is not
/// a tone, it is a reed: a low fundamental — 300 Hz for the `peck` tock up to
/// 700 Hz for the top of the `wheee` ride — with a great many harmonics, the
/// odd ones louder than the even (`evenLevel` below 1 is what makes it read as
/// nasal and pinched rather than round), the whole stack tilted down by
/// `1/nᵈ` (`rolloff`) and then pushed through one broad resonance around
/// 1–2 kHz (`formant`, `bandwidth`) that stands in for the bird's throat. The
/// character is in the *contour*: a quack falls (`chirp`, 560 → 430 Hz), a
/// question rises (`inquire`, 360 → 640), a coo barely moves and wobbles
/// instead (a 5 Hz tremolo). On top of that goes a fast attack — four
/// milliseconds for the alarm, because a honk that fades in is a goose — and
/// a little filtered noise for breath.
///
/// DETERMINISTIC, FROM AN EXPLICIT SEED. The randomness here is real (breath
/// noise, and whether a `greet` comes out as a single quack or a double
/// wak-wak) but it comes out of `Random`, a SplitMix64 carried in this file,
/// never out of `Double.random`. Same seed, same bytes — so a buffer can be
/// hashed, and a test can pin it. The one caveat worth stating: the tone is
/// `sin` from libm, so two *different platforms* can differ in the last bit
/// of a sample. Determinism here means "the same machine gives the same
/// answer forever", which is what a regression test needs and is why
/// `DuckVoiceTests` pins render-against-render rather than a golden constant
/// that would be a lie on one of the two OSes this package supports.
public enum DuckVoice {

    /// 48 kHz, mono. High enough that the tenth harmonic of a 700 Hz call is
    /// nowhere near Nyquist, and the rate every phone audio session runs at
    /// anyway, so nothing has to resample.
    public static let sampleRate: Double = 48_000

    /// 48000 / 50 = 960 samples in one control tick. Every `DuckSound` part
    /// is a whole number of ticks, so every buffer is a whole number of these
    /// and no length in this file is ever rounded.
    public static let samplesPerTick = Int(sampleRate / DuckModel.tickHz)

    /// How many harmonics the oscillator stack carries. Twenty: at the lowest
    /// fundamental here (the 210 Hz tail of `peck`) that reaches 4.2 kHz, and
    /// at the highest (700 Hz) the ones past Nyquist are dropped per sample
    /// rather than folded back as aliasing. The formant sits at 1–2 kHz, so
    /// the harmonics that actually carry the timbre are the first ten or so;
    /// the rest are the buzz.
    public static let harmonicLimit = 20

    // ── what comes out ───────────────────────────────────────────────────

    /// One rendered part: the audio, and the amplitude envelope that produced
    /// it, sample for sample.
    ///
    /// The envelope is not a debugging aid. It is the haptics track: Core
    /// Haptics wants an intensity curve on 0…1 and the honest one is the
    /// curve the synthesizer already used, so a duck noise and the buzz in
    /// your hand are the same gesture rather than two things somebody tried
    /// to line up by eye. It excludes the output level for the same reason —
    /// a haptic engine does not care how loud the speaker is set.
    public struct Rendering: Equatable, Sendable {
        public let sound: DuckSound
        public let part: DuckSound.Part
        /// Samples per second, always `DuckVoice.sampleRate`; carried so a
        /// buffer that has been passed around still knows how to be played.
        public let sampleRate: Double
        /// Mono audio on −1…1. Hard-limited at those bounds: a sample outside
        /// them is a fault in this file, not a loud noise.
        public let samples: [Float]
        /// Amplitude on 0…1, one value per sample, never negative.
        public let envelope: [Float]

        public var duration: Double { Double(samples.count) / sampleRate }
    }

    // ── the PRNG ─────────────────────────────────────────────────────────

    /// SplitMix64, carried here rather than taken from anywhere.
    ///
    /// `Double.random` draws from `SystemRandomNumberGenerator`, which is
    /// seeded by the OS and cannot be pinned — a buffer built with it hashes
    /// differently every launch, so nothing can be tested and no two devices
    /// in the same room make the same noise. Sixteen lines of Steele, Lea and
    /// Flood's SplitMix64 (the mixing constants are theirs: 0x9E3779B97F4A7C15
    /// is the 64-bit golden-ratio increment) fixes both and adds no
    /// dependency. Its useful property here is that *adjacent* seeds give
    /// unrelated streams, which is what lets each part of a held sound take
    /// `seed + n` and still sound independent.
    public struct Random: Equatable, Sendable {
        private var state: UInt64

        public init(seed: UInt64) {
            self.state = seed
        }

        /// The next 64 bits of the stream.
        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// A double on [0, 1), from the top 53 bits — the mantissa's width,
        /// so every representable value in the range is reachable and none is
        /// twice as likely as its neighbour.
        public mutating func nextUnit() -> Double {
            Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)  // 2⁻⁵³
        }

        /// A double on [−1, 1). What white noise wants.
        public mutating func nextSymmetric() -> Double {
            nextUnit() * 2.0 - 1.0
        }
    }

    // ── rendering ────────────────────────────────────────────────────────

    /// Render one part of one sound.
    ///
    /// `.whole` of a held tag is the shortest complete utterance — start, one
    /// loop, end — and is *exactly* those three renderings concatenated, so a
    /// preview button and the live hold path play the same audio rather than
    /// two nearly-identical takes.
    public static func render(_ sound: DuckSound, part: DuckSound.Part, seed: UInt64) -> Rendering {
        precondition(sound.supports(part), "\(sound.tag) has no \(part.rawValue) part")

        if sound.isHeld, part == .whole {
            let pieces = sound.parts.map { render(sound, part: $0, seed: seed) }
            return Rendering(
                sound: sound, part: .whole, sampleRate: sampleRate,
                samples: pieces.flatMap { $0.samples },
                envelope: pieces.flatMap { $0.envelope })
        }

        let count = sound.ticks(of: part) * samplesPerTick
        var samples = [Double](repeating: 0, count: count)
        var envelope = [Double](repeating: 0, count: count)

        // Each part takes its own stream off the seed, so rendering the loop
        // alone and rendering it inside `.whole` give the same samples.
        var random = Random(seed: seed &+ salt(of: part))
        let voice = timbre(of: sound)
        for syllable in syllables(of: sound, part: part, random: &random) {
            add(syllable, timbre: voice, to: &samples, envelope: &envelope, random: &random)
        }

        return Rendering(
            sound: sound, part: part, sampleRate: sampleRate,
            samples: samples.map { Float(min(max($0, -1.0), 1.0)) },
            envelope: envelope.map { Float(min(max($0, 0.0), 1.0)) })
    }

    /// Every part a sound is sent in, in play order — one rendering for a
    /// one-shot, three for a held tag.
    public static func renderParts(_ sound: DuckSound, seed: UInt64) -> [Rendering] {
        sound.parts.map { render(sound, part: $0, seed: seed) }
    }

    /// Which stream of the seed a part draws from. Distinct per part, and
    /// small, because SplitMix64 decorrelates adjacent seeds for us.
    static func salt(of part: DuckSound.Part) -> UInt64 {
        switch part {
        case .whole: return 0
        case .start: return 1
        case .loop: return 2
        case .end: return 3
        }
    }

    // ── the instrument ───────────────────────────────────────────────────

    /// The spectral half of a voice: what the duck's throat does to whatever
    /// pitch is passing through it. Shared by every syllable of one sound —
    /// including all three parts of `wheee`, which is what keeps the ride
    /// sounding like one animal across the seams.
    struct Timbre {
        /// Centre of the one broad resonance the harmonics are weighted
        /// against, Hz. The nasal peak — moving it is what separates the
        /// bright `chirp` from the dull `peck`.
        let formant: Double
        /// Half-width of that resonance, Hz. Wide is honky, narrow is vocal.
        let bandwidth: Double
        /// Level of the even harmonics relative to the odd ones. Below 1 is
        /// the buzzy, pinched, reed-like sound a duck call has; at 1 the
        /// stack is a plain sawtooth and reads as a synthesizer.
        let evenLevel: Double
        /// Harmonic n is scaled by 1/nᵈ before the formant. Larger is duller.
        let rolloff: Double
        /// Seconds from silence to full amplitude. Milliseconds, always: a
        /// call that fades in is not a call.
        let attack: Double
        /// Seconds from the sustain level back to silence.
        let release: Double
        /// Level the body of the sound sags to before the release begins,
        /// relative to the peak. Held sounds must use 1.0 — their parts are
        /// butted together at play time, so the level at a seam has to be
        /// identical on both sides or the join clicks.
        let sustain: Double
        /// Fraction of filtered noise mixed under the tone, 0…1. Every voice
        /// here carries some, which is also what makes the seed matter for
        /// every tag rather than only for the one with a coin flip in it.
        let breath: Double
        /// Peak output, below 1 to leave the mix headroom.
        let level: Double
    }

    /// One voiced stretch inside a part: a pitch contour, a length and how it
    /// begins and ends. A `greet` that comes out as a wak-wak is two of these
    /// with a gap between them; the `wheee` loop is one that neither opens
    /// nor closes, because it has to be able to butt against itself.
    struct Syllable {
        let offsetTicks: Int
        let durationTicks: Int
        /// Fundamental at the start of the syllable, Hz.
        let f0Start: Double
        /// Fundamental at its end. The glide between them is exponential —
        /// constant in semitones per second, which is how pitch is heard.
        let f0End: Double
        let gain: Double
        /// Whether this syllable rises out of silence (applies the attack).
        let opens: Bool
        /// Whether it falls back to silence (applies the release).
        let closes: Bool
        /// Amplitude wobble, Hz. Zero for none.
        let tremoloHz: Double
        /// Depth of that wobble, 0…1: amplitude swings between 1 − depth
        /// and 1, so it can never drive the envelope negative.
        let tremoloDepth: Double

        init(offsetTicks: Int, durationTicks: Int, f0Start: Double, f0End: Double,
             gain: Double = 1, opens: Bool = true, closes: Bool = true,
             tremoloHz: Double = 0, tremoloDepth: Double = 0) {
            self.offsetTicks = offsetTicks
            self.durationTicks = durationTicks
            self.f0Start = f0Start
            self.f0End = f0End
            self.gain = gain
            self.opens = opens
            self.closes = closes
            self.tremoloHz = tremoloHz
            self.tremoloDepth = tremoloDepth
        }
    }

    /// The seven voices. Every number is a choice made here — there is no
    /// upstream to be faithful to, because the bank is on the robot — and
    /// each one is a sentence about what the sound is.
    static func timbre(of sound: DuckSound) -> Timbre {
        switch sound {
        case .alarm:
            // The loud one: high formant, hard odd-harmonic bias, a 4 ms
            // attack, and a body that sags fast so it lands like a honk.
            return Timbre(formant: 1900, bandwidth: 700, evenLevel: 0.45, rolloff: 0.85,
                          attack: 0.004, release: 0.09, sustain: 0.55, breath: 0.06, level: 0.92)
        case .greet:
            return Timbre(formant: 1500, bandwidth: 600, evenLevel: 0.50, rolloff: 1.00,
                          attack: 0.006, release: 0.07, sustain: 0.50, breath: 0.08, level: 0.85)
        case .inquire:
            // A question does not decay — it holds up at the top. Slower
            // attack and a high sustain are the whole difference.
            return Timbre(formant: 1400, bandwidth: 550, evenLevel: 0.55, rolloff: 1.10,
                          attack: 0.020, release: 0.12, sustain: 0.80, breath: 0.10, level: 0.80)
        case .peck:
            // Barely a voice: a 2 ms attack, a body that is gone almost at
            // once, even harmonics nearly as loud as odd (a knock is not a
            // reed) and a lot of noise. A tock, not a quack.
            return Timbre(formant: 900, bandwidth: 800, evenLevel: 0.95, rolloff: 1.70,
                          attack: 0.002, release: 0.05, sustain: 0.25, breath: 0.30, level: 0.75)
        case .chirp:
            return Timbre(formant: 1700, bandwidth: 650, evenLevel: 0.45, rolloff: 0.95,
                          attack: 0.005, release: 0.06, sustain: 0.55, breath: 0.07, level: 0.80)
        case .coo:
            // Drowsy: an 80 ms attack, a 300 ms release, the dullest formant
            // here and a third of the sound is breath.
            return Timbre(formant: 1100, bandwidth: 500, evenLevel: 0.70, rolloff: 1.40,
                          attack: 0.080, release: 0.30, sustain: 0.90, breath: 0.35, level: 0.60)
        case .wheee:
            // sustain 1.0 is not a taste: the three parts are played back to
            // back, so the level either side of a seam has to match exactly.
            return Timbre(formant: 1600, bandwidth: 700, evenLevel: 0.50, rolloff: 1.00,
                          attack: 0.030, release: 0.14, sustain: 1.00, breath: 0.09, level: 0.80)
        }
    }

    /// The pitch contours, laid out in control ticks so a syllable can never
    /// land off a tick boundary.
    ///
    /// Draws from `random` for exactly one decision — whether a `greet` is a
    /// double — and that draw happens before any noise is generated, so the
    /// layout is decided first and the two possible greets are different
    /// utterances rather than the same one with different hiss.
    static func syllables(of sound: DuckSound, part: DuckSound.Part,
                          random: inout Random) -> [Syllable] {
        switch sound {
        case .alarm:
            // Falls about three semitones over its whole length: 640 → 520 Hz.
            return [Syllable(offsetTicks: 0, durationTicks: 20, f0Start: 640, f0End: 520)]

        case .greet:
            // "Sometimes a double wak-wak" — a coin flip, because there is no
            // better number available to us. Single: one 0.36 s quack falling
            // 520 → 370. Double: 0.18 s, a 0.08 s gap, then a shorter and
            // slightly lower answer, which is what makes it read as wak-wak
            // rather than as one quack played twice.
            if random.nextUnit() < 0.5 {
                return [
                    Syllable(offsetTicks: 0, durationTicks: 9, f0Start: 520, f0End: 400),
                    Syllable(offsetTicks: 13, durationTicks: 11, f0Start: 480, f0End: 350, gain: 0.9),
                ]
            }
            return [Syllable(offsetTicks: 0, durationTicks: 18, f0Start: 520, f0End: 370)]

        case .inquire:
            // The only rising contour here, and the reason it reads as a
            // question: 360 → 640 Hz, most of an octave up, over 0.44 s.
            return [Syllable(offsetTicks: 1, durationTicks: 22, f0Start: 360, f0End: 640)]

        case .peck:
            // 0.14 s of sound inside a 0.24 s slot; the rest is the silence
            // that makes it a tock instead of a chirp.
            return [Syllable(offsetTicks: 0, durationTicks: 7, f0Start: 300, f0End: 210)]

        case .chirp:
            return [Syllable(offsetTicks: 0, durationTicks: 11, f0Start: 560, f0End: 430)]

        case .coo:
            // Hardly moves — 340 → 300 Hz over most of a second — and wobbles
            // instead: 5 Hz, a third deep. That wobble is the whole call.
            return [Syllable(offsetTicks: 2, durationTicks: 46, f0Start: 340, f0End: 300,
                             tremoloHz: 5, tremoloDepth: 0.35)]

        case .wheee:
            switch part {
            case .start:
                // Take-off: 420 → 700 Hz in 0.24 s, opening from silence and
                // *not* closing — it hands straight over to the loop.
                return [Syllable(offsetTicks: 0, durationTicks: 12, f0Start: 420, f0End: 700,
                                 opens: true, closes: false)]
            case .loop:
                // 700 Hz held for 0.5 s = 350 whole cycles, which is why this
                // pitch: the loop can be butted against itself with the
                // waveform phase-continuous at the join. The 8 Hz shimmer is
                // 8 × 0.5 = 4 whole cycles for the same reason. Neither opens
                // nor closes, so its envelope is flat and its first and last
                // amplitudes are equal.
                return [Syllable(offsetTicks: 0, durationTicks: 25, f0Start: 700, f0End: 700,
                                 opens: false, closes: false,
                                 tremoloHz: 8, tremoloDepth: 0.25)]
            case .end:
                // Landing: 700 → 340 Hz over 0.36 s, closing to silence.
                return [Syllable(offsetTicks: 0, durationTicks: 18, f0Start: 700, f0End: 340,
                                 opens: false, closes: true)]
            case .whole:
                preconditionFailure("a held sound's .whole is assembled from its parts")
            }
        }
    }

    // ── the oscillator ───────────────────────────────────────────────────

    /// One-pole lowpass coefficient for the breath noise: a 3 kHz cutoff,
    /// `exp(−2π·3000/48000)` ≈ 0.675. Above that it is hiss rather than
    /// breath, and hiss is what makes a synthesized animal sound synthetic.
    static let noiseCoefficient = exp(-2.0 * Double.pi * 3000.0 / sampleRate)

    /// Uniform noise on [−1, 1) has RMS 1/√3; a one-pole at coefficient `a`
    /// multiplies variance by (1−a)/(1+a), so the filtered stream comes out at
    /// (1/√3)·√((1−a)/(1+a)) ≈ 0.25 RMS. Scaling by 0.5 over that puts breath
    /// at half full scale, which leaves room for the tone underneath it.
    static let noiseGain = 0.5 / ((1.0 / 3.0).squareRoot()
        * ((1 - noiseCoefficient) / (1 + noiseCoefficient)).squareRoot())

    /// Sum one syllable into the buffers.
    ///
    /// The oscillator stack is divided by the sum of its own weights every
    /// sample, so the tone before the envelope is bounded by ±1 by
    /// construction — there is no normalization pass afterwards, which is
    /// what lets the three parts of a held sound be rendered separately and
    /// still match in level at the seams.
    static func add(_ syllable: Syllable, timbre: Timbre,
                    to samples: inout [Double], envelope: inout [Double],
                    random: inout Random) {
        let first = syllable.offsetTicks * samplesPerTick
        let count = syllable.durationTicks * samplesPerTick
        precondition(count > 0 && first >= 0 && first + count <= samples.count,
                     "a syllable runs past the end of its part — the table above is wrong")

        let duration = Double(count) / sampleRate
        let nyquist = sampleRate / 2
        let glide = log(syllable.f0End / syllable.f0Start)

        // Odd harmonics at full strength, even ones held back, the whole
        // stack tilted by 1/nᵈ. Fixed for the syllable; only the formant
        // weighting below changes as the pitch glides.
        var base = [Double](repeating: 0, count: harmonicLimit)
        for n in 1...harmonicLimit {
            let odd = n % 2 == 1 ? 1.0 : timbre.evenLevel
            base[n - 1] = odd / pow(Double(n), timbre.rolloff)
        }

        // Envelope breakpoints. A syllable that neither opens nor closes is
        // flat at full level for its whole length — the seamless case.
        let attack = syllable.opens ? timbre.attack : 0
        let release = syllable.closes ? timbre.release : 0
        let bodyStart = min(attack, duration)
        let bodyEnd = max(bodyStart, duration - release)
        let sustain = (syllable.opens || syllable.closes) ? timbre.sustain : 1.0

        var phase = 0.0
        var noise = 0.0

        for i in 0..<count {
            let u = Double(i) / sampleRate

            // Exponential pitch glide, integrated into a running phase so the
            // waveform stays continuous while the frequency moves.
            let f = syllable.f0Start * exp(glide * (duration > 0 ? u / duration : 0))
            phase += 2.0 * Double.pi * f / sampleRate

            var sum = 0.0
            var norm = 0.0
            for n in 1...harmonicLimit {
                let harmonic = Double(n) * f
                if harmonic >= nyquist { break }
                let offset = (harmonic - timbre.formant) / timbre.bandwidth
                let weight = base[n - 1] / (1.0 + offset * offset)
                norm += weight
                sum += weight * sin(Double(n) * phase)
            }
            let tone = norm > 0 ? sum / norm : 0

            noise = noiseCoefficient * noise + (1 - noiseCoefficient) * random.nextSymmetric()

            // Attack ramp, a body sagging towards the sustain level, release.
            var shape: Double
            if u < bodyStart {
                shape = u / bodyStart
            } else if u > bodyEnd {
                shape = release > 0 ? sustain * (duration - u) / release : sustain
            } else if bodyEnd > bodyStart {
                shape = 1 + (sustain - 1) * (u - bodyStart) / (bodyEnd - bodyStart)
            } else {
                shape = 1
            }
            if syllable.tremoloDepth > 0 {
                shape *= 1 - syllable.tremoloDepth
                    * (0.5 - 0.5 * cos(2.0 * Double.pi * syllable.tremoloHz * u))
            }
            let amplitude = max(shape, 0) * syllable.gain

            let voiced = (1 - timbre.breath) * tone + timbre.breath * noise * noiseGain
            samples[first + i] += voiced * amplitude * timbre.level
            envelope[first + i] += amplitude
        }
    }
}

#if canImport(Glibc)
import Glibc
#endif
