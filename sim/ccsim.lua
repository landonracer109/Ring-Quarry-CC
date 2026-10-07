-- Like CC 1.63 (LuaJ): calling next() with a key that was removed from the
-- table during the loop is an error ("invalid key to 'next'").
function CC_NEXT(t, k)
  if k ~= nil and rawget(t, k) == nil then error("invalid key to 'next'", 2) end
  return next(t, k)
end
function CC_PAIRS(t) return CC_NEXT, t, nil end
if os.getenv("SIM_NOJIT") then jit.off() end
-- Watchdog: one scheduler step (one event handed to one computer) that runs
-- over 50M instructions means a program loops without ever waiting.
-- (LuaJIT hooks are global, so this counts everything; reset per step.)
local watch_steps = 0
local WATCH_MAIN = setmetatable({}, { __mode = "k" }) -- computers' main coroutines
function WATCH(co) end
function WATCH_COMPUTER(co) WATCH_MAIN[co] = true end
local raw_resume = coroutine.resume
coroutine.resume = function(co, ...)
  if WATCH_MAIN[co] then watch_steps = 0 end
  return raw_resume(co, ...)
end
debug.sethook(function()
  watch_steps = watch_steps + 1
  if watch_steps > 500 then
    watch_steps = 0
    local tb = debug.traceback("SIM STUCK: a program loops without waiting", 2)
    io.stderr:write(tb .. "\n")
    error(tb, 0)
  end
end, "", 1e5)
-- ccsim.lua -- a small ComputerCraft 1.63 simulator for the quarry programs.
--
-- Runs the real control / service / miner programs as coroutines in a
-- discrete-event world, reproducing the CC behaviors that matter here:
--   * turtle actions take time, and any event (including rednet messages)
--     that arrives while a turtle is busy is DISCARDED, like real CC
--   * turtles can dig other turtles (reported as a fatal error)
--   * fuel, 16-slot inventories, chests, bedrock
--
-- Usage: luajit ccsim.lua [lanes] [length] [depth] [chunks] [stop_at_seconds] [bedrock_y] [loaders]
--        (use "-" for stop_at_seconds to not press S)

local LANES     = tonumber(arg[1]) or 3
local LENGTH    = tonumber(arg[1]) or 3 -- (ring quarry: a chunk is LANES x LANES)
local DEPTH     = tonumber(arg[3]) or 8
local CHUNKS    = tonumber(arg[4]) or 2 -- rings to mine
local STOP_AT   = tonumber(arg[5])        -- press S at this sim time (optional)
local BEDROCK_Y = tonumber(arg[6]) or -DEPTH -- flat bedrock: DEPTH layers can be mined
local BOTTOM = BEDROCK_Y + 1 -- lowest layer the quarry should clear
local LOADERS = tonumber(arg[7]) or 8
local TIME_LIMIT = tonumber(os.getenv("SIM_TLIMIT")) or 60000
-- arg 11: "deploy" = turtles start with only the boot loader (from Join)
-- and get their programs from the controller; "deploy+update@T" also
-- presses U on the controller at time T, with GitHub serving a newer
-- version of every program.
local DEPLOY = (arg[11] or ""):find("^deploy") ~= nil
local UPDATE_AT = tonumber((arg[11] or ""):match("update@([%d%.]+)"))
local UPDATE_MARK = "\n-- simulated update v2\n"
local FAKE_GET = "-- fake get program --"

local function read_host(name)
  local h = assert(io.open("../" .. name, "rb")) -- the program files
  local text = h:read("*a")
  h:close()
  -- the controller's chunk size is fixed at 16; tests use smaller ones
  if name == "ControlCPU" then
    text = text:gsub("local CHUNK_SIZE = 16", "local CHUNK_SIZE = " .. LENGTH)
  end
  if name == "TurtleTest1" then
    text = text:gsub("local CHUNK = 16", "local CHUNK = " .. LENGTH)
  end
  return text
end
local PROGRAM_DIR = "../"

---------------------------------------------------------------------------
-- Event scheduler
---------------------------------------------------------------------------
local now = 0
-- mobs: [key] = { hp=, gone= }; SIM_MOB="lane1@600@deep,lane2@300@shallow@200"
-- (at time T a mob steps in front of that turtle's next forward move, deep
-- = 5+ layers down, shallow = 1-3 down; @life = it wanders off after that)
local mobs, mob_plan, attacks, mobs_killed = {}, {}, 0, 0
for spec in (os.getenv("SIM_MOB") or ""):gmatch("[^,]+") do
  local name, at, kind, life = spec:match("^(%w+)@(%d+)@(%a+)@?(%d*)$")
  if name then
    mob_plan[name] = { at = tonumber(at), deep = kind == "deep", life = tonumber(life) }
  end
end
local queue, qseq = {}, 0
local fatal_errors, warnings = {}, {}

-- Server load counters: per computer and kind, how many per second.
--   net   = rednet messages sent;  recv = messages delivered (a broadcast
--   reaches every computer in range);  mon = monitor calls;  file = file
--   writes;  turtle = turtle commands
local stats = {}
local function count(who, kind, n)
  local k = who .. "\0" .. kind
  local t = stats[k]
  if not t then t = { who = who, kind = kind, total = 0, per = {} }; stats[k] = t end
  local sec = math.floor(now)
  n = n or 1
  t.total = t.total + n
  t.per[sec] = (t.per[sec] or 0) + n
end
-- SIM_OUT: folder for this run's logs (so several runs can go at once)
local OUT = os.getenv("SIM_OUT") or ""
local logf = assert(io.open(OUT .. "sim.log", "w"))
logf:setvbuf("line")

local function schedule(t, comp, ev)
  qseq = qseq + 1
  local e = { t = t, seq = qseq, comp = comp, ev = ev }
  local i = #queue
  while i >= 1 and (queue[i].t > t or (queue[i].t == t and queue[i].seq > e.seq)) do
    i = i - 1
  end
  table.insert(queue, i + 1, e)
end

local function log(who, text)
  logf:write(string.format("[%8.2f] %-8s %s\n", now, who, text))
  logf:flush()
end

local function fatal(text)
  table.insert(fatal_errors, string.format("t=%.1f %s", now, text))
  log("FATAL", text)
end

local function warn(text)
  table.insert(warnings, string.format("t=%.1f %s", now, text))
  log("WARN", text)
end

