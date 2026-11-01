extends SceneTree
## fp_bench's pipeline-compilation column: the monitors are RenderingDevice counters and read 0 on
## gl_compatibility (the web build's renderer), so a bench row from that renderer labels them n/a
## instead of reporting a misleading "none", while Forward+ and Mobile keep their deltas. Headless.
## Prints FP_BENCH_PIPELINES_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const BENCH := preload("res://tools/tests/fp_bench.gd")

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	print(("FP_BENCH_PIPELINES_TEST:   ok   " if ok else "FP_BENCH_PIPELINES_TEST:   FAIL ") + what)
	if not ok:
		fails.append(what)


func _init() -> void:
	# A script error in the helper under test would end this _init() early and leave the run to hang
	# until the gate's timeout: the watchdog turns that into a FAIL line.
	K.watchdog(self, "FP_BENCH_PIPELINES_TEST", 60.0)
	await process_frame
	var deltas := {"draw": 2, "surface": 1}
	var gl: Variant = BENCH.pipelines_for("gl_compatibility", deltas)
	check(
		gl is String and (gl as String).begins_with("n/a"), "gl_compatibility: the column says n/a"
	)
	check(str(gl).contains("gl_compatibility"), "...and names the renderer")
	check(BENCH.pipelines_for("gl_compatibility", {}) is String, "...also when no counter moved")
	check(BENCH.pipelines_for("forward_plus", deltas) == deltas, "forward_plus: the deltas")
	check(BENCH.pipelines_for("mobile", {}) == {}, "mobile: an empty delta stays empty")
	var row: Dictionary = BENCH._hitch(
		40.0, 0.0, 0.0, BENCH.pipelines_for("gl_compatibility", deltas), 0.0
	)
	check(row["pipelines"] is String, "a hitch row carries the label")
	var rd: Dictionary = BENCH._hitch(
		40.0, 0.0, 0.0, BENCH.pipelines_for("forward_plus", deltas), 0.0
	)
	check(rd["pipelines"] == deltas, "...or the deltas")
	K.finish(self, "FP_BENCH_PIPELINES_TEST", fails)
