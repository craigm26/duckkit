import Foundation

extension DuckVoice {

    /// The traits that make one duck sound like a different creature from the
    /// next one, derived from a single seed.
    ///
    /// EVERY DUCK IN THIS PACKAGE USED TO SOUND IDENTICAL, AND THE REAL ROBOT
    /// DOES NOT WORK THAT WAY. Upstream's voice is a seedable synth: one integer
    /// derives a personality — register, harmonic tilt, nasality, vibrato,
    /// quackiness, tempo — and the robot's seed comes from its own SoC serial,
    /// so two Microducks on the same table sound like two animals rather than
    /// one animal played twice. `DuckVoice`'s per-tag `Timbre` gives each *sound*
    /// its character; this gives each *duck* its own. Without it an app showing
    /// six ducks is showing one duck six times.
    ///
    /// THE DERIVATION IS A PORT, NOT AN INVENTION. The generator, the call
    /// order, the ranges and the harmonic weighting below are ported from
    /// `sounds/src/personality.rs` and `sounds/src/rng.rs` in
    /// github.com/pollen-robotics/microduck (Apache-2.0), where the file header
    /// makes the stakes explicit: *"the generator IS the voice"*. A robot's bank
    /// is re-rendered from its seed on every install, so changing the arithmetic
    /// re-voices the fleet silently. That is why the RNG is written out here
    /// rather than taken from a library that reserves the right to change, and
    /// why `DuckPersonalityTests` pins the stream against values computed by a
    /// second, independent implementation.
    ///
    /// WHAT IS **NOT** CLAIMED: that a given seed produces bit-identical audio
    /// to the robot's bank. The recipes that turn these traits into samples are
    /// upstream's and are not ported — `DuckVoice`'s own synthesis renders them.
    /// So the *traits* for a seed match; the waveform is ours. Nothing here has
    /// been checked against a real robot's bank, because none exists to check
    /// against yet. When hardware lands, compare and record the result rather
    /// than assuming this paragraph is still the last word.
    public struct Personality: Equatable, Sendable {

        /// The seed every field below is a pure function of.
        public let seed: UInt32

        // ── pitch ────────────────────────────────────────────────────────────

        /// Where this duck's voice sits, in Hz. Clamped to 110…620 — the whole
        /// population stays in duck-and-toad territory however the dice fall.
        public let pitchCenterHz: Double
        /// Roughly −1.4…+1.4: an octave-ish shift on top of the centre. Drawn as
        /// a choice of −1/0/0/1 plus a ±0.4 wobble, which is deliberately
        /// bimodal — some ducks are small and high, some are big and low, and
        /// few are exactly average.
        public let register: Double
        /// 0.4…1.2 — how dramatic this duck's glides are.
        public let pitchSpread: Double
        /// −1…+1 — negative falls, positive rises.
        public let glideBias: Double

        // ── timbre ───────────────────────────────────────────────────────────

        /// 0.05…0.55 — lift on the high-harmonic tail. Higher is buzzier.
        public let brightness: Double
        /// 1.4…2.8 — the exponent on harmonic decay. Higher is darker.
        public let tilt: Double
        /// 0.1…1 — emphasis on the 2nd and 3rd harmonics, which is what reads
        /// as "nasal" rather than "round".
        public let nasal: Double
        /// −1…+1 — negative leans odd-only and square-ish, positive leans even.
        public let harmonicSkew: Double
        /// 1…5 — which harmonic the formant boosts.
        public let formantN: Int
        /// 0…1.4 — how hard it boosts it.
        public let formantGain: Double

        // ── modulation ───────────────────────────────────────────────────────

        /// 3.5…9.5 Hz.
        public let vibratoRateHz: Double
        /// 0…0.7 semitones.
        public let vibratoDepth: Double
        /// 0.03…0.35 semitones of random pitch wobble — the thing that stops a
        /// held note sounding synthesised.
        public let jitterDepth: Double
        /// 0…0.30 — how much noise is mixed in as breath.
        public let breath: Double
        /// 0.2…1 — blends pure tone against amplitude-modulated buzz. This is
        /// the trait that most decides whether it reads as a quack at all.
        public let quackiness: Double
        /// 18…55 Hz — the quack/croak buzz rate. Only audible when
        /// `quackiness` is up.
        public let amRateHz: Double
        /// 0.15…0.70 — that buzz's depth.
        public let amDepth: Double
        /// 7…18 Hz — the trill on a chirp.
        public let warbleHz: Double
        /// 0…1.4 semitones of it.
        public let warbleDepth: Double

        // ── timing ───────────────────────────────────────────────────────────

        /// 0…1 — 0 is a soft pad, 1 is snappy.
        public let attackSharpness: Double
        /// 0.82…1.22 — a global tempo multiplier, so one duck is simply a
        /// brisker animal than another.
        public let speed: Double

