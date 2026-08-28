import Foundation

/// The five skills, and what happens when one of the twelve things a person can
/// press meets a robot that is already busy.
///
/// THE POINT OF THE TYPE IS THE SECOND COLUMN. Any app can hold a list of
/// names; what it cannot easily hold is the fact that pressing `kick_left`
/// takes the whole robot for half a second while pressing `chirp` takes a
/// speaker. `robotd` enforces that distinction — the skills are one-shot and
/// exclusive, and a second one arriving while a move is holding the robot is
/// refused, by an error that names the move already holding it — so an app
/// that does not model it produces a row of buttons that all look equally
/// pressable and are not.
///
/// The other seven names live next door in `DuckSound`, which knows far more
/// about them than a catalogue needs to. `DuckPress` is the union of the two:
/// twelve buttons, one type, so a companion sheet iterates rather than being
/// written out twice — and so the exclusivity rule is stated once, over both.
///
/// PREDICTING A REFUSAL IS A UI PROBLEM WITH A CORRECTNESS TRAP IN IT. Without
/// prediction, a button says "sent…" for one full round trip over a bridged
/// LAN and then admits it was refused, which is the worst of both: the user
/// has already pressed it twice. With naive prediction, a button greys itself
/// out on a stale or half-understood state and the robot becomes
/// unreachable through a UI that is certain it is busy — an unfalsifiable
/// interface, which is much worse than a wasted round trip.
///
/// So the rule here is one-sided on purpose: a press is predicted refused
/// ONLY on a field that is present and true. Silence predicts nothing.
/// `DuckState` makes every field optional precisely so that "the daemon
/// renamed `safety`" cannot arrive as `fallen: false`, and the same care runs
/// the other way here — a missing `safety` block must not arrive as "fine",
/// but neither may it grey out a button. When the state does not say, send it
/// and let the robot answer.
///
/// A SOUND IS A SPEAKER, NOT A BODY. No sound is ever predicted refused: a
/// duck lying on its side can still quack, and a companion app that greys out
/// the quack button because the duck fell over is lying about the robot at the
/// exact moment its owner most wants to hear from it. Whether `robotd` refuses
/// a sound in some state it has not published is its business; this file
/// refuses to guess.
///
/// The durations are `DuckModel`'s, not restated here. A skill's nominal
/// window and the policy that runs it are two views of one fact, and a second
/// copy of 0.5 is a copy that eventually disagrees with the network that was
/// trained against it.
public enum DuckSkill: String, CaseIterable, Equatable, Sendable {
    case groundPick = "ground_pick"
    case kickLeft = "kick_left"
    case kickRight = "kick_right"
    case sitToggle = "sit_toggle"
    case roulade = "roulade"

    /// The name the runtime knows it by, which is also this case's raw value.
    public var tag: String { rawValue }

    /// The network that runs while it does. The five skills map onto exactly
    /// the five non-locomotion policies `DuckPolicyKind` carries, which is
    /// what makes `holding(_:)` possible: the state stream reports a policy,
    /// not a skill, so the policy is the only evidence there is.
    public var policy: DuckPolicyKind {
        switch self {
        case .groundPick: return .groundPick
        case .kickLeft: return .kickLeft
        case .kickRight: return .kickRight
        case .sitToggle: return .sitStand
        case .roulade: return .roulade
        }
    }

    /// How long the move nominally takes, seconds, from `DuckModel`.
    ///
    /// Nil for `sitToggle`, which upstream publishes no duration for and which
    /// is not a window in the first place: it moves between two held poses,
    /// and the second of them lasts until somebody presses it again. A guessed
    /// number here would be a progress bar that lies.
    ///
    /// Ground pick's four seconds is upstream's *period* — one cycle of the
    /// pick — and not a promise that anything is in the beak at the end of it.
    public var nominalDuration: Double? {
        switch self {
        case .kickLeft, .kickRight: return DuckModel.kickDuration
        case .roulade: return DuckModel.rouladeDuration
        case .groundPick: return DuckModel.groundPickPeriod
        case .sitToggle: return nil
        }
    }

    /// The same window in control ticks, at `DuckModel.tickHz`: 25 for a kick,
    /// 50 for a roulade, 200 for a ground pick. Useful for anything counting
    /// the loop rather than the clock.
    public var nominalTicks: Int? {
        nominalDuration.map { Int(($0 * DuckModel.tickHz).rounded()) }
    }

