extends RefCounted
## Clips made from the mocap ones by hand-keyed bone rotations (build_anim_library.gd adds them to
## both libraries: the kick as a UAL clip, the get-in and get-out of a car per gender, see car_in).
## The kick: a front kick with the right (rear) leg out of the guard
## stance (the first frame of punch_jab): the knee comes up, the leg snaps out along the body's +Z
## at contact (KICK_HIT), comes back and goes down, the hips leaning back over the standing leg.
## Every pose is built in skeleton space (rotations about the body's lateral X axis) and turned
## back into local bone rotations, so it holds on any body on the humanoid profile.

const SKEL := "%GeneralSkeleton:"
const FPS := 30.0
const KICK_LEN := 0.7
const KICK_HIT := 0.24
## Kick keys: [time (s), thigh lift, knee bend, hip lean back, foot point] (degrees).
const KICK_KEYS := [
	[0.0, 0.0, 0.0, 0.0, 0.0],
	[0.12, 95.0, 120.0, 10.0, 0.0],
	[KICK_HIT, 105.0, 4.0, 22.0, 20.0],
	[0.34, 100.0, 18.0, 22.0, 20.0],
	[0.46, 90.0, 115.0, 12.0, 0.0],
	[KICK_LEN, 0.0, 0.0, 0.0, 0.0],
]
const LEG := ["RightUpperLeg", "RightLowerLeg", "RightFoot"]


## The kick, from the guard stance at the start of base (punch_jab). Bones not on the kicking
## leg, the hips or the standing thigh hold their stance.
static func kick(base: Animation) -> Animation:
	var a := Animation.new()
	a.length = KICK_LEN
	a.loop_mode = Animation.LOOP_NONE
	var stance := {}
	for i in range(base.get_track_count()):
		var path := str(base.track_get_path(i))
		var t := base.track_get_type(i)
		if t == Animation.TYPE_ROTATION_3D:
			stance[path] = base.rotation_track_interpolate(i, 0.0)
		elif t == Animation.TYPE_POSITION_3D:
			var k := a.add_track(Animation.TYPE_POSITION_3D)
			a.track_set_path(k, path)
			a.position_track_insert_key(k, 0.0, base.position_track_interpolate(i, 0.0))
	var moved := ["Hips", "LeftUpperLeg"] + LEG
	for path: String in stance:
		if path.trim_prefix(SKEL) in moved:
			continue
		var k := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(k, path)
		a.rotation_track_insert_key(k, 0.0, stance[path])
	var tracks := {}
	for b: String in moved:
		var k := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(k, SKEL + b)
		tracks[b] = k
	var frames := int(round(KICK_LEN * FPS))
	for f in range(frames + 1):
		var t := minf(float(f) / FPS, KICK_LEN)
		var pose := _kick_pose(stance, _kick_params(t))
		for b: String in moved:
			a.rotation_track_insert_key(tracks[b], t, pose[b])
	return a


## [thigh lift, knee bend, hip lean, foot point] (radians) at t, eased between the keys.
static func _kick_params(t: float) -> Array:
	for i in range(KICK_KEYS.size() - 1):
		var k0: Array = KICK_KEYS[i]
		var k1: Array = KICK_KEYS[i + 1]
		if t <= float(k1[0]):
			var u := smoothstep(float(k0[0]), float(k1[0]), t)
			var out := []
			for j in range(1, 5):
				out.append(deg_to_rad(lerpf(float(k0[j]), float(k1[j]), u)))
			return out
	return [0.0, 0.0, 0.0, 0.0]


