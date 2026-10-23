extends SkeletonModifier3D
## A dog's life on top of its clip (DogBodies puts one on every dog skeleton): the tail wags (wag
## 0..1, faster as it grows), the head turns and tilts toward a world point (look) and jerks up
## with each bark (bark 1, easing back to 0 here). It turns bones about the model's own up and
## right axes, found once from the transforms between the skeleton and the scene root, so it does
## not depend on how the bones are rolled.

const TAIL: Array[String] = ["Tail1", "Tail2", "Tail3", "Tail4", "Tail5", "Tail6"]
## Swing of each tail bone at full wag (rad), the beat from a calm to a delighted wag (Hz) and the
## lag from one tail bone to the next (rad of the beat).
const WAG_ANGLE := 0.4
const WAG_HZ := Vector2(1.5, 4.5)
const WAG_LAG := 0.7
## How far the head turns and tilts toward look (rad, the neck takes NECK_SHARE of it) and how
## fast it follows (1/s); a point further behind than LOOK_GIVE_UP is not followed at all.
const LOOK_YAW := 1.1
const LOOK_UP := 0.7
const LOOK_DOWN := 0.3
const LOOK_RATE := 6.0
const LOOK_GIVE_UP := 1.9
const NECK_SHARE := 0.4
## The head's height in model units (the tilt toward look starts there).
const HEAD_UNITS := 2.65
## Head lift at a bark's peak (rad) and how fast a bark eases off (1/s).
const BARK_LIFT := 0.3
const BARK_FALL := 7.0

var wag: float = 0.0
## World point to look at; NAN x for straight ahead.
var look := Vector3(NAN, NAN, NAN)
var bark: float = 0.0
## Game seconds per real second (0 while the game is paused).
var pace: float = 1.0
var _tail: PackedInt32Array = PackedInt32Array()
var _neck: int = -1
var _head: int = -1
var _up := Vector3.UP
var _right := Vector3.LEFT
var _scene: Node3D = null
var _phase: float = 0.0
var _yaw: float = 0.0
var _tilt: float = 0.0


## Finds the bones and the model's axes in skeleton space (the dog faces +Z in scene, its right
## is -X).
func bind(skel: Skeleton3D, scene: Node3D) -> void:
	_scene = scene
	_tail.clear()
	for n: String in TAIL:
		var k := skel.find_bone(n)
		if k >= 0:
			_tail.append(k)
	_neck = skel.find_bone("Neck1")
	_head = skel.find_bone("Head")
	var xf := Transform3D.IDENTITY
	var at: Node = skel
	while at != null and at != scene:
		if at is Node3D:
			xf = (at as Node3D).transform * xf
		at = at.get_parent()
	var inv := xf.basis.inverse()
	_up = (inv * Vector3.UP).normalized()
	_right = (inv * Vector3.LEFT).normalized()


## Back to a still tail and a straight head (a body going back to the pool).
func calm() -> void:
	wag = 0.0
	bark = 0.0
	look = Vector3(NAN, NAN, NAN)
	_yaw = 0.0
	_tilt = 0.0


func _process_modification_with_delta(real_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	var delta := real_delta * pace
	bark = maxf(0.0, bark - BARK_FALL * delta)
	var w := clampf(wag, 0.0, 1.0)
	_phase = fmod(_phase + TAU * lerpf(WAG_HZ.x, WAG_HZ.y, w) * delta, TAU)
	if w > 0.01:
		for k in range(_tail.size()):
			var a := WAG_ANGLE * w * (1.0 - 0.12 * k) * sin(_phase - WAG_LAG * k)
			_turn(sk, _tail[k], _up, a)
	var want := _aim()
	var f := 1.0 - exp(-LOOK_RATE * delta)
	_yaw = lerpf(_yaw, want.x, f)
	_tilt = lerpf(_tilt, want.y, f)
	var lift := _tilt + BARK_LIFT * sin(PI * 0.5 * bark)
	for k: int in [_neck, _head]:
		var share := NECK_SHARE if k == _neck else 1.0 - NECK_SHARE
		_turn(sk, k, _up, _yaw * share)
		_turn(sk, k, _right, lift * share)


## (yaw, tilt) toward look in the dog's frame, (0, 0) without a point or for one far behind.
func _aim() -> Vector2:
	if is_nan(look.x) or _scene == null or not is_instance_valid(_scene):
		return Vector2.ZERO
	var local := _scene.global_transform.affine_inverse() * look
	var yaw := atan2(local.x, local.z)
	if absf(yaw) > LOOK_GIVE_UP:
		return Vector2.ZERO
	var flat := Vector2(local.x, local.z).length()
	var tilt := atan2(local.y - HEAD_UNITS, maxf(flat, 0.01))
	return Vector2(clampf(yaw, -LOOK_YAW, LOOK_YAW), clampf(tilt, -LOOK_DOWN, LOOK_UP))


## Turns bone k by angle about a skeleton-space axis, on top of its pose.
static func _turn(sk: Skeleton3D, k: int, axis: Vector3, angle: float) -> void:
	if k < 0 or absf(angle) < 1e-4:
		return
	var parent := sk.get_bone_parent(k)
	var basis := sk.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	var local_axis := (basis.inverse() * axis).normalized()
	sk.set_bone_pose_rotation(k, Quaternion(local_axis, angle) * sk.get_bone_pose_rotation(k))
