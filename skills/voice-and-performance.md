# Skill: Voice and Performance

## When to Use

- Making duck noises without shipping an audio asset
- Giving several ducks on one screen distinct voices
- Animating a body around a sound — the beak, the head, the little lean
- Implementing the held `wheee` ride, or a soundboard's button states

## Quick Check

Seven tags. Six are fire-and-forget; `wheee` is held and has a deadman. If your
code treats all seven the same, the ride will not stop when the phone does.

---

## The Seven Tags

`robot.sound` takes a string, and a string is the part that rots — send it
`"quack"` and nothing happens, no error comes back, and the bug looks like a dead
speaker rather than a typo. So the tags live in `DuckSound` once, as cases, with
`rawValue` *being* the wire string.

| Tag | Character | Ticks | Seconds |
|---|---|---|---|
| `alarm` | a sharp honk — the only loud one | 20 | 0.40 |
| `greet` | the wake-up quack, sometimes doubled | 30 | 0.60 |
| `inquire` | a rising question | 25 | 0.50 |
| `peck` | a low tock, more knock than voice | 12 | 0.24 |
| `chirp` | the ordinary content quack | 15 | 0.30 |
| `coo` | drowsy; the only one allowed to take its time | 50 | 1.00 |
| `wheee` | the ride — **held** | 12 / 25 / 18 | 0.24 / 0.50 / 0.36 |

`DuckSound.goodbye` is `peck`: an app about to ask for a power-off has one
obvious thing to say first, and every app should say the same one.

**The durations are ours, not Pollen's.** The voice bank is on the robot and not
in this repo, so nobody here can measure a real one. These are the lengths
DuckKit *plays* them at, quantised to the 50 Hz tick so a timeline always ends on
a tick boundary — and at 48 kHz that is 960 samples per tick exactly, so nothing
in the voice has to round. When hardware lands, measure the bank and correct the
tick counts; every timeline and every buffer follows from them.

---

## The Hold Protocol

Held is not "long". `coo` is the longest thing sent whole and is still
fire-and-forget. Held means the duck is waiting to hear from you again.

```
holdInterval  = 0.1 s   — re-send this often
holdDeadline  = 0.5 s   — robotd decays the sound this long after the last hold
holdsPerDeadline = 5    — so four consecutive lost packets still keep it running
```

That deadman is correct behaviour, not a bug to work around: it is what stops the
noise when a phone is backgrounded, walks out of Wi-Fi range, or is dropped in a
pond mid-ride.

`DuckPerformance.Playback` implements it once, and reimplementing it per app
produces four timers with four different off-by-a-frame bugs. One of those bugs
is interesting: a ride that decays while the body is still mid-spin leaves a
non-zero twist commanded and the duck quietly walks away from you. Every timeline
here returns to a zero twist and a neutral pose before it finishes.

```swift
var playback = DuckPerformance.Playback(.wheee, at: now)
playback.hold(at: now)        // every ~100 ms while the button is down
playback.release(at: now)     // or let the deadman take it
let pose = playback.pose(at: now)
```

`hold` on a one-shot does nothing, on purpose — robotd will not extend a `chirp`
either. `release` never cuts the start part short: the duck has already drawn
breath, so the earliest an end can begin is when the loop would have.

---

## Synthesis

There is no WAV to vendor, so `DuckVoice` computes one: a mono `[Float]` at
48 kHz with no AVFoundation, no asset, no licence question, and no download —
which also means it runs under `swift test` on a Pi.

```swift
let quack = DuckVoice.render(.chirp, part: .whole, seed: 1)
quack.samples      // [Float], clamped to ±1
quack.envelope     // [Float] 0…1, for a mouth or a meter
```

A quack is a reed, not a tone: a low fundamental (300 Hz for `peck` up to 700 Hz
at the top of the `wheee` ride) with many harmonics, the odd ones louder than the
even, tilted by `1/nᵈ` and pushed through one broad resonance around 1–2 kHz that
stands in for the bird's throat. The character is in the contour — a quack falls
(`chirp`, 560 → 430 Hz), a question rises (`inquire`, 360 → 640).

