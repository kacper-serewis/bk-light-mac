# BK Light (macOS)

Native SwiftUI + CoreBluetooth app that drives four BK-Light `LED_BLE_*` 32×32 panels as a 2×2 wall:
the album cover of whatever plays on the Mac, screen colours, the Minecraft clock, weather, system
status, Home Assistant screens or Game of Life, picked by simple rules. Lives in the menu bar and
keeps running when the window is closed.

Protocol and clock logic are ported from `bk-light-app` (Tauri) and
[Bk-Light-AppBypass](https://github.com/kacper-serewis/Bk-Light-AppBypass) (`display_session.py`,
`watch_ha_media_or_clock.py`).

## Build

```sh
./scripts/build-app.sh          # → build/BK Light.app
./scripts/build-app.sh --install  # also copies it to /Applications
swift test                      # protocol, rendering and rule tests
```

The app is signed with the first "Apple Development" identity in the keychain (`SIGN_IDENTITY=…`
picks another, `SIGN_IDENTITY=-` signs ad-hoc). A real identity keeps macOS permissions (Bluetooth,
Screen Recording, Automation) across rebuilds; ad-hoc builds lose them every time.

## Setup

1. **Scan**, then use **Assign** to put each panel in its slot (top left, top right, …).
   macOS hides MAC addresses, so panels are remembered by their CoreBluetooth UUID instead.
2. Press **Identify panels**: each panel shows its number with a white bar on top. Adjust each
   slot's rotation until every number is upright. Defaults: 90° for the left column, 270° for the right,
   the same as `config.yaml`.
3. Choose the music source:
   - **Anything playing on this Mac** (default): Music, Spotify, browsers, Podcasts… via MediaRemote.
     Since macOS 15.4 only entitled processes may read it, so the bundled
     [mediaremote-adapter](ThirdParty/mediaremote-adapter) runs under `/usr/bin/perl`, which is.
   - **Spotify app (AppleScript)**: AppleScript plus Spotify's playback notifications. The first time,
     macOS asks for Automation permission.
   - **Home Assistant**: polls a `media_player` entity, so phones and speakers count too.
     The token is stored in the Keychain.
4. Turn on **Start at login** (in the window or the menu bar menu). Install to /Applications first, because
   the login item points to the app's location. When started at login, the app stays in the menu bar
   without opening its window.

## Behaviour

What the wall shows, first match wins:

1. **Identify panels** (8 s).
2. **Off** mode.
3. **Night schedule** (optional): wall off, or the clock only.
4. **Away** (screen locked, display asleep, screensaver, system sleep): wall off by default. Before
   system sleep the app holds sleep for up to 5 s so the black frame reaches the panels.
5. The chosen **mode**. Clock, screen colours, weather and system status can be pinned; **Automatic**
   goes through the "show while active" list in order (music while playing, screen colours while
   you use the Mac, 3D printer, washing machine, bins) and otherwise lets the enabled idle screens
   (clock, weather, system status, home, Game of Life) take turns.

Screens:

- **Music**: the cover is rendered at 64×64 and split into four 32×32 tiles (or the same 32×32 image
  on every panel with the "Same image" layout). It stays up for a grace period after pausing
  (4 s by default), so skipping tracks doesn't flash the next screen.
- **Clock**: the Minecraft clock, 64 frames a day, noon = frame 0. It dims at night (15 %) and peaks
  at 15:00.
- **Screen colours (ambilight)** captures the main display (Screen Recording permission) as a soft
  glow of averaged colours or as a mini mirror of the screen.
- **Weather**: icon, temperature and today's high/low from [Open-Meteo](https://open-meteo.com)
  (no key; the place is looked up by name), refreshed every 15 minutes.
- **System status**: CPU, memory and battery (or disk) with bars, plus two minutes of CPU history.
- **Game of Life** on a wrap-around 64×64 board, one generation per second; it reseeds when the
  board dies out, loops or reaches 500 generations.
- **Home Assistant** (URL + long-lived token; one `/api/states` poll every 10 s while used). Entities
  are found by name pattern:
  - *3D printer* (ha-bambulab `sensor.*_print_status`, `_print_progress`, `_remaining_time`,
    `image.*_cover_image`): model thumbnail, progress and time left while printing, DONE/FAIL for 15 min.
  - *Washing machine* (`sensor.*_machine_state` with a `run` option, `_job_state`, `_completion_time`):
    time left and phase, then KLAAR for 30 min.
  - *Bins* (`sensor.afvalbeheer_*_morgen` / `_vandaag`): tomorrow's bins from 17:00, today's until noon.
  - *Home* (`sensor.*p1_meter_power`, the first `climate.*` and its `_humidity` sensor): power use with a
    10-minute graph, indoor temperature and humidity.

Sending to the panels:

- Frames are only sent when the picture changes. Each panel uploads its newest tile on its own; after
  the frame ack it waits up to 250 ms for the panels uploading the same frame, so they validate
  (show it) together. Waiting longer makes a panel drop the frame (`05 00 01 80 03`) and ignore the
  next handshake. Newer frames replace ones still waiting.
- A panel gets the current picture again after reconnecting, and panels reconnect on their own when
  they come back on.
- Per frame: handshake → ack `0C 00 01 80 81…`, framed PNG (write-with-response) → ack `05 00 02 00 03`,
  then validation `05 00 00 01 00`. Frames over the 512-byte ATT limit (cover tiles are ~3 KB) are
  written in sequential 512-byte chunks.
- Debug logging: `log stream --level debug --predicate 'subsystem == "nl.serewis.bklight"'`.
