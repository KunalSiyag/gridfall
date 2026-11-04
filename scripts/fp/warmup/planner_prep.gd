class_name PlannerPrep
extends RefCounted
## "Preparing the Planner view": the honest way through the two moves that freeze the web page.
## Going up to the Planner the first time, the browser links about a hundred shader programs (the
## Planner draws every material with four shadow splits and exponential fog, and has materials of
## its own) and the view rebuilds the world; coming back down rebuilds the whole street.
## Each used to be one frozen frame of 3 to 5 seconds. Here, with the flag planner_prepare_overlay
## on (web only), Main hands the move to take(), which
##  1. shows the page's overlay (WebSupport.prepare_show: HTML, so its spinner keeps turning
##     while the game blocks) and waits two frames, so it is painted BEFORE anything heavy runs;
##  2. (opt-in: tuning key planner_warm, see warm_wanted) going up for the first time, draws the
##     Planner's materials in the Planner's state a few at a time (ShaderWarmup.warm_orbit) with
##     the overlay's bar following the work, so the links the move would do in one frame happen
##     here in frames of a few hundred ms. Measured on the day-10 city it did not pay (see
##     docs/runbooks/web-deploy.md), so by default there is no step 2: a spinner over the move;
##  3. makes the move itself (Main.exit_fp(true) / Main._back_to_street()) under the overlay, and
##     keeps it up until the frames settle (SETTLE_CALM frames in a row under SETTLE_FRAME_MS, at
##     most SETTLE_CAP_MS): the first frames after the move still freeze (the programs the new view
##     links as it first draws, the chunks it builds), measured at 0.6 to 1.3 s each, and with the
##     overlay down after two frames they were bare freezes. The wait is not shorter, it is
##     honest: the player sees the card until the picture moves.
## What is still frozen is the move's own rebuild (the world and the street are built in one frame)
## and any program the warm-up did not cover: the overlay says so, not a frozen picture.
## Off the web, with the flag off, take() does nothing and the move is as it was.

const FLAG := "planner_prepare_overlay"
## Frames waited after showing the overlay so the page has painted.
const PAINT_FRAMES := 2
## After the move the overlay stays until this many frames in a row took under SETTLE_FRAME_MS
## (a smooth web frame is 17 to 33 ms), or SETTLE_CAP_MS has passed (a slow machine is not held
## for ever: what is left freezes bare, as it did).
const SETTLE_CALM := 5
const SETTLE_FRAME_MS := 50.0
const SETTLE_CAP_MS := 6000.0
const TITLE_UP := "Preparing the Planner view"
const NOTE_UP := "The first time the screen may stand still for a few seconds."
const NOTE_UP_WARM := "The first time takes a few seconds while the browser readies the city view."
## The key in user://warmup_tuning.json that turns step 2 on (default false).
const WARM_KEY := "planner_warm"
const TITLE_DOWN := "Back to the street"
const NOTE_DOWN := "Rebuilding the street. The screen may stand still for a moment."

## Tests set this to run the move on the desktop.
static var force: bool = false
## True while a move is in progress; a second request in that time is swallowed.
static var busy: bool = false
## True once the Planner's variants have been drawn this session (a second visit links nothing new).
static var warmed: bool = false
## Tests: a Callable returning the clock in ms (default: Time.get_ticks_usec), so settling is
## deterministic.
static var clock_hook: Callable = Callable()
## Tests: called as show_hook(title, ratio, note) and hide_hook() instead of the page's overlay.
static var show_hook: Callable = Callable()
static var hide_hook: Callable = Callable()
## The last move's report ({"to_orbit", "warm", "ms", "frames"}).
static var report: Dictionary = {}


## Whether the move up draws the Planner's materials behind the overlay first (the tuning key
## planner_warm, with the flag warmup_orbit_variants on).
static func warm_wanted() -> bool:
	return (
		bool(ShaderWarmup.tuning().get(WARM_KEY, false))
		and FeatureFlags.enabled("warmup_orbit_variants", true)
	)


static func active() -> bool:
	return (force or WebSupport.is_web()) and FeatureFlags.enabled("planner_prepare_overlay", true)


