-- Space Jukebox launcher: grabs the newest jukebox.lua from GitHub,
-- then runs it. If it crashes, it restarts after 5 seconds.
local URL = "https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-Music/main/jukebox.lua"

local function update()
  local h = http.get(URL .. "?t=" .. os.epoch("utc"))
  if not h then return false end
  local code = h.readAll()
  h.close()
  if not code or #code < 1000 or not load(code, "jukebox") then return false end
  local f = fs.open("jukebox.lua", "w")
  f.write(code)
  f.close()
  return true
end

while true do
  term.clear(); term.setCursorPos(1, 1)
  print("Checking for jukebox updates...")
  if update() then print("Up to date.") else print("Update failed, using saved copy.") end
  if not fs.exists("jukebox.lua") then
    print("No jukebox.lua yet. Retrying in 10s...")
    sleep(10)
  elseif shell.run("jukebox.lua") then
    break -- quit normally with Q
  else
    print("Jukebox crashed. Restarting in 5s (Ctrl+T to stop)...")
    sleep(5)
  end
end
