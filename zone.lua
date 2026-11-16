-- ============================================================
--  JUKEBOX ZONE  -  a second listening spot for the Space Jukebox
--  Its own computer + speaker(s) + monitor(s), linked by a wireless
--  (or ender) modem. Plays the same song in sync with the main
--  jukebox, and its buttons control the music everywhere.
--  Repo: TensorialRhyme5/Minecraft-Music
-- ============================================================

local REPO = "https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-Music/main/"
local PROTO = "spacejukebox"
local CFG = {
  textScale = 0.5,
  chunk     = 4 * 1024,
  syncTol   = 0.25,      -- seconds out of step before we jump back in line
  frame     = 0.1,
}
local SAVE = "zone_settings.txt"

local dfpwm = require("cc.audio.dfpwm")

-- ---------------------------------------------------------- devices
local mons, monByName = {}, {}
local function findMonitors()
  mons, monByName = {}, {}
  for _, m in ipairs({ peripheral.find("monitor") }) do
    if m.isColour() then
      m.setTextScale(CFG.textScale)
      local name = peripheral.getName(m)
      mons[#mons + 1] = { p = m, name = name, last = {} }
      monByName[name] = true
    end
  end
end
findMonitors()
if #mons == 0 then error("No advanced monitor found.", 0) end
local speakers = { peripheral.find("speaker") }

local netOn = false
local function openNet()
  netOn = false
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" and pcall(rednet.open, name) then netOn = true end
  end
end
openNet()

local PAL = {
  [colors.black] = 0x05060f, [colors.brown] = 0x15162e, [colors.blue] = 0x2c2f72,
  [colors.gray] = 0x4a4e66, [colors.lightGray] = 0x9ea3c2, [colors.purple] = 0x9b5cff,
  [colors.magenta] = 0xff4fa3, [colors.lime] = 0x7ed957, [colors.lightBlue] = 0x38c6ff,
  [colors.green] = 0x2ee05a, [colors.yellow] = 0xffd23f, [colors.red] = 0xff3b3b,
  [colors.cyan] = 0x38e0d0, [colors.orange] = 0xff9a3a,
}
local function applyPalette() for _, e in ipairs(mons) do for c, v in pairs(PAL) do e.p.setPaletteColour(c, v) end end end
applyPalette()
local WHITE, ORANGE, MAGENTA, LBLUE, YELLOW, LIME = "0", "1", "2", "3", "4", "5"
local GRAY, LGRAY, CYAN, PURPLE, HILITE, PANEL, GREEN, RED, BLACK = "7", "8", "9", "a", "b", "c", "d", "e", "f"
local G_RIGHT, G_LEFT = "\16", "\17"

-- ---------------------------------------------------------- helpers
local function now() return os.epoch("utc") / 1000 end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function clean(s)
  s = tostring(s or "")
  s = s:gsub("\226\128[\152\153]", "'"):gsub("\226\128[\156\157]", '"')
  return (s:gsub("[\192-\255][\128-\191]*", "?"))
end
local function fmtTime(sec) sec = math.max(0, math.floor(sec)); return string.format("%d:%02d", math.floor(sec / 60), sec % 60) end
local function fit(s, w) if #s > w then return s:sub(1, math.max(1, w - 1)) .. "." end return s end
local function shuffled(n)
  local t = {}
  for i = 1, n do t[i] = i end
  for i = n, 2, -1 do local j = math.random(1, i); t[i], t[j] = t[j], t[i] end
  return t
end

-- Mountain Time clock (same as the jukebox)
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
local function clockText()
  local utc = math.floor(os.epoch("utc") / 1000)
  local y = civil(math.floor(utc / 86400))
  local dst = utc >= nthSunday(y, 3, 2) * 86400 + 9 * 3600 and utc < nthSunday(y, 11, 1) * 86400 + 8 * 3600
  local t = utc + (dst and -6 or -7) * 3600
  local secs = t % 86400
  local hour = math.floor(secs / 3600)
  local h12 = hour % 12; if h12 == 0 then h12 = 12 end
  return string.format("%d:%02d %s", h12, math.floor(secs / 60) % 60, hour < 12 and "AM" or "PM")
end

-- ---------------------------------------------------------- settings (this zone's own volume)
local settings = { volume = 1.0 }
if fs.exists(SAVE) then
  local f = fs.open(SAVE, "r")
  local ok, d = pcall(textutils.unserialize, f.readAll()); f.close()
  if ok and type(d) == "table" and tonumber(d.volume) then settings.volume = clamp(tonumber(d.volume), 0, 3) end
end
local function saveSettings() local f = fs.open(SAVE, "w"); f.write(textutils.serialize(settings)); f.close() end

-- ---------------------------------------------------------- playlists (for names / Up Next / starting a list)
local lists = nil
local function loadPlaylists()
  local h = http.get(REPO .. "playlists.json?t=" .. os.epoch("utc"))
  if not h then return nil end
  local txt = h.readAll(); h.close()
  local ok, data = pcall(textutils.unserializeJSON, txt)
  if not ok or type(data) ~= "table" then return nil end
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
  return list
end

-- ---------------------------------------------------------- link to the main jukebox
local J = { st = nil, at = 0, id = nil }
local function online() return J.st ~= nil and now() - J.at < 4 end
local function send(msg)
  if not netOn then return end
  if J.id then pcall(rednet.send, J.id, msg, PROTO) else pcall(rednet.broadcast, msg, PROTO) end
end
local function masterPos()
  local st = J.st
  if not st or not st.title then return 0 end
  if st.anchor then return now() - st.anchor end
  local p = st.pos or 0
  if not st.paused and not st.loading then p = p + (now() - J.at) end
  return p
end

-- ---------------------------------------------------------- audio (plays in step with the jukebox)
local A = { file = nil, data = nil, want = nil, loading = false, err = nil,
            playing = false, startByte = 0, startTime = 0, feedByte = 0, gen = 0 }
local ring = {}                                  -- recent decoded audio, for the visualizer
local function wake() os.queueEvent("zone_wake") end
local function stopSpeakers() for _, s in ipairs(speakers) do pcall(s.stop) end end
local function duration() return A.data and #A.data / 6000 or 0 end
local function localPos() return A.startByte / 6000 + (now() - A.startTime) end
local function startAt(sec)
  sec = clamp(sec, 0, duration())
  A.startByte = math.floor(sec * 6000)
  A.feedByte, A.startTime = A.startByte, now()
  A.gen = A.gen + 1
  A.playing = true
  ring = {}
  stopSpeakers(); wake()
end
local function stopPlaying()
  if A.playing then A.playing = false; A.gen = A.gen + 1; stopSpeakers(); wake() end
end

-- compare with the jukebox and fix anything that's off
local function syncCheck()
  local st = J.st
  if not online() or not st.file or st.paused or st.loading or not st.anchor or st.power == false then
    stopPlaying(); return
  end
  if A.want ~= st.file then A.want = st.file; wake() end
  if A.file ~= st.file or not A.data then stopPlaying(); return end
  local mp = masterPos()
  if mp >= duration() - 0.05 then stopPlaying(); return end
  if not A.playing or math.abs(localPos() - mp) > CFG.syncTol then startAt(mp) end
end

local function waitWake(t)
  local id = os.startTimer(t)
  while true do
    local ev, p = os.pullEvent()
    if ev == "zone_wake" or (ev == "timer" and p == id) then break end
  end
  os.cancelTimer(id)
end

local function downloadLoop()
  while true do
    if A.want and A.want ~= A.file and not A.loading then
      local file = A.want
      A.loading, A.err = true, nil
      local h, err = http.get(REPO .. file, nil, true)
      local data
      if h then data = h.readAll(); h.close() end
      A.loading = false
      if A.want == file then
        if data and #data > 0 then A.file, A.data = file, data; syncCheck()
        else A.err = "download failed: " .. tostring(err) end
      end
    else
      waitWake(1)
    end
  end
end

local function playAll(pcm, g)
  local list = speakers
  local pending, left = {}, #list
  for i = 1, left do pending[i] = true end
  while true do
    for i, spk in ipairs(list) do
      if pending[i] then
        local ok, accepted = pcall(spk.playAudio, pcm, settings.volume)
        if not ok or accepted then pending[i] = false; left = left - 1 end
      end
    end
    if left == 0 then return true end
    os.pullEvent()
    if A.gen ~= g or speakers ~= list then return false end
  end
end

local function audioLoop()
  local decoder, decGen = nil, -1
  local lastResync = 0
  while true do
    if A.playing and A.data and A.feedByte < #A.data and #speakers > 0 then
      local g = A.gen
      local t = now()
      if A.feedByte > A.startByte and t - A.startTime > 1 and t - lastResync > 5 and localPos() > A.feedByte / 6000 + 0.05 then
        lastResync = t
        startAt(localPos())                           -- fell behind: catch up
        g = A.gen
      end
      if decGen ~= g then decoder = dfpwm.make_decoder(); decGen = g end
      local chunk = A.data:sub(A.feedByte + 1, A.feedByte + CFG.chunk)
      local pcm = decoder(chunk)
      ring[#ring + 1] = { s = A.feedByte * 8, pcm = pcm }
      if #ring > 4 then table.remove(ring, 1) end
      if playAll(pcm, g) and A.gen == g then A.feedByte = A.feedByte + #chunk end
    else
      waitWake(0.5)
    end
  end
end

-- loudness of the audio right around "now", for the bars
local function levelAt(sample, span)
  for _, r in ipairs(ring) do
    if sample >= r.s and sample < r.s + #r.pcm then
      local i0 = sample - r.s + 1
      local sum, n = 0, 0
      for i = i0, math.min(#r.pcm, i0 + span - 1), 4 do local v = r.pcm[i]; sum = sum + v * v; n = n + 1 end
      return n > 0 and math.sqrt(sum / n) / 128 or 0
    end
  end
  return 0
end

-- ---------------------------------------------------------- drawing
local W, H = math.huge, math.huge
local fbC, fbF, fbB = {}, {}, {}
local function measure()
  W, H = math.huge, math.huge
  for _, e in ipairs(mons) do local w, h = e.p.getSize(); W, H = math.min(W, w), math.min(H, h); e.last = {} end
  fbC, fbF, fbB = {}, {}, {}
  for y = 1, H do fbC[y], fbF[y], fbB[y] = {}, {}, {} end
end
measure()
local function clear() for y = 1, H do for x = 1, W do fbC[y][x], fbF[y][x], fbB[y][x] = " ", WHITE, BLACK end end end
local function setCell(x, y, ch, fg, bg)
  if x < 1 or x > W or y < 1 or y > H then return end
  fbC[y][x] = ch; if fg then fbF[y][x] = fg end; if bg then fbB[y][x] = bg end
end
local function text(x, y, s, fg, bg) for i = 1, #s do setCell(x + i - 1, y, s:sub(i, i), fg, bg) end end
local function center(y, s, fg, bg) text(math.floor((W - #s) / 2) + 1, y, s, fg, bg) end
local function fill(x1, y1, x2, y2, bg) for y = y1, y2 do for x = x1, x2 do setCell(x, y, " ", WHITE, bg) end end end
local function present()
  for y = 1, H do
    local c, f, b = table.concat(fbC[y]), table.concat(fbF[y]), table.concat(fbB[y])
    local key = c .. f .. b
    for _, e in ipairs(mons) do
      if e.last[y] ~= key then e.p.setCursorPos(1, y); e.p.blit(c, f, b); e.last[y] = key end
    end
  end
end

local hits, flash = {}, {}
local function hit(id, x1, y1, x2, y2, fn) hits[#hits + 1] = { id = id, x1 = x1, y1 = y1, x2 = x2, y2 = y2, fn = fn } end
local function button(id, x1, y1, x2, y2, label, fg, bg, fn)
  if flash[id] and now() - flash[id] < 0.15 then fg, bg = BLACK, WHITE end
  fill(x1, y1, x2, y2, bg)
  text(x1 + math.floor((x2 - x1 + 1 - #label) / 2), math.floor((y1 + y2) / 2), label, fg, bg)
  hit(id, x1, y1, x2, y2, fn)
end
local function marquee(s, w, t)
  if #s <= w then return s end
  local pad = s .. "   " .. s
  local off = math.floor(t * 4) % (#s + 3)
  return pad:sub(off + 1, off + w)
end

local bars, gain = {}, { peak = 0.05 }
local UI = { page = "main", plScroll = 0, songPl = nil, scroll = 0, qScroll = 0 }

local function drawMain(t)
  local st = J.st or {}
  local on = online()
  -- header
  fill(1, 1, W, 1, PANEL)
  text(2, 1, "JUKEBOX", YELLOW, PANEL)
  text(10, 1, "ZONE", LBLUE, PANEL)
  local clk = clockText()
  text(W - #clk, 1, clk, LGRAY, PANEL)
  -- now playing
  if not on then
    center(4, "Looking for the jukebox...", LGRAY)
    center(6, netOn and "(no signal - check range)" or "NO MODEM ATTACHED", netOn and GRAY or RED)
  elseif st.power == false then
    center(4, "Jukebox is turned off", LGRAY)
  elseif not st.title then
    center(4, "Nothing playing", LGRAY)
    center(5, "pick a playlist below", GRAY)
  else
    text(2, 3, marquee(st.title or "", W - 2, t), YELLOW)
    text(2, 4, fit(st.artist or "", W - 2), LGRAY)
    local plName = st.names and st.curPl and st.names[st.curPl] or ""
    local nxt = ""
    if lists then
      local up = st.upNext and st.upNext[1]
      if up and lists[up.pl] then nxt = lists[up.pl].songs[up.si].title
      elseif st.queue and st.qi and st.queue[st.qi + 1] and st.pl and lists[st.pl] then
        local s = lists[st.pl].songs[st.queue[st.qi + 1]]; nxt = s and s.title or ""
      end
    end
    text(2, 5, fit(plName, W - 2), PURPLE)
    if nxt ~= "" then text(2, 6, "Next: ", GRAY); text(8, 6, fit(nxt, W - 8), LGRAY) end
  end
  -- progress
  local dur = st.dur or 0
  local pos = clamp(masterPos(), 0, dur)
  local bx1, bx2 = 2, W - 1
  local bw = bx2 - bx1 + 1
  local filled = dur > 0 and math.floor(pos / dur * bw + 0.5) or 0
  for i = 1, bw do setCell(bx1 + i - 1, 8, "\140", i <= filled and LBLUE or GRAY, BLACK) end
  if dur > 0 then
    hit("seek", bx1, 8, bx2, 8, function(x) send({ cmd = "seek", sec = (x - bx1) / math.max(1, bw - 1) * dur }) end)
  end
  text(2, 9, fmtTime(pos), LGRAY)
  local d = fmtTime(dur); text(W - #d, 9, d, LGRAY)
  local stat = A.loading and "loading..." or (A.err and "load error" or (A.playing and "in sync" or (#speakers == 0 and "no speaker" or "")))
  center(9, stat, A.err and RED or (A.playing and GREEN or GRAY))
  -- visualizer (loudness over the last moment, scrolling)
  local vy1, vy2 = 11, 15
  local nb = W - 2
  local sample = math.floor(localPos() * 48000)
  local raw, top = {}, 0
  for i = 1, nb do
    raw[i] = A.playing and levelAt(sample - (nb - i) * 360, 360) or 0
    if raw[i] > top then top = raw[i] end
  end
  local mean = 0
  for i = 1, nb do mean = mean + raw[i] end
  mean = mean / nb
  gain.peak = math.max(0.02, gain.peak * 0.97 + mean * 0.03)    -- auto-gain follows the song's average loudness
  for i = 1, nb do
    local lv = clamp((raw[i] / gain.peak - 0.4) / 1.1, 0, 1)    -- average sits mid-height, peaks reach the top
    bars[i] = (bars[i] or 0) * 0.4 + math.min(1, lv) * 0.6
    local hgt = math.floor(bars[i] * (vy2 - vy1 + 1) * 3 + 0.5)
    for row = 0, vy2 - vy1 do
      local yy = vy2 - row
      local amt = hgt - row * 3
      local col = row >= 3 and MAGENTA or (row >= 2 and PURPLE or LBLUE)
      if amt >= 3 then setCell(1 + i, yy, " ", nil, col)
      elseif amt == 2 then setCell(1 + i, yy, "\140", col, BLACK)       -- partial block (top-heavy chars look odd; use lower bar)
      elseif amt == 1 then setCell(1 + i, yy, "_", col, BLACK) end
    end
  end
  -- controls
  local playing = st.title and not st.paused
  local cw = math.floor((W - 2 - 4) / 5)
  local ctl = {
    { "prev", G_LEFT .. G_LEFT, { cmd = "prev" } }, { "back10", "-10", { cmd = "skip", by = -10 } },
    { "play", playing and "| |" or G_RIGHT, { cmd = "toggle" } },
    { "fwd10", "+10", { cmd = "skip", by = 10 } }, { "next", G_RIGHT .. G_RIGHT, { cmd = "next" } },
  }
  for i, c in ipairs(ctl) do
    local x1 = 2 + (i - 1) * (cw + 1)
    local main = c[1] == "play"
    button(c[1], x1, 17, x1 + cw - 1, 19, c[2], main and BLACK or WHITE, main and LIME or GRAY, function() send(c[3]) end)
  end
  -- this zone's volume + playlists
  text(2, 21, "VOL", YELLOW)
  button("vdown", 6, 21, 8, 21, "-", WHITE, GRAY, function() settings.volume = clamp(settings.volume - 0.25, 0, 3); saveSettings() end)
  local vw = W - 19
  local vf = math.floor(settings.volume / 3 * vw + 0.5)
  for i = 1, vw do setCell(9 + i, 21, " ", nil, i <= vf and GREEN or PANEL) end
  local pct = math.floor(settings.volume * 100 + 0.5) .. "%"
  button("vup", W - 8, 21, W - 6, 21, "+", WHITE, GRAY, function() settings.volume = clamp(settings.volume + 0.25, 0, 3); saveSettings() end)
  text(W - #pct + 1, 21, pct, LGRAY)
  local half = math.floor((W - 3) / 2)
  button("lists", 2, 23, 1 + half, H, "PLAYLISTS", BLACK, PURPLE, function() UI.page = "lists"; UI.plScroll = 0 end)
  local nq = st.upNext and #st.upNext or 0
  button("upnext", 3 + half, 23, W - 1, H, "UP NEXT" .. (nq > 0 and (" (" .. nq .. ")") or ""), BLACK, LBLUE,
    function() UI.page = "queue"; UI.qScroll = 0 end)
end

-- ---------------------------------------------------------- queue helpers
local function queuePos(pl, si)
  local st = J.st
  for i, e in ipairs(st and st.upNext or {}) do if e.pl == pl and e.si == si then return i end end
end
-- tap a song: add it to / remove it from Up Next. If nothing is playing, start the list on it.
local function tapSong(pl, si)
  local st = J.st or {}
  if st.title then
    send({ cmd = "queue", pl = pl, si = si })
  else
    local order = shuffled(#lists[pl].songs)
    for i, v in ipairs(order) do if v == si then order[i], order[1] = order[1], order[i]; break end end
    send({ cmd = "play", pl = pl, order = order, idx = 1 })
    UI.page = "main"
  end
end
local function scrollButtons(idUp, idDown, get, set, maxScroll)
  local third = math.floor((W - 4) / 3)
  button(idUp, 2, H - 2, 1 + third, H, "\30 UP", WHITE, get() > 0 and GRAY or PANEL, function() set(math.max(0, get() - (H - 9))) end)
  button("back", 3 + third, H - 2, 2 + 2 * third, H, G_LEFT .. " BACK", BLACK, YELLOW, function()
    UI.page = UI.page == "songs" and "lists" or "main"
  end)
  button(idDown, 4 + 2 * third, H - 2, W - 1, H, "DOWN \31", WHITE, get() < maxScroll and GRAY or PANEL,
    function() set(math.min(maxScroll, get() + (H - 9))) end)
end

-- songs of one playlist: tap = queue it
local function drawSongs()
  local p = UI.songPl
  local pl = lists and lists[p]
  if not pl then UI.page = "lists"; return end
  local st = J.st or {}
  fill(1, 1, W, 1, PANEL)
  text(2, 1, fit(pl.name, W - 10), YELLOW, PANEL)
  local n = #pl.songs .. ""
  text(W - #n, 1, n, LGRAY, PANEL)
  button("shuffle", 2, 3, W - 1, 3, "SHUFFLE-PLAY THIS LIST", BLACK, PURPLE, function()
    send({ cmd = "play", pl = p, order = shuffled(#pl.songs), idx = 1 }); UI.page = "main"
  end)
  local y1, y2 = 5, H - 4
  local rows = y2 - y1 + 1
  local maxScroll = math.max(0, #pl.songs - rows)
  UI.scroll = clamp(UI.scroll, 0, maxScroll)
  for r = 1, rows do
    local si = UI.scroll + r
    local song = pl.songs[si]
    if not song then break end
    local y = y1 + r - 1
    local q = queuePos(p, si)
    local cur = st.curPl == p and st.curSi == si
    local bg = cur and HILITE or ((r % 2 == 0) and BLACK or PANEL)
    fill(2, y, W - 1, y, bg)
    local tag = q and ("Q" .. q) or (cur and G_RIGHT or "")
    text(2, y, tag, q and LBLUE or YELLOW, bg)
    text(5, y, fit(song.title, W - 6), cur and YELLOW or WHITE, bg)
    hit("song" .. si, 2, y, W - 1, y, function() tapSong(p, si) end)
  end
  center(H - 3, st.title and "tap a song to queue / unqueue it" or "tap a song to play it", GRAY)
  scrollButtons("sup", "sdown", function() return UI.scroll end, function(v) UI.scroll = v end, maxScroll)
end

-- what's queued up next: tap one to take it off
local function drawQueue()
  local st = J.st or {}
  fill(1, 1, W, 1, PANEL)
  text(2, 1, "UP NEXT", YELLOW, PANEL)
  local q = st.upNext or {}
  local y1, y2 = 3, H - 4
  local rows = y2 - y1 + 1
  local maxScroll = math.max(0, #q - rows)
  UI.qScroll = clamp(UI.qScroll, 0, maxScroll)
  if #q == 0 then
    center(5, "Nothing queued", LGRAY)
    center(7, "PLAYLISTS > pick a list >", GRAY)
    center(8, "tap songs to queue them", GRAY)
    -- after the queue, the shuffle continues:
    if lists and st.queue and st.pl and lists[st.pl] then
      center(11, "then the shuffle continues:", GRAY)
      for k = 1, 4 do
        local idx = st.queue[(st.qi or 0) + k]
        local s2 = idx and lists[st.pl].songs[idx]
        if s2 then text(3, 12 + k, fit(s2.title, W - 4), LGRAY) end
      end
    end
  else
    for r = 1, rows do
      local i = UI.qScroll + r
      local e = q[i]
      if not e then break end
      local y = y1 + r - 1
      local song = lists and lists[e.pl] and lists[e.pl].songs[e.si]
      local bg = (r % 2 == 0) and BLACK or PANEL
      fill(2, y, W - 1, y, bg)
      text(2, y, tostring(i), LBLUE, bg)
      text(5, y, fit(song and song.title or "?", W - 9), WHITE, bg)
      text(W - 2, y, "x", RED, bg)
      hit("q" .. i, 2, y, W - 1, y, function() send({ cmd = "queue", pl = e.pl, si = e.si }) end)
    end
    center(H - 3, "tap a song to remove it", GRAY)
  end
  scrollButtons("qup", "qdown", function() return UI.qScroll end, function(v) UI.qScroll = v end, maxScroll)
end

local function drawLists()
  fill(1, 1, W, 1, PANEL)
  text(2, 1, "PLAYLISTS", YELLOW, PANEL)
  local st = J.st or {}
  if not lists then
    center(5, "Loading playlists...", LGRAY)
  else
    local y = 3
    for p, pl in ipairs(lists) do
      if y + 2 > H - 4 then break end
      local cur = st.curPl == p
      button("pl" .. p, 2, y, W - 1, y + 2, "", WHITE, cur and HILITE or PANEL, function()
        UI.songPl, UI.scroll, UI.page = p, 0, "songs"
      end)
      text(4, y + 1, fit(pl.name, W - 14), cur and YELLOW or WHITE, cur and HILITE or PANEL)
      local n = #pl.songs .. " songs"
      text(W - 1 - #n, y + 1, n, LGRAY, cur and HILITE or PANEL)
      y = y + 4
    end
    center(H - 3, "tap one to see its songs", GRAY)
  end
  button("back", 2, H - 1, W - 1, H, G_LEFT .. " BACK", WHITE, GRAY, function() UI.page = "main" end)
end

local function draw(t)
  clear(); hits = {}
  if UI.page == "lists" then drawLists()
  elseif UI.page == "songs" then drawSongs()
  elseif UI.page == "queue" then drawQueue()
  else drawMain(t) end
  present()
end

local function termStatus()
  term.clear(); term.setCursorPos(1, 1)
  term.setTextColour(colors.yellow); print("JUKEBOX ZONE")
  term.setTextColour(colors.white)
  print("Monitors: " .. #mons .. "   Speakers: " .. #speakers)
  print("Modem: " .. (netOn and "open" or "NONE - attach a wireless modem"))
  print("Jukebox: " .. (online() and ("linked (#" .. tostring(J.id) .. ")") or "not heard from yet"))
  term.setTextColour(colors.lightGray)
  print("Hold Ctrl+T to stop.")
end

-- ---------------------------------------------------------- loops
local function netLoop()
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and c == PROTO and type(b) == "table" and b.type == "state" then
      local was = online()
      J.st, J.at, J.id = b, now(), a
      syncCheck()
      if not was then termStatus() end
    end
  end
end

local function uiLoop()
  local timer = os.startTimer(0)
  local lastHello, lastStatus = -100, now()
  while true do
    local ev, a, b, c = os.pullEventRaw()
    if ev == "terminate" then return
    elseif ev == "timer" and a == timer then
      local t = now()
      if not online() then
        if A.playing then stopPlaying() end
        if t - lastHello > 3 then lastHello = t; send({ cmd = "hello" }) end
      else syncCheck() end
      if t - lastStatus > 30 then lastStatus = t; termStatus() end
      draw(t)
      timer = os.startTimer(CFG.frame)
    elseif ev == "monitor_touch" and monByName[a] then
      for i = #hits, 1, -1 do
        local h = hits[i]
        if b >= h.x1 and b <= h.x2 and c >= h.y1 and c <= h.y2 then flash[h.id] = now(); h.fn(b, c); break end
      end
      draw(now())
    elseif ev == "peripheral" or ev == "peripheral_detach" or ev == "monitor_resize" then
      speakers = { peripheral.find("speaker") }
      openNet()
      findMonitors(); applyPalette(); measure()
      if A.playing then startAt(localPos()) end
      termStatus()
    end
  end
end

local function playlistLoop()
  while not lists do
    lists = loadPlaylists()
    if not lists then sleep(10) end
  end
  while true do os.pullEvent("zone_never") end
end

-- ---------------------------------------------------------- main
math.randomseed(os.epoch("utc"))
termStatus()
if _G.__JB_TEST then _G.__ZONE = { A = A, J = J, UI = UI, hits = function() return hits end, settings = settings }; _G.__JB = _G.__ZONE end
parallel.waitForAny(uiLoop, netLoop, audioLoop, downloadLoop, playlistLoop)

stopSpeakers()
for _, e in ipairs(mons) do
  for i = 0, 15 do e.p.setPaletteColour(2 ^ i, term.nativePaletteColour(2 ^ i)) end
  e.p.setBackgroundColour(colors.black); e.p.clear()
end
term.clear(); term.setCursorPos(1, 1); print("Jukebox zone stopped.")
