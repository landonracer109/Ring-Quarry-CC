
-- Run state -------------------------------------------------------------------
-- S holds everything needed to carry on after a restart. It's nil when no
-- run is in progress. Position: e = blocks EAST of lane 0's start spot,
-- n = blocks NORTH of it, y = blocks up from the home row (negative below);
-- f = facing (0 north, 1 east, 2 south, 3 west). Saved to two files in
-- turn before every move, so a restart in the middle of writing one never
-- loses both. After a restart GPS (if there is one) has the last word.
-- (S is declared with the network code above.)
local save_seq = 0

local function save()
  save_seq = save_seq + 1
  S.seq = save_seq
  S.fuel = turtle.getFuelLevel()
  -- the in-game clock: saved with the world, so after a server crash it's
  -- behind this (see start_run)
  S.wt = math.floor(world_seconds())
  local f = fs.open(STATE_FILES[save_seq % 2 + 1], "w")
  f.write(textutils.serialize(S))
  f.close()
end

local function load_state()
  local best
  for _, name in ipairs(STATE_FILES) do
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

local DONE_FILE = ".quarry_done" -- (our state at the end of the last run)

local function clear_state()
  for _, name in ipairs(STATE_FILES) do fs.delete(name) end
  S = nil
end

-- unique per program run, so the service turtle can tell a restart apart
local session = os.getComputerID() .. ":" .. os.day() .. ":" .. os.time()
local service_seq = 0

-- Samples in 12-14 for this run? They stay put for the whole run, even
-- if the trash can gets lost.
local function has_samples()
  return S ~= nil and (S.samples or S.trash) and true or false
end

