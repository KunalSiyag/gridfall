class_name FpPlayer
extends Node3D
## The on-foot player (slice A): feet at `position`, a kinematic controller against the analytic
## CollisionWorld (no physics bodies, D2) and the one current Camera3D. Third person (the play
## default, D13) hangs the camera on TpsRig's over-the-shoulder spring arm and shows the Avatar;
## V switches to first person at eye height (the body then only casts its shadow). Walk, run,
## crouch, jump with coyote time and a buffer, curb steps, sliding along walls and poles, head
## bob, footsteps, shoulder swap, zoom, free-fly photo mode and the conversation two-shot. A jump
## press (jump_hook) or a landing (land_hook) can be taken over by a move that carries the body
## itself (carry / release).
## `yaw` is the body yaw (rotation.y); cam_yaw / cam_pitch are the view; movement input is
## relative to the view.

## A foot came down: on the gait's foot contacts (the left heel at phase 0, the right at PI; the
## placeholder's visible stride follows the same phase). pos is that foot's ground point, surface
## comes from CollisionWorld.surface_at.
signal stepped(surface: String, pos: Vector3)
## The hero touched down after LAND_STEP_MIN_AIR or more in the air, right after that landing's
## stepped; speed_mps is the downward speed at touchdown, rolled true when land_hook took the
## landing over (a roll).
signal landed(speed_mps: float, rolled: bool)
## Photo mode was entered or left.
signal photo_mode_changed(on: bool)

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const SM := preload("res://scripts/fp/player/spring_math.gd")
const AVATAR := preload("res://scripts/fp/player/player_avatar.gd")
## Gaps above this between a loaded position and the ground snap to the ground.
const GROUND_SNAP := 0.05
## Longest frame _process hands to simulate(), in seconds. A sim tick stall can freeze a frame for
## 0.7-2.7 s; the player then moves one 10 fps frame's worth instead of lurching ahead.
const MAX_FRAME_DELTA := 0.1
## Upper bound on collision sub-steps per simulate() call (each moves at most PLAYER_RADIUS).
const MAX_SUBSTEPS := 4096
# --- Movement (A 6.4): a critically damped velocity spring, body yaw spring, pivots, jumps
const HL_SPEED_UP := 0.15
const HL_SLOW_DOWN := 0.10
const HL_AIR := 0.5
const HL_BODY_YAW := 0.10
const YAW_RATE_WALK := deg_to_rad(720.0)
const YAW_RATE_RUN := deg_to_rad(450.0)
const TURN_MIN_SPEED := 0.2 * WS.M
const PIVOT_ANGLE := deg_to_rad(135.0)
const PIVOT_MIN_SPEED := 2.5 * WS.M
const PIVOT_TIME := 0.3
const HL_PIVOT_VEL := 0.06
const HL_PIVOT_YAW := 0.08
## Momentum (the "momentum" flag): the half-lives at RUN pace, eased in from the walk's above, so
## a run takes about 0.7 s to reach and 1.2 m to pull up from while a walk stays brisk; a run
## turns at most YAW_RATE_RUN_HEAVY; and a turn at a run sheds the pace above WALK, down to
## TURN_KEEP of it once the body is TURN_LOSS_FULL off the wish (from TURN_LOSS_FROM).
const HL_SPEED_UP_RUN := 0.24
const HL_SLOW_DOWN_RUN := 0.18
const YAW_RATE_RUN_HEAVY := deg_to_rad(360.0)
const TURN_LOSS_FROM := deg_to_rad(30.0)
const TURN_LOSS_FULL := deg_to_rad(110.0)
const TURN_KEEP := 0.55
## Free running (the "free_running" flag): sprint held at SPRINT_KEEP of RUN or more, heading
## within SPRINT_TURN of the wish (in first person with the wish ahead, SPRINT_AHEAD of it at
## least), for SPRINT_BUILD s lifts the top speed to WS.SPRINT. It drops back once sprint is let
## go, the pace falls off or the body turns away; in the air it holds.
const SPRINT_BUILD := 0.8
const SPRINT_KEEP := 0.9
const SPRINT_TURN := deg_to_rad(25.0)
const SPRINT_AHEAD := 0.7
const COYOTE_TIME := 0.10
const JUMP_BUFFER := 0.12
const HEAVY_LAND_SPEED := 4.0 * WS.M
const HEAVY_LAND_TIME := 0.3
## Shorter drops (a curb stepped off at a run) are not a foot contact of their own.
const LAND_STEP_MIN_AIR := 0.15
## Eye height follows crouch and stand with this halflife.
const HL_EYE := 0.06
## First-person eye catching up after a curb step.
const HL_FP_STEP := 0.08
## Scripted facing on interact: turn in place when the error is over FACE_MIN_ERROR.
const FACE_RATE := deg_to_rad(270.0)
const FACE_MIN_ERROR := deg_to_rad(60.0)
const HL_CONV_FACE := 0.3
# --- First person
const BOB_V := 0.03 * WS.M
const BOB_L := 0.015 * WS.M
const HL_BOB := 0.12
## Step length (m) = STEP_BASE + STEP_PER_MPS * speed (m/s): 0.70 m at WALK, 1.35 m at RUN.
const STEP_BASE := 0.40
const STEP_PER_MPS := 0.21
## With nothing to look at, the hero looks at the point this far along the view.
const LOOK_AHEAD := 10.0 * WS.M
## Gait phase per radian turned in place (scripted facing): 4 is two steps per quarter turn.
const TURN_STEPS := 4.0
## Footsteps sound this far either side of the body's centre line.
const FOOT_SPREAD := 0.09 * WS.M
const FP_SPRINT_FOV := 4.0
const HL_FOV := 0.25
const FP_PITCH_LIMIT := deg_to_rad(WS.PITCH_LIMIT_DEG)
## A view kick (kick_view) dies away with this halflife (s).
const HL_KICK := 0.07
## Camera shake (shake): trauma 0..1 drains at SHAKE_DECAY a second, and the view turns by up to
## SHAKE_MAX (pitch, yaw, roll; radians) times trauma squared, wobbling at about SHAKE_HZ.
const SHAKE_DECAY := 1.6
## The wobble's fastest line (SHAKE_HZ * 1.73) is capped at this many cycles a frame
## (shake_wobble_clamp): past it the sampled shake jumps instead of oscillating at low frame
## rates, so the clock slows instead. 60 fps never reaches the cap.
const SHAKE_MAX_CPF := 0.27
const SHAKE_MAX := Vector3(0.03, 0.025, 0.04)
const SHAKE_HZ := 9.0
## Half way through a first-person roll (tumble_view) the eye is this high.
const TUMBLE_EYE := 0.5 * WS.M
## Knocked down (down_view): the first-person eye sinks to this height flat on the ground and
## tips this far up (radians; the sky, and whoever stands over the hero) at full lie.
const DOWN_EYE := 0.3 * WS.M
const DOWN_PITCH := 0.4
# --- Camera modes and the right stick
const MODE_BLEND := 0.35
const STICK_YAW := deg_to_rad(270.0)
const STICK_YAW_FAST := deg_to_rad(400.0)
const STICK_FAST_AFTER := 0.3
const STICK_PITCH := deg_to_rad(160.0)
const STICK_EASE := deg_to_rad(10.0)
# --- Conversation two-shot (A 6.8)
const CONV_IN := 0.6
const CONV_OUT := 0.45
const CONV_FOV := 45.0
const CONV_BACK := 0.9 * WS.M
const CONV_BACK_SHORT := 0.6 * WS.M
const CONV_SIDE := 0.6 * WS.M
const CONV_UP := 0.1 * WS.M
const CONV_LOOK_T := 0.6
const CONV_LOOK_DOWN := 0.05 * WS.M
const CONV_PROBE := 0.2 * WS.M
const CONV_FREE_MIN := 0.7
const REVERSE_GAP := 2.5
# --- Traffic (E, optional): stopped cars block the walker; the arm pulls in out of car boxes
const TRAFFIC_POLL := 0.1
const BLOCKER_REACH := 2.0 * WS.M
const AGENT_REACH := 8.0 * WS.M
## People on foot (E's walkers_near) become the soft circles CollisionWorld pushes the hero out
## of: everyone within this reach of the feet is listed, once a frame (a sprint covers 0.65 m in
## one TRAFFIC_POLL, more than a person is wide, so the circles cannot be that stale).
const PEOPLE_REACH := 2.5 * WS.M
## Approximate agent boxes for the camera (half length, half width, height), metres * M.
const AGENT_SIZES := {
	"car": Vector3(2.3, 1.0, 1.6),
	"emergency": Vector3(2.8, 1.1, 2.4),
	"bus": Vector3(6.0, 1.3, 3.2),
	"truck": Vector3(4.5, 1.3, 3.4)
}

