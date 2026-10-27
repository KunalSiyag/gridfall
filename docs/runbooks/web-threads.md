# Threaded web export: staged, not deployed

Thread Support enables real resource-loading and worker tasks that already have synchronous
fallbacks. It does not automatically move arbitrary GDScript, scene-tree mutation, scene
instantiation, rendering uploads, or the whole city build off the main thread.

## Deployment boundary

The live single-threaded image remains pinned to `c651bbe324e7...`. The preset change is for a
future build after round 3 merges; do not deploy it as part of the Phase A verification.
The live gateway now proves COOP `same-origin`, COEP `require-corp`, secure HTTPS,
`crossOriginIsolated === true`, and SharedArrayBuffer availability. No Caddy changes are needed.
Keep the service-worker isolation-header workaround off: the server already sets the headers.
Keep the Web Audio Sample playback default; Stream audio is a separate decision.

## All six in-game thread gate sites

Audit this table whenever changing an asynchronous path or merging round-3 code. Run:

```bash
rg -n 'WebSupport\.threads_supported\(|Thread\.new\(|WorkerThreadPool|load_threaded_request|use_threads\s*=' scripts/
```

`WebSupport.threads_supported()` checks `OS.has_feature("threads")` and supports the
`GRIDFALL_NO_THREADS=1` native-environment escape hatch. That environment switch is not a
browser-side fallback selector. A threaded WASM still requires isolation to boot.

| Surface | Threaded-web behavior | Guard / boundary |
| --- | --- | --- |
| `scripts/world/city_view.gd`, `_warm_one` | Background `PackedScene` loading | Headless and unsupported builds load synchronously; scene-tree operations remain main-thread |
| `scripts/fp/scene_loads.gd`, `request` | Background resource loading for feature scenes | Unsupported builds load on caller; consumers poll readiness or explicitly wait |
| `scripts/fp/render/midlod.gd`, `mesh_for` | WorkerThreadPool merges CPU-side arrays | Requires both `threaded` and support gate; gather/upload remain main-thread; baked cache may bypass work |
| `scripts/fp/posters/poster_worker.gd`, `_ensure` | Dedicated thread handles mipmaps/image compression | Unsupported builds execute jobs inline; thread shutdown still required |
| `scripts/fp/traffic/people.gd`, `_scene` | Background body-scene loading with subthreads | `blocking` or unsupported builds use synchronous loading; arrival/instantiation remains main-thread |
| `scripts/ai/gmi_image_client.gd`, `_http_transport` | HTTPRequest polling must stay on main thread on Web | MUST include explicit web exclusion even when engine threads exist; sim/ai owner supplies fix and regression test before merge |

The six-site audit is not a promise that every operation is parallel or thread-safe: when adding
a site, document its data ownership, main-thread boundary, fallback, and shutdown path here.

## Compatibility and checks

Single-threaded remains Godot's recommended broadly compatible Web export, especially for
Safari/iOS. Threaded mode is justified by existing worker surfaces, not by a proven startup-speed
claim. Validate Chromium and Firefox, and obtain a Safari/iOS check before claiming parity.
The shell refuses to run when SharedArrayBuffer/isolation is missing; check `Engine.getMissingFeatures`
and do not mask this with a service-worker workaround on this controlled server.

All page resources and worker scripts are same-origin. GMI HTTPRequest uses CORS; COEP does not
replace CORS or authorize missing API headers. User-key live mayor turn remains a manual user
check; the operator verifies the keyless replay path and never handles a key.

## Same-content A/B measurements

One staging copy and one import, then the same staged project exported twice with only
`variant/thread_support` toggled. The build reports prove that is the only difference:
`thread_support=false`, version `0de222ca148193b9` vs `thread_support=true`, version
`da81a180fca42b47`, with identical `pack_after` 160,536,592 bytes, 6,364 files and 4,735
unique payloads. Both sides are precompressed with the image build's exact codecs: Brotli
q11 `-w 24` and gzip -9.

| Payload (bytes) | Single-threaded | Threaded |
| --- | --- | --- |
| index.pck raw / br / gz | 160,536,592 / 106,224,215 / 119,958,309 | identical; pck and both sidecars sha256-equal |
| index.wasm raw | 39,514,754 | 38,820,072 |
| index.wasm br / gz | 6,902,599 / 10,084,297 | 6,890,455 / 10,120,982 |
| index.js raw / br | 279,815 / 59,854 | 314,653 / 63,750 |
| first load over Brotli | 113,191,461 | 113,183,214 |

First load = index.html.br + index.js.br + index.wasm.br + index.pck.br + the two audio
worklets, every sidecar served from disk exactly as the live site does. Thread support costs
nothing on the wire here: the smaller threaded WASM pays for the bigger shell, and the pack is
untouched. Boot timings from this shared, software-WebGL box are environment-specific noise;
never infer a startup speedup from them.

## Boot and isolation check

Both fresh variants then booted back-to-back from the repo's production Caddy config on
localhost (COOP `same-origin` / COEP `require-corp`, precompressed sidecars served from disk)
via `tools/web_measure.py`: the single-threaded member rendered a first frame in 187.2 s and
the threaded one in 154.2 s, with browser-measured first loads of 113,226,292 vs 113,218,045
bytes (threads 8,247 smaller; both totals include ~35 KB of identity-encoded icons). The
threaded run makes 15 first-load requests vs 7 — the extra worker fetches — over the same wire.
The threaded shell refuses to run without cross-origin isolation, so its rendered first frame
proves the isolation chain holds for the exact artifact a future deploy would push. The two
frame times are software-WebGL seconds on a shared box: parity, not a speedup claim.
