extends SceneTree
## A GMI answer that is still in flight when New City or Load replaces the city belongs to a city
## that no longer exists. CityBrain used to keep its in-flight flags across CityBrain.setup() and
## from_dict(), so the old city's mayor and support answers landed in the new one (a mayor's
## actions built on the wrong map, the Gazette and the Grid Operator speaking for the old day) and
## the new city's own day-1 plans were skipped while the flags stayed true. The brain now counts
## city generations: a request remembers the one it was sent under, an answer that finds it changed
## is dropped, and a heuristic fallback that runs late neither reads nor draws RNG from the new
## city. ResidentMinds does the same for its plan batches and reactions: it used to let a batch
## from the old city settle its own counters after setup() had zeroed them, so the count went
## negative, the brain's day gate (which waits for the count to reach zero) stayed shut for
## MAX_WAIT_MS, and plans_done never fired for the new city. The calls here are held by hand
## (support/gated_client.gd), so the order is exact and no timer is involved.
## Headless, offline. Prints BRAIN_STALE_ANSWER_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
const GATED := preload("res://tools/tests/support/gated_client.gd")
const TOKEN := "BRAIN_STALE_ANSWER_TEST"
const SEED := 7
const NEW_SEED := 777
const SUPPORT := {
	"citizens": "_run_citizens",
	"news": "_run_news",
	"chaos": "_run_chaos",
	"operator": "_run_operator",
	"council": "_run_council",
}

var fails: Array[String] = []


## What a test watches on one brain: every signal an answer ends in, and the last busy count.
class Tap:
	extends RefCounted
	var decided: Array = []
	var published := 0
	var spoke := 0
	var ruled := 0
	var chaos := 0
	var operator := 0
	var answered: Array = []
	var busy := -1

	func _init(brain: CityBrain) -> void:
		brain.mayor_decided.connect(
			func(mi: int, e: Dictionary) -> void: decided.append([mi, int(e["day"])])
		)
		brain.news_published.connect(func(_p: Dictionary) -> void: published += 1)
		brain.citizens_spoke.connect(func(_v: Array) -> void: spoke += 1)
		brain.council_ruled.connect(func(_r: Dictionary) -> void: ruled += 1)
		brain.chaos_decided.connect(func(_c: Dictionary) -> void: chaos += 1)
		brain.operator_decided.connect(func(_o: Dictionary) -> void: operator += 1)
		brain.inspector_answered.connect(
			func(r: Dictionary) -> void: answered.append(bool(r.get("pending", false)))
		)
		brain.busy_changed.connect(func(n: int) -> void: busy = n)

	## Signals that carry an answer to the player (everything but the mayors' own).
	func support_total() -> int:
		return published + spoke + ruled + chaos + operator


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN)
	await process_frame
	await _check_mayors_new_city()
	await _check_support_new_city()
	await _check_mayors_load()
	await _check_current_answer_lands()
	await _check_late_heuristic()
	await _check_inspector()
	await _check_overlapping_calls()
	await _check_minds_new_city()
	await _check_minds_load()
	K.finish(self, TOKEN, fails)


## A grown seed-7 city, its brain on a GatedClient (calls pass straight through until hold is set).
func _world() -> Dictionary:
	var w := SK.make_world(get_root(), SEED)
	var gated := GATED.new()
	gated.name = "GatedClient"
	get_root().add_child(gated)
	gated.live_enabled = false
	var brain: CityBrain = w["brain"]
	brain.setup(w["sim"], gated)
	(w["minds"] as ResidentMinds).setup(w["sim"], w["people"], gated, brain)
	K.grow(w["sim"], w["people"], 30)
	w["gated"] = gated
	w["tap"] = Tap.new(brain)
	return w


func _free(w: Dictionary) -> void:
	(w["gated"] as Node).queue_free()
	SK.free_world(w)


func _city(sim: CitySim) -> int:
	return JSON.stringify(sim.to_dict()).hash()


func _logs(brain: CityBrain) -> Array:
	var out: Array = []
	for ms: Dictionary in brain.mayor_state:
		out.append([(ms["log"] as Array).size(), int(ms["day"]), str(ms["post"])])
	return out


