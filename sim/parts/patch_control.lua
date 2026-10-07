-- Turns the straight-line main computer into the ring one. Run from ringsim/parts.
local path = "../../ControlCPU"
local src = "orig_ControlCPU" -- (the straight-line main computer, R0)
local f = assert(io.open(src, "rb")); local s = f:read("*a"); f:close()
local function rep(a, b)
  local i, j = s:find(a, 1, true); assert(i, "rep: " .. a:sub(1, 70))
  assert(not s:find(a, j + 1, true), "twice: " .. a:sub(1, 70))
  s = s:sub(1, i - 1) .. b .. s:sub(j + 1)
end
local function cut(from, to, new)
  local i = assert(s:find(from, 1, true), "cut from: " .. from)
  local j = assert(s:find(to, i, true), "cut to: " .. to)
  s = s:sub(1, i - 1) .. new .. s:sub(j)
end

------------------------------------------------------------------------------
-- 1. settings, rings, the plan and the map of finished chunks
cut("-- The last settings are remembered", "-- State ---", [==[
-- The last settings are remembered and reused; you're only asked the
-- first time, after "c new", or after pressing C (or SET on the monitor).
local SETTINGS_FILE = "quarry.cfg"
local CHUNK_SIZE = 16 -- a Minecraft chunk
-- quarry.cfg: how many rings to mine (up to and including that ring)
local saved_rings = 2
if fs.exists(SETTINGS_FILE) then
  local f = fs.open(SETTINGS_FILE, "r")
  saved_rings = tonumber(f.readLine()) or saved_rings
  f.close()
end

-- Rings (the same code is in the miners' program) -----------------------------
-- The quarry mines rings of chunks around the CONTROL chunk (this computer's
-- tower, the service turtle), clockwise, starting with the spoke: the line
-- of chunks straight north of it, where the miners' start spots are.
-- Chunk (a, b) is a chunks east and b chunks north of the control chunk.
-- d = the way the lanes run (0 north, 1 east, 2 south, 3 west).
local function ring_order(r)
  local list = { { a = 0, b = r, d = 0 } }
  for a = 1, r do list[#list + 1] = { a = a, b = r, d = 1 } end
  for b = r - 1, -r, -1 do list[#list + 1] = { a = r, b = b, d = 2 } end
  for a = r - 1, -r, -1 do list[#list + 1] = { a = a, b = -r, d = 3 } end
  for b = -r + 1, r do list[#list + 1] = { a = -r, b = b, d = 0 } end
  for a = -r + 1, -1 do list[#list + 1] = { a = a, b = r, d = 1 } end
  return list
end

local function ckey(a, b) return a .. "," .. b end
local function ring_of(a, b) return math.max(math.abs(a), math.abs(b)) end

-- Finished chunks, over all runs ("a,b" = true). A chunk counts as finished
-- when every lane has checked or mined its lane in it.
local MAP_FILE = "quarry.map"
local mined = {}
local function load_map()
  mined = {}
  if not fs.exists(MAP_FILE) then return end
  local f = fs.open(MAP_FILE, "r")
  while true do
    local line = f.readLine()
    if not line then break end
    if line:match("^%-?%d+,%-?%d+$") then mined[line] = true end
  end
  f.close()
end
local function save_map()
  local f = fs.open(MAP_FILE, "w")
  for k in pairs(mined) do f.writeLine(k) end
  f.close()
end
load_map()

local function ask(question, default)
  io.write(question .. " [" .. default .. "]: ")
  return tonumber(read()) or default
end

-- A run in progress is saved to two files in turn, so a restart in the
-- middle of writing one never loses both.
local RUN_FILES = { ".quarry_run_a", ".quarry_run_b" }
local run_seq = 0

local function load_run()
  local best
  for _, name in ipairs(RUN_FILES) do
    if fs.exists(name) then
      local f = fs.open(name, "r")
      local text = f.readAll()
      f.close()
      local ok, t = pcall(textutils.unserialize, text)
      if ok and type(t) == "table" and type(t.seq) == "number"
          and (not best or t.seq > best.seq) then
        best = t
      end
    end
  end
  return best
end

local function clear_run()
  for _, name in ipairs(RUN_FILES) do fs.delete(name) end
end

if OPTION == "new" then clear_run() end
local resumed = load_run()

local ASK_FILE = ".ask_settings" -- written by the C key
local depth
local chunks = saved_rings -- (rings to mine: "chunks" kept as the name)
local ask_now = fs.exists(ASK_FILE) or OPTION == "new" or not fs.exists(SETTINGS_FILE)
if resumed then
  -- (the turtles registered before the reboot are kept either way)
  depth, chunks = resumed.depth, resumed.chunks or chunks
  run_seq = resumed.seq
end
if resumed and resumed.started then
  -- a run is in progress: carry on without asking anything
  if fs.exists(ASK_FILE) then fs.delete(ASK_FILE) end
elseif ask_now then
  if fs.exists(ASK_FILE) then fs.delete(ASK_FILE) end
  -- the question is on the computer's own screen: say so on the monitor
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local m = peripheral.wrap(name)
      m.setBackgroundColor(colors.black)
      m.clear()
      m.setTextScale(1)
      m.setCursorPos(2, 2)
      m.write("Answer the question on the")
      m.setCursorPos(2, 3)
      m.write("main computer's screen.")
    end
  end
  parallel.waitForAny(function()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Ring Quarry Control ===")
    print("(press ENTER to keep the value in brackets)")
    chunks = math.max(1, math.floor(ask("Mine up to ring", saved_rings)))
  end, deploy_server, sender_loop) -- keep handing out programs while you type
  local f = fs.open(SETTINGS_FILE, "w")
  f.write(chunks .. "\n")
  f.close()
end

-- The plan: every chunk of rings 1 .. chunks, in order. Its index (seq) is
-- how the miners know which chunk is which.
local plan = {}
local function build_plan()
  plan = {}
  for r = 1, chunks do
    local order = ring_order(r)
    for i, c in ipairs(order) do
      plan[#plan + 1] = { a = c.a, b = c.b, d = c.d, ring = r, idx = i, count = #order }
    end
  end
end
build_plan()

local function last_chunk_no() return #plan end

-- depth = layers down to bedrock, as reported by the miners (nil until
-- one has found it). Miners clear 3 layers per pass.
local function passes() return depth and math.ceil(depth / 3) end
local function depth_text() return depth and tostring(depth) or "?" end

]==])

------------------------------------------------------------------------------
-- 2. state
rep([==[local current_chunk = 1
local service = { state = "not heard from yet" }]==], [==[local current_chunk = 0 -- (the plan index the fleet is on; 0 = not yet)
local loaders_out = {}   -- { a, b, d, ring } in the order they were placed
local last_next          -- the last "next_chunk" message (re-sent to a lane that missed it)
local arrived = {}       -- [lane] = true: left the finished ring (see ring changes)
local service = { state = "not heard from yet" }]==])
rep([==[    seq = run_seq, length = length, depth = depth, chunks = chunks, skip = skip,]==],
    [==[    seq = run_seq, depth = depth, chunks = chunks,
    loaders_out = loaders_out, last_next = last_next,]==])
rep([==[  last_chunk = resumed.last_chunk
  if started then started_at = os.clock() - (resumed.elapsed or 0) end]==],
    [==[  last_chunk = resumed.last_chunk
  loaders_out, last_next = resumed.loaders_out or {}, resumed.last_next
  if started then started_at = os.clock() - (resumed.elapsed or 0) end]==])

------------------------------------------------------------------------------
-- 3. progress bars: by plan index
rep([==[  if all_home or (done[lane] or 0) >= current_chunk then return 1 end
  if m.chunk == current_chunk and m.pass and passes() then]==],
    [==[  if all_home or (done[lane] or 0) >= current_chunk then return 1 end
  local c = plan[current_chunk]
  if c and m.chunk == ckey(c.a, c.b) and m.pass and passes() then]==])

------------------------------------------------------------------------------
-- 4. start
rep([==[  panel = nil -- (a settings panel left open closes)
  skip = read_progress()
  local lanes = sorted_lanes()
  add_log("control", string.format("Started %d lanes: down to bedrock, %s.",
    #lanes, chunks == 0 and "until stopped" or (chunks .. " chunks")))
  if skip > 0 then
    add_log("control", "Chunks 1-" .. skip .. " were mined before: driving past them.")
  end
  for _, lane in ipairs(lanes) do
    queue_send(miners[lane].id, {
      cmd = "start", id = lane, length = length, depth = depth, chunks = last_chunk_no(),
      chunk = current_chunk, skip = skip,
    }, PROTOCOL)]==], [==[  panel = nil -- (a settings panel left open closes)
  build_plan()
  current_chunk, loaders_out, last_next, done, arrived = 0, {}, nil, {}, {}
  local lanes = sorted_lanes()
  local n = 0
  for k in pairs(mined) do n = n + 1 end
  add_log("control", string.format("Started %d lanes: rings 1-%d, down to bedrock (%d chunks finished before).",
    #lanes, chunks, n))
  for _, lane in ipairs(lanes) do
    queue_send(miners[lane].id, { cmd = "start", id = lane }, PROTOCOL)]==])
rep([==[    miners[lane].stop_heard, miners[lane].stop_sent = nil, nil
  end
  save_run()
end]==], [==[    miners[lane].stop_heard, miners[lane].stop_sent = nil, nil
  end
  save_run()
  advance()
end]==])
rep([==[local function do_start()]==], [==[local advance -- (with the fleet control code below)

local function do_start()]==])

------------------------------------------------------------------------------
-- 5. dashboard: ring and chunk
rep([==[    { string.format(" Chunk %d/%s  ", current_chunk, chunks == 0 and "inf" or tostring(last_chunk_no())), colors.white },]==],
    [==[    { " " .. where_text() .. "  ", colors.white },]==])
rep([==[local function run_state()]==], [==[-- "Ring 2  chunk 5/16" (or how far the plan goes before a start)
local function where_text()
  local c = plan[current_chunk]
  if c then return string.format("Ring %d  chunk %d/%d", c.ring, c.idx, c.count) end
  return "Rings 1-" .. chunks
end

local function run_state()]==])
rep([==[  local prefix = string.format(" Length %d  Depth %s   Chunk ", length, depth_text())]==],
    [==[  local prefix = string.format(" Depth %s   Chunk ", depth_text())]==])
rep([==[    { string.format("L=%d D=%s chunk %d/%s ", length, depth_text(), current_chunk,
      chunks == 0 and "inf" or tostring(last_chunk_no())), colors.white },]==],
    [==[    { string.format("D=%s %s ", depth_text(), where_text()), colors.white },]==])
-- the map, right of the service panel and the log (below the lane table):
-- one character per chunk, north up
rep([==[  local sw = math.max(10, w - fixed)]==], [==[  local sw = math.max(10, w - fixed)
  local mapw = (2 * chunks + 1) * 2 + 1
  if w - mapw < 30 then mapw = 0 end
  local cur = plan[current_chunk]
  local map_top -- (set below the lane table)
  -- the map's piece for screen row yy, or nil
  local function map_at(yy)
    if mapw == 0 or not map_top then return nil end
    local b = chunks - (yy - map_top)
    if b > chunks or b < -chunks then return nil end
    local text = " "
    for a = -chunks, chunks do
      local ch = "."
      if a == 0 and b == 0 then ch = "C"
      elseif cur and cur.a == a and cur.b == b and started then ch = "@"
      elseif mined[ckey(a, b)] then ch = "#" end
      text = text .. ch .. " "
    end
    return { { text, colors.lightBlue } }
  end]==])
rep([==[  if y <= h then row(t, y, {}) y = y + 1 end

  -- Service turtle panel.]==], [==[  if y <= h then row(t, y, {}) y = y + 1 end
  map_top = y

  -- Service turtle panel.]==])
rep([==[      row(t, y, pieces_row)]==], [==[      row(t, y, pieces_row, map_at(y))]==])
rep([==[  if y <= h then row(t, y, {}) y = y + 1 end

  -- Log: newest at the bottom, filling the rest of the screen.]==], [==[  if y <= h then row(t, y, {}, map_at(y)) y = y + 1 end

  -- Log: newest at the bottom, filling the rest of the screen.]==])
rep([==[    row(t, y, { { " LOG ", colors.white, colors.gray }, { "  also saved to " .. LOG_FILE, colors.gray } })]==],
    [==[    row(t, y, { { " LOG ", colors.white, colors.gray }, { "  also saved to " .. LOG_FILE, colors.gray } }, map_at(y))]==])
rep([==[      row(t, y, {
        { " " .. pad(e.time, 8), colors.gray },
        { pad(e.source, 9), source_color(e.source) },
        { e.text, e.warn and colors.red or colors.white },
      })
    else
      row(t, y, {})]==], [==[      row(t, y, {
        { " " .. pad(e.time, 8), colors.gray },
        { pad(e.source, 9), source_color(e.source) },
        { e.text, e.warn and colors.red or colors.white },
      }, map_at(y))
    else
      row(t, y, {}, map_at(y))]==])

------------------------------------------------------------------------------
-- 6. a new run after everyone is home
rep([==[  current_chunk = 1
  skip = read_progress()
  done, stopped = {}, {}]==], [==[  current_chunk = 0
  loaders_out, last_next = {}, nil
  done, stopped = {}, {}]==])

------------------------------------------------------------------------------
-- 7. stop tells the way home
rep([==[function tell_stop(lane)
  send(lane, { cmd = "stop", id = lane })]==], [==[function tell_stop(lane)
  send(lane, { cmd = "stop", id = lane, open = open_list() })]==])
rep([==[local function send(lane, msg)]==], [==[-- Chunks the turtles may travel through: finished and loaded (ring 1 is
-- always loaded; further out only while its loader is in).
local function open_list()
  local list = {}
  for k in pairs(mined) do
    local a, b = k:match("^(%-?%d+),(%-?%d+)$")
    a, b = tonumber(a), tonumber(b)
    local loaded = ring_of(a, b) <= 1
    for _, t in ipairs(loaders_out) do
      if t[1] == a and t[2] == b then loaded = true end
    end
    if loaded then list[#list + 1] = { a, b } end
  end
  return list
end

local function send(lane, msg)]==])

------------------------------------------------------------------------------
-- 8. moving on: the next unfinished chunk, with the loaders it needs
rep([==[-- Called when a lane reports chunk_done: if everyone is done, either move
-- the fleet to the next chunk or finish.
local function try_advance()
  for lane in pairs(miners) do
    if (done[lane] or 0) < current_chunk then return end
  end
  -- every lane has finished this chunk: remember it for the next run
  if current_chunk > read_progress() then write_progress(current_chunk) end
  if stop_requested or last_chunk or (chunks ~= 0 and current_chunk >= last_chunk_no()) then
    finished = true
    if stop_requested then
      add_log("control", "Stopped after chunk " .. current_chunk .. ". Lanes are heading home.")
    else
      add_log("control", "Run complete: mined up to chunk " .. current_chunk .. ". Lanes are heading home.")
    end
    for lane in pairs(miners) do tell_stop(lane) end
  else
    add_log("control", "All lanes finished chunk " .. current_chunk
      .. ". Moving to chunk " .. (current_chunk + 1) .. ".")
    current_chunk = current_chunk + 1
    -- one message every lane hears at once (they all set off together)
    queue_send(nil, { cmd = "next_chunk", chunk = current_chunk }, PROTOCOL)
    for lane in pairs(miners) do
      miners[lane].status = "to chunk " .. current_chunk
      miners[lane].pass = nil
    end
  end
  save_run()
end]==], [==[-- Every chunk from ring 2 out needs a Spot Loader while the fleet works
-- in it or goes through it. Lane 0 puts it in from the chunk next door.
local function has_loader(a, b)
  for _, t in ipairs(loaders_out) do
    if t[1] == a and t[2] == b then return true end
  end
  return false
end

-- Loaders needed to work on plan[j]: the spoke out to its ring, then its
-- ring from the spoke round to it (the way the fleet came).
local function loaders_for(j)
  local c, list = plan[j], {}
  for b = 2, c.ring do
    if not has_loader(0, b) then list[#list + 1] = { 0, b, 0, b } end
  end
  if c.ring >= 2 then
    local first = j - c.idx + 1
    for k = first + 1, j do
      local x = plan[k]
      if not has_loader(x.a, x.b) then list[#list + 1] = { x.a, x.b, x.d, x.ring } end
    end
  end
  return list
end

local function next_unfinished(after)
  for j = after + 1, #plan do
    if not mined[ckey(plan[j].a, plan[j].b)] then return j end
  end
end

-- Sends the fleet to plan[j]. At a ring change lane 0 first takes the
-- finished ring's loaders back (not the spoke's), once everyone else has
-- left that ring.
local function go_to_chunk(j)
  local c = plan[j]
  local prev = plan[current_chunk]
  local l0 = { place = {}, collect = {} }
  local open_before = open_list()
  if prev and c.ring > prev.ring then
    local keep = {}
    for i = #loaders_out, 1, -1 do
      local t = loaders_out[i]
      if t[4] == prev.ring and not (t[1] == 0 and t[2] > 0) then -- (not the spoke's)
        l0.collect[#l0.collect + 1] = t
      end
    end
    for _, t in ipairs(loaders_out) do
      if not (t[4] == prev.ring and not (t[1] == 0 and t[2] > 0)) then keep[#keep + 1] = t end
    end
    if #l0.collect > 0 then
      l0.collect_open = open_before
      l0.wait_clear = true
      loaders_out = keep
    end
  end
  for _, t in ipairs(loaders_for(j)) do
    l0.place[#l0.place + 1] = t
    loaders_out[#loaders_out + 1] = t
  end
  l0.place_open = open_list()
  current_chunk = j
  arrived = {}
  last_next = { cmd = "next_chunk", seq = j, ring = c.ring, idx = c.idx, count = c.count,
    a = c.a, b = c.b, d = c.d, open = open_list(), travel_open = open_before, l0 = l0 }
  -- one message every lane hears at once (they all set off together)
  queue_send(nil, last_next, PROTOCOL)
  local others = false
  for lane in pairs(miners) do if lane ~= 0 then others = true end end
  if l0.wait_clear and not others and miners[0] then
    send(0, { cmd = "clear", id = 0, seq = j })
  end
  add_log("control", string.format("Ring %d, chunk %d/%d (%d,%d): off we go.", c.ring, c.idx, c.count, c.a, c.b))
  for lane in pairs(miners) do
    miners[lane].status = "to chunk " .. ckey(c.a, c.b)
    miners[lane].pass = nil
  end
  save_run()
end

-- Called when a lane reports its part done: if everyone has, the chunk is
-- finished; then the next one, or the run is over.
function advance()
  local c = plan[current_chunk]
  if c then
    for lane in pairs(miners) do
      if (done[lane] or 0) < current_chunk then return end
    end
    mined[ckey(c.a, c.b)] = true
    save_map()
    add_log("control", string.format("Chunk (%d,%d) finished (ring %d, %d/%d).", c.a, c.b, c.ring, c.idx, c.count))
  end
  local j = next_unfinished(current_chunk)
  if stop_requested or last_chunk or not j then
    finished = true
    if stop_requested then
      add_log("control", "Stopped. Lanes are heading home.")
    else
      add_log("control", "Run complete: rings 1-" .. chunks .. " are mined. Lanes are heading home.")
    end
    for lane in pairs(miners) do tell_stop(lane) end
    save_run()
    return
  end
  go_to_chunk(j)
end]==])

------------------------------------------------------------------------------
-- 9. handling the lanes' messages
rep([==[      send(lane, { cmd = "start", id = lane, length = length, depth = depth,
        chunks = last_chunk_no(), chunk = current_chunk, skip = skip })
      save_run()]==], [==[      send(lane, { cmd = "start", id = lane })
      save_run()]==])
rep([==[      m.home, m.at_home, m.confirmed = nil, nil, nil
      send(lane, { cmd = "start", id = lane, length = length, depth = depth,
        chunks = last_chunk_no(), chunk = current_chunk, skip = skip })]==],
    [==[      m.home, m.at_home, m.confirmed = nil, nil, nil
      send(lane, { cmd = "start", id = lane })]==])
rep([==[      m.status = "collecting loaders"
      send(lane, { cmd = "collect", id = lane })]==], [==[      m.status = "collecting loaders"
      local list = {}
      for i = #loaders_out, 1, -1 do list[#list + 1] = loaders_out[i] end
      send(lane, { cmd = "collect", id = lane, list = list, open = open_list() })]==])
cut([==[  elseif msg.cmd == "chunk_done" then
    if msg.no_next_loader and not last_chunk then]==], [==[-- States a lane only ever reports while on its start spot.]==], [==[  elseif msg.cmd == "chunk_done" then
    local seq = tonumber(msg.seq) or 0
    if (done[lane] or 0) < seq then
      done[lane] = seq
      save_run()
    end
    if finished or stop_requested then
      tell_stop(lane)
    elseif seq < current_chunk and last_next then
      -- behind (it missed the message, or was restarted): send it again
      local copy = {}
      for k, v in pairs(last_next) do copy[k] = v end
      copy.id = lane
      send(lane, copy)
    elseif current_chunk > 0 then
      m.status = "chunk " .. (plan[current_chunk] and ckey(plan[current_chunk].a, plan[current_chunk].b) or "?")
        .. " done, waiting"
      advance()
    end
  elseif msg.cmd == "arrived" then
    -- at a ring change: once everyone else is out of the finished ring,
    -- lane 0 may take its loaders back
    if tonumber(msg.seq) == current_chunk then
      arrived[lane] = true
      local all = true
      for other in pairs(miners) do
        if other ~= 0 and not arrived[other] then all = false end
      end
      if all and miners[0] then
        send(0, { cmd = "clear", id = 0, seq = current_chunk })
        add_log("control", "Everyone is out of the finished ring: lane 0 is taking its loaders back.")
      end
    end
  end
end

]==])
rep([==[    if type(msg.chunk_done) == "table" then
      handle(sender, { cmd = "chunk_done", id = msg.id, chunk = msg.chunk_done.chunk,
        no_next_loader = msg.chunk_done.no_next_loader })
    end]==], [==[    if type(msg.chunk_done) == "table" then
      handle(sender, { cmd = "chunk_done", id = msg.id, seq = msg.chunk_done.seq })
    end
    if type(msg.arrived) == "table" then
      handle(sender, { cmd = "arrived", id = msg.id, seq = msg.arrived.seq })
    end]==])

------------------------------------------------------------------------------
-- 10. settings panel: rings, and "start over"
rep([==[  setting("Chunks to mine", panel.chunks == 0 and "no limit" or panel.chunks, "c", "0 = no limit")
  setting("Already mined (driven past)", panel.mined, "m", "0 = start over at chunk 1")
  boxes({]==], [==[  setting("Mine up to ring", panel.chunks, "c", "ring 1 = the 8 chunks around the base")
  line({ { " Finished chunks on the map: " .. panel.mined, colors.white } })
  boxes({
    { label = panel.reset and "MAP CLEARED" or (panel.confirm_reset and "SURE?" or "START OVER"),
      w = 14, name = panel.confirm_reset and "reset2" or "reset",
      bg = panel.confirm_reset and colors.orange or colors.gray },
  })
  line({ { " (start over: every chunk gets checked again)", colors.lightGray } })
  line({})
  boxes({]==])
rep([==[local PANEL_W, PANEL_H = 40, 19]==], [==[local PANEL_W, PANEL_H = 40, 20]==])
rep([==[local function save_settings()
  chunks = math.max(0, panel.chunks)
  write_progress(math.max(0, panel.mined))
  skip = read_progress()
  local f = fs.open(SETTINGS_FILE, "w")
  f.write(length .. "\n0\n" .. chunks .. "\n")
  f.close()
  save_run()
  add_log("control", string.format("Settings saved: %s, %d mined before (driven past).",
    chunks == 0 and "until stopped" or (chunks .. " chunks"), skip))
end]==], [==[local function save_settings()
  chunks = math.max(1, panel.chunks)
  if panel.reset then
    mined = {}
    save_map()
    add_log("control", "Map cleared: every chunk gets checked again.")
  end
  local f = fs.open(SETTINGS_FILE, "w")
  f.write(chunks .. "\n")
  f.close()
  build_plan()
  save_run()
  add_log("control", "Settings saved: mine up to ring " .. chunks .. ".")
end]==])
rep([==[      panel = { chunks = chunks, mined = read_progress() }]==], [==[      local n = 0
      for _ in pairs(mined) do n = n + 1 end
      panel = { chunks = chunks, mined = n }]==])
rep([==[    local key, amount = name:match("^([cm])([%-%+]%d+)$")
    if key == "c" then panel.chunks = math.max(0, panel.chunks + tonumber(amount)) end
    if key == "m" then panel.mined = math.max(0, panel.mined + tonumber(amount)) end]==],
    [==[    if name == "reset" then panel.confirm_reset = true
    elseif name == "reset2" then panel.reset, panel.confirm_reset, panel.mined = true, nil, 0 end
    local key, amount = name:match("^([cm])([%-%+]%d+)$")
    if key == "c" then panel.chunks = math.max(1, panel.chunks + tonumber(amount)) end]==])

------------------------------------------------------------------------------
-- 11. messages at boot
rep([==[  add_log("control", "Restarted: resuming the run at chunk " .. current_chunk .. ".")]==],
    [==[  add_log("control", "Restarted: resuming the run (" .. where_text() .. ").")]==])
rep([==[  add_log("control", string.format("Controller ready (down to bedrock, %s, %d mined before). Waiting for lanes.",
    chunks == 0 and "until stopped" or (chunks .. " chunks"), read_progress()))]==],
    [==[  add_log("control", "Controller ready (rings 1-" .. chunks .. ", down to bedrock). Waiting for lanes.")]==])


------------------------------------------------------------------------------
-- 12. RECALL: everyone home now (no finishing the pass), from the monitor
rep([==[local confirm_stop_until = 0]==], [==[local confirm_stop_until = 0
local confirm_recall_until = 0]==])
rep([==[  add(" LOG ", "logs", colors.lightGray)
  add(" ", nil, nil)
  if not started then]==], [==[  add(" LOG ", "logs", colors.lightGray)
  add(" ", nil, nil)
  if started and not finished and not recalled then
    if os.clock() < confirm_recall_until then
      add(" RECALL? ", "confirm_recall", colors.orange)
    else
      add(" RECALL ", "recall", colors.purple)
    end
    add(" ", nil, nil)
  end
  if not started then]==])
rep([==[local function do_stop()
  if not started or stop_requested or finished then return end]==], [==[local recalled = false
local do_recall -- (with the fleet control code below)

local function do_stop()
  if not started or stop_requested or finished then return end]==])
rep([==[local function all_stopped()]==], [==[-- RECALL: like STOP, but the lanes drop what they're doing and come home
-- at once (lane 0 still takes the loaders back after).
function do_recall()
  if not started or finished or recalled then return end
  recalled, stop_requested = true, true
  add_log("control", "RECALL: every turtle comes home now.")
  save_run()
  for lane in pairs(miners) do
    send(lane, { cmd = "recall", id = lane, open = open_list() })
    stopped[lane] = true
    miners[lane].stop_sent = os.clock()
    miners[lane].status = "recalled, going home"
  end
end

local function all_stopped()]==])
rep([==[  elseif name == "confirm_stop" then
    confirm_stop_until = 0
    do_stop()]==], [==[  elseif name == "confirm_stop" then
    confirm_stop_until = 0
    do_stop()
  elseif name == "recall" then
    confirm_recall_until = os.clock() + 5
  elseif name == "confirm_recall" then
    confirm_recall_until = 0
    do_recall()]==])
rep([==[  current_chunk = 0
  loaders_out, last_next = {}, nil
  done, stopped = {}, {}]==], [==[  current_chunk = 0
  loaders_out, last_next = {}, nil
  recalled = false
  done, stopped = {}, {}]==])

f = assert(io.open(path, "wb")); f:write(s); f:close()
print("ok")

LIB = "patchlib.lua"
dofile("patch_control2.lua")
