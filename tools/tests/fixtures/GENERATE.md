# Regenerating the save fixtures

`save_v2_seed7.json` / `save_v3_seed7.json` are the save-schema contract's fixtures
(docs/save-schema.md): the same small seed-7 city, saved by the last build that wrote each
version.

Run `tools/gen_save_fixture.gd` under the build whose format you need (it only uses
`new_city` / `apply_action` / `step_tick` / `to_dict` / `district_rect`, which exist in every
era):

```bash
# v2: the last version-2 writer (the parent of the 192x192 world commit)
git worktree add /tmp/gf-v2gen ba1636e
cp -a .godot /tmp/gf-v2gen/.godot   # first launch otherwise imports ~460 MB
XDG_DATA_HOME=$(mktemp -d) GRIDFALL_OFFLINE=1 godot --headless --path /tmp/gf-v2gen \
    -s $PWD/tools/gen_save_fixture.gd -- $PWD/tools/tests/fixtures/save_v2_seed7.json

# v3 (current): run in this checkout
XDG_DATA_HOME=$(mktemp -d) GRIDFALL_OFFLINE=1 godot --headless --path . \
    -s tools/gen_save_fixture.gd -- tools/tests/fixtures/save_v3_seed7.json
```

The generator prints `GEN_OK ... day=11 pop=144` — `save_versions_test.gd` pins those numbers
(and the road-tile count), so update the pins there when the city changes on purpose.
