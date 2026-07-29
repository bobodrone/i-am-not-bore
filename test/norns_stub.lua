-- Minimal norns API stub, enough to load and drive a script for real.
local S = {}

-- ---------------- fake filesystem ----------------
S.fs = { dirs = {}, files = {} }   -- files[dir] = {names}
function S.mkfolder(root, name, n)
  S.fs.dirs[root] = S.fs.dirs[root] or {}
  table.insert(S.fs.dirs[root], name .. "/")
  local list = {}
  for i = 1, n do list[i] = string.format("snd-%04d.wav", i) end
  S.fs.files[root .. name .. "/"] = list
end

-- ---------------- time ----------------
S.now = 1000.0

-- ---------------- clock ----------------
S.clocks = {}
local clock = {}
function clock.run(fn, ...)
  local co = coroutine.create(fn)
  local id = #S.clocks + 1
  S.clocks[id] = { co = co, alive = true }
  local ok, err = coroutine.resume(co, ...)
  if not ok then error("clock.run body failed: " .. tostring(err)) end
  return id
end
function clock.cancel(id) if S.clocks[id] then S.clocks[id].alive = false end end
function clock.sleep(_) coroutine.yield() end
function clock.sync(_) coroutine.yield() end
function clock.get_tempo() return 124 end
S.clock = clock

-- resume clock `id` n times
function S.pump(id, n)
  local c = S.clocks[id]
  if not c then error("no clock " .. tostring(id)) end
  for _ = 1, n do
    if coroutine.status(c.co) == "dead" then break end
    local ok, err = coroutine.resume(c.co)
    if not ok then error("clock body failed: " .. tostring(err)) end
  end
end
-- pump every live clock
function S.pump_all(n)
  for id, c in pairs(S.clocks) do
    if c.alive and coroutine.status(c.co) ~= "dead" then S.pump(id, n) end
  end
end

-- ---------------- engine ----------------
S.calls = {}
local engine = {}
setmetatable(engine, { __newindex = function(t, k, v) rawset(t, k, v) end })
local function rec(name)
  return function(...) table.insert(S.calls, { name = name, args = { ... } }) end
end
engine.trackLevel = rec("trackLevel")
engine.trackPan   = rec("trackPan")
engine.setMaster  = rec("setMaster")
engine.loadSlot   = rec("loadSlot")
engine.trig       = rec("trig")
engine.panic      = rec("panic")
S.engine = engine

function S.calls_named(n)
  local out = {}
  for _, c in ipairs(S.calls) do if c.name == n then out[#out + 1] = c end end
  return out
end

-- ---------------- controlspec ----------------
local controlspec = {}
function controlspec.new(min, max, warp, step, default, units)
  return { minval = min, maxval = max, warp = warp, step = step,
           default = default, units = units }
end
S.controlspec = controlspec

-- ---------------- util ----------------
local util = {}
function util.file_exists(p)
  if S.fs.dirs[p] then return true end
  if S.fs.files[p] then return true end
  return false
end
function util.scandir(p)
  if S.fs.dirs[p] then
    local out = {}
    for _, d in ipairs(S.fs.dirs[p]) do out[#out + 1] = d end
    return out
  end
  return S.fs.files[p] or {}
end
function util.clamp(v, a, b) return math.max(a, math.min(b, v)) end
function util.time() return S.now end
function util.round(v) return math.floor(v + 0.5) end
S.util = util

-- ---------------- params ----------------
local P = { list = {}, order = {} }
local function reg(p) P.list[p.id] = p; P.order[#P.order + 1] = p.id; return p end
function P:add_separator(id, name) end
function P:add_group(id, name, n) P.last_group = { id = id, n = n, count = 0 } end
function P:add_text(id, name, text)
  reg({ id = id, t = "text", value = text })
  if P.last_group then P.last_group.count = P.last_group.count + 1 end
end
function P:add_trigger(id, name)
  reg({ id = id, t = "trigger" })
  if P.last_group then P.last_group.count = P.last_group.count + 1 end
end
function P:add_option(id, name, options, default)
  reg({ id = id, t = "option", options = options, value = default or 1,
        min = 1, max = #options })
  if P.last_group then P.last_group.count = P.last_group.count + 1 end
end
function P:add_number(id, name, min, max, default, formatter)
  reg({ id = id, t = "number", min = min, max = max, value = default,
        formatter = formatter, step = 1 })
  if P.last_group then P.last_group.count = P.last_group.count + 1 end
end
function P:add_control(id, name, spec)
  reg({ id = id, t = "control", min = spec.minval, max = spec.maxval,
        value = spec.default, step = spec.step })
  if P.last_group then P.last_group.count = P.last_group.count + 1 end
end
function P:set_action(id, fn) P.list[id].action = fn end
function P:lookup_param(id)
  local p = P.list[id]
  if not p then error("lookup_param: no such param '" .. tostring(id) .. "'") end
  return p
end
function P:get(id)
  local p = P.list[id]
  if not p then error("params:get: no such param '" .. tostring(id) .. "'") end
  return p.value
end
function P:string(id)
  local p = P:lookup_param(id)
  if p.t == "option" then return p.options[p.value] end
  return tostring(p.value)
end
function P:set(id, v, silent)
  local p = P:lookup_param(id)
  if p.t == "trigger" then
    if p.action then p.action(1) end
    return
  end
  if p.min then v = math.max(p.min, math.min(p.max, v)) end
  p.value = v
  if p.action and not silent then p.action(v) end
end
function P:delta(id, d)
  local p = P:lookup_param(id)
  P:set(id, p.value + (p.step or 1) * d)
end
function P:bang() end
S.params = P

-- clock_tempo, as norns provides
reg({ id = "clock_tempo", t = "number", min = 1, max = 300, value = 120 })

-- ---------------- screen ----------------
local screen = {}
S.draw_ops = 0
S.texts = {}
local noop = function(...) S.draw_ops = S.draw_ops + 1 end
for _, k in ipairs({ "clear","level","move","rect","fill",
                     "stroke","line","circle","update","aa","font_size" }) do
  screen[k] = noop
end
-- capture rendered text so tests can assert on what the screen actually says
local function capture(s)
  S.draw_ops = S.draw_ops + 1
  S.texts[#S.texts + 1] = tostring(s)
end
screen.text = capture
screen.text_right = capture
screen.clear = function() S.draw_ops = S.draw_ops + 1; S.texts = {} end
function S.screen_says(sub)
  for _, t in ipairs(S.texts) do if t:find(sub, 1, true) then return true, t end end
  return false
end
S.screen = screen

S._path = { audio = "/audio/", dust = "/dust/", data = "/data/" }

-- install globals
function S.install()
  _G.engine = S.engine
  _G.params = S.params
  _G.clock = S.clock
  _G.screen = S.screen
  _G._path = S._path
  _G.norns = { state = {} }
  package.loaded["util"] = S.util
  package.loaded["controlspec"] = S.controlspec
end

return S
