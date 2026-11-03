# Web probe kit: where a browser hitch goes

In the browser, the web build's frame time and stalls were only ever measured as requestAnimationFrame
intervals (the droid's budget doc has per-section node timers, but from the staged bench, not from a
browser), so a hitch had no owner there: a shader link, a texture upload, a readback and script time
all looked alike.
The probe kit records which of them a slow frame spent its time in, and what a frame is made of
(draws, framebuffer passes, program switches), so the measure-first items of the web backlog get
their numbers before anything is built. It changes no gameplay.

| Piece | Where |
| --- | --- |
| Driver: boots the page in Chrome, drives street, walk, sky and orbit rows, writes `result.json` | `tools/web_fps_probe.js` |
| In-page WebGL wrappers, frame log, observers, and the pure maths (`node --test tools/tests/web_probe_kit.test.js`) | `tools/web_probe_kit.js` |
| The game's first-use marks and stopwatches, web only and off by default (flag `web_first_use_marks`) | `scripts/ops/first_use.gd` |
| The droid's budget table in busy ms and display Hz, and its day-10 lanes against the vsync steps | `python tools/web_measure.py --budget`, `--lanes` |
| The bench's pipeline column, labelled n/a on GL | `tools/tests/fp_bench.gd` (`pipelines_for`) |

## Run it

On a machine with a real GPU and a display (the numbers that count; label every run with the renderer
string it records):

```bash
DISPLAY=:0 NODE_PATH=<dir with playwright-core> node tools/web_fps_probe.js https://<host>/ <outdir>
```

Without a display (a sanity run: the WebGL call counts carry over, the milliseconds do not). Use an explicit
profile directory and delete it afterwards:

```bash
env -u DISPLAY GF_FPS_HEADLESS=1 GF_FPS_CHROME=/opt/google/chrome/chrome \
  GF_FPS_CHROME_ARGS="--use-angle=swiftshader --enable-unsafe-swiftshader --disable-dev-shm-usage --no-sandbox" \
  GF_FPS_USER_DATA_DIR=<scratch>/profile NODE_PATH=<dir with playwright-core> \
  node tools/web_fps_probe.js http://127.0.0.1:8080/ <outdir>
```

Every knob is optional; the defaults are the probe's setup before the kit (1600x900, DPR 1, headed
Chrome, 30 s settle, 20 s rows) with two rows added, `walk` and `orbit`. `GF_FPS_KIT=0 GF_FPS_FLAGS=none
GF_FPS_ROWS=street,sky` is the nearest to the old run (the display-rate sample and the flags file still run).
A knob the probe does not know, a value it cannot read, a flag name `data/feature_flags.json` does not
define, an empty `GF_FPS_ROWS` and `GF_FPS_AB` together with `GF_FPS_KIT=0` or `GF_FPS_GLHOOK=0` all stop
the run with exit 2 and a message: none is ignored.

| Knob | Meaning |
| --- | --- |
| `GF_FPS_VIEWPORT=WxH` | CSS viewport (default `1600x900`) |
| `GF_FPS_DPR=n` | Playwright `deviceScaleFactor` (default 1); the canvas grows with it, `canvas` in the output is its pixel size |
| `GF_FPS_HEADLESS=1` | `--headless=new`, muted; never opens a window |
| `GF_FPS_CHROME=<binary>` | Chrome to run (default `/usr/bin/google-chrome`) |
| `GF_FPS_CHROME_ARGS="..."` | extra Chrome arguments |
| `GF_FPS_USER_DATA_DIR=<dir>` | profile directory, made absolute (default: a temp dir, removed at the end). A fresh one is a cold Chrome GPU shader cache; run twice with the same directory for the warm-cache numbers. The driver keeps its own cache outside the profile: on Linux that is Mesa's, which is warm from the first run on, so a cold run needs `MESA_SHADER_CACHE_DISABLE=true` as well (the variable's name is from the Mesa docs and was not tried here). `env.cache` records `profile_fresh`, the Mesa switch, `cold` and `why`; item 10's leaning is only dropped or left inconclusive when `cold` is true |
| `GF_FPS_SETTLE_S`, `GF_FPS_WINDOW_S` | seconds before the first row (30) and per row (20) |
| `GF_FPS_ROWS=street,walk,sky,orbit` | which rows to measure |
| `GF_FPS_AB=<s>` | three pairs of windows of `<s>` seconds with the WebGL wrappers on and off on the idle street: what the kit costs on this game |
| `GF_FPS_KIT=0` | no init script at all (the old probe) |
| `GF_FPS_GLHOOK=0` | frame log and observers without the WebGL wrappers |
| `GF_FPS_FLAGS="a=1,b=0"` | feature flags written to `user://feature_flags.json` before the engine boots (the web build reads no environment); names are checked against `data/feature_flags.json`. Default `web_first_use_marks=1`; `none` writes an empty `{}`, so a reused profile loses the flags an earlier run left in it |
| `GF_FPS_SAVE=<path>` | seeds a `gridfall_save.json` first, to measure a grown city (see web-deploy.md) |
| `GF_FPS_MEMORY=0` | skip process RSS and `measureUserAgentSpecificMemory` |
| `GF_FPS_RAW=1` | keep every window's raw frames and events in `<outdir>/gl-raw-*.json` |
| `GF_FPS_AUDIBLE=1` | autoplay policy on and output unmuted, as a player has it (default: policy off, `--mute-audio`); see "Audio" below |
| `GF_FPS_NO_OCCLUSION=1` | exit 6 when the console shows an `occlusion` line (see web-deploy.md); also counted as `occlusion_lines` |

