extends SceneTree
## "Ask the five" (scripts/ai/arena_ask.gd, flag arena_ask): one question goes to all five mayors'
## models in parallel and the answers are only shown. The five calls are held by hand
## (support/gated_client.gd, each = true) and released in permuted orders, so the finish ranks are
## exact; the sim, the brain's logs, proposals and feed, the client's caches and the breaker are
## compared before and after; the budget (one ask per 60 s, five per game day) refuses with a
## reason, not an error; without a live call each column is the last recorded turn or the offline
## planner; a live failure shows the scrubbed error on a recorded column; the isolated role leaves
## the breaker alone through a real GmiClient transport (a 429 storm); the prompts carry the
## question and, in neutral mode, the one shared persona line; plausibility flags read the sim.
## Headless, offline. Prints AI_ASK_ALL_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
const KK := preload("res://tools/tests/fp_keyflow_kit.gd")
const LIVE := preload("res://tools/tests/support/arena_live_client.gd")
const BRAIN := preload("res://scripts/ai/city_brain.gd")
const WORDS := preload("res://scripts/fp/activity/activity_words.gd")
const TOKEN := "AI_ASK_ALL_TEST"
const QUESTION := "Your district just lost power and the treasury is at minus 1500. What do you do?"

var fails: Array[String] = []
var _now_ms: int = 0


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN)
	await process_frame
	await _check_race_and_isolation()
	await _check_budget()
	await _check_prompts()
	await _check_offline()
	await _check_failures()
	await _check_ranks_with_failures()
	await _check_timeout()
	await _check_real_client()
	await _check_city_replaced()
	_check_plausibility()
	await _check_hostile_orders()
	_check_fallback_source()
	K.finish(self, TOKEN, fails)


## A grown seed-7 city whose brain talks to a Live client that holds each call.
func _world() -> Dictionary:
	var w := SK.make_world(get_root(), 7)
	var live: LIVE = LIVE.new()
	live.name = "LiveClient"
	get_root().add_child(live)
	live.live_enabled = true
	live.each = true
	var brain: CityBrain = w["brain"]
	brain.setup(w["sim"], live)
	(w["minds"] as ResidentMinds).setup(w["sim"], w["people"], live, brain)
	K.grow(w["sim"], w["people"], 30)
	w["live"] = live
	for mi in range(D.MAYORS.size()):
		var m: Dictionary = D.MAYORS[mi]
		live.data_for[str(m["id"])] = {
			"thought": "As %s I would act fast." % str(m["name"]),
			"public_post": "%s here: on it." % str(m["model"]),
			"mood": "calm",
			"actions":
			[
				{"type": "set_tax", "r": 5 + mi, "c": 6, "i": 7},
				{"type": "build", "building": "solar_farm", "x": 5000, "y": 5000},
			],
			"propose_ordinance": "recycling" if mi == 1 else "",
			"votes": {},
		}
	return w


func _free(w: Dictionary) -> void:
	(w["live"] as Node).queue_free()
	SK.free_world(w)


func _city(sim: CitySim) -> int:
	return JSON.stringify(sim.to_dict()).hash()


## Everything the ask must leave alone, as one comparable value.
func _snapshot(w: Dictionary) -> Array:
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var client: GmiClient = w["live"]
	var ok: Array = []
	var logs: Array = []
	for mi in range(D.MAYORS.size()):
		ok.append([int(sim.mayors[mi]["actions_ok"]), int(sim.mayors[mi]["actions_rejected"])])
		logs.append(JSON.stringify(brain.mayor_state[mi]).hash())
	return [
		_city(sim),
		JSON.stringify(brain.to_dict()).hash(),
		ok,
		logs,
		JSON.stringify(brain.proposals).hash(),
		brain.day_feed.size(),
		JSON.stringify(client.session_cache).hash(),
		JSON.stringify(client.replay_cache).hash(),
		client.breaker_state(),
		client.live_outcomes.size(),
		JSON.stringify(client.stats).hash(),
	]


func _arena(w: Dictionary) -> ArenaAsk:
	var a: ArenaAsk = (w["brain"] as CityBrain).arena_asker()
	a.clock = func() -> int: return _now_ms
	return a


