extends SceneTree
## Free running (flag free_running; docs/fp/ARCHITECTURE.md, Parkour): Shift held on a straight run
## builds up over SPRINT_BUILD s to a sprint (WS.SPRINT, 6.5 m/s); letting go, a hard turn, a
## crouch or the flag off drops it back to a run. At a sprint a 1 m wall just ahead is vaulted and a
## 0.5 m ledge hopped onto with no press, a 1.5 m one still stops the body; Space at a 2.7 m ledge
## runs up it and climbs over (at a stand it is a wall to take hold of), one above RUN_UP_MAX is a
## wall. An edge with a roof across a 2.5 m gap is leapt, landing on it; a gap too wide, ground
## across higher than the feet, a beam over the gap and the flag off leave the body to run off the
## edge; at a run it runs off too and the hands catch the far roof. Coming down from a running jump
## at a 1.8 m ledge the hands catch it and climb onto it; dropping straight down by it, nothing.
## Third person on a grown city; time runs through the features' tick(1/60) and the player's
## simulate and update_view.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const MOVES := preload("res://scripts/fp/parkour/moves.gd")
const PL := preload("res://scripts/fp/player/player.gd")
const DT := 1.0 / 60.0
const M := WS.M
const R_M := WS.PLAYER_RADIUS / WS.M

var fails: Array[String] = []
var ctx: FpContext
var f: FpFeature
var health: FpFeature
## The test lane: its start (the feet), its direction and the right of it.
var start: Vector3
var run: Vector3
var right: Vector3
var yaw_deg: float
## Every hero_action and every landing's speed (m/s) since the last _sprint_up.
var actions: Array[String] = []
var landings: Array[float] = []


func _init() -> void:
	await process_frame
	if not _fixture():
		K.finish(self, "FP_FREERUN_TEST", fails)
		return
	_check_setup()
	_check_build()
	_check_drop_back()
	_check_auto_moves()
	_check_run_up()
	_check_leap()
	_check_leap_refusals()
	_check_catch()
	_check_counts()
	K.finish(self, "FP_FREERUN_TEST", fails)


# ------------------------------------------------------------------ helpers


## The city, the health and parkour features and the lane: false (a failed check) without them.
func _fixture() -> bool:
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	var p := ctx.player
	p.set_process(false)
	p.input_enabled = true
	health = K.make_feature(ctx, "health")
	f = K.make_feature(ctx, "parkour")
	var lane := K.sidewalk(ctx, 0.7)
	var ok := f != null and health != null and not lane.is_empty()
	K.check(fails, ok, "fixture: the health and parkour features, a clear straight sidewalk")
	if not ok:
		return false
	f.set_process(false)
	health.set_process(false)
	ctx.bus.hero_action.connect(func(a: String, _at: Vector3) -> void: actions.append(a))
	p.landed.connect(func(v: float, _rolled: bool) -> void: landings.append(v))
	start = lane["pos"]
	run = lane["run"]
	right = Vector3(-run.z, 0.0, run.x)
	yaw_deg = lane["yaw"]
	return true


## One frame as _process runs it: parkour first, then health, then the player.
func _frame(wish: Vector2, sprint: bool, jump: bool = false, crouch: bool = false) -> void:
	f.call("tick", DT)
	health.call("tick", DT)
	ctx.player.simulate(wish, sprint, DT, crouch, jump)
	ctx.player.update_view(DT)


## The view-relative wish that walks along dir (unit, xz) whatever the camera does.
func _wish(dir: Vector3) -> Vector2:
	var cy := ctx.player.cam_yaw
	return Vector2(dir.x * cos(cy) - dir.z * sin(cy), -dir.x * sin(cy) - dir.z * cos(cy))


## The lane point ahead metres along it, up metres above its start.
func _lane_point(ahead: float, up: float = 0.0) -> Vector3:
	return start + run * ahead * M + Vector3(0.0, up * M, 0.0)


func _ahead() -> float:
	return (ctx.player.position - start).dot(run) / M


func _up() -> float:
	return (ctx.player.position.y - start.y) / M


func _speed() -> float:
	var v := ctx.player.velocity
	return Vector2(v.x, v.z).length() / M


