-- ============================================================
--  SPACE JUKEBOX REMOTE  -  second screen for CC: Tweaked
--  Playlists + music controls (talks to the jukebox computer over
--  modems), real Mountain Time clock, Minecraft sky + clock + day
--  counter, and a spinning 3D shape (tap it to change shape).
-- ============================================================

local REPO = "https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-Music/main/"
local PROTO = "spacejukebox"

local CFG = {
  textScale = 0.5,
  frame     = 0.1,
}

-- ---------------------------------------------------------- monitor (must touch this computer)
local mon, monName
for _, side in ipairs(redstone.getSides()) do
  if peripheral.getType(side) == "monitor" then
    mon, monName = peripheral.wrap(side), side
    break
  end
end
if not mon then
  error("No monitor touching this computer. Place the remote's monitor directly against it (not on the cable network).", 0)
end
if not mon.isColour() then error("The remote monitor must be an ADVANCED monitor (gold border).", 0) end

local netOn = false
local function openNet()
  netOn = false
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if pcall(rednet.open, name) then netOn = true end
    end
  end
end
openNet()

-- ---------------------------------------------------------- palette
local PAL = {
  [colors.black]     = 0x05060f,
  [colors.brown]     = 0x15162e, -- panel
  [colors.blue]      = 0x2c2f72, -- highlight row
  [colors.gray]      = 0x4a4e66,
  [colors.lightGray] = 0x9ea3c2,
  [colors.lightBlue] = 0x38c6ff,
  [colors.cyan]      = 0x7fc8ff, -- day sky
  [colors.purple]    = 0x0e1a4a, -- night sky
  [colors.orange]    = 0xff8a3d, -- sunrise / sunset
  [colors.pink]      = 0xd8649a, -- dusk
  [colors.green]     = 0x3f9b2f, -- grass
  [colors.yellow]    = 0xffd23f,
  [colors.red]       = 0xff3b3b,
  [colors.magenta]   = 0xff4fa3,
  [colors.lime]      = 0x9b5cff, -- purple accent (lime slot reused)
}
for c, v in pairs(PAL) do mon.setPaletteColour(c, v) end

local WHITE, ORANGE, MAGENTA, LBLUE, YELLOW, ACCENT, PINK, GRAY, LGRAY = "0", "1", "2", "3", "4", "5", "6", "7", "8"
local DAYSKY, NIGHTSKY, HILITE, PANEL, GRASS, RED, BLACK = "9", "a", "b", "c", "d", "e", "f"

local G_RIGHT, G_LEFT, G_UP, G_DOWN, G_DOT, G_HLINE, G_VLINE = "\16", "\17", "\30", "\31", "\7", "\140", "\149"

-- ---------------------------------------------------------- helpers
local function now() return os.epoch("utc") / 1000 end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function fmtTime(sec)
  sec = math.max(0, math.floor(sec))
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end
local function clean(s)
  s = tostring(s or "")
  s = s:gsub("\226\128[\152\153]", "'"):gsub("\226\128[\156\157]", '"')
  return (s:gsub("[\192-\255][\128-\191]*", "?"))
end
local function shuffled(n)
  local t = {}
  for i = 1, n do t[i] = i end
  for i = n, 2, -1 do local j = math.random(1, i); t[i], t[j] = t[j], t[i] end
  return t
end

-- ---------------------------------------------------------- framebuffer
local W, H = 0, 0
local fbC, fbF, fbB, lastRow = {}, {}, {}, {}
local function fbClear()
  for y = 1, H do
    local c, f, b = fbC[y], fbF[y], fbB[y]
    for x = 1, W do c[x] = " "; f[x] = WHITE; b[x] = BLACK end
  end
end
local function setCell(x, y, ch, fg, bg)
  if x < 1 or x > W or y < 1 or y > H then return end
  fbC[y][x] = ch
  if fg then fbF[y][x] = fg end
  if bg then fbB[y][x] = bg end
end
local function text(x, y, s, fg, bg) for i = 1, #s do setCell(x + i - 1, y, s:sub(i, i), fg, bg) end end
local function fill(x1, y1, x2, y2, bg) for y = y1, y2 do for x = x1, x2 do setCell(x, y, " ", WHITE, bg) end end end
local function present()
  for y = 1, H do
    local c, f, b = table.concat(fbC[y]), table.concat(fbF[y]), table.concat(fbB[y])
    local key = c .. f .. b
    if lastRow[y] ~= key then mon.setCursorPos(1, y); mon.blit(c, f, b); lastRow[y] = key end
  end
end

