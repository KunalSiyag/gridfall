extends RefCounted
## The building crews' bodies: HC's trades avatars (roster group "trades"), each under a
## CharacterRoot scaled to a jittered stature and animated by its gender's clip library with the
## root motion pulled out, so a clip plays in place and the crew rig moves the worker. start()
## loads the body scenes on background threads; make() returns null until a scene is in, unless
## `blocking` (tests, photo shots) makes it wait. Without the roster a worker is a hi-vis capsule.

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const LOADS := preload("res://scripts/fp/scene_loads.gd")
const GROUP := "trades"
const STAND_IN_COLOR := Color(1.0, 0.52, 0.1)
const CRATE_COLOR := Color(0.62, 0.47, 0.3)
## The crate's depth and height (metres on the skeleton); its width follows the hands.
const CRATE_DEPTH := 0.32
const CRATE_HEIGHT := 0.28


## One worker's body.
class Body:
	extends RefCounted
	var root: Node3D = null
	var skel: Skeleton3D = null
	var ap: AnimationPlayer = null
	## BoneAttachment3D with the carried crate (add_crate), hidden until the rig shows it.
	var crate: Node3D = null
	var gender: String = "m"
	## Index into kinds, -1 for the stand-in.
	var kind: int = -1
	## World units this body covers per unit of a clip's hip-relative speed (hip height times the
	## CharacterRoot scale).
	var stride: float = WS.M
	var clip: StringName = &""


var ok: bool = false
var why: String = "not loaded"
var blocking: bool = false
## Trades bodies that exist: {"name", "gender", "rest" (stature, m), "hip" (m), "path"}.
var kinds: Array[Dictionary] = []
var made: int = 0
var _libs: Dictionary = {}
## gender -> {clip: speed_mps / speed_ref_hip_m}
var _clip_speed: Dictionary = {}
## gender -> [crate transform in the UpperChest bone's frame, crate BoxMesh]
var _crate_fit: Dictionary = {}
var _height: Dictionary = {"target_m": 1.75, "female_factor": 0.95, "jitter": [0.97, 1.03]}
var _loads := LOADS.new()
var _pool: Dictionary = {}
var _crate_mat: StandardMaterial3D = null


## Reads the roster's trades bodies and both clip libraries. False (and why) when they are missing;
## make() then hands out stand-ins.
func load_roster() -> bool:
	kinds.clear()
	ok = false
	var raw := FileAccess.get_file_as_string(AP.CHAR_ROSTER)
	var parsed: Variant = JSON.parse_string(raw) if not raw.is_empty() else null
	if typeof(parsed) != TYPE_DICTIONARY:
		why = "no character roster"
		return false
	var roster: Dictionary = parsed
	var all: Dictionary = roster.get("bodies", {})
	var groups: Dictionary = roster.get("groups", {})
	for n: Variant in groups.get(GROUP, []):
		var b: Dictionary = all.get(str(n), {})
		var path := str(b.get("path", AP.CHAR_BODIES_DIR + str(n) + ".glb"))
		if b.is_empty() or not ResourceLoader.exists(path):
			continue
		var kd := {"name": str(n), "gender": str(b.get("gender", "m")), "path": path}
		kd["rest"] = float(b.get("rest_height_m", 1.75))
		kd["hip"] = float(b.get("hip_m", 0.9))
		kinds.append(kd)
	if typeof(roster.get("height")) == TYPE_DICTIONARY:
		_height = roster["height"]
	for g: String in ["m", "f"]:
		var lp := AP.CHAR_LIB_M if g == "m" else AP.CHAR_LIB_F
		var lib: AnimationLibrary = (
			load(lp) as AnimationLibrary if ResourceLoader.exists(lp) else null
		)
		if lib == null:
			why = "clip library %s missing" % g
			return false
		_libs[g] = lib
		var per: Dictionary = {}
		for clip: StringName in lib.get_animation_list():
			var a := lib.get_animation(clip)
			var ref_hip := maxf(float(a.get_meta("speed_ref_hip_m", 1.0)), 0.01)
			per[clip] = float(a.get_meta("speed_mps", 0.0)) / ref_hip
		_clip_speed[g] = per
	ok = not kinds.is_empty()
	why = "" if ok else "no trades body in the roster"
	return ok


