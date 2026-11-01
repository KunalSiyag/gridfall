extends SceneTree
## A load the sim rejects leaves the live city exactly as it was. CitySim.from_dict used to call
## new_city(save seed) first and check the save afterwards, so a truncated save that still carried
## an accepted version, or one with a section of the wrong kind (mayors as a string, an event with
## no type, a number that is null), replaced the live city with a fresh or half-loaded one while
## Main.load_game reported "Save file is invalid" (and first person kept drawing the old city).
## Every rejection path is walked here: the live sim's whole state, the RNG stream, the signals it
## emits and the days it goes on to play must match a twin that never saw the bad save, and the
## saves it does accept still load to the same bytes, without one script error.
## Headless, offline. Prints SIM_LOAD_ATOMIC_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
const SAVE_SHAPE := preload("res://scripts/sim/save_shape.gd")
const SEED := 7
const TOKEN := "SIM_LOAD_ATOMIC_TEST"
const FIXTURE_V2 := "res://tools/tests/fixtures/save_v2_seed7.json"
const FIXTURE_V3 := "res://tools/tests/fixtures/save_v3_seed7.json"

## A value of the wrong kind for each kind of section (SaveShape names the kinds).
const WRONG := {
	"number": [null, "x", [], {}],
	"dict": [null, "x", 5, []],
	"array": [null, "x", 5, {}],
	"numbers": [null, "x", 5, [], {"3": null}, {"3": "x"}, {"3": []}],
	"records": [null, "x", 5, {}, [null], [5], ["x"], [[]], [[1]]],
}
## The sections of the sim's save by kind, as CitySim.from_dict reads them.
const SECTIONS := {
	"number": ["version", "seed", "day", "tick_in_day", "event_seq", "site_seq", "crew_seq"],
	"dict": ["ordinances"],
	"array": ["grid_priority", "log"],
	"numbers": ["disabled_until", "broken_roads"],
	"records": ["mayors", "events", "history", "sites", "crew_jobs"],
}
## The fields of the first record of a section that the load converts or calculates with.
const RECORD_NUMBERS := {
	"mayors":
	[
		"treasury",
		"tax_r",
		"tax_c",
		"tax_i",
		"last_income",
		"last_upkeep",
		"actions_ok",
		"actions_rejected",
		"annexed",
		"pop",
		"jobs",
		"happiness",
	],
	"events": ["id", "x", "y", "radius", "start_day", "until_day", "progress", "work"],
	"sites":
	[
		"id",
		"i",
		"x",
		"y",
		"owner",
		"from_kind",
		"from_level",
		"target_kind",
		"target_level",
		"stage",
		"start_tick",
		"progress",
		"stage_work",
		"rate",
		"tick_work",
		"job",
	],
	"crew_jobs": ["id", "owner", "x", "y", "crew", "work", "total", "done"],
}

var fails: Array[String] = []
var _signals := 0
var _errors := ErrLog.new()


## Counts the script errors the engine raises. A cast that fails inside from_dict is one: a save
## the load takes must not raise any, and a save it refuses must be refused by a check, not by a
## runtime error half way through the load.
class ErrLog:
	extends Logger
	var n := 0
	var first := ""

	func _log_error(
		_function: String,
		file: String,
		line: int,
		_code: String,
		rationale: String,
		_editor_notify: bool,
		_error_type: int,
		_backtraces: Array
	) -> void:
		n += 1
		if first.is_empty():
			first = "%s:%d %s" % [file.get_file(), line, rationale.left(80)]

	func _log_message(_message: String, _error: bool) -> void:
		pass


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN)
	OS.add_logger(_errors)
	await process_frame
	var live := _grown_world()
	var twin := _grown_world()
	var sim: CitySim = live["sim"]
	var save := _doc(sim)
	check(
		_fingerprint(sim) == _fingerprint(twin["sim"] as CitySim),
		"fixture: the live city and its twin start identical"
	)
	_watch(sim)
	_check_rejections(live, save)
	var rich := _rich_save()
	_check_shape_rejections(live, rich)
	# The rejected loads must not have disturbed the days to come either: the RNG stream, the
	# queued work and the clocks still match a city that never saw them.
	var a: CitySim = live["sim"]
	var b: CitySim = twin["sim"]
	K.ticks(a, 2 * D.GROWTH_TICKS_PER_DAY)
	K.ticks(b, 2 * D.GROWTH_TICKS_PER_DAY)
	check(
		SK.state_hash(live) == SK.state_hash(twin),
		"after the rejected loads the city plays the next two days exactly as its twin"
	)
	_check_brain_client()
	_check_job_survives()
	_check_accepts(save)
	_check_real_saves(rich)
	_check_leaving_out(rich)
	_check_old_layouts()
	check(_errors.n == 0, "no script error in the whole run (%d: %s)" % [_errors.n, _errors.first])
	OS.remove_logger(_errors)
	SK.free_world(live)
	SK.free_world(twin)
	await process_frame
	K.finish(self, TOKEN, fails)


