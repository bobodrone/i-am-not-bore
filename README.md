# i am not bore

Eight parallel **Turing machine sample players** for [norns](https://monome.org/norns).

Each of the eight tracks owns one folder of samples and runs its own shift
register at its own clock division. Steps that fire pull a sound from that
track's folder — a different one every time, or the same one every time, your
choice. Everything hangs off one tempo (124 bpm by default), so eight registers
of different lengths at different divisions phase against each other and take a
long time to repeat.

## Install

Copy this folder to `dust/code/i-am-not-bore/` on the norns, then put the
samples where the script expects them:

```
dust/audio/i-am-not-bore/
  00_long_bright_quiet_noisy/
  01_low_loud_tonal_1/
  02_bright_loud_noisy/
  03_low_tonal/
  04_mid/
  05_low_loud_tonal_5/
  06_long_quiet/
  07_bright_noisy/
```

Subfolders are sorted alphabetically and handed out in order — folder 1 to
track 1, and so on — which is what the `00_`–`07_` prefixes are for. Any number
of subfolders works; with fewer than eight the assignment wraps. `.wav`,
`.aif`, `.aiff` and `.flac` are picked up.

The path is the **sample folder** param if you keep them elsewhere; hit
**rescan folders** after changing it.

## Controls

| | |
|---|---|
| **E1** | turing — CCW or CW locks the loop, centre keeps it changing |
| **E2** | speed — CCW 4x reverse / 12 o'clock stopped / CW 4x forward |
| **E3** | density — how many steps of the register fire |
| **K1** *hold* | peek at all eight tracks; release to return |
| **K1** *hold* + K2 | select the next track, while peeking |
| **K1** *hold* + K3 | lock the selected voice to the sample it just played (again to unlock) |
| **K2** *tap* | select the next track, 1→8→1 |
| **K2** *hold* + E1 / E2 / E3 | steps (1–16) / level / pan of the selected track |
| **K2** *hold* + K3 | reroll — deal the selected track a new random 15 samples |
| **K3** *tap* | start/stop the selected track |
| **K3** *hold* + K2 | select the previous track, 1→8 |
| **K3** *double tap* | fade everything out |

**K1 is hold-only.** norns keeps the short K1 press for its own system menu, so
a script cannot put an action on a K1 tap — it loses the race and you get the
menu. Held, K1 is the script's. There is no K1 double-tap either: the first tap
opens the menu and the second closes it, and the script never sees a pair.

So the overview is not a page you navigate to — it is a **peek**, on screen for
exactly as long as K1 is down. There is no page state, so there is nothing to
get stranded on. While peeking, the header tells you what the other two keys
do, and both still work: K2 moves the selection, K3 locks the selected voice.

(If a K1 release ever goes missing — norns can swallow one when its menu takes
over — the peek gives up after ten seconds rather than trapping you.)

**Start/stop all** lives in PARAMS (`start all tracks` / `stop all tracks`),
not on K3. A bare K3 tap always means *the selected track* — it used to mean
"all tracks" while the overview was up, which made one key do two different
things depending on a mode you could not feel from your fingers. The K3 double
tap still kills everything, and the PARAMS triggers are MIDI-mappable, which
makes a footswitch a better start-all than any key combo would have been.

**K2 + K3 and K3 + K2 are the same two keys** — whichever you hold *first* is
the modifier. Hold K2 and press K3 to reroll; hold K3 and press K2 to step
back. The footer names the combo you are currently in, so you can check before
committing.

Because K3 has to be holdable, its own action fires on **release** rather than
press — otherwise reaching for K3 + K2 would start or stop the track every
time. There is no maximum hold time on it, unlike K1 and K2, so resting on the
key and letting go still toggles; only using it as a modifier suppresses it.

The encoders always address the **selected** track. Everything they reach, plus
clock division and sample mode, is also in PARAMS under `track 1`–`track 8`, so
it is all MIDI-mappable and saved with a PSET.

### A note on E2

Twelve o'clock is silence, as specified — the track keeps stepping, it just
fires nothing. Tracks therefore start at **1.0x forward** rather than centred,
so a freshly loaded script makes sound when you press K3.

Speed is captured when a voice starts and does not bend while that sample
sounds. Nothing in the library runs past ~1.5 s, so the next trigger picks up
the new setting; this is what lets each voice know its own length in advance
and free itself cleanly.

## The Turing machine

Fully clockwise the loop is locked. Fully anticlockwise it is also locked, but
it plays its own inverse on alternate laps — a loop of twice the length. In
between, the sequence changes. That is the hardware
[Music Thing Turing Machine](https://www.musicthing.co.uk/pages/turing.html)'s
knob law, where the chance of flipping the recycled bit falls linearly across
the sweep:

```
p = 1 - k        k=1 -> 0 (never flip)   k=0.5 -> 0.5   k=0 -> 1 (always flip)
```

Measured change rate across the sweep, in bits per step:

| knob | 0.00 | 0.20 | 0.40 | 0.50 | 0.60 | 0.80 | 1.00 |
|------|------|------|------|------|------|------|------|
| rate | 1.000 | 0.642 | 0.358 | 0.247 | 0.200 | 0.103 | 0.000 |

The `1.000` at fully CCW is *deterministic* change — the inverse loop flips
every bit every lap and repeats exactly every two laps. It is locked, not
random.

### Values, not bits

The register holds floating point values rather than bits, and a step fires
when its value sits **below the density line**. That is what makes E3 a
threshold instead of a wrecking ball: sliding density changes how many steps
fire while leaving the underlying sequence intact, so you can thin a pattern
out and bring the same one back. The screen draws it literally — one bar per
step, with the density line across them. Bars poking above the line are the
steps that fire.

A bit flip does double duty on the hardware: flipping a bit half the time *is*
randomness. Values need those two jobs separated, so an alteration is either a
complement (`v -> 1-v`, reshuffling material already in the register) or a
fresh random value, weighted toward complement as you approach fully CCW:

```
w = max(0, (0.5 - k) * 2)     1 at fully CCW, 0 at centre and clockwise
```

Deciding by which *side* of centre you are on instead would put a cliff exactly
at the centre detent — a deterministic inverse loop one click left, chaos one
click right — which is where the encoder likes to sit. The weighting keeps the
sweep smooth and monotonic from one end to the other.

## Sample pools and rerolling

The library this was built against is ~300 MB across ~2900 stereo files. That
is too much to hold in RAM, and 2900 is more buffers than scsynth's default
table has room for. So each track loads **15 samples** from its folder at
startup (~18 MB across all eight) and random mode draws from those 15.

That set then **holds still** until you ask for a new one. **K2 + K3** deals
the selected track a fresh 15, drawn from anywhere in its folder — so the pool
is a hand of cards you play until you want a different one, not a window that
drifts underneath you. It is also the per-track **reroll samples** param, so it
can be MIDI-mapped to a footswitch or fired from a PSET.

Rerolling does not interrupt anything. The engine only swaps a slot's buffer
once its read completes, so until then the slot still holds — and still plays —
the old file. The cast crosses over sound by sound across about 0.4 s instead
of dropping out, and voices already sounding are never cut off (the old buffer
is kept alive for two seconds before being freed).

### Random or locked, per voice

Each voice is in one of two modes, and **K1 + K3** toggles it:

- **random** (the default) draws a fresh one of the 15 on **every gate**.
  Nothing is sticky — a voice firing four times a second re-draws four times a
  second.
- **locked** plays one sample on every gate. Locking points it at whatever the
  voice played *most recently*, so the gesture is: hear something in the random
  stream worth keeping, hold K1 and hit K3.

Slot 0 of each track is reserved for the locked sample, which is why reroll
only ever touches slots 1–15. Two consequences worth knowing:

- Rerolling a locked voice is silent. It re-deals the hand you get **when you
  unlock**, without disturbing what is currently playing.
- Unlocking returns to the same 15 it left, so lock and unlock are reversible.

Locking a voice that has not played anything yet falls back to whatever the
`locked file` param points at. That param picks from the **whole folder**, not
just the loaded 15, so you can also choose a specific sample from the menu —
but K1 + K3 is the fast way, and it keeps the param in sync so PARAMS always
shows what you grabbed.

The lock read jumps the load queue so it lands before the next gate; otherwise
a voice would play its previously locked sample once on the way in.

Startup reads are queued slot-major rather than track-major — every track gets
its first sample before any track gets its second. Filling track by track
instead would leave track 8 with nothing loaded, and so silent, for the first
few seconds while the queue drains. The screen reports `loading n` until it is
done.

### What random actually sounds like

Uniform over 15 files, not over the folder. At the default 1/16 and density
0.5, a track fires ~4 times a second, so with 15 files in play you hear the
same sound back roughly every 3–4 seconds. That is a recognisable cast, which
is the point — it gives a track an identity that you change deliberately rather
than one that erodes on its own.

If you want a track to churn continuously, map its `reroll samples` param to an
LFO or a MIDI clock divider.

## Signal path

```
PlayBuf -> linen env -> track pan -> track level -> master level -> out
```

Track level and pan are control busses rather than synth arguments, so a
*running* voice keeps following them. That is what makes the K3 double-press
fade duck the tails of already-sounding samples instead of only affecting the
next trigger. The master level is driven by a `VarLag` so the fade is a true
linear ramp over the requested time — a plain `Lag` would only get about 63% of
the way there.

Reverse playback starts at the last frame of the buffer, and the envelope
length is the sample length scaled by `|speed|`, so the release still lands at
the end of the sound at 4x and at 0.25x alike.

## Files

| | |
|---|---|
| `i-am-not-bore.lua` | sequencing, UI, sample discovery, pool management |
| `Engine_NotBore.sc` | the eight-voice sample engine |

Command names in the engine avoid `load`, `free` and `name` — norns' own
`Engine` table already defines those, and a command sharing one of those names
is shadowed by the core function and never reaches the engine.