var ctx: FpContext
var camera: Camera3D
var yaw: float = 0.0  # radians; body yaw = rotation.y. Body forward = (-sin(yaw), 0, -cos(yaw)).
var pitch: float = 0.0  # radians; the view pitch (= cam_pitch), kept for S0 callers
var velocity: Vector3 = Vector3.ZERO  # u/s; y is the vertical speed
var input_enabled: bool = true  # false for tests and scripted tours
## Scripted movement while input_enabled is false (photo tour shots of the hero in motion):
## {"wish": Vector2, "sprint": bool}; empty for none.
var autopilot: Dictionary = {}
var photo_mode: bool = false  # free-fly photo mode; FpMode ignores hud_toggle and C ignores chat_open while true
## View angles (radians). Movement input is rotated by cam_yaw; forward() looks along them.
var cam_yaw: float = 0.0
var cam_pitch: float = 0.0
## "third" (over the shoulder) or "first" (eye height).
var camera_mode: String = "first"
var crouched: bool = false
var grounded: bool = true
var rig: TpsRig
var avatar: Node3D
var _sensitivity: float = WS.MOUSE_SENSITIVITY
var _invert_y: bool = false
var _fov_setting: float = WS.FOV
var _head_bob: bool = true
var _last_tps_distance: float = -1.0
var _last_tile: int = -2
var _acc: Vector2 = Vector2.ZERO
var _eye_h: float = WS.EYE
var _cam_dy: float = 0.0
var _step_snap: float = 0.0
var _coyote: float = 0.0
var _jump_buffer: float = 0.0
var _jump_held: bool = false
var _heavy: float = 0.0
var _air_t: float = 0.0
var _pivot_t: float = 0.0
## The "momentum" flag, read at setup (tests may set it).
var momentum: bool = true
## The "free_running" flag, read at setup (tests may set it).
var free_running: bool = true
## Seconds the sprint has built up (sprinting() from SPRINT_BUILD).
var _sprint_t: float = 0.0
var _wish_dir: Vector2 = Vector2.ZERO
var _yaw_v: float = 0.0
var _yaw_rate: float = 0.0
var _fwd_acc: float = 0.0
var _target_speed: float = 0.0
var _running: bool = false
## Gait phase (radians): one cycle is two steps; the left heel strikes at 0, the right at PI.
var _gait_phase: float = 0.0
var _bob_amp: float = 0.0
var _fp_fov: float = WS.FOV
var _stick_full: float = 0.0
var _face_goal: float = NAN
var _face_hl: float = 0.0
var _trans_from: Transform3D = Transform3D()
var _trans_fov: float = 60.0
var _trans_t: float = 0.0
var _trans_len: float = 0.0
var _conv_id: String = ""
var _conv_on: bool = false
var _conv_npc: Vector3 = Vector3.ZERO
var _conv_side: float = 1.0
var _conv_back: float = CONV_BACK
var _conv_t: float = 0.0
var _conv_from: Vector2 = Vector2.ZERO
var _conv_reverse: bool = false
var _conv_cut_t: float = 99.0
var _photo_saved: Dictionary = {}
var _photo_pos: Vector3 = Vector3.ZERO
var _set_up: bool = false
var _traffic_t: float = 0.0
## True while another owner (the city overview) places the camera through set_view_override().
var view_override: bool = false
## Third person: while not NAN the body turns toward this yaw instead of its travel (the actions
## feature: the guard faces where the camera looks, a blow faces its target).
var aim_yaw: float = NAN
## Asked (no arguments) when a jump is about to leave the ground: true when it took the press over
## (the parkour feature vaults or climbs instead of the jump), false to jump. Empty for none.
var jump_hook: Callable = Callable()
## Asked with the downward speed (u/s) when the body touches down after LAND_STEP_MIN_AIR or more
## in the air: true when it took the landing over (the parkour feature rolls the body on), false
## to land. Empty for none.
var land_hook: Callable = Callable()
## True while another owner moves the body through carry(): simulate leaves it alone until
## release(); teleport() and ride() end it.
var carried: bool = false
## While carried: the input simulate was last given (the view-relative wish, sprint and crouch;
## none while a modal is open) for the owner to read (a climb on a wall). A jump press is
## take_jump()'s.
var carry_wish: Vector2 = Vector2.ZERO
var carry_sprint: bool = false
var carry_crouch: bool = false
## The most the body walks or runs at (u/s), INF for no limit: dragging someone held, say.
var speed_cap: float = INF
## The view kick still applied (pitch, roll; radians).
var _kick: Vector2 = Vector2.ZERO
## Shake trauma (0..1), the clock its wobble runs on and the turn it gives now (radians).
var _trauma: float = 0.0
## How far the body is down on the ground (0..1; the health feature drives it through the
## knock-down's fall, lie and get-up; down_view): the first-person eye goes with it.
var down_w := 0.0
var _shake_t: float = 0.0
## Smoothed seconds a frame; paces the shake wobble's cap at low frame rates.
var _frame_dt: float = 1.0 / 60.0
var _shake: Vector3 = Vector3.ZERO
## Seconds into the first-person roll (tumble_view) and its length: over once the one reaches the
## other.
var _tumble_t: float = 0.0
var _tumble_len: float = 0.0
var _override_xf: Transform3D = Transform3D()
var _override_fov: float = 50.0


## Builds the camera (sharing ctx.env, so SkyDirector's sky applies), the avatar and the rig,
## applies the settings (camera mode included) and makes the camera current.
func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	momentum = FeatureFlags.enabled("momentum")
	free_running = FeatureFlags.enabled("free_running")
	rig = TpsRig.new()
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.position = Vector3(0.0, WS.EYE, 0.0)
	camera.near = WS.CAMERA_NEAR
	camera.far = WS.CAMERA_FAR
	camera.fov = float(ctx.settings.get("fov", WS.FOV))
	camera.environment = ctx.env
	add_child(camera)
	if camera.is_inside_tree():
		camera.make_current()
	avatar = AVATAR.new()
	avatar.name = "Avatar"
	add_child(avatar)
	_apply_settings(ctx.settings)
	if ctx.bus != null:
		ctx.bus.settings_changed.connect(_apply_settings)
		ctx.bus.conversation_changed.connect(_on_conversation_changed)
		ctx.bus.interact_requested.connect(_on_interact_requested)
	_set_up = true
	_apply_rotation()
	_snap_view()


## Places the feet at pos (y snapped to the ground when snap is true), sets the body and the view
## to yaw / pitch (degrees) and snaps the camera (springs, pivot, arm, blends): no swoop.
func teleport(pos: Vector3, yaw_deg: float, pitch_deg: float = 0.0, snap: bool = true) -> void:
	if photo_mode:
		_leave_photo(false)
	position = pos
	if snap:
		snap_to_ground()
	yaw = wrapf(deg_to_rad(yaw_deg), -PI, PI)
	cam_yaw = yaw
	cam_pitch = clampf(deg_to_rad(pitch_deg), _pitch_min(), _pitch_max())
	pitch = cam_pitch
	velocity = Vector3.ZERO
	_acc = Vector2.ZERO
	carried = false
	_yaw_v = 0.0
	_pivot_t = 0.0
	_heavy = 0.0
	_air_t = 0.0
	_jump_buffer = 0.0
	_coyote = 0.0
	grounded = true
	_face_goal = NAN
	_apply_rotation()
	_snap_view()
	_update_tile()


## Carries the body with a vehicle (input off): feet at pos, body yaw and view yaw in radians,
## no ground snap and no camera snap (the vehicle owns the view through set_view_override).
func ride(pos: Vector3, body_yaw: float, view_yaw: float) -> void:
	carried = false
	position = pos
	yaw = wrapf(body_yaw, -PI, PI)
	cam_yaw = wrapf(view_yaw, -PI, PI)
	velocity = Vector3.ZERO
	# The avatar leans from the last walk's acceleration and turn rate: a carried body does not.
	_fwd_acc = 0.0
	_yaw_rate = 0.0
	_apply_rotation()
	_update_tile()


## Moves the body for another owner (a vault or a climb) until release(): feet at pos, the body
## turned to body_yaw (radians; first person keeps facing the view), velocity vel (u/s) for the
## camera and the avatar, on the ground or in the air. simulate leaves the body alone meanwhile.
func carry(pos: Vector3, body_yaw: float, vel: Vector3, on_ground: bool) -> void:
	if not carried:
		carry_wish = Vector2.ZERO
		carry_sprint = false
		carry_crouch = false
	carried = true
	position = pos
	if camera_mode != "first":
		yaw = wrapf(body_yaw, -PI, PI)
	velocity = vel
	grounded = on_ground
	_acc = Vector2.ZERO
	_pivot_t = 0.0
	_fwd_acc = 0.0
	_yaw_rate = 0.0
	_apply_rotation()
	_update_tile()


## Gives a carried body back to simulate: standing, or in the air to land on the next step (with
## that landing's footstep and landed signal). A jump still held does not fire again.
func release(on_ground: bool) -> void:
	carried = false
	grounded = on_ground
	_air_t = 0.0 if on_ground else LAND_STEP_MIN_AIR
	_coyote = 0.0
	_jump_buffer = 0.0
	_jump_held = true


## Takes a jump pressed while the body is carried: true once per press.
func take_jump() -> bool:
	if not carried or _jump_buffer <= 0.0:
		return false
	_jump_buffer = 0.0
	return true


## Faces a world point: the view (yaw and pitch) and the body.
func look_toward(target: Vector3) -> void:
	var d := target - eye_position()
	if d.length_squared() < 1e-12:
		return
	cam_yaw = atan2(-d.x, -d.z)
	cam_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), _pitch_min(), _pitch_max())
	pitch = cam_pitch
	yaw = cam_yaw
	if rig != null:
		rig.yaw = cam_yaw
		rig.pitch = cam_pitch
		rig.notify_look()
	_apply_rotation()


## World position of the head (feet + current eye height; crouching lowers it). Talk and interact
## ranges are measured from here in both cameras.
func eye_position() -> Vector3:
	return position + Vector3(0.0, _eye_h, 0.0)


