-- Host-side test, run with plain `lua`. Never run it on the norns: it calls
-- os.exit(), which would take matron down with it. `_path` only exists inside
-- matron, so this bails out if the file is ever picked from the script menu.
if rawget(_G, "_path") ~= nil then
  print("i-am-not-bore: test/ is a host-side harness, not a norns script")
  return
end

package.path = "./?.lua;" .. package.path
local S = require "norns_stub"

local ROOT = "/audio/i-am-not-bore/"
local FOLDERS = {
  {"00_long_bright_quiet_noisy", 565}, {"01_low_loud_tonal_1", 213},
  {"02_bright_loud_noisy", 136},       {"03_low_tonal", 358},
  {"04_mid", 491},                     {"05_low_loud_tonal_5", 297},
  {"06_long_quiet", 505},              {"07_bright_noisy", 305},
}
for _, f in ipairs(FOLDERS) do S.mkfolder(ROOT, f[1], f[2]) end
S.install()

local fails, checks = 0, 0
local function check(name, cond, detail)
  checks = checks + 1
  print(string.format("%-56s %s  %s", name, cond and "PASS" or "FAIL", detail or ""))
  if not cond then fails = fails + 1 end
end

assert(loadfile((os.getenv("SCRIPT") or "../i-am-not-bore.lua")))()

-- ---- input helpers: a press is always matched by a release ----------------
local function gap(s) S.now = S.now + (s or 1.0) end
local function tap(n) key(n, 1); S.now = S.now + 0.1; key(n, 0); gap() end
-- hold `mod`, press and release `k`, release `mod`
local function combo(mod, k)
  key(mod, 1); key(k, 1); key(k, 0); key(mod, 0); gap()
end
-- two taps of `n` inside the double-press window
local function double_tap(n)
  key(n, 1); S.now = S.now + 0.05; key(n, 0)
  S.now = S.now + 0.1
  key(n, 1); S.now = S.now + 0.05; key(n, 0)
  gap()
end

-- read the selected track off the screen (detail header renders "T<n>")
-- the overview is a peek: it is on screen exactly while K1 is held, so there
-- is no page state and nothing to navigate back from.
local function showing_overview()
  S.texts = {}; redraw(); return S.screen_says("overview")
end
local function peek()      -- what is on screen while K1 is down
  key(1, 1)
  local ov = showing_overview()
  key(1, 0); gap()
  return ov
end
local function selected_track()
  S.texts = {}; redraw()
  for _, t in ipairs(S.texts) do
    local n = t:match("^T(%d)$"); if n then return tonumber(n) end
  end
end
local function select_track(n)
  for _ = 1, 9 do
    if selected_track() == n then return true end
    tap(2)
  end
  return false
