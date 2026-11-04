extends SceneTree
## The model ledger (scripts/ai/model_ledger.gd, brain.ledger): what each model has done, counted
## from GmiClient's call log and the mayors' turns. A scripted transport (the real _post behind a
## fake HTTPRequest round trip) sends replies with usage and fenced, think-tagged, comma-trailed,
## cut-off and reasoning-only JSON, HTTP 429s, a body with no JSON and a dead network, and the
## ledger must count repairs, tokens, retries, errors by class and where every answer came from;
## p50 and p95 are checked over 20 and over 60 injected records (the last 50 count); accepted
## orders come from synthetic mayor turns; the health light, the bounded event ring, the bounded
## save and its round trip (and a hostile save), the services roster, the brain's hook (attach,
## turns, save) and the flag's off switch are asserted. Headless, offline, fake transports only.
## Prints AI_LEDGER_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
const TOKEN := "AI_LEDGER_TEST"
const MODEL := "google/gemini-4-argon"
const OTHER := "XiaomiMiMo/MiMo-V2.6-Flash"
const NET := preload("res://tools/tests/support/scripted_gmi_net.gd")

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 120.0)
	await process_frame
	await _check_transport()
	_check_percentiles()
	_check_turns()
	_check_health()
	_check_ring_and_save()
	_check_hostile_save()
	_check_services()
	_check_classes()
	await _check_brain_hook()
	_check_flag_off()
	K.finish(self, TOKEN, fails)


func _net() -> NET:
	var net := NET.new()
	net.name = "NET"
	get_root().add_child(net)
	net.api_key = "test-key-not-real"
	net.live_enabled = true
	net.sleep_ms = func(_ms: int) -> void: pass
	return net


func _call(net: GmiClient, role: String, agent: String, model: String, day: int = 1) -> Dictionary:
	return await net.chat_json(
		role,
		agent,
		model,
		"system",
		"user",
		day,
		100,
		5.0,
		func() -> Dictionary: return {"fallback": true}
	)


func _msg(content: String) -> Dictionary:
	return {"content": content}


# ------------------------------------------------------------------ the real transport


func _check_transport() -> void:
	var net := _net()
	var ledger := ModelLedger.new()
	ledger.attach(net)
	var usage := {"prompt_tokens": 1200, "completion_tokens": 300}
	net.steps = [
		{
			"message": _msg('```json\n{"thought":"a","actions":[]}\n```'),
			"usage": usage,
			"finish": "stop"
		}
	]
	var res := await _call(net, "mayor", "argon", MODEL)
	check(
		str(res["source"]) == "live" and str(res["error"]).is_empty(),
		"fixture: a fenced reply is a live answer"
	)
	var row := _row(ledger, MODEL)
	check(
		int(row["calls"]) == 1 and int(row["live_ok"]) == 1,
		"a live call is counted once (%s)" % str(row.get("calls"))
	)
	check(
		int(row["tokens_in"]) == 1200 and int(row["tokens_out"]) == 300,
		"tokens come from the reply's usage (%s/%s)" % [row["tokens_in"], row["tokens_out"]]
	)
	check(
		int(row["token_calls"]) == 1 and int(row["repairs"]) == 1,
		"a fenced reply is one repair and one token call"
	)
	check(
		(row["repair_kinds"] as Dictionary).has("fenced"),
		"the repair is named: fenced (%s)" % str(row["repair_kinds"])
	)
	check(
		str(res["finish_reason"]) == "stop" and int(res["tokens_in"]) == 1200,
		"the slim record keeps usage and finish_reason"
	)
	check(not (res["repairs"] as Array).is_empty(), "the slim record keeps the repairs")
	# <think>, a trailing comma, a cut-off reply and a reasoning-only reply, one call each.
	var cases := [
		["think_tag", {"message": _msg('<think>hmm {x}</think>{"thought":"t"}')}],
		["trailing_comma", {"message": _msg('{"thought":"t","actions":[],}')}],
		[
			"salvaged",
			{
				"message": _msg('{"thought":"f","actions":[{"type":"zone","x":1},{"ty'),
				"finish": "length"
			}
		],
		["reasoning_only", {"message": {"content": "", "reasoning_content": '{"thought":"c"}'}}],
	]
	for c: Array in cases:
		net.steps = [c[1]]
		await _call(net, "mayor", "argon", MODEL)
		row = _row(ledger, MODEL)
		var kinds: Dictionary = row["repair_kinds"]
		check(kinds.has(str(c[0])), "repair counted: %s (%s)" % [c[0], str(kinds)])
	row = _row(ledger, MODEL)
	check(
		int(row["repairs"]) == 5 and int(row["live_ok"]) == 5,
		"five live answers, five of them repaired (%s/%s)" % [row["repairs"], row["live_ok"]]
	)
	check(int(row["truncated"]) == 1, "finish_reason length is counted as truncated")
	check(
		int(row["token_calls"]) == 1,
		"an answer with no usage adds no tokens (%s)" % row["token_calls"]
	)
	# A clean reply is no repair.
	net.steps = [{"message": _msg('{"thought":"clean"}'), "usage": usage, "finish": "stop"}]
	await _call(net, "mayor", "argon", MODEL)
	check(int(_row(ledger, MODEL)["repairs"]) == 5, "a clean reply needs no repair")
	await _check_failures(net, ledger)


