# Slice D: Posters

Branch `fp/D-posters`, branched from `fp/integration` after S0. Read ARCHITECTURE D9 and D12, and S0 §§9, 10, 14 and 15.

Your protocol reference is `tools/gmi/generate_concepts.py:23-24, 122-200`. Do not print its key resolver output. Measured facts about the image API (synchronous success, sizes that work, unsigned media URLs) are in `/tmp/claude-1000/-home-kunalsiyag-Ambassador-Gmi-Cloud-gridfall/ed910984-b548-4cd5-88e0-8f11330d4e8e/scratchpad/hy-image-notes.md` (cited below as `hy-image-notes.md`).

## Goal (what the player sees)

The streets carry real, current posters:

- mayors' campaign billboards in their own districts
- the GridFall Gazette front page at bus shelters
- shop adverts named after the real businesses on the street
- "Coming soon" hoardings at construction sites
- incident and ordinance notices

Images come from `hy-image-v3.5-preview`. The text on them (names, slogans, headlines) is crisp because it is drawn by Godot over the image. At night, billboards and shelter lightboxes glow.

Offline there are no network calls. The same city shows the same posters, from a pre-baked set.

## Owned files (exclusive)

- `scripts/ai/gmi_image_client.gd` (new, `class_name GmiImageClient extends Node`)
- `scripts/fp/posters/**` (entry point `poster_feature.gd`, id `posters`; `poster_director.gd`, `poster_compositor.gd`, `poster_surfaces.gd`, …)
- `tools/gmi/generate_posters.py` (new)
- `assets/posters/**`: the pre-baked PNGs, their `.import` files and `manifest.json`
- `tools/tests/fp_posters_test.gd`

## Seams consumed

| From | API |
|---|---|
| `GmiClient` | `api_key` (read, never print or log it), `live_enabled` (honour it; gates run with `GRIDFALL_OFFLINE=1`, so it is false, and `gmi_client.gd:34` forces it false under that env) |
| `CityBrain` | `mayor_decided(mi, entry)` (`entry.post` is debranded), `news_published(paper)` (debranded), `council_ruled(r)`, `mayor_state[mi].mood` (a **word** of at most 20 characters, `city_brain.gd:54, 283`) and `.post`, `last_paper` (`city_brain.gd:33, 627`). `ctx.brain` and `ctx.hud` are null-guarded. |
| `CitySim` | `site_started(site)`, `site_finished(site)`, `event_started` / `event_ended`, `day`, `day_started`, `district`, `kind`, `level`, `city_seed`, `sites` |
| `Residents` | `district_mood(d).avg_mood` (0–10, `residents.gd:292-315`), `people` (`plan.evening == "protest"`, for optional placards) |
| `CityView` (S0 seams) | `tile_built(i, holder)`, `tile_cleared(i)`, `world_rebuilt`, `in_setup`, `tile_holder(i)` (meta `building_path`, `building_xform`, `poster_slot`), `bus_stops`, `night` |
| `CityDirectory` | `business_name`, `business_kind`, `landmark_name`, `planned_name(i, target_kind, target_level)`, `place_label`, `frontage`, `frontage_yaw`, `district_name`, `mayor_display`, `street_name`, `address` |
| `SimDefs` | `MAYORS[d].display` / `.color` / `.district` / `.style`, `debrand()`, `BUILDINGS[key].label`, `ORDINANCES` |
| `FpContext` | `world_root`, `features`, `hud.slot("overlay")` (poster viewer), `player_position()` (priority, composite radius) |
| `GameBus` | emits `poster_ready({key, kind, texture, meta})`; listens to `interact_requested` (kind `poster` opens the viewer, modal `&"poster"`), `world_ready` (close the viewer) |
| `AP` (`asset_paths.gd`, owned by H) | `load_scene()`, `BILLBOARD_POSTER`, `BUS_SHELTER`, `POSTER_FRAME`, `HOARDING`, `LEASE_SIGN`, `POSTER_NODE_PREFIX` (`Poster_<n>`), `POSTER_SPOT_PREFIX` (`PosterSpot_<n>`), each with a fallback when missing |

