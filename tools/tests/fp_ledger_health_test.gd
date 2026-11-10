extends SceneTree
## The honesty of the model ledger's health light and its books (scripts/ai/model_ledger.gd): a
## repair that costs the city nothing (a code fence, a <think> block) leaves a model green while a
## cut-off or reasoning-only answer, a retry or a failure turns it amber for five outcomes only; a
## row that only had scripted answers reads "scripted", not "grey" (replay); a call still in flight
## when New City replaced the city is not counted in the new city's ledger; a call that waited for a
## slot past its timeout is counted as a scripted answer (call_skipped, "no free slot"); and with
## the model_ledger flag off a ledger an older save carried feeds nothing and is passed on
## untouched. Headless, offline, a scripted transport. Prints FP_LEDGER_HEALTH_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const NET := preload("res://tools/tests/support/scripted_gmi_net.gd")
const TOKEN := "FP_LEDGER_HEALTH_TEST"
const MODEL := "google/gemini-4-argon"
const OTHER := "XiaomiMiMo/MiMo-V2.6-Flash"

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 60.0)
	await process_frame
	_check_health_words()
	await _check_stale_calls()
	await _check_no_free_slot()
	_check_flag_off_old_save()
	_check_bounds()
	K.finish(self, TOKEN, fails)


func _net() -> NET:
	var net := NET.new()
	net.name = "NET"
	get_root().add_child(net)
	net.api_key = "test-key-not-real"
	net.live_enabled = true
	net.sleep_ms = func(_ms: int) -> void: pass
	return net


## A call left in flight: its answer lands in results.
func _spawn(net: GmiClient, results: Array[Dictionary]) -> void:
	results.append(await _call(net, "news", "gazette", OTHER))


func _msg(content: String) -> Dictionary:
	return {"content": content}


func _call(net: GmiClient, role: String, agent: String, model: String) -> Dictionary:
	return await net.chat_json(
		role,
		agent,
		model,
		"system",
		"user",
		1,
		100,
		5.0,
		func() -> Dictionary: return {"fallback": true}
	)


func _row(ledger: ModelLedger, model: String) -> Dictionary:
	for r: Dictionary in ledger.snapshot():
		if str(r["model"]) == model:
			return r
	return {"calls": 0, "health": "idle", "fallback": 0, "live_fail": 0, "errors": {}, "repairs": 0}


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


func _entry(source: String, acts: Array) -> Dictionary:
	var applied: Array = []
	for a: Array in acts:
		applied.append({"action": {"type": a[0]}, "ok": bool(a[1]), "reason": ""})
	return {
		"day": 3,
		"source": source,
		"latency_ms": 9000,
		"error": "",
		"model": MODEL,
		"actions": applied
	}


## Repairs that cost the city nothing (a code fence, a <think> block, a trailing comma) are a
## model's house style, not a fault: the light stays green. A cut-off or reasoning-only answer, a
## retry or a failure turns it amber, for the last five outcomes only. Scripted-only rows are
## "scripted", not "grey" (that is for a recorded answer).
func _check_health_words() -> void:
	var l := ModelLedger.new()
	for kind: String in ["fenced", "think_tag", "trailing_comma"]:
		for _i in range(3):
			l.note_call(
				{
					"role": "news",
					"agent": "g",
					"model": "h/" + kind,
					"source": "live",
					"latency_ms": 900,
					"attempts": 1,
					"repairs": [kind]
				}
			)
		var row := _row(l, "h/" + kind)
		check(
			str(row["health"]) == "green" and int(row["repairs"]) == 3,
			"%s every time: counted as a repair, still green (%s)" % [kind, row["health"]]
		)
	for kind: String in ["salvaged", "reasoning_only"]:
		for i in range(6):
			l.note_call(
				{
					"role": "news",
					"agent": "g",
					"model": "w/" + kind,
					"source": "live",
					"latency_ms": 900,
					"attempts": 1,
					"repairs": [kind] if i == 0 else []
				}
			)
			if i == 0:
				check(str(_row(l, "w/" + kind)["health"]) == "amber", "a %s answer: amber" % kind)
		check(
			str(_row(l, "w/" + kind)["health"]) == "green",
			"%s leaves the light after %d clean answers" % [kind, ModelLedger.HEALTH_WINDOW]
		)
	# Nothing live: a recorded answer is grey, the scripted planner's alone is "scripted".
	for _i in range(2):
		l.note_call(
			{"role": "news", "agent": "g", "model": "s/s", "source": "heuristic", "attempts": 0}
		)
	check(str(_row(l, "s/s")["health"]) == "scripted", "scripted answers only: scripted")
	l.note_call({"role": "news", "agent": "g", "model": "s/s", "source": "cache", "attempts": 0})
	check(str(_row(l, "s/s")["health"]) == "grey", "a recorded answer among them: grey")


