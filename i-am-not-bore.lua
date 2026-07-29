-- i am not bore
-- v1.0.0 @bobodrone
--
-- eight parallel turing machine
-- sample players. one folder of
-- samples per track, each running
-- its own shift register at its
-- own clock division.
--
-- E1 : turing -- fully CCW or CW
--      locks the loop, centre is
--      total randomness
-- E2 : speed -- CCW 4x reverse /
--      12 o'clock stopped /
--      CW 4x forward
-- E3 : density -- how many steps
--      of the register fire
--
-- K1 : hold = peek at all 8 tracks.
--      release returns to detail.
--      while held:
--        K2 = next track
--        K3 = lock this voice to the
--        sample it just played
--        (again to unlock)
--      K1 is hold-only: norns keeps
--      the short press for its menu
-- K2 : tap = next track (1-8)
--      hold + E1 = steps 1-16
--      hold + E2 = level
--      hold + E3 = pan
--      hold + K3 = reroll -- deal
--      this track a new random 15
-- K3 : tap = start/stop the
--      selected track, either page
--      double tap = fade everything
--      hold + K2 = previous track
--      (start/stop all is in PARAMS)
--
-- K2+K3 and K3+K2 are the same two
-- keys: whichever you hold first is
-- the modifier.
--
-- each track loads 15 samples from
-- its folder at start and draws a
-- new one on every gate, until you
-- lock it or reroll it.
--
-- samples live in
-- dust/audio/i-am-not-bore/
-- one subfolder per track.

-- must match Engine_NotBore in Engine_NotBore.sc
engine.name = "NotBore"

local controlspec = require "controlspec"
local util = require "util"

-- ----------------------------------------------------------------------
-- constants
-- ----------------------------------------------------------------------

local NUM_TRACKS = 8
local MAX_STEPS  = 16

-- how many buffers each track keeps loaded. slot 1 (wire slot 0) is reserved
-- for the track's locked sample, leaving 15 for the random pool. the library is
-- ~300 MB / ~2900 files, far too much to hold at once, so a track plays from
-- its 15 and you deal it a new hand on demand with K2 + K3 -- see reroll().
local POOL_SIZE = 16

-- |speed| at or below this counts as the E2 dead zone: the track keeps
-- stepping but fires nothing. matches "12 o'clock = stopped".
local SPEED_DEADZONE = 0.05

-- K1 and K2 both do one thing on a tap and something else when held as a
-- modifier. held longer than this, or used with another control, and the
-- release stops counting as a tap.
local TAP_MAX       = 0.3
local K3_DOUBLE_MAX = 0.35 -- two K3 presses inside this window = double press

-- longest a K1 peek can last before it is assumed to be a lost release
local K1_PEEK_MAX   = 10.0

local FILE_EXTENSIONS = { wav = true, aif = true, aiff = true, flac = true }

-- clock divisions offered per track. beats = length of one step in beats,
-- which is what clock.sync() wants.
local DIVISIONS = {
  { name = "1/1",   beats = 4     },
  { name = "1/2",   beats = 2     },
  { name = "1/4",   beats = 1     },
  { name = "1/4T",  beats = 2/3   },
  { name = "1/8",   beats = 0.5   },
  { name = "1/8T",  beats = 1/3   },
  { name = "1/16",  beats = 0.25  },
  { name = "1/16T", beats = 1/6   },
  { name = "1/32",  beats = 0.125 },
}
local DEFAULT_DIVISION = 7  -- 1/16

local DIVISION_NAMES = {}
for i, d in ipairs(DIVISIONS) do DIVISION_NAMES[i] = d.name end

-- ----------------------------------------------------------------------
-- state
-- ----------------------------------------------------------------------

local tracks = {}       -- per-track table, see make_track()
local selected = 1      -- which track the encoders address

-- K1 held shows the overview for as long as you hold it. there is no page
-- state: the screen follows the key, so you cannot end up stranded on the
-- wrong one.
local k1_held = false
local k1_down_at = 0
local k2_held = false
local k2_down_at = 0
local k2_used = false   -- an encoder moved while K2 was held -> not a tap
local k3_held = false
local k3_used = false   -- K3 was used as a modifier -> its release does nothing
local k3_last_at = -1

