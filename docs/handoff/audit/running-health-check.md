# running-health: skeptic check

Repo checked: /home/kunalsiyag/Ambassador/Gmi_Cloud/gridfall-wt-integ, tip 720d4e0. Read-only: grep, git, python over JSON (sizes only), file reads. No Godot, Chrome, Docker or network. No .env or settings.json read.

Tally: 26 items checked (14 findings, 12 proposals). 15 hold (several with small caveats), 11 need a correction. The lens is mostly accurate on mechanics; its weak spots are (a) one finding whose evidence is not what it looks like (F1 mock), (b) byte numbers in the wrong unit (F2/P4), (c) two factual errors (F10 soak is not sim-only, F13 "no way to force a fresh city"), (d) proposals that skip a repo rule (P3 needs a feature flag) or whose stated verification cannot work (P2), and (e) it missed the cheapest decisive CORS check.

Note on provenance: F2/P4/P5 and F4/P6 are restatements of backlog items 12 and 9 in ~/.claude/projects/-home-kunalsiyag-Ambassador-Gmi-Cloud-gridfall/session-artifacts/2026-10-31/web-gap-backlog.md (lines 240-256 and 296-314), which already carry the real save numbers and the (a)-(d) sketch. They are valid but not new discoveries.

## Findings

### F1 keyed browser -> GMI never verified: HOLDS as an unverified risk, but one piece of evidence is wrong
- Verified: docs/runbooks/web-deploy.md:195-200 (keyed turn is a manual user check), :443-444 ("Still manual"), web-threads.md:48-49. gmi_client.gd:388,391,393 send User-Agent, X-Request-ID, X-Trace-ID. `grep -rn GMI_OK scripts tools deploy docs` finds only docs/runbooks/web-deploy.md:200 (never printed by code); GMI_FAIL at gmi_client.gd:360. Header provenance: 8c60c33 2026-10-20 vs 19969e1 2026-10-26 (git log). Both 2026-11-03 smokes in scratchpad (smoke-83fe2e8, smoke-live-83fe2e8 summary.json) are offline runs ("0 requests seen"), so no keyed or mocked-key evidence exists for the new image.
- WRONG/MISLEADING: "the only CORS mock does not allow those headers". deploy/web/smoke.js:151-155 lists `authorization, content-type`, but Playwright's Chromium answers an intercepted CORS preflight itself and echoes whatever Access-Control-Request-Headers asked: playwright-core crNetworkManager.js:270-280 (installed copy 1.64.0 under ~/.vscode/extensions/vscjava.migrate-java-to-azure-1.24.0-linux-x64/node_modules/playwright-core/lib/server/chromium/). The mock's OPTIONS branch therefore never runs and its allow list is decorative. So (1) it is not a detected gap, and (2) proposal P2's verification ("make the OPTIONS handler reject unlisted headers") cannot work. Which Playwright version smoke.js resolves is UNKNOWN (it requires playwright-core from elsewhere, smoke.js:17,32).
- Counter-evidence confirmed by me: real save stats live_ok 546, live_fail 17, retries 4, breaker_open 0 (client.stats in gridfall_save.json); all five mayor_state sources 'live' (latencies 4.3-10.2 s). That is desktop, not browser.
- Consequence if the preflight fails (confirmed from code): _post returns "network result N" (gmi_client.gd:~410), is_service_failure true for any non-success result (gmi_client.gd:~158-160), 4 consecutive failures open the breaker (gmi_client.gd:54), chat_json falls to cache (gmi_client.gd:~228).
- Engine caveat UNKNOWN: Godot's HTTPRequest may add its own default User-Agent/Accept when the caller omits them; engine source is not on this machine, so P2's effect is unverified.