## Where the camera is (the arm end in third person).
func view_position() -> Vector3:
	if camera != null and camera.is_inside_tree():
		return camera.global_position
	return eye_position()


## Unit direction the camera looks along.
func view_dir() -> Vector3:
	if camera != null and camera.is_inside_tree():
		return -camera.global_transform.basis.z.normalized()
	return forward()


## Unit look direction (cam_yaw, cam_pitch).
func forward() -> Vector3:
	return Vector3(-sin(cam_yaw) * cos(cam_pitch), sin(cam_pitch), -cos(cam_yaw) * cos(cam_pitch))


## Unit horizontal direction the body faces.
func body_forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


## Tile index under the feet or -1.
func tile() -> int:
	var x := roundi(position.x)
	var y := roundi(position.z)
	return D.idx(x, y) if D.in_bounds(x, y) else -1


## Puts the feet on the walkable ground under them (no change over unwalkable ground).
func snap_to_ground() -> void:
	if ctx == null or ctx.collision == null:
		return
	var g := ctx.collision.walk_height(position)
	if not is_nan(g):
		position.y = g


## A short, grounded combat step (at most 0.18 m), with the same world collision and ground
## following as walking. It never enters another person's circle or changes running strength.
## Returns the actual displacement; an unsafe destination leaves the hero where they stood.
func combat_step(motion: Vector3) -> Vector3:
	if ctx == null or ctx.collision == null or not grounded or crouched or carried or photo_mode:
		return Vector3.ZERO
	var col := ctx.collision
	var move := Vector3(motion.x, 0.0, motion.z).limit_length(0.18 * WS.M)
	var at := col.move_body(position, move, WS.PLAYER_RADIUS, WS.PLAYER_HEIGHT, WS.STEP_HEIGHT)
	var ground := col.walk_height(at)
	if is_nan(ground) or absf(ground - position.y) > WS.STEP_HEIGHT:
		return Vector3.ZERO
	_refresh_people()
	for k in range(0, col.people_circles.size(), 4):
		var person := Vector3(
			col.people_circles[k], col.people_circles[k + 1], col.people_circles[k + 2]
		)
		var gap := WS.PLAYER_RADIUS + col.people_circles[k + 3]
		if (
			absf(person.y - at.y) < col.SOFT_Y
			and Vector2(person.x - at.x, person.z - at.z).length() < gap
		):
			return Vector3.ZERO
	var moved := at - position
	position = at
	snap_to_ground()
	if moved.length_squared() > 1e-12:
		_advance_gait(Vector2(moved.x, moved.z), WS.WALK)
	return moved


## Horizontal speed in u/s.
func speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


## One deterministic movement step; _process calls it with the held input, tests call it
## directly. wish: x = strafe right, y = forward, each -1..1, relative to the view (cam_yaw).
## While ctx.is_modal(), simulate itself zeroes wish and jump (gravity and ground snap still
## run). crouch and jump are held states (a jump fires on the press, buffered JUMP_BUFFER s).
## In photo mode it flies the camera instead (jump up, crouch down).
## Any delta is safe: the step is split so that no collision sub-step moves farther than
## PLAYER_RADIUS (a 0.008 u hoarding grown by the radius is only 0.038 u thick), and a velocity
## component whose move was blocked drops to zero.
func simulate(
	wish: Vector2, sprint: bool, delta: float, crouch: bool = false, jump: bool = false
) -> void:
	if ctx == null or ctx.collision == null or not (delta > 0.0) or not is_finite(delta):
		return
	if ctx.is_modal():
		wish = Vector2.ZERO
		jump = false
		crouch = crouch and not carried
	if wish.length_squared() > 1.0:
		wish = wish.normalized()
	if photo_mode:
		_photo_fly(wish, sprint, crouch, jump, delta)
		return
	if jump and not _jump_held:
		_jump_buffer = JUMP_BUFFER
	_jump_held = jump
	if carried:
		carry_wish = wish
		carry_sprint = sprint
		carry_crouch = crouch
		return
	if _jump_taken():
		return
	_set_crouch(crouch)
	_resolve_stuck()
	_refresh_people()
	_eye_h = SM.damp(_eye_h, WS.CROUCH_EYE if crouched else WS.EYE, HL_EYE, delta)
	_build_sprint(wish, sprint, delta)
	var top_speed := _top_speed(sprint)
	_running = sprint and not crouched and wish.length_squared() > 0.01
	_target_speed = top_speed * wish.length()
	var flat := Vector2(velocity.x, velocity.z)
	var goal := _wish_goal(wish, top_speed)
	_start_pivot(flat, goal)
	# The spring can overshoot its goal a little while turning; 1.25 keeps each step under the radius.
	var top := maxf(
		maxf(flat.length(), _target_speed) * 1.25, absf(velocity.y) + WS.GRAVITY * delta
	)
	var n := clampi(ceili(top * delta / WS.PLAYER_RADIUS), 1, MAX_SUBSTEPS)
	var h := delta / float(n)
	var yaw0 := yaw
	var third := camera_mode == "third"
	for _s in range(n):
		# The view recenters inside the sub-steps, and the camera-relative wish turns with it.
		if third:
			rig.yaw = cam_yaw
			rig.pitch = cam_pitch
			rig.advance(h, speed(), _target_speed, yaw)
			cam_yaw = rig.yaw
			cam_pitch = rig.pitch
		_step(_wish_goal(wish, top_speed), h)
	pitch = cam_pitch
	var flat1 := Vector2(velocity.x, velocity.z)
	_fwd_acc = (flat1 - flat).dot(Vector2(-sin(yaw), -cos(yaw))) / delta
	_yaw_rate = wrapf(yaw - yaw0, -PI, PI) / delta
	_update_tile()


## Top speed on foot (u/s): a crouch-walk, a walk, a run or a built-up sprint; speed_cap at most.
func _top_speed(sprint: bool) -> float:
	var run_top := WS.SPRINT if sprinting() else WS.RUN
	return minf(WS.CROUCH_WALK if crouched else (run_top if sprint else WS.WALK), speed_cap)


## True once a sprint has built up to the free-running pace (WS.SPRINT).
func sprinting() -> bool:
	return _sprint_t >= SPRINT_BUILD


## Leaves the ground in a running jump (free running's leap across a gap): false off the ground,
## carried or crouched.
func leap() -> bool:
	if not grounded or carried or crouched:
		return false
	_jump()
	return true


## Builds the sprint up (free running): on, at pace and on line with the wish it builds; off the
## ground it holds while sprint stays held; otherwise it starts over.
func _build_sprint(wish: Vector2, sprint: bool, delta: float) -> void:
	if not free_running or not sprint or crouched or carried:
		_sprint_t = 0.0
		return
	if not grounded:
		return
	var flat := Vector2(velocity.x, velocity.z)
	var fwd := Vector2(-sin(cam_yaw), -cos(cam_yaw))
	var goal := Vector2(-fwd.y, fwd.x) * wish.x + fwd * wish.y
	var ahead := camera_mode == "third" or wish.y >= SPRINT_AHEAD
	var on_line := goal.length() > 0.9 and absf(flat.angle_to(goal)) <= SPRINT_TURN
	if ahead and on_line and flat.length() >= WS.RUN * SPRINT_KEEP:
		_sprint_t += delta
	else:
		_sprint_t = 0.0


## A jump about to leave the ground that jump_hook takes over: true (the press is spent) when the
## hook moves the body instead.
func _jump_taken() -> bool:
	if _jump_buffer <= 0.0 or not grounded or crouched or not jump_hook.is_valid():
		return false
	if not bool(jump_hook.call()):
		return false
	_jump_buffer = 0.0
	return true


## Turning hard against the travel at speed on the ground pivots: the body stops, then turns.
func _start_pivot(flat: Vector2, goal: Vector2) -> void:
	if (
		grounded
		and _pivot_t <= 0.0
		and flat.length() > PIVOT_MIN_SPEED
		and goal.length_squared() > 1e-12
		and absf(flat.angle_to(goal)) > PIVOT_ANGLE
	):
		_pivot_t = PIVOT_TIME


## The goal velocity (xz, u/s) for a view-relative wish.
func _wish_goal(wish: Vector2, top_speed: float) -> Vector2:
	var goal := (
		(
			Vector2(cos(cam_yaw), -sin(cam_yaw)) * wish.x
			+ Vector2(-sin(cam_yaw), -cos(cam_yaw)) * wish.y
		)
		* top_speed
	)
	_wish_dir = goal.normalized() if goal.length_squared() > 1e-12 else Vector2.ZERO
	return goal


