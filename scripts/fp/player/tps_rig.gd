class_name TpsRig
extends RefCounted
## Over-the-shoulder follow camera (D13; docs/fp/slices/A-player.md 6.5-6.6): an analytic spring
## arm root -> shoulder -> hand -> camera, swept against CollisionWorld boxes (no physics, D2).
## Pure logic: FpPlayer feeds it the body state each frame and copies cam_xform, fov and
## player_alpha to the camera and the avatar. Lengths are metres * M.

const WS := preload("res://scripts/fp/world_scale.gd")
const SM := preload("res://scripts/fp/player/spring_math.gd")
const M := WS.M

# --- Framing
const PIVOT_BELOW_EYE := 0.10 * M    # pivot 1.55 m above the feet: the neck, 0.10 m under the eye
const ARM_UP := 0.10 * M             # the "hand" above the shoulder pivot
const SHOULDER_X := 0.40 * M
const DIST_DEFAULT := 3.2 * M
const DIST_MIN := 1.6 * M
const DIST_MAX := 5.0 * M
const ZOOM_STEP := 0.4 * M
const DIST_RUN_ADD := 0.4 * M
const CAM_RADIUS := 0.20 * M         # > the near-plane corner (0.124 m at 60 deg), < PLAYER_RADIUS
const GROUND_CLEAR := 0.20 * M
const FADE_NEAR := 0.45 * M          # the hero is hidden when the camera is this close to the head
const FADE_FAR := 0.90 * M
const LEAD_TIME := 0.12
const LEAD_MAX := 0.4 * M
## Sweeps stop this far before a hit.
const SKIN := 1e-5
## Boxes farther than this from the pivot cannot touch the arm (5.0 + 0.4 + 0.4 m + the probe).
const REACH := 6.2 * M
# --- Angles
const PITCH_MIN := deg_to_rad(-70.0)
const PITCH_MAX := deg_to_rad(50.0)
const PITCH_REST := deg_to_rad(-10.0)
# --- Halflives (seconds)
const HL_LATERAL := 0.03
const HL_DEPTH := 0.05
const HL_VERTICAL := 0.08
const HL_VERTICAL_AIR := 0.30
const HL_LOOKAHEAD := 0.35
const HL_SIDE := 0.12
const HL_ZOOM := 0.12
const HL_FOV := 0.25
const HL_FEELER_IN := 0.05
const HL_RELEASE := 0.20
const RELEASE_HOLD := 0.15
# --- Recentering behind the body while moving
const RECENTER_WAIT := 1.0
const RECENTER_HL_WALK := 1.6
const RECENTER_HL_RUN := 0.8
const RECENTER_MAX := deg_to_rad(135.0)
const RECENTER_MIN_SPEED := 0.3 * M
# --- FOV
const FOV_RUN_ADD := 6.0
# --- Auto shoulder swap (settings.auto_shoulder)
const AUTO_SWAP_FRAC := 0.5
const AUTO_SWAP_TIME := 0.5
# --- Soft aim assist toward the focused interactable (6.7)
const ASSIST_YAW := deg_to_rad(10.0)
const ASSIST_PITCH := deg_to_rad(6.0)
const ASSIST_HL := 0.6
const ASSIST_WAIT := 0.5
## Predictive feelers (after Lyra): [yaw offset deg, pitch offset deg, weight, retrace interval frames].
const FEELERS := [[16.0, 0.0, 0.75, 3], [-16.0, 0.0, 0.75, 3], [32.0, 0.0, 0.5, 5], [-32.0, 0.0, 0.5, 5], [0.0, 20.0, 1.0, 4], [0.0, -20.0, 0.5, 4]]

## View angles (radians). FpPlayer writes them on look input and reads them back after update().
var yaw: float = 0.0
var pitch: float = PITCH_REST
## Arm length goal before pitch scaling (settings.tps_distance_m, then the wheel).
var zoom: float = DIST_DEFAULT
## Factor on that goal (the actions feature pulls the arm in while the guard is up).
var arm_scale: float = 1.0
## Shoulder goal: 1 right, -1 left.
var side: float = 1.0
var base_fov: float = 60.0
var auto_shoulder: bool = false
## World point the soft assist leans toward (NAN components: none).
var assist_target: Vector3 = Vector3(NAN, NAN, NAN)
## Agent boxes (world AABBs) that pull the arm in hard when the camera would end inside one.
var agent_boxes: Array[AABB] = []
## Outputs.
var cam_xform: Transform3D = Transform3D()
var fov: float = 60.0
var player_alpha: float = 1.0
## Cost of the last update() in microseconds.
var update_us: float = 0.0
## Sweeps run by the last update().
var sweeps: int = 0