## A box across the lane, its face ahead metres along it, depth deep, height tall from base above
## the sidewalk, 2 m wide.
func _box(ahead: float, depth: float, height: float, base: float = 0.0) -> void:
	var c := _lane_point(ahead + depth * 0.5)
	var size := (run.abs() * depth + right.abs() * 2.0 + Vector3(0.0, height, 0.0)) * M
	var lo := Vector3(c.x - size.x * 0.5, start.y + base * M, c.z - size.z * 0.5)
	ctx.collision.add_test_box(AABB(lo, size))


## Puts the hero at the lane point ahead metres along it (up metres up) and holds Shift and the
## run along the lane there, the body kept on the spot like on a treadmill, until the sprint has
## built up and reached full pace (or secs): the seconds it took. Clears the actions and landings.
func _sprint_up(ahead: float, up: float = 0.0, secs: float = 5.0) -> float:
	var p := ctx.player
	var spot := _lane_point(ahead, up)
	p.teleport(spot, yaw_deg, 0.0, up <= 0.0)
	var t := 0.0
	while t < secs:
		_frame(_wish(run), true)
		t += DT
		p.position -= run * (p.position - spot).dot(run)
		if p.sprinting() and _speed() >= WS.SPRINT / M - 0.05:
			break
	actions.clear()
	landings.clear()
	return t


## Runs on along the lane with sprint held for secs, pressing jump once the gap to a face `face`
## metres ahead is at most gap (no press for gap < 0); stops early once the hero has stood 0.3 s
## after landing or a move. The lowest height (m above the lane) the feet came to.
func _run_on(secs: float, face: float = 0.0, gap: float = -1.0) -> float:
	var p := ctx.player
	var low := INF
	var stood := 0.0
	var pressed := false
	var left := false
	var t := 0.0
	while t < secs and stood < 0.3:
		var press := not pressed and gap >= 0.0 and face - _ahead() - R_M <= gap
		pressed = pressed or press
		_frame(_wish(run), true, press)
		t += DT
		low = minf(low, _up())
		left = left or not p.grounded or p.carried
		stood = stood + DT if left and p.grounded and not p.carried else 0.0
	return low


# ------------------------------------------------------------------ checks


func _check_setup() -> void:
	var p := ctx.player
	K.check(
		fails,
		FeatureFlags.enabled("free_running") and p.free_running,
		"the free_running flag is on by default"
	)
	var st := f.self_test()
	K.check(fails, bool(st.get("ok", false)), "self_test (%s)" % st.get("detail", ""))
	K.check(fails, is_equal_approx(WS.SPRINT / M, 6.5), "a sprint is 6.5 m/s")


## Shift held on a straight run: the sprint builds SPRINT_BUILD s after the pace reaches
## SPRINT_KEEP of a run, then the body speeds up to 6.5 m/s. With free running off it tops out at
## a run.
func _check_build() -> void:
	var p := ctx.player
	p.teleport(_lane_point(0.0), yaw_deg)
	var spot := _lane_point(0.0)
	var t := 0.0
	var at_keep := -1.0
	var at_sprint := -1.0
	while t < 4.0:
		_frame(_wish(run), true)
		t += DT
		p.position -= run * (p.position - spot).dot(run)
		if at_keep < 0.0 and _speed() >= WS.RUN / M * PL.SPRINT_KEEP:
			at_keep = t
		if at_sprint < 0.0 and p.sprinting():
			at_sprint = t
	var built := at_keep > 0.0 and absf(at_sprint - at_keep - PL.SPRINT_BUILD) <= 2.5 * DT
	K.check(
		fails,
		built,
		(
			"the sprint builds %.2f s after the pace reaches a run (%.2f s in)"
			% [at_sprint - at_keep, at_keep]
		)
	)
	K.check(
		fails,
		p.sprinting() and absf(_speed() - 6.5) < 0.05,
		"and the body speeds up to 6.5 m/s (%.2f m/s)" % _speed()
	)
	p.free_running = false
	var top := 0.0
	p.teleport(spot, yaw_deg)
	for _k in range(240):
		_frame(_wish(run), true)
		p.position -= run * (p.position - spot).dot(run)
		top = maxf(top, _speed())
	p.free_running = true
	K.check(
		fails,
		not p.sprinting() and top <= WS.RUN / M + 0.01,
		"free running off: Shift tops out at a run (%.2f m/s)" % top
	)