## Seams D may request

- G1 (already in G1's contract): a `poster_slot` meta on poster-carrying props when they are placed (billboards, shelters, the construction kit's frontage fence segment as kind `"hoarding"`, lease boards as `"lease"`). The format is `{"kind": String, "size": Vector2 (units), "xform": Transform3D local to the prop}`. Until then, D detects props by `scene_file_path` (below).
- H (already in H's contract): each poster face exported as its own `MeshInstance3D` named `Poster_<n>` (one surface, material `Poster`, UV 0..1, normal +Z in node space, kept out of the `<name>_body` merge, which today collapses every face into one surface, `make_realistic_city.py:63-64`); and `PosterSpot_<n>` empties on blank walls of zone and building models (+Z out of the wall, scale = poster size).
- S0 (added): `CityDirectory.planned_name()` for hoardings, `view.in_setup`.

## Deliverables

### 1. `GmiImageClient` (`scripts/ai/gmi_image_client.gd`)

```gdscript
class_name GmiImageClient
extends Node
signal image_ready(key: String, tex: Texture2D, meta: Dictionary)
signal image_failed(key: String, reason: String)
const QUEUE_URL := "https://console.gmicloud.ai/api/v1/ie/requestqueue/apikey/requests"
const MODEL := "hy-image-v3.5-preview"
const STYLE_VERSION := "fp1"
var transport: Callable        # (method: String, url: String, headers: PackedStringArray, body: String, to_file: String) -> {code:int, body:PackedByteArray}; default = HTTPRequest
## Test hook: honour the live path under GRIDFALL_OFFLINE=1, but only while `transport` is not the
## default HTTPRequest transport (an injected fake). The env check stays for the default transport.
var allow_live_with_injected_transport: bool = false
## Virtual clock in milliseconds; default Time.get_ticks_msec. Every wait below reads it.
var clock: Callable
var poll_s: float = 3.0
var submit_spacing_s: float = 6.0
var backoff_s: Array = [5.0, 30.0]     # first and maximum 429 back-off
var deadline_s: float = 180.0
## day_fn returns the current game day (sim.day); it drives the per-day cap and the breaker reset.
func setup(client: GmiClient, day_fn: Callable) -> void
## Advances polling, back-off and submit spacing; _process calls tick(delta), tests call it directly.
func tick(dt: float) -> void
## Returns the cache key immediately. The texture arrives through image_ready, which (like image_failed)
## is ALWAYS emitted with call_deferred, never inside request(). pos (world) orders the live queue
## by distance to the player; Vector3.INF means "no position".
func request(kind: String, prompt: String, size: String = "1536x640", priority: int = 0, pos: Vector3 = Vector3.INF) -> String
static func key_for(prompt: String, size: String) -> String   # sha256(MODEL|size|STYLE_VERSION|normalized).left(32)
func get_cached(key: String) -> Texture2D                    # memory LRU or user:// file, else null
func budget_left_today() -> int
var stats: Dictionary  # {"live_submits", "live_ok", "live_fail", "cache_hits", "prebaked", "procedural"}
```

The director maps key → slot with the static `key_for()` **before** it calls `request()`, so a deferred `image_ready` always finds its slot.

**Lookup order.**
1. In-memory LRU (32 textures).
2. `user://posters/<key>.webp`.
3. The pre-baked set: `res://assets/posters/manifest.json`, by exact key, then by `kind` pool. The pick is deterministic: `hash(key) % pool.size()`.
4. The live queue, only if every one of these holds:
   - `client.live_enabled`
   - the env does not have `GRIDFALL_OFFLINE=1`, **or** `allow_live_with_injected_transport` is true and `transport` is not the default
   - the budget is not spent
   - the breaker is closed
5. A procedural fallback (gradient plus palette from the kind or mayor colour).

**Live flow.** This is a straight port of `generate_concepts.py`:

1. `POST QUEUE_URL` with headers `Authorization: Bearer <key>` and `Content-Type: application/json`. The body is `{"model": MODEL, "payload": {"prompt": …, "size": …}}`. Timeout 120 s. The POST often blocks about 20 s and returns `success` with the outcome filled in (`hy-image-notes.md`).
2. If the reply `status != "success"`, take `request_id` and poll `GET QUEUE_URL/<request_id>` every `poll_s` (3 s). Each GET times out at 30 s.
   - **HTTP 429:** wait an extra `backoff_s[0]` (5 s) and double the wait each time, up to `backoff_s[1]` (30 s).
   - **status `failed` or `error`:** the request fails.
   - **No success after `deadline_s` (180 s):** the request fails.
   - All of these waits are measured on `clock` and advanced by `tick(dt)`, so the test drives virtual time.
3. On success, read `outcome.media_urls[0].url`. Also accept `outcome.urls[0]` and `outcome.artifacts[0].url`, because the public docs disagree with the script.
4. `GET` that URL **without the Authorization header**, using HTTPRequest `download_file = user://posters/tmp_<key>.bin`, with `body_size_limit` 12 MB.

**Processing.**
1. Detect the format from the magic bytes (PNG, JPEG or WebP).
2. On a `WorkerThreadPool` task, touching nothing shared: decode, crop to the target aspect, resize the long edge (**1024** for billboards and Gazette shelters, **512** for ads, walls, hoardings and notices), `save_webp` (quality 0.85) to `user://posters/<key>.webp`, then `generate_mipmaps()` and VRAM-compress the private image with `Image.compress(Image.COMPRESS_S3TC)` (or BPTC) when the renderer supports it; compression is CPU-heavy, so it never runs on the main thread.
3. Back on the main thread: `ImageTexture.create_from_image`, update `stats` and `user://posters/index.json` (`{key: {kind, size, day, created_at, source, bytes}}`) — two jobs can be in flight, so only the main thread writes them — then emit `image_ready` deferred.

**Logging.** Never put the key or the headers in any string that is printed, stored or saved. Errors keep only `body.left(140)`.

**Budget (D12).**
- **Live caps:** at most **6 live images per game day** (`day_fn`) and **30 per session**, with at most **2 in flight**.
- **Submit spacing:** at least `submit_spacing_s` (6 s) between submits.
- **Breaker:** after 3 consecutive failures it opens until `day_fn()` returns a later day.
- **Queue order:** by priority, then by distance from `pos` to `ctx.player_position()` (requests with `Vector3.INF` last).

The default transport uses one `HTTPRequest` child per request. Use `use_threads = true` for the download.

### 2. Poster director (`scripts/fp/posters/poster_director.gd`)

The director decides what goes where. Each row below maps one source to a poster kind:

| Trigger | Kind | Prompt and overlay | Refresh |
|---|---|---|---|
| `mayor_decided` | `campaign` | Image: campaign photography of a civic scene matching the mayor's `style` and district (no text, no people's faces in close-up), with the mayor colour as the accent. Overlay: display name, `"for <district>"`, and the slogan (the first ≤ 60 characters of `post`). | Per mayor, at most every 3 game days; within that limit, refresh when `residents.district_mood(mi).avg_mood` (0–10) has moved by ≥ 1.0 since the last campaign poster, or when the `mayor_state[mi].mood` word changed. (`mayor_state[mi].mood` is a word such as `"ready"` or `"focused"`, not a number.) |
| `news_published` | `gazette` | Image: a news photo of the headline subject. Overlay: `"GRIDFALL GAZETTE · Day N"` and the headline. | 1 per day |
| C lots at level > 0 | `ad` | Pre-baked pool chosen through the explicit `AD_POOL` table below. Overlay: `business_name` and the street. | Fixed per tile (seeded) |
| `site_started` | `hoarding` | Pre-baked hoarding art. Overlay: `"Coming soon: <name>"` with `directory.planned_name(i, site.target_kind, site.target_level)` (falls back to `D.BUILDINGS[key].label` or `"New homes"`; `business_name` and `landmark_name` return `""` on SITE tiles), and `"Built by <mayor display>'s contractors"`. | Until `site_finished` |
| `council_ruled.enacted` | `notice` | Procedural or pre-baked notice background. Overlay: the ordinance label and its effect. | Until repealed |
| `event_started` | `incident` | Procedural only. Overlay: `"<Label> near <place>. Follow crews' directions."` | Until `event_ended` |
| protests (optional) | `placard` | Pre-baked. Overlay: the complaint. | Daily |

