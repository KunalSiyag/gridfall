extends SceneTree
## Save migration and load robustness (AGENTS.md: sim state must survive a save/load round trip).
## Covers what a save written before this round's from_dict hardening can look like: unknown extra
## fields, fields a newer build added but the old file lacks, a file with fewer than the five
## mayors, empty subsystem documents, and the bad versions the sim must reject. Also covers the
## aliasing case: loading one parsed Dictionary twice must give two independent, identical worlds,
## and byte-idempotency: a save and its reload are the same bytes, because no field the load
## recomputes (a mayor's derived pop/jobs/happiness) is ever written.
##
## Headless, offline. Prints SAVE_MIGRATION_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
const SEED := 7

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	print(("SAVE_MIGRATION_TEST:   ok   " if ok else "SAVE_MIGRATION_TEST:   FAIL ") + what)
	if not ok:
		fails.append(what)


func _init() -> void:
	await process_frame
	var save := _fixture()
	check(not save.is_empty(), "fixture: a grown city saves")

	_check_roundtrip(save)
	_check_extra_fields(save)
	_check_missing_optional(save)
	_check_few_mayors(save)
	_check_missing_mayor_fields(save)
	_check_old_mayor_fields(save)
	_check_empty_subsystems(save)
	_check_aliasing(save)
	_check_bad_versions(save)
	_check_bad_world(save)

	await process_frame
	print("SAVE_MIGRATION_TEST: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	quit(0 if fails.is_empty() else 1)


## A seed-7 city grown two days and a few ticks, as JSON so every load below starts from its own
## parsed bytes. Mid-day on purpose: a save at tick 0 starts its day when it loads (sim.start()),
## which is gameplay, not the save format.
func _fixture() -> Dictionary:
	var w := SK.make_world(get_root(), SEED)
	var sim: CitySim = w["sim"]
	for _t in range(2 * D.GROWTH_TICKS_PER_DAY + 7):
		sim.step_tick()
	var d := SK.document(w)
	SK.free_world(w)
	return JSON.parse_string(JSON.stringify(d)) as Dictionary


## A mutable deep copy of the fixture, so a variant's mutation cannot leak into the next check.
func _copy(save: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(save)) as Dictionary


func _check_roundtrip(save: Dictionary) -> void:
	var a := SK.load_into_new(get_root(), save)
	check(bool(a.get("ok", true)), "a current-format save loads")
	var b := SK.load_into_new(get_root(), save)
	check(SK.state_hash(a) == SK.state_hash(b), "two loads of one save agree")
	# Byte-idempotency: no field the load recomputes is written, so save -> load -> save
	# writes the same bytes. The parsed-copy hop mirrors a save going through disk.
	var again := JSON.parse_string(JSON.stringify(SK.document(a))) as Dictionary
	check(JSON.stringify(again) == JSON.stringify(save), "a save and its reload are byte-identical")
	var c := SK.load_into_new(get_root(), again)
	var third := JSON.parse_string(JSON.stringify(SK.document(c))) as Dictionary
	check(JSON.stringify(third) == JSON.stringify(again), "the second round-trip is stable too")
	var stray: Array = []
	for m: Variant in (again["sim"] as Dictionary)["mayors"] as Array:
		for derived: String in ["pop", "jobs", "happiness"]:
			if (m as Dictionary).has(derived):
				stray.append(derived)
	check(stray.is_empty(), "a saved mayor carries no derived pop/jobs/happiness (%s)" % str(stray))
	check(SK.ticks_ok(a, 1), "a loaded city ticks a day")
	SK.free_world(a)
	SK.free_world(b)
	SK.free_world(c)


## Unknown fields (a file written by a newer build) are ignored, not an error.
func _check_extra_fields(save: Dictionary) -> void:
	var d := _copy(save)
	d["future_top"] = {"nested": [1, 2, 3]}
	(d["sim"] as Dictionary)["future_sim"] = "ignore me"
	(d["sim"] as Dictionary)["mayors"][0]["future_mayor"] = 1
	(d["residents"] as Dictionary)["future_people"] = true
	var w := SK.load_into_new(get_root(), d)
	check(bool(w.get("ok", true)), "a save with unknown extra fields still loads")
	check(SK.ticks_ok(w, 1), "and ticks")
	SK.free_world(w)


## Every field this round's build reads but an older file may lack, removed at once.
func _check_missing_optional(save: Dictionary) -> void:
	var d := _copy(save)
	var s: Dictionary = d["sim"]
	for key: String in [
		"event_seq",
		"site_seq",
		"crew_seq",
		"crew_jobs",
		"grid_priority",
		"disabled_until",
		"broken_roads",
		"history",
		"log",
		"ordinances",
		"events",
		"sites"
	]:
		s.erase(key)
	var w := SK.load_into_new(get_root(), d)
	check(bool(w.get("ok", true)), "a save missing every optional sim field loads")
	var sim: CitySim = w["sim"]
	var stale: Array = []
	for i: int in sim.sites.keys():
		if not bool(sim.call("_site_valid", sim.sites[i])):
			stale.append(i)
	check(
		stale.is_empty(),
		"no stale or malformed site survives the dropped sites list (%s)" % str(stale)
	)
	check(sim._site_seq >= sim.sites.size(), "the site counter is not behind the open sites")
	check(SK.ticks_ok(w, 1), "and ticks")
	SK.free_world(w)


## A file from a build with fewer mayors: every district and owner lookup needs all five.
func _check_few_mayors(save: Dictionary) -> void:
	var d := _copy(save)
	var ms: Array = (d["sim"] as Dictionary)["mayors"]
	(d["sim"] as Dictionary)["mayors"] = ms.slice(0, 2)
	var w := SK.load_into_new(get_root(), d)
	check(bool(w.get("ok", true)), "a save with two mayors loads")
	var sim: CitySim = w["sim"]
	check(
		sim.mayors.size() == D.MAYORS.size(),
		"the missing mayors are padded back to five (%d)" % sim.mayors.size()
	)
	var names: Array = sim.mayors.map(func(m: Dictionary) -> String: return str(m["name"]))
	var want: Array = D.MAYORS.map(func(m: Dictionary) -> String: return str(m["display"]))
	check(names == want, "each district has its own mayor (%s)" % str(names))
	check(SK.ticks_ok(w, 2), "and ticks two days with every district addressable")
	SK.free_world(w)


## A mayor that did load but is missing a field added since gets it back.
func _check_missing_mayor_fields(save: Dictionary) -> void:
	var d := _copy(save)
	for m: Variant in (d["sim"] as Dictionary)["mayors"] as Array:
		(m as Dictionary).erase("annexed")
		(m as Dictionary).erase("tax_i")
	var w := SK.load_into_new(get_root(), d)
	var sim: CitySim = w["sim"]
	check(
		(
			bool(w.get("ok", true))
			and sim.mayors.size() == D.MAYORS.size()
			and sim.mayors[0].has("annexed")
			and sim.mayors[0].has("tax_i")
		),
		"a mayor missing a newer field gets the founding default back"
	)
	check(SK.ticks_ok(w, 1), "and ticks")
	SK.free_world(w)


## A save from a build that still wrote a mayor's derived pop/jobs/happiness: the fields load
## (they are tolerated, not required) but the load recomputes them from the tiles, and the
## re-save drops them again.
func _check_old_mayor_fields(save: Dictionary) -> void:
	var d := _copy(save)
	var ms: Array = (d["sim"] as Dictionary)["mayors"]
	for i: int in range(ms.size()):
		(ms[i] as Dictionary)["pop"] = 12345
		(ms[i] as Dictionary)["jobs"] = 999
		(ms[i] as Dictionary)["happiness"] = 0.99
	var w := SK.load_into_new(get_root(), d)
	check(bool(w.get("ok", true)), "a save with the mayors' derived fields (an older build) loads")
	var sim: CitySim = w["sim"]
	var m0_live: Dictionary = sim.mayors[0]
	check(
		(
			int(m0_live["pop"]) != 12345
			and int(m0_live["jobs"]) != 999
			and absf(float(m0_live["happiness"]) - 0.99) > 0.001
		),
		"the load recomputes the derived fields instead of trusting the file"
	)
	var resave := JSON.parse_string(JSON.stringify(SK.document(w))) as Dictionary
	var m0: Dictionary = ((resave["sim"] as Dictionary)["mayors"] as Array)[0]
	check(
		not m0.has("pop") and not m0.has("jobs") and not m0.has("happiness"),
		"the re-save drops the derived fields again"
	)
	SK.free_world(w)


## Subsystem documents an older build may not have written at all.
func _check_empty_subsystems(save: Dictionary) -> void:
	for key: String in ["brain", "minds", "client", "residents"]:
		var d := _copy(save)
		d.erase(key)
		var w := SK.load_into_new(get_root(), d)
		check(bool(w.get("ok", true)), "a save with no %s document loads" % key)
		SK.free_world(w)


## Loading one parsed Dictionary twice must not let the two loads share state.
func _check_aliasing(save: Dictionary) -> void:
	var d := _copy(save)
	var before := JSON.stringify(d)
	var a := SK.load_into_new(get_root(), d)
	var b := SK.load_into_new(get_root(), d)
	check(bool(a.get("ok", true)) and bool(b.get("ok", true)), "the aliasing fixture loads twice")
	check(JSON.stringify(d) == before, "loading does not mutate the parsed save dictionary")
	check(
		SK.state_hash(a) == SK.state_hash(b),
		"the same dictionary loaded twice gives the same world"
	)
	# Spend in the first world; the second must not move.
	var sa: CitySim = a["sim"]
	var sb: CitySim = b["sim"]
	var acts := [
		{"type": "build", "building": "coal_plant", "x": 9, "y": 9},
		{"type": "zone", "zone": "R", "x": 2, "y": 6, "w": 4, "h": 3},
	]
	for act: Dictionary in acts:
		sa.apply_action(0, act)
	check(
		sa.mayors[0]["treasury"] != sb.mayors[0]["treasury"],
		(
			"spending in one load does not change the other (%d vs %d)"
			% [int(sa.mayors[0]["treasury"]), int(sb.mayors[0]["treasury"])]
		)
	)
	SK.free_world(a)
	SK.free_world(b)


func _check_bad_versions(save: Dictionary) -> void:
	for v: int in [1, 0, -1, 4]:
		var d := _copy(save)
		(d["sim"] as Dictionary)["version"] = v
		var w := SK.load_into_new(get_root(), d)
		check(not bool(w.get("ok", true)), "version %d is rejected, not half-applied" % v)
		SK.free_world(w)
	var no_v := _copy(save)
	(no_v["sim"] as Dictionary).erase("version")
	var w2 := SK.load_into_new(get_root(), no_v)
	check(not bool(w2.get("ok", true)), "a save with no version is rejected")
	SK.free_world(w2)


func _check_bad_world(save: Dictionary) -> void:
	var no_world := _copy(save)
	(no_world["sim"] as Dictionary).erase("world")
	var w := SK.load_into_new(get_root(), no_world)
	check(not bool(w.get("ok", true)), "a 192x192 save with no world block is rejected")
	SK.free_world(w)
	var short := _copy(save)
	var s: Dictionary = short["sim"]
	s["kind"] = (s["kind"] as Array).slice(0, 100)
	var w2 := SK.load_into_new(get_root(), short)
	check(not bool(w2.get("ok", true)), "a save with a short tile array is rejected")
	SK.free_world(w2)
