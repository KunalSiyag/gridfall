# Web demo deployment (GMI AgentBox)

The web build is how people try GridFall without installing anything. `tools/export.sh web` runs
`tools/web_export.py`, which builds an isolated staging copy of the project (never the source
tree), caps the prop and character textures at 256 px, converts every WAV to Ogg, exports the
Godot 4 web build, aliases duplicate PCK payloads to one copy and publishes the result
under a content-addressed `releases/<hash>/` directory. The `.pck` that ships is ~194 MB instead of
~654 MB, and the whole site is ~224 MB. A first visit moves ~137 MB (Brotli; 137.3 MB measured in
the offline smoke). `deploy/web/` serves
it from Caddy, a static file server only — players' browsers call `api.gmi-serving.com` themselves
with each player's own GMI key (CORS allows it), and without a key the game runs offline (replay
cache, then heuristics). There is no server-side key by design.

The source Web preset now enables Thread Support. The recorded live `cd173a9` image remains
single-threaded until an explicitly approved rollout after round 3; merging the preset does not
change a running deployment. See [the six-surface thread audit and A/B evidence](web-threads.md)
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
saved city`.

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

Both are logged on every boot of the current build and both are fixed by the round-3 render work
(quality/viewport presets); this section goes away with that release.

- **`WARNING: FSR2 3D scaling is only available when using the Forward+ renderer.`** Every quality
  preset asks for FSR2 3D scaling, which the web build cannot use (WebGL2 is Compatibility only).
  It is a warning, not a failure: the build falls back and first person runs. Under desktop
  gl_compatibility the same request is a crash risk, which is why round 3 switches Compatibility to
  bilinear scaling plus MSAA.
- **`Too many instances using shader instance variables, max 4096`.** Compatibility caps instance
  uniforms at 4096. The city lives in each player's own browser save, so it is the player's city
  growing past that limit that can fail to load (around day 2, roughly 176 roads and 35 sites),
  whatever the instance's uptime — the container is a static file server and holds no city at all.
  A fresh day-1 city boots and plays. Round 3 moves the road shader's per-mesh attributes out of
  instance variables.

## Replace an instance, do not expect an in-place redeploy

The GMI register form takes an **Image URL** only. A running instance keeps the image it was
created with: pushing `:main` or editing the template does not update it. As verified on
2026-10-27, the instance menu offers Shell, Log, Monitoring and Detail, but no redeploy action.

1. Edit the existing private template, pin its Image URL to `<repository>@sha256:<digest>`, and
   save. Keep its region and port mapping unchanged. Tag registry pushes with both `:main` and
   `:<merge-sha>` for traceability, but use the immutable digest in the template.
2. With approval for temporary overlap billing, create a **replacement** instance from that
   template: IOWA IDC-1, Container (2 CPU, 4 GiB, $0.0475/hr), HTTPS/2 443 -> 8080, no extra
   models or environment variables. Do not use the separate public-listing action.
3. Wait for the new instance to reach RUNNING. Its public URL is **new**; tell the owner and
   run the complete keyless post-redeploy checklist against that URL. Keep the old one running
   if any check fails. The player's keyed check remains a separate manual step.
4. Only after the replacement passes, terminate the **old** instance by its exact ID and confirm
   that only the replacement remains RUNNING. Recheck `/healthz` on the new URL. Do not terminate
   the replacement by accident; save the URL and image digest with the deployment record.

### Verified deployment, 2026-10-27

- **Current URL:** https://ct-cc58dbb0-1190-4eab-891f-bb58578e8ad2-web.caas-us1.gmicloud.ai
- Instance name: `gridfall-web-cd173a9`; image tags `:main` and `:cd173a9` resolve to
  `sha256:c651bbe324e7861db1c2552c08953225c75229eb05fe1c20451d6cda336600b4`.
- Old instance `22bdf518-fe51-4da8-8022-27effbf3fed0` was terminated **after** replacement checks
  passed; its former URL is retired. The replacement stayed RUNNING and healthy afterward.
- Live first load: **451.8 MB / 689.3 s** (old, gzip) -> **137.36 MB / 93.82 s** (new, Brotli),
  time to first rendered frame measured in software WebGL. This is 69.6% fewer bytes and 7.35x
  faster first frame, not a hardware-browser performance guarantee.
- `/healthz` 200; Brotli passes through the gateway; COOP/COEP present;
  `crossOriginIsolated === true`; SharedArrayBuffer available; Range 206; loader `no-cache`;
  hashed payloads `immutable`. Offline smoke **8/8**; screenshot shows a REPLAY mayor action;
  no GMI requests or stored key; save/reload persisted; explicit first-person view verified;
  no instance-uniform-limit errors. Engine first log arrived in 44 s (not the first-frame metric).
- Known FSR2/occlusion warnings remain in this pre-round-3 build. Automated reload also produced
  pointer-lock user-gesture and AudioContext autoplay warnings; these are not engine failures.
  The smoke's engine-error check does not count JavaScript `pageerror` events, so inspect them too.
- **Still manual:** the owner opens the new URL with their own key and confirms a live mayor
  turn under isolation. No operator handles the key.
- Header probes must compare HTTP field names case-insensitively: the gateway sends lowercase
  names. A Title-Case-only lookup falsely reports identity encoding and missing isolation headers.
