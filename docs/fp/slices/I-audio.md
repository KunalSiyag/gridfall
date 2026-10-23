# Slice I: Audio

Branch `fp/I-audio`, branched from `fp/integration` after S0. Read ARCHITECTURE D1, S0 §§4, 9 and 12 (`CollisionWorld.surface_at`). In `understand.md`, read the AudioDirector notes in "Wiring". The current director is `scripts/audio_director.gd`: 2D only, with a tick SFX on every `set_blackout_intensity` call (lines 68–69).

## Goal (what the player sees, and hears)

The city sounds alive and **positional**:

- Engines rise and fall as cars pass, and horns sound when traffic stalls.
- Sirens doppler past toward incidents. Construction clanks near sites.
- Your footsteps change between asphalt, sidewalk, grass and bridge, and land exactly when your character's feet hit the ground (third person is the default, D13: you see every step).
- Area beds cross-fade as you walk: traffic hum downtown, birds in parks, water by the river, and a quieter residential bed.
- The music ducks under the street sound in first person, and a soft blip marks new chat lines.
- In orbit mode everything sounds as it does today, except that the blackout tick no longer repeats on every call (§2).

## Owned files (exclusive)

- `scripts/fp/audio/**` (entry point `audio_feature.gd`, id `audio`; `emitters.gd`, `ambience.gd`, `footsteps.gd`, …)
- `sounds/fp/**` (new assets and their `.import` files)
- `scripts/audio_director.gd`
- `tools/audio/synth_fp_sfx.py` (new, procedural synthesis). The existing `generate_audio_acestep.py` may be used optionally under the heavy lock.
- `tools/tests/fp_audio_test.gd`

## Seams consumed

