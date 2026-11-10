extends SceneTree
## The readiness check of a key (GmiPreflight, GmiReadiness): once per key, one GET of the
## model list compared with the 14 model ids the game calls, a sentence on the key panel ("13 of 14
## models available; Mei Kimura will use the offline planner") and one line in the GMI log. Every
## transport here is a fake (_models_trip); no test ever reaches a network, and the client only
## starts the check by itself where the game runs (preflight.enabled), never under
## GRIDFALL_OFFLINE=1. Offline.

const K := preload("res://tools/tests/fp_kit.gd")
const KIT := preload("res://tools/tests/fp_keyflow_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")

var fails: Array[String] = []


## A GmiClient whose model-list GET is scripted and recorded.
class ModelsNet:
	extends GmiClient
	var trips: Array[Dictionary] = []
	var answer: Dictionary = {}
	var delay_frames: int = 0

	func _models_trip(headers: PackedStringArray, timeout_s: float) -> Dictionary:
		trips.append({"headers": headers, "timeout": timeout_s})
		var mine := answer.duplicate()  # what the network said when the request went out
		for _k in range(delay_frames):
			await get_tree().process_frame
		return mine


func _init() -> void:
	K.watchdog(self, "FP_GMI_READY_TEST")
	await process_frame
	_check_configured()
	_check_body_and_compare()
	_check_lines()
	_check_from_trip()
	var had_offline := OS.get_environment("GRIDFALL_OFFLINE")
	await _check_offline_and_off_switches()
	OS.unset_environment("GRIDFALL_OFFLINE")
	await _check_client()
	await _check_failures()
	await _check_key_changes()
	await _check_panel()
	if not had_offline.is_empty():
		OS.set_environment("GRIDFALL_OFFLINE", had_offline)
	FeatureFlags.set_override("gmi_live", true)
	FeatureFlags.set_override("gmi_preflight", true)
	K.finish(self, "FP_GMI_READY_TEST", fails)


# ------------------------------------------------------------------ the pure part


func _ids_except(missing: Array) -> Array:
	var out: Array = []
	for entry: Dictionary in GmiReadiness.configured():
		if not missing.has(str(entry["id"])):
			out.append(str(entry["id"]))
	return out


func _check_configured() -> void:
	var cfg := GmiReadiness.configured()
	var ids: Array = cfg.map(func(e: Dictionary) -> String: return str(e["id"]))
	var distinct := {}
	for id: String in ids:
		distinct[id] = true
	K.check(
		fails,
		cfg.size() == 14 and distinct.size() == 14 and GmiReadiness.total() == 14,
		"the game calls 14 distinct models (%d)" % cfg.size()
	)
	var every_mayor := true
	for m: Dictionary in D.MAYORS:
		every_mayor = every_mayor and ids.has(str(m["model"]))
	var every_agent := true
	for role: String in D.SUPPORT_AGENTS:
		every_agent = every_agent and ids.has(str((D.SUPPORT_AGENTS[role] as Dictionary)["model"]))
	var every_mind := true
	for id: String in ResidentMinds.MODELS:
		every_mind = every_mind and ids.has(id)
	for id: String in ChatterMinds.MODEL_NAMES:
		every_mind = every_mind and ids.has(id)
	K.check(
		fails,
		every_mayor and every_agent and every_mind,
		"every mayor, support agent, resident and chatter model is in the list"
	)
	var kimi: Dictionary = cfg[ids.find("moonshotai/kimi-k3")]
	K.check(
		fails,
		(
			(kimi["users"] as Array).size() == 1
			and str((kimi["users"] as Array)[0]["name"]) == "Mei Kimura"
			and str((kimi["users"] as Array)[0]["kind"]) == "mayor"
		),
		"a mayor's model lists the mayor's person name"
	)


