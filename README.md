# GridFall — a SimCity-style city run by GMI Cloud AI

**GridFall** is a 3D SimCity-style city builder made with **Godot 4.7 (Forward+)**, **Blender**, **GMI Cloud** inference and **ACE-Step 1.5** audio. You don't build the city. Five autonomous AI mayors do, each running on a different GMI Cloud model. Every other layer of the city also has a GMI model behind it. You watch, inspect and intervene.

GridFall was built with [Factory](https://factory.ai)'s Droid coding agent, which wrote the Godot code, the Blender asset pipeline and the tests. Every mayor, resident and city agent runs on [GMI Cloud](https://www.gmicloud.ai) inference.

## The AI city

| Role | Model | What it does |
| --- | --- | --- |
| Mayor Argon-4 (NW Civic Campus) | `google/gemini-4-argon` | Utility-first planner |
| Mayor DeepSeek-V4 (NE Tech Corridor) | `deepseek-ai/DeepSeek-V4-Flash-0731` | Systems engineer |
| Mayor Kimi-K3 (Central Plaza) | `moonshotai/kimi-k3` | Coalition builder |
| Mayor Qwen-3.8 (SW Eco Quarter) | `Qwen/Qwen3.8-Max` | Fiscal pragmatist |
| Mayor Grok-4.5 (SE Boomtown) | `x-ai/grok-4.5` | Growth maximalist |
| Citizen Voices | `MiniMaxAI/MiniMax-M3` | Residents react to their real tile data |
| GridFall Gazette | `XiaomiMiMo/MiMo-V2.6-Flash` | Daily newspaper and editorial |
| Council Speaker | `openai/gpt-6-luna` | Rules on ordinances the mayors propose and vote on |
| Chaos Director | `deepseek-ai/DeepSeek-V4-Pro` | Picks disasters that test real weaknesses |
| Grid Operator | `google/gemini-3.8-flash` | Sets the power load-shedding priority |
| Street Inspector | `MiniMaxAI/MiniMax-M3` | Click any tile; whoever is standing there tells you what's wrong |

Once per in-game day, each mayor gets an ASCII map of its district, district and city stats, open lots, its open construction sites, land it can annex, yesterday's results, other mayors' posts, letters from its residents, the Gazette headline, open proposals and any player decree. It replies with JSON: a private thought, a public post, a mood, up to 7 actions (road, zone, build, bulldoze, taxes, emergency, grant, annex), an ordinance proposal and votes. The simulation checks every action and rejects invalid ones with a reason.

## Simulation

- **World:** the founding city is 32×32 tiles (x,y 0..31) with a river, forests and five districts, inside a 192×192 frontier (x,y -80..111) of unclaimed woods, lakes and the river. Mayors **annex** unclaimed 16×16 plots that border their district; each plot costs a little more than the last ($1500, then +$400). Surveyors map land up to two plots beyond claimed territory; the frontier past that sits under a haze that lifts as the city grows. Per-tick systems and most view passes only touch claimed land plus a 3-tile margin, trees are drawn in chunks that switch to low-poly stand-ins far from the camera, so the bigger world costs little. Saves from the old 96×96 world load into the same place in the bigger one.
- **Zoning:** R/C/I demand and density growth (levels 1–3). Growth depends on road access, power, water, land value and taxes.
- **Utilities:** a power network that flows through roads and buildings, with load shedding; coal, solar and wind power (wind is stronger near water or the map edge); water pumps (stronger near the river); sewage capacity; garbage collection through landfills (a waste shortage adds pollution and lowers happiness).
- **Services:** police, fire, hospital, school and parks, each with a coverage radius.
- **Big projects:** stadium (leisure coverage), train station (transit cuts traffic by up to 40%), university (wide school coverage), and airport (jobs plus commercial and industrial demand, but it pollutes). Each mayor has a favorite project once its city passes 900 residents.
- **City maps:** traffic, pollution, crime, land value and happiness.
- **Economy:** a budget for each district (taxes, upkeep, ordinance costs), plus 10 citywide ordinances.
- **Disasters:** 8 types (fire, blackout, sewage burst, gridlock, smog, earthquake, flood, tornado).
- **Staged construction:** see below.
- Time speeds: pause, 1x, 2x, 4x, 8x. A day waits for the mayors' GMI calls (up to 75s).
- Save and load to `user://gridfall_save.json` (atomic write, previous save kept as `.bak`). The game autosaves each morning and on quit, and continues the saved city on launch; `GRIDFALL_NEW_CITY=1` starts fresh.

## Residents

About 100 named residents (one per ~10 people) each have a job, skills, traits, a household, a home, savings and a memory. Their GMI minds (`scripts/ai/resident_minds.gd`, batched) decide each day whether to go to work, how to commute, where to spend, what to do in the evening (including helping neighbours or protesting at city hall) and whether to move away. Traffic, wages, sales tax and moods come from those decisions instead of fixed formulas.

Incidents (fires, broken water mains, downed power lines, crashes, quakes...) never end on a timer: they stay broken until residents with the right skills and paid city crews put in enough repair work. Residents write to their mayor, and the mayor reads those letters the next day. Click a person in the city, or use the People tab, to read their mind.

## Staged construction

Nothing appears instantly once people live in the city. Every build order opens a **construction site** (`+` on the AI map) that goes through stages:

| Site | Stages |
| --- | --- |
| Service buildings | clearing → excavation → foundation → frame → finishing (solar, wind and landfill skip excavation; parks are clearing → landscaping) |
| Zoned lots (private developers) | houses: foundation → frame → finishing; shops/factories: excavation → foundation → frame → finishing; towers rebuild from the foundation; smaller upgrades add a frame and facade around the building while people keep living there |
| Roads / bridges | clearing → grading → paving / piling → decking → paving |
| Demolition (bulldoze) | demolition → hauling (trees: clearing; rubble: hauling) |

The paid contractor puts `CREW_RATE` work points into every open site each tick (4 ticks a day). With contractors alone a park takes about a day, a road a day, a bridge 2.5 days, a police station 3, a hospital 4, a coal plant 9, a stadium 12 and an airport 15. Private developers take about 2 days for houses and 6 for a tower, and run at most `MAX_ZONE_SITES` (10) sites per district at once. Residents with construction skills (construction workers, civil engineers, electricians, water engineers) spend their working day on the nearest site; together they can add up to `HELPER_CAP` (60%) of a contractor shift per tick. They are paid a day rate, remember what they helped build, and show up in the tile inspector's crew list. A building does nothing until it is finished. Sites survive save/load.

Orders you place on foot from the phone go to your own two building crews instead of the contractors. A crew builds one order at a time in real time: 2 minutes for a park up to 5 for the airport at speed 1, and 10 seconds per road tile. A third order waits for the first crew to free up. You can watch them work on site: a foreman by the gate, two builders, and a hauler carrying crates from a pile to the work. A board over the gate names the crew, the order, the stage and the time left. They stand on the ground, among the rebar, on the slab and between the frame's columns, and on the scaffold once the building fills its lot. A crew that takes an order while you play walks in through the gate.

Progress shows continuously, not stage by stage: the view runs each site forward between ticks at its recent work rate, and each stage changes as work goes in. Trees come down and stumps are pulled, the pit widens and the spoil heaps grow, rebar goes in before the slab is poured across, the frame rises floor by floor, safety netting rolls up, asphalt is laid end to end, bridge piers rise, and demolished buildings sink into a growing rubble pile that is then hauled away.

The view draws each stage with a fenced dirt lot, an excavated pit with spoil heaps, a wet concrete slab with formwork and rebar, a rising concrete frame (floor by floor), scaffolding with safety netting around the finishing building, and a floodlight. Animated procedural machines work the sites: excavators, JCB-style backhoe loaders, tipping dump trucks, cement mixers with turning drums, tower cranes with slewing jibs and moving trolleys, bulldozers and road rollers.

Founding builds made before anyone lives in the city, and runs with residents off, are still instant. `CitySim.construction_mode` can force `"staged"` or `"instant"`.

## City life

- Zone lots pick from a library of houses, apartments, shops, offices, skyscrapers, warehouses and plants for each density level (`models/zones/<r|c|i><level>/`). Built lots get trees, benches, lamps, hydrants, planters, bins and billboards.
- Bus stops appear on straight roads next to homes and shops. Buses stop there and also run out of train stations.
- Delivery trucks run from industry, and garbage trucks from landfills.
- Every disaster sends a crew: fire trucks, ambulances and police drive the road network from the nearest station to the event with sirens flashing, stay until it ends, then leave.
- Boats sail the river. Airports run a plane that takes off, circles the city and lands again; hospitals get a circling helicopter when the model is present.
- Wind farm rotors spin and rooftop beacons blink.

## Rendering

- Realistic models in `models/real/` (zones, service buildings, roads, props, vehicles, people) are used whenever they exist, with the Kenney and earlier Blender models as fallbacks.
- HDRI sky that blends day, dusk and a procedural starry night; a 24-hour day/night cycle (`scripts/world/sky_director.gd`) drives the sun, fog, exposure, lit windows and street lamps with pools of light.
- PBR grass, dirt, asphalt and sidewalk (Poly Haven CC0), a water shader with moving normals and fresnel, ACES tonemapping, SSAO, SSIL, glow and aerial-perspective fog.
- Model materials are tuned at load: roofs, brick, concrete, plaster, stone, wood and paving are matte (the source textures marked them fully metallic, which made roofs mirror the sky), sheet metal is semi-matte, and glass and chrome keep a soft sheen.

## Player controls

`godot --path .` starts in **first person** at street level. Set `GRIDFALL_VIEW=orbit` to play the orbit city builder with the full HUD described below.

- **First person:** WASD or the arrow keys walk, Shift runs, mouse to look (click to capture the pointer), `]` and `[` change time speed (1x, 2x, 4x, 8x), `T` skips to the next morning, `Esc` pauses, `F1` hides the HUD, `F5` saves, `F9` loads. `F` by a car gets in: your character walks round to the driver's door, opens it, climbs in and shuts it (`F` on the way turns back). W/S throttle and brake or reverse, A/D steer, Space handbrake, V switches chase and driver view, and `F` again, once the car slows down, brakes to a stop and climbs out the same way. The car is solid: it bounces off walls, scrapes along them at a glance, shoves the cars it hits (they slide off, then pull back into their lane) and sends bins, benches, planters and other light street props flying. People it runs into stagger back, or go down when it is going fast. On foot, left click shoves whoever stands in front of you. Hold right click to put your guard up (fists up, the camera in closer), and left click then throws a jab and a cross in turn. A light blow makes people reel and step back. A hard one, the third punch in a row or a fast car knocks them down: they lie a while, get up, then shout at you, run off or walk back, and the people nearby who saw it run off or shout too. A resident who was hit remembers it and their mood drops (a shove least, a car most), and the ones who saw it remember it too. Floor someone or keep punching and the police drive out from the nearest station; someone a car knocks down gets an ambulance. The one who was hit and a witness say so in the chat, a crew called to the scene posts a City Alert card, and you hear each blow, swing and fall. `1`-`5` wave, nod, shake your head, shout and dance, and the people around answer. `B` opens the build phone: `1`-`6` pick road, homes, shops, industry, a building (mouse wheel picks which) or bulldoze, left click places on the tile ahead (roads and zones take a start and an end click), right click undoes the start. Each order is paid by the district that owns the land, as if its mayor had ordered it, and one of your two building crews builds it in real time (see Staged construction). The phone says how many crews are free and how long the order takes, a card under the top bar counts down your orders, and `E` on a worker gets a word about the job. The AI activity feed (top right) shows each mayor turn, council ruling, Chaos Director pick, grid order and Gazette front page as it lands. A card shows who decided, the model they run on, whether the answer came live, from a replay, from a fallback or from the offline planner, what they did and why. On foot the mayors take their turns spread over the day. A decision with a place raises a light beacon there. `J` cycles the feed between full, brief and hidden, and `G` routes the GPS to the newest decision with a place. Each of those decisions is also a lead for the Gazette, and you are its stringer: `K` takes the newest on assignment, and a card shows what happened, where and how far, and what the story still needs, while the GPS leads you to the scene. There, a reply from someone you talk to (or the answer when you ask someone here) is your quote. In photo mode (`P`), a click with the scene inside the viewfinder's marks is a press photo. `K` then files the story: the Gazette runs it in the chat, the person quoted remembers it, and it earns points towards the press ranks, with bonuses for a scoop (filed within a third of a day), a local voice and a sharp photo. A lead goes cold after a day. `L` opens the mayors' league: the five mayors ranked on people, jobs, approval and funds, each with the model they run on, your press card, the open leads (chase any of them) and your latest stories.

The orbit view (`GRIDFALL_VIEW=orbit`):

- **Top bar:** day, population, jobs, funds, happiness, the RCI demand meter, power/water/sewage load, GMI call status, speed, Save/Load/New, Live GMI toggle, Mute.
- **Overlays tab:** 3D data views for power, water, pollution, crime, land value, traffic, happiness, services and districts.
- **Disasters tab:** arm a disaster, then click the map. There is also a random target option and "Restore all".
- **Powers tab:** send a decree to all mayors, grant funds, and override ordinances.
- **Mayor cards (bottom):** click a card to focus that district and read its latest thought, post and action results.
- **Right panel:** Mayor, Gazette, City Hall (council, operator, chaos, citizens), Inspect, GMI Log, Feed.
- **Keys:** WASD pan, mouse wheel zoom, right-drag rotate, `C` recenter, `Space` pause, `1`–`4` speed, `Esc` cancel an armed disaster, `F5` save, `F9` load.

## GMI inference and fallbacks

`scripts/ai/gmi_client.gd` calls `https://api.gmi-serving.com/v1/chat/completions`. The API key comes from `GMI_API_KEY` or from the GMI entry in `~/.factory/settings.json`. Hybrid reasoning models get per-model settings so they answer instead of spending the whole token budget on reasoning: DeepSeek and Kimi get `thinking: disabled`, Qwen gets `enable_thinking: false`, and Grok gets `reasoning_effort: low`. A model that refuses the default temperature of 0.7 with an HTTP 400 (Kimi-K3 takes only 1) is tried again at once with 1 and keeps it for the session. Every failed live call prints one `GMI_FAIL <role>/<agent> on <model>: <error>` line to the output (scrubbed; never the prompt), so a run from the editor shows why replies fell back.

Each call falls back in this order:

1. Live GMI response.
2. Replay cache: real recorded responses in `data/gmi_replay_cache.json` (22 days are included), nearest day for the same agent.
3. Heuristic fallback for that role.

The source of every call (live, cache or heuristic) is shown on the mayor cards and in the GMI Log.

The replay cache was recorded before wind farms, landfills and the big projects existed. On a replayed day, a mayor therefore also borrows at most one of those builds from its heuristic planner, and only when the district can still afford it after the replayed actions.

```bash
GRIDFALL_OFFLINE=1   # never call GMI (replay cache + heuristics)
GRIDFALL_RECORD=1    # write live responses into data/gmi_replay_cache.json
GRIDFALL_SPEED=4     # starting game speed
GRIDFALL_RESIDENTS=0 # no AI residents (old formula behaviour, instant construction)
LIVE_RESIDENTS=30    # residents_live test: how many residents call GMI (default 30)
GRIDFALL_HOUR=21.5   # freeze the clock at this hour (e.g. for night screenshots)
GRIDFALL_VIEW=orbit  # play the legacy orbit view with the full CityHud (default: first person)
GRIDFALL_MOUSE=free  # first person: never capture the mouse pointer
GRIDFALL_FP_SMOKE=1  # headless first-person smoke test (see Running)
GRIDFALL_FP_PHOTO_DIR=/tmp/gf_fp  # first-person photo tour: save eye-level shots to this folder
```

## Running

```bash
# Play (first person; add GRIDFALL_VIEW=orbit for the orbit view and CityHud)
godot --path .
GRIDFALL_VIEW=orbit godot --path .

# The gate: parse check and unit tests (quick), plus the orbit and first-person smokes (full),
# or the windowed first-person photo tour and perf report (render). Runs offline in temp user dirs.
tools/gate.sh quick
tools/gate.sh full
tools/gate.sh render

# First-person headless smoke and photo tour
GRIDFALL_FP_SMOKE=1 godot --headless --path .
GRIDFALL_FP_PHOTO_DIR=/tmp/gf_fp GRIDFALL_PHOTO_DAYS=6 godot --path . --resolution 1600x900

# Headless smoke test (offline: 6 days, quake + crews, overlays, inspector, save/load round trip)
GRIDFALL_SMOKE_TEST=1 godot --headless --path .

# Photo tour: grow the city offline, then save landmark, dusk, night, construction and fire shots
# (GRIDFALL_PHOTO_SHOWCASE=1 also builds any missing big project first)
GRIDFALL_PHOTO_DIR=/tmp/gf_photos GRIDFALL_PHOTO_DAYS=12 godot --path . --resolution 1600x900

# Trailer: a ~30 s 1080p clip with captions and a ticker of live GMI mayor calls
# (grows a city offline once, then records with Movie Maker and encodes an MP4 for X)
tools/record_trailer.sh trailer/gridfall_trailer.mp4
# Sim unit test and a live two-day brain test
godot --headless --path . -s tools/tests/sim_test.gd
godot --headless --path . -s tools/tests/buildings_test.gd
godot --headless --path . -s tools/tests/residents_test.gd      # residents, incidents, save/load
godot --headless --path . -s tools/tests/expansion_test.gd      # annexation, survey, old-save migration, 192x192 world
godot --headless --path . -s tools/tests/construction_test.gd   # staged construction and crews
godot --headless --path . -s tools/tests/brain_live_test.gd
LIVE_RESIDENTS=10 godot --headless --path . -s tools/tests/residents_live.gd

# Rebuild the realistic models (procedural Blender + Poly Haven CC0 textures) and validate them
blender --background --python /abs/path/to/tools/blender/make_realistic_city.py -- all
blender --background --python /abs/path/to/tools/blender/validate_real.py

# Rebuild the Blender GLB assets (includes coal plant, water tower, police, fire, hospital, school, apartment tower, factory)
blender --background --python /abs/path/to/tools/blender/make_gridfall_assets.py -- all

# Re-import the Kenney CC0 kits into models/zones, models/props and models/vehicles
blender --background --python /abs/path/to/tools/blender/import_kits.py
```

## Development setup

```bash
tools/setup.sh                       # venv with pinned tools, pre-commit hooks, first asset import
pre-commit run --all-files           # gdlint, gdformat --check, large files, secret scan
python tools/checks/run_all.py       # complexity, dead code, duplicates, module boundaries, TODOs, flags
python -m pytest                     # Python tooling tests (coverage gate, >= 80%)
```

Requires Godot 4.7.x (`.godot-version`) and Python 3.10+. Run the Python tools from the venv `tools/setup.sh` creates (`. ~/.venvs/gridfall-tools/bin/activate`). A dev container with both is in `.devcontainer/`. See `AGENTS.md` and `CONTRIBUTING.md` for rules and workflow, and `docs/runbooks/` when something breaks.

## Build and export

```bash
tools/export.sh linux                # build/linux/gridfall.x86_64 (+ .pck)
tools/export.sh windows              # build/windows/gridfall.exe (+ .pck)
tools/export.sh all                  # both presets in export_presets.cfg
```

Export needs the Godot export templates for the version in `.godot-version` (Editor > Manage Export Templates, or `tools/export.sh` prints the download commands when they are missing). Releases are cut with `tools/release.sh <version>` (for example `tools/release.sh 0.2.0`), which updates `VERSION` and `CHANGELOG.md`, commits and tags; pushing the tag runs the `release` workflow, which runs the gate, exports both platforms and publishes a GitHub Release with zips, checksums and generated notes. Each zip also carries the player guide `tools/release/PLAYING.md` (which heads the release notes) and a `play-orbit` launcher for the orbit view.

## Code map

- `scripts/sim/sim_defs.gd`: rules, costs, ordinances, disasters, mayors, support agents.
- `scripts/sim/city_sim.gd`: tile simulation, actions, annexation, construction sites, disasters and incidents, summaries for the AI, save/load.
- `scripts/sim/residents.gd`: the resident population, their days, jobs, money, incident help and construction crews.
- `scripts/ai/resident_minds.gd`: batched GMI minds for residents.
- `scripts/ai/gmi_client.gd`: GMI HTTP client, JSON extraction, replay cache, call log.
- `scripts/ai/city_brain.gd`: prompts and the daily schedule for all GMI agents.
- `scripts/world/city_view.gd`: 3D renderer (roads chosen by neighbor mask, buildings by density, services, props, bus stops, cars, pedestrians, effects, overlays, click to inspect).
- `scripts/world/city_life.gd`: buses, trucks, emergency crews, boats and aircraft.
- `scripts/world/construction_kit.gd`: construction site stages and the animated machines.
- `scripts/world/resident_avatars.gd`: residents as walking and driving people you can click.
- `scripts/world/sky_director.gd`: day/night cycle and sky.
- `scripts/ui/city_hud.gd`: HUD.
- `scripts/main.gd`: wiring, save/load, smoke test.
- `scripts/cinematic.gd`: the scripted trailer (camera path, captions, live GMI ticker).

## License

GridFall's code is released under the [MIT License](LICENSE). Third-party assets keep their own licenses, listed below.

## Asset credits

Building, prop and vehicle models in `models/zones`, `models/props` and `models/vehicles` are adapted from Kenney asset kits (CC0). See `models/LICENSES/`. The realistic set in `models/real/` is procedural Blender geometry with Poly Haven CC0 textures, HDRIs and a few embedded Poly Haven models; see `models/real/LICENSES/polyhaven.txt`.

## Assets from earlier GridFall versions

- `concepts/*.png`: `hy-image-v3.5-preview` concept sheets made with `tools/gmi/generate_concepts.py`.
- `sounds/music/*.wav`: ACE-Step 1.5 stems (96 BPM nominal, 122 BPM crisis). `audio_director.gd` crossfades between them based on blackouts and active disasters.
- The original 8-tick crisis episode player (`episode_player.gd`, `gridfall_world.gd`, `gridfall_hud.gd`, `tools/gmi/run_episode.py`) is still in the repo but is no longer used by the main scene.
