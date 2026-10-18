# Slice F: Sim performance

Branch `fp/F-simperf`, branched from `fp/integration` after S0. Read ARCHITECTURE D4 and D11, and S0 §§15.2–15.3, which define the seams you must keep. In `understand.md`, read the sections "TILE SIMULATION" and "RESIDENTS & THEIR MINDS" (the perf_hotspots parts). The baseline tool is `.../scratchpad/tools/tick_bench.gd`.

## Goal (what the player sees)

Walking through the city never hitches. Today every growth tick freezes the main thread for 280–765 ms, and the day boundary for 0.7–1.2 s. After F, the sim does the same work spread over frames: no frame stalls more than 50 ms because of the sim, residents or minds, at any time scale. Tests still get the exact synchronous behaviour.

## Owned files (exclusive)

- `scripts/sim/city_sim.gd`. Keep every S0 seam: `day_seconds`, `tick_seconds()`, `skip_to_next_day()`, display names in `mayors[].name` and the from_dict normalisation, plus every public API used by others.
- `scripts/sim/residents.gd`. Keep the S0 signals `resident_said` and `trip_started` with their exact emission semantics, and every public API.
- `scripts/ai/resident_minds.gd`, **performance changes only**. Prompts, schemas, models and outputs stay as they are, except the S0 seam at line 170.
- `scripts/fp/sim/**` (entry point `sim_perf_feature.gd`, id `sim_perf`).
- `tools/profile_sim.gd`. It calls private phase names by string; update it if you rename them.
- `scripts/ai/gmi_client.gd`, **`flush_cache()` only** (perf). Nothing else in that file.
- `tools/tests/fp_simperf_test.gd`.

## Seams consumed

| From | API |
|---|---|
| S0 | `CitySim.day_seconds` / `tick_seconds()` (FP 1200 s days, a tick every 300 s at 1×, 37.5 s at 8×); `FpMode.time_scale`; `FpContext.sim` / `residents` / `minds`; `GameBus.pause_changed` |
| Tests | `step_tick()`, `new_city(seed)`, `apply_action`, `to_dict` / `from_dict`, `_recompute_all()` (`buildings_test.gd:18,29,36` calls it by name; keep the name), `minds._on_event_started` (`residents_test.gd:78,92` disconnects it by name; keep the name) |

## Seams F provides (new public API; keep it stable once merged)

```gdscript
# city_sim.gd
## Time-sliced ticking for first person. false (default): _process runs step_tick() synchronously,
## exactly as today. true: a due tick runs as a resumable job, at most slice_budget_ms per frame.
var sliced: bool = false
var slice_budget_ms: float = 4.0
## Progress of a sliced tick; phase is a stable name ("recompute", "growth", "construction",
## "incidents", "residents", "commit", "day_end"); fraction 0..1 within the whole tick.
signal tick_progress(phase: String, fraction: float)
## Starts a sliced tick now if none is in flight and the day gate is open (waiting_for_ai false).
## Returns true if a job started. _process calls it when _time_accum reaches a tick; tests call it.
func begin_tick() -> bool
## Advances the in-flight sliced job by up to budget_ms of work. It never starts a new tick (that is
## begin_tick's job). Returns true if a tick committed during this call.
func pump(budget_ms: float) -> bool
## True while a sliced tick is between start and commit.
func is_tick_running() -> bool
## Per-pump timings since the last reset: {"pumps", "ticks", "max_ms", "p95_ms", "over_budget",
## "max_units" (largest number of work units in one pump, nested sync sections counted),
## "sync_max_ms" (the longest forced synchronous finish, reported separately)}.
func slice_stats() -> Dictionary
func reset_slice_stats() -> void
```

`residents.gd` gets the internal resumable work `begin_tick(t)` / `pump_tick(budget_ms) -> bool` and `begin_day(day)` / `pump_day(budget_ms) -> bool` (deliverable 1), which the sliced pipeline calls. The tick_done-driven synchronous path stays for `step_tick()`. `resident_minds.gd` gets `spreading() -> bool` (deliverable 3).

## Seams F may request

- From the S0 owner: `CityBrain._on_day_started` spread over frames, for example an `await get_tree().process_frame` between `_run_mayor` calls. File it in `docs/fp/requests/F-needs.md` with measurements first. **Until it lands, brain listeners are excluded from F's 50 ms budget**: `slice_stats()` reports their time separately as `"brain_ms"` (measured around the `day_started` emission minus F's own listeners), and F's hard checks exclude it.
- From G1: CityView's budgeted rebuild queue. Its 45–75 ms per tick is outside F's budget, but it counts toward the D11 total.

