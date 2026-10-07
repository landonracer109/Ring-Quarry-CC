
-- Our lane in the current chunk ------------------------------------------------
-- S.job: the chunk we're working on (seq = its place in the main
-- computer's plan, ring, a, b, d = which way the lanes run, cells = our
-- lane, approach = where we step into it from, in a mined-out chunk).
-- S.in_lane: we're inside our lane (mining, or on our way in or out).

local function cell_index()
  if not S.job or not S.job.cells then return nil end
  for k, c in ipairs(S.job.cells) do
    if c.e == S.e and c.n == S.n then return k end
  end
end

-- Along our lane (facing the way it runs): forward, or back without digging.
local function go_to_k(k)
  while true do
    local cur = cell_index()
    if not cur then return false end
    if cur == k then return true end
    turn_to(S.job.d) -- (after a restart we may have faced another way)
    if cur < k then
      if not forward() then return false end
    elseif not back() then
      return false
    end
  end
end

-- The cell we step into our lane from: behind its first cell if we may be
-- there, else beside it (the service turtle's marker block is in the way
-- of one lane). dir = the way we step in.
local function find_approach(job, open)
  local first = job.cells[1]
  for _, f in ipairs({ (job.d + 2) % 4, (job.d + 1) % 4, (job.d + 3) % 4 }) do
    local e, n = first.e + STEP[f][1], first.n + STEP[f][2]
    local a, b = chunk_of(e, n)
    if not protected(e, n) and is_open(open, a, b) then
      return { e = e, n = n, dir = (f + 2) % 4 }
    end
  end
end

local function enter_lane()
  local ap = S.job.approach
  if ap then
    turn_to(ap.dir)
    -- (waits here if the chunk isn't loaded yet: lane 0 is on its way
    -- with the loader)
    if not forward() then return false end
  end
  S.in_lane = true
  turn_to(S.job.d)
  save()
  return true
end

-- Up to the home row level and back along our lane to its first cell, then
-- out onto the approach cell.
local function leave_lane()
  if not cell_index() then S.in_lane = false return true end
  go_to_y(0)
  go_to_k(1)
  local ap = S.job.approach
  if ap then
    if ap.dir == S.f then
      back()
    else
      turn_to((ap.dir + 2) % 4)
      forward()
    end
  end
  S.in_lane = false
  save()
  return true
end

-- Messages from the control computer ------------------------------------------
-- (chunk lists come as { {a, b}, ... })
local function as_set(list)
  local set = {}
  for _, c in ipairs(list or {}) do set[ckey(c[1], c[2])] = true end
  return set
end

-- STOP (finish the pass, then home) or RECALL (home now), if one came in.
local function stop_heard()
  for i, ev in ipairs(inbox) do
    local msg = ev[3]
    if ev[4] == PROTOCOL and ev[2] == S.controller and type(msg) == "table"
        and (msg.cmd == "stop" or msg.cmd == "recall") then
      table.remove(inbox, i)
      if type(msg.open) == "table" then S.open = as_set(msg.open) end
      debug("Got " .. msg.cmd)
      return msg.cmd
    end
  end
end


-- Service turtle ------------------------------------------------------------
local check_in -- (below)

-- rough fuel for the way home from here and back
local function trip_fuel()
  return math.abs(S.y) + 2 * CHUNK + math.abs(S.e - LANE) + math.abs(S.n)
    + math.abs(travel_depth()) * 2 + FUEL_BUFFER
end