func _check_failures(net: NET, ledger: ModelLedger) -> void:
	var row: Dictionary = {}
	# Failures: 429 (retried twice, then the planner answers), no JSON, a dead network.
	net.steps = [{"http": 429, "body": "slow down"}]
	var failed := await _call(net, "news", "zz", OTHER)
	row = _row(ledger, OTHER)
	check(
		str(failed["source"]) == "heuristic" and int(row["live_fail"]) == 1,
		"a 429 is a failed live call and the planner answers (%s)" % failed["source"]
	)
	check(
		int(row["retries"]) == 2 and int(failed["attempts"]) == 3,
		"its two retries are counted (%s)" % row["retries"]
	)
	check(
		int(row["fallback"]) == 1 and int((row["errors"] as Dictionary).get("429", 0)) == 1,
		"fallback and the 429 class (%s)" % str(row["errors"])
	)
	net.steps = [{"message": _msg("I cannot help with that.")}]
	await _call(net, "news", "zz", OTHER)
	net.steps = [{"result": HTTPRequest.RESULT_CANT_CONNECT, "http": 0}]
	await _call(net, "news", "zz", OTHER)
	row = _row(ledger, OTHER)
	var errors: Dictionary = row["errors"]
	check(
		int(errors.get("no JSON", 0)) == 1 and int(errors.get("network", 0)) == 1,
		"errors by class: 429, no JSON, network (%s)" % str(errors)
	)
	check(
		int(row["live_fail"]) == 3 and int(row["calls"]) == 3,
		"three failed calls (%s)" % row["live_fail"]
	)
	check(str(row["health"]) == "red", "the last two live calls failed: red (%s)" % row["health"])
	# A replayed answer and an offline planner answer.
	net.session_cache["news|gazette"] = [{"day": 1, "data": {"headline": "replayed"}}]
	net.live_enabled = false
	var rep := await _call(net, "news", "gazette", OTHER)
	var off := await _call(net, "citizens", "zz", OTHER)
	row = _row(ledger, OTHER)
	check(
		str(rep["source"]) == "cache" and str(off["source"]) == "heuristic",
		"fixture: a cache hit and a planner answer"
	)
	check(
		int(row["replay"]) == 1 and int(row["offline"]) == 1,
		"replay and offline are counted apart (%s/%s)" % [row["replay"], row["offline"]]
	)
	# live_json calls that never leave: offline, and a breaker that is open.
	await net.live_json("residents", "plans", OTHER, "s", "u", 1, 100, 5.0)
	row = _row(ledger, OTHER)
	check(
		int(row["calls"]) == 6 and int(row["offline"]) == 2,
		"a skipped live_json call is counted as offline (%s/%s)" % [row["calls"], row["offline"]]
	)
	check(
		(row["roles"] as Dictionary).get("residents", 0) == 1,
		"the role mix keeps it (%s)" % str(row["roles"])
	)
	net.live_enabled = true
	for _i in range(4):
		net.breakers.breaker_for("residents").record_failure()
	var skipped: Dictionary = await net.live_json(
		"residents", "plans", OTHER, "s", "u", 1, 100, 5.0
	)
	row = _row(ledger, OTHER)
	check(
		str(skipped["error"]) == "circuit open" and int(row["fallback"]) == 4,
		"an open breaker's skip is a fallback (%s)" % row["fallback"]
	)
	check(int((row["errors"] as Dictionary).get("skipped", 0)) == 0, "a skip is not an error class")
	# The mayors' own rows come from their own calls.
	var mayors := ledger.mayor_rows()
	check(
		int(mayors[0]["calls"]) == 6 and int(mayors[1]["calls"]) == 0,
		"the mayor row counts that mayor's calls (%s)" % mayors[0]["calls"]
	)
	check(str(mayors[1]["health"]) == "idle", "a mayor not called yet is idle")
	# The headers rule of the web build is untouched by any of this.
	var hdrs := GmiClient.request_headers("k", "r", "t", true)
	check(
		(
			hdrs.size() == 2
			and hdrs[0].begins_with("Authorization")
			and hdrs[1].begins_with("Content-Type")
		),
		"web headers stay Authorization + Content-Type only"
	)
	net.queue_free()