## Places the camera for this frame: the first-person eye (bob, step smoothing), the rig, the
## conversation shot or the photo camera, through any running blend; updates the avatar (lean,
## fade, shadow-only). _process calls it every frame; tests driving simulate() call it with
## their own dt.
func update_view(delta: float) -> void:
	if camera == null or ctx == null:
		return
	var dt := clampf(delta, 0.0, MAX_FRAME_DELTA)
	_frame_dt = SM.damp(_frame_dt, dt, 0.35, dt)
	var sp := speed()
	_cam_dy = SM.damp(_cam_dy, 0.0, HL_FP_STEP, dt)
	_kick *= pow(0.5, dt / HL_KICK)
	_update_shake(dt)
	_tumble_t += dt
	_bob_amp = SM.damp(
		_bob_amp, sqrt(clampf(sp / WS.RUN, 0.0, 1.0)) if grounded else 0.0, HL_BOB, dt
	)
	var fp_goal := (
		_fov_setting + (FP_SPRINT_FOV if _head_bob and _running and sp > 0.8 * WS.RUN else 0.0)
	)
	_fp_fov = SM.damp(_fp_fov, fp_goal, HL_FOV, dt)
	_update_facing(dt, sp)
	_update_conversation(dt)
	_poll_traffic(dt)
	var third := camera_mode == "third"
	if third and not photo_mode:
		rig.yaw = cam_yaw
		rig.pitch = cam_pitch
		rig.update(dt, position, velocity, yaw, _eye_h, grounded, _running, ctx.collision)
		cam_yaw = rig.yaw
		cam_pitch = rig.pitch
		pitch = cam_pitch
	var xf: Transform3D
	var fv: float
	var pure_fp := false
	if view_override:
		xf = _override_xf * _shake_xform()
		fv = _override_fov
	elif photo_mode:
		xf = Transform3D(SM.look_basis(cam_yaw, cam_pitch), _photo_pos)
		fv = rig.base_fov if third else _fov_setting
	elif third and _conv_on:
		xf = _conv_xform(dt)
		fv = CONV_FOV
	elif third:
		xf = rig.cam_xform * _kick_xform()
		fv = rig.fov
	else:
		xf = _fp_world()
		fv = _fp_fov
		pure_fp = true
	if _trans_len > 0.0:
		_trans_t += dt
		if _trans_t >= _trans_len - 1e-5:
			_trans_len = 0.0
		else:
			var s := SM.smooth01(_trans_t / _trans_len)
			xf = SM.blend_xform(_trans_from, xf, s)
			fv = lerpf(_trans_fov, fv, s)
			pure_fp = false
	if pure_fp:
		camera.top_level = false
		camera.transform = _fp_local()
	else:
		camera.top_level = true
		if camera.is_inside_tree():
			camera.global_transform = xf
		else:
			camera.transform = xf
	camera.fov = fv
	if avatar != null:
		var head := (
			eye_position()
			if not photo_mode
			else (_photo_saved.get("pos", position) as Vector3) + Vector3.UP * _eye_h
		)
		var alpha := clampf(
			inverse_lerp(TpsRig.FADE_NEAR, TpsRig.FADE_FAR, xf.origin.distance_to(head)), 0.0, 1.0
		)
		avatar.set_view_state(pure_fp, alpha)
		if not photo_mode:
			avatar.set_look_target(_look_target(xf))
			var back := (
				Vector2(velocity.x, velocity.z).dot(Vector2(-sin(yaw), -cos(yaw))) < -0.3 * sp
			)
			avatar.update_motion(
				dt,
				sp,
				_yaw_rate,
				_fwd_acc,
				_step_snap,
				clampf((WS.EYE - _eye_h) / (WS.EYE - WS.CROUCH_EYE), 0.0, 1.0),
				_gait_phase,
				grounded,
				velocity.y,
				_conv_on,
				back
			)
			if avatar.is_animated():
				_hero_steps()
		_step_snap = 0.0


## Jolts the view by d_pitch (positive up) and d_roll (radians; positive tips left), dying away
## over HL_KICK: a blow landing.
func kick_view(d_pitch: float, d_roll: float) -> void:
	_kick += Vector2(d_pitch, d_roll)


## Turns the first-person view over forward once in secs, the eye dipping toward the ground on the
## way round (a landing roll). Third person leaves the view alone.
func tumble_view(secs: float) -> void:
	_tumble_t = 0.0
	_tumble_len = maxf(secs, 0.0)


## Shakes the view (a blow landing or taken, a crash): adds trauma (0..1, 1 the most), which
## drains away over a second or so; a strong shake is far more than twice a weak one.
func shake(trauma: float) -> void:
	_trauma = clampf(_trauma + maxf(trauma, 0.0), 0.0, 1.0)


## The shake trauma left (0..1).
func shake_amount() -> float:
	return _trauma


func _update_shake(dt: float) -> void:
	_trauma = maxf(0.0, _trauma - SHAKE_DECAY * dt)
	# Past Nyquist the wobble jumps instead of oscillating (a 20-25 fps cap): keep its fastest
	# line under SHAKE_MAX_CPF cycles a (smoothed) frame — the shake runs slower but coherent.
	var rate := 1.0
	if FeatureFlags.enabled("shake_wobble_clamp"):
		rate = minf(1.0, SHAKE_MAX_CPF / maxf(_frame_dt, 1e-3) / (SHAKE_HZ * 1.73))
	_shake_t += dt * rate
	var s := _trauma * _trauma
	_shake = Vector3(_wobble(0.0), _wobble(1.7), _wobble(3.1)) * SHAKE_MAX * s


## Smooth noise in -1..1 along the shake clock, a different line for each phase.
func _wobble(phase: float) -> float:
	var t := _shake_t * SHAKE_HZ * TAU
	return 0.6 * sin(t + phase * 2.3) + 0.4 * sin(t * 1.73 + phase * 5.1)


func _shake_xform() -> Transform3D:
	return Transform3D(Basis.from_euler(_shake), Vector3.ZERO)


func _kick_xform() -> Transform3D:
	var e := Vector3(_kick.x + _shake.x, _shake.y, _kick.y + _shake.z)
	return Transform3D(Basis.from_euler(e), Vector3.ZERO)


## Mouse or stick look (radians): turns the view; in first person the body turns with it.
func look(d_yaw: float, d_pitch: float) -> void:
	cam_yaw = wrapf(cam_yaw + d_yaw, -PI, PI)
	cam_pitch = clampf(cam_pitch + d_pitch, _pitch_min(), _pitch_max())
	pitch = cam_pitch
	if rig != null:
		rig.yaw = cam_yaw
		rig.pitch = cam_pitch
		if absf(d_yaw) + absf(d_pitch) > 1e-7:
			rig.notify_look()
	if camera_mode == "first" and not photo_mode:
		yaw = cam_yaw
	_apply_rotation()


## Turns the view by a mouse motion at mouse_sensitivity radians per screen pixel. Reads
## screen_relative: `relative` is scaled by the window's content-scale stretch (canvas_items,
## 1600x900 base), so look speed would change with the window size. Applied raw, never smoothed.
func mouse_look(event: InputEventMouseMotion) -> void:
	var rel := event.screen_relative
	look(-rel.x * _sensitivity, -rel.y * _sensitivity * (-1.0 if _invert_y else 1.0))


## Switches between "first" and "third" (V); blend eases over MODE_BLEND s. Does not write the
## settings (toggle_camera_mode does).
func set_camera_mode(m: String, blend: bool = true) -> void:
	if (m != "first" and m != "third") or m == camera_mode:
		return
	var from_xf := _camera_world()
	var from_fov := camera.fov if camera != null else WS.FOV
	camera_mode = m
	if m == "first":
		cam_pitch = clampf(cam_pitch, -FP_PITCH_LIMIT, FP_PITCH_LIMIT)
		yaw = cam_yaw
		_yaw_v = 0.0
	else:
		cam_pitch = clampf(cam_pitch, TpsRig.PITCH_MIN, TpsRig.PITCH_MAX)
		_snap_rig()
	pitch = cam_pitch
	_apply_rotation()
	if blend and _set_up and not photo_mode:
		_start_transition(MODE_BLEND, from_xf, from_fov)
	else:
		_trans_len = 0.0
	if _set_up:
		update_view(0.0)


## V: flips the camera mode and saves the choice in the settings (the next session boots in it).
func toggle_camera_mode() -> void:
	var m := "first" if camera_mode == "third" else "third"
	if ctx != null and ctx.mode != null:
		ctx.mode.apply_settings({"camera_mode": m})
	set_camera_mode(m, true)
	Analytics.track("camera_mode", {"mode": m})


## Hands the camera to another owner: until clear_view_override(), update_view puts it at xf with
## fov while the body, rig and avatar keep updating. The first call eases in over blend seconds;
## later calls (one per frame) move it at once.
func set_view_override(xf: Transform3D, fov: float, blend: float = 0.0) -> void:
	var first := not view_override
	var from_xf := _camera_world()
	var from_fov := camera.fov if camera != null else WS.FOV
	view_override = true
	_override_xf = xf
	_override_fov = fov
	if first and blend > 0.0 and _set_up:
		_start_transition(blend, from_xf, from_fov)
	if _set_up:
		update_view(0.0)


## Gives the camera back to the player's own view, easing over blend seconds.
func clear_view_override(blend: float = MODE_BLEND) -> void:
	if not view_override:
		return
	var from_xf := _camera_world()
	var from_fov := camera.fov if camera != null else WS.FOV
	view_override = false
	if blend > 0.0 and _set_up:
		_start_transition(blend, from_xf, from_fov)
	else:
		_trans_len = 0.0
	if _set_up:
		update_view(0.0)


## Q: the camera moves to the other shoulder (saved in the settings).
func swap_shoulder() -> void:
	rig.swap_shoulder()
	if ctx != null and ctx.mode != null:
		ctx.mode.apply_settings({"shoulder": int(signf(rig.side))})


