# Web demo deployment (GMI AgentBox)

The web build is how people try GridFall without installing anything. `tools/export.sh web` runs
`tools/web_export.py`, which builds an isolated staging copy of the project (never the source
tree), caps the prop and character textures at 256 px, converts every WAV to Ogg (it loops only the ones whose import says loop_mode Forward, Ping-Pong or
Backward, 2-4: 1 is Disabled, which is what the one-shots use; the music dir always loops), exports the
Godot 4 web build, aliases duplicate PCK payloads to one copy and publishes the result
under a content-addressed `releases/<hash>/` directory. The `.pck` that ships is ~161 MB instead of
~654 MB, and one release directory is ~192 MB on disk. A first visit moves ~113 MB (Brotli; 113.4 MB
measured against the live deployment on 2026-10-28). `deploy/web/` serves
it from Caddy, a static file server only — players' browsers call `api.gmi-serving.com` themselves
with each player's own GMI key (CORS allows it), and without a key the game runs offline (replay
cache, then heuristics). There is no server-side key by design.

The source Web preset now enables Thread Support. The recorded live image (`f762234`, no-threads)
predates the threaded rollout; merging the preset does not change a running deployment. See [the six-surface thread audit and A/B evidence](web-threads.md)
before building or deploying the threaded variant. The size figures above describe the recorded
Phase A deployment, not the later ground-texture-capped staging used in the A/B experiment.

## Build and ship a new image

