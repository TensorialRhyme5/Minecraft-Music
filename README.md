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

## CONTROL panel

Tap **CONTROL** on the jukebox screen (top left of the right side), on the remote (top right of the
Minecraft box), or the **CONTROL** tab on the pocket. Tap **MUSIC** to go back. The jukebox always
starts on the music screen.

It shows:
- Mountain Time, plus live weather for Herriman and Firestone
- Players online (names only), with a green dot for anyone within 64 blocks of the Player Detector
- In-game day, time and weather, and the server's TPS (20 = no lag)
- Storage: how full it is, item count, the last thing it did, and low-stock items
- Which devices are online (storage, crafter turtle, listening zone, remote)

Optional blocks on the jukebox computer's network (touching it, or on a wired modem):
- **Player Detector**: needed for the players list
- **Environment Detector**: needed for in-game rain/thunder

## Pairing (who can control the music)

Only paired devices can control the jukebox. Anyone can still *see* what's playing.

1. On the big screen: **CONTROL > PAIRING > NEW PAIRING CODE**. A code shows for 2 minutes.
2. Type it in:
   - **Remote / listening zone:** open that computer (right-click it) and type the code, then press Enter.
   - **Pocket:** open the MUSIC tab and type it there.
3. The PAIRING page lists every paired device with a **REMOVE** button.

## Search

- **Big screen:** tap **SEARCH** at the top of the playlists side and type on the tap keyboard.
- **Pocket:** MUSIC tab > **SEARCH**.

Tapping a song plays it if nothing is on; otherwise it goes into the queue (tap again to take it out).
