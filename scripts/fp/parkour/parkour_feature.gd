extends FpFeature
## Parkour (integration slice; docs/fp/ARCHITECTURE.md, Parkour): jump in front of an obstacle and
## the hero gets over it instead of jumping against it. A low, thin one (a bench, a low wall, a
## railing) is vaulted, a low ledge hopped onto and one up to 2.1 m climbed, the rig's climb clip
## playing as the body pulls itself up (moves.gd plans each move). A wall taller than that is
## taken hold of (flag wall_climb; wall.gd finds it): the hero leaps onto it and climbs it with the
## move keys, hands and feet on holds (climb.gd), climbs over the top where there is room to stand
## and steps off at its foot; crouch lets go and jump pushes off it. A hard landing on the move
## rolls on along the ground over a shoulder (flag landing_roll), the rig's roll clip playing and
## the first-person view turning over; the health feature counts it softer. The player's jump and
## land hooks hand the press or the landing over; the move carries the body (FpPlayer.carry) and
## gives it back at the end, after a vault, a hop or a let-go to land. A knock-down or a loss of
## control drops the body where it is, and a teleport ends the move. Each move goes out on the bus
## (hero_action "vault", "hop", "climb", "roll" or "grab").

const WS := preload("res://scripts/fp/world_scale.gd")
const MOVES := preload("res://scripts/fp/parkour/moves.gd")
const WALL := preload("res://scripts/fp/parkour/wall.gd")
const CLIMB := preload("res://scripts/fp/parkour/climb.gd")

## Below this speed (u/s) a press heads where the body faces, else along its travel.
const MOVING := 0.3 * WS.M
## The body turns to face across the obstacle with this halflife (s).
const HL_TURN := 0.06
## The view dips (pitch, radians) as the hands take the ledge.
const KICK := -0.02
## Jump on a wall pushes off it, back from it and up at these speeds (u/s).
const PUSH_BACK := 2.0 * WS.M
const PUSH_UP := 2.5 * WS.M
## A landing rolls (flag landing_roll) from ROLL_MIN down (u/s; about a 1.8 m drop) up to ROLL_MAX
## (a 10 m one, past which it cannot be rolled off), moving at ROLL_MOVING or more.
const ROLL_MIN := 6.0 * WS.M
const ROLL_MAX := 14.0 * WS.M
const ROLL_MOVING := 1.0 * WS.M

## The move under way ("vault", "hop", "climb", "roll", or "wall" on a wall) or "".
var move: String = ""
## Moves made so far, by kind ("grab": walls taken hold of).
var made: Dictionary = {"vault": 0, "hop": 0, "climb": 0, "roll": 0, "grab": 0}
## The body on a wall (climb.gd) while move is "wall", else null.
var climber: CLIMB = null
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
	if p != null and p.land_hook == try_roll:
		p.land_hook = Callable()


func self_test() -> Dictionary:
	var p := ctx.player
	var detail := (
		"%d vaults, %d hops, %d climbs, %d rolls, %d walls"
		% [made["vault"], made["hop"], made["climb"], made["roll"], made["grab"]]
	)
	var hooked := p == null or (p.jump_hook == try_move and p.land_hook == try_roll)
	return {"ok": hooked, "detail": detail}


## The player's jump hook: a jump press in front of an obstacle starts the move it allows, or at a
## wall too tall for that takes hold of it (true); otherwise the hero jumps (false). Only on foot
## and in control, not talking or knocked down.
func try_move() -> bool:
	var p := ctx.player if ctx != null else null
	if p == null or not move.is_empty() or not FeatureFlags.enabled("parkour"):
		return false
	if not p.input_enabled or p.photo_mode or p.in_conversation() or _knocked():
		return false
	var flat := Vector3(p.velocity.x, 0.0, p.velocity.z)
	var dir := flat if flat.length() > MOVING else p.body_forward()
	var plan := MOVES.find(ctx.collision, p.position, dir, flat.length())
	if not plan.is_empty():
		_start(plan)
		return true
	var w := {}
	if FeatureFlags.enabled("wall_climb"):
		w = WALL.grab(ctx.collision, p.position, dir, flat.length())
	if w.is_empty():
		return false
	_grab(w)
	return true