func _check_body_and_compare() -> void:
	var listed := _ids_except([])
	var shapes := {
		"data of objects":
		JSON.stringify(
			{
				"object": "list",
				"data":
				listed.map(func(i: String) -> Dictionary: return {"id": i, "object": "model"})
			}
		),
		"models of strings": JSON.stringify({"models": listed}),
		"a bare list": JSON.stringify(listed.map(func(i: String) -> Dictionary: return {"id": i})),
	}
	for name: String in shapes:
		K.check(
			fails,
			GmiReadiness.ids_from_body(str(shapes[name])).size() == 14,
			"ids_from_body reads %s" % name
		)
	K.check(
		fails,
		(
			GmiReadiness.ids_from_body("not json").is_empty()
			and GmiReadiness.ids_from_body('{"data": 5}').is_empty()
			and GmiReadiness.ids_from_body('{"error":"x"}').is_empty()
			and GmiReadiness.ids_from_body("").is_empty()
		),
		"ids_from_body: junk, a wrong shape and an error object give []"
	)
	K.check(
		fails,
		(
			GmiReadiness.ids_from_body('{"data":[{"id":" a "},{"nope":1},{"id":""},"b",3]}')
			== ["a", "b"]
		),
		"ids_from_body: blanks and non-ids are skipped, ids trimmed"
	)
	var all := GmiReadiness.compare(listed)
	K.check(
		fails,
		(
			int(all["available"]) == 14
			and (all["missing"] as Array).is_empty()
			and (all["offline"] as Array).is_empty()
		),
		"compare: all 14 listed"
	)
	var lower := GmiReadiness.compare(listed.map(func(i: String) -> String: return i.to_lower()))
	K.check(fails, int(lower["available"]) == 14, "compare: ids match without regard to case")
	var no_kimi := GmiReadiness.compare(_ids_except(["moonshotai/kimi-k3"]))
	K.check(
		fails,
		(
			int(no_kimi["available"]) == 13
			and no_kimi["offline"] == ["Mei Kimura"]
			and int(no_kimi["skipped"]) == 0
		),
		"compare: a missing mayor model puts that mayor on the offline planner"
	)
	var no_minimax := GmiReadiness.compare(_ids_except(["MiniMaxAI/MiniMax-M3"]))
	K.check(
		fails,
		(
			no_minimax["offline"] == ["Citizen Voices", "Street Inspector"]
			and int(no_minimax["skipped"]) == 0
		),
		"compare: one model that two agents share names both (%s)" % str(no_minimax["offline"])
	)
	var no_pool := GmiReadiness.compare(
		_ids_except(["deepseek-ai/DeepSeek-V4.1-Flash", "zai-org/GLM-5.3-Flash"])
	)
	K.check(
		fails,
		(
			(no_pool["offline"] as Array).is_empty()
			and int(no_pool["skipped"]) == 2
			and int(no_pool["available"]) == 12
		),
		"compare: pool-only models are skipped, not offline (%s)" % str(no_pool)
	)
	var shared := GmiReadiness.compare(_ids_except(["deepseek-ai/DeepSeek-V4-Flash-0731"]))
	K.check(
		fails,
		shared["offline"] == ["Viktor Han"] and int(shared["skipped"]) == 0,
		"compare: a mayor's model the residents also use counts for the mayor"
	)


