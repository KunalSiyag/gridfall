extends SceneTree
## Parkour (integration feature "parkour"; docs/fp/ARCHITECTURE.md, Parkour): jump presses in
## front of obstacles on a clear sidewalk. A run at a low wall vaults it (over its top, a soft
## landing beyond it; from an angle the move goes straight across and turns the body); a low ledge
## is hopped onto and a higher one climbed (the rig's climb clip, the body leaving the ground only
## at the face and ending on top). A wall taller than that is taken hold of (flag wall_climb): the
## hero leaps onto its face and hangs there in the rig's wall pose, the IK putting hands and feet on
## their holds; the move keys climb it (faster with sprint), along it to short of its end, over the
## top onto a roof with room to stand and down to its foot; with no room on top the hero hangs on,
## and an overhang stops the climb. Crouch drops off it, a jump pushes off it. A wall too high with
## wall_climb off, a post, a wall under an awning, no room to land or stand, a crouch, an approach
## far off head-on and the parkour flag off leave an ordinary jump, and no press no move. A climb
## cut short half over its ledge leaves the body clear of it; a knock-down, a teleport and a load
## end a move (on a wall too, as does the wall going away), photo mode does not start during one,
## and teardown hands jumps back. Third person on a grown city; time runs through the features'
## tick(1/60) and the player's simulate and update_view.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const MOVES := preload("res://scripts/fp/parkour/moves.gd")
const WALL := preload("res://scripts/fp/parkour/wall.gd")
const HEALTH := preload("res://scripts/fp/health/health_feature.gd")
const DT := 1.0 / 60.0
const M := WS.M
const R_M := WS.PLAYER_RADIUS / WS.M

var fails: Array[String] = []
var ctx: FpContext
var f: FpFeature
var health: FpFeature
var rig: RefCounted
## The test lane: its start (the feet), its direction, the right of it and its yaw (degrees).
var start: Vector3
var run: Vector3
var right: Vector3
var yaw_deg: float
## Every hero_action and every landing speed (m/s) since the last _press_at.
var actions: Array[String] = []
var landings: Array[float] = []


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	health = K.make_feature(ctx, "health")
	f = K.make_feature(ctx, "parkour")
	if f == null or health == null:
		K.check(fails, false, "the health and parkour features are registered")
		K.finish(self, "FP_PARKOUR_TEST", fails)
		return
	f.set_process(false)
	health.set_process(false)
	var p := ctx.player
	p.input_enabled = true
	rig = p.avatar.get("rig")
	ctx.bus.hero_action.connect(func(a: String, _at: Vector3) -> void: actions.append(a))
	p.landed.connect(func(v: float) -> void: landings.append(v))
	var lane := K.sidewalk(ctx, 0.4)
	K.check(fails, not lane.is_empty() and rig != null, "fixture: a clear sidewalk, HC's hero")
	if lane.is_empty() or rig == null:
		K.finish(self, "FP_PARKOUR_TEST", fails)
		return
	start = lane["pos"]
	run = lane["run"]
	right = Vector3(-run.z, 0.0, run.x)
	yaw_deg = lane["yaw"]
	_check_setup()
	_check_vault()
	_check_hop()
	_check_climb()
	_check_refusals()
	_check_cut_short()
	_check_interruptions()
	await _check_wall_grab()
	_check_wall_moves()
	_check_wall_limits()
	_check_wall_off()
	_check_wall_interruptions()
	_check_wall_refusals()
	_check_teardown()
	K.finish(self, "FP_PARKOUR_TEST", fails)


# ------------------------------------------------------------------ helpers


## One frame as _process runs it: parkour first, then health, then the player.
func _frame(wish: Vector2, sprint: bool, jump: bool, crouch: bool = false) -> void:
	f.call("tick", DT)
	health.call("tick", DT)
	ctx.player.simulate(wish, sprint, DT, crouch, jump)
	ctx.player.update_view(DT)


## The view-relative wish that walks along dir (unit, xz) whatever the camera does.
func _wish(dir: Vector3) -> Vector2:
	var cy := ctx.player.cam_yaw
	return Vector2(dir.x * cos(cy) - dir.z * sin(cy), -dir.x * sin(cy) - dir.z * cos(cy))