## The five calls held and released in three different orders: the finish ranks follow the
## release order, and nothing but the panel's data changes.
func _check_race_and_isolation() -> void:
	var w := _world()
	var live: LIVE = w["live"]
	var arena := _arena(w)
	var before := _snapshot(w)
	var orders := [[0, 1, 2, 3, 4], [4, 3, 2, 1, 0], [2, 0, 4, 1, 3]]
	var landed: Array[int] = []
	arena.answered.connect(func(r: Dictionary) -> void: landed.append(int(r["mi"])))
	for perm: Array in orders:
		_now_ms += ArenaAsk.COOLDOWN_MS + 1
		var base := live.parked.size()
		landed.clear()
		var started := arena.ask(QUESTION)
		check(bool(started.get("ok", false)), "ask %s goes out" % str(perm))
		check(
			live.parked.size() - base == D.MAYORS.size() and arena.busy(),
			"five calls are in flight at once and the run is busy"
		)
		var in_order := true
		for r in range(perm.size()):
			_now_ms += 1000 + r * 10
			live.release(base + int(perm[r]))
			var got: Dictionary = (arena.run["results"] as Array)[int(perm[r])]
			in_order = in_order and int(got.get("finish_rank", 0)) == r + 1
		check(in_order and landed == perm, "finish ranks follow the landing order %s" % str(perm))
		check(
			not arena.busy() and bool(arena.run["done"]), "the run is done after the fifth answer"
		)
	check(
		_snapshot(w) == before,
		"nothing in the city, the brain or the client changed (sim.to_dict byte-equal)"
	)
	var res: Dictionary = (arena.run["results"] as Array)[0]
	var keys_ok := true
	for k in [
		"mi",
		"model",
		"thought",
		"post",
		"actions",
		"elapsed_s",
		"finish_rank",
		"source",
		"error",
		"flags"
	]:
		keys_ok = keys_ok and res.has(k)
	check(
		keys_ok and str(res["source"]) == "live" and str(res["error"]).is_empty(),
		"a result carries the documented fields and is live"
	)
	check(float(res["elapsed_s"]) > 0.0, "elapsed_s is measured (%.2f)" % float(res["elapsed_s"]))
	check(
		not str(res["thought"]).contains("Argon") and not str(res["post"]).contains("gemini-4"),
		"text is de-branded (%s | %s)" % [res["thought"], res["post"]]
	)
	check(
		res["actions"].size() == 2 and str((res["actions"] as Array)[0]["type"]) == "set_tax",
		"the proposed actions are listed raw"
	)
	var prop: Dictionary = (arena.run["results"] as Array)[1]
	check(
		str(prop["proposal"]) == str(D.ORDINANCES["recycling"]["label"]),
		"a proposed ordinance is shown by its label"
	)
	_free(w)


func _check_budget() -> void:
	var w := _world()
	var live: LIVE = w["live"]
	live.each = false
	var sim: CitySim = w["sim"]
	var arena := _arena(w)
	_now_ms = 100000
	var first := arena.ask(QUESTION)
	check(bool(first["ok"]), "the first ask goes out")
	var second := arena.ask("And again?")
	check(
		(
			not bool(second["ok"])
			and str(second["code"]) in ["cooldown", "busy"]
			and not str(second["reason"]).is_empty()
		),
		"a second ask while the first runs is refused with a reason (%s)" % str(second.get("code"))
	)
	_now_ms += 30000
	var third := arena.ask("Still me")
	check(
		(
			not bool(third["ok"])
			and str(third["code"]) == "cooldown"
			and int(third["retry_in_s"]) == 30
		),
		"within 60 s: refused as cooldown with 30 s left (%s)" % str(third)
	)
	var asked := 1
	while asked < ArenaAsk.PER_DAY:
		_now_ms += ArenaAsk.COOLDOWN_MS + 1
		if bool(arena.ask("Question %d" % asked)["ok"]):
			asked += 1
		else:
			break
	check(asked == ArenaAsk.PER_DAY, "five asks fit in a day (%d)" % asked)
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	var sixth := arena.ask("One more")
	check(
		not bool(sixth["ok"]) and str(sixth["code"]) == "daily",
		"the sixth ask of the day is refused (%s)" % str(sixth.get("code"))
	)
	sim.day += 1
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	check(bool(arena.ask("A new day")["ok"]), "a new game day starts a new budget")
	var empty := arena.ask("   ")
	check(not bool(empty["ok"]) and str(empty["code"]) == "empty", "an empty question is refused")
	FeatureFlags.set_override("arena_ask", false)
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	var off := arena.ask("Flag off")
	FeatureFlags.set_override("arena_ask", true)
	check(not bool(off["ok"]) and str(off["code"]) == "off", "with the flag off the ask is refused")
	_free(w)


