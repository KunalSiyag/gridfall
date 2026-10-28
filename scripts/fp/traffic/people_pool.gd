## The body pool and scene cache behind people.gd (split out so people.gd stays under the
## 1000-line cap; the public API stays on people, which delegates here). Owns the PackedScene
## cache (_scenes / _pending / scene_loads; the load mechanics are people_kit.gd's statics with
## this pool as their `pe`), the free Body instances per avatar, the bodies lent by seat(), and
## the take / attach / detach / release lifecycle. people.gd keeps the roster, the avatar pick
## (dress), and the per-frame tier pipeline; it reaches this pool through `_pool`, and this pool
## reaches back (avatars, _active, root, the roster-built libraries and box transforms, the
## _set_mode animation helper) through a WEAKREF so the pair does not leak at exit_fp.
extends RefCounted

const KIT := preload("res://scripts/fp/traffic/people_kit.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")

## Bodies are instanced at most this many per frame (the rest wait for a pooled one).
const NEW_PER_FRAME := 4


## One instanced body: CharacterRoot > the body scene (Armature/GeneralSkeleton/Body, Anim, Tree).
class Body:
	extends RefCounted
	var av: int = -1
	var root: Node3D = null
	var scene: Node3D = null
	var skel: Skeleton3D = null
	var meshes: Array[GeometryInstance3D] = []
	var ap: AnimationPlayer = null
	var tree: AnimationTree = null
	var playback: AnimationNodeStateMachinePlayback = null
	var head: int = -1
	var walker: Object = null
	var mode: int = -1  # 0 tree, 1 player, -1 inactive (off screen or pooled)
	var clip: StringName = &""
	var acc: float = 0.0  # game seconds not yet advanced
	var since: float = 0.0  # real seconds since the last advance
	var shadow: int = -1
	var box: Node3D = null
	var look: LookAtModifier3D = null
	var off_t: float = 0.0
	var seen: int = -1


## Load body and lod1 scenes on the calling thread (deterministic tests), not in the background.
var blocking: bool = false
## Body-scene load initiations; tests assert a dressed walker's seat/take adds none.
var scene_loads: int = 0
var bodies_made: int = 0
var _scenes: Dictionary = {}  # path -> PackedScene (null: missing or failed)
var _pending: Dictionary = {}  # paths with a background load running
var _seated: Array = []  # bodies lent by seat()
var _made_frame: int = 0
## people.gd, weakly: the pool dies with it, never the other way round.
var _ppl_ref: WeakRef = null


func _init(p_people: RefCounted) -> void:
	_ppl_ref = weakref(p_people)


func _ppl() -> RefCounted:
	return _ppl_ref.get_ref()


## New frame: the per-frame instancing budget resets (people.begin).
func begin_frame() -> void:
	_made_frame = 0


## The PackedScene at path: loaded at once when blocking, else from a background load (null
## while that runs, and for good when it fails or the file is missing). A dumb loader: the
## callers own the policy (dress warms at pick time on threaded builds, reset pre-warms on
## no-threads ones). Mechanics in people_kit.
func scene(path: String) -> PackedScene:
	return KIT.scene(self, path)


## True while a background load of path is still running (a finished or failed one reads false).
func is_pending(path: String) -> bool:
	return _pending.has(path)


## Waits for every background scene load still running and keeps the results.
func finish_loads() -> void:
	KIT.finish_loads(self)


## Loads every ambient avatar's body scene up front: on no-threads builds (the web export)
## this blocks at world build so play never hitches on a first seat or take; on threaded
## builds tests call it directly (in-game, dress-time requests warm the same paths lazily).
## One scene at a time: the headless dummy renderer's RID/material storage races when many
## threaded loads finalize together, and a loading screen does not need the parallelism.
func prewarm_ambient(groups: Array, avatars: Array) -> void:
	for gw: Array in groups:
		for ai: int in gw[1]:
			scene(str((avatars[ai] as RefCounted).get("path")))
			finish_loads()
	finish_loads()


## A pooled body of avatar ai, or a new one within this frame's budget once its scene has loaded.
func take(ai: int) -> Body:
	var a: Variant = _ppl().avatars[ai]
	if not a.pool.is_empty():
		return a.pool.pop_back()
	if _made_frame < NEW_PER_FRAME and scene(a.path) != null:
		_made_frame += 1
		return make(ai)
	return null


## Seats walker w on a body lent out of the pool (drivers, riders): the body stays out of the
## per-frame pipeline until release. False when none is available yet.
func seat(w: WK.Walker) -> bool:
	var b := take(w.av)
	if b == null:
		return false
	b.walker = w
	w.body = b
	b.root.visible = true
	_seated.append(b)
	return true