## P: enters or leaves the free-fly photo mode (HUD hidden, no modal, the sim keeps running). The
## feet follow the camera while flying and return on exit; the body stays where it stood.
func set_photo_mode(on: bool) -> void:
	if on == photo_mode or (on and carried):
		return
	if on:
		var xf := _camera_world()
		_photo_saved = {
			"pos": position,
			"yaw": yaw,
			"cam_yaw": cam_yaw,
			"cam_pitch": cam_pitch,
			"hud": ctx.hud.is_hud_visible() if ctx != null and ctx.hud != null else true,
			"avatar": _node_world(avatar) if avatar != null else Transform3D()
		}
		var yp := SM.yaw_pitch_of(xf.basis)
		photo_mode = true
		cam_yaw = yp.x
		cam_pitch = clampf(yp.y, -FP_PITCH_LIMIT, FP_PITCH_LIMIT)
		pitch = cam_pitch
		_photo_pos = xf.origin
		velocity = Vector3.ZERO
		_acc = Vector2.ZERO
		_trans_len = 0.0
		if avatar != null:
			var axf: Transform3D = _photo_saved["avatar"]
			avatar.top_level = true
			if avatar.is_inside_tree():
				avatar.global_transform = axf
			else:
				avatar.transform = axf
		if ctx != null and ctx.hud != null:
			ctx.hud.set_hud_visible(false)
		update_view(0.0)
		photo_mode_changed.emit(true)
	else:
		_leave_photo(true)


## Save section: {"pos": [x, y, z], "yaw": deg (body), "pitch": deg (view), "crouched", "photo"
## (always false), "cam_yaw": deg, "cam_pitch": deg, "camera_mode"}.
func to_dict() -> Dictionary:
	var pos := position
	var by := yaw
	var cy := cam_yaw
	var cp := cam_pitch
	if photo_mode:
		pos = _photo_saved.get("pos", position)
		by = float(_photo_saved.get("yaw", yaw))
		cy = float(_photo_saved.get("cam_yaw", cam_yaw))
		cp = float(_photo_saved.get("cam_pitch", cam_pitch))
	return {
		"pos": [pos.x, pos.y, pos.z],
		"yaw": rad_to_deg(by),
		"pitch": rad_to_deg(cp),
		"crouched": crouched,
		"photo": false,
		"cam_yaw": rad_to_deg(cy),
		"cam_pitch": rad_to_deg(cp),
		"camera_mode": camera_mode
	}


## Restores to_dict(); {} (or no "pos") spawns at ctx.mode.spawn_point(). Saves without the
## camera fields take the view from the body and the mode from the settings.
func from_dict(d: Dictionary) -> void:
	if photo_mode:
		_leave_photo(false)
	_end_conversation()
	var m := str(d.get("camera_mode", ""))
	if (m == "first" or m == "third") and m != camera_mode:
		if ctx != null and ctx.mode != null:
			ctx.mode.apply_settings({"camera_mode": m}, false)
		set_camera_mode(m, false)
	var pos: Variant = d.get("pos")
	if typeof(pos) == TYPE_ARRAY and (pos as Array).size() >= 3:
		var a: Array = pos
		crouched = bool(d.get("crouched", false))
		teleport(
			Vector3(float(a[0]), float(a[1]), float(a[2])),
			float(d.get("yaw", 0.0)),
			float(d.get("pitch", 0.0)),
			false
		)
		var g := (
			ctx.collision.walk_height(position) if ctx != null and ctx.collision != null else NAN
		)
		if not is_nan(g) and absf(g - position.y) > GROUND_SNAP:
			position.y = g
		if d.has("cam_yaw"):
			cam_yaw = wrapf(deg_to_rad(float(d["cam_yaw"])), -PI, PI)
			cam_pitch = clampf(
				deg_to_rad(float(d.get("cam_pitch", d.get("pitch", 0.0)))),
				_pitch_min(),
				_pitch_max()
			)
			pitch = cam_pitch
			if camera_mode == "first":
				yaw = cam_yaw
			_apply_rotation()
		_eye_h = WS.CROUCH_EYE if crouched else WS.EYE
		_snap_view()
		return
	crouched = false
	var sp: Dictionary = (
		ctx.mode.spawn_point()
		if ctx != null and ctx.mode != null
		else {"pos": Vector3.ZERO, "yaw": 0.0}
	)
	teleport(sp["pos"], float(sp["yaw"]), 0.0, true)


## Turns the body in place toward a world point (interact): only when it is more than 60 degrees
## off and the player is nearly still (A 6.4 scripted facing).
func face_point(p: Vector3) -> void:
	var d := p - position
	if Vector2(d.x, d.z).length_squared() < 1e-12:
		return
	var g := atan2(-d.x, -d.z)
	if (
		absf(wrapf(g - yaw, -PI, PI)) > FACE_MIN_ERROR
		and speed() < TURN_MIN_SPEED
		and camera_mode == "third"
	):
		_face_goal = g
		_face_hl = 0.0


## True while the conversation two-shot (or its first-person turn) is active.
func in_conversation() -> bool:
	return _conv_on


## The resident id of the active conversation, or "".
func conversation_id() -> String:
	return _conv_id if _conv_on else ""


## The gait phase in radians (the left heel strikes at 0, the right at PI).
func gait_phase() -> float:
	return _gait_phase


func _process(delta: float) -> void:
	if ctx == null:
		return
	var dt := minf(delta, MAX_FRAME_DELTA)
	if input_enabled:
		if not ctx.is_modal():
			_stick_look(dt)
		var wish := Input.get_vector("move_left", "move_right", "move_back", "move_forward")
		simulate(
			wish,
			Input.is_action_pressed("sprint"),
			dt,
			Input.is_action_pressed("crouch"),
			Input.is_action_pressed("jump")
		)
	elif not autopilot.is_empty():
		simulate(autopilot.get("wish", Vector2.ZERO), bool(autopilot.get("sprint", false)), dt)
	update_view(dt)


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled or ctx == null:
		return
	if event is InputEventMouseMotion:
		if not ctx.is_modal() and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			mouse_look(event as InputEventMouseMotion)
		return
	if event.is_echo() or ctx.is_modal():
		return
	if event.is_action_pressed("photo_mode"):
		set_photo_mode(not photo_mode)
	elif photo_mode:
		return
	elif event.is_action_pressed("view_toggle"):
		toggle_camera_mode()
	elif event.is_action_pressed("shoulder_swap"):
		if camera_mode != "third":
			return
		swap_shoulder()
	elif event.is_action_pressed("zoom_in") or event.is_action_pressed("zoom_out"):
		# First person leaves the wheel to the minimap.
		if camera_mode != "third":
			return
		rig.step_zoom(-1 if event.is_action_pressed("zoom_in") else 1)
	else:
		return
	if is_inside_tree():
		get_viewport().set_input_as_handled()


## One collision sub-step of at most PLAYER_RADIUS: the velocity spring, the slide, the world
## edge, steps, gravity, landing and the body yaw.
func _step(goal: Vector2, h: float) -> void:
	if carried:
		# land_hook took a landing over earlier in this frame: its owner moves the body now.
		return
	var col := ctx.collision
	_jump_buffer = maxf(0.0, _jump_buffer - h)
	_heavy = maxf(0.0, _heavy - h)
	var flat := Vector2(velocity.x, velocity.z)
	var g := goal * (0.5 if _heavy > 0.0 else 1.0)
	var hl := _velocity_halflife(g, flat)
	if _pivot_t > 0.0:
		_pivot_t -= h
		g = Vector2.ZERO
	elif momentum and grounded:
		g *= turn_keep(g)
	var r := SM.velocity_spring(flat, _acc, g, hl, h)
	var nv: Vector2 = r[0]
	var na: Vector2 = r[1]
	var disp: Vector2 = r[2]
	var height := WS.CROUCH_HEIGHT if crouched else WS.PLAYER_HEIGHT
	# Built exactly as move_body builds its full move, so an unblocked move compares equal (a
	# sub-ulp displacement that rounds away is not a wall).
	var full := Vector3(position.x + disp.x, position.y, position.z + disp.y)
	var p := col.move_body(
		position,
		Vector3(disp.x, 0.0, disp.y),
		WS.PLAYER_RADIUS,
		height,
		WS.STEP_HEIGHT if grounded else 0.0
	)
	var rad := WS.PLAYER_RADIUS
	var blocked := p != full
	var cx := clampf(p.x, D.X0 - 0.5 + rad, D.X0 + D.W - 0.5 - rad)
	var cz := clampf(p.z, D.Y0 - 0.5 + rad, D.Y0 + D.H - 0.5 - rad)
	if cx != p.x or cz != p.z:
		blocked = true
		p.x = cx
		p.z = cz
	# People nearby are soft-solid: ease out of their circles and stop pressing into them. The
	# tangential speed keeps, so the hero slides round a crowd instead of sticking to it, and the
	# walkers give way in turn (walkers.gd).
	if not col.people_circles.is_empty():
		var slid := _people_slide(col, p, rad, height, nv, na)
		p = slid[0]
		nv = slid[1]
		na = slid[2]
	var moved := Vector2(p.x - position.x, p.z - position.z)
	if blocked:
		if moved.length_squared() < 1e-16:
			nv = Vector2.ZERO
			na = Vector2.ZERO
		else:
			var u := moved.normalized()
			nv = u * maxf(0.0, nv.dot(u))
			na = u * na.dot(u)
			if absf(moved.x) < 1e-12:
				nv.x = 0.0
				na.x = 0.0
			if absf(moved.y) < 1e-12:
				nv.y = 0.0
				na.y = 0.0
	position.x = p.x
	position.z = p.z
	velocity.x = nv.x
	velocity.z = nv.y
	_acc = na
	var dist := moved.length()
	if grounded and dist > 0.0 and not _hero_animates():
		_advance_gait(moved, nv.length())
	_vertical(h, height)
	_body_yaw_step(h)


