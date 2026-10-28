# Save schema and version policy

A save is one JSON object written atomically by `Main._write_save` (SaveSlot: tmp file, rename,
the previous save kept as `.bak`). Sections:

| key | writer | notes |
|---|---|---|
| `sim` | `CitySim.to_dict()` | the city; versioned (below) |
| `brain` | `CityBrain.to_dict()` | mayor state; a round in progress is dropped, not saved |
| `client` | `GmiClient.to_dict()` | replay-cache metadata, never prompts or keys |
| `residents` | `Residents.to_dict()` | people and their day |
| `minds` | `ResidentMinds.to_dict()` | per-resident AI state |
| `fp` | `FpMode.to_dict()` | first/third-person section; own version, absent in orbit saves |
| `saved_at` | `Main` | display string only |

Before any section serialises, `Main._canonicalise_for_save()` settles the live world (flushes
the view's deferred rebuild queue, runs each FP feature's `canonicalise_for_save()`), and the
sim's `to_dict()` finishes any in-flight sliced job. Every `to_dict()` is pure: it photographs
settled state and moves nothing (docs/fp/S0-foundation.md §6.4).

## Sim section versions

| version | status | format |
|---|---|---|
| 1 | rejected | predates the 96x96 world; not converted |
| 2 | accepted | 96x96 world (`world` rect recorded); the load places it into the current world and the fresh wilds generated around it stay |
| 3 | current | 192x192 world; mayors no longer carry derived `pop/jobs/happiness` (recomputed on load) |

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
