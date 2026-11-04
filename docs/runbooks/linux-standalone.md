# Standalone Linux build (presenter machine)

A native x86_64 Linux build of the same game, for one machine: the presenter's laptop or desktop on 12 Nov,
while the audience plays the web build. It runs the Forward+ renderer (FSR2 upscaling from 0.77 of the window on the
default Medium preset) with full-size textures, with no browser in the way. This runbook says when to use it, how to build, package, run and
benchmark it, how it differs from the web build, and what has and has not been measured.

## When to use it

- **Use it** to present from a Linux machine with a Vulkan GPU: a higher render scale than the web build (0.77 FSR2
  against its 0.6), SSAO, soft shadows, a 4096 shadow atlas, full-size textures, and no WebAssembly or WebGL
  translation layer between the game and the GPU.
- **Do not use it** as the thing the audience plays: it is a 470 MB download, not a link. Players keep using the
  web build ([web-deploy.md](web-deploy.md)).
- Windows presets (`Windows Desktop`) exist in `export_presets.cfg` and `tools/export.sh windows` runs, but a
  Windows build is not built, packaged or tested here.

## Build and package

```bash
. ~/.venvs/gridfall-tools/bin/activate
tools/export.sh linux                  # build/linux/gridfall.x86_64 + gridfall.pck, about a minute
tools/package_linux.sh                 # export, then build/gridfall-linux-x86_64-<VERSION>-<rev>.tar.gz (+ .sha256)
EXPORT_DIR=/some/dir tools/package_linux.sh      # everything under /some/dir instead of build/
tools/package_linux.sh --skip-export   # package the export that is already in $EXPORT_DIR/linux/
```

Needs the export templates for the version in `.godot-version` (`tools/export.sh` prints the install commands
when they are missing). The archive holds, under one folder of its own name: `gridfall.x86_64`, `gridfall.pck`
(kept beside the program; not embedded), `run-gridfall.sh`, `README-linux.txt`, `LICENSE`, `VERSION` and
`THIRD-PARTY-LICENSES/` (the model, character and font licence texts). The
same inputs give the same bytes (fixed owner and file time, `gzip -n`; the file time is the commit time unless
`SOURCE_DATE_EPOCH` is set). No key is read, printed or packed. The export log goes to
`$EXPORT_DIR/package-linux-export.log`.

Sizes of the 2e57576 build: program 73,519,416 bytes (70 MiB), pack 655,026,180 bytes (625 MiB), archive
471,845,285 bytes (450 MiB), about 695 MiB unpacked. The pack is four times the web pack (about 161 MB) because
the web export caps most textures at 256 px; the desktop keeps them at full resolution.

## Run

On the presenter machine:

```bash
sha256sum -c gridfall-linux-x86_64-*.tar.gz.sha256
tar xzf gridfall-linux-x86_64-*.tar.gz && cd gridfall-linux-x86_64-*/    # trailing slash: the folder, not the .tar.gz files beside it
./run-gridfall.sh                         # windowed 1600x900, Vulkan when available, else OpenGL 3
./run-gridfall.sh --fullscreen
./run-gridfall.sh --renderer opengl3      # Compatibility (the web build's renderer) if Vulkan misbehaves
./run-gridfall.sh --offline               # never call GMI Cloud, whatever key is on the machine
./run-gridfall.sh --orbit --offline       # top-down builder (see "Sim slicing" below), offline
GMI_API_KEY=<key> ./run-gridfall.sh       # mayors think live (or paste the key in the game)
```

**Which key the game uses.** The launcher reads no key, but the game does: `GMI_API_KEY` first, and when that is
unset, the `gmi-serving.com` entry under `customModels` in `~/.factory/settings.json`
(`GmiClient._resolve_api_key`). So a presenter machine that has that file goes live without being asked, which can
spend credits, hit rate limits, or differ from the recorded replay. For a guaranteed offline run pass `--offline`
(sets `GRIDFALL_OFFLINE=1`, which the game honours over any key). The key goes only to GMI Cloud:
`api.gmi-serving.com` for the mayors and `console.gmicloud.ai` for the poster images.

`--renderer auto` (the default) uses Vulkan when a loader (`libvulkan.so.1`) and a driver description
(`icd.d/*.json`) exist, and OpenGL 3 otherwise; if the game exits non-zero within 20 s on the Vulkan it picked,
the launcher starts it once more on OpenGL 3. An explicit `--renderer` is never retried. The launcher sets no
key and writes nothing; `--dry-run` prints the command it would run.

**Start it once, ahead of time.** The first launch compiles shaders (a stutter for the first minute); the
driver's pipeline cache under `~/.local/share/godot/` makes the next launches smoother, so do a full run on
the presenter machine the day before and again just before going on stage.

