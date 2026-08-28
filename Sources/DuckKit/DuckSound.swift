/// The duck's seven noises, as a type.
///
/// `robot.sound` TAKES A STRING, AND A STRING IS THE PART THAT ROTS. The seven
/// tags below are the whole vocabulary robotd accepts; send it "quack" or
/// "wheeee" and nothing happens, no error comes back, and the bug looks like a
/// dead speaker rather than a typo. Every duck app needs this list, every one
/// of them would otherwise retype it as string literals scattered through a
/// view layer, and each copy is one more place a tag can be spelled wrong. So
/// the tags live here once, as cases, and `rawValue` *is* the wire string —
/// the same trick `DuckPolicyKind` plays with its ONNX file names.
///
/// SIX OF THESE ARE FIRE-AND-FORGET, ONE IS A SUBSCRIPTION. `wheee` is held:
/// you start it, you keep saying you still want it, and it ends — either
/// because you said so or because you stopped saying anything. That last case
/// is the one worth having a type for. robotd runs a deadman on the hold:
/// roughly half a second with no further hold and the sound decays into its
/// end part on its own, which is the correct behaviour when a phone is
/// backgrounded, walks out of Wi-Fi range, or is dropped in a pond mid-ride.
/// The client's side of that bargain is to re-send the hold about every
/// 100 ms, which buys 0.5 / 0.1 = five chances to be heard inside one deadman
/// window: four consecutive lost packets still leave the ride running, and a
/// genuinely dead client still stops the noise within half a second.
///
/// THE DURATIONS BELOW ARE OURS, NOT POLLEN'S. The voice bank is on the robot
/// and not in this repo, so nobody here can measure a real one; these are the
/// lengths DuckKit *plays* them at — what `DuckVoice` renders and what
/// `DuckPerformance` choreographs against. They are quantized to the 50 Hz
/// control tick (one tick = 20 ms) so that a performance timeline always ends
/// on a tick boundary and a rendered buffer is always a whole number of ticks
/// long; at 48 kHz that also makes every part a whole number of samples
/// (48000 / 50 = 960 samples per tick), which is why nothing in the voice has
/// to round. When hardware lands, measure the bank and correct the tick counts
/// here: every timeline and every rendered buffer follows from them.
public enum DuckSound: String, CaseIterable, Equatable, Sendable {

    /// A sharp honk. The duck's only loud noise and its only warning.
    case alarm
    /// The wake-up quack, sometimes doubled into a wak-wak.
    case greet
    /// A rising question. The duck has noticed something and wants to know.
    case inquire
    /// A low tock, more knock than voice.
    case peck
    /// Its quack: the ordinary, content, unremarkable one.
    case chirp
    /// Drowsy and breathy — what it answers being petted with.
    case coo
    /// The joy ride. Held for as long as the ride lasts.
    case wheee

    /// The string `robot.sound` wants. Identical to `rawValue`; spelled out
    /// at call sites so the wire field and the Swift case are visibly the
    /// same thing.
    public var tag: String { rawValue }

    /// The tag to play on the way down. `peck` is the duck's goodbye, so an
    /// app that is about to ask for a power-off has one obvious thing to say
    /// first — and every app should say the same one.
    public static let goodbye = DuckSound.peck

    // ── one-shot versus held ─────────────────────────────────────────────

    /// True for the one tag that has to be kept alive: `wheee`.
    ///
    /// Held is not "long". `coo` is the longest thing sent whole and it is
    /// still fire-and-forget — you ask for it, it happens, it is over — while
    /// every part `wheee` is actually sent in is shorter than `coo` and held
    /// regardless. Held means the duck is waiting to hear from you again, and
    /// that a silent client is a client whose sound stops.
    public var isHeld: Bool { self == .wheee }

    /// The pieces a sound is played in. A one-shot is `.whole` and nothing
    /// else; a held tag is start → loop (as many times as the ride lasts) →
    /// end, and `.whole` for it means the shortest complete utterance: start,
    /// one loop, end.
    public enum Part: String, CaseIterable, Equatable, Sendable {
        /// The entire sound, start to finish.
        case whole
        /// The attack of a held sound. Plays once, cannot be interrupted
        /// short — the duck has already drawn breath.
        case start
        /// The sustain of a held sound. Repeats while holds keep arriving,
        /// and is written so its last instant matches its first: it has to
        /// be able to butt against itself without a click or a lurch.
        case loop
        /// The release of a held sound, played when the hold stops arriving
        /// or is explicitly let go.
        case end
    }

