extends SceneTree
## What a model's loose JSON may put in a mayor's order and text (ActionClean) and how Ask the five
## and the mayors' own turns take it: a null, NaN, infinity, a negative width, a coordinate of 1e12,
## a tax rate of -4 or a grant of 1e30 never reaches a screen as "<null>" or "$9223372036854775807"
## and never reaches the sim as a number that makes it walk a trillion tiles; an order that already
## holds sane values (every recorded one) comes back equal, so replayed turns play as before; the
## panel shows no "<null>"; the side question's retries are not the city's retry count. Offline.

const D := preload("res://scripts/sim/sim_defs.gd")
const BrainText := preload("res://scripts/ai/brain_text.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
const LIVE := preload("res://tools/tests/support/arena_live_client.gd")
const PANEL := preload("res://scripts/fp/arena/arena_panel.gd")
const QUESTION := "Your district just lost power. What do you do?"
const TOKEN := "FP_ARENA_NUMBERS_TEST"
## A road end far past any map: what a model that wrote a runaway number asked for.
const HOSTILE_X2 := 5000000

var fails: Array[String] = []
var _now_ms: int = 0


## chat_json that answers every role with nulls where text goes.
class NullChat:
	extends GmiClient

	func chat_json(
		_role: String,
		_agent: String,
		_model: String,
		_system: String,
		_user: String,
		_day: int,
		_max_tokens: int,
		_timeout_s: float,
		_heuristic: Callable
	) -> Dictionary:
		var data := {
			"trigger": false,
			"reason": null,
			"narration": null,
			"note": null,
			"advice": null,
			"statement": null,
			"enacted": [],
			"repealed": [],
			"headline": "H",
			"priority": "power",
		}
		return {"ok": true, "data": data, "source": "live", "latency_ms": 1, "error": "", "raw": ""}


## A GmiClient whose support agents answer with a wrong type in every field (role -> data).
class WeirdChat:
	extends GmiClient
	var data_by_role: Dictionary = {}

	func chat_json(
		role: String,
		_agent: String,
		_model: String,
		_system: String,
		_user: String,
		_day: int,
		_max_tokens: int,
		_timeout_s: float,
		_heuristic: Callable
	) -> Dictionary:
		var data: Dictionary = data_by_role.get(role, {})
		return {"ok": true, "data": data, "source": "live", "latency_ms": 1, "error": "", "raw": ""}


## A GmiClient whose transport fails the way a rate limit does.
class Flaky:
	extends GmiClient
	var posts: int = 0

	func _post(_m: String, _s: String, _u: String, _t: int, _timeout: float) -> Dictionary:
		posts += 1
		return {
			"ok": false,
			"error": "HTTP 429 slow down",
			"retryable": true,
			"service_fail": true,
			"retry_after_ms": 0
		}


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN)
	await process_frame
	_check_numbers()
	_check_text()
	_check_clean()
	_check_recorded_orders_unchanged()
	_check_arena_num()
	await _check_ask()
	await _check_sim_never_walks()
	await _check_brain_text()
	await _check_weird_types()
	await _check_retry_stat()
	K.finish(self, TOKEN, fails)


func _check_numbers() -> void:
	check(
		ActionClean.number(5) == 5 and ActionClean.number(2.5) == 2.5,
		"number: an int and a float stand for themselves"
	)
	check(
		ActionClean.number("12") == 12 and typeof(ActionClean.number("12")) == TYPE_INT,
		"number: a whole numeric word is an int"
	)
	check(
		ActionClean.number(" 7 ") == 7 and ActionClean.number("1.5e2") == 150.0,
		"number: padded and exponent words read"
	)
	var junk: Array = [null, true, false, [], [1], {}, "abc", "", "0x10", "--3", NAN, INF, -INF]
	var all_null := true
	for v: Variant in junk:
		all_null = all_null and ActionClean.number(v) == null
	check(all_null, "number: null, bool, list, map, a word, NaN and infinity are not numbers")
	for word: String in ["NaN", "nan", "inf", "-inf", "Infinity"]:
		var n: Variant = ActionClean.number(word)
		check(
			n == null or is_finite(float(n)),
			"number: the word '%s' is never a non-finite number" % word
		)
	var parsed: Variant = JSON.parse_string('{"x": 1e999, "y": -1e999}')
	var inf_ok := (
		typeof(parsed) != TYPE_DICTIONARY
		or (ActionClean.number((parsed as Dictionary).get("x")) == null)
	)
	check(inf_ok, "number: a JSON 1e999 does not come through as a number")