1. `tools/export.sh web` — needs `ffmpeg` with libvorbis and the `web_release.zip` export
   template (see the script's help for the one-time install). `EXPORT: PASS` ends the run and
   `build/web/build-report.json` records the cap/audio/dedup numbers and the release version.
   The script deletes the previous export first; the source assets and desktop imports are never
   touched. Like `tools/gate.sh`, it takes the heavy-run lock itself per step (`flock -w 3600`
   on `$GATE_TMP/gf-heavy.lock`): never wrap it in a manual `flock` of the same lock — the inner
   acquisition cannot succeed while its own ancestor holds it, and the run hangs silent until
   the inner timeout (an hour).
2. `docker build -t <registry>/gridfall-web:<tag> -f deploy/web/Dockerfile .` from the repo root
   (the root `.dockerignore` keeps the context to `build/web/` and `deploy/web/`). The image
   pre-compresses the `.pck` and `.wasm` with Brotli q11 (`-w 24`) and gzip at build time, so the
   box's 2 vCPUs never compress anything per visitor; Caddy serves those sidecars with
   `file_server { precompressed br gzip }`. The build takes ~17 minutes alone on a quiet machine;
   the image is ~1.1 GB unpacked.
3. GMI AgentBox pulls the image from an OCI registry: the register form takes an **Image URL**
   only (Docker Hub, GHCR, ECR; there is no image-upload control in the console as of 2026-10).
   Scan the build before a public push — `docker history` and the image env must be clean, no
   `.env` / `*.pem` / key files in `build/web`, no token-shaped strings anywhere (the `.pck` is
   stored uncompressed, so plain `grep -a` does see its strings) — then tag and push both a
   rolling and a commit tag so a running build traces back to its code:
   `docker tag gridfall-web:latest docker.io/<user>/gridfall-web:main` (and `:<commit>`), push.
   A private registry means typing its credentials into GMI's **Requires sign-in** toggle; a
   public image built from a public repo avoids that entirely.
4. Console → Agentbox → **Register Template**: the single-page form is the **Host on GMI** tab
   (the GMI CE Deployment path; "Connect your agent" is the self-hosted + MaaS flow). Fill the
   internal project name and the image URL, keep region **IOWA IDC-1** (the only one), leave
   **Requires sign-in** off for a public image, and keep the port mapping `web`, HTTPS/2,
   external 443 -> internal 8080: Caddy listens on 8080 and `/healthz` answers the platform's
   port check. The **GMI_MAAS_API_KEY** row is auto-injected by GMI at deploy and cannot be
   turned off in this UI; the static server never reads it and players' mayors still bring
   their own key, so no env variables are added. There is no compute-tier picker here either:
   Host on GMI provisions the Container sandbox (2 vCPU, 4 GiB).
5. Launch from My Agents → the agent → **Instance**: in the dialog pick the **Container**
   compute tier radio (the form wants an explicit pick even though the default shows), add no
   model and no variables, then **Create Instance**. The instance gets a public URL
   (`https://ct-<uuid>-web.caas-us1.gmicloud.ai`). Billing is per second of active runtime
   ($0.0475/hr at the Container tier) and a provisioned instance stays up until you
   **Terminate** it — the console has no idle-stop or auto-stop setting as of 2026-10, so
   "always on" is the default for your own instance. The **Integration** tab holds the Template
   ID and the lifecycle API for scripted control: `POST /v1/agents/deployments/<slug>/tasks`
   provisions, `GET /v1/agents/tasks/<id>` polls to `running`, `DELETE` terminates — Bearer
   token from GMI account settings. Registering is private; the marketplace is a separate
   "List an agent" action.
6. Never bake a key, prompt or save into the image; nothing under `data/` is player-specific.

## Verify

- `curl https://<public-host>/healthz` returns `ok` (also the platform's port health check;
  the container maps 443 -> 8080 by default).
- `curl -sI -H 'Accept-Encoding: br' https://<public-host>/releases/<hash>/index.pck` must report
  `content-encoding: br`, `cache-control: public, max-age=31536000, immutable` and a
  `content-length` around 130 MB; the same URL with `--compressed` transfers that many bytes
  instead of 194 MB. `curl -sI https://<public-host>/index.html` must say `cache-control: no-cache`.
- The page boots to the first-person city in a normal browser; the first visit moves roughly the
  compressed size of the `.pck` plus the `.wasm` and small files. Later visits come from the
  service worker cache; a new release has a new `releases/<hash>/` path and a new
  `CACHE_VERSION`, so a reload after a redeploy fetches the new build instead of the old one.
- The loader overlay stays up until the game is interactive. Godot's web `main()` runs the first
  main-loop iteration inside `callMain`, so `Main._ready` and the first frame's draw are one
  main-thread task, and `startGame()` resolves only after it (the stock shell removed the overlay
  then, frozen on whatever it had last painted). The page cannot paint or take input during that
  task, so at 100% of bytes it switches to "Starting your city" with a transform-only spinner and
  waits two frames before starting the engine, which leaves the spinner on the compositor when the
  task begins. The game lifts the overlay with `window.gfBootDone()` (`BootClock.finish`: the first
  interactive frame plus three rendered ones). The call goes through the bridge's object interface,
  not `eval`, so a Content-Security-Policy without `'unsafe-eval'` still delivers it. If the hook
  never comes (a boot that stops before `BootClock.finish`, or an old build), a 30 s timeout that
  starts when `startGame()` resolves lifts the overlay: that is the most a game without the hook
  costs the player on the veil. That timeout rests on the engine ordering above, which only a real
  web build shows, so every full smoke run checks that `gf:start_game_resolved` does not come before
  `gf:first_frame` (if a Godot update breaks it, re-measure the timeout; until then the worst case is
  a veil lifted right after the boot task instead of three frames later). godot.js has no reject
  path for a wasm that fails to download or compile, so `startGame()` then never settles; after 60 s
  without a progress tick (counted from the page load until the first one) the page stops the
  spinner and shows "Taking longer than expected. If nothing changes soon, reload the page."
  `node tools/web_loader_check.js` checks the page side in headless Chrome with a stub engine (no
  build needed; keep `TMPDIR` short, Chrome refuses a long socket path; its fake clock is paused, so
  a busy machine does not change the result).
- When the boot completes the game prints one `GF_BOOT {json}` line, then `GRIDFALL: boot complete`
  (the browser console only; nothing leaves the machine). The line lists every boot stage with its
  time in ms since the first mark, and the page's `performance.now()` at the first mark and at the
  end; the same marks are `gf:<stage>` entries on the User Timing timeline. A stage marked twice (a
  continued city restores every feature a second time) is `name#2`. The first frame is split in
  two rows: `ready_end` to `pre_draw` is what its main-loop iteration still ran before drawing, and
  `pre_draw` to `first_frame` is the draw itself, first-use shader work included (the rows do not
  separate GL program links from the rest of the draw; a headless run draws nothing and has no
  `pre_draw`). A page whose CSP forbids `eval` loses the `gf:` marks and the page times (-1), at the
  cost of one console error, because those reads use `eval`; the hook and the two console lines do
  not. smoke.js ends its boot wait at the `boot complete` line, so it needs a build that prints it:
  against an image from before BootClock it sees the GPU banner without a `gf:ready_begin` mark and
  fails the boot checks right away instead of waiting out its 10 minutes. Its boot checks read the
  game's `gf:` marks, so a host whose CSP forbids `eval` fails them the same way (the failure text
  names both causes); the Caddy image sets no CSP.
