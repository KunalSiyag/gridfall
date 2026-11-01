# Save will not load

## Symptoms

`F9` / Load shows an empty or reset city, or the console prints a JSON parse error for `user://gridfall_save.json`.

## Confirm

1. Find the file: on Linux it is under `~/.local/share/godot/app_userdata/<project name>/gridfall_save.json` (the project name is `config/name` in `project.godot`).
2. `python3 -m json.tool gridfall_save.json > /dev/null` shows whether the JSON is valid.

## Fix

- **Invalid JSON (crash mid-save):** restore the previous copy if you have one; otherwise start a new city. Keep the broken file and open a bug with it attached.
- **"Save file is invalid" toast:** the load refused the save: a version other than 2 or 3, tile arrays that do not match the world size it declares, or a section (the sim's own, or the brain, client, residents or minds) that is not the kind of value the loaders read (`scripts/sim/save_shape.gd`). The refusal changes nothing: `CitySim.from_dict` and `Main._restore` check before they touch the live city, so the city you are in is intact and you lose nothing by trying. If the slot's backup (`gridfall_save.json.bak`, the previous save) loads, Load and the launch use it instead, so the toast only shows when neither file loads. Keep the refused file and open a bug with it attached: the next autosave moves it to `.bak`.
- **Valid JSON from an older version:** `CitySim.from_dict` migrates old 96x96 saves; for other gaps, open a bug with the save and the version from `VERSION`.
- **First-person state missing:** feature state lives under `save["fp"][<feature id>]`. A feature that changed its format must accept `{}` in `from_dict`.

## Verify

Load succeeds and `tools/gate.sh full` (orbit smoke does a save/load round trip) passes.