func _check_text() -> void:
	var table := [
		["hello", "hello"],
		["", ""],
		[null, ""],
		["<null>", ""],
		[5, "5"],
		[2.5, "2.5"],
		[NAN, ""],
		[INF, ""],
		[true, ""],
		[{}, ""],
		[{"a": 1}, ""],
		[[], ""],
		[["a", "b"], "a b"],
		[[null, "x", [1], 3], "x 3"],
		[&"name", "name"],
	]
	var ok := true
	for row: Array in table:
		var got := ActionClean.text_of(row[0])
		if got != row[1]:
			ok = false
			print("  text_of(%s) = '%s', wanted '%s'" % [str(row[0]), got, row[1]])
	check(
		ok,
		"text_of: strings as they are, numbers as digits, a list joined, null and the rest nothing"
	)
	check(
		not ActionClean.text_of(null).contains("<null>"),
		"text_of(null) is not the engine's '<null>'"
	)


func _check_clean() -> void:
	var before := {"type": "zone", "x": 4.0, "y": 5.0, "w": 3.0, "h": 2.0, "zone": "R"}
	check(ActionClean.clean(before) == before, "clean: an order of sane values comes back equal")
	var road := {
		"type": "road",
		"x": 10.0,
		"y": 10.0,
		"x2": 25.0,
		"y2": 10.0,
		"grade": "gravel",
		"reason": "link"
	}
	check(
		ActionClean.clean(road) == road, "clean: a road with a grade and a reason comes back equal"
	)
	var wild := {
		"type": "road",
		"x": 1e12,
		"y": -1e12,
		"x2": 4.0e30,
		"y2": "9999999999",
		"w": -3,
		"h": 99,
		"amount": 1e30,
		"r": 99,
		"c": -4,
		"i": "7",
		"reason": "keep",
		"z": 1e30
	}
	var c := ActionClean.clean(wild)
	check(
		c["x"] == 2048.0 and c["y"] == -2048.0 and c["x2"] == 2048.0 and c["y2"] == 2048,
		(
			"clean: coordinates are held to +-%d (%s %s %s %s)"
			% [ActionClean.COORD_LIMIT, c["x"], c["y"], c["x2"], c["y2"]]
		)
	)
	check(c["w"] == 1 and c["h"] == 64, "clean: sides are held to 1..64")
	check(c["amount"] == 100000000.0, "clean: an amount is held to 0..1e8")
	check(
		c["r"] == 20 and c["c"] == 0 and c["i"] == 7,
		"clean: tax rates are held to 0..20, a numeric word read"
	)
	check(c["reason"] == "keep" and c["z"] == 1e30, "clean: keys it does not know are left alone")
	check(wild["x"] == 1e12, "clean: the input is not changed")
	var dropped := ActionClean.clean(
		{
			"type": null,
			"building": [],
			"grade": 5,
			"to": {},
			"zone": "C",
			"x": null,
			"y": NAN,
			"w": "wide",
			"amount": [3],
			"r": true
		}
	)
	check(
		(
			not dropped.has("type")
			and not dropped.has("building")
			and not dropped.has("grade")
			and not dropped.has("to")
		),
		"clean: a text field that is not text is dropped"
	)
	check(
		(
			dropped["zone"] == "C"
			and not dropped.has("x")
			and not dropped.has("y")
			and not dropped.has("w")
			and not dropped.has("amount")
			and not dropped.has("r")
		),
		"clean: a number field that is not a number is dropped, a good field kept"
	)
	var negative := ActionClean.clean({"type": "grant", "to": "kimi", "amount": -500})
	check(negative["amount"] == 0, "clean: a negative amount is 0 (the grant reads as no grant)")


