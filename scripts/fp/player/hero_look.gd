extends RefCounted
## The hero's head look (A-player.md 6.9; hero_rig.gd): LookAtModifier3Ds on Neck and Head turn
## the head toward a look target within the head's limits, the Neck taking a share of the turn. A
## target that jumps is smoothed (the head turns rather than snaps), and the influence fades out
## while the target is outside the limits and comes back once it is well inside them. The
## modifiers run in the skeleton's own update, after the AnimationTree has posed it.

const AP := preload("res://scripts/fp/asset_paths.gd")

## Head limits (yaw, pitch), the Neck's share and limit, the modifier's own interpolation, the
## influence fade when the target leaves the limits, and the halflife that smooths a jumping
## target.
const LOOK_YAW := deg_to_rad(70.0)
const LOOK_PITCH := deg_to_rad(35.0)
## Anatomical limits apply to the finished head, not separately to Neck and Head. In combat the
## chin stays down even when a view target is high above the street.
const HEAD_PITCH := deg_to_rad(20.0)
const COMBAT_YAW := deg_to_rad(45.0)
const COMBAT_PITCH := deg_to_rad(6.0)
const NECK_INFLUENCE := 0.35
const NECK_LIMIT := deg_to_rad(45.0)
const LOOK_DURATION := 0.35
const LOOK_FADE := 0.3
const HL_LOOK := 0.12
## A faded-out look comes back once the target is this far inside the limits (no flicker at the
## edge).
const LOOK_REARM := deg_to_rad(8.0)
## Skeleton-local (metres): closer targets interpolate (LookAtModifier3D.origin_safe_margin).
const LOOK_SAFE_MARGIN := 0.5

var head_look: LookAtModifier3D
var neck_look: LookAtModifier3D
var look_marker: Marker3D
## Influence (0..1) and whether the modifier last found its target within its limits.
var look_weight: float = 0.0
var look_within: bool = false
## The head's forward (world) as the look-at modifiers left it, from the last frame they ran.
var head_forward: Vector3 = Vector3.ZERO
var _skeleton: Skeleton3D
var _holder: Node3D
var _head_bone: int = -1
var _goal: Vector3 = Vector3(NAN, NAN, NAN)
var _dir: Vector3 = Vector3.ZERO
var _dist: float = 0.0


## Adds the modifiers under sk and the target marker under holder (the body).
func _init(sk: Skeleton3D, holder: Node3D) -> void:
	_skeleton = sk
	_holder = holder
	_head_bone = sk.find_bone("Head")
	# The Neck goes first so the Head resolves what remains.
	neck_look = _modifier("NeckLook", "Neck", NECK_LIMIT, NECK_LIMIT)
	head_look = _modifier("HeadLook", "Head", LOOK_YAW, LOOK_PITCH)
	look_marker = Marker3D.new()
	look_marker.name = "LookTarget"
	look_marker.top_level = true
	holder.add_child(look_marker)
	neck_look.target_node = neck_look.get_path_to(look_marker)
	head_look.target_node = head_look.get_path_to(look_marker)
	head_look.modification_processed.connect(_on_processed)
	_set_weight(0.0)


## The world point the head turns toward; NAN components let the head return to the clip.
func set_target(p: Vector3) -> void:
	_goal = p


## Forgets the smoothed direction (a teleport): the next target is taken at once.
func reset() -> void:
	_dir = Vector3.ZERO


## Smooths the target's direction from the head (a jump between targets turns the head rather
## than snapping it) and fades the influence out while the target is outside the limits.
func update(dt: float) -> void:
	var head := _skeleton.global_transform * _skeleton.get_bone_global_pose(_head_bone).origin
	var want := 0.0
	if not is_nan(_goal.x):
		var d := _goal - head
		var dist := d.length()
		if dist > 1e-6:
			var dir := d / dist
			if _dir == Vector3.ZERO or dt <= 0.0:
				_dir = dir
				_dist = dist
			else:
				var s := 1.0 - pow(0.5, dt / HL_LOOK)
				_dir = _dir.slerp(dir, s).normalized()
				_dist = lerpf(_dist, dist, s)
			if look_marker.is_inside_tree():
				look_marker.global_position = head + _dir * _dist
			else:
				look_marker.position = head + _dir * _dist
			want = 1.0 if look_within or look_weight <= 0.0 else 0.0
	if look_weight <= 0.0 and want > 0.0 and not _within_limits(head, LOOK_REARM):
		want = 0.0
	var w := want if dt <= 0.0 else move_toward(look_weight, want, dt / LOOK_FADE)
	_set_weight(w)