        // ── derivation ───────────────────────────────────────────────────────

        /// Derive a duck's whole voice from one integer.
        ///
        /// The draw order below is load-bearing and matches upstream exactly:
        /// the generator is a single stream, so moving one line changes every
        /// field after it. Do not reorder to tidy the file.
        public init(seed: UInt32) {
            var rng = Random(seed: seed)
            self.seed = seed

            let register = rng.choice([-1.0, 0.0, 0.0, 1.0]) + rng.uniform(-0.4, 0.4)
            let base = rng.uniform(160.0, 380.0)
            self.pitchCenterHz = min(max(base * pow(2.0, register * 0.45), 110.0), 620.0)
            self.register = register

            self.pitchSpread = rng.uniform(0.4, 1.2)
            self.glideBias = rng.uniform(-1.0, 1.0)

            self.brightness = rng.uniform(0.05, 0.55)
            self.tilt = rng.uniform(1.4, 2.8)
            self.nasal = rng.uniform(0.1, 1.0)
            self.harmonicSkew = rng.uniform(-1.0, 1.0)
            self.formantN = Int(rng.integers(1, 6))
            self.formantGain = rng.uniform(0.0, 1.4)

            self.vibratoRateHz = rng.uniform(3.5, 9.5)
            self.vibratoDepth = rng.uniform(0.0, 0.7)
            self.jitterDepth = rng.uniform(0.03, 0.35)
            self.breath = rng.uniform(0.0, 0.30)
            self.quackiness = rng.uniform(0.2, 1.0)
            self.amRateHz = rng.uniform(18.0, 55.0)
            self.amDepth = rng.uniform(0.15, 0.70)
            self.warbleHz = rng.uniform(7.0, 18.0)
            self.warbleDepth = rng.uniform(0.0, 1.4)

            self.attackSharpness = rng.uniform(0.0, 1.0)
            self.speed = rng.uniform(0.82, 1.22)
        }

        /// Derive a duck's voice from any stable string — a robot serial, a
        /// pairing UUID, a save-file id.
        ///
        /// The robot seeds itself from its SoC serial. That mapping is not in
        /// the sources this file was ported from, so **this one is ours**:
        /// CRC-32 of the UTF-8 bytes, chosen because it is the hash upstream
        /// already relies on for variant selection and because Swift's own
        /// `Hasher` is salted per process — which would give the same duck a
        /// different voice on every launch, the one failure mode a voice must
        /// not have.
        public init(identifier: String) {
            self.init(seed: Personality.crc32(Array(identifier.utf8)))
        }

        /// The voice of a duck that has no identity yet. Seed 0 is as arbitrary
        /// as any other seed and is spelled out so nobody invents a second
        /// default somewhere else.
        public static let unnamed = Personality(seed: 0)

        // ── what the synth reads ─────────────────────────────────────────────

        /// Personality-shaped weights for the first seven harmonics.
        ///
        /// Combines the overall rolloff (`tilt`), the high-end lift
        /// (`brightness`), the 2nd/3rd bump (`nasal`), an even-versus-odd
        /// preference (`harmonicSkew`) and a boost at one chosen harmonic.
        /// Never negative: a weight that went below zero would invert that
        /// partial's phase rather than remove it.
        public func harmonics() -> [Double] {
            let n = 7
            return (1...n).map { i in
                let h = Double(i)
                let base = 1.0 / pow(h, tilt)
                let highLift = brightness * pow(h / Double(n), 1.5)
                let nasalLift = nasal * ((i == 2 || i == 3) ? 0.6 : 0.0)
                let skew: Double = harmonicSkew >= 0
                    ? harmonicSkew * (i % 2 == 0 ? 0.4 : -0.2)
                    : -harmonicSkew * (i % 2 == 0 ? -0.3 : 0.4)
                let formant = (i == formantN) ? formantGain : 0.0
                return max(base + highLift + nasalLift + skew + formant * base * 1.5, 0.0)
            }
        }

        /// A stable generator for one (duck, tag, variant).
        ///
        /// Variants are small re-rolls *within* this duck's voice, so a duck
        /// that quacks twice does not sound like a stuck recording while still
        /// sounding like the same duck. CRC-32 of the tag rather than a
        /// standard-library hash for the reason in `init(identifier:)` — a
        /// salted hash would re-roll every variant on every launch.
        public func variantRandom(tag: String, variant: UInt32) -> Random {
            let h = (UInt64(seed) &* 1_000_003)
                ^ UInt64(Personality.crc32(Array(tag.utf8)))
                ^ (UInt64(variant) &* 2_654_435_761)
            return Random(seed: UInt32(truncatingIfNeeded: h))
        }

