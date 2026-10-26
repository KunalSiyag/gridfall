extends FpFeature
## Close combat (integration feature "brawl"; docs/fp/ARCHITECTURE.md, Brawl): grapples and the
## counter cue. H (or the back mouse button) takes hold of the person on their feet in front
## within GRAB_REACH: they hang in the hero's hands HOLD_GAP ahead, the hero's fists up and the body
## squared to the camera, dragged along at DRAG_SPEED at most. Punches land on them where they hang
## (the combo's hook or the third in a row puts them down), R throws them where the camera looks
## (the actions feature's "throw": knocked down and flung) and H again lets go; after a while they
## break free (traffic's reactions.gd holds them). The hold ends when the hero can no longer act
## (driving, knocked down, a modal open). Someone fighting the hero who starts a punch flashes the
## counter cue under the crosshair (hero_threatened) until it lands: the guard raised in time
## counters it (the actions feature's parry, the counters flag). Environmental attacks (the slams
## flag): R with something solid just beyond the person held slams them into it instead of
## throwing them (slam_spot, slam; the actions feature's "slam"): a light street prop goes over
## with them, a wall, a post, a parked car or a prop that holds stops them dead (hero_slammed).

const WS := preload("res://scripts/fp/world_scale.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const INPUTS: Array[String] = ["act_grab"]
## Who can be grabbed: on their feet within GRAB_REACH (feet to feet) inside the cone ahead of the
## camera (the cosine).
const GRAB_REACH := 1.1 * WS.M
const GRAB_CONE := 0.5
## Where the held person's feet go: HOLD_GAP ahead of the hero's, far enough that the two bodies
## clear each other with the hero's hands on their arms.
const HOLD_GAP := 0.68 * WS.M
## The held person shifts and turns slightly as they struggle (m, radians, and Hz).
const HOLD_SWAY_SIDE := 0.12 * WS.M
const HOLD_SWAY_FORWARD := 0.04 * WS.M
const HOLD_SWAY_YAW := deg_to_rad(6.0)
const HOLD_SWAY_HZ := 1.25
## The hero's top speed dragging someone (u/s).
const DRAG_SPEED := 1.1 * WS.M
## The reach for them as the hold starts (the rig's push clip, seconds).
const REACH_S := 0.3
## The counter cue stays this long past the punch's landing (s).
const CUE_TAIL := 0.15
## A slam: something solid at most SLAM_REACH beyond the body of the person held (taken as
## SLAM_BODY_R round their feet, SLAM_HEIGHT tall), looked for in steps of SLAM_STEP; a knockable
## prop at most SLAM_TIE further than a wall is the one they hit. They hit it at SLAM_SPEED, with
## PERSON_MASS (a sedan is 1), handing a prop (1 + SLAM_GIVE) times its share of that; the bus
## hears of it at SLAM_CHEST up. They fall to a side with SLAM_SIDE clear.
const SLAM_REACH := 0.8 * WS.M
const SLAM_BODY_R := 0.25 * WS.M
const SLAM_HEIGHT := 1.7 * WS.M
const SLAM_STEP := 0.05 * WS.M
const SLAM_TIE := 0.1 * WS.M
const SLAM_SPEED := 3.0 * WS.M
const PERSON_MASS := 0.05
const SLAM_GIVE := 0.2
const SLAM_CHEST := 1.2 * WS.M
const SLAM_SIDE := 1.0 * WS.M

## The walkers_near id of the person held, -1 for none; holds taken so far.
var held_id: int = -1
var grabs: int = 0
## Slams so far.
var slams: int = 0
## The counter cue, and how long it stays.
var cue: Label
var cue_t: float = 0.0
var _hold_t: float = 0.0


func feature_id() -> String:
	return "brawl"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	if ctx.bus != null:
		link_signal(ctx.bus.hero_threatened, _on_threatened)
		link_signal(ctx.bus.drive_changed, _on_drive_changed)
	if ctx.hud != null:
		cue = S.label("!", 34, S.RED)
		cue.name = "CounterCue"
		cue.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cue.anchor_left = 0.5
		cue.anchor_right = 0.5
		cue.anchor_top = 0.5
		cue.anchor_bottom = 0.5
		cue.offset_left = -20.0
		cue.offset_right = 20.0
		cue.offset_top = 28.0
		cue.offset_bottom = 72.0
		cue.visible = false
		ctx.hud.slot("center").add_child(cue)


func on_world_rebuilt() -> void:
	release()


func from_dict(_d: Dictionary) -> void:
	release()


func teardown() -> void:
	release()
	unlink_signals()
	if cue != null and is_instance_valid(cue):
		cue.queue_free()
	cue = null


func self_test() -> Dictionary:
	for a: String in INPUTS:
		if not InputMap.has_action(a):
			return {"ok": false, "detail": "missing input %s" % a}
	return {"ok": true, "detail": "%d grabs" % grabs}


## Takes hold of the person on their feet in front (on foot, upright, free to act). False when
## nobody is there or the hero cannot now.
func grab() -> bool:
	var traffic := ctx.feature("traffic") if ctx != null else null
	if held_id >= 0 or traffic == null or not _free():
		return false
	var p := ctx.player
	if p.crouched or not p.grounded:
		return false
	var who := _target(traffic)
	if who.is_empty() or not bool(traffic.call("grab_walker", int(who["id"]), p.position)):
		return false
	held_id = int(who["id"])
	_hold_t = 0.0
	grabs += 1
	p.speed_cap = DRAG_SPEED
	var rig: Variant = p.avatar.get("rig") if p.avatar != null else null
	if rig is RefCounted and (rig as RefCounted).has_method("play_action"):
		rig.call("play_action", "push", REACH_S)
	if ctx.bus != null:
		ctx.bus.hero_action.emit("grapple", p.position)
	return true


## Lets go of whoever is held.
func release() -> void:
	if held_id < 0:
		return
	var traffic := ctx.feature("traffic") if ctx != null else null
	if traffic != null:
		traffic.call("release_walker", held_id)
	_end()


## True while someone is held.
func holding() -> bool:
	return held_id >= 0


func _process(delta: float) -> void:
	if ctx == null or ctx.player == null:
		return
	tick(minf(delta, 0.1))


## One step: the cue fades, and the person held goes where the hero's hands are (or the hold ends).
func tick(dt: float) -> void:
	cue_t = maxf(0.0, cue_t - dt)
	if cue != null:
		cue.visible = cue_t > 0.0 and not ctx.player.photo_mode
	if held_id < 0:
		return
	var traffic := ctx.feature("traffic")
	if traffic == null or not _free(true):
		release()
		return
	var p := ctx.player
	var f := p.body_forward()
	var at := p.position + Vector3(f.x, 0.0, f.z).normalized() * HOLD_GAP
	_hold_t += dt
	var phase := _hold_t * TAU * HOLD_SWAY_HZ
	var sway := sin(phase)
	var side := Vector3(f.z, 0.0, -f.x).normalized()
	at += side * HOLD_SWAY_SIDE * sway + f * HOLD_SWAY_FORWARD * cos(phase * 0.5)
	var yaw := atan2(-f.x, -f.z) + HOLD_SWAY_YAW * sway
	if not bool(traffic.call("hold_walker", held_id, at, yaw)):
		_end()
		return
	_grip(true, at)


## The hero's hands on the person held, feet at at (or let go).
func _grip(on: bool, at: Vector3 = Vector3.ZERO) -> void:
	var p := ctx.player if ctx != null else null
	var rig: Variant = p.avatar.get("rig") if p != null and p.avatar != null else null
	if not rig is RefCounted:
		return
	var pose: Variant = (rig as RefCounted).get("strike_pose")
	if pose is RefCounted:
		(pose as RefCounted).call("set_hold", on, at)


func _end() -> void:
	held_id = -1
	_hold_t = 0.0
	_grip(false)
	if ctx != null and ctx.player != null:
		ctx.player.speed_cap = INF


## What the person held would hit thrown along the level dir (the slams flag): the nearest thing
## solid within SLAM_REACH of their body, a knockable street prop standing there ({"what": its
## kind, "tile", "slot", "mass"}) or anything else that blocks a body, a wall, a post or a parked
## car ({"what": "wall"}). "at" is the contact at the height of their feet, "gap" how far off it
## is and "side" the level unit direction they fall to off it. {} for open street (a drop or
## water too), nobody held or the flag off.
func slam_spot(dir: Vector3) -> Dictionary:
	if held_id < 0 or ctx.collision == null or not FeatureFlags.enabled("slams"):
		return {}
	var q := _held_feet()
	var d := Vector3(dir.x, 0.0, dir.z).normalized()
	if is_nan(q.x) or d.is_zero_approx():
		return {}
	var wall := _wall_gap(q, d)
	var spot := _prop_ahead(q, d)
	if spot.is_empty() or float(spot["gap"]) > minf(wall, SLAM_REACH) + SLAM_TIE:
		if wall > SLAM_REACH:
			return {}
		spot = {"what": "wall", "gap": wall}
	spot["at"] = q + d * (float(spot["gap"]) + SLAM_BODY_R)
	spot["side"] = _fall_side(q, d)
	return spot


## The person held hits spot (slam_spot's) thrown along the level unit dir: a prop there that
## gives way to the body goes over (the props feature's knock), and the bus hears of it
## (hero_slammed). True when a prop went over.
func slam(spot: Dictionary, dir: Vector3) -> bool:
	if spot.is_empty():
		return false
	var at: Vector3 = spot["at"]
	var props := ctx.feature("props")
	var over := false
	if spot.has("tile") and props != null:
		var share := PERSON_MASS * (1.0 + SLAM_GIVE) / (PERSON_MASS + float(spot["mass"]))
		var fly := dir * SLAM_SPEED * share
		over = bool(props.call("knock", int(spot["tile"]), int(spot["slot"]), at, fly))
	slams += 1
	if ctx.bus != null:
		ctx.bus.hero_slammed.emit(at + Vector3.UP * SLAM_CHEST, str(spot["what"]), over)
	return over


## The drawn feet of the person held, NAN when they are not about.
func _held_feet() -> Vector3:
	var traffic := ctx.feature("traffic")
	if traffic != null:
		for w: Dictionary in traffic.call("walkers_near", ctx.player.position, GRAB_REACH * 2.0):
			if int(w["id"]) == held_id:
				return w["pos"]
	return Vector3(NAN, NAN, NAN)


## How far (u) a body at q goes along d before it meets something that blocks it; INF past
## SLAM_REACH, or where the ground ends first.
func _wall_gap(q: Vector3, d: Vector3) -> float:
	var col := ctx.collision
	for k in range(1, ceili(SLAM_REACH / SLAM_STEP) + 1):
		var p := q + d * (SLAM_STEP * k)
		if is_nan(col.ground_height(p)):
			return INF
		if col.body_blocked(p, SLAM_BODY_R, SLAM_HEIGHT):
			return SLAM_STEP * k
	return INF


## The nearest knockable prop standing in the way of a body at q going along d, within
## SLAM_REACH (+ SLAM_TIE) of it: {"what", "tile", "slot", "mass", "gap"}, {} for none.
func _prop_ahead(q: Vector3, d: Vector3) -> Dictionary:
	var props := ctx.feature("props")
	if props == null:
		return {}
	var c := Vector2(q.x, q.z)
	var a := Vector2(d.x, d.z)
	var best := {}
	for k: Dictionary in props.call("knockables_near", q, SLAM_BODY_R + SLAM_REACH + SLAM_TIE):
		var to: Vector2 = (k["c"] as Vector2) - c
		var r := float(k["r"])
		var along := to.dot(a)
		var gap := maxf(along - r - SLAM_BODY_R, 0.0)
		if k.has("down") or along <= 0.0 or absf(to.cross(a)) > r + SLAM_BODY_R:
			continue
		if gap <= SLAM_REACH + SLAM_TIE and (best.is_empty() or gap < float(best["gap"])):
			best = {"what": k["kind"], "tile": k["tile"], "slot": k["slot"], "mass": k["mass"]}
			best["gap"] = gap
	return best


## The level side (unit, across d) a body at q falls to off what it hit: the right unless that
## is blocked within SLAM_SIDE and the left is not.
func _fall_side(q: Vector3, d: Vector3) -> Vector3:
	var right := Vector3(-d.z, 0.0, d.x)
	var col := ctx.collision
	for s: Vector3 in [right, -right]:
		var p := q + s * SLAM_SIDE
		var ground := not is_nan(col.ground_height(p))
		if ground and not col.body_blocked(p, SLAM_BODY_R, SLAM_HEIGHT):
			return s
	return right


## True when the hero may grab (or, holding, go on holding): in control, and the actions feature
## lets them act with no swing under way (one may be under way while holding).
func _free(holding_now: bool = false) -> bool:
	var a := ctx.feature("actions")
	var p := ctx.player
	if a == null or p == null or not p.input_enabled or not bool(a.call("can_act")):
		return false
	return holding_now or str(a.get("swing")).is_empty()


## The nearest person on their feet within GRAB_REACH in the cone ahead of the camera, {} for none.
func _target(traffic: Node) -> Dictionary:
	var p := ctx.player
	var aim := Vector2(-sin(p.cam_yaw), -cos(p.cam_yaw))
	var best := {}
	var bd := INF
	for w: Dictionary in traffic.call("walkers_near", p.position, GRAB_REACH):
		var q: Vector3 = w["pos"]
		var d := Vector2(q.x - p.position.x, q.z - p.position.z)
		var dist := d.length()
		if bool(w["down"]) or (dist > 1e-5 and d.dot(aim) < GRAB_CONE * dist):
			continue
		if dist < bd:
			bd = dist
			best = w
	return best


func _unhandled_input(event: InputEvent) -> void:
	if ctx == null or ctx.player == null or not event.is_action_pressed("act_grab"):
		return
	if event.is_echo() or not ctx.player.input_enabled:
		return
	var live := (
		DisplayServer.get_name() == "headless" or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	)
	if not live:
		return
	if held_id >= 0:
		release()
	elif not grab():
		return
	if is_inside_tree():
		get_viewport().set_input_as_handled()


## A punch at the hero lands in secs: the cue shows until just after (the counters flag).
func _on_threatened(_at: Vector3, secs: float) -> void:
	if FeatureFlags.enabled("counters"):
		cue_t = maxf(cue_t, secs + CUE_TAIL)


func _on_drive_changed(active: bool) -> void:
	if active:
		release()