func _check_prompts() -> void:
	var w := _world()
	var live: LIVE = w["live"]
	live.each = false
	var arena := _arena(w)
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	arena.ask(QUESTION, "own")
	var own: Array[Dictionary] = live.seen.duplicate()
	live.seen.clear()
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	arena.ask(QUESTION, "neutral")
	var neutral: Array[Dictionary] = live.seen.duplicate()
	check(
		own.size() == D.MAYORS.size() and neutral.size() == D.MAYORS.size(), "five prompts per ask"
	)
	var q_ok := true
	var own_ok := true
	var neutral_ok := true
	var models_ok := true
	for mi in range(D.MAYORS.size()):
		var m: Dictionary = D.MAYORS[mi]
		for turn: Array in [own, neutral]:
			var s: Dictionary = turn[mi]
			q_ok = (
				q_ok
				and str(s["user"]).contains("OVERSEER QUESTION")
				and str(s["user"]).contains(QUESTION)
			)
			models_ok = (
				models_ok and str(s["model"]) == str(m["model"]) and str(s["agent"]) == str(m["id"])
			)
		own_ok = own_ok and str(own[mi]["system"]).begins_with(str(m["persona"]))
		neutral_ok = (
			neutral_ok
			and str(neutral[mi]["system"]).begins_with(ArenaAsk.NEUTRAL_PERSONA)
			and not str(neutral[mi]["system"]).contains(str(m["persona"]))
			and str(neutral[mi]["system"]).contains("You are one of the five elected mayors")
		)
	check(q_ok, "every prompt carries the OVERSEER QUESTION and the question text")
	check(models_ok, "each mayor's prompt goes to that mayor's own model")
	check(own_ok, "own mode keeps each mayor's persona")
	check(neutral_ok, "neutral mode swaps the persona for the one shared line, rules intact")
	var normal := (w["brain"] as CityBrain)._mayor_user_prompt(0, (w["sim"] as CitySim).day)
	check(
		str(own[0]["user"]).begins_with(normal),
		"the user prompt is the mayor's normal turn prompt with the question after it"
	)
	_free(w)


## No key: five recorded or offline columns, none live, and nothing from the network.
func _check_offline() -> void:
	var w := K.make_sim(get_root(), 7, true)
	var sim: CitySim = w["sim"]
	var client: GmiClient = w["client"]
	K.grow(sim, w["people"], 30)
	var brain: CityBrain = BRAIN.new()
	brain.name = "CityBrain"
	get_root().add_child(brain)
	brain.setup(sim, client)
	var arena := brain.arena_asker()
	arena.clock = func() -> int: return _now_ms
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	var before := _city(sim)
	check(not arena.live_possible(), "a client without a key is not live")
	var started := arena.ask(QUESTION)
	check(bool(started["ok"]) and not arena.busy(), "offline answers land at once")
	var sources: Array[String] = []
	for r: Dictionary in arena.run["results"]:
		sources.append(str(r["source"]))
	var all_off := (
		sources.size() == 5
		and sources.all(func(s: String) -> bool: return s in ["recorded", "offline"])
	)
	check(all_off, "offline: five non-live results (%s)" % str(sources))
	var recorded := sources.count("recorded")
	check(
		recorded == 5 if client.replay_cache.has("mayor|argon") else true,
		"with a replay cache each column is a recorded turn (%d)" % recorded
	)
	for r: Dictionary in arena.run["results"]:
		all_off = all_off and not str(r["thought"]).is_empty() and (r["actions"] is Array)
	check(all_off, "each offline column has a thought and a list of orders")
	check(_city(sim) == before, "offline: the sim is untouched")
	# Without a replay cache the scripted planner answers, tagged offline.
	client.replay_cache = {}
	client.session_cache = {}
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	arena.ask("Again, no recordings")
	var planner := true
	for r: Dictionary in arena.run["results"]:
		planner = planner and str(r["source"]) == "offline"
	check(planner, "no recording: the planner answers and is tagged offline")
	check(_city(sim) == before, "the planner reads the sim without drawing from it")
	brain.queue_free()
	SK.free_world(w)


