extends RefCounted
## Building proxies for far impostors and occluders (slice G2): per model path, the body box and a
## low-poly stepped mass mesh template (tops coloured by what covers each cell, facades by the
## model's average facade colour) built from the offline bake in proxies.json (proxy_bake.gd). A
## model missing from the bake falls back to the bounds of its non-foliage surfaces. Model space:
## the GLB root's own space, before the holder's building_xform.

const WS := preload("res://scripts/fp/world_scale.gd")
const BAKE := "res://scripts/fp/render/proxies.json"
const SKIP_PREFIXES := ["Leaves", "Leaf", "Bark", "Hedge", "Tree", "Grass", "Turf"]
const FALLBACK_WALL := Color(0.55, 0.54, 0.52)
const FALLBACK_ROOF := Color(0.3, 0.3, 0.31)

static var _bake: Dictionary = {}
static var _bake_loaded: bool = false

## path -> {"verts", "normals", "colors", "win", "body": AABB, "baked": bool}
var _cache: Dictionary = {}


## The baked data of every model (loaded once per process). {} when the bake file is missing.
static func bake() -> Dictionary:
	if not _bake_loaded:
		_bake_loaded = true
		var f := FileAccess.open(BAKE, FileAccess.READ)
		if f != null:
			var d: Variant = JSON.parse_string(f.get_as_text())
			if typeof(d) == TYPE_DICTIONARY:
				_bake = d
	return _bake


## The proxy of a model: {"verts": PackedVector3Array, "normals": PackedVector3Array, "colors":
## PackedColorArray, "win": float (glass share of the facade), "body": AABB (main mass), "baked"}.
## model is an instance of the scene at path, used only for the fallback (may be null).
func proxy(path: String, model: Node3D = null) -> Dictionary:
	if _cache.has(path):
		return _cache[path]
	var models: Dictionary = bake().get("models", {})
	var p: Dictionary
	if models.has(path):
		p = _from_bake(models[path], int(bake().get("grid", 16)), float(bake().get("half", 0.5)))
	else:
		p = _from_bounds(model)
	_cache[path] = p
	return p


## True when the model has a proxy with some mass (always true for baked models).
func has_mass(path: String, model: Node3D = null) -> bool:
	return not (proxy(path, model)["verts"] as PackedVector3Array).is_empty()


func _from_bake(e: Dictionary, g: int, half: float) -> Dictionary:
	var hs: Array = e["h"]
	var cs: Array = e["c"]
	var pal: Array = e["pal"]
	var wl: Array = e["wall"]
	var wall := Color(float(wl[0]), float(wl[1]), float(wl[2]), float(e.get("lit", 0.0)))
	var wb: Array = e.get("wall_lo", wl)
	var base := Color(float(wb[0]), float(wb[1]), float(wb[2]), wall.a)
	var split := float(e.get("split", 0.0))
	var step := 2.0 * half / float(g)
	var out := {"verts": PackedVector3Array(), "normals": PackedVector3Array(), "colors": PackedColorArray(), "win": float(e.get("win", 0.0)), "baked": true}
	var h := func(i: int, j: int) -> float:
		return float(hs[j * g + i]) if i >= 0 and j >= 0 and i < g and j < g else 0.0
	# Tops: greedy rectangles of equal height and colour.
	var used := PackedByteArray()
	used.resize(g * g)
	for j in range(g):
		for i in range(g):
			var k := j * g + i
			if used[k] == 1 or float(hs[k]) <= 0.0:
				continue
			var key := Vector2(float(hs[k]), float(cs[k]))
			var w := 1
			while i + w < g and used[k + w] == 0 and Vector2(float(hs[k + w]), float(cs[k + w])) == key:
				w += 1
			var d := 1
			var grow := true
			while grow and j + d < g:
				for q in range(w):
					var kk := (j + d) * g + i + q
					if used[kk] == 1 or Vector2(float(hs[kk]), float(cs[kk])) != key:
						grow = false
						break
				if grow:
					d += 1
			for jj in range(j, j + d):
				for ii in range(i, i + w):
					used[jj * g + ii] = 1
			var x0 := -half + float(i) * step
			var z0 := -half + float(j) * step
			var x1 := x0 + float(w) * step
			var z1 := z0 + float(d) * step
			var y := key.x
			var pc: Array = pal[int(key.y)] if int(key.y) >= 0 and int(key.y) < pal.size() else [FALLBACK_ROOF.r, FALLBACK_ROOF.g, FALLBACK_ROOF.b]
			var top := Color(float(pc[0]), float(pc[1]), float(pc[2]), wall.a)
			_quad(out, Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), Vector3.UP, top)
	# Facades: wherever a cell stands above its neighbour, merged along runs of equal steps.
	for dir: Vector2i in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
		for a in range(g):
			var b := 0
			while b < g:
				var i := b if dir.y != 0 else a
				var j := a if dir.y != 0 else b
				var hi: float = h.call(i, j)
				var lo: float = h.call(i + dir.x, j + dir.y)
				if hi <= lo:
					b += 1
					continue
				var run := 1
				while b + run < g:
					var i2 := b + run if dir.y != 0 else a
					var j2 := a if dir.y != 0 else b + run
					if not is_equal_approx(h.call(i2, j2), hi) or not is_equal_approx(h.call(i2 + dir.x, j2 + dir.y), lo):
						break
					run += 1
				if split > lo and split < hi:
					_facade(out, dir, i, j, run, step, half, lo, split, base)
					_facade(out, dir, i, j, run, step, half, split, hi, wall)
				else:
					_facade(out, dir, i, j, run, step, half, lo, hi, base if hi <= split else wall)
				b += run
	var bb: Array = e["body"]
	out["body"] = AABB(Vector3(float(bb[0]), float(bb[1]), float(bb[2])), Vector3(float(bb[3]) - float(bb[0]), float(bb[4]) - float(bb[1]), float(bb[5]) - float(bb[2])))
	return out