-- thin border drawn with teletext glyphs
local function thinBox(x1, y1, x2, y2, col)
  setCell(x1, y1, "\159", BLACK, col); setCell(x2, y1, "\144", col, BLACK)
  setCell(x2, y2, "\129", col, BLACK); setCell(x1, y2, "\130", col, BLACK)
  for x = x1 + 1, x2 - 1 do setCell(x, y1, "\143", BLACK, col); setCell(x, y2, "\131", col, BLACK) end
  for y = y1 + 1, y2 - 1 do setCell(x1, y, "\149", BLACK, col); setCell(x2, y, "\149", col, BLACK) end
end

-- ---------------------------------------------------------- layout
local L = {}
local function computeLayout()
  mon.setTextScale(CFG.textScale)
  W, H = mon.getSize()
  fbC, fbF, fbB, lastRow = {}, {}, {}, {}
  for y = 1, H do fbC[y], fbF[y], fbB[y] = {}, {}, {} end
  mon.setBackgroundColour(colors.black); mon.clear()

  L.lw = math.max(16, math.floor(W * 0.34))          -- yellow playlist panel
  L.sep = L.lw + 1
  L.rx1, L.rx2 = L.lw + 3, W - 1                       -- right area
  L.rw = L.rx2 - L.rx1 + 1
  L.topH = math.max(6, math.floor(H / 3))              -- white + red boxes
  L.wx1, L.wx2 = L.rx1, L.rx1 + math.floor(L.rw * 0.33) - 1   -- white (3D)
  L.cx1, L.cx2 = L.wx2 + 2, L.rx2                              -- red (clock)
  L.by2 = H - 1; L.by1 = L.by2 - 2                     -- green controls
  L.npy = L.by1 - 2                                    -- now playing row
  L.pgy = L.by1 - 1                                    -- progress row
  L.my1 = L.topH + 1; L.my2 = L.npy - 2                -- pink MC box
  L.sky1, L.sky2 = L.my1 + 1, L.my2 - 2                -- light blue sky
  L.mdy = L.my2 - 1                                    -- purple digital row
  L.hy2 = 3; L.ly1 = 5; L.fy1 = H - 2; L.ly2 = L.fy1 - 2
  L.rows = L.ly2 - L.ly1 + 1
end

