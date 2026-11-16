# Minecraft-Music
## Listening zone (second spot, plays in sync)
A separate advanced computer with a **wireless (or ender) modem**, a speaker and one or more advanced monitors
(made for 2x2; every monitor shows the same screen). It plays the same song as the jukebox, in step, and its
buttons (prev / -10 / play-pause / +10 / next, seek bar, PLAYLISTS) control the music everywhere.
PLAYLISTS > a list shows its songs: tap one to add it to (or remove it from) Up Next; UP NEXT shows the queue.
The VOL slider only changes this zone's speaker. The main jukebox computer needs a wireless modem too.

```
wget https://raw.githubusercontent.com/TensorialRhyme5/Minecraft-Music/main/zone_startup.lua startup.lua
reboot
```
Wireless range is ~64 blocks near sea level, up to ~384 high up; use ender modems for longer distances.

The main jukebox screens and the 3x2 remote have a VOL bar (tap -/+ or anywhere on the bar) for the jukebox's speakers; it is remembered across reboots.
