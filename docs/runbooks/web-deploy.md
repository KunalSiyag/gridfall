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
  `api.gmi-serving.com`; **Test** makes one tiny live call and says in plain words whether the key
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
Quit to orbit was never logged: this headed run is the checklist's only surface with real audio
buses, where that crash class reproduces, so the headless smoke cannot substitute for it.
`GF_FPS_NO_OCCLUSION=1` makes it exit 6 when the console shows any `occlusion` line: set it on a
build with the web dead-work change (render_opt builds no occluders there, so the engine's
`Occlusion culling is disabled at build-time` warning must be gone); older builds log it once per
boot, so it is off by default.

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
     longer `DEMO_CHECK_BUILD_TIMEOUT` (the pack is 88-123 MB, so below about 3 Mbit/s the default
     240 s is not enough) before trusting the image.
   - any other `FAIL`: the line names the check (healthz, COOP/COEP, Brotli, immutable cache, a
     file the page needs that does not answer 200); fix the deployment and rerun.
2. In the browser, with a real key (the operator never types or sees it; ask the key's owner):
   open that URL, press Esc (a browser reserves Esc for releasing the mouse pointer from the page, so if
   no pause menu appears press Esc once more), Settings, **GMI Cloud**, paste the key, press **Test**
   and read the line under the buttons (F12, Console, shows `GMI_TEST <status> http=<code>` too). If
   the page has no Test button, this is an old image: go back to step 1. Then:
   - "Key works (answered in N s)": the whole path works from that origin (CORS, key, model). Go on.
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
3. Confirm live mayors. In the pause menu choose **Quit to orbit**: the overview shows the mayor
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

## Known limitations (web / gl_compatibility)

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
  Headless runs never reproduced the crash, so the real-audio exit/enter has not been run against
  the current image: the FPS probe's exit/enter round trip (headed Chrome, above) is the check that
  can. A freeze when leaving first person on a build before 3fccc38 is this bug.
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
  owner's notes). The URL recorded for it in the 2026-10-28 section below (`ct-acf8ab8c...`) answered 404 on
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