end
local function trigs_for(track)
  local out = {}
  for _, c in ipairs(S.calls_named("trig")) do
    if c.args[1] == track then out[#out+1] = c end
  end
  return out
end

print("=== init ===")
local ok, err = pcall(init)
check("init() completes without error", ok, ok and "" or tostring(err))
if not ok then os.exit(1) end
check("engine.name is NotBore", engine.name == "NotBore")
check("tempo set to 124", params:get("clock_tempo") == 124)

print("\n=== per-track params ===")
local missing = {}
for n = 1, 8 do
  for _, k in ipairs({"mode","reroll","file","div","length","turing",
                      "density","speed","level","pan"}) do
    local id = string.format("t%d_%s", n, k)
    if not pcall(function() return params:lookup_param(id) end) then
      missing[#missing+1] = id
    end
  end
end
check("all 10 params exist on all 8 tracks", #missing == 0, table.concat(missing, " "))
check("mode options are random/locked",
  params:string("t1_mode") == "random", params:string("t1_mode"))
check("locked-file max widened per folder",
  params:lookup_param("t1_file").max == 565 and params:lookup_param("t3_file").max == 136)

print("\n=== startup load queue is interleaved across tracks ===")
S.pump_all(200)
local loads = S.calls_named("loadSlot")
check("128 slots queued (8 locked + 8x15 pool)", #loads == 128, tostring(#loads))
local a, b = {}, {}
for i = 1, 8 do a[i] = loads[i].args[1] .. ":" .. loads[i].args[2] end
for i = 9, 16 do b[#b+1] = loads[i].args[1] .. ":" .. loads[i].args[2] end
check("first 8 are slot 0 of tracks 0..7",
  table.concat(a, " ") == "0:0 1:0 2:0 3:0 4:0 5:0 6:0 7:0", table.concat(a, " "))
check("next 8 are slot 1 of tracks 0..7 (no track starved)",
  table.concat(b, " ") == "0:1 1:1 2:1 3:1 4:1 5:1 6:1 7:1", table.concat(b, " "))

print("\n=== selection ===")
check("starts on track 1", selected_track() == 1, "T" .. tostring(selected_track()))
tap(2)
check("K2 tap advances the selection", selected_track() == 2, "T" .. tostring(selected_track()))
check("selection wraps 8 -> 1", select_track(8) and (tap(2) or selected_track() == 1),
  "T" .. tostring(selected_track()))

print("\n=== K2 + K3 reroll ===")
assert(select_track(1))
S.calls = {}
combo(2, 3)
check("K2 release after a reroll does not advance the track",
  selected_track() == 1, "T" .. tostring(selected_track()))
S.pump_all(60)
local rl = S.calls_named("loadSlot")
local slots, same = {}, true
for _, c in ipairs(rl) do slots[#slots+1] = c.args[2]; if c.args[1] ~= 0 then same = false end end
table.sort(slots)
check("reroll queues exactly 15 slots", #rl == 15, tostring(#rl))
check("reroll touches slots 1..15, never slot 0", #slots == 15 and slots[1] == 1 and slots[15] == 15)
check("reroll only touches the selected track", same)

S.calls = {}
key(2, 1); key(3, 1); key(3, 1); key(3, 1); key(2, 0); gap()
S.pump_all(80)
check("three rerolls in a row still send only 15 reads",
  #S.calls_named("loadSlot") == 15, tostring(#S.calls_named("loadSlot")))

print("\n=== loading indicator ===")
combo(2, 3)                       -- reroll: 15 pending
S.texts = {}; redraw()
check("footer reports loading while reads are outstanding", S.screen_says("loading"))
S.pump_all(200)
S.texts = {}; redraw()
check("indicator clears once the queue drains", not S.screen_says("loading"))

print("\n=== stepping ===")
assert(select_track(1))
tap(3)                            -- start track 1
S.calls = {}
S.pump_all(300)
local t1 = trigs_for(0)
check("track 1 fires from the pool", #t1 > 0, #t1 .. " triggers")
local bad = 0
for _, c in ipairs(t1) do
  if c.args[2] < 1 or c.args[2] > 15 or math.abs(c.args[3]) > 4 then bad = bad + 1 end
end
check("random mode uses pool slots 1..15 only", bad == 0, bad .. " bad of " .. #t1)
local seen = {}
for _, c in ipairs(t1) do seen[c.args[2]] = true end
local distinct = 0
for _ in pairs(seen) do distinct = distinct + 1 end
check("random mode re-draws per gate (many distinct slots)", distinct > 5,
  distinct .. " distinct slots over " .. #t1 .. " gates")

print("\n=== K1 + K3 lock to last played ===")
check("track 1 starts out random", params:string("t1_mode") == "random")
S.calls = {}
combo(1, 3)                       -- lock
check("K1+K3 locks the voice", params:string("t1_mode") == "locked",
  params:string("t1_mode"))
S.pump_all(1)                     -- exactly one loader tick
local sent = S.calls_named("loadSlot")
check("the lock load jumps the queue (lands on the very next tick)",
  #sent > 0 and sent[1].args[1] == 0 and sent[1].args[2] == 0,
  #sent > 0 and ("track " .. sent[1].args[1] .. " slot " .. sent[1].args[2]) or "nothing sent")
check("releasing K1 after a lock returns to detail", not showing_overview())

S.calls = {}
S.pump_all(300)
local t1b = trigs_for(0)
local only0 = #t1b > 0
for _, c in ipairs(t1b) do if c.args[2] ~= 0 then only0 = false end end
check("locked voice plays slot 0 on every gate", only0,
  #t1b .. " gates, all slot 0: " .. tostring(only0))

S.texts = {}; redraw()
check("detail footer shows the locked sample", S.screen_says("lock"))
-- while peeking, the overview header says what K2 and K3 do. capture with K1
-- still down: releasing it triggers its own redraw and wipes the text.
S.pump_all(60)                      -- drain loads, they take the header slot
key(1, 1); S.texts = {}; redraw()
local unlock_hint, unlock_txt = S.screen_says("K3 unlock")
key(1, 0); gap()
check("peeking at a locked voice offers unlock", unlock_hint,
  unlock_txt or "header said nothing")

-- over a random voice it should offer to lock instead. "K3 lock" must not
-- match the "K3 unlock" wording.
assert(select_track(2))
S.pump_all(60)
key(1, 1); S.texts = {}; redraw()
local lock_hint, lock_txt = S.screen_says("K3 lock")
local trk_hint = S.screen_says("K2 trk")
key(1, 0); gap()
check("peeking at a random voice offers lock", lock_hint,
  lock_txt or "header said nothing")
check("the peek header also advertises K2 = next track", trk_hint,
  lock_txt or "not shown")
assert(select_track(1))

combo(1, 3)                       -- unlock
check("K1+K3 again returns to random", params:string("t1_mode") == "random")
S.calls = {}
S.pump_all(300)
local t1c = trigs_for(0)
local back = #t1c > 0
for _, c in ipairs(t1c) do if c.args[2] < 1 then back = false end end
check("unlocked voice returns to the pool it left", back, #t1c .. " gates from pool")

print("\n=== hold-to-peek (K1 is hold-only) ===")
check("detail is what you see with nothing held", not showing_overview())
check("holding K1 shows the overview", peek())
check("releasing K1 returns to detail", not showing_overview())
tap(1)
check("a bare K1 tap leaves you on detail (norns owns the tap)",
  not showing_overview())

-- the bug from hardware: K1+K3 must lock and must not strand you anywhere
local before = params:string("t1_mode")
combo(1, 3)
check("K1+K3 locks", params:string("t1_mode") ~= before,
  "mode " .. params:string("t1_mode"))
check("and leaves you back on detail, not stranded", not showing_overview())
combo(1, 3)   -- put it back

-- K2 while peeking moves the selection, as the header advertises
local sel = selected_track()
key(1, 1); key(2, 1); S.now = S.now + 0.1; key(2, 0); key(1, 0); gap()
check("K2 while peeking advances the selection",
  selected_track() == (sel % 8) + 1,
  "T" .. tostring(sel) .. " -> T" .. tostring(selected_track()))

-- a peek stuck by a lost K1 release must time out rather than trap you
key(1, 1)
check("peek is up while held", showing_overview())
S.now = S.now + 11          -- simulate a release that never arrived
check("a stuck peek times out back to detail", not showing_overview())
key(1, 0); gap()

print("\n=== locking a voice that has never played ===")
assert(select_track(8))
check("track 8 has not run", params:string("t8_mode") == "random")
local okl = pcall(function() combo(1, 3) end)
check("locking an unplayed voice does not error", okl)
check("it still locks (falls back to the menu selection)",
  params:string("t8_mode") == "locked", params:string("t8_mode"))
combo(1, 3)

print("\n=== K3 + K2 steps back through the cycle ===")
assert(select_track(3))
key(3, 1); key(2, 1); key(2, 0); key(3, 0); gap()
check("K3+K2 moves back one track", selected_track() == 2,
  "T" .. tostring(selected_track()))
assert(select_track(1))
key(3, 1); key(2, 1); key(2, 0); key(3, 0); gap()
check("stepping back from track 1 wraps to 8", selected_track() == 8,
  "T" .. tostring(selected_track()))

-- the whole point of the release-driven K3: holding it must not start/stop
assert(select_track(4))
params:set("t4_speed", 1.0)
tap(3)                                   -- start track 4
S.calls = {}; S.pump_all(40)
local running = #trigs_for(3) > 0
S.calls = {}
key(3, 1); key(2, 1); key(2, 0); key(3, 0); gap()   -- step back off track 4
S.pump_all(40)
check("K3 held as a modifier does not start/stop the track",
  running and #trigs_for(3) > 0, "track 4 still running: " .. tostring(#trigs_for(3) > 0))

-- and the reverse order must still reroll, not step back
assert(select_track(4))
S.calls = {}
combo(2, 3)                              -- K2 first = reroll
S.pump_all(60)
check("K2 held first still rerolls (not a track step)",
  #S.calls_named("loadSlot") == 15 and selected_track() == 4,
  #S.calls_named("loadSlot") .. " loads, on T" .. tostring(selected_track()))

print("\n=== K3 tap starts and stops ===")
assert(select_track(1))
params:set("t1_speed", 1.0)
params:set("t1_density", 1.0)            -- every step fires, so this is decisive
-- get to a known stopped state first
S.calls = {}; S.pump_all(40)
if #trigs_for(0) > 0 then tap(3) end
S.calls = {}; S.pump_all(40)
check("track 1 is stopped to begin with", #trigs_for(0) == 0,
  #trigs_for(0) .. " triggers")
tap(3)
S.calls = {}; S.pump_all(40)
local started = #trigs_for(0)
check("a K3 tap starts the track", started > 0, started .. " triggers")
tap(3)
S.calls = {}; S.pump_all(40)
check("another K3 tap stops it", #trigs_for(0) == 0,
  #trigs_for(0) .. " triggers")

S.calls = {}
double_tap(3)
local faded = false
for _, c in ipairs(S.calls_named("setMaster")) do if c.args[1] == 0 then faded = true end end
check("double tap ramps master to 0", faded)

print("\n=== K3 only ever acts on the selected track ===")
assert(select_track(1))
for n = 1, 8 do params:set("t" .. n .. "_speed", 1.0)
                params:set("t" .. n .. "_density", 1.0) end
params:set("start_all")
S.calls = {}; S.pump_all(40)
local live = 0
for n = 0, 7 do if #trigs_for(n) > 0 then live = live + 1 end end
check("start all tracks (PARAMS) starts all 8", live == 8, live .. "/8 running")

tap(3)                                   -- should stop ONLY track 1
S.calls = {}; S.pump_all(40)
local still = 0
for n = 0, 7 do if #trigs_for(n) > 0 then still = still + 1 end end
check("a K3 tap stops only the selected track", still == 7,
  still .. "/8 still running")

params:set("stop_all")
S.calls = {}; S.pump_all(40)
local any = 0
for n = 0, 7 do any = any + #trigs_for(n) end
check("stop all tracks (PARAMS) stops all 8", any == 0, any .. " triggers")

print("\n=== the hint names whichever key was held first ===")
assert(select_track(1))
key(3, 1); S.texts = {}; redraw()
local h3 = S.screen_says("K3+K2 previous track")
key(3, 0); gap()
check("K3 held alone offers the previous-track combo", h3)

key(2, 1); S.texts = {}; redraw()
local h2 = S.screen_says("K2+K3 reroll")
key(2, 0); gap()
check("K2 held alone offers the reroll combo", h2)

-- both down, K3 first: the hint must stay on K3's combo
key(3, 1); key(2, 1); S.texts = {}; redraw()
local both3 = S.screen_says("K3+K2 previous track")
key(2, 0); key(3, 0); gap()
check("K3 first, then K2: hint stays on K3's combo", both3)

-- both down, K2 first: the hint must stay on K2's combo
key(2, 1); key(3, 1); S.texts = {}; redraw()
local both2 = S.screen_says("K2+K3 reroll")
key(3, 0); key(2, 0); gap()
check("K2 first, then K3: hint stays on K2's combo", both2)

print("\n=== redraw + cleanup ===")
local o1 = pcall(redraw); tap(1)
local o2 = pcall(redraw)
key(2, 1); local o3 = pcall(redraw); key(2, 0)
key(1, 1); local o4 = pcall(redraw); key(1, 0)
check("redraw works on every page and modifier state", o1 and o2 and o3 and o4)
check("cleanup() completes", pcall(cleanup))

print(string.format("\n%d/%d checks passed", checks - fails, checks))
os.exit(fails == 0 and 0 or 1)