## Gives w a body (pooled, or new within this frame's budget), stamped with the people's frame.
## False when none is available.
func attach(w: WK.Walker, tier: int, frame: int) -> bool:
	var a: Variant = _ppl().avatars[w.av]
	var b := take(w.av)
	if b == null:
		return false
	b.walker = w
	w.body = b
	b.off_t = 0.0
	b.seen = frame
	b.shadow = -1
	b.mode = -1
	b.root.visible = true
	if w.extra == 1:
		ensure_box(b, a.gender)
	if b.box != null:
		b.box.visible = false
	_ppl()._active.append(b)
	_ppl()._set_mode(b, w, 0 if tier == 0 else 1)
	return true


## Returns w's body (if any) to its pool.
func detach(w: WK.Walker) -> void:
	var b: Body = w.body
	if b == null:
		return
	if b.mode == 0 and b.playback != null and b.playback.get_current_node() == w.anim_clip:
		w.anim_t = b.playback.get_current_play_position()
	elif b.mode == 1 and b.ap.current_animation == String(w.anim_clip):
		w.anim_t = b.ap.current_animation_position
	w.body = null
	_ppl()._active.erase(b)
	_seated.erase(b)
	release_body(b)


func release_body(b: Body) -> void:
	b.walker = null
	b.mode = -1
	if is_instance_valid(b.tree):
		b.tree.active = false
	if is_instance_valid(b.ap):
		b.ap.active = false
	if b.look != null:
		b.look.active = false
	if is_instance_valid(b.root):
		b.root.visible = false
	_ppl().avatars[b.av].pool.append(b)


## A walker leaves for good (removed): its body goes back to the pool.
func release(w: WK.Walker) -> void:
	detach(w)
	w.tier = -1


## Frees the pooled and the lent bodies (people.clear frees the active ones and the rest).
func clear() -> void:
	for a: Variant in _ppl().avatars:
		for b: Body in a.pool:
			if is_instance_valid(b.root):
				b.root.queue_free()
		a.pool.clear()
		a.made = 0
	for b: Body in _seated:
		b.walker.set("body", null)
		b.root.queue_free()
	_seated.clear()
	bodies_made = 0


func make(ai: int) -> Body:
	var ppl := _ppl()
	var a: Variant = ppl.avatars[ai]
	var ps := scene(a.path)
	if ps == null:
		return null
	var b := Body.new()
	b.av = ai
	b.root = Node3D.new()
	b.root.name = "CharacterRoot_%s_%d" % [a.name, a.made]
	b.scene = ps.instantiate() as Node3D
	b.root.add_child(b.scene)
	ppl.root.add_child(b.root)
	b.skel = b.scene.get_node_or_null("%GeneralSkeleton") as Skeleton3D
	if b.skel == null:
		b.root.queue_free()
		return null
	b.head = b.skel.find_bone("Head")
	for n: Node in b.scene.find_children("*", "GeometryInstance3D", true, false):
		b.meshes.append(n as GeometryInstance3D)
	var lib: AnimationLibrary = ppl._libs[a.gender]
	b.ap = AnimationPlayer.new()
	b.ap.name = "Anim"
	b.scene.add_child(b.ap)
	b.ap.add_animation_library("", lib)
	b.ap.root_motion_track = NodePath(AP.CHAR_ROOT_MOTION_TRACK)
	b.ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	b.ap.active = false
	b.tree = AnimationTree.new()
	b.tree.name = "Tree"
	b.scene.add_child(b.tree)
	b.tree.add_animation_library("", lib)
	b.tree.root_motion_track = NodePath(AP.CHAR_ROOT_MOTION_TRACK)
	b.tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	b.tree.tree_root = ppl._tree_root
	b.tree.active = false
	b.playback = b.tree.get(&"parameters/sm/playback")
	a.made += 1
	bodies_made += 1
	return b


## A cardboard box held in front of the chest (carry poses), parented to UpperChest.
func ensure_box(b: Body, g: String) -> void:
	var ppl := _ppl()
	if b.box != null or not ppl._box_xf.has(g):
		return
	if not ppl._box_mesh.has(g):
		var bm := BoxMesh.new()
		bm.size = ppl._box_size[g]
		bm.material = ppl._box_mat
		ppl._box_mesh[g] = bm
	var att := BoneAttachment3D.new()
	att.name = "Box"
	att.bone_name = "UpperChest"
	b.skel.add_child(att)
	var mi := MeshInstance3D.new()
	mi.mesh = ppl._box_mesh[g]
	mi.transform = ppl._box_xf[g]
	att.add_child(mi)
	b.box = att