func _check_lines() -> void:
	var ok := func(missing: Array) -> Dictionary:
		var r := GmiReadiness.compare(_ids_except(missing))
		r["ok"] = true
		return r
	K.check(
		fails, GmiReadiness.line(ok.call([])) == "All 14 models available.", "line: all available"
	)
	K.check(
		fails,
		(
			GmiReadiness.line(ok.call(["moonshotai/kimi-k3"]))
			== "13 of 14 models available; Mei Kimura will use the offline planner."
		),
		"line: one mayor (%s)" % GmiReadiness.line(ok.call(["moonshotai/kimi-k3"]))
	)
	K.check(
		fails,
		(
			GmiReadiness.line(ok.call(["moonshotai/kimi-k3", "XiaomiMiMo/MiMo-V2.6-Flash"]))
			== (
				"12 of 14 models available; "
				+ "Mei Kimura and GridFall Gazette will use the offline planner."
			)
		),
		"line: two names joined with 'and'"
	)
	K.check(
		fails,
		(
			GmiReadiness.line(
				ok.call(["moonshotai/kimi-k3", "XiaomiMiMo/MiMo-V2.6-Flash", "x-ai/grok-4.5"])
			)
			== (
				"11 of 14 models available; "
				+ "Mei Kimura, Duke Granger and GridFall Gazette will use the offline planner."
			)
		),
		"line: three names"
	)
	K.check(
		fails,
		(
			GmiReadiness.line(ok.call(["zai-org/GLM-5.3-Flash"]))
			== "13 of 14 models available; 1 resident or chat model will be skipped."
		),
		"line: a pool model is skipped"
	)
	K.check(
		fails,
		(
			GmiReadiness
			. line(ok.call(["moonshotai/kimi-k3", "zai-org/GLM-5.3-Flash", "Qwen/Qwen3.8-Flash"]))
			. ends_with("will use the offline planner; 2 resident or chat models will be skipped.")
		),
		"line: offline and skipped together"
	)
	K.check(
		fails,
		(
			GmiReadiness.line({"ok": false, "error": "HTTP 404"})
			== "Could not check the model list (HTTP 404). The Test button checks the key."
		),
		"line: a failed check says why and points to Test"
	)
	K.check(fails, GmiReadiness.line({}).is_empty(), "line: no report, no line")
	var sentence := GmiReadiness.line(ok.call(["moonshotai/kimi-k3"]))
	K.check(
		fails,
		(
			not D.debrand(sentence).is_empty()
			and sentence.contains("Mei Kimura")
			and not sentence.to_lower().contains("kimi-k3")
		),
		"the line names people, not model ids"
	)


func _trip(result: int, http: int, body: String) -> Dictionary:
	return {
		"result": result,
		"http": http,
		"headers": PackedStringArray(),
		"body": body.to_utf8_buffer()
	}


func _check_from_trip() -> void:
	var good := JSON.stringify(
		{"data": _ids_except([]).map(func(i: String) -> Dictionary: return {"id": i})}
	)
	var r := GmiReadiness.from_trip(_trip(HTTPRequest.RESULT_SUCCESS, 200, good), 12.0)
	K.check(
		fails, bool(r["ok"]) and int(r["available"]) == 14, "from_trip: a model list is a report"
	)
	K.check(
		fails,
		GmiReadiness.from_trip({"start_error": 31}, 12.0)["error"] == "the request could not start",
		"from_trip: a request that could not start"
	)
	var too_big := _trip(HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, 200, "")
	K.check(
		fails,
		GmiReadiness.from_trip(too_big, 12.0)["error"] == "the model list is too large to read",
		"from_trip: a model list past the size limit says so"
	)
	K.check(
		fails,
		(
			GmiReadiness.from_trip(_trip(HTTPRequest.RESULT_CANT_CONNECT, 0, ""), 12.0)["error"]
			== "blocked by the browser or offline"
		),
		"from_trip: no connection reads as blocked or offline"
	)
	(
		K
		. check(
			fails,
			(
				(
					GmiReadiness
					. from_trip(
						_trip(HTTPRequest.RESULT_SUCCESS, 401, "bad key SECRETSECRET"), 12.0
					)["error"]
				)
				== "HTTP 401"
			),
			"from_trip: an HTTP error is the code only, never the body"
		)
	)
	K.check(
		fails,
		(
			GmiReadiness.from_trip(_trip(HTTPRequest.RESULT_SUCCESS, 200, "<html>"), 12.0)["error"]
			== "the reply is not a model list"
		),
		"from_trip: a 200 that is not a list"
	)
	K.check(
		fails,
		(
			(
				GmiReadiness
				. from_trip(_trip(HTTPRequest.RESULT_SUCCESS, 200, '{"data":[]}'), 12.0)["error"]
			)
			== "the reply is not a model list"
		),
		"from_trip: an empty list"
	)
	var none := GmiReadiness.from_trip(
		_trip(HTTPRequest.RESULT_SUCCESS, 200, '{"data":[{"id":"other/model"}]}'), 12.0
	)
	K.check(
		fails,
		not bool(none["ok"]) and str(none["error"]) == "it names none of the 14 models",
		"from_trip: a list that names none of ours is not read as 14 missing"
	)


