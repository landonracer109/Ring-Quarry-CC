-- Second stage of patch_control.lua (run by it): ring-change fixes.
local P = dofile(LIB)("../../ControlCPU")
P.rep([==[    if tonumber(msg.seq) == current_chunk then
      arrived[lane] = true
      local all = true]==], [==[    if tonumber(msg.seq) == current_chunk then
      -- (lane 0 sends it too, now and then, while it waits: we answer again)
      if lane ~= 0 then arrived[lane] = true end
      local all = true]==])
-- a lane that is in the new chunk is out of the old ring, even if its
-- "arrived" got lost (we restarted)
P.rep([==[        m.trash = info.trash]==], [==[        m.trash = info.trash
        local c = plan[current_chunk]
        if msg.id ~= 0 and c and type(info.e) == "number" and type(info.n) == "number"
            and math.floor(info.e / CHUNK_SIZE) == c.a
            and math.floor(info.n / CHUNK_SIZE) + 1 == c.b
            and last_next and type(last_next.l0) == "table" and last_next.l0.wait_clear
            and not arrived[msg.id] then
          handle(sender, { cmd = "arrived", id = msg.id, seq = current_chunk })
        end]==])
P.rep([[local VERSION = "R0"]], [[local VERSION = "R5"]])
-- the map: as big as fits beside the service panel and log, centered
-- up and down, in colored blocks (1 character per chunk when it's tight)
P.rep([[  local mapw = (2 * chunks + 1) * 2 + 1
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
  end]], [[  local cur = plan[current_chunk]
  local map_top -- (set below the lane table)
  local geo -- the map's size and place (worked out once map_top is known)
  local function map_geo()
    local n = 2 * chunks + 1
    local rows = h - map_top + 1
    local room = w - 58 -- (the service panel's text needs the rest)
    local color = t.isColor and t.isColor()
    -- big: each chunk a block of py-1 rows (plus a gap row), about square
    -- (a character is about 1.5 times taller than wide)
    for py = math.floor(rows / n), 2, -1 do
      local cw = math.max(2, math.floor(1.5 * (py - 1) + 0.5))
      if color and n * (cw + 1) + 1 <= room then
        return { n = n, py = py, cw = cw, top = map_top + math.floor((rows - n * py) / 2) }
      end
    end
    -- small: one character per chunk
    if rows >= n and w - (2 * n + 1) >= 30 then
      return { n = n, py = 1, top = map_top + math.floor((rows - n) / 2) }
    end
    return false
  end
  local function chunk_look(a, b)
    if a == 0 and b == 0 then return "C", colors.white, colors.blue end
    if cur and cur.a == a and cur.b == b and started then return "@", colors.black, colors.yellow end
    if mined[ckey(a, b)] then return "#", colors.white, colors.green end
    return ".", colors.white, colors.gray
  end
  -- the map's pieces for screen row yy, or nil
  local function map_at(yy)
    if not map_top then return nil end
    if geo == nil then geo = map_geo() end
    if not geo then return nil end
    local r = yy - geo.top
    if r < 0 or r >= geo.n * geo.py then return nil end
    local b = chunks - math.floor(r / geo.py)
    if geo.py == 1 then
      local text = " "
      for a = -chunks, chunks do text = text .. (chunk_look(a, b)) .. " " end
      return { { text, colors.lightBlue } }
    end
    local sub = r % geo.py
    local width = geo.n * (geo.cw + 1) + 1
    if sub == geo.py - 1 then return { { string.rep(" ", width) } } end -- (gap)
    local mid = math.floor((geo.py - 2) / 2)
    local pieces = { { " " } }
    for a = -chunks, chunks do
      local ch, fg, bg = chunk_look(a, b)
      local label = string.rep(" ", geo.cw)
      if sub == mid and (ch == "C" or ch == "@") then
        local left = math.floor((geo.cw - 1) / 2)
        label = string.rep(" ", left) .. ch .. string.rep(" ", geo.cw - left - 1)
      end
      pieces[#pieces + 1] = { label, fg, bg }
      pieces[#pieces + 1] = { " " }
    end
    return pieces
  end]])
-- a lane's version shows as soon as it registers (not only once a run starts)
P.rep([[      miners[lane].status = "registered"
      miners[lane].seen = os.clock()]], [[      miners[lane].status = "registered"
      miners[lane].seen = os.clock()
      miners[lane].ver = msg.ver or miners[lane].ver]])
-- before any chunk has started, nothing is done yet
P.rep([[  if all_home or (done[lane] or 0) >= current_chunk then return 1 end]],
    [[  if current_chunk == 0 and not all_home then return 0 end
  if all_home or (done[lane] or 0) >= current_chunk then return 1 end]])
P.done()