## The lane point ahead metres along it and side metres to its right, on the lane's level.
func _lane_point(ahead: float, side: float) -> Vector3:
	return start + (run * ahead + right * side) * M


func _ahead() -> float:
	return (ctx.player.position - start).dot(run) / M


## A box across the lane, its face ahead metres along it, depth deep, height tall from base above
## the sidewalk and width wide (metres).
func _box(ahead: float, depth: float, height: float, width: float = 2.0, base: float = 0.0) -> void:
	var c := _lane_point(ahead + depth * 0.5, 0.0)
	var size := (run.abs() * depth + right.abs() * width + Vector3(0.0, height, 0.0)) * M
	var lo := Vector3(c.x - size.x * 0.5, start.y + base * M, c.z - size.z * 0.5)
	ctx.collision.add_test_box(AABB(lo, size))


## Puts the hero at the lane start (side metres to its right) and walks them along dir (a run with
## sprint) until the gap to a face `face` metres ahead is at most gap metres, then presses jump:
## the move that started ("" for none, "?" when the gap never closed).
func _press_at(face: float, gap: float, dir: Vector3, sprint: bool, side: float = 0.0) -> String:
	var p := ctx.player
	p.teleport(_lane_point(0.0, side), yaw_deg)
	actions.clear()
	landings.clear()
	for _k in range(240):
		var press := face - _ahead() - R_M <= gap
		_frame(_wish(dir), sprint, press)
		if press:
			return str(f.get("move"))
	return "?"


## Walks on along dir until the hero has stood 0.3 s after the move (or max_s), one entry a frame:
## {"ahead", "side", "y" (metres along, right of and above the lane start), "carried", "grounded",
## "state" (the rig's), "yaw" (degrees off the lane)}.
func _finish(dir: Vector3, sprint: bool, max_s: float = 4.0) -> Array[Dictionary]:
	var p := ctx.player
	var out: Array[Dictionary] = []
	var stood := 0.0
	var t := 0.0
	while t < max_s and stood < 0.3:
		_frame(_wish(dir), sprint, false)
		t += DT
		var rel := p.position - start
		(
			out
			. append(
				{
					"ahead": rel.dot(run) / M,
					"side": rel.dot(right) / M,
					"y": rel.y / M,
					"carried": p.carried,
					"grounded": p.grounded,
					"state": str(rig.call("state")),
					"yaw": rad_to_deg(wrapf(p.yaw - deg_to_rad(yaw_deg), -PI, PI)),
				}
			)
		)
		stood = stood + DT if p.grounded and not p.carried else 0.0
	return out


## The entries of log while the body was carried.
func _carried(log: Array[Dictionary]) -> Array[Dictionary]:
	return log.filter(func(e: Dictionary) -> bool: return bool(e["carried"]))


func _max_y(log: Array[Dictionary]) -> float:
	var y := -INF
	for e: Dictionary in log:
		y = maxf(y, float(e["y"]))
	return y


func _states(log: Array[Dictionary]) -> Array[String]:
	var out: Array[String] = []
	for e: Dictionary in log:
		if str(e["state"]) not in out:
			out.append(str(e["state"]))
	return out


func _made() -> int:
	var m: Dictionary = f.get("made")
	return int(m["vault"]) + int(m["hop"]) + int(m["climb"]) + int(m["grab"])


## True when a whole standing body fits where the hero stands.
func _clear() -> bool:
	var p := ctx.player
	return not ctx.collision.body_blocked(p.position, WS.PLAYER_RADIUS * 0.99, WS.PLAYER_HEIGHT)


## Steps standing still for secs.
func _wait(secs: float) -> void:
	for _k in range(ceili(secs / DT)):
		_frame(Vector2.ZERO, false, false)


## Metres to the right of the lane, and above its start, of the feet.
func _side() -> float:
	return (ctx.player.position - start).dot(right) / M


func _up() -> float:
	return (ctx.player.position.y - start.y) / M