- If those headers ever go missing (a proxy strips them, a wrong serving config), the player
  no longer gets a hung splash: an `html/head_include` script in the Web export preset checks
  `crossOriginIsolated` in the real document at parse time and shows a plain-language
  full-page notice (reload once, then Chrome/Edge/Firefox desktop). It only fires when the
  browser reports `crossOriginIsolated === false`, so non-threaded local exports are never
  nagged. Asserts in smoke.js/web_measure.py evaluate it only after the engine boot marker —
  the pre-commit CDP about:blank reports `complete` + `false` and is a trap.
- The response headers include `cross-origin-opener-policy: same-origin` and
  `cross-origin-embedder-policy: require-corp`: the threaded source preset refuses to boot
  without them, and they are harmless on the recorded single-threaded live build.
- Esc -> Settings -> **GMI Cloud**: a pasted key is sent only to `api.gmi-serving.com`
  (`GMI_FAIL` console lines show rejected keys working the retry path), **Remember on this device**
  keeps it in the browser's `localStorage` (`gridfall.gmi_key`), Forget erases it.
- Save (Esc -> Save) then reload the tab: the console prints
  `GRIDFALL: continuing the saved city, day N tick M` — the save lives in the browser's IndexedDB,
  not on the container. Replacing the image never touches player saves.
- Serve any built image locally with the exact production headers:
  `docker run --rm -p 8080:8080 <registry>/gridfall-web:<sha>`, then http://127.0.0.1:8080/.
  Without a built image, the same Caddy config serves a raw export:
  `docker run --rm -p 8080:8080 -v $PWD/build/web:/srv:ro
  -v $PWD/deploy/web/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2-alpine`.
- A real smoke run: `node deploy/web/smoke.js http://127.0.0.1:8080/` against a local
  `docker run -p 8080:8080 <image>` (needs Chrome; see the script header, ~10 minutes under
  software WebGL). It routes `api.gmi-serving.com` to a local mock that answers 401, so it proves
  a mayor call leaves with the player's key in the Authorization header (checked as a boolean,
  never printed) and that the game falls back, without sending anything to GMI.
- Against a live deployment use the offline mode instead:
  `GF_SMOKE_OFFLINE=1 node deploy/web/smoke.js https://<public-host>/` — no mock, nothing typed
  into the key page, nothing stored, and the run fails if a single request reaches
  `api.gmi-serving.com`: the mayors plan offline (replay cache, then heuristics), which is the
  state every visitor without a key is in.

### Post-redeploy checklist: keyless checks first, one keyed turn last

Verification splits by who holds a GMI key, because the deployment never does.

**Keyless (the operator, every redeploy):** `/healthz`; `python tools/web_measure.py
https://<public-host>/` for the per-file encodings and headers (Brotli through the gateway,
`immutable` on the hashed payloads, `no-cache` on the loader, COOP/COEP) plus the first-load wire
bytes and time to first frame; boot to the first-person city in a normal browser; scan the console
for errors and for `Too many instances using shader instance variables` (none expected on a fresh
day-1 city — that warning belongs to grown saves, see Known limitations); one offline mayor
turn (`GF_SMOKE_OFFLINE=1` smoke above), which fails if a single request leaves for
`api.gmi-serving.com`; and a real-GPU frame-pacing run on a machine with a GPU:
`DISPLAY=:0 NODE_PATH=<dir with playwright-core> node tools/web_fps_probe.js
https://<public-host>/ <outdir>` in a headed Chrome. The probe fails on software WebGL
(`hardware: false`), records the WebGL `UNMASKED_RENDERER` — label every measurement with the
GPU that produced it — plus a shadow-piercing `chrome://gpu` dump, and reports rAF
fps/p50/p95/max on the street and in sky view after a 30 s settle. To measure a **grown city**
(the scenario that used to trip the 4096 instance-variable cap), pass a save:
`GF_FPS_SAVE=<path>/gridfall_save.json` seeds it into the browser's IndexedDB before the engine
boots (Emscripten IDBFS v21 — the probe creates the `FILE_DATA` store with its `timestamp`
index; without the index the engine logs `IndexedDB not available` and runs on an ephemeral
in-memory filesystem), and the run fails unless the console prints `GRIDFALL: continuing the
saved city`. After the measurements the probe drives the exit_fp/enter_fp round trip (Quit to
orbit from the pause menu, then Tab back to the street) and exits 4 on any uncaught exception
or `invalid bus index` line: this headed run is the checklist's only surface with real audio
buses, where that crash class reproduces, so the headless smoke cannot substitute for it.