## New City while all five mayors are mid-call: the flags clear at once, the new city plans on its
## own first day, and the old answers, landing later, change nothing.
func _check_mayors_new_city() -> void:
	var w := _world()
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var gated: GATED = w["gated"]
	var tap: Tap = w["tap"]
	var old_day := sim.day
	check(old_day >= 2, "mayors: fixture: the old city is past its first day (day %d)" % old_day)
	gated.hold = true
	for mi in range(D.MAYORS.size()):
		brain._run_mayor(mi, old_day)
	check(brain.mayors_pending() == D.MAYORS.size(), "mayors: five calls are in flight")
	var gen := brain._generation
	sim.new_city(NEW_SEED)
	brain.setup(sim, gated)
	check(brain._generation != gen, "mayors: New City starts a new generation")
	check(
		brain.mayors_pending() == 0 and brain.pending_calls() == 0 and tap.busy == 0,
		"mayors: New City clears the in-flight flags (and tells the HUD, busy=%d)" % tap.busy
	)
	var decided_before := tap.decided.size()
	gated.hold = false
	sim.start()
	var fresh: Array = tap.decided.slice(decided_before)
	check(
		fresh.size() == D.MAYORS.size() and fresh.all(func(e: Array) -> bool: return e[1] == 1),
		"mayors: the new city's own day-1 plans all run (%s)" % str(fresh)
	)
	var city := _city(sim)
	var logs := _logs(brain)
	gated.gate.emit()
	check(
		tap.decided.size() == decided_before + D.MAYORS.size(),
		"mayors: no old decision is announced"
	)
	check(_city(sim) == city, "mayors: the old answers do not touch the new city")
	check(_logs(brain) == logs, "mayors: the new mayors' thoughts and logs are theirs alone")
	check(brain.mayors_pending() == 0, "mayors: and no flag is left set")
	_free(w)


## Every support role in flight at New City: nothing it was asked about survives the new city.
func _check_support_new_city() -> void:
	var w := _world()
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var gated: GATED = w["gated"]
	var tap: Tap = w["tap"]
	gated.hold = true
	for role: String in SUPPORT.keys():
		brain._run_support(role, sim.day, Callable(brain, SUPPORT[role]))
	check(
		brain._support_in_flight.size() == SUPPORT.size(),
		"support: %d roles are in flight" % SUPPORT.size()
	)
	sim.new_city(NEW_SEED)
	brain.setup(sim, gated)
	check(
		brain._support_in_flight.is_empty() and brain.pending_calls() == 0,
		"support: New City clears the support flags"
	)
	var city := _city(sim)
	var priority := sim.grid_priority.duplicate()
	var rng_state := sim.rng.state
	var before := tap.support_total()
	gated.hold = false
	gated.gate.emit()
	check(tap.support_total() == before, "support: no old answer is announced")
	check(
		(
			brain.last_paper.is_empty()
			and brain.last_voices.is_empty()
			and brain.last_council.is_empty()
			and brain.last_chaos.is_empty()
			and brain.last_operator.is_empty()
		),
		"support: the Gazette, voices, council, chaos and operator records stay empty"
	)
	check(
		_city(sim) == city and sim.grid_priority == priority and sim.rng.state == rng_state,
		"support: the new city, its grid priority and its RNG are untouched"
	)
	check(
		brain._support_in_flight.is_empty() and brain.pending_calls() == 0 and tap.busy == 0,
		"support: no flag is left set (busy=%d)" % tap.busy
	)
	# The new city's own round then runs every role it is due for: the flags do not block it.
	var now_news := tap.published
	brain._run_support("news", 2, Callable(brain, "_run_news"))
	check(tap.published == now_news + 1, "support: the new city's own Gazette still prints")
	_free(w)


## Load (CityBrain.from_dict) is the same event: calls in flight are the old city's.
func _check_mayors_load() -> void:
	var w := _world()
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var gated: GATED = w["gated"]
	var tap: Tap = w["tap"]
	var saved := JSON.parse_string(JSON.stringify(brain.to_dict())) as Dictionary
	var sim_saved := JSON.parse_string(JSON.stringify(sim.to_dict())) as Dictionary
	gated.hold = true
	brain._run_mayor(1, sim.day)
	brain._run_mayor(3, sim.day)
	brain._run_support("news", sim.day, Callable(brain, "_run_news"))
	check(brain.pending_calls() == 3, "load: two mayors and the Gazette are in flight")
	var gen := brain._generation
	check(sim.from_dict(sim_saved), "load: fixture: the sim takes the save")
	brain.from_dict(saved)
	check(brain._generation != gen, "load: from_dict starts a new generation")
	check(brain.pending_calls() == 0 and tap.busy == 0, "load: the flags are clear after the load")
	var city := _city(sim)
	var brain_doc := JSON.stringify(brain.to_dict())
	var decided := tap.decided.size()
	var published := tap.published
	gated.hold = false
	gated.gate.emit()
	check(
		tap.decided.size() == decided and tap.published == published,
		"load: no answer from before the load is announced"
	)
	check(_city(sim) == city, "load: the loaded city is untouched by them")
	check(
		JSON.stringify(brain.to_dict()) == brain_doc,
		"load: the loaded brain state is untouched by them"
	)
	_free(w)