func _row(ledger: ModelLedger, model: String) -> Dictionary:
	for r: Dictionary in ledger.snapshot():
		if str(r["model"]) == model:
			return r
	return {
		"calls": 0,
		"live_ok": 0,
		"live_fail": 0,
		"replay": 0,
		"fallback": 0,
		"offline": 0,
		"retries": 0,
		"tokens_in": 0,
		"tokens_out": 0,
		"token_calls": 0,
		"repairs": 0,
		"truncated": 0,
		"errors": {},
		"repair_kinds": {},
		"roles": {},
		"health": "idle"
	}


# ------------------------------------------------------------------ percentiles


func _live(ledger: ModelLedger, model: String, ms: int, role: String = "news") -> void:
	ledger.note_call(
		{
			"role": role,
			"agent": "gazette",
			"model": model,
			"source": "live",
			"latency_ms": ms,
			"attempts": 1
		}
	)


func _check_percentiles() -> void:
	var ledger := ModelLedger.new()
	for i in range(1, 21):
		_live(ledger, OTHER, i * 1000)
	var row := _row(ledger, OTHER)
	check(
		int(row["p50_ms"]) == 10000 and int(row["p95_ms"]) == 19000,
		"p50 and p95 over 20 records: nearest rank (%s/%s)" % [row["p50_ms"], row["p95_ms"]]
	)
	check(
		int(row["last_ms"]) == 20000 and int(row["mean_ms"]) == 10500 and int(row["n_live"]) == 20,
		"last, mean and n (%s/%s/%s)" % [row["last_ms"], row["mean_ms"], row["n_live"]]
	)
	for i in range(21, 61):
		_live(ledger, OTHER, i * 1000)
	row = _row(ledger, OTHER)
	check(
		int(row["p50_ms"]) == 35000 and int(row["p95_ms"]) == 58000,
		"only the last 50 answers count (%s/%s)" % [row["p50_ms"], row["p95_ms"]]
	)
	check(
		int(row["n_live"]) == 60 and int((ledger.models[OTHER]["lat"] as Array).size()) == 50,
		"n counts all, the list keeps 50"
	)
	var few := ModelLedger.new()
	_live(few, OTHER, 8000)
	_live(few, OTHER, 12000)
	row = _row(few, OTHER)
	check(
		int(row["p95_ms"]) == -1 and int(row["p50_ms"]) == 8000,
		"a p95 needs %d live answers (%s)" % [ModelLedger.P95_MIN_CALLS, row["p95_ms"]]
	)
	check(
		ModelLedger.percentile([], 50.0) == -1 and ModelLedger.percentile([7], 95.0) == 7,
		"percentile of nothing and of one"
	)
	# Replay latency never reaches the percentiles: only live answers are timed.
	few.note_call(
		{
			"role": "news",
			"agent": "gazette",
			"model": OTHER,
			"source": "cache",
			"latency_ms": 99999,
			"attempts": 0
		}
	)
	check(
		int(_row(few, OTHER)["last_ms"]) == 12000 and int(_row(few, OTHER)["replay"]) == 1,
		"a replayed answer is not timed"
	)
	check(
		ModelLedger.seconds_text(11200) == "11.2 s" and ModelLedger.seconds_text(-1) == "-",
		"seconds_text"
	)