## Local rotations of the hips, the standing thigh and the kicking leg for params p.
static func _kick_pose(stance: Dictionary, p: Array) -> Dictionary:
	var hips: Quaternion = stance.get(SKEL + "Hips", Quaternion.IDENTITY)
	var up: Quaternion = stance.get(SKEL + "RightUpperLeg", Quaternion.IDENTITY)
	var low: Quaternion = stance.get(SKEL + "RightLowerLeg", Quaternion.IDENTITY)
	var foot: Quaternion = stance.get(SKEL + "RightFoot", Quaternion.IDENTITY)
	var stand: Quaternion = stance.get(SKEL + "LeftUpperLeg", Quaternion.IDENTITY)
	# Skeleton-space rotations of the stance.
	var up_g := hips * up
	var low_g := up_g * low
	var foot_g := low_g * foot
	var stand_g := hips * stand
	# Rotating about -X swings a limb hanging down forward (+Z) and the upright hips back (-Z).
	var shin := float(p[0]) - float(p[1])
	var hips_n := _rx(-float(p[2])) * hips
	var up_n := _rx(-float(p[0])) * up_g
	var low_n := _rx(-shin) * low_g
	var foot_n := _rx(-shin + float(p[3])) * foot_g
	return {
		"Hips": hips_n.normalized(),
		"LeftUpperLeg": (hips_n.inverse() * stand_g).normalized(),
		"RightUpperLeg": (hips_n.inverse() * up_n).normalized(),
		"RightLowerLeg": (up_n.inverse() * low_n).normalized(),
		"RightFoot": (low_n.inverse() * foot_n).normalized(),
	}


static func _rx(angle: float) -> Quaternion:
	return Quaternion(Vector3.RIGHT, angle)


# ------------------------------------------------------------------ getting into a car

## The get-in (car_in), on a body standing beside a car's open driver's door facing along it, the
## seat on its right (-X): the right hand goes up to the roof and the left to the door's top, the
## right leg lifts high over the sill and in, the head and back duck under the roof and the body
## leans in toward the seat, then the left leg follows it in and the body settles into the
## driving pose (end, hands on the wheel). The Root slides CAR_SIDE toward the seat as the hips
## go over (the tree drops root motion: whoever plays it moves the body from beside the car onto
## the seat along that curve, HeroRig.travel). car_out is the same clip backwards.
const CAR_LEN := 2.0
const CAR_SIDE := 0.5
## The blend from start to end of each body part: [from, to] (s), eased.
const CAR_BLEND := {
	"hips": [0.5, 1.4],
	"spine": [0.3, 1.8],
	"arms": [1.3, 1.95],
	"right_leg": [0.35, 1.1],
	"left_leg": [0.9, 1.7],
}
## Moves over the blend, by channel: [[time (s), degrees], ...], eased between keys.
## r_lift / l_lift raise a thigh forward, r_out / l_out swing it out to the side (right toward the
## car, left away from it), r_knee / l_knee bend the knee further, duck bends the back forward,
## lean bends it toward the car, twist turns the chest toward it, head bends the neck and head,
## r_arm / l_arm raise an arm forward and up.
const CAR_KEYS := {
	"r_lift": [[0.0, 0.0], [0.3, 15.0], [0.6, 70.0], [0.9, 40.0], [1.2, 0.0]],
	"r_out": [[0.0, 0.0], [0.35, 10.0], [0.6, 25.0], [0.9, 15.0], [1.3, 0.0]],
	"r_knee": [[0.0, 0.0], [0.35, 30.0], [0.6, 85.0], [0.9, 40.0], [1.2, 0.0]],
	"l_lift": [[0.0, 0.0], [1.0, 0.0], [1.25, 45.0], [1.5, 25.0], [1.8, 0.0]],
	"l_out": [[0.0, 0.0], [0.6, 8.0], [1.0, 25.0], [1.3, 15.0], [1.7, 0.0]],
	"l_knee": [[0.0, 0.0], [0.9, 20.0], [1.25, 70.0], [1.5, 30.0], [1.8, 0.0]],
	"duck": [[0.0, 0.0], [0.35, 10.0], [0.75, 35.0], [1.15, 30.0], [1.6, 5.0], [2.0, 0.0]],
	"lean": [[0.0, 0.0], [0.5, 10.0], [0.9, 18.0], [1.3, 5.0], [2.0, 0.0]],
	"twist": [[0.0, 0.0], [0.4, 20.0], [0.9, 15.0], [1.4, 0.0]],
	"head": [[0.0, 0.0], [0.45, 10.0], [0.85, 25.0], [1.25, 10.0], [1.7, 0.0]],
	"r_arm": [[0.0, 0.0], [0.25, 50.0], [0.55, 110.0], [1.1, 100.0], [1.45, 30.0], [1.9, 0.0]],
	"l_arm": [[0.0, 0.0], [0.35, 40.0], [0.75, 55.0], [1.2, 35.0], [1.6, 0.0]],
}
const SPINE := ["Spine", "Chest", "UpperChest"]
const NECK := ["Neck", "Head"]