## A seed-7 city grown by the scripted recipe, mid-day on purpose (a boundary save starts its day
## again when it loads).
func _grown_world() -> Dictionary:
	var w := SK.make_world(get_root(), SEED)
	K.grow(w["sim"], w["people"], 30)
	K.ticks(w["sim"], 3)
	return w


func _doc(sim: CitySim) -> Dictionary:
	return JSON.parse_string(JSON.stringify(sim.to_dict())) as Dictionary


func _copy(save: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify(save)) as Dictionary


## Everything from_dict and new_city write: the save document (all arrays, mayors, events, sites),
## the derived maps and counters a load recomputes, the RNG, and the clocks.
func _fingerprint(sim: CitySim) -> Dictionary:
	return {
		"doc": JSON.stringify(sim.to_dict()).hash(),
		"seed": sim.city_seed,
		"rng": sim.rng.state,
		"road_epoch": sim.road_epoch,
		"active": sim.active.size(),
		"stats": JSON.stringify(sim.stats).hash(),
		"powered": hash(sim.powered),
		"watered": hash(sim.watered),
		"pollution": hash(sim.pollution),
		"land_value": hash(sim.land_value),
		"road_dist": hash(sim.road_dist),
		"traffic": hash(sim.traffic),
		"remap": sim.load_remap.size(),
		"job": sim.job_pending(),
		"accum": sim._time_accum,
	}


## Counts what a half-applied load would announce to the view and the HUD.
func _watch(sim: CitySim) -> void:
	_signals = 0
	var bump := func(_a: Variant = null) -> void: _signals += 1
	sim.tiles_changed.connect(bump)
	sim.stats_updated.connect(bump)
	sim.city_log.connect(func(_l: String, _c: String) -> void: _signals += 1)
	sim.day_started.connect(bump)
	sim.territory_changed.connect(bump)


func _check_rejections(w: Dictionary, save: Dictionary) -> void:
	var sim: CitySim = w["sim"]
	var cases := {}
	for v: Variant in [0, 1, 4, -1]:
		var d := _copy(save)
		d["version"] = v
		cases["version %s" % str(v)] = d
	var no_version := _copy(save)
	no_version.erase("version")
	cases["no version"] = no_version
	for key: String in ["kind", "district"]:
		var short := _copy(save)
		short[key] = (short[key] as Array).slice(0, 100)
		cases["%s truncated" % key] = short
		var long := _copy(save)
		(long[key] as Array).append(0)
		cases["%s one too long" % key] = long
		var missing := _copy(save)
		missing.erase(key)
		cases["%s missing" % key] = missing
		var wrong_type := _copy(save)
		wrong_type[key] = "not an array"
		cases["%s not an array" % key] = wrong_type
		var nothing := _copy(save)
		nothing[key] = null
		cases["%s null" % key] = nothing
	# The same-size world also needs level, terrain and burning at full length: a short one is a
	# truncated file, and the load used to take it and trip over the missing tiles later.
	for key: String in ["level", "terrain", "burning"]:
		var short := _copy(save)
		short[key] = (short[key] as Array).slice(0, 100)
		cases["%s truncated" % key] = short
		var missing := _copy(save)
		missing.erase(key)
		cases["%s missing" % key] = missing
		var wrong_type := _copy(save)
		wrong_type[key] = {"0": 1}
		cases["%s not an array" % key] = wrong_type
	var no_world := _copy(save)
	no_world.erase("world")
	cases["192x192 arrays with no world block"] = no_world
	var odd_world := _copy(save)
	(odd_world["world"] as Dictionary)["w"] = 100
	cases["world block disagrees with the arrays"] = odd_world
	var empty_world := _copy(save)
	empty_world["world"] = {"w": 0, "h": 0, "x0": 0, "y0": 0}
	empty_world["kind"] = []
	empty_world["district"] = []
	cases["empty world"] = empty_world
	var bad_world := _copy(save)
	bad_world["world"] = "192"
	cases["world block is not a dictionary"] = bad_world
	var before := _fingerprint(sim)
	for name: String in cases.keys():
		var sig_before := _signals
		var ok: bool = sim.from_dict(cases[name])
		check(not ok, "%s: rejected" % name)
		check(
			_fingerprint(sim) == before and _signals == sig_before,
			"%s: the live city is untouched, nothing was announced" % name
		)