        /// Convenience for the seven shipped tags.
        public func variantRandom(for sound: DuckSound, variant: UInt32) -> Random {
            variantRandom(tag: sound.tag, variant: variant)
        }

        /// CRC-32 (IEEE), as `zlib.crc32` computes it. Written out rather than
        /// pulled in: the polynomial is fixed by the voices already in the
        /// field, so this is a constant of the format and not a dependency.
        static func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    let mask = (crc & 1) == 1 ? UInt32.max : 0
                    crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
                }
            }
            return ~crc
        }

        // ── the generator ────────────────────────────────────────────────────

        /// xoshiro256++, seeded through splitmix64.
        ///
        /// A SECOND GENERATOR IN THIS FILE, AND ON PURPOSE. `DuckVoice.Random`
        /// is SplitMix64 and re-rolls detail *inside* one rendering; this one
        /// decides what a duck sounds like at all, and it has to match
        /// upstream's stream exactly or the traits it derives are a different
        /// animal's. Both are written out for the same reason — a generator
        /// taken from a library that reserves the right to change its algorithm
        /// would re-voice every duck on a dependency bump, silently.
        ///
        /// Both algorithms are Blackman & Vigna's and public domain.
        public struct Random: Equatable, Sendable {
            private var s: (UInt64, UInt64, UInt64, UInt64)

            /// Hand-written because a tuple of four `UInt64`s does not
            /// synthesize `Equatable`. Two generators are equal when they would
            /// produce the same stream from here on — which is what a test
            /// comparing a derived variant against a known seed is asking.
            public static func == (a: Random, b: Random) -> Bool { a.s == b.s }

            /// Seeded from a `UInt32`, as upstream is: splitmix64 expands it
            /// into the four xoshiro words so that small, adjacent seeds — 0, 1,
            /// 2, the ones a caller actually reaches for — still start
            /// well-mixed and sound unrelated.
            public init(seed: UInt32) {
                var x = UInt64(seed)
                func next() -> UInt64 {
                    x = x &+ 0x9E37_79B9_7F4A_7C15
                    var z = x
                    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                    return z ^ (z >> 31)
                }
                s = (next(), next(), next(), next())
            }

            public mutating func nextUInt64() -> UInt64 {
                let result = ((s.0 &+ s.3) << 23 | (s.0 &+ s.3) >> 41) &+ s.0
                let t = s.1 << 17
                s.2 ^= s.0
                s.3 ^= s.1
                s.1 ^= s.2
                s.0 ^= s.3
                s.2 ^= t
                s.3 = s.3 << 45 | s.3 >> 19
                return result
            }

            /// Uniform in [0, 1), from the top 53 bits — the full precision a
            /// `Double` mantissa holds, and the same slice upstream takes.
            public mutating func next() -> Double {
                Double(nextUInt64() >> 11) * (1.0 / Double(1 << 53))
            }

            /// Uniform in [lo, hi).
            public mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
                lo + (hi - lo) * next()
            }

            /// Uniform integer in [lo, hi) — numpy's half-open `integers`
            /// convention, which is what the Python original used and what the
            /// ranges above are written against.
            public mutating func integers(_ lo: Int, _ hi: Int) -> Int {
                lo + Int((next() * Double(hi - lo)).rounded(.down))
            }

            /// One element, uniformly.
            public mutating func choice(_ choices: [Double]) -> Double {
                choices[integers(0, choices.count)]
            }
        }
    }
}

// ── applying a personality to this synth ─────────────────────────────────────

extension DuckVoice.Personality {

    /// The fundamental the shipped per-tag syllable tables in `DuckVoice` are
    /// written at. A duck whose `pitchCenterHz` is this sings them unshifted.
    public static let referencePitchHz: Double = 300

    /// How far this duck's pitch is from the tables, as a multiplier.
    public var pitchScale: Double { pitchCenterHz / Self.referencePitchHz }
}

extension DuckVoice {