# ------------------------------------------------------------------ mayor turns


func _entry(source: String, acts: Array, err: String = "") -> Dictionary:
	var applied: Array = []
	for a: Array in acts:
		applied.append(
			{"action": {"type": a[0]}, "ok": bool(a[1]), "reason": "" if bool(a[1]) else "blocked"}
		)
	return {
		"day": 3,
		"source": source,
		"latency_ms": 9000,
		"error": err,
		"model": MODEL,
		"actions": applied
	}


func _check_turns() -> void:
	var ledger := ModelLedger.new()
	ledger.note_turn(
		0, _entry("live", [["road", true], ["zone", true], ["zone", true], ["build", false]])
	)
	ledger.note_turn(0, _entry("cache", [["road", true]]))
	ledger.note_turn(0, _entry("heuristic", [["build", true]], "HTTP 503 down"))
	ledger.note_turn(0, _entry("heuristic", []))
	ledger.note_turn(7, _entry("live", [["road", true]]))
	ledger.note_turn(-1, _entry("live", [["road", true]]))
	var r: Dictionary = ledger.mayor_rows()[0]
	check(
		(
			int(r["turns_live"]) == 1
			and int(r["turns_replay"]) == 1
			and int(r["turns_fallback"]) == 1
			and int(r["turns_offline"]) == 1
		),
		(
			"turns by where the answer came from (%s)"
			% str([r["turns_live"], r["turns_replay"], r["turns_fallback"], r["turns_offline"]])
		)
	)
	check(
		int(r["orders_ok"]) == 4 and int(r["orders_rejected"]) == 1 and int(r["accept_pct"]) == 80,
		(
			"accepted share from live and replayed orders; the planner's are not the model's (%s%%)"
			% r["accept_pct"]
		)
	)
	var mix: Dictionary = r["mix"]
	check(
		(
			int(mix.get("road", 0)) == 2
			and int(mix.get("zone", 0)) == 2
			and int(mix.get("build", 0)) == 1
		),
		"the order mix (%s)" % str(mix)
	)
	check(int(ledger.mayor_rows()[1]["accept_pct"]) == -1, "no order, no accept share")
	ledger.note_call(
		{
			"role": "mayor",
			"agent": "argon",
			"model": MODEL,
			"source": "live",
			"latency_ms": 5000,
			"attempts": 1
		}
	)
	check(
		int(_row(ledger, MODEL)["tokens_in"]) == 0 and int(_row(ledger, MODEL)["token_calls"]) == 0,
		"no usage reported, no tokens"
	)
	# Offline / replay: accepted share is still real, speed is not claimed.
	check(
		ledger.events.size() == 5,
		"turns and calls land in the event ring (%d)" % ledger.events.size()
	)


# ------------------------------------------------------------------ health


func _fail(ledger: ModelLedger, model: String) -> void:
	ledger.note_call(
		{
			"role": "news",
			"agent": "gazette",
			"model": model,
			"source": "heuristic",
			"latency_ms": 100,
			"attempts": 3,
			"error": "HTTP 503 down"
		}
	)


func _check_health() -> void:
	var l := ModelLedger.new()
	check(ModelLedger.health_of({}) == "idle", "no call: idle")
	l.note_call({"role": "news", "agent": "g", "model": "a/a", "source": "cache", "attempts": 0})
	check(str(_row(l, "a/a")["health"]) == "grey", "only replay: grey")
	_live(l, "b/b", 1000)
	_live(l, "b/b", 1200)
	check(str(_row(l, "b/b")["health"]) == "green", "clean live answers: green")
	_fail(l, "b/b")
	check(str(_row(l, "b/b")["health"]) == "amber", "one failure: amber")
	_fail(l, "b/b")
	check(str(_row(l, "b/b")["health"]) == "red", "two failures in a row: red")
	_live(l, "b/b", 900)
	check(
		str(_row(l, "b/b")["health"]) == "amber",
		"recovering: amber until the failures leave the last five"
	)
	for _i in range(5):
		_live(l, "b/b", 900)
	check(str(_row(l, "b/b")["health"]) == "green", "five clean answers: green again")
	_live(l, "c/c", ModelLedger.SLOW_MS + 5000)
	check(
		str(_row(l, "c/c")["health"]) == "green",
		(
			"one slow answer is not a pattern: green (a p95 needs %d answers)"
			% ModelLedger.P95_MIN_CALLS
		)
	)
	for _i in range(ModelLedger.P95_MIN_CALLS - 1):
		_live(l, "c/c", ModelLedger.SLOW_MS + 5000)
	check(str(_row(l, "c/c")["health"]) == "amber", "very slow answers, five of them: amber")
	l.note_call(
		{
			"role": "news",
			"agent": "g",
			"model": "d/d",
			"source": "live",
			"latency_ms": 900,
			"attempts": 2
		}
	)
	check(str(_row(l, "d/d")["health"]) == "amber", "a retried answer: amber")