### F2 session_cache unbounded, saved twice, autosave every game day: HOLDS, numbers are inflated about 14%
- Code verified: _remember appends (gmi_client.gd:523-526); flush_cache prunes only its own file (552-575); to_dict returns whole cache (630-631); main._write_save stores `"client": client.to_dict()` (main.gd:~331) and brain.to_dict stores `"client": client.to_dict()` (city_brain.gd:949), same object; autosave on tick 0 of each day (main.gd:262-264, 252-254); exit_fp -> BASE_DAY_SECONDS 12 (main.gd:623, sim_defs.gd:22); FP day 1200 s (world_scale.gd:108); new_game does not touch client (main.gd:451-466) and brain.setup does not either (city_brain.gd:55-80).
- Real save (/home/kunalsiyag/.local/share/godot/app_userdata/GridFall — GMI Cloud Multi-Model Crisis Sim/gridfall_save.json), measured by me: file is 2,379,259 B (ls), not 2,704,120. The lens got 2,704,120 from Python json.dumps default separators (I reproduced exactly 2,704,120); Godot writes compact JSON. Compact: brain 896,968 + client 824,186 of 2,379,259 = 72% (lens 65%), day 10, 282 keys, 1,682 entries, brain.client cache equals client cache. Growth: .bak (day 9) 2,274,221 B file vs 2,379,259 = +105,038 B/day (lens +111,940). Pruning to 3 days/key: cache 824,014 -> 300,038 B; both copies pruned = about 1.33 MB; dedupe plus prune = about 1.03 MB (this equals backlog item 12's "2.38 MB to about 1.03 MB"). The lens's "1,581,574 B" and "1.3-1.6 MB" are in the inflated unit. Extrapolation "about 8 MB at day 60" is still fair (2.38 + 50 x 0.105 = 7.6 MB), INFERRED.
- Also true and missed by the lens: flush_cache writes user://gmi_session_cache.json every day (gmi_client.gd:~575-580) and nothing reads it outside record mode (backlog item 12 correction).

### F3 replay cache ends at day 12: HOLDS mechanically, severity overstated, scope understated
- Verified by python over data/gmi_replay_cache.json: mayor keys max day 12 (gaps, e.g. argon lacks 4 and 10), news|gazette [2,4,5,10,11,12], council|speaker [3,5,6,7,9,11], chaos|director [4,6,8,10,12], citizens|voices [3], operator|grid [10]; chaos day 12 = trigger true, sewage_burst, x 18, y 24. _cache_lookup (gmi_client.gd:529-545) has no horizon, runs before the heuristic (chat_json 237-246). City_brain.gd:204-205 gates chaos on `day - chaos_last_day >= 2`; trigger_disaster fires when population > 80 (city_brain.gd:742-746). `topped_up` logic at city_brain.gd:351-361 ok. All as the lens says.
- Corrections: (1) "major" is only true for keyless or degraded sessions (a keyed healthy run answers live; every live answer lands in session_cache and wins the lookup). Time to day 13: FP at 1x is 12 x 20 min = 4 h; at 8x about 30 min; Planner (12 s days) 144 s (lens says 2.6 min). Realistic only for the audience-facing keyless instance at high speed, the Planner, or a rehearsal save already beyond day 12. (2) The repetition starts earlier for sparse roles: citizens|voices has only day 3 and operator|grid only day 10, so those repeat from the first call after them; council ends at day 11. (3) client.lookup() (gmi_client.gd:264-266) also serves per-resident `resident|..` and `react|..` keys (resident_minds.gd:226,453,484, max day 12 in the cache), so a horizon placed in _cache_lookup changes those too; the proposal tests only mayors, news and chaos.

### F4 Planner runs unsliced ticks: HOLDS (restates backlog item 9)
- Verified: sim_perf_feature.gd:29-34 teardown sets sliced false (lens says 29-36); city_sim.gd:574-588 _process_whole runs the first due tick regardless of budget (the budget break needs `ran > 0`); exit_fp sets 12 s days. Not web-specific: desktop orbit is identical; web only multiplies cost. Never measured on wasm (UNKNOWN, as stated).

### F5 hidden tab: HOLDS (unverified by design)
- traffic_feature.gd:557-558 `dt := delta * float(ctx.sim.speed)` then Pacing.step_for; pacing.gd:8-15 bounds only the step count (a 60 s gap becomes 12 x 5 s). Same pattern in bird_flocks.gd:115, squirrels.gd:197, cats.gd:271, animals_feature.gd:381. Whether Godot clamps the first delta after a hidden tab is UNKNOWN.

### F6 key field 128 chars, status text: HOLDS
- gmi_key_panel.gd:15,67 FIELD_MAX 128, refresh() status text 'Key in use' for any non-empty key (gmi_key_panel.gd:~142-146). is_service_failure excludes 401/403/400 (gmi_client.gd:~158-160), activity feed turns 'down' on failure ratio > 0.5 (activity_feature.gd:368-377). Placeholder text "gmi_..." hints a prefix; key length stays UNKNOWN. Cheap hedge: raise FIELD_MAX (no downside).

### F7 single breaker: HOLDS
- gmi_client.gd:54; BATCH 10 (resident_minds.gd:17) so batch count = residents/10 (cache shows r1..r112, about 11); gmi-outage.md:28 names LIVE_RESIDENTS, which only tools/tests/residents_live.gd:36 reads (README.md:124,166 documents it correctly as test-only).

### F8 JSON extraction untested: HOLDS
- No caller or test of extract_json or salvage_array outside gmi_client.gd (grep). 14 distinct model ids confirmed by grep (DeepSeek-V4.1-Flash, V4-Flash-0731, V4-Pro, gemini-3.5-flash-lite, gemini-3.8-flash, gemini-4-argon, MiniMax-M3, kimi-k3, gpt-6-luna, Qwen3.8-Flash, Qwen3.8-Max, grok-4.5, MiMo-V2.6-Flash, GLM-5.3-Flash). Ids first appear in ba1636e (2026-10-17). MODEL_EXTRAS also covers zai-org/ (gmi_client.gd:~36), which the lens omits from the list; GLM therefore is covered.

### F9 gate/CI state: HOLDS with one count wrong
- Verified: /tmp/claude-1000/gf-gate-* does not exist; memory records gate full PASS at 8818de0 and b350fea; `git diff --stat b350fea HEAD` = 5 files (+210/-14; includes city_hud.gd, city_view.gd and new fp_orbit_names_test.gd); `git log --oneline origin/main..HEAD | wc -l` = 27 (lens says 26); `git diff --shortstat origin/main HEAD` = 164 files, +21,973/-427 (matches). origin/main is a local tracking ref (e2927f8), so "nothing pushed, CI never ran" is INFERRED. Gate step arithmetic: quick = 1 + 18 listed + 104 fp_*_test + 3 = 126; full = 129 (matches). git status: 7 modified sounds/fp/*.ogg.import (adds uid/path/dest_files after reimport) and untracked tools/tests/_throwpix_capture.gd (benign).

### F10 ungated tests: HOLDS except one factual error
- Verified ungated (shell loop vs gate.sh): brain_live_test, gpu_memory_test, pack_arrival_test, pack_request_gate_test, pack_status_test. pytest: coverage floor 80 (pyproject.toml:7), 21 .py files / 3,197 lines (lens says 20 files).
- WRONG: "sim_soak_test is sim-only". Its header and sim_save_kit.gd:13-27 show a full CitySim + GmiClient(offline) + Residents + ResidentMinds + CityBrain wired as Main wires them, 2 seeds x 50 days, with a save/reload byte-identity check every 10 days (sim_soak_test.gd:2-10,14-19). It therefore already runs mayors offline through the replay cache past day 12 (so it is exactly the code path P3 changes), and it asserts no memory, node or keyed-cache growth. That narrows the real gap: no keyed session_cache growth, no scene/FP/web heap.

### F11 mitigated classes: HOLDS
- 3fccc38 (#83) is an ancestor of HEAD; audio_feature.gd teardown keeps buses; ChatterMinds has no generation token (grep _generation: none) and reset() only clears in-flight flags (chatter_minds.gd:191-196), called from chat_feature.gd:175, so a late round can still land old-city lines.

### F12 stale runbook lines: HOLDS (all three verified)
- web-deploy.md:368 "Known issue, fix in flight" (fix 3fccc38 is merged); web-deploy.md:200 GMI_OK; gmi-outage.md:28 LIVE_RESIDENTS.

### F13 first minute / recovery: one sentence is WRONG
- WRONG: "no way to force a fresh city on web". The FP pause menu has "New city (press twice)" (pause_menu.gd:19-20, pause_menu.gd:3) and the Continue toast says so (main.gd:448); the orbit HUD has the same (city_hud.gd:266, main.gd:137). What is missing is only a boot-time fresh start that skips the Continue rebuild (GRIDFALL_NEW_CITY env, main.gd:414). Other numbers confirmed from memory notes and the smoke summaries (boot 20 s and 29 s under software GL, 94.8 MB).

### F14 stampede: HOLDS (idea)
- web-deploy.md:58 "2 vCPU, 4 GiB"; Caddy precompressed br gzip (Caddyfile:22); 50 x 94.8 MB = 4.7 GB arithmetic ok.

## Proposals

### P1 Test-key button: HOLDS, effort S with caveats
- web_test.gd is in the quick gate (gate.sh:~191) and already has _check_player_key / _check_panel; fp_ops_test.gd already overrides _post. A direct 8-token call must bypass `live_enabled` (set_live requires has_key and the gmi_live flag, gmi_client.gd:~135) and the breaker, and must not feed live_outcomes/stats. Error strings are already classifiable ("HTTP 401 ...", "network result N", "HTTP 429"). "Within about 2 s" is optimistic: average live latency in the real save is 8.5 s (latency_ms_sum 4,638,385 / live_ok 546), though that is for large prompts; use a 10 s timeout and say so. Bundle the FIELD_MAX raise (F6).

### P2 Web-safe headers + strict CORS mock: CORRECTION
- The verification does not work (see F1: Playwright answers preflights itself). Value is unproven: the engine may add its own User-Agent; dropping X-Request-ID/X-Trace-ID on web loses the GMI Log correlation the runbook relies on (gmi-outage.md:20-21). Make it conditional on the curl check below; do not build before the preflight is known.

### P3 Replay horizon: CORRECTION (flag, scope, effort)
- AGENTS.md Rules: "Gate new behaviour behind a flag in data/feature_flags.json when it changes gameplay". P3 changes offline gameplay content and lists no flag or feature_flags.json. Scope: lookup() also feeds resident plans and reactions (resident_minds.gd:226,453,484); _heuristic_chaos draws from sim.rng (city_brain.gd:753-755) so offline sim state after day 12 changes, which moves sim_soak_test's fingerprint (report-only) and may touch fp_react_determinism_test / sim_determinism_test / fp_brainspread_test (they run CityBrain offline; unverified which cross day 12). Heuristic content quality past day 12 is not evidenced (lens says "good heuristics exist" from reading code only). Realistic effort: S-M (about 1-2 days) with flag, tests and a soak review.

### P4 Save diet: CORRECTION (numbers) otherwise HOLDS, effort S
- Real outcome at day 10: about 1.03 MB (dedupe + prune) or 1.33 MB (prune both), vs 2.38 MB, not "1.3-1.6 MB vs 2.7 MB". Safest variant (backlog (b)): strip nested brain.client only in Main._write_save; main._restore already calls client.from_dict(d.client) after brain.from_dict (main.gd:~395-397), so the nested copy is redundant on load; keep brain.to_dict intact (tests call CityBrain.from_dict without a client key: fp_seams_test.gd:141, fp_activity_test.gd:493, fp_brainspread_test.gd:233, sim_save_kit.gd:50; sim_save_kit.document() uses brain.to_dict and the soak asserts byte identity, so changing brain.to_dict is riskier). SaveShape requires top-level client keys (save_shape.gd:66). Skip flush_cache's file write outside record mode (never read). fp_simperf_test.gd:432 pins "never prune session_cache itself".

### P5 Autosave minimum interval: HOLDS, effort S
- fp_smoke._check_autosave must change (backlog item 12 risk). Keep first-save-after-load unthrottled; tab close fires no WM_CLOSE_REQUEST, so the morning save is the only persistence.

### P6 Keep sim sliced in Planner on web: HOLDS, effort S (measure first)
- Same as backlog item 9 sketch. Also gameplay-timing (effective speed at 8-16x), so under AGENTS.md put it behind a flag. tools/profile_sim.gd exists; `grow_offline` is a helper inside tests/tools (fp_smoke, fp_photo_tour, fp_bench, profile_sim), not a standalone script.

### P7 Hidden-tab clamp: HOLDS, effort S
### P8 Model preflight: HOLDS, S-M
- GET /v1/models CORS behaviour unknown; id count of 14 verified; checks presence only, not that each model answers in the configured mode.
### P9 Per-role breakers: HOLDS, M (low priority; agree with the lens ordering)
- Consumers verified: alerts.gd:104, activity_feature.gd:376, fp_ops_test.gd:153-171,333-338.
### P10 JSON extraction tests: HOLDS, S (register in gate.sh list at line ~191)

### P11 Gate ungated tests + soak: CORRECTION
- sim_soak_test already runs the brain offline for 50 days (F10), so the new soak's job is only keyed cache growth plus scene/node/heap, which needs the fake live client the lens mentions. The four "headless-capable" tests have no recorded pass: run each once before gating. pack_* cover split packs which ship disabled (web_split_packs default false). nightly.yml already runs `tools/gate.sh full` (nightly.yml:39), so a full-gate step needs no workflow edit.

### P12 Demo-day kit: CORRECTION (?new=1 must clear itself)
- A reload with ?new=1 still in the URL discards the rehearsal city and the fresh city's first autosave overwrites the slot, so a presenter F5 mid-demo would lose the city. Read the param once then history.replaceState it away. WebSupport already evaluates JS (web_support.gd:68-71), so reading location.search is feasible; value is skipping the Continue rebuild, since New city already exists in the pause menu (F13).

## Missed by the lens

1. A key-free decisive CORS check. A preflight needs no key: the owner can run, once, `curl -i -X OPTIONS https://api.gmi-serving.com/v1/chat/completions -H 'Origin: https://<instance host>' -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: authorization,content-type,user-agent,x-request-id,x-trace-id'` and read Access-Control-Allow-Origin / -Headers. That settles F1 (and whether P2 is needed) in a minute with no code and no key; the lens only offers key-dependent checks. Add it to tools/demo_check.sh (P12).
2. Web heap and VRAM growth over 30+ minutes is unmeasured: web-deploy.md:189 "wasm keeps its heap high-water mark"; backlog items 11 (about 270 MB redundant VRAM on a grown city), 13 and 21 (soak and memory monitoring, deferred). The lens measures save bytes but not the heap that can kill a tab.
3. Parallel fan-out per origin at dawn: 5 mayors + 6 support calls + about 11 resident batches (3,600 tokens, 55 s timeout, resident_minds.gd:209) + reactions + chatter. If api.gmi-serving.com is HTTP/1.1, Chrome allows 6 connections per host and the rest queue while Godot's HTTPRequest timeout is already running. INFERRED, unverified; one more reason for P1 to measure round-trip time.
4. flush_cache's per-day write of user://gmi_session_cache.json is dead weight outside record mode (backlog item 12) and is cheap to drop with P4.
5. The lens says nothing about ordering against the 12 Nov date (9 days). Suggested order: curl preflight (minutes) -> P1 -> P4 + P5 -> P3 (flagged) -> P6 measure -> the rest.
