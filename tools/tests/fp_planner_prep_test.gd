extends SceneTree
## "Preparing the Planner view" (scripts/fp/warmup/planner_prep.gd, flag planner_prepare_overlay):
## on the web the first move from the street to the Planner and every Tab back show the page's
## overlay BEFORE the heavy frame, warm the Planner's materials behind it with a bar that follows
## the work (first time only), make the move, and take the overlay down. Off the web or with the
## flag off nothing changes. Headless and offline; a fake Main stands in for the real one (the real
## one is booted by the browser probe). Prints FP_PLANNER_PREP_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const TOKEN := "FP_PLANNER_PREP_TEST"

var fails: Array[String] = []
var events: Array[String] = []
var bars: Array[float] = []
var frame_at_show := -1
var frames_to_move := -1
var paused_at_move := false
var frame_at_move := -1
var frame_at_hide := -1
## The scripted clock (ms per frame; the last one repeats) PlannerPrep reads while settling.
var frame_ms: Array = [10.0]
var _clock_t := 0.0
var _clock_calls := 0


class FakeMain:
	extends Node3D
	var cam: Camera3D
	var sun_light: DirectionalLight3D
	var fp: Variant = null
	var prep_test: Object

	func active_camera() -> Camera3D:
		return cam

	func exit_fp(prepared: bool = false) -> void:
		prep_test.call("moved", "exit_fp(%s)" % str(prepared))

	func _back_to_street() -> void:
		prep_test.call("moved", "back_to_street")


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func moved(what: String) -> void:
	events.append("move:" + what)
	frame_at_move = Engine.get_process_frames()
	paused_at_move = get_root().get_tree().paused
	frames_to_move = Engine.get_process_frames() - frame_at_show


func _show(title: String, ratio: float, _note: String) -> void:
	if frame_at_show < 0:
		frame_at_show = Engine.get_process_frames()
	events.append("show:%s" % title)
	bars.append(ratio)


func _hide() -> void:
	events.append("hide")
	frame_at_hide = Engine.get_process_frames()


## The first read is the start; each later one is one frame on.
func _clock() -> float:
	if _clock_calls > 0:
		_clock_t += float(frame_ms[mini(_clock_calls - 1, frame_ms.size() - 1)])
	_clock_calls += 1
	return _clock_t


func _init() -> void:
	K.watchdog(self, TOKEN, 120.0)
	await process_frame
	var flag_before := FeatureFlags.enabled(PlannerPrep.FLAG, true)
	await _check_off()
	await _check_up_and_down()
	await _check_settle()
	await _check_main_freed()
	_check_call_sites()
	FeatureFlags.set_override(PlannerPrep.FLAG, flag_before)
	PlannerPrep.force = false
	PlannerPrep.show_hook = Callable()
	PlannerPrep.hide_hook = Callable()
	PlannerPrep.clock_hook = Callable()
	K.finish(self, TOKEN, fails)


func _fake_main() -> FakeMain:
	var m := FakeMain.new()
	m.name = "FakeMain"
	m.prep_test = self
	get_root().add_child(m)
	m.cam = Camera3D.new()
	m.add_child(m.cam)
	m.sun_light = DirectionalLight3D.new()
	m.add_child(m.sun_light)
	for k in 3:
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		var mat := StandardMaterial3D.new()
		mat.cull_mode = k as BaseMaterial3D.CullMode
		mi.material_override = mat
		m.add_child(mi)
	return m


func _reset() -> void:
	events.clear()
	bars.clear()
	frame_at_show = -1
	frames_to_move = -1
	PlannerPrep.busy = false
	PlannerPrep.warmed = false
	PlannerPrep.report = {}
	PlannerPrep.show_hook = _show
	PlannerPrep.hide_hook = _hide
	frame_ms = [10.0]
	_clock_t = 0.0
	_clock_calls = 0
	frame_at_move = -1
	frame_at_hide = -1
	PlannerPrep.clock_hook = _clock


func _wait_done() -> void:
	var guard := 0
	while PlannerPrep.busy and guard < 2000:
		guard += 1
		await process_frame