func _check_failures() -> void:
	var w := _world()
	var live: LIVE = w["live"]
	live.each = false
	var key := KK.long_key()
	live.api_key = key
	live.fail["kimi"] = "HTTP 429 slow down for %s" % key
	live.fail["grok"] = "network result 13"
	var arena := _arena(w)
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	arena.ask(QUESTION)
	var by_id := {}
	for r: Dictionary in arena.run["results"]:
		by_id[str(D.MAYORS[int(r["mi"])]["id"])] = r
	var kimi: Dictionary = by_id["kimi"]
	check(
		(
			str(kimi["source"]) in ["recorded", "offline"]
			and str(kimi["error"]).begins_with("HTTP 429")
		),
		(
			"a failed call shows a fallback column with the error (%s / %s)"
			% [kimi["source"], kimi["error"]]
		)
	)
	check(not KK.leaks(str(kimi["error"]), key), "the error never carries the key")
	check(
		(
			str((by_id["argon"] as Dictionary)["source"]) == "live"
			and str(by_id["grok"]["error"]) == "network result 13"
		),
		"the other columns are unaffected"
	)
	check(not arena.busy(), "the run finishes even with failures")
	_free(w)


## Two calls fail fast, three answer later: only the live answers take places, 1st to 3rd.
func _check_ranks_with_failures() -> void:
	var w := _world()
	var live: LIVE = w["live"]
	live.fail["argon"] = "HTTP 429 slow down"
	live.fail["deepseek"] = "network result 2"
	var arena := _arena(w)
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	var base := live.parked.size()
	arena.ask(QUESTION)
	var release_order: Array[int] = []
	for mi in range(D.MAYORS.size()):
		if str(D.MAYORS[mi]["id"]) in ["argon", "deepseek"]:
			release_order.append(mi)
	for mi in [3, 2, 4, 0, 1]:
		if not release_order.has(mi):
			release_order.append(mi)
	for mi: int in release_order:
		_now_ms += 500
		live.release(base + mi)
	var live_ranks: Array[int] = []
	var failed_ranks: Array[int] = []
	for r: Dictionary in arena.run["results"]:
		if str(r["source"]) == "live":
			live_ranks.append(int(r["finish_rank"]))
		else:
			failed_ranks.append(int(r["finish_rank"]))
	live_ranks.sort()
	check(live_ranks == [1, 2, 3], "the live answers are 1st to 3rd (%s)" % str(live_ranks))
	check(failed_ranks == [0, 0], "failed columns take no place (%s)" % str(failed_ranks))
	check(int(arena.run["live_landed"]) == 3, "the run counts its live answers")
	_free(w)


## A call that never answers lands as a failed column when the time budget is spent; its late
## reply changes nothing and its slot is given back.
func _check_timeout() -> void:
	var w := _world()
	var live: LIVE = w["live"]
	var arena := _arena(w)
	arena.timeout_s = 0.3
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	var base := live.parked.size()
	arena.ask(QUESTION)
	live.release(base)
	await create_timer(0.8).timeout
	check(bool(arena.run["done"]) and not arena.busy(), "the run ends at the time budget")
	var res: Array = arena.run["results"]
	var timed_out := 0
	for r: Dictionary in res:
		if str(r["error"]).begins_with("timed out"):
			timed_out += 1
			check(
				str(r["source"]) != "live" and int(r["finish_rank"]) == 0,
				"a timed-out column is a fallback with no place"
			)
	check(timed_out == 4, "the four silent calls timed out (%d)" % timed_out)
	check(
		str(res[0]["source"]) == "live" and int(res[0]["finish_rank"]) == 1,
		"the call that answered in time keeps its place"
	)
	var before := JSON.stringify(res).hash()
	for i in range(base + 1, live.parked.size()):
		live.release(i)
	check(JSON.stringify(arena.run["results"]).hash() == before, "a late reply changes nothing")
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	check(bool(arena.ask("After the timeout")["ok"]), "the slots were given back: asking works")
	_free(w)


