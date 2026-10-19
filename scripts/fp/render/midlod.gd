extends RefCounted
## Mid-range building LOD (slice G2): a building mesh's surfaces merged into one, each carrying its
## material's average colour (proxies.json, else albedo_color) as vertex colour, with generated
## LODs. A building is one draw call instead of 17 to 30 between VIS_BUILDING_NEAR and
## VIS_BUILDING, where its textures are down to their smallest mips anyway. Merges run on the
## WorkerThreadPool (the main thread only copies the arrays and uploads the result); cached per
## source mesh, which every instance of a model shares.

const PROXIES := preload("res://scripts/fp/render/proxies.gd")
const SHADER := preload("res://scripts/fp/render/midlod.gdshader")
const GLASS_PREFIXES := ["Glass", "Window"]
const LIT_PREFIXES := ["WindowLit"]
## A mesh with fewer surfaces gains too little to replace.
const MIN_SURFACES := 3

var material: ShaderMaterial
## false builds on the calling thread (tests).
var threaded: bool = true
var _meshes: Dictionary = {}
var _jobs: Dictionary = {}


func _init() -> void:
	material = ShaderMaterial.new()
	material.shader = SHADER


## True when src is worth merging.
static func mergeable(src: Mesh) -> bool:
	return src != null and src.get_surface_count() >= MIN_SURFACES


## The merged mesh for src, or null while it is being built (the build starts on the first call).
## path is the building model's scene path (for the baked colours).
func mesh_for(src: Mesh, path: String) -> ArrayMesh:
	var id := src.get_instance_id()
	if _meshes.has(id):
		return _meshes[id]
	if _jobs.has(id):
		return null
	var job := _gather(src, path)
	if threaded:
		job["task"] = WorkerThreadPool.add_task(_merge.bind(job), false, "G2 mid LOD")
		_jobs[id] = job
		return null
	_merge(job)
	_meshes[id] = _finish(job)
	return _meshes[id]


## Uploads every finished build; returns how many finished.
func poll() -> int:
	var n := 0
	for id: int in _jobs.keys():
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


## Main thread: copies the surfaces with their colour and kind.
static func _gather(src: Mesh, path: String) -> Dictionary:
	var models: Dictionary = PROXIES.bake().get("models", {})
	var mats: Dictionary = (models.get(path, {}) as Dictionary).get("mats", {})
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