## The player's land hook: a landing from ROLL_MIN to ROLL_MAX down (land_v, u/s) at ROLL_MOVING
## or more rolls on along the ground where there is room (moves.gd plans it; true); otherwise the
## hero just lands (false). Only on foot and in control, not talking or knocked down.
func try_roll(land_v: float) -> bool:
	var p := ctx.player if ctx != null else null
	if p == null or not move.is_empty() or land_v < ROLL_MIN or land_v > ROLL_MAX:
		return false
	if not FeatureFlags.enabled("parkour") or not FeatureFlags.enabled("landing_roll"):
		return false
	if not p.input_enabled or p.photo_mode or p.in_conversation() or _knocked():
		return false
	var flat := Vector3(p.velocity.x, 0.0, p.velocity.z)
	var plan := {}
	if flat.length() >= ROLL_MOVING:
		plan = MOVES.roll(ctx.collision, p.position, flat, flat.length())
	if plan.is_empty():
		return false
	_start(plan)
	_clip()
	return true


func _process(delta: float) -> void:
	if ctx != null:
		tick(minf(delta, 0.1))


## One step of the move under way: on a wall the climb; otherwise the body along the plan, turning
## across the obstacle (along a roll), the climb clip from the face, and the body handed back at
## the end.
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
	if move == "wall":
		_hang(dt)
		return
	_t = minf(_t + dt, float(_plan["length"]))
	var at := MOVES.point(_plan, _t)
	var dir: Vector3 = _plan["dir"]
	var turn := 1.0 - pow(0.5, dt / HL_TURN) if dt > 0.0 else 0.0
	var yaw := lerp_angle(p.yaw, atan2(-dir.x, -dir.z), turn)
	var vel := (at - p.position) / dt if dt > 0.0 else p.velocity
	p.carry(at, yaw, vel, bool(_plan["grounded"]))
	if not _clip_on and float(_plan["anim_at"]) >= 0.0 and _t >= float(_plan["anim_at"]):
		_clip()
	if _t >= float(_plan["length"]):
		p.velocity = _plan["exit"]
		p.release(bool(_plan["grounded"]))
		_forget()


## Ends the move under way (a knock-down, a loss of control, a load, teardown): the body drops
## from where it is (off a wall), or from the last point of the move where it stood clear (cut
## short half over a ledge).
func stop() -> void:
	if move.is_empty():
		return
	var p := ctx.player if ctx != null else null
	if p != null and p.carried and climber != null:
		_let_go(Vector3.ZERO)
		return
	if p != null and p.carried:
		if ctx.collision != null:
			p.carry(MOVES.clear_point(ctx.collision, _plan, _t), p.yaw, p.velocity, false)
		p.release(false)
	_forget()


## Starts the move plan (moves.gd) from where the body stands and puts it on the bus.
func _start(plan: Dictionary) -> void:
	var p := ctx.player
	_plan = plan
	move = str(plan["move"])
	_t = 0.0
	_clip_on = false
	made[move] = int(made.get(move, 0)) + 1
	_cancel_actions()
	var lead := 1.0 / 60.0
	var vel := (MOVES.point(plan, lead) - MOVES.point(plan, 0.0)) / lead
	p.carry(p.position, p.yaw, vel, bool(plan["grounded"]))
	if ctx.bus != null:
		ctx.bus.hero_action.emit(move, p.position)