## The sprint drops back: Shift let go, a hard turn, a crouch.
func _check_drop_back() -> void:
	var p := ctx.player
	_sprint_up(0.0)
	_frame(_wish(run), false)
	var let_go := not p.sprinting()
	_sprint_up(0.0)
	_frame(_wish(right), true)
	var turned := not p.sprinting()
	_sprint_up(0.0)
	_frame(_wish(run), true, false, true)
	var crouched := not p.sprinting()
	K.check(
		fails,
		let_go and turned and crouched,
		(
			"Shift let go, a hard turn or a crouch drops the sprint (%s, %s, %s)"
			% [let_go, turned, crouched]
		)
	)
	_frame(Vector2.ZERO, false)
	for _k in range(20):
		_frame(_wish(run), true)
	K.check(fails, not p.sprinting(), "and it builds again from scratch")
	for _k in range(60):
		_frame(Vector2.ZERO, false)


## At a sprint a 1 m wall 0.3 m deep just ahead is vaulted and a 0.5 m ledge hopped onto with no
## press; a 1.5 m ledge stops the body. With the flag off the 1 m wall stops it too.
func _check_auto_moves() -> void:
	var auto0 := int(f.get("auto_moves"))
	_box(4.0, 0.3, 1.0)
	_sprint_up(0.0)
	_run_on(3.0)
	var over := actions == ["vault"] and _ahead() > 4.3 + R_M and absf(_up()) < 1e-3
	K.check(
		fails,
		over and landings.size() == 1,
		"at a sprint a 1 m wall is vaulted unasked (%s, %.2f m along)" % [actions, _ahead()]
	)
	FeatureFlags.set_override("free_running", false)
	_sprint_up(0.0)
	_run_on(1.5)
	FeatureFlags.set_override("free_running", true)
	K.check(
		fails,
		actions.is_empty() and _ahead() < 4.0,
		"flag off: the wall stops the run (%s, %.2f m along)" % [actions, _ahead()]
	)
	ctx.collision.clear_test_boxes()
	_box(4.0, 3.0, 0.5)
	_sprint_up(0.0)
	_run_on(1.5)
	K.check(
		fails,
		actions[0] == "hop" if not actions.is_empty() else false,
		"a 0.5 m ledge is hopped onto (%s, %.2f m up)" % [actions, _up()]
	)
	ctx.collision.clear_test_boxes()
	_box(4.0, 3.0, 1.5)
	_sprint_up(0.0)
	_run_on(1.5)
	K.check(
		fails,
		actions.is_empty() and _ahead() < 4.0,
		"a 1.5 m ledge is no vault: it stops the run (%s)" % [actions]
	)
	ctx.collision.clear_test_boxes()
	K.check(fails, int(f.get("auto_moves")) - auto0 == 2, "two moves made unasked")


## Space at a 2.7 m ledge at a sprint runs up it and climbs over, standing on top; at a walk the
## same ledge is a wall to take hold of, and at a sprint one 3.5 m tall too.
func _check_run_up() -> void:
	var p := ctx.player
	_box(5.0, 3.0, 2.7)
	_sprint_up(0.0)
	_run_on(4.0, 5.0, 0.4)
	K.check(
		fails,
		actions == ["run_up"] and absf(_up() - 2.7) < 1e-3 and _ahead() > 5.0,
		"at a sprint Space at a 2.7 m ledge runs up it (%s, %.2f m up)" % [actions, _up()]
	)
	ctx.collision.clear_test_boxes()
	_box(1.0, 2.0, 2.7)
	p.teleport(_lane_point(1.0 - R_M - 0.3), yaw_deg)
	actions.clear()
	_frame(Vector2.ZERO, false, true)
	K.check(
		fails,
		str(f.get("move")) == "wall" and actions == ["grab"],
		"at a stand it is a wall to take hold of (%s)" % [actions]
	)
	f.call("stop")
	for _k in range(60):
		_frame(Vector2.ZERO, false)
	ctx.collision.clear_test_boxes()
	_box(1.0, 2.0, 3.5)
	_sprint_up(0.0)
	_run_on(0.6, 1.0, 0.4)
	K.check(fails, actions == ["grab"], "a 3.5 m one at a sprint is a wall (%s)" % [actions])
	f.call("stop")
	for _k in range(60):
		_frame(Vector2.ZERO, false)
	ctx.collision.clear_test_boxes()