**Street trees are streamed** (docs/fp/slices/G1-streetscape.md, "On foot the chunks are
streamed"): on the street `CityView/Trees` holds only the chunks around the camera, about 900
MultiMeshInstance3D at the web tier (not the old 8.7k); the overview plants the whole map over some
frames and drops it again on the way back (wasm keeps its heap high-water mark, so the memory saving
lasts until the first overview). A frame-time gain is not demonstrated: microbenchmarks put an idle
MMI at 15-120 ns a frame (desktop and a web export), 0.1-1 ms for the old 8.7k, against a few ms for
a teleport, an overview or a shrink. Compare the probe's street fps and p95 with the previous deploy,
same grown save, before crediting it, and check the `CityView/Trees` census reads about 900 MMIs.

**Keyed (the player, once, with their own key):** open the site, paste the key, confirm a live
mayor turn. This is the only check that exercises the real `api.gmi-serving.com` call and the only
one that can prove it works under cross-origin isolation — the COOP/COEP headers isolate the page
on the recorded single-threaded live build too, and no offline smoke reaches the API. The operator never asks for,
types or sees the key: ask the player to run this step and report whether the turn went live
(`GMI_OK` console lines) or fell back (`GMI_FAIL`).

## Symptoms and fixes

### Split-pack staging and rollback

`tools/web_export.py --split` is opt-in export groundwork, not the current live deployment.
Its default keeps district buildings (including their imported resources) in the boot pack
(Option A); baked mid-LOD twins remain a background pack. Unsplit exports are unchanged.
Runtime streaming and its `web_split_packs` flag still need to be wired and verified after
round 3. Re-measure the merged round-3 boot dependency closure before shipping split packs;
earlier staging sizes do not describe that build.

A split release with `web_split_packs` disabled is **not a rollback**: the flag cannot restore
assets absent from its boot pack. Keep a verified unsplit immutable release available and
replace the deployment with that release if streaming needs to be rolled back. Do not disable
the flag on a split release and expect a complete city.

### Troubleshooting

- **Black screen or "wasm" compile error:** the browser got the wrong MIME type or a truncated
  file. `curl -I https://<host>/releases/<hash>/index.wasm` must say `Content-Type:
  application/wasm`; check the gateway really forwards the whole response.
- **Stuck on the loading bar:** the `.pck` request died mid-flight; watch the browser's network
  tab for a cancelled/failed request, then the platform's instance logs. A reload usually
  resumes from the browser cache.
- **Old version after a redeploy:** the root `index.html`, the service worker and the PWA
  manifest are served `no-cache`, and every release lives under its own hashed directory, so a
  reload always picks up the new build. If a browser still shows the old one, its service worker
  was never updated: unregister it (DevTools -> Application -> Service Workers) and reload.
- **`releases/<old-hash>/...` 404 after a redeploy:** the export keeps only the current and the
  previous release directory; a tab that loaded the build before that will 404 until reloaded.
  Reload the page to pick up the new release.
- **Mayors never go live although the player pasted a key:** check the browser console for
  `GMI_FAIL` lines (bad key) and that the player's account works against `api.gmi-serving.com`
  directly. The game-side breaker trips after a few failures and falls back to offline planners;
  it recovers on its own.
- **Instance will not start:** confirm the port mapping (443 -> 8080) and `/healthz`, and that the
  image entrypoint is the stock Caddy one (`deploy/web/Dockerfile` has no custom entrypoint).
- **Textures look soft on the web build:** expected — props, characters and legacy vehicles import
  at 256 px on the web only (desktop keeps the source resolution). Posters, hoardings and billboard
  art are exempt and keep their source resolution because players read them up close. Raise the cap
  in `tools/web_export.py` (`CAP_LIMIT`) or add a tree to `UNCAPPED_TREES`/`UNCAPPED_NAMES`.
- **`ERROR: Parameter "t" is null` at `texture_2d_initialize` (`dummy/storage/texture_storage`)
  in headless runs:** Godot's dummy renderer has no texture storage, so `godot --headless`
  (gates, tests) logs this once per texture. Benign — the underlying assets are valid and it
  never fires under a real renderer, browsers included. A harness that greps raw ERROR lines may
  whitelist exactly `texture_2d_initialize` together with `dummy/storage/texture_storage`, and
  nothing broader.
- **Known limitation, fixed in round 3 — Compatibility-renderer SIGSEGV on desktop GL:** entering
  first person on `gl_compatibility` could crash minutes in, when the poster/mayor-image pipeline
  first VRAM-compressed a texture on a worker thread. Godot's Betsy GPU compressor registers its
  local RenderingDevice as the global singleton before its context driver exists, and the engine's
  per-frame viewport HDR check dereferences the null driver (upstream draft on file). Both runtime
  compression sites now skip GPU compression unless `RenderingServer.get_rendering_device()` is
  non-null. The web build never had a rendering device, so its images stay uncompressed either way;
  no action needed.

## Known limitations (web / gl_compatibility)

- **Slow motion below 30 fps (flag `web_real_time_pace`, off by default).** The web build caps
  the engine to 2 physics catch-up steps per frame, so a frame over 33 ms advances the world by
  only 33.3 ms: about 80% speed at a grown city's 42 ms frames, 50% at 15 fps. Turning the flag
  on raises the cap to 4 (real time down to 15 fps) and bounds the traffic and animal catch-up
  loops to 12 steps a frame (`Pacing.step_for`). It costs more mayor turns, chat drips and live GMI
  calls per real minute (about 1.3-2x on a grown city, keyed players only). Players switch it in
  the pause menu (Settings > Display) or the planner HUD's "Real-time pace" check button, web
  build only; the choice is saved in `user://feature_flags.json`. To default it on for everyone,
  change `default` in `data/feature_flags.json` after checking the GMI spend.
- **`WARNING: Occlusion culling is disabled at build-time.`** Logged once per boot on the web
  build: occlusion culling is compiled out of the Compatibility export. Cosmetic; no action.
- **Fixed by round 3, verified live 2026-10-28 (`f762234`):** the `FSR2 3D scaling is only
  available when using the Forward+ renderer` warning and the `Too many instances using shader
  instance variables, max 4096` error are gone. A day-2, 35-site grown city that logged the
  instance-cap error 69 times on the previous build now runs with zero occurrences (street
  22.7 fps vs 16.1, worst frame stall 3.0 s vs 13.7 s, same save, same box).
- **Known issue, fix in flight:** quitting first person to the orbit overview can halt the game
  with `invalid bus index "-1"` in `sample_set_volumes_linear` when real audio buses are up
  (windowed play with audio). Headless runs do not reproduce it. The offline smoke's exit_fp
  phase and the FPS probe's exit/enter round trip guard the path from here on; until the fix
  ships, treat a freeze when leaving first person as this bug.
- **Night matches Forward+'s brightness, not its picture** (`SkyDirector.COMPAT_LOOK`, night half).
  Street-half mean luma against Forward+ at 23:00 in the frozen-city street poses: 1.00x clear,
  0.97x on wet streets under a clear sky, 0.89x in soaked rain; the planner view at its default
  zoom is 0.87x (0.81x at the end of dusk). This is darker than the build before it where the
  player looks (street half -24%, planner -28 to -31% absolute luma; only the sky was too dark and
  is now fixed): confirm a darker web night is wanted before shipping. Not matched: Compatibility
  draws no `Decal`, so the warm pool under each street lamp, the puddles, cracks and wear marks are
  missing; it has no screen-space reflections; its tonemap path crushes the dark end (near-black
  pixels 27.8% of the street half against Forward+'s 15.8%, brighter highlights, bluer shadows);
  tree crowns draw nearly black. A joint night retune (contrast 0.97, exposure 0.90, saturation
  1.25) matched mean and distribution at clear 23:00 in review but was not checked in rain, wet,
  planner, web tier or dusk: a follow-up. The sky's night
  encode (`srgb_sky`, `SRGB_SKY_LIFT` in `sky_blend.gdshader`) is tied to 4.7.x's cheap sRGB
  conversions: re-measure the night against Forward+ after an engine bump.

## Replace an instance: saving the template IS the cutover

The GMI register form takes an **Image URL** only, and a running instance keeps the image it was
created with: pushing `:main` alone updates nothing. But as observed at revision 4 (2026-10-27,
pin at 19:08:57Z, replacement task at 19:12:03Z), **saving the template with a new digest triggers
an immediate rolling replacement**: the platform terminates the current instance and provisions a
new one from the new revision, with a NEW public URL and a few minutes of 404s in between. There
is no overlap window, no approval gate, and no way to keep the old instance serving while the new
one is verified.

So the order is verify-then-pin, never pin-then-verify:

1. Before touching the console, finish every offline check on the new image: export `PASS`,
   the image history/env scan, and a local serve (the `caddy:2-alpine` mount above) passing the
   offline smoke. Note the currently-live image digest as the rollback.
2. Tag registry pushes with both `:main` and `:<merge-sha>` for traceability, then edit the
   existing private template, pin its Image URL to `<repository>@sha256:<digest>`, and save.
   Keep region and port mapping unchanged. Expect the replacement within ~4 minutes; its public
   URL is **new** — tell the owner.
3. Run the complete keyless post-redeploy checklist against the new URL. If it fails, roll back
   by re-pinning the previous digest (another replacement, another new URL), not by terminating
   anything.
4. The player's keyed check remains a separate manual step. Record the URL, the instance Task ID,
   the image digest and the checklist numbers in the deployment record below.

### Verified deployment, 2026-10-28

- **Current URL:** https://ct-acf8ab8c-2e82-4cf9-885b-4feb693ef0ac-web.caas-us1.gmicloud.ai
- Instance `gridfall-web-f762234` (Task ID `c8a0b95e-6011-4399-8490-ecb201d25ec0`); image tags
  `:main` and `:f762234` resolve to
  `sha256:a12de813ec6b54c93cd459af3e53dfa13d710d9331b0c5a279e2daeb1fc7558f`; web release
  `e71e7bd18c5733c7` (pack 160,703,300 B). No-threads build from the round-3 fix commit.
- The previous instance (`gridfall-web-cd173a9`) was auto-replaced by the platform the moment the
  template pin saved (see "Replace an instance" above); its URL is retired.
- `/healthz` 200; Brotli through the gateway; COOP/COEP on every probe; loader `no-cache`;
  hashed payloads `immutable`; Range 206. First load **113.43 MB**, first frame **125.0 s**
  (software-WebGL measurement; the previous build measured 243.9 s on the same connection that
  day).
- Offline smoke **8/8**, including "no unexpected console errors": the round-3 pooled-rig
  `backhoe_arm_rig` meta error that failed the previous candidate is gone. Offline mayors made
  zero GMI requests; no key stored; reload continues the IndexedDB save.
- Real-GPU frame pacing (AMD Radeon Renoir iGPU, hardware WebGL confirmed; system load recorded
  with each run): grown city (day 2, 35 construction sites, seeded save) **street 22.7 fps,
  p95 48.7 ms, worst stall 3.0 s, sky 52.1 fps** — the same save on the previous build gave
  street 16.1 fps, a 13.7 s worst stall and 69 `Too many instances` errors; the new build has
  **zero** instance-cap errors and zero FSR2 warnings. Day-1 fresh city measured 79.1 fps street
  on a calm box (36.4 fps under load ~30; label every measurement with its load average).
- The FPS probe's exit_fp/enter_fp round trip (Quit to orbit, then Tab back) ran clean on this
  build for a day-1 city; the audio bus-index crash class found in profiling needs conditions a
  fresh city does not hit and is tracked separately (see Known limitations).
- **Still manual:** the owner opens the new URL with their own key and confirms a live mayor
  turn under isolation. No operator handles the key.
- Header probes must compare HTTP field names case-insensitively: the gateway sends lowercase
  names. A Title-Case-only lookup falsely reports identity encoding and missing isolation headers.

<details><summary>Previous record (2026-10-27, instance retired)</summary>

- URL https://ct-cc58dbb0-1190-4eab-891f-bb58578e8ad2-web.caas-us1.gmicloud.ai (retired), image
  `sha256:c651bbe324e7861db1c2552c08953225c75229eb05fe1c20451d6cda336600b4`. First load
  137.36 MB / 93.82 s vs 451.8 MB / 689.3 s for its predecessor (software WebGL). Offline smoke
  8/8. Instance 22bdf518 was terminated after replacement checks passed; cd173a9 was later
  auto-replaced by the platform on the f762234 template pin.

</details>
