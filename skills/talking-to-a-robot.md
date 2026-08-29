# Skill: Talking to a Robot

## When to Use

- Reading `robotd`'s socket, or writing requests to it
- Decoding `robot.state` or `tof.frame`
- Deciding whether a button should be enabled before it is pressed
- Turning a session's stream into totals someone else can reproduce
- A user reports missing events, or a diary that says less happened than did

## Quick Check

`DuckRPC.StreamDecoder` owns the framing. Do not split reads on newlines
yourself — on a real network that silently loses about one message in seven.

---

## The Protocol Is Trivial and the Framing Is Not

`robotd` speaks JSON-RPC 2.0 as newline-delimited JSON: one object, one line. A
phone reaches that socket across a LAN bridge, so bytes arrive in whatever chunks
TCP felt like producing.

A `robot.state` notification carrying all twelve documented fields is 319 bytes;
at 50 Hz that is about 16 KB a second, so a single 1500-byte segment holds four
whole lines and part of a fifth — **always**, not occasionally. A decoder that
assumes one read is one message is correct on loopback, correct against a unit
test that hands it a whole file, and wrong on Wi-Fi: it throws away 0.7 of every
4.7 lines. Silently, which is the real damage — a fall reported in one simply
never happened, and the diary reads like a robot that did less rather than like a
parser that ate the evidence.

```swift
var decoder = DuckRPC.StreamDecoder()
for message in decoder.append(bytesJustRead) {
    if message.isNotification, message.method == DuckState.method,
       let state = message.params(as: DuckState.self) { … }
}
```

Written against the five things that actually happen: a message split across two
reads, two messages in one read, CRLF from a bridge that rewrote the stream, a
partial line at the end of every read, and a line that never ends.

**And it refuses to grow.** Past `maxLineBytes` — 256 KB, which is 821 state
lines, sixteen seconds of the entire stream as ONE line — the line is discarded,
the buffer's memory handed back, and the decoder hunts forward to the next
newline. Refusing one line loses one line; buffering it loses the hour, because
iOS kills the app and takes the recording session with it.

Three counters, three different failures:

| Counter | Means |
|---|---|
| `malformedLines` | Arrived whole, was not a message — a schema change, a log line on the wrong stream |
| `refusedLines` | Breached the cap and was discarded unread |
| `pendingBytes` | Held right now waiting for a terminator — "quiet" versus "mid-sentence" |

An empty line is a keepalive, not a defect, and is not counted.

---

## Requests and Answers

```swift
var correlator = DuckRPC.Correlator()
let (id, bytes) = try correlator.request("robot.skill", params: params)
send(bytes)
// later:
if let method = correlator.method(answering: message) { … }
```

Two `robot.skill` calls half a second apart come back as two objects
distinguishable only by an integer, so the table mapping that integer back to a
method is the difference between "the kick was refused" and "something was
refused".

**Ids are never reused, not even across a reconnect.** A late answer to a request
from a previous connection would otherwise land on a live id and be reported as
the answer to a question nobody asked. On a dropped socket call `abandonAll()`
and say what was lost — four buttons stuck on "sent…" is worse than four buttons
that admit the socket died.

`method(answering:)` returns nil for a notification, for an id nobody minted, and
for a second copy of an answer already matched. All three mean the same honest
thing.

Methods seen on the wire in this package: `robot.state`, `robot.health`,
`robot.subscribe`, `tof.frame`.

---

## `robot.state`: Every Field Optional, At Every Depth

`robotd` ships with a robot that reaches customers around Christmas 2026, so its
schema will move — a key renamed, a block added — while apps that read it are
already installed on phones.

The two ways of coping are not equally bad. An app that throws on an unknown key
is annoying: it stops working and everyone can see that. An app that decodes a
*missing* block as zeros is dangerous: `fallen: false` for a robot whose safety
block was renamed is a diary that says, in signed and hash-chained form, that the
duck never fell. **A zero is a lie that looks exactly like data**, and the only
structural defence is to have no zero to fall back to.