## The get-in from start's first frame (standing) to end's (seated at the wheel), posed through
## skeleton sk (this body's bone hierarchy and rests).
static func car_in(start: Animation, end: Animation, sk: Skeleton3D) -> Animation:
	var a := Animation.new()
	a.length = CAR_LEN
	a.loop_mode = Animation.LOOP_NONE
	var from := {}
	var to := {}
	var hips_at := [Vector3.ZERO, Vector3.ZERO]
	for i in range(start.get_track_count()):
		var path := str(start.track_get_path(i))
		var bone := path.trim_prefix(SKEL)
		if start.track_get_type(i) == Animation.TYPE_ROTATION_3D:
			from[bone] = start.rotation_track_interpolate(i, 0.0)
			var j := end.find_track(NodePath(path), Animation.TYPE_ROTATION_3D)
			to[bone] = end.rotation_track_interpolate(j, 0.0) if j >= 0 else from[bone]
		elif start.track_get_type(i) == Animation.TYPE_POSITION_3D:
			var p0 := start.position_track_interpolate(i, 0.0)
			var k := a.add_track(Animation.TYPE_POSITION_3D)
			a.track_set_path(k, path)
			if bone == "Hips":
				var j := end.find_track(NodePath(path), Animation.TYPE_POSITION_3D)
				hips_at = [p0, end.position_track_interpolate(j, 0.0) if j >= 0 else p0]
			a.position_track_insert_key(k, 0.0, p0)
	var hips_track := a.find_track(NodePath(SKEL + "Hips"), Animation.TYPE_POSITION_3D)
	var root_track := a.find_track(NodePath(SKEL + "Root"), Animation.TYPE_POSITION_3D)
	var root_at := Vector3.ZERO
	if root_track < 0:
		root_track = a.add_track(Animation.TYPE_POSITION_3D)
		a.track_set_path(root_track, SKEL + "Root")
	else:
		root_at = a.position_track_interpolate(root_track, 0.0)
	var tracks := {}
	for bone: String in from:
		var k := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(k, SKEL + bone)
		tracks[bone] = k
	var frames := int(round(CAR_LEN * FPS))
	for f in range(frames + 1):
		var t := minf(float(f) / FPS, CAR_LEN)
		var pose := _car_pose(sk, from, to, t)
		for bone: String in tracks:
			a.rotation_track_insert_key(tracks[bone], t, pose[bone])
		var w := _car_w("hips", t)
		if hips_track >= 0:
			a.position_track_insert_key(hips_track, t, (hips_at[0] as Vector3).lerp(hips_at[1], w))
		a.position_track_insert_key(root_track, t, root_at + Vector3(-CAR_SIDE * w, 0.0, 0.0))
	return a


## The get-out: car_in played backwards.
static func car_out(car_in_anim: Animation) -> Animation:
	var a := Animation.new()
	a.length = car_in_anim.length
	a.loop_mode = Animation.LOOP_NONE
	var n := car_in_anim.length
	for i in range(car_in_anim.get_track_count()):
		var ty := car_in_anim.track_get_type(i)
		var k := a.add_track(ty)
		a.track_set_path(k, car_in_anim.track_get_path(i))
		for key in range(car_in_anim.track_get_key_count(i) - 1, -1, -1):
			var t := n - car_in_anim.track_get_key_time(i, key)
			var v: Variant = car_in_anim.track_get_key_value(i, key)
			if ty == Animation.TYPE_ROTATION_3D:
				a.rotation_track_insert_key(k, t, v)
			else:
				a.position_track_insert_key(k, t, v)
	return a