# ------------------------------------------------------------------ ring and save


func _check_ring_and_save() -> void:
	var ledger := ModelLedger.new()
	for i in range(450):
		ledger.note_call(
			{
				"role": "mayor" if i % 3 == 0 else "news",
				"agent": "argon",
				"model": "m/%d" % (i % 14),
				"source": "live",
				"latency_ms": 1000 + i,
				"attempts": 1,
				"tokens_in": 100,
				"tokens_out": 50,
				"repairs": ["fenced"] if i % 5 == 0 else []
			}
		)
	check(
		ledger.events.size() == ModelLedger.MAX_EVENTS,
		"the event ring is bounded (%d)" % ledger.events.size()
	)
	var seqs: Array = ledger.events.map(func(e: Dictionary) -> int: return int(e["seq"]))
	check(
		int(seqs[0]) == 51 and int(seqs[-1]) == 450,
		"newest 400 kept, in order (%s..%s)" % [seqs[0], seqs[-1]]
	)
	check(ledger.recent_events(10).size() == 10, "recent_events")
	var saved := ledger.to_dict()
	var stamped := (saved["events"] as Array).any(func(e: Dictionary) -> bool: return e.has("at"))
	check(
		not stamped, "a save holds no wall-clock stamp (two runs of one seed save the same bytes)"
	)
	var twin := ModelLedger.new()
	for e: Dictionary in ledger.events:
		twin.events.append(e.duplicate(true))
		twin.events[-1]["at"] = int(e["at"]) + 12345
	twin.models = ledger.models.duplicate(true)
	twin.agents = ledger.agents.duplicate(true)
	twin.svc = ledger.svc.duplicate(true)
	twin.turns = ledger.turns.duplicate(true)
	check(
		JSON.stringify(twin.to_dict()) == JSON.stringify(saved),
		"the same calls at other times: the same save"
	)
	var text := JSON.stringify(saved)
	check(
		text.length() < 40000,
		"the saved ledger is small (%d bytes for 14 models and 450 calls)" % text.length()
	)
	check(
		(saved["events"] as Array).size() == 40 and ModelLedger.SAVED_EVENTS == 40,
		"a save keeps the newest 40 events (%d)" % (saved["events"] as Array).size()
	)
	var back := ModelLedger.new()
	back.from_dict(JSON.parse_string(text))
	var a := ledger.snapshot()
	var b := back.snapshot()
	var same := a.size() == b.size()
	for k in range(mini(a.size(), b.size())):
		for key: String in [
			"model",
			"calls",
			"live_ok",
			"p50_ms",
			"p95_ms",
			"last_ms",
			"mean_ms",
			"repairs",
			"tokens_in",
			"tokens_out",
			"health"
		]:
			if str(a[k][key]) != str(b[k][key]):
				same = false
				print("  differs: %s %s %s vs %s" % [a[k]["model"], key, a[k][key], b[k][key]])
	check(same, "a JSON round trip gives the same rows")
	check(back.events.size() == 40 and int(back.events[-1]["seq"]) == 450, "events come back")
	var again := JSON.stringify(back.to_dict()).length()
	check(
		again <= text.length(), "saving again does not grow it (%d vs %d)" % [again, text.length()]
	)
	# Many more calls change numbers, not the size.
	for i in range(2000):
		_live(ledger, "m/%d" % (i % 14), 1000 + i)
	check(
		JSON.stringify(ledger.to_dict()).length() < text.length() + 6000,
		"2000 more calls add numbers, not size (%d)" % JSON.stringify(ledger.to_dict()).length()
	)
	# A ledger fed with endless distinct model ids stays bounded.
	var wide := ModelLedger.new()
	for i in range(200):
		_live(wide, "vendor/model-%d" % i, 1000)
	check(
		wide.models.size() == ModelLedger.MAX_MODELS,
		"distinct models are capped (%d)" % wide.models.size()
	)
	wide.clear()
	check(
		wide.models.is_empty() and wide.events.is_empty() and wide.snapshot().is_empty(),
		"clear forgets everything"
	)


