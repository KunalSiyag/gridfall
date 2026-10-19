extends SceneTree
## Offline bake of wall-poster spots (slice D). For every zone building model and each of its four
## sides it finds the wall plane (the depth most wall-material rays hit near the wall box face) and,
## on that plane, the largest standard poster (6-sheet 1.2 x 1.8 m, 4-sheet 1.0 x 1.5 m, A0
## 0.84 x 1.19 m) that sits on flat wall nearest a corner: every ray of a grid over the poster must
## first hit outward-facing wall material on the plane, so no window, door, trim, sign or awning is
## covered and nothing floats. Writes res://assets/posters/wall_spots.json:
##   {model path: {"box": [x, y, z, sx, sy, sz], "spots": {side: {"p": [x, cy, z], "size": [w, h]}}}}
## side is +z, -z, +x or -x (the outward normal in model space); p.x/p.z lie on the wall plane in
## model space, cy is the world height of the poster centre (independent of the building scale) and
## size is in world units. The checks cover building scales 0.9 (S0) to 1.0 (G1).
## Run: godot --headless --path . -s scripts/fp/posters/wall_spot_baker.gd

const OUT := "res://assets/posters/wall_spots.json"
const DIRS := ["res://models/real/zones/"]
const WALL_PREFIXES := ["Brick", "Siding", "Stone", "Plaster", "Concrete_Wall", "Concrete_Panel", "Panel"]
const GLASS_PREFIXES := ["Glass_Shop"]
const SKIP_PREFIXES := ["Grass", "Sidewalk", "Dirt", "Concrete_Floor", "Hedge", "Leaves", "Bark"]
## Surfaces shorter than this (plinths, sills) do not define the wall box.
const MIN_WALL_H := 0.03
## Poster sizes in world units, largest first, and centre heights (world y), preferred first.
const SIZES := [Vector2(0.06, 0.09), Vector2(0.05, 0.075), Vector2(0.042, 0.0595)]
const HEIGHTS := [0.074, 0.08, 0.068]
## Window posters: A0 and A1, centred about 1.5 m up.
const WINDOW_SIZES := [Vector2(0.042, 0.0595), Vector2(0.03, 0.042)]
const WINDOW_HEIGHTS := [0.076, 0.07, 0.082]
const MIN_SCALE := 0.9
## The wall plane is searched this far behind the box face.
const PLANE_RANGE := 0.08
## Hits must lie within these distances behind / in front of the plane (model units).
const BEHIND_TOL := 0.002
const FRONT_TOL := 0.0012
const STEP := 0.006
const GRID := Vector2i(6, 8)
const MARGIN := 0.006

var _surfaces: Array[Dictionary] = []


func _init() -> void:
	await process_frame
	var out := {}
	var paths: Array[String] = []
	for d: String in DIRS:
		_collect(d, paths)
	paths.sort()
	var found := 0
	for p in paths:
		var e := bake(p)
		out[p] = e
		var desc := PackedStringArray()
		for kind: String in ["spots", "windows"]:
			var sides: Dictionary = e[kind]
			found += sides.size()
			for s: String in sides.keys():
				desc.append("%s%s %.2fx%.2fm" % ["window " if kind == "windows" else "", s, float(sides[s]["size"][0]) * 20.0, float(sides[s]["size"][1]) * 20.0])
		print("WALL_SPOTS %s %s" % [p.get_file(), ", ".join(desc)])
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "\t", true) + "\n")
	f.close()
	print("WALL_SPOTS: DONE models=%d spots=%d" % [paths.size(), found])
	quit(0)


func _collect(dir: String, out: Array[String]) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for sub in da.get_directories():
		_collect(dir + sub + "/", out)
	for f in da.get_files():
		if f.ends_with(".glb"):
			out.append(dir + f)


