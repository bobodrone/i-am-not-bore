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

-- ---- grid helpers ---------------------------------------------------------
local function gpress(x, y) S.grid_key(x, y, 1); S.grid_key(x, y, 0); gap(0.1) end
local function near(a, b) return math.abs(a - b) < 1e-6 end
local function row(y, x1, x2)
  local out = {}
  for x = x1, x2 do out[#out + 1] = string.format("%x", S.led(x, y)) end
  return table.concat(out)
end

print("\n=== grid: transport, lock, selection ===")
params:set("stop_all")
assert(select_track(1))
check("the grid is drawn from init, page column lit on turing",
  S.led(16, 1) == 15 and S.led(16, 2) == 3, row(1, 16, 16) .. row(2, 16, 16))
check("a stopped track's play key is dim", S.led(1, 3) == 2, tostring(S.led(1, 3)))

gpress(1, 3)
S.calls = {}; S.pump_all(40)
check("col 1 starts that row's track", #trigs_for(2) > 0, #trigs_for(2) .. " triggers")
check("and only that track", #trigs_for(0) == 0 and #trigs_for(3) == 0)
check("touching a row selects it on the norns", selected_track() == 3,
  "T" .. tostring(selected_track()))
S.now = S.now + 1; redraw()
check("a playing track's play key is lit", S.led(1, 3) == 8, tostring(S.led(1, 3)))
S.pump_all(4); redraw()               -- density is 1.0, so it has just fired
check("and flashes on a gate", S.led(1, 3) == 15, tostring(S.led(1, 3)))
gpress(1, 3)
S.calls = {}; S.pump_all(40)
check("col 1 again stops it", #trigs_for(2) == 0 and S.led(1, 3) == 2)

gpress(2, 5)
check("col 2 locks that row's voice", params:string("t5_mode") == "locked")
check("and lights while locked", S.led(2, 5) == 15 and S.led(2, 4) == 2)
gpress(2, 5)
check("col 2 again unlocks", params:string("t5_mode") == "random" and S.led(2, 5) == 2)

print("\n=== grid: value pages ===")
gpress(3, 2)
check("turing: leftmost key is 0", near(params:get("t2_turing"), 0), tostring(params:get("t2_turing")))
gpress(15, 2)
check("turing: rightmost key is 1", near(params:get("t2_turing"), 1))
gpress(9, 2)
check("turing: centre key is 0.5", near(params:get("t2_turing"), 0.5))
check("the centre key lights alone", row(2, 3, 15) == "000000c000000", row(2, 3, 15))
gpress(12, 2)
check("a centre strip fills out from the middle", row(2, 3, 15) == "000000355c000", row(2, 3, 15))
check("other rows are untouched", near(params:get("t1_turing"), 0.5))

gpress(16, 2)                          -- speed
check("page key latches", S.led(16, 2) == 15 and S.led(16, 1) == 3)
local want = { -4, -2, -1.5, -1, -0.5, -0.25, 0, 0.25, 0.5, 1, 1.5, 2, 4 }
local got, okv = {}, true
for i = 1, 13 do
  gpress(2 + i, 6)
  got[i] = params:get("t6_speed")
  if not near(got[i], want[i]) then okv = false end
end
check("speed keys are octaves and fifths, centre = stop", okv, table.concat(got, " "))
gpress(8, 6)
S.texts = {}; redraw()
check("0.25x survives the param and reads as itself on screen",
  near(params:get("t6_speed"), -0.25) and S.screen_says("0.25x rev"))
check("reverse fills leftwards from the centre", row(6, 3, 15) == "00000c3000000", row(6, 3, 15))
params:set("t6_speed", 1.2)            -- as if set from E2, between two keys
redraw()
check("an encoder value lights the nearest key (1.0x)", S.led(12, 6) == 12, row(6, 3, 15))

gpress(16, 3)                          -- density
gpress(3, 4); local d0 = params:get("t4_density")
gpress(15, 4)
check("density runs 0..1 across the strip", near(d0, 0) and near(params:get("t4_density"), 1))
check("a bar strip fills from the left", row(4, 3, 15) == "555555555555c", row(4, 3, 15))

gpress(16, 4)                          -- division
gpress(3, 7); local dv1 = params:string("t7_div")
gpress(11, 7)
check("division: 9 keys, 1/1 to 1/32", dv1 == "1/1" and params:string("t7_div") == "1/32",
  dv1 .. " .. " .. params:string("t7_div"))
gpress(13, 7)
check("the dark keys past the 9th do nothing", params:string("t7_div") == "1/32")
check("division lights one key", row(7, 3, 15) == "22222222c0000", row(7, 3, 15))

gpress(16, 6)                          -- level
S.calls = {}
gpress(9, 1)
local lv = S.calls_named("trackLevel")
check("level reaches the engine", near(params:get("t1_level"), 0.5) and #lv == 1
  and lv[1].args[1] == 0 and near(lv[1].args[2], 0.5))

gpress(16, 7)                          -- pan
gpress(3, 1); local pl = params:get("t1_pan")
gpress(15, 1); local pr = params:get("t1_pan")
gpress(9, 1)
check("pan runs L..R with centre in the middle",
  near(pl, -1) and near(pr, 1) and near(params:get("t1_pan"), 0), pl .. " " .. pr)

print("\n=== grid: steps page ===")
gpress(16, 7)                          -- come from pan
params:set("t3_length", 8)
gpress(16, 5)
local lit = 0
for x = 1, 16 do if S.led(x, 3) > 0 then lit = lit + 1 end end
check("each row shows its register, as long as its loop", lit == 8, lit .. " lit")
gpress(16, 3)
check("all 16 columns are lengths, column 16 included",
  params:get("t3_length") == 16, tostring(params:get("t3_length")))
gpress(1, 3)
check("column 1 is length 1, not start/stop", params:get("t3_length") == 1)
S.calls = {}; S.pump_all(40)
check("so nothing started", #trigs_for(2) == 0)
gpress(5, 8)
check("several tracks can be set in one visit", params:get("t8_length") == 5)
S.now = S.now + 1.5; redraw()
-- nothing is running, so no register key is at 15: only a page key can be
check("the page holds while you are still within 2 s", S.led(16, 7) ~= 15,
  "pan key " .. S.led(16, 7))
gpress(6, 8)
S.now = S.now + 1.5; redraw()
check("a touch restarts the timeout", params:get("t8_length") == 6 and S.led(16, 7) ~= 15,
  "pan key " .. S.led(16, 7))
S.now = S.now + 1.0; redraw()
check("it returns to the page it came from after 2 s idle", S.led(16, 7) == 15,
  "pan key " .. S.led(16, 7))

print("\n=== grid: global page ===")
gpress(16, 8)
gpress(9, 1)
check("row 1 is master level", near(params:get("master"), 0.5))
gpress(3, 2); local f0 = params:get("fade_time")
gpress(15, 2)
check("row 2 is fade time, 0.5 s to 20 s", near(f0, 0.5) and near(params:get("fade_time"), 20))
check("master does not move a track param", near(params:get("t1_pan"), 0))

S.pump_all(200); S.calls = {}
gpress(6, 7)                           -- reroll track 4
S.pump_all(60)
local gr, only4 = S.calls_named("loadSlot"), true
for _, c in ipairs(gr) do if c.args[1] ~= 3 or c.args[2] < 1 then only4 = false end end
check("row 7 rerolls one track per key", #gr == 15 and only4, #gr .. " loads")

gpress(3, 8)
S.calls = {}; S.pump_all(40)
live = 0
for n = 0, 7 do if #trigs_for(n) > 0 then live = live + 1 end end
check("start all fires on a tap", live == 8, live .. "/8 running")

gpress(9, 8)
S.calls = {}; S.pump_all(40)
live = 0
for n = 0, 7 do if #trigs_for(n) > 0 then live = live + 1 end end
check("a tap on stop all does nothing", live == 8, live .. "/8 running")
S.now = S.now + 1; redraw()
S.calls = {}; S.pump_all(40)
check("nor does it go off later, once released", #trigs_for(0) > 0)

S.grid_key(9, 8, 1)
S.now = S.now + 0.25; redraw()
local arming = S.led(9, 8)
S.now = S.now + 0.3; redraw()
S.calls = {}; S.pump_all(40)
any = 0
for n = 0, 7 do any = any + #trigs_for(n) end
check("stop all fires once held 0.5 s", any == 0, any .. " triggers")
check("its key fills while arming", arming > 4 and arming < 15 and S.led(9, 8) == 15,
  arming .. " -> " .. S.led(9, 8))
S.grid_key(9, 8, 0); gap()

gpress(3, 8)                           -- start all again
S.calls = {}
S.grid_key(15, 8, 1); S.now = S.now + 0.6; redraw()
faded = false
for _, c in ipairs(S.calls_named("setMaster")) do if c.args[1] == 0 then faded = true end end
S.now = S.now + 5; redraw()
local once = 0
for _, c in ipairs(S.calls_named("setMaster")) do if c.args[1] == 0 then once = once + 1 end end
S.grid_key(15, 8, 0); gap()
check("fade all fires once held", faded)
check("and only once, however long it is held", once == 1, once .. " fades")
S.pump_all(2)                          -- let the fade finish and stop everything

-- a key armed on one page must not go off after the page changes under it
gpress(3, 8)
S.grid_key(9, 8, 1)
gpress(16, 5)                          -- to the steps page, stop all still down
S.now = S.now + 1; redraw()
S.grid_key(9, 8, 0)
S.calls = {}; S.pump_all(40)
check("changing page disarms a held key", #trigs_for(0) > 0)
check("and its release is not read as a length", params:get("t8_length") == 6,
  tostring(params:get("t8_length")))
params:set("stop_all")
S.now = S.now + 3; redraw()
gpress(16, 1)

print("\n=== redraw + cleanup ===")
local o1 = pcall(redraw); tap(1)
local o2 = pcall(redraw)
key(2, 1); local o3 = pcall(redraw); key(2, 0)
key(1, 1); local o4 = pcall(redraw); key(1, 0)
check("redraw works on every page and modifier state", o1 and o2 and o3 and o4)
check("cleanup() completes", pcall(cleanup))

print(string.format("\n%d/%d checks passed", checks - fails, checks))
os.exit(fails == 0 and 0 or 1)