**Which carrier shows which kind** (deterministic per slot):

| Carrier | Content |
|---|---|
| Billboard | the district mayor's `campaign` on slots whose `hash(slot_id)` is even, otherwise an `ad`; frontier land (district −1) always an `ad` |
| Bus shelter | the `gazette` |
| Wall poster | an `ad` on C lots; a `notice` (ordinance, or an `incident` nearby while one is active) on R and I lots |
| Hoarding | the `hoarding` poster of that site |
| Lease board (G1 `poster_slot` kind `"lease"`) | procedural `"For lease · <address>"` |

**`AD_POOL`** maps `business_kind()` (S0 §14.2, lower-cased) to a pre-baked pool:

| Pool | business_kind values |
|---|---|
| `ad_cafe` | cafe, diner, deli, noodle bar, bistro |
| `ad_bakery` | bakery |
| `ad_market` | market, corner store, pharmacy, laundromat, barbershop, dental clinic |
| `ad_bookshop` | bookshop, florist, design studio, electronics, tailors |
| `ad_fitness` | fitness club |
| `ad_cinema` | cinema, hotel |
| `ad_bank` | savings bank, exchange |
| `ad_hardware` | hardware, workshop, garage, auto repair, joinery, print works |
| `ad_default` | everything else (C3 tower, plaza, center, building; the I2 and I3 kinds) |

