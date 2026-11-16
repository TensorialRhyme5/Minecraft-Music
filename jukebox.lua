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

-- volume is saved so it survives reboots (the screens and remotes can change it)
local VOL_SAVE = "jukebox_volume.txt"
if fs.exists(VOL_SAVE) then
  local f = fs.open(VOL_SAVE, "r"); local v = tonumber(f.readAll()); f.close()
  if v then CFG.volume = math.max(0, math.min(3, v)) end
end
local function saveVolume() local f = fs.open(VOL_SAVE, "w"); f.write(tostring(CFG.volume)); f.close() end

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
-- recent audio the speakers were fed, reused by the equalizer (no second decode)
local pcmRing = {}
local function ringAdd(startSample, pcm)
  pcmRing[#pcmRing + 1] = { s = startSample, pcm = pcm }
  if #pcmRing > 6 then table.remove(pcmRing, 1) end
end
local function ringFind(i)
  for k = #pcmRing, 1, -1 do
    local c = pcmRing[k]
    if i >= c.s and i < c.s + #c.pcm then return c end
  end
end

local function analyze(pos)
  local first = math.max(0, math.floor(pos * 48000) - N / 2)
  local c = ringFind(first)
  if not c or not ringFind(first + N - 1) then return false end
  for i = 0, N - 1 do
    local si = first + i
    if si >= c.s + #c.pcm then c = ringFind(si); if not c then return false end end
    local r = rev[i]
    re[r] = c.pcm[si - c.s + 1] * hann[i]
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

local theme            -- defined with the background themes further down
local warpStars = {}
local function drawWarpStars(dt, boost)
  local cx, cy = (L.rx1 + L.rx2) / 2, H / 2
  if #warpStars == 0 then
    for i = 1, 130 do warpStars[i] = { a = math.random() * 2 * math.pi, d = math.random() * 40 } end
  end
  for _, s in ipairs(warpStars) do
    s.d = s.d + (1.5 + s.d * 1.4) * dt * boost
    local x = math.floor(cx + math.cos(s.a) * s.d * 1.6 + 0.5)
    local y = math.floor(cy + math.sin(s.a) * s.d + 0.5)
    if x < L.rx1 or x > W or y < 1 or y > H then
      s.a, s.d = math.random() * 2 * math.pi, math.random() * 2
    else
      local tx = math.floor(cx + math.cos(s.a) * (s.d - 1.2) * 1.6 + 0.5)
      local ty = math.floor(cy + math.sin(s.a) * (s.d - 1.2) + 0.5)
      if s.d < 6 then setCell(x, y, ".", GRAY)
      elseif s.d < 14 then setCell(tx, ty, ".", GRAY); setCell(x, y, G_DOT, LGRAY)
      else
        local ux = math.floor(cx + math.cos(s.a) * (s.d - 2.6) * 1.6 + 0.5)
        local uy = math.floor(cy + math.sin(s.a) * (s.d - 2.6) + 0.5)
        setCell(ux, uy, ".", GRAY); setCell(tx, ty, G_DOT, GRAY); setCell(x, y, "*", WHITE)
      end
    end
  end
end

local function drawStars(dt, boost)
  local th = theme()
  if th.stars == "none" then return end
  if th.stars == "warp" then drawWarpStars(dt, boost); return end
  boost = boost * (th.starSpeed or 1)
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
local UI = { screen = "jukebox", view = "playlists", viewPl = nil, viewOrder = nil, lastPl = nil, scroll = 0, plScroll = 0, queueMode = false, power = true }
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
  S.netDirty = true                     -- tell listening zones right away
  pcmRing = {}
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

-- ---------------------------------------------------------- Mountain Time clock + live weather (Open-Meteo, free, no key)
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
  local dst = utc >= nthSunday(y, 3, 2) * 86400 + 9 * 3600 and utc < nthSunday(y, 11, 1) * 86400 + 8 * 3600
  local t = utc + (dst and -6 or -7) * 3600
  local days = math.floor(t / 86400)
  local yy, mm, dd = civil(days)
  local secs = t - days * 86400
  local hour = math.floor(secs / 3600)
  local h12 = hour % 12; if h12 == 0 then h12 = 12 end
  return { month = mm, day = dd, wday = (days + 4) % 7, hour = hour, min = math.floor(secs / 60) % 60,
           sec = secs % 60, dst = dst, h12 = h12, ampm = hour < 12 and "AM" or "PM" }
end
local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function wxURL(lat, lon)
  return "https://api.open-meteo.com/v1/forecast?latitude=" .. lat .. "&longitude=" .. lon ..
    "&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min" ..
    "&temperature_unit=fahrenheit&timezone=America%2FDenver&forecast_days=1"
end
local CITIES = {
  { name = "HERRIMAN, UT", short = "Herriman", url = wxURL("40.5141", "-112.0330"), col = LBLUE },
  { name = "FIRESTONE, CO", short = "Firestone", url = wxURL("40.1125", "-104.9366"), col = RED },
}
for _, c in ipairs(CITIES) do c.at, c.pending, c.ok = -1e9, false, false end
local function wxFetch(t)
  for _, c in ipairs(CITIES) do
    if c.pending and t - c.at > 30 then c.pending = false; c.err = "no reply (timed out)" end
    if not c.pending and t - c.at >= (c.ok and 600 or 60) then   -- every 10 min (retry each minute until it works)
      c.pending, c.at = true, t
      local ok, res, why = pcall(http.request, c.url)
      if not ok or res == false then                           -- refused straight away (e.g. site not allowed)
        c.pending = false
        c.err = tostring(not ok and res or why or "request refused")
      end
    end
  end
end
local function wxResult(url, handle, why)
  for _, c in ipairs(CITIES) do
    if c.url == url then
      c.pending = false
      if not handle then c.err = tostring(why or "request failed") end
      if handle then
        local body = handle.readAll()
        handle.close()
        local ok, data = pcall(textutils.unserializeJSON, body)
        if not (ok and type(data) == "table" and type(data.current) == "table") then c.err = "couldn't read weather data" end
        if ok and type(data) == "table" and type(data.current) == "table" then
          c.err = nil
          c.temp = tonumber(data.current.temperature_2m)
          c.code = tonumber(data.current.weather_code) or 0
          c.day = data.current.is_day == 1
          local d = type(data.daily) == "table" and data.daily or {}
          c.hi = type(d.temperature_2m_max) == "table" and tonumber(d.temperature_2m_max[1]) or nil
          c.lo = type(d.temperature_2m_min) == "table" and tonumber(d.temperature_2m_min[1]) or nil
          c.ok = c.temp ~= nil
        end
      end
      return true
    end
  end
end
-- WMO weather code -> short label, icon, icon colour
local function wxLook(code, day)
  if code == 0 then return day and "Sunny" or "Clear", day and "\15" or "\7", day and YELLOW or WHITE end
  if code <= 2 then return "Partly cloudy", day and "\15" or "\7", day and YELLOW or LGRAY end
  if code == 3 then return "Cloudy", "\22", LGRAY end
  if code == 45 or code == 48 then return "Fog", "=", LGRAY end
  if code >= 51 and code <= 57 then return "Drizzle", "\25", LBLUE end
  if (code >= 61 and code <= 67) or (code >= 80 and code <= 82) then return "Rain", "\25", LBLUE end
  if (code >= 71 and code <= 77) or code == 85 or code == 86 then return "Snow", "*", WHITE end
  if code >= 95 then return "Storm", "\19", YELLOW end
  return "--", "?", GRAY
end
local DEG = "\176"

-- ---------------------------------------------------------- pairing: only paired remotes / zones / pockets may control the music
local hit, button                     -- (defined further down; declared here so the pairing page can use them)
local SEC
do
local band, bor, bxor, bnot, rrot, rshift = bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.rrotate, bit32.rshift
local SHA_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local function sha256(msg)
  msg = tostring(msg)
  local len = #msg
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
  local bits = len * 8
  local hi = math.floor(bits / 4294967296)
  msg = msg .. string.char(
    band(rshift(hi, 24), 255), band(rshift(hi, 16), 255), band(rshift(hi, 8), 255), band(hi, 255),
    band(rshift(bits, 24), 255), band(rshift(bits, 16), 255), band(rshift(bits, 8), 255), band(bits, 255))
  local h0, h1, h2, h3, h4, h5, h6, h7 =
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = bor(a * 16777216, b * 65536, c * 256, d)
    end
    for i = 16, 63 do
      local s0 = bxor(rrot(w[i - 15], 7), rrot(w[i - 15], 18), rshift(w[i - 15], 3))
      local s1 = bxor(rrot(w[i - 2], 17), rrot(w[i - 2], 19), rshift(w[i - 2], 10))
      w[i] = band(w[i - 16] + s0 + w[i - 7] + s1, 0xffffffff)
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 0, 63 do
      local S1 = bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = band(h + S1 + ch + SHA_K[i + 1] + w[i], 0xffffffff)
      local S0 = bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = band(S0 + maj, 0xffffffff)
      h, g, f, e, d, c, b, a = g, f, e, band(d + t1, 0xffffffff), c, b, a, band(t1 + t2, 0xffffffff)
    end
    h0, h1, h2, h3 = band(h0 + a, 0xffffffff), band(h1 + b, 0xffffffff), band(h2 + c, 0xffffffff), band(h3 + d, 0xffffffff)
    h4, h5, h6, h7 = band(h4 + e, 0xffffffff), band(h5 + f, 0xffffffff), band(h6 + g, 0xffffffff), band(h7 + h, 0xffffffff)
  end
  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

  local FILE, ABC = "jukebox_pairing.txt", "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  SEC = { devices = {}, code = nil, until_ = 0, sha256 = sha256 }
  if fs.exists(FILE) then
    local f = fs.open(FILE, "r"); local ok, d = pcall(textutils.unserialize, f.readAll()); f.close()
    if ok and type(d) == "table" and type(d.devices) == "table" then SEC.devices = d.devices end
  end
  function SEC.save() local f = fs.open(FILE, "w"); f.write(textutils.serialize({ devices = SEC.devices })); f.close() end
  function SEC.newCode()
    local c = ""
    for _ = 1, 8 do local i = math.random(1, #ABC); c = c .. ABC:sub(i, i) end
    SEC.code, SEC.until_ = c, now() + 120
  end
  -- what gets signed (must match the remotes exactly)
  local function canon(m)
    local o = type(m.order) == "table" and table.concat(m.order, ",") or ""
    return table.concat({ tostring(m.cmd), tostring(m.pl or ""), tostring(m.si or ""), tostring(m.idx or ""), tostring(m.sec or ""),
      tostring(m.by or ""), tostring(m.vol or ""), o }, "|")
  end
  local function reply(to, m) if to then pcall(rednet.send, to, m, "spacejukebox") end end
  -- true = go ahead and run this command
  function SEC.gate(msg, from)
    local c = msg.cmd
    if c == "hello" then return true end                    -- just asks for the current state
    local dev = tonumber(msg.dev)
    if c == "pair" then
      local ok = SEC.code and now() < SEC.until_ and dev and msg.nonce
        and msg.proof == sha256(SEC.code .. "|jpair|" .. dev .. "|" .. tostring(msg.nonce))
      if ok then
        SEC.devices[dev] = { key = sha256(SEC.code .. "|jkey|" .. dev), ctr = 0,
          kind = tostring(msg.kind or "device"), label = type(msg.label) == "string" and msg.label or nil }
        SEC.code = nil
        SEC.save()
      end
      reply(from, { type = "jpaired", ok = ok and true or false, dev = dev,
        why = (not ok) and (SEC.code and now() < SEC.until_ and "wrong code" or "no code showing on the jukebox") or nil })
      return false
    end
    local r = dev and SEC.devices[dev]
    local why
    if not r then why = "not paired"
    elseif not tonumber(msg.ctr) or tonumber(msg.ctr) <= (r.ctr or 0) then why = "old or replayed command"
    elseif msg.mac ~= sha256(r.key .. "|" .. tostring(msg.ctr) .. "|" .. canon(msg)) then why = "bad signature" end
    if why then reply(from, { type = "jdenied", why = why, dev = dev }); return false end
    r.ctr = tonumber(msg.ctr)
    r.seen = now()
    if now() - (SEC.savedAt or 0) > 30 then SEC.savedAt = now(); SEC.save() end
    if type(msg.label) == "string" then r.label = msg.label end
    return true
  end
  function SEC.list()
    local ids = {}
    for id in pairs(SEC.devices) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
  end
end

local WEL, SOTD                        -- (filled in further down)
local queuePos, requestSong              -- (defined further down)
local P, pollWorld, tpsLoop, panelData, drawControl, screenButton
do
P = { storage = nil, storageAt = -1e9, seen = {}, players = nil, near = {}, hasDet = false, hasEnv = false, tps = nil }
local NEAR_RANGE = 64                       -- "near base" = within this many blocks of the Player Detector
local function fitT(s, w) s = tostring(s or ""); if w < 1 then return "" end if #s > w then return s:sub(1, math.max(1, w - 1)) .. "." end return s end
local function commasN(n) local s = tostring(math.floor(n or 0)); local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse(); return (r:gsub("^,", "")) end
pollWorld = function()
  local det = peripheral.find("player_detector") or peripheral.find("playerDetector")
  P.hasDet = det ~= nil
  if det then
    local ok, list = pcall(det.getOnlinePlayers)
    if ok and type(list) == "table" then
      local names = {}
      for _, n in pairs(list) do if type(n) == "string" then names[#names + 1] = n end end
      table.sort(names, function(a, b) return a:lower() < b:lower() end)
      P.players = names
    end
    local ok2, near = pcall(det.getPlayersInRange, NEAR_RANGE)
    P.near = {}
    if ok2 and type(near) == "table" then for _, n in pairs(near) do P.near[n] = true end end
  else
    P.players, P.near = nil, {}
  end
  local env = peripheral.find("environment_detector") or peripheral.find("environmentDetector")
  P.hasEnv = env ~= nil
  if env then
    local ok, r = pcall(env.isRaining); P.rain = ok and r or nil
    local ok2, th = pcall(env.isThunder); P.thunder = ok2 and th or nil
  else P.rain, P.thunder = nil, nil end
end
-- server speed: a 5 second timer takes longer than 5 real seconds when the server lags
tpsLoop = function()
  while true do
    local t0 = now()
    sleep(5)
    local dt = now() - t0
    if dt > 0 then P.tps = math.min(20, 100 / dt) end
  end
end
local function gameClock()
  local tm = os.time()
  local h = math.floor(tm); local m = math.floor((tm - h) * 60)
  local h12 = h % 12; if h12 == 0 then h12 = 12 end
  return string.format("%d:%02d %s", h12, m, h < 12 and "AM" or "PM"), os.day()
end
local function online(who) return now() - (P.seen[who] or -1e9) < 30 end
local function storageOK() return P.storage ~= nil and now() - P.storageAt < 20 end
-- everything the remote and pockets need to draw their CONTROL view
panelData = function()
  local mt = mountainTime()
  local wx = {}
  for i, c in ipairs(CITIES) do wx[i] = { name = c.short, ok = c.ok, temp = c.temp, code = c.code, day = c.day, hi = c.hi, lo = c.lo } end
  local gt, gd = gameClock()
  local players
  if P.players then
    players = {}
    for i, n in ipairs(P.players) do players[i] = { name = n, near = P.near[n] == true } end
  end
  return { type = "panel", clock = mt.h12 .. ":" .. string.format("%02d", mt.min) .. " " .. mt.ampm, tz = mt.dst and "MDT" or "MST",
    date = DAYS[mt.wday + 1]:sub(1, 3) .. ", " .. MONTHS[mt.month] .. " " .. mt.day, wx = wx,
    players = players, hasDet = P.hasDet, game = { time = gt, day = gd, rain = P.rain, thunder = P.thunder, hasEnv = P.hasEnv },
    tps = P.tps, storage = storageOK() and P.storage or nil,
    sotd = (function() local d = SOTD and SOTD.get(); return d and { title = d.title, artist = d.artist, pl = d.pl, si = d.si } end)(),
    dev = { storage = storageOK(), crafter = storageOK() and P.storage.crafter == true, zone = online("zone"), remote = online("remote") } }
end
local function tpsLook(tps)
  if not tps then return "checking...", GRAY end
  if tps >= 18 then return string.format("%.1f  smooth", tps), LIME end
  if tps >= 12 then return string.format("%.1f  a bit laggy", tps), YELLOW end
  return string.format("%.1f  very laggy", tps), RED
end
local function card(x1, y1, x2, y2, title, col)
  fill(x1, y1, x2, y2, PANEL)
  text(x1 + 1, y1, title, col, PANEL)
end
local function drawPairPage()
  local x1, x2 = L.rx1 + 1, W - 1
  local top, bottom = 5, L.py - 2
  card(x1, top, x2, bottom, "PAIRED DEVICES", YELLOW)
  text(x1 + 18, top, "only these can control the music", GRAY, PANEL)
  local ids = SEC.list()
  local y = top + 2
  if #ids == 0 then text(x1 + 2, y, "nothing paired yet", LGRAY, PANEL); y = y + 1 end
  for _, id in ipairs(ids) do
    if y > bottom - 9 then break end
    local d = SEC.devices[id]
    local kind = ({ remote = "Remote screen", zone = "Listening zone", pocket = "Pocket" })[d.kind] or d.kind
    text(x1 + 2, y, fitT(kind, 16), LBLUE, PANEL)
    text(x1 + 19, y, "#" .. id, GRAY, PANEL)
    if d.label then text(x1 + 26, y, fitT(d.label, 24), WHITE, PANEL) end
    button("jrm" .. id, x2 - 10, y, x2 - 2, y, "REMOVE", WHITE, RED, function()
      SEC.devices[id] = nil; SEC.save()
    end)
    y = y + 2
  end
  local cy = bottom - 7
  if SEC.code and now() < SEC.until_ then
    fill(x1 + 2, cy, x2 - 2, cy + 4, HILITE)
    text(x1 + 4, cy, "Type this on the device you're pairing:", LGRAY, HILITE)
    local shown = (SEC.code:sub(1, 4) .. "-" .. SEC.code:sub(5)):gsub(".", "%0 ")
    text(L.cx - math.floor(#shown / 2), cy + 2, shown, YELLOW, HILITE)
    text(x1 + 4, cy + 4, math.ceil(SEC.until_ - now()) .. "s left", LGRAY, HILITE)
  else
    SEC.code = nil
    text(x1 + 2, cy, "Remote / zone: type the code on that computer's keyboard", LGRAY, PANEL)
    text(x1 + 2, cy + 1, "Pocket: open the MUSIC tab and type it there", LGRAY, PANEL)
    button("jnew", x1 + 2, cy + 3, x1 + 24, cy + 5, "NEW PAIRING CODE", BLACK, LIME, function() SEC.newCode() end)
  end
  button("jback", x2 - 12, bottom - 2, x2 - 2, bottom - 1, G_LEFT .. " BACK", BLACK, YELLOW, function() UI.ctlPage = nil; SEC.code = nil end)
end

drawControl = function(t)
  if UI.ctlPage == "pair" then drawPairPage(); return end
  local x1, x2 = L.rx1 + 1, W - 1
  local top, bottom = 5, L.py - 2
  local gap = 2
  -- row 1: real time + the two towns
  local cw = math.floor((x2 - x1 + 1 - gap * 2) / 3)
  local rowH = 6
  local cx = x1
  local mt = mountainTime()
  card(cx, top, cx + cw - 1, top + rowH - 1, "MOUNTAIN TIME", YELLOW)
  text(cx + 2, top + 2, mt.h12 .. ":" .. string.format("%02d", mt.min) .. ":" .. string.format("%02d", mt.sec) .. " " .. mt.ampm, WHITE, PANEL)
  text(cx + 2, top + 3, mt.dst and "MDT (daylight time)" or "MST (standard time)", GRAY, PANEL)
  text(cx + 2, top + 4, DAYS[mt.wday + 1] .. ", " .. MONTHS[mt.month] .. " " .. mt.day, LGRAY, PANEL)
  for i, c in ipairs(CITIES) do
    cx = x1 + i * (cw + gap)
    card(cx, top, cx + cw - 1, top + rowH - 1, c.name, c.col)
    if c.ok then
      local label, icon, icol = wxLook(c.code, c.day)
      text(cx + 2, top + 2, icon, icol, PANEL)
      text(cx + 4, top + 2, math.floor(c.temp + 0.5) .. DEG .. "F", WHITE, PANEL)
      text(cx + 4, top + 3, fitT(label, cw - 5), LGRAY, PANEL)
      if c.hi and c.lo then text(cx + 2, top + 4, "High " .. math.floor(c.hi + 0.5) .. DEG .. "  Low " .. math.floor(c.lo + 0.5) .. DEG, GRAY, PANEL) end
    else
      text(cx + 2, top + 2, fitT(c.err or "loading weather...", cw - 3), c.err and RED or GRAY, PANEL)
    end
  end
  -- song of the day, in the gap under the top row
  local sd = SOTD and SOTD.get()
  if sd then
    local sy = top + rowH
    local label = "SONG OF THE DAY"
    text(x1 + 1, sy, label, YELLOW)
    local line = sd.title .. (sd.artist ~= "" and ("  -  " .. sd.artist) or "")
    text(x1 + #label + 3, sy, fitT(line, x2 - x1 - #label - 16), WHITE)
    button("sotd", x2 - 10, sy, x2, sy, S.song and "QUEUE IT" or "PLAY", BLACK, YELLOW, function() requestSong({ pl = sd.pl, si = sd.si }) end)
  end
  -- row 2: players | minecraft + devices
  local y2a = top + rowH + 1
  local stH = 6
  local y2b = bottom - stH - 1
  local hw = math.floor((x2 - x1 + 1 - gap) / 2)
  local px1, px2 = x1, x1 + hw - 1
  local n = P.players and #P.players or 0
  card(px1, y2a, px2, y2b, "PLAYERS ONLINE" .. (P.players and (" (" .. n .. ")") or ""), LBLUE)
  if not P.hasDet then
    text(px1 + 2, y2a + 2, "Place a Player Detector", LGRAY, PANEL)
    text(px1 + 2, y2a + 3, "on this computer's network", GRAY, PANEL)
  elseif n == 0 then
    text(px1 + 2, y2a + 2, "nobody online", GRAY, PANEL)
  else
    local rows = y2b - y2a - 1
    local colsN = (n > rows and hw >= 36) and 2 or 1
    local colW = math.floor((hw - 2) / colsN)
    local shownN = math.min(n, rows * colsN)
    if shownN < n then shownN = shownN - 1 end
    for i = 1, shownN do
      local name = P.players[i]
      local c = math.floor((i - 1) / rows)
      local yy = y2a + 1 + ((i - 1) % rows) + 1 - 1
      local xx = px1 + 2 + c * colW
      local near = P.near[name]
      setCell(xx, yy + 1 - 1, G_DOT, near and LIME or LBLUE, PANEL)
      text(xx + 2, yy, fitT(name, colW - (near and 8 or 3)), WHITE, PANEL)
      if near then text(xx + colW - 6, yy, "NEAR", LIME, PANEL) end
    end
    if shownN < n then text(px1 + 2, y2b, "+" .. (n - shownN) .. " more", GRAY, PANEL) end
  end
  local mx1, mx2 = px2 + 1 + gap, x2
  card(mx1, y2a, mx2, y2b, "MINECRAFT", LIME)
  local gt, gd = gameClock()
  local y = y2a + 2
  text(mx1 + 2, y, "Day " .. gd .. "   " .. gt, WHITE, PANEL); y = y + 1
  local wxs, wcol = "add an Environment Detector", GRAY
  if P.hasEnv then
    if P.thunder then wxs, wcol = "Thunderstorm", YELLOW elseif P.rain then wxs, wcol = "Raining", LBLUE else wxs, wcol = "Clear", WHITE end
  end
  text(mx1 + 2, y, "Weather ", LGRAY, PANEL); text(mx1 + 10, y, fitT(wxs, mx2 - mx1 - 11), wcol, PANEL); y = y + 1
  local ts, tcol = tpsLook(P.tps)
  text(mx1 + 2, y, "TPS     ", LGRAY, PANEL); text(mx1 + 10, y, ts, tcol, PANEL); y = y + 2
  text(mx1 + 1, y, "DEVICES", YELLOW, PANEL)
  button("jpair", mx2 - 10, y, mx2 - 1, y, "PAIRING", BLACK, YELLOW, function() UI.ctlPage = "pair" end)
  y = y + 1
  local devs = { { "Jukebox", true }, { "Storage", storageOK() }, { "Crafter", storageOK() and P.storage.crafter == true },
                 { "Listening zone", online("zone") }, { "Remote screen", online("remote") } }
  local dw = math.floor((mx2 - mx1 - 2) / 2)
  for i, d in ipairs(devs) do
    local xx = mx1 + 2 + ((i - 1) % 2) * dw
    local yy = y + math.floor((i - 1) / 2)
    if yy <= y2b then
      setCell(xx, yy, G_DOT, d[2] and LIME or RED, PANEL)
      text(xx + 2, yy, fitT(d[1], dw - 3), d[2] and WHITE or GRAY, PANEL)
    end
  end
  -- row 3: storage
  local sy1 = bottom - stH + 1
  card(x1, sy1, x2, bottom, "STORAGE", MAGENTA)
  local st = storageOK() and P.storage or nil
  if not st then
    text(x1 + 2, sy1 + 2, "waiting for the storage computer...", GRAY, PANEL)
  else
    -- 24-hour graph on the right: one column per hour, scaled to its own low/high
    local g = type(st.graph) == "table" and st.graph or {}
    local gw = 24
    local gx1 = x2 - gw - 1
    local ix2 = gx1 - 3                                  -- right edge of the text side
    text(gx1, sy1, "LAST 24 HOURS", LGRAY, PANEL)
    if #g >= 2 then
      local lo, hi = math.huge, -math.huge
      for _, v in ipairs(g) do lo = math.min(lo, v); hi = math.max(hi, v) end
      local span = math.max(1, hi - lo)
      local gh = bottom - sy1 - 1                        -- rows for the bars
      local units = gh * 3
      local off = gw - #g
      for i, v in ipairs(g) do
        local u = 1 + math.floor((v - lo) / span * (units - 1) + 0.5)
        local x = gx1 + off + i - 1
        for r = 1, gh do
          local left = u - (r - 1) * 3
          local y = bottom - r
          if left >= 3 then setCell(x, y, " ", WHITE, LBLUE)
          elseif left == 2 then setCell(x, y, G_TOP1, PANEL, LBLUE)     -- bottom two-thirds blue
          elseif left == 1 then setCell(x, y, G_TOP2, PANEL, LBLUE) end -- bottom third blue
        end
      end
      local diff = g[#g] - g[1]
      local ds = (diff >= 0 and "+" or "-") .. commasN(math.abs(diff))
      text(x2 - #ds, sy1, ds, diff >= 0 and LIME or RED, PANEL)
    else
      text(gx1, sy1 + 2, "building history...", GRAY, PANEL)
      text(gx1, sy1 + 3, "(a point every 10 min)", GRAY, PANEL)
    end
    -- today's total next to the title
    local td = "Today +" .. commasN(st.today or 0) .. " in"
    text(x1 + 10, sy1, td, LIME, PANEL)
    if (st.yesterday or 0) > 0 then text(x1 + 11 + #td, sy1, "(yesterday " .. commasN(st.yesterday) .. ")", GRAY, PANEL) end
    local pct = (st.slots or 0) > 0 and st.used / st.slots or 0
    local pctS = math.floor(pct * 100 + 0.5) .. "% full"
    local bw = ix2 - x1 - 3 - #pctS
    local f = math.floor(pct * bw + 0.5)
    for i = 1, bw do setCell(x1 + 1 + i, sy1 + 1, " ", WHITE, i <= f and (pct > 0.9 and RED or (pct > 0.75 and YELLOW or LIME)) or GRAY) end
    text(ix2 - #pctS + 1, sy1 + 1, pctS, WHITE, PANEL)
    text(x1 + 2, sy1 + 2, fitT(commasN(st.total) .. " items   " .. commasN(st.types) .. " kinds   " .. commasN(st.used) .. "/" .. commasN(st.slots) .. " slots", ix2 - x1 - 1), LGRAY, PANEL)
    text(x1 + 2, sy1 + 3, fitT(st.busy or st.smelt or st.msg or "", ix2 - x1 - 1), (st.busy or st.smelt) and YELLOW or WHITE, PANEL)
    local low = type(st.low) == "table" and st.low or {}
    if #low == 0 then text(x1 + 2, sy1 + 4, "Low stock: none", GRAY, PANEL)
    else
      local parts = {}
      for _, a in ipairs(low) do parts[#parts + 1] = a.name .. " " .. commasN(a.have) .. "/" .. commasN(a.limit) end
      text(x1 + 2, sy1 + 4, "Low stock:", RED, PANEL)
      text(x1 + 13, sy1 + 4, fitT(table.concat(parts, "   "), ix2 - x1 - 12), WHITE, PANEL)
    end
  end
  -- what's playing, just above the progress bar
  local np = S.song and (G_RIGHT .. " " .. S.song.title .. "  -  " .. S.song.artist) or "Nothing playing"
  text(L.cx - math.floor(math.min(#np, L.rw - 4) / 2), L.py - 1, fitT(np, L.rw - 4), S.song and WHITE or GRAY)
end
end

-- ---------------------------------------------------------- welcome back (chime + message) and song of the day
do
  -- Friends get "WELCOME BACK"; anyone else gets "VISITOR". The base is a box between two corners
  -- (x, y, z). Until it's filled in, anyone within FALLBACK blocks of the Player Detector counts.
  WEL = {
    BOX = { { x = 135, y = 76, z = -1155 }, { x = 146, y = 110, z = -1138 } },   -- the base (corners 146 89 -1155 / 135 89 -1138, down to y 76)
    FALLBACK = 40,
    FRIENDS = { TensorialRhyme5 = "TEN", Haydog098 = "Haydog098" },
    AWAY = 60,
    SHOW = 10,                        -- seconds the message stays up                        -- seconds someone must be gone before they're welcomed again
    inside = {}, lastSeen = {}, queue = {}, showUntil = 0, cur = nil,
  }
  function WEL.poll()
    local det = peripheral.find("player_detector") or peripheral.find("playerDetector")
    if not det then return end
    local ok, list
    if WEL.BOX then ok, list = pcall(det.getPlayersInCoords, WEL.BOX[1], WEL.BOX[2])
    else ok, list = pcall(det.getPlayersInRange, WEL.FALLBACK) end
    if not ok or type(list) ~= "table" then return end
    local t = now()
    local here = {}
    for _, n in pairs(list) do
      if type(n) == "string" then
        here[n] = true
        if not WEL.inside[n] and t - (WEL.lastSeen[n] or -1e9) > WEL.AWAY and WEL.started then
          WEL.queue[#WEL.queue + 1] = { name = n, friend = WEL.FRIENDS[n] ~= nil }
        end
        WEL.lastSeen[n] = t
      end
    end
    WEL.inside = here
    WEL.started = true                -- nobody gets welcomed just because the jukebox rebooted
  end
  -- ding-dong, made once: two bell notes with a few overtones, fading out (48 kHz, -128..127)
  local CH = { pcm = nil, pos = 0, on = false }
  local function makeChime()
    local rate, out = 48000, {}
    local notes = { { f = 1318.5, at = 0, len = 0.9 }, { f = 1046.5, at = 0.42, len = 1.3 } }
    local total = math.floor(rate * 1.75)
    for i = 1, total do out[i] = 0 end
    for _, nt in ipairs(notes) do
      local s0 = math.floor(nt.at * rate)
      local n = math.floor(nt.len * rate)
      local w = 2 * math.pi * nt.f / rate
      for k = 0, n - 1 do
        local env = math.exp(-k / (rate * 0.28)) * math.min(1, k / 120)
        local v = math.sin(w * k) + 0.35 * math.sin(2 * w * k) + 0.12 * math.sin(3.01 * w * k)
        local i = s0 + k + 1
        if i <= total then out[i] = out[i] + v * env * 44 end
      end
    end
    for i = 1, total do out[i] = math.floor(out[i] + 0.5) end
    return out
  end
  function WEL.chime() CH.pcm = CH.pcm or makeChime(); CH.pos, CH.on = 0, true; wake() end
  -- add the chime on top of a chunk of music
  function WEL.mix(pcm)
    if not CH.on then return end
    local c = CH.pcm
    for i = 1, #pcm do
      local v = c[CH.pos + i]
      if not v then break end
      local m = pcm[i] * 0.6 + v
      pcm[i] = m > 127 and 127 or (m < -128 and -128 or math.floor(m))
    end
    CH.pos = CH.pos + #pcm
    if CH.pos >= #c then CH.on = false end
  end
  function WEL.waiting() return CH.on end
  -- nothing playing: play the chime by itself
  function WEL.solo(play)
    while CH.on do
      local chunk = {}
      for i = 1, 16384 do local v = CH.pcm[CH.pos + i]; if not v then break end; chunk[i] = v end
      CH.pos = CH.pos + #chunk
      if #chunk == 0 or CH.pos >= #CH.pcm then CH.on = false end
      if #chunk > 0 then play(chunk, S.gen) end
    end
  end
  -- big message across the screens for 5 seconds
  function WEL.draw(t)
    if t >= WEL.showUntil then
      WEL.cur = table.remove(WEL.queue, 1)
      if WEL.cur then WEL.showUntil = t + WEL.SHOW; WEL.chime() end
    end
    local c = WEL.cur
    if not c or t >= WEL.showUntil then WEL.cur = nil; return end
    local bw, bh = math.min(W - 6, 70), 11
    local x1, y1 = math.floor((W - bw) / 2) + 1, math.floor((H - bh) / 2) + 1
    local x2, y2 = x1 + bw - 1, y1 + bh - 1
    local col = c.friend and LIME or YELLOW
    fill(x1 - 1, y1 - 1, x2 + 1, y2 + 1, col)
    fill(x1, y1, x2, y2, PANEL)
    local head = c.friend and "W E L C O M E   B A C K" or "V I S I T O R"
    local name = c.friend and WEL.FRIENDS[c.name] or c.name
    local big = name:upper():gsub(".", "%0 "):sub(1, -2)
    local cx = math.floor((x1 + x2) / 2)
    text(cx - math.floor(#head / 2), y1 + 2, head, col, PANEL)
    text(cx - math.floor(#big / 2), y1 + 5, big, WHITE, PANEL)
    local mt = mountainTime()
    local sub = c.friend and (mt.h12 .. ":" .. string.format("%02d", mt.min) .. " " .. mt.ampm .. "  -  good to see you!") or "someone is at the base"
    text(cx - math.floor(#sub / 2), y1 + 8, sub, LGRAY, PANEL)
    local left = math.max(0, math.min(1, (WEL.showUntil - t) / WEL.SHOW))
    for x = x1, x1 + math.floor((bw - 1) * left) do setCell(x, y2, " ", WHITE, col) end
  end

  -- song of the day: the same pick everywhere, changes at midnight Mountain Time
  SOTD = { day = nil, pick = nil }
  function SOTD.get()
    local mt = mountainTime()
    local key = mt.month .. "/" .. mt.day .. "/" .. (os.epoch("utc") > 0 and math.floor(os.epoch("utc") / 31557600000) or 0)
    if SOTD.day == key and SOTD.pick then return SOTD.pick end
    local all, seen = {}, {}
    for p, pl in ipairs(S.lists or {}) do
      for si, sg in ipairs(pl.songs) do
        if not seen[sg.file] then seen[sg.file] = true; all[#all + 1] = { pl = p, si = si, title = sg.title, artist = sg.artist } end
      end
    end
    if #all == 0 then return nil end
    local h = 5381
    for i = 1, #key do h = (h * 33 + key:byte(i)) % 2147483647 end
    SOTD.day, SOTD.pick = key, all[h % #all + 1]
    return SOTD.pick
  end
end

-- ---------------------------------------------------------- song search on the jukebox screen (tap keyboard)
local drawSearchLeft
do
  local KEYS = { "1234567890", "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM" }
  local function matches(q)
    local out, seen, words = {}, {}, {}
    for w in q:lower():gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then return out end
    for p, pl in ipairs(S.lists or {}) do
      for si, sg in ipairs(pl.songs) do
        local key = sg.file or (sg.title .. sg.artist)
        if not seen[key] then
          local hay = (tostring(sg.title) .. " " .. tostring(sg.artist)):lower()
          local ok = true
          for _, w in ipairs(words) do if not hay:find(w, 1, true) then ok = false; break end end
          if ok then seen[key] = true; out[#out + 1] = { pl = p, si = si, song = sg } end
        end
      end
    end
    return out
  end
  drawSearchLeft = function()
    local lw = L.lw
    fill(1, 1, lw, L.hy2, PANEL)
    button("sback", 1, 1, 9, L.hy2, G_LEFT .. " BACK", YELLOW, GRAY, function() UI.view = "playlists" end)
    text(math.floor((lw - 6) / 2) + 3, 2, "SEARCH", YELLOW, PANEL)
    for x = 1, lw do setCell(x, 4, G_HLINE, YELLOW, BLACK) end
    local q = UI.sq or ""
    fill(1, 5, lw, 5, HILITE)
    text(2, 5, "> " .. q:sub(-(lw - 5)) .. "_", WHITE, HILITE)
    -- keyboard along the bottom: keys are 3 wide and 2 tall
    local kw = lw >= 31 and 3 or 2                     -- key width (narrow panels get smaller keys)
    local kbTop = H - 9
    local kx = math.floor((lw - kw * 10) / 2) + 1
    for r, row in ipairs(KEYS) do
      local y = kbTop + (r - 1) * 2
      local x0 = kx + math.floor((10 - #row) * kw / 2)
      for i = 1, #row do
        local ch = row:sub(i, i)
        local x = x0 + (i - 1) * kw
        button("k" .. ch, x, y, x + kw - 1, y + 1, ch, WHITE, (r + i) % 2 == 0 and GRAY or PANEL, function() UI.sq = (UI.sq or "") .. ch:lower(); UI.sScroll = 0 end)
      end
    end
    local y = kbTop + 8
    local kbw = kw * 10                                -- whole keyboard width
    local sp, dl = math.floor(kbw / 2), math.floor(kbw * 0.8)
    button("kspace", kx, y, kx + sp - 1, y + 1, "SPACE", WHITE, GRAY, function() UI.sq = (UI.sq or "") .. " " end)
    button("kdel", kx + sp, y, kx + dl - 1, y + 1, "DEL", BLACK, YELLOW, function() UI.sq = (UI.sq or ""):sub(1, -2); UI.sScroll = 0 end)
    button("kclr", kx + dl, y, kx + kbw - 1, y + 1, "CLR", WHITE, RED, function() UI.sq = ""; UI.sScroll = 0 end)
    -- results
    local res = matches(q)
    local ry1, ry2 = 7, kbTop - 3
    local rows = ry2 - ry1 + 1
    UI.sScroll = clamp(UI.sScroll or 0, 0, math.max(0, #res - rows))
    if q == "" then text(2, ry1, "tap letters to search all songs", GRAY)
    elseif #res == 0 then text(2, ry1, "no songs match", GRAY) end
    for r = 1, rows do
      local e = res[UI.sScroll + r]
      if not e then break end
      local yy = ry1 + r - 1
      local cur = S.curPl == e.pl and S.curSi == e.si
      local qp = queuePos(e.pl, e.si)
      local bg = cur and HILITE or nil
      if cur then fill(1, yy, lw, yy, HILITE) end
      text(1, yy, cur and G_RIGHT or (qp and ("Q" .. qp) or " "), cur and YELLOW or LBLUE, bg)
      local x = qp and 4 or 3
      local room = lw - x
      local t1 = e.song.title
      if #t1 > room then t1 = t1:sub(1, room - 2) .. ".." end
      text(x, yy, t1, WHITE, bg)
      local rest = room - #t1
      if rest > 4 and (e.song.artist or "") ~= "" then
        local a = " - " .. e.song.artist
        if #a > rest then a = a:sub(1, rest - 2) .. ".." end
        text(x + #t1, yy, a, LGRAY, bg)
      end
      hit("sres:" .. r, 1, yy, lw, yy, function()
        local i = queuePos(e.pl, e.si)
        if i then table.remove(S.upNext, i) else requestSong({ pl = e.pl, si = e.si }) end
      end)
    end
    -- scroll + count
    local info = #res > 0 and ((UI.sScroll + 1) .. "-" .. math.min(#res, UI.sScroll + rows) .. " of " .. #res) or ""
    text(math.floor((lw - #info) / 2) + 1, ry2 + 1, info, GRAY)
    button("sup", 1, ry2 + 1, 5, ry2 + 1, G_UP, YELLOW, GRAY, function() UI.sScroll = UI.sScroll - (rows - 2) end, UI.sScroll > 0)
    button("sdn", lw - 4, ry2 + 1, lw, ry2 + 1, G_DOWN, YELLOW, GRAY, function() UI.sScroll = UI.sScroll + (rows - 2) end, UI.sScroll + rows < #res)
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
  print("P = screen power on/off")
  print("Q = quit")
  -- time + weather on the computer's own screen
  local mt = mountainTime()
  print("")
  term.setTextColour(colors.white)
  print(string.format("%d:%02d %s %s  %s, %s %d", mt.h12, mt.min, mt.ampm, mt.dst and "MDT" or "MST",
    DAYS[mt.wday + 1], MONTHS[mt.month], mt.day))
  for _, c in ipairs(CITIES) do
    term.setTextColour(colors.lightGray)
    if c.ok then
      local label = wxLook(c.code, c.day)
      local hl = (c.hi and c.lo) and string.format("  H%d L%d", math.floor(c.hi + 0.5), math.floor(c.lo + 0.5)) or ""
      print(string.format("%-10s %d" .. DEG .. "F %s%s", c.short, math.floor(c.temp + 0.5), label, hl))
    else
      print(string.format("%-10s loading weather...", c.short))
      if c.err then term.setTextColour(colors.red); print("  error: " .. c.err) end
    end
  end
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

queuePos = function(pl, si)
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
-- a song asked for from a pocket: queue it next (or just play it if nothing is on)
requestSong = function(msg)
  local p, si = tonumber(msg.pl), tonumber(msg.si)
  local pl = p and S.lists[p]
  if not (pl and si and pl.songs[si]) then return end
  if S.song then
    if not queuePos(p, si) then S.upNext[#S.upNext + 1] = { pl = p, si = si }; wake() end
  else
    local order = shuffled(#pl.songs)
    local at = 1
    for k, v in ipairs(order) do if v == si then at = k end end
    startPlaylist(p, order, at)
  end
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
      out[#out + 1] = { title = clean(title), artist = clean(artist), file = s.file, bpm = tonumber(s.bpm), theme = s.theme }
    end
    if #out > 0 then list[#list + 1] = { name = clean(name), songs = out } end
  end
  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
  if #list == 0 then return nil, "No playlists in playlists.json" end
  return list
end

-- ---------------------------------------------------------- drawing
hit = function(id, x1, y1, x2, y2, fn)
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

button = function(id, x1, y1, x2, y2, label, fg, bg, fn, enabled)
  if enabled == false then fg, bg = GRAY, PANEL end
  if flashing(id) then fg, bg = BLACK, WHITE end
  fill(x1, y1, x2, y2, bg)
  local cy = math.floor((y1 + y2) / 2)
  text(x1 + math.floor((x2 - x1 + 1 - #label) / 2), cy, label, fg, bg)
  if enabled ~= false then hit(id, x1, y1, x2, y2, fn) end
end

local function drawLeft()
  if UI.view == "search" then drawSearchLeft(); return end
  local lw = L.lw
  -- header with back / forward
  fill(1, 1, lw, L.hy2, PANEL)
  local inSongs = UI.view == "songs"
  if inSongs then
    button("back", 1, 1, 6, L.hy2, G_LEFT, YELLOW, GRAY, function() UI.view = "playlists" end)
  else
    button("search", 1, 1, 8, L.hy2, "SEARCH", BLACK, LBLUE, function() UI.view = "search"; UI.sq = ""; UI.sScroll = 0 end)
  end
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
    if S.song.bpm then info = info .. sep .. S.song.bpm .. " BPM" end
    if #S.upNext > 0 then info = info .. sep .. #S.upNext .. " queued" end
    col = S.paused and YELLOW or MAGENTA
  else info, col = "", GRAY end
  if #info > iw then info = info:sub(1, iw) end
  text(x0 + math.floor((iw - #info) / 2), L.ty1 + 3, info, col, PANEL)
end

-- ---------------------------------------------------------- dim 3D shape behind the right-hand area
-- Uses the 3 colour slots the jukebox doesn't otherwise need (orange, pink, cyan) set to dark tints.
local BT = { bass = 0, beat = false, avg = 0, last = -10, scheme = 1, rings = {}, spin = 0 }
local BG_NEAR, BG_FAR, BG_RING = "1", "6", "9"
local BG_SCHEMES = {
  { 0x24406a, 0x142236, 0x2c5280 },   -- blue
  { 0x562450, 0x2a1428, 0x6a2c60 },   -- magenta
  { 0x584618, 0x2a2210, 0x6a5622 },   -- gold
  { 0x1e5030, 0x10281a, 0x266a3c },   -- green
  { 0x3a2a6a, 0x1c1638, 0x4a3682 },   -- purple
}
-- Background themes. Pick one per playlist with THEME_FOR (playlist name -> theme name).
local THEMES = {
  classic = { effect = "shape", shapes = { 1, 2, 3, 4, 5, 6 }, tints = BG_SCHEMES, stars = "fall", starSpeed = 1,
              beat = 1, rings = true, hold = 6, morph = 2, spin = 1 },
  chill   = { effect = "shape", shapes = { 3, 5, 2 }, stars = "fall", starSpeed = 0.5, beat = 0.5, rings = false,
              hold = 9, morph = 3, spin = 0.6,
              tints = { { 0x24406a, 0x142236, 0x2c5280 }, { 0x3a2a6a, 0x1c1638, 0x4a3682 }, { 0x1a4a50, 0x0e2628, 0x22606a } } },
  hype    = { effect = "shape", shapes = { 1, 6, 2 }, stars = "warp", starSpeed = 1, beat = 1.6, rings = true,
              hold = 3, morph = 1, spin = 1.6,
              tints = { { 0x6a2020, 0x351010, 0x803030 }, { 0x6a5218, 0x352a0c, 0x806420 }, { 0x6a3a14, 0x351c0a, 0x80481a } } },
  rain    = { effect = "rain", stars = "none", beat = 0.8,
              tints = { { 0x2a4a6a, 0x16263a, 0x346080 }, { 0x1e4a5a, 0x10262e, 0x286070 } } },
  waves   = { effect = "waves", stars = "fall", starSpeed = 0.4, beat = 1.2,
              tints = { { 0x5a2456, 0x2c1630, 0x3a2a6a }, { 0x3a2a6a, 0x1c1638, 0x24406a } } },
}
-- Each song's BPM (measured ahead of time, stored in playlists.json) picks its background.
local BPM_THEMES = {
  { 85, "rain" },      -- under 85 BPM: slow / slowed + reverb
  { 105, "chill" },    -- 85-104
  { 125, "waves" },    -- 105-124
  { 140, "classic" },  -- 125-139
  { math.huge, "hype" },
}
local THEME_FOR = {}     -- optional per-playlist override, e.g. THEME_FOR["Chill Vibes 2.0"] = "chill"
local THEME_CAP = {      -- highest background a playlist's songs may use (by BPM order above)
  ["Chill Vibes 2.0"] = "waves",
}
theme = function()
  local name = _G.__THEME
  local pl = S.lists and (S.curPl or S.pl) and S.lists[S.curPl or S.pl]
  if not name and pl then name = THEME_FOR[pl.name] end
  local cap = pl and THEME_CAP[pl.name]
  if not name and S.song and S.song.theme and THEMES[S.song.theme] then
    name = S.song.theme                          -- measured "feel" of the song (energy + BPM)
  elseif not name and S.song and S.song.bpm then
    for _, r in ipairs(BPM_THEMES) do
      name = r[2]
      if S.song.bpm < r[1] or name == cap then break end
    end
  end
  if name and cap then                           -- keep capped playlists calm
    local rank, capRank = 0, 0
    for i, r in ipairs(BPM_THEMES) do
      if r[2] == name then rank = i end
      if r[2] == cap then capRank = i end
    end
    if rank > capRank then name = cap end
  end
  return THEMES[name or "classic"] or THEMES.classic
end

local function beatTick(t)
  local playing = S.data and not S.paused and not S.loading
  local bass = 0
  if playing then bass = (levels[1] + levels[2] + levels[3] + levels[4]) / 4 end
  local beat = playing and bass > 0.3 and bass > BT.avg * 1.25 + 0.05 and t - BT.last > 0.25
  if beat then
    BT.last = t
    BT.scheme = BT.scheme % #theme().tints + 1
    BT.rings[#BT.rings + 1] = t
    if #BT.rings > 3 then table.remove(BT.rings, 1) end
  end
  BT.avg = BT.avg * 0.85 + bass * 0.15
  BT.bass, BT.beat = bass, beat
end

local function mix(c, k)   -- brighten a 0xRRGGBB colour by factor k
  local r, g, b = math.floor(c / 65536), math.floor(c / 256) % 256, c % 256
  return math.min(255, math.floor(r * k)) * 65536 + math.min(255, math.floor(g * k)) * 256 + math.min(255, math.floor(b * k))
end

local BG_NP = 500
local BG_SHAPES = {}
do
  local PHI = (1 + math.sqrt(5)) / 2
  local function norm(pts)
    local r = 0
    for _, v in ipairs(pts) do r = math.max(r, math.sqrt(v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2)) end
    for _, v in ipairs(pts) do v[1], v[2], v[3] = v[1] / r, v[2] / r, v[3] / r end
    table.sort(pts, function(a, b) return math.atan2(a[3], a[1]) + a[2] * 0.01 < math.atan2(b[3], b[1]) + b[2] * 0.01 end)
    return pts
  end
  local function edgeShape(verts)
    local best, edges = math.huge, {}
    local function d2(a, b) return (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2 end
    for i = 1, #verts do for j = i + 1, #verts do best = math.min(best, d2(verts[i], verts[j])) end end
    for i = 1, #verts do for j = i + 1, #verts do
      if math.abs(d2(verts[i], verts[j]) - best) < 1e-6 then edges[#edges + 1] = { verts[i], verts[j] } end
    end end
    local pts, per = {}, BG_NP / #edges
    for n = 0, BG_NP - 1 do
      local e = edges[math.floor(n / per) + 1]
      local f = (n % per) / per + 0.5 / per
      local a, b = e[1], e[2]
      pts[#pts + 1] = { a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f }
    end
    BG_SHAPES[#BG_SHAPES + 1] = norm(pts)
  end
  local function curveShape(fn)
    local pts = {}
    for n = 0, BG_NP - 1 do pts[#pts + 1] = fn(n) end
    BG_SHAPES[#BG_SHAPES + 1] = norm(pts)
  end
  local cube = {}
  for x = -1, 1, 2 do for y = -1, 1, 2 do for z = -1, 1, 2 do cube[#cube + 1] = { x, y, z } end end end
  edgeShape(cube)
  edgeShape({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } })
  curveShape(function(n)
    local ring, k = math.floor(n / 25), n % 25
    local u, v = ring / 20 * 2 * math.pi, k / 25 * 2 * math.pi
    return { (0.68 + 0.32 * math.cos(v)) * math.cos(u), 0.32 * math.sin(v), (0.68 + 0.32 * math.cos(v)) * math.sin(u) }
  end)
  local ico = {}
  for _, a in ipairs({ -1, 1 }) do for _, b in ipairs({ -PHI, PHI }) do
    ico[#ico + 1] = { 0, a, b }; ico[#ico + 1] = { a, b, 0 }; ico[#ico + 1] = { b, 0, a }
  end end
  edgeShape(ico)
  curveShape(function(n)
    local ring, a = math.floor(n / 167), (n % 167) / 167 * 2 * math.pi
    local c, s2 = math.cos(a), math.sin(a)
    if ring == 0 then return { c, s2, 0 } elseif ring == 1 then return { c, 0, s2 } else return { 0, c, s2 } end
  end)
  edgeShape({ { 1, 1, 1 }, { 1, -1, -1 }, { -1, 1, -1 }, { -1, -1, 1 } })
end
local BG_HOLD, BG_MORPH = 6, 2
local bgMorph = { from = 1, to = 1, start = -100, nextAt = 0 }

local rainDrops = {}
local function backgroundPixels(t, dt, th, pw, ph, pulse)
  local pix = {}
  local function plot(px, py, z)
    px, py = math.floor(px + 0.5), math.floor(py + 0.5)
    if px >= 0 and py >= 0 and px < pw and py < ph then
      local k = py * pw + px
      if not pix[k] or z < pix[k] then pix[k] = z end
    end
  end
  local beat = th.beat or 1
  if th.effect == "waves" then
    -- three soft waves whose height follows the bass
    for w = 0, 2 do
      local amp = ph * 0.07 * (1 + beat * (BT.bass * 2 + pulse))
      local base = ph * (0.32 + 0.18 * w)
      for x = 0, pw - 1 do
        local y = base + amp * math.sin(x * 0.045 * (1 + w * 0.35) + t * (1.1 + w * 0.5) + w * 2)
        plot(x, y, w == 0 and -1 or (w == 1 and 1 or 10))
      end
    end
  elseif th.effect == "rain" then
    -- diagonal streaks; heavier and faster on loud parts
    if #rainDrops == 0 then
      for n = 1, 110 do rainDrops[n] = { x = math.random() * pw, y = math.random() * ph, near = math.random() < 0.4 } end
    end
    local speed = 55 * (1 + beat * (BT.bass * 1.5 + pulse * 0.5))
    for _, d in ipairs(rainDrops) do
      local v = d.near and speed * 1.4 or speed
      d.y = d.y + v * dt; d.x = d.x - v * 0.35 * dt
      if d.y > ph or d.x < 0 then d.y = -math.random() * 10; d.x = math.random() * (pw + 20) end
      local len = d.near and 5 or 3
      for q = 0, len - 1 do plot(d.x + q * 0.35, d.y - q, d.near and -1 or 1) end
    end
  else
    -- warping wireframe shape
    local list = th.shapes or { 1, 2, 3, 4, 5, 6 }
    if bgMorph.list ~= list then bgMorph.list, bgMorph.i, bgMorph.from, bgMorph.to, bgMorph.start, bgMorph.nextAt = list, 1, list[1], list[1], -100, 0 end
    local hold, morphT = th.hold or BG_HOLD, th.morph or BG_MORPH
    if bgMorph.nextAt == 0 then bgMorph.nextAt = t + hold end
    if t >= bgMorph.nextAt then
      bgMorph.i = bgMorph.i % #list + 1
      bgMorph.from, bgMorph.to = bgMorph.to, list[bgMorph.i]
      bgMorph.start, bgMorph.nextAt = t, t + morphT + hold
    end
    local f = clamp((t - bgMorph.start) / morphT, 0, 1)
    local e = f * f * (3 - 2 * f)
    local A, B = BG_SHAPES[bgMorph.from], BG_SHAPES[bgMorph.to]
    BT.spin = BT.spin + BT.bass * 1.2 * beat * dt
    local spin = t * 0.6 * (th.spin or 1) + BT.spin
    local cx, sx, cy, sy = math.cos(spin * 0.9), math.sin(spin * 0.9), math.cos(spin * 1.3), math.sin(spin * 1.3)
    local scale = math.min(pw, ph) * 0.42 * 3.2 * (1 + 0.12 * math.sin(f * math.pi)) * (1 + beat * (0.1 * pulse + 0.05 * BT.bass))
    for i = 1, BG_NP do
      local a, b = A[i], B[i]
      local x = a[1] + (b[1] - a[1]) * e
      local y = a[2] + (b[2] - a[2]) * e
      local z = a[3] + (b[3] - a[3]) * e
      y, z = y * cx - z * sx, y * sx + z * cx
      x, z = x * cy + z * sy, -x * sy + z * cy
      local d = z + 3.2
      plot(pw / 2 + x * scale / d, ph / 2 + y * scale / d, z)
    end
  end
  if th.rings then
    for _, rt in ipairs(BT.rings) do
      local age = t - rt
      if age < 0.6 then
        local rad = math.min(pw, ph) * (0.3 + age * 1.2)
        for a = 0, 239 do
          local ang = a / 240 * 2 * math.pi
          local px = math.floor(pw / 2 + math.cos(ang) * rad * 1.15 + 0.5)
          local py = math.floor(ph / 2 + math.sin(ang) * rad + 0.5)
          if px >= 0 and py >= 0 and px < pw and py < ph and not pix[py * pw + px] then pix[py * pw + px] = 10 end
        end
      end
    end
  end
  return pix
end

local function drawBackShape(t, dt)
  local x1, y1 = L.rx1, 1                 -- the whole right-hand (red box) area
  local cw, ch = L.rw, H
  local pw, ph = cw * 2, ch * 3
  local th = theme()
  local pulse = math.exp(-(t - BT.last) * 6)
  local pix = backgroundPixels(t, dt, th, pw, ph, pulse)
  -- palette: dim tints, a little brighter right on the beat
  local tints = th.tints or BG_SCHEMES
  local sc = tints[(BT.scheme - 1) % #tints + 1]
  local k = 1 + 0.5 * pulse * (th.beat or 1)
  for _, m in ipairs(mons) do
    m.p.setPaletteColour(2 ^ 1, mix(sc[1], k))
    m.p.setPaletteColour(2 ^ 6, mix(sc[2], k))
    m.p.setPaletteColour(2 ^ 9, mix(sc[3], k))
  end
  for cyy = 0, ch - 1 do
    for cxx = 0, cw - 1 do
      local bits, zmin = 0, math.huge
      for sub = 0, 5 do
        local z = pix[(cyy * 3 + math.floor(sub / 2)) * pw + cxx * 2 + sub % 2]
        if z then bits = bits + 2 ^ sub; if z < zmin then zmin = z end end
      end
      if bits > 0 then
        local col = zmin >= 10 and BG_RING or (zmin < 0 and BG_NEAR or BG_FAR)
        if bits >= 32 then setCell(x1 + cxx, y1 + cyy, string.char(128 + (63 - bits)), BLACK, col)
        else setCell(x1 + cxx, y1 + cyy, string.char(128 + bits), col, BLACK) end
      end
    end
  end
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

local setVolume
setVolume = function(v)
  v = math.floor(clamp(v, 0, 3) * 20 + 0.5) / 20
  if v == CFG.volume then return end
  CFG.volume = v
  saveVolume()
  S.netDirty = true                     -- remotes / zones see it right away
end

-- volume bar on the row just above the play controls
local function drawVolume()
  local y = L.by1 - 1
  local pct = math.floor(CFG.volume * 100 + 0.5) .. "%"
  local bw = math.min(40, L.rw - 30)
  local total = 4 + 3 + 1 + bw + 1 + 3 + 1 + 4
  local x = L.cx - math.floor(total / 2)
  text(x, y, "VOL", YELLOW)
  button("vdown", x + 4, y, x + 6, y, "-", WHITE, GRAY, function() setVolume(CFG.volume - 0.1) end)
  local bx1 = x + 8
  local filled = math.floor(CFG.volume / 3 * bw + 0.5)
  for i = 1, bw do setCell(bx1 + i - 1, y, " ", WHITE, i <= filled and LIME or PANEL) end
  hit("vbar", bx1, y, bx1 + bw - 1, y, function(px) setVolume((px - bx1 + 1) / bw * 3) end)
  button("vup", bx1 + bw + 1, y, bx1 + bw + 3, y, "+", WHITE, GRAY, function() setVolume(CFG.volume + 0.1) end)
  text(bx1 + bw + 5, y, pct, LGRAY)
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

-- power: off = music stops and the screen goes fully dark; tap anywhere to turn it back on
local setPower            -- defined after the network code (it broadcasts state)
-- POWER button in the top-right corner, same spot whether the screen is on or dark
local function powerButton()
  local px1 = math.max(L.tx2 + 3, W - 8)
  if px1 + 4 > W then px1 = W - 8 end
  button("power", px1, 1, W, 3, "POWER", WHITE, RED, function() setPower(not UI.power) end)
end
local function drawOff()
  fbClear()
  hits = {}
  flash.power = nil                  -- the dark screen isn't redrawn, so don't leave a tap flash on it
  powerButton()
  present()
end

-- clock + weather strip under the controls (layout option A)
local function drawWeatherStrip()
  local y1, y2 = H - 1, H
  if y1 <= L.by2 then return end                       -- no room on very small monitors
  fill(L.rx1, y1, W, y2, PANEL)
  local mt = mountainTime()
  local x = L.rx1 + 2
  local tm = mt.h12 .. ":" .. string.format("%02d", mt.min) .. " " .. mt.ampm
  text(x, y1, tm, WHITE, PANEL)
  text(x + #tm + 1, y1, mt.dst and "MDT" or "MST", GRAY, PANEL)
  text(x, y2, DAYS[mt.wday + 1]:sub(1, 3) .. ", " .. MONTHS[mt.month] .. " " .. mt.day, LGRAY, PANEL)
  local colW = math.floor((W - (L.rx1 + 22)) / 2)
  for i, c in ipairs(CITIES) do
    local cx = L.rx1 + 22 + (i - 1) * colW
    text(cx, y1, c.name, c.col, PANEL)
    if c.ok then
      local label, icon, icol = wxLook(c.code, c.day)
      local wx = cx + #c.name + 2
      text(wx, y1, icon, icol, PANEL)
      local rest = math.floor(c.temp + 0.5) .. DEG .. "F " .. label
      local room = cx + colW - 2 - (wx + 2)
      if #rest > room then rest = rest:sub(1, room) end
      text(wx + 2, y1, rest, WHITE, PANEL)
      if c.hi and c.lo then
        text(cx, y2, "High " .. math.floor(c.hi + 0.5) .. DEG .. "  Low " .. math.floor(c.lo + 0.5) .. DEG, LGRAY, PANEL)
      end
    else
      if c.err then
        local e = c.err
        if #e > colW - 2 then e = e:sub(1, colW - 2) end
        text(cx, y2, e, RED, PANEL)
      else
        text(cx, y2, "loading weather...", GRAY, PANEL)
      end
    end
  end
end

-- ---------------------------------------------------------- CONTROL panel (base / server status)
-- P is filled from: the storage's status broadcast, a Player Detector, an Environment Detector
-- (both optional, on this computer's network), a tick-rate check, and the weather above.

-- CONTROL / MUSIC switch, top-left of the right side
screenButton = function()
  local x1 = L.rx1 + 1
  local x2 = math.min(x1 + 10, L.tx1 - 2)
  if x2 - x1 < 6 then x2 = x1 + 8 end
  local ctl = UI.screen == "control"
  button("screen", x1, 1, x2, 3, ctl and "MUSIC" or "CONTROL", ctl and BLACK or WHITE, ctl and LIME or PURPLE, function()
    UI.screen = ctl and "jukebox" or "control"
  end)
end

local function draw(dt, t)
  fbClear()
  hits = {}
  local active = S.data and not S.paused and not S.loading
  if active then active = analyze(position()) end
  updateBars(dt, active)
  local bass = (shown[1] + shown[2] + shown[3] + shown[4]) / 4
  drawStars(dt, 1 + bass * 2.5)
  beatTick(t)
  local ctl = UI.screen == "control"
  if not ctl then drawBackShape(t, dt) end       -- dim shape behind the whole right-hand area
  for y = 1, H do setCell(L.sep, y, G_VLINE, YELLOW, BLACK) end
  drawLeft()
  if ctl then
    local title = "CONTROL PANEL"
    text(L.cx - math.floor(#title / 2), 2, title, YELLOW)
    drawControl(t)
  else
    drawTitle(t)
    drawEQ()
  end
  drawProgress()
  drawVolume()
  drawControls()
  screenButton()
  powerButton()
  if not ctl then drawWeatherStrip() end
  WEL.draw(t)
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

-- Feed every speaker the same chunk in lockstep. Each wake-up tries ALL speakers
-- that still need the chunk, so no speaker sits empty waiting on another one
-- (that gap is what made multiple speakers drift apart).
local function playAll(pcm, g)
  local list = speakers
  local pending, left = {}, #list
  for i = 1, left do pending[i] = true end
  while true do
    for i, spk in ipairs(list) do
      if pending[i] then
        local ok, accepted = pcall(spk.playAudio, pcm, CFG.volume)
        if not ok or accepted then pending[i] = false; left = left - 1 end -- detached speakers are skipped
      end
    end
    if left == 0 then return true end
    os.pullEventRaw()
    if S.gen ~= g or speakers ~= list then return false end
  end
end

local function audioLoop()
  local decoder, decGen = nil, -1
  local lastResync = 0
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
      local t = now()
      -- If the computer fell behind and the speakers ran dry, they can drift apart.
      -- Restart them all together at the right spot (at most once every 5s).
      if S.feedByte > S.startByte and t - S.startTime > 1 and t - lastResync > 5
        and position() > S.feedByte / 6000 + 0.05 then
        lastResync = t
        S.resyncs = (S.resyncs or 0) + 1
        beginAt(position())
        g = S.gen
      end
      if decGen ~= g then decoder = dfpwm.make_decoder(); decGen = g end
      local chunk = S.data:sub(S.feedByte + 1, S.feedByte + CFG.chunk)
      local pcm = decoder(chunk)
      ringAdd(S.feedByte * 8, pcm)
      WEL.mix(pcm)
      if playAll(pcm, g) and S.gen == g then S.feedByte = S.feedByte + #chunk end
    elseif S.data and not S.paused then
      if position() >= duration() - 0.05 then nextTrack() else waitWake(0.1) end
    elseif WEL.waiting() then
      WEL.solo(playAll)
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

-- ---------------------------------------------------------- network (remote screens)
local PROTO = "spacejukebox"
local netOn = false
local function openNet()
  netOn = false
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if pcall(rednet.open, name) then netOn = true end
    end
  end
end

local function sendState()
  if not netOn then return end
  local names = {}
  for i, p in ipairs(S.lists or {}) do names[i] = p.name end
  pcall(rednet.broadcast, {
    type = "state", names = names,
    pl = S.pl, queue = S.queue, qi = S.qi, curPl = S.curPl, curSi = S.curSi,
    fromQueue = S.fromQueue, upNext = S.upNext,
    title = S.song and S.song.title, artist = S.song and S.song.artist,
    pos = position(), dur = duration(), paused = S.paused, loading = S.loading, err = S.err,
    -- for listening zones: which file is playing and the wall-clock time its 0:00 would have been
    file = S.song and S.song.file, track = S.trackId, power = UI.power, volume = CFG.volume,
    anchor = (S.data and not S.paused) and (S.startTime - S.startByte / 6000) or nil, sent = now(),
  }, PROTO)
end

local function sameOrder(a, b)
  if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function handleRemote(msg, from)
  if type(msg) ~= "table" then return end
  if type(msg.who) == "string" then P.seen[msg.who] = now() end
  if not SEC.gate(msg, from) then return end
  local c = msg.cmd
  if c == "toggle" then togglePause()
  elseif c == "next" then nextTrack()
  elseif c == "prev" then prevTrack()
  elseif c == "seek" and tonumber(msg.sec) then seek(tonumber(msg.sec))
  elseif c == "skip" and tonumber(msg.by) then seek(position() + tonumber(msg.by))
  elseif c == "volume" and tonumber(msg.vol) then setVolume(tonumber(msg.vol))
  elseif c == "request" then requestSong(msg)
  elseif c == "queue" and S.song then
    local p, si = tonumber(msg.pl), tonumber(msg.si)
    if p and si and S.lists[p] and S.lists[p].songs[si] then toggleQueue(p, si) end
  elseif c == "play" then
    local p, idx, order = tonumber(msg.pl), tonumber(msg.idx), msg.order
    local pl = p and S.lists[p]
    if not (pl and idx and type(order) == "table" and #order == #pl.songs and order[idx]) then return end
    if S.pl == p and sameOrder(order, S.queue) then
      playIndex(idx)
    else
      local copy = {}
      for i = 1, #order do copy[i] = tonumber(order[i]) or i end
      startPlaylist(p, copy, idx)
      if UI.viewPl == p then UI.viewOrder = S.queue end
    end
  end
  sendState()
end

-- bass level + simple beat detection for remote screens (sent ~10x a second)
local function sendBeat(t)
  if not netOn then return end
  pcall(rednet.broadcast, { type = "beat", bass = BT.bass, beat = BT.beat }, PROTO)
end

setPower = function(on)
  if UI.power == on then return end
  UI.power = on
  if not on then
    if S.data and not S.paused then togglePause() end
    drawOff()
  end
  sendState()
end

local function renderLoop()
  local last = now()
  local frames = 0
  local timer = os.startTimer(0)
  while true do
    local _, id = os.pullEventRaw("timer")
    if id == timer then
      local t = now()
      wxFetch(t)
      if UI.power then
        draw(math.min(0.5, t - last), t)
        sendBeat(t)
      end
      if frames % 300 == 0 then termStatus() end            -- refresh the computer's own screen every ~30s
      last = t
      frames = frames + 1
      if frames % 5 == 0 or S.netDirty then S.netDirty = false; sendState() end
      if frames % 30 == 0 then pollWorld() end
      if frames % 20 == 10 then WEL.poll() end
      if frames % 30 == 15 and netOn then pcall(rednet.broadcast, panelData(), PROTO) end
      timer = os.startTimer(CFG.frame)
    end
  end
end

local function handleTouch(x, y)
  -- while dark, only the POWER button responds (hits only holds that button)
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
    elseif ev == "monitor_touch" and monByName[a] then handleTouch(b, c); sendState()
    elseif ev == "rednet_message" and c == PROTO then handleRemote(b, a)
    elseif ev == "rednet_message" and c == "storagestat" and type(b) == "table" and b.type == "status" then
      P.storage, P.storageAt = b, now()
    elseif (ev == "http_success" or ev == "http_failure") and wxResult(a, ev == "http_success" and b or nil, ev == "http_failure" and b or nil) then
      termStatus()                                            -- weather arrived: refresh the computer's screen
    elseif (ev == "monitor_resize" and monByName[a]) or ev == "peripheral" or ev == "peripheral_detach" then
      if ev ~= "monitor_resize" then
        local found = { peripheral.find("speaker") }
        if #found ~= #speakers then
          speakers = found
          if S.data and not S.paused then beginAt(position()) end -- restart all speakers together
        end
      end
      openNet()
      local old = #mons
      findMonitors()
      if #mons > 0 then
        applyPalette(); computeLayout(); setupBands(L.nb)
        if #mons ~= old or ev == "monitor_resize" then initStars() end
      end
    elseif ev == "key" then
      if a == keys.q then return
      elseif a == keys.space then togglePause()
      elseif a == keys.p then setPower(not UI.power)
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

if _G.__JB_TEST then _G.__JB = { S = S, UI = UI, hits = function() return hits end, L = L, P = P, panelData = panelData, SEC = SEC } end

openNet()
pollWorld()
parallel.waitForAny(inputLoop, audioLoop, prefetchLoop, renderLoop, tpsLoop)

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