func bake(path: String) -> Dictionary:
	_surfaces.clear()
	var inst := (load(path) as PackedScene).instantiate()
	_walk(inst, Transform3D())
	inst.free()
	var box := AABB()
	var has := false
	for s: Dictionary in _surfaces:
		if not bool(s["wall"]) or (s["aabb"] as AABB).size.y < MIN_WALL_H:
			continue
		box = s["aabb"] if not has else box.merge(s["aabb"])
		has = true
	var spots := {}
	var windows := {}
	if has:
		for side: String in ["+z", "-z", "+x", "-x"]:
			var sp := _side_spot(box, side, "wall", SIZES, HEIGHTS)
			if not sp.is_empty():
				spots[side] = sp
			var wp := _side_spot(box, side, "glass", WINDOW_SIZES, WINDOW_HEIGHTS)
			if not wp.is_empty():
				windows[side] = wp
	return {"box": [snappedf(box.position.x, 0.0001), snappedf(box.position.y, 0.0001), snappedf(box.position.z, 0.0001),
		snappedf(box.size.x, 0.0001), snappedf(box.size.y, 0.0001), snappedf(box.size.z, 0.0001)], "spots": spots, "windows": windows}


func _walk(n: Node, xf: Transform3D) -> void:
	var t := xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	if n is MeshInstance3D and not str(n.name).ends_with("_foliage"):
		var m := (n as MeshInstance3D).mesh
		for si in range(m.get_surface_count()):
			var mat := m.surface_get_material(si)
			var mname := mat.resource_name if mat != null else ""
			if _starts(mname, SKIP_PREFIXES):
				continue
			var arr := m.surface_get_arrays(si)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var tris := PackedVector3Array()
			var bb := AABB(t * verts[0], Vector3.ZERO)
			for v in verts:
				bb = bb.expand(t * v)
			if idx.is_empty():
				for v in verts:
					tris.append(t * v)
			else:
				for k in idx:
					tris.append(t * verts[k])
			_surfaces.append({"mat": mname, "wall": _starts(mname, WALL_PREFIXES), "glass": _starts(mname, GLASS_PREFIXES), "aabb": bb, "tris": tris})
	for c in n.get_children():
		_walk(c, t)


static func _starts(s: String, prefixes: Array) -> bool:
	for p: String in prefixes:
		if s.begins_with(p):
			return true
	return false


## Face frame of a side: [outward normal, horizontal axis u, box face offset along the normal,
## u range of the box].
static func frame(box: AABB, side: String) -> Array:
	match side:
		"+z":
			return [Vector3(0, 0, 1), Vector3(1, 0, 0), box.end.z, box.position.x, box.end.x]
		"-z":
			return [Vector3(0, 0, -1), Vector3(-1, 0, 0), -box.position.z, -box.end.x, -box.position.x]
		"+x":
			return [Vector3(1, 0, 0), Vector3(0, 0, -1), box.end.x, -box.end.z, -box.position.z]
	return [Vector3(-1, 0, 0), Vector3(0, 0, 1), -box.position.x, box.position.z, box.end.z]


## The best spot on a side, or {} when the side has no flat surface of class cls ("wall" or
## "glass") big enough near poster height.
func _side_spot(box: AABB, side: String, cls: String, sizes: Array, heights: Array) -> Dictionary:
	var fr := frame(box, side)
	var n: Vector3 = fr[0]
	var u: Vector3 = fr[1]
	var face: float = fr[2]
	var v_lo: float = float(heights.min()) - (sizes[0] as Vector2).y * 0.5 - 0.004
	var v_hi: float = (float(heights.max()) + (sizes[0] as Vector2).y * 0.5) / MIN_SCALE + 0.004
	# First-hit candidates: triangles reaching the search range in front of the wall, in the band.
	var cand: Array[Dictionary] = []
	for s: Dictionary in _surfaces:
		var tris: PackedVector3Array = s["tris"]
		for k in range(0, tris.size(), 3):
			var a := tris[k]
			var b := tris[k + 1]
			var c := tris[k + 2]
			if maxf(a.dot(n), maxf(b.dot(n), c.dot(n))) < face - PLANE_RANGE - 0.01:
				continue
			if maxf(a.y, maxf(b.y, c.y)) < v_lo or minf(a.y, minf(b.y, c.y)) > v_hi:
				continue
			var ua := a.dot(u)
			var ub := b.dot(u)
			var uc := c.dot(u)
			var nn := (b - a).cross(c - a).normalized()
			cand.append({"a": a, "b": b, "c": c, "u0": minf(ua, minf(ub, uc)), "u1": maxf(ua, maxf(ub, uc)),
				"wall": s[cls], "flat": absf(nn.dot(n)) > 0.97})
	var plane := _wall_plane(cand, n, u, face, float(fr[3]), float(fr[4]), v_lo, v_hi)
	if is_nan(plane):
		return {}
	for sz: Vector2 in sizes:
		var half_u := sz.x * 0.5 / MIN_SCALE + MARGIN
		var lo: float = float(fr[3]) + half_u
		var hi: float = float(fr[4]) - half_u
		if hi < lo:
			continue
		var centres: Array[float] = []
		var k2 := 0
		while lo + k2 * STEP <= hi - k2 * STEP:
			centres.append(lo + k2 * STEP)
			if hi - k2 * STEP > lo + k2 * STEP:
				centres.append(hi - k2 * STEP)
			k2 += 1
		for cy: float in heights:
			var v0 := cy - sz.y * 0.5 - MARGIN
			var v1 := (cy + sz.y * 0.5) / MIN_SCALE + MARGIN
			for cu in centres:
				if _flat(cand, n, u, plane, cu, half_u, v0, v1):
					var p := n * plane + u * cu
					return {"p": [snappedf(p.x, 0.0001), cy, snappedf(p.z, 0.0001)], "size": [sz.x, sz.y]}
	return {}