## Many refusals at once, one verdict: every case in cases is rejected, the live city is untouched
## and nothing was announced, and the engine raised no error on the way (the check refused it).
func _reject_all(sim: CitySim, cases: Dictionary, what: String) -> void:
	var before := _fingerprint(sim)
	var bad: Array[String] = []
	for name: String in cases.keys():
		var sig_before := _signals
		var errors_before := _errors.n
		var ok: bool = sim.from_dict(cases[name])
		if (
			ok
			or _fingerprint(sim) != before
			or _signals != sig_before
			or _errors.n != errors_before
		):
			bad.append(name)
	check(
		bad.is_empty(),
		(
			"%s: all %d refused, nothing changed or announced, no error%s"
			% [what, cases.size(), "" if bad.is_empty() else " (not: %s)" % str(bad.slice(0, 6))]
		)
	)


## A save with one incident, one crew order and its sites: every record section of a save has a
## record to corrupt. A different city from the live one, so a replacement would show.
func _rich_save() -> Dictionary:
	var w := SK.make_world(get_root(), 11)
	var sim: CitySim = w["sim"]
	var people: Residents = w["people"]
	K.grow(sim, people, 30)
	K.ticks(sim, 3)
	var home := int((people.people[0] as Dictionary)["home"])
	sim.trigger_disaster("fire", D.tx(home), D.ty(home), "test", "fixture")
	var lot: Array = sim.open_lots(0, 10)[0]
	var order := {"type": "build", "building": "park", "x": int(lot[0]), "y": int(lot[1])}
	(sim.mayors[0] as Dictionary)["treasury"] = 100000
	sim.apply_player_order(0, order)
	var save := _doc(sim)
	SK.free_world(w)
	for key: String in ["mayors", "events", "history", "sites", "crew_jobs"]:
		check(not (save[key] as Array).is_empty(), "fixture: the rich save has %s" % key)
	return save


## Every section the load reads, of the wrong kind, and every field it calculates with, of the
## wrong kind: refused whole, before the live city is touched. (A section of the right kind that
## says something odd is not refused: the checks are about shape, not meaning.)
func _check_shape_rejections(w: Dictionary, save: Dictionary) -> void:
	var sim: CitySim = w["sim"]
	var cases := {}
	for kind: String in SECTIONS.keys():
		for key: String in SECTIONS[kind]:
			for wrong: Variant in WRONG[kind]:
				var d := _copy(save)
				d[key] = wrong
				cases["%s = %s" % [key, JSON.stringify(wrong)]] = d
	_reject_all(sim, cases, "sections of the wrong kind")
	cases = {}
	for key: String in RECORD_NUMBERS.keys():
		for field: String in RECORD_NUMBERS[key]:
			for wrong: Variant in WRONG["number"]:
				var d := _copy(save)
				var rec: Dictionary = (d[key] as Array)[0]
				if rec.has(field):
					rec[field] = wrong
					cases["%s[0].%s = %s" % [key, field, JSON.stringify(wrong)]] = d
	check(cases.size() > 100, "fixture: %d record fields are corrupted one by one" % cases.size())
	_reject_all(sim, cases, "record fields of the wrong kind")
	cases = {}
	for field: String in ["type", "x", "y"]:
		var d := _copy(save)
		((d["events"] as Array)[0] as Dictionary).erase(field)
		cases["events[0] without %s" % field] = d
	for wrong: Variant in [null, "x", {}, [null], ["x"], [[1]]]:
		var d := _copy(save)
		((d["events"] as Array)[0] as Dictionary)["tiles"] = wrong
		cases["events[0].tiles = %s" % JSON.stringify(wrong)] = d
	for field: String in ["w", "h", "x0", "y0"]:
		for wrong: Variant in WRONG["number"]:
			var d := _copy(save)
			(d["world"] as Dictionary)[field] = wrong
			cases["world.%s = %s" % [field, JSON.stringify(wrong)]] = d
	_reject_all(
		sim, cases, "events without their keys, tiles that are not numbers, a world of text"
	)