## Off the web, or with the flag off, take() leaves the move to the caller.
func _check_off() -> void:
	_reset()
	var m := _fake_main()
	PlannerPrep.force = false
	FeatureFlags.set_override(PlannerPrep.FLAG, true)
	check(not PlannerPrep.active(), "desktop: not active")
	check(not PlannerPrep.take(m, true) and events.is_empty(), "desktop: take() does nothing")
	PlannerPrep.force = true
	FeatureFlags.set_override(PlannerPrep.FLAG, false)
	check(not PlannerPrep.active(), "flag off: not active")
	check(not PlannerPrep.take(m, true) and not PlannerPrep.busy, "flag off: take() does nothing")
	check(events.is_empty() and not PlannerPrep.warmed, "flag off: no overlay, no warm-up")
	FeatureFlags.set_override(PlannerPrep.FLAG, true)
	check(PlannerPrep.active(), "force and the flag: active")
	m.free()


func _check_up_and_down() -> void:
	_reset()
	PlannerPrep.force = true
	FeatureFlags.set_override(PlannerPrep.FLAG, true)
	var m := _fake_main()
	# By default the move up is the overlay over the move: a spinner, no warm-up (planner_warm is
	# opt-in, measured not to pay), and the world is held still until the move.
	_clear_tuning()
	check(not PlannerPrep.warm_wanted(), "the Planner warm-up is off by default")
	check(PlannerPrep.take(m, true), "the move up is taken over")
	await _wait_done()
	check(
		events == ["show:%s" % PlannerPrep.TITLE_UP, "move:exit_fp(true)", "hide"],
		"default: overlay, move, overlay down (%s)" % str(events)
	)
	check(
		bars.size() == 1 and bars[0] < 0.0 and not PlannerPrep.warmed, "default: a spinner, no bar"
	)
	check(paused_at_move, "default: the world was held still until the move")
	_reset()
	_write_tuning({"planner_warm": true})
	check(PlannerPrep.warm_wanted(), "the tuning key turns the warm-up on")
	# Up, the first time with the warm-up: overlay, warm-up with a bar, the move, the overlay down.
	check(PlannerPrep.take(m, true), "the first move up is taken over")
	check(PlannerPrep.busy and PlannerPrep.take(m, true), "a second request meanwhile is swallowed")
	check(
		events.size() == 1 and events[0].begins_with("show:"), "the overlay is shown first, at once"
	)
	check(not bars.is_empty() and is_equal_approx(bars[0], 0.0), "the bar starts at 0")
	await _wait_done()
	var paused := paused_state()
	var moves := events.filter(func(e: String) -> bool: return e.begins_with("move:"))
	check(moves == ["move:exit_fp(true)"], "the move runs once, prepared (%s)" % str(moves))
	check(
		events[-1] == "hide" and events.find("hide") > events.find("move:exit_fp(true)"),
		"the overlay comes down after the move"
	)
	check(
		frames_to_move >= PlannerPrep.PAINT_FRAMES,
		(
			"the move waits %d frames for the overlay to paint (%d)"
			% [PlannerPrep.PAINT_FRAMES, frames_to_move]
		)
	)
	var mono := true
	for k in range(1, bars.size()):
		mono = mono and bars[k] >= bars[k - 1] - 0.0001
	check(
		mono and bars.size() >= 3,
		"the bar follows the work and never goes back (%d updates)" % bars.size()
	)
	check(bars.max() >= 0.99, "and reaches the end (%.2f)" % bars.max())
	check(PlannerPrep.warmed, "the Planner's materials were drawn")
	check(paused_at_move, "the world was held still until the move")
	check(not paused, "and the tree runs again afterwards")
	var warm: Dictionary = PlannerPrep.report.get("warm", {})
	check(
		not warm.is_empty() and int(warm["orbit_recipes"]) > 0 and int(warm["state"]["drawn"]) > 0,
		"the warm-up drew the scene and the catalogue (%s)" % str(warm).left(90)
	)
	check(m.cam.get_child_count() == 0, "no warm-up stage is left under the camera")
	# Down: overlay with no bar, the move, the overlay down.
	events.clear()
	bars.clear()
	frame_at_show = -1
	check(PlannerPrep.take(m, false), "Tab back is taken over")
	await _wait_done()
	check(
		events == ["show:%s" % PlannerPrep.TITLE_DOWN, "move:back_to_street", "hide"],
		"back: overlay, move, overlay down (%s)" % str(events)
	)
	check(bars.size() == 1 and bars[0] < 0.0, "back: a spinner with no bar (nothing to count)")
	# Up again: the variants are already warm, so no warm-up and no bar.
	events.clear()
	bars.clear()
	frame_at_show = -1
	check(PlannerPrep.take(m, true), "the second move up is taken over")
	await _wait_done()
	check(
		events == ["show:%s" % PlannerPrep.TITLE_UP, "move:exit_fp(true)", "hide"],
		"second time up: no warm-up (%s)" % str(events)
	)
	check(not PlannerPrep.busy, "idle afterwards")
	# Flag warmup_orbit_variants off: the overlay still covers the move, but nothing is warmed.
	events.clear()
	bars.clear()
	frame_at_show = -1
	PlannerPrep.warmed = false
	FeatureFlags.set_override("warmup_orbit_variants", false)
	check(PlannerPrep.take(m, true), "variants off: the move is still taken over")
	await _wait_done()
	check(
		events == ["show:%s" % PlannerPrep.TITLE_UP, "move:exit_fp(true)", "hide"],
		"variants off: overlay, move, overlay down, no warm-up (%s)" % str(events)
	)
	check(not PlannerPrep.warmed and bars.size() == 1 and bars[0] < 0.0, "variants off: no bar")
	FeatureFlags.set_override("warmup_orbit_variants", true)
	_clear_tuning()
	m.free()