## Holds the move keys at wish (x right, y forward; on a wall along it and up) and sprint for secs,
## or until until() is true when given.
func _hold(wish: Vector2, sprint: bool, secs: float, until: Callable = Callable()) -> void:
	for _k in range(roundi(secs / DT)):
		if until.is_valid() and bool(until.call()):
			return
		_frame(wish, sprint, false)


## Jumps at the wall whose face is face metres ahead of the lane start and waits out the leap onto
## it: the move under way ("wall" on it).
func _grab_wall(face: float) -> String:
	_press_at(face, 0.3, run, false)
	_wait(0.4)
	return str(f.get("move"))


func _on_wall() -> bool:
	return str(f.get("move")) == "wall" and ctx.player.carried


# ------------------------------------------------------------------ checks


func _check_setup() -> void:
	var p := ctx.player
	var st := f.self_test()
	K.check(fails, bool(st.get("ok", false)), "self_test (%s)" % st.get("detail", ""))
	var hooked := p.jump_hook == Callable(f, "try_move") and not p.carried
	K.check(fails, hooked, "the player's jump hook is the feature's")


## A run at a 1 m wall, 0.3 m deep: vaulted, the feet above its top while over it, a soft landing
## beyond it. From 25 degrees off, the move runs straight across and turns the body to it.
func _check_vault() -> void:
	_box(2.5, 0.3, 1.0, 3.0)
	var mv := _press_at(2.5, 0.9, run, true)
	var log := _finish(run, true)
	var over := _carried(log)
	K.check(
		fails, mv == "vault" and actions == ["vault"], "a run at a 1 m wall vaults it (%s)" % mv
	)
	var low := over.filter(
		func(e: Dictionary) -> bool:
			return float(e["ahead"]) > 2.5 and float(e["ahead"]) < 2.8 and float(e["y"]) < 1.0
	)
	var n_over := over.filter(func(e: Dictionary) -> bool: return float(e["ahead"]) > 2.5).size()
	K.check(fails, low.is_empty() and n_over > 0, "the feet stay above its top while over it")
	var last: Dictionary = log[-1] if not log.is_empty() else {}
	var beyond := not last.is_empty() and float(last["ahead"]) > 2.8 + R_M
	var down := not last.is_empty() and absf(float(last["y"])) < 1e-3 and bool(last["grounded"])
	K.check(fails, beyond and down, "lands beyond it, on the sidewalk (%s)" % str(last))
	var soft := landings.size() == 1 and landings[0] < 4.0
	K.check(fails, soft, "one soft landing (%s m/s)" % str(landings))
	var flew := "jump" in _states(over) or "fall" in _states(over)
	var secs := over.size() * DT
	K.check(
		fails, flew and secs < 1.2, "the rig flies it (%s), over in %.2f s" % [_states(over), secs]
	)
	var oblique := (run * cos(deg_to_rad(25.0)) + right * sin(deg_to_rad(25.0))).normalized()
	mv = _press_at(2.5, 0.9, oblique, true, -0.5)
	log = _finish(oblique, true)
	over = _carried(log)
	var straight := false
	var turned := false
	if over.size() > 2:
		straight = absf(float(over[-1]["side"]) - float(over[0]["side"])) < 0.01
		turned = absf(float(over[-1]["yaw"])) < 8.0 and absf(float(over[0]["yaw"])) > 10.0
	var what := (
		"%s, yaw %.1f -> %.1f" % [mv, over[0]["yaw"], over[-1]["yaw"]] if over.size() > 2 else mv
	)
	K.check(
		fails,
		mv == "vault" and straight and turned,
		"from 25 degrees off: straight over, turned (%s)" % what
	)
	ctx.collision.clear_test_boxes()


## A walk at a 0.5 m ledge, 2 m deep: hopped onto, standing on top.
func _check_hop() -> void:
	_box(1.5, 2.0, 0.5)
	var mv := _press_at(1.5, 0.4, run, false)
	var log := _finish(run, false)
	var last: Dictionary = log[-1] if not log.is_empty() else {}
	var on_top := not last.is_empty() and absf(float(last["y"]) - 0.5) < 1e-3
	var past := not last.is_empty() and float(last["ahead"]) >= 1.5 + R_M - 0.02
	K.check(
		fails, mv == "hop" and actions == ["hop"], "a walk at a 0.5 m ledge hops onto it (%s)" % mv
	)
	K.check(
		fails,
		on_top and past and bool(last.get("grounded", false)),
		"stands on top (%s)" % str(last)
	)
	ctx.collision.clear_test_boxes()


