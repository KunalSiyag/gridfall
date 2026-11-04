extends SceneTree
## Whose words a mayor's chat line is (scripts/fp/chat/mayor_voice.gd, flag mayor_voice_calls).
## Every line credited to a mayor says it is the press office's draft (a fast chat model or the
## offline script wrote it); with the flag on and a live key the mayor's own model is called (one
## live_json chatter/mayor-voice call per mayor line, at most three a round, on that mayor's model)
## and its words replace the draft; a failed, empty or unsuitable answer (a link, a model's name,
## three sentences) leaves the press office's line; offline there is no call. A fake client; no
## network. Prints FP_MAYOR_VOICE_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const LIVE := preload("res://tools/tests/support/arena_live_client.gd")
const MV := preload("res://scripts/fp/chat/mayor_voice.gd")
const TOKEN := "FP_MAYOR_VOICE_TEST"

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 60.0)
	await process_frame
	await _check_mayor_voice()
	K.finish(self, TOKEN, fails)


func _lines() -> Array:
	return [
		{
			"id": "r1",
			"author": "Someone",
			"role": "resident",
			"district": 2,
			"text": "Roads are fine.",
			"reply_to": -1,
			"reply_idx": -1
		},
		{
			"id": "mayor:1",
			"author": "Viktor Han",
			"role": "mayor",
			"district": 1,
			"text": "We repaved Copper Street.",
			"reply_to": -1,
			"reply_idx": -1
		},
		{
			"id": "mayor:3",
			"author": "Rosa Quintero",
			"role": "mayor",
			"district": 3,
			"text": "The budget is balanced.",
			"reply_to": -1,
			"reply_idx": -1
		},
	]


func _check_mayor_voice() -> void:
	var live: LIVE = LIVE.new()
	live.name = "VoiceClient"
	get_root().add_child(live)
	live.live_enabled = true
	live.api_key = "test-key-not-real"
	FeatureFlags.set_override("mayor_voice_calls", false)
	var lines := await MV.attribute(live, 1, _lines(), null)
	var vias := lines.map(func(l: Dictionary) -> String: return str(l.get("via", "")))
	check(
		vias == ["", MV.PRESS, MV.PRESS],
		(
			"flag off: mayor lines say they are the press office's, residents' say nothing (%s)"
			% str(vias)
		)
	)
	check(live.seen.is_empty(), "flag off: not one extra call")
	check(not MV.wants_own(live), "wants_own is false with the flag off")
	FeatureFlags.set_override("mayor_voice_calls", true)
	check(MV.wants_own(live), "wants_own with the flag on and a live key")
	live.data_for["mayor-voice"] = {"say": "Copper Street is paved, and I did it myself."}
	lines = await MV.attribute(live, 1, _lines(), null)
	check(
		live.seen.size() == 2,
		"one call per mayor line, none for the resident (%d)" % live.seen.size()
	)
	var models: Array = live.seen.map(func(s: Dictionary) -> String: return str(s["model"]))
	models.sort()
	var want: Array = [str(D.MAYORS[1]["model"]), str(D.MAYORS[3]["model"])]
	want.sort()
	check(models == want, "each goes to that mayor's own model (%s)" % str(models))
	check(
		live.seen[0]["role"] == "chatter" and live.seen[0]["agent"] == "mayor-voice",
		"as live_json chatter/mayor-voice"
	)
	check(str(live.seen[0]["user"]).contains("press_office_draft"), "the draft goes with it")
	var now := lines.map(
		func(l: Dictionary) -> String: return "%s|%s" % [l.get("via", ""), l["text"]]
	)
	check(
		(
			now[0] == "|Roads are fine."
			and now[1] == MV.OWN + "|Copper Street is paved, and I did it myself."
		),
		"the mayor's line is the mayor's own words now (%s)" % str(now)
	)
	# A failed call, a link, a model's name, three sentences: the press office's line stays.
	for bad: Array in [
		["fail", ""],
		["data", {"say": "See https://example.com now."}],
		["data", {"say": "As Grok I agree."}],
		["data", {"say": "One. Two. Three."}],
		["data", {"say": ""}]
	]:
		live.seen.clear()
		live.fail.clear()
		live.data_for.clear()
		if bad[0] == "fail":
			live.fail["mayor-voice"] = "HTTP 429 slow"
		else:
			live.data_for["mayor-voice"] = bad[1]
		lines = await MV.attribute(live, 1, _lines(), null)
		var kept := (
			str(lines[1]["text"]) == "We repaved Copper Street."
			and str(lines[1]["via"]) == MV.PRESS
		)
		check(
			kept and str(lines[2]["via"]) == MV.PRESS,
			"unsuitable answer %s keeps the press office's line" % str(bad)
		)
	# More than MAX_REWRITES mayor lines: only the first three are sent.
	live.seen.clear()
	live.fail.clear()
	live.data_for["mayor-voice"] = {"say": "In my own words."}
	var many: Array = []
	for k in range(5):
		many.append(
			{
				"id": "mayor:%d" % k,
				"author": "x",
				"role": "mayor",
				"district": k,
				"text": "Draft %d." % k
			}
		)
	await MV.attribute(live, 1, many, null)
	check(
		live.seen.size() == MV.MAX_REWRITES,
		"at most %d rewrites a round (%d)" % [MV.MAX_REWRITES, live.seen.size()]
	)
	# A live connection without a key (the flag on) makes no call either.
	var key := live.api_key
	live.api_key = ""
	check(not MV.wants_own(live), "wants_own is false without a key")
	live.seen.clear()
	await MV.attribute(live, 1, _lines(), null)
	check(live.seen.is_empty(), "no key: not one call")
	live.api_key = key
	# The offline line of ChatterMinds carries the label too (the main path of a keyless demo).
	var minds := ChatterMinds.new()
	var msg: Dictionary = minds.call("_mayor_msg", 2, "Hello there.", -1)
	check(str(msg.get("via", "")) == MV.PRESS, "an offline mayor line is the press office's")
	minds.free()
	# Offline or without a key: no call, still labelled.
	live.live_enabled = false
	live.seen.clear()
	lines = await MV.attribute(live, 1, _lines(), null)
	check(live.seen.is_empty() and str(lines[1]["via"]) == MV.PRESS, "offline: labelled, no call")
	FeatureFlags.set_override("mayor_voice_calls", false)
	live.queue_free()