## Ground following, steps, jumps (coyote time and buffer), gravity and landing for one sub-step.
func _vertical(h: float, height: float) -> void:
	var col := ctx.collision
	var sup := col.support_height(
		position, WS.PLAYER_RADIUS, position.y, WS.STEP_HEIGHT if grounded else 0.0
	)
	if is_nan(sup):
		sup = position.y
	if grounded:
		if _jump_buffer > 0.0 and not crouched:
			_jump()
		elif sup >= position.y - 1e-7:
			_snap_y(sup)
		elif position.y - sup <= WS.STEP_HEIGHT:
			_snap_y(sup)
		else:
			grounded = false
			_coyote = COYOTE_TIME
			velocity.y = 0.0
	if grounded:
		return
	_air_t += h
	_coyote -= h
	if _jump_buffer > 0.0 and _coyote > 0.0 and velocity.y <= 0.0 and not crouched:
		_jump()
	var y0 := position.y
	var vy0 := velocity.y
	velocity.y -= WS.GRAVITY * h
	position.y += (vy0 + velocity.y) * 0.5 * h
	if velocity.y > 0.0 and col.body_blocked(position, WS.PLAYER_RADIUS * 0.99, height):
		position.y = y0
		velocity.y = 0.0
	if position.y <= sup and velocity.y <= 0.0:
		_touch_down(col, sup)


## Touchdown on the ground at height sup: a hard one slows the next steps, and after
## LAND_STEP_MIN_AIR in the air it is a footstep and a landing, which land_hook may take over (a
## roll then carries the body on instead of the slow-down).
func _touch_down(col: CollisionWorld, sup: float) -> void:
	var land_v := -velocity.y
	if land_v > HEAVY_LAND_SPEED:
		_heavy = HEAVY_LAND_TIME
	position.y = sup
	velocity.y = 0.0
	grounded = true
	_coyote = 0.0
	if _air_t >= LAND_STEP_MIN_AIR:
		var rolled := land_hook.is_valid() and bool(land_hook.call(land_v))
		if rolled:
			_heavy = 0.0
		stepped.emit(col.surface_at(position), position)
		landed.emit(land_v / WS.M, rolled)
	_air_t = 0.0


## What the hero looks at (A 6.9): the conversation partner's head, else the focused interactable,
## else the point 10 m along the view from camera transform xf.
func _look_target(xf: Transform3D) -> Vector3:
	if _conv_on:
		return _conv_npc
	if rig != null and camera_mode == "third" and not is_nan(rig.assist_target.x):
		return rig.assist_target
	return xf.origin - xf.basis.z * LOOK_AHEAD


## Advances the gait phase by a ground move (u; backward travel runs it backward) at speed (u/s)
## and sounds a footstep on each heel strike it crosses.
func _advance_gait(moved: Vector2, sp: float) -> void:
	var dist := moved.length()
	var back := moved.dot(Vector2(-sin(yaw), -cos(yaw))) < -0.25 * dist
	var step_len := (STEP_BASE + STEP_PER_MPS * sp / WS.M) * WS.M
	_advance_phase((-1.0 if back else 1.0) * dist / step_len * PI)


## Moves the gait phase by d radians (less than PI) and sounds a footstep on the heel strike it
## crosses, at that foot's ground point.
func _advance_phase(d: float) -> void:
	var ph0 := _gait_phase
	var ph1 := ph0 + d
	var k0 := floori(ph0 / PI)
	var k1 := floori(ph1 / PI)
	_gait_phase = fposmod(ph1, TAU)
	if k0 == k1:
		return
	var left := posmod(maxi(k0, k1), 2) == 0
	var side := Vector3(-cos(yaw), 0.0, sin(yaw)) * (FOOT_SPREAD if left else -FOOT_SPREAD)
	var foot := position + side
	stepped.emit(ctx.collision.surface_at(foot), foot)


## True while HC's hero animates: its clips own the gait phase and the footsteps.
func _hero_animates() -> bool:
	return avatar != null and avatar.is_animated()


## The hero's heel strikes become footsteps at the striking foot's ground point; the gait phase
## (head bob) follows its locomotion clip.
func _hero_steps() -> void:
	for c: Dictionary in avatar.contacts():
		var foot: Vector3 = c["pos"]
		stepped.emit(ctx.collision.surface_at(foot), foot)
	var ph: float = avatar.gait_phase()
	if not is_nan(ph):
		_gait_phase = ph


func _jump() -> void:
	velocity.y = WS.JUMP_SPEED
	grounded = false
	_coyote = 0.0
	_jump_buffer = 0.0


## Moves the feet to y on the ground; the first-person eye and the avatar absorb the jump.
func _snap_y(y: float) -> void:
	var dy := y - position.y
	if dy != 0.0:
		_cam_dy -= dy
		_step_snap += dy
	position.y = y


## The velocity spring's half-life for goal g from flat: a pivot's, the air's, else speeding up or
## slowing down (eased toward the run's half-lives with momentum).
func _velocity_halflife(g: Vector2, flat: Vector2) -> float:
	var pace := run_pace(maxf(g.length(), flat.length())) if momentum else 0.0
	if _pivot_t > 0.0:
		return HL_PIVOT_VEL
	if not grounded:
		return HL_AIR
	if g.length_squared() > flat.length_squared():
		return lerpf(HL_SPEED_UP, HL_SPEED_UP_RUN, pace)
	return lerpf(HL_SLOW_DOWN, HL_SLOW_DOWN_RUN, pace)


## 0 at WALK pace (or slower) to 1 at RUN.
static func run_pace(sp: float) -> float:
	return clampf((sp - WS.WALK) / (WS.RUN - WS.WALK), 0.0, 1.0)


## The share of goal g the body keeps while it turns toward it (third person, a run): the pace
## above WALK fades to TURN_KEEP as the body's facing falls TURN_LOSS_FULL behind g. 1 otherwise.
func turn_keep(g: Vector2) -> float:
	var sp := g.length()
	if camera_mode != "third" or not is_nan(aim_yaw) or sp <= WS.WALK:
		return 1.0
	var err := absf(Vector2(-sin(yaw), -cos(yaw)).angle_to(g))
	var t := SM.smooth01((err - TURN_LOSS_FROM) / (TURN_LOSS_FULL - TURN_LOSS_FROM))
	var keep := lerpf(1.0, TURN_KEEP, t)
	return (WS.WALK + (sp - WS.WALK) * keep) / sp


## Third person: the body turns toward aim_yaw, else its travel (a spring, rate-limited; toward
## the wish during a pivot). First person: the body follows the view.
func _body_yaw_step(h: float) -> void:
	if camera_mode == "first":
		if absf(yaw - cam_yaw) > 0.0:
			yaw = cam_yaw
			_apply_rotation()
		_yaw_v = 0.0
		return
	var flat := Vector2(velocity.x, velocity.z)
	var sp := flat.length()
	var goal := NAN
	if not is_nan(aim_yaw):
		goal = aim_yaw
	elif _pivot_t > 0.0 and _wish_dir != Vector2.ZERO:
		goal = atan2(-_wish_dir.x, -_wish_dir.y)
	elif sp > TURN_MIN_SPEED:
		goal = atan2(-flat.x, -flat.y)
	if is_nan(goal):
		return
	_face_goal = NAN
	var r := SM.spring_angle(yaw, _yaw_v, goal, HL_PIVOT_YAW if _pivot_t > 0.0 else HL_BODY_YAW, h)
	var run_rate := YAW_RATE_RUN_HEAVY if momentum else YAW_RATE_RUN
	var max_rate := lerpf(YAW_RATE_WALK, run_rate, run_pace(sp))
	var dy := clampf(wrapf(r.x - yaw, -PI, PI), -max_rate * h, max_rate * h)
	yaw = wrapf(yaw + dy, -PI, PI)
	_yaw_v = clampf(r.y, -max_rate, max_rate)
	rotation.y = yaw


## A body left inside a blocker (a teleport or a load put it half inside a building or a car box)
## steps straight out to the nearest free side (CollisionWorld.resolve_out); the walk-out rule of
## move_body only helps once it moves.
func _resolve_stuck() -> void:
	var height := WS.CROUCH_HEIGHT if crouched else WS.PLAYER_HEIGHT
	var q := ctx.collision.resolve_out(position, WS.PLAYER_RADIUS, height)
	if q != position:
		position.x = q.x
		position.z = q.z


## The soft-people half of a sub-step: p eased out of the people circles (CollisionWorld's
## soft_people_move) and the into-person part of the velocity and the spring's acceleration
## taken off, so the hero stops pressing on people while the tangential speed keeps (they slide
## round a crowd instead of sticking to it). Returns [p, nv, na].
func _people_slide(
	col: CollisionWorld, p: Vector3, rad: float, height: float, nv: Vector2, na: Vector2
) -> Array:
	var q := col.soft_people_move(p, rad, height)
	if q == p:
		return [p, nv, na]
	var push := Vector2(q.x - p.x, q.z - p.z)
	var u := push / push.length()
	var into := nv.dot(u)
	if into < 0.0:
		nv -= u * into
	var acc := na.dot(u)
	if acc < 0.0:
		na -= u * acc
	return [Vector3(q.x, p.y, q.z), nv, na]