## Deliverables

### 1. The resumable tick (`city_sim.gd`)

The **reference** is `step_tick()`:

1. `_growth_tick()`, which is:
   - `_recompute_all()` (8 passes)
   - `_grow_zones`
   - `_construction_tick`
   - `_update_fires`
   - `_random_fires`
   - `[_incident_tick]`
   - `_recompute_all()` again
   - `_flush_changes`
2. `tick_done.emit(t)`. Residents is its only listener (connected at `residents.gd:101`), and runs `_on_tick`.
3. `tick_in_day++`.
4. `_end_day()` at the day boundary.

**Sliced mode** runs the same steps **in the same order, with the same RNG draws**, as a state machine:

- Split each `_recompute_all` pass and each `sim.active` loop into chunks of at most N tiles, where N is tuned so a chunk costs under 1 ms.
- Keep resumable cursors, and write derived maps into scratch buffers. Swap them in at the end of each pass.
- The structural arrays (`kind`, `level`, `terrain`, `district`, `sites`, `events`) change only inside the same commit points as the sync path. The guarantee is **"the same signal sequence as the sync path"**, not "exactly once per tick": even today `trigger_disaster` and `resolve_incident` call `_recompute_all()` plus `_flush_changes(true)` mid-tick (`city_sim.gd:1903-1905, 1951-1952`), so `tiles_changed` can fire more than once per tick.
- Residents work runs inside the job, `begin_tick` / `pump_tick`, processing K residents per chunk. `resident_moved`, `trip_started` and `resident_said` are emitted as each resident is processed, which spreads departures over a few frames. That is fine for E. Run `_helpers_work` after all residents, exactly as the sync path does.
- `tick_done.emit(t)` is still emitted once per tick, at the same logical point. In sliced mode Residents ignores it (`if sim.is_tick_running(): return`), because the job already did that work.
- **At most one tick in flight.** If time accumulates beyond one tick (high speed), the next tick starts on the next frame. There are no 8-tick bursts in sliced mode; the sync path keeps its guard.
- **`_time_accum` in sliced mode.** `_process` adds `delta * speed` as today; when it reaches `tick_seconds()` and no job is running, it calls `begin_tick()` and subtracts `tick_seconds()` **at commit**, not at start. `tick_phase()` (`city_sim.gd:1314`, read by CityView's `_stage_fraction`, `city_view.gd:1078`) clamps to 1.0 while a job runs.

**Re-entrancy (the job calls itself today).** The job's own phases call mutators: `_random_fires` calls `trigger_disaster` (`city_sim.gd:1422`), `_incident_tick` calls it too (1961–1984), and Residents' `_helpers_work` calls `add_incident_work` → `resolve_incident` (`residents.gd:591`). And offline `chat_json` returns without ever awaiting (`gmi_client.gd:73-111`), so `CityBrain._run_mayor` calls `sim.apply_action` **inside** the `day_started` emission (`city_brain.gd:232-259`); the chaos heuristic draws from `sim.rng` there too (`city_brain.gd:671-681`). Rules:

- Keep an `_in_job` depth counter. Code running inside the job, or inside a listener of a signal the job emits, never calls `_finish_job_now()`; it runs synchronously as part of the current phase.
- A nested `_recompute_all()` triggered by a phase (a fire, an incident resolution) is pushed onto a **job stack** as a resumable sub-job; the calling phase resumes after it. RNG order stays identical to the sync path.
- **Commit the tick before the day boundary signals**: the job sets `is_tick_running() == false` before emitting `day_ended` and `day_started`. Day-end is the last phase, so the order matches the sync path, and brain listeners that call `apply_action` see no job.
- External mutators (`trigger_disaster`, `resolve_incident`, `apply_action`, `finish_all_sites`, `clear_all_events`) called from **outside** a job while one is in flight: first `_finish_job_now()` (recorded in `slice_stats().sync_max_ms`), then do their work; in sliced mode, the `_recompute_all()` they would run synchronously is queued as a sliced recompute job instead. Note that `apply_action` itself does not recompute (only `_act_annex` does, line 353); it calls `_flush_changes(true)` (line 1515), which drains `_changed` mid-job, and that is why it must finish the job first.

**The day boundary.** `_end_day` (budget, history, `day_ended`) and `_begin_day` (`day_started`) run as job phases, after the tick commits. The 690.9 ms measured at day end (`tick_split.log`) is mostly Residents' `_on_day_started`: spawns, `_check_home` / `_check_job`, then `rebuild_maps` with `_compute_trips` at 70–84 ms (`residents.gd:331-351`). Add resumable `begin_day(day)` / `pump_day(budget_ms) -> bool` to Residents, chunked by spawn and by BFS origin, that emits `day_ready` at its end exactly as today. In sliced mode, `_process`'s waiting branch (`city_sim.gd:375-381`), which today calls `_begin_day()` synchronously when the gate opens, starts a day-start job phase instead. Brain listeners are outside F's budget until the S0 request lands (above).

**Job boundaries.**
- `to_dict()` calls `_finish_job_now()` first, so a save taken mid-job equals a save after the equivalent sync tick.
- `from_dict()` and `new_city()` call a new `_abort_job()` that drops cursors, scratch buffers, the job stack and the Residents job.
- The `sliced` property setter finishes any in-flight job before switching modes (so teardown's `sliced = false` never abandons a half tick).
- `grow_offline` (S0 §6.2) turns `sliced` off while it grows and restores it.
- Cheap wins that apply to **both** paths, as long as all legacy tests pass:
  - Mark `_trips_dirty` only when plans or roads change, instead of every tick (`residents.gd:383`).
  - Restrict `_compute_mood_map` to `sim.active`.
  - Reuse a single BFS parent buffer, cached per origin per road signature (`residents.gd:1062-1086`).
  - Remove the duplicate first `_recompute_all` when nothing changed since the last commit, only if the results are provably identical.
  - Cache `district_rect` misses.

**Threads (optional).** `WorkerThreadPool` is allowed only for pure passes over private copies, for example `_compute_pollution` into a scratch buffer, joined and swapped on the main thread within the same phase. No other thread may read live sim arrays.

### 2. The sim_perf feature (`scripts/fp/sim/sim_perf_feature.gd`)

- `setup`: `ctx.sim.sliced = true`, with `slice_budget_ms` from the quality preset (low 3, medium 4, high 5) via `bus.quality_changed`.
- `teardown`: `sliced = false` (the setter finishes any in-flight job).
- `self_test`: `sliced` is true and `slice_stats().max_ms < 50` (brain time excluded and reported). Report p95 and `sync_max_ms`.
- Expose `slice_stats()` for G2's bench.

### 3. Day-start smoothing (`resident_minds.gd`, perf only)

- **Only when `sim.sliced` is true**, `plan_day` builds the 10 batch cards across frames (`await get_tree().process_frame` between batches). Each batch's `card()` work stays at most 10 ms. With `sliced == false` the path stays byte-identical and fully synchronous: offline `live_json` returns before any await (`gmi_client.gd:120-122`), so `residents_test.gd:41-57` ticks inside `_init` without yielding a frame and still asserts "every resident has a plan for today". Spreading there would leave batches 2–10 unrun.
- Expose `spreading() -> bool` (true while spread batches are pending). In sliced mode, `begin_tick()` does not start a new tick while `minds.spreading()` is true, so whether a batch lands before or after the next tick never depends on wall-clock time.
- Results must equal the current offline output: same plans, same order of `apply_plan` calls per resident.
- `_react` builds its responder cards in one frame only if that takes at most 5 ms; otherwise split it (sliced mode only, same rule).

### 4. `GmiClient.flush_cache()` (perf only)

- Prune a **copy** of the session cache to the last 3 days per key before stringifying. Never prune `session_cache` itself: record mode merges `session_cache[key]` into the replay cache (`gmi_client.gd:303-305`) and `_cache_lookup` reads it (277–292).
- Skip the write when nothing changed since the last flush.
- Never change record-mode behaviour (`GRIDFALL_RECORD`). Never write `res://data/gmi_replay_cache.json` outside record mode.

## Acceptance tests

`tools/tests/fp_simperf_test.gd`, token `FP_SIMPERF_TEST: PASS`. It runs headless and offline.

1. **Determinism (sync vs sliced).**
   - Build world A: `new_city(7)`, the scripted actions from `sim_test.gd:9-23` (the `acts` list at 9–18 plus the three mayor-4 actions at 21–23; lines 24–25 are the 40-day loop header), plus `Residents` **and `ResidentMinds` with an offline `GmiClient`** (without minds, `resident_said` never fires: `_post_message` is only called from `apply_plan` and `respond`, `residents.gd:684, 726`).
   - Connect a `day_started` listener that calls `sim.apply_action(0, <a small road action>)` (the brain does exactly this offline, inside the emission), and force a fire mid-run (`trigger_disaster` from a `tick_done` listener on tick 10) so the nested-recompute path runs.
   - Run 40 ticks with `step_tick()`.
   - Build world B identically with `sliced = true`. Drive it with `while committed < 40: if not sim.is_tick_running(): sim.begin_tick()` then `if sim.pump(4.0): committed += 1` (`pump` never starts a tick; `_time_accum` only advances in `_process`, so a loop that waits for a "due" tick would hang).
   - `JSON.stringify(sim.to_dict())` must be equal, and `JSON.stringify(people.to_dict())` and `JSON.stringify(minds.to_dict())` must be equal.
   - Every derived array must be bitwise equal: `pollution`, `crime`, `land_value`, `traffic`, `happiness`, `powered`, `watered`, `road_dist`, the seven `cov_*` arrays, `burning`, `trip_load`, `mood_map`, plus `demand` and `stats`.
   - The sequence of `(signal, args)` for `tiles_changed`, `day_started`, `day_ended`, `trip_started` and `resident_said` must be identical.
2. **Budget (structural, hard).** Over those 40 ticks, `slice_stats().max_units` stays within the configured units-per-pump limit (nested sync sections counted). This check does not depend on machine load.
   - **Wall clock (report-only in `quick`).** Print `max_ms`, p95 and `sync_max_ms`. Quick-gate unit tests do not run under the heavy lock and the machine is shared, so a wall-clock hard check would be flaky. The hard `max_ms ≤ 50` check is the FP smoke's `sim_perf` `self_test` and the bench, which run under the lock.
3. **Sync path untouched.** With `sliced = false`, `_process` still runs `step_tick()` with the guard of 8. A fake 30 s delta at speed 16 runs exactly 8 ticks in one call.
4. **Skip.** `skip_to_next_day()` works in both modes. In sliced mode it completes any in-flight job first.
5. **Day boundary.** In sliced mode, `day_started` fires exactly once per day, `is_tick_running()` is false inside the `day_ended` and `day_started` handlers, Residents' `day_ready` fires after `pump_day` completes, and `waiting_for_ai` gating still holds the next day when `day_gate` returns false (stub Callable).
6. **Job boundaries.** A save (`to_dict`) taken mid-job equals a save after the equivalent sync tick. `from_dict` and `new_city` mid-job leave `is_tick_running() == false` and no stale cursor. Setting `sliced = false` mid-job finishes it.
7. **Minds.** With `sliced = false`, `plan_day` completes synchronously (all plans set before `step_tick` returns, as `residents_test` requires). With `sliced = true`, `minds.spreading()` is true until the batches finish and `begin_tick()` returns false meanwhile.
8. **Legacy.** `tools/gate.sh quick` keeps all five legacy unit tests green, and `full` keeps both smokes green. The orbit smoke has no `sliced` flag set.

FP smoke: the `sim_perf` `self_test()` (above). With F merged, fp_bench `street_tick` should report `max_ms < 50` from sim work. Attach the bench table to the hand-off. The view-rebuild share belongs to G1.

## Performance budget

| Item | Budget |
|---|---|
| Sliced sim work per frame | ≤ `slice_budget_ms` (4 ms default), p95 ≤ 6 ms |
| Any single frame stall from sim, residents or minds, at 1× and 8× in FP | ≤ 50 ms (D11) |
| Day boundary, including Residents' `pump_day` and minds card building (brain listeners excluded and reported as `brain_ms` until the S0 request lands) | ≤ 50 ms per frame |
| Throughput | a tick must finish in under 50% of its real interval at 8× (37.5 s), so in under 18 s of sliced pumping |

## Risks

- **Determinism.** Any reordering of `rng` calls changes the city and breaks the replay seeding (`residents.gd:766-767`). The determinism test is the guard.
- **Readers.** The view, HUD, traffic and chat read derived maps mid-tick. With scratch-buffer swaps they see either the old or the new pass, never a partial array.
- **Re-entrancy.** See deliverable 1: the job calls mutators itself and brain listeners call `apply_action` inside `day_started`. Only calls from outside the job finish it (`_finish_job_now()`); calls from inside run as part of the current phase, with nested recomputes as sub-jobs.
- **Name coupling.** Tests call private names (`_recompute_all`, `_on_event_started`). Do not rename them.

## Do NOT touch

- `city_view.gd`, `city_brain.gd` (request it instead), `main.gd`, the S0 files and other slices' files.
- Prompt and schema text in `resident_minds.gd`.
- The replay cache.
