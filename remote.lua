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
  [colors.cyan]      = 0xa8dcff, -- day sky
  [colors.purple]    = 0x0e1a4a, -- night sky
  [colors.orange]    = 0xd8904a, -- sunrise / sunset + wood planks
  [colors.pink]      = 0x7a4a24, -- brown (wood, dirt, doors)
  [colors.green]     = 0x3f9b2f, -- grass
  [colors.yellow]    = 0xffd23f,
  [colors.red]       = 0xff3b3b,
  [colors.magenta]   = 0xff4fa3,
  [colors.lime]      = 0x2d6e23, -- dark green (hill)
}
for c, v in pairs(PAL) do mon.setPaletteColour(c, v) end

local WHITE, ORANGE, MAGENTA, LBLUE, YELLOW, DKGREEN, BROWN, GRAY, LGRAY = "0", "1", "2", "3", "4", "5", "6", "7", "8"
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
  L.by2 = H; L.by1 = H                                 -- green controls (1 row)
  L.pgy = H - 1                                        -- progress row
  L.npy = H - 2                                        -- now playing row
  L.my1 = L.topH + 1; L.my2 = H - 3                    -- pink MC box
  L.sky1, L.sky2 = L.my1 + 1, L.my2 - 2                -- light blue scene
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

-- music reaction (beat messages from the jukebox)
local BEAT = { bass = 0, at = -10, last = -10, colour = 1, rings = {} }
local SCHEMES = {
  { WHITE, LBLUE, GRAY }, { WHITE, MAGENTA, GRAY }, { YELLOW, RED, GRAY },
  { WHITE, GRASS, GRAY }, { LBLUE, MAGENTA, GRAY }, { YELLOW, LBLUE, GRAY },
}
local function onBeat(msg, t)
  BEAT.bass, BEAT.at = tonumber(msg.bass) or 0, t
  if msg.beat then
    BEAT.last = t
    BEAT.colour = BEAT.colour % #SCHEMES + 1
    BEAT.rings[#BEAT.rings + 1] = t
    if #BEAT.rings > 3 then table.remove(BEAT.rings, 1) end
  end
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
  local bass = (t - BEAT.at < 1) and BEAT.bass or 0
  local pulse = math.exp(-(t - BEAT.last) * 7)                 -- 1 on the beat, fades fast
  BEAT.spin = (BEAT.spin or 0) + (bass * 1.5) * (CFG.frame)    -- extra spin while the bass is heavy
  local spin = t + BEAT.spin + (warping and math.sin(f * math.pi) * 1.2 or 0)   -- spins faster mid-warp
  local ax, ay = spin * 0.9, spin * 1.3
  local cx, sx, cy, sy = math.cos(ax), math.sin(ax), math.cos(ay), math.sin(ay)
  local scale = math.min(pw, ph) * 0.42 * 3.2 * (1 + 0.18 * math.sin(f * math.pi)) * (1 + 0.16 * pulse + 0.06 * bass)
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
  -- light rings expanding from the shape on each beat
  for _, rt in ipairs(BEAT.rings) do
    local age = t - rt
    if age < 0.5 then
      local rad = math.min(pw, ph) * (0.28 + age * 0.9)
      for a = 0, 47 do
        local ang = a / 48 * 2 * math.pi
        local px = math.floor(pw / 2 + math.cos(ang) * rad + 0.5)
        local py = math.floor(ph / 2 + math.sin(ang) * rad * 0.9 + 0.5)
        if px >= 0 and py >= 0 and px < pw and py < ph then
          local k = py * pw + px
          if not pix[k] then pix[k] = 10 + age end            -- depth >= 10 marks ring pixels
        end
      end
    end
  end
  local sc = SCHEMES[BEAT.colour]
  blitCanvas(x1, y1, cw, ch, pix, function(z)
    if z >= 10 then return (z - 10) < 0.25 and sc[1] or sc[2] end   -- ring: bright, then dimmer
    if warping then return z < 0 and MAGENTA or LBLUE end      -- glows pink/blue while warping
    if pulse > 0.5 then return z < 0.3 and sc[1] or sc[2] end  -- flash brighter right on the beat
    return z < -0.3 and sc[1] or (z < 0.3 and sc[2] or sc[3])
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

-- ---------------------------------------------------------- Firestone, CO weather (Open-Meteo, free, no key)
local WX_URL = "https://api.open-meteo.com/v1/forecast?latitude=40.1125&longitude=-104.9366" ..
  "&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min" ..
  "&temperature_unit=fahrenheit&timezone=America%2FDenver&forecast_days=1"
local WX = { at = -1e9, pending = false, ok = false }
local function wxFetch(t)
  if WX.pending and t - WX.at > 30 then WX.pending = false; WX.err = "no reply (timed out)" end
  if WX.pending then return end
  local wait = WX.ok and 600 or 60                         -- every 10 min (retry each minute until it works)
  if t - WX.at < wait then return end
  WX.pending, WX.at = true, t
  local ok, res, why = pcall(http.request, WX_URL)
  if not ok or res == false then                           -- refused straight away (e.g. site not allowed)
    WX.pending = false
    WX.err = tostring(not ok and res or why or "request refused")
  end
end
local function wxResult(handle, why)
  WX.pending = false
  if not handle then WX.err = tostring(why or "request failed"); return end
  local body = handle.readAll()
  handle.close()
  local ok, data = pcall(textutils.unserializeJSON, body)
  if not (ok and type(data) == "table" and type(data.current) == "table") then
    WX.err = "couldn't read weather data"
  end
  if ok and type(data) == "table" and type(data.current) == "table" then
    WX.err = nil
    WX.temp = tonumber(data.current.temperature_2m)
    WX.code = tonumber(data.current.weather_code) or 0
    WX.day = data.current.is_day == 1
    local d = type(data.daily) == "table" and data.daily or {}
    WX.hi = type(d.temperature_2m_max) == "table" and tonumber(d.temperature_2m_max[1]) or nil
    WX.lo = type(d.temperature_2m_min) == "table" and tonumber(d.temperature_2m_min[1]) or nil
    WX.ok = WX.temp ~= nil
  end
end
-- WMO weather code -> short label, icon, icon colour
local function wxLook(code, day)
  if code == 0 then return day and "Sunny" or "Clear", day and "\15" or "\7", day and YELLOW or WHITE end
  if code <= 2 then return "Partly", day and "\15" or "\7", day and YELLOW or LGRAY end
  if code == 3 then return "Cloudy", "\22", LGRAY end
  if code == 45 or code == 48 then return "Fog", "=", LGRAY end
  if code >= 51 and code <= 57 then return "Drizzle", "\25", LBLUE end
  if (code >= 61 and code <= 67) or (code >= 80 and code <= 82) then return "Rain", "\25", LBLUE end
  if (code >= 71 and code <= 77) or code == 85 or code == 86 then return "Snow", "*", WHITE end
  if code >= 95 then return "Storm", "\19", YELLOW end
  return "--", "?", GRAY
end

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
  local ty = y1 + 1
  smallText(tx, ty, s, WHITE, PANEL, math.floor(mt.sec) % 2 == 0)
  text(tx + cw + 1, ty, ampm, RED, PANEL)
  text(tx + cw + 1, ty + 2, mt.dst and "MDT" or "MST", GRAY, PANEL)
  local date = DAYS[mt.wday + 1] .. ", " .. MONTHS[mt.month] .. " " .. mt.day
  if #date > iw then date = DAYS[mt.wday + 1]:sub(1, 3) .. ", " .. MONTHS[mt.month] .. " " .. mt.day end
  text(x1 + 1 + math.floor((iw - #date) / 2), ty + 3, date, LGRAY, PANEL)
  -- Firestone weather: "Firestone  * 24°F" / "Snow  H35° L19°"
  local deg = "\176"
  if WX.ok then
    local label, icon, icol = wxLook(WX.code, WX.day)
    local temp = math.floor(WX.temp + 0.5) .. deg .. "F"
    local l1 = "Firestone  " .. icon .. " " .. temp
    local lx = x1 + 1 + math.floor((iw - #l1) / 2)
    text(lx, ty + 4, "Firestone", RED, PANEL)
    text(lx + 11, ty + 4, icon, icol, PANEL)
    text(lx + 13, ty + 4, temp, WHITE, PANEL)
    local l2 = label
    if WX.hi and WX.lo then l2 = l2 .. "  H" .. math.floor(WX.hi + 0.5) .. deg .. " L" .. math.floor(WX.lo + 0.5) .. deg end
    text(x1 + 1 + math.floor((iw - #l2) / 2), ty + 5, l2, GRAY, PANEL)
    text(x1 + 1 + math.floor((iw - #l2) / 2), ty + 5, label, icol == YELLOW and YELLOW or LGRAY, PANEL)
  else
    local msg = "Firestone weather..."
    text(x1 + 1 + math.floor((iw - #msg) / 2), ty + 4, msg, GRAY, PANEL)
    if WX.err then                                          -- show why it isn't loading
      local e = WX.err
      if #e > iw then e = e:sub(1, iw) end
      text(x1 + 1 + math.floor((iw - #e) / 2), ty + 5, e, RED, PANEL)
    end
  end
end

-- ---------------------------------------------------------- light blue + purple: Minecraft scene + time
-- Weather needs an Environment Detector (Advanced Peripherals mod) on this computer or the network.
local weather = { rain = false, thunder = false, known = false, checked = -10 }
local function updateWeather(t)
  if t - weather.checked < 3 then return end
  weather.checked = t
  local det = peripheral.find("environmentDetector") or peripheral.find("environment_detector")
  if det then
    local ok1, r = pcall(det.isRaining)
    local ok2, th = pcall(det.isThunder)
    weather.rain, weather.thunder, weather.known = ok1 and r == true, ok2 and th == true, true
  else
    weather.rain, weather.thunder, weather.known = false, false, false
  end
end

local function mcClock()
  local t = os.time("ingame") % 24
  local h, m = math.floor(t), math.floor((t % 1) * 60)
  local h12 = h % 12; if h12 == 0 then h12 = 12 end
  return t, string.format("%d:%02d %s", h12, m, h < 12 and "AM" or "PM")
end

-- Colour pixels -> teletext: every cell shows its two most common colours.
local function blitColorCanvas(x1, y1, cw, ch, px)
  for cy = 0, ch - 1 do
    local r1, r2, r3 = px[cy * 3 + 1], px[cy * 3 + 2], px[cy * 3 + 3]
    for cx = 0, cw - 1 do
      local a, b = cx * 2 + 1, cx * 2 + 2
      local p = { r1[a], r1[b], r2[a], r2[b], r3[a], r3[b] }
      local cnt, c1, c2 = {}, nil, nil
      for i = 1, 6 do cnt[p[i]] = (cnt[p[i]] or 0) + 1 end
      for col, n in pairs(cnt) do
        if not c1 or n > cnt[c1] then c2 = c1; c1 = col
        elseif not c2 or n > cnt[c2] then c2 = col end
      end
      if not c2 then
        setCell(x1 + cx, y1 + cy, " ", WHITE, c1)
      else
        local bits = 0
        for i = 1, 6 do if p[i] == c2 then bits = bits + 2 ^ (i - 1) end end
        if bits >= 32 then setCell(x1 + cx, y1 + cy, string.char(128 + (63 - bits)), c1, c2)
        else setCell(x1 + cx, y1 + cy, string.char(128 + bits), c2, c1) end
      end
    end
  end
end

-- sprites face right; "." = transparent
local SPR = {
  -- designed so every 2x3 screen cell needs at most two colours
  cow      = { "666600", "666600", "6.6.00" },            -- brown body, white face
  pig      = { "2222", "2222", "2..2" },                    -- small pink block
  zombie   = { "dd", "d7", "77", "66", "66", "dd" },     -- green skin, torn gray shirt, brown pants
  skeleton = { "00", "f0", "00", ".0", "0.", "0." },
  resident = { "33", "3d", "33", "ff", "ff", "77" },  -- light blue w/ green speck, black pants, gray feet
}
local DAY_MOBS = { "cow", "pig" }
local NIGHT_MOBS = { "zombie", "skeleton" }

local SC = { mobs = {}, nextMob = 0, clouds = nil, drops = nil, stars = nil, bolt = nil, nextBolt = 0, lastT = nil,
  res = { state = "inside", x = 0, target = 0, wait = 0, face = 1 } }

local function drawScene(t, mc, x1, y1, cw, ch)
  local PW, PH = cw * 2, ch * 3
  local dt = SC.lastT and math.min(0.5, t - SC.lastT) or 0
  SC.lastT = t
  local px = {}
  local gy = PH - 2                                    -- top grass row
  local isNight = mc >= 19 or mc < 5.5
  local rain, storm = weather.rain or weather.thunder, weather.thunder

  -- sky
  local top, low
  if mc >= 6.5 and mc < 17.5 then top, low = DAYSKY, DAYSKY
  elseif mc >= 4.5 and mc < 6.5 then top, low = NIGHTSKY, RED       -- sunrise (not orange: that's the planks)
  elseif mc >= 17.5 and mc < 19.5 then top, low = MAGENTA, RED      -- sunset
  else top, low = NIGHTSKY, NIGHTSKY end
  if rain and top == DAYSKY then top, low = storm and GRAY or LGRAY, storm and GRAY or LGRAY end
  local flash = SC.bolt and t < SC.bolt.flash
  for y = 1, PH do
    local row = {}
    local col = flash and WHITE or ((y <= (gy - 1) / 2) and top or low)
    for x = 1, PW do row[x] = col end
    px[y] = row
  end
  local function put(x, y, c)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    if y >= 1 and y <= PH and x >= 1 and x <= PW then px[y][x] = c end
  end
  local function rect(xa, ya, xb, yb, c) for y = ya, yb do for x = xa, xb do put(x, y, c) end end end
  local function sprite(name, x, yBottom, face)
    local spr = SPR[name]
    local w = #spr[1]
    for r = 1, #spr do
      local row = spr[r]
      for k = 1, w do
        local c = row:sub(face > 0 and k or (w - k + 1), face > 0 and k or (w - k + 1))
        if c ~= "." then put(x + k - 1, yBottom - #spr + r, c) end
      end
    end
  end

  -- stars
  if not SC.stars then
    SC.stars = {}
    for i = 1, 18 do SC.stars[i] = { math.random(1, PW), math.random(1, gy - 8), math.random() * 6 } end
  end
  if top == NIGHTSKY and not rain and not flash then
    for _, s in ipairs(SC.stars) do
      if math.sin(t * 1.7 + s[3]) > -0.4 then put(s[1], s[2], math.sin(t + s[3]) > 0.3 and WHITE or LGRAY) end
    end
  end

  -- sun / moon on an arc
  local arcH = gy - 6
  local function body(frac, col, size)
    local bx = 2 + frac * (PW - 4 - size)
    local by = gy - 3 - math.sin(frac * math.pi) * arcH
    rect(bx, by, bx + size - 1, by + size - 1, col)
  end
  if not rain then
    if mc >= 6 and mc < 18 then body((mc - 6) / 12, YELLOW, 4) else body(((mc - 18) % 24) / 12, WHITE, 3) end
  end

  -- clouds
  if not SC.clouds then
    SC.clouds = {}
    for i = 1, 5 do SC.clouds[i] = { x = math.random(0, PW), y = math.random(2, 7), w = math.random(7, 13), v = 1 + math.random() } end
  end
  local cloudCol = storm and PANEL or (rain and GRAY or ((top == NIGHTSKY) and GRAY or WHITE))
  local nClouds = rain and 5 or 3
  for i = 1, nClouds do
    local c = SC.clouds[i]
    c.x = c.x + c.v * dt
    if c.x > PW + 2 then c.x = -c.w - math.random(0, 10); c.y = math.random(2, 7) end
    local cx = math.floor(c.x)
    rect(cx + 2, c.y, cx + c.w - 3, c.y, cloudCol)
    rect(cx, c.y + 1, cx + c.w - 1, c.y + 1, cloudCol)
    rect(cx + 1, c.y + 2, cx + c.w - 2, c.y + 2, cloudCol)
  end

  -- hill: rounded steps of 4-pixel blocks, grassy body with a bright grass top edge
  local hcx, hrx = math.floor(PW * 0.8 / 4) * 4 + 1, math.floor(PW * 0.3)
  local levels = math.max(2, math.floor(gy * 0.45 / 3))
  for bx = math.floor((hcx - hrx) / 4) * 4 + 1, hcx + hrx, 4 do
    local dist = math.abs(bx + 1.5 - hcx)
    local d = clamp(math.floor((hrx - dist) / 5) + 1, 0, levels) * 3   -- even steps: 4 px across, 3 px up
    if d > 0 then
      for x = bx, bx + 3 do
        for y = gy - d, gy - 1 do
          local depth = y - (gy - d)
          local c
          if depth == 0 then c = GRASS                               -- grass top
          elseif depth < 3 then c = BROWN                            -- dirt layer
          else                                                       -- stone with coal ore clusters
            local cx, cy = math.floor(x / 4), math.floor(y / 3)
            local ore = (cx * 7 + cy * 11) % 5 == 0
            c = (ore and (x + y) % 2 == 0) and BLACK or LGRAY
          end
          put(x, y, c)
        end
      end
    end
  end

  -- ground
  rect(1, gy, PW, gy, GRASS)
  rect(1, gy + 1, PW, PH, BROWN)

  -- village-style cottage, laid out on the 2x3 screen-cell grid so every block stays crisp
  -- (rows counted up from the grass line: one block row = 3 pixels)
  local hx, hw = 3, 18
  local b1 = gy - 3                 -- bottom block row: cobblestone base (gy-3 .. gy-1)
  local b2 = gy - 6                 -- lower wall row
  local b3 = gy - 9                 -- upper wall row (windows)
  local b4 = gy - 12                -- log beam
  local function blockRow(y, xa, xb, c) rect(xa, y, xb, y + 2, c) end
  -- cobblestone base
  for x = hx, hx + hw - 1 do for y = b1, b1 + 2 do put(x, y, ((x + y * 2) % 3 == 0) and GRAY or LGRAY) end end
  -- plank walls with seams, log corner posts and top beam
  for y = b3, b2 + 2 do for x = hx, hx + hw - 1 do put(x, y, (y == b3 + 2 or y == b2 + 2) and BROWN or ORANGE) end end
  blockRow(b4, hx, hx + hw - 1, BROWN)
  rect(hx, b4, hx + 1, b1 + 2, BROWN)
  rect(hx + hw - 2, b4, hx + hw - 1, b1 + 2, BROWN)
  -- roof: stair steps on the edges, plank gable inside, small attic window
  local r1, r2, r3 = b4 - 3, b4 - 6, b4 - 9
  blockRow(r1, hx - 2, hx + 1, BROWN); blockRow(r1, hx + 2, hx + hw - 3, ORANGE); blockRow(r1, hx + hw - 2, hx + hw + 1, BROWN)
  blockRow(r2, hx + 2, hx + 5, BROWN); blockRow(r2, hx + 6, hx + hw - 7, ORANGE); blockRow(r2, hx + hw - 6, hx + hw - 3, BROWN)
  blockRow(r3, hx + 6, hx + hw - 7, BROWN)
  local lightOn = mc >= 18 or mc < 6.5 or (storm and SC.res.state == "inside")
  local glass = lightOn and YELLOW or BLACK                    -- dark by day, lit at night
  blockRow(r2, hx + 8, hx + 9, glass)                          -- attic window
  -- windows (one block tall, two wide) and a 1x2 door in the middle
  blockRow(b3, hx + 2, hx + 5, glass)
  blockRow(b3, hx + hw - 6, hx + hw - 3, glass)
  local doorX = hx + 8
  rect(doorX, b2, doorX + 1, b1 + 2, BROWN)

  -- round, bright tree with a thick trunk (shape from Bryan's sketch)
  local tx = hx + hw + 8                                       -- trunk left edge
  rect(tx, b4 + 3, tx + 3, gy - 1, BROWN)                      -- 4-pixel-wide trunk
  -- blocky oak: small cap, medium layer, two wide bottom layers (rows = 3-pixel block rows)
  local rows = {
    { b4 - 6, tx,     tx + 3, 4 },    -- cap (top stays one block below the roof peak)
    { b4 - 3, tx - 4, tx + 7, 5 },    -- middle layer
    { b4,     tx - 6, tx + 9, 7 },    -- wide
    { b4 + 3, tx - 6, tx + 9, 11 },   -- wide bottom, darker (fewer light specks)
  }
  for _, r in ipairs(rows) do
    for y = r[1], r[1] + 2 do
      for x = r[2], r[3] do put(x, y, ((x * 3 + y * 5) % r[4] == 0) and GRASS or DKGREEN) end
    end
  end

  -- resident: out during the day, home at night or when it rains
  local R = SC.res
  local wantsOut = mc >= 7 and mc < 18 and not rain
  if R.state == "inside" and wantsOut then
    R.state, R.x, R.target, R.wait = "out", doorX, doorX + 6, 0
  elseif R.state == "out" and not wantsOut then
    R.state, R.target = "returning", doorX
  end
  if R.state ~= "inside" then
    if math.abs(R.target - R.x) < 0.5 then
      if R.state == "returning" then R.state = "inside"
      else
        R.wait = R.wait - dt
        if R.wait <= 0 then R.target = math.random(doorX + 4, PW - 6); R.wait = math.random(1, 4) end
      end
    else
      local dir = R.target > R.x and 1 or -1
      R.face = dir
      R.x = R.x + dir * math.min(4 * dt, math.abs(R.target - R.x))
    end
  end

  -- mobs: stand somewhere for a while, then disappear (animals by day, monsters at night)
  local pool = isNight and NIGHT_MOBS or DAY_MOBS
  for i = #SC.mobs, 1, -1 do
    local m = SC.mobs[i]
    local ok = false
    for _, k in ipairs(pool) do if k == m.kind then ok = true end end
    if t > m.untilT or not ok then table.remove(SC.mobs, i) end
  end
  if t >= SC.nextMob and #SC.mobs < 2 then
    local kind = pool[math.random(1, #pool)]
    local w = #SPR[kind][1]
    for _ = 1, 8 do                                    -- find a free spot (not on the house or another mob)
      local x = math.floor(math.random(hx + hw + 2, PW - w) / 2) * 2 + 1
      local free = true
      for _, m in ipairs(SC.mobs) do if math.abs(m.x - x) < 8 then free = false end end
      if free then
        SC.mobs[#SC.mobs + 1] = { kind = kind, x = x, face = math.random(0, 1) == 0 and -1 or 1, untilT = t + math.random(25, 50) }
        break
      end
    end
    SC.nextMob = t + math.random(8, 20)
  end
  for _, m in ipairs(SC.mobs) do sprite(m.kind, m.x, gy - 1, m.face) end
  if R.state ~= "inside" then sprite("resident", math.floor(R.x / 2) * 2 + 1, gy - 1, R.face) end -- cell-aligned so all colours show

  -- rain
  if rain then
    if not SC.drops then
      SC.drops = {}
      for i = 1, 40 do SC.drops[i] = { math.random(1, PW), math.random() * PH } end
    end
    for _, d in ipairs(SC.drops) do
      d[2] = d[2] + 22 * dt
      d[1] = d[1] - 3 * dt
      if d[2] > gy then d[2] = math.random() * 4; d[1] = math.random(1, PW + 6) end
      put(d[1], d[2], LBLUE)
    end
  end

  -- lightning
  if storm and t >= SC.nextBolt then
    local pts, x = {}, math.random(8, PW - 8)
    for y = 6, gy - 1 do x = x + math.random(-1, 1); pts[#pts + 1] = { x, y } end
    SC.bolt = { pts = pts, flash = t + 0.12, untilT = t + 0.4 }
    SC.nextBolt = t + math.random(4, 12)
  end
  if SC.bolt and t < SC.bolt.untilT then
    for _, p in ipairs(SC.bolt.pts) do put(p[1], p[2], YELLOW) end
  end

  blitColorCanvas(x1, y1, cw, ch, px)
end

local function drawMinecraft(t)
  local x1, x2 = L.rx1, L.rx2
  fill(x1 + 1, L.my1 + 1, x2 - 1, L.my2 - 1, PANEL)
  thinBox(x1, L.my1, x2, L.my2, MAGENTA)
  updateWeather(t)
  local mc, label = mcClock()
  drawScene(t, mc, x1 + 1, L.sky1, x2 - x1 - 1, L.sky2 - L.sky1 + 1)
  local day = os.day("ingame")
  local ds = tostring(day):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  local parts = { label, "DAY " .. ds }
  if weather.thunder then parts[3] = "STORM" elseif weather.rain then parts[3] = "RAIN" end
  local sep = "  " .. G_DOT .. "  "
  local line = table.concat(parts, sep)
  local iw = x2 - x1 - 1
  local lx = x1 + 1 + math.floor((iw - #line) / 2)
  text(lx, L.mdy, line, WHITE, PANEL)
  local pos = lx
  for i = 1, #parts - 1 do
    pos = pos + #parts[i]
    text(pos + 2, L.mdy, G_DOT, MAGENTA, PANEL)
    pos = pos + #sep
  end
  if parts[3] then text(lx + #line - #parts[3], L.mdy, parts[3], weather.thunder and YELLOW or LBLUE, PANEL) end
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

-- the computer's own screen: status + Mountain time + Firestone weather (refreshed every ~30s)
local function termStatus()
  term.setBackgroundColour(colors.black)
  term.clear(); term.setCursorPos(1, 1)
  term.setTextColour(colors.yellow); print("JUKEBOX REMOTE")
  term.setTextColour(colors.white)
  print(netOn and "Modem found - talking to the jukebox." or "No modem found! Attach one to this computer.")
  term.setTextColour(colors.lightGray); print("Q = quit")
  local mt = mountainTime()
  local h12 = mt.hour % 12; if h12 == 0 then h12 = 12 end
  print("")
  term.setTextColour(colors.white)
  print(string.format("%d:%02d %s %s  %s, %s %d", h12, mt.min, mt.hour < 12 and "AM" or "PM", mt.dst and "MDT" or "MST",
    DAYS[mt.wday + 1], MONTHS[mt.month], mt.day))
  term.setTextColour(colors.lightGray)
  if WX.ok then
    local label = wxLook(WX.code, WX.day)
    local hl = (WX.hi and WX.lo) and string.format("  H%d L%d", math.floor(WX.hi + 0.5), math.floor(WX.lo + 0.5)) or ""
    print(string.format("Firestone  %d\176F %s%s", math.floor(WX.temp + 0.5), label, hl))
  else
    print("Firestone  loading weather...")
    if WX.err then term.setTextColour(colors.red); print("Weather error: " .. WX.err) end
  end
end
termStatus()
local frames = 0

send({ cmd = "hello" })
if _G.__JB_TEST then _G.__JB = { UI = UI, J = J, hits = function() return hits end, L = L } end

local timer = os.startTimer(0)
while true do
  local ev, a, b, c = os.pullEventRaw()
  if ev == "terminate" or (ev == "key" and a == keys.q) then break
  elseif ev == "timer" and a == timer then
    wxFetch(now())
    draw(now())
    frames = frames + 1
    if frames % 300 == 0 then termStatus() end
    timer = os.startTimer(CFG.frame)
  elseif ev == "rednet_message" and c == PROTO and type(b) == "table" and b.type == "beat" then
    onBeat(b, now())
  elseif ev == "rednet_message" and c == PROTO and type(b) == "table" and b.type == "state" then
    J.st, J.at, J.id = b, now(), a
    -- playlist file changed on GitHub? reload so both sides agree
    if type(b.names) == "table" and #b.names ~= #lists then
      local nl = loadPlaylists(); if nl then lists = nl; UI.view = "playlists" end
    end
  elseif (ev == "http_success" or ev == "http_failure") and a == WX_URL then
    if ev == "http_success" then wxResult(b) else wxResult(nil, b) end
    termStatus()
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