# ------------------------------------------------------------------ the client


func _models_json(missing: Array = []) -> Dictionary:
	var body := JSON.stringify(
		{"data": _ids_except(missing).map(func(i: String) -> Dictionary: return {"id": i})}
	)
	return _trip(HTTPRequest.RESULT_SUCCESS, 200, body)


func _net(key: String = "") -> ModelsNet:
	var c := ModelsNet.new()
	c.name = "ModelsNet"
	get_root().add_child(c)
	c.live_enabled = true
	c.preflight.enabled = true
	c.answer = _models_json()
	if not key.is_empty():
		c.api_key = key
	return c


func _check_offline_and_off_switches() -> void:
	var key := "off_0123456789abcdef"
	# A client a test builds never starts a check by itself (preflight.enabled is the game's
	# switch).
	var had := OS.get_environment("GRIDFALL_OFFLINE")
	OS.set_environment("GRIDFALL_OFFLINE", "1")
	var quiet := ModelsNet.new()
	get_root().add_child(quiet)
	quiet.answer = _models_json()
	quiet.set_player_key(key)
	await process_frame
	K.check(
		fails,
		(
			quiet.trips.is_empty()
			and quiet.preflight.report.is_empty()
			and quiet.preflight.line().is_empty()
			and not quiet.preflight.enabled
		),
		"a test client does not check a key it is given: no GET, no line"
	)
	var forced: Dictionary = await quiet.preflight.run(quiet, true)
	K.check(
		fails,
		forced.is_empty() and quiet.trips.is_empty(),
		"and run() without the game's switch does nothing even when asked"
	)
	# GRIDFALL_OFFLINE=1 (the gate's setting) refuses it.
	var c := _net()
	c.set_player_key(key)
	await process_frame
	var r: Dictionary = await c.preflight.run(c)
	K.check(
		fails, c.trips.is_empty() and r.is_empty(), "GRIDFALL_OFFLINE=1: no model list is asked for"
	)
	quiet.queue_free()
	c.queue_free()
	if had.is_empty():
		OS.unset_environment("GRIDFALL_OFFLINE")
	else:
		OS.set_environment("GRIDFALL_OFFLINE", had)


