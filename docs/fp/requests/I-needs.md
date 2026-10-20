# I needs

Requests from slice I (audio) to the slices that own the files involved. Nothing breaks while one
is open: each has a local fallback in `scripts/fp/audio/`, or the sound is simply missing.

## To A (player)

1. **Done:** `FpPlayer` emits `stepped` on touchdown after 0.15 s or more in the air, then
   `landed(speed_mps)`; footsteps add the other foot, 3 dB up, above 4 m/s.
   **A landing is a foot contact.** `FpPlayer.stepped` fires on each heel strike of the gait
   (`_advance_phase`), but not on touchdown: `_vertical` sets `grounded = true` after a jump or
   a fall without emitting. The I contract (§5) and A2 count a landing as one more contact. Please
   emit `stepped(collision.surface_at(position), position)` once when the hero lands after more
   than about 0.15 s in the air. If A also exposes the landing speed (for example a
   `landed(speed: float)` signal, or the existing `_heavy` timer as a public flag), I will play a
   heavier two-foot thump above `HEAVY_LAND_SPEED`.
   Fallback: none. While `stepped` exists I never polls (polling as well would double every step),
   so landings are silent until then.
2. I reads `velocity`, `crouched`, `grounded` and `photo_mode` on `FpPlayer` by name (run and
   crouch trims, polling pauses). Please keep those names.

## To E (traffic)

1. **`siren: bool` in `agents_near` dicts**: true only for a crew vehicle with `c.siren` set
   whose owner phase is not `"leaving"`. That is the condition `traffic_feature` already uses for
   the light bar in `draw_car`. Fallback: I treats every `"emergency"` agent moving faster than
   1 m/s as wailing while any incident is live, so utility trucks (`c.siren == false`) and crews
   driving home after a second incident starts sound sirens too.
2. **Bikes are reported as `"pedestrian"`** (`_refresh_snapshot` maps `kind == "bike"`). I plays
   passers-by footsteps for `"pedestrian"` agents within 6 m and drops any faster than 2.6 m/s as
   bikes. A distinct `"bike"` kind, or a flag, would be cleaner, and would let I give bikes a
   freewheel tick later.
3. Optional (E2): a foot-contact hook for T0 walkers, for example a
   `walker_stepped(id, pos)` signal fired at HC's contact phases. I derives passer-by steps from
   distance travelled (one per 0.7 m stride at a walk, `footsteps.gd` `stride_length`), which keeps
   the cadence but not the drawn foot phase.

## To G1 (streetscape)

1. I reads the weather by name: `ctx.feature("streetscape").weather.state` (`"rain"` fades in a
   rain bed and quietens the birds and insects) and `.weather.wet` (0..1; at 0.2 and above the
   hero's steps on asphalt, sidewalk, lot and bridge get a splash layer scaled by it). Please keep
   those names, or tell I if they move. Fallback: without the streetscape feature it never rains
   and the streets stay dry, as before.

## To C (chat)

Nothing open. C's "I (audio)" requests are in: the full blip for a reply to the player's own line
(I tracks the player's last `seq` from `chat_posted`), a soft blip for system `alert` and
`incident` cards and for mayor and press posts, and one quiet blip per 30 s for every other line,
all only while `panel.is_open` is false. Talking ducks the beds 6 dB on
`conversation_changed(id, true)`. I reads `panel.is_open` by name, so please keep that name.

## To the integrator

- **Asset containers.** §7 asks for Ogg Vorbis. I ships the sounds the game starts often
  (footsteps and their splash layer, horns, both engines, the siren, the UI cues) as 16-bit PCM
  WAV, and the long loops started rarely (the beds, construction, fire, river, fountain, plant hum)
  as Ogg Vorbis. Measured with a headless probe on this machine, starting an Ogg playback costs
  410–470 µs on the main thread (decoder setup) and a WAV 0.6–0.9 µs. With the hero's and up to
  four passers-by's footsteps, Ogg would spend the whole 0.3 ms/frame audio budget on starts alone.
  `sounds/fp/` is 5.2 MB in total (limit 8 MB). `tools/audio/synth_fp_sfx.py` picks the container
  per sound and writes the matching `.import` loop flags.
- **Beyond §4 and §5.** A sixth bed, `rain`, follows G1's weather (the cap of 4 playing beds still
  holds), and the hero's steps get a splash layer on wet paving. Passers-by's footsteps (§5,
  optional) are in, derived from E's agents by distance travelled.