local function is_cargo(slot)
  if has_samples() and slot >= SAMPLE_SLOTS[1] and slot <= SAMPLE_SLOTS[#SAMPLE_SLOTS] then
    return false
  end
  if S and S.trash and slot == TRASH_SLOT then return false end
  return not (LANE == 0 and slot == LOADER_SLOT and (not S or (S.loaders or 0) > 0))
end

local function fuel_level()
  local level = turtle.getFuelLevel()
  if level == "unlimited" then return math.huge end
  return level
end

-- Rings -----------------------------------------------------------------------
-- The quarry mines rings of chunks around the CONTROL chunk (main computer
-- tower, service turtle), clockwise, starting with the spoke: the line of
-- chunks straight north of the control chunk, where our start spots are.
-- Chunk (a, b) is a chunks east and b chunks north of the control chunk;
-- chunk (0, 1) holds our start spots (its south row).
-- (The same code is in the main computer's program.)
local CHUNK = 16
local STEP = { [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } } -- e, n per facing
local FACING_NAME = { [0] = "north", [1] = "east", [2] = "south", [3] = "west" }

local function chunk_box(a, b) -- e0, e1, n0, n1
  local e0, n0 = a * CHUNK, (b - 1) * CHUNK
  return e0, e0 + CHUNK - 1, n0, n0 + CHUNK - 1
end

local function chunk_of(e, n)
  return math.floor(e / CHUNK), math.floor(n / CHUNK) + 1
end

local function ckey(a, b) return a .. "," .. b end

-- Never dug or entered: the control chunk, and the service turtle's home
-- (fuel chest below, output chest above) plus the marker block in front of
-- it, each with the whole column under it.
local function protected(e, n)
  if e >= 0 and e < CHUNK and n < 0 and n >= -CHUNK then return true end
  return e == -1 and (n == -1 or n == 0)
end

-- Our lane in chunk (a, b) mined going `d`: its cells in mining order.
-- Lane 0 is the leftmost, looking the way the lanes run.
local function lane_cells(a, b, d, lane)
  local e0, e1, n0, n1 = chunk_box(a, b)
  local cells = {}
  for k = 0, CHUNK - 1 do
    local e, n
    if d == 0 then e, n = e0 + lane, n0 + k
    elseif d == 1 then e, n = e0 + k, n1 - lane
    elseif d == 2 then e, n = e1 - lane, n1 - k
    else e, n = e1 - k, n0 + lane end
    if not protected(e, n) then cells[#cells + 1] = { e = e, n = n } end
  end
  return cells
end

-- Where lane 0 stands to put a loader into chunk (a, b) (lanes going d):
-- where it steps into its own lane there, in the chunk the fleet comes
-- from, one above the home row, facing in. No other turtle uses that
-- column, and it's where lane 0 goes next anyway.
local function loader_spot(a, b, d)
  local first = lane_cells(a, b, d, 0)[1]
  return { e = first.e - STEP[d][1], n = first.n - STEP[d][2], f = d }
end

-- Movement ------------------------------------------------------------------
-- Every move is saved BEFORE it happens, with the fuel level: after a
-- restart, fuel one lower means the move happened. A turtle in the way is
-- never dug (in this CC version a turtle can dig another one): we wait for
-- it to move. Nor is a protected block, ever.
local SIDE = { f = "front", b = "back", u = "top", d = "bottom" }
local MOVE = { f = turtle.forward, b = turtle.back, u = turtle.up, d = turtle.down }
local DIG = { f = turtle.dig, u = turtle.digUp, d = turtle.digDown }
local DETECT = { f = turtle.detect, u = turtle.detectUp, d = turtle.detectDown }
local ATTACK = { f = turtle.attack, u = turtle.attackUp, d = turtle.attackDown }
-- A mob parked in our way: we can't tell a mob from a PLAYER, so we only
-- ever swing when it's been in the way this long, this deep down (players
-- walk the surface, the home row and the tunnels), and never while
-- travelling between chunks.
local ATTACK_AFTER = 60 -- seconds blocked
local ATTACK_DEPTH = 5  -- layers below the surface
local ATTACK_HITS = 3   -- swings per minute of being blocked
local COMPARE = { f = turtle.compare, u = turtle.compareUp, d = turtle.compareDown }

-- Lane 0 never digs a Spot Loader by accident (only when collecting it):
-- after a server crash it can find itself right under one.
local function is_loader(dir)
  if LANE ~= 0 or turtle.getItemCount(LOADER_SLOT) == 0 then return false end
  turtle.select(LOADER_SLOT)
  local same = COMPARE[dir]()
  turtle.select(1)
  return same
end

-- the cell a move in direction dir goes to
local function target(dir)
  if dir == "u" then return S.e, S.y + 1, S.n end
  if dir == "d" then return S.e, S.y - 1, S.n end
  local f = (dir == "b") and (S.f + 2) % 4 or S.f
  return S.e + STEP[f][1], S.y, S.n + STEP[f][2]
end

local function apply_move(dir)
  S.e, S.y, S.n = target(dir)
end

local check_facing, find_facing, turn_to -- (below)

local function try_move(dir)
  S.pending = dir
  save()
  local ok = MOVE[dir]()
  S.pending = nil
  if ok then
    apply_move(dir)
    if S.check_facing and (dir == "f" or dir == "b") then check_facing(dir) end
  end
  return ok
end

local function is_turtle(dir)
  return peripheral.getType(SIDE[dir]) == "turtle"
end

local burn_fuel -- (defined with the inventory code below)

-- Out of fuel: burn any fuel we carry; if there's none, wait right here
-- until someone puts some in us. Never give up: a failed move would be
-- taken for bedrock.
local function wait_for_fuel()
  local warned = false
  while turtle.getFuelLevel() == 0 do
    burn_fuel()
    if turtle.getFuelLevel() == 0 then
      if not warned then
        say("Out of fuel! Put fuel (e.g. coal blocks) in any of my slots 1-11.",
          "OUT OF FUEL - refuel by hand")
        warned = true
      end
      sleep(10)
    end
  end
  if warned then say("Got fuel, carrying on.", "working") end
end

local lost -- (defined at the end)

-- One block in direction dir ("f", "b", "u", "d"), digging whatever is in
-- the way (not backwards: we can't dig behind us). Returns false, "bedrock"
-- when something can't be dug.
local function step(dir)
  local failed, digs, waits, warned = 0, 0, 0, false
  local blocked_since
  while true do
    local te, ty, tn = target(dir)
    if protected(te, tn) then
      lost("I was about to enter a protected spot (" .. te .. ", " .. ty .. ", " .. tn .. ").")
    end
    if try_move(dir) then
      if warned then say("Way is clear again.", "working") end
      return true
    end
    if turtle.getFuelLevel() == 0 then wait_for_fuel() end
    if dir == "f" and S.check_facing then
      local near = false
      for f = 0, 3 do
        if protected(S.e + STEP[f][1], S.n + STEP[f][2]) then near = true end
      end
      if near then
        local want = S.f
        if not find_facing() then
          lost("Next to a protected spot and I can't tell which way I face.")
        end
        turn_to(want)
      end
    end
    if dir == "f" and S.check_facing and DETECT[dir]() then
      -- (the way the caller meant: turn there for real once we know)
      local want = S.f
      find_facing()
      turn_to(want)
    end
    if dir ~= "b" and DETECT[dir]() and not is_turtle(dir) then
      if is_loader(dir) then
        debug("A Spot Loader is in my way (" .. dir .. "): not digging it")
        return false, "loader"
      end
      if DIG[dir]() then
        failed = 0
        digs = digs + 1
        if digs > 50 then -- endless gravel? give up
          debug("Gave up moving " .. dir .. ": dug 50 times and still blocked")
          return false
        end
      else
        failed = failed + 1
        if failed >= UNBREAKABLE_TRIES then
          debug("Can't dig " .. dir .. " (" .. UNBREAKABLE_TRIES .. " tries): taking it as bedrock")
          return false, "bedrock"
        end
      end
    else
      -- a mob, a player, another turtle, or a chunk that isn't loaded yet
      -- (its loader comes any moment): wait, longer and longer up to 10 s
      if not warned then
        say("Something is in my way. Waiting for it to move...", "blocked")
        debug("(moving " .. dir .. " facing " .. S.f .. " to " .. te .. " " .. ty .. " " .. tn .. ")")
        warned = true
        blocked_since = os.clock()
      end
      if ATTACK[dir] and os.clock() - blocked_since >= ATTACK_AFTER
          and S.y <= -ATTACK_DEPTH and not S.traveling and not is_turtle(dir) then
        local hits = 0
        for _ = 1, ATTACK_HITS do
          if not ATTACK[dir]() then break end
          hits = hits + 1
          sleep(0.5)
        end
        if hits > 0 then
          say("A mob was in my way at y=" .. S.y .. ": attacked it (" .. hits .. " hits).")
        end
        blocked_since = os.clock() -- (the next swings a minute from now)
      end
      sleep(math.min(1 + waits, 10))
      waits = waits + 1
    end
    sleep(0.3)
  end
end

local function forward() return step("f") end
local function back() return step("b") end
local function up() return step("u") end
local function down() return step("d") end

local function go_to_y(target_y)
  while S.y < target_y do
    local ok, why = up()
    if not ok then return false, why end
  end
  while S.y > target_y do
    local ok, why = down()
    if not ok then return false, why end
  end
  return true
end


-- One block sideways (or back), never digging: out from under a loader.
local function sidestep()
  if try_move("b") then return true end
  for _ = 1, 4 do
    turn_to((S.f + 1) % 4)
    if not DETECT.f() and not is_turtle("f") and try_move("f") then return true end
  end
  return false
end

-- Turning: saved first, like a move (a turn costs no fuel, so after a
-- restart mid-turn we look which way we face: see find_facing).
function turn_to(f)
  while S.f ~= f do
    local right = (f - S.f) % 4 ~= 3
    S.turning = true
    save()
    if right then turtle.turnRight() else turtle.turnLeft() end
    S.f = right and (S.f + 1) % 4 or (S.f + 3) % 4
    S.turning = nil
    save()
  end
end

-- GPS -----------------------------------------------------------------------
-- With GPS hosts on the tower a turtle can always find out where it is.
-- ORIGIN: the world coordinates of lane 0's start spot, worked out at home.
local ORIGIN_FILE = ".quarry_origin"
local origin
if fs.exists(ORIGIN_FILE) then
  local h = fs.open(ORIGIN_FILE, "r")
  origin = textutils.unserialize(h.readAll() or "")
  h.close()
end

local function locate()
  if not gps then return nil end
  local ok, x, y, z = pcall(gps.locate, 2)
  if not ok or not x then return nil end
  return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
end

-- Our position in quarry coordinates, or nil (no GPS, or not calibrated).
local function gps_here()
  if not origin then return nil end
  local x, y, z = locate()
  if not x then return nil end
  return x - origin.x, y - origin.y, origin.z - z
end

-- At home, between runs: remember where lane 0's start spot is.
local function calibrate()
  local x, y, z = locate()
  if not x then return end
  local o = { x = x - LANE, y = y, z = z }
  if not origin or o.x ~= origin.x or o.y ~= origin.y or o.z ~= origin.z then
    origin = o
    local h = fs.open(ORIGIN_FILE, "w")
    h.write(textutils.serialize(o))
    h.close()
    debug("GPS: lane 0's start spot is at " .. o.x .. " " .. o.y .. " " .. o.z)
  end
end

-- Which way do we face? Move a block and see where GPS puts us, then move
-- back (tries all four ways; never digs). Only after a restart mid-turn.
local function facing_from(de, dn)
  for f = 0, 3 do
    if STEP[f][1] == de and STEP[f][2] == dn then return f end
  end
end

local function probe_facing(anywhere)
  local bf = S.f -- (the way we think we face: no test step into a protected
  -- spot. The test step never digs, so if we're wrong it's only into air.
  -- anywhere: below the surface, where protected spots are solid rock)
  for _ = 1, 4 do
    local e, _, n = gps_here()
    if not e then return false end
    if (anywhere or not protected(S.e + STEP[bf][1], S.n + STEP[bf][2])) and turtle.forward() then
      local e2, _, n2 = gps_here()
      if not turtle.back() and e2 then
        S.e, S.n = e2, n2 -- (someone came in behind us: we stay here)
      end
      local f = e2 and facing_from(e2 - e, n2 - n)
      if f then
        S.f = f
        S.check_facing = nil
        save()
        return true
      end
    end
    turtle.turnRight()
    bf = (bf + 1) % 4
  end
  -- boxed in (deep down, all four sides solid): the first step we take
  -- forward or back shows it (GPS before and after)
  S.check_facing = true
  save()
  return false
end

function find_facing()
  local near = false
  for f = 0, 3 do
    if protected(S.e + STEP[f][1], S.n + STEP[f][2]) then near = true end
  end
  if not near then return probe_facing() end
  -- Next to a protected spot: protected spots are never dug, so below the
  -- surface they're solid and a test step can't go in. Look from there.
  local y0 = S.y
  local ok = go_to_y(math.min(y0, -1)) and probe_facing(true)
  if not ok then
    S.check_facing = true
    save()
  end
  go_to_y(y0)
  return ok
end

-- After a step forward or back while we're not sure which way we face.
function check_facing(dir)
  local e, _, n = gps_here()
  if not e then return end
  local sign = (dir == "f") and 1 or -1
  -- (our notes moved us one step along the facing we thought we had)
  local e0, n0 = S.e - sign * STEP[S.f][1], S.n - sign * STEP[S.f][2]
  local f = facing_from(sign * (e - e0), sign * (n - n0))
  if f then
    if f ~= S.f then debug("GPS: I was facing " .. f .. ", not " .. S.f) end
    S.f = f
    S.check_facing = nil
  end
  S.e, S.n = e, n
  save()
end

-- Travel --------------------------------------------------------------------
-- Between chunks we only travel through chunks that are mined out and
-- loaded ("open": the main computer tells us which), at our own depth
-- (lane 0 two below the home row, lane 1 three, ...), so two travelling
-- turtles never meet. We turn only down there.
local function travel_depth()
  local h = -(2 + LANE)
  if S.depth then h = math.max(h, -(S.depth - 1)) end
  return h
end

local function is_open(open, a, b) return open and open[ckey(a, b)] end

-- Chunks to go through from (a1, b1) to (a2, b2), both included.
local function chunk_path(a1, b1, a2, b2, open)
  if a1 == a2 and b1 == b2 then return { { a1, b1 } } end
  local from = { [ckey(a1, b1)] = false }
  local todo, i = { { a1, b1 } }, 1
  while todo[i] do
    local a, b = todo[i][1], todo[i][2]
    i = i + 1
    for f = 0, 3 do
      local na, nb = a + STEP[f][1], b + STEP[f][2]
      local k = ckey(na, nb)
      if from[k] == nil and ((na == a2 and nb == b2) or is_open(open, na, nb)) then
        from[k] = { a, b }
        if na == a2 and nb == b2 then
          local path, c = { { na, nb } }, { a, b }
          while c do
            table.insert(path, 1, c)
            c = from[ckey(c[1], c[2])] or nil
          end
          return path
        end
        todo[#todo + 1] = { na, nb }
      end
    end
  end
end

-- Along the ground plan at our depth: east-west, then north-south (or the
-- other way round if that would pass a protected column).
local function crosses_protected(e1, n1, e2, n2, e_first)
  local ce, cn = e1, n1
  local function walk(te, tn)
    while ce ~= te or cn ~= tn do
      if ce ~= te then ce = ce + (te > ce and 1 or -1) else cn = cn + (tn > cn and 1 or -1) end
      if protected(ce, cn) then return true end
    end
  end
  if e_first then
    if walk(e2, cn) then return true end
  else
    if walk(ce, n2) then return true end
  end
  return walk(e2, n2) or false
end

local function go_flat(te, tn)
  local e_first = not crosses_protected(S.e, S.n, te, tn, true)
  -- (we aim again before every step: a GPS check after a restart can
  -- find we were facing another way, see check_facing)
  local function along_e()
    while S.e ~= te do
      turn_to(te > S.e and 1 or 3)
      if not forward() then return false end
    end
    return true
  end
  local function along_n()
    while S.n ~= tn do
      turn_to(tn > S.n and 0 or 2)
      if not forward() then return false end
    end
    return true
  end
  for _ = 1, 3 do
    local ok
    if e_first then ok = along_e() and along_n() else ok = along_n() and along_e() end
    if not ok then return false end
    if S.e == te and S.n == tn then return true end
  end
  return false
end

-- From where we are (in an open chunk) to cell (te, tn), height ty, facing
-- tf (optional; the turn happens down at our depth). sky: travel above the
-- ground instead (lane 0 with loaders: nobody else ever goes up there, so
-- it can't meet a turtle waiting at the spot below it).
local SKY = 2
-- Flying: above the ground we can also cross chunks that are loaded but not
-- mined yet (the chunk being mined, ring 1), which can cut a trip home from
-- all the way around a ring to a chunk or two. Each lane flies at its own
-- height (above cacti and most trees; anything in the way is dug).
local FLY_BASE = 8
local function fly_height() return FLY_BASE + LANE end

local function travel_to(te, tn, ty, tf, open, sky)
  open = open or S.open
  if S.e == te and S.n == tn then -- (already there: just up or down)
    if tf and S.y == ty then turn_to(tf) end
    if not go_to_y(ty) then return false end
    if tf then turn_to(tf) end
    return true
  end
  local a1, b1 = chunk_of(S.e, S.n)
  local a2, b2 = chunk_of(te, tn)
  local path = chunk_path(a1, b1, a2, b2, open)
  local fly = false
  if not sky then
    local air = {} -- (chunks we can fly over: loaded ones)
    for k in pairs(open or {}) do air[k] = true end
    if S.job then air[ckey(S.job.a, S.job.b)] = true end
    for a = -1, 1 do
      for b = -1, 1 do
        if a ~= 0 or b ~= 0 then air[ckey(a, b)] = true end -- (ring 1: always loaded)
      end
    end
    local fpath = chunk_path(a1, b1, a2, b2, air)
    -- (up in the air over a chunk that isn't mined: we must fly on)
    local must = S.y > 0 and not is_open(open, a1, b1)
    if fpath and (not path or must or #fpath < #path) then path, fly = fpath, true end
  end
  if not path then
    lost("No way from chunk " .. ckey(a1, b1) .. " to chunk " .. ckey(a2, b2) .. " through mined-out chunks.")
  end
  S.traveling = true
  local h = sky and SKY or (fly and fly_height() or travel_depth())
  for _ = 1, 4 do
    local ok, why = go_to_y(h)
    if ok then break end
    if why ~= "loader" or not sidestep() then return false end
  end
  if S.y ~= h then return false end
  for i = 2, #path do
    local e0, _, n0 = chunk_box(path[i][1], path[i][2])
    local mid = math.floor(CHUNK / 2)
    if not go_flat(e0 + mid, n0 + mid) then return false end
  end
  if not go_flat(te, tn) then return false end
  if tf then turn_to(tf) end
  S.traveling = nil
  return go_to_y(ty)
end
