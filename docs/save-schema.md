# Save schema and version policy

A save is one JSON object written atomically by `Main._write_save` (SaveSlot: tmp file, rename,
the previous save kept as `.bak`). Sections:

| key | writer | notes |
|---|---|---|
| `sim` | `CitySim.to_dict()` | the city; versioned (below) |
| `brain` | `CityBrain.to_dict()` | mayor state, council history and notes (below); a round in progress is dropped, not saved; `brain.ledger` (below) |
| `client` | `GmiClient.to_dict()` | this session's cached answers (`session_cache`, pruned for the save, see below) and the call counters; never prompts or keys |
| `residents` | `Residents.to_dict()` | people and their day |
| `minds` | `ResidentMinds.to_dict()` | per-resident AI state |
| `fp` | `FpMode.to_dict()` | first/third-person section; own version, absent in orbit saves |
| `saved_at` | `Main` | display string only |

Before any section serialises, `Main._canonicalise_for_save()` settles the live world (flushes
the view's deferred rebuild queue, runs each FP feature's `canonicalise_for_save()`), and the
sim's `to_dict()` finishes any in-flight sliced job. Every `to_dict()` is pure: it photographs
settled state and moves nothing (docs/fp/S0-foundation.md §6.4).

## The client section and its size

`client.session_cache` is `{key: [{day, data}, ...]}`: every live answer of the session, so that
a key that fails later, or a resumed game, can fall back to the nearest answer it remembers. A save
keeps each key's **last 3 distinct days** (`GmiCache.SAVE_KEEP_DAYS`; `GmiClient.to_dict()` builds
the pruned copy, the in-memory cache is never pruned), and the brain's own `brain.client` copy is the
same pruned dictionary. Before the diet the section grew by about 105 KB a game day (the real day-10
save was 2.38 MB, 72% of it these two copies); a lookup reads the nearest day, so older entries are
never the answer once newer ones exist, and the saved size now stops growing (a synthetic 60-day
cache with twice the recorded keys saves in well under 1.5 MB, asserted by
`tools/tests/fp_gmi_cache_test.gd`). While recording (`GRIDFALL_RECORD=1`) the whole cache is saved,
because it is what gets merged into the replay file. Loading a pruned save and saving again gives the
same bytes. `Main.new_game()` clears the cache and zeroes the counters (`GmiCache.clear_session(client)`),
so a New City never replays the last city's answers. Older saves with the whole cache load as they
always did.

## The model ledger section (`brain.ledger`)

