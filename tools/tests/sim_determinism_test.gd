extends SceneTree
## Sim boot determinism (AGENTS.md: "Keep the sim deterministic and headless-safe ... no randomness
## without the sim seed"): a save made at a day boundary (tick 0), loaded through the same path as
## Main.load_game and stepped the same number of ticks, must end in the same state every time.
##
## The day-start decision pass used to draw from Godot's global RNG stream (CitySim.sample_citizens
## called Array.shuffle(), CityBrain.residents_spoke() used randf()), so two boots of one save
## sampled different citizens and ranked different voices: the cities diverged. Every draw on the
## run/load path now comes from CitySim.rng_for(), which is seeded from the city seed and the tick.
##
## Headless, offline. Prints SIM_DETERMINISM_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
## Ticks each loaded world runs before its state is hashed (two whole days at 4 ticks a day).
const TICKS := 8
const SEED := 7

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	print(("SIM_DETERMINISM_TEST:   ok   " if ok else "SIM_DETERMINISM_TEST:   FAIL ") + what)
	if not ok:
		fails.append(what)


func _init() -> void:
	await process_frame
	var save := _make_save()
	# Two independent worlds load the same bytes; nothing about the first may colour the second.
	var a := SK.load_into_new(get_root(), save)
	var b := SK.load_into_new(get_root(), save)
	check(
		SK.state_hash(a) == SK.state_hash(b),
		"the same tick-0 save loaded twice ends in the same state after %d ticks" % TICKS
	)
	var ca := _counts(a)
	var cb := _counts(b)
	check(ca == cb, "the two loads agree on the city: %s vs %s" % [str(ca), str(cb)])
	check(ca["sites"] > 0 or ca["zones"] > 0, "fixture: the city actually grew while the loads ran")
	# A third load, taken after the first two have consumed the global RNG stream, still matches:
	# the fix must not depend on the shared stream's position.
	var c := SK.load_into_new(get_root(), save)
	check(
		SK.state_hash(a) == SK.state_hash(c), "a third load, after the stream moved, still matches"
	)
	SK.free_world(a)
	SK.free_world(b)
	SK.free_world(c)
	await process_frame
	print("SIM_DETERMINISM_TEST: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	quit(0 if fails.is_empty() else 1)


## A city grown to a day boundary, saved exactly as Main._write_save does, then JSON round-tripped
## so the two loads below start from identical, independent bytes.
func _make_save() -> Dictionary:
	var w := SK.make_world(get_root(), SEED)
	var sim: CitySim = w["sim"]
	# Two whole days (D.GROWTH_TICKS_PER_DAY is 4), so the save lands on a day boundary.
	for _k in range(2 * D.GROWTH_TICKS_PER_DAY):
		sim.step_tick()
	check(
		sim.tick_in_day == 0,
		"fixture: the save lands on a day boundary (tick %d)" % sim.tick_in_day
	)
	var d := SK.document(w)
	SK.free_world(w)
	return JSON.parse_string(JSON.stringify(d)) as Dictionary


## The shape of the city, so a divergence names itself instead of only failing the hash.
func _counts(w: Dictionary) -> Dictionary:
	var sim: CitySim = w["sim"]
	var c := SK.counts(w)
	return {
		"day": sim.day,
		"tick": sim.tick_in_day,
		"sites": sim.sites.size(),
		"zones": c[0],
		"built": c[1],
		"residents": (w["people"] as Residents).people.size(),
	}
