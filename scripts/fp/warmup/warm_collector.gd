class_name WarmCollector
extends RefCounted
## Finds the draws the scene will make, as a list of recipes, one per distinct material: a material
## on a plain mesh, on a MultiMesh (with or without per-instance colours and custom data), casting
## shadows or not, is one recipe, whatever meshes carry it. Instances with the same combination link
## the same shader programs, so the warm-up (ShaderWarmup) draws one tiny copy of each under the
## loader veil and the browser links its programs then, instead of in the middle of play. One
## material to a recipe keeps a batch's cost small and its order meaningful (a building with thirty
## materials is thirty recipes, not one frame of two seconds).
## Read-only: nothing under the root is touched. A skinned mesh counts like any other: the skeleton
## is its own pass, and the scene program that draws it is the plain mesh's for that material.

## A recipe: {"key", "mesh": Mesh (a small box: only the material matters), "multi": bool,
## "colors": bool, "custom": bool, "shadow": int, "override": Material, "overlay": null,
## "surfaces": Array, "verts": int, "dist": float (metres from the reference point to the nearest
## instance that has it), "n": int (instances with it)}.

## Where the list of things to warm that are not in the scene yet lives.
const PROTOTYPES_PATH := "res://data/warm_prototypes.json"
## The shader variants only the Planner view holds, written by tools/warm_variants.gd.
const ORBIT_PATH := "res://data/warm_orbit_variants.json"
## True (the default): one recipe per shader variant, the materials grouped by WarmSignature, so a
## grown city's fifteen hundred materials are a hundred or so draws. false: one recipe per material
## instance, as before (a test and probe knob).
static var by_variant: bool = true
static var _box: BoxMesh


## Recipes under root, nearest to near first (the order the warm-up draws them), at most cap. Nodes
## named in skip (and everything below them) are left out: the warm-up's own stage.
static func collect(
	root: Node, near: Vector3 = Vector3.ZERO, cap: int = 2000, skip: Array = []
) -> Array[Dictionary]:
	var by_key: Dictionary = {}
	WarmSignature.clear_cache()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if skip.has(n):
			continue
		for c: Node in n.get_children():
			stack.append(c)
		if not (n is MeshInstance3D or n is MultiMeshInstance3D):
			continue
		var d := _distance(n as Node3D, near)
		for rec: Dictionary in _recipes_of(n as GeometryInstance3D):
			var key: String = rec["key"]
			if by_key.has(key):
				var have: Dictionary = by_key[key]
				have["n"] = int(have["n"]) + 1
				have["dist"] = minf(float(have["dist"]), d)
			else:
				rec["dist"] = d
				rec["n"] = 1
				by_key[key] = rec
	var out: Array[Dictionary] = []
	for rec: Dictionary in by_key.values():
		out.append(rec)
	WarmSignature.clear_cache()
	out.sort_custom(_nearer)
	if out.size() > cap:
		out.resize(cap)
	return out


static func _nearer(a: Dictionary, b: Dictionary) -> bool:
	if not is_equal_approx(float(a["dist"]), float(b["dist"])):
		return float(a["dist"]) < float(b["dist"])
	return str(a["key"]) < str(b["key"])


static func _distance(n: Node3D, near: Vector3) -> float:
	if n == null or not n.is_inside_tree():
		return 1.0e9
	return n.global_position.distance_to(near)