## A walk at a 1.5 m ledge, 2 m deep: climbed. The rig plays its climb clip, the feet leave the
## ground only at the face, and the hero ends standing on top, the rig back in locomotion.
func _check_climb() -> void:
	_box(1.5, 2.0, 1.5)
	var mv := _press_at(1.5, 0.4, run, false)
	var log := _finish(run, false)
	var up := _carried(log)
	K.check(
		fails, mv == "climb" and actions == ["climb"], "a walk at a 1.5 m ledge climbs it (%s)" % mv
	)
	K.check(fails, "climb" in _states(up), "the rig plays its climb clip (%s)" % str(_states(up)))
	var gap := INF
	for e: Dictionary in up:
		if float(e["y"]) > 0.01:
			gap = 1.5 - float(e["ahead"]) - R_M
			break
	K.check(fails, gap <= 0.05, "the feet leave the ground at the face (%.3f m from it)" % gap)
	var last: Dictionary = log[-1] if not log.is_empty() else {}
	var on_top := not last.is_empty() and absf(float(last["y"]) - 1.5) < 1e-3
	var past := not last.is_empty() and float(last["ahead"]) >= 1.5 + R_M - 0.02
	var secs := up.size() * DT
	K.check(fails, on_top and past and secs < 1.5, "ends on top in %.2f s (%s)" % [secs, str(last)])
	var loco := not last.is_empty() and str(last["state"]) == "loco" and bool(last["grounded"])
	K.check(fails, loco, "standing, the rig back in locomotion")
	ctx.collision.clear_test_boxes()


## Ordinary jumps: a 2.5 m wall with wall_climb off, a 1 m wall with a taller one right behind
## it, a crouch, 60 degrees off head-on and the flag off. No press, no move.
func _check_refusals() -> void:
	var before := _made()
	_box(1.0, 0.5, 2.5)
	FeatureFlags.set_override("wall_climb", false)
	var mv := _press_at(1.0, 0.3, run, false)
	FeatureFlags.set_override("wall_climb", true)
	var log := _finish(run, false)
	K.check(fails, mv == "" and _max_y(log) > 0.3, "a 2.5 m wall, wall_climb off: a jump (%s)" % mv)
	ctx.collision.clear_test_boxes()
	_box(1.5, 0.3, 1.0)
	_box(1.9, 0.5, 3.0)
	mv = _press_at(1.5, 0.4, run, false)
	_finish(run, false)
	K.check(fails, mv == "", "no room to land or stand beyond a 1 m wall: a jump (%s)" % mv)
	ctx.collision.clear_test_boxes()
	_box(1.5, 0.3, 1.0)
	var p := ctx.player
	p.teleport(_lane_point(1.5 - R_M - 0.3, 0.0), yaw_deg)
	for _k in range(20):
		_frame(Vector2.ZERO, false, false, true)
	_frame(Vector2.ZERO, false, true, true)
	K.check(fails, str(f.get("move")) == "" and p.crouched, "crouched: nothing")
	_wait(0.5)
	var at := _lane_point(1.5 - R_M - 0.3, 0.0)
	var d60 := run * cos(deg_to_rad(60.0)) + right * sin(deg_to_rad(60.0))
	var d25 := run * cos(deg_to_rad(25.0)) + right * sin(deg_to_rad(25.0))
	var off := MOVES.find(ctx.collision, at, d60, WS.WALK).is_empty()
	var near := not MOVES.find(ctx.collision, at, d25, WS.WALK).is_empty()
	K.check(fails, off and near, "60 degrees off head-on: nothing; 25 degrees: a move")
	FeatureFlags.set_override("parkour", false)
	mv = _press_at(1.5, 0.4, run, false)
	log = _finish(run, false)
	FeatureFlags.set_override("parkour", true)
	K.check(fails, mv == "" and _max_y(log) > 0.3, "flag off: a jump (%s)" % mv)
	mv = _press_at(1.5, -1.0, run, false)
	K.check(fails, mv == "?" and _ahead() <= 1.5 - R_M + 0.01, "no press: the wall stops the walk")
	K.check(fails, _made() == before, "none of these made a move")
	ctx.collision.clear_test_boxes()