-- ---------------------------------------------------------- playlists (same file the jukebox reads)
local lists
local function loadPlaylists()
  local h, err = http.get(REPO .. "playlists.json?t=" .. os.epoch("utc"))
  if not h then return nil, err end
  local txt = h.readAll(); h.close()
  local ok, data = pcall(textutils.unserializeJSON, txt)
  if not ok or type(data) ~= "table" then return nil, "bad playlists.json" end
  local list = {}
  for name, songs in pairs(data) do
    local out = {}
    for _, s in ipairs(songs) do
      local title, artist = s.title or s.file, s.artist
      if not artist then
        local a, b = title:match("^(.*) %- (.-)$")
        if a then title, artist = a, b else artist = "" end
      end
      out[#out + 1] = { title = clean(title), artist = clean(artist) }
    end
    if #out > 0 then list[#list + 1] = { name = clean(name), songs = out } end
  end
  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
  return list
end

-- ---------------------------------------------------------- jukebox link
local J = { st = nil, at = 0, id = nil }
local function online() return J.st ~= nil and now() - J.at < 4 end
local function send(msg)
  if not netOn then return end
  if J.id then pcall(rednet.send, J.id, msg, PROTO) else pcall(rednet.broadcast, msg, PROTO) end
end
local function jPos()
  local st = J.st
  if not st or not st.title then return 0, 0 end
  local p = st.pos or 0
  if not st.paused and not st.loading then p = p + (now() - J.at) end
  return math.min(p, st.dur or 0), st.dur or 0
end

local UI = { view = "playlists", viewPl = nil, viewOrder = nil, lastPl = nil, scroll = 0, plScroll = 0, queueMode = false }
local hits, flash = {}, {}
local function hit(id, x1, y1, x2, y2, fn) hits[#hits + 1] = { id = id, x1 = x1, y1 = y1, x2 = x2, y2 = y2, fn = fn } end
local function flashing(id) return flash[id] and now() - flash[id] < 0.15 end
local function button(id, x1, y1, x2, y2, label, fg, bg, fn, enabled)
  if enabled == false then fg, bg = GRAY, PANEL end
  if flashing(id) then fg, bg = BLACK, WHITE end
  fill(x1, y1, x2, y2, bg)
  if #label > x2 - x1 + 1 then label = label:sub(1, x2 - x1 + 1) end
  text(x1 + math.floor((x2 - x1 + 1 - #label) / 2), math.floor((y1 + y2) / 2), label, fg, bg)
  if enabled ~= false then hit(id, x1, y1, x2, y2, fn) end
end

local function playingOrder(p)
  local st = J.st
  if online() and st.pl == p and type(st.queue) == "table" then return st.queue end
end

local function openPlaylist(p)
  UI.viewPl, UI.lastPl, UI.view, UI.scroll = p, p, "songs", 0
  local live = playingOrder(p)
  if live then
    UI.viewOrder = nil
    UI.scroll = clamp((J.st.qi or 1) - 3, 0, math.max(0, #live - L.rows))
  else
    UI.viewOrder = shuffled(#lists[p].songs)
    if online() and not J.st.title then send({ cmd = "play", pl = p, order = UI.viewOrder, idx = 1 }) end
  end
end

-- ---------------------------------------------------------- yellow: playlists
local function queuePos(p, si)
  local st = J.st
  if not online() or type(st.upNext) ~= "table" then return nil end
  for i, e in ipairs(st.upNext) do if e.pl == p and e.si == si then return i end end
end

local function drawLeft()
  local lw = L.lw
  local inSongs = UI.view == "songs"
  fill(1, 1, lw, L.hy2, PANEL)
  button("back", 1, 1, 4, L.hy2, G_LEFT, YELLOW, inSongs and GRAY or PANEL, function() UI.view = "playlists" end, inSongs)
  button("fwd", lw - 3, 1, lw, L.hy2, G_RIGHT, YELLOW, GRAY, function() if UI.lastPl then openPlaylist(UI.lastPl) end end,
    (not inSongs) and UI.lastPl ~= nil)
  local title = inSongs and lists[UI.viewPl].name:upper() or "PLAYLISTS"
  local tw = lw - 9
  if #title > tw then title = title:sub(1, tw - 1) .. "." end
  text(5 + math.floor((tw + 1 - #title) / 2), 2, title, YELLOW, PANEL)
  for x = 1, lw do setCell(x, 4, G_HLINE, YELLOW, BLACK) end

  local st = online() and J.st or nil
  local total, scroll, per
  if inSongs then
    local order = playingOrder(UI.viewPl) or UI.viewOrder
    if not order then UI.viewOrder = shuffled(#lists[UI.viewPl].songs); order = UI.viewOrder end
    local pl = lists[UI.viewPl]
    total, per = #order, L.rows
    UI.scroll = clamp(UI.scroll, 0, math.max(0, total - per))
    scroll = UI.scroll
    for r = 1, per do
      local idx = scroll + r
      if idx > total then break end
      local y = L.ly1 + r - 1
      local si = order[idx]
      local song = pl.songs[si]
      if song then
        local cur = st and st.curPl == UI.viewPl and st.curSi == si
        local qp = queuePos(UI.viewPl, si)
        if cur then fill(1, y, lw, y, HILITE) end
        local bg = cur and HILITE or nil
        text(1, y, cur and G_RIGHT or " ", YELLOW, bg)
        if qp then text(2, y, string.format("%3s ", "Q" .. qp), LBLUE, bg)
        else text(2, y, string.format("%3d ", idx), cur and YELLOW or GRAY, bg) end
        local room = lw - 5
        local t1 = song.title
        if #t1 > room then t1 = t1:sub(1, room - 1) .. "." end
        text(6, y, t1, WHITE, bg)
        local p = UI.viewPl
        hit("song:" .. idx, 1, y, lw, y, function()
          if UI.queueMode and st and st.title then send({ cmd = "queue", pl = p, si = si })
          else send({ cmd = "play", pl = p, order = order, idx = idx }) end
        end)
      end
    end
  else
    total = #lists
    per = math.max(1, math.floor(L.rows / 3))
    UI.plScroll = clamp(UI.plScroll, 0, math.max(0, total - per))
    scroll = UI.plScroll
    for r = 1, per do
      local i = scroll + r
      if i > total then break end
      local y = L.ly1 + (r - 1) * 3
      local pl = lists[i]
      local cur = st and st.pl == i and st.title
      local bg = cur and HILITE or PANEL
      fill(1, y, lw, y + 1, bg)
      local name = pl.name
      if #name > lw - 3 then name = name:sub(1, lw - 4) .. "." end
      text(1, y, (cur and G_RIGHT or " ") .. " " .. name, cur and YELLOW or WHITE, bg)
      text(3, y + 1, #pl.songs .. " songs" .. (cur and " " .. G_DOT .. " on" or ""), LGRAY, bg)
      hit("pl:" .. i, 1, y, lw, y + 1, function() openPlaylist(i) end)
    end
  end
  local first, last = math.min(total, scroll + 1), math.min(total, scroll + per)
  local info, icol = first .. "-" .. last .. " of " .. total, GRAY
  if UI.queueMode then info, icol = "tap to queue", LBLUE end
  text(math.floor((lw - #info) / 2) + 1, L.ly2 + 1, info, icol)
  local page = math.max(1, per - 2)
  local function scrollBy(d) if inSongs then UI.scroll = UI.scroll + d else UI.plScroll = UI.plScroll + d end end
  local bw = math.floor((lw - 2) / 4)
  local nq = st and type(st.upNext) == "table" and #st.upNext or 0
  button("up", 1, L.fy1, bw, H, G_UP, YELLOW, GRAY, function() scrollBy(-page) end, scroll > 0)
  button("queue", bw + 2, L.fy1, lw - bw - 1, H, (UI.queueMode and "Q ON" or "QUEUE") .. (nq > 0 and " " .. nq or ""),
    UI.queueMode and BLACK or LBLUE, UI.queueMode and LBLUE or GRAY, function() UI.queueMode = not UI.queueMode end)
  button("down", lw - bw + 1, L.fy1, lw, H, G_DOWN, YELLOW, GRAY, function() scrollBy(page) end, scroll + per < total)
end

-- ---------------------------------------------------------- white: spinning 3D shape
-- Teletext sub-pixel canvas: each cell is 2x3 square "pixels".
-- pix[k] = depth (smaller = closer); colourOf(depth) picks the cell colour.
local function blitCanvas(x1, y1, cw, ch, pix, colourOf, bg)
  local pw = cw * 2
  for cyy = 0, ch - 1 do
    for cxx = 0, cw - 1 do
      local bits, zmin = 0, math.huge
      for sub = 0, 5 do
        local z = pix[(cyy * 3 + math.floor(sub / 2)) * pw + cxx * 2 + sub % 2]
        if z then bits = bits + 2 ^ sub; if z < zmin then zmin = z end end
      end
      if bits > 0 then
        local col = colourOf(zmin)
        if bits >= 32 then setCell(x1 + cxx, y1 + cyy, string.char(128 + (63 - bits)), bg, col)
        else setCell(x1 + cxx, y1 + cyy, string.char(128 + bits), col, bg) end
      end
    end
  end
end

-- Every shape is a cloud of NP points; morphing moves point i of one shape to point i of the next.
local NP = 180
local PHI = (1 + math.sqrt(5)) / 2
local SHAPES = {}

local function norm(pts)
  local r = 0
  for _, v in ipairs(pts) do r = math.max(r, math.sqrt(v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2)) end
  for _, v in ipairs(pts) do v[1], v[2], v[3] = v[1] / r, v[2] / r, v[3] / r end
  -- sort around the vertical axis so the warp swirls instead of scrambling
  table.sort(pts, function(a, b) return math.atan2(a[3], a[1]) + a[2] * 0.01 < math.atan2(b[3], b[1]) + b[2] * 0.01 end)
  return pts
end

local function edgeShape(name, verts)
  local best, edges = math.huge, {}
  local function d2(a, b) return (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2 end
  for i = 1, #verts do for j = i + 1, #verts do best = math.min(best, d2(verts[i], verts[j])) end end
  for i = 1, #verts do for j = i + 1, #verts do
    if math.abs(d2(verts[i], verts[j]) - best) < 1e-6 then edges[#edges + 1] = { verts[i], verts[j] } end
  end end
  local pts, per = {}, NP / #edges
  for n = 0, NP - 1 do
    local e = edges[math.floor(n / per) + 1]
    local f = (n % per) / per + 0.5 / per
    local a, b = e[1], e[2]
    pts[#pts + 1] = { a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f }
  end
  SHAPES[#SHAPES + 1] = { name = name, p = norm(pts) }
end

local function curveShape(name, fn)
  local pts = {}
  for n = 0, NP - 1 do pts[#pts + 1] = fn(n) end
  SHAPES[#SHAPES + 1] = { name = name, p = norm(pts) }
end

do
  local cube = {}
  for x = -1, 1, 2 do for y = -1, 1, 2 do for z = -1, 1, 2 do cube[#cube + 1] = { x, y, z } end end end
  edgeShape("CUBE", cube)
  edgeShape("OCTAHEDRON", { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } })
  curveShape("TORUS", function(n)                 -- 12 rings of 15 points
    local ring, k = math.floor(n / 15), n % 15
    local u, v = ring / 12 * 2 * math.pi, k / 15 * 2 * math.pi
    local R, r = 0.68, 0.32
    return { (R + r * math.cos(v)) * math.cos(u), r * math.sin(v), (R + r * math.cos(v)) * math.sin(u) }
  end)
  local ico = {}
  for _, a in ipairs({ -1, 1 }) do for _, b in ipairs({ -PHI, PHI }) do
    ico[#ico + 1] = { 0, a, b }; ico[#ico + 1] = { a, b, 0 }; ico[#ico + 1] = { b, 0, a }
  end end
  edgeShape("ICOSAHEDRON", ico)
  curveShape("GYROSCOPE", function(n)             -- three rings at right angles
    local ring, a = math.floor(n / 60), (n % 60) / 60 * 2 * math.pi
    local c, s = math.cos(a), math.sin(a)
    if ring == 0 then return { c, s, 0 } elseif ring == 1 then return { c, 0, s } else return { 0, c, s } end
  end)
  edgeShape("PYRAMID", { { 1, 1, 1 }, { 1, -1, -1 }, { -1, 1, -1 }, { -1, -1, 1 } })
end

local HOLD, MORPH = 5, 1.6
local morph = { from = 1, to = 1, start = -100, nextAt = 0 }
local function startMorph(t)
  morph.from = morph.to
  morph.to = morph.to % #SHAPES + 1
  morph.start, morph.nextAt = t, t + MORPH + HOLD
end

local function draw3D(t)
  local x1, y1, x2, y2 = L.wx1, 1, L.wx2, L.topH
  local cw, ch = x2 - x1 + 1, y2 - y1 + 1
  local pw, ph = cw * 2, ch * 3
  if morph.nextAt == 0 then morph.nextAt = t + HOLD end
  if t >= morph.nextAt then startMorph(t) end
  local f = clamp((t - morph.start) / MORPH, 0, 1)
  local e = f * f * (3 - 2 * f)                                -- ease in/out
  local warping = f > 0 and f < 1
  local A, B = SHAPES[morph.from].p, SHAPES[morph.to].p
  local spin = t + (warping and math.sin(f * math.pi) * 1.2 or 0)   -- spins faster mid-warp
  local ax, ay = spin * 0.9, spin * 1.3
  local cx, sx, cy, sy = math.cos(ax), math.sin(ax), math.cos(ay), math.sin(ay)
  local scale = math.min(pw, ph) * 0.42 * 3.2 * (1 + 0.18 * math.sin(f * math.pi))
  local pix = {}
  for i = 1, NP do
    local a, b = A[i], B[i]
    local x = a[1] + (b[1] - a[1]) * e
    local y = a[2] + (b[2] - a[2]) * e
    local z = a[3] + (b[3] - a[3]) * e
    y, z = y * cx - z * sx, y * sx + z * cx
    x, z = x * cy + z * sy, -x * sy + z * cy
    local d = z + 3.2
    local px = math.floor(pw / 2 + x * scale / d + 0.5)
    local py = math.floor(ph / 2 + y * scale / d + 0.5)
    if px >= 0 and py >= 0 and px < pw and py < ph then
      local k = py * pw + px
      if not pix[k] or z < pix[k] then pix[k] = z end
    end
  end
  blitCanvas(x1, y1, cw, ch, pix, function(z)
    if warping then return z < 0 and MAGENTA or LBLUE end      -- glows pink/blue while warping
    return z < -0.3 and WHITE or (z < 0.3 and LBLUE or GRAY)
  end, BLACK)
  if t - morph.start < MORPH + 1.2 then
    local n = SHAPES[morph.to].name
    text(x1 + math.floor((cw - #n) / 2), y2, n, LGRAY)
  end
  hit("shape", x1, y1, x2, y2, function() startMorph(now()) end)
end

-- ---------------------------------------------------------- red: real Mountain Time
local function civil(days)
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  local y = yoe + era * 400
  if m <= 2 then y = y + 1 end
  return y, m, d
end
local function daysFromCivil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = m > 2 and m - 3 or m + 9
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  return era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
end
local function nthSunday(y, m, n)
  local d1 = daysFromCivil(y, m, 1)
  return d1 + (7 - (d1 + 4) % 7) % 7 + (n - 1) * 7
end
local function mountainTime()
  local utc = math.floor(os.epoch("utc") / 1000)
  local y = civil(math.floor(utc / 86400))
  local dstStart = nthSunday(y, 3, 2) * 86400 + 9 * 3600   -- 2nd Sun of March, 2:00 MST
  local dstEnd = nthSunday(y, 11, 1) * 86400 + 8 * 3600    -- 1st Sun of Nov, 2:00 MDT
  local dst = utc >= dstStart and utc < dstEnd
  local t = utc + (dst and -6 or -7) * 3600
  local days = math.floor(t / 86400)
  local yy, mm, dd = civil(days)
  local secs = t - days * 86400
  return { year = yy, month = mm, day = dd, wday = (days + 4) % 7,
    hour = math.floor(secs / 3600), min = math.floor(secs / 60) % 60, sec = secs % 60, dst = dst }
end

local FONT = {
  ["0"] = { "01110", "10001", "10011", "10101", "11001", "10001", "01110" },
  ["1"] = { "00100", "01100", "00100", "00100", "00100", "00100", "01110" },
  ["2"] = { "01110", "10001", "00001", "00010", "00100", "01000", "11111" },
  ["3"] = { "11110", "00001", "00001", "01110", "00001", "00001", "11110" },
  ["4"] = { "00010", "00110", "01010", "10010", "11111", "00010", "00010" },
  ["5"] = { "11111", "10000", "11110", "00001", "00001", "10001", "01110" },
  ["6"] = { "00110", "01000", "10000", "11110", "10001", "10001", "01110" },
  ["7"] = { "11111", "00001", "00010", "00100", "01000", "01000", "01000" },
  ["8"] = { "01110", "10001", "10001", "01110", "10001", "10001", "01110" },
  ["9"] = { "01110", "10001", "10001", "01111", "00001", "00010", "01100" },
  [":"] = { "0", "0", "1", "0", "1", "0", "0" },
}
-- width in teletext pixels (1 px gap between glyphs)
local function smallWidth(s)
  local w = 0
  for i = 1, #s do w = w + #FONT[s:sub(i, i)][1] + 1 end
  return w - 1
end
-- draws text 3 cells tall (9 px); returns width in cells
local function smallText(x, y, s, col, bg, colonOn)
  local pwPx = smallWidth(s)
  local cw = math.ceil(pwPx / 2)
  local pw = cw * 2
  local pix, px = {}, 0
  for i = 1, #s do
    local c = s:sub(i, i)
    local g = FONT[c]
    if c ~= ":" or colonOn then
      for r = 1, 7 do
        for k = 1, #g[r] do
          if g[r]:sub(k, k) == "1" then pix[(r) * pw + px + k - 1] = 0 end
        end
      end
    end
    px = px + #g[1] + 1
  end
  blitCanvas(x, y, cw, 3, pix, function() return col end, bg)
  return cw
end

local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function drawClock()
  local x1, x2, y1, y2 = L.cx1, L.cx2, 1, L.topH
  fill(x1 + 1, y1 + 1, x2 - 1, y2 - 1, PANEL)
  thinBox(x1, y1, x2, y2, RED)
  local mt = mountainTime()
  local h12 = mt.hour % 12; if h12 == 0 then h12 = 12 end
  local s = h12 .. ":" .. string.format("%02d", mt.min)
  local ampm = mt.hour < 12 and "AM" or "PM"
  local iw = x2 - x1 - 1
  local cw = math.ceil(smallWidth(s) / 2)
  local tw = cw + 1 + 3
  local tx = x1 + 1 + math.max(0, math.floor((iw - tw) / 2))
  local ty = y1 + 2
  smallText(tx, ty, s, WHITE, PANEL, math.floor(mt.sec) % 2 == 0)
  text(tx + cw + 1, ty, ampm, RED, PANEL)
  text(tx + cw + 1, ty + 2, mt.dst and "MDT" or "MST", GRAY, PANEL)
  local date = DAYS[mt.wday + 1] .. ", " .. MONTHS[mt.month] .. " " .. mt.day
  if #date > iw then date = DAYS[mt.wday + 1]:sub(1, 3) .. ", " .. MONTHS[mt.month] .. " " .. mt.day end
  text(x1 + 1 + math.floor((iw - #date) / 2), ty + 4, date, LGRAY, PANEL)
end

-- ---------------------------------------------------------- light blue + purple: Minecraft time
local skyStars = {}
local function mcClock()
  local t = os.time("ingame") % 24
  local h, m = math.floor(t), math.floor((t % 1) * 60)
  local h12 = h % 12; if h12 == 0 then h12 = 12 end
  return t, string.format("%d:%02d %s", h12, m, h < 12 and "AM" or "PM")
end

local function drawMinecraft(t)
  local x1, x2 = L.rx1, L.rx2
  fill(x1 + 1, L.my1 + 1, x2 - 1, L.my2 - 1, PANEL)
  thinBox(x1, L.my1, x2, L.my2, MAGENTA)
  local mc, label = mcClock()
  -- sky colours by time of day
  local top, low
  if mc >= 6.5 and mc < 17.5 then top, low = DAYSKY, DAYSKY
  elseif mc >= 4.5 and mc < 6.5 then top, low = NIGHTSKY, ORANGE     -- sunrise
  elseif mc >= 17.5 and mc < 19.5 then top, low = PINK, ORANGE       -- sunset
  else top, low = NIGHTSKY, NIGHTSKY end
  local sx1, sx2, sy1, sy2 = x1 + 1, x2 - 1, L.sky1, L.sky2
  local skyH = sy2 - sy1                      -- last row is grass
  for y = sy1, sy2 - 1 do
    local col = (y - sy1) < skyH / 2 and top or low
    fill(sx1, y, sx2, y, col)
  end
  local night = top == NIGHTSKY
  if night then
    if #skyStars == 0 then
      for i = 1, 14 do skyStars[i] = { math.random(0, 1000) / 1000, math.random(0, 1000) / 1000, math.random() } end
    end
    for _, s in ipairs(skyStars) do
      local sx = sx1 + math.floor(s[1] * (sx2 - sx1))
      local sy = sy1 + math.floor(s[2] * (skyH - 1))
      local tw = math.sin(t * 2 + s[3] * 6) > -0.3
      local bg = (sy - sy1) < skyH / 2 and top or low
      if tw and bg == NIGHTSKY then setCell(sx, sy, ".", LGRAY, bg) end
    end
  end
  -- sun 6:00 -> 18:00, moon 18:00 -> 6:00, along an arc
  local function body(frac, col)
    local bx = sx1 + math.floor(frac * (sx2 - sx1 - 1) + 0.5)
    local by = sy2 - 1 - math.floor(math.sin(frac * math.pi) * (skyH - 1) + 0.5)
    setCell(bx, by, " ", WHITE, col); setCell(bx + 1, by, " ", WHITE, col)
  end
  if mc >= 6 and mc < 18 then body((mc - 6) / 12, YELLOW) else body(((mc - 18) % 24) / 12, WHITE) end
  for x = sx1, sx2 do setCell(x, sy2, "\143", GRASS, BLACK) end    -- grass strip
  -- digital time + day counter
  local day = os.day("ingame")
  local ds = tostring(day):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  local line = label .. "   " .. G_DOT .. "   DAY " .. ds
  local iw = x2 - x1 - 1
  text(x1 + 1 + math.floor((iw - #line) / 2), L.mdy, line, WHITE, PANEL)
  text(x1 + 1 + math.floor((iw - #line) / 2) + #label + 3, L.mdy, G_DOT, ACCENT, PANEL)
end

-- ---------------------------------------------------------- green: now playing + controls
local function marquee(s, width, t)
  if #s <= width then
    local pad = math.floor((width - #s) / 2)
    return string.rep(" ", pad) .. s .. string.rep(" ", width - #s - pad)
  end
  local loop = s .. "     " .. G_DOT .. "     "
  local off = math.floor(math.max(0, t - 2) * 5) % #loop
  return (loop .. loop):sub(off + 1, off + width)
end

local trackKey, trackStart = nil, 0
local function drawMusic(t)
  local st = online() and J.st or nil
  local x1, x2 = L.rx1, L.rx2
  local line
  if not netOn then line = "No modem on this computer"
  elseif not st then line = "Looking for the jukebox..."
  elseif not st.title then line = "Pick a playlist to start"
  else line = st.title .. (st.artist ~= "" and ("  -  " .. st.artist) or "") end
  local key = st and st.title
  if key ~= trackKey then trackKey, trackStart = key, t end
  text(x1, L.npy, marquee(line, x2 - x1 + 1, t - trackStart), st and st.title and WHITE or LGRAY)
  -- progress
  local pos, dur = jPos()
  local lt, rt = fmtTime(pos), fmtTime(dur)
  local bx1, bx2 = x1 + #lt + 1, x2 - #rt - 1
  local bw = bx2 - bx1 + 1
  text(x1, L.pgy, lt, LGRAY); text(bx2 + 2, L.pgy, rt, LGRAY)
  local filled = dur > 0 and math.floor(pos / dur * bw + 0.5) or 0
  for i = 1, bw do setCell(bx1 + i - 1, L.pgy, G_HLINE, i <= filled and MAGENTA or GRAY, BLACK) end
  if dur > 0 then setCell(clamp(bx1 + filled - 1, bx1, bx2), L.pgy, " ", WHITE, MAGENTA) end
  if st and st.title then
    hit("seek", bx1, L.pgy, bx2, L.pgy, function(x) send({ cmd = "seek", sec = (x - bx1) / math.max(1, bw - 1) * dur }) end)
  end
  -- buttons
  local playing = st and st.title and not st.paused
  local enabled = st ~= nil and st.title ~= nil
  local btns = {
    { "prev", G_LEFT .. G_LEFT, { cmd = "prev" } }, { "back5", "-5s", { cmd = "skip", by = -5 } },
    { "play", playing and "| |" or G_RIGHT, { cmd = "toggle" } },
    { "fwd5", "+5s", { cmd = "skip", by = 5 } }, { "next", G_RIGHT .. G_RIGHT, { cmd = "next" } },
  }
  local gap = 1
  local bw2 = math.floor((x2 - x1 + 1 - gap * 4) / 5)
  local extra = (x2 - x1 + 1) - (bw2 * 5 + gap * 4)
  local x = x1
  for i, b in ipairs(btns) do
    local w = bw2 + ((i == 3) and extra or 0)
    local isPlay = b[1] == "play"
    button(b[1], x, L.by1, x + w - 1, L.by2, b[2], isPlay and WHITE or BLACK, isPlay and RED or LBLUE,
      function() send(b[3]) end, enabled)
    x = x + w + gap
  end
end

-- ---------------------------------------------------------- frame
-- falling starfield, same feel as the jukebox (speeds scaled to this screen's height)
local stars, lastT = {}, nil
local STAR_SPEED = { 3, 7, 16 }
local function drawStars(t)
  if #stars == 0 then
    for i = 1, math.floor(W * H / 26) do stars[i] = { x = math.random(1, W), y = math.random() * H, l = math.random(1, 3) } end
  end
  local dt = lastT and math.min(0.5, t - lastT) or 0
  lastT = t
  local k = H / 38
  for _, s in ipairs(stars) do
    s.y = s.y + STAR_SPEED[s.l] * k * dt
    if s.y >= H + 2 then s.y = -math.random() * 3; s.x = math.random(1, W) end
    local y = math.floor(s.y) + 1
    if s.x <= L.lw or s.l == 1 then setCell(s.x, y, ".", GRAY)
    elseif s.l == 2 then setCell(s.x, y, G_DOT, LGRAY)
    else setCell(s.x, y - 1, "|", GRAY); setCell(s.x, y, "*", WHITE) end
  end
end

local function draw(t)
  fbClear()
  hits = {}
  drawStars(t)
  for y = 1, H do setCell(L.sep, y, G_VLINE, YELLOW, BLACK) end
  drawLeft()
  draw3D(t)
  drawClock()
  drawMinecraft(t)
  drawMusic(t)
  present()
end

local function message(lines)
  fbClear()
  for i, s in ipairs(lines) do text(math.floor((W - #s) / 2) + 1, math.floor(H / 2) - 1 + i, s, i == 1 and YELLOW or WHITE) end
  present()
end

-- ---------------------------------------------------------- main
math.randomseed(os.epoch("utc"))
computeLayout()
while not lists do
  message({ "JUKEBOX REMOTE", "Loading playlists..." })
  local err
  lists, err = loadPlaylists()
  if not lists then message({ "Couldn't load playlists", tostring(err), "Retrying in 10s..." }); sleep(10) end
end

term.clear(); term.setCursorPos(1, 1)
term.setTextColour(colors.yellow); print("JUKEBOX REMOTE")
term.setTextColour(colors.white)
print(netOn and "Modem found - talking to the jukebox." or "No modem found! Attach one to this computer.")
print("Q = quit")

send({ cmd = "hello" })
if _G.__JB_TEST then _G.__JB = { UI = UI, J = J, hits = function() return hits end, L = L } end

local timer = os.startTimer(0)
while true do
  local ev, a, b, c = os.pullEventRaw()
  if ev == "terminate" or (ev == "key" and a == keys.q) then break
  elseif ev == "timer" and a == timer then
    draw(now())
    timer = os.startTimer(CFG.frame)
  elseif ev == "rednet_message" and c == PROTO and type(b) == "table" and b.type == "state" then
    J.st, J.at, J.id = b, now(), a
    -- playlist file changed on GitHub? reload so both sides agree
    if type(b.names) == "table" and #b.names ~= #lists then
      local nl = loadPlaylists(); if nl then lists = nl; UI.view = "playlists" end
    end
  elseif ev == "monitor_touch" and a == monName then
    for i = #hits, 1, -1 do
      local h = hits[i]
      if b >= h.x1 and b <= h.x2 and c >= h.y1 and c <= h.y2 then flash[h.id] = now(); h.fn(b, c); break end
    end
  elseif ev == "monitor_resize" and a == monName then computeLayout(); stars = {}
  elseif ev == "peripheral" or ev == "peripheral_detach" then openNet()
  end
end

for i = 0, 15 do local col = 2 ^ i; mon.setPaletteColour(col, term.nativePaletteColour(col)) end
mon.setBackgroundColour(colors.black); mon.clear()
term.clear(); term.setCursorPos(1, 1); print("Remote stopped.")