    /// The parts this sound is actually sent in — `[.whole]` for a one-shot,
    /// `[.start, .loop, .end]` for a held one.
    public var parts: [Part] { isHeld ? [.start, .loop, .end] : [.whole] }

    /// Whether a part means anything for this sound. `.whole` always does;
    /// the three held parts only exist for a held tag. Callers that take a
    /// part as a parameter check this rather than silently rendering silence.
    public func supports(_ part: Part) -> Bool {
        part == .whole || isHeld
    }

    // ── length ───────────────────────────────────────────────────────────

    /// How long a part lasts, in 50 Hz control ticks — the primary number,
    /// because it is an integer and everything downstream (sample counts,
    /// keyframe times) divides out of it exactly.
    ///
    /// Chosen, not measured, for the reason in this file's opening: the bank
    /// is on the robot. The shapes are the character — `peck` is 12 ticks
    /// because a tock that lasts a quarter of a second is a tock and one that
    /// lasts half a second is a groan; `coo` is a full second because the
    /// drowsy one is the only sound that is allowed to take its time.
    public func ticks(of part: Part) -> Int {
        precondition(supports(part), "\(tag) has no \(part.rawValue) part")
        switch (self, part) {
        case (.alarm, _): return 20      // 0.40 s
        case (.greet, _): return 30      // 0.60 s — room for two syllables
        case (.inquire, _): return 25    // 0.50 s
        case (.peck, _): return 12       // 0.24 s
        case (.chirp, _): return 15      // 0.30 s
        case (.coo, _): return 50        // 1.00 s
        case (.wheee, .start): return 12 // 0.24 s
        case (.wheee, .loop): return 25  // 0.50 s
        case (.wheee, .end): return 18   // 0.36 s
        case (.wheee, .whole): return 12 + 25 + 18  // one ride, one loop: 1.10 s
        }
    }

    /// The same length in seconds. Derived from the tick count and the
    /// control rate, never written down separately, so the two cannot drift.
    public func duration(of part: Part) -> Double {
        Double(ticks(of: part)) / DuckModel.tickHz
    }

    /// The length of one complete utterance — for a held tag, the shortest
    /// one there is. What a UI budgets a slot for.
    public var nominalDuration: Double { duration(of: .whole) }

    // ── the hold protocol ────────────────────────────────────────────────

    /// How often a client re-sends the hold while a held sound is wanted:
    /// 100 ms, or once every five control ticks.
    public static let holdInterval = 0.1

    /// How long robotd waits after the last hold before letting a held sound
    /// decay into its end part — the deadman. Approximately half a second;
    /// the point of it is that a client which stops talking cannot leave the
    /// duck shrieking, so err towards re-sending rather than towards trusting
    /// this number to the millisecond.
    public static let holdDeadline = 0.5

    /// Holds that fit inside one deadman window: 0.5 / 0.1 = 5. The margin,
    /// stated as a number because it is the reason the cadence is 100 ms and
    /// not 400 ms — four consecutive dropped packets still keep the ride
    /// alive, and nothing keeps it alive once the client is really gone.
    public static let holdsPerDeadline = Int((holdDeadline / holdInterval).rounded())

    // ── what each one is ─────────────────────────────────────────────────

    /// One sentence about what this noise *is*, for the screen that lists
    /// them. Not a translation of the case name: someone picking a sound off
    /// a menu is choosing a meaning, and "inquire" does not tell them the
    /// duck is going to sound like it asked a question.
    public var character: String {
        switch self {
        case .alarm:
            return "A sharp honk. The loud one — a warning, not a greeting."
        case .greet:
            return "The wake-up quack. Sometimes a double, wak-wak."
        case .inquire:
            return "A rising question. The duck noticed something."
        case .peck:
            return "A low tock, almost a knock. Also the goodbye before power-off."
        case .chirp:
            return "Its quack: ordinary, content, nothing in particular."
        case .coo:
            return "Drowsy and breathy. What it answers being petted with."
        case .wheee:
            return "The joy ride, held for as long as the ride lasts."
        }
    }
}
