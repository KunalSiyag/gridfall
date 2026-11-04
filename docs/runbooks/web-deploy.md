# Web demo deployment (GMI AgentBox)

The web build is how people try GridFall without installing anything. `tools/export.sh web` runs
`tools/web_export.py`, which builds an isolated staging copy of the project (never the source
tree), caps the prop, character and vehicle textures at 256 px (and the zone and building normal and
ARM maps by kind, see "Textures look soft"), converts every WAV to Ogg (it loops only the ones whose import says loop_mode Forward, Ping-Pong or
Backward, 2-4: 1 is Disabled, which is what the one-shots use; the music dir always loops), exports the
Godot 4 web build, aliases duplicate PCK payloads to one copy and publishes the result
under a content-addressed `releases/<hash>/` directory. The `.pck` that ships is ~161 MB instead of
~654 MB, and one release directory is ~192 MB on disk. A first visit moves ~113 MB (Brotli; 113.4 MB
measured against the live deployment on 2026-10-28). `deploy/web/` serves
it from Caddy, a static file server only — players' browsers call `api.gmi-serving.com` themselves
with each player's own GMI key, and without a key the game runs offline (replay cache, then
heuristics). There is no server-side key by design.

**What is and is not verified about that browser call (2026-11-03).** Before 2026-11-03 the keyed
browser path had not been verified by anything: the docs said CORS allowed it, and the only test
(`deploy/web/smoke.js`) used a mock that cannot show it (see the NOTE in its `ctx.route` handler). The first real
measurement, a key-free preflight (`OPTIONS https://api.gmi-serving.com/v1/chat/completions`),
answers 204 with `access-control-allow-origin: *` and `access-control-allow-headers: Content-Type,
Authorization, X-Requested-With, x-gmi-request-id`. The client used to send `User-Agent`,
`X-Request-ID` and `X-Trace-ID` as well, none of them in that list, so a browser would have
blocked every live call, the breaker would have opened after four failures, and the game would
have run on the replay cache while the player believed it was live. The web build now sends only
`Authorization` and `Content-Type` (`GmiClient.request_headers`, flag `gmi_web_safe_headers`), which
the preflight allows. The images deployed before that change (the 2026-11-03 instance
`gridfall-83fe2e8` and the older one) still send the three blocked headers; `tools/demo_check.sh`
reads a deployed `.pck` and fails an image that lacks the fix, because GMI's preflight answer
is the same for every request and so cannot tell an old image from a new one. What has still
**not** been seen: a real browser completing a keyed call from the deployed origin. That needs a
real key; see "Verify the key path" below.

The source Web preset now enables Thread Support. The recorded live image (`f762234`, no-threads)
predates the threaded rollout; merging the preset does not change a running deployment. See [the six-surface thread audit and A/B evidence](web-threads.md)
before building or deploying the threaded variant. The size figures above describe the recorded
Phase A deployment, not the later ground-texture-capped staging used in the A/B experiment, and they
predate the typed zone and building cap: that cap takes 12.4 MB of raw texture payload out of the
boot pack (about 8 MB Brotli q11; computed from the importer's own `.ctex` sizes for the 115 distinct
images, not from a fresh export), so re-measure the pack from `build-report.json` (`pack_after`) and
the first load with `tools/web_measure.py` before quoting a new total.

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
- Esc -> Settings -> **GMI Cloud**: a pasted key (up to 512 characters) is sent only to
  GMI Cloud (`api.gmi-serving.com`, and on desktop the poster queue at `console.gmicloud.ai`); **Test** makes one tiny live call and says in plain words whether the key
  works (and prints one `GMI_TEST <status> http=<code>` console line, never the key); a failed live
  call prints a `GMI_FAIL` line; **Remember on this device** keeps the key in the browser's
  `localStorage` (`gridfall.gmi_key`), Forget erases it.
- Save with the pause menu (Esc -> **Save**; **Load** brings it back), then reload the tab: the
  console prints `GRIDFALL: continuing the saved city, day N tick M` — the save lives in the
  browser's IndexedDB, not on the container. Replacing the image never touches player saves. Tell a
  web player to use the pause menu rather than F5 and F9 (the quick-save and quick-load keys; the
  actions are bound in every build, the browser build included, and the pause menu's Controls list
  shows them there too; the game also saves every morning). Whether F5 saves or reloads the page in the browser build has
  **not been tried in a real browser**: the Godot web template's `godot.js` (4.7.2, read, not run)
  calls `preventDefault()` on every key press while the canvas has focus, which should stop the
  browser's own reload, so F5 probably reaches the game there, but a reload with the focus
  elsewhere would still throw the session away. Treat the pause menu as the safe route until
  someone has pressed F5 in Chrome.
- Serve any built image locally with the exact production headers:
  `docker run --rm -p 8080:8080 <registry>/gridfall-web:<sha>`, then http://127.0.0.1:8080/.
  Without a built image, the same Caddy config serves a raw export:
  `docker run --rm -p 8080:8080 -v $PWD/build/web:/srv:ro
  -v $PWD/deploy/web/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2-alpine`.
- A real smoke run: `node deploy/web/smoke.js http://127.0.0.1:8080/` against a local
  `docker run -p 8080:8080 <image>` (needs Chrome; see the script header, ~10 minutes under
  software WebGL). It routes `api.gmi-serving.com` to a local mock that answers 401, so it proves
  a mayor call leaves with the player's key in the Authorization header (checked as a boolean,
  never printed) and that the game falls back, without sending anything to GMI. It does **not**
  prove CORS: Playwright answers an intercepted preflight itself (read in playwright-core's
  source, not observed in a run) so the mock's allow-list is never consulted, and the smoke has no
  way to notice a header GMI would not allow. The preflight is checked against GMI itself by
  `tools/demo_check.sh`.
- Against a live deployment use the offline mode instead:
  `GF_SMOKE_OFFLINE=1 node deploy/web/smoke.js https://<public-host>/` — no mock, nothing typed
  into the key page, nothing stored, and the run fails if a single request reaches
  `api.gmi-serving.com`: the mayors plan offline (replay cache, then heuristics), which is the
  state every visitor without a key is in.

### Post-redeploy checklist: keyless checks first, one keyed turn last

Verification splits by who holds a GMI key, because the deployment never does.

