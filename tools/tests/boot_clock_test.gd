extends SceneTree
## BootClock (scripts/ops/boot_clock.gd): off the web it records nothing unless
## GRIDFALL_BOOT_CLOCK=1. With the switch the marks come back in order and the report is one
## `GF_BOOT {json}` line with every mark. finish() waits for the first frame plus VEIL_FRAMES,
## prints the report and then the `GRIDFALL: boot complete` line the harnesses wait for, and
## closes the clock so later marks (the per-rebuild loops in FpMode) cost nothing, and a boot that
## never finishes stops recording at MAX_MARKS. A stage marked again gets #2, #3. The browser-only
## calls are no-ops on the desktop. The last case boots the real Main scene with the clock on, to
## pin the call sites in main.gd and fp_mode.gd (the stage order, a mark per feature and phase, a
## second restore of every feature as a continued city does) and the boot-complete line.

const K := preload("res://tools/tests/fp_kit.gd")
const REGISTRY := preload("res://scripts/fp/fp_features.gd")
const MAIN := preload("res://scripts/main.gd")

var fails: Array[String] = []


## Collects every printed line and every error line (Godot calls a Logger from the printing thread).
class LineLog:
	extends Logger
	var lines: PackedStringArray = PackedStringArray()
	var errors: PackedStringArray = PackedStringArray()

	func _log_message(message: String, error: bool) -> void:
		if error:
			errors.append(message.strip_edges())
		else:
			lines.append(message.strip_edges())


func _init() -> void:
	K.watchdog(self, "BOOT_CLOCK_TEST")
	await process_frame
	_check_off()
	_check_marks()
	_check_report()
	await _check_finish()
	_check_closed()
	_check_cap()
	_check_repeats()
	_check_web_calls()
	await _check_main_boot()
	BootClock.reset()
	OS.unset_environment(BootClock.ENV)
	K.finish(self, "BOOT_CLOCK_TEST", fails)


func _check_off() -> void:
	OS.unset_environment(BootClock.ENV)
	BootClock.reset()
	K.check(fails, not BootClock.enabled(), "off the web with no switch: disabled")
	BootClock.mark("a")
	BootClock.mark_for("b", "c")
	K.check(fails, BootClock.names().is_empty(), "disabled: nothing is recorded")
	BootClock.finish(self)
	K.check(fails, not BootClock.completed(), "disabled: finish() returns without completing")
	var marks: Array = BootClock.report()["marks"]
	K.check(fails, marks.is_empty(), "disabled: the report has no marks")


func _check_marks() -> void:
	OS.set_environment(BootClock.ENV, "1")
	BootClock.reset()
	K.check(fails, BootClock.enabled(), "GRIDFALL_BOOT_CLOCK=1 turns it on off the web")
	BootClock.mark("first")
	BootClock.mark_for("load", "traffic")
	OS.delay_usec(2000)
	BootClock.mark("last")
	var want := PackedStringArray(["first", "load:traffic", "last"])
	K.check(fails, BootClock.names() == want, "marks come back in order; mark_for joins stage:id")


func _check_report() -> void:
	var rep := BootClock.report()
	var marks: Array = rep["marks"]
	K.check(fails, marks.size() == 3 and marks[0][0] == "first", "the report lists every mark")
	K.check(fails, float(marks[0][1]) == 0.0, "the first mark is at 0 ms")
	var ordered := true
	for i in range(1, marks.size()):
		ordered = ordered and float(marks[i][1]) >= float(marks[i - 1][1])
	K.check(fails, ordered, "mark times never go backwards")
	K.check(fails, float(marks[2][1]) >= 2.0, "a 2 ms pause shows between the marks")
	K.check(fails, float(rep["total_ms"]) == float(marks[2][1]), "total_ms is the last mark")
	var line := BootClock.report_line()
	K.check(fails, line.begins_with('GF_BOOT {"v":1,'), "the line is GF_BOOT and a JSON object")
	K.check(fails, not line.contains("\n"), "the report is one line")
	var parsed: Variant = JSON.parse_string(line.trim_prefix(BootClock.REPORT_PREFIX))
	K.check(fails, _well_formed(parsed), "the JSON carries version, build facts, page clock, marks")


