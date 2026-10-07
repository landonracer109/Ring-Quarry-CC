-- Builds the ring miner from the straight-line miner (unchanged parts, by
-- marker) plus the new parts. Run from ringsim/parts.
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s end
local old = read("orig_TurtleTest1") -- (the straight-line miner, R0)
local function slice(from, to)
  local i = assert(old:find(from, 1, true), "no " .. from)
  local j = to and assert(old:find(to, i, true), "no " .. to) or (#old + 1)
  return old:sub(i, j - 1)
end

local parts = {
  read("n0_header.lua"),
  "\n",
  slice("local args = { ... }", "-- Network ---"),
  slice("-- Network ---", "-- Run state ---"),
  read("n1_core.lua"),
  "\n",
  slice("-- Inventory ---", "-- Service turtle ---"),
  read("n2_work.lua"),
  slice("-- Waits for the control computer's", "-- Keeps telling the dashboard"),
  read("n3_start.lua"),
  "\n",
  slice("-- Uploads text to a paste site", "local function main()"),
  [[
local function main()
  while start_run() do
    run()
    if S then return end -- (ended away from the start spot)
  end
end
-- (the listener goes first, so a message is filed before main looks)
parallel.waitForAny(listener, main, status_sender, uploader)
]],
}
local s = table.concat(parts)

local function rep(a, b)
  local i, j = s:find(a, 1, true); assert(i, "rep: " .. a:sub(1, 60))
  assert(not s:find(a, j + 1, true), "twice: " .. a:sub(1, 60))
  s = s:sub(1, i - 1) .. b .. s:sub(j + 1)
end
-- "here": no journal any more
rep([[  fs.delete(".quarry_away") -- left over from older versions
  fs.delete(".quarry_log_a")
  fs.delete(".quarry_log_b")
]], "")
-- what the dashboard gets with our status
rep([[    hello = p.hello, chunk_done = p.chunk_done, may_collect = p.may_collect }]],
    [[    hello = p.hello, chunk_done = p.chunk_done, may_collect = p.may_collect,
    arrived = p.arrived }]])
rep([[    msg.info = { chunk = S.chunk, pass = S.pass, y = S.y, fuel = turtle.getFuelLevel(),
      depth = S.depth, trash = S.trash and true or false }]],
[[    msg.info = { chunk = S.job and (S.job.a .. "," .. S.job.b) or "-",
      ring = S.job and S.job.ring, idx = S.job and S.job.idx, count = S.job and S.job.count,
      pass = S.pass, e = S.e, y = S.y, n = S.n, fuel = turtle.getFuelLevel(),
      depth = S.depth, trash = S.trash and true or false }]])
rep([[os.pullEvent("status_pending") end    local w = world_seconds()]],
    "os.pullEvent(\"status_pending\") end\n    local w = world_seconds()")
-- the trash can: remember where it last went (a server crash can put it back there)
rep([[  S.trash_out = dir
  save()
  turtle.select(TRASH_SLOT)]], [[  S.trash_out, S.trash_last = dir, dir
  save()
  turtle.select(TRASH_SLOT)]])
rep([[  S.trash_out = nil
  S.trash_free = nil
  save()
end]], [[  S.trash_out = nil
  S.trash_free_last, S.trash_free = S.trash_free, nil -- (see start_run)
  save()
end]])
rep([[local VERSION = "R0"]], [[local VERSION = "R5"]])
-- burn fuel as soon as one piece of coal fits: a 1000 cut-off left a
-- handed-over coal block in a cargo slot on about 1 fill-up in 4, and
-- mined coal waited in a slot. Coal blocks only ever come from the service
-- turtle, which hands over exactly what fits, and we burn our mined coal
-- before we ask it (so the fuel we report is right): a block never meets
-- a nearly full tank.
rep([[    -- room for any fuel item (a coal block is 800, lava 1000): burning one
    -- into a nearly full tank would waste most of it
    if fuel_limit() - fuel_level() < 1000 then break end]], [[    -- room for one piece of coal (80). A coal block only ever comes from
    -- the service turtle, which hands over just what fits.
    if fuel_limit() - fuel_level() < 80 then break end]])

-- our own log: where we are
rep([[  local where = S and string.format("c%s p%s y%s z%s f%s", tostring(S.chunk), tostring(S.pass),
    tostring(S.y), tostring(S.z), tostring(turtle.getFuelLevel())) or "idle"]],
[[  local where = S and string.format("c%s p%s e%s y%s n%s f%s", S.job and (S.job.a .. "," .. S.job.b) or "-",
    tostring(S.pass), tostring(S.e), tostring(S.y), tostring(S.n), tostring(turtle.getFuelLevel())) or "idle"]])

local f = assert(io.open("../../TurtleTest1", "wb"))
f:write(s)
f:close()
print("assembled " .. #s .. " bytes")