**Keyless (the operator, every redeploy):** first `tools/demo_check.sh https://<public-host>/` (see
"Verify the key path": `/healthz`, headers, Brotli, the pack's header fix and GMI's CORS preflight in one
read-only run; it must end `DEMO_CHECK: PASS`); then `/healthz`; `python tools/web_measure.py
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
fps/p50/p95/max on the street, on foot, in sky view and in the Planner (orbit) view after a 30 s
settle, with the main-thread busy ms, a WebGL call census and what slow frames were spent on
(knobs, output and what each number decides: [web-probe-kit.md](web-probe-kit.md)). To measure a **grown city**
(the scenario that used to trip the 4096 instance-variable cap), pass a save:
`GF_FPS_SAVE=<path>/gridfall_save.json` seeds it into the browser's IndexedDB before the engine
boots (Emscripten IDBFS v21 — the probe creates the `FILE_DATA` store with its `timestamp`
index; without the index the engine logs `IndexedDB not available` and runs on an ephemeral
in-memory filesystem), and the run fails unless the console prints `GRIDFALL: continuing the
saved city`. After the measurements the probe drives the exit_fp/enter_fp round trip (Quit to
orbit from the pause menu, then Tab back to the street) and exits 4 on any uncaught exception
or `invalid bus index` line (the orbit view's seconds included), or when the game's marks are on and
the `quit_to_orbit` mark was never logged: this headed run is the checklist's only surface with real audio
buses, where that crash class reproduces, so the headless smoke cannot substitute for it.
`GF_FPS_NO_OCCLUSION=1` makes it exit 6 when the console shows any `occlusion` line: set it on a
build with the web dead-work change (render_opt builds no occluders there, so the engine's
`Occlusion culling is disabled at build-time` warning must be gone); older builds log it once per
boot, so it is off by default.

**Audible check (every redeploy, a real browser or the probe).** Every earlier check ran with the autoplay
policy off (`--autoplay-policy=no-user-gesture-required`), muted (`--mute-audio`, which the headless probe adds)
or with the `AudioContext` console lines filtered, so none of them could hear that the build was silent for every
player (see "Web audio"). Run `NODE_PATH=<dir with playwright-core> node tools/web_audio_probe.js
https://<public-host>/ <outdir> --gpu`: policy ON, output NOT muted, it must end `AUDIO_PROBE PASS` (destination
peak over 0.01 within 20 s of boot, context running), and `--suspend` must end `PASS` too (banner and gesture
resume). Then listen once on the demo laptop: click the game, Esc, Settings, Audio at 100%. A first-person
frame-pacing run that should be audible takes `GF_FPS_AUDIBLE=1`.

