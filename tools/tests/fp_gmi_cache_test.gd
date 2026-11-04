extends SceneTree
## The answer caches of GmiClient (GmiCache): the replay horizon (a recorded answer is served only
## up to the last day recorded for its key, so a city past the recording falls to the scripted
## planner instead of replaying day 12 forever; the session cache has no horizon; the flag
## replay_horizon switches it off) and the save diet (a save keeps each key's last 3 days, the
## in-memory cache is whole, recording writes everything, a 60-day cache stays under 1.5 MB, a New
## City starts with no answers and zero counters). Offline.

const K := preload("res://tools/tests/fp_kit.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const SIZE_BUDGET := 1500000

var fails: Array[String] = []


func _init() -> void:
	K.watchdog(self, "FP_GMI_CACHE_TEST")
	await process_frame
	_check_cache_functions()
	await _check_client_horizon()
	await _check_brain_horizon()
	_check_save_diet()
	_check_size_budget()
	K.finish(self, "FP_GMI_CACHE_TEST", fails)


func _entries(days: Array, tag: String = "x") -> Array:
	var out: Array = []
	for d: int in days:
		out.append({"day": d, "data": {"tag": "%s%d" % [tag, d]}})
	return out


func _check_cache_functions() -> void:
	var e := _entries([3, 5, 9])
	K.check(
		fails,
		GmiCache.last_day(e) == 9 and GmiCache.last_day([]) == -1,
		"last_day: the newest recorded day, -1 for none"
	)
	K.check(
		fails,
		(
			GmiCache.nearest(e, 5)["tag"] == "x5"
			and GmiCache.nearest(e, 6)["tag"] == "x5"
			and GmiCache.nearest(e, 8)["tag"] == "x9"
		),
		"nearest: the closest day wins"
	)
	K.check(fails, GmiCache.nearest(e, 4)["tag"] == "x3", "nearest: on a tie the first entry wins")
	K.check(
		fails,
		GmiCache.nearest(e, 1)["tag"] == "x3" and GmiCache.nearest(e, 30)["tag"] == "x9",
		"nearest: no horizon serves any day"
	)
	K.check(
		fails,
		GmiCache.nearest(e, 9, true)["tag"] == "x9" and GmiCache.nearest(e, 1, true)["tag"] == "x3",
		"horizon: up to and before the last recorded day it answers"
	)
	K.check(
		fails,
		GmiCache.nearest(e, 10, true).is_empty() and GmiCache.nearest(e, 30, true).is_empty(),
		"horizon: past the last recorded day it does not"
	)
	K.check(
		fails,
		GmiCache.nearest([], 3).is_empty() and GmiCache.nearest([5, "x", {"day": 4}], 4).is_empty(),
		"nearest: no entry, or none with data, is {}"
	)
	var session := {"k": _entries([2], "s"), "only_session": _entries([1], "o")}
	var replay := {"k": _entries([1, 4], "r"), "only_replay": _entries([3], "p")}
	K.check(
		fails,
		GmiCache.lookup(session, replay, "k", 40, true)["tag"] == "s2",
		"lookup: the session's own answer has no horizon and wins over the replay"
	)
	K.check(
		fails,
		(
			GmiCache.lookup(session, replay, "only_replay", 3, true)["tag"] == "p3"
			and GmiCache.lookup(session, replay, "only_replay", 4, true).is_empty()
		),
		"lookup: the replay answers inside its horizon only"
	)
	K.check(
		fails,
		GmiCache.lookup(session, replay, "only_replay", 40, false)["tag"] == "p3",
		"lookup: horizon off serves it at any day"
	)
	K.check(
		fails,
		GmiCache.lookup(session, replay, "nothing", 1, true).is_empty(),
		"lookup: an unknown key is {}"
	)
	var long := {
		"k": _entries([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), "j": _entries([2, 2, 7, 7, 7]), "bad": "x"
	}
	var p := GmiCache.pruned(long)
	var days: Array = (p["k"] as Array).map(func(en: Dictionary) -> int: return int(en["day"]))
	K.check(fails, days == [8, 9, 10], "pruned: the last 3 distinct days of a key (%s)" % str(days))
	K.check(
		fails,
		(p["j"] as Array).size() == 5 and not p.has("bad"),
		"pruned: every entry of a kept day stays; a non-list is dropped"
	)
	K.check(fails, (long["k"] as Array).size() == 10, "pruned: the original is not touched")
	K.check(fails, GmiCache.pruned(p) == p, "pruned: pruning twice is pruning once")
	K.check(fails, GmiCache.entry_count(long) == 15, "entry_count counts the entries of every list")


func _client() -> GmiClient:
	var c: GmiClient = (load("res://scripts/ai/gmi_client.gd") as GDScript).new()
	c.name = "GmiClient"
	get_root().add_child(c)
	c.live_enabled = false
	return c


## Through the client with the real recorded cache (data/gmi_replay_cache.json).
func _check_client_horizon() -> void:
	var c := _client()
	K.check(
		fails,
		not c.replay_cache.is_empty() and FeatureFlags.enabled("replay_horizon"),
		"fixture: the replay cache is loaded and the horizon flag is on by default"
	)
	var mayors_ok := true
	var mayors_past := true
	for m: Dictionary in D.MAYORS:
		var key := "mayor|%s" % str(m["id"])
		var last := GmiCache.last_day(c.replay_cache[key])
		mayors_ok = mayors_ok and last == 12 and not c.lookup(key, last).is_empty()
		mayors_past = (
			mayors_past and c.lookup(key, last + 1).is_empty() and c.lookup(key, 40).is_empty()
		)
	K.check(fails, mayors_ok, "every mayor's recording runs to day 12 and answers on it")
	K.check(fails, mayors_past, "and no mayor's recording answers on day 13 or day 40")
	K.check(
		fails,
		not c.lookup("mayor|argon", 4).is_empty(),
		"a gap inside the recording (argon has no day 4) is still answered by the nearest day"
	)
	var support_ok := true
	for key: String in [
		"news|gazette", "chaos|director", "council|speaker", "operator|grid", "citizens|voices"
	]:
		var last := GmiCache.last_day(c.replay_cache[key])
		support_ok = (
			support_ok and not c.lookup(key, last).is_empty() and c.lookup(key, last + 1).is_empty()
		)
	K.check(
		fails,
		support_ok,
		"each support agent's recording stops at its own last day (sparse ones sooner)"
	)
	var minds_ok := true
	var checked := 0
	for key: String in c.replay_cache:
		if key.begins_with("resident|") or key.begins_with("react|"):
			var last := GmiCache.last_day(c.replay_cache[key])
			minds_ok = (
				minds_ok
				and not c.lookup(key, last).is_empty()
				and c.lookup(key, last + 1).is_empty()
			)
			checked += 1
	K.check(
		fails,
		minds_ok and checked > 100,
		"residents' plans and reactions follow the same horizon (%d keys)" % checked
	)
	# The flag off: the nearest recorded day answers at any day, as before.
	FeatureFlags.set_override("replay_horizon", false)
	var late := c.lookup("mayor|argon", 40)
	K.check(
		fails,
		not late.is_empty() and late == c.lookup("mayor|argon", 12),
		"flag off: day 40 replays day 12, as before"
	)
	FeatureFlags.set_override("replay_horizon", true)
	# A session answer is served at any day.
	c.remember("mayor|argon", 3, {"thought": "this session's own"})
	K.check(
		fails,
		str(c.lookup("mayor|argon", 40).get("thought", "")) == "this session's own",
		"this session's live answer has no horizon"
	)
	# chat_json: the source tells.
	var day12: Dictionary = await c.chat_json(
		"news",
		"gazette",
		"m",
		"s",
		"u",
		12,
		10,
		1.0,
		func() -> Dictionary: return {"headline": "h"}
	)
	var day13: Dictionary = await c.chat_json(
		"news",
		"gazette",
		"m",
		"s",
		"u",
		13,
		10,
		1.0,
		func() -> Dictionary: return {"headline": "scripted"}
	)
	K.check(
		fails,
		(
			str(day12["source"]) == "cache"
			and str(day13["source"]) == "heuristic"
			and str(day13["data"]["headline"]) == "scripted"
		),
		(
			"chat_json: day 12 plays the recording, day 13 the scripted planner (%s, %s)"
			% [day12["source"], day13["source"]]
		)
	)
	var kept := int(c.stats["heuristic"])
	K.check(fails, kept == 1 and int(c.stats["cache"]) == 1, "and the stats count one of each")
	c.queue_free()


## Through a brain: the mayors, the Gazette and the Chaos Director on day 12 and day 14.
func _check_brain_horizon() -> void:
	var w := SK.make_world(get_root(), 7)
	var brain: CityBrain = w["brain"]
	var sim: CitySim = w["sim"]
	var client: GmiClient = w["client"]
	sim.day = 12
	await brain._run_mayor(0, 12)
	var m12 := str(brain.mayor_state[0]["source"])
	await brain._run_news(12)
	var n12 := str(brain.last_paper.get("source", ""))
	await brain._run_chaos(12)
	var c12 := str(brain.last_chaos.get("source", ""))
	K.check(
		fails,
		m12 == "cache" and n12 == "cache" and c12 == "cache",
		"day 12: mayor, Gazette and Chaos Director play the recording (%s %s %s)" % [m12, n12, c12]
	)
	sim.day = 14
	await brain._run_mayor(0, 14)
	var m14 := str(brain.mayor_state[0]["source"])
	await brain._run_news(14)
	var n14 := str(brain.last_paper.get("source", ""))
	await brain._run_chaos(14)
	var c14 := str(brain.last_chaos.get("source", ""))
	K.check(
		fails,
		m14 == "heuristic" and n14 == "heuristic" and c14 == "heuristic",
		"day 14: all three fall to the scripted planner (%s %s %s)" % [m14, n14, c14]
	)
	var sewage := (
		str(brain.last_chaos.get("type", "")) == "sewage_burst"
		and int(brain.last_chaos.get("x", -1)) == 18
	)
	K.check(fails, not sewage, "and day 12's sewage burst at (18,24) is not replayed on day 14")
	FeatureFlags.set_override("replay_horizon", false)
	await brain._run_mayor(1, 14)
	K.check(
		fails,
		str(brain.mayor_state[1]["source"]) == "cache",
		"flag off: the recording answers on day 14 again"
	)
	FeatureFlags.set_override("replay_horizon", true)
	K.check(fails, client.log_records.size() > 0, "fixture: the calls were logged")
	SK.free_world(w)


func _check_save_diet() -> void:
	var c := _client()
	for day in range(1, 11):
		c.remember("resident|r1:Test", day, {"say": "day %d" % day})
	c.remember("mayor|argon", 2, {"thought": "old"})
	c.stats["live_ok"] = 7
	var d := c.to_dict()
	var saved: Array = (d["session_cache"] as Dictionary)["resident|r1:Test"]
	var days: Array = saved.map(func(en: Dictionary) -> int: return int(en["day"]))
	K.check(
		fails,
		(
			days == [8, 9, 10]
			and ((d["session_cache"] as Dictionary)["mayor|argon"] as Array).size() == 1
		),
		"to_dict keeps each key's last 3 days (%s)" % str(days)
	)
	K.check(
		fails,
		(c.session_cache["resident|r1:Test"] as Array).size() == 10,
		"to_dict never prunes the in-memory cache"
	)
	K.check(
		fails, int((d["stats"] as Dictionary)["live_ok"]) == 7, "the stats are saved as they are"
	)
	# Round trip: loading the pruned save and saving again is the same bytes.
	var c2 := _client()
	c2.from_dict(JSON.parse_string(JSON.stringify(d)))
	var first := JSON.stringify(JSON.parse_string(JSON.stringify(d)))
	var second := JSON.stringify(JSON.parse_string(JSON.stringify(c2.to_dict())))
	K.check(fails, first == second, "save, load, save: the same bytes")
	K.check(
		fails,
		c2.lookup("resident|r1:Test", 9)["say"] == "day 9",
		"a lookup on a loaded save still answers from the nearest kept day"
	)
	# The brain saves the same pruned copy under its own key.
	var w := SK.make_world(get_root(), 7)
	var client: GmiClient = w["client"]
	for day in range(1, 8):
		client.remember("brain|probe", day, {"n": day})
	var bd: Dictionary = (w["brain"] as CityBrain).to_dict()
	var nested: Array = ((bd["client"] as Dictionary)["session_cache"] as Dictionary)["brain|probe"]
	K.check(
		fails,
		nested.size() == 3 and JSON.stringify(bd["client"]) == JSON.stringify(client.to_dict()),
		"the brain's nested client section is the same pruned copy"
	)
	SK.free_world(w)
	# Recording keeps everything: the session cache is what gets merged into the replay file.
	c.record_mode = true
	K.check(
		fails,
		((c.to_dict()["session_cache"] as Dictionary)["resident|r1:Test"] as Array).size() == 10,
		"record mode: to_dict saves the whole cache"
	)
	c.record_mode = false
	# GmiCache.clear_session: no answers, zero counters, the calls in flight stay counted.
	c.stats["in_flight"] = 2
	c.stats["retries"] = 5
	GmiCache.clear_session(c)
	var zero := true
	for k: String in c.stats:
		zero = zero and (int(c.stats[k]) == 0 or k == "in_flight")
	K.check(
		fails,
		c.session_cache.is_empty() and zero and int(c.stats["in_flight"]) == 2,
		"clear_session: no answers, zero counters, in_flight untouched"
	)
	K.check(
		fails,
		c.lookup("resident|r1:Test", 9).is_empty(),
		"and the new city finds none of the last city's answers"
	)
	c.queue_free()
	c2.queue_free()


## A synthetic 60-day keyed session: every key of the recorded game (mayors, support agents and
## about 170 resident plans and reactions, sizes as recorded, twice over) gets one answer per day
## for 60 days, about what a live run remembers. Unpruned that is several MB and growing; saved it
## stays flat.
func _check_size_budget() -> void:
	var c := _client()
	var replay := c.replay_cache
	var added := 0
	# Two namespaces of the recorded keys: a live session remembers more keys than the one game that
	# was recorded (the real day-10 save had 282 keys against 179 here).
	for day in range(1, 61):
		for key: String in replay:
			var recorded: Array = replay[key]
			var pick: Dictionary = recorded[day % recorded.size()]
			for suffix: String in ["", "#b"]:
				c.remember(key + suffix, day, (pick["data"] as Dictionary).duplicate(true))
				added += 1
	var whole := JSON.stringify(c.session_cache).length()
	var saved := JSON.stringify(c.to_dict()).length()
	var at_day_30: GmiClient = _client()
	for day in range(1, 31):
		for key: String in replay:
			var recorded: Array = replay[key]
			for suffix: String in ["", "#b"]:
				at_day_30.remember(
					key + suffix,
					day,
					(recorded[day % recorded.size()]["data"] as Dictionary).duplicate(true)
				)
	var saved_30 := JSON.stringify(at_day_30.to_dict()).length()
	print(
		(
			"FP_GMI_CACHE: 60 days, %d answers: whole %d bytes, saved %d bytes (day 30: %d)"
			% [added, whole, saved, saved_30]
		)
	)
	K.check(
		fails,
		whole > SIZE_BUDGET * 2,
		"fixture: unpruned, the 60-day cache is far over the budget (%d bytes)" % whole
	)
	K.check(fails, saved < SIZE_BUDGET, "a 60-day cache saves under 1.5 MB (%d bytes)" % saved)
	K.check(
		fails,
		absf(float(saved) - float(saved_30)) < float(saved) * 0.1,
		"and it stops growing: day 30 saves %d bytes, day 60 %d" % [saved_30, saved]
	)
	# Both copies a save carries (the top-level client and the brain's own) fit the budget together.
	K.check(
		fails,
		saved * 2 < 3000000,
		"even the two copies a save carries (client and brain.client) stay under 3 MB"
	)
	c.queue_free()
	at_day_30.queue_free()