func _check_hostile_save() -> void:
	var l := ModelLedger.new()
	var hostile: Array = [
		{},
		{"models": 5, "agents": "x", "turns": "x", "events": 3},
		{
			"models":
			{
				"a/b": 5,
				"c/d":
				{
					"calls": "NaN",
					"lat": [1, "a", null, 2.5],
					"recent": "x",
					"errors": {"429": "many"},
					"roles": []
				}
			}
		},
		{
			"turns": [5, {"live": "x", "mix": {"road": 3, "zone": "z"}}],
			"events": [1, {"seq": "a", "repairs": "no"}]
		},
		{"models": {"x": {"calls": 1e30, "last_ms": -5e9}}},
	]
	var ok := true
	for h: Dictionary in hostile:
		l.from_dict(h)
		for r: Dictionary in l.snapshot():
			ok = ok and int(r["calls"]) >= 0 and int(r["calls"]) <= 1000000000
		l.mayor_rows()
		l.services()
	check(ok, "hostile saves load without error and stay in range")
	var many := {"models": {}, "events": []}
	for i in range(300):
		many["models"]["m/%d" % i] = {"calls": 1}
		many["events"].append({"seq": i})
	l.from_dict(many)
	check(
		l.models.size() <= ModelLedger.MAX_MODELS and l.events.size() <= ModelLedger.SAVED_EVENTS,
		"a save cannot make it bigger than its bounds (%d, %d)" % [l.models.size(), l.events.size()]
	)


# ------------------------------------------------------------------ services and classes


func _check_services() -> void:
	var l := ModelLedger.new()
	var idle := l.services()
	var models: Array = idle.map(func(r: Dictionary) -> String: return str(r["model"]))
	var want := ["MiniMaxAI/MiniMax-M3", "XiaomiMiMo/MiMo-V2.6-Flash", "openai/gpt-6-luna"]
	var has_all := true
	for m: String in want:
		has_all = has_all and models.has(m)
	check(has_all, "the roster lists the support agents before any call (%d rows)" % idle.size())
	check(
		models.has("deepseek-ai/DeepSeek-V4.1-Flash") and models.has("Qwen/Qwen3.8-Flash"),
		"resident and chat models are on it"
	)
	var seen := {}
	var dup := false
	for m: String in models:
		dup = dup or seen.has(m)
		seen[m] = true
	check(not dup, "one row per model, however many jobs it has")
	_live(l, "MiniMaxAI/MiniMax-M3", 4000, "citizens")
	_live(l, "MiniMaxAI/MiniMax-M3", 6000, "inspector")
	_live(l, "MiniMaxAI/MiniMax-M3", 2000, "residents")
	_live(l, "google/gemini-4-argon", 9000, "mayor")
	var rows := l.services()
	check(
		str(rows[0]["model"]) == "MiniMaxAI/MiniMax-M3" and int(rows[0]["calls"]) == 3,
		"the busiest model first, with its calls (%s)" % rows[0]["calls"]
	)
	var mix := str(rows[0]["mix"])
	check(
		(
			mix.contains("Citizen Voices 1")
			and mix.contains("Street Inspector 1")
			and mix.contains("Residents 1")
		),
		"the job mix names the jobs (%s)" % mix
	)
	var argon_listed := false
	for r: Dictionary in rows:
		argon_listed = argon_listed or str(r["model"]) == "google/gemini-4-argon"
	check(not argon_listed, "a model that only sits in a mayor's chair is not a service")
	_live(l, "other/new-model", 1000, "chatter")
	var extra := l.services().filter(
		func(r: Dictionary) -> bool: return str(r["model"]) == "other/new-model"
	)
	check(
		extra.size() == 1 and str(extra[0]["mix"]) == "Chat 1",
		"an unlisted model with calls still gets a row (%s)" % str(extra)
	)
	check(
		(
			ModelLedger.short_name("deepseek-ai/DeepSeek-V4-Flash-0731") == "DeepSeek-V4-Flash"
			and ModelLedger.short_name("openai/gpt-6-luna") == "gpt-6-luna"
		),
		"short_name"
	)