**What this is not:** a reproduction of the real duck. Nobody involved has heard
the real bank. It is a placeholder with the right shape, and when the hardware
lands the honest move is to compare and change the numbers here.

Determinism comes from an explicit seed through a SplitMix64 carried in the file,
never `Double.random`. Caveat worth stating: the tone is `sin` from libm, so two
different *platforms* can differ in the last bit. Determinism means "the same
machine gives the same answer forever" — which is why `DuckVoiceTests` pins
render-against-render rather than a golden constant.

---

## Every Duck Sounds Like Itself

Upstream's voice is a seedable synth: one integer derives a personality and the
robot seeds itself from its own SoC serial, so two Microducks on a table sound
like two animals.

```swift
let duck = DuckVoice.Personality(identifier: robotSerial)   // or (seed: 42)
let quack = DuckVoice.render(.chirp, part: .whole, seed: 1, as: duck)
```

**The derivation is a port; the synthesis is ours.** The generator
(xoshiro256++ through splitmix64), the draw order, the trait ranges, the harmonic
weighting and the CRC-32 variant hash come from upstream, where the file header
makes the stakes explicit: *"the generator IS the voice"* — a robot's bank is
re-rendered from its seed on every install, so a change to the arithmetic
re-voices the fleet silently. `DuckPersonalityTests` pins the stream against
values from a **second, independent implementation**, because a golden value
copied out of the code under test only proves the code has not changed.

What is **not** claimed: byte-parity with a real robot's audio. The traits for a
seed match; the waveform is ours; nothing has been checked against a real bank
because none exists yet.

**A personality never changes a length.** Every buffer stays a whole number of
50 Hz ticks whatever the traits say, because `DuckPerformance` choreographs
against those counts and a duck that stretched its own audio would slide out of
its own gestures. `speed` moves rates *inside* a sound — wobble, trill — never
its duration.

---

## Choreography

A sound is not a sound, it is a performance. `robot.sound` plays a tag through
the speaker; it moves nothing. Something still has to decide that the beak opens
on the quack and shuts a beat before it ends, that a `peck` puts the head on the
floor, that `inquire` tilts. That is ours to choose — and it lives in the kit
because there is going to be more than one app, and an AR ghost animating one set
of curves while the robot is driven by another is two ducks with the same name.

```swift
let pose = DuckPerformance.pose(.chirp, elapsed: t)
pose.command       // a DuckCommand — send it, or drive a ghost with it
pose.mouthTarget   // radians, via DuckModel.mouthTarget(open:)
```

**Sign convention, because nothing else settles it.** The MuJoCo model gives axes
and travel but not which way a positive `head_pitch` points the beak. These
tables assume positive neck/head pitch is beak-towards-the-floor, positive
`head_yaw` turns to the duck's left, positive `head_roll` leans right. If hardware
disagrees, negate that column in `keyframes(of:part:)` — the shapes and timings
stay right.

The head values are **commands**. `DuckObservation` feeds them to the policy
rather than adding them to its output, so what the joint finally does is the
network's business. That is why the tables stay well inside travel: the tests
check every keyframe both as an absolute angle and as an offset from home,
because we do not get to decide which one robotd means.

---

## Common Mistakes

**Greying out a sound button because the duck fell over.** No sound is ever
predicted refused. A duck on its side can still quack, and an app that hides the
quack at the moment its owner most wants to hear from it is lying about the
robot. Only the five *skills* are exclusive — `skills/talking-to-a-robot.md`.

**Rendering `.whole` and separately rendering the parts for a preview.**
`.whole` of a held tag *is* those three renderings concatenated, so a preview
button and the live hold path already play the same audio.

**Asking for a part a tag does not have.** `render` and `ticks(of:)` both
precondition on `sound.supports(part)`. Check it if a part is a parameter.

**Driving a long ride with `DuckPerformance.pose(_:elapsed:)`.** That is the
shortest complete ride — start, one loop, end. Anything longer is a question
about holds, and holds have a state machine: use `Playback`.