**Seeding.** In `on_world_rebuilt()` and `from_dict({})`, seed the Gazette from `brain.last_paper` when it is non-empty, and the campaigns from every non-empty `brain.mayor_state[mi].post`, so posters do not wait up to a game day (20 real minutes) for the next signal. The director exposes `on_mayor_decided(mi, entry)` and `on_news(paper)` as public methods (its signal handlers call them), so tests can call them directly.

Rules for every poster:

- Prompts are built from SimDefs and directory data, never from raw LLM text except the debranded slogan or headline.
- Every prompt carries a **STYLE_LOCK**: photorealistic street poster photography; no text, letters, logos or brand names; no real people or celebrities; city of GridFall.
- All overlay text goes through `SimDefs.debrand()`.

### 3. Surfaces (`scripts/fp/posters/poster_surfaces.gd`)

On `tile_built(i, holder)` — **skipped while `view.in_setup`** — and in one full pass on `world_rebuilt`, discover poster carriers. The full pass visits only C lots, `view.bus_stops` keys, `sim.sites` tiles and wall-poster lots, not all ~2,660 tiles (at 0.3 ms per tile a blind double pass would cost about 0.8 s on every load).

**Precedence** on any carrier: a `Poster_<n>` MeshInstance3D (H) wins (`find_children("Poster_*", "MeshInstance3D")`, set `material_override` on each); then a `poster_slot` meta (G1); then the hardcoded quad below. When a `Poster_*` node exists, D adds no quad.