## True for a parsed report with every key, three marks, this version and the desktop's facts.
func _well_formed(parsed: Variant) -> bool:
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = parsed
	for key: String in [
		"v", "web", "threads", "engine_ms", "page_start_ms", "page_end_ms", "total_ms", "marks"
	]:
		if not d.has(key):
			return false
	var marks: Array = d["marks"]
	return (
		marks.size() == 3
		and int(d["v"]) == BootClock.REPORT_VERSION
		and d["web"] == false
		and float(d["page_start_ms"]) == -1.0
	)


func _check_finish() -> void:
	var log := LineLog.new()
	OS.add_logger(log)
	BootClock.finish(self)
	K.check(fails, BootClock.names()[-1] == "ready_end", "finish() marks ready_end at once")
	K.check(fails, not BootClock.completed(), "finish() waits for frames before completing")
	var frames := 0
	while not BootClock.completed() and frames < 30:
		await process_frame
		frames += 1
	OS.remove_logger(log)
	K.check(fails, BootClock.completed(), "finish() completes")
	K.check(
		fails, frames == 1 + BootClock.VEIL_FRAMES, "one interactive frame plus the veil frames"
	)
	var tail := BootClock.names().slice(-5)
	var want_tail := PackedStringArray(
		["ready_end", "first_frame", "frame_2", "frame_3", "veil_frames"]
	)
	K.check(
		fails,
		tail == want_tail,
		"ready_end, then one mark per frame up to veil_frames, close the table"
	)
	var printed := log.lines.size()
	var at := log.lines.find(BootClock.COMPLETE_LINE)
	K.check(fails, printed >= 2 and at == printed - 1, "the boot-complete line is printed last")
	var report_first := at >= 1 and log.lines[at - 1].begins_with(BootClock.REPORT_PREFIX)
	K.check(fails, report_first, "the GF_BOOT line comes right before it")
	K.check(
		fails, BootClock.COMPLETE_LINE == "GRIDFALL: boot complete", "the line harnesses wait for"
	)


func _check_closed() -> void:
	var count := BootClock.names().size()
	BootClock.mark("late")
	BootClock.mark_for("world", "late")
	K.check(fails, BootClock.names().size() == count, "after completion marks are ignored")
	K.check(fails, not BootClock.enabled(), "after completion the clock reads as off")
	var log := LineLog.new()
	OS.add_logger(log)
	BootClock.finish(self)
	OS.remove_logger(log)
	K.check(fails, log.lines.is_empty(), "a second finish() prints nothing")


## A boot that stops before finish() (an error that aborts Main._ready) keeps being marked by the
## rebuild loops; the arrays stop growing at MAX_MARKS and the clock stays usable.
func _check_cap() -> void:
	OS.set_environment(BootClock.ENV, "1")
	BootClock.reset()
	for i in BootClock.MAX_MARKS + 40:
		BootClock.mark("m%d" % i)
		BootClock.mark_for("world", "f%d" % i)
	K.check(fails, BootClock.names().size() == BootClock.MAX_MARKS, "marks stop at MAX_MARKS")
	K.check(fails, BootClock.names()[0] == "m0", "the cap keeps the earliest marks")
	var marks: Array = BootClock.report()["marks"]
	K.check(fails, marks.size() == BootClock.MAX_MARKS, "the report is capped the same")
	var open := BootClock.enabled() and not BootClock.completed()
	K.check(fails, open, "the cap does not end the boot")


## A stage marked again keeps its place in the table and gets #2, #3: the names stay unique, so a
## consumer that keys the marks by name loses none (a continued city restores each feature twice).
func _check_repeats() -> void:
	OS.set_environment(BootClock.ENV, "1")
	BootClock.reset()
	BootClock.mark("dict:traffic")
	BootClock.mark("fp_from_dict")
	BootClock.mark("dict:traffic")
	BootClock.mark_for("dict", "traffic")
	var want := PackedStringArray(
		["dict:traffic", "fp_from_dict", "dict:traffic#2", "dict:traffic#3"]
	)
	K.check(fails, BootClock.names() == want, "a repeated stage gets #2, #3 after its first mark")
	var marks: Array = BootClock.report()["marks"]
	var listed := PackedStringArray()
	for m: Array in marks:
		listed.append(str(m[0]))
	K.check(fails, listed == want, "the report lists the same unique names")