## On a 1.5 m roof with another across a 2.5 m gap: at a sprint the hero leaps at the edge with no
## press and lands on the far roof, never dropping below it.
func _check_leap() -> void:
	_box(-2.0, 6.0, 1.5)
	_box(6.5, 6.0, 1.5)
	_sprint_up(0.0, 1.5)
	var low := _run_on(3.0)
	K.check(
		fails,
		actions == ["leap"] and _ahead() > 6.5 and absf(_up() - 1.5) < 1e-3,
		(
			"at a sprint the hero leaps the gap (%s, %.2f m along, %.2f up)"
			% [actions, _ahead(), _up()]
		)
	)
	K.check(fails, low > 1.5 - 1e-3, "and never drops below the roofs (%.2f m)" % low)
	ctx.collision.clear_test_boxes()


## No leap: the gap too wide (6 m), ground across higher than the feet, a beam over the gap and
## the flag off (the body runs off the edge and drops); at a run short of a sprint the body runs off
## it too, and coming down the hands catch the far roof's edge.
func _check_leap_refusals() -> void:
	var edge := _lane_point(4.0 - 0.1, 1.5)
	var v := run * WS.SPRINT
	_box(-2.0, 6.0, 1.5)
	_box(10.0, 3.0, 1.5)
	var wide := MOVES.leap(ctx.collision, edge, v, WS.SPRINT).is_empty()
	ctx.collision.clear_test_boxes()
	_box(-2.0, 6.0, 1.5)
	_box(6.5, 3.0, 2.0)
	var higher := MOVES.leap(ctx.collision, edge, v, WS.SPRINT).is_empty()
	ctx.collision.clear_test_boxes()
	_box(-2.0, 6.0, 1.5)
	_box(6.5, 3.0, 1.5)
	var fine := not MOVES.leap(ctx.collision, edge, v, WS.SPRINT).is_empty()
	_box(5.0, 0.3, 0.3, 2.6)
	var beam := MOVES.leap(ctx.collision, edge, v, WS.SPRINT).is_empty()
	K.check(
		fails,
		wide and higher and fine and beam,
		"no leap across 6 m, up 0.5 m or under a beam (%s, %s, %s, %s)" % [wide, higher, fine, beam]
	)
	ctx.collision.clear_test_boxes()
	_box(-2.0, 6.0, 1.5)
	_box(6.5, 6.0, 1.5)
	FeatureFlags.set_override("free_running", false)
	_sprint_up(0.0, 1.5)
	_run_on(3.0)
	FeatureFlags.set_override("free_running", true)
	K.check(
		fails,
		actions.is_empty() and _up() < 1.0,
		"flag off: the hero runs off the edge (%s, %.2f m up)" % [actions, _up()]
	)
	var p := ctx.player
	p.free_running = false
	_sprint_up(0.0, 1.5, 2.0)
	_run_on(3.0)
	p.free_running = true
	K.check(
		fails,
		actions == ["catch"] and absf(_up() - 1.5) < 1e-3 and _ahead() > 6.5,
		"at a run: no leap, the hero runs off and the hands catch the far roof (%s)" % [actions]
	)
	ctx.collision.clear_test_boxes()


## A running jump at a 1.8 m ledge 3 m deep pressed 2.9 m short of it: coming down the hands catch
## it and the hero climbs onto it. Dropped from 1 m up right by it, standing still: nothing.
func _check_catch() -> void:
	var p := ctx.player
	_box(5.0, 3.0, 1.8)
	_sprint_up(0.0)
	_run_on(4.0, 5.0, 2.9)
	K.check(
		fails,
		actions == ["catch"] and absf(_up() - 1.8) < 1e-3 and _ahead() > 5.0,
		(
			"a running jump short of a 1.8 m ledge catches it and climbs on (%s, %.2f m up)"
			% [actions, _up()]
		)
	)
	p.teleport(_lane_point(5.0 - R_M - 0.2, 1.0), yaw_deg, 0.0, false)
	actions.clear()
	for _k in range(60):
		_frame(Vector2.ZERO, false)
	K.check(fails, actions.is_empty() and absf(_up()) < 1e-3, "dropped beside it: nothing")
	ctx.collision.clear_test_boxes()


func _check_counts() -> void:
	var made: Dictionary = f.get("made")
	var counted := int(made["run_up"]) == 1 and int(made["leap"]) == 1 and int(made["catch"]) == 2
	var st := f.self_test()
	K.check(
		fails,
		counted and bool(st.get("ok", false)),
		"run-ups, leaps and catches are counted (%s)" % st.get("detail", "")
	)