## Takes over a move between the street and the Planner when the overlay is on: returns true (the
## caller returns at once, the move finishes later), false when the caller should move as before.
## to_orbit: leaving the street for the Planner; false: Tab down from the Planner to the street.
static func take(main: Node, to_orbit: bool) -> bool:
	if not active() or main == null or not main.is_inside_tree():
		return false
	if busy:
		return true
	busy = true
	_run(main, to_orbit)
	return true


static func _run(main: Node, to_orbit: bool) -> void:
	var tree := main.get_tree()
	var began := Time.get_ticks_usec()
	var warm_now := to_orbit and not warmed and warm_wanted() and is_instance_valid(main)
	var title := TITLE_UP if to_orbit else TITLE_DOWN
	var note := NOTE_DOWN
	if to_orbit:
		note = NOTE_UP_WARM if warm_now else NOTE_UP
	report = {"to_orbit": to_orbit, "warm": {}}
	_show(title, 0.0 if warm_now else -1.0, note)
	# The world holds still while the overlay is up: no key reaches the street (Tab, the pause menu)
	# and the warm-up's frames draw a scene that does not move. The move itself unpauses, as ever.
	tree.paused = true
	for _i in PAINT_FRAMES:
		await _frame(tree)
	# Main may be gone after the paint frames (the page reloads, the game quits): no warm-up then,
	# and the overlay still comes down below.
	if warm_now and is_instance_valid(main):
		var stamp := FirstUse.begin("planner", "warm")
		var warm := await ShaderWarmup.warm_orbit(main, _bar.bind(title, note))
		FirstUse.end("planner", "warm", stamp)
		warmed = true
		report["warm"] = warm
		_show(title, 1.0, note)
		await _frame(tree)
	var move_stamp := FirstUse.begin("planner", "move_up" if to_orbit else "move_down")
	if is_instance_valid(main):
		if to_orbit:
			main.call("exit_fp", true)
		else:
			main.call("_back_to_street")
	FirstUse.end("planner", "move_up" if to_orbit else "move_down", move_stamp)
	tree.paused = false
	var settle := await _settle(tree)
	_hide()
	report["settle"] = settle
	report["ms"] = snappedf(float(Time.get_ticks_usec() - began) / 1000.0, 0.1)
	print("PLANNERPREP " + JSON.stringify(report, "", false))
	busy = false


## Holds the overlay after the move until SETTLE_CALM frames in a row took under SETTLE_FRAME_MS
## (or SETTLE_CAP_MS has passed): the frames that follow a move are the ones that still link
## programs and build chunks. Returns {"frames", "ms", "calm": bool (settled, not cut by the cap)}.
static func _settle(tree: SceneTree) -> Dictionary:
	var began := _now_ms()
	var last := began
	var calm := 0
	var frames := 0
	# One clock read a frame, so a scripted clock (the tests) can say how long each frame took.
	while calm < SETTLE_CALM and last - began < SETTLE_CAP_MS:
		await _frame(tree)
		var now := _now_ms()
		frames += 1
		calm = calm + 1 if now - last < SETTLE_FRAME_MS else 0
		last = now
	return {"frames": frames, "ms": snappedf(last - began, 0.1), "calm": calm >= SETTLE_CALM}


static func _now_ms() -> float:
	if clock_hook.is_valid():
		return float(clock_hook.call())
	return float(Time.get_ticks_usec()) / 1000.0


## The warm-up's progress sink: the overlay's bar follows the work.
static func _bar(pct: int, _done: int, _total: int, title: String, note: String) -> void:
	_show(title, float(pct) / 100.0, note)


static func _show(title: String, ratio: float, note: String) -> void:
	if show_hook.is_valid():
		show_hook.call(title, ratio, note)
	else:
		WebSupport.prepare_show(title, ratio, note)


static func _hide() -> void:
	if hide_hook.is_valid():
		hide_hook.call()
	else:
		WebSupport.prepare_done()


## One drawn frame (a rendered one in a window, a process frame headless).
static func _frame(tree: SceneTree) -> void:
	if DisplayServer.get_name() == "headless":
		await tree.process_frame
	else:
		await RenderingServer.frame_post_draw