var _pivot: Vector3 = Vector3.ZERO
var _prev_target: Vector3 = Vector3.ZERO
var _side_cur: float = 1.0
var _side_v: float = 0.0
var _zoom_cur: float = DIST_DEFAULT
var _lead: float = 0.0
var _arm: float = DIST_DEFAULT
var _limited: bool = false
var _soft_block: float = 1.0
var _feeler_frames: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0, 0])
var _feeler_frac: PackedFloat32Array = PackedFloat32Array([1.0, 1.0, 1.0, 1.0, 1.0, 1.0])
var _since_look: float = 99.0
var _release_timer: float = 0.0
var _auto_t: float = 0.0
var _assist_anchor: Vector2 = Vector2(NAN, NAN)
var _boxes: Array[AABB] = []


## Look input (radians, already scaled). Clamps pitch to the third-person limits and restarts the
## recenter and assist delays.
func add_look(d_yaw: float, d_pitch: float) -> void:
	yaw = wrapf(yaw + d_yaw, -PI, PI)
	pitch = clampf(pitch + d_pitch, PITCH_MIN, PITCH_MAX)
	if absf(d_yaw) + absf(d_pitch) > 1e-6:
		notify_look()


## Marks look input now (the recenter and assist wait from here).
func notify_look() -> void:
	_since_look = 0.0
	_assist_anchor = Vector2(NAN, NAN)


## Seconds since the last look input.
func since_look() -> float:
	return _since_look


## Wheel zoom: dir -1 in, +1 out, in ZOOM_STEP steps within [DIST_MIN, DIST_MAX].
func step_zoom(dir: int) -> void:
	zoom = clampf(zoom + float(dir) * ZOOM_STEP, DIST_MIN, DIST_MAX)


## Q: swap the shoulder goal and clear the auto-swap state.
func swap_shoulder() -> void:
	side = -signf(side) if side != 0.0 else -1.0
	_auto_t = 0.0


## True while the arm is shorter than its free length because of a wall (and until it has eased
## back out).
func is_limited() -> bool:
	return _limited


## Puts every spring, damper, timer and feeler at its steady state for the current pose (spawn,
## load, teleport, photo-mode exit): the next frame shows no swoop.
func snap(feet: Vector3, vel: Vector3, body_yaw: float, eye_h: float, grounded: bool, running: bool, col: CollisionWorld) -> void:
	_solve(0.0, feet, vel, body_yaw, eye_h, grounded, running, col, true)


## One frame. feet, vel (u/s) and body_yaw describe the body; eye_h is the current eye height
## above the feet (crouch lowers it); col may be null (no collision).
func update(dt: float, feet: Vector3, vel: Vector3, body_yaw: float, eye_h: float, grounded: bool, running: bool, col: CollisionWorld) -> void:
	_solve(dt, feet, vel, body_yaw, eye_h, grounded, running, col, false)


## Advances the look timer and the recentering by dt. FpPlayer calls it inside its movement
## sub-steps, so the view (and the camera-relative input it steers) turns the same way at any
## frame rate. flat_speed is the body's horizontal speed, speed_hint the speed the player asks
## for (both u/s; the larger picks the recenter rate).
func advance(dt: float, flat_speed: float, speed_hint: float, body_yaw: float) -> void:
	_since_look += dt
	_recenter(dt, flat_speed, maxf(flat_speed, speed_hint), body_yaw)


## The arm length in use (collision-limited), in units.
func current_arm() -> float:
	return _arm


## The unobstructed arm for the current zoom and pitch (no run extension).
func free_arm() -> float:
	return zoom * _pitch_scale()


## The damped pivot (neck) the arm hangs from.
func pivot() -> Vector3:
	return _pivot


func _pitch_scale() -> float:
	if pitch > 0.0:
		return lerpf(1.0, 0.6, pitch / PITCH_MAX)        # worm's-eye: pull in instead of hitting the ground
	return lerpf(1.0, 1.15, pitch / PITCH_MIN)