## The depth (along n) most outward-facing wall hits land on, scanning the side's poster band.
func _wall_plane(cand: Array[Dictionary], n: Vector3, u: Vector3, face: float, u0: float, u1: float, v0: float, v1: float) -> float:
	var hist := {}
	var pu := u0 + 0.01
	while pu < u1 - 0.01:
		var pv := v0
		while pv <= v1:
			var hit := _first_hit(cand, n, u, face + 0.3, pu, pv)
			if not hit.is_empty() and bool(hit["wall"]) and bool(hit["flat"]):
				var depth: float = hit["depth"]
				if depth >= face - PLANE_RANGE:
					var b := roundi(depth * 1000.0)
					hist[b] = int(hist.get(b, 0)) + 1
			pv += 0.012
		pu += 0.01
	var best := -1
	var best_n := 0
	for b: int in hist.keys():
		if int(hist[b]) > best_n or (int(hist[b]) == best_n and b > best):
			best = b
			best_n = int(hist[b])
	if best_n < 6:
		return NAN
	return float(best) / 1000.0


func _first_hit(cand: Array[Dictionary], n: Vector3, u: Vector3, start: float, pu: float, pv: float) -> Dictionary:
	var from := u * pu + n * start
	from.y = pv
	var best := INF
	var out := {}
	for t: Dictionary in cand:
		if pu < float(t["u0"]) or pu > float(t["u1"]):
			continue
		var hit: Variant = Geometry3D.ray_intersects_triangle(from, -n, t["a"], t["b"], t["c"])
		if hit == null:
			continue
		var d := from.distance_to(hit as Vector3)
		if d < best:
			best = d
			out = {"depth": start - d, "wall": t["wall"], "flat": t["flat"]}
	return out


## True when every ray of the grid over [cu +- half_u] x [v0, v1] first hits flat wall on the plane.
func _flat(cand: Array[Dictionary], n: Vector3, u: Vector3, plane: float, cu: float, half_u: float, v0: float, v1: float) -> bool:
	var local: Array[Dictionary] = []
	for t: Dictionary in cand:
		if float(t["u1"]) >= cu - half_u and float(t["u0"]) <= cu + half_u:
			local.append(t)
	for iu in range(GRID.x):
		for iv in range(GRID.y):
			var pu := cu - half_u + 2.0 * half_u * float(iu) / float(GRID.x - 1)
			var pv := v0 + (v1 - v0) * float(iv) / float(GRID.y - 1)
			var hit := _first_hit(local, n, u, plane + 0.3, pu, pv)
			if hit.is_empty() or not bool(hit["wall"]) or not bool(hit["flat"]):
				return false
			var depth: float = hit["depth"]
			if depth > plane + FRONT_TOL or depth < plane - BEHIND_TOL:
				return false
	return true