func _check_classes() -> void:
	var cases := {
		"": "",
		"HTTP 429 slow down": "429",
		"HTTP 503 ": "503",
		"network result 2": "network",
		"request error 31": "network",
		"no JSON in reply": "no JSON",
		"no choices": "bad reply",
		"bad response body": "bad reply",
		"offline": "skipped",
		"circuit open": "skipped",
		"no free slot": "skipped",
		"weird": "other",
		"HTTP x": "other",
	}
	var bad: Array[String] = []
	for k: String in cases.keys():
		if ModelLedger.error_class(k) != str(cases[k]):
			bad.append("%s -> %s" % [k, ModelLedger.error_class(k)])
	check(bad.is_empty(), "error classes (%s)" % str(bad))
	var kinds := GmiReply.classify('```json\n<think>x</think>{"a":1,}\n```', true, true)
	check(
		kinds == ["think_tag", "fenced", "trailing_comma", "salvaged", "reasoning_only"],
		"every repair has its name, in order (%s)" % str(kinds)
	)
	check(
		GmiReply.classify('{"a":"x, }"}', false, false).is_empty(),
		"a comma inside a string is not a repair"
	)
	check(
		GmiReply.classify('{"a":NaN,"b":1}', false, false) == ["non_finite"],
		"NaN is named non_finite, not a trailing comma"
	)
	check(
		(
			GmiReply.classify('{"a":Infinity,"b":[1,]}', false, false)
			== ["trailing_comma", "non_finite"]
		),
		"a comma and an Infinity are both named"
	)
	check(
		(
			GmiReply.classify('<think>```json\n{"x":1}\n```</think>{"a":1}', false, false)
			== ["think_tag"]
		),
		"a fence inside the think block is not the answer's"
	)
	check(
		(
			GmiReply.classify('<think>hm</think>```json\n{"a":1}\n```', false, false)
			== ["think_tag", "fenced"]
		),
		"a think block and a fence after it are both repairs"
	)
	var usage := GmiReply.usage_of(
		{"usage": {"prompt_tokens": 10, "completion_tokens": "x"}}, {"finish_reason": "length"}
	)
	check(
		(
			int(usage["tokens_in"]) == 10
			and int(usage["tokens_out"]) == -1
			and usage["finish_reason"] == "length"
		),
		"usage_of reads what is there (%s)" % str(usage)
	)
	check(int(GmiReply.usage_of({}, null)["tokens_in"]) == -1, "no usage: -1")


# ------------------------------------------------------------------ the brain's hook