func _check_client() -> void:
	var key := "ready_0123456789abcdef_KEY"
	var c := _net()
	var seen: Array[Dictionary] = []
	c.preflight.changed.connect(func(rep: Dictionary) -> void: seen.append(rep))
	var snap_before := _snapshot(c)
	c.set_player_key(key)
	await process_frame
	K.check(
		fails,
		c.trips.size() == 1,
		"setting a key asks for the model list once (%d)" % c.trips.size()
	)
	var headers: PackedStringArray = c.trips[0]["headers"]
	K.check(
		fails,
		(
			headers
			== PackedStringArray(["Authorization: Bearer " + key, "Content-Type: application/json"])
		),
		"the GET carries Authorization and Content-Type only (%d headers)" % headers.size()
	)
	K.check(
		fails,
		(
			float(c.trips[0]["timeout"]) == GmiClient.PREFLIGHT_TIMEOUT_S
			and GmiClient.MODELS_URL == "https://api.gmi-serving.com/v1/models"
		),
		"the GET goes to /v1/models of the GMI endpoint with a short timeout"
	)
	K.check(
		fails,
		(
			bool(c.preflight.report["ok"])
			and c.preflight.line() == "All 14 models available."
			and seen.size() == 1
		),
		"the report says all 14 are available and was announced once"
	)
	var rec: Dictionary = c.log_records.back()
	K.check(
		fails,
		(
			str(rec["role"]) == "preflight"
			and str(rec["agent"]) == "models"
			and str(rec["source"]) == "live"
			and str(rec["summary"]) == "All 14 models available."
			and str(rec["error"]).is_empty()
		),
		"one GMI log entry carries the sentence (%s)" % JSON.stringify(rec).left(120)
	)
	K.check(
		fails,
		_snapshot(c) == snap_before,
		"the check leaves the breakers, counters and caches alone"
	)
	# The same key again: no second GET.
	c.set_player_key(key)
	var again: Dictionary = await c.preflight.run(c)
	K.check(
		fails, c.trips.size() == 1 and again == c.preflight.report, "the same key is asked once"
	)
	# Forced: asks again; a model gone from the list shows.
	c.answer = _models_json(["moonshotai/kimi-k3"])
	var forced: Dictionary = await c.preflight.run(c, true)
	K.check(
		fails,
		(
			c.trips.size() == 2
			and int(forced["available"]) == 13
			and (
				c.preflight.line()
				== "13 of 14 models available; Mei Kimura will use the offline planner."
			)
		),
		"force asks again and reports 13 of 14 (%s)" % c.preflight.line()
	)
	K.check(
		fails,
		c.log_records.size() == 2 and seen.size() == 2,
		"each finished check adds a log line and an announcement"
	)
	# Nothing the key is made of reaches a line, a record or a report.
	var all_text := (
		JSON.stringify(c.log_records) + JSON.stringify(c.preflight.report) + c.preflight.line()
	)
	K.check(fails, not KIT.leaks(all_text, key), "the key appears in no report, line or log record")
	# The gmi_preflight flag and the live kill switch.
	FeatureFlags.set_override("gmi_preflight", false)
	var off: Dictionary = await c.preflight.run(c, true)
	K.check(fails, off.is_empty() and c.trips.size() == 2, "gmi_preflight off: no GET")
	FeatureFlags.set_override("gmi_preflight", true)
	FeatureFlags.set_override("gmi_live", false)
	var killed: Dictionary = await c.preflight.run(c, true)
	K.check(fails, killed.is_empty() and c.trips.size() == 2, "gmi_live off: no GET")
	FeatureFlags.set_override("gmi_live", true)
	c.queue_free()


func _snapshot(c: GmiClient) -> Dictionary:
	return {
		"breakers": c.breakers.states(),
		"stats": c.stats.duplicate(),
		"outcomes": c.live_outcomes.duplicate(),
		"session": c.session_cache.duplicate(true),
		"replay_n": c.replay_cache.size(),
	}


func _check_failures() -> void:
	var key := "fail_0123456789abcdef_KEY"
	var c := _net(key)
	c.answer = _trip(HTTPRequest.RESULT_SUCCESS, 401, "invalid key " + key)
	var r: Dictionary = await c.preflight.run(c)
	var line := c.preflight.line()
	K.check(
		fails,
		(
			not bool(r["ok"])
			and str(r["error"]) == "HTTP 401"
			and line == "Could not check the model list (HTTP 401). The Test button checks the key."
		),
		"a 401 reads as a failed check with the code (%s)" % line
	)
	K.check(fails, c.trips.size() == 1, "a failed check is not retried")
	var rec: Dictionary = c.log_records.back()
	K.check(
		fails,
		(
			str(rec["source"]) == "failed"
			and str(rec["error"]) == "HTTP 401"
			and not KIT.leaks(JSON.stringify(rec) + line + JSON.stringify(r), key)
		),
		"the failure is logged as failed and the echoed key is in none of it"
	)
	K.check(
		fails,
		(
			c.breaker_state() == "closed"
			and c.live_outcomes.is_empty()
			and int(c.stats["live_fail"]) == 0
		),
		"a failed check is not a service failure: no breaker, no outcome, no live_fail"
	)
	# The retry (force) after the network comes back.
	c.answer = _models_json()
	var healed: Dictionary = await c.preflight.run(c, true)
	K.check(
		fails,
		bool(healed["ok"]) and c.preflight.line() == "All 14 models available.",
		"asking again after a failure gives the real answer"
	)
	# Blocked: a browser CORS block reads as no HTTP answer.
	var d := _net("blocked_0123456789abcdef")
	d.answer = _trip(HTTPRequest.RESULT_CANT_CONNECT, 0, "")
	await d.preflight.run(d)
	K.check(
		fails,
		(
			d.preflight.line()
			== (
				"Could not check the model list (blocked by the browser or offline). "
				+ "The Test button checks the key."
			)
		),
		"a blocked request says so (%s)" % d.preflight.line()
	)
	c.queue_free()
	d.queue_free()