## Orders with a null, a list or a word where a number belongs (a model's loose JSON): no error,
## the other orders keep their flags, and nothing non-numeric reaches the page.
func _check_hostile_orders() -> void:
	var w := _world()
	var sim: CitySim = w["sim"]
	var rect := sim.district_rect(0)
	var inside := rect.position + Vector2i(1, 1)
	var acts: Array = [
		{"type": "set_tax", "r": 5, "c": 5, "i": 5, "x": null, "y": null},
		{"type": "build", "building": "park", "x": null, "y": [1, 2]},
		{"type": "road", "x": inside.x, "y": inside.y, "x2": null, "y2": {"a": 1}},
		{"type": "zone", "zone": "R", "x": inside.x, "y": inside.y, "w": null, "h": "2"},
		{"type": "build", "building": "solar_farm", "x": 5000, "y": 5000},
		{"type": "grant", "to": "kimi", "amount": [3]},
		{"type": "bulldoze", "x": inside.x, "y": inside.y, "w": "wide", "h": null},
	]
	var flags := ArenaAsk.plausibility(sim, 0, acts)
	var codes := {}
	for f: Dictionary in flags:
		codes["%d:%s" % [f["i"], f["code"]]] = true
	check(not flags.is_empty(), "malformed orders do not blank the flags")
	check(codes.has("4:outside"), "a well-formed order in the same answer is still flagged")
	check(codes.has("1:outside"), "a build with no usable coordinates is outside the district")
	check(
		not codes.has("0:outside") and not codes.has("3:outside") and not codes.has("6:outside"),
		"a tax order and orders at a good place are not flagged outside"
	)
	check(codes.has("5:bad_grant"), "a grant with a list for its amount is a bad grant")
	# Through a whole ask: the page's data holds numbers only.
	var live: LIVE = w["live"]
	live.each = false
	live.data_for["argon"]["actions"] = acts
	var arena := _arena(w)
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	arena.ask(QUESTION)
	var res: Dictionary = (arena.run["results"] as Array)[0]
	var shown: Array = res["actions"]
	var clean := true
	var words := true
	for a: Dictionary in shown:
		for k: String in ArenaAsk.NUMBER_KEYS:
			if a.has(k):
				clean = clean and typeof(a[k]) in [TYPE_INT, TYPE_FLOAT, TYPE_STRING]
		words = words and not WORDS.action_words(a).is_empty()
	check(clean and words, "the result's orders carry numbers or nothing, and read as words")
	check(
		not (res["flags"] as Array).is_empty() and str(res["source"]) == "live",
		"the live answer keeps its flags"
	)
	check(
		(
			not ArenaAsk.clean_action({"x": null}).has("x")
			and ArenaAsk.clean_action({"x": "12", "y": 3.5}).size() == 2
		),
		"clean_action drops a null and keeps numbers and numeric words"
	)
	_free(w)


## A recorded column is a replay-cache entry nearest today; a session's own live turn is not one.
func _check_fallback_source() -> void:
	var w := _world()
	var live: LIVE = w["live"]
	var brain: CityBrain = w["brain"]
	var arena := _arena(w)
	var day: int = brain.sim.day
	live.session_cache["mayor|argon"] = [{"day": day, "data": {"thought": "SESSION LIVE TURN"}}]
	live.replay_cache = {
		"mayor|argon":
		[
			{"day": day + 40, "data": {"thought": "far recording"}},
			{"day": day + 2, "data": {"thought": "near recording"}},
		]
	}
	var fb := arena._fallback(0, day)
	check(
		str(fb["source"]) == "recorded" and str(fb["data"]["thought"]) == "near recording",
		"recorded means the replay cache's nearest day, not the session's live turn (%s)" % str(fb)
	)
	live.replay_cache = {}
	var none := arena._fallback(0, day)
	check(
		(
			str(none["source"]) == "offline"
			and str(none["data"].get("thought", "")) != "SESSION LIVE TURN"
		),
		"with no recording the planner answers and the session's live turn is not passed off"
	)
	var long_text := "word ".repeat(80)
	var cut := ArenaAsk.clip(long_text, ArenaAsk.THOUGHT_MAX)
	check(
		(
			cut.length() <= ArenaAsk.THOUGHT_MAX
			and cut.ends_with("…")
			and ArenaAsk.clip("short", 20) == "short"
		),
		"a long text is cut with an ellipsis, a short one is left alone"
	)
	_free(w)