func _check_web_calls() -> void:
	var log := LineLog.new()
	OS.add_logger(log)
	var page_ms := WebSupport.perf_now()
	WebSupport.perf_mark("gf:test")
	WebSupport.boot_done()
	OS.remove_logger(log)
	K.check(fails, page_ms == -1.0, "desktop: no page clock")
	K.check(
		fails,
		log.errors.is_empty() and log.lines.is_empty(),
		"desktop: the browser calls are silent no-ops"
	)


## The real Main scene booted headless with the clock on: main.gd and fp_mode.gd mark the boot
## stages in order, every first-person feature gets a load, setup, world and dict mark (in the
## registry's order), the clock closes with ready_end, first_frame, frame_2, frame_3 and
## veil_frames, and the boot-complete line smoke.js waits for follows the GF_BOOT line. Main is not
## the current scene here, so it neither reads nor writes a save slot.
func _check_main_boot() -> void:
	OS.set_environment(BootClock.ENV, "1")
	OS.set_environment("GRIDFALL_OFFLINE", "1")
	OS.set_environment("GRIDFALL_MOUSE", "free")
	# The first-person boot, whatever the developer's shell exports: GRIDFALL_VIEW=orbit has no
	# FpMode, and a tool mode (smoke test, photo tour, trailer) returns from Main._ready before
	# BootClock.finish.
	OS.set_environment("GRIDFALL_VIEW", "fp")
	for mode: String in MAIN.TOOL_MODES:
		OS.unset_environment(mode)
	BootClock.reset()
	var log := LineLog.new()
	OS.add_logger(log)
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	var frames := 0
	var restored := false
	while not BootClock.completed() and frames < 120:
		await process_frame
		frames += 1
		var fp: Variant = main.get("fp")
		if not restored and fp != null and not BootClock.completed():
			# What Main._continue does for a saved city: every feature restores a second time.
			restored = true
			fp.from_dict({})
	OS.remove_logger(log)
	K.check(fails, BootClock.completed(), "the real Main boots through the end of the clock")
	var names := BootClock.names()
	var stages := PackedStringArray(
		[
			"ready_begin",
			"gpu_banner",
			"pack_stream",
			"await_frame",
			"frame_resumed",
			"resume_data",
			"view_setup",
			"hud_setup",
			"sky_setup",
			"fp_view_mode",
			"fp_collision",
			"fp_player",
			"fp_hud",
			"fp_world_rebuilt",
			"fp_from_dict",
			"fp_setup",
			"sim_start",
			"ready_end",
			"first_frame",
			"frame_2",
			"frame_3",
			"veil_frames",
		]
	)
	K.check(fails, _in_order(names, stages), "main.gd and fp_mode.gd mark the stages in order")
	var ids := _feature_ids()
	K.check(fails, not ids.is_empty(), "the registry lists features to mark")
	for phase: String in ["load", "setup", "world", "dict"]:
		var want := PackedStringArray()
		for id in ids:
			want.append("%s:%s" % [phase, id])
		var ok := _in_order(names, want)
		K.check(fails, ok, "every feature has a %s mark, in registry order" % phase)
	K.check(fails, restored, "the boot reached first person, so the second restore ran")
	var again := true
	for id in ids:
		again = again and names.has("dict:%s#2" % id)
	K.check(fails, again, "a second restore of every feature gets dict:<id>#2 marks")
	var seen := {}
	for n in names:
		seen[n] = true
	K.check(fails, seen.size() == names.size(), "every mark in the real boot has a unique name")
	var at := log.lines.find(BootClock.COMPLETE_LINE)
	var ended := at >= 1 and log.lines[at - 1].begins_with(BootClock.REPORT_PREFIX)
	K.check(fails, ended, "the boot-complete line follows the GF_BOOT line")
	main.queue_free()
	await process_frame


## True when every name in want appears in names, in that order (other names may sit between).
func _in_order(names: PackedStringArray, want: PackedStringArray) -> bool:
	var at := 0
	for w in want:
		at = names.find(w, at)
		if at < 0:
			return false
		at += 1
	return true


## The features FpMode.setup loads, in its order: the registry minus flagged-off and missing ones.
func _feature_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for entry: Dictionary in REGISTRY.FEATURES:
		var id := str(entry["id"])
		if FeatureFlags.enabled(id) and ResourceLoader.exists(str(entry["path"])):
			ids.append(id)
	return ids
