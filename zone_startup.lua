-- Jukebox ZONE launcher: grabs the newest zone.lua from GitHub,
-- then runs it. If it crashes, it restarts after 5 seconds.
local URL = "https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-Music/main/zone.lua"

local function update()
  local h = http.get(URL .. "?t=" .. os.epoch("utc"))
  if not h then return false end
  local code = h.readAll()
  h.close()
  if not code or #code < 1000 or not load(code, "zone") then return false end
  local f = fs.open("zone.lua", "w")
  f.write(code)
  f.close()
  return true
end

while true do
  term.clear(); term.setCursorPos(1, 1)
  print("Checking for zone updates...")
  if update() then print("Up to date.") else print("Update failed, using saved copy.") end
  if not fs.exists("zone.lua") then
    print("No zone.lua yet. Retrying in 10s...")
    sleep(10)
  elseif shell.run("zone.lua") then
    break -- stopped normally
  else
    print("Zone crashed. Restarting in 5s (Ctrl+T to stop)...")
    sleep(5)
  end
end
