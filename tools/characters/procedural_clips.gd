extends RefCounted
## Clips made from the mocap ones by hand-keyed bone rotations (build_anim_library.gd adds them to
## both libraries as UAL clips). The kick: a front kick with the right (rear) leg out of the guard
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