func _solve(dt: float, feet: Vector3, vel: Vector3, body_yaw: float, eye_h: float, grounded: bool, running: bool, col: CollisionWorld, snapping: bool) -> void:
	var t0 := Time.get_ticks_usec()
	sweeps = 0
	pitch = clampf(pitch, PITCH_MIN, PITCH_MAX)
	var flat := Vector2(vel.x, vel.z).length()
	if not snapping:
		_assist(dt, flat)
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var back := Vector3(sin(yaw), 0.0, cos(yaw))
	# Pivot follow, damped per camera-local axis (lateral, depth, vertical). The target moves
	# through the frame, so each axis solves the damper exactly for a target moving at its
	# average speed: the lag is the same at 30 and at 144 fps.
	var target := feet + Vector3.UP * (eye_h - PIVOT_BELOW_EYE)
	if snapping or dt <= 0.0:
		if snapping:
			_pivot = target
		_prev_target = target
	else:
		var err := _pivot - _prev_target
		var vt := (target - _prev_target) / dt
		var ex := _track(err.dot(right), vt.dot(right), HL_LATERAL, dt)
		var ez := _track(err.dot(back), vt.dot(back), HL_DEPTH, dt)
		var ey := _track(err.y, vt.y, HL_VERTICAL if grounded else HL_VERTICAL_AIR, dt)
		_pivot = target + right * ex + back * ez + Vector3.UP * ey
		_prev_target = target
	# Lateral look-ahead: leave screen space in front of a character crossing the frame.
	var lead_goal := clampf(vel.dot(right) * LEAD_TIME, -LEAD_MAX, LEAD_MAX)
	# Shoulder, zoom, run extension.
	var run_add := DIST_RUN_ADD if running and flat > 0.5 * WS.RUN else 0.0
	var want := zoom * _pitch_scale() * arm_scale + run_add
	var fov_goal := base_fov + (FOV_RUN_ADD if running and flat > 0.8 * WS.RUN else 0.0)
	if snapping:
		_lead = lead_goal
		_side_cur = side
		_side_v = 0.0
		_zoom_cur = want
		fov = fov_goal
	else:
		_lead = SM.damp(_lead, lead_goal, HL_LOOKAHEAD, dt)
		var s := SM.spring(_side_cur, _side_v, side, HL_SIDE, dt)
		_side_cur = s.x
		_side_v = s.y
		_zoom_cur = SM.damp(_zoom_cur, want, HL_ZOOM, dt)
		fov = SM.damp(fov, fov_goal, HL_FOV, dt)
	# Rig points: root (inside the body) -> shoulder -> hand -> camera.
	_boxes = col.boxes_near(_pivot, REACH) if col != null else ([] as Array[AABB])
	# The damped pivot can lag behind into a wall the body walks away from: keep the root on the
	# free side, swept from the body's own (always free) neck point.
	var root := _pivot
	var lag := _pivot - target
	if lag.length_squared() > 1e-12:
		var ll := lag.length()
		root = target + lag / ll * _sweep(target, lag / ll, ll, CAM_RADIUS * 1.05)
	var lateral := right * (_side_cur * SHOULDER_X + _lead)
	var lat_len := lateral.length()
	var shoulder := root
	var lat_free := 1.0
	if lat_len > 1e-6:
		var t := _sweep(root, lateral / lat_len, lat_len, CAM_RADIUS * 1.05)
		shoulder = root + lateral / lat_len * t
		lat_free = t / lat_len
	_auto_swap(dt, lat_free, snapping)
	var hand := shoulder + Vector3.UP * ARM_UP
	var rot := SM.look_basis(yaw, pitch)
	var cam_back := rot.z
	# Main ray: a hard limit (never inside a box). Feelers: soft and predictive.
	var hard := _sweep(hand, cam_back, _zoom_cur, CAM_RADIUS)
	var soft_goal := 1.0
	for i in range(FEELERS.size()):
		_feeler_frames[i] -= 1
		if snapping or _feeler_frames[i] <= 0:
			var f: Array = FEELERS[i]
			var d := (Basis(Vector3.UP, deg_to_rad(float(f[0]))) * Basis(rot.x, deg_to_rad(float(f[1])))) * cam_back
			var tf := _sweep(hand, d.normalized(), _zoom_cur, CAM_RADIUS)
			var frac := tf / maxf(_zoom_cur, 1e-6)
			_feeler_frac[i] = 1.0 - (1.0 - frac) * float(f[2])
			_feeler_frames[i] = 0 if frac < 1.0 else int(f[3])   # retrace every frame while blocked
		soft_goal = minf(soft_goal, _feeler_frac[i])
	if snapping:
		_soft_block = soft_goal
	else:
		_soft_block = SM.damp(_soft_block, soft_goal, HL_FEELER_IN if soft_goal < _soft_block else HL_RELEASE, dt)
	var want_arm := minf(hard, _zoom_cur * _soft_block)
	var blocked := hard < _zoom_cur - 1e-6 or _soft_block < 0.9999
	if snapping:
		_arm = want_arm
		_release_timer = 0.0
		_limited = blocked
	elif want_arm < _arm - 1e-7:
		_arm = want_arm                                     # pull in at once
		_release_timer = RELEASE_HOLD
		_limited = _limited or blocked
	elif not _limited:
		_arm = want_arm                                     # zoom and pitch changes follow directly
	elif want_arm <= _arm + 1e-7:
		_arm = want_arm                                     # still held in: restart the hold
		_release_timer = RELEASE_HOLD
	else:
		_release_timer -= dt                                # free again: hold, then ease out
		if _release_timer <= 0.0:
			_arm = minf(SM.damp(_arm, want_arm, HL_RELEASE, dt), want_arm)
			if _arm > want_arm - 1e-5 * M and not blocked:
				_arm = want_arm
				_limited = false
	var cam_pos := hand + cam_back * _arm
	# Inside a car or bus box (E's agents): pull in hard to its surface.
	for b: AABB in agent_boxes:
		var g := b.grow(CAM_RADIUS)
		if g.has_point(cam_pos) and not g.has_point(hand):
			var ta := CollisionWorld.ray_box_t(hand, cam_back, g)
			if ta >= 0.0 and ta < _arm:
				_arm = ta
				_limited = true
				cam_pos = hand + cam_back * _arm
	# The ground lifts the camera: a hill or a curb is not a wall.
	if col != null:
		var gy := col.ground_height(cam_pos)
		if is_nan(gy):
			gy = WS.WATER_Y
		cam_pos.y = maxf(cam_pos.y, gy + GROUND_CLEAR)
	cam_xform = Transform3D(rot, cam_pos)
	var head := feet + Vector3.UP * eye_h
	player_alpha = clampf(inverse_lerp(FADE_NEAR, FADE_FAR, cam_pos.distance_to(head)), 0.0, 1.0)
	update_us = float(Time.get_ticks_usec() - t0)


