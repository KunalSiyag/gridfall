extends RefCounted
## Clips made from the mocap ones by hand-keyed bone rotations (build_anim_library.gd adds them to
## both libraries: the kick and the throw as UAL clips, the get-in and get-out of a car and the
## pedalling on a bicycle per gender, see car_in and ride).
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


# ------------------------------------------------------------------ the throw

## The throw, on the upper body over the guard stance at the start of base (punch_jab): holding
## someone in front, the hands drop and the back winds up to the right, then it unwinds and
## straightens as both arms swing up and out, the elbows opening, letting go at THROW_HIT, and the
## body comes back to the guard.
const THROW_LEN := 0.8
const THROW_HIT := 0.3
## Moves by channel as CAR_KEYS: duck bends the back forward (negative: back), twist turns the
## chest to the right, arms raise both arms forward, reach opens the elbows (0..1 of the way to
## straight).
const THROW_KEYS := {
	"duck": [[0.0, 0.0], [0.14, 18.0], [0.3, -12.0], [0.45, 6.0], [THROW_LEN, 0.0]],
	"twist": [[0.0, 0.0], [0.14, 25.0], [0.3, -15.0], [0.45, -10.0], [THROW_LEN, 0.0]],
	"arms": [[0.0, 0.0], [0.14, -25.0], [THROW_HIT, 70.0], [0.42, 95.0], [THROW_LEN, 0.0]],
	"reach": [[0.0, 0.0], [0.14, 0.0], [THROW_HIT, 0.8], [0.45, 0.9], [THROW_LEN, 0.0]],
}


## The throw from base's first frame, posed through skeleton sk.
static func throw(base: Animation, sk: Skeleton3D) -> Animation:
	var a := Animation.new()
	a.length = THROW_LEN
	a.loop_mode = Animation.LOOP_NONE
	var stance := {}
	for i in range(base.get_track_count()):
		var path := str(base.track_get_path(i))
		var t := base.track_get_type(i)
		if t == Animation.TYPE_ROTATION_3D:
			stance[path.trim_prefix(SKEL)] = base.rotation_track_interpolate(i, 0.0)
		elif t == Animation.TYPE_POSITION_3D:
			var k := a.add_track(Animation.TYPE_POSITION_3D)
			a.track_set_path(k, path)
			a.position_track_insert_key(k, 0.0, base.position_track_interpolate(i, 0.0))
	var tracks := {}
	for bone: String in stance:
		var k := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(k, SKEL + bone)
		tracks[bone] = k
	var frames := int(round(THROW_LEN * FPS))
	for f in range(frames + 1):
		var t := minf(float(f) / FPS, THROW_LEN)
		var pose := _throw_pose(sk, stance, t)
		for bone: String in tracks:
			a.rotation_track_insert_key(tracks[bone], t, pose[bone])
	return a


static func _throw_pose(sk: Skeleton3D, stance: Dictionary, t: float) -> Dictionary:
	sk.reset_bone_poses()
	for bone: String in stance:
		var i := sk.find_bone(bone)
		if i >= 0:
			sk.set_bone_pose_rotation(i, stance[bone])
	var reach := _keyed(THROW_KEYS, "reach", t)
	for b: String in ["LeftLowerArm", "RightLowerArm"]:
		var i := sk.find_bone(b)
		if i >= 0:
			var straight := sk.get_bone_rest(i).basis.get_rotation_quaternion()
			sk.set_bone_pose_rotation(i, sk.get_bone_pose_rotation(i).slerp(straight, reach))
	var duck := deg_to_rad(_keyed(THROW_KEYS, "duck", t)) / SPINE.size()
	var twist := deg_to_rad(_keyed(THROW_KEYS, "twist", t)) / SPINE.size()
	for b: String in SPINE:
		_turn(sk, b, _ry(-twist) * _rx(duck))
	# The head keeps its eyes on whoever is thrown.
	for b: String in NECK:
		_turn(sk, b, _rx(-duck * SPINE.size() * 0.5))
	var arms := deg_to_rad(_keyed(THROW_KEYS, "arms", t))
	for b: String in ["LeftUpperArm", "RightUpperArm"]:
		_turn(sk, b, _rx(-arms))
	var out := {}
	for bone: String in stance:
		var i := sk.find_bone(bone)
		out[bone] = sk.get_bone_pose_rotation(i).normalized() if i >= 0 else stance[bone]
	return out


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


## Channel c of CAR_KEYS at t (radians), eased between its keys.
static func _car_key(c: String, t: float) -> float:
	return deg_to_rad(_keyed(CAR_KEYS, c, t))