## A call that was in flight when the city was replaced lands in the new city's books only if the
## ledger counts it: it must not (the client numbers every call; clear() remembers the last one).
func _check_stale_calls() -> void:
	var net := _net()
	var l := ModelLedger.new()
	l.attach(net, true)
	net.hold = true
	var landed: Array[Dictionary] = []
	_spawn(net, landed)
	await process_frame
	check(
		net.last_seq() == 1 and net.trips == 0,
		"fixture: one call is in flight (%d)" % net.last_seq()
	)
	l.attach(net, true)
	net.steps = [{"message": _msg('{"headline":"x"}')}]
	net.hold = false
	for _i in range(20):
		if not landed.is_empty():
			break
		await process_frame
	check(landed.size() == 1, "fixture: the held call landed once released")
	check(l.snapshot().is_empty(), "the previous city's call lands after New City: not counted")
	await _call(net, "news", "gazette", OTHER)
	check(
		_row(l, OTHER)["calls"] == 1,
		"the new city's own call is counted (%s)" % _row(l, OTHER)["calls"]
	)
	# Load clears too; a record without a number (a test, a replay of an old log) is counted.
	l.from_dict({})
	_live(l, OTHER, 100)
	check(int(_row(l, OTHER)["calls"]) == 1, "after from_dict a record without a number is counted")
	l.note_call(
		{"role": "news", "model": OTHER, "source": "live", "latency_ms": 5, "attempts": 1, "seq": 1}
	)
	check(int(_row(l, OTHER)["calls"]) == 1, "a numbered record older than the clear is not")
	net.queue_free()


## A call that waited for a slot longer than its timeout never went out: the client says so
## (call_skipped) and the ledger counts it as a scripted answer, not as a failure of the model.
func _check_no_free_slot() -> void:
	var net := _net()
	var l := ModelLedger.new()
	l.attach(net, true)
	FeatureFlags.set_override("gmi_inflight_cap", true)
	for _i in range(net.admission.background_max):
		net.admission.enter("residents")
	var seen: Array[Dictionary] = []
	net.call_skipped.connect(func(rec: Dictionary) -> void: seen.append(rec))
	var res: Dictionary = await net.live_json("residents", "plans", OTHER, "s", "u", 1, 100, 0.05)
	check(
		str(res["error"]) == "no free slot" and seen.size() == 1,
		(
			"fixture: the call gave up waiting for a slot (%s, %d skip signals)"
			% [res["error"], seen.size()]
		)
	)
	var row := _row(l, OTHER)
	check(
		int(row["calls"]) == 1 and int(row["fallback"]) == 1 and int(row["live_fail"]) == 0,
		(
			"counted as a scripted answer, not as a failed live call (%s/%s/%s)"
			% [row["calls"], row["fallback"], row["live_fail"]]
		)
	)
	check(
		(
			int((row["errors"] as Dictionary).get("skipped", 0)) == 0
			and str(row["health"]) == "scripted"
		),
		"a skip is no error class; the row reads scripted (%s)" % row["health"]
	)
	FeatureFlags.set_override("gmi_inflight_cap", false)
	net.queue_free()


## A ledger an older save carried must not feed anything while the flag is off, and the save is
## passed on untouched so the flag can come back on.
func _check_flag_off_old_save() -> void:
	var l := ModelLedger.new()
	for ms in [8000, 9000, 10000]:
		_live(l, MODEL, ms, "mayor")
	l.note_turn(0, _entry("live", [["road", true]]))
	var saved := l.to_dict()
	FeatureFlags.set_override("model_ledger", false)
	var off := ModelLedger.new()
	off.from_dict(saved)
	check(
		off.snapshot().is_empty() and int(off.mayor_rows()[0]["orders_ok"]) == 0,
		"flag off: an older save's ledger is not loaded"
	)
	check(off.to_dict() == saved, "flag off: the save is handed back as it came")
	FeatureFlags.set_override("model_ledger", true)
	check(
		ModelLedger.new().to_dict().get("v") == ModelLedger.SAVE_VERSION,
		"flag on again: a normal save"
	)


## The health light reads the last HEALTH_WINDOW outcomes of the RECENT_KEEP a stat remembers (and a
## save keeps); a save is a file anyone can edit, so a huge list or a NaN number is cut or ignored.
func _check_bounds() -> void:
	var l := ModelLedger.new()
	for i in range(30):
		l.note_call(
			{
				"role": "news",
				"agent": "g",
				"model": "b/b",
				"source": "live",
				"latency_ms": 100,
				"attempts": 1 if i % 2 == 0 else 2
			}
		)
	var saved: Dictionary = l.to_dict()
	var recent: Array = (saved["models"]["b/b"] as Dictionary)["recent"]
	check(
		recent.size() == ModelLedger.RECENT_KEEP,
		(
			"a stat remembers, and a save keeps, the last %d outcomes (%d)"
			% [ModelLedger.RECENT_KEEP, recent.size()]
		)
	)
	var wide := ModelLedger.new()
	var many: Array = []
	for _i in range(100):
		many.append(0)
	wide.from_dict({"models": {"b/b": {"calls": 3, "recent": many, "lat": many}}})
	var st: Dictionary = wide.models["b/b"]
	check(
		(
			(st["recent"] as Array).size() == ModelLedger.RECENT_KEEP
			and (st["lat"] as Array).size() == ModelLedger.LAT_KEEP
		),
		"a saved list longer than the bounds is cut on load"
	)
	var nan_ledger := ModelLedger.new()
	nan_ledger.from_dict({"models": {"b/b": {"calls": NAN, "live_ok": INF, "last_ms": NAN}}})
	var row := _row(nan_ledger, "b/b")
	check(
		int(row["calls"]) == 0 and int(row["live_ok"]) == 0,
		"a NaN or infinite count in a save reads as 0 (%s/%s)" % [row["calls"], row["live_ok"]]
	)