## The overlay stays up until the frames after the move settle: SETTLE_CALM frames in a row under
## SETTLE_FRAME_MS (the bare freezes after the move used to come after the overlay was gone).
func _check_settle() -> void:
	_reset()
	PlannerPrep.force = true
	FeatureFlags.set_override(PlannerPrep.FLAG, true)
	_clear_tuning()
	var m := _fake_main()
	# Quiet frames from the start: exactly SETTLE_CALM frames after the move.
	check(PlannerPrep.take(m, false), "settle: Tab back taken over")
	await _wait_done()
	var settle: Dictionary = PlannerPrep.report.get("settle", {})
	check(
		(
			int(settle.get("frames", -1)) == PlannerPrep.SETTLE_CALM
			and bool(settle.get("calm", false))
		),
		(
			"quiet frames: the overlay comes down after %d (%s)"
			% [PlannerPrep.SETTLE_CALM, str(settle)]
		)
	)
	check(
		frame_at_hide - frame_at_move >= PlannerPrep.SETTLE_CALM,
		"the overlay stays up %d frames after the move" % (frame_at_hide - frame_at_move)
	)
	# Two freezes (0.9 s and 0.6 s) then a calm run: the overlay waits through both.
	_reset()
	frame_ms = [900.0, 600.0, 10.0]
	check(PlannerPrep.take(m, true), "settle: the move up is taken over")
	await _wait_done()
	settle = PlannerPrep.report.get("settle", {})
	check(
		int(settle.get("frames", -1)) == 2 + PlannerPrep.SETTLE_CALM and bool(settle["calm"]),
		(
			"freezes after the move are covered, then %d calm frames (%s)"
			% [PlannerPrep.SETTLE_CALM, str(settle)]
		)
	)
	check(
		frame_at_hide - frame_at_move >= 2 + PlannerPrep.SETTLE_CALM,
		(
			"the overlay was still up for the freezes (%d frames after the move)"
			% (frame_at_hide - frame_at_move)
		)
	)
	# A slow frame in the middle of the calm run starts the count again.
	_reset()
	frame_ms = [10.0, 10.0, 10.0, 80.0, 10.0]
	check(PlannerPrep.take(m, false), "settle: Tab back taken over again")
	await _wait_done()
	settle = PlannerPrep.report.get("settle", {})
	check(
		int(settle.get("frames", -1)) == 4 + PlannerPrep.SETTLE_CALM,
		"a slow frame restarts the calm count (%s)" % str(settle)
	)
	# A machine that never settles is held for SETTLE_CAP_MS and no longer.
	_reset()
	frame_ms = [100.0]
	check(PlannerPrep.take(m, false), "settle: Tab back taken over, slow machine")
	await _wait_done()
	settle = PlannerPrep.report.get("settle", {})
	check(
		(
			not bool(settle.get("calm", true))
			and float(settle.get("ms", 0.0)) >= PlannerPrep.SETTLE_CAP_MS
			and float(settle.get("ms", 0.0)) < PlannerPrep.SETTLE_CAP_MS + 200.0
		),
		"a frame time that never settles is cut at the cap (%s)" % str(settle)
	)
	check(events[-1] == "hide" and not PlannerPrep.busy, "and the overlay still comes down")
	_clear_tuning()
	m.free()


