-- ============================================================
--  SPACE JUKEBOX  -  CC: Tweaked music player
--  Streams .dfpwm songs from GitHub, always shuffled.
--  Repo: TensorialRhyme5/Minecraft-Music
-- ============================================================

local REPO = "https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-Music/main/"

local CFG = {
  textScale  = 0.5,   -- monitor text scale (0.5 = most detail)
  volume     = 1.0,   -- speaker volume 0.0 - 3.0
  frame      = 0.1,   -- seconds between screen redraws
  autoplay   = false, -- true = start the first playlist on boot
  eqFloor    = 58,    -- equalizer sensitivity (lower = taller bars)
  eqCeil     = 92,
  eqTilt     = 30,    -- boost for high frequencies
  starCells  = 26,    -- one star per this many screen cells
  chunk      = 4 * 1024,
}

local dfpwm = require("cc.audio.dfpwm")

-- every connected monitor shows the same screen (mirrored) and accepts taps
local mons, monByName = {}, {}
local function findMonitors()
  mons, monByName = {}, {}
  for _, m in ipairs({ peripheral.find("monitor") }) do
    if m.isColour() then
      local e = { p = m, name = peripheral.getName(m), lastRow = {} }
      mons[#mons + 1] = e
      monByName[e.name] = e
    end
  end
end
findMonitors()
if #mons == 0 then error("No advanced monitor found. Put the computer touching the monitor (or use wired modems).", 0) end
local speakers = { peripheral.find("speaker") }
if #speakers == 0 then error("No speaker found. Place a speaker touching the computer.", 0) end

-- ---------------------------------------------------------- palette
local PAL = {
  [colors.black]     = 0x05060f, -- deep space
  [colors.brown]     = 0x15162e, -- panel
  [colors.blue]      = 0x2c2f72, -- highlight row
  [colors.gray]      = 0x4a4e66,
  [colors.lightGray] = 0x9ea3c2,
  [colors.purple]    = 0x9b5cff,
  [colors.magenta]   = 0xff4fa3,
  [colors.lime]      = 0x7ed957,
  [colors.lightBlue] = 0x38c6ff,
  [colors.green]     = 0x2ee05a,
  [colors.yellow]    = 0xffd23f,
  [colors.red]       = 0xff3b3b,
}
local function applyPalette()
  for _, e in ipairs(mons) do for c, v in pairs(PAL) do e.p.setPaletteColour(c, v) end end
end
applyPalette()

-- blit colour codes
local WHITE, MAGENTA, YELLOW, LIME, GRAY, LGRAY = "0", "2", "4", "5", "7", "8"
local PURPLE, HILITE, PANEL, GREEN, RED, BLACK = "a", "b", "c", "d", "e", "f"
local LBLUE = "3"

-- CC font glyphs
local G_RIGHT, G_LEFT, G_UP, G_DOWN, G_DOT = "\16", "\17", "\30", "\31", "\7"
local G_HLINE, G_VLINE = "\140", "\149"
local G_TOP1, G_TOP2 = "\131", "\143" -- top third / top two thirds filled

-- ---------------------------------------------------------- helpers
local function now() return os.epoch("utc") / 1000 end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function wake() os.queueEvent("jb_wake") end

local function clean(s)
  s = tostring(s or "")
  s = s:gsub("\226\128[\152\153]", "'"):gsub("\226\128[\156\157]", '"')
  s = s:gsub("[\192-\255][\128-\191]*", "?")
  return s
end

local function fmtTime(sec)
  sec = math.floor(sec)
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function shuffled(n, avoidFirst)
  local t = {}
  for i = 1, n do t[i] = i end
  for i = n, 2, -1 do
    local j = math.random(1, i)
    t[i], t[j] = t[j], t[i]
  end
  if avoidFirst and n > 1 and t[1] == avoidFirst then t[1], t[2] = t[2], t[1] end
  return t
end

-- ---------------------------------------------------------- framebuffer
local W, H = 0, 0
local fbC, fbF, fbB = {}, {}, {}

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

local function text(x, y, s, fg, bg)
  for i = 1, #s do setCell(x + i - 1, y, s:sub(i, i), fg, bg) end
end

local function fill(x1, y1, x2, y2, bg)
  for y = y1, y2 do for x = x1, x2 do setCell(x, y, " ", WHITE, bg) end end
end

local function present()
  for y = 1, H do
    local c, f, b = table.concat(fbC[y]), table.concat(fbF[y]), table.concat(fbB[y])
    local key = c .. f .. b
    for _, e in ipairs(mons) do
      if e.lastRow[y] ~= key then
        e.p.setCursorPos(1, y)
        e.p.blit(c, f, b)
        e.lastRow[y] = key
      end
    end
  end
end

-- ---------------------------------------------------------- layout
local L = {}
local function computeLayout()
  W, H = math.huge, math.huge
  for _, e in ipairs(mons) do            -- if sizes differ, use the smallest
    e.p.setTextScale(CFG.textScale)
    local w, h = e.p.getSize()
    W, H = math.min(W, w), math.min(H, h)
    e.lastRow = {}
    e.p.setBackgroundColour(colors.black)
    e.p.clear()
  end
  fbC, fbF, fbB = {}, {}, {}
  for y = 1, H do fbC[y], fbF[y], fbB[y] = {}, {}, {} end

  L.lw  = math.max(20, math.floor(W * 0.3))       -- left (yellow) panel width
  L.sep = L.lw + 1
  L.rx1, L.rx2 = L.lw + 2, W                        -- right (red) area
  L.rw  = L.rx2 - L.rx1 + 1
  L.cx  = math.floor((L.rx1 + L.rx2) / 2)

  L.tw  = math.min(L.rw - 4, math.max(30, math.floor(L.rw * 0.7)))  -- purple box
  L.tx1 = L.cx - math.floor(L.tw / 2); L.tx2 = L.tx1 + L.tw - 1
  L.ty1, L.ty2 = 2, 6

  L.by2 = H - 2; L.by1 = L.by2 - 2                  -- lime controls
  L.py  = L.by1 - 3                                 -- pink progress bar
  L.ey1 = L.ty2 + 3; L.ey2 = L.py - 3               -- blue equalizer
  L.nb  = math.max(8, math.floor((L.rw - 8 + 1) / 3))
  L.ex1 = L.cx - math.floor((L.nb * 3 - 1) / 2)

  L.hy2 = 3                                         -- list header rows 1-3
  L.ly1 = 5                                         -- list rows
  L.fy1 = H - 2                                     -- scroll buttons
  L.ly2 = L.fy1 - 2
  L.rows = L.ly2 - L.ly1 + 1
end

-- ---------------------------------------------------------- equalizer (FFT)
local N = 1024
local rev, hann, cosT, sinT, re, im = {}, {}, {}, {}, {}, {}
do
  for i = 0, N - 1 do
    local r, v = 0, i
    for _ = 1, 10 do r = r * 2 + v % 2; v = math.floor(v / 2) end
    rev[i] = r
    hann[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (N - 1))
    re[i], im[i] = 0, 0
  end
  for i = 0, N / 2 - 1 do
    cosT[i] = math.cos(2 * math.pi * i / N)
    sinT[i] = -math.sin(2 * math.pi * i / N)
  end
end

local function fft()
  local size = 2
  while size <= N do
    local half, step = size / 2, N / size
    for start = 0, N - 1, size do
      local k = 0
      for j = start, start + half - 1 do
        local l = j + half
        local wr, wi = cosT[k], sinT[k]
        local rl, il = re[l], im[l]
        local tr = wr * rl - wi * il
        local ti = wr * il + wi * rl
        local rj, ij = re[j], im[j]
        re[l], im[l] = rj - tr, ij - ti
        re[j], im[j] = rj + tr, ij + ti
        k = k + step
      end
    end
    size = size * 2
  end
end

local bandLo, bandHi, levels, shown, peaks = {}, {}, {}, {}, {}
local function setupBands(nb)
  local fmin, fmax, prev = 60, 12000, 1
  for b = 1, nb do
    local hi = math.max(prev, math.floor(fmin * (fmax / fmin) ^ (b / nb) / 46.875))
    bandLo[b], bandHi[b] = prev, hi
    prev = hi + 1
    levels[b], shown[b], peaks[b] = 0, 0, 0
  end
end

local LN10 = math.log(10)
local function analyze(data, pos)
  local s = math.max(0, math.floor(pos * 6000) - 160)
  local e = s + 288
  if e > #data then return false end
  local pcm = dfpwm.make_decoder()(data:sub(s + 1, e))
  local off = #pcm - N
  for i = 0, N - 1 do
    local r = rev[i]
    re[r] = (pcm[off + i + 1] or 0) * hann[i]
    im[r] = 0
  end
  fft()
  local nb = L.nb
  for k = 1, nb do
    local m = 0
    for i = bandLo[k], bandHi[k] do
      local v = re[i] * re[i] + im[i] * im[i]
      if v > m then m = v end
    end
    local db = 10 * math.log(m + 1) / LN10 + CFG.eqTilt * (k - 1) / (nb - 1)
    levels[k] = clamp((db - CFG.eqFloor) / (CFG.eqCeil - CFG.eqFloor), 0, 1)
  end
  return true
end

local function updateBars(dt, active)
  local f = dt / 0.1
  for k = 1, L.nb do
    local target = active and levels[k] or 0
    if target > shown[k] then
      shown[k] = shown[k] + (target - shown[k]) * math.min(1, 0.75 * f)
    else
      shown[k] = math.max(target, shown[k] - 0.11 * f)
    end
    peaks[k] = math.max(shown[k], peaks[k] - 0.02 * f)
  end
end

-- ---------------------------------------------------------- stars
local stars = {}
local STAR_SPEED = { 3, 7, 16 }
local function initStars()
  stars = {}
  for i = 1, math.floor(W * H / CFG.starCells) do
    stars[i] = { x = math.random(1, W), y = math.random() * H, l = math.random(1, 3) }
  end
end

local function drawStars(dt, boost)
  for _, s in ipairs(stars) do
    s.y = s.y + STAR_SPEED[s.l] * dt * boost
    if s.y >= H + 2 then s.y = -math.random() * 3; s.x = math.random(1, W) end
    local y = math.floor(s.y) + 1
    if s.x <= L.lw then
      setCell(s.x, y, ".", GRAY)
    elseif s.l == 1 then
      setCell(s.x, y, ".", GRAY)
    elseif s.l == 2 then
      setCell(s.x, y, G_DOT, LGRAY)
    else
      setCell(s.x, y - 2, "'", GRAY)
      setCell(s.x, y - 1, "|", GRAY)
      setCell(s.x, y, "*", WHITE)
    end
  end
end

-- ---------------------------------------------------------- player state
local S = {
  lists = nil, pl = nil, queue = nil, qi = 0, song = nil,
  data = nil, loading = false, err = nil, paused = false,
  startByte = 0, feedByte = 0, startTime = 0, pausePos = 0,
  gen = 0, trackId = 0, trackStart = 0,
  upNext = {},                      -- queued songs { pl, si } played before the shuffle continues
  curPl = nil, curSi = nil, fromQueue = false,
}
local UI = { view = "playlists", viewPl = nil, viewOrder = nil, lastPl = nil, scroll = 0, plScroll = 0, queueMode = false }
local hits, flash = {}, {}

local function stopSpeakers() for _, s in ipairs(speakers) do pcall(s.stop) end end
local function duration() return S.data and #S.data / 6000 or 0 end
local function position()
  if not S.data then return 0 end
  if S.paused then return S.pausePos end
  return math.min(duration(), S.startByte / 6000 + (now() - S.startTime))
end

local function beginAt(sec)
  sec = clamp(sec, 0, duration())
  S.startByte = math.floor(sec * 6000)
  S.feedByte, S.startTime, S.pausePos = S.startByte, now(), sec
  S.gen = S.gen + 1
  stopSpeakers(); wake()
end

local function seek(sec)
  if not S.data then return end
  sec = clamp(sec, 0, math.max(0, duration() - 0.5))
  if S.paused then S.pausePos = sec else beginAt(sec) end
end

local function togglePause()
  if not S.data then return end
  if S.paused then
    S.paused = false
    beginAt(S.pausePos)
  else
    S.pausePos = position()
    S.paused = true
    S.gen = S.gen + 1
    stopSpeakers(); wake()
  end
end

local function ensureVisible(i)
  if i <= UI.scroll or i > UI.scroll + L.rows then
    local n = UI.viewOrder and #UI.viewOrder or 0
    UI.scroll = clamp(i - 3, 0, math.max(0, n - L.rows))
  end
end

local function termStatus()
  term.setBackgroundColour(colors.black)
  term.clear(); term.setCursorPos(1, 1)
  term.setTextColour(colors.yellow); print("SPACE JUKEBOX")
  term.setTextColour(colors.white)
  if S.song then
    print("Now playing:"); print(" " .. S.song.title); print(" " .. S.song.artist)
  else
    print("Nothing playing")
  end
  print("")
  term.setTextColour(colors.lightGray)
  print("Space = pause   Left/Right = prev/next")
  print("Q = quit")
end

local function playSong(pl, si, fromQueue)
  S.song = S.lists[pl].songs[si]
  S.curPl, S.curSi, S.fromQueue = pl, si, fromQueue
  S.data, S.loading, S.err, S.paused, S.pausePos = nil, true, nil, false, 0
  S.trackId = S.trackId + 1
  S.trackStart = now()
  S.gen = S.gen + 1
  stopSpeakers()
  termStatus()
  wake()
end

local function playIndex(i)
  S.qi = i
  playSong(S.pl, S.queue[i], false)
  if UI.view == "songs" and UI.viewOrder == S.queue then ensureVisible(i) end
end

local function queuePos(pl, si)
  for i, e in ipairs(S.upNext) do if e.pl == pl and e.si == si then return i end end
end

local function toggleQueue(pl, si)
  local i = queuePos(pl, si)
  if i then table.remove(S.upNext, i) else S.upNext[#S.upNext + 1] = { pl = pl, si = si } end
  wake() -- lets the prefetcher grab the new next song
end

local function nextTrack()
  if not S.queue then return end
  if #S.upNext > 0 then
    local e = table.remove(S.upNext, 1)
    playSong(e.pl, e.si, true)
    return
  end
  local i = S.qi + 1
  if i > #S.queue then
    local q = shuffled(#S.lists[S.pl].songs, S.queue[#S.queue])  -- reshuffle, keep going
    if UI.viewOrder == S.queue then UI.viewOrder = q end
    S.queue, i = q, 1
  end
  playIndex(i)
end

local function prevTrack()
  if not S.queue then return end
  if S.data and position() > 3 then seek(0)
  elseif S.fromQueue then playIndex(S.qi)          -- back to the shuffle song before the queue
  elseif S.qi <= 1 then
    if S.data then seek(0) else playIndex(S.qi) end
  else
    playIndex(S.qi - 1)
  end
end

local function startPlaylist(p, order, index)
  S.pl, S.queue = p, order
  playIndex(index or 1)
end

local function openPlaylist(p)
  if S.pl == p then UI.viewOrder = S.queue
  elseif UI.viewPl ~= p or not UI.viewOrder then UI.viewOrder = shuffled(#S.lists[p].songs) end
  UI.viewPl, UI.lastPl, UI.view, UI.scroll = p, p, "songs", 0
  if S.pl == p then ensureVisible(S.qi)
  elseif not S.song then startPlaylist(p, UI.viewOrder, 1) end -- nothing playing yet: start it
end

-- ---------------------------------------------------------- downloading
local cache, inflight = {}, {}

local function fetch(file)
  inflight[file] = true
  local h, err = http.get(REPO .. file, nil, true)
  local data
  if h then data = h.readAll(); h.close() end
  inflight[file] = nil
  if data then cache[file] = data end
  os.queueEvent("jb_loaded")
  return data, err
end

local function getData(file)
  while inflight[file] do os.pullEventRaw("jb_loaded") end
  if cache[file] then return cache[file] end
  return fetch(file)
end

local function nextFile()
  local e = S.upNext[1]
  if e then return S.lists[e.pl].songs[e.si].file end
  if not S.queue or S.qi >= #S.queue then return nil end
  return S.lists[S.pl].songs[S.queue[S.qi + 1]].file
end

local function pruneCache()
  local keep = {}
  if S.song then keep[S.song.file] = true end
  local nf = nextFile(); if nf then keep[nf] = true end
  for k in pairs(cache) do if not keep[k] then cache[k] = nil end end
end

local function loadPlaylists()
  local h, err = http.get(REPO .. "playlists.json?t=" .. os.epoch("utc"))
  if not h then return nil, err end
  local txt = h.readAll(); h.close()
  local ok, data = pcall(textutils.unserializeJSON, txt)
  if not ok or type(data) ~= "table" then return nil, "playlists.json is not valid JSON" end
  local list = {}
  for name, songs in pairs(data) do
    local out = {}
    for _, s in ipairs(songs) do
      local title, artist = s.title or s.file, s.artist
      if not artist then
        local a, b = title:match("^(.*) %- (.-)$")
        if a then title, artist = a, b else artist = "" end
      end
      out[#out + 1] = { title = clean(title), artist = clean(artist), file = s.file }
    end
    if #out > 0 then list[#list + 1] = { name = clean(name), songs = out } end
  end
  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
  if #list == 0 then return nil, "No playlists in playlists.json" end
  return list
end

-- ---------------------------------------------------------- drawing
local function hit(id, x1, y1, x2, y2, fn)
  hits[#hits + 1] = { id = id, x1 = x1, y1 = y1, x2 = x2, y2 = y2, fn = fn }
end

local function flashing(id) return flash[id] and now() - flash[id] < 0.15 end

local function marquee(s, width, t)
  if #s <= width then
    local pad = math.floor((width - #s) / 2)
    return string.rep(" ", pad) .. s .. string.rep(" ", width - #s - pad)
  end
  local loop = s .. "     " .. G_DOT .. "     "
  local off = math.floor(math.max(0, t - 2) * 5) % #loop
  return (loop .. loop):sub(off + 1, off + width)
end

local function button(id, x1, y1, x2, y2, label, fg, bg, fn, enabled)
  if enabled == false then fg, bg = GRAY, PANEL end
  if flashing(id) then fg, bg = BLACK, WHITE end
  fill(x1, y1, x2, y2, bg)
  local cy = math.floor((y1 + y2) / 2)
  text(x1 + math.floor((x2 - x1 + 1 - #label) / 2), cy, label, fg, bg)
  if enabled ~= false then hit(id, x1, y1, x2, y2, fn) end
end

local function drawLeft()
  local lw = L.lw
  -- header with back / forward
  fill(1, 1, lw, L.hy2, PANEL)
  local inSongs = UI.view == "songs"
  button("back", 1, 1, 6, L.hy2, G_LEFT, YELLOW, inSongs and GRAY or PANEL,
    function() UI.view = "playlists" end, inSongs)
  button("fwd", lw - 5, 1, lw, L.hy2, G_RIGHT, YELLOW, (not inSongs and UI.lastPl) and GRAY or PANEL,
    function() if UI.lastPl then openPlaylist(UI.lastPl) end end, (not inSongs) and UI.lastPl ~= nil)
  local title = inSongs and S.lists[UI.viewPl].name:upper() or "PLAYLISTS"
  local tw = lw - 14
  if #title > tw then title = title:sub(1, tw - 2) .. ".." end
  text(math.floor((lw - #title) / 2) + 1, 2, title, YELLOW, PANEL)
  for x = 1, lw do setCell(x, 4, G_HLINE, YELLOW, BLACK) end

  local total, scroll, rowsPer
  if inSongs then
    local order, pl = UI.viewOrder, S.lists[UI.viewPl]
    total, rowsPer = #order, 1
    UI.scroll = clamp(UI.scroll, 0, math.max(0, total - L.rows))
    scroll = UI.scroll
    for r = 1, L.rows do
      local idx = scroll + r
      if idx > total then break end
      local y = L.ly1 + r - 1
      local song = pl.songs[order[idx]]
      local si = order[idx]
      local cur = (S.curPl == UI.viewPl and S.curSi == si)
      local qp = queuePos(UI.viewPl, si)
      if cur then fill(1, y, lw, y, HILITE) end
      local bg = cur and HILITE or nil
      text(1, y, cur and G_RIGHT or " ", YELLOW, bg)
      if qp then
        text(2, y, string.format("%3s ", "Q" .. qp), LBLUE, bg)
      else
        text(2, y, string.format("%3d ", idx), cur and YELLOW or GRAY, bg)
      end
      local room = lw - 5
      local t1 = song.title
      if #t1 > room then t1 = t1:sub(1, room - 2) .. ".." end
      text(6, y, t1, WHITE, bg)
      local rest = room - #t1
      if rest > 4 and song.artist ~= "" then
        local a = " - " .. song.artist
        if #a > rest then a = a:sub(1, rest - 2) .. ".." end
        text(6 + #t1, y, a, LGRAY, bg)
      end
      hit("song:" .. idx, 1, y, lw, y, function()
        if UI.queueMode and S.song then toggleQueue(UI.viewPl, si)
        else startPlaylist(UI.viewPl, order, idx) end
      end)
    end
  else
    total, rowsPer = #S.lists, 3
    local per = math.max(1, math.floor(L.rows / rowsPer))
    UI.plScroll = clamp(UI.plScroll, 0, math.max(0, total - per))
    scroll = UI.plScroll
    for r = 1, per do
      local i = scroll + r
      if i > total then break end
      local y = L.ly1 + (r - 1) * rowsPer
      local pl = S.lists[i]
      local cur = (S.pl == i)
      fill(1, y, lw, y + 1, cur and HILITE or PANEL)
      local bg = cur and HILITE or PANEL
      local name = pl.name
      if #name > lw - 4 then name = name:sub(1, lw - 6) .. ".." end
      text(2, y, (cur and G_RIGHT or " ") .. " " .. name, cur and YELLOW or WHITE, bg)
      text(4, y + 1, #pl.songs .. " songs" .. (cur and "  " .. G_DOT .. " playing" or ""), LGRAY, bg)
      hit("pl:" .. i, 1, y, lw, y + 1, function() openPlaylist(i) end)
    end
  end

  -- count + scroll buttons
  local per = inSongs and L.rows or math.max(1, math.floor(L.rows / 3))
  local first = math.min(total, scroll + 1)
  local last = math.min(total, scroll + per)
  local info, icol = first .. "-" .. last .. " of " .. total, GRAY
  if UI.queueMode then info, icol = "Tap songs to add/remove from queue", LBLUE end
  if #info > lw then info = "Tap to queue/unqueue" end
  text(math.floor((lw - #info) / 2) + 1, L.ly2 + 1, info, icol)
  local canUp, canDown = scroll > 0, scroll + per < total
  local function scrollBy(d)
    if inSongs then UI.scroll = UI.scroll + d else UI.plScroll = UI.plScroll + d end
  end
  local page = math.max(1, per - 2)
  local bw = math.floor((lw - 2) / 3)
  local qx1, qx2 = bw + 2, lw - bw - 1
  button("up", 1, L.fy1, bw, H, G_UP .. " UP", YELLOW, GRAY, function() scrollBy(-page) end, canUp)
  local qn = #S.upNext
  button("queue", qx1, L.fy1, qx2, H, (UI.queueMode and "QUEUE ON" or "QUEUE") .. (qn > 0 and " " .. qn or ""),
    UI.queueMode and BLACK or LBLUE, UI.queueMode and LBLUE or GRAY,
    function() UI.queueMode = not UI.queueMode end)
  button("down", qx2 + 2, L.fy1, lw, H, G_DOWN .. " DOWN", YELLOW, GRAY, function() scrollBy(page) end, canDown)
end

-- border split into a red half and a light-blue half chasing each other around the box
local function drawChaseBorder(x1, y1, x2, y2, t)
  -- thin lines drawn with teletext glyphs; inv = colour goes in the background
  local ring = {}
  local function add(x, y, ch, inv) ring[#ring + 1] = { x, y, ch, inv } end
  add(x1, y1, "\159", true)                                     -- top-left corner
  for x = x1 + 1, x2 - 1 do add(x, y1, "\143", true) end        -- top: bottom third
  add(x2, y1, "\144", false)                                    -- top-right corner
  for y = y1 + 1, y2 - 1 do add(x2, y, "\149", false) end       -- right: left half
  add(x2, y2, "\129", false)                                    -- bottom-right corner
  for x = x2 - 1, x1 + 1, -1 do add(x, y2, "\131", false) end   -- bottom: top third
  add(x1, y2, "\130", false)                                    -- bottom-left corner
  for y = y2 - 1, y1 + 1, -1 do add(x1, y, "\149", true) end    -- left: right half
  local n = #ring
  local head = math.floor(t * 22) % n           -- red half's front; blue fills the other half
  for i, c in ipairs(ring) do
    local col = ((head - i) % n) < n / 2 and RED or LBLUE
    if c[4] then setCell(c[1], c[2], c[3], BLACK, col) else setCell(c[1], c[2], c[3], col, BLACK) end
  end
end

local function drawTitle(t)
  fill(L.tx1 + 1, L.ty1 + 1, L.tx2 - 1, L.ty2 - 1, PANEL)
  drawChaseBorder(L.tx1, L.ty1, L.tx2, L.ty2, t)
  local iw, x0 = L.tw - 4, L.tx1 + 2
  local title, artist = "Nothing playing", "Pick a playlist to start"
  if S.song then title, artist = S.song.title, S.song.artist end
  local mt = t - S.trackStart
  text(x0, L.ty1 + 1, marquee(title, iw, mt), WHITE, PANEL)
  text(x0, L.ty1 + 2, marquee(artist, iw, mt), LGRAY, PANEL)
  local info, col
  if S.err then info, col = S.err, RED
  elseif S.loading then info, col = "Loading...", YELLOW
  elseif S.song then
    local sep = "  " .. G_DOT .. "  "
    if S.fromQueue then
      info = (S.paused and "PAUSED" or "FROM QUEUE") .. sep .. S.lists[S.curPl].name
    else
      info = (S.paused and "PAUSED" or "SHUFFLE") .. sep .. S.lists[S.pl].name .. sep .. S.qi .. "/" .. #S.queue
    end
    if #S.upNext > 0 then info = info .. sep .. #S.upNext .. " queued" end
    col = S.paused and YELLOW or MAGENTA
  else info, col = "", GRAY end
  if #info > iw then info = info:sub(1, iw) end
  text(x0 + math.floor((iw - #info) / 2), L.ty1 + 3, info, col, PANEL)
end

local function drawEQ()
  local eqH = L.ey2 - L.ey1 + 1
  local units = eqH * 3
  for k = 1, L.nb do
    local x = L.ex1 + (k - 1) * 3
    local filled = math.floor(shown[k] * units + 0.5)
    for r = 1, eqH do
      local u = filled - (r - 1) * 3
      if u <= 0 then break end
      local frac = r / eqH
      local col = frac <= 0.55 and GREEN or (frac <= 0.8 and YELLOW or RED)
      local y = L.ey2 - r + 1
      local ch = u >= 3 and " " or (u == 2 and G_TOP1 or G_TOP2)
      setCell(x, y, ch, BLACK, col); setCell(x + 1, y, ch, BLACK, col)
    end
    local p = math.floor(peaks[k] * units + 0.5)
    if p > filled + 1 then
      local y = L.ey2 - math.ceil(p / 3) + 1
      setCell(x, y, G_HLINE, LGRAY); setCell(x + 1, y, G_HLINE, LGRAY)
    end
  end
end

local function drawProgress()
  local y = L.py
  local pos, dur = position(), duration()
  local lt, rt = fmtTime(pos), fmtTime(dur)
  local bx1, bx2 = L.rx1 + 8, L.rx2 - 8
  local bw = bx2 - bx1 + 1
  text(bx1 - 2 - #lt, y, lt, WHITE)
  text(bx2 + 3, y, rt, LGRAY)
  local filled = dur > 0 and math.floor(pos / dur * bw + 0.5) or 0
  for i = 1, bw do
    setCell(bx1 + i - 1, y, G_HLINE, i <= filled and MAGENTA or GRAY, BLACK)
  end
  if dur > 0 then setCell(clamp(bx1 + filled - 1, bx1, bx2), y, " ", WHITE, MAGENTA) end
  hit("seek", bx1, y - 1, bx2, y + 1, function(x)
    if dur > 0 then seek((x - bx1) / math.max(1, bw - 1) * dur) end
  end)
end

local function drawControls()
  local playing = S.data and not S.paused
  local btns = {
    { "prev", G_LEFT .. G_LEFT, 9, prevTrack },
    { "back5", "-5s", 9, function() seek(position() - 5) end },
    { "play", playing and "| |" or G_RIGHT, 11, togglePause },
    { "fwd5", "+5s", 9, function() seek(position() + 5) end },
    { "next", G_RIGHT .. G_RIGHT, 9, nextTrack },
  }
  local gap, total = 2, 0
  for _, b in ipairs(btns) do total = total + b[3] end
  total = total + gap * (#btns - 1)
  local x = L.cx - math.floor(total / 2)
  for _, b in ipairs(btns) do
    local isPlay = b[1] == "play"
    button(b[1], x, L.by1, x + b[3] - 1, L.by2, b[2], isPlay and WHITE or BLACK,
      isPlay and RED or LBLUE, b[4], S.song ~= nil)
    x = x + b[3] + gap
  end
end

local function draw(dt, t)
  fbClear()
  hits = {}
  local active = S.data and not S.paused and not S.loading
  if active then active = analyze(S.data, position()) end
  updateBars(dt, active)
  local bass = (shown[1] + shown[2] + shown[3] + shown[4]) / 4
  drawStars(dt, 1 + bass * 2.5)
  for y = 1, H do setCell(L.sep, y, G_VLINE, YELLOW, BLACK) end
  drawLeft()
  drawTitle(t)
  drawEQ()
  drawProgress()
  drawControls()
  present()
end

local function message(lines)
  fbClear()
  for i, s in ipairs(lines) do
    text(math.floor((W - #s) / 2) + 1, math.floor(H / 2) - 1 + i, s, i == 1 and YELLOW or WHITE)
  end
  present()
end

-- ---------------------------------------------------------- loops
local function waitWake(timeout)
  local id = os.startTimer(timeout)
  while true do
    local ev, p = os.pullEventRaw()
    if ev == "jb_wake" or (ev == "timer" and p == id) then break end
  end
  os.cancelTimer(id)
end

local function playAll(pcm, g)
  for _, spk in ipairs(speakers) do
    while not spk.playAudio(pcm, CFG.volume) do
      os.pullEventRaw()
      if S.gen ~= g then return false end
    end
    if S.gen ~= g then return false end
  end
  return true
end

local function audioLoop()
  local decoder, decGen = nil, -1
  while true do
    if S.loading and S.song then
      local id, song = S.trackId, S.song
      local data, err = getData(song.file)
      if S.trackId == id then
        S.loading = false
        if data and #data > 0 then
          S.data = data
          S.trackStart = now()
          beginAt(0)
        else
          S.err = "Couldn't load song (" .. tostring(err) .. ")"
          waitWake(3)
          if S.trackId == id then nextTrack() end
        end
      end
    elseif S.data and not S.paused and S.feedByte < #S.data then
      local g = S.gen
      if decGen ~= g then decoder = dfpwm.make_decoder(); decGen = g end
      local chunk = S.data:sub(S.feedByte + 1, S.feedByte + CFG.chunk)
      local pcm = decoder(chunk)
      if playAll(pcm, g) and S.gen == g then S.feedByte = S.feedByte + #chunk end
    elseif S.data and not S.paused then
      if position() >= duration() - 0.05 then nextTrack() else waitWake(0.1) end
    else
      waitWake(1)
    end
  end
end

local function prefetchLoop()
  while true do
    pruneCache()
    local nf = nextFile()
    if S.data and nf and not cache[nf] and not inflight[nf] then
      fetch(nf)
    else
      os.pullEventRaw("jb_wake")
    end
  end
end

local function renderLoop()
  local last = now()
  local timer = os.startTimer(0)
  while true do
    local _, id = os.pullEventRaw("timer")
    if id == timer then
      local t = now()
      draw(math.min(0.5, t - last), t)
      last = t
      timer = os.startTimer(CFG.frame)
    end
  end
end

local function handleTouch(x, y)
  for i = #hits, 1, -1 do
    local h = hits[i]
    if x >= h.x1 and x <= h.x2 and y >= h.y1 and y <= h.y2 then
      flash[h.id] = now()
      h.fn(x, y)
      return
    end
  end
end

local function inputLoop()
  while true do
    local ev, a, b, c = os.pullEventRaw()
    if ev == "terminate" then return
    elseif ev == "monitor_touch" and monByName[a] then handleTouch(b, c)
    elseif (ev == "monitor_resize" and monByName[a]) or ev == "peripheral" or ev == "peripheral_detach" then
      local old = #mons
      findMonitors()
      if #mons > 0 then
        applyPalette(); computeLayout(); setupBands(L.nb)
        if #mons ~= old or ev == "monitor_resize" then initStars() end
      end
    elseif ev == "key" then
      if a == keys.q then return
      elseif a == keys.space then togglePause()
      elseif a == keys.right then nextTrack()
      elseif a == keys.left then prevTrack() end
    end
  end
end

-- ---------------------------------------------------------- main
math.randomseed(os.epoch("utc"))
computeLayout()
setupBands(L.nb)
initStars()

local lists
while not lists do
  message({ "SPACE JUKEBOX", "Loading playlists..." })
  local err
  lists, err = loadPlaylists()
  if not lists then
    message({ "Couldn't load playlists", tostring(err), "Retrying in 10 seconds..." })
    sleep(10)
  end
end
S.lists = lists

if CFG.autoplay then
  local order = shuffled(#lists[1].songs)
  UI.viewPl, UI.viewOrder, UI.lastPl, UI.view = 1, order, 1, "songs"
  startPlaylist(1, order, 1)
else
  termStatus()
end

if _G.__JB_TEST then _G.__JB = { S = S, UI = UI, hits = function() return hits end, L = L } end

parallel.waitForAny(inputLoop, audioLoop, prefetchLoop, renderLoop)

-- cleanup
stopSpeakers()
for _, e in ipairs(mons) do
  for i = 0, 15 do
    local c = 2 ^ i
    e.p.setPaletteColour(c, term.nativePaletteColour(c))
  end
  e.p.setBackgroundColour(colors.black)
  e.p.clear()
end
term.setTextColour(colors.white)
term.clear(); term.setCursorPos(1, 1)
print("Jukebox stopped.")
