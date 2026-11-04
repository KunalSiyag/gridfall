# The long-session soak (`tools/tests/fp_soak.gd`)

A live demo is a long session: five mayors on different models, days played at 8x, a tab left in the
background. `fp_soak.gd` plays 40 game days at 8x in first person against a scripted client
(`tools/tests/support/soak_live_client.gd`), so every live path runs and the session cache fills as
it does with a key, with no key and no network. It is **not** part of `tools/gate.sh` (it takes
minutes); the nightly workflow runs it after the full gate and opens the `Nightly gate failing`
issue when it fails.

```bash
godot --headless --path . -s tools/tests/fp_soak.gd              # 40 days, about 10-25 minutes
GRIDFALL_SOAK_DAYS=10 godot --headless --path . -s tools/tests/fp_soak.gd   # a quick look
```

It prints one `FP_SOAK day=...` row per game day (node count, static memory, objects, orphan nodes,
cache keys and entries, the size of the save the game would write, live calls, population) and ends
with `FP_SOAK: PASS` or `FP_SOAK: FAIL <reasons>`. The caps it asserts, measured against day 6 so the
first growth is not counted: nodes under 1.5x plus 800, static memory under 1.6x, the save under 3 MB
and no more than 1.35x its size at day 13, the saved cache at most a few days per key, no breaker open,
mayor and resident calls really served, no script error, and no one error site repeating more than 60 times (a bug that raises every frame is thousands; the headless dummy renderer's own errors come in a few bursts and are not counted against the run).

## When it fails

- **nodes or static memory over the cap:** something is added every day and never freed. Compare the
  rows: the day the growth starts, and whether `orphans` grows with it (nodes that were removed from
  the tree but never freed). `Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)` and
  `Node.print_orphan_nodes()` name them.
- **the save keeps growing:** look at `saved_cache_entries` first. It must stop at a few days of
  answers per key (`GmiCache.SAVE_KEEP_DAYS`, [save-schema.md](../save-schema.md)); if it does, the
  growth is in the sim, minds or `fp` sections.
- **script errors, or one site repeating:** the log has the first `SCRIPT ERROR` with its backtrace; a per-frame error repeats thousands of times, so look at the first one.
- **"the soak measured N of 40 days":** the run hit its wall-clock cap (`GRIDFALL_SOAK_SECS`) or the
  day gate stalled; a day that never ends is a hang, look for the last row.

The soak uses the 12 s Planner day length so that 40 days take minutes, and speed 8: it exercises the
day-boundary work (autosave-sized saves, day rounds, caches) forty times, not forty real first-person
days of street time. A run on the real 1200 s day is the same code 100 times slower.