## A climb cut short half over its ledge (control taken away) puts the body back at the face,
## clear of the ledge, and it drops to the foot of it.
func _check_cut_short() -> void:
	var p := ctx.player
	_box(1.5, 2.0, 1.5)
	var mv := _press_at(1.5, 0.4, run, false)
	for _k in range(120):
		if not p.carried or _ahead() >= 1.5 - R_M + 0.1:
			break
		_frame(Vector2.ZERO, false, false)
	var into := _ahead() - (1.5 - R_M)
	var low := (p.position.y - start.y) / M
	p.input_enabled = false
	_frame(Vector2.ZERO, false, false)
	var ended := not p.carried and str(f.get("move")) == ""
	K.check(fails, mv == "climb" and into >= 0.1 and low < 1.4, "fixture: half over the edge")
	K.check(
		fails, ended and _clear(), "cut short, the body is clear of the ledge (%.3f m)" % _ahead()
	)
	_wait(1.0)
	var foot := absf(p.position.y - start.y) < 1e-4 and _ahead() <= 1.5 - R_M + 0.01
	K.check(
		fails,
		foot,
		"and drops to the foot of it (%.3f m along, %.4f up)" % [_ahead(), p.position.y]
	)
	p.input_enabled = true
	ctx.collision.clear_test_boxes()


## A knock-down ends a vault with the body clear; a teleport ends a move where the body was put;
## photo mode does not start during a move; a load ends one.
func _check_interruptions() -> void:
	var p := ctx.player
	_box(2.5, 0.3, 1.0)
	var mv := _press_at(2.5, 0.9, run, true)
	_wait(0.1)
	health.call("hurt", 10.0, "car", Vector3.ZERO, true)
	_frame(Vector2.ZERO, false, false)
	var ended := mv == "vault" and not p.carried and str(f.get("move")) == ""
	K.check(fails, ended and bool(health.call("knocked")), "a knock-down ends a vault")
	for _k in range(600):
		if not bool(health.call("knocked")):
			break
		_frame(Vector2.ZERO, false, false)
	K.check(fails, _clear() and p.input_enabled, "the hero gets up clear of the wall")
	health.call("from_dict", {"hp": HEALTH.MAX_HP})
	mv = _press_at(2.5, 0.9, run, true)
	_wait(0.1)
	var spot := _lane_point(0.0, 0.0)
	p.teleport(spot, yaw_deg)
	_wait(0.1)
	var put := Vector2(p.position.x - spot.x, p.position.z - spot.z).length() < 1e-4
	K.check(fails, mv == "vault" and put and str(f.get("move")) == "", "a teleport ends a move")
	mv = _press_at(2.5, 0.9, run, true)
	p.set_photo_mode(true)
	var refused := not p.photo_mode
	_finish(run, true)
	K.check(fails, mv == "vault" and refused, "no photo mode during a move")
	mv = _press_at(2.5, 0.9, run, true)
	_wait(0.05)
	f.call("from_dict", {})
	K.check(fails, not p.carried and str(f.get("move")) == "", "a load ends a move")
	_wait(1.0)
	ctx.collision.clear_test_boxes()