## The guard must not eat answers it should keep: a call sent in this city lands normally.
func _check_current_answer_lands() -> void:
	var w := _world()
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var gated: GATED = w["gated"]
	var tap: Tap = w["tap"]
	var logs := _logs(brain)
	gated.hold = true
	brain._run_mayor(2, sim.day)
	brain._run_support("news", sim.day, Callable(brain, "_run_news"))
	check(brain.pending_calls() == 2, "current: a mayor and the Gazette are in flight")
	var decided := tap.decided.size()
	var published := tap.published
	gated.hold = false
	gated.gate.emit()
	check(
		tap.decided.size() == decided + 1 and tap.published == published + 1,
		"current: both answers land in the city they were sent for"
	)
	check(
		(brain.mayor_state[2]["log"] as Array).size() == (logs[2] as Array)[0] + 1,
		"current: the mayor's log gained its entry"
	)
	check(brain.pending_calls() == 0 and tap.busy == 0, "current: the flags clear as before")
	_free(w)


## A call that fails live and falls back to the offline planner after the city was replaced must
## not read the new city or take numbers from its seeded RNG (the Chaos Director's planner does).
func _check_late_heuristic() -> void:
	var w := _world()
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var gated: GATED = w["gated"]
	gated.hold = true
	gated.late = true
	brain._run_support("chaos", sim.day, Callable(brain, "_run_chaos"))
	brain._run_mayor(0, sim.day)
	sim.new_city(NEW_SEED)
	brain.setup(sim, gated)
	var rng_state := sim.rng.state
	var city := _city(sim)
	var mayors_before: Array = sim.mayors.duplicate(true)
	gated.gate.emit()
	check(sim.rng.state == rng_state, "late fallback: the new city's RNG stream is not advanced")
	check(
		_city(sim) == city and sim.mayors == mayors_before,
		"late fallback: the new city's state is not touched"
	)
	_free(w)


## The on-demand Street Inspector answers for a tile of the old city: dropped after New City.
func _check_inspector() -> void:
	var w := _world()
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var gated: GATED = w["gated"]
	var tap: Tap = w["tap"]
	gated.hold = true
	brain.inspect_tile(5, 5)
	check(tap.answered == [true], "inspector: the request is announced as pending")
	sim.new_city(NEW_SEED)
	brain.setup(sim, gated)
	gated.hold = false
	gated.gate.emit()
	check(tap.answered == [true], "inspector: the old city's answer is never shown")
	brain.inspect_tile(5, 5)
	check(
		tap.answered == [true, true, false],
		"inspector: a request in the new city is answered (%s)" % str(tap.answered)
	)
	_free(w)


## The old city's answer lands while the new city's own call for the same role is in flight: it
## must not clear the new call's flag or tell the HUD the brain is less busy than it is.
func _check_overlapping_calls() -> void:
	var w := _world()
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var gated: GATED = w["gated"]
	var tap: Tap = w["tap"]
	gated.each = true
	brain._run_support("news", sim.day, Callable(brain, "_run_news"))
	brain._run_mayor(0, sim.day)
	check(gated.parked.size() == 2, "overlap: the old Gazette and the old mayor are parked")
	sim.new_city(NEW_SEED)
	brain.setup(sim, gated)
	brain._run_support("news", 1, Callable(brain, "_run_news"))
	brain._run_mayor(0, 1)
	check(
		gated.parked.size() == 4 and brain.pending_calls() == 2 and tap.busy == 2,
		"overlap: the new city's Gazette and mayor 0 are in flight too (busy=%d)" % tap.busy
	)
	var published := tap.published
	var decided := tap.decided.size()
	gated.release(0)
	gated.release(1)
	check(
		brain._support_in_flight.has("news") and bool(brain._mayor_in_flight[0]),
		"overlap: the old answers did not clear the new calls' flags"
	)
	check(
		brain.pending_calls() == 2 and tap.busy == 2,
		(
			"overlap: the busy count is still the new calls' (%d, HUD %d)"
			% [brain.pending_calls(), tap.busy]
		)
	)
	check(
		tap.published == published and tap.decided.size() == decided,
		"overlap: the old answers announced nothing"
	)
	gated.release(2)
	gated.release(3)
	check(
		tap.published == published + 1 and tap.decided.size() == decided + 1,
		"overlap: the new answers land, each once"
	)
	check(
		brain.pending_calls() == 0 and tap.busy == 0,
		(
			"overlap: and clear their own flags (pending %d, HUD %d)"
			% [brain.pending_calls(), tap.busy]
		)
	)
	_free(w)


