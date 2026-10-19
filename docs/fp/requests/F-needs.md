# Slice F (sim performance): requests to other slices

With F, the sim's own work runs time-sliced in first person: at most `slice_budget_ms` per frame
(4 ms on medium). The remaining frame spikes on growth ticks and day boundaries come from two
listeners that run inside F's job but belong to other owners. F leaves their time out of its own
budget and reports it in `CitySim.slice_stats()` as `view_ms` and `brain_ms` (each also has a
`_total`). Each item below has a local fallback, so nothing is blocked on it.

Measurements were taken on 2026-10-19 with seed 7, offline, at 1600x900 on the shared RADV
RENOIR GPU. The fp_bench street spot ran at 12 s days and 1x. A scratch probe (not in the repo)
split every frame by node, using probe nodes placed between process priorities. The 16-day city
ran headless.

| Frame contributor (tick and day-end frames) | fp/integration | fp/F |
|---|---|---|
| `CitySim` node, the slowest frame | 382 ms (day end), 171–177 ms (tick) | 56–72 ms warm, up to 2555 ms when the view loads a model cold (G1 item 2); all of it is the view's `tiles_changed` rebuild |
| The sim's own pump (`slice_stats().max_ms`) | n/a (synchronous) | 4.3–5.5 ms at day 6, 4.85 ms at day 16 |
| `tiles_changed` rebuild in CityView (`view_ms`) | inside the 171–382 ms | 34–72 ms warm at day 6, 198 ms headless at day 16, 530–2552 ms with a cold model load |
| `day_started` in CityBrain (`brain_ms`) | inside the 382 ms | 35–39 ms at day 6, 27–29 ms headless at day 16 |
| fp_bench `street_tick` max / `street_day_end` max | 240 / 442 ms | 89–126 / 77–392 ms (the day-end maxima are cold model loads) |

## To S0 (owner of `scripts/ai/city_brain.gd`)

1. **Spread `CityBrain._on_day_started` over frames (one mayor per frame).** Offline, at day 6, the
   five `_run_mayor` calls cost 4.7 / 3.1–5.3 / 2.0 / 2.7 / 5.2–6.4 ms each headless (17.7–21.9 ms
   in all). The view rebuilds triggered by their `apply_action` calls make that 35–39 ms windowed,
   all in one frame on top of a frame that already takes about 48 ms of GPU time. F now provides
   the seam, and `fp_simperf_test` covers it with a brain-like listener ("1b. spread sources"):
   - Spread only when `sim.day_start_deferred()` is true, which means the emission comes from the
     sliced day job. Otherwise run everything inline as today: `step_tick()`, orbit, tests,
     `start()` and `skip_to_next_day()` stay synchronous and unchanged.
   - Register once: `sim.add_spread_source(func() -> bool: return not _queue.is_empty(), _finish_queue)`.
     While the gate is true, the sim's day job and `begin_tick()` wait. Residents' day work, minds
     planning and the next tick therefore come after the last mayor, exactly as in the synchronous
     path, and `sim.rng` draws (the chaos heuristic) keep their order.
   - Run each deferred piece, including the ones `_finish_queue` runs, through
     `sim.run_in_phase(piece)`. Inside it, `apply_action` and `trigger_disaster` neither force the
     job to finish nor recompute on the spot; the recompute they owe runs as a sub-job right after
     the piece. The pieces must not await. Keep the support calls (`_run_support`: citizens, news,
     chaos, operator, council) after the last mayor, in today's order.
   - `to_dict()`, `skip_to_next_day()` and `sliced = false` call `_finish_queue` through the gate,
     so a save never cuts a day start in half. Clear the queue in `from_dict` and `new_city` paths
     (F's `_abort_job` drops only its own job).
   *Fallback:* none needed. F leaves brain time out of its budget and reports it as `brain_ms`.
2. **Live mode: apply a late mayor's actions when no sliced job is in flight.** When a GMI response
   lands while a sliced tick is in flight, `apply_action` must first finish that tick
   synchronously (`_finish_job_now`, reported as `slice_stats().sync_max_ms` / `sync_finishes`).
   That costs up to a whole tick: 171–177 ms at day 6, view rebuild included. Before applying,
   `while sim.job_pending(): await get_tree().process_frame` (a tick takes about 41 pumps, roughly
   2 s at 20 fps). Offline nothing changes, because offline `chat_json` returns inside the emission.
   *Fallback:* the forced finish, which is correct but hitches.

## To G1 (owner of `scripts/world/city_view.gd`)

1. **The budgeted rebuild queue for `tiles_changed` in first person.** This is the largest spike
   left on tick frames: 34–55 ms per emission at day 6 windowed, and 198 ms for one emission at
   day 16 headless. F emits `tiles_changed` at the same logical points and with the same indices
   as the synchronous path, and the determinism test pins that, so F cannot split the emission.
   The rebuild queue on `fp/G1` (`rebuild_budget_ms = 3.0`, `flush_rebuild_queue()`, which
   `main.grow_offline` already calls) is the fix. With it, every tick and day-end frame should sit
   at the sim's 4–5 ms plus the queue's 3 ms.
   *Fallback:* F leaves view time out of its budget (`view_ms`). A pump that has already paid for
   a rebuild in its frame starts no further step.
2. **Load building models before their first tile appears, not inside the rebuild.** The worst
   frames in four runs on `fp/F` (530, 686, 2552 ms, and the bench's 392 ms on `street_day_end`)
   are first-time `load()` calls in `CityView._scene()` during a `tiles_changed` rebuild. On day 7
   the first police station and two parks complete. The 32 tiles of that emission cost 2552 ms
   cold, 41 ms rebuilt warm, and VRAM grows by 45 MB at that moment. Cold `load()` of each
   `models/real/buildings/*.glb` takes 190–390 ms windowed (park 390, fire station 358, school
   310, hospital 274, landfill 254, police 214 ms), before `_tune_materials` and the first
   pipeline compile. Two options: warm every building model once at boot or under the loading
   veil, or start `ResourceLoader.load_threaded_request` on `site_started`, since a site stands for
   several ticks before its building appears, and draw the site until the load finishes.

## To G2 (owner of `tools/tests/fp_bench.gd`)

1. **Report the sim's share next to the frame times.** At 1600x900 on this GPU, a street frame
   takes about 47–50 ms of GPU time, so `max_ms < 50` on `street_tick` can never hold for the whole
   frame. Call `sim.reset_slice_stats()` before `street_tick` and before `street_day_end`, then add
   `sim.slice_stats()` to each of those rows (`max_ms`, `p95_ms`, `view_ms`, `brain_ms`,
   `sync_max_ms`, `pumps`, `ticks`). The `sim_perf` feature also exposes it as `slice_stats()`.
   The D11 check for F is then `slice_stats().max_ms < 50`, which is 4.85–5.45 ms today. View and
   brain time are reported separately until the two items above land.
   *Fallback:* the FP smoke's `sim_perf` `self_test` checks `max_ms < 50` under the heavy lock.

## Answered (from C-needs.md)

- `Residents.remember(r, line)` and `Residents.nudge_mood(r, delta)` are public on `fp/F`. They
  behave as C asked: a dated memory line, an exact repeat skipped, the last 8 kept, and mood clamped
  to 0..10.
- Optional `heard_in_town` on `card(r)` is **not done**. `card()` feeds the resident prompts, and
  any change to it changes the prompt text and therefore the replay-cache keys. F's contract
  freezes prompts and outputs (performance changes only). It belongs to whoever owns the prompts,
  and C's own fallback (`your_recent_chat` in the talk prompt) covers it.