    /// The skill a state shows as holding the robot, if any.
    ///
    /// SIT_TOGGLE IS DELIBERATELY EXCLUDED, and the reason is the sharpest
    /// argument for not treating "running policy" and "running move" as the
    /// same thing. `alpha_sitstand` is both the network that performs the
    /// toggle and — as far as this package can tell from a policy name — the
    /// network that keeps a seated duck seated afterwards. Treating it as a
    /// hold would grey out the one button that gets a sitting duck back on its
    /// feet, for as long as it sits, which is a robot rendered unusable by its
    /// own remote control. The cost of the exclusion is one wasted round trip
    /// if somebody double-presses sit during the toggle itself; the cost of
    /// including it is a duck that cannot stand up.
    public static func holding(_ state: DuckState) -> DuckSkill? {
        guard let kind = state.policyKind else { return nil }
        return allCases.first { $0 != .sitToggle && $0.policy == kind }
    }

    /// The skill named in a refusal's prose, if one is.
    ///
    /// `robotd` refuses a second exclusive move with an error that names the
    /// move already holding the robot, so the message usually contains one of
    /// these five tags. This reads it back — for a label, and only for a
    /// label. An error string is prose, not an API: it may be reworded in any
    /// release, so nothing may branch on this. When two tags appear, the
    /// earliest in the text wins, so the answer depends on the message rather
    /// than on the order the cases happen to be declared in.
    public static func mentioned(in text: String) -> DuckSkill? {
        var best: (skill: DuckSkill, at: String.Index)?
        for skill in allCases {
            guard let found = text.range(of: skill.tag) else { continue }
            if best == nil || found.lowerBound < best!.at {
                best = (skill, found.lowerBound)
            }
        }
        return best?.skill
    }
}

/// Something a person can press: one of the five skills or one of `DuckSound`'s
/// seven tags. Twelve buttons, one type, so a companion sheet can be built by
/// iterating rather than by being written out twice.
public enum DuckPress: Equatable, Sendable, CaseIterable {
    case skill(DuckSkill)
    case sound(DuckSound)

    /// Skills first, then sounds — the order a sheet lays them out in, and a
    /// stable one, because both underlying enumerations are declared in a
    /// fixed order.
    public static var allCases: [DuckPress] {
        DuckSkill.allCases.map(DuckPress.skill) + DuckSound.allCases.map(DuckPress.sound)
    }

    /// The runtime's name for it.
    public var tag: String {
        switch self {
        case .skill(let skill): return skill.tag
        case .sound(let sound): return sound.tag
        }
    }

    /// Whether this press takes the whole robot. True for every skill, false
    /// for every sound — the distinction the exclusivity rule is about.
    public var holdsTheRobot: Bool {
        switch self {
        case .skill: return true
        case .sound: return false
        }
    }

    /// How long this press is expected to hold the robot, for a press that
    /// holds it at all. Nil for every sound — not because a sound is
    /// instantaneous, but because how long it plays is a different question,
    /// and `DuckSound` is where that one is answered.
    public var nominalHold: Double? {
        switch self {
        case .skill(let skill): return skill.nominalDuration
        case .sound: return nil
        }
    }

    /// Why this press can be expected to come back refused — before it is
    /// sent, from the last state the robot published.
    ///
    /// Nil means "nothing known says no", which is not the same as yes: the
    /// robot is the only authority, and every one of these presses can still
    /// be refused for a reason no state field exposes. Pass nil for `state`
    /// when there is nothing recent to reason from — a fresh connection, or a
    /// state `DuckState.isStale(now:after:)` has already disqualified — and
    /// nothing will be predicted, which is the correct answer when the robot
    /// has not spoken lately.
    ///
    /// The order is fallen, limp, busy, and it is the order of causes: a duck
    /// that is both on its side and mid-roulade is on its side, and reporting
    /// the roulade would send someone to fix the wrong thing.
    public func predictedRefusal(given state: DuckState?) -> DuckRefusal? {
        guard holdsTheRobot, let state else { return nil }
        if state.safety?.fallen == true { return .fallen }
        if state.safety?.limp == true { return .limp }
        if let holder = DuckSkill.holding(state) { return .busy(holder) }
        return nil
    }
}

/// A refusal that can be predicted from a state, in the vocabulary a button
/// can use without a translation table.
public enum DuckRefusal: Equatable, Sendable {
    /// `safety.fallen` is true: the robot is down and a skill would be asking
    /// a body that is not under it to move.
    case fallen
    /// `safety.limp` is true: torque is off. Nothing will move until it is on.
    case limp
    /// An exclusive move is already holding the robot, and this is which one.
    /// Its `nominalDuration` is how long that is expected to last — half a
    /// second for a kick, four for a ground pick — which is the difference
    /// between a button that says "busy" and one that can say how long.
    case busy(DuckSkill)
}
