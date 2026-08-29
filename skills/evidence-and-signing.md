# Skill: Evidence and Signing

## When to Use

- Making a claim about a duck that someone else should be able to check
- Signing, hash-chaining or canonicalising anything
- Storing a signing key, or being asked where it lives
- Recording a soccer match, a session total, or which policy ran

## Quick Check

Canonical bytes → chain → signature. Three steps in that order, and each one has
exactly one implementation in this package. Do not write a second.

---

## Canonical Bytes First

`rcan-canonical-json-v1`, deliberately boring:

- keys sorted lexicographically by Unicode code point, at every level
- no insignificant whitespace
- non-ASCII emitted as raw UTF-8, never `\uXXXX`
- whole-number floats normalised to integers (`50.0` → `50`), recursively
- booleans never coerced to numbers
- `{}`, `[]`, no trailing newline
- the `envelope_signature` key excluded to form the pre-image

**Why it is spelled out rather than left to `JSONEncoder`:** `JSONSerialization`
collapses `50` and `50.0` to the same bytes, does not promise key order, and
behaves differently between Apple and swift-corelibs Foundation. Either one
silently produces a signature the verifier cannot reproduce, and the symptom is
"verification fails on some records" — the worst possible bug to debug.

That is also why `CanonicalValue` distinguishes `.int(Int64)` from
`.double(Double)` and why `CanonicalJSONParser` exists at all: it parses over
Unicode scalars, preserving what the source text expressed.

---

## The Fold, and Only the Fold

```
head₀ = "GENESIS"
headᵢ = sha256_hex( utf8(headᵢ₋₁) ‖ canonical(recordᵢ) )
```

```swift
let head = DuckChain.head(of: records)
// or incrementally:
let next = DuckChain.head(after: previousHead, record: record)
```

Insert, drop or reorder a record and the head changes. Sign the head and the
whole sequence is pinned by one signature — which is what makes "your duck walked
1.2 km" a claim someone else can check rather than a number you typed.

The previous head is hashed as its **own UTF-8 bytes**, not decoded from hex: the
string is the value, and re-deriving it invites two implementations to disagree
about case.

`genesis` is a literal so an empty chain has a defined head rather than an empty
string that could be confused with a missing one.

### What deliberately did not move

OpenCastor's `Journal` chains over a `Receipt` — a record of a decision some
robot's gateway actually signed. That type means nothing to a duck's diary or a
soccer match, and dragging it across would let a phone-minted record wear the
shape of a gateway decision. **That is the one failure the whole evidence rail
exists to prevent: fabricated provenance in the artifact whose integrity is the
product.**

So the arithmetic is shared and the container is not. Each consumer keeps its own
namespace and its own record kinds.

---

## Signing

```swift
let kid = DuckSigning.kid(for: key.publicKey)          // "duck-" + 6 bytes hex
let signed = try DuckSigning.sign(record, with: key, kid: kid)
DuckSigning.verify(signedObject: signed, with: key.publicKey)   // Bool
```

The signature attaches under `envelope_signature` as `{"kid": …, "sig": …}`,
base64. `verify` returns **false rather than throwing** for every failure — a
malformed block, a missing one, unreadable base64 and a genuinely bad signature
are all the same answer to the only question being asked.

Crypto is swift-crypto, not CryptoKit: the same `Curve25519.Signing` API, but one
that compiles on Linux, so the signer under `swift test` on a Pi is the signer on
the phone.

---

## The Key

`SigningKeyStore` has two implementations behind one shape: Keychain on Apple,
in-memory on Linux.

The invariant is **the signing key is device-local, unlock-gated, and never syncs
off this device** — `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. That constant
does not exist on Linux, so `KeychainAccessibility` models it as an enum carrying
the constant's *name* as a plain string, which is what makes the posture
assertable under `swift test` on a machine with no Security framework.

Ed25519 cannot live in the Secure Enclave, and the type says so rather than
over-claiming.

---

## A Worked Example: A Match

`DuckSoccerMatch` is the shape to copy — an append-only, hash-chained,
Ed25519-signed record; a league table nobody can quietly edit.

```swift
var match = DuckSoccerMatch(participantRRNs: rrns, isPractice: false)
// … events appended …
let signed = try match.signedRecord(with: key, kid: kid)
DuckSoccerMatch.verify(signedRecord: signed, with: key.publicKey)
```

The referee is the phone: its signing identity signs the match, so a result is
`(participant RRNs, event chain, referee key)` — checkable by anyone holding the
public key, with no server, no account, and nothing collected.

The record carries `kind`, participants, `practice`, the events, the
`chain_head`, and the score. A goal names both the scorer and the **judging
authority** — `"phone-vision"` for the AR referee, `"human"` for a tap — because
those are different claims.

**Practice matches refuse to sign for export.** Any simulated participant marks
the match, and `signedRecord` throws `ExportRefusal.practiceMatchesStayOnDevice`
unless `allowPractice` is passed. A practice result signed like a real one is the
soccer version of a fabricated receipt; the same rule keeps demo fixtures from
becoming evidence.

---

## What Is Worth Signing Here

| Claim | Record |
|---|---|
| Which network ran | `DuckPolicy.fingerprintRecord` — `skills/policy-provenance.md` |
| What a session added up to | `DuckStateReducer.Totals`, all `Int64` |
| A match result | `DuckSoccerMatch.record` |

`DuckStateReducer` is built for this: every accumulator is `Int64`, because
summing 180,000 doubles gives an answer that depends on the order they were
summed in — so the app, the verifier and a reference script could each produce a
slightly different total and no two of them could ever be said to disagree about
anything meaningful.

---

## Common Mistakes

**Signing a struct through `JSONEncoder`.** Build a `CanonicalValue`. Anything
else silently re-orders keys or collapses `50.0`.

**Hashing a policy file to say which policy ran.** Use the parameter fingerprint.

**Putting the chain in `DuckKit`.** It needs SHA-256, which needs swift-crypto,
which brings BoringSSL — and DuckKit compiling without a dependency is the reason
the real network runs under `swift test` on a Pi. The pattern for a DuckKit thing
that must be hashed is `canonicalParameterBytes` in DuckKit and the digest in
`DuckEvidence`, as an extension.

**Reusing another product's record kind.** Keep your own namespace. That is the
whole reason `DuckChain` moved and `Journal` did not.

**Averaging away an anomaly.** A `DuckState` where every leaf is nil, a refused
stream line, a dropped clock second — count them and carry the count into the
record. A total that quietly excludes what it could not parse is a total that
lies with a signature on it.