## The brain's section keeps a copy of the client's state and loads it with the client's own
## from_dict, which casts its two dictionaries. A copy with either of them the wrong kind is
## refused whole, like the client's own section: it used to pass the shape check, load with a
## script error and leave the client half restored. A copy that leaves them out is fine.
func _check_brain_client() -> void:
	var w := _grown_world()
	var doc := _copy(SK.document(w))
	var client := (doc["brain"] as Dictionary)["client"] as Dictionary
	check(
		client.has("session_cache") and client.has("stats"),
		"brain.client: fixture: a real save holds both of the client's dictionaries"
	)
	var before := SK.state_hash(w)
	var taken: Array[String] = []
	for key: String in ["session_cache", "stats"]:
		for wrong: Variant in WRONG["dict"]:
			var d := _copy(doc)
			((d["brain"] as Dictionary)["client"] as Dictionary)[key] = wrong
			if SAVE_SHAPE.document_ok(d) or SK.apply(w, d):
				taken.append("%s = %s" % [key, JSON.stringify(wrong)])
	for wrong: Variant in WRONG["dict"]:
		var d := _copy(doc)
		(d["brain"] as Dictionary)["client"] = wrong
		if SAVE_SHAPE.document_ok(d) or SK.apply(w, d):
			taken.append("client = %s" % JSON.stringify(wrong))
	check(taken.is_empty(), "brain.client: every wrong kind is refused (taken: %s)" % str(taken))
	check(SK.state_hash(w) == before, "brain.client: the refused saves changed nothing")
	var left_out := _copy(doc)
	((left_out["brain"] as Dictionary)["client"] as Dictionary).erase("stats")
	check(SAVE_SHAPE.document_ok(left_out), "brain.client: a copy without its stats is fine")
	left_out = _copy(doc)
	(left_out["brain"] as Dictionary)["client"] = {}
	check(SAVE_SHAPE.document_ok(left_out), "brain.client: an empty copy is fine")
	left_out = _copy(doc)
	(left_out["brain"] as Dictionary).erase("client")
	check(SAVE_SHAPE.document_ok(left_out), "brain.client: a brain without the copy is fine")
	check(SAVE_SHAPE.document_ok(doc), "brain.client: and the real save still has the shape")
	SK.free_world(w)


## A sliced job in flight (a tick the frame budget has not finished) belongs to the live city: a
## rejected load must not drop it, and the tick goes on to finish and commit.
func _check_job_survives() -> void:
	var w := _grown_world()
	var sim: CitySim = w["sim"]
	var bad := _doc(sim)
	bad["kind"] = (bad["kind"] as Array).slice(0, 100)
	var day_before := sim.day * D.GROWTH_TICKS_PER_DAY + sim.tick_in_day
	sim.sliced = true
	sim.day_gate = Callable()
	sim.slice_budget_ms = 0.01
	sim.tick_budget_ms = 0.01
	sim.set_day_seconds(D.BASE_DAY_SECONDS)
	sim.set_speed(1)
	sim._process(120.0)
	check(
		sim.job_pending() and sim.is_tick_running(),
		"job: fixture: a tick is in flight under a tiny frame budget"
	)
	check(not sim.from_dict(bad), "job: a truncated save is rejected")
	check(
		sim.job_pending() and sim.is_tick_running(),
		"job: the rejected load leaves the tick in flight"
	)
	var frames := 0
	while sim.job_pending() and frames < 400:
		sim._process(0.0)
		frames += 1
	var day_after := sim.day * D.GROWTH_TICKS_PER_DAY + sim.tick_in_day
	check(
		not sim.job_pending() and day_after > day_before,
		"job: the tick finishes and commits (%d -> %d)" % [day_before, day_after]
	)
	sim.set_speed(0)
	sim.sliced = false
	SK.free_world(w)