## Channel c of table at t (its own units), eased between its keys.
static func _keyed(table: Dictionary, c: String, t: float) -> float:
	var keys: Array = table[c]
	for i in range(keys.size() - 1):
		var k0: Array = keys[i]
		var k1: Array = keys[i + 1]
		if t <= float(k1[0]):
			var u := smoothstep(float(k0[0]), float(k1[0]), t)
			return lerpf(float(k0[1]), float(k1[1]), u)
	return float((keys.back() as Array)[1])


static func _ry(angle: float) -> Quaternion:
	return Quaternion(Vector3.UP, angle)


static func _rz(angle: float) -> Quaternion:
	return Quaternion(Vector3.BACK, angle)


# ------------------------------------------------------------------ riding a bicycle

## Pedalling (ride): one turn of the cranks over RIDE_LEN, looped, on a body whose Hips bone sits
## on a bicycle's saddle (the Seat_Driver point of bicycle.glb). The hips and back lean forward
## (RIDE_LEAN), the head comes up to look ahead, the hands hold the grips and each foot stays on
## its pedal as the cranks turn (two-bone IK in skeleton space; the right pedal half a turn ahead
## of the left), the toes dipping most just past the bottom of the stroke and the hips rocking
## with each push. The arms start from the drive pose (bent at the elbow, fingers closed). Points
## are metres from the Hips bone (+Y up, +Z forward), from tools/blender/realcity/vehicles2.py
## bicycle(): the bottom bracket, the crank, the pedals' offset and the grips.
const RIDE_LEN := 1.0
const RIDE_BB := Vector3(0.0, -0.7, 0.23)
const RIDE_CRANK := 0.17
const RIDE_PEDAL_X := 0.11
const RIDE_GRIP := Vector3(0.26, 0.04, 0.61)
## The wrist sits this far from the middle of the grip.
const RIDE_PALM := Vector3(0.0, 0.02, -0.07)
## Forward lean of the hips and of the back, head lift, hip rock (degrees).
const RIDE_LEAN := Vector2(15.0, 20.0)
const RIDE_HEAD := 25.0
const RIDE_ROCK := 3.0
## Toes down (degrees): the mean and the swing about it, deepest RIDE_DIP past the bottom.
const RIDE_ANKLE := Vector2(15.0, 10.0)
const RIDE_DIP := 200.0
## The ball of the foot from the ankle with the foot flat ([down, forward], m).
const RIDE_BALL := Vector2(-0.1, 0.17)


## The ride loop from stand's first frame (idle), the arms and fingers from grip's (drive), posed
## through skeleton sk.
static func ride(stand: Animation, grip: Animation, sk: Skeleton3D) -> Animation:
	var a := Animation.new()
	a.length = RIDE_LEN
	a.loop_mode = Animation.LOOP_LINEAR
	var pose := {}
	for i in range(stand.get_track_count()):
		var path := str(stand.track_get_path(i))
		var bone := path.trim_prefix(SKEL)
		if stand.track_get_type(i) == Animation.TYPE_ROTATION_3D:
			pose[bone] = stand.rotation_track_interpolate(i, 0.0)
			var j := grip.find_track(NodePath(path), Animation.TYPE_ROTATION_3D)
			if j >= 0 and _car_part(bone) == "arms":
				pose[bone] = grip.rotation_track_interpolate(j, 0.0)
		elif stand.track_get_type(i) == Animation.TYPE_POSITION_3D:
			var k := a.add_track(Animation.TYPE_POSITION_3D)
			a.track_set_path(k, path)
			a.position_track_insert_key(k, 0.0, stand.position_track_interpolate(i, 0.0))
	var tracks := {}
	for bone: String in pose:
		var k := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(k, SKEL + bone)
		tracks[bone] = k
	var frames := int(round(RIDE_LEN * FPS))
	for f in range(frames + 1):
		var t := float(f) / float(frames) * RIDE_LEN
		var out := _ride_pose(sk, pose, TAU * t / RIDE_LEN)
		for bone: String in tracks:
			a.rotation_track_insert_key(tracks[bone], t, out[bone])
	return a