## Everyone on foot nearby (E's walkers_near) becomes CollisionWorld's soft circles, once a
## simulate call: the hero cannot pass through people, but they are not walls. Nobody without the
## traffic feature, and nobody while the hero is aboard a car (their body is the car's; E's
## blockers and contacts own that).
func _refresh_people() -> void:
	var col := ctx.collision
	var traffic := ctx.feature("traffic")
	if (
		traffic == null
		or not traffic.has_method("walkers_near")
		or bool(traffic.get("hero_aboard"))
	):
		if not col.people_circles.is_empty():
			col.people_circles = PackedFloat32Array()
		return
	var out := PackedFloat32Array()
	for d: Variant in traffic.call("walkers_near", position, PEOPLE_REACH):
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = d
		var q: Vector3 = e.get("pos", position)
		out.append(q.x)
		out.append(q.y)
		out.append(q.z)
		out.append(col.PERSON_R)
	col.people_circles = out


## A few times a second: E's stopped cars become dynamic collision boxes, and its agents near the
## camera become the rig's pull-in boxes. No traffic feature, nothing to do.
func _poll_traffic(dt: float) -> void:
	_traffic_t -= dt
	if _traffic_t > 0.0:
		return
	_traffic_t = TRAFFIC_POLL
	var traffic := ctx.feature("traffic")
	if traffic == null:
		return
	if traffic.has_method("blockers_near"):
		var list: Array[AABB] = []
		for b: Variant in traffic.call("blockers_near", position, BLOCKER_REACH):
			if typeof(b) == TYPE_AABB:
				list.append(b)
		ctx.collision.dynamic_boxes = list
	if camera_mode == "third" and traffic.has_method("agents_near"):
		var boxes: Array[AABB] = []
		for a: Variant in traffic.call("agents_near", position, AGENT_REACH):
			if typeof(a) != TYPE_DICTIONARY:
				continue
			var d: Dictionary = a
			var size: Variant = AGENT_SIZES.get(str(d.get("kind", "")))
			if size == null:
				continue
			var ext: Vector3 = (size as Vector3) * WS.M
			var v: Vector3 = d.get("vel", Vector3.ZERO)
			var h := (
				atan2(v.x, v.z)
				if Vector2(v.x, v.z).length_squared() > 1e-10
				else float(d.get("heading", 0.0))
			)
			var hx := absf(sin(h)) * ext.x + absf(cos(h)) * ext.y
			var hz := absf(cos(h)) * ext.x + absf(sin(h)) * ext.y
			var pos: Vector3 = d.get("pos", Vector3.ZERO)
			boxes.append(
				AABB(Vector3(pos.x - hx, pos.y, pos.z - hz), Vector3(hx * 2.0, ext.z, hz * 2.0))
			)
		rig.agent_boxes = boxes


## Scripted facing (interact) and the conversation turn toward the resident.
func _update_facing(dt: float, sp: float) -> void:
	if (
		is_nan(_face_goal)
		or sp >= TURN_MIN_SPEED
		or camera_mode == "first"
		or photo_mode
		or dt <= 0.0
	):
		return
	var y0 := yaw
	var err := wrapf(_face_goal - yaw, -PI, PI)
	if _face_hl > 0.0:
		var r := SM.spring_angle(yaw, _yaw_v, _face_goal, _face_hl, dt)
		yaw = r.x
		_yaw_v = r.y
	else:
		yaw = wrapf(yaw + clampf(err, -FACE_RATE * dt, FACE_RATE * dt), -PI, PI)
		if absf(err) < deg_to_rad(1.0):
			_face_goal = NAN
	var turned := wrapf(yaw - y0, -PI, PI)
	_yaw_rate = turned / dt
	rotation.y = yaw
	# The placeholder turns in place with small steps (two per quarter turn).
	if not _hero_animates():
		_advance_phase(absf(turned) * TURN_STEPS)


func _set_crouch(want: bool) -> void:
	if want == crouched:
		return
	if want:
		crouched = true
		return
	# Stand up only with headroom: nothing between the crouched and the standing height.
	var col := ctx.collision
	if (
		col.body_blocked(position, WS.PLAYER_RADIUS * 0.99, WS.PLAYER_HEIGHT)
		and not col.body_blocked(position, WS.PLAYER_RADIUS * 0.99, WS.CROUCH_HEIGHT)
	):
		return
	crouched = false


func _photo_fly(wish: Vector2, sprint: bool, down: bool, up: bool, delta: float) -> void:
	var f := forward()
	var r := Vector3(cos(cam_yaw), 0.0, -sin(cam_yaw))
	var v := f * wish.y + r * wish.x + Vector3.UP * ((1.0 if up else 0.0) - (1.0 if down else 0.0))
	if v.length_squared() > 1.0:
		v = v.normalized()
	_photo_pos += v * WS.PHOTO_FLY_SPEED * (3.0 if sprint else 1.0) * delta
	# The ground stops the camera: it never flies under the road.
	if ctx != null and ctx.collision != null:
		var g := ctx.collision.ground_height(_photo_pos)
		_photo_pos.y = maxf(_photo_pos.y, (WS.WATER_Y if is_nan(g) else g) + TpsRig.GROUND_CLEAR)
	position = _photo_pos - Vector3.UP * WS.EYE
	_update_tile()


func _leave_photo(snap_back: bool) -> void:
	if not photo_mode:
		return
	photo_mode = false
	if snap_back:
		position = _photo_saved.get("pos", position)
		yaw = float(_photo_saved.get("yaw", yaw))
		cam_yaw = float(_photo_saved.get("cam_yaw", cam_yaw))
		cam_pitch = clampf(
			float(_photo_saved.get("cam_pitch", cam_pitch)), _pitch_min(), _pitch_max()
		)
		pitch = cam_pitch
	if avatar != null:
		avatar.top_level = false
		avatar.transform = Transform3D.IDENTITY
	if ctx != null and ctx.hud != null:
		ctx.hud.set_hud_visible(bool(_photo_saved.get("hud", true)))
	_apply_rotation()
	_snap_view()
	_update_tile()
	photo_mode_changed.emit(false)


## Right stick: response x^2, faster after STICK_FAST_AFTER s at full deflection, the pitch rate
## eased in the last STICK_EASE before a limit. The dead zone comes from the actions (0.15).
func _stick_look(dt: float) -> void:
	var v := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	var mag := v.length()
	if mag < 1e-4:
		_stick_full = 0.0
		return
	var dir := v / mag
	var resp := mag * mag
	_stick_full = _stick_full + dt if mag > 0.98 else 0.0
	var yr := STICK_YAW_FAST if _stick_full > STICK_FAST_AFTER else STICK_YAW
	var dp := -dir.y * resp * STICK_PITCH * dt * (-1.0 if _invert_y else 1.0)
	var room := (_pitch_max() - cam_pitch) if dp > 0.0 else (cam_pitch - _pitch_min())
	dp *= clampf(room / STICK_EASE, 0.15, 1.0)
	look(-dir.x * resp * yr * dt, dp)


func _apply_settings(s: Dictionary) -> void:
	_sensitivity = float(s.get("mouse_sensitivity", WS.MOUSE_SENSITIVITY))
	_invert_y = bool(s.get("invert_y", false))
	_fov_setting = float(s.get("fov", WS.FOV))
	_head_bob = bool(s.get("head_bob", true))
	_fp_fov = _fov_setting
	if rig != null:
		rig.base_fov = float(s.get("tps_fov", 60.0))
		var dist := float(s.get("tps_distance_m", 3.2))
		if not is_equal_approx(dist, _last_tps_distance):
			_last_tps_distance = dist
			rig.zoom = clampf(dist * WS.M, TpsRig.DIST_MIN, TpsRig.DIST_MAX)
		var sh := signf(float(s.get("shoulder", 1)))
		if sh != 0.0 and sh != signf(rig.side):
			rig.side = sh
		rig.auto_shoulder = bool(s.get("auto_shoulder", false))
	if avatar != null:
		avatar.set_hero(str(s.get("hero", "m")))
	var m := str(s.get("camera_mode", camera_mode))
	if m != camera_mode:
		set_camera_mode(m, _set_up)
	if camera != null and camera_mode == "first" and not photo_mode and _trans_len <= 0.0:
		camera.fov = _fov_setting


func _apply_rotation() -> void:
	rotation = Vector3(0.0, yaw, 0.0)
	if camera != null and not camera.top_level:
		camera.rotation = Vector3(cam_pitch, 0.0, 0.0)


## Resets every spring, offset and blend for the current pose and writes the camera at once.
func _snap_view() -> void:
	_trans_len = 0.0
	_tumble_len = 0.0
	_cam_dy = 0.0
	_step_snap = 0.0
	_bob_amp = 0.0
	_eye_h = WS.CROUCH_EYE if crouched else WS.EYE
	_fp_fov = _fov_setting
	if avatar != null:
		avatar.snap()
	if camera_mode == "third":
		_snap_rig()
	if _set_up:
		update_view(0.0)


func _snap_rig() -> void:
	if rig == null or ctx == null:
		return
	rig.yaw = cam_yaw
	rig.pitch = clampf(cam_pitch, TpsRig.PITCH_MIN, TpsRig.PITCH_MAX)
	rig.snap(position, velocity, yaw, _eye_h, grounded, _running, ctx.collision)
	cam_pitch = rig.pitch
	pitch = cam_pitch


func _start_transition(length: float, from_xf: Transform3D, from_fov: float) -> void:
	_trans_from = from_xf
	_trans_fov = from_fov
	_trans_t = 0.0
	_trans_len = length


