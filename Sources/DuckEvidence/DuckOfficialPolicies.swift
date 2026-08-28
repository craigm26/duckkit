import Foundation
import DuckKit

/// Which policies Pollen Robotics actually released, by fingerprint.
///
/// WHY A MANIFEST AND NOT A LABEL. An app that shows "Official" because a file
/// arrived in its own bundle is telling the user where the file came from, not
/// what it is. Those diverge immediately: a policy downloaded from Pollen's own
/// Hugging Face repo is official and is not bundled; a file someone renames to
/// `alpha_walking.onnx` and AirDrops over is bundled-shaped and is not. The
/// only claim worth making is one the phone can check, offline, against
/// something it already holds.
///
/// SO THE KEY IS THE PARAMETER FINGERPRINT, NOT THE FILE. `DuckPolicy`'s
/// `fingerprint` digests the trained numbers in a fixed order and nothing else,
/// which is what makes this table survive the things that change without
/// changing the network — a re-export under a newer opset, a different producer
/// string, initializers renamed, the graph's nodes emitted in another order. A
/// file digest calls every one of those a different policy, and would mark
/// Pollen's own re-release as unknown. Change one weight, though, and the
/// fingerprint moves, which is exactly the case that must not pass.
///
/// WHAT A MATCH PROVES, AND WHAT IT DOES NOT. A match proves the parameters are
/// bit-identical to a release recorded here. It does NOT prove the file is
/// safe, current, or suited to any particular robot, and a MISS proves only
/// that this table has not seen those weights — someone's own good training run
/// is a miss, and so is a release newer than this build. The vocabulary below
/// is deliberately `released` / `unrecognised` rather than trusted / untrusted:
/// this table knows about provenance and has no opinion about quality.
public enum DuckOfficialPolicies {

    /// One policy Pollen have released.
    public struct Release: Equatable, Sendable {
        /// The filename upstream ships it under. A hint for display, never an
        /// identity — the fingerprint is the identity.
        public let filename: String
        /// SHA-256 over `DuckPolicy.canonicalParameterBytes`, lowercase hex.
        public let fingerprint: String
        /// One line about what the network does.
        public let purpose: String
    }

    /// What this table can say about a policy in front of it.
    public enum Standing: Equatable, Sendable {
        /// The parameters match a recorded Pollen release.
        case released(Release)
        /// Loadable, and these weights are not in this table. NOT an accusation:
        /// a policy somebody trained themselves lands here, and so does a Pollen
        /// release newer than this build.
        case unrecognised
    }

    /// The nine networks shipped with the robot, fingerprinted from the files
    /// vendored out of `pollen-robotics/microduck`.
    ///
    /// REGENERATE, NEVER RETYPE. `duck-studio`'s `PrintFingerprints` prints this
    /// table from the policy files themselves; a hand-edited digest is a digest
    /// that is wrong in a way nothing detects until it wrongly marks a real
    /// release unrecognised.
    public static let releases: [Release] = [
        Release(filename: "alpha_walking.onnx",
                fingerprint: "da820b718aa8bdb3317c018afba3ad3f461e0cf42256811c204dc005546ec4a3",
                purpose: "Walking, at a commanded velocity. The default gait."),
        Release(filename: "BEST_alpha_stand.onnx",
                fingerprint: "1157f7e7f9e88b2e61070a0f28833ff02bdf89799583434e69914affb170c0ce",
                purpose: "Standing still and staying there."),
        Release(filename: "BEST_alpha_sitstand.onnx",
                fingerprint: "85fa1fc2331baf003575a96a7dbf2222cf7ca10aef9c17372cf0b92ef42199e2",
                purpose: "Sitting down and getting back up, on a commanded flag."),
        Release(filename: "alpha_ground_pick.onnx",
                fingerprint: "8416d82f6125b70823611c61362225febe32a1bc0b24d7ab641becfdbf711f6a",
                purpose: "Reaching down to pick something up, driven by a phase clock."),
        Release(filename: "ball_kick_left.onnx",
                fingerprint: "e304692d7920d4b438d78b9a98ba6927820f5505a477827b67232acf8f05746e",
                purpose: "Kicking with the left foot."),
        Release(filename: "ball_kick_right.onnx",
                fingerprint: "ed14d95cac9f79a2683dc49f65ff837a061329eebd7f9f23c7ae6c0adfb0db41",
                purpose: "Kicking with the right foot."),
        Release(filename: "roulade.onnx",
                fingerprint: "cd76e0b8590114206e435905d819c8d7eefb686098ef211d506b9742efd8b3a3",
                purpose: "A forward roll, tipping over and coming back upright."),
        Release(filename: "BEST_roller.onnx",
                fingerprint: "710ccbdafd8583e3b96660bdfa441b658500305462de0b52a7e5d922a83ec8ce",
                purpose: "Rolling on the skate wheels instead of walking."),
        Release(filename: "BEST_roller_crouch.onnx",
                fingerprint: "d13112dfe0c3b43cbbd7f3b219c6be2a5dcf21ccd490eae2028a915ce234c081",
                purpose: "Crouching low while rolling, to get under things."),
    ]

    /// Fingerprint to release, built once.
    static let byFingerprint: [String: Release] = Dictionary(
        uniqueKeysWithValues: releases.map { ($0.fingerprint, $0) })

    /// What this table can say about a loaded policy.
    public static func standing(of policy: DuckPolicy) -> Standing {
        byFingerprint[policy.fingerprint].map(Standing.released) ?? .unrecognised
    }

    /// The same question asked of a fingerprint that was recorded earlier —
    /// so a stored record can be re-checked without the file it describes.
    public static func standing(ofFingerprint fingerprint: String) -> Standing {
        byFingerprint[fingerprint.lowercased()].map(Standing.released) ?? .unrecognised
    }

    /// The sentence to show a person, phrased so it does not overclaim.
    ///
    /// "Unrecognised" is not "untrusted". Somebody's own training run belongs in
    /// this app, and a release newer than this build will land here too, so the
    /// copy says what is actually known rather than implying a judgement about
    /// the file.
    public static func summary(for standing: Standing) -> String {
        switch standing {
        case .released(let release):
            return "Released by Pollen Robotics as \(release.filename). \(release.purpose)"
        case .unrecognised:
            return "Not one of the nine policies Pollen have released. That may mean it was "
                 + "trained by someone else, or that it is newer than this app knows about — "
                 + "this only says the weights are unfamiliar, not that they are bad."
        }
    }
}