## Jump at a 3 m wall, 2 m deep (too tall to climb onto): the hero leaps onto it and hangs on its
## face, the feet 0.5 m up, facing it in the rig's wall pose, the IK putting hands and feet on their
## holds. W climbs at 0.6 m/s (sprint 1.6 times that), the limbs moving hold to hold, and at the
## top the hero climbs over onto the roof (the climb clip) and stands there.
func _check_wall_grab() -> void:
	var p := ctx.player
	_box(1.0, 2.0, 3.0, 2.4)
	var mv := _grab_wall(1.0)
	var c: RefCounted = f.get("climber")
	K.check(
		fails,
		mv == "wall" and actions == ["grab"] and c != null,
		"jump at a 3 m wall takes hold of it (%s, %s)" % [mv, str(actions)]
	)
	var on_face := absf(_ahead() - (1.0 - R_M)) < 1e-3 and absf(_up() - 0.5) < 1e-3
	var turn := rad_to_deg(absf(angle_difference(p.yaw, deg_to_rad(yaw_deg))))
	K.check(
		fails,
		on_face and turn < 0.5 and _on_wall() and str(rig.call("state")) == "wall",
		(
			"hangs on its face 0.5 m up, facing it in the wall pose (%.3f m along, %.3f up)"
			% [_ahead(), _up()]
		)
	)
	if c == null:
		ctx.collision.clear_test_boxes()
		return
	await _check_wall_reach(c)
	var y0 := _up()
	_hold(Vector2(0.0, 1.0), false, 0.5)
	var slow := _up() - y0
	y0 = _up()
	_hold(Vector2(0.0, 1.0), true, 0.5)
	var fast := _up() - y0
	var straight := absf(_ahead() - (1.0 - R_M)) < 1e-3
	K.check(
		fails,
		absf(slow - 0.3) < 0.02 and absf(fast - 0.48) < 0.02 and straight,
		"W climbs at 0.6 m/s, faster with sprint (%.3f m, then %.3f m in 0.5 s)" % [slow, fast]
	)
	var swings := int(c.get("swings"))
	K.check(fails, swings >= 3, "the hands and feet move hold to hold (%d swings)" % swings)
	_hold(Vector2(0.0, 1.0), false, 2.0, func() -> bool: return not _on_wall())
	var over := str(f.get("move"))
	_hold(Vector2.ZERO, false, 2.0, func() -> bool: return not p.carried)
	_wait(0.3)
	K.check(
		fails,
		over == "climb" and actions == ["grab", "climb"],
		"at the top the hero climbs over (%s, %s)" % [over, str(actions)]
	)
	var roof := absf(_up() - 3.0) < 1e-3 and _ahead() > 1.0 + R_M and p.grounded
	K.check(
		fails,
		roof and not p.carried and str(rig.call("state")) == "loco",
		"and stands on the roof (%.3f m along, %.3f up, %s)" % [_ahead(), _up(), rig.call("state")]
	)
	p.teleport(_lane_point(0.0, 0.0), yaw_deg)
	ctx.collision.clear_test_boxes()


## The IK puts each hand and foot on its hold once the limbs have eased in: the end bones within
## 4 cm of their targets.
func _check_wall_reach(c: RefCounted) -> void:
	_wait(0.5)
	await process_frame
	await process_frame
	var limbs: RefCounted = rig.get("limbs")
	var ends: Array = limbs.get("ends")
	var off: Array[float] = []
	for i in range(ends.size()):
		var want: Vector3 = (c.call("limb", i) as Array)[0]
		off.append(snappedf((ends[i] as Vector3).distance_to(want) / M, 0.001))
	var worst: float = off.max() if not off.is_empty() else INF
	K.check(fails, worst < 0.04, "the hands and feet are on their holds (%s m off)" % str(off))