## Main freed while the overlay is up (the game quits or reloads mid-move): no move, the overlay
## comes down, the tree runs, a new request is not swallowed.
func _check_main_freed() -> void:
	for warm in [false, true]:
		_reset()
		PlannerPrep.force = true
		FeatureFlags.set_override(PlannerPrep.FLAG, true)
		if warm:
			_write_tuning({"planner_warm": true})
		var m := _fake_main()
		check(PlannerPrep.take(m, true), "freed: the move up is taken over (warm %s)" % str(warm))
		await process_frame
		m.free()
		await _wait_done()
		var moves := events.filter(func(e: String) -> bool: return e.begins_with("move:"))
		check(moves.is_empty(), "freed: no move on a freed Main (warm %s)" % str(warm))
		check(events[-1] == "hide", "freed: the overlay comes down (warm %s)" % str(warm))
		check(
			not PlannerPrep.busy and not paused_state(),
			"freed: idle and unpaused (warm %s)" % str(warm)
		)
		_clear_tuning()


## The call sites: Main routes the move through PlannerPrep, the loader page defines the overlay.
func _check_call_sites() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/main.gd")
	check(
		(
			src.contains("func exit_fp(prepared: bool = false)")
			and src.contains("func _back_to_street()")
		),
		"Main has the move entry points"
	)
	# The hooks must be the unconditional statements (a mutant such as `if false and ...` or a
	# dropped `return` would turn the overlay off or run the move twice).
	var up_pat := "\\n\\tif not prepared and PlannerPrep\\.take\\(self, true\\):"
	up_pat += "\\n\\t\\treturn\\n\\t_fp_saved = "
	var up := RegEx.create_from_string(up_pat)
	check(up.search(src) != null, "exit_fp hands the move up to PlannerPrep and returns")
	var down_pat := "\\n\\tif PlannerPrep\\.take\\(self, false\\):[^\\n]*"
	down_pat += "\\n\\t\\treturn[^\\n]*\\n\\t_back_to_street\\(\\)"
	var down := RegEx.create_from_string(down_pat)
	check(down.search(src) != null, "Tab back hands the move down to PlannerPrep and returns")
	var html := FileAccess.get_file_as_string("res://tools/web_export.py")
	check(
		(
			html.contains("window.gfPrepare = function")
			and html.contains("window.gfPrepareDone = function")
		),
		"the loader page defines the overlay hooks"
	)
	var ws := FileAccess.get_file_as_string("res://scripts/ops/web_support.gd")
	check(
		(
			ws.contains("window.gfPrepare(title, ratio, note)")
			and ws.contains("window.gfPrepareDone()")
		),
		"WebSupport calls them"
	)


func paused_state() -> bool:
	return get_root().get_tree().paused


const TUNING := "user://warmup_tuning.json"


func _write_tuning(d: Dictionary) -> void:
	var f := FileAccess.open(TUNING, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()


func _clear_tuning() -> void:
	if FileAccess.file_exists(TUNING):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TUNING))