## A New City as Main.new_game makes it: the sim, the brain, the people and the minds, in order.
func _new_city(w: Dictionary, gated: GATED) -> void:
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var people: Residents = w["people"]
	var minds: ResidentMinds = w["minds"]
	sim.new_city(NEW_SEED)
	brain.setup(sim, gated)
	people.setup(sim)
	minds.setup(sim, people, gated, brain)
	brain.minds = minds


## Starts a fire at a resident's home and plans the day, every call parked: plan batches and
## reactions in flight. Returns how many calls this parked.
func _park_residents(w: Dictionary, gated: GATED) -> int:
	var sim: CitySim = w["sim"]
	var people: Residents = w["people"]
	var minds: ResidentMinds = w["minds"]
	var before := gated.parked.size()
	gated.each = true
	var home := int((people.people[0] as Dictionary)["home"])
	sim.trigger_disaster("fire", D.tx(home), D.ty(home), "test", "in flight")
	minds.plan_day(sim.day)
	return gated.parked.size() - before


## Plan batches and a reaction in flight at New City: they were counted in the old city's two
## counters, which setup() zeroed, so they must settle nothing when they land, not drive the
## counters below zero. The new city's own batches (started before the old ones land) still count
## and still end in plans_done.
func _check_minds_new_city() -> void:
	var w := _world()
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var people: Residents = w["people"]
	var minds: ResidentMinds = w["minds"]
	var gated: GATED = w["gated"]
	var old_calls := _park_residents(w, gated)
	check(
		old_calls > 1 and minds.pending() == old_calls,
		"minds: %d calls (plan batches and a reaction) are in flight" % old_calls
	)
	var gen := minds._generation
	_new_city(w, gated)
	check(minds._generation != gen, "minds: New City starts a new generation")
	check(minds.pending() == 0, "minds: New City zeroes the count (%d)" % minds.pending())
	gated.each = false
	K.grow(sim, people, 30)
	var done: Array = []
	var reacted: Array = []
	minds.plans_done.connect(func(d: int) -> void: done.append(d))
	minds.reacted.connect(func(_e: Dictionary, _r: Array) -> void: reacted.append(1))
	var new_calls := _park_residents(w, gated)
	check(
		new_calls > 1 and minds.pending() == new_calls,
		"minds: the new city's own %d calls are in flight (%d)" % [new_calls, minds.pending()]
	)
	var stats := minds.stats.duplicate()
	var folk := JSON.stringify(people.to_dict()).hash()
	var city := _city(sim)
	for i in range(old_calls):
		gated.release(i)
	check(
		minds.pending() == new_calls,
		"minds: the old answers settle nothing of the new city's count (%d)" % minds.pending()
	)
	check(done.is_empty() and reacted.is_empty(), "minds: and announce nothing")
	check(
		minds.stats == stats and JSON.stringify(people.to_dict()).hash() == folk,
		"minds: nor do they plan the new city's people or count in its stats"
	)
	check(_city(sim) == city, "minds: nor touch the new city")
	for i in range(old_calls, old_calls + new_calls):
		gated.release(i)
	check(
		minds.pending() == 0 and done == [sim.day],
		"minds: the new city's own batches settle, and plans_done fires once (%s)" % str(done)
	)
	check(brain._day_gate(), "minds: so the day gate is open with nothing in flight")
	_free(w)


## Load (ResidentMinds.from_dict) is the same event.
func _check_minds_load() -> void:
	var w := _world()
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var minds: ResidentMinds = w["minds"]
	var gated: GATED = w["gated"]
	var saved := JSON.parse_string(JSON.stringify(minds.to_dict())) as Dictionary
	var old_calls := _park_residents(w, gated)
	check(old_calls > 1 and minds.pending() == old_calls, "minds load: calls are in flight")
	var done: Array = []
	minds.plans_done.connect(func(d: int) -> void: done.append(d))
	minds.from_dict(saved)
	check(minds.pending() == 0, "minds load: from_dict zeroes the count (%d)" % minds.pending())
	gated.each = false
	for i in range(old_calls):
		gated.release(i)
	check(
		minds.pending() == 0 and done.is_empty(),
		"minds load: the old answers land on nothing (count %d)" % minds.pending()
	)
	check(brain._day_gate(), "minds load: the day gate is open")
	_free(w)