## The first-person camera relative to the body (body yaw = cam_yaw in first person).
func _fp_local() -> Transform3D:
	var bv := 0.0
	var bl := 0.0
	if _head_bob:
		bv = -BOB_V * _bob_amp * cos(2.0 * _gait_phase)
		bl = BOB_L * _bob_amp * sin(_gait_phase)
	var tb := _tumble()
	# Down on the ground (down_view): the eye sinks with the body and tips up to the sky.
	var dw := 0.0
	if FeatureFlags.enabled("down_view"):
		dw = SM.smooth01(clampf(down_w, 0.0, 1.0))
	var eye := Vector3(bl, lerpf(_eye_h + _cam_dy + bv - tb.y, DOWN_EYE, dw), 0.0)
	var e := Vector3(cam_pitch + tb.x + DOWN_PITCH * dw, 0.0, 0.0)
	return Transform3D(Basis.from_euler(e), eye) * _kick_xform()


## The first-person roll (tumble_view) now: the pitch it adds (radians, once round forward) and
## how far it drops the eye (to TUMBLE_EYE half way).
func _tumble() -> Vector2:
	if _tumble_t >= _tumble_len:
		return Vector2.ZERO
	var w := _tumble_t / _tumble_len
	return Vector2(-TAU * SM.smooth01(w), (_eye_h - TUMBLE_EYE) * sin(PI * w))


func _fp_world() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, cam_yaw), position) * _fp_local()


func _camera_world() -> Transform3D:
	if camera == null:
		return Transform3D(SM.look_basis(cam_yaw, cam_pitch), eye_position())
	if camera.is_inside_tree():
		return camera.global_transform
	return camera.transform if camera.top_level else transform * camera.transform


func _node_world(n: Node3D) -> Transform3D:
	return n.global_transform if n.is_inside_tree() else transform * n.transform


func _pitch_min() -> float:
	return TpsRig.PITCH_MIN if camera_mode == "third" and not photo_mode else -FP_PITCH_LIMIT


func _pitch_max() -> float:
	return TpsRig.PITCH_MAX if camera_mode == "third" and not photo_mode else FP_PITCH_LIMIT


func _update_tile() -> void:
	var t := tile()
	if t == _last_tile:
		return
	_last_tile = t
	if t >= 0 and ctx != null and ctx.bus != null:
		ctx.bus.player_tile_changed.emit(D.tx(t), D.ty(t))


# --- Conversation (C emits conversation_changed; A frames it)


func _on_conversation_changed(id: String, active: bool) -> void:
	if active:
		var n := _npc_head(id)
		if is_nan(n.x):
			return
		if _conv_on:
			_end_conversation()
		_conv_id = id
		_conv_on = true
		_conv_npc = n
		_conv_t = 0.0
		_conv_reverse = false
		_conv_cut_t = 99.0
		var d := n - position
		_face_goal = atan2(-d.x, -d.z)
		_face_hl = HL_CONV_FACE
		if camera_mode == "third" and not photo_mode:
			_choose_shot()
			_start_transition(CONV_IN, _camera_world(), camera.fov)
		else:
			_conv_from = Vector2(cam_yaw, cam_pitch)
	elif _conv_on and (id == _conv_id or id.is_empty()):
		var was_third := camera_mode == "third" and not photo_mode
		var xf := _camera_world()
		var fv := camera.fov
		_end_conversation()
		if was_third:
			# Keep the final view: the rig resumes from its direction, blended back over CONV_OUT.
			var yp := SM.yaw_pitch_of(xf.basis)
			cam_yaw = yp.x
			cam_pitch = clampf(yp.y, TpsRig.PITCH_MIN, TpsRig.PITCH_MAX)
			pitch = cam_pitch
			rig.yaw = cam_yaw
			rig.pitch = cam_pitch
			rig.notify_look()
			_start_transition(CONV_OUT, xf, fv)


## The hero greets a resident with a wave and reaches toward a car, a poster, a dog or a cat to pet
## or the pigeons to throw crumbs (6.9 OneShot).
func _on_interact_requested(t: Dictionary) -> void:
	if avatar == null or photo_mode:
		return
	var kind := str(t.get("kind", ""))
	if kind == "resident" or kind == "pedestrian":
		avatar.play_gesture("wave")
	elif kind in ["vehicle", "poster", "dog", "pigeons", "cat"]:
		avatar.play_gesture("interact")


func _end_conversation() -> void:
	_conv_on = false
	_conv_id = ""
	_face_goal = NAN
	_face_hl = 0.0


## The resident's head: E's anchor_of(id) when the traffic feature has it, else the legacy avatar
## root + EYE; NAN when the resident is not drawn.
func _npc_head(id: String) -> Vector3:
	var none := Vector3(NAN, NAN, NAN)
	if ctx == null:
		return none
	var traffic := ctx.feature("traffic")
	if traffic != null and traffic.has_method("anchor_of"):
		var a: Variant = traffic.call("anchor_of", id)
		if (
			typeof(a) == TYPE_VECTOR3
			and not is_nan((a as Vector3).x)
			and (a as Vector3) != Vector3.ZERO
		):
			return a
	if ctx.view != null and ctx.view.avatars != null:
		var avs: Variant = ctx.view.avatars.get("_avatars")
		if typeof(avs) == TYPE_DICTIONARY and (avs as Dictionary).has(id):
			var root: Node3D = (avs as Dictionary)[id]["root"]
			if is_instance_valid(root) and root.visible:
				var g := (
					ctx.collision.ground_height(root.position) if ctx.collision != null else 0.0
				)
				return Vector3(
					root.position.x, (g if not is_nan(g) else 0.0) + WS.EYE, root.position.z
				)
	return none


## Picks the two-shot side: keep the side the camera is on (the 180-degree rule) unless the arm
## from the head is blocked there; with both sides blocked, come in closer.
func _choose_shot() -> void:
	var p := eye_position()
	var u := _conv_u(p)
	var s0 := Vector3(-u.z, 0.0, u.x)
	var cam := _camera_world().origin
	_conv_side = 1.0 if (cam - p).dot(s0) >= 0.0 else -1.0
	_conv_back = CONV_BACK
	var here := _shot_free(p, u, s0 * _conv_side, CONV_BACK)
	if here >= CONV_FREE_MIN:
		return
	var there := _shot_free(p, u, -s0 * _conv_side, CONV_BACK)
	if there >= CONV_FREE_MIN:
		_conv_side = -_conv_side
		return
	_conv_back = CONV_BACK_SHORT
	if (
		_shot_free(p, u, -s0 * _conv_side, CONV_BACK_SHORT)
		> _shot_free(p, u, s0 * _conv_side, CONV_BACK_SHORT) + 0.05
	):
		_conv_side = -_conv_side


func _shot_free(p: Vector3, u: Vector3, s: Vector3, back: float) -> float:
	var off := -u * back + s * CONV_SIDE + Vector3.UP * CONV_UP
	var len := off.length()
	return ctx.collision.sweep_sphere(p, off / len, len, CONV_PROBE) / len


func _conv_u(p: Vector3) -> Vector3:
	var u := Vector3(_conv_npc.x - p.x, 0.0, _conv_npc.z - p.z)
	if u.length_squared() < 1e-12:
		u = body_forward()
	return u.normalized()


## The two-shot (or, while the player types in C's dialogue, the reverse shot) camera transform.
func _conv_xform(dt: float) -> Transform3D:
	var p := eye_position()
	var n := _conv_npc
	var u := _conv_u(p)
	var s := Vector3(-u.z, 0.0, u.x) * _conv_side
	_conv_cut_t += dt
	var chat := ctx.feature("chat")
	var typing := chat != null and chat.has_method("is_typing") and bool(chat.call("is_typing"))
	if typing != _conv_reverse and _conv_cut_t >= REVERSE_GAP and _trans_len <= 0.0:
		_conv_reverse = typing
		_conv_cut_t = 0.0
	var c: Vector3
	var l: Vector3
	if _conv_reverse:
		c = n + u * _conv_back + s * CONV_SIDE + Vector3.UP * CONV_UP
		l = n + (p - n) * CONV_LOOK_T - Vector3.UP * CONV_LOOK_DOWN
	else:
		c = p - u * _conv_back + s * CONV_SIDE + Vector3.UP * CONV_UP
		l = p + (n - p) * CONV_LOOK_T - Vector3.UP * CONV_LOOK_DOWN
	return Transform3D(Basis.looking_at(l - c, Vector3.UP), c)


## Refreshes the resident's head and, in first person, turns the view toward it over CONV_IN.
func _update_conversation(dt: float) -> void:
	if not _conv_on:
		return
	var traffic := ctx.feature("traffic")
	if traffic != null and traffic.has_method("anchor_of"):
		var a: Variant = traffic.call("anchor_of", _conv_id)
		if (
			typeof(a) == TYPE_VECTOR3
			and not is_nan((a as Vector3).x)
			and (a as Vector3) != Vector3.ZERO
		):
			_conv_npc = a
	_conv_t += dt
	if camera_mode == "first" and not photo_mode:
		var d := _conv_npc - eye_position()
		var s := SM.smooth01(_conv_t / CONV_IN)
		var ty := atan2(-d.x, -d.z)
		var tp := clampf(atan2(d.y, Vector2(d.x, d.z).length()), -FP_PITCH_LIMIT, FP_PITCH_LIMIT)
		cam_yaw = wrapf(_conv_from.x + wrapf(ty - _conv_from.x, -PI, PI) * s, -PI, PI)
		cam_pitch = lerpf(_conv_from.y, tp, s)
		pitch = cam_pitch
		yaw = cam_yaw
		_apply_rotation()