func _check_key_changes() -> void:
	var a := "keyA_0123456789abcdef"
	var b := "keyB_0123456789abcdef"
	var c := _net()
	c.answer = _models_json()
	c.set_player_key(a)
	await process_frame
	K.check(
		fails,
		c.trips.size() == 1 and c.preflight.line() == "All 14 models available.",
		"key A is checked"
	)
	c.answer = _models_json(["x-ai/grok-4.5"])
	c.delay_frames = 3
	c.set_player_key(b)
	K.check(
		fails,
		c.preflight.report.is_empty() and c.preflight.line().is_empty(),
		"a new key clears the line until its own check is in"
	)
	for _k in range(6):
		await process_frame
	c.delay_frames = 0
	K.check(
		fails,
		c.trips.size() == 2 and c.preflight.line().begins_with("13 of 14"),
		"key B is checked on its own (%s)" % c.preflight.line()
	)
	c.set_player_key(a)
	K.check(
		fails,
		c.trips.size() == 2 and c.preflight.line() == "All 14 models available.",
		"going back to key A shows its earlier report without asking again"
	)
	# A key changed while the GET is out: the late report is kept for its key, not shown for the
	# new one.
	var slow := _net()
	slow.delay_frames = 4
	slow.answer = _models_json()
	slow.set_player_key(a)
	await process_frame
	slow.answer = _models_json(["moonshotai/kimi-k3"])
	slow.delay_frames = 0
	slow.set_player_key(b)
	var guard := 0
	while slow.preflight.report.is_empty() and guard < 40:
		await process_frame
		guard += 1
	K.check(
		fails,
		slow.trips.size() == 2 and slow.preflight.line().begins_with("13 of 14"),
		"the report on screen is the new key's (%s)" % slow.preflight.line()
	)
	for _k in range(8):
		await process_frame
	K.check(
		fails,
		slow.preflight.line().begins_with("13 of 14"),
		"and the late report of the old key does not replace it"
	)
	# The same key set twice while its GET is out asks once.
	var twice := _net()
	twice.delay_frames = 3
	twice.set_player_key(a)
	twice.set_player_key(a)
	for _k in range(8):
		await process_frame
	K.check(
		fails,
		twice.trips.size() == 1 and twice.preflight.line() == "All 14 models available.",
		"a key set twice while its check is out is asked about once"
	)
	c.queue_free()
	slow.queue_free()
	twice.queue_free()


func _check_panel() -> void:
	var key := "panel_0123456789abcdef_KEY"
	var c := _net()
	var ctx := FpContext.new()
	ctx.client = c
	var panel := GmiKeyPanel.new()
	get_root().add_child(panel)
	panel.setup(ctx)
	K.check(
		fails,
		panel.models != null and panel.models.text.is_empty(),
		"the key page has a model line, empty before any check"
	)
	c.answer = _models_json(["moonshotai/kimi-k3"])
	c.set_player_key(key)
	var guard := 0
	while panel.models.text.is_empty() and guard < 40:
		await process_frame
		guard += 1
	K.check(
		fails,
		panel.models.text == "13 of 14 models available; Mei Kimura will use the offline planner.",
		(
			(
				"the page shows '13 of 14 models available; "
				+ "Mei Kimura will use the offline planner.' (%s)"
			)
			% panel.models.text
		)
	)
	K.check(
		fails,
		panel.status.text.contains("Key in use") and not KIT.leaks(panel.models.text, key),
		"the status line is the page's own and the model line holds no key"
	)
	c.delay_frames = 3
	c.set_player_key("other_0123456789abcdef")
	K.check(
		fails,
		panel.models.text.is_empty(),
		"a different key blanks the line until its own check lands"
	)
	panel.queue_free()
	c.queue_free()
