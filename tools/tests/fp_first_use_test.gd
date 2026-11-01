extends SceneTree
## FirstUse (scripts/ops/first_use.gd), the game half of the web probe kit: silent everywhere but
## the web build with the web_first_use_marks flag on (the flag ships off), logs the first
## MAX_PER_TAG marks and readings of a tag as FIRSTUSE JSON lines, names a stream by its file name
## and gives its length so a reading can be put per second of audio, and writes the console line
## and the User Timing mark in the format tools/web_fps_probe.js reads. SaveSlot.write times its
## stringify and its file write through it. The test forces the web path with FirstUse.force
## (JavaScriptBridge does nothing on the desktop). Headless, offline.
## Prints FP_FIRST_USE_TEST: PASS|FAIL.

const SAVE_PATH := "user://web_first_use_test_save.json"

var fails: Array[String] = []


## What print() sends to the console (an OS.add_logger hook), so the console line is read as the
## probe reads it.
class Console:
	extends Logger
	var lines: Array[String] = []

	func _log_message(message: String, error: bool) -> void:
		if not error:
			lines.append(message.strip_edges())


func check(ok: bool, what: String) -> void:
	print(("FP_FIRST_USE_TEST:   ok   " if ok else "FP_FIRST_USE_TEST:   FAIL ") + what)
	if not ok:
		fails.append(what)