## The real GmiClient with a scripted transport: a 429 storm on five arena calls leaves the
## breaker, the live window, the counters and every cache alone; a good answer is not remembered.
func _check_real_client() -> void:
	var w := K.make_sim(get_root(), 7, false)
	var key := KK.long_key()
	var net := KK.client(get_root(), key)
	net.live_enabled = true
	net.sleep_ms = func(_ms: int) -> void: pass
	net.reply = {
		"ok": false,
		"error": "HTTP 429 slow",
		"retryable": true,
		"service_fail": true,
		"retry_after_ms": 0
	}
	var sim: CitySim = w["sim"]
	K.grow(sim, w["people"], 30)
	var brain: CityBrain = BRAIN.new()
	brain.name = "CityBrain"
	get_root().add_child(brain)
	brain.setup(sim, net)
	var arena := brain.arena_asker()
	arena.clock = func() -> int: return _now_ms
	var cities := _city(sim)
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	check(arena.live_possible(), "a keyed client is live")
	arena.ask(QUESTION)
	var guard := 0
	while arena.busy() and guard < 600:
		await process_frame
		guard += 1
	check(not arena.busy(), "the 429 run ends (%d frames)" % guard)
	check(net.posts >= 5, "every mayor's call went to the transport (%d posts)" % net.posts)
	check(
		net.breaker_state() == "closed" and net.breaker.failures == 0,
		"a 429 storm does not touch the breaker"
	)
	check(
		net.live_outcomes.is_empty() and int(net.stats["live_fail"]) == 0,
		"nor the live window or the failure count"
	)
	var red := 0
	for r: Dictionary in arena.run["results"]:
		if not str(r["error"]).is_empty() and str(r["source"]) != "live":
			red += 1
	check(red == 5, "five columns carry the 429 (%d)" % red)
	# Good answers: shown, but never remembered anywhere.
	net.reply = {
		"ok": true,
		"data": {"thought": "Calm.", "public_post": "On it.", "actions": []},
		"raw": "{}",
		"http": 200
	}
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	var replay_before := JSON.stringify(net.replay_cache).hash()
	arena.ask(QUESTION)
	guard = 0
	while arena.busy() and guard < 600:
		await process_frame
		guard += 1
	var live_n := 0
	for r: Dictionary in arena.run["results"]:
		live_n += 1 if str(r["source"]) == "live" else 0
	check(live_n == 5, "good replies are five live columns (%d)" % live_n)
	check(
		net.session_cache.is_empty() and JSON.stringify(net.replay_cache).hash() == replay_before,
		"no cache was written"
	)
	check(
		(
			int(net.stats["live_ok"]) == 0
			and net.live_outcomes.is_empty()
			and net.breaker_state() == "closed"
		),
		"the counters and the breaker still read zero"
	)
	check(_city(sim) == cities, "the sim is untouched")
	check(net.to_dict()["session_cache"].is_empty(), "the client's save has nothing from the ask")
	# Breaker open: no call goes out.
	_check_breaker_scopes(net, arena)
	var posts := net.posts
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	arena.ask(QUESTION)
	var none_live := true
	for r: Dictionary in arena.run["results"]:
		none_live = none_live and str(r["source"]) != "live"
	check(none_live and net.posts == posts, "breaker open: recorded or offline columns, no call")
	brain.queue_free()
	net.queue_free()
	(w["sim"] as Node).queue_free()
	(w["people"] as Node).queue_free()
	(w["client"] as Node).queue_free()


## Which breaker the panel reads: a failing residents or chatter group says nothing about the
## mayors (the panel stays live); an open mayor breaker is not live.
func _check_breaker_scopes(net: GmiClient, arena: ArenaAsk) -> void:
	for _k in range(4):
		net.breaker.record_failure()
		net.breakers.group("residents").record_failure()
	check(
		(
			net.breaker_state() == "open"
			and net.breakers.mayor_state() == "closed"
			and arena.live_possible()
		),
		"an open chatter or residents breaker leaves the panel live"
	)
	net.breakers.reset()
	for _k in range(4):
		net.breakers.group("mayor").record_failure()
	check(
		net.breaker_state() == "open" and not arena.live_possible(),
		"an open mayor breaker is not live"
	)


