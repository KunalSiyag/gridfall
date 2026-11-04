extends SceneTree
## Model-ledger corrections found in review (tools/tests/ai_ledger_test.gd has the main cases): a
## model that sits in a mayor's chair and also holds a service job keeps its service row apart;
## tokens and cut-off replies are counted by the finish reason, partial usage included, and for a
## reply that held no answer; an isolated role (Ask the five) is not counted and so leaves the brain
## save alone; a clean reply runs no repair scan and look-alikes (backticks in a string, a lone
## brace in prose) are not repairs. Headless, offline, a scripted HTTP round trip. Prints
## AI_LEDGER_REVIEW_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const NET := preload("res://tools/tests/support/scripted_gmi_net.gd")
const TOKEN := "AI_LEDGER_REVIEW_TEST"
const MODEL := "google/gemini-4-argon"

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 60.0)
	await process_frame
	_check_shared_model()
	_check_usage_and_truncation()
	await _check_failed_usage_and_isolation()
	_check_reply_classes()
	K.finish(self, TOKEN, fails)


func _net() -> NET:
	var net := NET.new()
	net.name = "ScriptedNet"
	get_root().add_child(net)
	net.api_key = "test-key-not-real"
	net.live_enabled = true
	net.sleep_ms = func(_ms: int) -> void: pass
	return net


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


func _msg(content: String) -> Dictionary:
	return {"content": content}


func _live(ledger: ModelLedger, model: String, ms: int, role: String) -> void:
	ledger.note_call(
		{
			"role": role,
			"agent": "deepseek" if role == "mayor" else "x",
			"model": model,
			"source": "live",
			"latency_ms": ms,
			"attempts": 1
		}
	)


func _row(ledger: ModelLedger, model: String) -> Dictionary:
	for r: Dictionary in ledger.snapshot():
		if str(r["model"]) == model:
			return r
	return {"live_ok": 0, "tokens_in": 0, "tokens_out": 0, "token_calls": 0, "truncated": 0}


## A model that sits in a mayor's chair AND holds a service job (DeepSeek-V4-Flash is Viktor Han's
## model and one of the resident minds): its service row carries only the service calls.
func _check_shared_model() -> void:
	var shared := str(D.MAYORS[1]["model"])
	check(ResidentMinds.MODELS.has(shared), "fixture: a mayor's model is also a resident mind")
	var l := ModelLedger.new()
	for _i in range(3):
		_live(l, shared, 20000, "mayor")
	for _i in range(2):
		l.note_call(
			{
				"role": "residents",
				"agent": "plans",
				"model": shared,
				"source": "heuristic",
				"latency_ms": 300,
				"attempts": 3,
				"error": "HTTP 503 down"
			}
		)
	var row: Dictionary = {}
	for r: Dictionary in l.services():
		if str(r["model"]) == shared:
			row = r
	check(
		(
			int(row["calls"]) == 2
			and int(row["live_ok"]) == 0
			and int(row["live_fail"]) == 2
			and int(row["p50_ms"]) == -1
		),
		"the service row is the service's calls only (%s)" % str(row)
	)
	check(
		str(row["health"]) == "red" and not str(row["mix"]).contains("Mayor"),
		"its light is the service's, not the mayor's (%s)" % row["health"]
	)
	var mayor: Dictionary = l.mayor_rows()[1]
	check(
		int(mayor["calls"]) == 3 and int(_row(l, shared)["calls"]) == 5,
		"the mayor row and the model's own row still count their calls"
	)
	var back := ModelLedger.new()
	back.from_dict(l.to_dict())
	var again: Array = back.services().filter(
		func(r: Dictionary) -> bool: return str(r["model"]) == shared
	)
	check(
		again.size() == 1 and int(again[0]["live_fail"]) == 2 and int(again[0]["live_ok"]) == 0,
		"the service stats survive a save"
	)


## tokens and cut-off replies are counted by the finish reason, and partial usage still counts.
func _check_usage_and_truncation() -> void:
	var l := ModelLedger.new()
	var rec := {"role": "news", "agent": "g", "model": "t/t", "source": "live", "latency_ms": 10}
	l.note_call(rec.merged({"finish_reason": "stop"}))
	check(int(_row(l, "t/t")["truncated"]) == 0, "finish_reason stop is not truncated")
	l.note_call(rec.merged({"finish_reason": "length"}))
	check(int(_row(l, "t/t")["truncated"]) == 1, "finish_reason length is")
	l.note_call(rec.merged({"tokens_in": 100, "tokens_out": -1}))
	var row := _row(l, "t/t")
	check(
		(
			int(row["tokens_in"]) == 100
			and int(row["tokens_out"]) == 0
			and int(row["token_calls"]) == 1
		),
		(
			"partial usage still counts what was reported (%s/%s)"
			% [row["tokens_in"], row["tokens_out"]]
		)
	)
	l.note_call(rec.merged({"tokens_in": -1, "tokens_out": -1}))
	check(int(_row(l, "t/t")["token_calls"]) == 1, "no usage at all adds nothing")