| Carrier | How it is found | Placement |
|---|---|---|
| Billboard | `scene_file_path` equal to `res://models/real/props/billboard.glb` (what `_add_zone_prop` instances today) or `AP.BILLBOARD_POSTER`, or a `poster_slot` of kind `"billboard"` | `Poster_0` (H), else a `MeshInstance3D "Poster"` with a `QuadMesh` of size `(0.34, 0.15)` at local `(0, 0.275, 0.006)` facing +Z. The board face spans 0.20–0.35 in y, its front plane is at about z 0.0045, and the aspect is 2.27:1. |
| Bus shelter | `scene_file_path` equal to `res://models/props/bus_stop.glb` (the gf stop `_maybe_bus_stop` uses, `city_view.gd:1242`), `res://models/real/props/bus_stop.glb` or `AP.BUS_SHELTER`, or `poster_slot` kind `"bus_shelter"` | gf stop: a quad of `(0.08, 0.09)` at local `(0.10, 0.09, −0.0555)` facing +Z, **plus** a back quad at z −0.0605 facing −Z (the `gf_ad_pink` lightbox box spans z −0.060 to −0.056, so z −0.058 would sit inside it). Real stop: its lightbox faces −X at x −0.123. H's shelter: `Poster_0`. |
| Wall poster | Building lots with a frontage and `hash(i) % 3 == 0` | A `PosterSpot_<n>` empty under the holder's building instance (H) gives the exact wall pose and size. Until H lands, a **per-path cached wall box**: the union of the vertex AABBs of surfaces whose material starts with `Brick`, `Siding`, `Stone`, `Plaster`, `Concrete_Wall` or `Panel`, excluding `Grass`, `Sidewalk`, `Dirt`, `Concrete_Floor`, `Hedge*`, `Leaves*`, `Bark*` and the `*_foliage` node, transformed by the holder and its `building_xform` meta. Place `AP.POSTER_FRAME` or a fallback quad of `(0.06, 0.09)` (1.2×1.8 m) on that box's frontage face near a corner, centred 0.07 above `LOT_TOP` and 0.002 off the wall. **Never** on `building_aabb`: it includes the 0.94 lot slab, so posters would float 3–7 m in front of the facade (bank.glb walls x ±0.35, z −0.33…0.284; house_bungalow's front wall at z 0.103 against a box face at 0.47). |
| Hoarding | G1's `poster_slot` kind `"hoarding"` on the construction kit's frontage fence segment (the kit already fences the lot at ±0.47 with a gate gap, `construction_kit.gd:641-654`) | The slot's rect; with H, `AP.HOARDING` has `Poster_0` and `Poster_1`. Until G1 lands: a quad on the frontage fence segment itself (0.47 from the tile centre, 0.002 outside it), never a separate panel at 0.44 that collides with the fence. |
| Lease board | `poster_slot` kind `"lease"` (G1, FP level-0 lots) | the slot's rect |

Material: one `StandardMaterial3D` per poster key, shared by every instance of that key.
- `albedo_texture = tex`, `roughness = 0.85`, `texture_filter` linear with mipmaps and anisotropy.
- Billboards and shelters also set `emission_texture = tex`, with energy `0.4 + 1.6 * view.night` updated at 2 Hz.
- **Composites** (texture + overlay text, §4) exist only for slots within `WS.VIS_PROP` of the player, at most 32 at once; beyond `1.25 * VIS_PROP` a slot releases its composite and falls back to the shared base texture of its key (whose overlay-free image is shared by every slot with that key).

Slot ids are `"<tile>:<carrier>:<n>"`. Assignment is deterministic, seeded by `sim.city_seed`.

**Nodes under tile holders** (S0 §3 exception): every quad, frame or material holder D adds under a holder is tagged `set_meta("fp_owner", "posters")`, re-created on every `tile_built` and full pass, and freed in `teardown()`.

### 4. Compositor (`scripts/fp/posters/poster_compositor.gd`)

1. A one-shot `SubViewport` with `render_target_update_mode = ONCE`. It holds a TextureRect for the image plus Labels using `res://fonts/lilita_one_regular.ttf`, laid out per kind.
2. Read the result back as an Image and wrap it in an ImageTexture.
3. Headless (`DisplayServer.get_name() == "headless"`): skip compositing and use the raw image. Tests check the pipeline, not the pixels of the text.
4. The same layout composites the procedural fallback, so a poster is never blank.

### 5. Viewer

`interact_requested` with kind `poster` opens a full-screen TextureRect in `hud.slot("overlay")`, with `EXPAND_IGNORE_SIZE` and `KEEP_ASPECT_CENTERED`, the same pattern as `gridfall_hud.gd:393-395`. Push the modal `&"poster"`. Esc or E closes it, handled in `_unhandled_input` on `is_action_pressed(…) and not is_echo()` and consumed (S0 §7.2); A ignores the interact press in the frame the modal pops, so the viewer does not reopen. On `world_ready` and in `from_dict()` the viewer closes and pops its modal.

Implement `pick()` against the poster quads within `WS.INTERACT_RANGE`, returning `{"kind": "poster", "id": key, "label": "Look at <title>", …}`.

### 6. The pre-baked set (`tools/gmi/generate_posters.py` and `assets/posters/`)

The generator is a port of `generate_concepts.py`: the same key resolver (never printed), the same submit, poll and download, at most 4 concurrent jobs. Sizes (both measured to succeed, `hy-image-notes.md`): **`1536x640`** for billboards, hoardings and campaign posters, and **`768x1152`** for shelters, wall frames and notices. No 1920x1080 crop.

It produces about **25** images as **WebP at quality 85**, resized to a 1024 long edge (billboard, Gazette) or 512 (ads, notices, hoardings). PNG at 1024 measured 684 KB and 1,169 KB; WebP q85 measured 82 KB and 140 KB.

| Count | Content |
|---|---|
| 5 | `campaign_<mayor_id>` |
| 9 | `ad_<cafe\|bakery\|bookshop\|fitness\|cinema\|market\|bank\|hardware\|default>` (the `AD_POOL` names) |
| 4 | `gazette_<skyline\|construction\|crews\|park>` |
| 3 | `hoarding_<tower\|park\|station>` |
| 4 | `notice_<incident\|ordinance\|power\|water>` |

`manifest.json` maps `{file: {kind, tags, prompt, size, model, elapsed_s, created}}`.

How to run it:
1. Run `--dry-run` first. It prints the prompts only.
2. The **one** live run is the only paid step of this slice: about 24 images. Run it once, commit the outputs with their Godot `.import` files (made by a heavy `--import`), and never run it again in gates.
3. If the live key is unavailable, ship procedural placeholders under the same file names and record this in the hand-off.

### 7. Save (`poster_feature.to_dict`)

- `{"slots": {slot_id: {"key": String, "kind": String, "overlay": {…the overlay fields: name, district, slogan, headline, day, address…}}}, "campaign_day": [d0..d4], "campaign_mood": [m0..m4], "live_today": n, "live_session": n, "day": d}`. The key is a prompt hash, so the overlay text cannot be rebuilt from it; it is saved explicitly.
- Textures are never saved. They come back from `user://` or the pre-baked set.
- Ints come back from JSON as floats; cast `campaign_day`, `live_*` and `day` to int in `from_dict`.

## Acceptance tests

`tools/tests/fp_posters_test.gd`, token `FP_POSTERS_TEST: PASS`. It runs offline and uses a fake `transport`. **Time is virtual**: the test sets `image_client.clock` to a counter it advances and calls `image_client.tick(dt)`; it sets `poll_s`, `submit_spacing_s`, `backoff_s` and `deadline_s` small where it does not test them. The whole test finishes in under 5 s of wall clock (the real 3 s polls, 5–30 s back-offs and 6 s spacing over 30 submits would need ≥ 174 s, against the 300 s gate timeout). Deferred signals are awaited with one `process_frame`.

**Key.**
- `key_for(" A  Cafe ", "1536x640") == key_for("a cafe", "1536x640")`.
- The key is 32 hex characters.

**Live path, with the fake transport.** Set `client.api_key = "TESTKEY123"`, `client.live_enabled = true` (after `_ready`, which forces it false under `GRIDFALL_OFFLINE=1`) and `image_client.allow_live_with_injected_transport = true`.
- The fake answers in this order: submit → `{"request_id": "abc", "status": "queued"}`; poll → 429; poll → `processing`; poll → `success` with a media URL; download → a 64×32 PNG built in the test.
- `image_ready` fires, and never synchronously inside `request()` (a flag set after `request()` returns is already true when the handler runs).
- The texture's long edge is ≤ 1024 and it has mipmaps.
- `user://posters/<key>.webp` exists.
- The download call carried **no** `Authorization` header.
- No recorded string (`stats`, `index.json`, `last_error`) contains the fake key `"TESTKEY123"`.
- With the default transport (flag set but no fake), `GRIDFALL_OFFLINE=1` still blocks the live path: 0 network requests.

**Cache.** The same prompt again makes 0 transport calls and increments `stats.cache_hits`; `image_ready` is still deferred.

**Breaker and budget** (with `day_fn` returning a test-controlled day).
- After 3 consecutive failures, a further request makes 0 transport calls and falls back; advancing `day_fn` by one day closes the breaker.
- The 7th live request in one game day is served from the pre-baked set or the procedural fallback.
- After 30 per session, no more live submits happen.
- Never more than 2 jobs are in flight at once. Two queued requests with equal priority are submitted nearest-`pos`-first.

**Offline.** With `live_enabled = false`, there are 0 transport calls, and the same seed picks the same pre-baked files across two runs.

**Director (with a view).** Use `fp_kit.make_ctx(root, {"view": true, "grow": true})` and `make_feature(ctx, "posters")`.
- **Fixtures first:** assert at least 1 C lot with a `business_name` and at least 1 `view.bus_stops` entry; FAIL (do not pass vacuously) if one is missing. The grown kit city has no guaranteed billboard (S0 §17.2), so the test instantiates `res://models/real/props/billboard.glb` under the first C-lot holder, then emits `view.tile_built(i, holder)`; that billboard must get a `Poster` child (or a `Poster_*` override when H's asset is used).
- Call `director.on_mayor_decided(mi, entry)` for every mayor that owns a billboard slot, and `director.on_news(paper)`: every campaign slot sits in a tile whose `sim.district` equals that mayor's index; shelters show the gazette.
- Ad overlays use `directory.business_name` of their tile, and the pool follows `AD_POOL` (an unmapped kind gets `ad_default`).
- Every wall poster lies within 0.005 of its wall box face (never on the `building_aabb` face) and inside the tile.
- A site's hoarding overlay uses `planned_name` and is non-empty for a C or service target.
- `to_dict` → JSON → `from_dict` keeps each slot's key, kind and overlay text; `from_dict({})` with a non-empty `brain.last_paper` seeds the gazette without any signal.
- `tile_built` emissions during `view.setup()` (`in_setup`) do no work: counting calls to the per-tile handler stays 0 until `world_rebuilt`.
- At most 32 composites exist; moving the player beyond `1.25 * VIS_PROP` from a slot releases its composite.
- `pick()` along a ray into a billboard quad returns kind `poster`.
- `teardown()` leaves no node with `fp_owner == "posters"` under any holder.

**FP smoke and photo tour.**
- FP smoke: `self_test()` passes when at least 1 poster surface exists, or when there are no C lots yet, with that stated in the detail.
- Photo tour: add `photo_shots()` entries `"billboard"` (the nearest billboard, framed at 6 m) and `"bus_shelter"`, both at 10.5 h. The night shot shows glowing billboards.

## Performance budget

- **Main thread:** at most 2 ms per poster texture upload. Decode, resize, WebP encode and VRAM compression happen off the main thread.
- **Surfaces:** at most 0.3 ms per `tile_built`, and none during `view.setup()`.
- **Memory:** at most **32 resident poster textures** (LRU) and at most **32 composites**, within **64 MB** of VRAM: a 1024-long-edge RGBA texture with mipmaps measures 2.2–3.6 MB, so the budget only holds because ads, walls, hoardings and notices are 512 and every texture is BC-compressed where `Image.compress` is available (about 4–8× smaller). Distant posters (beyond `VIS_PROP`) use `visibility_range_end`.
- **Network:** never block the frame on it. The gate stays offline.

## Risks

- **Sizes.** `1536x640` and `768x1152` are measured to work (`hy-image-notes.md`); `1920x1080` comes back as 1920×1072. Request the slot's aspect directly instead of cropping.
- **Image text and content.** The model garbles text and may draw logos or likenesses. Keep the STYLE_LOCK, and put the text in the overlay only.
- **Shared credits.** The poster key and credits are shared with the chat calls, so keep posters at low priority.
- **Shared materials.** Billboard Sign_* materials are shared across all billboards. Do not edit them; overlay a quad instead.

## Do NOT touch

- `scripts/ai/gmi_client.gd` (read `api_key` and `live_enabled` only), `city_view.gd` (request `poster_slot` meta from G1), `concepts/`, `data/gmi_replay_cache.json`, and other slices' files.
- Never print the key.