## Starts loading every trades body on a background thread.
func start() -> void:
	for kd: Dictionary in kinds:
		_loads.request(str(kd["path"]))


## Waits for the loads still in flight (quitting with one running aborts it noisily).
func finish_loads() -> void:
	_loads.finish()


## A body of kinds[k] (any k, wrapped) under parent, its stature picked by jitter (0..1), or null
## while its scene still loads. Reuses a released body of the same kind first.
func make(k: int, jitter: float, parent: Node3D) -> Body:
	var kk := posmod(k, kinds.size()) if ok else -1
	var spare: Array = _pool.get(kk, [])
	if not spare.is_empty():
		var again: Body = spare.pop_back()
		parent.add_child(again.root)
		again.root.visible = true
		again.clip = &""
		return again
	if kk < 0:
		return _stand_in(parent)
	var kd: Dictionary = kinds[kk]
	var path := str(kd["path"])
	var ps := _loads.scene(path, blocking)
	if ps == null:
		return null if _loads.pending(path) else _stand_in(parent)
	var b := Body.new()
	b.kind = kk
	b.gender = str(kd["gender"])
	var sc := WS.M * stature(b.gender, jitter) / maxf(float(kd["rest"]), 0.5)
	b.stride = float(kd["hip"]) * sc
	b.root = Node3D.new()
	b.root.name = "Worker_%s_%d" % [kd["name"], made]
	b.root.scale = Vector3.ONE * sc
	var scene := ps.instantiate() as Node3D
	b.root.add_child(scene)
	parent.add_child(b.root)
	made += 1
	b.skel = scene.get_node_or_null("%GeneralSkeleton") as Skeleton3D
	for g: Node in scene.find_children("*", "GeometryInstance3D", true, false):
		(g as GeometryInstance3D).visibility_range_end = WS.VIS_PERSON
	if b.skel == null:
		return b
	var anim := AnimationPlayer.new()
	anim.name = "Anim"
	scene.add_child(anim)
	anim.add_animation_library("", _libs[b.gender])
	anim.root_motion_track = NodePath(AP.CHAR_ROOT_MOTION_TRACK)
	b.ap = anim
	return b


## Takes b off the street for a later make() of the same kind.
func release(b: Body) -> void:
	if b == null or b.root == null or not is_instance_valid(b.root):
		return
	var p := b.root.get_parent()
	if p != null:
		p.remove_child(b.root)
	if b.crate != null:
		b.crate.visible = false
	if b.ap != null:
		b.ap.stop()
		b.ap.active = true
	if not _pool.has(b.kind):
		_pool[b.kind] = []
	(_pool[b.kind] as Array).append(b)


## Frees the released bodies (teardown).
func clear() -> void:
	for spare: Array in _pool.values():
		for b: Body in spare:
			if is_instance_valid(b.root):
				b.root.free()
	_pool.clear()


## Stature (m) for a gender and a 0..1 jitter value, from the roster's height targets.
func stature(g: String, jitter: float) -> float:
	var span: Array = _height.get("jitter", [0.97, 1.03])
	var base := float(_height.get("target_m", 1.75))
	if g == "f":
		base *= float(_height.get("female_factor", 0.95))
	return base * lerpf(float(span[0]), float(span[1]), clampf(jitter, 0.0, 1.0))


## World units per second that b covers playing clip (0 for clips that stand still).
func speed(b: Body, clip: StringName) -> float:
	if b == null or b.ap == null:
		return 0.6 * WS.M if clip == &"carry" or clip == &"walk" else 0.0
	var per: Dictionary = _clip_speed.get(b.gender, {})
	return float(per.get(clip, 0.0)) * b.stride