func _check_recorded_orders_unchanged() -> void:
	var replay := (
		JSON.parse_string(FileAccess.get_file_as_string("res://data/gmi_replay_cache.json"))
		as Dictionary
	)
	var orders := 0
	var same := 0
	for key: String in replay:
		if not key.begins_with("mayor|"):
			continue
		for e: Dictionary in replay[key]:
			for a: Variant in (e["data"] as Dictionary).get("actions", []):
				if typeof(a) == TYPE_DICTIONARY:
					orders += 1
					same += 1 if ActionClean.clean(a) == a else 0
	check(
		orders > 250 and same == orders,
		"every recorded order (%d) comes back equal: replayed turns play as before" % orders
	)


func _check_arena_num() -> void:
	var a := {"x": 1e30, "y": -1e30, "w": -5, "amount": "5", "r": NAN, "z": null}
	check(
		ArenaAsk._num(a, "x", -99999) == ActionClean.COORD_LIMIT,
		"_num: a huge coordinate is held to the limit"
	)
	check(
		ArenaAsk._num(a, "y", -99999) == -ActionClean.COORD_LIMIT, "_num: a hugely negative one too"
	)
	check(ArenaAsk._num(a, "w", 1) == 1, "_num: a negative side is 1")
	check(ArenaAsk._num(a, "amount", 0) == 5, "_num: a numeric word reads")
	check(
		ArenaAsk._num(a, "r", 7) == 7 and ArenaAsk._num(a, "z", 7) == 7,
		"_num: NaN and null give the fallback"
	)
	check(
		ArenaAsk._num(a, "missing", -99999) == -99999,
		"_num: a missing key gives the fallback as it is"
	)
	var sim: CitySim = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	sim.name = "NumSim"
	get_root().add_child(sim)
	sim.new_city(7)
	var rect := sim.district_rect(0)
	var hostile: Array = [
		{"type": "road", "x": 10, "y": 10, "x2": 1e30, "y2": 1e30, "grade": "paved"},
		{"type": "road", "x": -1e30, "y": 1e12, "x2": 5, "y2": 5},
		{"type": "zone", "x": 5, "y": 5, "w": -3, "h": 1e30},
		{"type": "bulldoze", "x": 5, "y": 5, "w": 1e30, "h": -1e30},
		{"type": "grant", "to": "kimi", "amount": -1e30},
		{"type": "grant", "to": "kimi", "amount": 1e30},
		{"type": "annex", "x": 1e30, "y": -1e30},
	]
	var sane := true
	for o: Dictionary in hostile:
		var chk := ArenaAsk._check_action(sim, 0, rect, o)
		var cost := int(chk["cost"])
		sane = sane and cost >= 0 and cost <= 100000000 * 2
	check(sane, "_check_action: no hostile order costs a negative or absurd sum")
	var flags := ArenaAsk.plausibility(sim, 0, hostile)
	check(
		not flags.is_empty(),
		"plausibility: the hostile orders are flagged, not a crash (%d flags)" % flags.size()
	)
	sim.queue_free()


## A fresh grown world whose brain talks to a live client that answers at once.
func _world() -> Dictionary:
	var w := SK.make_world(get_root(), 7)
	var live: LIVE = LIVE.new()
	live.name = "LiveClient"
	get_root().add_child(live)
	live.live_enabled = true
	live.each = false
	var brain: CityBrain = w["brain"]
	brain.setup(w["sim"], live)
	(w["minds"] as ResidentMinds).setup(w["sim"], w["people"], live, brain)
	K.grow(w["sim"], w["people"], 30)
	w["live"] = live
	return w


func _free(w: Dictionary) -> void:
	(w["live"] as Node).queue_free()
	SK.free_world(w)