| Block | Fields |
|---|---|
| `safety` | `fallen`, `limp` |
| `loop` | `hz`, `missed` |
| `battery` | `volts`, `percent` |
| `odom` | `position` ([x, y]), `yaw` |
| `move` | `requested`, `applied`, `limitedBy` |
| — | `policy` (the daemon's own string, verbatim) |

`isEmpty` is the alarm: a state where every leaf is nil means a line arrived,
parsed as JSON, and contained nothing this package recognised — the loudest
possible signal that the schema moved. **Count those. Never average them.**

`receivedAt` is a stored property because staleness is a fact about the value and
not about whoever is displaying it. At 50 Hz a state is 20 ms old by the time its
successor lands; a screen showing a three-second-old "walking" may be describing
a robot that has been on its side for two and a half of them. Ask
`isStale(now:after:)` wherever the value has got to.

The clock is the phone's. `robot.state` as documented carries no timestamp of its
own, so network jitter sits inside every duration computed from these, and any
honest summary says so out loud. `init(from:)` stamps `receivedAt` at decode
because a decoder has no other clock; a caller with a better one uses
`init(_:receivedAt:)`.

Each block is read with its own `try?`, so a renamed `battery` costs exactly the
battery and not the odometry standing next to it.

---

## Depth: `tof.frame`

An 8×8 grid from a VL53L5CX/VL53L8CX on the head's I²C bus, looking where the
head looks. `tofd` owns it and publishes on its **own** socket, not `robotd`'s,
because nothing in the control loop reads depth.

**The status byte is the point, and collapsing it loses the answer that matters.**
JSON has no NaN, so a distance-only frame would encode "no measurement" as a magic
number. The sensor answers three ways:

| `Zone` | Means |
|---|---|
| `.range(Double)` | Something is there, in metres |
| `.noTarget` | Nothing out to the sensor's range — **empty space is information** |
| `.unusable(UInt8)` | The measurement failed, and carries ST's status byte |

Treating the third as "clear" is how a robot walks into a table leg it could not
see. Statuses 5 and 9 are usable (valid, and valid with a large pulse); 255 is
no-target. Those thresholds are upstream's, from the `tof` crate.

`isTrustworthy(minimumUsableFraction:)`, `nearestInCentre(margin:)` and
`columnMeans` are there so a caller does not re-derive the interpretation.

---

## Predicting a Refusal

Pressing `kick_left` takes the whole robot for half a second; pressing `chirp`
takes a speaker. `robotd` enforces that — skills are one-shot and exclusive, and
a second one arriving while a move holds the robot is refused by an error naming
the move already holding it.

```swift
if let why = DuckPress.skill(.kickLeft).predictedRefusal(given: latestState) { … }
```

**The rule is one-sided on purpose: a press is predicted refused ONLY on a field
that is present and true.** Silence predicts nothing. Without prediction a button
says "sent…" for a full round trip and then admits it was refused, and the user
has already pressed it twice. With *naive* prediction a button greys itself out
on a stale state and the robot becomes unreachable through a UI certain it is
busy — an unfalsifiable interface, which is much worse.

Pass `nil` for `state` when there is nothing recent (a fresh connection, or one
`isStale` has disqualified) and nothing is predicted, which is correct when the
robot has not spoken lately.

Order of causes: `fallen`, then `limp`, then `busy(DuckSkill)`. A duck that is
both on its side and mid-roulade is on its side, and reporting the roulade sends
someone to fix the wrong thing.

`sit_toggle` is deliberately never reported as holding. `alpha_sitstand` both
performs the toggle and — as far as a policy name can tell — keeps a seated duck
seated, so treating it as a hold would grey out the one button that gets a
sitting duck back on its feet.

---

## Totals Somebody Else Can Reproduce

`DuckStateReducer` folds the stream into `Int64` accumulators: distance in
**micrometres**, turn in microradians, time in milliseconds, falls, resets, gaps.

Micrometres, not millimetres, and the difference is a quarter of the answer. The
envelope is 0.2 m/s at 50 Hz, so a step is at most 4 mm; truncating each to whole
millimetres loses up to 1 mm per step, and there are 180,000 steps in an hour —
up to 180 m lost against the 720 m that hour covers. In micrometres the same
worst case is 18 cm, comfortably under the odometry's own drift.

No float ever reaches an accumulator — not because floats are inaccurate but
because summing 180,000 doubles depends on the order, so the app, the verifier
and a reference script could never be said to disagree about anything meaningful.
One rounding rule throughout: `floor(x + 0.5)`, chosen because it is one obvious
expression in Swift, Python and JavaScript alike.

---

## Common Mistakes

**Decoding a state and storing zeros for absent blocks.** See above. Store the
optionals.

**Branching on a refusal's prose.** `DuckSkill.mentioned(in:)` reads a skill name
out of an error message **for a label, and only for a label**. Error strings are
prose, not an API.

**Assuming `tof.frame` arrives on robotd's socket.** It does not.

**Treating `robot.state`'s `policy` string as a policy identity.** It is what the
daemon said it was running. The checkable identity is the parameter fingerprint —
`skills/policy-provenance.md`.