Exit codes: 0 done; 2 bad knob or crash; 3 the `GF_FPS_SAVE` city was not continued; 4 the round trip below logged an
exception (a `pageerror`, `SCRIPT ERROR` or invalid bus index, the orbit row's seconds included) or, with the
game's marks on, never logged `quit_to_orbit` (the blind navigation missed the button); 5 the WebGL census was
asked for and saw no draws (`kit_ok: false`); 6 `GF_FPS_NO_OCCLUSION` was set and an `occlusion` line showed.

The run ends with the exit_fp / enter_fp round trip (Planner view, Tab back), as before. The web game
always boots into first person; the `orbit` row is the Planner view reached through the pause menu's Planner view button (once "Quit to orbit"), and
`sky` is the Tab overview. (The overview swallows the first Esc, so the probe leaves it with Tab before
it opens the pause menu; the probe before the kit pressed Esc there and never reached Planner view.)

Two runs' call censuses compare with `node tools/web_probe_kit.js compare <a>/result.json
<b>/result.json [tolerance [street|walk|sky|orbit|all]]`. It exits 0 when, in every row both results hold,
the median framebuffer binds and passes agree within two calls and the median draws, program switches
and `useProgram` calls agree within the tolerance (default 15%), the draws are not zero, and the link
census (programs linked after the first draw, frames that held links) agrees within 10% or three. A row
of fewer than 20 frames has no stable median and is skipped, not failed.
It is the stability check of an idle street, and the before-and-after of a change such as item 14's
sky-write guard: judge that one on `fbo_binds` and `passes`, which do not move between boots of one
build, and take three or more boots per arm for anything that counts draws.

How stable the census is, from three identical software-WebGL runs of the live build (960x540, 20 s
settle, 12 s rows): `fbo_binds` was identical in every row of every run (street 34, walk 34, sky 35, orbit
49). `passes` is a count of render targets since attachments and the viewport origin joined its definition
(two runs re-measured after that, 960x540, 20 s settle, 12 s rows): street 21, walk 21, sky 20 and orbit 62 in
both. A result file from before the change holds the older count (16, 16, 15 and 21: one pass per
framebuffer and viewport size) and does not compare with a new one. The draws moved with the boot, not with the window: a
run holds its own count from boot on (street 874-886 inside one run) but the runs held 878, 782 and 804,
a spread of 12%, all of it in the individually drawn objects (537, 537 and 539 instanced draws); sky was
577, 578 and 582. Program switches on the street were 251, 242 and 247. The link census was 206, 206 and
194 programs in 21, 21 and 19 frames. The orbit row has 8 to 11 frames at 0.3 to 0.5 fps on software
WebGL, too few for a median: its program switches ran 287 to 348 in one run and 285 to 295 in the others,
so `compare` skips it there; a real GPU gives hundreds of frames.

## What it records

`<outdir>/result.json` (and the `GF_FPS_*` lines on stdout) carry, per row: the old `fps` and rAF
intervals; `busy_ms` (the time the rAF callbacks took on the main thread: script, physics and the GL
calls the engine makes in them); `late_ms` (how long after the vsync timestamp the callback began);
the call census; the pass table; the timed WebGL calls; program builds; long tasks; and the slow
frames with what they were spent on. A frame is whatever happens between two rAF timestamps.

- **Census** (`census`): per frame, draws (and instanced draws), `bindFramebuffer` calls, passes (a run of
  draws into one render target: one framebuffer, the same attachments, the same viewport rectangle; a new
  cube face, mip level or layer through `framebufferTexture2D`, `framebufferTextureLayer` or
  `framebufferRenderbuffer`, or a viewport at another origin, starts a new one. Scissor rectangles and
  `drawBuffers` are not watched), program switches (`useProgram` to a different
  program), uploads and their bytes. `pass_table` lists the passes of the typical frame by size. Draws,
  binds and switches are only counted; the calls that can block the main thread are timed.
- **Timed calls** (`gl_kinds`, `events`): `linkProgram`, `compileShader`, the status queries (the blocking
  point of a compile), `readPixels`, `texImage2D` and friends, `generateMipmap`, `bufferData`,
  `bufferSubData`, `finish`. Bytes are sized from the call (Emscripten passes its whole heap with an offset,
  so the view's length is not the size).
- **Builds** (`builds`, `link_builds`): one build is the compile, link and status calls of one shader
  variant. `n` counts programs after the first drawn frame; an *event* is a frame that held builds, and
  that frame's cost is what stalls. The engine's start-up runs in a task of its own, outside any rAF
  callback, and the page's own loader may already have run rAF frames by then: work outside a callback is
  booked to the last frame before it (builds carry `off`), and the first drawn frame is the first one that
  drew inside a callback. Builds after it count; start-up and the first frame's own builds do not.
  `off_raf` (per row) totals the timed GL, the draws and the builds that ran outside callbacks, which
  `busy_ms` cannot see; a slow frame's `off_ms` is what that frame ran after its callbacks.
  The grouping assumes the engine finishes one program before it starts the next (compile, status, link,
  status: what Godot's compatibility renderer does, and the 4.7.2 web template has no use of
  `KHR_parallel_shader_compile` in it). When a link or a compile begins before the last link's status was
  read, the engine batches: the calls and the milliseconds still add up and `events` and `total_ms` (what
  item 10's rule reads) are right, but a build is then no longer one program, so `n`, `max_ms`, `ge_100`
  and `ge_150` are not per program. `link_builds.batched` counts those cases after the first drawn frame (the
  old build's start-up links one program of its own and never reads its status, which overlaps the next
  program's calls three times before the first draw: not batching, and not counted; after the first draw it
  was 0), the probe prints a `GF_FPS_WARN` line, and `compare` leaves `n` out.
- **Lists and caps**: each drain (one per row boundary) keeps up to 6,000 events of each kind, 20,000 builds
  and 12,000 frames. Past that the newest event of that kind is dropped (the frame log drops its oldest
  frames) and counted: `dropped` (per row and
  segment, `by_kind`; run total `dropped`), with a `GF_FPS_WARN` line when builds or readbacks were dropped
  (uploads are dropped on any texture-heavy boot and decide nothing). The per-frame aggregates (`gl_kinds`,
  the census) still hold every call, so only percentiles, event counts and the builds list can be short.
  A texture-heavy boot is 4,500 events in one frame and an idle street about 80 events a second: a long
  `GF_FPS_SETTLE_S` or `GF_FPS_WINDOW_S` can reach the cap. Item 10 and item 16 say `no data` when builds or
  `readPixels` were dropped. The two lists then cover different stretches of the row, so the per-second
  rate of a kind's events (`events.<kind>.per_s`) is taken over the stretch its events cover: the whole row
  when only frames were dropped (the events are kept), up to its last kept event when its own budget ran
  out. `gl_kinds` has the rate of every call in the frames that were kept; a `GF_FPS_WARN` line says when
  frames were dropped.
- **Result fields besides the rows**: `schema` (1; `web_measure.py --probe-report` checks it), `hardware`
  (the renderer is not a software one: SwiftShader, llvmpipe, lavapipe, softpipe, WARP, no context),
  `kit_ok` (`true` the census saw draws, `false` it was asked for and saw none, `null` not asked for:
  `GF_FPS_KIT=0` or `GF_FPS_GLHOOK=0`), `decides`, `dropped`, `exit_fp` (`exit_clean`, `enter_clean`,
  `quit_marked`/`orbit_reached`: `null` without the game's marks, `transition_ms`), per row `kit_frames`,
  `kit_fps` (frames and rate of the kit's own log, beside the old `frames` and `fps`), `gl_on`, and in
  `env` the `drawing_buffer`, `context_attributes` and `kit.seen` (which observers the browser has). `loaf` is
  the long-animation-frame count and blocking time.
- **Slow frames** (`hitches`): one row per frame that ran long, the frame that did the work: its `busy_ms`,
  the timed GL share, the build share, the top three call kinds, the game's marks and the long tasks in its
  span, and `interval_ms`, the time from its timestamp to the next frame's. A callback that runs long delays
  the timestamp of the frame after it, so the long interval sits on the row of the frame that caused it, and
  the frame that merely arrived late is not a row. Interval far above `busy_ms` is waiting (on the GPU or
  the vsync), the two close together is main-thread work. The last frame of a window has no successor in
  it: `interval_ms` is null and the row stands on its busy time.
- **Environment** (`env`): viewport, DPR, canvas and drawing-buffer size, the WebGL renderer string,
  `threads` (the loader's `GODOT_THREADS_ENABLED`), cross-origin isolation, and the display rate. The
  display rate is the 2nd percentile of 5 s of quiet rAF intervals on the page before the game loads; the
  minimum is kept too. Headless Chrome has no display and answers with a virtual 60 Hz.
- **Memory** (`memory`): resident MB of the browser, GPU and renderer processes at boot and at the end
  (Linux and macOS, from `ps`), `performance.memory`, and `measureUserAgentSpecificMemory` when the page
  is cross-origin isolated (true behind the deployment's Caddy, not on a plain static server). That call
  runs last; it took 62 s on a software-WebGL run.
- **Overhead** (`overhead`, with `GF_FPS_AB`): the median busy p50 with the wrappers on and off, the
  spread between legs (`noise_ms`) and whether the difference is inside it (`within_noise`).

A sample, one idle street, a threaded build, software WebGL (a headless sanity run; it is slow, so the
counts are the point):

```
GF_FPS_ENV {"viewport":{"width":960,"height":540},"dpr":1,"canvas":{"w":960,"h":540,"cw":960,"ch":540},"hz":60,"threads":true,"coi":true,"hook":true}
GF_FPS_ROW street  fps 2.2 p50 366.7 p95 1666.6 max 2983.2 | busy p50 351.2 p95 1660.7 | draws 780 fbo 34 passes 21 switches 241 | builds 21 (1547.5 ms) | longtasks 29
GF_FPS_ROW orbit   fps 0.4 p50 2016.6 p95 3983.2 max 3983.2 | busy p50 1994.6 p95 3971.8 | draws 5665 fbo 49 passes 62 switches 342 | builds 13 (2571.3 ms) | longtasks 9
GF_FPS_BUILDS {"n":198,"total_ms":15188.29,"max_ms":2767.23,"ge_100":17,"ge_150":16,"events":19,"event_max_ms":2923.63,"events_ge_100":14,"events_ge_150":14,"batched":0}
GF_FPS_OVERHEAD {"delta_busy_p50_ms":15.37,"delta_pct":3.3,"noise_ms":57.62,"within_noise":true,"per_draw_us":19.78,"legs":6}
```

## Which output decides which backlog item

| Output | Decides |
| --- | --- |
| `link_builds` after the first drawn frame (events, total ms), `mark_links` | item 10: build a warm-up if cold-cache link time is at least 2 s or at least 3 events are at least 150 ms; drop it if each event is at most 100 ms and the total is under 1 s. `decides.item10_link_warmup` applies the rule and says `no data` (census off or empty, builds dropped), `withheld` (software renderer: the milliseconds say nothing about a real GPU; the program count was the same across three runs on one backend, SwiftShader, and that it carries over to ANGLE on a real GPU is untested) or `warm cache (...)` (`env.cache.cold` false: it can only confirm "build") instead of answering from zeros |
| `census` of the idle street, run with and without the sky-write guard | item 14: a drop in `fbo_binds` and `passes` is fewer render passes; the census splits passes by framebuffer, attachment and viewport rectangle but names one only by its target kind and size (the `pass_table` key), so that it is the radiance or glow work the guard removes is an inference to check in `pass_table`, not a measurement |
| `walk.events.readPixels` and `texImage2D` (p95, calls per second) | item 16: close if the `readPixels` p95 is under 3 ms and under 0.5 calls/s; the cheap tier from 5 ms. Per-second rates scale with the frame rate, so `decides.item16_readback` is `withheld` on a software renderer, and `no data` when the walk window held no `readPixels` and no `poster_composite` mark (a walk that never faced a poster measures nothing; needs a build with the game's marks) or events were dropped |
| `GF_FPS_DPR` and `GF_FPS_VIEWPORT` sweeps (`canvas`, row `busy_ms`) | item 7 |
| `first_use.item15_stream` | item 15: build if a stream of 5 s or more costs 3 ms or more per audio second and a 30 s bed costs 100 ms or more (a short stream's fixed cost would inflate its rate, so only the beds count; `max_ms_per_s_any` shows every stream). The first long stream played in a session pays a one-off first-play cost, so with two long streams or more it is left out (`first_left_out`, `first_long_stream`); the game plays the music stems first, so those two are the first two |
| `first_use.watches` for `save:stringify` and `save:file_write` | item 12 (only the part inside `SaveSlot.write`, see below) |
| `exit_fp.transition_ms`, the `to_orbit`, `orbit` and `to_street` segments | item 9 and the Planner round trip (item 13) |
| `memory` (RSS at boot and end, `uasm`) | item 21; run it at boot, day 3 and day 10 with `GF_FPS_SAVE` saves. A run makes one exit/enter cycle, so "after three cycles" is three runs' worth of separate boots, not one |

## Game-side marks

With the `web_first_use_marks` flag on (default off) the web build prints one console line per event and
makes a User Timing mark `gf:<tag>` with the same record as its detail; nothing leaves the browser.
The probe turns the flag on through `user://feature_flags.json`. On a desktop build, or with the flag off,
`FirstUse` does nothing.

```
FIRSTUSE {"tag":"lamp_pool","n":1}
FIRSTUSE {"tag":"play:rain.ogg","n":1,"ms":2.31,"len":30.0}
```

Marks (first sight): `lamp_pool`, `beam`, `overview` (Tab), `pause_menu` (Esc), `quit_to_orbit`, `beacon`,
`site` (a construction site's parts are built), `poster_composite`, `rain`. Stopwatches: `play:<stream file>`
around the first three `play()` calls of each stream (the register-as-sample cost, with the stream length so
a reading can be put per audio second; the residential bed is a looping duplicate with no file, so it reads
`play:OggVorbis@<length>s`) and `save:stringify`, `save:file_write` inside `SaveSlot.write`.
A mark is logged for its first 3 sightings, a stopwatch for its first 3 readings (a save for its first
100). The probe attributes the builds that follow each mark (`mark_links`): first sight should show
builds above 0 and a repeat 0. Only these marks count: each carries its record as `detail` with a string
`tag`. Other `gf:` marks (the boot clock's stage marks, the loader's) have none and are ignored there,
though they still show in a slow frame's `marks`. `rain` is marked when the rain emitter first goes on, which
is also the first boot of a fresh profile (the default city's day 1 is rain), a load into a rainy day and a
forced start, not only a day roll from clear.
`tools/tests/fp_first_use_test.gd` pins the helper and `SaveSlot.write`; `fp_first_use_sites_test.gd`
drives every mark except `beam` and `poster_composite` through the real game code; and
`tools/pytests/test_web_probe_kit.py` holds all nine to one call site each and to this list.

Not marked, because the code is in files another lane edits: the `_write_save` stages before the file is
written (`view.flush_rebuild_queue`, each `to_dict`), `view.setup` and `set_fp_mode` phases, and cold
`_scene()` loads. `FirstUse.begin(kind, what)` and `FirstUse.end(kind, what, stamp)` are the stopwatch
API to put there. Until then, the frame that held an autosave shows its whole `busy_ms` in `hitches`;
that minus `save:stringify` and `save:file_write` is the canonicalise, `to_dict` and cache work. The `site`
mark is made when `ConstructionKit.build_site` puts the parts in the tree, which is a frame or more before
they are first drawn (the same holds for `beacon`), so its builds can start after the attribution window.

## The budget in busy ms and display Hz

On a vsync-locked display the interval between frames is a whole number of refresh periods, so a CPU
saving shows nothing until the frame's busy time crosses a vsync boundary: 34 ms busy shows 20 fps on 60
Hz and 31 ms shows 30. The droid measured on a 144 Hz display (its live p50 and p95 are exact multiples
of 6.944 ms), so each row is a range of busy time, and a 60 Hz or 120 Hz display shows something else.

```bash
python tools/web_measure.py --budget --hz 60 --hz 120            # the droid's rows (add --json for data)
python tools/web_measure.py --lanes                              # its day-10 lanes against each display's steps
python tools/web_measure.py --probe-report <outdir>/result.json  # a probe run the same way
```

```
row                              measured  vsyncs     busy ms | display   shows ms       fps         cut for a step  where
day-10 street, p50                   41.7       6   34.7-41.7 |    60Hz         50        20             1.4-8.3 ms  live 23.4 fps
day-10 street, p95                   62.5       9   55.6-62.5 |    60Hz       66.7        15            5.6-12.5 ms  live, same window
day-10 street_tick, p50              56.2    8.09   48.6-55.6 |    60Hz    50-66.7     15-20   0-5.6 | 15.3-16.7 ms  bench 17.5 fps (v4)
```

"Cut for a step" is the milliseconds to take off to show one vsync less on that display. The day-10 street
needs 1.4 to 8.3 ms to go from 20 to 30 fps on 60 Hz: the in-flight CPU lanes (a few ms each) read as 0
fps until their sum crosses it. Two ranges (`0-5.6 | 15.3-16.7`) mean busy straddles a boundary.

`--lanes` does the same for the droid's day-10 attribution table (`street_tick`, 57.1 ms: render CPU 13.0,
traffic 3.5, sim 3.8, animals 1.6, Weather 1.5, audio 1.2, CityView 1.1, everything else 1.5, and a 30 ms
engine and browser floor that is a residual): the frame rate each display shows if one lane cost nothing.

```
lane (street_tick, day 10)                                        ms  share  busy if free |    60Hz   120Hz   144Hz
frame as measured                                               57.1   100%     50.2-57.1 |      15    17.1   16-18
render CPU                                                        13  22.8%     37.2-44.1 |      20   20-24 20.6-24
traffic_feature                                                  3.5   6.1%     46.7-53.6 |   15-20 17.1-20 18-20.6
engine/browser floor (residual)                                   30  52.5%     20.2-27.1 |      30   30-40   36-48
in-flight lanes: traffic_feature + animals_feature + Weather     6.6  11.6%     43.6-50.5 |   15-20 17.1-20 18-20.6
```

On 60 Hz only the render CPU lane or the floor changes the rate for certain (15 to 20 and 15 to 30 fps).
The three in-flight CPU lanes together, 6.6 ms, land on 15 or 20 fps depending on where in its 7 ms
range the frame's busy time sits, which the interval cannot say: read `busy_ms` from a probe row. These
are the steps of a percentile or of one busy time. A mean over frames that spread across several vsyncs
(the day-10 street's p50 and p95 are 21 ms apart, more than a 60 Hz period) moves smoothly with every
millisecond saved, so judge a change by the p50 and `busy_ms`, not by a mean fps.

## Water look check

`tools/web_water_shots.js` boots a web build with a seeded save, puts the hero at a pose, hides the HUD and
saves the canvas, then prints the mean colour, luminance spread and distinct colours of a patch (the lower
half by default). The river rendered as a pale slab on the web because the water shader read depth with the
Forward+ formula under gl_compatibility; its spread was 2.4 of 255 over 900x300 px, real water is above 15
(`--min-std 8` fails a flat one). Pass the poses on the command line, for example the bank, a wade and a
dusk shot (tick 2 with `--settle-ms 1500`). The sky is not part of a pose: the game recomputes the weather
from the seed and the sim day on load, so pick it with `--day N` (for the seed-31767 save used here, day 11 is
clear, 9 rain, 10 overcast; `Weather.daily_state(seed, day)` gives it for any other save):

```bash
NODE_PATH=<dir with playwright-core> node tools/web_water_shots.js http://127.0.0.1:8080/ out save.json \
  --min-std 8 bank:27.44,7,-90,-4,first,1 wade:27.625,7,-90,-10,third,1
```

Cost: the on-foot water shader reads 7 textures per pixel (5 normal, 1 noise, 1 depth) against 3 before, plus
the finer shore quads and the ground shader's shore terms. At 1280x720 the frame is CPU or vsync bound and shows
no difference (about 100 fps either way), so that run says nothing about shader cost. With the frame limiter off
at 2560x1440, water filling the view, on an integrated AMD Renoir the new build measured about +1.3 ms a frame
(14.6 to 16.0 ms, about 9%) in a review; the split between water, shore and ground was not measured and no GPU
timer was used. Weaker web GPUs in water-heavy views should expect at least that.

## Limits

- Only a real GPU run decides the millisecond rules. Software WebGL (SwiftShader) is a JIT rasterizer, not a
  stand-in for Mesa on a GPU, which is itself not one for ANGLE/D3D11. What may carry over are the per-frame
  counts (draws, passes, binds per frame) and the programs linked, which were identical across three runs on
  one backend; calls per second do not, they scale with the frame rate (2.7 uploads a second at 2.7 fps is one
  a frame).
- Record which build ran: `threads` is in the output. The runbooks disagree on whether the live image is
  threaded (web-threads.md versus web-deploy.md).
- The wrappers cost about 0.09 to 0.13 us per wrapped call: +0.12 to +0.17 ms per frame at the idle street's
  call mix (1,305 real WebGL calls a frame: 863 draws, 356 `useProgram`, 34 framebuffer binds, 52 uploads),
  from three runs of five interleaved rounds (300 to 600 frames each) on a cross-origin-isolated page with a
  5 us timer, the GPU process kept idle with rasterizer discard. The last run: 0.140 ms a frame without the
  kit, 0.255 with it, 0.135 with only the frame log (`GF_FPS_GLHOOK=0`). That is about 1% of the day-1 street's 13.9 ms
  p50 frame and 0.3% of the day-10 street's 41.7 ms. `GF_FPS_AB` measures it on the real game; with GPU-bound
  frames it reads as noise (software WebGL: +0.7 ms of 294 inside a 37 ms spread).
- A headed Chrome on Wayland throttles an unfocused window to about 1 fps: run on X11 with the window focused.
- `MEMORY_STATIC` and `OBJECT_ORPHAN_NODE_COUNT` read 0 on release web templates, and the bench's
  `PIPELINE_COMPILATIONS_*` counters read 0 on gl_compatibility (they belong to the RenderingDevice), so the
  bench labels them `n/a` there. Count links with this kit instead.

## One tab, bounded waits (the hang)

The probe used to open a second tab for `chrome://gpu` and a third to seed IndexedDB. With another tab in
front, Chrome stops the game tab's `requestAnimationFrame`: the display-rate sampler and every fps window then
waited for frames that never came, and the run hung without an error. Now the whole run uses **one tab**
(`chrome://gpu`, the seed, the Hz sample and the game load one after another in it) and calls `bringToFront()`
before the rows. The Hz sample (30 s), the boot wait (15 min, then exit 2 with the console in `console.log`) and
every fps window (its length plus 60 s) are bounded and reject instead of waiting. A run that dies still
writes `console.log`, and one `GF_FPS_STEP <time> <phase>` line per phase goes to stderr (browser up,
`chrome://gpu`, seeding, display rate, loading the game, booted, each row, the round trip), so a run that
stalls says where; `result.json` itself is only written at the end.

A third way to hang is closed. A page whose WebGL2 context cannot be created prints `The following features
required to run Godot projects on the Web are missing: WebGL2 - Check web browser configuration and hardware
support` and sits there, and the boot wait looked for a line that would never come (15 minutes, silently). It is
**intermittent** on this shared machine (2026-11-03: 4 of 9 headless runs with a real GPU, with and without
`--disable-gpu-vsync --disable-frame-rate-limit`, so those flags are not the cause; a busy GPU process is the
likely one, not established). The probe now **reloads the page up to twice** when the engine reports it, then
fails at once (exit 2, the line in the message) instead of waiting out the watchdog. It also no longer creates a
WebGL context of its own before the engine starts (it did, on a throwaway canvas, to read the renderer string;
whether that ever contributed is not established): the renderer is read from the game's own canvas after the boot.

With a **reused profile** (`GF_FPS_USER_DATA_DIR`) remember that the orbit round trip at the end autosaves the
city: the next run on that profile *continues* that city (a later day, other weather, a different density)
instead of starting day 1. Use a fresh profile for comparable numbers, or seed the same save each time.

## Audio

`tools/web_fps_probe.js` runs with the autoplay policy off and (headless) muted, and the smoke filters
`AudioContext` console lines: none of them can tell a silent game from a playing one, and the web build
shipped silent for every player because of it (web-deploy.md, "Web audio"). Two additions:

- `GF_FPS_AUDIBLE=1` runs the probe with the policy on and the output unmuted. It still does not measure sound.
- **`tools/web_audio_probe.js`** is the audio check. An init script wraps `AudioContext`, routes its destination
  through a pass-through gain with an `AnalyserNode` and samples the peak every 30 ms. It boots the game with
  `--autoplay-policy=document-user-activation-required` and **no** `--mute-audio`, clicks once, walks, and exits
  1 when the destination peak stays under 0.01 for the 20 s after boot or the context is not running (0
  pass, 2 the game never booted, 3 `--suspend` mode failed). `--suspend` holds the context suspended until a
  real gesture to prove the "Sound is off - click or press any key" banner and the gesture resume, a case a
  headless Chrome never hits by itself. One tab, `--gpu` for a real GPU, screenshots (`banner.png`) and
  `audio-result.json` in the output directory. `node --test tools/tests/web_audio_probe.test.js` covers the
  verdict and the tap offline; `python -m pytest tools/pytests/test_web_audio.py` reads the export's `.pck`
  (`GF_WEB_PACK=<index.pck>`, else the newest under `build/web`).

```bash
NODE_PATH=<dir with playwright-core> GF_AUDIO_CHROME=/opt/google/chrome/chrome \
  node tools/web_audio_probe.js http://127.0.0.1:8080/ <outdir> --gpu            # sound check
  ... node tools/web_audio_probe.js http://127.0.0.1:8080/ <outdir> --gpu --suspend  # banner check
```

`AUDIOSEC {"ms":{...}}` console lines (the game, with flag `web_first_use_marks` on, every 10 s) carry the slowest
frame of each audio section (`falls`, `emitters` and its `refresh*` and `assigned` parts, `ambience`,
`footsteps`, `duck_reverb`); the probe's `result.json` has them as `audio_sections` (`max` per section, `worst`).

## Stripes (shadow-map acne on the roads)

`result.json` `stripes` is the **clear-sky stripe pose** (`stripePose` in `web_fps_probe.js`). A fresh profile's day 1
is clear all day (flag `first_day_opening`), so the sky cannot hide the acne of the street sun, which is how it went
unseen before (overcast light casts no sun shadow). Straight after boot (about 07:30: the sun is lowest, the pedestrians
and the HUD cards have not come, the hero has not moved) the probe presses V for the first-person camera, moves the
mouse down 174 px so the plaza's sidewalk fills the lower frame, screenshots it (`stripes.png`), and puts the camera
back. Nothing is placed by a hook: only keys and the mouse. It scores the band `STRIPE_BAND` (66 to 84% of the width,
55 to 72% of the height: the sidewalk right of the fountain, clear of the HUD, the trees and the hero's shadow) with
`rowProfileRms`: the rms, in grey levels, of the row-mean luminance minus its own smoothing (10 rows). The verdict is
`stripeVerdict`: `ok` while the reading is at most `STRIPE_MAX` (2.0), and the probe exits **7** when it is not.

Measured through the probe on local exports, three runs of each: **0.71, 1.15 and 1.19** with the fixed street sun
(normal bias 1.5), **2.75, 2.89 and 2.99** with the bias put back to 0.6 (a build made for that comparison and
discarded). Both frames were looked at: the old bias shows the owner's horizontal bands across the whole sidewalk
and paving, the fix is clean. The pose is a fixed early moment on purpose: a later frame (08:00, pedestrians and a
card in the band) read the old bias at 1.49, below the limit, so do not move the pose to a later time. Skipped, with
`stripes: {skipped}`, under `GF_FPS_SAVE` (the sky is the save's weather) and with `GF_FPS_STRIPES=0`.

The older band-pass metric `dogRms` (luminance blurred at 1.5 px minus 5 px) stays in `web_probe_kit.js` for stripes
that tilt or curve (a road seen at an angle), which a row profile averages away. It reads the texture of whatever
lies in its box: on this plaza pose it did not tell the fix from the old bias (4.77 against 4.87), so the probe does
not judge with it. Use it only to compare two builds on one pose, never against zero.