## On the wall D moves along it at 0.6 m/s and stops with the body short of its end, A moves back;
## S climbs down and steps off at its foot, standing.
func _check_wall_moves() -> void:
	var p := ctx.player
	_box(1.0, 2.0, 3.0, 2.4)
	var mv := _grab_wall(1.0)
	_hold(Vector2(1.0, 0.0), false, 0.5)
	var along := _side()
	K.check(
		fails,
		mv == "wall" and absf(along - 0.3) < 0.02 and absf(_up() - 0.5) < 1e-3,
		"D moves the hero right along the wall at 0.6 m/s (%.3f m in 0.5 s)" % along
	)
	_hold(Vector2(1.0, 0.0), true, 1.5)
	K.check(
		fails,
		_on_wall() and _side() > 0.68 and _side() < 0.7,
		"and stops with the body 0.5 m inside its end (%.3f m right)" % _side()
	)
	_hold(Vector2(-1.0, 0.0), false, 0.5)
	K.check(fails, _on_wall() and _side() < 0.45, "A moves back (%.3f m right)" % _side())
	_hold(Vector2(0.0, -1.0), false, 2.0, func() -> bool: return not p.carried)
	var off := not p.carried and p.grounded and absf(_up()) < 1e-3 and str(f.get("move")) == ""
	_wait(0.3)
	var foot := absf(_ahead() - (1.0 - R_M)) < 0.05 and str(rig.call("state")) == "loco"
	K.check(
		fails,
		off and foot,
		"S climbs down and steps off at its foot (%.3f m along, %s)" % [_ahead(), rig.call("state")]
	)
	ctx.collision.clear_test_boxes()


## With no room to stand on top (a taller wall right behind it) W held at the top hangs on there;
## under an overhang 3 m up the climb stops with the hands below it.
func _check_wall_limits() -> void:
	var p := ctx.player
	_box(1.0, 0.4, 3.0, 2.4)
	_box(1.4, 1.0, 5.0, 2.4)
	var mv := _grab_wall(1.0)
	_hold(Vector2(0.0, 1.0), true, 2.0)
	K.check(
		fails,
		mv == "wall" and _on_wall() and absf(_up() - 1.45) < 1e-3,
		"no room on top: W hangs on at the top (%s, %.3f m up)" % [f.get("move"), _up()]
	)
	p.teleport(_lane_point(0.0, 0.0), yaw_deg)
	ctx.collision.clear_test_boxes()
	_box(1.0, 2.0, 4.0, 2.4)
	_box(0.4, 1.0, 0.5, 2.4, 3.0)
	mv = _grab_wall(1.0)
	_hold(Vector2(0.0, 1.0), true, 2.0)
	K.check(
		fails,
		mv == "wall" and _on_wall() and _up() > 0.97 and _up() <= 1.0 + 1e-4,
		"an overhang 3 m up stops the climb under it (%.3f m up)" % _up()
	)
	p.teleport(_lane_point(0.0, 0.0), yaw_deg)
	ctx.collision.clear_test_boxes()


## Crouch lets go: the body drops to the foot of the wall. Jump pushes off it, up and back.
func _check_wall_off() -> void:
	var p := ctx.player
	_box(1.0, 2.0, 3.0, 2.4)
	_grab_wall(1.0)
	_hold(Vector2(0.0, 1.0), false, 1.0)
	var high := _up()
	_frame(Vector2.ZERO, false, false, true)
	_frame(Vector2.ZERO, false, false, true)
	var dropped := not p.carried and str(f.get("move")) == ""
	_wait(1.0)
	var foot := p.grounded and absf(_up()) < 1e-3 and absf(_ahead() - (1.0 - R_M)) < 0.01
	K.check(
		fails,
		dropped and foot and landings.size() == 1 and str(rig.call("state")) != "wall",
		"crouch lets go %.2f m up: the body drops to the foot (%s m/s)" % [high, str(landings)]
	)
	_grab_wall(1.0)
	_hold(Vector2(0.0, 1.0), false, 1.0)
	high = _up()
	_frame(Vector2.ZERO, false, true)
	_frame(Vector2.ZERO, false, false)
	var pushed := not p.carried and p.velocity.y > 0.0 and p.velocity.dot(run) < 0.0
	var log := _finish(Vector3.ZERO, false)
	var back := 1.0 - R_M - _ahead()
	var rise := _max_y(log) - high
	K.check(
		fails,
		pushed and rise > 0.2 and back > 0.5,
		"jump pushes off it, up and back (%.2f m up, lands %.2f m back)" % [rise, back]
	)
	ctx.collision.clear_test_boxes()


