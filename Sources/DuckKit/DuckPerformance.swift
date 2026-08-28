/// What the duck's body does while it makes a noise.
///
/// A SOUND IS NOT A SOUND, IT IS A PERFORMANCE. `robot.sound` plays a tag
/// through the speaker; it does not move anything. Something still has to
/// decide that the beak opens on the quack and shuts a beat before it ends,
/// that a `peck` puts the head on the floor, that `inquire` tilts. That
/// decision is choreography, it is ours to make — Pollen ships the tag, not
/// the gesture — and the reason it lives in the kit rather than in an app is
/// that there is going to be more than one app. An AR ghost animating one set
/// of curves while the real robot is driven by another set is two ducks with
/// the same name. Here, both read this file: the ghost samples the poses and
/// draws them, the driver samples the same poses and sends them as
/// `DuckCommand`s. Same animal.
///
/// THE HOLD-AND-DECAY SEMANTICS ARE IMPLEMENTED ONCE, IN `Playback`. Held
/// sounds are the part everybody gets subtly wrong on their own: `wheee` runs
/// start → loop → end, the loop repeats while holds keep arriving, and if they
/// stop, robotd's ~0.5 s deadman (`DuckSound.holdDeadline`) drops it into the
/// end part without being asked. Reimplementing that per app produces four
/// timers with four different off-by-a-frame bugs, and one of those bugs is
/// interesting: a ride that decays while the body is still mid-spin leaves a
/// non-zero twist commanded and the duck quietly walking away from you. So
/// every timeline here comes back to a zero twist and a neutral pose before it
/// finishes, `Playback` is the only thing that knows about the deadman, and
/// `DuckPerformanceTests` holds both claims on Linux with no phone in the room.
///
/// SIGN CONVENTION, WRITTEN DOWN ONCE BECAUSE NOTHING ELSE HERE SETTLES IT.
/// The vendored MuJoCo model gives joint axes and travel but does not tell you
/// which way a positive `head_pitch` points the beak. These tables assume
/// positive neck/head pitch is beak-towards-the-floor, positive `head_yaw`
/// turns to the duck's left, positive `head_roll` leans right. If hardware
/// disagrees, the fix is to negate that column in `keyframes(of:part:)` — the
/// shapes and the timings stay right, and nothing else in the kit has an
/// opinion to correct.
///
/// The head values are *commands*, and `DuckObservation` feeds them to the
/// policy rather than adding them to its output, so what the joint finally
/// does is the network's business. That is why the tables stay well inside
/// travel instead of near it: `DuckPerformanceTests` checks every keyframe
/// both as an absolute joint angle and as an offset from the home pose,
/// because we do not get to decide which one robotd means, and staying legal
/// under either reading is the only claim that can honestly be made from here.
public enum DuckPerformance {

    // ── what a moment looks like ─────────────────────────────────────────

    /// One instant of a performance: everything the duck is being asked to
    /// do, in the two pieces the robot takes them in. `DuckCommand` is what
    /// the policy sees; the mouth is not in any policy, so it travels beside
    /// the command exactly as it does in `DuckSimulation`.
    public struct Pose: Equatable, Sendable {
        public let command: DuckCommand
        /// Beak opening, 0 shut … 1 wide. A fraction rather than an angle so
        /// a caller cannot accidentally send radians to a servo that wanted
        /// the other convention; `mouthTarget` does that conversion, once.
        public let mouth: Double

        public init(command: DuckCommand, mouth: Double) {
            self.command = command
            self.mouth = mouth
        }

        /// Standing still, looking straight ahead, beak shut. What a
        /// performance starts from and what it must come back to.
        public static let neutral = Pose(command: DuckCommand(), mouth: 0)

        /// The mouth joint angle this fraction means, clamped to travel by
        /// `DuckModel`.
        public var mouthTarget: Double { DuckModel.mouthTarget(open: mouth) }
    }

