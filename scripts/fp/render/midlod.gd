extends RefCounted
## Mid-range building LOD (slice G2): a building mesh's surfaces merged into one, each carrying its
## material's average colour (proxies.json, else albedo_color) as vertex colour, with generated
## LODs. A building is one draw call instead of 17 to 30 between VIS_BUILDING_NEAR and
## VIS_BUILDING, where its textures are down to their smallest mips anyway. Merges run on the
## WorkerThreadPool (the main thread only copies the arrays and uploads the result); cached per
## source mesh, which every instance of a model shares. proxy_bake.gd bakes the merges offline into
## BAKED_DIR: copying a mesh's arrays reads them back from the GPU and waits for the frames in
## flight (10 to 140 ms), so the runtime merge is only the fallback for a model without a fresh
## bake.

const PROXIES := preload("res://scripts/fp/render/proxies.gd")
const SHADER := preload("res://scripts/fp/render/midlod.gdshader")
const WebSupport := preload("res://scripts/ops/web_support.gd")
const GLASS_PREFIXES := ["Glass", "Window"]
const LIT_PREFIXES := ["WindowLit"]
## A mesh with fewer surfaces gains too little to replace.
const MIN_SURFACES := 3
const BAKED_DIR := "res://models/real/midlod/"
const MODELS_DIR := "res://models/real/"

var material: ShaderMaterial
## false builds on the calling thread (tests).
var threaded: bool = true
## false ignores BAKED_DIR and always merges at runtime (tests).
var use_baked: bool = true
var baked_loads: int = 0
var _meshes: Dictionary = {}
var _jobs: Dictionary = {}


func _init() -> void:
	material = ShaderMaterial.new()
	material.shader = SHADER


## True when src is worth merging.
static func mergeable(src: Mesh) -> bool:
	return src != null and src.get_surface_count() >= MIN_SURFACES


## The merged mesh for src, or null while it is being built (the build starts on the first call).
## path is the model's scene path (building or road piece, for the baked colours).
func mesh_for(src: Mesh, path: String) -> ArrayMesh:
	var id := src.get_instance_id()
	if _meshes.has(id):
		return _meshes[id]
	if _jobs.has(id):
		return null
	var baked := load_baked(src, path) if use_baked else null
	if baked != null:
		_meshes[id] = baked
		baked_loads += 1
		return baked
	var job := _gather(src, path)
	if threaded and WebSupport.threads_supported():
		job["task"] = WorkerThreadPool.add_task(_merge.bind(job), false, "G2 mid LOD")
		_jobs[id] = job
		return null
	_merge(job)
	_meshes[id] = _finish(job)
	return _meshes[id]


## True once src's merge is built or under way (mesh_for() then does no gather).
func started(src: Mesh) -> bool:
	var id := src.get_instance_id()
	return _meshes.has(id) or _jobs.has(id)


## Uploads finished builds; returns how many. With a deadline (clock() µs) it uploads at least one
## and starts no further upload once the deadline has passed.
func poll(deadline: int = -1, clock: Callable = Time.get_ticks_usec) -> int:
	var n := 0
	for id: int in _jobs.keys():
		if n > 0 and deadline >= 0 and int(clock.call()) >= deadline:
			break
		var job: Dictionary = _jobs[id]
		if not WorkerThreadPool.is_task_completed(int(job["task"])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(job["task"]))
		_meshes[id] = _finish(job)
		_jobs.erase(id)
		n += 1
	return n


## Builds still running.
func pending() -> int:
	return _jobs.size()


## Waits for every running build and uploads it (tests, teardown).
func wait_all() -> void:
	for id: int in _jobs.keys():
		WorkerThreadPool.wait_for_task_completion(int((_jobs[id] as Dictionary)["task"]))
	poll()


## Where proxy_bake.gd stores the merge of src, a mesh of the model at path.
static func baked_path(src: Mesh, path: String) -> String:
	var key := path.trim_prefix(MODELS_DIR).get_basename().replace("/", "__")
	return BAKED_DIR + key + "__" + src.resource_name.validate_filename() + ".res"