## Takes hold of the wall w (wall.grab()): the leap onto it in the rig's wall pose, "grab" on the
## bus.
func _grab(w: Dictionary) -> void:
	var p := ctx.player
	climber = CLIMB.new(ctx.collision, w, p.position)
	move = "wall"
	made["grab"] = int(made["grab"]) + 1
	_cancel_actions()
	p.carry(p.position, climber.yaw(), Vector3.ZERO, true)
	var rig := _rig()
	if rig != null:
		rig.call("hold_wall", true)
	if ctx.bus != null:
		ctx.bus.hero_action.emit("grab", p.position)


## One step on a wall: crouch lets go and jump pushes off; the move keys climb (faster with
## sprint), over the top where there is room to stand and off at the foot.
func _hang(dt: float) -> void:
	var p := ctx.player
	if climber.on_wall() and p.carry_crouch:
		_let_go(Vector3.ZERO)
		return
	if climber.on_wall() and p.take_jump():
		var u: Vector2 = climber.wall["u"]
		_let_go(Vector3(-u.x, 0.0, -u.y) * PUSH_BACK + Vector3.UP * PUSH_UP)
		return
	var said := climber.step(dt, p.carry_wish, p.carry_sprint)
	p.carry(climber.feet(), climber.yaw(), climber.velocity, true)
	var rig := _rig()
	if rig != null:
		for i in range(WALL.REST.size()):
			var l := climber.limb(i)
			rig.call("reach", i, l[0], l[1], l[2])
	if said == "top":
		_top_out()
	elif said == "foot":
		_off_wall(Vector3.ZERO, true)
	elif said == "lost":
		_let_go(Vector3.ZERO)


## Over the top of the wall when there is room to stand up there: a climb (moves.gd) from where
## the body hangs. Otherwise it hangs on.
func _top_out() -> void:
	var p := ctx.player
	var u: Vector2 = climber.wall["u"]
	var plan := MOVES.find(ctx.collision, p.position, Vector3(u.x, 0.0, u.y), 0.0)
	if plan.is_empty() or str(plan["move"]) != "climb":
		return
	climber = null
	var rig := _rig()
	if rig != null:
		rig.call("hold_wall", false)
	_start(plan)
	_clip()


## Off the wall into the air at vel (u/s): dropping, or pushed off it.
func _let_go(vel: Vector3) -> void:
	_off_wall(vel, false)


## Hands the body back off the wall: standing at its foot (on_ground) or into the air at vel.
func _off_wall(vel: Vector3, on_ground: bool) -> void:
	var p := ctx.player
	climber = null
	var rig := _rig()
	if rig != null:
		rig.call("hold_wall", false, on_ground)
	p.velocity = vel
	p.release(on_ground)
	_forget()


## The rig's clip for the climb or the roll under way (play_action with the move's name): the view
## dips as the hands take the edge, or turns over in first person through a roll.
func _clip() -> void:
	_clip_on = true
	if move == "roll":
		ctx.player.tumble_view(MOVES.ROLL_OVER)
	else:
		ctx.player.kick_view(KICK, 0.0)
	var rig := _rig()
	if rig != null:
		rig.call("play_action", move, float(_plan["anim_len"]))


func _forget() -> void:
	if climber != null:
		# The body was taken off the wall (a teleport): the limbs go back to the clips.
		climber = null
		var rig := _rig()
		if rig != null:
			rig.call("hold_wall", false, ctx.player.grounded)
	move = ""
	_plan = {}
	_t = 0.0
	_clip_on = false


func _hook() -> void:
	if ctx != null and ctx.player != null:
		ctx.player.jump_hook = try_move
		ctx.player.land_hook = try_roll


func _cancel_actions() -> void:
	var actions := ctx.feature("actions")
	if actions != null:
		actions.call("cancel")


func _knocked() -> bool:
	var health := ctx.feature("health")
	return health != null and bool(health.call("knocked"))


## HC's animated hero, or null for the placeholder body.
func _rig() -> RefCounted:
	var av: Node3D = ctx.player.avatar if ctx != null and ctx.player != null else null
	if av == null or not bool(av.call("is_animated")):
		return null
	return av.get("rig") as RefCounted