func _check_ask() -> void:
	var w := _world()
	var live: LIVE = w["live"]
	var brain: CityBrain = w["brain"]
	live.data_for["argon"] = {
		"thought": null,
		"public_post": ["a list", null],
		"mood": null,
		"propose_ordinance": null,
		"actions":
		[
			{"type": null, "x": null},
			{"type": "road", "x": 5, "y": 5, "x2": 1e30, "y2": NAN, "grade": null},
			{"type": "grant", "to": "kimi", "amount": 1e30},
			{"type": "set_tax", "r": -4, "c": 99, "i": "x"},
			{"type": "zone", "x": 3, "y": 3, "w": -3, "h": 1e18, "zone": null},
		],
	}
	live.data_for["deepseek"] = {"thought": "<null>", "public_post": 7, "actions": "none"}
	live.data_for["kimi"] = {
		"thought": {"nested": 1},
		"public_post": true,
		"actions": [null, 5, "x", {"type": "emergency"}]
	}
	live.data_for["qwen"] = {"thought": "Fine.", "public_post": "Steady.", "actions": []}
	live.data_for["grok"] = {}
	var arena := brain.arena_asker()
	arena.clock = func() -> int: return _now_ms
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	var asked := arena.ask(QUESTION)
	var guard := 0
	while arena.busy() and guard < 200:
		await process_frame
		guard += 1
	check(
		bool(asked["ok"]) and not arena.busy(),
		"the ask over hostile answers ends (%d frames)" % guard
	)
	var all_text := JSON.stringify(arena.run["results"])
	check(not all_text.contains("<null>"), "no result holds the engine's '<null>'")
	var res: Array = arena.run["results"]
	check(
		(
			str((res[0] as Dictionary)["thought"]).is_empty()
			and str((res[0] as Dictionary)["post"]) == "a list"
		),
		(
			"a null thought is empty and a list post is its text (%s | %s)"
			% [(res[0] as Dictionary)["thought"], (res[0] as Dictionary)["post"]]
		)
	)
	check(
		(
			str((res[1] as Dictionary)["thought"]).is_empty()
			and str((res[1] as Dictionary)["post"]) == "7"
		),
		"a literal '<null>' thought is empty and a numeric post is its digits"
	)
	check(
		(
			str((res[2] as Dictionary)["thought"]).is_empty()
			and str((res[2] as Dictionary)["post"]).is_empty()
		),
		"a map thought and a bool post are empty"
	)
	check(
		((res[2] as Dictionary)["actions"] as Array).size() == 1,
		"an actions list of junk keeps only the real order"
	)
	var held := true
	for a: Dictionary in (res[0] as Dictionary)["actions"]:
		for k: String in ["x", "y", "x2", "y2", "w", "h", "amount", "r", "c", "i"]:
			if a.has(k):
				var n: Variant = ActionClean.number(a[k])
				held = held and n != null and absf(float(n)) <= 100000000.0
	check(held, "every number of the first mayor's orders is finite and inside its range")
	# The panel: no '<null>' and no ten-digit number on screen.
	var panel: Control = PANEL.new()
	get_root().add_child(panel)
	panel.call("setup", brain)
	panel.call("show_last")
	var texts: PackedStringArray = panel.call("texts")
	var rx := RegEx.create_from_string("\\d{10,}")
	var junk := ""
	for t: String in texts:
		if t.contains("<null>") or rx.search(t) != null:
			junk = t
	check(
		junk.is_empty(), "the panel shows no '<null>' and no ten-digit number (%s)" % junk.left(80)
	)
	var column_texts := "\n".join(texts)
	check(
		column_texts.contains("(nothing said)"), "a mayor who said nothing shows '(nothing said)'"
	)
	panel.queue_free()
	_free(w)