## Plays clip on b. Asking for the clip it already plays restarts it (a one-shot that ended).
static func play(b: Body, clip: StringName, blend: float = 0.25) -> void:
	if b == null or b.ap == null or not b.ap.has_animation(clip):
		return
	var again := b.clip == clip
	b.clip = clip
	b.ap.play(clip, 0.0 if again else blend)
	if again:
		b.ap.seek(0.0, true)


## True while b's current clip still runs (loops always do).
static func playing(b: Body) -> bool:
	return b == null or b.ap == null or b.ap.is_playing()


## Gives b a crate held in both hands of its carry pose (hidden: the rig shows it while carrying).
func add_crate(b: Body) -> void:
	if b == null or b.skel == null or b.crate != null:
		return
	if not _crate_fit.has(b.gender):
		_crate_fit[b.gender] = _fit_crate(b)
	var fit: Array = _crate_fit[b.gender]
	var att := BoneAttachment3D.new()
	att.name = "Crate"
	att.bone_name = "UpperChest"
	b.skel.add_child(att)
	var box := MeshInstance3D.new()
	box.mesh = fit[1]
	box.transform = fit[0]
	att.add_child(box)
	att.visible = false
	b.crate = att


## The crate between the hands at the start of b's carry clip, in the UpperChest bone's frame, and
## a box mesh as wide as the hands are apart.
func _fit_crate(b: Body) -> Array:
	if _crate_mat == null:
		_crate_mat = StandardMaterial3D.new()
		_crate_mat.albedo_color = CRATE_COLOR
		_crate_mat.roughness = 0.9
	var mesh := BoxMesh.new()
	mesh.material = _crate_mat
	mesh.size = Vector3(0.4, CRATE_HEIGHT, CRATE_DEPTH)
	var sk := b.skel
	var chest := sk.find_bone("UpperChest")
	var left := sk.find_bone("LeftHand")
	var right := sk.find_bone("RightHand")
	if chest < 0 or left < 0 or right < 0 or b.ap == null or not b.ap.has_animation(&"carry"):
		return [Transform3D(Basis(), Vector3(0.0, -0.12, 0.3)), mesh]
	b.ap.play(&"carry")
	b.ap.seek(0.0, true)
	var hand_l := _bone_in_skeleton(sk, left).origin
	var hand_r := _bone_in_skeleton(sk, right).origin
	var side := hand_l - hand_r
	mesh.size.x = clampf(side.length() - 0.05, 0.28, 0.5)
	var x_axis := side.normalized()
	var z_axis := x_axis.cross(Vector3.UP).normalized()
	z_axis = -z_axis if z_axis.z < 0.0 else z_axis
	var held := Transform3D(Basis(x_axis, z_axis.cross(x_axis), z_axis), (hand_l + hand_r) * 0.5)
	b.ap.stop()
	return [_bone_in_skeleton(sk, chest).affine_inverse() * held, mesh]


## Bone pose in skeleton space, composed from the local poses (the global cache can lag a seek).
static func _bone_in_skeleton(sk: Skeleton3D, bone: int) -> Transform3D:
	var out := Transform3D.IDENTITY
	var at := bone
	while at >= 0:
		out = sk.get_bone_pose(at) * out
		at = sk.get_bone_parent(at)
	return out


func _stand_in(parent: Node3D) -> Body:
	var b := Body.new()
	b.root = Node3D.new()
	b.root.name = "WorkerStandIn_%d" % made
	made += 1
	var cap := CapsuleMesh.new()
	cap.radius = 0.25 * WS.M
	cap.height = 1.75 * WS.M
	var m := StandardMaterial3D.new()
	m.albedo_color = STAND_IN_COLOR
	cap.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = cap
	mi.position.y = cap.height * 0.5
	mi.visibility_range_end = WS.VIS_PERSON
	b.root.add_child(mi)
	parent.add_child(b.root)
	return b