---------------------------------------------------------------------------
-- World
---------------------------------------------------------------------------
local blocks = {}      -- "x,y,z" -> { name=, inv= }
local turtles_at = {}  -- "x,y,z" -> computer
-- World autosave (like Minecraft's, every 45 s) and crash rollback: blocks
-- changed since the last autosave are remembered here with their old value.
local AUTOSAVE = 45
local block_undo = {}
local function set_block(k, v)
  if block_undo[k] == nil then block_undo[k] = { old = blocks[k] } end
  blocks[k] = v
end
local ground_items = 0
local dug_outside = 0

local function key(x, y, z) return x .. "," .. y .. "," .. z end

-- Chunk loading along the tunnel: chunk 1 (z < LENGTH) and home are loaded
-- because the player is nearby; later chunks only once a loader is inside.
local loaded_chunks = {} -- ["a,b"] = true while a loader is in it
-- chunk (a, b): a east, b north of the control chunk (z = -LENGTH .. -1)
local function chunk_ab(x, z) return math.floor(x / LENGTH), math.floor(z / LENGTH) + 1 end
local function ring_of(a, b) return math.max(math.abs(a), math.abs(b)) end
local function is_loaded(x, z)
  local a, b = chunk_ab(x, z)
  return ring_of(a, b) <= 1 or loaded_chunks[a .. "," .. b] == true
end
-- never dug, never entered by a miner: the control chunk, the service
-- home column (chests) and its marker block's column
local function protected(x, z)
  if x >= 0 and x < LENGTH and z < 0 and z >= -LENGTH then return true end
  return x == -1 and (z == -1 or z == 0)
end
local RINGS = CHUNKS
local R_MIN, R_MAX = -(RINGS + 1) * LENGTH, (RINGS + 1) * LENGTH + LENGTH - 1 -- x range of the world
local Z_MIN, Z_MAX = -(RINGS + 1) * LENGTH - LENGTH, (RINGS + 1) * LENGTH - 1
local move_refusals = 0
local service_home_trips = 0
local bad_fuel_handed = 0

local DROPS = { stone = "cobblestone", coal_ore = "coal", dirt = "dirt",
  loader = "loader", chest = "chest", gravel = "gravel", iron_ore = "iron_ore" }
local FUEL_VALUE = { coal = 80, coal_block = 800 }
local SIM_FUEL = os.getenv("SIM_FUEL") or "coal"
local FUEL_LIMIT = tonumber(os.getenv("SIM_FUEL_LIMIT")) or 100000 -- advanced turtles
local fuel_wasted = 0
local SIM_TRASH = os.getenv("SIM_NOTRASH") == nil
local JUNK = { cobblestone = true, dirt = true, gravel = true }
local trashed = {} -- [item] = count thrown into trash cans
local by_cmd = {} -- [message cmd] = sends ("*" = broadcast)
-- SIM_RANGE="N@T1-T2,...": between T1 and T2 the radio only reaches N
-- blocks (rain). The main computer stands at (0, 0, -4).
local RANGES = {}
for n, a, b in (os.getenv("SIM_RANGE") or ""):gmatch("(%d+)@([%d%.]+)%-([%d%.]+)") do
  RANGES[#RANGES + 1] = { n = tonumber(n), from = tonumber(a), to = tonumber(b) }
end
local radio_lost = 0
local function radio_reaches(a, b)
  local limit
  for _, r in ipairs(RANGES) do
    if now >= r.from and now < r.to then limit = r.n end
  end
  if not limit then return true end
  local function pos(c) if c.x then return c.x, c.y, c.z end return 0, 0, -4 end
  local ax, ay, az = pos(a)
  local bx, by, bz = pos(b)
  return (ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2 <= limit * limit
end
uploads = {} -- log uploads (see http in the program environment)
local sec_cmds = {} -- [second] = { "lane3:status", ... } (what made up each second)
local function note_send(who, msg)
  local sec = math.floor(now)
  sec_cmds[sec] = sec_cmds[sec] or {}
  table.insert(sec_cmds[sec], who .. ":" .. (type(msg) == "table" and tostring(msg.cmd) .. (msg.state and ("(" .. msg.state .. ")") or "") or "?"))
end
-- SIM_IDLE=N: after the run, stay N more seconds and count what the idle
-- quarry still does (messages, program wake-ups)
local IDLE = tonumber(os.getenv("SIM_IDLE"))
local net_total, wake_total = 0, 0
local idle_from, idle_net0, idle_wake0
-- SIM_FROZENCLOCK=1: the in-game clock stands still (daylight cycle off)
local FROZEN = os.getenv("SIM_FROZENCLOCK")
-- The in-game clock is saved with the world: a crash puts it back to the
-- autosave, and it stands still while the server is down.
local world_offset = 0
local function world_now() return now - world_offset end
-- SIM_TIMEBACK=T: at T an admin sets the time back ("/time set day"): the
-- clock jumps back 900 s with no crash
local TIMEBACK = tonumber(os.getenv("SIM_TIMEBACK"))
local trash_dumps = {} -- [miner name] = times it put its trash can down
-- SIM_ORES=x: share of blocks that are rare ores (default 0.018; the real
-- world has far more ore kinds and they fill a miner's slots)
local RARE = tonumber(os.getenv("SIM_ORES")) or 0.018

local function in_quarry(x, y, z)
  local a, b = chunk_ab(x, z)
  return ring_of(a, b) >= 1 and ring_of(a, b) <= RINGS and not protected(x, z)
    and y <= 0 and y >= BOTTOM
end

-- Inserts items into an inventory, starting at `start` and wrapping.
-- Returns how many didn't fit.
local function insert(inv, size, name, count, start)
  start = start or 1
  for k = 0, size - 1 do
    local i = (start - 1 + k) % size + 1
    local s = inv[i]
    if s and s.name == name and s.count < 64 then
      local add = math.min(64 - s.count, count)
      s.count = s.count + add
      count = count - add
    elseif not s then
      local add = math.min(64, count)
      inv[i] = { name = name, count = add }
      count = count - add
    end
    if count == 0 then return 0 end
  end
  return count
end

local function inv_total(inv, size)
  local t, byname = 0, {}
  for i = 1, size do
    local s = inv[i]
    if s then
      t = t + s.count
      byname[s.name] = (byname[s.name] or 0) + s.count
    end
  end
  return t, byname
end

local function serialize(v)
  local t = type(v)
  if t == "table" then
    local parts = {}
    for k, x in pairs(v) do
      local ks = type(k) == "string" and string.format("[%q]", k) or ("[" .. tostring(k) .. "]")
      parts[#parts + 1] = ks .. "=" .. serialize(x)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then return string.format("%q", v)
  elseif t == "number" then return string.format("%.17g", v)
  elseif t == "boolean" or t == "nil" then return tostring(v)
  end
  error("can't serialize " .. t)
end

local function unserialize(text)
  local fn = loadstring("return " .. text)
  if not fn then return nil end
  setfenv(fn, {})
  local ok, r = pcall(fn)
  if ok then return r end
end

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local r = {}
  for k, x in pairs(v) do r[deepcopy(k)] = deepcopy(x) end
  return r
end

---------------------------------------------------------------------------
-- Computers
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Advanced Monitor (fake): records the text so the dashboard can be viewed
---------------------------------------------------------------------------
local COLORS = {
  white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32,
  pink = 64, gray = 128, lightGray = 256, cyan = 512, purple = 1024,
  blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768,
}
local VALID_COLOR = {}
for _, v in pairs(COLORS) do VALID_COLOR[v] = true end

local function make_monitor(bw, bh)
  local m, scale, w, h, buf = {}, 1, 0, 0, {}
  local cx, cy = 1, 1
  local function resize()
    w = math.floor((bw - 0.3125) * 64 / (6 * scale) + 0.5)
    h = math.floor((bh - 0.3125) * 64 / (9 * scale) + 0.5)
    buf = {}
    for y = 1, h do buf[y] = string.rep(" ", w) end
  end
  resize()
  m.overflows = 0
  function m.setTextScale(s)
    assert(s == 0.5 or s == 1 or s == 1.5 or s == 2 or s == 2.5 or s == 3 or s == 3.5 or s == 4 or s == 4.5 or s == 5, "bad text scale " .. tostring(s))
    scale = s
    resize()
  end
  function m.getSize() return w, h end
  -- where a label is on screen (nth time it shows, top to bottom)
  function m.find(label, nth)
    nth = nth or 1
    for y = 1, h do
      local from = 1
      while true do
        local i = buf[y]:find(label, from, true)
        if not i then break end
        nth = nth - 1
        if nth == 0 then return i + math.floor(#label / 2), y end
        from = i + 1
      end
    end
  end
  function m.isColor() return true end
  function m.setCursorPos(x, y) cx, cy = x, y end
  function m.setTextColor(c) assert(VALID_COLOR[c], "bad text color " .. tostring(c)) end
  function m.setBackgroundColor(c) assert(VALID_COLOR[c], "bad background color " .. tostring(c)) end
  function m.write(s)
    s = tostring(s)
    if cx + #s - 1 > w then m.overflows = m.overflows + 1 end
    if cy >= 1 and cy <= h then
      local line = buf[cy]
      for i = 1, #s do
        local x = cx + i - 1
        if x >= 1 and x <= w then line = line:sub(1, x - 1) .. s:sub(i, i) .. line:sub(x + 1) end
      end
      buf[cy] = line
    end
    cx = cx + #s
  end
  function m.clear() for y = 1, h do buf[y] = string.rep(" ", w) end end
  function m.clearLine() if buf[cy] then buf[cy] = string.rep(" ", w) end end
  function m.setCursorBlink() end
  for _, name in ipairs({ "setTextScale", "setCursorPos", "setTextColor",
      "setBackgroundColor", "write", "clear", "clearLine" }) do
    local fn = m[name]
    m[name] = function(...) count("control", "mon"); return fn(...) end
  end
  function m.dump()
    local border = "+" .. string.rep("-", w) .. "+"
    local out = { string.format("monitor %dx%d blocks, text scale %s -> %dx%d chars", bw, bh, tostring(scale), w, h), border }
    for y = 1, h do out[#out + 1] = "|" .. buf[y] .. "|" end
    out[#out + 1] = border
    return table.concat(out, "\n")
  end
  return m
end

local MON_W = tonumber(arg[9] and arg[9]:match("^(%d+)x")) or 6
local MON_H = tonumber(arg[9] and arg[9]:match("x(%d+)$")) or 5
local monitor = make_monitor(MON_W, MON_H)

local computers = {}   -- by id
local next_id = 1
local DIRS = { [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } }

-- CC 1.63 parallel API (same event-filter rules as the real one)
local function make_parallel(os_api)
  local function run_until_limit(routines, limit)
    local count, living = #routines, #routines
    local filters, event = {}, {}
    while true do
      for n = 1, count do
        local r = routines[n]
        if r then
          if filters[r] == nil or filters[r] == event[1] or event[1] == "terminate" then
            local ok, param = coroutine.resume(r, unpack(event))
            if not ok then error(param, 0) end
            filters[r] = param
            if coroutine.status(r) == "dead" then
              routines[n] = nil
              living = living - 1
              if living <= limit then return n end
            end
          end
        end
      end
      event = { os_api.pullEventRaw() }
    end
  end
  return {
    waitForAny = function(...)
      local rs = {}
      for i, f in ipairs({ ... }) do rs[i] = coroutine.create(f); WATCH(rs[i]) end
      return run_until_limit(rs, #rs - 1)
    end,
  }
end

local function new_computer(o)
  local c = {
    id = next_id, name = o.name, is_turtle = o.turtle,
    x = o.x, y = o.y, z = o.z, facing = o.facing or 0,
    inv = o.inv or {}, slot = 1, fuel = o.fuel or 0,
    input = o.input or {}, quiet = o.quiet, dropped = 0, moves = 0, gen = 0,
    files = o.files or {}, running = {},
  }
  if o.program then c.files[o.run_name or o.program] = read_host(o.program) end
  -- what runs at boot: a path in c.files plus its arguments
  c.boot = o.boot or { o.run_name or o.program }
  next_id = next_id + 1
  computers[c.id] = c
  if c.is_turtle then turtles_at[key(c.x, c.y, c.z)] = c end

  local timer_id = 0
  local os_api = {}
  function os_api.startTimer(t)
    timer_id = timer_id + 1
    schedule(now + math.max(t, 0.05), c, { "timer", timer_id })
    return timer_id
  end
  function os_api.pullEventRaw(filter) return coroutine.yield(filter) end
  function os_api.pullEvent(filter)
    local ev = { coroutine.yield(filter) }
    if ev[1] == "terminate" then error("Terminated", 0) end
    return unpack(ev)
  end
  function os_api.clock() return now end
  function os_api.time() return FROZEN and 7.25 or (world_now() / 50) % 24 end
  function os_api.day() return FROZEN and 3 or math.floor(world_now() / 1200) end
  function os_api.getComputerID() return c.id end
  function os_api.reboot()
    schedule(now + 1, c, { "__reboot", 1 })
    while true do coroutine.yield("__never") end
  end
  function os_api.queueEvent(...) schedule(now, c, { ... }) end

  local function sleep(t)
    local id = os_api.startTimer(t)
    while true do
      local _, p = os_api.pullEvent("timer")
      if p == id then return end
    end
  end
  os_api.sleep = sleep

  local rednet = {}
  function rednet.open() end
  local function deliver(target, msg, proto)
    if target and target ~= c and not radio_reaches(c, target) then
      radio_lost = radio_lost + 1
      return
    end
    if target and target ~= c then
      schedule(now + 0.05, target, { "rednet_message", c.id, deepcopy(msg), proto })
    end
  end
  function rednet.send(id, msg, proto)
    count(c.name, "net")
    net_total = net_total + 1
    note_send(c.name, msg)
    by_cmd[(type(msg) == "table" and msg.cmd or "?")] = (by_cmd[(type(msg) == "table" and msg.cmd or "?")] or 0) + 1
    count("ALL", "recv")
    deliver(computers[id], msg, proto)
    return true
  end
  function rednet.broadcast(msg, proto)
    count(c.name, "net")
    net_total = net_total + 1
    note_send(c.name, msg)
    by_cmd[(type(msg) == "table" and msg.cmd or "?") .. "*"] = (by_cmd[(type(msg) == "table" and msg.cmd or "?") .. "*"] or 0) + 1
    for _, t in pairs(computers) do
      if t ~= c then count("ALL", "recv") end
      deliver(t, msg, proto)
    end
  end
  function rednet.receive(proto_filter, timeout) -- copied from CC 1.63
    if type(proto_filter) == "number" and timeout == nil then
      proto_filter, timeout = nil, proto_filter
    end
    local timer, filter
    if timeout then timer = os_api.startTimer(timeout) else filter = "rednet_message" end
    while true do
      local ev, p1, p2, p3 = os_api.pullEvent(filter)
      if ev == "rednet_message" then
        if proto_filter == nil or p3 == proto_filter then return p1, p2, p3 end
      elseif ev == "timer" and p1 == timer then
        return nil
      end
    end
  end

  -- Turtle API ------------------------------------------------------------
  -- Every action waits for a "turtle_response" event, discarding anything
  -- else that arrives meanwhile -- exactly how real turtles lose messages.
  local op_id = 0
  -- The command takes effect one tick after it's issued, and the program
  -- hears back after `duration`. A restart before the effect loses the
  -- command; a restart after it keeps the effect but the program never
  -- hears about it -- just like a real server stopping.
  local function op(duration, fn)
    count(c.name, "turtle")
    op_id = op_id + 1
    local my = op_id
    schedule(now + 0.05, c, { "__effect", fn, my, c.gen, math.max(duration - 0.05, 0) })
    while true do
      local ev = { coroutine.yield("turtle_response") }
      if ev[2] == my then return unpack(ev, 3, ev.n or #ev) end
    end
  end

  local function front(dir) -- dir: "f", "b", "u", "d"
    if dir == "u" then return c.x, c.y + 1, c.z end
    if dir == "d" then return c.x, c.y - 1, c.z end
    local d = DIRS[dir == "b" and (c.facing + 2) % 4 or c.facing]
    return c.x + d[1], c.y, c.z + d[2]
  end

  local function move(dir)
    return op(0.4, function()
      if c.fuel <= 0 then return false, "Out of fuel" end
      local nx, ny, nz = front(dir)
      local k = key(nx, ny, nz)
      -- SIM_MOB: a mob steps in front of this turtle (see mob_plan)
      local plan = mob_plan[c.name]
      if plan and not plan.done and now >= plan.at and dir == "f" and not blocks[k]
          and not turtles_at[k] and ((plan.deep and ny <= -5) or (not plan.deep and ny < 0 and ny > -4)) then
        plan.done = true
        mobs[k] = { hp = 4, gone = plan.life and (now + plan.life) or nil }
        log("MOB", "a mob steps in front of " .. c.name .. " at " .. k)
      end
      local mob = mobs[k]
      if mob and mob.gone and now >= mob.gone then
        mobs[k] = nil
        log("MOB", "the mob at " .. k .. " wanders off")
        mob = nil
      end
      if blocks[k] or turtles_at[k] or mob then return false, "Movement obstructed" end
      if c.name ~= "service" and protected(nx, nz) then
        fatal(c.name .. " moved into a PROTECTED spot " .. k)
      end
      if not is_loaded(nx, nz) then
        -- (at y = 0 that is a lane waiting to step into the next chunk until
        -- its loader is in: expected. Anywhere else a route went wrong.)
        -- (a single refused move is harmless: e.g. a facing test step after
        -- a restart. The same move refused 3 times in a row is a route
        -- through an unloaded chunk: stuck.)
        if c.refused_k == k then c.refused_n = c.refused_n + 1 else c.refused_k, c.refused_n = k, 1 end
        if ny ~= 0 and c.refused_n == 3 then move_refusals = move_refusals + 1 end
        local ra, rb = chunk_ab(nx, nz)
        log("REFUSED", c.name .. " -> " .. k .. " (chunk " .. ra .. "," .. rb .. " not loaded)")
        return false, "Cannot leave loaded world"
      end
      turtles_at[key(c.x, c.y, c.z)] = nil
      c.x, c.y, c.z = nx, ny, nz
      turtles_at[k] = c
      c.fuel = c.fuel - 1
      c.moves = c.moves + 1
      if c.name == "service" and os.getenv("SIMDEBUG") then log("MOVE", string.format("service -> %d,%d,%d facing %d", c.x, c.y, c.z, c.facing)) end
      if c.name == "service" and k == "-1,0,-1" then service_home_trips = service_home_trips + 1 end
      return true
    end)
  end

  local function detect(dir)
    return op(0.05, function()
      local k = key(front(dir))
      return blocks[k] ~= nil or turtles_at[k] ~= nil
    end)
  end

  -- is the block there the same as the item in the selected slot?
  local function compare(dir)
    return op(0.05, function()
      local b, st = blocks[key(front(dir))], c.inv[c.slot]
      return b ~= nil and st ~= nil and b.name == st.name
    end)
  end

  local function dig(dir)
    return op(0.4, function()
      local x, y, z = front(dir)
      local k = key(x, y, z)
      local t = turtles_at[k]
      if t then
        fatal(c.name .. " DUG TURTLE " .. t.name .. " at " .. k)
        return false
      end
      local b = blocks[k]
      if not b or b.name == "bedrock" then return false end
      if b.name == "chest" then fatal(c.name .. " dug a chest at " .. k) end
      -- (the service turtle may clear its own row: z = -1, y = 0)
      if protected(x, z) and not (c.name == "service" and z == -1 and y == 0) then
        fatal(c.name .. " DUG A PROTECTED BLOCK at " .. k)
      end
      if b.name == "loader" then
        -- taking a loader unloads its chunk: nobody may still be in there
        local a, bb = chunk_ab(x, z)
        local ch = a .. "," .. bb
        log(c.name, "picked up the loader at " .. k .. " (chunk " .. ch .. ")")
        loaded_chunks[ch] = nil
        if ring_of(a, bb) > 1 then
          for _, o in pairs(computers) do
            local oa, ob = chunk_ab(o.x or 0, o.z or 0)
            if o ~= c and o.is_turtle and oa == a and ob == bb then
              fatal(c.name .. " took the loader of chunk " .. ch .. " while "
                .. o.name .. " was still in it (" .. o.x .. "," .. o.y .. "," .. o.z .. ")")
            end
          end
        end
      end
      if not in_quarry(x, y, z) then dug_outside = dug_outside + 1 end
      set_block(k, nil)
      -- SIM_DIGSLOT1=1: dug items go in from slot 1, not the selected slot
      local left = insert(c.inv, 16, DROPS[b.name] or b.name, 1, os.getenv("SIM_DIGSLOT1") and 1 or c.slot)
      if left > 0 then ground_items = ground_items + left end
      return true
    end)
  end

  local function drop(dir, n)
    return op(0.05, function()
      local s = c.inv[c.slot]
      if not s then return false end
      n = math.min(n or s.count, s.count)
      local k = key(front(dir))
      local target = turtles_at[k]
      local left
      if target then
        if c.name == "service" and not FUEL_VALUE[s.name] then
          bad_fuel_handed = bad_fuel_handed + n
          warn("service handed " .. n .. " " .. s.name .. " to " .. target.name)
        end
        left = insert(target.inv, 16, s.name, n, 1)
      elseif blocks[k] and blocks[k].name == "trash" then
        trashed[s.name] = (trashed[s.name] or 0) + n
        left = 0
      elseif blocks[k] and blocks[k].inv then
        left = insert(blocks[k].inv, blocks[k].size or 27, s.name, n, 1)
      else
        warn(c.name .. " dropped " .. n .. " " .. s.name .. " on the ground at " .. k)
        ground_items = ground_items + n
        left = 0
      end
      local moved = n - left
      s.count = s.count - moved
      if s.count == 0 then c.inv[c.slot] = nil end
      return moved > 0
    end)
  end

  local function suck(dir)
    return op(0.05, function()
      local k = key(front(dir))
      local b = blocks[k]
      local src, size
      if turtles_at[k] then src, size = turtles_at[k].inv, 16
      elseif b and b.inv then
        src, size = b.inv, 27
        if b.refill_at and now >= b.refill_at and not b.bottomless then
          for i = 1, 20 do b.inv[i] = { name = SIM_FUEL, count = 64 } end
          b.bottomless = true
          log("SIM", "fuel chest refilled")
        end
      else return false end
      if not (b and b.bottomless) then
        -- like CC's InventoryUtil.takeItems: the first item found, plus
        -- the same item from EVERY later slot, up to 64
        local name, got = nil, 0
        for i = 1, size do
          local st = src[i]
          if st and (name == nil or st.name == name) and got < 64 then
            name = st.name
            local take = math.min(64 - got, st.count)
            got = got + take
            st.count = st.count - take
            if st.count == 0 then src[i] = nil end
          end
        end
        if not name then return false end
        local left = insert(c.inv, 16, name, got, c.slot)
        if left > 0 then insert(src, size, name, left, 1) end -- back where it came from
        return left < got
      end
      for i = 1, size do
        local s = src[i]
        if s then
          local left = insert(c.inv, 16, s.name, s.count, c.slot)
          local moved = s.count - left
          if b and b.bottomless then return moved > 0 end -- never runs out
          if moved == 0 then return false end
          s.count = left
          if left == 0 then src[i] = nil end
          return true
        end
      end
      return false
    end)
  end

  local turtle = {}
  function turtle.forward() return move("f") end
  function turtle.back() return move("b") end
  function turtle.transferTo(slot, n)
    return op(0.05, function()
      local s = c.inv[c.slot]
      if not s or slot == c.slot then return false end
      n = math.min(n or s.count, s.count)
      local t = c.inv[slot]
      if t and t.name ~= s.name then return false end
      local room = t and (64 - t.count) or 64
      local moved = math.min(n, room)
      if moved == 0 then return false end
      if t then t.count = t.count + moved else c.inv[slot] = { name = s.name, count = moved } end
      s.count = s.count - moved
      if s.count == 0 then c.inv[c.slot] = nil end
      return true
    end)
  end
  function turtle.up() return move("u") end
  function turtle.down() return move("d") end
  function turtle.turnRight() return op(0.4, function() c.facing = (c.facing + 1) % 4; if c.name == "service" then log("TURN", "service now facing " .. c.facing) end; return true end) end
  function turtle.turnLeft() return op(0.4, function() c.facing = (c.facing + 3) % 4; if c.name == "service" then log("TURN", "service now facing " .. c.facing) end; return true end) end
  function turtle.detect() return detect("f") end
  function turtle.detectUp() return detect("u") end
  function turtle.detectDown() return detect("d") end
  function turtle.compare() return compare("f") end
  function turtle.compareUp() return compare("u") end
  function turtle.compareDown() return compare("d") end
  function turtle.dig() return dig("f") end
  function turtle.digUp() return dig("u") end
  function turtle.digDown() return dig("d") end
  -- attacks: only ever deep down, never at a turtle (players can't be told apart)
  local function attack(dir)
    return op(0.4, function()
      local x, y, z = front(dir)
      local k = key(x, y, z)
      attacks = attacks + 1
      if turtles_at[k] then fatal(c.name .. " ATTACKED A TURTLE at " .. k) end
      if c.y > -5 then fatal(c.name .. " ATTACKED near the surface (y=" .. c.y .. ")") end
      local mob = mobs[k]
      if not mob then return false end
      mob.hp = mob.hp - 1
      if mob.hp <= 0 then
        mobs[k] = nil
        mobs_killed = mobs_killed + 1
        log("MOB", c.name .. " killed the mob at " .. k)
      end
      return true
    end)
  end
  function turtle.attack() return attack("f") end
  function turtle.attackUp() return attack("u") end
  function turtle.attackDown() return attack("d") end
  function turtle.drop(n) return drop("f", n) end
  function turtle.dropUp(n) return drop("u", n) end
  function turtle.dropDown(n) return drop("d", n) end
  function turtle.suck() return suck("f") end
  function turtle.suckUp() return suck("u") end
  function turtle.suckDown() return suck("d") end
  function turtle.select(n)
    assert(n >= 1 and n <= 16, "bad slot " .. tostring(n))
    c.slot = n
    return true
  end
  function turtle.getItemCount(n)
    local s = c.inv[n or c.slot]
    return s and s.count or 0
  end
  function turtle.getItemSpace(n)
    local s = c.inv[n or c.slot]
    return s and 64 - s.count or 64
  end
  function turtle.getFuelLevel() return c.fuel end
  function turtle.getFuelLimit() return FUEL_LIMIT end
  function turtle.compareTo(slot)
    local a, b = c.inv[c.slot], c.inv[slot]
    if not a and not b then return true end
    return a ~= nil and b ~= nil and a.name == b.name
  end
  function turtle.refuel(n)
    return op(0.05, function()
      local s = c.inv[c.slot]
      if not s or not FUEL_VALUE[s.name] then return false end
      n = math.min(n or s.count, s.count)
      c.fuel = c.fuel + n * FUEL_VALUE[s.name]
      if c.fuel > FUEL_LIMIT then -- burnt past the limit: wasted
        fuel_wasted = fuel_wasted + (c.fuel - FUEL_LIMIT)
        c.fuel = FUEL_LIMIT
      end
      s.count = s.count - n
      if s.count == 0 then c.inv[c.slot] = nil end
      return true
    end)
  end
  local function place(dir)
    return op(0.05, function()
      local s = c.inv[c.slot]
      local x, y, z = front(dir)
      local k = key(x, y, z)
      if not s or blocks[k] or turtles_at[k] then return false end
      set_block(k, { name = s.name })
      if s.name == "loader" then
        local a, b = chunk_ab(x, z)
        loaded_chunks[a .. "," .. b] = true
      end
      if s.name == "trash" then trash_dumps[c.name] = (trash_dumps[c.name] or 0) + 1 end
      s.count = s.count - 1
      if s.count == 0 then c.inv[c.slot] = nil end
      log(c.name, "placed " .. s.name .. " at " .. k)
      return true
    end)
  end
  function turtle.place() return place("f") end
  function turtle.placeUp() return place("u") end
  function turtle.placeDown() return place("d") end

  -- Screen / input ---------------------------------------------------------
  local function out(...)
    if c.quiet then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    log(c.name, table.concat(parts, " "))
  end
  local term = setmetatable({ getSize = function() return 51, 19 end }, {
    __index = function() return function() end end,
  })

  local env = {
    turtle = c.is_turtle and turtle or nil,
    rednet = rednet, os = os_api, sleep = sleep, parallel = make_parallel(os_api),
    print = out, term = term,
    read = function() return table.remove(c.input, 1) or "" end,
    io = { write = function() end },
    rs = { getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end },
    peripheral = {
      getNames = function()
        if o.monitor then return { "right", "top" } end
        return { "right" }
      end,
      getType = function(side)
        if side == "right" then return "modem" end
        if c.is_turtle then
          local x, y, z
          local d = DIRS[c.facing]
          if side == "front" then x, y, z = c.x + d[1], c.y, c.z + d[2]
          elseif side == "back" then x, y, z = c.x - d[1], c.y, c.z - d[2]
          elseif side == "top" then x, y, z = c.x, c.y + 1, c.z
          elseif side == "bottom" then x, y, z = c.x, c.y - 1, c.z end
          if x and turtles_at[key(x, y, z)] then return "turtle" end
        end
        if side == "top" and o.monitor then return "monitor" end
      end,
      wrap = function(side)
        if side == "top" and o.monitor then return monitor end
      end,
    },
    colors = COLORS,
    -- GPS hosts on the tower: lane 0's start spot is at 432 64 -209 (north
    -- is -Z in Minecraft). SIM_NOGPS=1: no GPS.
    gps = (not os.getenv("SIM_NOGPS")) and {
      locate = function()
        return c.x + 432, c.y + 64, -209 - c.z
      end,
    } or nil,
    textutils = { serialize = serialize, unserialize = unserialize,
      formatTime = function(t, h24)
        return string.format("%d:%02d", math.floor(t), math.floor((t % 1) * 60))
      end,
      urlEncode = function(str)
        return (str:gsub("[^%w%-_%.~]", function(ch) return string.format("%%%02X", ch:byte()) end))
      end },
    -- a paste site: every upload is kept in `uploads` and gets an address
    http = {
      post = function(url, data)
        uploads[#uploads + 1] = { who = c.name, url = url, size = #data, text = data }
        local addr = "https://paste.rs/sim" .. #uploads
        return { readAll = function() return addr end, close = function() end }
      end,
    },
    -- each computer has its own in-memory disk (kept across reboots);
    -- the controller's quarry.log is also copied to ctrl_quarry.log
    fs = {
      exists = function(p)
        if c.files[p] then return true end
        for name in pairs(c.files) do
          if name:sub(1, #p + 1) == p .. "/" then return true end
        end
        return false
      end,
      delete = function(p)
        c.files[p] = nil
        for name in pairs(c.files) do
          if name:sub(1, #p + 1) == p .. "/" then c.files[name] = nil end
        end
      end,
      makeDir = function() end,
      isDir = function() return false end,
      getName = function(p) return p:match("([^/]+)$") or p end,
      move = function(a, b)
        assert(c.files[a], "fs.move: no such file " .. a)
        assert(not c.files[b], "fs.move: file exists " .. b)
        c.files[b], c.files[a] = c.files[a], nil
      end,
      copy = function(a, b)
        assert(c.files[a], "fs.copy: no such file " .. a)
        assert(not c.files[b], "fs.copy: file exists " .. b)
        c.files[b] = c.files[a]
      end,
      open = function(path, mode)
        if mode == "r" then
          local content = c.files[path]
          if not content then return nil end
          local pos = 1
          return {
            readLine = function()
              if pos > #content then return nil end
              local nl = content:find("\n", pos, true) or (#content + 1)
              local line = content:sub(pos, nl - 1)
              pos = nl + 1
              return line
            end,
            readAll = function() local r = content:sub(pos); pos = #content + 1; return r end,
            close = function() end,
          }
        end
        count(c.name, "file")
        if mode == "w" or not c.files[path] then c.files[path] = "" end
        local function append(s)
          c.files[path] = c.files[path] .. s
          if path == "quarry.log" then
            local hf = io.open(OUT .. "ctrl_quarry.log", "a")
            hf:write(s)
            hf:close()
          end
        end
        return {
          write = function(s) append(tostring(s)) end,
          writeLine = function(s) append(tostring(s) .. "\n") end,
          close = function() end,
        }
      end,
    },
    shell = {
      getRunningProgram = function() return c.running[#c.running] end,
      resolveProgram = function(name) if c.files[name] then return name end end,
      run = function(p, ...) return c.shell_run(p, ...) end,
    },
    loadstring = loadstring,
    keys = { enter = 28, s = 31, q = 16, u = 22, c = 46, l = 38 },
    math = math, string = string, table = table, coroutine = coroutine,
    ipairs = ipairs, pairs = CC_PAIRS, next = CC_NEXT, type = type, select = select,
    tostring = tostring, tonumber = tonumber, error = error, pcall = pcall,
    unpack = unpack, setmetatable = setmetatable, getmetatable = getmetatable,
  }
  env._G = env

  -- Programs are loaded from the computer's own files, fresh at every boot
  -- (so an updated program runs after a reboot).
  local function load_program(p)
    local code = c.files[p]
    if not code then return nil end
    local fn, err = loadstring(code, "=" .. p)
    if not fn then error(p .. ": " .. err, 0) end
    setfenv(fn, env)
    return fn
  end

  -- a fake "get": serves the program files as if from GitHub
  local function fake_get(url, dest)
    local name = url:match("([%w_]+)%?") or url:match("([%w_]+)$")
    local ok, text = pcall(read_host, name)
    if not ok then return false end
    if UPDATE_AT then text = text .. UPDATE_MARK end
    c.files[dest] = text
    log(c.name, "get " .. name .. " -> " .. dest)
    return true
  end

  function c.shell_run(p, ...)
    if c.files[p] == FAKE_GET then return fake_get(...) end
    local fn = load_program(p)
    if not fn then return false end
    table.insert(c.running, p)
    local ok, err = pcall(fn, ...)
    table.remove(c.running)
    if not ok then fatal(c.name .. " program '" .. p .. "' crashed: " .. tostring(err)) end
    return ok
  end

  local function boot_fn()
    return function()
      c.running = { c.boot[1] }
      local fn = load_program(c.boot[1])
      if not fn then error("nothing to boot: " .. tostring(c.boot[1]), 0) end
      return fn(unpack(c.boot, 2))
    end
  end

  c.co = coroutine.create(boot_fn()); WATCH_COMPUTER(c.co)
  -- rebooting restarts the program from the top; position, inventory and
  -- files survive, but everything the program had in memory is gone
  c.reboot = function()
    c.co = coroutine.create(boot_fn()); WATCH_COMPUTER(c.co)
    c.filter, c.done, c.started = nil, false, false
    c.gen = c.gen + 1 -- commands not yet carried out are lost
  end
  schedule(o.start or 0, c, { "__start" })
  return c
end

local function resume(c, ...)
  local ok, filter = coroutine.resume(c.co, ...)
  if not ok then
    fatal(c.name .. " CRASHED: " .. tostring(filter) .. "\n" .. debug.traceback(c.co))
    c.done = true
  elseif coroutine.status(c.co) == "dead" then
    c.done = true
    log(c.name, "<program ended>")
  else
    c.filter = filter
  end
end

---------------------------------------------------------------------------
-- Scenario
---------------------------------------------------------------------------
-- Deterministic pseudo-random ores
local rng = 12345
local function rand()
  rng = (rng * 1103515245 + 12345) % 2147483648
  return rng / 2147483648
end

for x = R_MIN, R_MAX do
  for z = Z_MIN, Z_MAX do
    for y = BEDROCK_Y, -1 do
      if y == BEDROCK_Y then
        blocks[key(x, y, z)] = { name = "bedrock" }
      else
        -- lots of ore kinds (Tekkit has many): each takes its own slot
        local r = rand()
        local name = "stone"
        if r < 0.05 then name = "coal_ore"
        elseif r < 0.07 then name = "iron_ore"
        elseif r < 0.10 then name = "gravel"
        elseif r < 0.10 + RARE then
          local kinds = { "copper_ore", "tin_ore", "lapis_ore", "redstone_ore", "gold_ore",
            "diamond_ore", "emerald_ore", "silver_ore", "lead_ore" }
          name = kinds[math.floor((r - 0.10) / RARE * 9) + 1]
        end
        blocks[key(x, y, z)] = { name = name }
      end
    end
    -- a raised dirt surface, to exercise digging at y=0 (not on the
    -- home row, the service row, or in the control chunk)
    if z >= 1 or (z <= -2 and not protected(x, z)) or (z < 0 and (x < -1 or x >= LENGTH)) then
      blocks[key(x, 0, z)] = { name = "dirt" }
    end
    -- the odd cactus above the surface (loader spots are up there)
    if (x * 7 + z * 13) % 23 == 0 and not protected(x, z) then
      blocks[key(x, 1, z)] = { name = "cactus" }
    end
  end
end
-- SIM_PREMINED="a,b;a,b": chunks already mined out (by the old straight
-- quarry), bedrock left
for pa, pb in (os.getenv("SIM_PREMINED") or ""):gmatch("(%-?%d+),(%-?%d+)") do
  pa, pb = tonumber(pa), tonumber(pb)
  for x = pa * LENGTH, pa * LENGTH + LENGTH - 1 do
    for z = (pb - 1) * LENGTH, (pb - 1) * LENGTH + LENGTH - 1 do
      for y = BOTTOM, 0 do blocks[key(x, y, z)] = nil end
    end
  end
end
-- a stray block on the service turtle's row
blocks[key(1, 0, -1)] = { name = "dirt" }

-- Service home at (-1,0,-1): output chest above, fuel chest below
local fuel_inv = {}
for i = 1, 20 do fuel_inv[i] = { name = SIM_FUEL, count = 64 } end
local FUELCHEST_N, FUELCHEST_REFILL = (os.getenv("SIM_FUELCHEST") or ""):match("^(%d+)@([%d%.]+)$")
if FUELCHEST_N then
  fuel_inv = {}
  local n = tonumber(FUELCHEST_N)
  local i = 1
  while n > 0 do
    fuel_inv[i] = { name = SIM_FUEL, count = math.min(64, n) }
    n, i = n - 64, i + 1
  end
end
blocks[key(-1, 1, -1)] = { name = "chest", inv = {}, size = 100000 } -- bottomless: like a chest emptied by pipes
blocks[key(-1, -1, -1)] = { name = "chest", inv = fuel_inv, bottomless = FUELCHEST_N == nil, -- the user has unlimited fuel
  refill_at = tonumber(FUELCHEST_REFILL) }
blocks[key(-1, 0, -1)] = nil
blocks[key(-1, 0, 0)] = { name = "stone" } -- recommended: a block in front of the home spot
local output_chest = blocks[key(-1, 1, -1)]

local JOIN = read_host("Join")
local service_opts = { name = "service", turtle = true,
  x = -1, y = 0, z = -1, facing = 0, fuel = 0, start = 0 }
if DEPLOY then
  service_opts.files = { boot = JOIN }
  service_opts.boot = { "boot", "service" }
else
  service_opts.program = "ServiceTurtle"
end
-- SIM_SVC_DESYNC=1: the service turtle's saved notes say it faces along the
-- row while it really faces forward (picked up and put back)
if os.getenv("SIM_SVC_DESYNC") then
  service_opts.files = service_opts.files or {}
  service_opts.files[".service_state_a"] = "{ sx = 0, sz = 0, facing = 1, front_solid = true, seq = 7, fuel = 0, }"
end
local service = new_computer(service_opts)

local miners = {}
for lane = 0, LANES - 1 do
  local inv = {}
  if lane == 0 then inv[16] = { name = "loader", count = LOADERS } end
  if SIM_TRASH then
    inv[12] = { name = "cobblestone", count = 1 }
    inv[13] = { name = "dirt", count = 1 }
    inv[14] = { name = "gravel", count = 1 }
    inv[15] = { name = "trash", count = 1 }
  end
  blocks[key(lane, 0, 0)] = nil
  local mo = { name = "lane" .. lane, turtle = true,
    x = lane, y = 0, z = 0, facing = 0, fuel = 0, inv = inv, start = 0.5 + lane * 0.1 }
  if DEPLOY then
    mo.files = { boot = JOIN }
    mo.boot = { "boot", "miner", tostring(lane) }
  else
    mo.program = "TurtleTest1"
    mo.boot = { "TurtleTest1", tostring(lane) }
  end
  local m = new_computer(mo)
  m.lane = lane
  miners[#miners + 1] = m
end


os.remove(OUT .. "ctrl_quarry.log")
local control_opts = { name = "control", turtle = false,
  input = { tostring(CHUNKS) }, quiet = true, start = 1,
  monitor = true }
if DEPLOY then
  control_opts.files = {
    c = read_host("ControlCPU"), ["live/m"] = read_host("TurtleTest1"),
    ["live/s"] = read_host("ServiceTurtle"), get = FAKE_GET,
  }
  control_opts.boot = { "c" }
else
  control_opts.program = "ControlCPU"
end
local control = new_computer(control_opts)
if UPDATE_AT then schedule(UPDATE_AT, control, { "key", 22 }) end -- press U
-- arg 12: press ENTER again at this time, for a second run
local AGAIN_AT = tonumber(arg[12])
if AGAIN_AT then schedule(AGAIN_AT, control, { "key", 28 }) end
schedule(15, control, { "key", 28 }) -- press ENTER
-- (after a fresh install lanes register a little later: like a player who
-- sees "no turtles registered yet", press it again)
if DEPLOY then schedule(45, control, { "key", 28 }) end
-- SIM_TOUCH="T:label[#n],...": touch the nth place a label shows on the monitor
touch_misses = 0
for t, label, nth in (os.getenv("SIM_TOUCH") or ""):gmatch("([%d%.]+):([^,#]+)#?(%d*)") do
  schedule(tonumber(t), control, { "__touch_label", label, tonumber(nth) or 1 })
end
-- SIM_LKEY=T: press L (upload logs) at T
if os.getenv("SIM_LKEY") then schedule(tonumber(os.getenv("SIM_LKEY")), control, { "key", 38 }) end
if UPDATE_AT then schedule(UPDATE_AT + 60, control, { "key", 28 }) end
-- SIM_CKEY="T:a:b": press C at time T, then answer the questions with a, b
local ckey = os.getenv("SIM_CKEY")
if ckey then
  local t, a, b = ckey:match("^([%d%.]+):([^:]*):([^:]*)$")
  schedule(tonumber(t), control, { "key", 46 })
  table.insert(control.input, a)
  table.insert(control.input, b)
end
if STOP_AT then schedule(STOP_AT, control, { "key", 31 }) end -- press S
-- touch the title bar's right edge (the STOP button) twice to confirm
local TOUCH_STOP_AT = tonumber(arg[8])
if TOUCH_STOP_AT then
  schedule(TOUCH_STOP_AT, control, { "__touch_button" })
  schedule(TOUCH_STOP_AT + 2, control, { "__touch_button" })
end

-- Restarts (arg 10): "who@T" entries separated by commas. who is a
-- computer name (e.g. lane3, service, control) or "all" for a whole server
-- restart: every computer stops at T and boots again 20-25 s later. Each
-- program starts over from the top, like after a real restart.
local restarts = 0
for who, at in (arg[10] or ""):gmatch("(%w+)@([%d%.]+)") do
  at = tonumber(at)
  local found = false
  if who == "crash" then
    -- server CRASH: the world goes back to the last autosave, but every
    -- computer's files keep their newer contents; then everything reboots
    schedule(at, control, { "__crash" })
    found = true
  end
  for _, comp in pairs(computers) do
    if who == "all" or comp.name == who then
      schedule(at, comp, { "__reboot", who == "all" and (20 + rand() * 5) or 1 })
      found = true
    end
  end
  assert(found, "no computer named " .. who)
  restarts = restarts + 1
end

-- Dashboard snapshots, written to monitor_<time>.txt
local SNAPSHOTS = { 14, 60, 250 }
if TOUCH_STOP_AT then
  table.insert(SNAPSHOTS, TOUCH_STOP_AT + 1)
  table.sort(SNAPSHOTS)
end
local next_snapshot = 1
local function snapshot(name)
  local f = io.open(OUT .. "monitor_" .. name .. ".txt", "w")
  f:write(monitor.dump(), "\n")
  f:close()
end

---------------------------------------------------------------------------
-- Run
---------------------------------------------------------------------------
-- A miner is finished when its program ended, or when it's back on its
-- start spot with no run in progress (after a restart it boots up and
-- waits for the next run -- exactly what it should do).
local function miner_finished(m)
  if m.done then return true end
  local no_run = not m.files[".quarry_state_a"] and not m.files[".quarry_state_b"]
  return no_run and m.x == m.lane and m.y == 0 and m.z == 0 and m.facing == 0
end

-- The controller is finished when its program ended, or when the run it
-- saved has been cleared (after a restart it waits for the next run).
local seen_run = false
local function control_finished()
  -- a run is in progress if the newest saved run file says it started
  local best
  for _, name in ipairs({ ".quarry_run_a", ".quarry_run_b" }) do
    local t = control.files[name] and unserialize(control.files[name])
    if t and (not best or t.seq > best.seq) then best = t end
  end
  local running = best and best.started
  if running then seen_run = true end
  return control.done or (seen_run and not running)
end

local function updated(c, name)
  local text = c.files[name]
  return text and text:sub(-#UPDATE_MARK) == UPDATE_MARK
end

local function everyone_updated()
  if not UPDATE_AT then return true end
  if not updated(control, "c") or not updated(service, "s") then return false end
  for _, m in ipairs(miners) do if not updated(m, "m") then return false end end
  return true
end

local function all_finished()
  local control_ok = control_finished() -- always call: it tracks whether a run happened
  -- a second run was asked for: wait until it has started and finished too
  if AGAIN_AT then
    if now < AGAIN_AT + 5 then return false end
    local text = control.files["quarry.log"] or ""
    local _, runs = text:gsub("All lanes are home", "")
    if runs < 2 then return false end
  end
  if not everyone_updated() then return false end
  if not control_ok then return false end
  for _, m in ipairs(miners) do if not miner_finished(m) then return false end end
  return true
end

local processed = 0
local wall_start = os.clock()
-- SIM_DRAIN="lane@T@T2" or "lane@T@T2@reboot": that lane's fuel drops to 0
-- at T (stuck wherever it is); at T2 the player puts 5 fuel items in it
-- (and reboots it with @reboot)
local drains = {}
for spec in (os.getenv("SIM_DRAIN") or ""):gmatch("[^,]+") do
  local lane, t1, t2, rb = spec:match("^(%d+)@([%d%.]+)@([%d%.]+)(@?r?e?b?o?o?t?)$")
  table.insert(drains, { m = miners[tonumber(lane) + 1], t1 = tonumber(t1), t2 = tonumber(t2),
    reboot = rb == "@reboot" })
end
local function run_drains()
  for _, d in ipairs(drains) do
    if not d.drained and now >= d.t1 then
      d.drained = true
      d.m.fuel = 0
      log("SIM", d.m.name .. " fuel set to 0 at " .. d.m.x .. "," .. d.m.y .. "," .. d.m.z)
    end
    if d.drained and not d.refueled and now >= d.t2 then
      d.refueled = true
      insert(d.m.inv, 16, SIM_FUEL, 5, 1)
      log("SIM", "player put 5 " .. SIM_FUEL .. " in " .. d.m.name)
      if d.reboot then schedule(now, d.m, { "__reboot", 1 }) end
    end
  end
end

local function copy_inv(inv)
  local t = {}
  for i, st in pairs(inv) do t[i] = { name = st.name, count = st.count } end
  return t
end

local world_save
local function autosave()
  block_undo = {}
  local ws = { turtles = {}, chests = {}, loaded = {} }
  for _, c in pairs(computers) do
    if c.is_turtle then
      ws.turtles[c] = { x = c.x, y = c.y, z = c.z, facing = c.facing, fuel = c.fuel,
        inv = copy_inv(c.inv) }
    end
  end
  for k, b in pairs({ output_chest, blocks[key(-1, -1, -1)] }) do
    ws.chests[b] = { inv = copy_inv(b.inv), bottomless = b.bottomless }
  end
  for ch, v in pairs(loaded_chunks) do ws.loaded[ch] = v end
  ws.world_t = world_now()
  world_save = ws
end

local crashes = 0
local function crash()
  crashes = crashes + 1
  log("SIM", string.format("*** SERVER CRASH: world back to the autosave at %.0f s ***",
    math.floor(now / AUTOSAVE) * AUTOSAVE))
  -- (the clock stays at the autosave until the server is back, ~20 s)
  world_offset = now + 20 - world_save.world_t
  for k, u in pairs(block_undo) do blocks[k] = u.old end
  block_undo = {}
  for b, cs in pairs(world_save.chests) do
    b.inv = cs.inv
    b.bottomless = cs.bottomless
  end
  loaded_chunks = {}
  for ch, v in pairs(world_save.loaded) do loaded_chunks[ch] = v end
  for kk in pairs(turtles_at) do turtles_at[kk] = nil end
  for c, ts in pairs(world_save.turtles) do
    c.x, c.y, c.z, c.facing, c.fuel = ts.x, ts.y, ts.z, ts.facing, ts.fuel
    c.inv = copy_inv(ts.inv)
    turtles_at[key(c.x, c.y, c.z)] = c
  end
  -- every computer stops now and boots again 20-25 s later
  for _, c in pairs(computers) do
    local delay = 20 + rand() * 5
    log(c.name, string.format("<CRASH at %s,%s,%s; back in %.1fs>", tostring(c.x), tostring(c.y), tostring(c.z), delay))
    c.reboot()
    schedule(now + delay, c, { "__start" })
  end
  autosave() -- the world as it is now is what the server loaded
end

autosave()
local next_autosave = AUTOSAVE

while #queue > 0 and #fatal_errors == 0 do
  processed = processed + 1
  if processed % 20000 == 0 then
    local counts = {}
    for _, q in ipairs(queue) do
      local k = q.comp.name .. ":" .. tostring(q.ev[1])
      counts[k] = (counts[k] or 0) + 1
    end
    local parts = {}
    for k, v in pairs(counts) do if v > 50 then parts[#parts + 1] = k .. "=" .. v end end
    log("SIM", string.format("%d events, queue=%d %s", processed, #queue, table.concat(parts, " ")))
    if os.clock() - wall_start > (tonumber(os.getenv("SIM_WALL")) or 400) then
      fatal("simulator gave up after " .. (tonumber(os.getenv("SIM_WALL")) or 400) .. " s of real time (something is spinning)")
      break
    end
  end
  local e = table.remove(queue, 1)
  if not e then break end -- (nothing left to happen)
  if e.t > TIME_LIMIT then break end
  while SNAPSHOTS[next_snapshot] and e.t >= SNAPSHOTS[next_snapshot] do
    snapshot(tostring(SNAPSHOTS[next_snapshot]))
    next_snapshot = next_snapshot + 1
  end
  while e.t >= next_autosave do
    now = next_autosave
    autosave()
    next_autosave = next_autosave + AUTOSAVE
  end
  now = e.t
  if TIMEBACK and now >= TIMEBACK then
    TIMEBACK = nil
    world_offset = world_offset + 900
    log("SIM", "*** admin set the time back 900 s ***")
  end
  run_drains()
  local c = e.comp
  if e.ev[1] == "__crash" then
    crash()
    e.ev = { "__ignored" }
  end
  if e.ev[1] == "__reboot" then
    log(c.name, string.format("<RESTART at %s,%s,%s facing %d; back in %.1fs>", tostring(c.x), tostring(c.y), tostring(c.z), c.facing, e.ev[2]))
    c.reboot()
    schedule(now + e.ev[2], c, { "__start" })
    e.ev = { "__ignored" }
  end
  if e.ev[1] == "__effect" then
    -- a turtle command being carried out (only if no restart came first)
    if e.ev[4] == c.gen then
      local r = { e.ev[2]() }
      local resp = { "turtle_response", e.ev[3] }
      local n = 2
      for i = 1, table.maxn(r) do n = n + 1; resp[n] = r[i] end
      resp.n = n
      schedule(now + e.ev[5], c, resp)
    end
    e.ev = { "__ignored" }
  end
  if e.ev[1] == "__touch_label" then
    local x, y = monitor.find(e.ev[2], e.ev[3])
    if x then
      log("SIM", "touched '" .. e.ev[2] .. "' at " .. x .. "," .. y)
      e.ev = { "monitor_touch", "top", x, y }
    else
      log("SIM", "couldn't find '" .. e.ev[2] .. "' on the monitor")
      touch_misses = touch_misses + 1
      e.ev = { "__ignored" }
    end
  end
  if e.ev[1] == "__touch_button" then
    local w = monitor.getSize()
    e.ev = { "monitor_touch", "top", w, 1 }
    log("SIM", "touched monitor at " .. w .. ",1")
  end
  if not c.done then
    if e.ev[1] == "__start" then
      c.started = true
      resume(c)
    elseif e.ev[1] == "__ignored" or not c.started then
      -- program not running yet: event is lost
    elseif c.filter == nil or c.filter == e.ev[1] or e.ev[1] == "terminate" then
      wake_total = wake_total + 1
      if idle_from then c.idle_wakes = (c.idle_wakes or 0) + 1; c.idle_ev = c.idle_ev or {}; c.idle_ev[e.ev[1]] = (c.idle_ev[e.ev[1]] or 0) + 1 end
      resume(c, unpack(e.ev))
    elseif e.ev[1] == "rednet_message" then
      c.dropped = c.dropped + 1 -- lost, like in real CC
    end
  end
  if all_finished() then
    if not IDLE then break end
    if not idle_from then idle_from, idle_net0, idle_wake0 = now, net_total, wake_total end
  end
  if idle_from and now >= idle_from + IDLE then break end
end
if idle_from then
  print(string.format("Idle after the run (%d s): %d rednet messages, %d program wake-ups (%.2f/s)",
    IDLE, net_total - idle_net0, wake_total - idle_wake0, (wake_total - idle_wake0) / IDLE))
  for _, c in pairs(computers) do
    if c.idle_wakes then
      local p = {}
      for k, v in pairs(c.idle_ev) do p[#p + 1] = k .. "=" .. v end
      print("   " .. c.name .. ": " .. c.idle_wakes .. " (" .. table.concat(p, " ") .. ")")
    end
  end
end

snapshot("final")
local deploy_failed = false
if restarts > 0 then print("Restarts: " .. (arg[10] or "") .. "  (crashes: " .. crashes .. ")") end
if DEPLOY then
  local installed, updated_n = 0, 0
  for line in io.lines(OUT .. "sim.log") do
    if line:find("Program installed", 1, true) then installed = installed + 1 end
    if line:find("Updated to the newest version", 1, true) then updated_n = updated_n + 1 end
  end
  print(string.format("Deploy: %d turtles got their program over the network, %d updated", installed, updated_n))
  if UPDATE_AT then
    local ok_all = everyone_updated()
    print("Everyone on the new version: " .. tostring(ok_all))
    if not ok_all then deploy_failed = true end
  end
end
logf:flush()
local lost_lines = 0
-- Without GPS, a restart in the middle of a turn can't be sorted out: the
-- turtle says LOST ("GPS needed") on purpose, rather than guess. That is
-- the expected outcome of such a run (see the RESULT line).
local lost_no_gps = false
for line in io.lines(OUT .. "sim.log") do
  if os.getenv("SIM_NOGPS") and line:find("(GPS needed)", 1, true) then lost_no_gps = true end
  if line:find("LOST", 1, true) or line:find("don't know where", 1, true) or line:find("find my way home after", 1, true) then
    lost_lines = lost_lines + 1
    if lost_lines <= 3 then print("LOST: " .. line) end
  end
end

---------------------------------------------------------------------------
-- Report
---------------------------------------------------------------------------
print(string.format("Scenario: %d lanes (chunks %dx%d), depth %d, rings 1-%d%s",
  LANES, LENGTH, LENGTH, DEPTH, CHUNKS, STOP_AT and (", S pressed at t=" .. STOP_AT) or ""))
print(string.format("Sim time: %.0f s (%.1f MC days)", now, now / 1200))
print()

local ok = #fatal_errors == 0
for _, f in ipairs(fatal_errors) do print("FATAL: " .. f) end

print("Programs:")
for _, c in ipairs({ control, service }) do
  print(string.format("  %-8s done=%-5s dropped_msgs=%d", c.name, tostring(c.done == true), c.dropped))
end
for _, m in ipairs(miners) do
  print(string.format("  %-8s done=%-5s pos=(%d,%d,%d) facing=%d fuel=%d moves=%d dropped_msgs=%d",
    m.name, tostring(m.done == true), m.x, m.y, m.z, m.facing, m.fuel, m.moves, m.dropped))
  if not miner_finished(m) then
    ok = false
    local inv = {}
    for i = 1, 16 do if m.inv[i] then inv[#inv + 1] = i .. ":" .. m.inv[i].name .. "x" .. m.inv[i].count end end
    print("    ^ did not finish  (inventory " .. table.concat(inv, " ") .. ")")
  end
  local cargo = 0
  for i = 1, 16 do
    local s = m.inv[i]
    local kept = SIM_TRASH and i >= 12 and i <= 15 -- samples + trash can
    if s and not kept and s.name ~= "loader" and not FUEL_VALUE[s.name] then cargo = cargo + s.count end
  end
  -- (a crash can undo the last unload after the lane had finished: it
  -- carries a few blocks into the next run, where they get unloaded)
  if cargo > 0 and crashes > 0 and cargo <= 64 then
    print("    (note: holding " .. cargo .. " mined blocks after a crash undid its last unload)")
  elseif cargo > 0 then
    ok = false
    print("    ^ finished still holding " .. cargo .. " mined blocks")
  end
  if not (STOP_AT or TOUCH_STOP_AT) and (m.x ~= m.lane or m.y ~= 0 or m.z ~= 0) then
    ok = false
    print("    ^ not back at its start spot")
  end
end
print(string.format("  service  pos=(%d,%d,%d) fuel=%d moves=%d", service.x, service.y, service.z,
  service.fuel, service.moves))

local remaining = 0
for x = R_MIN, R_MAX do
  for z = Z_MIN, Z_MAX do
    if in_quarry(x, 0, z) then
      for y = 0, BOTTOM, -1 do
        local b = blocks[key(x, y, z)]
        if b and b.name ~= "bedrock" then remaining = remaining + 1; if remaining <= 5 then print("  unmined: " .. b.name .. " at " .. key(x, y, z)) end end
      end
    end
  end
end
-- the base must be untouched
for _, k in ipairs({ key(-1, 1, -1), key(-1, -1, -1), key(-1, 0, 0) }) do
  if not blocks[k] then ok = false; print("    ^ base block at " .. k .. " is GONE") end
end
print()
print("Quarry blocks left unmined: " .. remaining)
-- (a STOP or RECALL leaves the rest for the next run -- unless there was one)
local RECALLED = (os.getenv("SIM_TOUCH") or ""):find("RECALL") ~= nil
-- (a server crash right after a chunk was finished can put back a few of
-- its bottom blocks: the fleet has moved on. Known limit: up to one layer.)
if crashes > 0 and remaining > 0 and remaining <= LENGTH * LENGTH * (0 - BEDROCK_Y) then
  print("    (note: " .. remaining .. " blocks put back by the crash in a finished chunk)")
elseif not (STOP_AT or TOUCH_STOP_AT or (RECALLED and not AGAIN_AT)) and remaining > 0 then ok = false end
print("Blocks dug outside quarry (service row / transit): " .. dug_outside)

local loaders = {}
for k, b in pairs(blocks) do if b.name == "loader" then loaders[#loaders + 1] = k end end
table.sort(loaders)
print("Chunk loaders left in the world: " .. #loaders .. "  (" .. table.concat(loaders, "  ") .. ")")
local marker = blocks[key(-1, 0, 0)]
if not marker then ok = false; print("    ^ the block in front of the service home was DUG") end
if #loaders > 0 then ok = false; print("    ^ loaders left in the world") end
local back = 0
for i = 1, 16 do
  local st = miners[1].inv[i]
  if st and st.name == "loader" then
    back = back + st.count
    if i ~= 16 then ok = false; print("    ^ loaders in lane 0 slot " .. i .. ", not 16") end
  end
end
print("Loaders back in lane 0: " .. back .. " of " .. LOADERS)
if back ~= LOADERS then ok = false end

local total, byname = inv_total(output_chest.inv, output_chest.size)
local parts = {}
for n, cnt in pairs(byname) do parts[#parts + 1] = n .. "=" .. cnt end
print("Output chest: " .. total .. " items  (" .. table.concat(parts, ", ") .. ")")
print("Attacks: " .. attacks .. ", mobs killed: " .. mobs_killed)
for name, plan in pairs(mob_plan) do
  if not plan.done then ok = false; print("    ^ the mob for " .. name .. " never appeared") end
end
for k in pairs(mobs) do ok = false; print("    ^ a mob is still at " .. k) end
print("Items dropped on the ground: " .. ground_items)
print("Fuel burnt past a turtle's limit (wasted): " .. fuel_wasted)
if fuel_wasted > 0 then ok = false end
local tparts, bad_trash = {}, 0
for n, cnt in pairs(trashed) do
  tparts[#tparts + 1] = n .. "=" .. cnt
  if not JUNK[n] then bad_trash = bad_trash + cnt end
end
print("Thrown in trash cans: " .. table.concat(tparts, ", "))
do
  local total, worst, wn = 0, 0, "-"
  for n, c in pairs(trash_dumps) do total = total + c; if c > worst then worst, wn = c, n end end
  print("Trash can put down: " .. total .. " times (most: " .. wn .. " " .. worst .. ")")
  -- dumping every few blocks is slow and wastes server time
  local blocks_per_lane = LENGTH * ((2 * RINGS + 1) ^ 2 - 1) * (0 - BEDROCK_Y)
  -- (a crash replays up to 45 s of mining, trash trips included)
  -- (the old bug this catches dumped every few blocks; tiny test chunks
  -- with lots of ore legitimately dump every 20-30)
  if worst > blocks_per_lane / 15 + 5 + 3 * crashes then ok = false; print("    ^ TRASH CAN THRASHING: " .. wn .. " put it down " .. worst .. " times") end
end
if bad_trash > 0 then ok = false; print("    ^ NON-JUNK THROWN AWAY: " .. bad_trash) end
-- every iron ore mined must end up in the output chest or a turtle
local iron_mined = 0
for _, st in pairs(output_chest.inv) do if st.name == "iron_ore" then iron_mined = iron_mined + st.count end end
local iron_carried = 0
for _, c in pairs(computers) do
  if c.inv then for i = 1, 16 do local st = c.inv[i]; if st and st.name == "iron_ore" then iron_carried = iron_carried + st.count end end end
end
print("Iron ore: " .. iron_mined .. " in the output chest, " .. iron_carried .. " still in turtles")
if SIM_TRASH then
  for _, m in ipairs(miners) do
    local okslots = m.inv[12] and m.inv[13] and m.inv[14] and m.inv[15] and m.inv[15].name == "trash"
    if not okslots then ok = false; print("    ^ " .. m.name .. " lost its samples or trash can") end
  end
end
print("Service trips home: " .. service_home_trips)
print("Non-coal items handed to miners by the service turtle: " .. bad_fuel_handed)
if bad_fuel_handed > 0 then ok = false end
print("Moves refused away from a chunk entry (unloaded chunk on the way): " .. move_refusals)
-- The server's rule: no computer sends more than 1 rednet message a second.
do
  local worst, who = 0, nil
  for _, t in pairs(stats) do
    if t.kind == "net" then
      for _, n in pairs(t.per) do if n > worst then worst, who = n, t.who end end
    end
  end
  print("Most rednet messages sent by one computer in one second: " .. worst .. (who and (" (" .. who .. ")") or ""))
  if worst > 1 then ok = false; print("    ^ OVER THE SERVER'S LIMIT OF 1 PER SECOND") end
end
if os.getenv("SIM_STATS") then
  -- per kind: the busiest computer's average and worst second, plus totals
  local kinds = { "net", "recv", "mon", "file", "turtle" }
  local secs = math.max(1, math.floor(now))
  print()
  print(string.format("Server load over %d s  (avg/s and worst single second)", secs))
  for _, kind in ipairs(kinds) do
    local rows = {}
    for _, t in pairs(stats) do if t.kind == kind then rows[#rows + 1] = t end end
    table.sort(rows, function(a, b) return a.total > b.total end)
    local sum, worst_all = 0, 0
    local all_per = {}
    for _, t in ipairs(rows) do
      sum = sum + t.total
      for sec, n in pairs(t.per) do all_per[sec] = (all_per[sec] or 0) + n end
    end
    for _, n in pairs(all_per) do if n > worst_all then worst_all = n end end
    local line = string.format("  %-6s all computers: %7.2f/s (worst %4d)", kind, sum / secs, worst_all)
    if rows[1] then
      local worst1 = 0
      for _, n in pairs(rows[1].per) do if n > worst1 then worst1 = n end end
      line = line .. string.format("   busiest: %-8s %6.2f/s (worst %d)", rows[1].who, rows[1].total / secs, worst1)
    end
    print(line)
  end
  local parts = {}
  for k, n in pairs(by_cmd) do parts[#parts + 1] = { k, n } end
  table.sort(parts, function(a, b) return a[2] > b[2] end)
  local out = {}
  for _, p in ipairs(parts) do out[#out + 1] = string.format("%s %.2f", p[1], p[2] / secs) end
  print("  net by message (/s): " .. table.concat(out, ", "))
  local list = {}
  for sec, l in pairs(sec_cmds) do list[#list + 1] = { sec, l } end
  table.sort(list, function(a, b) return #a[2] > #b[2] end)
  for i = 1, math.min(3, #list) do
    print(string.format("  busiest second t=%d (%d msgs): %s", list[i][1], #list[i][2], table.concat(list[i][2], " ")))
  end
  local over = 0
  for _, l in pairs(sec_cmds) do if #l > 2 then over = over + 1 end end
  print("  seconds with more than 2 messages (whole quarry): " .. over)
end
-- (after a crash a miner may be told to go on before the next chunk's loader
-- is back; the game refuses the move and it waits: that's fine)
if move_refusals > 0 and crashes == 0 then ok = false end
print("Monitor writes past the right edge: " .. monitor.overflows)
if monitor.overflows > 0 then ok = false end
local lf = io.open(OUT .. "ctrl_quarry.log")
local log_text = lf and lf:read("*a") or ""
if lf then lf:close() end
local _, log_count = log_text:gsub("\n", "")
print("Controller log lines (quarry.log): " .. log_count)
for line in log_text:gmatch("[^\n]+") do
  if line:find("Display error", 1, true) then ok = false; print("  " .. line) end
end
local ftotal = inv_total(blocks[key(-1, -1, -1)].inv, 27)
print("Fuel chest: " .. ftotal .. " coal left (started with 1280)")
if #warnings > 0 then
  print()
  print("Warnings (" .. #warnings .. "):")
  for i = 1, math.min(#warnings, 15) do print("  " .. warnings[i]) end
end
print()
if lost_lines > 0 then ok = false end
if deploy_failed then ok = false end
if os.getenv("SIM_DUMPFILES") then
  for _, c in pairs(computers) do
    if c.files then
      for name, text in pairs(c.files) do
        if name:sub(1, 1) == "." then
          local h = io.open(OUT .. c.name .. "_" .. name:sub(2), "w")
          if h then h:write(text); h:close() end
        end
      end
    end
  end
end
if os.getenv("SIM_LKEY") then
  local by = {}
  for _, u in ipairs(uploads) do by[u.who] = (by[u.who] or 0) + 1 end
  local n, parts = 0, {}
  for who, k in pairs(by) do n = n + 1; parts[#parts + 1] = who .. "=" .. k end
  print("Log uploads: " .. #uploads .. " from " .. n .. " computers (" .. table.concat(parts, " ") .. ")")
  local last = uploads[#uploads]
  if not (last and last.who == "control") then ok = false; print("    ^ the main computer's log wasn't the last upload") end
  if n < LANES + 2 then ok = false; print("    ^ not every computer uploaded its log") end
  if last and last.who == "control" then
    local links = select(2, last.text:gsub("Log uploaded: https://", ""))
    print("Turtle log links in the main computer's log: " .. links)
    if links < LANES + 1 then ok = false; print("    ^ some turtles' links missing from the main log") end
  end
  local h = io.open(OUT .. "uploads.txt", "w")
  for i, u in ipairs(uploads) do h:write("=== #" .. i .. " " .. u.who .. " " .. u.size .. " bytes\n" .. u.text .. "\n") end
  h:close()
end
if #RANGES > 0 then print("Messages lost out of radio range: " .. radio_lost) end
if touch_misses > 0 then ok = false; print("    ^ " .. touch_misses .. " touches missed their button") end
if not ok and lost_no_gps and #fatal_errors == 0 then
  print("    (expected: without GPS a turtle restarted mid-turn stops as LOST instead of guessing)")
  ok = true
end
print(ok and "RESULT: PASS" or "RESULT: FAIL")
logf:close()