## A road to x2 = 1e12 reached the sim as is would make it walk a trillion tiles; through the
## brain's landing it is held to the map's edge and the sim answers at once.
func _check_sim_never_walks() -> void:
	var w := _world()
	var brain: CityBrain = w["brain"]
	var sim: CitySim = w["sim"]
	var res := {
		"ok": true,
		"source": "live",
		"latency_ms": 5,
		"error": "",
		"data":
		{
			"thought": null,
			"public_post": null,
			"mood": null,
			"actions":
			[{"type": "road", "x": 10, "y": 10, "x2": HOSTILE_X2, "y2": 10}, {"type": null}],
		},
	}
	# Large enough to be absurd, small enough that a missing clamp still finishes (the sim builds
	# the road's path tile by tile before it refuses it): the check below then fails instead of
	# the process running away with the machine's memory (a 1e12 road would).
	var t0 := Time.get_ticks_msec()
	brain._land_mayor(0, sim.day, res)
	var ms := Time.get_ticks_msec() - t0
	var entry: Dictionary = (brain.mayor_state[0]["log"] as Array).back()
	check(
		ms < 2000,
		"a mayor's road to x2 = %d is applied (refused) in %d ms, not walked" % [HOSTILE_X2, ms]
	)
	var first: Dictionary = (entry["actions"] as Array)[0]
	var applied: Dictionary = first["action"]
	check(
		float(applied["x2"]) == float(ActionClean.COORD_LIMIT),
		(
			"the sim was handed x2 = %d, not %d (%s)"
			% [ActionClean.COORD_LIMIT, HOSTILE_X2, str(applied["x2"])]
		)
	)
	check(not str(first["reason"]).is_empty(), "and it answered (%s)" % str(first["reason"]))
	check(
		(
			str(brain.mayor_state[0]["mood"]) == "focused"
			and not str(entry["thought"]).contains("<null>")
			and not str(entry["post"]).contains("<null>")
		),
		"a null thought, post and mood are empty and 'focused', never '<null>'"
	)
	var line := str((brain.mayor_state[0]["results"] as Array)[1])
	check(not line.contains("<null>"), "a null order type reads '?' in the mayor's log (%s)" % line)
	_free(w)


## The Gazette, the council, the Chaos Director and the Grid Operator take a null text as empty too.
func _check_brain_text() -> void:
	var w := _world()
	var brain: CityBrain = w["brain"]
	var sim: CitySim = w["sim"]
	var net := NullChat.new()
	net.name = "NullChat"
	get_root().add_child(net)
	net.live_enabled = false
	brain.setup(sim, net)
	sim.day = 6
	brain.proposals = {
		"recycling":
		{"by": "Ada Okafor", "day": 5, "votes": {"argon": "yes", "kimi": "yes", "qwen": "yes"}}
	}
	await brain._run_chaos(6)
	await brain._run_operator(6)
	await brain._run_council(6)
	var texts := JSON.stringify([brain.last_chaos, brain.last_operator, brain.last_council])
	check(
		not texts.contains("<null>"),
		"the support agents' null texts are empty, not '<null>' (%s)" % texts.left(160)
	)
	check(
		(
			str(brain.last_chaos.get("source", "")) == "live"
			and str(brain.last_operator.get("source", "")) == "live"
		),
		"fixture: the agents' answers landed"
	)
	net.queue_free()
	_free(w)