local load_queue = {}   -- pending {track, slot, path} buffer reads
local loader_clock = nil
local redraw_clock = nil
local fade_clock = nil
local fading = false

local sample_root = nil -- resolved at init from the path param
local scan_error = nil  -- human-readable reason there is nothing to play

-- ----------------------------------------------------------------------
-- helpers
-- ----------------------------------------------------------------------

local function make_track(n)
  local t = {
    index = n,
    folder = nil,          -- absolute path to this track's sample folder
    label = "-",           -- short folder name for the screen
    files = {},            -- filenames (not paths) in that folder
    pool = {},             -- pool[slot] = filename currently loaded there
    pending = 0,           -- reads queued but not yet sent, for the screen
    last_file = nil,       -- what the most recent trigger played, for the screen
    playing = false,
    pos = 0,               -- step index most recently played, 1..length
    reg = {},              -- the shift register: MAX_STEPS floats in [0,1)
    clock_id = nil,
  }
  -- seed the register. values, not bits: see step() for why.
  for i = 1, MAX_STEPS do t.reg[i] = math.random() end
  return t
end

-- "03_low_tonal" -> "low_tonal", and short enough for the header.
local function short_label(name)
  local stripped = name:match("^%d+_(.+)$") or name
  if #stripped > 15 then stripped = stripped:sub(1, 15) end
  return stripped
end

local function is_sample(name)
  local ext = name:match("%.([%a]+)$")
  return ext ~= nil and FILE_EXTENSIONS[ext:lower()] == true
end

local function pid(n, key)
  return string.format("t%d_%s", n, key)
end

-- key numbers in the order they went down, so the screen can name whichever
-- one is acting as the modifier. K2 and K3 modify each other, so the first
-- one down wins -- exactly the rule the key handler uses to tell K2+K3 from
-- K3+K2. Comparing press timestamps would tie whenever two presses land in
-- the same millisecond; the order they arrived in never does.
local held_order = {}

local function note_up(n)
  for i = #held_order, 1, -1 do
    if held_order[i] == n then table.remove(held_order, i) end
  end
end