`ModelLedger.to_dict()` (scripts/ai/model_ledger.gd, flag `model_ledger`) is what the street league's
Orders and Speed columns, its Services & minds page and the orbit Arena tab read: per model (and per
mayor, and per model outside the mayors' chairs: `svc`) the counts of calls, live answers, failures, replayed and scripted answers, retries, errors by
class, repairs by kind, tokens, truncated replies and roles, the last 50 live answer times (for p50 and
p95) and the last 8 outcomes (the health light), plus each mayor's turns by source, accepted and
refused orders and order mix, and the newest 40 events. Never prompts, replies, keys or request ids.
It is bounded: at most 48 models, 12 error classes, 12 roles and 24 order types per entry, 50 times and
8 outcomes per entry; a measured 450-call, 14-model ledger saves in about 13 KB and 2000 more calls
change numbers, not size (`tools/tests/ai_ledger_test.gd`). The section is optional: a save from before
it loads with an empty ledger, a damaged one is ignored, and every number read back is clamped, so an
edited save cannot break or grow it. `New City` starts an empty ledger. Tokens are what the API
reported for the last attempt of a call (nothing is counted for a reply without `usage`), and "time to
answer" is the call's `latency_ms`, which includes retries, back-off and waiting behind other calls.

## The brain section: council history and notes

`brain.council_history` is the council's last 20 rulings, newest last (`CouncilLog.KEEP`): one
record per proposal the Speaker looked at and one per repeal, each `{day, key, by, by_id, votes
{mayor id: "yes"|"no"}, notes {mayor id: reason}, yes, no, outcome (enacted|rejected|deferred|
repealed), against, override, statement, source}`. `against` is true when the outcome disagrees
with the count (enacted with fewer than 3 yes, or kept out with 3 or more); `override` is `against`
for a ruling a live Speaker made (`source` "live") and false for a replayed or offline one, whose
Speaker never read today's votes. The City Hall tab and the street's council card read both.
`brain.last_council` also carries the same records as `tally` for its
proposals. `brain.notes` is what the mayors left each other under flag `mayor_context_v2`:
`{recipient id: [{from, day, kind (note|request), text, amount, seen}]}`, at most 4 per recipient
(`MayorContext.NOTES_PER_MAYOR`), 120 characters of text, an amount only for a request (at most
3000), dropped after 8 days. Both are optional with safe defaults (empty), so they are not a
version bump. A load rebuilds them rather than trusting them (`CouncilLog.restore`,
`MayorContext.restore`): unknown outcomes, mayors and extra seats are dropped, tallies are
recomputed from the votes, text is de-branded and cut again, and the newest 20 / 4 are kept even if
the file holds more. `SaveShape` refuses a save whose `council_history` is not an array or whose
`notes` is not a dictionary.

## Sim section versions

| version | status | format |
|---|---|---|
| 1 | rejected | predates the 96x96 world; not converted |
| 2 | accepted | 96x96 world (`world` rect recorded); the load places it into the current world and the fresh wilds generated around it stay |
| 3 | current | 192x192 world; mayors no longer carry derived `pop/jobs/happiness` (recomputed on load) |

`CitySim.from_dict` checks a save before it changes anything, and returns false (the live city is
left exactly as it was, `sim_load_atomic_test.gd`) when the version is not 2 or 3, the `world`
block is not a rectangle of numbers with tiles, `kind` or `district` are not arrays of `w * h`
entries, or, in this build's own 192x192 world, `level`, `terrain` or `burning` are not arrays of
that length (a version 2 save may leave those three short or out; the placement fills the rest).
It refuses a save with any other section of the wrong kind of value too
(`scripts/sim/save_shape.gd`): the counters (`seed`, `day`, `tick_in_day`, `event_seq`,
`site_seq`, `crew_seq`) must be numbers, `ordinances` a dictionary, `disabled_until` and
`broken_roads` dictionaries of numbers, `grid_priority` and `log` arrays, and `mayors`, `events`,
`history`, `sites` and `crew_jobs` arrays of dictionaries whose numeric fields the load converts
are numbers (every incident has a `type`, `x` and `y`; its `tiles` are numbers). A section a save
leaves out is fine, the loader has a default for it; a section that is there with the wrong kind
of value, null included, is refused. These are checks of shape, not of meaning: a tax rate of 1e9
is still a number and loads.

`Main._restore` runs the same kind of check on the other sections before it calls the sim
(`SaveShape.document_ok`): `sim`, `brain`, `client`, `residents` and `minds` must be dictionaries,
and the arrays and dictionaries inside them that their `from_dict` reads must be the kind it casts
them to (the brain's own copy of the client's state, `brain.client`, is checked like the top-level
`client` section, since the brain loads it with the client's `from_dict`). So a save that is wrong
anywhere in these is refused as a whole and the sim, brain, people and minds all stay as they
were. What is still not checked is the content of a record that is the
right kind: a resident or mayor record with keys missing or odd values loads and can fail on first
use (a `residents.people` of `[{}]` raises script errors every frame; a `brain.mayor_state` entry
without `thoughts` fails at the first mayor turn). Saves the game wrote never look like that.

A file the build refuses this way is skipped like an unreadable one: `SaveSlot.read(path, accept)`
falls back to the backup, `Main._read_save` passes it `Main._restorable` (`SaveShape.document_ok`
and `CitySim.save_is_loadable`), and both in-game Load and the launch that continues the city go on
from the previous save instead of reporting an invalid save or starting a new city. Only when the
slot and its backup are both refused does the launch start a new city (and the next autosave then
moves the refused file to `.bak`, so it is kept for a bug report).

## Bump policy

- Bump the version when the **meaning** of an existing field changes or a field's absence can no
  longer be defaulted safely. New optional fields with safe defaults are **not** a bump.
- When the version moves: `from_dict` keeps accepting every version listed above, a fixture of
  the new version is committed (tools/tests/fixtures/, regeneration steps in
  tools/tests/fixtures/GENERATE.md), and `save_versions_test.gd`'s `accepted` list and pins move
  with it.
- The FP section follows the same policy with its own `FpMode.SAVE_VERSION` (currently 1; no
  past versions yet).

## The contract test

`tools/tests/save_versions_test.gd` loads every committed fixture, migrates it, and asserts the
save reaches a **byte-stable fixed point**: the migrated save, loaded again, re-serialises to
the same bytes. Note the first load normalises JSON number types (Godot's parser reads `2` as
`2.0`), so a fixture file can differ from its first re-save in `2` vs `2.0` text only; the
second generation must be identical. The test also pins each fixture's city (day, population,
road tiles) so a silent migration drift fails, and that version-1 saves stay rejected.
