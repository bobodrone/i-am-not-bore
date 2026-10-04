# tests

Offline tests for the Lua half of the script. They exist because norns is not
a convenient place to find out that a param id was misspelled or that a key
combo eats a keypress it shouldn't.

```
cd test
lua run_script.lua     # loads the real script under a norns stub, 112 checks
lua tm2.lua            # the turing register in isolation
```

Both exit non-zero on failure. Nothing here ships to the norns — `dust/code/`
only needs the `.lua`, the `.sc` and the README.

## `norns_stub.lua`

Enough of the norns API to load and drive the real script: `params` (options,
numbers, controls, triggers, actions, groups), `clock` backed by real Lua
coroutines so timed loops can be pumped a step at a time, `engine` recording
every call, `screen` capturing rendered text so tests can assert on what the
display actually says, a 16x8 `grid` that keeps the LED levels of its last
refresh and rejects out-of-range LEDs, plus `util` over a fake filesystem seeded with eight
folders the size of the real ones.

## `run_script.lua`

Drives `init`, `key`, `enc`, `redraw` and `cleanup` and checks, among others:

- every one of the 80 per-track params exists and the file params widen to
  their folder's size
- the startup queue is interleaved, so no track is left silent while it drains
- track/slot indices sent to the engine are 0-based and in range
- random mode re-draws per gate; locked mode plays slot 0 and only slot 0
- reroll touches slots 1–15 and never slot 0, and mashing it does not queue a
  backlog
- K1, K2 and K3 held as modifiers do not also fire their tap actions, and the
  K1 peek times out rather than stranding you if a release goes missing
- K2+K3 and K3+K2 are told apart by which key went down first, and the footer
  hint names the right one even when both are down
- a K3 tap still starts and stops, now that its action fires on release
- the lock read jumps the queue and lands on the very next loader tick
- locking a voice that has never played does not error
- grid: every page's keys land on the right param values, the LEDs show bars,
  centre fills and single keys as intended, and an encoder-set value lights
  the nearest key
- grid: the steps page uses all 16 columns, holds while touched and returns
  after 2 s idle
- grid: stop all and fade all need the 0.5 s hold, fire once, and are disarmed
  by an early release or a page change

`SCRIPT=/path/to/i-am-not-bore.lua lua run_script.lua` to point it elsewhere.

## What is not covered

`Engine_NotBore.sc`. There is no sclang here, so the SuperCollider side is
checked by inspection only — it is the likeliest place for a first-boot
surprise.