## Requirements

- x86_64 Linux with glibc 2.28 or newer (the program links nothing newer; measured with `objdump -T`).
- A Vulkan 1.2 GPU: Mesa RADV or ANV, or NVIDIA driver 470 or newer, with the Vulkan loader installed. Without
  one, `--renderer opengl3` needs OpenGL 3.3 (the Compatibility renderer).
- About 700 MiB of disk. GPU memory: see [gpu-memory.md](gpu-memory.md); the game switches itself to a lighter mode
  on a card with 4 GB or less, an integrated GPU or little free memory (`GRIDFALL_LOW_VRAM=1|0` forces it).
- A display. The benchmark and the game open a real window; nothing here runs on a headless server except the
  logic checks.

## Benchmark it (the owner's one-liner)

Opens a 1600x900 window on your display for about two minutes per renderer, twice. Run it in your own terminal,
on the machine you will present from, with nothing else heavy running:

```bash
tools/bench_linux.sh
```

It runs the windowed benchmark that `tools/gate.sh render` runs (`tools/tests/fp_bench.gd`: grow a city
offline, measure the street on foot with and without the HUD, three quality presets, the third-person camera, a
sim tick and a day change) once with `--rendering-method forward_plus` and once with `gl_compatibility`, then
prints one table (p50, p99 and fps per row for each renderer, the fps ratio, frames over 33 ms, slow frames that
compiled shader pipelines) and a verdict line of the form `VERDICT: Forward+ (Vulkan) is N% faster than
Compatibility (median fps ratio R over K rows): use --renderer vulkan` (or a tie inside 5%, or Compatibility
faster).

Read the verdict for what it is:

- **Native against native only.** It prints no web number and no web-against-native verdict.
- **Renderer plus scale plus antialiasing.** The benchmark sweeps Low, Medium and High on the street rows, and the verdict takes one median over all common rows. Medium is FSR2 at 0.77 without MSAA on
  Forward+ and bilinear at 1.0 with MSAA 2x on Compatibility, so a difference is not the renderer alone.
- **The editor binary**, `godot --path .` on the imported project, not the exported release build.
- **A cold pipeline cache.** Each run gets a fresh `XDG_DATA_HOME`, so Forward+ compiles its shaders from scratch and
  the shader-hitch column is a first-launch count; the warm-cache figure the Run section recommends is not measured.
- **Only 12 slow frames per row** are kept in detail (`MAX_HITCHES` in `fp_bench.gd`); the table prints a `CAVEAT`
  when a row hit that cap, when a row was not measured at 1600x900 (a window manager can shrink the window) and when
  the benchmark printed `FPBENCH: WARNING` (for example a hidden window). `tools/gate.sh render` fails on the size
  case; this script only warns.

It refuses to run without
`DISPLAY` or `WAYLAND_DISPLAY`, forces vsync off so a fast GPU is not capped at the monitor's refresh
(`--vsync` keeps it on), waits for the heavy-run lock so a gate does not skew it, and needs the imported project
(`tools/setup.sh`). Logs and screenshots land in a new `gf-bench-linux-*` folder under `/tmp/claude-1000`
(`--out DIR` to choose). `tools/bench_linux.sh --compare A.log B.log` prints the table from two saved logs with
no window. Shader-compile counts exist only for Forward+: the engine reports no pipeline counters on
Compatibility, and the table says `n/a` there.

The fps this prints is capacity with vsync off. The number a viewer sees is capped at the refresh rate, so read
p99 as the smoothness figure and p50 as the headroom.

## How it differs from the web build

