extends FpFeature
## Parkour (integration slice; docs/fp/ARCHITECTURE.md, Parkour): jump in front of an obstacle and
## the hero gets over it instead of jumping against it. A low, thin one (a bench, a low wall, a
## railing) is vaulted, a low ledge hopped onto and one up to 2.1 m climbed, the rig's climb clip
## playing as the body pulls itself up (moves.gd plans each move). The player's jump hook hands
## the press over; the move carries the body (FpPlayer.carry) and gives it back at the end, after a
## vault or a hop to land. A knock-down or a loss of control drops the body where it is, and a
## teleport ends the move. Each move goes out on the bus (hero_action "vault", "hop" or "climb").

const WS := preload("res://scripts/fp/world_scale.gd")
const MOVES := preload("res://scripts/fp/parkour/moves.gd")

## Below this speed (u/s) a press heads where the body faces, else along its travel.
const MOVING := 0.3 * WS.M
## The body turns to face across the obstacle with this halflife (s).
const HL_TURN := 0.06
## The view dips (pitch, radians) as the hands take the ledge.
const KICK := -0.02

## The move under way ("vault", "hop", "climb") or "".
var move: String = ""
## Moves made so far, by kind.
var made: Dictionary = {"vault": 0, "hop": 0, "climb": 0}
var _plan: Dictionary = {}
var _t: float = 0.0
var _clip_on: bool = false


func feature_id() -> String:
	return "parkour"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	# Ahead of the player, which puts the camera on the body this moves.
	process_priority = -1
	_hook()


func on_world_rebuilt() -> void:
	stop()
	_hook()


func from_dict(_d: Dictionary) -> void:
	stop()


func teardown() -> void:
	stop()
	var p := ctx.player if ctx != null else null
	if p != null and p.jump_hook == try_move:
		p.jump_hook = Callable()


func self_test() -> Dictionary:
	var p := ctx.player
	var detail := "%d vaults, %d hops, %d climbs" % [made["vault"], made["hop"], made["climb"]]
	return {"ok": p == null or p.jump_hook == try_move, "detail": detail}


## The player's jump hook: a jump press in front of an obstacle starts the move it allows (true);
## otherwise the hero jumps (false). Only on foot and in control, not talking or knocked down.
func try_move() -> bool:
	var p := ctx.player if ctx != null else null
	if p == null or not move.is_empty() or not FeatureFlags.enabled("parkour"):
		return false
	if not p.input_enabled or p.photo_mode or p.in_conversation() or _knocked():
		return false
	var flat := Vector3(p.velocity.x, 0.0, p.velocity.z)
	var dir := flat if flat.length() > MOVING else p.body_forward()
	var plan := MOVES.find(ctx.collision, p.position, dir, flat.length())
	if plan.is_empty():
		return false
	_plan = plan
	move = str(plan["move"])
	_t = 0.0
	_clip_on = false
	made[move] = int(made.get(move, 0)) + 1
	var actions := ctx.feature("actions")
	if actions != null:
		actions.call("cancel")
	var lead := 1.0 / 60.0
	var vel := (MOVES.point(plan, lead) - MOVES.point(plan, 0.0)) / lead
	p.carry(p.position, p.yaw, vel, bool(plan["grounded"]))
	if ctx.bus != null:
		ctx.bus.hero_action.emit(move, p.position)
	return true


func _process(delta: float) -> void:
	if ctx != null:
		tick(minf(delta, 0.1))


## One step of the move under way: the body along the plan, turning across the obstacle, the
## climb clip from the face, and the body handed back at the end.
func tick(dt: float) -> void:
	if move.is_empty():
		return
	var p := ctx.player
	if p == null or not p.carried:
		_forget()
		return
	if not p.input_enabled or _knocked():
		stop()
		return
	_t = minf(_t + dt, float(_plan["length"]))
	var at := MOVES.point(_plan, _t)
	var dir: Vector3 = _plan["dir"]
	var turn := 1.0 - pow(0.5, dt / HL_TURN) if dt > 0.0 else 0.0
	var yaw := lerp_angle(p.yaw, atan2(-dir.x, -dir.z), turn)
	var vel := (at - p.position) / dt if dt > 0.0 else p.velocity
	p.carry(at, yaw, vel, bool(_plan["grounded"]))
	if not _clip_on and float(_plan["anim_at"]) >= 0.0 and _t >= float(_plan["anim_at"]):
		_clip_on = true
		p.kick_view(KICK, 0.0)
		var rig := _rig()
		if rig != null:
			rig.call("play_action", "climb", float(_plan["anim_len"]))
	if _t >= float(_plan["length"]):
		p.velocity = _plan["exit"]
		p.release(bool(_plan["grounded"]))
		_forget()


## Ends the move under way (a knock-down, a loss of control, a load, teardown): the body drops
## from where it is, or from the last point of the move where it stood clear (cut short half over
## a ledge).
func stop() -> void:
	if move.is_empty():
		return
	var p := ctx.player if ctx != null else null
	if p != null and p.carried:
		if ctx.collision != null:
			p.carry(MOVES.clear_point(ctx.collision, _plan, _t), p.yaw, p.velocity, false)
		p.release(false)
	_forget()


func _forget() -> void:
	move = ""
	_plan = {}
	_t = 0.0
	_clip_on = false


func _hook() -> void:
	if ctx != null and ctx.player != null:
		ctx.player.jump_hook = try_move


func _knocked() -> bool:
	var health := ctx.feature("health")
	return health != null and bool(health.call("knocked"))


## HC's animated hero, or null for the placeholder body.
func _rig() -> RefCounted:
	var av: Node3D = ctx.player.avatar
	if av == null or not bool(av.call("is_animated")):
		return null
	return av.get("rig") as RefCounted
