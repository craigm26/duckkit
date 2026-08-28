import Foundation

/// How often a motion actually works.
///
/// WHY A RECORDING CANNOT ANSWER THIS. A clip is one run. "Ends toppled" says
/// what happened that time and nothing about whether it happens every time, and
/// a screen that printed a success rate from a single recording would be
/// printing 0% or 100% and calling it a measurement. The only way to get a rate
/// is to run the thing repeatedly under conditions that vary, which is what
/// `measure_success.mjs` does in MuJoCo and what this reads back.
///
/// THE DISTRIBUTION IS POLLEN'S, NOT ONE THIS PROJECT INVENTED. A robustness
/// number means nothing without saying robust to WHAT, so the ranges are read
/// out of `microduck_velocity_env_cfg.py`: the drop height, the footpad
/// friction scale, the shove, and the trunk's centre of mass. Those are the
/// perturbations the policies were trained against, which makes the rate a
/// measurement of the same thing training was optimising.
///
/// TWO RATES, BECAUSE THERE ARE TWO QUESTIONS. `achieves` asks whether the move
/// did what it is FOR — a stair move that ends neatly upright on the floor has
/// failed, however tidy it looks. `repeats` asks only whether it did again what
/// it did the day it was recorded, which is what says whether the clip on file
/// is representative or a lucky take. They come apart badly on exactly the
/// clips that matter, and a single "success rate" would have to pick one
/// silently.
public struct DuckIntentSuccess: Equatable, Sendable {

    public struct Outcome: Equatable, Sendable {
        public let rollouts: Int
        /// Rollouts that met the stated criterion.
        public let achieves: Int
        /// The criterion, in words, so a rate can be read as "how often did it
        /// do THAT" rather than as an unqualified score.
        public let criterion: String
        /// Rollouts that ended in the same posture as the recording.
        public let repeats: Int
        public let recordedEnding: String?
        /// Rollouts MuJoCo could not finish — an extreme contact impulse taking
        /// the state to NaN. Counted separately because it is neither a success
        /// nor a failure of the move; Pollen's config terminates on it too.
        public let unstable: Int
        /// Where the trunk ended up, metres.
        public let medianHeight: Double?
        public let worstHeight: Double?
        /// How the rollouts ended, by posture.
        public let endings: [String: Int]

        public var achievedFraction: Double {
            rollouts > 0 ? Double(achieves) / Double(rollouts) : 0
        }
        public var repeatedFraction: Double {
            rollouts > 0 ? Double(repeats) / Double(rollouts) : 0
        }
    }

    /// What was varied between rollouts, in words a person can check against
    /// the config it came from.
    public struct Randomisation: Equatable, Sendable {
        public let source: String
        public let lines: [String]
    }

    public let rollouts: Int
    public let randomisation: Randomisation
    public let intents: [String: Outcome]

    public subscript(intent: String) -> Outcome? { intents[intent] }

    public enum LoadError: Error, Equatable { case missingResource, malformed(String) }

    public static func bundled() throws -> DuckIntentSuccess {
        guard let url = Bundle.module.url(forResource: "intent-success", withExtension: "json") else {
            throw LoadError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> DuckIntentSuccess {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["intents"] as? [String: Any] else {
            throw LoadError.malformed("expected an intents object")
        }
        var out: [String: Outcome] = [:]
        for (name, value) in raw {
            guard let o = value as? [String: Any],
                  let rollouts = o["rollouts"] as? Int else {
                throw LoadError.malformed("\(name) has no rollout count")
            }
            out[name] = Outcome(
                rollouts: rollouts,
                achieves: o["achieves"] as? Int ?? 0,
                criterion: o["criterion"] as? String ?? "",
                repeats: o["repeats"] as? Int ?? 0,
                recordedEnding: o["recordedEnding"] as? String,
                unstable: o["unstable"] as? Int ?? 0,
                medianHeight: o["medianHeight"] as? Double,
                worstHeight: o["worstHeight"] as? Double,
                endings: o["endings"] as? [String: Int] ?? [:])
        }
        let r = root["randomisation"] as? [String: Any] ?? [:]
        func span(_ key: String) -> String {
            guard let pair = r[key] as? [Double], pair.count == 2 else { return "—" }
            return "\(pair[0]) to \(pair[1])"
        }
        return DuckIntentSuccess(
            rollouts: root["rollouts"] as? Int ?? 0,
            randomisation: Randomisation(
                source: r["source"] as? String ?? "unknown",
                lines: [
                    "Drop height \(span("dropHeightMetres")) m",
                    "Footpad friction × \(span("footFrictionScale"))",
                    "A shove of \(span("pushMetresPerSecond")) m/s, every \(span("pushIntervalSeconds")) s",
                    "Trunk centre of mass \(span("trunkCentreOfMassMetres")) m",
                ]),
            intents: out)
    }
}