    /// A pose at a moment, as the tables are written. Everything defaults to
    /// zero — the neutral duck — so a keyframe names only what moves, which
    /// is what makes the tables below readable as choreography rather than as
    /// twelve columns of mostly zeroes.
    public struct Keyframe: Equatable, Sendable {
        /// Seconds from the start of the part this keyframe belongs to.
        public let time: Double
        /// Twist: forward m/s, left m/s, yaw rad/s. Zero on every sound but
        /// `wheee` — a noise is a gesture, not a drive command.
        public let forward: Double
        public let left: Double
        public let yaw: Double
        /// Head commands, radians. See this file's sign convention.
        public let neckPitch: Double
        public let headPitch: Double
        public let headYaw: Double
        public let headRoll: Double
        /// Standing body-pose offsets. Metres for z, radians for the angles.
        public let bodyZ: Double
        public let bodyRoll: Double
        public let bodyPitch: Double
        /// Beak opening, 0…1.
        public let mouth: Double

        public init(
            time: Double,
            forward: Double = 0, left: Double = 0, yaw: Double = 0,
            neckPitch: Double = 0, headPitch: Double = 0,
            headYaw: Double = 0, headRoll: Double = 0,
            bodyZ: Double = 0, bodyRoll: Double = 0, bodyPitch: Double = 0,
            mouth: Double = 0
        ) {
            self.time = time
            self.forward = forward
            self.left = left
            self.yaw = yaw
            self.neckPitch = neckPitch
            self.headPitch = headPitch
            self.headYaw = headYaw
            self.headRoll = headRoll
            self.bodyZ = bodyZ
            self.bodyRoll = bodyRoll
            self.bodyPitch = bodyPitch
            self.mouth = mouth
        }

        /// This keyframe as a pose, with nothing interpolated.
        public var pose: Pose { DuckPerformance.blend(self, self, 0) }
    }

    /// A part's choreography: keyframes, linearly interpolated, clamped at
    /// both ends. Sampling before zero or after the end gives the first or
    /// last pose rather than extrapolating — a performance that runs long
    /// because a frame arrived late must hold its last pose, never invent a
    /// pose past it.
    public struct Timeline: Equatable, Sendable {
        public let sound: DuckSound
        public let part: DuckSound.Part
        public let keyframes: [Keyframe]

        /// The length of the part, from `DuckSound` — never a separate
        /// number, so a timeline cannot disagree with the audio it is
        /// choreographing.
        public var duration: Double { sound.duration(of: part) }

        public init(sound: DuckSound, part: DuckSound.Part, keyframes: [Keyframe]) {
            precondition(!keyframes.isEmpty, "a timeline needs at least one keyframe")
            precondition(keyframes[0].time == 0, "a timeline starts at zero")
            for index in 1..<max(keyframes.count, 1) {
                precondition(keyframes[index].time >= keyframes[index - 1].time,
                             "keyframes must be in time order")
            }
            precondition(keyframes[keyframes.count - 1].time <= sound.duration(of: part) + 1e-9,
                         "a timeline cannot run past the part it choreographs")
            self.sound = sound
            self.part = part
            self.keyframes = keyframes
        }

        /// The pose at a time in seconds from the start of the part.
        ///
        /// A non-finite time — a clock that came back from a background stall
        /// with a NaN in it — reads as the opening pose rather than as an
        /// index nobody checked.
        public func pose(at time: Double) -> Pose {
            guard let first = keyframes.first, let last = keyframes.last else { return .neutral }
            guard time > first.time else { return first.pose }  // also catches NaN
            guard time < last.time else { return last.pose }
            var index = 0
            while index + 1 < keyframes.count && keyframes[index + 1].time <= time {
                index += 1
            }
            let a = keyframes[index]
            let b = keyframes[index + 1]
            let span = b.time - a.time
            return DuckPerformance.blend(a, b, span > 0 ? (time - a.time) / span : 0)
        }
    }