-- clearing first makes this self-healing: if a release ever goes missing, the
-- next press of that key replaces the stale entry instead of stacking on it.
local function note_down(n)
  note_up(n)
  held_order[#held_order + 1] = n
end

local function active_modifier() return held_order[1] end

-- ----------------------------------------------------------------------
-- sample discovery
-- ----------------------------------------------------------------------

-- find the 8 subfolders under sample_root and assign folder N to track N,
-- alphabetically -- which is why the folders are named 00_ .. 07_.
local function scan_folders()
  scan_error = nil

  if not util.file_exists(sample_root) then
    scan_error = "no folder at " .. sample_root
    return
  end

  local entries = util.scandir(sample_root)
  local dirs = {}
  for _, e in ipairs(entries) do
    -- scandir marks directories with a trailing slash
    if e:sub(-1) == "/" then table.insert(dirs, e:sub(1, -2)) end
  end
  table.sort(dirs)

  if #dirs == 0 then
    scan_error = "no subfolders in " .. sample_root
    return
  end

  for n = 1, NUM_TRACKS do
    local t = tracks[n]
    t.files = {}
    t.pool = {}
    -- fewer than 8 folders: wrap, so every track still has something to play
    local dir = dirs[((n - 1) % #dirs) + 1]
    t.folder = sample_root .. dir .. "/"
    t.label = short_label(dir)

    for _, f in ipairs(util.scandir(t.folder)) do
      if is_sample(f) then table.insert(t.files, f) end
    end
    table.sort(t.files)
  end
end

-- ----------------------------------------------------------------------
-- buffer loading
-- ----------------------------------------------------------------------

-- reads are queued rather than fired all at once: 128 simultaneous
-- Buffer.reads at startup stalls the server long enough to be audible.
-- `urgent` jumps the queue. only locking uses it: the lock has to land before
-- the next gate or the voice plays the previously locked sample once on its
-- way in, and a queue drained two files per tick is otherwise long enough at
-- startup for that to be audible.
local function queue_load(track, slot, filename, urgent)
  local t = tracks[track]
  if not t.folder or filename == nil then return end
  t.pool[slot] = filename
  t.pending = t.pending + 1
  local job = { track = track, slot = slot, path = t.folder .. filename }
  if urgent then
    table.insert(load_queue, 1, job)
  else
    table.insert(load_queue, job)
  end
end

local function random_file(t)
  if #t.files == 0 then return nil end
  return t.files[math.random(#t.files)]
end

-- slot 1 holds the locked sample; slots 2..POOL_SIZE are the random pool.
local function load_locked(track, urgent)
  local t = tracks[track]
  if #t.files == 0 then return end
  local idx = util.clamp(params:get(pid(track, "file")), 1, #t.files)
  queue_load(track, 1, t.files[idx], urgent)
end

-- deal one track a new hand: all 15 random slots re-drawn from its folder.
-- this is the only thing that ever changes the pool, so a track's set of
-- sounds holds still until you ask for a new one (K2 + K3, or the per-track
-- "reroll samples" param).
--
-- it does not interrupt playback. the engine only swaps a slot's buffer when
-- its read completes, so until then the slot still holds -- and still plays --
-- the old file. the cast crosses over sound by sound across ~0.4 s rather
-- than dropping out, and voices already sounding are never cut off.
-- discard this track's not-yet-sent pool reads, so mashing reroll re-deals
-- from now instead of queueing 15 more behind the last lot. slot 1 jobs are
-- kept: that is the locked sample, and it is not what reroll is replacing.
local function drop_queued_pool(track)
  local kept, pending = {}, 0
  for _, job in ipairs(load_queue) do
    if job.track == track and job.slot >= 2 then
      -- dropped
    else
      kept[#kept + 1] = job
      if job.track == track then pending = pending + 1 end
    end
  end
  load_queue = kept
  tracks[track].pending = pending
end

local function reroll(track)
  local t = tracks[track]
  if #t.files == 0 then return end
  drop_queued_pool(track)
  for slot = 2, POOL_SIZE do
    queue_load(track, slot, random_file(t))
  end
end

-- the startup fill. queued slot-major rather than track-major so every track
-- gets its first sample before any track gets its second: filling track by
-- track instead would leave track 8 with nothing loaded, and so silent, for
-- the first ~3 seconds while the queue drains.
local function queue_initial_load()
  for n = 1, NUM_TRACKS do load_locked(n) end
  for slot = 2, POOL_SIZE do
    for n = 1, NUM_TRACKS do
      local t = tracks[n]
      if #t.files > 0 then queue_load(n, slot, random_file(t)) end
    end
  end
end

-- ----------------------------------------------------------------------
-- locking
-- ----------------------------------------------------------------------

-- a locked voice plays slot 1 on every gate instead of drawing from the pool.
-- one place decides it, so the option's wording lives in exactly one comparison.
local function is_locked(n)
  return params:string(pid(n, "mode")) == "locked"
end

local function file_index(t, filename)
  for i, f in ipairs(t.files) do
    if f == filename then return i end
  end
  return nil
end

-- K1 + K3. lock the voice onto the sample it played most recently -- you hear
-- something in the random stream worth keeping and grab it -- or let it go
-- back to random. the 15 in the pool are left alone either way, so unlocking
-- returns to the same hand it left.
local function toggle_lock(n)
  local t = tracks[n]

  if is_locked(n) then
    params:set(pid(n, "mode"), 1)   -- back to random
    return
  end

  -- point slot 1 at whatever just played. nothing has played yet if the track
  -- has never run, or density has it silent, in which case keep whatever the
  -- locked-file param already points at.
  local idx = t.last_file and file_index(t, t.last_file)
  if idx then
    -- silent: setting the param would queue an ordinary load, and this one
    -- needs to jump the queue to land before the next gate.
    params:set(pid(n, "file"), idx, true)
    load_locked(n, true)
  end

  params:set(pid(n, "mode"), 2)
end

-- ----------------------------------------------------------------------
-- the turing machine
-- ----------------------------------------------------------------------

-- the register holds floats in [0,1) rather than bits, so that E3 (density)
-- can act as a threshold without destroying the pattern: a step fires when
-- its value sits below the density line. sliding density changes how many
-- steps fire while keeping the same underlying sequence.
--
-- E1 follows the hardware Turing Machine's knob law. On the real thing the
-- chance of flipping the recycled bit falls linearly across the sweep:
--
--   p = 1 - k        k=1 -> 0 (locked)   k=0.5 -> 0.5   k=0 -> 1 (always)
--
--   fully CW    never flips  -> the loop repeats, length = steps
--   centre      flips 50%    -> the sequence keeps changing
--   fully CCW   always flips -> the loop repeats its own inverse every other
--               lap, i.e. a locked loop of twice the length
--
-- A bit flip does double duty on the hardware: flipping a bit half the time
-- IS randomness. Floats need the two jobs separated, so `w` decides which
-- kind of alteration happens -- complement toward CCW, fresh random material
-- from the centre rightwards:
--
--   w = max(0, (0.5 - k) * 2)      1 at fully CCW, 0 at centre and CW
--
-- Splitting it this way is what keeps the knob smooth. Choosing the operation
-- by which side of centre you are on instead would put a cliff exactly at the
-- centre detent -- deterministic inverse-loop one click left, total chaos one
-- click right -- which is precisely where the encoder likes to sit.
local function mutate(v, k)
  local complement_odds = math.max(0, (0.5 - k) * 2)
  if math.random() < complement_odds then
    return 1 - v
  else
    return math.random()
  end
end

local function step(n)
  local t = tracks[n]
  local length = params:get(pid(n, "length"))
  local density = params:get(pid(n, "density"))
  local k = params:get(pid(n, "turing"))
  local speed = params:get(pid(n, "speed"))

  t.pos = (t.pos % length) + 1
  local v = t.reg[t.pos]

  -- read the gate before mutating, so a change lands on the next lap.
  if v < density and math.abs(speed) > SPEED_DEADZONE and #t.files > 0 then
    -- locked: always slot 1. random: a fresh draw from the pool every gate.
    local slot = is_locked(n) and 1 or math.random(2, POOL_SIZE)
    t.last_file = t.pool[slot]
    -- wire protocol is 0-based on both track and slot
    engine.trig(n - 1, slot - 1, speed)
  end

  if math.random() < (1 - k) then
    t.reg[t.pos] = mutate(v, k)
  end
end

-- ----------------------------------------------------------------------
-- transport
-- ----------------------------------------------------------------------

local function stop_fade_clock()
  if fade_clock then clock.cancel(fade_clock); fade_clock = nil end
end

-- abandon a fade and bring the master back up. only for taking the level back,
-- never as a step on the way into another fade -- see fade_all().
local function cancel_fade()
  stop_fade_clock()
  if fading then
    fading = false
    engine.setMaster(params:get("master"), 0.02)
  end
end

local function stop_track(n)
  local t = tracks[n]
  if t.clock_id then clock.cancel(t.clock_id); t.clock_id = nil end
  t.playing = false
end

local function start_track(n)
  local t = tracks[n]
  if t.playing then return end
  -- starting anything cancels a fade in progress, otherwise the new track
  -- would come up into a master level still on its way to zero.
  cancel_fade()
  t.playing = true
  -- the division is read fresh each pass, so changing it takes effect on the
  -- next step rather than needing the track restarted. no redraw here: eight
  -- tracks at 1/16 would ask for ~65 redraws a second between them, so the
  -- screen runs on its own timer instead (see redraw_clock in init).
  t.clock_id = clock.run(function()
    while true do
      clock.sync(DIVISIONS[params:get(pid(n, "div"))].beats)
      step(n)
    end
  end)
end

local function toggle_track(n)
  if tracks[n].playing then stop_track(n) else start_track(n) end
end

local function start_all()
  for n = 1, NUM_TRACKS do start_track(n) end
end

local function stop_all()
  for n = 1, NUM_TRACKS do stop_track(n) end
end

-- K3 double press. ramp the master level down over the fade time -- the
-- engine applies it to sounding voices too, so tails duck with the rest --
-- then stop the sequencers and restore the level silently.
local function fade_all()
  local secs = params:get("fade_time")
  -- drop only the pending clock, not the level: double-pressing again part
  -- way through a fade should carry on down from wherever it got to, rather
  -- than snapping back to full and starting the ramp over.
  stop_fade_clock()
  fading = true
  engine.setMaster(0, secs)
  fade_clock = clock.run(function()
    clock.sleep(secs)
    for n = 1, NUM_TRACKS do stop_track(n) end
    fading = false
    engine.setMaster(params:get("master"), 0.02)
    fade_clock = nil
    redraw()
  end)
end

-- ----------------------------------------------------------------------
-- params
-- ----------------------------------------------------------------------

-- each track's locked-file param is created before the folders have been
-- scanned, so its max starts at 1. widen it once the file list is known.
local function fit_file_params()
  for n = 1, NUM_TRACKS do
    local p = params:lookup_param(pid(n, "file"))
    p.max = math.max(1, #tracks[n].files)
    if p.value > p.max then params:set(pid(n, "file"), 1) end
  end
end

local function set_root(v)
  sample_root = v
  if sample_root:sub(-1) ~= "/" then sample_root = sample_root .. "/" end
end

local function add_params()
  params:add_separator("i_am_not_bore", "i am not bore")

  params:add_text("root", "sample folder", _path.audio .. "i-am-not-bore/")
  params:set_action("root", function(v) set_root(v) end)
  -- add_text does not fire its action on creation, so seed sample_root by
  -- hand -- scan_folders() runs before anything would otherwise set it.
  set_root(params:get("root"))

  params:add_trigger("rescan", "rescan folders")
  params:set_action("rescan", function()
    scan_folders()
    load_queue = {}
    for n = 1, NUM_TRACKS do tracks[n].pending = 0 end
    fit_file_params()
    queue_initial_load()
  end)

  params:add_control("master", "master level",
    controlspec.new(0, 1, "lin", 0.01, 1.0, ""))
  params:set_action("master", function(v)
    if not fading then engine.setMaster(v, 0.02) end
  end)

  params:add_control("fade_time", "fade out time",
    controlspec.new(0.5, 20, "lin", 0.5, 3.0, "s"))

  -- K3 acts on the selected track only, so the all-tracks transport lives
  -- here. MIDI-mappable, which makes a footswitch a better start-all than
  -- any key combo would have been.
  params:add_trigger("start_all", "start all tracks")
  params:set_action("start_all", function() start_all() end)

  params:add_trigger("stop_all", "stop all tracks")
  params:set_action("stop_all", function() stop_all() end)

  for n = 1, NUM_TRACKS do
    params:add_group("track_" .. n, "track " .. n, 10)

    -- random draws a different one of this track's 15 loaded samples on every
    -- gate; locked plays the one below on every gate. K1 + K3 toggles this and
    -- points the locked file at whatever was playing when you pressed it.
    params:add_option(pid(n, "mode"), "mode", { "random", "locked" }, 1)

    -- same gesture as K2 + K3, exposed here so it can be MIDI-mapped to a
    -- footswitch or fired from a PSET.
    params:add_trigger(pid(n, "reroll"), "reroll samples")
    params:set_action(pid(n, "reroll"), function() reroll(n) end)

    -- max is patched up in init() once the folder has been scanned.
    params:add_number(pid(n, "file"), "locked file", 1, 1, 1, function(p)
      local t = tracks[n]
      local f = t.files[p:get()]
      return f and f:gsub("%.%a+$", "") or "-"
    end)
    params:set_action(pid(n, "file"), function() load_locked(n) end)

    params:add_option(pid(n, "div"), "division", DIVISION_NAMES, DEFAULT_DIVISION)

    params:add_number(pid(n, "length"), "steps", 1, MAX_STEPS, 8)

    params:add_control(pid(n, "turing"), "turing",
      controlspec.new(0, 1, "lin", 0.02, 0.5, ""))

    params:add_control(pid(n, "density"), "density",
      controlspec.new(0, 1, "lin", 0.02, 0.5, ""))

    params:add_control(pid(n, "speed"), "speed",
      controlspec.new(-4, 4, "lin", 0.1, 1.0, "x"))

    params:add_control(pid(n, "level"), "level",
      controlspec.new(0, 1, "lin", 0.01, 0.7, ""))
    params:set_action(pid(n, "level"), function(v) engine.trackLevel(n - 1, v) end)

    params:add_control(pid(n, "pan"), "pan",
      controlspec.new(-1, 1, "lin", 0.02, 0.0, ""))
    params:set_action(pid(n, "pan"), function(v) engine.trackPan(n - 1, v) end)
  end
end

-- ----------------------------------------------------------------------
-- norns lifecycle
-- ----------------------------------------------------------------------

function init()
  math.randomseed(os.time())

  for n = 1, NUM_TRACKS do tracks[n] = make_track(n) end

  add_params()

  -- the main tempo. norns' own clock param drives every track's clock.sync().
  params:set("clock_tempo", 124)

  scan_folders()

  -- now that the folders are known, widen each locked-file param to the real
  -- file count and queue the initial buffer loads.
  fit_file_params()
  queue_initial_load()
  for n = 1, NUM_TRACKS do
    engine.trackLevel(n - 1, params:get(pid(n, "level")))
    engine.trackPan(n - 1, params:get(pid(n, "pan")))
  end

  engine.setMaster(params:get("master"), 0.02)

  -- drain the load queue a couple of files at a time. firing all 128 initial
  -- reads at once stalls the server long enough to hear.
  loader_clock = clock.run(function()
    while true do
      clock.sleep(0.05)
      for _ = 1, 2 do
        local job = table.remove(load_queue, 1)
        if job == nil then break end
        local t = tracks[job.track]
        t.pending = math.max(0, t.pending - 1)
        engine.loadSlot(job.track - 1, job.slot - 1, job.path)
      end
    end
  end)

  -- the screen is driven here rather than from the step callbacks, so its
  -- cost is fixed no matter how many tracks are running or how fast.
  redraw_clock = clock.run(function()
    while true do
      clock.sleep(1 / 15)
      redraw()
    end
  end)

  redraw()
end

function cleanup()
  for n = 1, NUM_TRACKS do stop_track(n) end
  if loader_clock then clock.cancel(loader_clock) end
  if redraw_clock then clock.cancel(redraw_clock) end
  if fade_clock then clock.cancel(fade_clock) end
  engine.panic(0)
end

function enc(n, d)
  local t = selected

  if k2_held then
    -- shift layer: the per-track settings that are not the three performance
    -- knobs. k2_used stops the release from also counting as a track-advance.
    k2_used = true
    if n == 1 then
      params:delta(pid(t, "length"), d)
    elseif n == 2 then
      params:delta(pid(t, "level"), d)
    elseif n == 3 then
      params:delta(pid(t, "pan"), d)
    end
  else
    if n == 1 then
      params:delta(pid(t, "turing"), d)
    elseif n == 2 then
      params:delta(pid(t, "speed"), d)
    elseif n == 3 then
      params:delta(pid(t, "density"), d)
    end
  end

  redraw()
end

function key(n, z)
  if z == 1 then note_down(n) else note_up(n) end

  -- K1 is a modifier ONLY. norns claims the short press for its own system
  -- menu, so a script that puts an action on a K1 tap fights the menu for it
  -- and loses: you get the menu instead, and the action only sneaks through
  -- in the sliver between the two thresholds. Held, K1 is ours -- and holding
  -- it is what shows the overview, so there is no page to navigate to and get
  -- stranded on.
  if n == 1 then
    k1_held = (z == 1)
    if k1_held then k1_down_at = util.time() end
    redraw()
    return
  end

  if n == 2 then
    if z == 1 then
      k2_held = true
      k2_used = false
      k2_down_at = util.time()

      -- K3 + K2: step BACK through the track cycle, 1 -> 8. the same pair of
      -- keys as the reroll combo, told apart by which one went down first:
      -- whichever is already held is the modifier. mark both as used so
      -- neither release fires its own tap action on the way out.
      if k3_held then
        k2_used = true
        k3_used = true
        k3_last_at = -1
        selected = ((selected - 2) % NUM_TRACKS) + 1
      end
    else
      k2_held = false
      -- a short press with no encoder movement is a tap: next track.
      if not k2_used and (util.time() - k2_down_at) < TAP_MAX then
        selected = (selected % NUM_TRACKS) + 1
      end
    end
    redraw()
    return
  end

  if n == 3 then
    -- K3 now has to be holdable, because K3 + K2 steps back through the
    -- tracks. So its own action waits for the release: firing start/stop on
    -- the press would toggle the track every time you reached for the combo.
    -- Only being used as a modifier suppresses it -- there is no duration
    -- test here, unlike K1 and K2, so resting on the key still works.
    if z == 1 then
      k3_held = true
      k3_used = false

      -- K1 + K3: lock the selected voice onto the sample it just played, or
      -- release it back to random. flag both keys as used so neither release
      -- fires its own action, and clear the double-press window so locking
      -- twice cannot be mistaken for a fade.
      if k1_held then
        k3_used = true
        k3_last_at = -1
        toggle_lock(selected)
      end

      -- K2 + K3: deal the selected track a new hand of 15 samples.
      if k2_held and not k1_held then
        k2_used = true
        k3_used = true
        k3_last_at = -1
        reroll(selected)
      end

      redraw()
      return
    end

    k3_held = false
    if k3_used then redraw(); return end   -- it was a modifier, not a press

    local now = util.time()
    if k3_last_at > 0 and (now - k3_last_at) < K3_DOUBLE_MAX then
      -- second tap inside the window: fade everything out. the first tap
      -- already toggled a track; the fade stops it again either way.
      fade_all()
      k3_last_at = -1   -- require a fresh pair for the next double
    else
      -- always the selected track, on both pages. having it mean "all tracks"
      -- on the overview made one key do two different things depending on a
      -- mode you cannot see from your fingers -- a bad way to lose a take.
      -- start/stop all now lives in PARAMS, and the double tap still kills
      -- everything from either page.
      toggle_track(selected)
      k3_last_at = now
    end
    redraw()
    return
  end
end

-- ----------------------------------------------------------------------
-- screen
-- ----------------------------------------------------------------------

local function speed_text(s)
  if math.abs(s) <= SPEED_DEADZONE then return "stop" end
  return string.format("%.1fx %s", math.abs(s), s < 0 and "rev" or "fwd")
end

local function pan_text(p)
  if p < -0.05 then return string.format("L%02d", math.floor(-p * 99))
  elseif p > 0.05 then return string.format("R%02d", math.floor(p * 99))
  else return "C" end
end

-- does step i of track n fire at the current density?
local function gate(t, i)
  return t.reg[i] < params:get(pid(t.index, "density"))
end

-- the register display: one bar per step, height = 1 - value, with the
-- density threshold drawn across as a line. bars poking above the line are
-- the steps that fire, so E3 visibly mows the pattern down.
local function draw_register(t)
  local length = params:get(pid(t.index, "length"))
  local density = params:get(pid(t.index, "density"))
  local bottom, height = 27, 15

  -- density threshold
  local ty = bottom - (density * height)
  screen.level(2)
  screen.move(0, ty)
  screen.line(128, ty)
  screen.stroke()

  for i = 1, length do
    local x = (i - 1) * 8
    local w = 6
    local h = math.max(1, (1 - t.reg[i]) * height)
    local playing_here = (t.pos == i and t.playing)

    if gate(t, i) then
      screen.level(playing_here and 15 or 8)
      screen.rect(x, bottom - h, w, h)
      screen.fill()
    else
      screen.level(playing_here and 8 or 3)
      screen.rect(x + 0.5, bottom - h + 0.5, w - 1, math.max(1, h - 1))
      screen.stroke()
    end
  end

  -- playhead marker under the current step
  if t.playing and t.pos >= 1 and t.pos <= length then
    screen.level(15)
    screen.rect((t.pos - 1) * 8, bottom + 2, 6, 1)
    screen.fill()
  end
end

local function draw_detail()
  local t = tracks[selected]

  -- header: track, folder, transport
  screen.level(15)
  screen.move(0, 7)
  screen.text("T" .. selected)
  screen.level(3)
  screen.move(14, 7)
  screen.text(t.label)
  screen.level(t.playing and 15 or 3)
  screen.move(128, 7)
  screen.text_right(t.playing and "play" or "stop")

  draw_register(t)

  -- two columns of readouts. the shift-layer values (steps / level / pan)
  -- brighten while K2 is held so you can see what the encoders moved onto.
  local shift = k2_held and 15 or 5

  screen.level(k2_held and 5 or 15)
  screen.move(0, 40)
  screen.text(string.format("turing %d%%", math.floor(params:get(pid(selected, "turing")) * 100)))
  screen.move(0, 49)
  screen.text(speed_text(params:get(pid(selected, "speed"))))
  screen.move(0, 58)
  screen.text(string.format("dens %d%%", math.floor(params:get(pid(selected, "density")) * 100)))

  screen.level(shift)
  screen.move(128, 40)
  screen.text_right(string.format("steps %d", params:get(pid(selected, "length"))))
  screen.move(128, 49)
  screen.text_right(string.format("lvl %d", math.floor(params:get(pid(selected, "level")) * 99)))
  screen.move(128, 58)
  screen.text_right("pan " .. pan_text(params:get(pid(selected, "pan"))))

  -- footer: what is actually going to play. while K2 is held it turns into a
  -- hint instead, so the reroll combo is discoverable rather than folklore.
  screen.level(3)
  screen.move(0, 64)
  -- K1 is not handled here: holding it shows the overview instead, and that
  -- page carries its own hint.
  local mod = active_modifier()
  if mod == 2 or mod == 3 then
    screen.level(15)
    screen.text(mod == 2 and "K2+K3 reroll 15 samples" or "K3+K2 previous track")
    return
  end
  if t.pending > 0 then
    screen.text(string.format("loading %d", t.pending))
  elseif scan_error then
    screen.text(scan_error)
  elseif is_locked(selected) then
    local f = t.files[params:get(pid(selected, "file"))]
    screen.level(15)
    screen.text("lock " .. (f and f:gsub("%.%a+$", "") or "-"))
  else
    -- show what the last trigger actually reached for, so random mode is not
    -- a black box; fall back to the file count before anything has fired.
    local f = t.last_file
    screen.text(string.format("rnd  %s", f and f:gsub("%.%a+$", "")
      or (#t.files .. " files")))
  end
  screen.move(128, 64)
  screen.text_right(DIVISIONS[params:get(pid(selected, "div"))].name)
end

local function draw_overview()
  screen.level(15)
  screen.move(0, 7)
  screen.text("overview")
  -- you are only ever here with K1 down, so the header doubles as the hint
  -- for what the other two keys do while peeking. status wins when there is
  -- any: a fade in progress, then loading.
  local pending = 0
  for n = 1, NUM_TRACKS do pending = pending + tracks[n].pending end

  screen.move(128, 7)
  if fading then
    screen.level(3)
    screen.text_right("fading")
  elseif pending > 0 then
    screen.level(3)
    screen.text_right(string.format("loading %d", pending))
  else
    screen.level(15)
    screen.text_right("K2 trk  K3 " ..
      (is_locked(selected) and "unlock" or "lock"))
  end

  for n = 1, NUM_TRACKS do
    local t = tracks[n]
    local y = 8 + (n * 7)
    local length = params:get(pid(n, "length"))

    -- selection marker + track number
    screen.level(n == selected and 15 or 3)
    screen.move(0, y)
    screen.text(n == selected and (">" .. n) or (" " .. n))

    -- transport dot
    screen.level(t.playing and 15 or 2)
    screen.rect(12, y - 4, 3, 3)
    screen.fill()

    -- compact register: one tick per step, filled if it fires
    for i = 1, length do
      local x = 19 + ((i - 1) * 4)
      if gate(t, i) then
        screen.level((t.playing and t.pos == i) and 15 or 7)
        screen.rect(x, y - 5, 3, 5)
        screen.fill()
      else
        screen.level((t.playing and t.pos == i) and 7 or 2)
        screen.rect(x, y - 1, 3, 1)
        screen.fill()
      end
    end

    -- level bar on the right, then a lock marker in the gap before the speed
    local lvl = params:get(pid(n, "level"))
    screen.level(3)
    screen.rect(86, y - 4, 16, 3)
    screen.stroke()
    screen.level(10)
    screen.rect(86, y - 4, math.max(0, lvl * 16), 3)
    screen.fill()

    if is_locked(n) then
      screen.level(15)
      screen.move(104, y)
      screen.text("L")
    end

    -- speed, abbreviated
    screen.level(4)
    screen.move(128, y)
    local s = params:get(pid(n, "speed"))
    screen.text_right(math.abs(s) <= SPEED_DEADZONE and "--"
      or string.format("%s%.1f", s < 0 and "-" or "", math.abs(s)))
  end
end

function redraw()
  -- safety valve. norns can swallow a K1 release when its menu takes over,
  -- and a peek stuck on forever would be worse than the bug it replaced.
  -- nobody holds K1 for ten seconds on purpose.
  if k1_held and (util.time() - k1_down_at) > K1_PEEK_MAX then
    k1_held = false
    note_up(1)
  end

  screen.clear()
  if k1_held then draw_overview() else draw_detail() end
  screen.update()
end