func _modifier(n: String, bone: String, yaw_lim: float, pitch_lim: float) -> LookAtModifier3D:
	var m := LookAtModifier3D.new()
	m.name = n
	m.bone_name = bone
	m.forward_axis = AP.CHAR_LOOK_AXIS
	m.primary_rotation_axis = Vector3.AXIS_Y
	m.use_secondary_rotation = true
	m.use_angle_limitation = true
	m.symmetry_limitation = true
	# The limit angles span both sides.
	m.primary_limit_angle = yaw_lim * 2.0
	m.secondary_limit_angle = pitch_lim * 2.0
	m.duration = LOOK_DURATION
	m.transition_type = Tween.TRANS_SINE
	m.ease_type = Tween.EASE_IN_OUT
	m.origin_safe_margin = LOOK_SAFE_MARGIN
	_skeleton.add_child(m)
	return m


func _on_processed() -> void:
	look_within = head_look.is_target_within_limitation()
	clamp_head(_skeleton, _holder.global_basis, LOOK_YAW, HEAD_PITCH)
	var head := _skeleton.get_bone_global_pose(_head_bone).basis
	head_forward = (_skeleton.global_transform.basis * head.z).normalized()


## A direction bounded in the torso's frame. The frame is orthonormalized so stature never
## changes the limits.
static func bounded_direction(
	dir: Vector3, torso: Basis, yaw_max: float, pitch_max: float
) -> Vector3:
	var frame := torso.orthonormalized()
	var local := frame.inverse() * dir.normalized()
	var yaw := clampf(atan2(local.x, local.z), -yaw_max, yaw_max)
	var pitch := clampf(atan2(local.y, Vector2(local.x, local.z).length()), -pitch_max, pitch_max)
	return frame * Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))


## Corrects the complete head after the neck, look-at and clip rotations have accumulated. The
## combat pose calls this again after adding the spine's turn and lean.
static func clamp_head(sk: Skeleton3D, torso: Basis, yaw_max: float, pitch_max: float) -> void:
	var bone := sk.find_bone("Head")
	if bone < 0:
		return
	var world := sk.global_basis * sk.get_bone_global_pose(bone).basis
	var forward := world.z.normalized()
	var bounded := bounded_direction(forward, torso, yaw_max, pitch_max)
	var parent := sk.get_bone_parent(bone)
	var parent_world := sk.global_basis
	if parent >= 0:
		parent_world *= sk.get_bone_global_pose(parent).basis
	var correction := Basis(Quaternion(forward, bounded.normalized()))
	var pose := sk.get_bone_pose(bone)
	pose.basis = parent_world.inverse() * correction * parent_world * pose.basis
	sk.set_bone_pose(bone, pose)


## The analytic limit test, used while the modifier is faded out (its flag is then stale): the
## target's yaw and pitch from the chest's forward.
func _within_limits(head: Vector3, margin: float) -> bool:
	var chest := _skeleton.find_bone("UpperChest")
	if chest < 0:
		return true
	var xf := _skeleton.global_transform * _skeleton.get_bone_global_pose(chest)
	var local := xf.basis.inverse() * (look_marker.global_position - head)
	var yaw := atan2(local.x, local.z)
	var pitch := atan2(local.y, Vector2(local.x, local.z).length())
	return absf(yaw) <= LOOK_YAW - margin and absf(pitch) <= LOOK_PITCH - margin


func _set_weight(w: float) -> void:
	look_weight = w
	head_look.influence = w
	neck_look.influence = NECK_INFLUENCE * w
	head_look.active = w > 0.0
	neck_look.active = w > 0.0