## Local rotations of every bone at t: the blend of each part, then the moves on top of it in
## skeleton space, parents first.
static func _car_pose(sk: Skeleton3D, from: Dictionary, to: Dictionary, t: float) -> Dictionary:
	sk.reset_bone_poses()
	for bone: String in from:
		var q := (from[bone] as Quaternion).slerp(to[bone], _car_w(_car_part(bone), t))
		var i := sk.find_bone(bone)
		if i >= 0:
			sk.set_bone_pose_rotation(i, q)
	var duck := _car_key("duck", t) / SPINE.size()
	var lean := _car_key("lean", t) / SPINE.size()
	var twist := _car_key("twist", t) / SPINE.size()
	for b: String in SPINE:
		_turn(sk, b, _ry(-twist) * _rz(lean) * _rx(duck))
	for b: String in NECK:
		_turn(sk, b, _rx(_car_key("head", t) * 0.5))
	_turn(sk, "RightUpperArm", _rz(-deg_to_rad(20.0)) * _rx(-_car_key("r_arm", t)))
	_turn(sk, "LeftUpperArm", _rx(-_car_key("l_arm", t)))
	_turn(sk, "RightUpperLeg", _rz(-_car_key("r_out", t)) * _rx(-_car_key("r_lift", t)))
	_turn(sk, "RightLowerLeg", _rx(_car_key("r_knee", t)))
	_turn(sk, "LeftUpperLeg", _rz(_car_key("l_out", t)) * _rx(-_car_key("l_lift", t)))
	_turn(sk, "LeftLowerLeg", _rx(_car_key("l_knee", t)))
	var out := {}
	for bone: String in from:
		var i := sk.find_bone(bone)
		out[bone] = sk.get_bone_pose_rotation(i).normalized() if i >= 0 else from[bone]
	return out


## Turns bone b by q in skeleton space about its own head (its children go with it).
static func _turn(sk: Skeleton3D, b: String, q: Quaternion) -> void:
	var i := sk.find_bone(b)
	if i < 0:
		return
	var p := sk.get_bone_parent(i)
	var gp := sk.get_bone_global_pose(p).basis.get_rotation_quaternion() if p >= 0 else Quaternion()
	var g := gp * sk.get_bone_pose_rotation(i)
	sk.set_bone_pose_rotation(i, (gp.inverse() * q * g).normalized())


static func _car_part(bone: String) -> String:
	if bone == "Hips" or bone == "Root":
		return "hips"
	if bone.begins_with("RightUpperLeg") or bone.begins_with("RightLowerLeg"):
		return "right_leg"
	if bone.begins_with("RightFoot") or bone.begins_with("RightToes"):
		return "right_leg"
	if bone.begins_with("LeftUpperLeg") or bone.begins_with("LeftLowerLeg"):
		return "left_leg"
	if bone.begins_with("LeftFoot") or bone.begins_with("LeftToes"):
		return "left_leg"
	if bone in SPINE or bone in NECK or bone.ends_with("Eye") or bone == "Jaw":
		return "spine"
	return "arms"


## The blend of part at t (0 start .. 1 end).
static func _car_w(part: String, t: float) -> float:
	var r: Array = CAR_BLEND[part]
	return smoothstep(float(r[0]), float(r[1]), t)


## Channel c at t (radians), eased between its keys.
static func _car_key(c: String, t: float) -> float:
	var keys: Array = CAR_KEYS[c]
	for i in range(keys.size() - 1):
		var k0: Array = keys[i]
		var k1: Array = keys[i + 1]
		if t <= float(k1[0]):
			var u := smoothstep(float(k0[0]), float(k1[0]), t)
			return deg_to_rad(lerpf(float(k0[1]), float(k1[1]), u))
	return deg_to_rad(float((keys.back() as Array)[1]))


static func _ry(angle: float) -> Quaternion:
	return Quaternion(Vector3.UP, angle)


static func _rz(angle: float) -> Quaternion:
	return Quaternion(Vector3.BACK, angle)