    /// Linear blend of two keyframes, `u` from 0 (all `a`) to 1 (all `b`).
    /// Twelve channels blended in one place, so a channel cannot be forgotten
    /// in one code path and interpolated in another.
    static func blend(_ a: Keyframe, _ b: Keyframe, _ u: Double) -> Pose {
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * u }
        return Pose(
            command: DuckCommand(
                twist: (mix(a.forward, b.forward), mix(a.left, b.left), mix(a.yaw, b.yaw)),
                head: (mix(a.neckPitch, b.neckPitch), mix(a.headPitch, b.headPitch),
                       mix(a.headYaw, b.headYaw), mix(a.headRoll, b.headRoll)),
                bodyZ: mix(a.bodyZ, b.bodyZ),
                bodyRoll: mix(a.bodyRoll, b.bodyRoll),
                bodyPitch: mix(a.bodyPitch, b.bodyPitch)),
            mouth: mix(a.mouth, b.mouth))
    }

    // ── the choreography ─────────────────────────────────────────────────

    /// The timeline for a part. `.whole` of a held tag is its three parts
    /// laid end to end — start, one loop, end — with the duplicated seam
    /// keyframes dropped, so a preview and a real ride move identically.
    public static func timeline(for sound: DuckSound, part: DuckSound.Part = .whole) -> Timeline {
        precondition(sound.supports(part), "\(sound.tag) has no \(part.rawValue) part")
        guard sound.isHeld, part == .whole else {
            return Timeline(sound: sound, part: part, keyframes: keyframes(of: sound, part: part))
        }
        var joined = keyframes(of: sound, part: .start)
        var offset = sound.duration(of: .start)
        for piece in [DuckSound.Part.loop, .end] {
            let frames = keyframes(of: sound, part: piece)
            for frame in frames.dropFirst() {
                joined.append(shifted(frame, by: offset))
            }
            offset += sound.duration(of: piece)
        }
        return Timeline(sound: sound, part: .whole, keyframes: joined)
    }

    /// The pose at `elapsed` seconds into a straight-through play of `sound`
    /// — the tag-and-a-clock form, which is all an AR ghost needs. For a held
    /// tag this is the shortest complete ride: start, one loop, end. Anything
    /// longer is a `Playback`, because a longer ride is a question about
    /// holds, and holds have a state machine.
    public static func pose(_ sound: DuckSound, elapsed: Double) -> Pose {
        var playback = Playback(sound, at: 0)
        if sound.isHeld {
            playback.release(at: sound.duration(of: .start) + sound.duration(of: .loop))
        }
        return playback.pose(at: elapsed)
    }

    static func shifted(_ frame: Keyframe, by offset: Double) -> Keyframe {
        Keyframe(
            time: frame.time + offset,
            forward: frame.forward, left: frame.left, yaw: frame.yaw,
            neckPitch: frame.neckPitch, headPitch: frame.headPitch,
            headYaw: frame.headYaw, headRoll: frame.headRoll,
            bodyZ: frame.bodyZ, bodyRoll: frame.bodyRoll, bodyPitch: frame.bodyPitch,
            mouth: frame.mouth)
    }

    /// The pose `wheee` holds at the seams — the last instant of the start,
    /// every instant the loop begins and ends on, and the first instant of
    /// the end. Written once because it must be identical in all four places
    /// or the ride jumps every time the loop comes round.
    static let rideSeam = Keyframe(
        time: 0, yaw: 0.60, neckPitch: -0.26, headYaw: 0.10, bodyZ: 0.018, mouth: 0.80)

    /// The seven performances.
    ///
    /// Timings are the `DuckSound` tick counts, so a gesture cannot outlast
    /// the noise that motivates it. Every table opens and closes on the
    /// neutral pose, which is what makes a sound safe to interrupt: whenever
    /// it ends, however it ends, the duck is standing still again.
    static func keyframes(of sound: DuckSound, part: DuckSound.Part) -> [Keyframe] {
        switch sound {
        case .alarm:
            // A startle: 40 ms to snap the head back and the beak wide, then
            // a long fall back. The fastest thing the duck does.
            return [
                Keyframe(time: 0.00),
                Keyframe(time: 0.04, neckPitch: -0.24, headPitch: -0.18, bodyZ: 0.015, mouth: 0.95),
                Keyframe(time: 0.18, neckPitch: -0.20, headPitch: -0.14, bodyZ: 0.010, mouth: 0.55),
                Keyframe(time: 0.40),
            ]

        case .greet:
            // Two beak openings, because `greet` is the tag that can come out
            // as a wak-wak. The voice decides that on a coin flip and this
            // table cannot see the coin — deliberately: a beak that opens
            // without a syllable reads as a duck about to speak, and a
            // syllable with a shut beak reads as a broken robot.
            return [
                Keyframe(time: 0.00),
                Keyframe(time: 0.06, neckPitch: -0.18, mouth: 0.85),
                Keyframe(time: 0.20, neckPitch: -0.20, mouth: 0.15),
                Keyframe(time: 0.30, neckPitch: -0.22, headYaw: 0.06, mouth: 0.80),
                Keyframe(time: 0.44, neckPitch: -0.14, headYaw: 0.04, mouth: 0.10),
                Keyframe(time: 0.60),
            ]

        case .inquire:
            // The head tilt. It is the tilt that makes it a question — the
            // rising pitch alone reads as a squeak.
            return [
                Keyframe(time: 0.00),
                Keyframe(time: 0.10, headYaw: 0.12, headRoll: 0.22, mouth: 0.35),
                Keyframe(time: 0.28, neckPitch: -0.10, headYaw: 0.18, headRoll: 0.28, mouth: 0.60),
                Keyframe(time: 0.50),
            ]

        case .peck:
            // Beak to the floor and shut on contact: the mouth closing at
            // 0.12 s is the tock. The recovery takes exactly as long as the
            // strike, 0.12 s each, which is what makes it a peck and not a
            // twitch.
            return [
                Keyframe(time: 0.00),
                Keyframe(time: 0.06, neckPitch: 0.30, headPitch: 0.22, mouth: 0.50),
                Keyframe(time: 0.12, neckPitch: 0.42, headPitch: 0.32, mouth: 0.00),
                Keyframe(time: 0.24),
            ]

        case .chirp:
            // The small one. A bob and a beak, nothing else.
            return [
                Keyframe(time: 0.00),
                Keyframe(time: 0.05, neckPitch: -0.12, mouth: 0.70),
                Keyframe(time: 0.16, neckPitch: -0.08, mouth: 0.25),
                Keyframe(time: 0.30),
            ]

        case .coo:
            // Drowsy: everything slow and small, the body settling by just
            // over a centimetre, the beak barely parted.
            return [
                Keyframe(time: 0.00),
                Keyframe(time: 0.25, neckPitch: 0.10, headRoll: 0.15, bodyZ: -0.008, mouth: 0.18),
                Keyframe(time: 0.60, neckPitch: 0.12, headRoll: 0.18, bodyZ: -0.012, mouth: 0.12),
                Keyframe(time: 1.00),
            ]

        case .wheee:
            switch part {
            case .start:
                // The only twist any performance commands. 0.60 rad/s is a
                // slow spin — a full turn takes 2π/0.6 ≈ 10.5 s — and it is
                // twelve times `DuckModel.standingThreshold`, so there is no
                // ambiguity about which policy is running during a ride.
                return [
                    Keyframe(time: 0.00),
                    Keyframe(time: 0.10, yaw: 0.30, neckPitch: -0.20, bodyZ: 0.012, mouth: 0.60),
                    shifted(rideSeam, by: 0.24),
                ]
            case .loop:
                // A head sweep, right round and back, over the 0.5 s loop.
                // First and last keyframes are the same seam pose, so the
                // loop can repeat without a jump — the same rule the voice's
                // loop obeys, for the same reason.
                return [
                    rideSeam,
                    Keyframe(time: 0.125, yaw: 0.60, neckPitch: -0.26, headYaw: 0.34,
                             bodyZ: 0.018, mouth: 0.80),
                    shifted(rideSeam, by: 0.25),
                    Keyframe(time: 0.375, yaw: 0.60, neckPitch: -0.26, headYaw: -0.16,
                             bodyZ: 0.018, mouth: 0.80),
                    shifted(rideSeam, by: 0.50),
                ]
            case .end:
                // The landing, and the important half-second in this file:
                // whether the rider let go or the deadman fired, the twist
                // comes back to zero before the tag is over. A ride that
                // decays must not leave the duck spinning.
                return [
                    rideSeam,
                    Keyframe(time: 0.18, yaw: 0.25, neckPitch: -0.12, headYaw: 0.04,
                             bodyZ: 0.008, mouth: 0.35),
                    Keyframe(time: 0.36),
                ]
            case .whole:
                preconditionFailure("a held sound's .whole timeline is assembled from its parts")
            }
        }
    }

    // ── hold and decay ───────────────────────────────────────────────────

    /// Where a performance is right now: which part is sounding and how far
    /// into it, or nothing.
    public enum Stage: Equatable, Sendable {
        case playing(DuckSound.Part, elapsed: Double)
        /// The tag is over and the duck is back at neutral.
        case finished

        /// The sounding part, or nil when finished.
        public var part: DuckSound.Part? {
            if case .playing(let part, _) = self { return part }
            return nil
        }

        public var isFinished: Bool { self == .finished }
    }

    /// One playing sound, with the robot's hold-and-decay rules in it.
    ///
    /// THE DEADMAN IS THE WHOLE POINT. A held tag keeps looping while holds
    /// keep arriving and ends on its own about half a second after they stop
    /// (`DuckSound.holdDeadline`), which is what happens when a phone is
    /// backgrounded, loses Wi-Fi, or goes in the pond. Modelling that here —
    /// rather than trusting the robot and animating something else — means
    /// the ghost stops when the duck stops, and it means the decay path is
    /// testable on a machine with no duck attached.
    ///
    /// Times are seconds on whatever monotonic clock the caller is already
    /// using (`CACurrentMediaTime`, a `DuckClock` accumulation, a test's
    /// literal). This type never reads a clock itself: it has no opinion
    /// about what time it is, only about what follows from the times it is
    /// given, which is why it can be driven a thousand ticks in a loop.
    public struct Playback: Equatable, Sendable {
        public let sound: DuckSound
        public let startedAt: Double
        /// When the most recent hold arrived. For a one-shot, the start.
        public private(set) var lastHoldAt: Double
        /// When the rider let go, if they did. Nil means the sound is either
        /// still held or already decaying towards its deadman.
        public private(set) var releasedAt: Double?

        public init(_ sound: DuckSound, at now: Double) {
            self.sound = sound
            self.startedAt = now
            self.lastHoldAt = now
            self.releasedAt = nil
        }

        /// I still want this sound. Send one about every
        /// `DuckSound.holdInterval` — five per deadman window, so four lost
        /// in a row still keep the ride alive.
        ///
        /// A hold on a one-shot does nothing, on purpose: robotd will not
        /// extend a `chirp` either, and a UI that holds a button down over
        /// the wrong tag should behave like the robot rather than crash.
        /// Holds that arrive out of order never move the deadline backwards.
        public mutating func hold(at now: Double) {
            guard sound.isHeld, releasedAt == nil else { return }
            lastHoldAt = max(lastHoldAt, now)
        }

        /// I am done — end it now rather than waiting out the deadman. Never
        /// cuts the start part short: the duck has already drawn breath, so
        /// the earliest an end can begin is when the loop would have.
        public mutating func release(at now: Double) {
            guard sound.isHeld, releasedAt == nil else { return }
            releasedAt = max(now, loopBegins)
        }

        /// When the loop takes over from the start part.
        public var loopBegins: Double {
            sound.isHeld ? startedAt + sound.duration(of: .start) : startedAt
        }

        /// When the end part begins: either where the rider let go, or half a
        /// second after the last hold — whichever comes first, and never
        /// before the start part has finished. For a one-shot there is no end
        /// part, so this is simply when the sound is over.
        public var endBegins: Double {
            guard sound.isHeld else { return startedAt + sound.duration(of: .whole) }
            return max(loopBegins, releasedAt ?? (lastHoldAt + DuckSound.holdDeadline))
        }

        /// What is sounding at `now`, and how far into it.
        public func stage(at now: Double) -> Stage {
            guard sound.isHeld else {
                let whole = sound.duration(of: .whole)
                let elapsed = now - startedAt
                return elapsed < whole ? .playing(.whole, elapsed: max(elapsed, 0)) : .finished
            }
            if now < loopBegins { return .playing(.start, elapsed: max(now - startedAt, 0)) }

            let ends = endBegins
            if now < ends {
                // Where in the loop this instant falls. The loop has been
                // running since the start part handed over, however many
                // times round that is.
                let length = sound.duration(of: .loop)
                return .playing(.loop, elapsed: (now - loopBegins).truncatingRemainder(dividingBy: length))
            }
            if now < ends + sound.duration(of: .end) {
                return .playing(.end, elapsed: now - ends)
            }
            return .finished
        }

        /// The pose at `now`. Finished means neutral — standing still, beak
        /// shut, nothing commanded — which is the property that makes a
        /// decayed ride safe.
        public func pose(at now: Double) -> Pose {
            switch stage(at: now) {
            case .finished:
                return .neutral
            case .playing(let part, let elapsed):
                return DuckPerformance.timeline(for: sound, part: part).pose(at: elapsed)
            }
        }

        /// Whether this sound is over at `now`. A caller polling at 50 Hz
        /// drops the playback the first time this is true.
        public func isFinished(at now: Double) -> Bool {
            stage(at: now).isFinished
        }
    }
}