## Wrong-typed answers from the support agents and the residents: no script error, no hang.
func _check_weird_types() -> void:
	check(
		ActionClean.truthy(true) and ActionClean.truthy(1) and ActionClean.truthy("Yes"),
		"truthy: true, 1 and 'Yes' are yes"
	)
	var no_values: Array = [false, 0, 0.0, "no", "", null, [], [true], {}, {"a": 1}]
	var all_no := true
	for v: Variant in no_values:
		all_no = all_no and not ActionClean.truthy(v)
	check(all_no, "truthy: false, 0, other words, null, a list and a map are no")
	check(
		ActionClean.int_of(7, 16) == 7 and ActionClean.int_of("9", 16) == 9,
		"int_of: a number stands for itself"
	)
	check(
		(
			ActionClean.int_of(null, 16) == 16
			and ActionClean.int_of([1], 16) == 16
			and ActionClean.int_of({}, 16) == 16
			and ActionClean.int_of(NAN, 16) == 16
			and ActionClean.int_of("x", 16) == 16
		),
		"int_of: null, a list, a map, NaN and a word are the fallback"
	)
	check(
		(
			ActionClean.int_of(1e30, 16) == ActionClean.COORD_LIMIT
			and ActionClean.int_of(-1e30, 16) == -ActionClean.COORD_LIMIT
		),
		"int_of: a huge number is held to the map's limit"
	)
	var paper := {"headline": "H", "stories": 100000000000, "editorial": "E"}
	BrainText.debrand_paper(paper)
	check(not paper.has("stories"), "a Gazette whose stories is a number has no stories to loop")
	paper = {"headline": "H", "stories": [{"title": "T", "body": "B"}]}
	BrainText.debrand_paper(paper)
	check((paper["stories"] as Array).size() == 1, "a real list of stories stays")
	check(
		Residents._as_bool([1]) and Residents._as_bool({"a": 1}),
		"a resident's go_to_work given as a list or a map is the default (yes), not an error"
	)
	check(
		not Residents._as_bool("no") and Residents._as_bool("yes") and Residents._as_bool(true),
		"and the words and bools read as before"
	)
	var w := _world()
	var brain: CityBrain = w["brain"]
	var sim: CitySim = w["sim"]
	var net := WeirdChat.new()
	net.name = "WeirdChat"
	get_root().add_child(net)
	net.live_enabled = false
	net.data_by_role = {
		"chaos": {"trigger": [true], "type": "fire", "x": [1], "y": {"a": 1}},
		"operator": {"priority": [[1], {"a": 1}, "x", 1e30, null, 3, 3, "2", true], "note": 5},
		"news": {"headline": "H", "stories": 1e30, "editorial": ["a", null]},
	}
	brain.setup(sim, net)
	sim.day = 6
	await brain._run_chaos(6)
	check(not bool(brain.last_chaos.get("trigger", true)), "a chaos trigger that is a list is no")
	await brain._run_operator(6)
	var prio: Array = brain.last_operator.get("priority", [])
	check(
		prio.size() == 5 and prio.slice(0, 2) == [3, 2],
		"the operator's priority list skips the junk and completes the rest (%s)" % str(prio)
	)
	await brain._run_news(6)
	check(
		not brain.last_paper.is_empty() and not brain.last_paper.has("stories"),
		"a Gazette with a huge number of stories is kept without them"
	)
	net.queue_free()
	_free(w)


func _check_retry_stat() -> void:
	var c := Flaky.new()
	c.name = "Flaky"
	get_root().add_child(c)
	c.live_enabled = true
	c.sleep_ms = func(_ms: int) -> void: pass
	var side: Dictionary = await c.live_json("arena", "argon", "m", "s", "u", 1, 50, 30.0)
	check(
		not bool(side["ok"]) and int(side["attempts"]) == 3 and c.posts == 3,
		"fixture: the side question is tried three times"
	)
	check(
		int(c.stats["retries"]) == 0 and int(c.stats["side_retries"]) == 2,
		(
			"its two retries are the side question's own, not the city's (retries %d, side %d)"
			% [int(c.stats["retries"]), int(c.stats["side_retries"])]
		)
	)
	check(
		(
			int(c.stats["live_fail"]) == 0
			and c.live_outcomes.is_empty()
			and c.breaker_state() == "closed"
		),
		"and it leaves the failure counts, the window and the breaker alone"
	)
	c.posts = 0
	var city: Dictionary = await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 30.0)
	check(
		(
			not bool(city["ok"])
			and c.posts == 3
			and int(c.stats["retries"]) == 2
			and int(c.stats["side_retries"]) == 2
		),
		(
			"a city call's retries count as the city's (retries %d, side %d)"
			% [int(c.stats["retries"]), int(c.stats["side_retries"])]
		)
	)
	check(int(c.stats["live_fail"]) == 1, "and it is one failed call, not three")
	c.queue_free()
