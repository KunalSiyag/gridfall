extends RefCounted
## The dogs' bodies: Quaternius' Shiba Inu and Husky (AP.DOG_SHIBA, AP.DOG_HUSKY), each scene under
## a root scaled from model units to its breed's height at the shoulder, with the scene's own
## AnimationPlayer playing the clips in place (the dog pack moves the root) and a DogRig on the
## skeleton for the tail, the head and the barks. start() loads the scenes on background threads;
## make() returns null until a scene is in, unless `blocking` (tests, photo shots) makes it wait.
## Without a scene a dog is a brown box stand-in.

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const LOADS := preload("res://scripts/fp/scene_loads.gd")
const RIG := preload("res://scripts/fp/animals/dog_rig.gd")

## Each breed's scene and height at the shoulder (m). Both models share one skeleton, whose
## shoulder stands SHOULDER_UNITS model units high.
const BREEDS := {
	"shiba": {"path": AP.DOG_SHIBA, "shoulder_m": 0.38},
	"husky": {"path": AP.DOG_HUSKY, "shoulder_m": 0.55},
}
const SHOULDER_UNITS := 2.35
## Model units per second the planted paws cover at rate 1, walking and galloping.
const WALK_UNITS := 2.35
const GALLOP_UNITS := 7.0
## Blend (s) from one clip into the next.
const BLEND := 0.2
## Draw distance (60 m).
const VIS := 3.0
const STAND_IN_COLOR := Color(0.55, 0.36, 0.2)


## One dog's body.
class Body:
	extends RefCounted
	var root: Node3D = null
	var skel: Skeleton3D = null
	var ap: AnimationPlayer = null
	var rig: RIG = null
	var breed: String = "shiba"
	## World units per model unit.
	var unit: float = 0.0
	var clip: StringName = &""
	var collar: int = -1
	var head: int = -1


## The kinds this loader makes (BREEDS for the dogs), the shoulder's height in model units and the
## name its bodies' nodes start with.
var breeds: Dictionary = BREEDS
var shoulder_units: float = SHOULDER_UNITS
var label: String = "Dog"
var ok: bool = false
var why: String = "not loaded"
var blocking: bool = false
var made: int = 0
var _loads := LOADS.new()
var _pool: Dictionary = {}


## Checks the breeds' scenes exist. False (and why) when one is missing: make() then hands out
## stand-ins for it.
func check() -> bool:
	ok = true
	why = ""
	for breed: String in breeds:
		if not ResourceLoader.exists(str(breeds[breed]["path"])):
			ok = false
			why = "%s model missing" % breed
	return ok


## Starts loading every breed's scene on a background thread.
func start() -> void:
	for breed: String in breeds:
		_loads.request(str(breeds[breed]["path"]))


## Waits for the loads still in flight (quitting with one running aborts it noisily).
func finish_loads() -> void:
	_loads.finish()


## A body of breed under parent, size times the breed's height, or null while its scene still
## loads. Reuses a released body of the same breed first.
func make(breed: String, size: float, parent: Node3D) -> Body:
	var key: String = breed if breeds.has(breed) else breeds.keys()[0]
	var spare: Array = _pool.get(key, [])
	if not spare.is_empty():
		var again: Body = spare.pop_back()
		parent.add_child(again.root)
		again.root.visible = true
		again.clip = &""
		_fit(again, size)
		return again
	var path := str(breeds[key]["path"])
	var ps := _loads.scene(path, blocking)
	if ps == null:
		return null if _loads.pending(path) else _stand_in(key, size, parent)
	var b := Body.new()
	b.breed = key
	b.root = Node3D.new()
	b.root.name = "%s_%s_%d" % [label, key, made]
	var scene := ps.instantiate() as Node3D
	b.root.add_child(scene)
	parent.add_child(b.root)
	made += 1
	for g: Node in scene.find_children("*", "GeometryInstance3D", true, false):
		(g as GeometryInstance3D).visibility_range_end = VIS
	b.ap = scene.get_node_or_null("AnimationPlayer") as AnimationPlayer
	var found := scene.find_children("*", "Skeleton3D", true, false)
	if not found.is_empty():
		b.skel = found[0] as Skeleton3D
		_bind(b, scene)
	_fit(b, size)
	return b


## Takes b off the street for a later make() of the same breed.
func release(b: Body) -> void:
	if b == null or b.root == null or not is_instance_valid(b.root):
		return
	var p := b.root.get_parent()
	if p != null:
		p.remove_child(b.root)
	if b.ap != null:
		b.ap.stop()
	if b.rig != null:
		b.rig.calm()
	if not _pool.has(b.breed):
		_pool[b.breed] = []
	(_pool[b.breed] as Array).append(b)


## Frees the released bodies (teardown).
func clear() -> void:
	for spare: Array in _pool.values():
		for b: Body in spare:
			if is_instance_valid(b.root):
				b.root.free()
	_pool.clear()


## Ground speed (u/s) b covers walking (or galloping) at clip rate 1.
static func gait_speed(b: Body, gallop: bool) -> float:
	return (GALLOP_UNITS if gallop else WALK_UNITS) * b.unit


## Plays clip on b at rate, blending from the clip before; again restarts a clip it already plays
## (a one-shot asked for once more).
static func play(b: Body, clip: StringName, rate: float, again: bool = false) -> void:
	if b == null or b.ap == null:
		return
	b.ap.speed_scale = rate
	if b.clip == clip and not again:
		return
	if not b.ap.has_animation(clip):
		return
	var same := b.clip == clip
	b.clip = clip
	b.ap.play(clip, 0.0 if same else BLEND)
	if same:
		b.ap.seek(0.0, true)


## World position of bone k of b (the collar or the head), else a point up and ahead of the feet
## by the model's proportions (forward, up in model units).
static func bone_point(b: Body, k: int, fallback: Vector2) -> Vector3:
	if b.skel != null and k >= 0 and b.skel.is_inside_tree():
		return b.skel.global_transform * b.skel.get_bone_global_pose(k).origin
	var xf := b.root.global_transform
	return xf * Vector3(0.0, fallback.y, fallback.x)


## The collar and head bones of b's skeleton and its rig (the tail and the head).
func _bind(b: Body, scene: Node3D) -> void:
	b.collar = b.skel.find_bone("Neck2")
	b.head = b.skel.find_bone("Head")
	b.rig = RIG.new()
	b.rig.name = "DogRig"
	# The rig runs on the idle frame, not once per physics frame (people_pool.gd says why).
	b.skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
	b.skel.add_child(b.rig)
	b.rig.bind(b.skel, scene)


func _fit(b: Body, size: float) -> void:
	var shoulder := float(breeds[b.breed]["shoulder_m"])
	b.unit = WS.M * shoulder * size / shoulder_units
	b.root.scale = Vector3.ONE * b.unit


## A box body in model units (the root's scale makes it the breed's size).
func _stand_in(breed: String, size: float, parent: Node3D) -> Body:
	var b := Body.new()
	b.breed = breed
	b.root = Node3D.new()
	b.root.name = "%sStandIn_%d" % [label, made]
	made += 1
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 1.4, 3.2)
	var m := StandardMaterial3D.new()
	m.albedo_color = STAND_IN_COLOR
	box.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.position.y = 1.6
	mi.visibility_range_end = VIS
	b.root.add_child(mi)
	parent.add_child(b.root)
	_fit(b, size)
	return b