## One wall quad on the dir side of cells (i, j)..(i, j) + run along the edge, from lo up to hi.
static func _facade(out: Dictionary, dir: Vector2i, i: int, j: int, run: int, step: float, half: float, lo: float, hi: float, col: Color) -> void:
	var x0 := -half + float(i) * step
	var z0 := -half + float(j) * step
	var a: Vector3
	var b: Vector3
	if dir.y != 0:
		var z := z0 + (step if dir.y > 0 else 0.0)
		a = Vector3(x0, 0.0, z)
		b = Vector3(x0 + float(run) * step, 0.0, z)
	else:
		var x := x0 + (step if dir.x > 0 else 0.0)
		a = Vector3(x, 0.0, z0)
		b = Vector3(x, 0.0, z0 + float(run) * step)
	_quad(out, Vector3(a.x, lo, a.z), Vector3(b.x, lo, b.z), Vector3(b.x, hi, b.z), Vector3(a.x, hi, a.z), Vector3(dir.x, 0, dir.y), col)


## Two triangles with Godot's clockwise front faces toward n.
static func _quad(out: Dictionary, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3, c: Color) -> void:
	var v: PackedVector3Array = out["verts"]
	var nn: PackedVector3Array = out["normals"]
	var cc: PackedColorArray = out["colors"]
	var tri := [p0, p1, p2, p0, p2, p3]
	if (p2 - p0).cross(p1 - p0).dot(n) < 0.0:
		tri = [p0, p2, p1, p0, p3, p2]
	for p: Vector3 in tri:
		v.append(p)
		nn.append(n)
		cc.append(c)


## Fallback proxy: one box over the non-foliage surfaces above the lot slab.
func _from_bounds(model: Node3D) -> Dictionary:
	var out := {"verts": PackedVector3Array(), "normals": PackedVector3Array(), "colors": PackedColorArray(), "win": 0.15, "baked": false, "body": AABB()}
	if model == null:
		return out
	var body := AABB()
	var cut := WS.LOT_TOP + 0.002
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or _skipped(str(mi.name)):
			continue
		var rel := _relative(model, mi)
		for s in range(mi.mesh.get_surface_count()):
			var m := mi.mesh.surface_get_material(s)
			if m != null and _skipped(m.resource_name):
				continue
			var sa: AABB = RenderingServer.mesh_get_surface(mi.mesh.get_rid(), s).get("aabb", AABB())
			var a := rel * sa
			if a.end.y <= cut:
				continue
			a.size.y = a.end.y - maxf(a.position.y, cut)
			a.position.y = maxf(a.position.y, cut)
			body = a if body.size == Vector3.ZERO else body.merge(a)
	if body.size == Vector3.ZERO:
		return out
	out["body"] = body
	var x0 := body.position.x
	var z0 := body.position.z
	var x1 := body.end.x
	var z1 := body.end.z
	var y := body.end.y
	var roof := Color(FALLBACK_ROOF.r, FALLBACK_ROOF.g, FALLBACK_ROOF.b, 0.3)
	var wall := Color(FALLBACK_WALL.r, FALLBACK_WALL.g, FALLBACK_WALL.b, 0.3)
	_quad(out, Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), Vector3.UP, roof)
	_quad(out, Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, y, z0), Vector3(x0, y, z0), Vector3.FORWARD, wall)
	_quad(out, Vector3(x0, 0, z1), Vector3(x1, 0, z1), Vector3(x1, y, z1), Vector3(x0, y, z1), Vector3.BACK, wall)
	_quad(out, Vector3(x0, 0, z0), Vector3(x0, 0, z1), Vector3(x0, y, z1), Vector3(x0, y, z0), Vector3.LEFT, wall)
	_quad(out, Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x1, y, z1), Vector3(x1, y, z0), Vector3.RIGHT, wall)
	return out


static func _skipped(name: String) -> bool:
	for p: String in SKIP_PREFIXES:
		if name.begins_with(p):
			return true
	return name.contains("foliage")


## mi's transform relative to root.
static func _relative(root: Node3D, mi: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = mi
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t