    /// Render a part *as a particular duck*.
    ///
    /// `render(_:part:seed:)` renders the tables as written — one duck, the
    /// same one every time. This renders them through a `Personality`, so six
    /// ducks on a screen are six animals rather than one animal six times.
    ///
    /// **The length does not change.** Every buffer stays a whole number of
    /// 50 Hz control ticks whatever the personality says, because
    /// `DuckPerformance` choreographs against those tick counts and a
    /// personality that stretched its own audio would slide out of its own
    /// gestures. `speed` therefore moves rates *inside* the sound — the wobble,
    /// the trill — and never its duration.
    ///
    /// The traits are a faithful port of upstream's; **how this synth consumes
    /// them is ours**, and has to be: the recipes that turn traits into samples
    /// on the robot are not ported, so these are the couplings that make
    /// DuckVoice's own oscillator stack respond to the same knobs. Two
    /// personalities are audibly two creatures here, and a given seed is a
    /// stable creature — those are the properties tested. Byte-parity with a
    /// robot's bank is neither claimed nor possible from this direction.
    public static func render(_ sound: DuckSound, part: DuckSound.Part,
                              seed: UInt64, as personality: Personality) -> Rendering {
        precondition(sound.supports(part), "\(sound.tag) has no \(part.rawValue) part")

        if sound.isHeld, part == .whole {
            let pieces = sound.parts.map { render(sound, part: $0, seed: seed, as: personality) }
            return Rendering(
                sound: sound, part: .whole, sampleRate: sampleRate,
                samples: pieces.flatMap { $0.samples },
                envelope: pieces.flatMap { $0.envelope })
        }

        let count = sound.ticks(of: part) * samplesPerTick
        var samples = [Double](repeating: 0, count: count)
        var envelope = [Double](repeating: 0, count: count)

        var random = Random(seed: seed &+ salt(of: part))
        let voice = personality.shape(timbre(of: sound))
        for syllable in syllables(of: sound, part: part, random: &random) {
            add(personality.shape(syllable), timbre: voice,
                to: &samples, envelope: &envelope, random: &random)
        }

        return Rendering(
            sound: sound, part: part, sampleRate: sampleRate,
            samples: samples.map { Float(min(max($0, -1.0), 1.0)) },
            envelope: envelope.map { Float(min(max($0, 0.0), 1.0)) })
    }

    /// Every part, in play order, as a particular duck.
    public static func renderParts(_ sound: DuckSound, seed: UInt64,
                                   as personality: Personality) -> [Rendering] {
        sound.parts.map { render(sound, part: $0, seed: seed, as: personality) }
    }
}

extension DuckVoice.Personality {

    /// Bend one of the seven shipped voices toward this duck.
    ///
    /// Each coupling is a sentence about what the trait means for *this*
    /// oscillator stack. Everything is clamped into the range the synth is
    /// known to behave in, because a personality is drawn from dice and must
    /// not be able to produce a voice that clips, whistles, or disappears.
    func shape(_ t: DuckVoice.Timbre) -> DuckVoice.Timbre {
        // Harmonic decay. `tilt` is the same quantity as `rolloff` — how fast
        // the stack falls away — so it maps directly, centred on its own
        // midpoint so an average duck leaves the tables alone.
        let rolloff = min(max(t.rolloff + (tilt - 2.1) * 0.35, 0.55), 2.4)

        // Even-versus-odd. Negative skew is odd-only and square-ish, which is
        // the reedy end; positive fills the evens in and rounds it out.
        let evenLevel = min(max(t.evenLevel + harmonicSkew * 0.25, 0.15), 1.0)

        // Where the throat resonates. `nasal` is the 2nd/3rd-harmonic lift, and
        // in a one-resonance model that reads as moving the peak; `formantN`
        // nudges it further, since it is the partial upstream boosts.
        let formant = min(max(t.formant + (nasal - 0.55) * 320
                              + (Double(formantN) - 3) * 55, 700), 2500)

        // A quackier duck is a buzzier one: the resonance tightens, which is
        // what turns a hoot into a honk.
        let bandwidth = min(max(t.bandwidth * (1.25 - 0.4 * quackiness), 300), 1100)

        // Breath rides on top of whatever the tag already carries.
        let breath = min(max(t.breath + (self.breath - 0.15) * 0.6, 0), 0.6)

        // Attack only ever gets sharper or softer within the millisecond range
        // that keeps a call a call — nothing here may fade in.
        let attack = min(max(t.attack * (1.4 - 0.8 * attackSharpness), 0.002), 0.05)

        return DuckVoice.Timbre(
            formant: formant, bandwidth: bandwidth, evenLevel: evenLevel,
            rolloff: rolloff, attack: attack, release: t.release,
            sustain: t.sustain,        // held seams depend on this — never touched
            breath: breath,
            level: t.level)            // headroom is not a personality trait
    }

    /// Move a syllable into this duck's register, and put its wobble at this
    /// duck's rate. Offsets and durations are untouched: they are tick counts,
    /// and the whole package is built on those being exact.
    func shape(_ s: DuckVoice.Syllable) -> DuckVoice.Syllable {
        let scale = pitchScale
        return DuckVoice.Syllable(
            offsetTicks: s.offsetTicks,
            durationTicks: s.durationTicks,
            f0Start: s.f0Start * scale,
            f0End: s.f0End * scale,
            gain: s.gain,
            opens: s.opens,
            closes: s.closes,
            // `speed` is a tempo trait, and the only tempo this synth has that
            // is not a tick count is the wobble rate.
            tremoloHz: s.tremoloHz * speed,
            tremoloDepth: min(max(s.tremoloDepth * (0.6 + 0.8 * vibratoDepth / 0.7), 0), 0.9))
    }
}
