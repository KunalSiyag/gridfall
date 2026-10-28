extends SceneTree
## Save-schema contract (docs/save-schema.md): a committed fixture of every save version the sim
## still accepts (2 and 3; version 1 predates the 96x96 world and is rejected) loads, migrates to
## the current version, and reaches a byte-stable fixed point — a migrated save, loaded again,
## re-serialises to the same bytes. The first load normalises JSON number types (2 parses to
## 2.0), so the fixture file itself may differ from its first re-save; the second must not.
## The pins (day, population, road tiles) are what the generator built, so a fixture swap has to
## move them. Regeneration recipe: tools/tests/fixtures/GENERATE.md.
## Headless, offline. Prints SAVE_VERSIONS_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")

## One entry per accepted version: the fixture, and the city the generator built in it.
const FIXTURES := {
	2:
	{"file": "res://tools/tests/fixtures/save_v2_seed7.json", "day": 11, "pop": 144, "roads": 156},
	3:
	{"file": "res://tools/tests/fixtures/save_v3_seed7.json", "day": 11, "pop": 144, "roads": 156},
}

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	print(("SAVE_VERSIONS_TEST:   ok   " if ok else "SAVE_VERSIONS_TEST:   FAIL ") + what)
	if not ok:
		fails.append(what)


func _sim() -> CitySim:
	var sim: CitySim = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	get_root().add_child(sim)
	return sim


func _road_tiles(sim: CitySim) -> int:
	var n := 0
	for k in sim.kind:
		if k == D.ROAD:
			n += 1
	return n


func _check_fixture(version: int, spec: Dictionary) -> void:
	var raw := FileAccess.get_file_as_string(str(spec["file"]))
	var parsed: Variant = JSON.parse_string(raw)
	check(typeof(parsed) == TYPE_DICTIONARY, "v%d: the fixture parses" % version)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed
	check(
		int(data.get("version", 0)) == version,
		"v%d: the fixture carries its own version (%s)" % [version, str(data.get("version", "?"))]
	)
	var sim := _sim()
	check(sim.from_dict(data), "v%d: the current build still loads it" % version)
	check(
		(
			sim.day == int(spec["day"])
			and int(sim.stats.get("population", 0)) == int(spec["pop"])
			and _road_tiles(sim) == int(spec["roads"])
		),
		(
			"v%d: the migrated city is the fixture's (day %d, pop %d, roads %d)"
			% [version, sim.day, int(sim.stats.get("population", 0)), _road_tiles(sim)]
		)
	)
	var first := JSON.stringify(sim.to_dict())
	var reparsed: Variant = JSON.parse_string(first)
	var sim2 := _sim()
	check(
		int((reparsed as Dictionary).get("version", 0)) == 3 and sim2.from_dict(reparsed),
		"v%d: the re-save is a version-3 save and loads" % version
	)
	var second := JSON.stringify(sim2.to_dict())
	check(
		second == first,
		"v%d: the migrated save is a byte-stable fixed point (%d bytes)" % [version, first.length()]
	)
	sim.queue_free()
	sim2.queue_free()


func _init() -> void:
	await process_frame
	var accepted := [2, 3]  # city_sim.from_dict; docs/save-schema.md's version history
	var keys := FIXTURES.keys()
	keys.sort()
	check(
		keys == accepted, "a fixture per accepted version (%s vs %s)" % [str(keys), str(accepted)]
	)
	for version: int in keys:
		_check_fixture(version, FIXTURES[version])
	# The rejected version stays rejected.
	var sim := _sim()
	check(not sim.from_dict({"version": 1}), "version 1 saves stay rejected")
	sim.queue_free()
	await process_frame
	print("SAVE_VERSIONS_TEST: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	quit(0 if fails.is_empty() else 1)