## A reply that came back but held no usable answer still cost tokens and may be cut off; and an
## isolated role (Ask the five) is not counted, so the brain save does not change when it runs.
func _check_failed_usage_and_isolation() -> void:
	var net := _net()
	var ledger := ModelLedger.new()
	ledger.attach(net)
	net.steps = [
		{
			"message": {"content": "", "reasoning_content": "thinking about it for a long while"},
			"usage": {"prompt_tokens": 1000, "completion_tokens": 200},
			"finish": "length"
		}
	]
	var res := await _call(net, "news", "zz", "f/fail")
	var row := _row(ledger, "f/fail")
	check(
		str(res["source"]) == "heuristic" and int(row["live_fail"]) >= 1,
		"fixture: a cut-off reply with no JSON is a failed call (%s)" % res["source"]
	)
	check(
		int(row["tokens_in"]) == 1000 and int(row["tokens_out"]) == 200,
		"a failed reply's tokens are counted (%s/%s)" % [row["tokens_in"], row["tokens_out"]]
	)
	check(int(row["truncated"]) >= 1, "a failed reply cut off at max_tokens is counted")
	var before := JSON.stringify(ledger.to_dict())
	var rev := ledger.revision
	net.steps = [
		{
			"message": _msg('{"thought":"what if"}'),
			"usage": {"prompt_tokens": 5, "completion_tokens": 5}
		}
	]
	var asked: Dictionary = await net.live_json("arena", "ask", MODEL, "s", "u", 1, 100, 5.0)
	check(str(asked["source"]) == "live", "fixture: the isolated ask went out live")
	check(
		JSON.stringify(ledger.to_dict()) == before and ledger.revision == rev,
		"an Ask the five call leaves the ledger (and so the brain save) alone"
	)
	var listed := false
	for r: Dictionary in ledger.snapshot():
		listed = listed or str(r["model"]) == MODEL
	check(not listed, "the asked model gets no row from it")
	net.live_enabled = false
	await net.live_json("arena", "ask", MODEL, "s", "u", 1, 100, 5.0)
	check(JSON.stringify(ledger.to_dict()) == before, "a skipped ask is not counted either")
	net.live_enabled = true
	await net.live_json("residents", "plans", MODEL, "s", "u", 1, 100, 5.0)
	check(ledger.revision > rev, "a normal live_json call is still counted")
	net.queue_free()


## What counts as a repair: a clean reply costs no repair scan, and look-alikes are not repairs.
func _check_reply_classes() -> void:
	var clean := '{"thought":"a","actions":[{"type":"road","x":1}],"votes":{"a":"yes"}}'
	var before := GmiReply.repair_scans
	var r := GmiReply.read({"choices": [{"message": {"content": clean}}]})
	check(
		(r["repairs"] as Array).is_empty() and GmiReply.repair_scans == before,
		"a clean reply runs no repair scan (%d)" % (GmiReply.repair_scans - before)
	)
	r = GmiReply.read({"choices": [{"message": {"content": '{"a":1,"b":[1,2,],}'}}]})
	check(
		r["repairs"] == ["trailing_comma"] and GmiReply.repair_scans == before + 1,
		"a trailing comma runs the scan once and is named (%s)" % str(r["repairs"])
	)
	var cases := {
		"three backticks inside a string value": ['{"thought":"use ``` blocks"}', []],
		"a lone brace in the prose before the answer":
		['Note { is needed. {"thought":"a","actions":[{"type":"road"}]}', []],
		"a comma in a string": ['{"thought":"NaN is bad, Infinity too, }"}', []],
		"a real fence": ['```json\n{"thought":"a"}\n```', ["fenced"]],
		"a cut-off reply": ['{"thought":"f","actions":[{"type":"road","x":1},{"ty', ["salvaged"]],
	}
	for k: String in cases.keys():
		var got := GmiReply.read({"choices": [{"message": {"content": cases[k][0]}}]})
		check(
			got["repairs"] == cases[k][1] and not (got["data"] as Dictionary).is_empty(),
			"%s: %s (%s)" % [k, str(cases[k][1]), str(got["repairs"])]
		)