## On a wall a knock-down drops the body off it, a teleport ends the climb where the body was put,
## a load lets go, and so does the wall going away.
func _check_wall_interruptions() -> void:
	var p := ctx.player
	_box(1.0, 2.0, 3.0, 2.4)
	_grab_wall(1.0)
	health.call("hurt", 10.0, "car", Vector3.ZERO, true)
	_frame(Vector2.ZERO, false, false)
	var off := not p.carried and str(f.get("move")) == "" and f.get("climber") == null
	K.check(fails, off and bool(health.call("knocked")), "a knock-down drops the body off the wall")
	for _k in range(600):
		if not bool(health.call("knocked")):
			break
		_frame(Vector2.ZERO, false, false)
	K.check(
		fails,
		_clear() and p.input_enabled and absf(_up()) < 1e-3,
		"the hero gets up at its foot (%.3f m up)" % _up()
	)
	health.call("from_dict", {"hp": HEALTH.MAX_HP})
	_grab_wall(1.0)
	var spot := _lane_point(0.0, 0.0)
	p.teleport(spot, yaw_deg)
	_wait(0.1)
	var put := Vector2(p.position.x - spot.x, p.position.z - spot.z).length() < 1e-4
	K.check(
		fails,
		put and str(f.get("move")) == "" and str(rig.call("state")) == "loco",
		"a teleport ends the climb where the body was put (%s)" % rig.call("state")
	)
	_grab_wall(1.0)
	f.call("from_dict", {})
	K.check(fails, not p.carried and str(f.get("move")) == "", "a load lets go of the wall")
	_wait(1.0)
	_grab_wall(1.0)
	ctx.collision.clear_test_boxes()
	_frame(Vector2.ZERO, false, false)
	K.check(fails, not p.carried and str(f.get("move")) == "", "the wall gone, the hero lets go")
	_wait(1.0)


## Ordinary jumps at a post 4 m tall and 0.2 m wide (no wall either side to hang on) and at a wall
## under an awning 2.2 m up (no room to hang). 60 degrees off a tall wall nothing takes hold of it,
## 25 degrees off a jump does.
func _check_wall_refusals() -> void:
	var before := _made()
	_box(1.0, 0.2, 4.0, 0.2)
	var mv := _press_at(1.0, 0.3, run, false)
	var log := _finish(run, false)
	K.check(fails, mv == "" and _max_y(log) > 0.3, "a 4 m post: a jump (%s)" % mv)
	ctx.collision.clear_test_boxes()
	_box(1.0, 2.0, 4.0, 2.4)
	_box(-0.5, 1.5, 0.3, 2.4, 2.2)
	mv = _press_at(1.0, 0.3, run, false)
	log = _finish(Vector3.ZERO, false)
	K.check(fails, mv == "" and _max_y(log) > 0.2, "a wall under an awning: a jump (%s)" % mv)
	ctx.collision.clear_test_boxes()
	_box(1.0, 2.0, 3.0, 2.4)
	var at := _lane_point(1.0 - R_M - 0.4, 0.0)
	var d60 := run * cos(deg_to_rad(60.0)) + right * sin(deg_to_rad(60.0))
	var d25 := run * cos(deg_to_rad(25.0)) + right * sin(deg_to_rad(25.0))
	var off := WALL.grab(ctx.collision, at, d60, WS.WALK).is_empty()
	var near := not WALL.grab(ctx.collision, at, d25, WS.WALK).is_empty()
	K.check(fails, off and near, "60 degrees off a tall wall: no hold; 25 degrees: a hold")
	K.check(fails, _made() == before, "none of these jumps took hold")
	ctx.collision.clear_test_boxes()


## Teardown hands the jump back: Space jumps at the wall it vaulted.
func _check_teardown() -> void:
	var p := ctx.player
	var made := _made()
	var st := f.self_test()
	K.check(
		fails, bool(st.get("ok", false)), "self_test after the moves (%s)" % st.get("detail", "")
	)
	f.teardown()
	K.check(fails, not p.jump_hook.is_valid(), "teardown takes the jump hook back")
	_box(2.5, 0.3, 1.0)
	var mv := _press_at(2.5, 0.9, run, true)
	var log := _finish(run, true)
	K.check(fails, mv == "" and _made() == made and _max_y(log) > 0.3, "after it Space jumps")
	ctx.collision.clear_test_boxes()