| From | API |
|---|---|
| S0 `WS` | `AUDIO_UNIT_SIZE` (0.5 u = 10 m, the `unit_size` of every `AudioStreamPlayer3D`), `M`, `TRAFFIC_RADIUS` |
| `FpContext` | `player` (the FP camera is the listener automatically, because it is current), `collision.surface_at(p)` (mapping in S0 §12: a park tile is `"grass"`), `directory`, `sim`, `view`, `settings` (`music_volume_db`, `sfx_volume_db`), `world_root`, `features` (E's `traffic.agents_near(p, r)` for engine emitters, when present: fields `id`, `pos`, `vel`, `speed`, `kind`, `stalled_s`) |
| `FpPlayer` | a `stepped(surface: String, pos: Vector3)` signal (A adds it). Once the hero animates (A's stage A2, on HC's bodies), A fires it on the locomotion clip's **foot contacts**: HC phase-aligns every loop so the left heel strikes at t = 0 and the right at half the cycle, so the signal follows the visible stride and cadence (walk, jog, run, crouch-walk, landing) in both cameras; `pos` is the contact foot's ground point. Before that, A fires it every `0.7 * M` of travel. Until A lands at all, I polls the player's distance travelled and calls `surface_at` itself every `0.7 * M` of horizontal travel. |
| `GameBus` | listens to `chat_posted` (blip), `ping` (`event:*` gives an alert stinger), `toast` (`alert` kind), `pause_changed` (pause the bus), `settings_changed` (volumes), `conversation_changed` (duck ambience −6 dB while talking), `player_tile_changed` (area bed selection), `time_scale_changed` |
| `CitySim` | `event_started` / `event_ended` (siren and fire emitters at the event), `site_started` / `site_finished` (construction loops), `traffic[i]`, `kind`, `terrain`, `is_surveyed`, `night` (via `SkyDirector.night`) |
| `CityView` | `tile_built` / `tile_cleared` (register site, fountain and coal-plant emitters; skip while `in_setup`), `world_rebuilt`, `life` (crew vehicles' positions while E is absent), `flush_rebuild_queue()` (tests) |
| `GridFallAudioDirector` (own file) | music stems, `play_sfx`, `toggle_mute`, `set_blackout_intensity` |

## Seams I may request

- A: the `stepped` signal on `FpPlayer`.
- E: `agents_near()` with `id` (stable per agent), `speed`, `vel` and `stalled_s` (already in E's contract). Until E provides them, I disables horns and engine pitch and keeps engines at idle volume.
- C: the `chat_posted` msg `role`, used for blip variants.

## Deliverables

### 1. Audio buses

Create them at runtime in `audio_feature.setup`, using `AudioServer.add_bus` if they are missing, and remove them in `teardown`:

- `Music`, `SFX`, `Ambience` and `UI`, all routed to `Master`.
- A `LowPassFilter` on `Music` with cutoff 20 kHz, dropped to 800 Hz while paused. (The FP players on `Ambience` and `SFX` are under the pausable Features node, so they already stop with the tree; only the director's music keeps playing, see §2.)

Settings map `music_volume_db` to `Music` and `sfx_volume_db` to `SFX` and `Ambience`.

### 2. AudioDirector changes (`scripts/audio_director.gd`)

- `set_blackout_intensity` plays the tick SFX at most once per 10 s, and only when the phase changes. Today it plays on every call, every day start (lines 68–69). **This throttle applies in orbit too** (a deliberate small orbit change: the tick spam is a bug in both modes; the orbit smoke does not assert on it). It is the only orbit-visible change.
- Add `set_fp(on: bool)`, which the audio feature calls. In FP:
  - the music stems go to the `Music` bus with a **−8 dB offset applied inside `_apply_volumes()`** (`audio_director.gd:104-114`, which rewrites the stem volumes every frame from `_process`, lines 55–57; a one-off volume change would be overwritten);
  - `play_sfx` for `day_bell` and `placement-a` (called from `main.gd:70` and `:74`) plays on the `UI` bus 6 dB quieter;
  - `play_sfx` for `gridlock_alert` (`main.gd:78`, every `event_started`) is **suppressed**: I's positional siren or stinger at the event replaces it;
  - `process_mode = PROCESS_MODE_ALWAYS` on the director, so the music keeps playing (muffled) in the pause menu; it is pausable today and would stop with the tree.
- Add a `signal sfx_played(path: String, bus: String)` emitted by `play_sfx` when it actually plays, so tests can count without hearing.
- Cache streams: `play_sfx` stops calling `load()` on every play (`audio_director.gd:90`).
- **Orbit behaviour is otherwise unchanged** when `set_fp(false)` (process mode restored too).

### 3. Positional emitters (`emitters.gd`)

- Every emitter is an `AudioStreamPlayer3D` with:
  - `unit_size = WS.AUDIO_UNIT_SIZE`
  - `attenuation_model = ATTENUATION_INVERSE_DISTANCE`
  - `max_distance` per type: engines 6 u, horns 10 u, sirens 25 u, construction 8 u, fountains 3 u, river 6 u
  - `doppler_tracking = DOPPLER_TRACKING_DISABLED` (see below)
  - the `SFX` bus
- **Doppler by hand.** Built-in doppler cannot work at this scale: `AudioStreamPlayer3D` has no `speed_of_sound` (probe), and the engine computes doppler in world units against 343 u/s, so a 50 km/h car (0.695 u/s) shifts pitch by about 0.2% and a siren by about 0.3%; emitters reassigned between cars would also spike the measured velocity. Compute `pitch = base * 343 / (343 + v_close_m)` where `v_close_m` is the closing speed in u/s divided by `WS.M` (positive when receding), from E's `vel` and the player's velocity, clamped to 0.7–1.4, and smoothed per emitter keyed by E's agent `id`.
- **Pool:** at most **24** concurrent players. Steal the farthest or quietest first.
- **Engines:** attach to the nearest cars from E's `agents_near(player, 3.0)` (at most 8), keyed by the agent's `id`. Pitch scales from 0.8 to 1.4 with `speed` (then the doppler factor), and the volume drops when `speed` is near 0. While E is absent, use `view.life` road agents at idle pitch.
- **Horns:** a probability per stalled car (`stalled_s > 4`), at most 1 per 6 s globally. Disabled while `agents_near` lacks `stalled_s`.
- **Sirens:** on `event_started` with a crew response; follow the crew vehicles through E, or the event position. Two-tone, looped.
- **Construction:** a loop at every site within 8 u, from `tile_built` on `SITE` tiles and zone sites.
- **Fire:** a crackle loop at burning tiles within 6 u.
- **Initial scan.** The view's first `tile_built` and the sim's existing `event_started` signals fire before FpMode exists, and a load re-creates the world. In `on_world_rebuilt()` and `from_dict()`, scan `sim.sites`, `sim.events`, burning tiles and the fountain and coal-plant holders and register their emitters directly.

### 4. Area ambience (`ambience.gd`)

- **Beds** (2D, looped, on the `Ambience` bus), cross-faded over 3 s:
  - `traffic_hum`, weighted by `sim.traffic` and the C/I density within 4 tiles
  - `park_birds`, from park or forest tiles within 4, quieter at night
  - `river`, from water tiles within 3; positional emitters along the bank also play `river`
  - `residential_quiet`
  - `night_insects`, at night in R or park areas
- Five bed types, **at most 4 playing at once**: a bed whose weight falls below 0.02 stops; the lowest-weight bed yields when a fifth would start.
- Reuse the unused `sounds/ambience.ogg` (1.2 MB) as the downtown bed when it fits. Its import has `loop=false` (`sounds/ambience.ogg.import:15`) and the legacy import is not I's to change, so I loops a **duplicated** stream at runtime (`stream.duplicate()` then `loop = true`).
- Weights are recomputed on `player_tile_changed` and every 2 s.

### 5. Footsteps (`footsteps.gd`)

- **Timing follows the hero's locomotion phase when available.** When `FpPlayer` has the `stepped` signal, I plays exactly one step per emission and stops polling (never both, so no doubled steps); the cadence then matches the animation, including the faster run cadence (a landing is one more contact). Only without the signal does I fall back to the distance poll.
- The surface comes from `stepped(surface, pos)`, or from polling.
- Alternate left and right variants per step (a stride has two contacts).
- Use 4–6 variations per surface: asphalt, sidewalk, grass, dirt, bridge, lot. Pick them with a seeded RNG, with ±8% pitch.
- Play them on a non-positional player at −14 dB on the `SFX` bus. Running is louder and faster; crouching is quieter. In third person the listener (the current camera) sits about 3.2 m behind the hero, so a non-positional step still reads as "my feet"; keep it non-positional in both cameras.
- Optional, after E's stage E2: footsteps for T0 residents within 6 m, positional, at most 4 at once, triggered by E at the same foot-contact phases.

### 6. UI

- The chat blip on `chat_posted`: only when the chat panel is collapsed, at most 1 per 1.5 s, and a softer variant for system cards.
- Alert stingers on `ping` (`event:*`) and on `toast(alert)`.

### 7. Assets (`sounds/fp/`, OGG Vorbis, 44.1 kHz mono for emitters and stereo for beds)

`tools/audio/synth_fp_sfx.py` synthesises them deterministically with numpy and a fixed seed:

| File | Content |
|---|---|
| `engine_idle`, `engine_run` | filtered noise plus harmonics |
| `horn_short`, `horn_long` | |
| `siren_two_tone` | |
| `footstep_<surface>_<n>` | |
| `construction_loop` | hits plus a generator hum |
| `fire_crackle` | |
| `river_loop`, `fountain_loop` | |
| `park_birds` | chirp synthesis |
| `night_insects` | |
| `traffic_hum` | |
| `chat_blip`, `chat_blip_soft`, `alert_stinger` | |
| `crash_heavy`, `crash_light`, `prop_clatter`, `prop_clang` | the player's car hitting walls and cars (`car_impact`) and street props knocked over (`prop_knocked`); WAV |
| `car_door_open`, `car_door_close` | the player's car door (`car_door`): the handle, the latch letting go, the seal and the door check as it opens; the slam, the latch catching and the panel as it shuts; WAV |
| `punch_hit`, `body_fall`, `punch_whoosh` | people hit in the street (`person_hit`): the thump of a punch, a shove or a car at the chest, scaled by the blow's strength (a car's lower and louder), and someone knocked down landing 0.45 s later; the hero hurt by a punch or a car (`hero_hurt`: the same thump at their chest, scaled by the health it took, full at 12 for a punch and 60 for a car, and their fall when knocked down); the hero's swing (`hero_action`: a jab, a cross or a shove, not an emote) whooshing at the shoulder; the hero's landing roll (`hero_action` `roll`): the shoulder meeting the ground 0.15 s after it starts, a `body_fall` 8 dB under a knock-down's; WAV, emitter type `hit` |
| `dog_bark_1`, `dog_bark_2`, `dog_bark_3`, `dog_growl`, `dog_whine`, `dog_snap` | dogs (`animal_called`, at the dog's head): three barks (a rough voice jumping up in pitch and falling away through the open mouth's formants, with the street's slap after it), a growl (a low rough voice of about 100 Hz fluttering into a "grrr", swelling over a second) and a whine (two high whimpers arching around 1 kHz); a growl plays 6 dB and a whine 12 dB under a bark, each at `sqrt(0.5 / h)` of its pitch for a dog `h` m high at the shoulder, so a Shiba Inu yaps higher than a husky. A dog's bite on the hero (`hero_hurt` `bite`): a snarl into the snap of its jaws and the tug at the trouser leg, at the knee (0.5 m up), full level at 7.5 health; WAV, emitter type `dog` |
| `pigeon_coo_1`, `pigeon_coo_2`, `pigeon_flap`, `pigeon_takeoff` | pigeons (`animal_called`, at the bird): two coos ("coo, roo-c'too-coo": low, nearly pure notes around 450 Hz, muffled and trembling), a lone bird fluttering off (two claps of its wings, then a few quick beats with the outer feathers' whistle) and a flock going up together (a dozen birds' claps and beats overlapping into one clatter, with the rush of air under them); a coo plays 16 dB under the wings, each within 6% of its pitch; WAV, emitter type `bird` |

Total size must be at most 8 MB. The ACE-Step tool is optional and needs the GPU, so only under the heavy lock and only for the beds. Write the import settings so loops loop (OGG `loop=true` in each `sounds/fp/*.ogg.import`, which I owns).

**Encoding.** The machine has numpy and scipy but no `soundfile` or `oggenc`. Write WAV with `scipy.io.wavfile`, then encode with ffmpeg 6.1's libvorbis for byte-identical output: `ffmpeg -y -fflags +bitexact -i in.wav -c:a libvorbis -q:a 4 -map_metadata -1 -flags:a +bitexact out.ogg`. Then one heavy `--import` under the lock and commit the `.ogg` files with their `.import` files.

### 8. Feature lifecycle

- `setup`: buses, `audio.set_fp(true)` (null-guard `ctx.audio`: unit tests without `"audio": true` have none), then start the beds.
- `on_world_rebuilt` / `from_dict`: the initial scan (§3).
- Pause: the Features node is pausable, so every I player pauses with the tree and needs no code. The pause muffle applies to what keeps playing: the `Music` bus (the director is `PROCESS_MODE_ALWAYS` in FP), via the `LowPassFilter` cutoff dropping to 800 Hz on `pause_changed(true)`.
- `teardown`: `set_fp(false)`, free the emitters, remove the buses.
- `to_dict`: `{}`. Volumes live in the settings.
- `self_test`: the buses exist, the beds are playing (`playing == true`), and every emitter's `unit_size == WS.AUDIO_UNIT_SIZE`.

## Acceptance tests

`tools/tests/fp_audio_test.gd`, token `FP_AUDIO_TEST: PASS`. It runs headless; Godot runs the Dummy audio driver headless, but the node state is testable. Setup: `fp_kit.make_ctx(root, {"view": true, "grow": true, "audio": true})` (the kit's headless player is the "stub player"), then `make_feature(ctx, "audio")`. Count SFX through the director's `sfx_played` signal. Float comparisons use `is_equal_approx`.

**Emitters.**
- Every `AudioStreamPlayer3D` the feature creates has `unit_size ≈ WS.AUDIO_UNIT_SIZE`, a `max_distance` from the table and `doppler_tracking == DOPPLER_TRACKING_DISABLED`.
- At no point do more than 24 exist. Fire 40 emitter requests to check the stealing.
- With a fake agent receding at 0.695 u/s (50 km/h), the engine pitch is `base * 343 / (343 + 13.9)` ± 1%.

**Initial scan.** A site and an event that existed before `make_feature` have emitters right after it (no signal needed).

**Sirens.** `sim.trigger_disaster("fire", …)` creates a siren emitter within 2 frames, and `event_ended` frees it within 10 s. In FP mode the director does not play `gridlock_alert` for it (`sfx_played` count 0 for that path).

**Footsteps.**
- `surface_at` on a road centre gives the `asphalt` variants, on the sidewalk the `sidewalk` variants, and on a park tile `grass`.
- Simulated travel of `10 * 0.7 * M` produces 10 steps (±1) when the player has no `stepped` signal (polling).
- With a stub player that has `stepped`, 8 emissions produce exactly 8 steps, alternating left and right variants, and walking the same distance with no emission produces none (polling is off).

**Ambience.** Moving the stub player next to a water tile makes the `river` weight the largest after 3 s simulated.

**Director.**
- 50 calls to `set_blackout_intensity(0.1, "NOMINAL")` produce at most 1 tick SFX (`sfx_played`).
- After `set_fp(true)` and one `_process` frame, the stem volumes are 8 dB below the orbit values computed by `_apply_volumes` for the same mix.
- `set_fp(false)` restores the orbit routing exactly. Assert the bus names, the volumes on the stem players after a `_process` frame, and the director's process mode.

**Settings.** `settings_changed({"music_volume_db": -20, …})` sets the `Music` bus volume to −20 dB.

**Assets.** Every `sounds/fp/*.ogg` loads, and the loops have `loop == true`. The downtown bed, when it reuses `sounds/ambience.ogg`, plays a duplicated stream with `loop == true` and the original resource still has `loop == false`.

**Beds.** No more than 4 bed players are playing at any time while the stub player walks from a park to the river to downtown.

FP smoke: the `self_test()` above. The orbit smoke is unchanged.

## Performance budget

- At most **0.3 ms per frame** of GDScript.
- At most 24 concurrent 3D players and at most 4 beds.
- Asset loads happen once, through `preload` or a cache. No `load()` on every play (today `play_sfx` calls `load` each time, at `audio_director.gd:90`).

## Risks

- **Units.** Default `unit_size` 10 with 1 unit = 20 m makes everything audible across the city. Always set `WS.AUDIO_UNIT_SIZE`.
- **Doppler.** Engine doppler is disabled and computed by hand (§3); the built-in effect is inaudible at 1 unit = 20 m.
- **Headless.** Headless tests cannot hear anything. Verify the mix by ear in a windowed run, and attach a short note to the hand-off.

## Do NOT touch

- `main.gd` (its SFX calls stay; the director reroutes them), `project.godot`, the sim, AI and world scripts, the S0 files and other slices' files.
- The legacy `sounds/*.wav` and `sounds/*.ogg` files and `sounds/music/*`.
