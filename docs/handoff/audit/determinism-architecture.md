# Lens: determinism-architecture (read-only audit, 2026-11-03)

Repo: /home/kunalsiyag/Ambassador/Gmi_Cloud/gridfall-wt-integ, branch web/wave0, tip 720d4e0 (`git log` run).
Method: Read of AGENTS.md, README.md, docs/save-schema.md, docs/fp/ARCHITECTURE.md (lines 1-88), scripts/ai/*.gd,
scripts/sim/city_sim.gd (selected ranges), residents.gd, main.gd, ops/*.gd, tools/tests/sim_determinism_test.gd,
brain_stale_answer_test.gd, sim_save_kit.gd, support/gated_client.gd, tools/gate.sh, tools/checks/rng_seed.py; python
(stdlib json) over data/gmi_replay_cache.json and tools/tests/fixtures/save_v3_seed7.json; grep/wc. No Godot, Chrome,
Docker or network was run. "OBS" = observed in code or by a command I ran. "INF" = inferred. "UNK" = unknown.

Notation: `file:line` refers to the integ worktree at 720d4e0.

---------------------------------------------------------------------------------------------------------------------
## 1. The one-paragraph answer

The sim is a deterministic function of (seed, save, ordered external inputs). The offline path is deterministic only
because every non-live call completes synchronously inside the same frame, in dispatch order (OBS city_brain.gd:112-118
comment; gmi_client.gd:208-242 has no `await` outside the live branch). The live path feeds the sim answers whose content,
arrival order, landing tick and fallback source are all unrecorded inputs. Nothing in the repo records them, and the
"replay cache" is not a record of a session (it is a nearest-day puppet keyed role|agent). The fix is not to make the live
world deterministic; it is to make the model I/O an explicit INPUT TAPE: record every answer with the sim position at
which it landed, and consume the tape through the same four GmiClient funnels (chat_json, live_json, lookup, remember).
Then "non-deterministic to produce, deterministic to consume": same tape in, same city out, and two tapes can be diffed.

---------------------------------------------------------------------------------------------------------------------
## 2. Where non-determinism enters (N-table)

| # | Source | Where (OBS) | Reaches sim state? | Recorded today? |
|---|---|---|---|---|
| N1 | Live model content | gmi_client.gd:436-448 `request_body`: temperature 0.7 (1.0 for Kimi via `temperature_of`), no `seed` field; GMI serving determinism UNK | yes: mayor actions (city_brain.gd:343-406), resident plans (residents.gd:1003), chaos/council/operator effects (city_brain.gd:743,793,827-831) | no: `_log` drops `data` (gmi_client.gd:603-614) and keeps 300 records (MAX_LOG :28) |
| N2 | Latency and arrival order | `chat_json` awaits the HTTP (gmi_client.gd:213); five mayor pieces are started back to back (city_brain.gd:118-130) and land in arrival order; `_land_mayor` mutates a shared sim | yes: two mayors annexing the same plot, treasury, grants (city_sim.gd:3093 `apply_action`) | no |
| N3 | Landing TICK | orbit: tick = 12 s/4 = 3 s, latency 5-40 s so answers land several ticks into the day; FP: tick = 1200/4 = 300 s so most land in tick 0-1 (city_sim.gd:93, 647-648; D4 in ARCHITECTURE.md) | yes: `apply_plan` stamps `plan_day = sim.day` (residents.gd:1024); `rng_for` is seeded by `global_tick()` at call time (city_sim.gd:4169-4172) and `residents_spoke` calls `rng_for(211)` when the last resident batch lands (city_brain.gd:632-641; resident_minds.gd:235-240) so latency changes which voices the mayors hear next day | no |
| N4 | Day gate timeout | `MAX_WAIT_MS = 75000` wall clock (city_brain.gd:26,91-101); after it, late answers land the next day | yes (cross-day landing) | no |
| N5 | Retry jitter and deadlines | `_jitter := RandomNumberGenerator.new()` (gmi_client.gd:64, used :324), deadline = 2 x timeout on `Time.get_ticks_msec` (:310-325). Default seeding of a bare RNG is randomized (INF, from the comment at :61-63 "should vary between processes") | indirectly (decides live vs failure vs cache) | no |
| N6 | Circuit breaker | `CircuitBreaker.new(4, 30000)` wall-clock cool-down (gmi_client.gd:54) | yes: decides whether a call is live or cache/heuristic, and `_land_mayor` branches on the source (city_brain.gd:351) | no |
| N7 | Heuristic fallback draws the SHARED sim stream | `_heuristic_chaos` uses `sim.rng.randf()/randi_range` (city_brain.gd:754-764) | yes: a network blip on the chaos call advances `sim.rng`, so every later sim draw shifts | no (brain_stale_answer_test only guards the stale case, :276-298) |
| N8 | Cache lookups | `_cache_lookup` = session_cache first, then replay_cache, nearest day, key `role|agent` (gmi_client.gd:206,529-545) | yes | no |
| N9 | Resident model routing | `_model(k)` skips models with >=3 consecutive failures (`_bad_models`, resident_minds.gd:87-92,95-105); `_bad_models` is not saved (:591-592) | indirectly: which model plans which batch of ten | no |
| N10 | New-city seed | `randi() % 100000` (main.gd:425,452), baselined in tools/checks/baselines/rng_seed.json | yes (whole world) | only via opt-in Analytics (main.gd `Analytics.track("new_city", {"seed"...})`) |
| N11 | Wall-clock pacing | `tick_budget_ms` (city_sim.gd:120, 584-591), `_clamp_backlog` (:598-606), `_crew_debt` (:125,604-605); sliced slice budget (:56) | ticks and order are unchanged (fp_simperf determinism spec, docs/fp/slices/F-simperf.md:135-148); only player crew time depends on dropped seconds | n/a |
| N12 | Player input | decree (city_brain.gd:104-107), orders (city_sim.gd:2833), disasters (:3540), grants (:3529), speed, live toggle (city_hud.gd:274), FP blows -> `residents.remember` (fp/traffic/incidents.gd:76-82) -> resident `memory` -> prompt (residents.gd:1586) | yes | no |
| N13 | Save/load resets RNG streams | `from_dict` -> `new_city(seed)` -> `rng.seed = seed` (city_sim.gd:4341, 199); `Residents._rng` reseeded in `setup` (residents.gd:120) which `_restore` calls after the sim load (main.gd:391); `ResidentMinds._rng` too (resident_minds.gd:71). No `.state` is saved anywhere (grep: only tests read `rng.state`). `CityBrain.to_dict` omits `day_feed` (city_brain.gd:943-951) | yes: "continue from save" is not "run straight through" | n/a |
| N14 | Threads (web) | Thread/WorkerThreadPool appear only in scripts/fp/scene_loads.gd, render/midlod.gd, traffic/people_kit.gd, posters/poster_worker.gd, world/city_view.gd (grep). None in scripts/sim or scripts/ai | no (timing only) | n/a |
| N15 | Staggered mayor turn start | threshold fractions 0.09/0.27/0.45/0.63/0.81 each sit strictly inside one tick, so the start tick is schedule-fixed; deferral by `sim_idle` (mayor_turns.gd:97-101, city_brain.gd:151-152) is frame-timing dependent (INF: small) | prompt content | no |

Cosmetic randomness (NOT inputs): FP layer has 326 generator draws in 33 files and world/ui 20 more (grep), all on
generators; tools/checks/rng_seed.py forbids bare global draws except the baselined set (main.gd 2, world/city_life,
world/city_view). ChatterMinds seeds per (day, round, salt) (chatter_minds.gd:206-207,247,271,445).

---------------------------------------------------------------------------------------------------------------------
## 3. Where determinism is guaranteed (G-table) and the tests that pin it

- Seed: `city_seed`, `rng.seed` (city_sim.gd:96-99,192-199); wilds from seeded noise (:293-314); resident identity from
  its own seed (residents.gd:1120-1126, comment "resident #N is the same person in every run of this city").
- `rng_for(salt)` = f(city_seed, global_tick, salt) (city_sim.gd:4169-4172) and `shuffle_seeded` (:4177).
- Atomic `from_dict` (city_sim.gd:4311-4416): `save_is_loadable` before any mutation; docs/save-schema.md:29-43.
- Generation tokens: brain_calls.gd:11-52 and resident_minds.gd:54,70,429; brain_stale_answer_test.gd.
- sim_determinism_test.gd:28-46: "same tick-0 save loaded twice -> same state hash after 8 ticks" over sim+brain+people+minds
  (sim_save_kit.gd:77-89). NOTE what it does NOT test: save-then-continue vs straight run (N13).
- fp_simperf determinism spec: sync vs sliced produce byte-equal saves (docs/fp/slices/F-simperf.md:135-148).
- save_versions_test: byte-stable fixed point (docs/save-schema.md:73-80).
- tools/checks/rng_seed.py + baseline: no bare global RNG draws.
- GatedClient (tools/tests/support/gated_client.gd): a subclass of GmiClient that overrides chat_json/live_json. It proves
  `brain.client`/`minds.client` accept a substituted client; ReplayClient follows the same pattern.

Direct consequence (INF, strongly supported): the existing gate proves "sim + offline brain is a pure function of a save".
It says nothing about the live regime, because the live regime is only ever exercised by brain_live_test (needs a key).

---------------------------------------------------------------------------------------------------------------------
## 4. Does the product intent conflict with AGENTS.md "keep the sim deterministic"?

No, if the rule is read as a rule about the CONSUMER (scripts/sim and the landing code), not about the PRODUCER (models).
It conflicts only where the boundary leaks:
1. N7: a fallback in the AI layer draws from the sim's own stream.
2. N3/N4: landing position is an input but is not part of any state or log.
3. N13: saved state is incomplete (RNG streams, day_feed, `_bad_models`), so a save is not a true checkpoint.
4. N8: the replay "tier" is keyed so loosely that it cannot be a reproduction.
Everything else already respects the boundary (all model I/O funnels through GmiClient; sim has no Node access).

Proposed contract (put in AGENTS.md when P1/P3 land):
  state(t) = Sim(seed, checkpoint, tape[0..t]),  tape = ordered (position, input) pairs,
  position = (day, tick_in_day, ordinal within that tick).
  Producing a tape may be non-deterministic. Consuming it never is.

---------------------------------------------------------------------------------------------------------------------
## 5. Findings about the replay cache (why it is not a recorder)

Commands run (python over data/gmi_replay_cache.json, git log):
- 179 keys, 681 entries: resident 532, react 74, mayor 56, council 6, news 6, chaos 5, citizens 1, operator 1.
- Max day anywhere = 13; mayor keys cover days 1-12 (argon has 10 entries, missing days 4, 10). README.md:112 says
  "22 days are included": the file does not support that (max day 13).
- Entry shape is `{day, data}` only: no model id, no seed, no prompt hash, no latency, no source, no build.
- Resident keys are `resident|r100:Yuki Dubois` (112 distinct) and `react|id:name|type` (57): valid only for the city whose
  deterministic resident identities match (seed 7 in this build; residents.gd:1120-1126).
- Committed once (git log: ba1636e, 2026-10-17); gmi_client.gd:583-596 `flush_cache` in record mode rewrites it.
Behaviour (OBS): on day 20 `_cache_lookup` returns the day-12/13 entry for every mayor/support key, so keyless play (which
the backlog says is what keyless web visitors get: "keyless visitors make no live calls",
session-artifacts/2026-10-31/web-gap-backlog.md:100) replays the same day-12 actions and Gazette every day after 13; the only
novelty is `_replay_top_up` (city_brain.gd:360,409-431) which borrows at most one newer build and one annex from the
heuristic planner. INF: stagnation and a wall of REJECTED actions after about day 13. UNK: how it looks in practice (not run).
Also: `_land_mayor` branches on `str(res["source"]) != "cache"` (city_brain.gd:351) so a replay source string must be
preserved exactly or the top-up changes (design gotcha for ReplayClient).
Record mode is unusable by a presenter: it writes `res://data/...` (gmi_client.gd:591-596, silently skipped when the open
fails: `if rf != null`; INF: res:// is read-only in an exported build), docs/fp/ARCHITECTURE.md D9 forbids it in gates, and
on web nothing can export a file (WebSupport has no download helper, web_support.gd:1-71).

---------------------------------------------------------------------------------------------------------------------
## 6. Recommended minimal architecture

### 6.1 Layers
```
 live GMI  ->  GmiClient (adapter: HTTP, retry, breaker)      <- non-deterministic
                 |  four funnels: chat_json, live_json, lookup, remember
                 v
 SessionTape (recorder, write-only)   |  ReplayClient (player; same four funnels)
                 |                              |
                 +--------- brain/minds (_ask, _plan_batch, _react) ------+
                                      |
                                  CitySim (deterministic consumer)
```
Everything left of the funnels may vary. Everything right of them is a pure function of the funnel outputs + player inputs.

### 6.2 Tape format (JSON lines, one file per session segment; scrubbed by Redact; NO prompt text, NO keys)
```
{"t":"hdr","v":1,"session":"<Trace.session_id()>","build":"<VERSION>","seed":7,"mode":"fp|orbit","day_s":1200,
 "start":{"kind":"new|save","save_sha":"...","day":1,"tick":0},"roster":{...},"flags":{...},"stagger":true}
{"t":"call","id":"<request_id>","fn":"chat|live","role":"mayor","agent":"argon","model":"...","day":3,
 "psha":"<sha256 of USER prompt>","ssha":"<sha256 of system prompt>","plen":5120,
 "src":"live|cache|heuristic|failed","ok":true,"lat":8421,"att":1,"err":"","tok":{"in":0,"out":0},"data":{...}}
{"t":"look","key":"resident|r100:Yuki Dubois","day":3,"hit":true,"data":{...}}       # the per-resident cache funnel
{"t":"land","id":"<request_id>","at":{"day":3,"tick":1,"gt":13},"ord":7}               # position at which _ask returned
{"t":"gate","day":4,"open":"idle|timeout","waited_ms":75012}                           # N4
{"t":"in","at":{...},"kind":"decree|order|disaster|grant|ordinance|speed|live|roster|load|new|skip","args":{...}}
{"t":"dig","day":3,"gt":16,"hash":"<hash of kind/level/district + mayors + people>","pop":..,"jobs":..,"m":[{...x5}]}
{"t":"ckpt","day":3,"file":"ckpt_d3.json.gz","sha":"..."}
```
Size (OBS from the cache averages): mayor 832 B, news 1180, chaos 337, council 252, resident entry 472, react 226. A 100-resident
day is about 56 KB of answer payload, so 30 days is about 1.7 MB raw (UNK: real sessions run longer answers; zstd/gzip cuts
about 5x, INF). Fine for a user:// file; on web keep it in memory and flush at the existing day-end flush point
(city_brain.gd:228 `_queue.append(client.flush_cache)`) because every user:// write is an IndexedDB sync there.
Privacy/AGENTS.md: "Never log ... raw prompts" -> store sha256 + length only; opt-in only (`GRIDFALL_TAPE=1` / flag
`session_tape`, same convention as analytics/error log, AGENTS.md rule on opt-in local files); files stay local.

### 6.3 Exact seams (files and functions)
Record (P1):
- scripts/ai/gmi_client.gd: add `var tape: SessionTape`; call `tape.call(...)` just before each `_log(result)` in
  `chat_json` (:225,:235,:241) and `live_json` (:274) with the full result (data, latency, attempts, source, error) and the
  user/system prompt shas (compute inside the client from the arguments it already has); `lookup()` (:282) and `_cache_lookup`
  record a `look` event; parse `usage` in `_post` (:413-428; today ignored) into result["tok"].
- scripts/ai/brain_calls.gd `_ask` (:36-52): after the await and the generation check, `tape.land(res, position)`; add a `sim`
  member to the base class (CityBrain declares it, city_brain.gd:28) or read it with `get("sim")`.
- scripts/ai/resident_minds.gd: after each `live_json` return (:209, :427) record `land`; `_react_one` shares the `_react` call.
- scripts/ai/city_brain.gd: `send_decree` (:104) -> `in`; `_day_gate` (:91-101) -> `gate` when it opens by timeout;
  `_on_day_ended` (:218-233) -> digest + `tape.flush()` next to `client.flush_cache`.
- scripts/main.gd: create the tape in `_ready` after `brain.setup` (:90) when opted in; `in` events in `load_game` (:343), `new_game`
  (:451), `_continue` (:432); `client.set_live` toggle (city_hud.gd:274); roster swap.
- scripts/ops/session_tape.gd, scripts/ops/session_digest.gd (new; scripts/ops is not in any boundaries.json layer: OBS
  tools/checks/boundaries.json layers sim-core, ai-core, runtime-not-tools only).
- scripts/ops/web_support.gd: `download(name, bytes)` via `JavaScriptBridge.download_buffer` (INF: API exists in Godot 4; not run).
Replay (P3):
- scripts/ai/replay_client.gd `class_name ReplayClient extends GmiClient` (pattern: gated_client.gd). Overrides `_ready`
  (no key lookup, no cache load), `chat_json`, `live_json`, `lookup`, `remember` (no-op).
  Match order: (role, agent, day, psha) exact -> (role, agent, day, ordinal) -> policy `strict | fallback | live`.
  `strict` raises a `divergence` event and fails tests; `fallback` serves the ordinal match and emits `divergence`; `live`
  forwards to a real GmiClient (this is the FORK).
  GOTCHA 1: return the RECORDED `src` string, not a new one (city_brain.gd:351 branches on "cache"); add `replayed: true` so
  the UI can tag REPLAY (activity_words.gd:34 `source_tag`, city_hud.gd:34 SOURCE_COLORS know only live/cache/heuristic).
  GOTCHA 2: when the recorded src was "heuristic", CALL `heuristic.call()` and compare with the recorded data (a free
  determinism assertion; also keeps `sim.rng` consumption identical, which makes N7 a non-issue for replay).
  GOTCHA 3: reproduce the per-resident `lookup` events, otherwise `src` labels (saved in residents.to_dict) differ and the state
  hash cannot match.
  GOTCHA 4: it must return without a real suspension in L1 so it lands in dispatch order, exactly like the offline path.
- tools/replay.gd (headless driver): `godot --headless --path . -s tools/replay.gd -- tape.jsonl [--policy strict|fallback]
  [--swap mayor:grok=<model>] [--out new.jsonl]`: loads header/checkpoint, wires ReplayClient, steps ticks, writes digest lines.
- scripts/main.gd: `GRIDFALL_TAPE=<file>` boots the game on a ReplayClient (Replay Theatre / demo insurance).
Save completeness (P4): city_sim.gd `to_dict` (:4249) / `from_dict` (:4334) add `"rng":{"sim":"<str(state)>"}`; residents.gd
`to_dict`/`from_dict` (:1594,:1603) add `"rng"`; resident_minds.gd (:591,:595) add `"rng"` and `"bad_models"`; city_brain.gd
(:943,:954) add `"day_feed"`; scripts/sim/save_shape.gd add the optional keys. Store states as STRINGS (JSON numbers are read
as doubles, docs/save-schema.md:76-79, so a 64-bit state would lose bits).
Roster (P5): data/roster.json + scripts/ai/roster.gd; replace reads at city_brain.gd:337,398,597,701,737,780,818,912;
resident_minds.gd:13-16,87-92; chatter_minds.gd (MODEL_NAMES); sim_defs.gd:216-252 stay as defaults, `debrand` (:380-415)
must scrub every roster candidate id/brand; display sites city_hud.gd:896,934,937,950,973,981,989,1001; FP sites
fp/activity/activity_words.gd:20 (`mayor_model`), fp/reporter/reporter_desk.gd:186, fp/activity/activity_feature.gd:318,
fp/chat/chat_text.gd:115-118; scripts/cinematic.gd:273. About 16 reads in total. Save under `brain.roster` (the brain section is
already shape-checked key by key; unknown keys are ignored: scripts/sim/save_shape.gd:49-70).
`entry["model"]` (city_brain.gd:398) must become `res["model"]` (the model actually used), not the configured one.

### 6.4 Two regimes, one tape
- LIVE (street/real-time): turns are staggered over the day (mayor_turns.gd), answers land whenever; the tape records the
  landing position; replay delivers at dispatch (L1) first, at the recorded tick (L2) later.
- ARENA (lockstep): flag `lockstep_ai`. The day start holds until every call of the round has returned (or timed out), then lands
  them in CANONICAL order (mayors 0..4, then support roles), not arrival order. Latency then only affects wall time; a tape
  recorded in this regime replays bit-exactly under L1. This is the regime for model comparison and forks.
Replay levels: L1 deliver-at-dispatch (same as today's offline path; cheap; exact for lockstep tapes), L2 deliver at the recorded
(day, tick) with `gate` events replaying day-gate timeouts (needed for faithful replay of a live street session; L effort),
L3 effect-log replay at the sim boundary (`_external_entry`, city_sim.gd:1161, is already the single funnel for
apply_action/apply_player_order/enact/repeal/gift/trigger; the operator writes `sim.grid_priority` directly at
city_brain.gd:793, which would need a setter): robust against brain code changes; NOT recommended for v1.

### 6.5 Fork and diff
- Checkpoint: the tape's `ckpt` entries are ordinary saves (SaveSlot format; day-10 save is 0.73 MB keyless, 2.38 MB with a key:
  web-gap-backlog.md:302; strip `session_cache`/`brain.client` from checkpoints since the tape supersedes it).
- Fork = load checkpoint, apply a different roster, run N days (live in lockstep, or replay with policy `live` for only the swapped
  seat). Both arms record tapes; `tools/session_diff.py` aligns by `dig` day and by `(role, agent, day, ordinal)`: first divergence
  day, the first call whose psha differs (prompt drift = the effect of an earlier difference), per-district deltas.
- Control arm: re-run the ORIGINAL roster from the same checkpoint (not the original recording) so both arms share the same RNG
  reset on load (N13). This avoids needing P4 for the comparison; P4 is needed to resume a recording mid-session.
- Experimental design note for the webinar: a seat is confounded with its district (SE Boomtown vs Civic Campus). A Latin-square
  rotation of models over seats (data-driven roster) separates "the model" from "the land".

### 6.6 What it enables (showcase)
1. Session Report (static HTML from a tape, python stdlib): per-model scorecard (calls, ok %, retries, fallbacks, p50/p95 latency,
   tokens once `usage` is parsed), per-mayor outcomes (accepted/rejected actions with reasons, builds by kind, annexations,
   treasury/pop curves), interaction edges (grants between mayors, ordinance votes, quoted posts), chaos/council timeline, and a
   reproducibility box (seed, build, roster, tape sha, replay command).
2. Divergence timeline: two tapes from one checkpoint; per-day sparkline pairs; marker at the first divergence and the call that
   caused it; optional per-day RLE tile maps for a city-diff heat map (extra M).
3. Reproducible bug report: attach tape (+checkpoint) -> `tools/replay.gd` reproduces; a golden tape becomes a gate test with real
   model outputs, replacing dependence on the thin cache.
4. Demo insurance: a rehearsal tape is a bulletproof offline mode on 12 Nov (GMI down, rate-limited key, keyless visitors).
   One 30-40 day tape in res://data/tapes/ (<5 MB, AGENTS.md size rule) also fixes the post-day-13 stagnation for keyless visitors.

---------------------------------------------------------------------------------------------------------------------
## 7. Test strategy that keeps gate quick headless and deterministic

(Constraints: gate runs offline with fresh XDG dirs, no key, timeouts; non-fp tests must be added to the explicit list at
tools/gate.sh:211, fp_* tests are globbed; no wall-clock assertions; use `sleep_ms`-style hooks and GatedClient gates.)
1. `tape_test.gd`: a ScriptedModel client (extends GmiClient, seeded pseudo-random but valid answers, with random "latency" released
   by gates) drives `brain._run_mayor` and support roles for 3 days; assert header, call/land counts, order, digest per day, that the
   fake api key (registered with Redact) and the prompt text appear nowhere in the file, and that enabling the tape does not change
   the sim state hash (run twice, compare).
2. `replay_determinism_test.gd` (the core): record 6 days with ScriptedModel in LOCKSTEP order, then replay on a fresh world with
   ReplayClient(strict): per-day state hash and digest must be equal; then flip one recorded answer and assert the hash differs
   (sensitivity) and that exactly one `divergence`/miss is reported when a prompt sha changes.
3. `sim_continuation_test.gd`: straight 6 days vs 3 days + `to_dict`->JSON->`from_dict` + 3 days, same answers: state hash equal.
   First run is EXPECTED to fail and enumerate the leaks (RNG states, day_feed, `_bad_models`, any other); fix or document each.
4. `roster_test.gd`: spy client records the model passed; swap changes the next call's model; `to_dict`/`from_dict` round trip;
   save without roster loads to defaults equal to D.MAYORS/SUPPORT_AGENTS; `debrand` scrubs a swapped-in id; tape gets `roster`.
5. `arena_order_test.gd` (with lockstep): GatedClient `each` mode, release answers in shuffled orders; final state hash independent.
6. `replay_cache_compat`: legacy `data/gmi_replay_cache.json` still loads and serves through the unchanged cache tier.
7. python: tools/pytests/test_session_report.py with tools/tests/fixtures/tape_min.jsonl (coverage gate >= 80% applies to tooling).
8. Repo checks: new flags need descriptions in data/feature_flags.json; new scripts need test-map entries (tools/checks/test_map.py).

---------------------------------------------------------------------------------------------------------------------
## 8. Migration risks

Saves (docs/save-schema.md bump policy: new optional fields with safe defaults are NOT a version bump):
- New keys: sim `rng`, residents `rng`, minds `rng`/`bad_models`, brain `day_feed`/`roster`. Old saves lack them and keep today's
  behaviour (reset on load). New saves loaded by an old build ignore them (save_migration_test covers "extra fields").
- save_versions_test fixed point: the first re-save of an old fixture adds the fields, the second is identical: still a fixed
  point (INF; verify when implementing). Pinned counts do not move. No fixture regeneration needed.
- Strings for 64-bit RNG states (see 6.3).
- Behaviour change: loaded games now continue the stream instead of restarting it. That is intended, and the only visible change.
- `session_cache` in saves (2 copies: main.gd:331 `client` and city_brain.gd:949) can be pruned after the tape exists (backlog item
  12); docs/save-schema.md:12 calls it "replay-cache metadata, never prompts or keys" but it carries full answers (OBS gmi_client.gd:630-631).
Replay cache:
- Keep it untouched as the legacy lowest tier (keyless demo, tests). Never convert it into a tape (its answers predate wind farms,
  landfills, annexation: README.md:117). Fix README.md:112 (22 -> 13 days) and mark nearest-day hits with `stale_by` in the result so
  cards can say "replayed from day 12" (S, gmi_client.gd `_cache_lookup` already computes `best_d`).
- Do not touch `GRIDFALL_RECORD`; it remains the maintainers' way to extend the cache. The tape is separate and writes only to user://.
Prompt drift: psha covers the USER prompt only (state-bearing); a system-prompt edit changes ssha and is reported as
"prompt version changed", not as a divergence. A tape recorded before a user-prompt format change degrades to the ordinal match.
Heuristics: moving `_heuristic_chaos` onto `rng_for(307)` changes the fallback-only stream (the gate runs with cache hits for chaos on
days 4+, so low impact; UNK whether any test pins a fallback outcome). Optional hygiene; not needed for replay (GOTCHA 2).
Perf (AGENTS/D11 no stall > 50 ms): a stringify of one answer (<=14 KB) per call is trivial; flush only at day end.

---------------------------------------------------------------------------------------------------------------------
## 9. Sequencing against 12 Nov (today 3 Nov; the owner's note asks for a feature freeze before 12 Nov)

Decisive order:
1. P1 tape + digest (record only; zero sim risk; opt-in). Nov 3-4.
2. P2 report script (parallel; python only). Nov 4-5.
3. P3 ReplayClient L1 + replay driver + the core determinism test; then a rehearsal recording (needs the owner's key and GMI spend:
   the owner's decision) -> ship one golden tape. Nov 5-8.
4. P11 honest replay labels (S) and P10 chaos RNG hygiene (S) alongside.
5. P5 roster-as-data only if P1-P3 are green by Nov 8; freeze Nov 9.
After the webinar (or if ahead): P4 save completeness, P6 lockstep arena, P7 fork experiment, P8 divergence viewer, L2 replay.
Do NOT build before the webinar: L2/L3 replay, a live in-game fork UI, a tile-level diff map, seeding the models (UNK that GMI
honours `seed`; a one-line experiment at most), a database or any outside service (AGENTS.md rule).

## 10. Unknowns
- UNK whether GMI's API honours a `seed` parameter or returns stable output at temperature 0.
- UNK the actual landing-tick distribution in FP (inferred small spread from tick = 300 s).
- UNK the real per-session tape size (estimate from cache averages only).
- UNK IndexedDB sync cost per flush on the web build; the plan is one flush per game day.
- UNK whether `usage` is present in GMI responses (OpenAI-compatible is the assumption); no network call was made.
- UNK whether a bare `RandomNumberGenerator.new()` is randomly seeded in 4.7 (only the code comment suggests it).
- UNK how keyless play looks after day 13 (derived from code only).