## The baked merge of src, or null when there is none or it was baked from another version of src.
static func load_baked(src: Mesh, path: String) -> ArrayMesh:
	var p := baked_path(src, path)
	if not ResourceLoader.exists(p):
		return null
	var m := load(p) as ArrayMesh
	if m == null or not fresh(m, src):
		push_warning("midlod: %s is stale; re-run proxy_bake.gd" % p)
		return null
	return m


## True when baked was merged from src as it is now (same surfaces, same bounds).
static func fresh(baked: Mesh, src: Mesh) -> bool:
	var box: Variant = baked.get_meta("src_aabb", null)
	return (
		int(baked.get_meta("src_surfaces", -1)) == src.get_surface_count()
		and box is AABB
		and (box as AABB).is_equal_approx(src.get_aabb())
	)


## Merges src on the calling thread and tags the result with what fresh() compares (the bake).
static func merged(src: Mesh, path: String) -> ArrayMesh:
	var job := _gather(src, path)
	_merge(job)
	var m := _finish(job)
	if m != null:
		m.set_meta("src_surfaces", src.get_surface_count())
		m.set_meta("src_aabb", src.get_aabb())
	return m


## Main thread: copies the surfaces with their colour and kind.
static func _gather(src: Mesh, path: String) -> Dictionary:
	var models: Dictionary = PROXIES.bake().get("models", {})
	var mats: Dictionary = (models.get(path, {}) as Dictionary).get("mats", (PROXIES.bake().get("road_mats", {}) as Dictionary).get(path, {}))
	var surfaces: Array = []
	for s in range(src.get_surface_count()):
		var mat := src.surface_get_material(s)
		var name := mat.resource_name if mat != null else ""
		var col := Color(0.6, 0.6, 0.6)
		if mats.has(name):
			var a: Array = mats[name]
			col = Color(float(a[0]), float(a[1]), float(a[2]))
		elif mat is BaseMaterial3D:
			col = (mat as BaseMaterial3D).albedo_color
		col.a = 0.0
		for p: String in GLASS_PREFIXES:
			if name.begins_with(p):
				col.a = 0.5
		for p: String in LIT_PREFIXES:
			if name.begins_with(p):
				col.a = 1.0
		var arr := src.surface_get_arrays(s)
		surfaces.append({"v": arr[Mesh.ARRAY_VERTEX], "n": arr[Mesh.ARRAY_NORMAL], "i": arr[Mesh.ARRAY_INDEX], "c": col})
	return {"surfaces": surfaces, "out": null}


## Any thread: concatenates the surfaces and generates LODs (no RenderingServer calls).
static func _merge(job: Dictionary) -> void:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var idx := PackedInt32Array()
	for s: Dictionary in job["surfaces"]:
		var sv: PackedVector3Array = s["v"]
		var base := v.size()
		v.append_array(sv)
		if s["n"] != null and (s["n"] as PackedVector3Array).size() == sv.size():
			n.append_array(s["n"])
		else:
			var up := PackedVector3Array()
			up.resize(sv.size())
			up.fill(Vector3.UP)
			n.append_array(up)
		var cc := PackedColorArray()
		cc.resize(sv.size())
		cc.fill(s["c"])
		c.append_array(cc)
		var si: PackedInt32Array = s["i"] if s["i"] != null else PackedInt32Array()
		var start := idx.size()
		if si.is_empty():
			for k in range(sv.size()):
				idx.append(base + k)
			continue
		idx.append_array(si)
		if base > 0:
			for k in range(start, idx.size()):
				idx[k] += base
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_COLOR] = c
	arrays[Mesh.ARRAY_INDEX] = idx
	var im := ImporterMesh.new()
	im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
	im.generate_lods(25.0, 60.0, [])
	job["out"] = im


static func _finish(job: Dictionary) -> ArrayMesh:
	var im: ImporterMesh = job["out"]
	job["surfaces"] = []
	return im.get_mesh() if im != null else null