func _check_brain_hook() -> void:
	var w := SK.make_world(get_root(), 7)
	var brain: CityBrain = w["brain"]
	var client: GmiClient = w["client"]
	var m: Dictionary = D.MAYORS[1]
	var res: Dictionary = await client.chat_json(
		"mayor",
		str(m["id"]),
		str(m["model"]),
		"s",
		"u",
		1,
		100,
		5.0,
		func() -> Dictionary: return {"thought": "offline plan", "actions": []}
	)
	check(
		str(res["source"]) in ["cache", "heuristic"],
		"fixture: an offline client answers from the recording or the planner"
	)
	var rows := brain.ledger.mayor_rows()
	check(
		int(rows[1]["calls"]) == 1 and int(rows[1]["replay"]) + int(rows[1]["offline"]) == 1,
		"the brain's ledger listens to its client (%s)" % rows[1]["calls"]
	)
	brain._land_mayor(
		1,
		1,
		{
			"data":
			{
				"thought": "t",
				"public_post": "p",
				"mood": "calm",
				"actions":
				[
					{"type": "set_tax", "r": 5, "c": 6, "i": 7},
					{"type": "build", "building": "solar_farm", "x": 5000, "y": 5000}
				]
			},
			"source": "live",
			"latency_ms": 4321,
			"error": ""
		}
	)
	rows = brain.ledger.mayor_rows()
	check(
		(
			int(rows[1]["turns_live"]) == 1
			and int(rows[1]["orders_ok"]) + int(rows[1]["orders_rejected"]) == 2
		),
		(
			"mayor_decided feeds the turn: orders counted (%s ok, %s refused)"
			% [rows[1]["orders_ok"], rows[1]["orders_rejected"]]
		)
	)
	check(
		int(rows[1]["orders_rejected"]) >= 1, "the sim's refusal of an impossible order is counted"
	)
	var sim: CitySim = w["sim"]
	var m1: Dictionary = sim.mayors[1]
	check(
		(
			int(rows[1]["orders_ok"]) == int(m1.get("actions_ok", 0))
			and int(rows[1]["orders_rejected"]) == int(m1.get("actions_rejected", 0))
		),
		(
			"the ledger and the sim agree on orders (%s/%s vs %s/%s)"
			% [
				rows[1]["orders_ok"],
				rows[1]["orders_rejected"],
				m1.get("actions_ok"),
				m1.get("actions_rejected")
			]
		)
	)
	# Save: the section is there, small, and loads back; an old save without it loads too.
	var d := brain.to_dict()
	check(d.has("ledger") and typeof(d["ledger"]) == TYPE_DICTIONARY, "the brain saves its ledger")
	var w2 := SK.make_world(get_root(), 7)
	var brain2: CityBrain = w2["brain"]
	brain2.from_dict(JSON.parse_string(JSON.stringify(d)))
	check(
		(
			int(brain2.ledger.mayor_rows()[1]["turns_live"]) == 1
			and int(brain2.ledger.mayor_rows()[1]["calls"]) == 1
		),
		"a load brings the ledger back"
	)
	var old := d.duplicate(true)
	old.erase("ledger")
	brain2.from_dict(old)
	check(
		int(brain2.ledger.mayor_rows()[1]["calls"]) == 0,
		"a save from before the ledger loads and starts it empty"
	)
	var bad := d.duplicate(true)
	bad["ledger"] = "junk"
	brain2.from_dict(bad)
	check(brain2.ledger.snapshot().is_empty(), "a damaged ledger section is ignored")
	# setup() (New City) starts a fresh ledger and keeps listening.
	brain.setup(w["sim"], client)
	check(brain.ledger.snapshot().is_empty(), "a new city starts with an empty ledger")
	await client.chat_json(
		"mayor", "argon", MODEL, "s", "u", 1, 100, 5.0, func() -> Dictionary: return {"actions": []}
	)
	check(brain.ledger.snapshot().size() == 1, "and it listens again")
	var rev := brain.ledger.revision
	brain.ledger.note_call(
		{"role": "news", "model": OTHER, "source": "live", "latency_ms": 1, "attempts": 1}
	)
	check(brain.ledger.revision == rev + 1, "a note bumps the revision a view compares")
	for n: Node in [
		w["sim"],
		w["people"],
		w["minds"],
		client,
		brain,
		w2["sim"],
		w2["people"],
		w2["minds"],
		w2["client"],
		brain2
	]:
		if is_instance_valid(n):
			n.queue_free()


func _check_flag_off() -> void:
	FeatureFlags.set_override("model_ledger", false)
	var net := GmiClient.new()
	var l := ModelLedger.new()
	l.attach(net)
	l.note_call({"role": "news", "model": OTHER, "source": "live", "latency_ms": 1, "attempts": 1})
	l.note_turn(0, _entry("live", [["road", true]]))
	check(
		l.snapshot().is_empty() and int(l.mayor_rows()[0]["turns_live"]) == 0,
		"flag model_ledger off: nothing is counted"
	)
	check(not net.call_logged.is_connected(l.note_call), "and it does not even listen")
	FeatureFlags.set_override("model_ledger", true)
	l.attach(net)
	check(
		net.call_logged.is_connected(l.note_call) and net.call_skipped.is_connected(l.note_call),
		"flag on: it listens to calls and skips"
	)
	l.attach(null)
	check(not net.call_logged.is_connected(l.note_call), "attach(null) stops listening")
	net.free()
