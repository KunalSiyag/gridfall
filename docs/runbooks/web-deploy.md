# Web demo deployment (GMI AgentBox)

The web build is how people try GridFall without installing anything: `tools/export.sh web` produces
a no-threads Godot 4 web export (`build/web/`, ~654 MB `.pck`), and `deploy/web/` serves it from a
plain nginx container. The container is a static file server only — players' browsers call
`api.gmi-serving.com` themselves with each player's own GMI key (CORS allows it), and without a key
the game runs offline (replay cache, then heuristics). There is no server-side key by design.

## Build and ship a new image

1. `tools/export.sh web` — needs the `web_nothreads_release.zip` export template (see the script's
   help for the one-time install). `EXPORT: PASS` ends the run.
2. `docker build -t <registry>/gridfall-web:<tag> -f deploy/web/Dockerfile .` from the repo root
   (the root `.dockerignore` keeps the context to `build/web/` and `deploy/web/`). The image
   pre-gzips the engine files at build time so the box's 2 vCPUs never compress the ~650 MB `.pck`
   per visitor; nginx serves those copies with `gzip_static`. Image content is ~1.2 GB.
3. In the AgentBox register wizard pick **GMI CE Deployment**: Step 2 offers **Registry URL** (any
   Docker Hub / GHCR image you pushed) or **Upload Image** (push a local image straight to GMI's
   registry, fine for one-off builds). Compute tier **Container** (2 vCPU, 4 GiB), region
   **IOWA IDC-1**. Leave **MaaS integration off** — players bring their own key, so the container
   needs no injected key and no env variables.
4. Networking (Step 3) keeps the default mapping `web`, external 443 -> internal 8080: nginx
   listens on 8080 and `/healthz` answers the platform's port check.
5. Instances bill per second of active runtime and stop when nobody uses them (scale to zero).
   The Integration tab gives the lifecycle API for explicit control:
   `POST /v1/agents/deployments/<slug>/tasks` provisions, `GET /v1/agents/tasks/<id>` polls to
   `running`, `DELETE` terminates — Bearer token from GMI account settings. Whether a stopped
   instance cold-starts by itself on incoming traffic is not documented; if the demo must always
   answer, keep an instance provisioned and verify wake-on-traffic after the first deploy.
6. Never bake a key, prompt or save into the image; nothing under `data/` is player-specific.

## Verify

- `curl https://<public-host>/healthz` returns `ok` (also the platform's port health check;
  the container maps 443 -> 8080 by default).
- The page boots to the first-person city in a normal browser; the first visit moves ~452 MB
  on the wire (measured: the 654 MB `.pck` gzips to 441 MB, plus the `.wasm` and small
  files); later visits are cached an hour.
- Esc -> Settings -> **GMI Cloud**: a pasted key is sent only to `api.gmi-serving.com`
  (`GMI_FAIL` console lines show rejected keys working the retry path), **Remember on this device**
  keeps it in the browser's `localStorage` (`gridfall.gmi_key`), Forget erases it.
- Save (Esc -> Save) then reload the tab: the console prints
  `GRIDFALL: continuing the saved city, day N tick M` — the save lives in the browser's IndexedDB,
  not on the container. Replacing the image never touches player saves.
- A real smoke run: `node deploy/web/smoke.js http://127.0.0.1:8080/` against a local
  `docker run -p 8080:8080 <image>` (needs Chrome; see the script header, ~12 minutes under
  software WebGL). It routes `api.gmi-serving.com` to a local mock that answers 401, so it proves
  a mayor call leaves with the player's key in the Authorization header (checked as a boolean,
  never printed) and that the game falls back, without sending anything to GMI.

## Symptoms and fixes

- **Black screen or "wasm" compile error:** the browser got the wrong MIME type or a truncated
  file. `curl -I https://<host>/index.wasm` must say `Content-Type: application/wasm`; check the
  gateway really forwards the whole response (the `.pck` is ~650 MB).
- **Stuck on the loading bar:** the `.pck` request died mid-flight; watch the browser's network
  tab for a cancelled/failed request, then the platform's instance logs. A reload usually
  resumes from the browser cache.
- **Old version after a redeploy:** `index.html` is served `no-cache`, engine files are cached an
  hour; a hard reload (Ctrl+Shift+R) forces a refetch. Publishing under a new image tag avoids
  the hour of overlap entirely.
- **Mayors never go live although the player pasted a key:** check the browser console for
  `GMI_FAIL` lines (bad key) and that the player's account works against `api.gmi-serving.com`
  directly. The game-side breaker trips after a few failures and falls back to offline planners;
  it recovers on its own.
- **Instance will not start:** confirm the port mapping (443 -> 8080) and `/healthz`, and that the
  image entrypoint is the stock nginx one (`deploy/web/Dockerfile` has no custom entrypoint).
