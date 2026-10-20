# GridFall @VERSION@

GridFall is a city builder where five AI mayors run the districts of one city. You walk the streets in first person, or run the city from above in the orbit builder.

## Requirements

- 64-bit Windows 10/11 or Linux (x86_64).
- A graphics card with Vulkan support and current drivers.
- About 750 MB of disk space after unzipping.

## Start the game

- **Windows:** unzip, then double-click `gridfall.exe`. The build is not code-signed, so Windows SmartScreen may warn; choose "More info", then "Run anyway".
- **Linux:** unzip, then run `./gridfall.x86_64`.
- Keep `gridfall.pck` in the same folder as the program; it holds all the game data.
- The first launch compiles shaders, so the first minute can stutter.

The game starts at street level. To play the orbit city builder with the full HUD, run `play-orbit.bat` (Windows) or `./play-orbit.sh` (Linux).

## Controls

- **On foot:** WASD or arrow keys to walk, Shift to run, Space to jump, Ctrl to crouch, mouse to look (click to capture the pointer), E to interact, F to get in or out of a car, M for the map, Enter to chat, V for third person, Tab for the city overview, `[` and `]` for time speed, T to skip to the next morning, Esc to pause, F1 to hide the HUD, F5 to save, F9 to load. A gamepad also works.
- **Driving:** W or the right trigger to accelerate, S or the left trigger to brake and reverse, A/D to steer, Space for the handbrake, V for the driver's view. Slow down to get out.
- **Orbit builder:** WASD to pan, mouse wheel to zoom, right-drag to rotate, C to recenter, Space to pause, 1-4 for speed, F5 to save, F9 to load.

## AI mayors

No account or key is needed. Out of the box the mayors replay real responses recorded from GMI Cloud models, and fall back to built-in planners when a recording does not fit.

To have the mayors think live, set a GMI Cloud API key before you start the game:

- Windows (Command Prompt): `set GMI_API_KEY=your-key` then `gridfall.exe`
- Linux: `GMI_API_KEY=your-key ./gridfall.x86_64`

The key stays on your machine and is only sent to `api.gmi-serving.com`.

## Saves and settings

The game saves your city every morning and when you close the window, and continues it the next time you start. F5 also saves at any time. To start over, open the pause menu (Esc) and press **New city** twice. The previous save is kept as `gridfall_save.json.bak` next to it.
- Windows: `%APPDATA%\Godot\app_userdata\GridFall — GMI Cloud Multi-Model Crisis Sim\`
- Linux: `~/.local/share/godot/app_userdata/GridFall — GMI Cloud Multi-Model Crisis Sim/`

Check a download against `SHA256SUMS.txt` on the release page.
