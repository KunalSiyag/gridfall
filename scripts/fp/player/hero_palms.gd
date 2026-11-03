extends RefCounted
## Turning the hero's hands about the wrist so that their palms face a given direction
## (hero_strike_pose.gd, pulling someone out of a car: the fists wrap the collar and the arm, they
## do not float at them). The hand IK puts a wrist at its goal and leaves the hand turned as the
## clip had it.


## [hand bone, the palm's outward normal in the bone's own frame] for the hand of sk's side ("Left"
## or "Right"): the side the fingers curl toward, from the rest pose's knuckle line. Empty without
## finger bones.
static func axis(sk: Skeleton3D, side: String) -> Array:
	var hand := sk.find_bone(side + "Hand")
	var at := {}
	for n: String in [
		"IndexProximal", "LittleProximal", "MiddleProximal", "MiddleDistal", "ThumbProximal"
	]:
		var b := sk.find_bone(side + n)
		if hand < 0 or b < 0:
			return []
		at[n] = sk.get_bone_global_rest(b).origin
	var along: Vector3 = (at["MiddleDistal"] - at["MiddleProximal"]).normalized()
	var across: Vector3 = (at["IndexProximal"] - at["LittleProximal"]).normalized()
	var palm := across.cross(along)
	var knuckles := (
		across if (at["ThumbProximal"] - at["MiddleProximal"]).dot(palm) >= 0.0 else -across
	)
	var normal := knuckles.cross(along).normalized()
	return [hand, (sk.get_bone_global_rest(hand).basis.inverse() * normal).normalized()]


## Turns the hand of `axis` (axis()'s) about its own wrist, in skeleton sk, so that its palm faces
## dir (world; need not be a unit vector).
static func face(sk: Skeleton3D, axis: Array, dir: Vector3) -> void:
	if axis.size() < 2 or dir.length() < 1e-5:
		return
	var b: int = axis[0]
	var global := sk.get_bone_global_pose(b).basis
	var now := (global * (axis[1] as Vector3)).normalized()
	var want := (sk.global_transform.basis.inverse() * dir).normalized()
	if now.dot(want) > 0.9999:
		return
	var q := Quaternion(now, want)
	var parent := sk.get_bone_parent(b)
	var pg := (
		sk.get_bone_global_pose(parent).basis.get_rotation_quaternion()
		if parent >= 0
		else Quaternion()
	)
	var g := global.get_rotation_quaternion()
	sk.set_bone_pose_rotation(b, (pg.inverse() * q * g).normalized())
