
-- Something we can't sort out on our own: keep telling the dashboard
-- (RECALL won't help either: someone has to come).
function lost(reason)
  print("Stuck: " .. reason)
  print("Put me on my start spot, facing the tunnel, and run:")
  print("  " .. PROGRAM .. " " .. LANE .. " here")
  while true do
    say(reason, "LOST - move to start")
    sleep(60)
  end
end

-- Starts a run: resumes the one saved on disk (after a restart) or waits
-- for the control computer to start a new one.
local function start_run()
  S = load_state()
  if not S and fs.exists(DONE_FILE) then
    -- a finished run: did a server crash take the world back to before
    -- we got home (and lane 0 took the loaders back)?
    local h = fs.open(DONE_FILE, "r")
    local ok, t = pcall(textutils.unserialize, h.readAll())
    h.close()
    local e, y, n = gps_here()
    local moved = ok and type(t) == "table" and e and (e ~= t.e or y ~= t.y or n ~= t.n)
    if ok and type(t) == "table" and type(t.wt) == "number"
        and (world_seconds() < t.wt - 3 or moved) then
      debug("Server crash undid the end of the run: finishing it again")
      fs.delete(DONE_FILE)
      S = t
      S.phase, S.stopped = "going_home", true
    end
  end
  if S then
    save_seq = S.seq
    -- A server CRASH: the in-game clock went back with the world...
    local crashed = type(S.wt) == "number" and world_seconds() < S.wt - 3
    -- the last move: did it happen? (every move costs 1 fuel)
    local now_fuel = turtle.getFuelLevel()
    if S.pending and type(now_fuel) == "number" and type(S.fuel) == "number"
        and now_fuel == S.fuel - 1 then
      apply_move(S.pending)
    end
    S.pending = nil
    -- GPS (if there is one) has the last word on where we are
    local e, y, n = gps_here()
    if e and (e ~= S.e or y ~= S.y or n ~= S.n) then
      debug("GPS puts me at " .. e .. " " .. y .. " " .. n .. ", my notes said "
        .. S.e .. " " .. S.y .. " " .. S.n)
      S.e, S.y, S.n = e, y, n
      crashed = true -- (...or we're not where we left ourselves)
    end
    -- a crash can have undone some of our digging: go over our lane again
    -- from the top (the parts that are still mined go quickly)
    if crashed and S.phase == "mining" and S.pass then
      debug("Server crash: going over my lane again from the top")
      S.pass = 1
    end
    if crashed and LANE == 0 then S.redo_loaders = true end
    -- (at a ring change: our "I'm out of the old ring" may not have gone
    -- out before the restart; the control computer ignores a repeat)
    if LANE ~= 0 and S.job and S.job.report_arrival then
      if crashed then
        S.job.report_arrival = nil -- (the crash may have put us back in it)
      else
        tell("arrived", { seq = S.job.seq })
      end
    end
    -- A turn costs no fuel, so our notes can't tell whether one happened:
    -- after a restart mid-turn, or a crash (which can undo turns, and
    -- isn't always noticed), look. (With GPS: after every restart.)
    if S.turning or crashed or e then
      -- (no GPS: we can't tell; next to a protected spot: our first step shows it)
      if not find_facing() and S.turning and not S.check_facing then
        lost("Restarted in the middle of a turn and couldn't work out which way I face (GPS needed).")
      end
      S.turning = nil
    end
    -- our trash can went out and came back in, but a crash put the world
    -- back to when it was out: we're where we were then, so it's there
    if S.trash and not S.trash_out and S.trash_last and turtle.getItemCount(TRASH_SLOT) == 0 then
      debug("My trash can isn't in slot " .. TRASH_SLOT .. ": getting it back (" .. S.trash_last .. ")")
      -- (it may be in the slot it landed in when we dug it)
      S.trash_out, S.trash_free = S.trash_last, S.trash_free_last
    end
    save()
    if S.trash_out then pick_up_trash() end
    say("Restarted: carrying on (" .. tostring(S.phase) .. ").", "resuming")
    return true
  end

  calibrate() -- (at home: where GPS says our start spot is)
  local controller, msg = register_and_wait()
  -- samples in 12-14 and a trash can in 15: throw junk away
  local trash = true
  for i = SAMPLE_SLOTS[1], TRASH_SLOT do
    if turtle.getItemCount(i) == 0 then trash = false end
  end
  if not trash then
    say("No trash can (slot 15) or samples (slots 12-14): keeping everything.")
  end
  S = {
    controller = controller, trash = trash, samples = trash,
    e = LANE, y = 0, n = 0, f = 0, phase = "wait_next",
    loaders = (LANE == 0) and turtle.getItemCount(LOADER_SLOT) or 0,
    open = { [ckey(0, 1)] = true },
  }
  save_seq = 0
  save()
  fs.delete(DONE_FILE) -- (a new run: the last one is over for good)
  print("Started.")
  return true
end