## Error after dt of an exponential damper (halflife hl) chasing a target that moves at speed v
## away from it: e' = -k e - v, solved exactly.
static func _track(e0: float, v: float, hl: float, dt: float) -> float:
	var k := SM.LN2 / maxf(hl, 1e-5)
	return (e0 + v / k) * exp(-k * dt) - v / k


func _sweep(origin: Vector3, dir: Vector3, max_dist: float, radius: float) -> float:
	sweeps += 1
	var t := CollisionWorld.sweep_boxes(origin, dir, max_dist, radius, _boxes)
	# Stop a hair short of the grown box so the probe never ends on (or, rounded, in) its face.
	return maxf(0.0, t - SKIN) if t < max_dist else t


## After RECENTER_WAIT s with no look input while moving, ease the view behind the body (a
## faster rate for faster moves); never while idle and never when the body faces the camera.
func _recenter(dt: float, flat: float, speed: float, body_yaw: float) -> void:
	if speed <= RECENTER_MIN_SPEED or _since_look <= RECENTER_WAIT:
		return
	var diff := wrapf(body_yaw - yaw, -PI, PI)
	if absf(diff) >= RECENTER_MAX:
		return
	var hl := lerpf(RECENTER_HL_WALK, RECENTER_HL_RUN, clampf((speed - WS.WALK) / (WS.RUN - WS.WALK), 0.0, 1.0))
	yaw = wrapf(yaw + diff * SM.damp_factor(hl, dt), -PI, PI)
	pitch = SM.damp(pitch, PITCH_REST, hl * 1.5, dt)


## Biases the view at most ASSIST_YAW / ASSIST_PITCH toward assist_target, from where the player
## left it, after ASSIST_WAIT s without look input and below walking speed.
func _assist(dt: float, flat: float) -> void:
	if is_nan(assist_target.x) or _since_look < ASSIST_WAIT or flat >= WS.WALK:
		_assist_anchor = Vector2(NAN, NAN)
		return
	if is_nan(_assist_anchor.x):
		_assist_anchor = Vector2(yaw, pitch)
	var d := assist_target - _pivot
	if d.length_squared() < 1e-10:
		return
	var ty := atan2(-d.x, -d.z)
	var tp := atan2(d.y, Vector2(d.x, d.z).length())
	var gy := _assist_anchor.x + clampf(wrapf(ty - _assist_anchor.x, -PI, PI), -ASSIST_YAW, ASSIST_YAW)
	var gp := _assist_anchor.y + clampf(tp - _assist_anchor.y, -ASSIST_PITCH, ASSIST_PITCH)
	yaw = SM.damp_angle(yaw, gy, ASSIST_HL, dt)
	pitch = clampf(SM.damp(pitch, gp, ASSIST_HL, dt), PITCH_MIN, PITCH_MAX)


func _auto_swap(dt: float, lat_free: float, snapping: bool) -> void:
	if not auto_shoulder or snapping:
		_auto_t = 0.0
		return
	if lat_free < AUTO_SWAP_FRAC and signf(_side_cur) == signf(side):
		_auto_t += dt
		if _auto_t > AUTO_SWAP_TIME:
			side = -side
			_auto_t = 0.0
	else:
		_auto_t = 0.0