## Accepted saves keep loading, and a load into a used city reaches the bytes of a fresh load.
func _check_accepts(save: Dictionary) -> void:
	var fresh := SK.make_world(get_root(), SEED)
	var used := _grown_world()
	check((used["sim"] as CitySim).from_dict(_copy(save)), "a live save loads into a used city")
	check((fresh["sim"] as CitySim).from_dict(_copy(save)), "...and into a fresh one")
	check(
		(
			JSON.stringify((used["sim"] as CitySim).to_dict())
			== JSON.stringify((fresh["sim"] as CitySim).to_dict())
		),
		"both loads write the same bytes back"
	)
	check(
		JSON.stringify(_doc(used["sim"] as CitySim)) == JSON.stringify(save),
		"...and, through JSON, they are the bytes that were saved"
	)
	SK.free_world(fresh)
	SK.free_world(used)
	for path: String in [FIXTURE_V2, FIXTURE_V3]:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		var w := SK.make_world(get_root(), SEED)
		var ok := (
			typeof(parsed) == TYPE_DICTIONARY
			and (w["sim"] as CitySim).from_dict(parsed as Dictionary)
		)
		check(ok, "%s still loads" % path.get_file())
		SK.free_world(w)


## What a real city writes is never refused: a false refusal would lock a player out of their own
## city. A grown city's whole save (the sim, brain, client, residents and minds as Main writes
## them, after days of play) has the shape every loader reads and loads; so does the rich save,
## with its incident, its crew order and their sites.
func _check_real_saves(rich: Dictionary) -> void:
	var w := _grown_world()
	K.ticks(w["sim"], 2 * D.GROWTH_TICKS_PER_DAY)
	var doc := JSON.parse_string(JSON.stringify(SK.document(w))) as Dictionary
	check(
		(
			(w["people"] as Residents).people.size() >= 5
			and not (doc["residents"] as Dictionary).is_empty()
		),
		"real saves: fixture: the grown city has residents to save"
	)
	check(SAVE_SHAPE.document_ok(doc), "real saves: a grown city's whole save has the shape")
	var fresh := SK.make_world(get_root(), SEED)
	check(SK.apply(fresh, doc), "real saves: and it loads into a new world")
	SK.free_world(fresh)
	SK.free_world(w)
	var other := SK.make_world(get_root(), 5)
	var ok: bool = (other["sim"] as CitySim).from_dict(_copy(rich))
	check(ok, "real saves: the rich save (incident, crew order, sites) loads whole")
	check(
		ok and JSON.stringify(_doc(other["sim"] as CitySim)) == JSON.stringify(rich),
		"real saves: and writes the bytes that were saved"
	)
	SK.free_world(other)


## Every section a save may leave out loads without it (the loader has a default): the shape
## checks refuse a wrong kind, never an absence.
func _check_leaving_out(save: Dictionary) -> void:
	var left_out := 0
	var refused: Array[String] = []
	for kind: String in SECTIONS.keys():
		for key: String in SECTIONS[kind]:
			if key == "version":
				continue
			var d := _copy(save)
			d.erase(key)
			var w := SK.make_world(get_root(), SEED)
			if (w["sim"] as CitySim).from_dict(d):
				left_out += 1
			else:
				refused.append(key)
			SK.free_world(w)
	check(
		refused.is_empty(),
		"a save without %d of its sections still loads (refused: %s)" % [left_out, str(refused)]
	)


## A version 2 save (the 96x96 world) may leave level, terrain and burning short or out: the
## placement fills the rest. Only this build's own world needs them at full length.
func _check_old_layouts() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_V2))
	var refused: Array[String] = []
	for key: String in ["level", "terrain", "burning"]:
		for how: String in ["missing", "short"]:
			var d := _copy(parsed as Dictionary)
			if how == "missing":
				d.erase(key)
			else:
				d[key] = (d[key] as Array).slice(0, 50)
			var w := SK.make_world(get_root(), SEED)
			if not (w["sim"] as CitySim).from_dict(d):
				refused.append("%s %s" % [key, how])
			SK.free_world(w)
	check(
		refused.is_empty(),
		"a version 2 save with a short or missing tile array loads (%s)" % str(refused)
	)