**Street trees are streamed** (docs/fp/slices/G1-streetscape.md, "On foot the chunks are
streamed"): on the street `CityView/Trees` holds only the chunks around the camera, about 900
MultiMeshInstance3D at the web tier (not the old 8.7k); the overview plants the whole map over some
frames and drops it again on the way back (wasm keeps its heap high-water mark, so the memory saving
lasts until the first overview). A frame-time gain is not demonstrated: microbenchmarks put an idle
MMI at 15-120 ns a frame (desktop and a web export), 0.1-1 ms for the old 8.7k, against a few ms for
a teleport, an overview or a shrink. Compare the probe's street fps and p95 with the previous deploy,
same grown save, before crediting it, and check the `CityView/Trees` census reads about 900 MMIs.

**Keyed (the player, once, with their own key):** open the site, paste the key, press **Test** and
confirm a live mayor turn. This is the only check that exercises the real `api.gmi-serving.com`
call and the only one that can prove it works under cross-origin isolation — the COOP/COEP headers
isolate the page on the recorded single-threaded live build too, and no offline smoke reaches the
API. The operator never asks for, types or sees the key: ask the player to run this step and report
the Test line and whether the mayor cards say live. A successful mayor call prints no console line
(nothing prints `GMI_OK`; older notes that promised it were wrong): the proof is the Test line ("Key
works (answered in 1.1 s)") with its `GMI_TEST ok` console line, and a mayor card whose source reads
live. A failed live call prints `GMI_FAIL <role>/<agent> on <model>: <error>`.

### Verify the key path

Run these in order after every deploy and before every demo. Every template change or **+ Instance**
gets a new URL, so pass the new one: a bare `tools/demo_check.sh` checks only the two instances that
were the defaults on 2026-11-03 (edit `DEFAULT_INSTANCES` in the script when they change).

1. From your shell, no key: `tools/demo_check.sh https://<the new instance URL>`. It is read-only
   (GET, HEAD and one key-free OPTIONS) and reads the whole `.pck` once (about a first load, 95 MB
   Brotli; `DEMO_CHECK_BUILD=0` skips that and then the build is *not verified*). Expect
   `DEMO_CHECK: PASS` and, in it, `ok    build: the pack holds 'gmi_web_safe_headers'` and
   `ok    CORS preflight OK`. The last line is the verdict: `PASS`; `FAIL (n check(s))`;
   `INCOMPLETE (the build was not verified ...)` (exit 1: the pack could not be read, usually a slow
   link, so the one image this tool exists to catch would have passed; raise
   `DEMO_CHECK_BUILD_TIMEOUT` and rerun); or `NO BUILD CHECK (skipped on request ...)` (exit 0, only
   with `DEMO_CHECK_BUILD=0`: every other check passed and the build is not verified). What to do about
   each failure:
   - `FAIL  build: the pack has no 'gmi_web_safe_headers'`: the image predates the browser-header
     fix and every browser call from it is blocked (the CORS line below it can still say OK: that
     line is GMI's side only). Rebuild from a commit that has the fix, push, launch a new instance
     and run this step on it. Do not go on to step 2 on this image: it is older than the Test button
     too (the button and the header fix came in the same change; `git show
     83fe2e8:scripts/fp/ui/gmi_key_panel.gd` has Apply and Forget only, and the older image is older
     still), so its GMI Cloud page has nothing to press. A GMI Cloud page without a **Test** button
     means an old image: rebuild. (If the flag is ever removed from `data/feature_flags.json`, set
     `DEMO_CHECK_BUILD_MARKER` to another string only a fixed build holds.)
   - `FAIL  CORS preflight BLOCKED`: GMI's allow-list changed. Change `GmiClient.request_headers`
     and `WEB_REQUEST_HEADERS` in the script to match it, or the game runs on its replay cache
     without saying so.
   - `warn  build: could not read ...` (verdict `INCOMPLETE`) or `not read (DEMO_CHECK_BUILD=0)`
     (verdict `NO BUILD CHECK`): the build is not verified; run it again with the network up and a
     longer `DEMO_CHECK_BUILD_TIMEOUT` (the pack is 88-106 MB on the wire, so below about 3.5 Mbit/s the default
     240 s is not enough) before trusting the image.
   - any other `FAIL`: the line names the check (healthz, COOP/COEP, Brotli, immutable cache, a
     file the page needs that does not answer 200); fix the deployment and rerun.
2. In the browser, with a real key (the operator never types or sees it; ask the key's owner):
   open that URL, press Esc (a browser reserves Esc for releasing the mouse pointer from the page, so if
   no pause menu appears press Esc once more), Settings, **GMI Cloud**, paste the key, press **Test**
   and read the line under the buttons (F12, Console, shows `GMI_TEST <status> http=<code>` too). If
   the page has no Test button, this is an old image: go back to step 1. Then:
   - "Key works (answered in N s)": the chat-completions call works from that origin (CORS and key, one model). It does not cover the other models (`tools/ops/model_check.py`) or the poster host. Go on.
   - "Key rejected (401)" or "(403)": GMI refused the key; paste another.
   - "Rate limited, try again in a minute": GMI is throttling the key; wait and press Test again.
   - "No answer from GMI in 12 s, try again": the call left and nothing came back in time. Press Test
     again; if it repeats, look at GMI's status page, then F12, Network.
   - "Blocked by the browser or offline": a CORS block or no connection (the browser does not say
     which). Check the connection, then F12, Network for a failed `OPTIONS` to `api.gmi-serving.com`.
     An image with the Test button has the header fix, so its step 1 `build` line is `ok` and does not
     explain this. What remains: a CORS refusal beyond the one preflight `demo_check.sh` sends (read the
     Console's CORS error, which names the header), being offline, or `gmi_web_safe_headers` switched
     off by a `user://feature_flags.json` entry kept in that browser's data (then the three extra
     headers are sent again).
   - "GMI answered an error (HTTP n)": the key reached GMI and the test call failed. Typically 402 is
     credit and 400 or 404 a model not enabled for that key (run `tools/ops/model_check.py`).
     "Could not reach GMI": the request could not be started at all.
3. Confirm live mayors. In the pause menu choose **Planner view** (this button was called "Quit to orbit" before): the overview shows the mayor
   cards (the top bar's **Live GMI** button should be on); at 1x speed a game day is 12 s there (20
   minutes on the street, `WorldScale.FP_DAY_SECONDS`), so give it a minute or two and read each card's source: it should say
   live, not cache or heuristic (a day waits up to 75 s for the mayors' answers before it advances, see
   [gmi-outage.md](gmi-outage.md)). Tab returns to the street, where the activity badge in the corner
   should read Live; it turns red (Reconnecting) only after at least three live calls have been seen
   and most failed, so a quiet badge is not proof, and the Test line in step 2 is.

`python tools/ops/model_check.py` (key in `GMI_API_KEY`, or the variable named by `--key-env`; never in
the browser) checks the other half: that every model the game is configured with is still served to
that key. Exit 1 lists the missing ones, 2 means the check itself failed (it refuses a key with a
space or line break in it, and never follows a redirect with the key).

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
- **Mayors never go live although the player pasted a key:** press **Test** on the GMI Cloud page
  first (see "Verify the key path"): it separates a rejected key from a CORS block or a dead
  connection. Then check the browser console for `GMI_FAIL` lines and that the player's account
  works against `api.gmi-serving.com` directly. The game-side breaker trips after four failures
  and falls back to offline planners; it recovers on its own. The street badge only says
  Reconnecting after three live calls have been seen and most of them failed, so one stray
  failure does not show it.
- **Instance will not start:** confirm the port mapping (443 -> 8080) and `/healthz`, and that the
  image entrypoint is the stock Caddy one (`deploy/web/Dockerfile` has no custom entrypoint).
- **Textures look soft on the web build:** expected — props, characters and legacy vehicles import
  at 256 px on the web only (desktop keeps the source resolution). Posters, hoardings and billboard
  art are exempt and keep their source resolution because players read them up close. Raise the cap
  in `tools/web_export.py` (`CAP_LIMIT`) or add a tree to `UNCAPPED_TREES`/`UNCAPPED_NAMES`.
  The zone and building GLBs cap by kind (`TYPED_LIMITS`): normal maps at 256 px, ARM maps at 128 px
  (the one 256 px ARM map, the glossy solar-cell grid, keeps its size), diffuse, emission and leaf
  cards untouched. The images the uncapped roads also ship (asphalt, pavement, two concrete walls,
  grass) stay at source resolution so the pack gains no second, smaller copy of them beside the
  road's (`kept_shared_with_roads` in the build report; the street GLBs already carry 256 px copies
  of some, so the pack still holds both sizes of those). In the build report `kept_full_size` counts
  the posters and billboards, as before, and `kept_typed_full_size` the zone and building images the
  typed rule leaves alone (diffuse, including the ones the roads share, emission, leaf cards, small
  ARM maps).
  What the cap changes: engine renders of the real capped and uncapped images on flat quads
  (headless Chrome on SwiftShader, the Compatibility renderer, 960x540, 72 degree FOV, tile repeats
  2 to 4 m; not the game scene) differ on a wall seen face-on only within about 2 to 3.5 m. Brick has
  SSIM 0.965 to 0.977 up to 1.8 m and 0.998 at 3.5 m (0.908 at 0.8 m under grazing sun, 0.999 from 5
  m), plaster 0.92 to 0.93 at 0.8 to 1.8 m, clay tile 0.956 to 0.971. The nominal reach, where the
  capped and uncapped chains first pick different mips, is about 3 to 6 m for the normal cap and about
  twice that for the ARM cap: an outer bound, not what shows. Both distances grow in proportion to the
  3D viewport height (540 px for a 900 px canvas at the web tier's 0.6 scale; about 1.8 times that at
  a 960 px 3D viewport, a 1600 px canvas) and were measured at 72 degrees: the default third-person
  camera is 60 degrees (about 1.3 times the distance) and conversation zoom 45 degrees (about 1.75
  times), pinhole scaling that nobody has rendered. The ground differs far less: from a 1.7 m eye height at pitches from -12 to -90 degrees,
  dry gravel renders at SSIM 0.995 or more and a lot's concrete floor slab at 0.999 or more, wet or
  dry (the game never wets gravel, which is only in `MATTE_PREFIXES`).
  One difference holds at any distance: Godot's importer leaves a capped normal map's red and green
  0.4 to 2.7 levels of 255 below the uncapped map, a uniform tilt of its mean normal of 0.2 to 1.5
  degrees (median 0.5; gravel and shutter metal the most; all 29 capped maps, measured with a headless
  import and the shipped BC5 decoded), worth at most about 0.03 of N.L.
  Soft brick, plaster or roof detail at arm's length on a facade: raise the normal limit in
  `TYPED_LIMITS` first. The aggregate error hides the maps that carry real relief. An offline model
  (Lambert lighting on the real maps, no engine frames) has brick, slate, roof-tile and gravel
  normals shift their shading by more than 0.05 on a quarter to two thirds of their pixels at full
  magnification, and flat plaster and bitumen on a few percent; ground never magnifies that far.
  Nobody has compared the game's own frames, so before shipping a build with this cap look at it on a
  real GPU, at the surfaces the cap does change: a brick or plaster facade at 0.5 to 2 m under a low
  sun or a street lamp, a clay-tile or slate roof edge at 1 to 2 m, and a corrugated-metal or
  container wall. Lot pavement (sidewalk, asphalt) and curbs are unchanged controls: the sidewalk,
  asphalt, trim stone and grass maps are the road-shared images that stay full size, and the curbs
  live in the road GLBs, which the cap never touches. Gravel underfoot is no test, it is the least
  affected surface. A diffuse cap of 384 px would save about 2.3 MB raw more (30 images, modelled
  from the importer's `.ctex` sizes: of the 39 diffuse maps, 2 are already under 384 px and 7 are
  shared with the roads and stay at 512 under the same exemption) and has not been tried.
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

## Web audio

**The web build was silent for every player until the default bus layout** (found 2026-11-03: "I don't hear
sound on web"). Files, import, volumes and the web gating were all fine (120 `.oggvorbisstr` in the pack, real
amplitude in the decoded buffers, 0 dB defaults). Cause, measured with an instrumented `AudioContext`
(`tools/web_audio_probe.js`): `audio_feature._make_buses()` called `AudioServer.add_bus` at runtime, and in the
web's default **Sample** playback mode each added bus makes the engine's JS rewire the graph: it disconnects the
Master output node from the context's destination and connects it to a bus (Master, SFX, Music ended in a
cycle with no edge to the destination). The context was `running`, 40 to 46 buffer sources started with real
audio, and the destination peak was 0.0 from boot to +62 s. Disconnecting Master and reconnecting it to
the destination made the peak jump to 0.2 to 0.7 at once. (Which C++ call passes the wrong send index is
inferred, not read from the engine source.) The earlier `invalid bus index -1 in sample_set_volumes_linear` crash
(#83) was the same runtime bus graph.

**The fix:** `default_bus_layout.tres` (project root, named by `[audio] buses/default_bus_layout`) declares
Music, SFX, Ambience and UI, each sending to Master, with the low-pass on Music and the reverb and hard
limiter on SFX that `_make_buses()` adopts; it adds only a bus that is missing (and warns on the web). No bus is
created while the game runs. Two traps found on the way: the setting's **default value is that very path**, so
`project.binary` does not list it and only the file in the pack makes the buses exist, and
`tools/web_export.py` stages named trees plus a few root files, so the layout had to be added to that list
(`BUS_LAYOUT`; `tools/pytests/test_web_audio.py` reads the pack and fails when it is missing).

**Measured on a local export of the fix** (headless Chrome with a GPU, policy `document-user-activation-required`,
no `--mute-audio`, one click, then W held; the clean-tree export, two measurements): context `running`, destination
peak 0.49 before any gesture, 0.75 to 0.76 at the end, first sound 0.2 to 1.9 s after `GRIDFALL: boot complete` (the
earlier hooked scratch export read 0.56 and 0.1 s: a different build); the same probe on the previous image: peak 0.0000
in all 456 samples, exit 1. The layout alone made it audible, with its effects inside (Sample mode ignores
effects, so the pause low-pass and the street reverb do nothing in the browser; unmeasured, from Godot's
documented sample limitation). **Stream playback** (`audio/general/default_playback_type.web=0`, which
mixes in the worklet and makes the effects work) was therefore not needed and not shipped: it moves mixing onto
a cost that is unmeasured on the street (main thread bound at 15 ms), the layout fix costs nothing.

**If the game is silent again**, in this order: run `tools/web_audio_probe.js` (exit 1 and `peak=0.0000`
is this bug class: look for `audio bus ... is not in the default layout` in the console and a bus
created at runtime); the console shows `Sound is off - click or press any key` on screen when the browser
holds the context suspended (the loader's sound watch, `LOADER_AUDIO` in `tools/web_export.py`: it
resumes the context on a click, key or touch and hides the banner; it reads the state and adds no node to the
graph). Owner-side checks once the probe passes: the tab's speaker icon (right-click, Unmute site), the OS
output device, Esc, Settings, Audio at 100%, and `new AudioContext().state` printing `running` in DevTools.

**Sound and boot.** The long beds (six area loops) and the two music stems used to start inside the boot task,
75 to 190 ms each for the first `play()`. They now wait for the loader veil (`BootClock` finished) and start one
per frame (`Ambience.MAX_STARTS_PER_STEP`, `AudioDirector._start_next_stem`); a boot that never finishes
releases them after 10 s. Measured in `GF_BOOT` on local exports, same machine: the `setup:audio` stage fell
from 626 ms (previous image) to 37 to 47 ms (three boots). **The cost moved, it did not vanish:** the first
`AUDIOSEC` window of a run read `ambience` 200 ms for its slowest frame (a bed's first `play()` right after the
veil lifts), so the first second of play can hitch once per bed started; a 0.5 s spacing between starts would
spread it if that is seen in play. The audio feature prints an `AUDIOSEC` line every 10 s (flag
`web_first_use_marks`) with the slowest frame of each section, which the FPS probe collects as
`audio_sections` (web-probe-kit.md): the audio-off ablation had cut frames over 34 ms from 4.5% to 0.5%, and
that line says which section holds them. **Where the slow audio frames come from** (day-10 grown city, GPU
Chrome, `AUDIOSEC` next to the `FIRSTUSE play:` stopwatches of the same run): the **first `play()` of each long
stream**, which decodes and registers all of it in Sample mode: 187 ms (the 63 s residential loop), 125 ms
`park_birds`, 113 ms `traffic_hum`, 81 ms `night_insects`, 74 to 78 ms for each music stem, then 46 ms
`construction_loop`, 12 ms `fountain_loop`, 10 ms `plant_hum` and `siren_two_tone` (the positional emitters:
they surface as the `emitters` section, `refresh_score` up to 47 ms, in the refresh that assigns a player to a
source for the first time). Later plays of the same stream read 7 to 29 ms. Only the beds and stems are moved
here (above); the emitters' loops would need the same treatment (play them once, silent, behind the veil) and
that was not done: the cost is the stream's length, so a per-refresh limit would only spread it.

**What sound costs the street.** With the graph connected the browser now renders the mix (a disconnected graph
is not pulled, so the old build skipped it). Street frames on the day-10 save, `GF_FPS_AUDIBLE=1`, same box, busy
ms p50 (main thread): previous image 15.3 / 15.7 / 15.4, the fix 16.4 / 15.4 (a third run died on the WebGL2 start
failure described in web-probe-kit.md); draws 2,079 to 2,057 against 2,058 (traffic 12 to 8). A reviewer's A/B on
one page with the graph pulled and not pulled, three pairs on the same shared box, read p50 18.1 / 16.7 / 16.7 ms
against 16.7 / 16.7 / 16.7, p95 23.2 / 20.8 / 18.1 against 19.3 / 16.7 / 16.7, and frames over 34 ms 4 / 8 / 4
against 2 / 3 / 2: the direction is the same in all three pairs, so **having the graph connected costs a little on the
main thread (about 1 to 2 ms, large uncertainty; the browser's audio rendering and the engine's mixing hand-off are
not free)**, and it is the price of the fix being audible. The first run of the fix reading +1.1 ms was not noise.
Re-check on a 2-core box before the demo. Driving a car was not measured (car sounds use the same bus and graph).

## Planner stalls, autosave and the web quality tiers

**Planner (orbit) stalls.** On a day-10 grown city the Planner showed three CPU-only stalls of 540 to 670 ms
in every 12 s window (`gl_ms` about 1 ms, no shader builds; the kit's hitch frames carried the `day_bell` and
`save` marks). Two causes, both fixed: (1) `SimPerfFeature.teardown()` set `CitySim.sliced = false` when
leaving first person, so the Planner ran whole `step_tick()`s; on the web it now **keeps `sliced` on** at a 4 ms
budget (`ORBIT_BUDGET_MS`, whatever preset the street ran at; the desktop still turns it off). (2)
`Main` autosaved at every morning tick, and the Planner's game day is 12 s: `save:stringify` alone was 95 ms
at day 10. A **morning autosave inside 60 s of wall clock of the last one is deferred, not dropped**
(`Main.AUTOSAVE_MIN_GAP_S`, `Main.autosave_wait_s()`): the due flag stays set and the save runs on the first frame
after the gap, because on the web a closing tab never reaches the quit autosave and the morning save is the only
persistence there (at most about a minute of play can be lost, not whole days). The quit save and manual saves always
go through. `fp_orbit_slicing_test` covers both, with a fake clock (`Main.autosave_clock`) and with the production
`Time.get_ticks_msec`.

**Measured** (`tools/web_fps_probe.js`, rows street and orbit, headless Chrome on an AMD GPU through ANGLE, the
day-10 grown save, a 15 s Planner window, the previous image against the fix, same commit otherwise, one run
each): frame intervals in the Planner, previous image: p99 517 ms, stalls of 650, 517 and 450 ms besides the
1,383 ms entry frame; with the fix: p99 100 ms, the worst frames after the entry 133 and 100 ms, entry frame
1,333 ms (the first-use shader builds of the Planner's first frames, not the sim: another unit's). 18.3 fps became
19.8, still vertex-bound (21,900 draws). The save's 94 ms `save:stringify` showed once in the previous run's
window and not in the fix's (its first morning save did not fall inside the window): the 60 s gap is
exercised by the unit test, not by this run. The exit_fp / enter_fp round trip stayed clean (exit 0).

**Planner geometry: orbit tree chunks (flag `orbit_tree_chunks`, default on).** The Planner's 21.9k draws and 37 M
vertices a frame on the day-10 city were mostly trees: about 266,000 instances in 25 48-tile `MultiMeshInstance3D` chunks
(the 192-tile map and its 12-tile ring of woods), and a multimesh is culled as a whole, so every chunk the view touched
drew all its trees (and again in each of the four sun-shadow cascades) at any zoom. The Planner now plants 16-tile chunks
(`CityView.TREE_CHUNK_ORBIT`; the same trees in the same places, pinned by `fp_orbit_trees_test`), so the renderer culls
the forest to what the view and the cascades reach. **The look is kept by deciding the full-tree / stand-in switch per
48-tile cell, not per small chunk** (`scripts/world/orbit_tree_lod.gd`): a visibility range on each small layer would have
moved the 120-unit switch to a finer grain, and in the day-10 save at about eleven wheel steps out the forest to the left
changed from dense round stand-ins to sparse full models with a hard edge between (found in review; the first fix,
measuring from the mean of the trees, still differed there because the engine measures from the centre of the layer's
AABB, the box the trees fill, and a cell whose woods lie to one side has the two far apart). `OrbitTreeLod` takes the box
centre of the cell's trees, the engine's own hysteresis (near inside 114, far outside 126) and the viewport's current camera,
and toggles the layers' `visible`; `fp_orbit_trees_test` sweeps cameras across the map against the old rule, pins that a chunk
near the camera in a far cell is far, and fails if `TREE_NEAR` or the cell size changes. Screenshots of the same save with the
flag off and on (same build, game paused, default view, five steps in, five and eleven out, the farthest zoom) differ by mean
absolute 0.5 to 1.1 grey levels over the forest corner and 0.6 to 1.6 over the map at the default, five-out, eleven-out and
farthest zoom (3.1 and 2.7 at five in, from traffic and the clock), and the eleven-out forest, which differed by 6.6 before
the box centre, reads 0.5 and looks the same when looked at. Measured with `tools/web_hitch_probe.js` (`GF_HP_ORBIT=1`, the
day-10 save, headless Chrome 151, AMD Renoir iGPU through ANGLE, 15 to 20 s windows, the default Planner view and the same
view zoomed in ten wheel steps), on a shared machine (load average 5 to 7): vertices a frame 37.2 to 37.7 M became 16.1
to 16.6 M at the default view (-56%) and 33.6 to 34.0 M became 9.0 to 11.0 M zoomed in (-68%); **GPU time**
(`EXT_disjoint_timer_query_webgl2`, p50) 24.3 to 25.9 ms became 17.2 to 19.1 ms (about -27%) and 20.6 to 20.8 ms became 12.1
to 12.9 ms (about -39%). **The frame interval did not move** (p50 50 ms at the default view, 33.3 ms zoomed, in every run):
the Planner is bound by the main thread's 22k draw calls on this machine and nothing here removes a draw (draws 21.8 to 22.2k
before, 20.8 to 22.5k after: the flag does not change the count). **What it costs**: the scene holds 2,352 tree layers
(196 chunks x 12) where it held 300, 8x the nodes the renderer walks each frame; the callback time of the Planner frame
(p50) read 42.1 to 44.5 ms in 9 runs without the change and 42.7 to 54.9 ms in 10 runs with it in the first set (a mean of
43.2 against 47.4, about +4 ms, +10%, at different hours on a loaded machine), and **49.4 and 55.0 without against 52.5 and
50.4 with it in two alternating pairs of the final build** (load average 3 to 7; vertices 37.1 and 37.2 M against 16.4 M,
GPU p50 25.5 and 25.9 against 18.6 ms), so a main-thread cost of up to a few ms is possible but not separated from the
machine's noise; no run shows it helping a frame time. The first-person return (Tab back) read 3.7 s twice without the
change and 4.1 s and 6.3 s with it (42 and 92 programs linked against 35 each; the 6.3 s run is the outlier and its cause is
not known: two runs each cannot say whether the 8x tree nodes freed on the way back play a part. Re-measure before relying on
the flag for the Tab-back freeze). The change pays where the GPU is the longer lane (a weaker GPU than
this iGPU: inferred from the GPU/CPU split, not measured on one). Screenshots before and after (`orbit.png`,
`orbit_zoom.png` of each run) show the same woods in the same places; they were taken at different game hours (the sim runs
at 12 s a day), so they compare layout, not light. Turn the flag off (`orbit_tree_chunks=0`) if the CPU lane is the one
that matters on the target machine.

**First-minute shader warm-up (flag `web_shader_warmup`, default on).** The browser links each shader program at
first use, on the main thread; a new material costs six or seven programs, 0.35 to 0.45 s, in one frame, and a
fresh day 1 hit 83 to 84 programs (4.2 s) in its first 90 s of play after the loader veil dropped, 13 to 16 frames over
100 ms among them. While the veil is up, `ShaderWarmup` (`scripts/fp/warmup/`) now draws a tiny copy of each material
the scene holds, and of a short list of what comes within a minute (people's cut-out materials, a building's leaves, the
construction beacon, the overview's markers, the far-tree layers), in the street's lighting and again with the sun's
shadow held off (the Tab overview's and dusk's programs), a few per frame with a **3,000 ms budget** (checked between
batches: it ran 3.0 to 3.1 s; the loader's status line reads "Preparing graphics N%" and reaches 100% as the budget ends).
What is left links lazily as before. Measured on a fresh day 1 (headless Chrome, AMD iGPU, `tools/web_hitch_probe.js`,
alternating runs of the final build, three each, flag off against flag on): frames over 100 ms **15, 15, 15 against 12, 12,
14** (those caused by a link 11, 11, 11 against 8, 8, 8: about -20% and -27%), over 250 ms 10, 10, 8 against 5, 6, 6,
programs linked after the veil 83, 84, 83 against 55, 61, 60, the veil dropping 19.2 to 23.4 s without and 21.5 to 23.8 s
with it (+3 s or so on this shared machine, where one run's boot varies by several seconds). An earlier set of five and
three runs read 14.2 to 12.0 (-15%) and, in a reviewer's, 17.0 to 12.3 (-28%). **The "halve them" target is not met at 3 s**:
it takes the whole warm-up, 6.8 s here (the link-caused ones fall to 4), because the first minute shows a dozen material
kinds the scene does not hold yet, 0.4 s each wherever they are paid (table and details in web-probe-kit.md, "Shader
warm-up"); raise `ShaderWarmup.DEFAULT_BUDGET_MS` to buy it. The first Tab's sun-without-shadow base programs fell from 21
to 22 to 1 to 5 (the whole Tab window, 24 to 29 s after the veil, linked 57 programs in 2.7 to 2.8 s without the warm-up and
27 to 29 in 1.4 to 1.6 s with it, about -47%, and still holds a 550 to 616 ms frame of 7 programs when a first beacon, a new
building and a new people shader arrive at the same moment: better, not smooth). The biggest remaining hitches are the same
five or six single-material frames at about +10, +24 to 26 and +82 s (each a new generated shader: a hash of the program's GLSL
that was not linked before; adding a person's body material and the far-LOD people layer's shader to the list was tried and
changed none of them, so it was left out). **A grown city is not warmed**: with more than 600 distinct materials
(`ShaderWarmup.LARGE_SCENE_RECIPES`; a new city has 190, the day-10 save 1,575) the run is skipped after counting them
(0.15 s), because there the budget went on the prototypes and the first shadow-off frame (1.9 s) and it added 0.8 to
2.1 s of boot and removed no hitch (9 and 9 frames over 100 ms with and without it); the final build's two day-10 runs read
9 and 10 with the flag on (skipped) and 8 and 8 with it off (the veil at 34.4 and 28.6 s against 31.2 and 28.2, a boot's
noise). The warm-up also stops at once if the loader's veil is gone (`window.gfVeilUp()`), so a hidden tab or the 30 s
timeout cannot make it draw in front of the player. The Planner's first frames (Planner view: 87 to 100 programs, a 3.9 to
4.5 s frame) are not reached by it. `web_shader_warmup=0` is the control. Unverified: Windows ANGLE/D3D11, Intel and
Apple drivers, where a program may cost several times what it does here.

**Web quality tiers.** `Quality.WEB` used to be merged over every preset, so Low, Medium and High looked
the same in the browser (measured: street cb 15.1 / 15.3 / 16.1 ms, identical Planner GPU) and the pause
menu's Display tab did nothing there. The overlay is now per tier (`Quality.WEB_TIERS`), and the browser starts
on Low (`GpuMemory`: "web browser"), so **Low is exactly what shipped** (scale 0.6, atlas 1024, vis 0.55, far 35,
lod 2.5, 4 street lights):

| tier | scale | shadow atlas | vis | far | lod | street lights |
| --- | --- | --- | --- | --- | --- | --- |
| Low (default) | 0.6 | 1024 | 0.55 | 35 | 2.5 | 4 |
| Medium | 0.7 | 1024 | 0.70 | 40 | 2.0 | 5 |
| High | 0.8 | 2048 | 0.85 | 45 | 1.5 | 6 |

Medium and High are for a good GPU and are a "sharper pixels" knob, not a speed-up. Measured on the day-10 save
(`tools/web_fps_probe.js`, one run per tier, AMD GPU through ANGLE): the street's busy p50 was 16.1 ms at Medium and
17.4 ms at High (about 1 ms over Low), with 2,066 draws at Low and 3,284 at High (+59%, fps 51.8 to 49.7); the **Planner is unchanged
by the tier** (busy p50 44.6 / 41.4 / 42.2 ms, 22.2k draws at each): it is vertex-bound, and nothing in the tiers
touches its geometry. A player who saved High or Medium before the tiers were real (those presets were no-ops in the
browser) now gets what they chose, about +1 ms on this GPU and more on a 2-core box (inferred); the pause menu's
Display tab puts them back on Low. A 0.5 "escape hatch" tier for weak
GPUs is not in the table because the default had to stay at today's look: add a fourth name rather than moving
Low. `WEB_DENSITY["traffic"]` is 8 (was 12; the whole traffic feature measured 2.5 ms of a 15 ms street frame
at day 10); crowd 24, animals 6 and rain 600 are unchanged.

## Shadow stripes on roads and sidewalks (the lines on the ground)

**Symptom** ("what are these lines on the ground?"): fine horizontal and arc-shaped stripes on the road and
the sidewalk seen from the street, **clear sky only** (overcast light casts no sun shadow). They are sun
shadow-map acne on Compatibility: the road and sidewalk pieces cast shadows and shade themselves. Measured
before the fix with the street's sun at normal bias 0.6 and depth bias 0.02, atlas 1024, scale 0.6, SSAO off.
Removed by a larger normal bias (and by depth bias 0.2, shadow reach 0.05, roads not casting, sun off); unchanged
by a 4096 atlas, MSAA, anisotropy, glow, fog, the quality preset or 3D scale 1.0; worse at bias 0. The earlier
lines fix covered the overview camera only (`COMPAT_AERIAL_NORMAL_BIAS`) and its probes stood on the plaza or on a
grey day.

**The fix:** `Quality.COMPAT_STREET_NORMAL_BIAS = 1.5` (`Quality.street_normal_bias()`), applied where the street
light profile sets the sun (`LightProfile.apply`); Forward+ keeps 0.6, depth bias stays 0.02 on both
(`fp_street_bias_test`). Free: no frame cost.

**Why 1.5, the smallest that clears.** Clear-sky street poses of the grown bank save (a junction with the hero,
and the road from first person), the same camera at each value, canvas screenshots on a local export (headless
Chrome, ANGLE AMD GPU, Compatibility), looked at side by side:

| sun (street clock) | 0.6 (before) | 1.0 | 1.5 | 2.0 |
| --- | --- | --- | --- | --- |
| 07:30 (the first-day start) | strong stripes on road and sidewalk | faint stripes remain on both | clean | clean |
| 10:45 | strong arcs on sidewalk, stripes on road | clean | clean | clean |
| 13:00 | stripes | clean | clean | clean |
| 16:48 | strong stripes | faint stripes remain | clean | clean |

1.0 clears the 10:45 pose the investigators measured but leaves residue at the low sun of the morning (07:30,
what every new player sees first) and the evening, so 1.5; 2.0 looked the same as 1.5. Band-pass energy
(`web_probe_kit.js` `dogRms`, grey levels, rms of luminance blurred at 1.5 px minus 5 px, in boxes on the road and
the sidewalk) at 0.6 / 1.0 / 1.5 / 2.0, first-person road pose: 07:30 sidewalk 3.76 / 2.14 / 1.01 / 0.95 (sun-off
floor 0.97), road 3.28 / 3.23 / 3.21 / 3.20 and 4.46 / 4.29 / 4.18 / 4.16; 10:45 road 3.14 / 2.39 / 2.39 / 2.39
and 3.63 / 2.81 / 2.81 / 2.81; 13:00 road 3.27 / 2.51 / 2.51 / 2.51. The metric includes the asphalt's own
texture, so on roads it moves by a fraction of the total (it is a comparison between values on one pose, not an
absolute floor), and at 16:48 long building shadows dominate it: the screenshots decided, the numbers back them.
Run-to-run noise from traffic and pedestrians in the box is about 0.15.

**What it costs:** the bias lifts the lookup off every surface, so very thin or low casters lose a little
shadow strength. Looked at on the junction pose: the hero's shadow on the road, the bollard's, the lamp pole's
and the shadow under the cars are all still there at 1.5; the stepped edge of the curb's shadow (hard shadow
resolution, not acne) is the same at 0.6 and at 3.0.

**Check it** with the probe: `result.json` `stripes` (web-probe-kit.md, "Stripes") is the clear-sky stripe pose of a
fresh profile (day 1 is clear by construction, so a grey day cannot hide the acne); the probe exits 7 when its
row-profile reading passes 2.0. Three runs on the fix read 0.71 to 1.19, three on a build with the old bias (0.6) read
2.75 to 2.99. It is skipped under `GF_FPS_SAVE` (the sky is then the save's weather), so a seeded run never checks it:
run the default run once per release too.

## Known limitations (web / gl_compatibility)

- **Planner view freezes the page for 3.9 to 4.5 s on the first entry** (and Tab back to the street for 3.4 to 3.7 s, 15 to
  25 programs). Measured on the day-10 city with `GF_HP_ORBIT=1` (web-probe-kit.md): 87 to 100 shader programs link on the
  Planner's first frames, 4.0 to 4.4 s of them (four shadow splits, exponential fog and orbit-only materials, none of which
  the street draws). The shader warm-up (`web_shader_warmup`) does not reach them, even with every pass drawn for 18 s.
  Open: draw the Planner's materials once behind a "Preparing the Planner" overlay when the player asks for it, or reveal
  the rebuilt city over several frames so each frame links a few.
- **The first-minute warm-up costs about 3 s of boot and removes about a quarter of the link-caused hitches on a new city,
  and does nothing on a grown one** (`ShaderWarmup.DEFAULT_BUDGET_MS`; 6.8 s of boot removes about two thirds; a city with
  more than 600 materials is not warmed: `ShaderWarmup.LARGE_SCENE_RECIPES`). Details in web-probe-kit.md.
- **No ambient occlusion in the web build's first-person view (`Quality.ssao_ok`).** On
  Compatibility (Godot 4.7.2), SSAO drew rows of dark horizontal lines on the plaza ground seen
  from the street whenever the 3D view rendered below native size. Only that street view was
  measured: in the day city overview, SSAO on and off measured the same on a lawn and a road, so
  the overview loses its ambient occlusion with no measured gain. Measured on the web build
  on a real GPU (ANGLE, AMD) on 2026-11-01, as the rms of a high-passed row profile of the plaza
  ground in 8-bit grey levels, in the street photo's left and right plaza boxes (left / right):
  12.2 / 14.2, 10.2 / 10.4 and 13.1 / 12.8 at Low / Medium / High in the web tier (3D scale 0.6,
  rows about 5 px apart), 11.1 / 14.2 on web Low with `web_quality` off (scale 0.77), against 0.7
  to 1.6 (left) and 1.3 to 3.0 (right) with SSAO off or at native size. `render_opt`, which owns
  the 3D scale, switches SSAO off wherever Compatibility renders scaled, so the web build has no
  ambient occlusion (less contact shading in creases and under objects) at any preset, and desktop
  Compatibility Low has none either (that one was not measured on a desktop run; it rests on the
  web result at the same 0.77 scale). `web_quality=off` does not bring it back on Low; Medium and
  High with the flag off render at native size and keep it. With the `render_opt` flag off nothing
  is scaled and SSAO stays as the orbit view has it; the `streetscape` flag does not matter. What
  inside the engine produces the rows is not established.
- **Rain streaks are capped in the web tier and off over the city (`Quality.WEB_DENSITY["rain"]`,
  `Weather._step_rain`).** The browser build draws at most 600 rain streaks at every preset (Low,
  Medium and High would draw 800, 1,600 and 3,000; `web_quality=off` lifts the cap) and the emitter
  is off and hidden while the Tab overview is open or the camera is more than 10 m above the
  player's feet, where it only drew streaks hanging before the lens. The overview counts whatever
  the height: its camera sits over the ground, so a hero standing on a roof (wall climb allows it)
  has the zoomed-in overview under 10 m over their feet. The planner view has no emitter: leaving
  first person frees the weather. Both rules are the web tier's only: the desktop keeps its
  800 / 1,600 / 3,000 streaks and its overview rain, because the overview result below comes from
  the browser's renderer alone. The P photo fly keeps its rain at any height (its feet follow the
  camera). `GRIDFALL_WEB_CAPS="rain=n"` moves the cap (at least 1, because an emitter takes no
  fewer) wherever the tier is on and the engine sees the variable; only the tests set it, no
  desktop run forces the tier, and whether the browser shell passes environment variables was not
  checked.
  Measured on the web build on a real GPU (ANGLE, AMD) on 2026-11-01 as the share of frame pixels
  that are thin bright streaks (luma more than 20 grey levels above its 7 px horizontal opening, HUD
  masked), fresh seed-7 city in its day-1 rain at 1280x720: the Tab overview went from 0.60 / 1.12 /
  1.77% to 0.17 to 0.22% at Low / Medium / High (the same overview with no rain at all reads 0.17 to
  0.34%), and the street's rain share, net of the same street with no rain, from 0.75 / 1.73 / 2.78%
  to 0.40 / 0.56 / 0.40%. At High the street's net share was 0.08 / 0.27 / 0.40 / 0.60% at 200 / 400
  / 600 / 800 streaks. All of that is the 06:00 plaza, where the streaks stand out against a dark
  scene; no daytime frame was measured, and in the daytime frames looked at (06:45 to 07:00, grey
  sky) 600 streaks are sparse and faint, only a few crossing the sky, with the splash beads on the
  ground as the clearer rain cue. If daytime rain reads too thin, change `WEB_DENSITY["rain"]` and
  re-measure: more streaks bring the lines back at night.
- **Slow motion below 30 fps (flag `web_real_time_pace`, off by default).** The web build caps
  the engine to 2 physics catch-up steps per frame, so a frame over 33 ms advances the world by
  only 33.3 ms: about 80% speed at a grown city's 42 ms frames, 50% at 15 fps. Turning the flag
  on raises the cap to 4 (real time down to 15 fps) and bounds the traffic and animal catch-up
  loops to 12 steps a frame (`Pacing.step_for`). It costs more mayor turns, chat drips and live GMI
  calls per real minute (about 1.3-2x on a grown city, keyed players only). Players switch it in
  the pause menu (Settings > Display) or the planner HUD's "Real-time pace" check button, web
  build only; the choice is saved in `user://feature_flags.json`. To default it on for everyone,
  change `default` in `data/feature_flags.json` after checking the GMI spend.
- **`WARNING: Occlusion culling is disabled at build-time.`** Occlusion culling is compiled out
  of the web export, and the engine prints this once, the first time anything touches it:
  creating an `ArrayOccluder3D`, or turning the viewport's `use_occlusion_culling` on (each alone
  prints it in a bare 4.7.2 web export). Only render_opt does either in this project, and older web
  builds logged it once per boot. render_opt now builds no occluders and leaves the flag alone on
  the web, so a build with that change should not log it (checked in the bare export, not yet on
  a live boot of the game; if it still shows, something else builds an occluder). Cosmetic either
  way; no action. The skip follows the platform tag, not a capability (the engine cannot be asked),
  so after an engine bump (`.godot-version`) count the occlusion backend in the web template:
  `python3 -I -c "import zipfile,sys; print(zipfile.ZipFile(sys.argv[1]).read('godot.wasm').count(b'RaycastOcclusionCull'))" <template>/web_release.zip`
  is 0 for 4.7.2 (the linux and windows release templates give 12). If it is no longer 0, drop the
  `web` skip in `render_opt_feature.gd`.
- **Fixed by round 3, verified live 2026-10-28 (`f762234`):** the `FSR2 3D scaling is only
  available when using the Forward+ renderer` warning and the `Too many instances using shader
  instance variables, max 4096` error are gone. A day-2, 35-site grown city that logged the
  instance-cap error 69 times on the previous build now runs with zero occurrences (street
  22.7 fps vs 16.1, worst frame stall 3.0 s vs 13.7 s, same save, same box).
- **Fixed in 3fccc38 (#83):** quitting first person to the orbit overview used to halt the game
  with `invalid bus index "-1"` in `sample_set_volumes_linear` when real audio buses were up
  (windowed play with audio). The audio buses now stay up across exit and enter, and the audio
  director falls back to Master when a bus is missing; `fp_audio_test` asserts the routing.
  Headless runs never reproduced the crash: the FPS probe's exit/enter round trip is the check that can,
  and it needs the real buses, which the default bus layout now provides from boot (see "Web audio"; the
  round trip, `GF_FPS_AUDIBLE=1`, ran clean on the layout build: exit 0). A freeze when leaving first person on a build before
  3fccc38 is this bug.
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
3. Run the complete keyless post-redeploy checklist against the new URL, starting with
   `tools/demo_check.sh <the new URL>`, which must end `DEMO_CHECK: PASS`. If it fails, roll back
   by re-pinning the previous digest (another replacement, another new URL), not by terminating
   anything. Put the new URL in `DEFAULT_INSTANCES` in `tools/demo_check.sh` (and drop a retired one),
   or a bare run keeps checking the old images and exits 1.
4. The player's keyed check remains a separate manual step. Record the URL, the instance Task ID,
   the image digest and the checklist numbers in the deployment record below.

### Console change observed 2026-11-03: a second instance, not a replacement

The paragraph above records what the console did on 2026-10-27. On 2026-11-03 it behaved differently, and
the runbook's step order is now simpler and safer:

- **Editing the template no longer replaces a running instance.** Changing the existing template's Image URL
  to `docker.io/kunalsiyag1/gridfall-web@sha256:<digest>` and saving left the running instance untouched (it
  keeps the image it was created with).
- **`+ Instance` on that template launches an additional Container instance** from the template's current image
  (Container tier, $0.0475/hr, 2 core / 4 GiB, region IOWA IDC-1), with a new public URL and the old instance
  still serving. Verify the new URL, then terminate the old instance only when satisfied. Rollback is
  re-pinning the previous digest and launching again.
- **Do not use the Register Template form for a web host any more.** A new template now only offers
  "Sandbox" specs (Small $0.0911/hr): an SDK-driven sandbox whose URL answers `401 unauthorized access` without a
  GMI access token, so it cannot serve the game. The Compute > Containers product is a different service (Elastic
  IP, no HTTPS gateway) and was not used.

### Verified deployment, 2026-11-03 (third instance: the key path fix)

- **URL:** https://ct-688045aa-4105-487b-ac5f-cd92cdb2ed92-web.caas-us1.gmicloud.ai, instance `gridfall-web-0528316`, image
  `docker.io/kunalsiyag1/gridfall-web@sha256:8813ccdb937ade9005cb483cf790914d3fb7b92162398b526408741cbb3068fd`
  (tag `:0528316`, release `7588ac5d7c80bf51`, threaded, pack 87,814,798 B on the wire, first load 94.8 MB), Container tier $0.0475/hr.
  Built from web/wave0 0528316 (key-path fix, carjack pull-out, police response); `gate quick` PASS on that tip.
- **Measured:** `/healthz` 200; `tools/demo_check.sh` PASS (headers, Brotli, the pack holds `gmi_web_safe_headers`, GMI's
  preflight allows Authorization + Content-Type); in headless Chrome against the same image the one live POST carried only
  `authorization` and `content-type` as custom headers (`deploy/web/smoke.js`, 21/21 checks, against a mock API).
- **Not verified:** a real keyed call from a browser. The owner presses **Test** on this URL with a real key (see "Verify
  the key path"). The older instances `gridfall-83fe2e8` and `gridfall-web-0a6855f-d` still send the blocked headers.
- `deploy/web/smoke.js` key-page keystrokes now include the Test button's Tab stop (Forget, Test, Remember Off, On).

### Verified deployment, 2026-11-03 (second instance)

- **URL:** https://ct-b22afc4d-cbdb-45e4-b3da-e209d09593fa-web.caas-us1.gmicloud.ai, instance `gridfall-83fe2e8`, image
  `docker.io/kunalsiyag1/gridfall-web@sha256:ec1443e645ea15df6c2e71570b4b220676a956a3327eb699ff166659acd2806f`
  (tag `:83fe2e8`, release `a5dcd6fb920dfffb`, threaded build, pack 123,035,484 B). The previous instance
  `gridfall-web-0a6855f-d` (image `sha256:ca8c3c5cde4d8f9aca1a220f794bef060aeb2992988774ef21804dd17c138ce3`) was left running for
  comparison.
- `/healthz` 200; COOP `same-origin` and COEP `require-corp`; `.pck` Brotli 87,776,017 B and `.wasm` Brotli
  6,890,455 B, immutable cache.
- Offline smoke through the gateway (`GF_SMOKE_OFFLINE=1`, headless software WebGL): **15/15 PASS**: boot complete
  in 29 s, loader lifted by `gfBootDone`, cross-origin isolated after cold load and reload, first load **94.8 MB**
  on the wire (113.43 MB on the 2026-10-28 build), 0 requests to `api.gmi-serving.com`, no key stored, reload
  continues the saved city, quit to orbit and back clean, no console errors.
- The older instance `gridfall-web-0a6855f-d` (the 2026-10-28 build, image `sha256:ca8c3c5c...`) is at
  https://ct-1ff7949c-bd38-4939-b13c-4a0638d82bec-web.caas-us1.gmicloud.ai (healthz 200 on 2026-10-30, per the
  owner's notes). The URL recorded in the 2026-10-28 section below (`ct-acf8ab8c...`) is a different, earlier instance (`gridfall-web-f762234`) and answered 404 on
  2026-10-30; `tools/demo_check.sh` defaults to this URL and the new one.
- **Still manual:** the owner opens the URL with their own key and confirms a live mayor turn (see "Verify the
  key path"; nothing verified the keyed browser path before 2026-11-03 and nothing has since: no real
  browser has completed a keyed call). This image predates the web-safe header
  change, so it still sends `User-Agent`, `X-Request-ID` and `X-Trace-ID`, which GMI's preflight does not allow:
  from a browser its keyed calls are expected to be blocked (inferred from the preflight, not observed in a
  browser). Redeploy before the keyed check. No browser frame-rate measurement of this build exists yet.

### Verified deployment, 2026-10-28

- **URL as recorded on 2026-10-28 (not live):** https://ct-acf8ab8c-2e82-4cf9-885b-4feb693ef0ac-web.caas-us1.gmicloud.ai
  (`/healthz` answered 404 when checked on 2026-10-30 and again on 2026-11-03; treat it as retired and use the
  instance URLs in the 2026-11-03 record above)
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
- The FPS probe's exit_fp/enter_fp round trip (Planner view, then Tab back) ran clean on this
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