## New City while the five are out: the answers of the old city are dropped.
func _check_city_replaced() -> void:
	var w := _world()
	var live: LIVE = w["live"]
	var brain: CityBrain = w["brain"]
	var arena := _arena(w)
	_now_ms += ArenaAsk.COOLDOWN_MS + 1
	var heard: Array[int] = []
	arena.answered.connect(func(r: Dictionary) -> void: heard.append(int(r["mi"])))
	arena.ask(QUESTION)
	brain.setup(w["sim"], live)
	check(brain.arena == null, "New City drops the engine")
	# The budget lives on the client: the new city's engine meets the same cooldown, and the old
	# run's five calls, still in flight, count as busy so ten calls never run at once.
	var fresh := _arena(w)
	check(fresh != arena, "the new city has a new engine")
	var early := fresh.ask("Right after New City")
	check(
		not bool(early["ok"]) and str(early["code"]) == "busy",
		"New City while the old calls fly: refused as busy (%s)" % str(early.get("code"))
	)
	for i in range(live.parked.size()):
		live.release(i)
	check(heard.is_empty() and not arena.busy(), "answers for the old city land nowhere")
	var cool := fresh.ask("Once they are done")
	check(
		not bool(cool["ok"]) and str(cool["code"]) == "cooldown",
		"New City does not reset the 60 s cooldown (%s)" % str(cool.get("code"))
	)
	live.each = false
	var asked := 1
	var left_over := false
	while asked < ArenaAsk.PER_DAY + 1:
		_now_ms += ArenaAsk.COOLDOWN_MS + 1
		if not bool(fresh.ask("Q%d" % asked)["ok"]):
			left_over = true
			break
		asked += 1
		if asked == 3:
			brain.setup(w["sim"], live)
			fresh = _arena(w)
	check(
		left_over and asked == ArenaAsk.PER_DAY,
		"the daily count survives a Load in the middle of the day (%d asks fit)" % asked
	)
	_free(w)


func _check_plausibility() -> void:
	var w := SK.make_world(get_root(), 7)
	var sim: CitySim = w["sim"]
	var rect := sim.district_rect(0)
	var inside := rect.position + Vector2i(1, 1)
	sim.mayors[0]["treasury"] = 1000
	var acts: Array = [
		{"type": "build", "building": "solar_farm", "x": rect.end.x + 40, "y": rect.end.y + 40},
		{"type": "build", "building": "stadium", "x": inside.x, "y": inside.y},
		{"type": "build", "building": "park", "x": inside.x, "y": inside.y},
		{"type": "levitate", "x": inside.x, "y": inside.y},
		{"type": "build", "building": "castle", "x": inside.x, "y": inside.y},
		{"type": "set_tax", "r": 5, "c": 5, "i": 5},
		{"type": "grant", "to": "argon", "amount": 10},
		{"type": "annex", "x": -500, "y": -500},
	]
	var before := _city(sim)
	var flags := ArenaAsk.plausibility(sim, 0, acts)
	var codes := {}
	for f: Dictionary in flags:
		codes["%d:%s" % [f["i"], f["code"]]] = true
	check(codes.has("0:outside"), "a build outside the district is flagged")
	check(codes.has("1:unaffordable"), "a stadium the treasury cannot cover is flagged")
	check(
		not codes.has("2:unaffordable") and not codes.has("2:outside"),
		"an affordable park inside the district has no flag"
	)
	check(
		codes.has("3:unknown") and codes.has("4:unknown"),
		"unknown orders and buildings are flagged"
	)
	check(not codes.has("5:unknown") and not codes.has("5:unaffordable"), "taxes are free")
	check(codes.has("6:bad_grant"), "a grant to oneself is flagged")
	check(
		codes.has("7:no_plot") and codes.has("7:beyond_limit"),
		"an annex with no plot, and the eighth order, are flagged"
	)
	check(_city(sim) == before, "plausibility changes nothing")
	check(
		(
			ArenaAsk.ordinal(1) == "1st"
			and ArenaAsk.ordinal(2) == "2nd"
			and ArenaAsk.ordinal(3) == "3rd"
			and ArenaAsk.ordinal(4) == "4th"
			and ArenaAsk.ordinal(11) == "11th"
			and ArenaAsk.ordinal(22) == "22nd"
		),
		"ordinals read 1st 2nd 3rd 4th 11th 22nd"
	)
	SK.free_world(w)