-- Home to our start spot (the service turtle waits on the row right behind
-- it), unloaded and refuelled, then back to where we were. If STOP comes
-- while we're home, we stay: S.stopped is set.
local function request_service(label, why)
  label = label or "waiting for service"
  if why then say("Heading home: " .. why .. ".") end
  local was = { e = S.e, y = S.y, n = S.n, k = cell_index() }
  local was_in_lane = S.in_lane and was.k ~= nil
  local need = 2 * trip_fuel() + CHUNK
  if was_in_lane then leave_lane() end
  travel_to(LANE, 0, 0, 0)

  while true do
  compact_cargo() -- (also: no point carrying junk to the service turtle)
  burn_fuel() -- (mined coal first: the fuel we report must be right)
  -- nothing left to unload once the junk is out, and fuel enough: no need
  -- to call (the service turtle doesn't answer a request with nothing in it)
  if stacks_for_service() == 0 and fuel_level() >= need then break end
  service_seq = service_seq + 1
  local req = {
    cmd = "service_request", id = LANE,
    session = session, seq = service_seq, z = 0,
    fuel = turtle.getFuelLevel(), limit = fuel_limit(), stacks = stacks_for_service(),
  }
  print("Waiting for service turtle...")
  say(nil, label)

  local acked = false
  local last_sent = -math.huge
  while true do
    -- re-send until acknowledged, then only now and then in case the
    -- service turtle was restarted (it forgets its queue)
    local interval = acked and 60 or 30
    if last_sent + interval - os.clock() <= 0 then -- (same sum as the wait below)
      req.controller = controller_id -- (so the service turtle can report straight to it)
      req.stacks = stacks_for_service() -- (count again: it may have taken some)
      if service_id then
        net_send(service_id, req, SERVICE_PROTOCOL)
      else
        net_broadcast(req, SERVICE_PROTOCOL)
      end
      if acked then say(nil, label) end
      last_sent = os.clock()
    end
    local sender, msg = net_receive(SERVICE_PROTOCOL, last_sent + interval - os.clock())
    if type(msg) == "table" and msg.id == LANE
        and msg.session == session and msg.seq == req.seq then
      service_id = sender
      if msg.cmd == "ack" then
        acked = true
      elseif msg.cmd == "serviced" then
        break
      end
    end
  end

  burn_fuel()
  tidy_slot_16()
  print("Serviced. Fuel: " .. tostring(turtle.getFuelLevel()))
  -- never drive back out on an empty "serviced": wait here and ask again
  if fuel_level() >= need and not inventory_nearly_full() then break end
  say("Still not enough fuel to get back to work: waiting at home.", "waiting for fuel")
  sleep(10)
  end -- while

  -- STOP pressed? We're home already: don't drive back out
  if not S.stopped and not check_in() then
    S.stopped = true
    save()
  end
  if S.stopped then
    say("Stopped: staying home.", "stopped, at home")
    return
  end
  say(nil, "back to work")
  if was_in_lane then
    local ap = S.job.approach
    if ap then
      travel_to(ap.e, ap.n, 0, ap.dir)
    else -- (our lane starts at our start spot)
      travel_to(S.job.cells[1].e, S.job.cells[1].n, 0, S.job.d)
    end
    enter_lane()
    go_to_k(was.k)
    go_to_y(was.y)
  end
end

-- enough to finish this row and still get home
local function fuel_needed()
  return trip_fuel() + CHUNK
end

local function ensure_ok()
  local unload = false
  if inventory_nearly_full() then
    -- junk out, split stacks merged (CC doesn't always put a dug block on
    -- its stack), mined coal burned: then see if we still need to go home
    compact_cargo()
    burn_fuel() -- coal we mined: as much as fits in the tank, freeing slots
    unload = free_cargo_slots() < FREE_AFTER_DUMP
  elseif fuel_level() < fuel_needed() then
    burn_fuel()
  end
  -- loop: one delivery might not be enough
  while unload or fuel_level() < fuel_needed() or inventory_nearly_full() do
    local why
    if fuel_level() < fuel_needed() then
      why = "fuel " .. fuel_level() .. " < " .. fuel_needed() .. " needed"
    else
      why = "unloading, " .. free_cargo_slots() .. " free slots"
    end
    unload = false
    request_service(nil, why)
    if S.stopped then return end
  end
end

-- Before a trip between chunks: enough fuel for it?
local function ensure_fuel_for(e, n)
  local need = math.abs(S.e - e) + math.abs(S.n - n) + 2 * CHUNK
    + 2 * math.abs(travel_depth()) + FUEL_BUFFER
  while fuel_level() < need do
    burn_fuel()
    if fuel_level() >= need then break end
    request_service(nil, "fuel " .. fuel_level() .. " < " .. need .. " for the trip")
    if S.stopped then return end
  end
end

-- Control computer ----------------------------------------------------------
-- Once a pass: a STOP that came in makes us finish up; RECALL too.
function check_in()
  say(nil, "mining pass " .. tostring(S.pass))
  local cmd = stop_heard()
  if cmd then
    if cmd == "recall" then S.recall = true end
    return false
  end
  return true
end

-- Chunk loaders (lane 0) --------------------------------------------------------
local function loaders_left()
  S.loaders = turtle.getItemCount(LOADER_SLOT)
  return S.loaders > 0
end

-- Puts a loader into chunk (a, b), standing in (pa, pb) next to it.
local function place_loader(t, open)
  local spot = loader_spot(t[1], t[2], t[3])
  ensure_fuel_for(spot.e, spot.n)
  travel_to(spot.e, spot.n, 1, spot.f, open, true)
  turtle.select(LOADER_SLOT)
  local there = turtle.compare()
  if not there then
    if not loaders_left() then
      turtle.select(1)
      say("Out of Spot Loaders (slot 16)! Chunk " .. ckey(t[1], t[2]) .. " won't load.", "OUT OF LOADERS")
      return false
    end
    if turtle.detect() and not is_turtle("f") then turtle.dig() end
    turtle.select(LOADER_SLOT)
    there = turtle.place()
  end
  turtle.select(1)
  loaders_left()
  save()
  debug("Loader for chunk " .. ckey(t[1], t[2]) .. (there and " placed" or " NOT placed"))
  return there
end

-- Takes the loader of chunk (a, b) back (from the same spot).
local function collect_loader(t, open)
  local spot = loader_spot(t[1], t[2], t[3])
  ensure_fuel_for(spot.e, spot.n)
  travel_to(spot.e, spot.n, 1, spot.f, open, true)
  turtle.select(LOADER_SLOT)
  if turtle.getItemCount(LOADER_SLOT) == 0 or turtle.compare() then
    dig_and_keep(LOADER_SLOT, turtle.dig)
  end
  turtle.select(1)
  loaders_left()
  save()
  debug("Loader of chunk " .. ckey(t[1], t[2]) .. " collected")
end

-- Several, newest first: each one's spot is in a chunk that's still loaded.
-- The list is kept on disk and shortened as we go: after a restart we carry
-- on with the loaders still out (never back through a chunk already unloaded).
-- Called with no list: carries on with the one on disk.
local function collect_all(list, open_list, final)
  if list or not S.collecting then
    -- (all and open0 stay: a server crash can put them back, see redo_loaders)
    S.collecting = { list = {}, open = as_set(open_list), all = list or {}, open0 = open_list or {},
      final = final or (S.collecting and S.collecting.final) }
    for i, t in ipairs(S.collecting.all) do S.collecting.list[i] = t end
    save()
  end
  local c = S.collecting
  while #c.list > 0 do
    local t = c.list[1]
    collect_loader(t, c.open)
    table.remove(c.list, 1)
    c.open[ckey(t[1], t[2])] = nil -- (unloaded now)
    if S.open then S.open[ckey(t[1], t[2])] = nil end
    save()
  end
  c.done = true
  save()
  return c.open
end

-- After a server CRASH (lane 0): the world went back up to a minute, so a
-- loader we put in may be gone again, or one we took may be back. Do this
-- job's loader work over (both are safe to repeat).
local function redo_loaders()
  if S.in_lane or cell_index() then leave_lane() end
  S.in_lane = false
  local c = S.collecting
  local placed = S.job and S.job.placed or 0
  if c and #c.all > 0 and (c.final or placed == 0) then
    -- Nothing put in since: our notes' count minus what we hold is how
    -- many the crash put back: the last ones we took.
    local held = turtle.getItemCount(LOADER_SLOT)
    if held > 0 then
      for i = 1, 16 do
        if i ~= LOADER_SLOT and turtle.getItemCount(i) > 0 then
          turtle.select(i)
          if turtle.compareTo(LOADER_SLOT) then held = held + turtle.getItemCount(i) end
        end
      end
      turtle.select(1)
    end
    local taken = #c.all - #c.list
    local back_out = math.max(0, math.min(taken, (S.loaders or held) - held))
    local rest, open = {}, as_set(c.open0)
    for i = 1, #c.all do
      if i <= taken - back_out then
        open[ckey(c.all[i][1], c.all[i][2])] = nil
      else
        rest[#rest + 1] = c.all[i]
      end
    end
    local open_list = {}
    for k in pairs(open) do
      local a, b = k:match("^(-?%d+),(-?%d+)$")
      open_list[#open_list + 1] = { tonumber(a), tonumber(b) }
    end
    if back_out > 0 then
      say("Server crash: " .. back_out .. " loader(s) are back out: picking them up again.", "collecting loaders")
    end
    collect_all(rest, open_list)
  elseif c and #c.all > 0 then
    -- The crash put back the loaders we took since the world's last save:
    -- the last few of the list. We're where we were then, so the spot
    -- nearest to us is where we were at: look there, then carry on.
    local function open_without(upto)
      local set = as_set(c.open0)
      for i = 1, upto do set[ckey(c.all[i][1], c.all[i][2])] = nil end
      return set
    end
    local best, best_d
    for i, t in ipairs(c.all) do
      local spot = loader_spot(t[1], t[2], t[3])
      local d = math.abs(spot.e - S.e) + math.abs(spot.n - S.n)
      if not best_d or d < best_d then best, best_d = i, d end
    end
    local t = c.all[best]
    local spot = loader_spot(t[1], t[2], t[3])
    local a1, b1 = chunk_of(S.e, S.n)
    local a2, b2 = chunk_of(spot.e, spot.n)
    local from = best
    if chunk_path(a1, b1, a2, b2, open_without(best)) then
      say("Server crash: checking the loaders I picked up.", "collecting loaders")
      travel_to(spot.e, spot.n, 1, spot.f, open_without(best), true)
      turtle.select(LOADER_SLOT)
      if not turtle.compare() then from = best + 1 end -- (that one's gone)
      turtle.select(1)
    end
    local rest = {}
    for i = from, #c.all do rest[#rest + 1] = c.all[i] end
    local open = open_without(from - 1)
    local open_list = {}
    for k in pairs(open) do
      local a, b = k:match("^(-?%d+),(-?%d+)$")
      open_list[#open_list + 1] = { tonumber(a), tonumber(b) }
    end
    collect_all(rest, open_list) -- (another crash: this shorter list is right too)
  end
  local l0 = S.job and S.job.l0
  -- (not on the way home: those loaders are the ones we took back)
  if l0 and (S.job.l0_done or (S.job.placed or 0) > 0)
      and not S.stopped and S.phase ~= "going_home" then
    for _, t in ipairs(l0.place or {}) do
      place_loader(t, as_set(l0.place_open))
    end
  end
  S.redo_loaders = nil
  save()
end

-- Mining --------------------------------------------------------------------
-- Digs straight down from our lane's first cell until bedrock, and
-- remembers how deep that is (bedrock is flat: the same for every chunk).
local function find_bedrock()
  say("Digging down to find bedrock...", "finding bedrock")
  while true do
    ensure_ok()
    if S.stopped then return end
    local ok, why = down()
    if not ok and why == "bedrock" then break end
    if not ok then sleep(1) end
  end
  S.depth = 1 - S.y -- (we're on the lowest layer that can be mined)
  save()
  say("Bedrock is " .. (S.depth + 1) .. " blocks down.", "working")
end

local function passes_per_chunk() return math.ceil(S.depth / 3) end

-- Pass p is centered on y = -1 - 3(p-1) and clears that layer plus the ones
-- above and below it. The last one is raised so it stays inside the depth.
local function pass_center(p)
  return math.max(-1 - 3 * (p - 1), -(S.depth - 1))
end

local function clear_above_below(bottom)
  if S.y + 1 <= 0 then
    while turtle.detectUp() and not is_turtle("u") do
      if not turtle.digUp() then break end
      sleep(0.3) -- let falling gravel/sand land
    end
  end
  if S.y - 1 >= bottom and turtle.detectDown() and not is_turtle("d") then
    turtle.digDown()
  end
end

-- Is our lane already mined out (a chunk from an earlier run)? Lanes are
-- mined from the top down, so the bottom layer is the last thing done: go
-- down our first column and along the bottom, without digging.
local function lane_already_mined()
  local bottom = -(S.depth - 1)
  while S.y > bottom do
    if turtle.detectDown() then return false end
    if not down() then return false end
  end
  for _ = 2, #S.job.cells do
    if turtle.detect() then return false end
    if not forward() then return false end
  end
  return true
end

-- One pass: down to the pass's layer at our first cell, along the lane to
-- its far end, then back. Returns false if we hit something unbreakable.
local function do_pass(p)
  local bottom = -(S.depth - 1)
  local cy = pass_center(p)
  local cells = S.job.cells
  turn_to(S.job.d) -- (after a crash we may face some other way)
  if S.y ~= cy then
    go_to_k(1) -- back along an already-mined layer
    if not go_to_y(cy) then return false end
  end
  clear_above_below(bottom)
  while cell_index() < #cells do
    ensure_ok()
    if S.stopped then return true end
    local cmd = stop_heard()
    if cmd == "recall" then
      S.recall, S.stopped = true, true
      save()
      return true
    elseif cmd == "stop" then
      S.stop_after_pass = true
    end
    if not forward() then return false end
    clear_above_below(bottom)
  end
  go_to_k(1)
  return true
end

-- Mines the rest of our lane. Returns false if told to stop.
local function mine_lane()
  if not S.depth then
    find_bedrock()
    if S.stopped then return false end
  end
  if not S.pass then
    say(nil, "checking the chunk")
    S.pass = lane_already_mined() and passes_per_chunk() + 1 or 1
    if S.pass > 1 then say("Chunk " .. ckey(S.job.a, S.job.b) .. ": my lane is already mined.") end
    save()
  end
  while not S.stopped and S.pass <= passes_per_chunk() do
    if S.stop_after_pass or not check_in() then
      S.stopped = true
      save()
      break
    end
    ensure_ok()
    if S.stopped then break end
    local ok = do_pass(S.pass)
    if S.stopped then break end
    if S.stop_after_pass then S.stopped = true end
    if not ok then
      say("Pass " .. S.pass .. " hit something I can't dig at y=" .. S.y
        .. ": counting my lane as done.")
    end
    S.pass = ok and S.pass + 1 or passes_per_chunk() + 1
    save()
  end
  if cell_index() then
    go_to_k(1)
    go_to_y(0)
  end
  return not S.stopped
end

-- Main ----------------------------------------------------------------------
-- The run is a series of phases (S.phase), so after a restart we pick up
-- in the right one:
--   wait_next  our part of the last chunk is done: waiting for the next
--   to_chunk   (lane 0: loaders first) to our lane in the next chunk
--   mining     mining our lane
--   going_home back to the start spot at the end of the run
local function job_from(msg)
  local cells = lane_cells(msg.a, msg.b, msg.d, LANE)
  local job = { seq = msg.seq, ring = msg.ring, idx = msg.idx, count = msg.count,
    a = msg.a, b = msg.b, d = msg.d, cells = cells, l0 = msg.l0,
    -- (at a ring change: the way out of the finished ring, before lane 0
    -- takes its loaders back)
    travel_open = msg.travel_open or msg.open }
  -- our start spots are the first cells of chunk (0, 1): no approach
  local first = cells[1]
  if not (first.e == LANE and first.n == 0) then
    job.approach = find_approach(job, as_set(msg.open))
  end
  return job
end

-- Waits for the next chunk (or STOP). Our "done" is re-sent now and then in
-- case the control computer missed it.
local function wait_for_next()
  -- (right after START the first chunk is already on its way: no need to
  -- say anything unless it doesn't come)
  local last_sent = S.job and -math.huge or os.clock()
  while true do
    if last_sent + 60 - os.clock() <= 0 then -- (same sum as the wait below)
      tell("chunk_done", { seq = S.job and S.job.seq or 0 })
      last_sent = os.clock()
    end
    local sender, msg = net_receive(PROTOCOL, last_sent + 60 - os.clock())
    if sender == S.controller and type(msg) == "table" then
      if msg.cmd == "stop" or msg.cmd == "recall" then
        if type(msg.open) == "table" then S.open = as_set(msg.open) end
        return false
      end
      if msg.cmd == "next_chunk" and (not S.job or msg.seq > S.job.seq)
          and (msg.id == nil or msg.id == LANE) then
        S.open = as_set(msg.open)
        S.job = job_from(msg)
        -- a "done" still waiting for our slot would get us this again
        if status_pending then status_pending.chunk_done = nil end
        return true
      end
    end
  end
end

-- Lane 0 at a ring change: wait until everyone has left the finished ring.
local function wait_clear(seq)
  say(nil, "waiting for the others to leave the ring")
  local last_asked = os.clock()
  while true do
    -- now and then, ask again (the answer can get lost in a restart)
    local left = 60 - (os.clock() - last_asked)
    if left <= 0.05 then
      tell("arrived", { seq = seq })
      last_asked, left = os.clock(), 60
    end
    local sender, msg = net_receive(PROTOCOL, left)
    if sender == S.controller and type(msg) == "table" then
      if msg.cmd == "clear" and msg.seq == seq then return true end
      if msg.cmd == "stop" or msg.cmd == "recall" then
        if type(msg.open) == "table" then S.open = as_set(msg.open) end
        return false
      end
    end
  end
end

-- At a ring change: we're out of the finished ring (lane 0 is waiting to
-- take its loaders back).
local function report_arrival()
  local job = S.job
  if job.report_arrival == nil and job.l0 and job.l0.wait_clear and LANE ~= 0 then
    tell("arrived", { seq = job.seq })
    job.report_arrival = true
    save()
  end
end

local function to_chunk()
  local job = S.job
  -- lane 0: take the finished ring's loaders back, put in the new ones
  if LANE == 0 and job.l0 and not job.l0_done then
    local l0 = job.l0
    if l0.collect and #l0.collect > 0 then
      if not job.cleared then
        if not wait_clear(job.seq) then S.stopped = true save() return end
        job.cleared = true
        save()
      end
      -- (S.collecting is this job's: a new job clears it)
      if not S.collecting then
        say("Picking up the loaders of the finished ring.", "collecting loaders")
        collect_all(l0.collect, l0.collect_open)
      elseif not S.collecting.done then
        collect_all() -- (restarted while picking them up)
      end
    end
    for i, t in ipairs(l0.place or {}) do
      if i > (job.placed or 0) then
        local open = as_set(l0.place_open)
        place_loader(t, open)
        job.placed = i
        save()
      end
    end
    job.l0_done = true
    save()
  end
  if job.approach then
    local ap = job.approach
    ensure_fuel_for(ap.e, ap.n)
    if S.stopped then return end
    say(nil, "to chunk " .. ckey(job.a, job.b))
    local topen = (LANE == 0 and job.l0) and as_set(job.l0.place_open) or as_set(job.travel_open)
    travel_to(ap.e, ap.n, 0, ap.dir, topen)
    report_arrival()
  end
  S.pass = nil
  S.phase = "mining"
  save()
  enter_lane()
end

local wait_to_collect -- (below)

local function go_home()
  S.phase = "going_home"
  save()
  say(nil, "going home") -- (the control computer stops re-sending "stop")
  if S.in_lane or cell_index() then leave_lane() end
  travel_to(LANE, 0, 0, 0)
  if LANE == 0 then
    if S.collecting and S.collecting.final then -- (restarted while picking them up)
      travel_to(LANE, 0, 0, 0, collect_all())
    else
      local list, open = wait_to_collect()
      if list and #list > 0 then
        say("Picking up the chunk loaders.", "collecting loaders")
        travel_to(LANE, 0, 0, 0, collect_all(list, open, true))
      end
    end
  end
  say(nil, "home, unloading")
  if has_cargo() then request_service("home, unloading") end
  -- (kept: if a server crash undoes the end of the run, we finish it again)
  save()
  local h = fs.open(DONE_FILE, "w")
  h.write(textutils.serialize(S))
  h.close()
  clear_state()
  say("Finished, back at the start.", "finished")
end

-- End of the run, lane 0 at home: once everyone else is home the control
-- computer sends the list of loaders to take back (newest first).
function wait_to_collect()
  say("Waiting for everyone else to get home, then picking up the loaders.",
    "waiting to collect loaders")
  local last_sent = -math.huge
  while true do
    if last_sent + 30 - os.clock() <= 0 then -- (same sum as the wait below)
      tell("may_collect", true)
      last_sent = os.clock()
    end
    local sender, msg = net_receive(PROTOCOL, last_sent + 30 - os.clock())
    if sender == S.controller and type(msg) == "table"
        and msg.cmd == "collect" and msg.id == LANE then
      return msg.list or {}, msg.open or {}
    end
  end
end

local function run()
  while true do
    if S.redo_loaders then redo_loaders() end
    if S.stopped then return go_home() end
    if S.phase == "wait_next" then
      if not wait_for_next() then
        S.stopped = true
      else
        S.phase = "to_chunk"
        S.job.l0_done = nil
        S.collecting = nil
      end
      save()
    elseif S.phase == "to_chunk" then
      to_chunk()
    elseif S.phase == "mining" then
      if not S.in_lane or not cell_index() then
        -- (after a restart on the way in or out)
        S.in_lane = false
        if S.job.approach then
          local ap = S.job.approach
          travel_to(ap.e, ap.n, 0, ap.dir)
          report_arrival()
        end
        enter_lane()
      end
      if mine_lane() then
        -- lane 0: the chunk's loader is right above our first cell, so we
        -- step back out: nothing may ever go up through that column
        if LANE == 0 and S.job.approach then leave_lane() end
        S.in_lane = false -- (our lane is done: just a place to wait now)
        S.phase = "wait_next"
        say(nil, "chunk " .. ckey(S.job.a, S.job.b) .. " done, waiting")
        save()
      end
    else
      return go_home()
    end
  end
end
