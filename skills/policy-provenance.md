# Skill: Policy Provenance

## When to Use

- Showing a user whether the policy they loaded is an official Pollen release
- Recording *which* network ran, in a diary, a match record or a share card
- Building a screen that imports `.onnx` files from anywhere
- A user asks "is this file safe?" — read the last section before answering

## Quick Check

The identity of a policy is `DuckPolicy.fingerprint` — SHA-256 over its
parameters. Never the file's digest, never its filename, never where it came
from.

---

## Why Not the File

Two ONNX exports of the same learned map differ in producer string, initializer
names, opset version and the order the graph lists its nodes. Hashing the file
calls them different policies — wrong, and wrong in the direction that makes
Pollen's own re-release look suspicious for no reason. A file can also be
byte-identical everywhere except one weight, which is a different robot.

The parameters are exactly the thing whose change matters.

```swift
import DuckKit
import DuckEvidence     // fingerprint is an extension declared here

let policy = try DuckPolicy.load(contentsOf: url)
policy.fingerprint          // 64 lowercase hex chars — what gets signed
policy.shortFingerprint     // first 16 — what goes on a screen
policy.fingerprintRecord    // a CanonicalValue, ready to chain or sign
```

### The byte order is the contract

`DuckPolicy.canonicalParameterBytes` (in `DuckKit`, free, no crypto) writes:
the normalizer mean, then the normalizer std, then for each layer
outermost-first its weights and then its biases. Every value is a little-endian
IEEE-754 binary32 — the same four bytes on the Pi and the phone, with no host
byte order to get wrong. 197,896 floats, 791,584 bytes.

That order is written down rather than left to whatever `layers` happens to
iterate as, because it is the thing a second implementation has to reproduce.

The split — bytes in `DuckKit`, digest in `DuckEvidence` — exists so a soundboard
app gets the bytes for free and links no TLS library.

---

## The Manifest

`DuckOfficialPolicies` records the **nine** networks Pollen have released, by
fingerprint:

| Filename as vendored here | Does |
|---|---|
| `alpha_walking.onnx` | Walking at a commanded velocity — the default gait |
| `BEST_alpha_stand.onnx` | Standing still and staying there |
| `BEST_alpha_sitstand.onnx` | Sitting down and getting back up |
| `alpha_ground_pick.onnx` | Reaching the mouth down to just above the ground, and standing back up. **It does not pick anything up** — see below |
| `ball_kick_left.onnx` / `ball_kick_right.onnx` | Kicking |
| `roulade.onnx` | A forward roll |
| `BEST_roller.onnx` | Rolling on skate wheels |
| `BEST_roller_crouch.onnx` | Crouching low while rolling |

### Ground pick does not pick anything up

Upstream's own docstring: the policy "crouches to bring its mouth tip AS CLOSE
AS POSSIBLE to the ground WITHOUT touching it ... then returns to a clean
standing pose". A strong head-impact penalty sits against the reach reward, and
the equilibrium between them is a mouth hovering just above the floor. There is
no grasp in it, and there could not be: **the mouth is the fifteenth servo and
no policy drives it** — all seven alpha networks are 61→14, and the mouth is the
one joint they do not command.

What upstream DOES model is carrying something. `sample_mouth_payload` draws
**10–40 g** per episode and `mouth_payload_force` applies it at the mouth tip
through the rise, so lifting a light object is inside the training distribution.
The grasp itself is yours to command on joint 9.

Three numbers worth having, measured through this package's kinematics over our
own recording of the policy rather than read off the config:

| | |
|---|---|
| Mouth tip at its lowest, open | **34.9 mm** above the floor, at **1.16 s** |
| Within 5 mm of that low point | **0.76 s – 1.50 s** — the window a grasp has to land in |
| Mouth tip with the jaw shut, at that instant | **20.0 mm** — anything thinner passes under the bite |

**The measurement disagrees with the config, and the measurement is the one to
use.** The env's reward schedule calls phase 0.375–0.425 the low hold — 1.50 s
to 1.70 s — but the plant bottoms out at 1.16 s and is already climbing by
1.50 s. Close the jaw on the config's window and you close it on the way up.

The jaw body and its `mouth_tip` site are OURS, derived from where the mouth
servo sits, because upstream's mesh does not split the head. The 20 mm is only
as good as that derivation.

`filename` is **a hint for display, never an identity** — four of the nine differ
from upstream's shipping names. The fingerprint is the identity.

```swift
switch DuckOfficialPolicies.standing(of: policy) {
case .released(let release):  show(release.purpose)
case .unrecognised:           show(DuckOfficialPolicies.summary(for: .unrecognised))
}
```

`standing(ofFingerprint:)` asks the same question of a fingerprint recorded
earlier, so a stored record can be re-checked without the file it describes.

**Regenerate this table, never retype it.** `duck-studio`'s `PrintFingerprints`
prints it from the policy files themselves; a hand-edited digest is wrong in a
way nothing detects until it wrongly marks a real release unrecognised.

---

## What a Match Proves, and What It Does Not

A match proves the parameters are bit-identical to a release recorded in this
build. It does **not** prove the file is safe, current, or suited to any
particular robot.

A miss proves only that this table has not seen those weights. Someone's own good
training run is a miss. So is a Pollen release newer than this build.

That is why the vocabulary is `released` / `unrecognised` and not
trusted / untrusted, and why `summary(for:)` exists — copy that says "unknown to
this build" rather than implying a judgement about the file. **Use it. Do not
write your own sentence.**

---

## Why "Official" Cannot Be a Label

An app that shows "Official" because a file arrived in its own bundle is telling
the user where the file came from, not what it is. Those diverge immediately:

- A policy downloaded from Pollen's own Hugging Face repo **is official and is
  not bundled**.
- A file someone renames to `alpha_walking.onnx` and AirDrops over **is
  bundled-shaped and is not official**.

The only claim worth making is one the phone can check, offline, against
something it already holds — which is what the fingerprint table is.

---

## Recording What Ran

For a diary entry or a match record, chain or sign `fingerprintRecord` rather
than a filename. `DuckState.policy` carries the daemon's own policy *string*
verbatim, which is a different fact: it says what the robot said it was running,
not what the parameters were. Record both when you have both; they answer
different questions and only one of them is checkable.

See `skills/evidence-and-signing.md` for the chain and the signature.

---

## Common Mistakes

**Importing only `DuckEvidence`.** `fingerprint` is an extension on
`DuckPolicy`, so you need both modules imported at the use site.

**Truncating to fewer than 16 characters for comparison.** `shortFingerprint` is
for a screen. Machines compare the full 64.

**Calling an unrecognised policy dangerous.** See above — it is a statement about
this table, not about the file.

**Fingerprinting before loading.** `canonicalParameterBytes` only exists on a
loaded `DuckPolicy`, which means the architecture was already validated. A file
that cannot load has no fingerprint, and `DuckPolicy.describe` is what you show
instead — see `skills/running-a-policy.md`.