| | Web (GMI AgentBox) | Linux standalone |
| --- | --- | --- |
| Renderer | Compatibility (WebGL2 through ANGLE), set by `rendering_method.web` | Forward+ on Vulkan by default (`--renderer opengl3` for Compatibility) |
| Resolution and textures | 0.6 render scale on the Low tier, 1024 shadow atlas, most textures capped at 256 px, no SSAO | Forward+ on the default Medium preset (`scripts/fp/render/quality.gd`): FSR2 at 0.77 of the window (0.59 Low, 0.9 High), no MSAA (FSR2 brings its own temporal AA), 4096 shadow atlas (2048 Low), SSAO and soft shadows, full-size textures. On Compatibility (`--renderer opengl3`) Medium is bilinear at 1.0 with MSAA 2x, and SSAO stays on at scale 1.0 |
| Threads and headers | WebAssembly threads need COOP/COEP (`deploy/web/` Caddy sets them) | none; native threads |
| Shaders | linked synchronously in the browser (about 198 programs, 11.4 s, in the boot's first draw, plus 83 to 84, 4.2 s, in the first 90 s of play; see `web-probe-kit.md`) | compiled by the driver on first use, kept in its pipeline cache |
| GMI key | each player pastes their own (Esc, Settings, GMI Cloud); "Remember" uses localStorage | `GMI_API_KEY` in the environment, else `~/.factory/settings.json` if present (the game reads it), or paste it in the same panel: kept in memory for that session only; `--offline` forces offline |
| Saves | IndexedDB in the browser | `user://`: `~/.local/share/godot/app_userdata/GridFall — GMI Cloud Multi-Model Crisis Sim/gridfall_save.json` (+ `.bak`) |
| Sim slicing | first person: sliced (4 ms a frame). Planner (orbit): kept on by `web_sliced_planner` to avoid whole-tick stalls | first person: sliced. Planner (`--orbit`): off, so whole `step_tick()`s, about 250 ms each on the day-10 grown city (measured below), several per 12 s game day. Faster than the browser's whole ticks, but hitchier than the web Planner's sliced ticks |
| Distribution | a link | a 450 MB archive |

Everything in `scripts/` is the same: the same sim, the same five mayors, the same replay cache. Offline (no
key), the mayors replay `data/gmi_replay_cache.json`, then the built-in planners.

## Measured and not measured

Measured on 2026-11-04, on one Linux box (16 cores, shared with other jobs, so the spread matters), headless
and offline, with real GDScript and no window. The first four rows ran on the **editor binary**
(`godot --headless --path .`, dummy renderer), not on the exported `gridfall.x86_64`; only the last row used the
export. The editor binary is probably no faster than the release export, so these are not flattering, but that
is an expectation and was not measured.

| What | Native Linux, editor binary (3 runs) | Web, from earlier probes (not re-measured here) |
| --- | --- | --- |
| Whole `step_tick()` on the day-10 grown save (seed 31767, 6,020 active tiles) | p50 250.4, 250.8, 250.6 ms; all 48 ticks 245.8 to 260.4 ms | whole-tick stalls of 540 to 670 ms in the Planner before slicing (include a 95 ms save and other frame work, so the sim part is less; [web-deploy.md](web-deploy.md) "Planner stalls") |
| The same, sliced at 4 ms (what the web Planner runs) | 540 pumps for 8 ticks; pump max 4.10 to 4.26 ms, p95 3.97 to 3.98 ms (the sim's share of a frame only) | frame p99 100 ms with slicing: a whole-frame figure (render included), so the two are different quantities and do not compare |
| Fresh city, day 12, `step_tick` (`tools/profile_sim.gd`, seed 7) | 53.9, 54.0, 54.7 ms | not measured |
| Traffic `step` + `sync_visuals` per frame (`tools/traffic_perf_probe.gd`, fresh-city street, 121 cars, 19 walkers) | 0.575 to 0.578 plus 0.612 to 0.632 ms (p95 1.29 to 1.30 and 0.62 to 0.70) | `traffic_feature` 3.5 ms per frame on the day-10 street ([web-probe-kit.md](web-probe-kit.md) lanes table); another scene, so only the direction compares |
| Whole-process boot, then the orbit smoke (`GRIDFALL_SMOKE_TEST=1`) of the exported binary | default boot 600 frames: exit 0, no script or load errors; smoke: `GRIDFALL_SMOKE: PASS` (day 6, save and load round trip, earthquake resolved, 55 residents) | n/a |

Reading, with the caveats up front: the whole-tick comparison is not like for like. The native 250 ms is the sim
alone on this box; the browser stalls are whole-frame stalls that [web-deploy.md](web-deploy.md) gives as 540 to
670 ms in one place and 450, 517 and 650 ms in another, the larger ones carrying a 95 ms autosave, and the doc does
not record whether the web probe used the same day-10 save. Raw, that is 1.8 to 2.7 times; with the 95 ms save
taken out of each browser stall it is about 1.4 to 2.3 times. Say "somewhere between about 1.4 and 2.7 times
cheaper natively" and no more; it is an inference from two probes on different days.

**What that does not say.** The desktop Planner (`--orbit`) runs whole ticks (see "Sim slicing" above), so at day 10
it has a stall of about 250 ms several times per 12 s game day (a re-run of the probe gave p50 252 to 262 ms, max 285
ms), where the shipped web Planner is sliced and measured a frame p99 of 100 ms. On a grown city the native Planner is
therefore probably hitchier than the web Planner, not smoother. First person is sliced on both and is unaffected.
Present from first person, or turn the Planner's slicing on for desktop: `SimPerfFeature.keeps_slicing()` only returns
true for the web, and changing that is a `scripts/` edit that this unit does not make, so it is a follow-up for
whoever owns that file.

**Not measured, because it needs a window:** GPU frame time, frames per second and hitches of Forward+ against
Compatibility, and of either against the web build; the shader-compile hitch count on Vulkan; real audio. The
expected direction, which is an inference and not a result: the web build is CPU-bound at 0.6 render scale in
headless Chrome (a street busy p50 of 16 to 19 ms on the Low tier, [web-deploy.md](web-deploy.md)), because the
wasm main thread runs the game and ANGLE translates every draw call to a driver, with shaders linked synchronously.
Natively the same CPU work is cheaper and draw submission through Vulkan is cheaper per call, so CPU-bound
scenes should gain most. Native renders somewhat more pixels per frame: Forward+ Medium is 0.77 against the web's
0.6, about 1.65 times the pixels for the same window, plus SSAO, soft shadows and a 4096 atlas; Compatibility Medium
at 1.0 with MSAA 2x is about 2.8 times. On a weak or integrated GPU the native build can therefore be slower than the
web build at 0.6 scale. `tools/bench_linux.sh` does not settle that: it compares the two native renderers with each
other and produces no web number (see below). Until someone measures the web build and the native build on the same
machine, same scene and same window size, "the Linux build is smoother on the presenter's GPU" is a prediction.

## Known limits

- Linux x86_64 only; no ARM, no Windows or macOS build is produced or tested here.
- Not exercised by a person: the windowed game on real hardware, fullscreen, audio through PulseAudio or
  PipeWire, gamepad. The exported binary has only been run headless (dummy renderer, dummy audio).
- The default boot is first person; `--orbit` is the top-down builder.
- Saves do not carry between the browser and the desktop.
- The desktop build still includes `data/gmi_replay_cache.pre_residents.json` (198 KB, unused; the web preset
  excludes it).
- Every headless boot, source or export, ends with six `ERROR:` lines about resources and RIDs leaked at exit from the
  dummy renderer. Now and then a boot also logs one to seven startup errors (`Initializing already initialized RID`,
  `Parameter "mem" is null`, `mesh_add_surface ... "m" is null`, `unimplemented base type encountered in renderer
  scene cull`, `texture_2d_initialize ... "t" is null`): 6 of the 18 headless boot logs a reviewer kept (packaged
  binary and source), which all still exited 0 and passed the smoke test. They come from the engine's dummy renderer
  (`servers/rendering/dummy`), which a windowed run does not use, so they are a headless-only artefact; do not make a
  CI check fail on `ERROR` in a headless boot log. This is the reviewer's tally; it was not re-run here.
- The archive carries the third-party licence texts the repository keeps beside the models and fonts, under
  `THIRD-PARTY-LICENSES/`. Texts that exist only in a vendor's download page are not in the repository, so not there.
- The launcher's Vulkan check is a file check (loader and `icd.d`), not a probe; a driver that is installed
  but broken is caught only by the 20 s retry.

## Troubleshooting

- **Black window, a crash at startup or `Unable to create RenderingDevice`:** `./run-gridfall.sh --renderer opengl3`;
  update the GPU driver; `vulkaninfo --summary` lists the Vulkan devices. Out-of-memory (`VkResult -2`) is in
  [gpu-memory.md](gpu-memory.md).
- **No Vulkan:** install the loader and a driver (`libvulkan1` and `mesa-vulkan-drivers`, or the NVIDIA driver), or
  run with `--renderer opengl3`.
- **No sound:** the game uses PulseAudio or PipeWire through its pulse layer. Check the system output with another
  program, start the launcher from a terminal, and try `./run-gridfall.sh -- --audio-driver ALSA` (or
  `PulseAudio`). The buses come from `default_bus_layout.tres`, which the export puts in the pack (the web export
  has to stage it by hand; the Linux export includes every resource). If the log says `invalid bus index`, the
  pack is missing it: rebuild with `tools/package_linux.sh` and check the warning it prints.
- **Frozen or tiny window on Wayland:** `./run-gridfall.sh -- --display-driver x11`.
- **Stutter in the first minute:** shader compilation; let it settle, or run once before presenting.
- **Mayors go live when you wanted offline:** the game found a key in `~/.factory/settings.json`. Start with
  `./run-gridfall.sh --offline`.
- **Mayors never go live:** no key reached the process. `echo ${GMI_API_KEY:+set}` in the same shell; or paste it
  in Esc, Settings, GMI Cloud. See [gmi-outage.md](gmi-outage.md) for the replay and breaker behaviour.
- **Check the export:** `tools/export.sh linux`, then run the binary headless and offline for the logic check:
  `GRIDFALL_OFFLINE=1 GRIDFALL_SMOKE_TEST=1 build/linux/gridfall.x86_64 --headless` ends in `GRIDFALL_SMOKE: PASS`.