func _init() -> void:
	await process_frame
	var flag_before := FeatureFlags.enabled("web_first_use_marks", false)
	_check_off()
	_check_marks()
	_check_stopwatch()
	_check_console()
	_check_names()
	_check_save_slot()
	FeatureFlags.set_override("web_first_use_marks", flag_before)
	FirstUse.force = false
	FirstUse.reset()
	print("FP_FIRST_USE_TEST: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	quit(0 if fails.is_empty() else 1)


func _turn(web: bool, flag: bool) -> void:
	FirstUse.force = web
	FeatureFlags.set_override("web_first_use_marks", flag)
	FirstUse.reset()


func _check_off() -> void:
	check(not bool(FeatureFlags.defaults().get("web_first_use_marks", true)), "the flag ships off")
	_turn(false, true)
	check(not FirstUse.active(), "desktop: off even with the flag on")
	FirstUse.mark("x")
	check(FirstUse.begin("play", "x") == -1, "desktop: no stopwatch is started")
	FirstUse.end("play", "x", -1)
	check(FirstUse.lines.is_empty(), "desktop: nothing is logged")
	_turn(true, false)
	check(not FirstUse.active(), "web with the flag off: off")
	FirstUse.mark("x")
	check(FirstUse.begin("play", "x") == -1, "flag off: no stopwatch is started")
	check(FirstUse.lines.is_empty(), "flag off: nothing is logged")
	_turn(true, true)
	check(FirstUse.active(), "web with the flag on: on")


func _check_marks() -> void:
	_turn(true, true)
	for i in range(5):
		FirstUse.mark("lamp_pool")
	check(
		FirstUse.lines.size() == FirstUse.MAX_PER_TAG,
		"the first %d marks of a tag are logged" % FirstUse.MAX_PER_TAG
	)
	var first: Variant = JSON.parse_string(FirstUse.lines[0])
	check(
		first is Dictionary and first["tag"] == "lamp_pool" and int(first["n"]) == 1,
		"a record is JSON with its tag and count"
	)
	var third: Variant = JSON.parse_string(FirstUse.lines[2])
	check(third is Dictionary and int(third["n"]) == 3, "...counted in order")
	FirstUse.mark("rain")
	check(FirstUse.lines.size() == FirstUse.MAX_PER_TAG + 1, "another tag has its own count")
	check(
		FirstUse.line_of({"tag": "a", "n": 1}) == 'FIRSTUSE {"tag":"a","n":1}',
		"the console line is FIRSTUSE plus JSON"
	)
	var js := 'try{performance.mark("gf:a",{detail:{"tag":"a","n":1}})}catch(e){}'
	check(
		FirstUse.mark_js({"tag": "a", "n": 1}) == js,
		"the User Timing mark is gf:<tag> with the record as detail"
	)
	check(
		FirstUse.mark_js({"tag": 'q"uote', "n": 1}).begins_with(
			'try{performance.mark("gf:q\\"uote",'
		),
		"a tag is quoted for JavaScript"
	)


func _check_stopwatch() -> void:
	_turn(true, true)
	var stamps: Array[bool] = []
	for i in range(5):
		var t0 := FirstUse.begin("play", "horn")
		stamps.append(t0 >= 0)
		if i == 0:
			OS.delay_msec(5)
		FirstUse.end("play", "horn", t0)
	check(
		stamps == [true, true, true, false, false],
		"a stopwatch times the first %d starts of a tag" % FirstUse.MAX_PER_TAG
	)
	check(FirstUse.lines.size() == FirstUse.MAX_PER_TAG, "...and logs only those")
	var r: Variant = JSON.parse_string(FirstUse.lines[0])
	check(
		r is Dictionary and r["tag"] == "play:horn" and int(r["n"]) == 1,
		"a reading is tagged kind:name"
	)
	var ms: float = float(r["ms"]) if r is Dictionary else -1.0
	check(
		ms >= 4.0 and ms < 1000.0,
		"...with the milliseconds between begin and end, not microseconds (%.3f)" % ms
	)
	check(not (r as Dictionary).has("len"), "...and no length unless a stream was timed")
	for i in range(5):
		FirstUse.end("save", "stringify", FirstUse.begin("save", "stringify"))
	var saves := FirstUse.lines.filter(func(l: String) -> bool: return l.contains("save:stringify"))
	check(
		saves.size() == 5, "a save kind keeps logging past the per-tag cap (%d of 5)" % saves.size()
	)
	var before := FirstUse.lines.size()
	FirstUse.end("play", "never_started", -1)
	check(
		FirstUse.lines.size() == before, "end() of a stopwatch that was never started does nothing"
	)
	check(
		(
			float(JSON.parse_string(FirstUse.line_of({"ms": 1.5}).trim_prefix("FIRSTUSE "))["ms"])
			== 1.5
		),
		"the line round-trips"
	)


func _check_console() -> void:
	_turn(true, true)
	var console := Console.new()
	OS.add_logger(console)
	FirstUse.mark("lamp_pool")
	FirstUse.end("play", "horn", FirstUse.begin("play", "horn"))
	OS.remove_logger(console)
	check(FirstUse.lines.size() == 2, "fixture: a mark and a reading were logged")
	for i in range(mini(2, FirstUse.lines.size())):
		var want := "FIRSTUSE " + FirstUse.lines[i]
		check(console.lines.has(want), "record %d reaches the console as a FIRSTUSE line" % i)
	_turn(true, false)
	var quiet := Console.new()
	OS.add_logger(quiet)
	FirstUse.mark("lamp_pool")
	OS.remove_logger(quiet)
	check(
		quiet.lines.filter(func(l: String) -> bool: return l.begins_with("FIRSTUSE")).is_empty(),
		"flag off: nothing reaches the console"
	)


func _check_names() -> void:
	_turn(true, true)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_8_BITS
	wav.mix_rate = 8000
	var data := PackedByteArray()
	data.resize(8000)
	wav.data = data
	wav.resource_path = "res://sounds/fp/first_use_test_stream.ogg"
	FirstUse.end("play", wav, FirstUse.begin("play", wav))
	var r: Variant = JSON.parse_string(FirstUse.lines[0])
	check(
		r is Dictionary and r["tag"] == "play:first_use_test_stream.ogg",
		"a stream is named by its file name"
	)
	check(
		r is Dictionary and is_equal_approx(float(r["len"]), 1.0),
		"...and carries its length in seconds"
	)
	var unnamed := wav.duplicate() as AudioStreamWAV
	unnamed.resource_path = ""
	FirstUse.end("play", unnamed, FirstUse.begin("play", unnamed))
	check(
		str(JSON.parse_string(FirstUse.lines[1])["tag"]) == "play:WAV@1.00s",
		"a stream without a path (a duplicate) is named by its class and length"
	)
	var longer := AudioStreamWAV.new()
	longer.format = AudioStreamWAV.FORMAT_8_BITS
	longer.mix_rate = 8000
	var more := PackedByteArray()
	more.resize(16000)
	longer.data = more
	FirstUse.end("play", longer, FirstUse.begin("play", longer))
	check(
		str(JSON.parse_string(FirstUse.lines[2])["tag"]) == "play:WAV@2.00s",
		"...so two such streams of different lengths keep their own tags"
	)
	FirstUse.end("save", null, FirstUse.begin("save", null))
	check(str(JSON.parse_string(FirstUse.lines[3])["tag"]) == "save", "null is no name")
	var empty := AudioStreamWAV.new()
	FirstUse.end("play", empty, FirstUse.begin("play", empty))
	check(
		str(JSON.parse_string(FirstUse.lines[4])["tag"]) == "play:WAV@0.00s",
		"an empty stream is still a class and a length"
	)


func _check_save_slot() -> void:
	_turn(true, true)
	check(SaveSlot.write(SAVE_PATH, {"sim": {"day": 1}}) == OK, "SaveSlot.write still writes")
	var tags: Array[String] = []
	for line: String in FirstUse.lines:
		tags.append(str(JSON.parse_string(line)["tag"]))
	check(
		tags == ["save:stringify", "save:file_write"],
		"...and times its stringify and its file write: %s" % str(tags)
	)
	var back := SaveSlot.read(SAVE_PATH)
	check(
		int((back.get("sim", {}) as Dictionary).get("day", 0)) == 1, "...the saved city reads back"
	)
	_turn(false, true)
	check(
		SaveSlot.write(SAVE_PATH, {"sim": {"day": 2}}) == OK and FirstUse.lines.is_empty(),
		"off: the same write logs nothing"
	)
	for p: String in [SAVE_PATH, SAVE_PATH + ".bak", SAVE_PATH + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