## Local rotations of every bone with the cranks at th (radians; 0 the left pedal at the top).
static func _ride_pose(sk: Skeleton3D, pose: Dictionary, th: float) -> Dictionary:
	sk.reset_bone_poses()
	for bone: String in pose:
		var i := sk.find_bone(bone)
		if i >= 0:
			sk.set_bone_pose_rotation(i, pose[bone])
	var rock := deg_to_rad(RIDE_ROCK) * sin(th)
	_turn_now(sk, "Hips", _rz(rock) * _rx(deg_to_rad(RIDE_LEAN.x)))
	for b: String in SPINE:
		_turn_now(sk, b, _rz(-rock / SPINE.size()) * _rx(deg_to_rad(RIDE_LEAN.y) / SPINE.size()))
	for b: String in NECK:
		_turn_now(sk, b, _rx(-deg_to_rad(RIDE_HEAD) / NECK.size()))
	var hips := _at(sk, "Hips")
	for side: String in ["Left", "Right"]:
		var sx := 1.0 if side == "Left" else -1.0
		var ang := th + (0.0 if side == "Left" else PI)
		var crank := Vector3(sx * RIDE_PEDAL_X, RIDE_CRANK * cos(ang), RIDE_CRANK * sin(ang))
		var toe := deg_to_rad(RIDE_ANKLE.x - RIDE_ANKLE.y * cos(ang - deg_to_rad(RIDE_DIP)))
		var ball := Vector3(
			0.0,
			RIDE_BALL.x * cos(toe) - RIDE_BALL.y * sin(toe),
			RIDE_BALL.y * cos(toe) + RIDE_BALL.x * sin(toe)
		)
		var ankle := hips + RIDE_BB + crank - ball
		_reach(sk, [side + "UpperLeg", side + "LowerLeg", side + "Foot"], ankle, Vector3(0, 0.2, 1))
		_aim(sk, side + "Foot", side + "Toes", Vector3(0.0, -sin(toe), cos(toe)))
		var grip := Vector3(sx * RIDE_GRIP.x, RIDE_GRIP.y, RIDE_GRIP.z) + RIDE_PALM
		var elbow := Vector3(sx * 0.6, -1.0, -0.2)
		_reach(sk, [side + "UpperArm", side + "LowerArm", side + "Hand"], hips + grip, elbow)
	var out := {}
	for bone: String in pose:
		var i := sk.find_bone(bone)
		out[bone] = sk.get_bone_pose_rotation(i).normalized() if i >= 0 else pose[bone]
	return out


## Bends the limb chain [upper, lower, end] so end reaches target (as near as it can), the middle
## joint bending toward pole.
static func _reach(sk: Skeleton3D, chain: Array, target: Vector3, pole: Vector3) -> void:
	var a := _at(sk, chain[0])
	var b := _at(sk, chain[1])
	var c := _at(sk, chain[2])
	var l1 := a.distance_to(b)
	var l2 := b.distance_to(c)
	var to := target - a
	var d := clampf(to.length(), absf(l1 - l2) + 1e-4, l1 + l2 - 1e-4)
	var dir := to.normalized()
	var side := (pole - dir * dir.dot(pole)).normalized()
	var ang := acos(clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0))
	var mid := a + (dir * cos(ang) + side * sin(ang)) * l1
	_turn_now(sk, chain[0], Quaternion((b - a).normalized(), (mid - a).normalized()))
	b = _at(sk, chain[1])
	c = _at(sk, chain[2])
	_turn_now(sk, chain[1], Quaternion((c - b).normalized(), (a + dir * d - b).normalized()))


## Turns bone b so the direction from it to its child bone tip points along want.
static func _aim(sk: Skeleton3D, b: String, tip: String, want: Vector3) -> void:
	if sk.find_bone(tip) < 0:
		return
	_turn_now(sk, b, Quaternion((_at(sk, tip) - _at(sk, b)).normalized(), want.normalized()))


## Turns bone b by q in skeleton space about its own head, its parent's pose composed from the
## local poses (a skeleton outside the tree, as the library builder's, never refreshes its global
## poses, so the IK cannot read them).
static func _turn_now(sk: Skeleton3D, b: String, q: Quaternion) -> void:
	var i := sk.find_bone(b)
	if i < 0:
		return
	var p := sk.get_bone_parent(i)
	var gp := _global(sk, p).basis.get_rotation_quaternion() if p >= 0 else Quaternion()
	var g := gp * sk.get_bone_pose_rotation(i)
	sk.set_bone_pose_rotation(i, (gp.inverse() * q * g).normalized())


## Bone i's pose in skeleton space, composed from the local poses up the chain.
static func _global(sk: Skeleton3D, i: int) -> Transform3D:
	var xf := Transform3D.IDENTITY
	while i >= 0:
		xf = sk.get_bone_pose(i) * xf
		i = sk.get_bone_parent(i)
	return xf


## Bone b's head in skeleton space.
static func _at(sk: Skeleton3D, b: String) -> Vector3:
	var i := sk.find_bone(b)
	return _global(sk, i).origin if i >= 0 else Vector3.ZERO