## The recipes of one instance: one per distinct material it draws with.
static func _recipes_of(g: GeometryInstance3D) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var mesh: Mesh = null
	var multi := false
	var colors := false
	var custom := false
	if g is MeshInstance3D:
		mesh = (g as MeshInstance3D).mesh
	else:
		var mm := (g as MultiMeshInstance3D).multimesh
		if mm == null or mm.instance_count == 0:
			return out
		mesh = mm.mesh
		multi = true
		colors = mm.use_colors
		custom = mm.use_custom_data
	if mesh == null or mesh.get_surface_count() == 0:
		return out
	var mats: Dictionary = {}
	if g.material_override != null:
		mats[g.material_override.get_instance_id()] = g.material_override
	else:
		for s in mesh.get_surface_count():
			var eff: Material = null
			if g is MeshInstance3D:
				eff = (g as MeshInstance3D).get_surface_override_material(s)
			if eff == null:
				eff = mesh.surface_get_material(s)
			if eff != null:
				mats[eff.get_instance_id()] = eff
	if g.material_overlay != null:
		mats[g.material_overlay.get_instance_id()] = g.material_overlay
	for id: int in mats:
		var mat: Material = mats[id]
		var tag := WarmSignature.of(mat) if by_variant else str(id)
		out.append(_material_recipe(mat, tag, multi, colors, custom, int(g.cast_shadow)))
	return out


## Recipes for the materials and models named in data/warm_prototypes.json (a path that is not
## there is skipped), then for the nodes in extra (prototypes the features build; freed here).
static func prototypes(extra: Array[Node3D] = []) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary = {}
	var spec: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROTOTYPES_PATH))
	if typeof(spec) == TYPE_DICTIONARY:
		for path: String in (spec as Dictionary).get("materials", []):
			if not ResourceLoader.exists(path):
				continue
			var mat := load(path) as Material
			if mat != null:
				_add_all(out, seen, [_material_recipe(mat, path)])
		for path: String in (spec as Dictionary).get("scenes", []):
			if not ResourceLoader.exists(path):
				continue
			var scene := load(path) as PackedScene
			if scene == null:
				continue
			var inst := scene.instantiate()
			_add_all(out, seen, collect(inst))
			inst.free()
	for node: Node3D in extra:
		if node == null:
			continue
		_add_all(out, seen, collect(node))
		node.free()
	return out


## Recipes with stand-in materials for the variants only the Planner view holds (its materials are
## made when it first opens: data/warm_orbit_variants.json, by tools/warm_variants.gd), biggest user
## first. A missing or unreadable file, or an entry that cannot be rebuilt, is skipped.
static func orbit_catalogue() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not FileAccess.file_exists(ORBIT_PATH):
		return out
	var spec: Variant = JSON.parse_string(FileAccess.get_file_as_string(ORBIT_PATH))
	if typeof(spec) != TYPE_DICTIONARY:
		return out
	for e: Variant in (spec as Dictionary).get("variants", []):
		if typeof(e) != TYPE_DICTIONARY or typeof((e as Dictionary).get("spec")) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = e
		var mat := WarmSignature.build(entry["spec"])
		if mat == null:
			continue
		var rec := _material_recipe(
			mat,
			str(entry.get("sig", "")),
			bool(entry.get("multi", false)),
			bool(entry.get("colors", false)),
			bool(entry.get("custom", false)),
			int(entry.get("shadow", GeometryInstance3D.SHADOW_CASTING_SETTING_ON))
		)
		rec["n"] = int(entry.get("n", 1))
		out.append(rec)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["n"]) > int(b["n"]))
	return out


static func _add_all(out: Array[Dictionary], seen: Dictionary, recipes: Array) -> void:
	for r: Dictionary in recipes:
		if r.is_empty() or seen.has(r["key"]):
			continue
		seen[r["key"]] = true
		r["dist"] = 0.0
		out.append(r)


## A recipe that draws mat on a small box.
static func _material_recipe(
	mat: Material,
	tag: String,
	multi: bool = false,
	colors: bool = false,
	custom: bool = false,
	shadow: int = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
) -> Dictionary:
	if _box == null:
		_box = BoxMesh.new()
	return {
		"key":
		(
			"%s|%d|%s|%s|%s"
			% ["mm" if multi else "m", shadow, "c" if colors else "-", "d" if custom else "-", tag]
		),
		"mesh": _box,
		"multi": multi,
		"colors": colors,
		"custom": custom,
		"shadow": shadow,
		"override": mat,
		"overlay": null,
		"surfaces": [null],
		"verts": 36,
		"dist": 0.0,
		"n": 1,
	}
