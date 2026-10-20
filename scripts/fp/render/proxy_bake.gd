extends SceneTree
## Offline bake of building proxies for G2's far impostors and occluders. Run by hand, headless:
##   godot --headless --path . -s res://scripts/fp/render/proxy_bake.gd
## For every building model it writes into proxies.json, in the model's own space (lot centred on the
## origin, ground at y = 0): a GRID x GRID height field of the building mass (lot slab, foliage and
## props excluded) with the colour of the surface on top of each cell, the facade colour, the share
## of the facade that is glass and of that the share that lights up at night, and the body box (the
## main mass: cells at least half the building's height, or H's ColBox_<n> empties when present),
## and the average colour of every material (midlod.gd's vertex colours). Then, with those colours,
## every mesh midlod.gd would merge at runtime, merged into MIDLOD.BAKED_DIR (stale files removed).
## Colours are the materials' albedo_color times the average of their source albedo images (read
## from the source files here, never from the VRAM-compressed imports at runtime). Re-run after a
## model changes; the runtime falls back to surface bounds for any model missing from the file.

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const MIDLOD := preload("res://scripts/fp/render/midlod.gd")
const PROXIES := preload("res://scripts/fp/render/proxies.gd")
const OUT := "res://scripts/fp/render/proxies.json"
const DIRS := ["res://models/real/zones/", "res://models/real/buildings/"]
## Road pieces get material colours only (midlod.gd twins), no proxy.
const ROAD_DIRS := ["res://models/real/roads/"]
const GRID := 16
const HALF := 0.5
## Facade colour bands (world units) and the base split for buildings at least TALL high.
const BAND_H := 0.02
const BANDS := 200
const TALL := 0.3
const BASE_MAX := 0.2
## Surfaces that are not building mass (by material or node name prefix).
const SKIP_PREFIXES := ["Leaves", "Leaf", "Bark", "Hedge", "Tree", "Grass", "Turf"]
const GLASS_PREFIXES := ["WindowLit", "Glass_Shop", "Glass_Office", "Glass"]
const CAR_MATERIALS := ["Glass_Car", "Rubber", "Car_Paint"]

var _tex_avg: Dictionary = {}


func _init() -> void:
	var models := {}
	var road_mats := {}
	var t0 := Time.get_ticks_msec()
	for p: String in _model_paths(DIRS):
		var d := _bake(p)
		if not d.is_empty():
			models[p] = d
	for p: String in _model_paths(ROAD_DIRS):
		road_mats[p] = _mats_only(p)
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 1, "grid": GRID, "half": HALF, "models": models, "road_mats": road_mats}, "", true, false))
	f.close()
	print("PROXY_BAKE: %d models in %d ms -> %s" % [models.size(), Time.get_ticks_msec() - t0, OUT])
	# MIDLOD reads the colours through PROXIES.bake(), which loads OUT on its first call: now.
	var t1 := Time.get_ticks_msec()
	var mids := _bake_midlods(_model_paths(DIRS) + _model_paths(ROAD_DIRS))
	var ms := Time.get_ticks_msec() - t1
	print("PROXY_BAKE: %d mid-LOD meshes in %d ms -> %s" % [mids, ms, MIDLOD.BAKED_DIR])
	quit(0)


## Merges every mesh hlod.warm() would hand to midlod.gd and removes bakes nothing produced.
func _bake_midlods(paths: Array[String]) -> int:
	DirAccess.make_dir_recursive_absolute(MIDLOD.BAKED_DIR)
	var written := {}
	for path: String in paths:
		var ps := load(path) as PackedScene
		if ps == null:
			continue
		var root := ps.instantiate()
		if root.find_children("Rotor*", "", true, false).is_empty():
			for n in root.find_children("*", "MeshInstance3D", true, false):
				var mi := n as MeshInstance3D
				if mi.material_override != null or PROXIES._skipped(str(mi.name)):
					continue
				if not MIDLOD.mergeable(mi.mesh):
					continue
				var out := MIDLOD.baked_path(mi.mesh, path)
				if written.has(out):
					continue
				var m := MIDLOD.merged(mi.mesh, path)
				if m == null or ResourceSaver.save(m, out, ResourceSaver.FLAG_COMPRESS) != OK:
					push_warning("proxy_bake: cannot write %s" % out)
					continue
				written[out] = true
		root.free()
	var da := DirAccess.open(MIDLOD.BAKED_DIR)
	for fn in da.get_files():
		if not written.has(MIDLOD.BAKED_DIR + fn):
			da.remove(fn)
	return written.size()


func _model_paths(dirs: Array) -> Array[String]:
	var out: Array[String] = []
	for root: String in dirs:
		var stack: Array[String] = [root]
		while not stack.is_empty():
			var d: String = stack.pop_back()
			var da := DirAccess.open(d)
			if da == null:
				continue
			for sub in da.get_directories():
				stack.append(d + sub + "/")
			for fn in da.get_files():
				var n := fn.trim_suffix(".import")
				if n.ends_with(".glb") and not out.has(d + n):
					out.append(d + n)
	out.sort()
	return out


## Average colour of every material of a model (road pieces).
func _mats_only(path: String) -> Dictionary:
	var out := {}
	var ps := load(path) as PackedScene
	if ps == null:
		return out
	var root := ps.instantiate()
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := (n as MeshInstance3D).mesh
		if mesh == null:
			continue
		for s in range(mesh.get_surface_count()):
			var mat := mesh.surface_get_material(s)
			if mat != null:
				var col := _surface_color(mat)
				out[mat.resource_name] = [snappedf(col.r, 0.005), snappedf(col.g, 0.005), snappedf(col.b, 0.005)]
	root.free()
	return out


static func _skipped(name: String) -> bool:
	for p: String in SKIP_PREFIXES:
		if name.begins_with(p):
			return true
	return name.contains("foliage")


static func _is_glass(name: String) -> bool:
	if name in CAR_MATERIALS:
		return false
	for p: String in GLASS_PREFIXES:
		if name.begins_with(p):
			return true
	return false


func _bake(path: String) -> Dictionary:
	var ps := load(path) as PackedScene
	if ps == null:
		return {}
	var root := ps.instantiate() as Node3D
	if root == null:
		return {}
	var parts: Array = []
	var colboxes: Array[AABB] = []
	_walk(root, Transform3D.IDENTITY, parts, colboxes, true)
	var n2 := GRID * GRID
	var step := 2.0 * HALF / float(GRID)
	var hgt := PackedFloat32Array()
	hgt.resize(n2)
	var top := PackedColorArray()
	top.resize(n2)
	var wall := Vector3.ZERO
	var wall_area := 0.0
	# Facade colour per 0.02 u height band: rgb * area, area.
	var bands: Array[Vector4] = []
	bands.resize(BANDS)
	bands.fill(Vector4.ZERO)
	var glass_area := 0.0
	var lit_area := 0.0
	var mats := {}
	var cut := WS.LOT_TOP + 0.002
	for e: Dictionary in parts:
		var mesh: Mesh = e["mesh"]
		var xf: Transform3D = e["xform"]
		for s in range(mesh.get_surface_count()):
			var mat := mesh.surface_get_material(s)
			var mname := mat.resource_name if mat != null else ""
			var col := _surface_color(mat)
			mats[mname] = [snappedf(col.r, 0.005), snappedf(col.g, 0.005), snappedf(col.b, 0.005)]
			if _skipped(mname) or mname in CAR_MATERIALS:
				continue
			var glass := _is_glass(mname)
			var arrays := mesh.surface_get_arrays(s)
			var v: PackedVector3Array = xf * (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array)
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var tri_n := idx.size() / 3 if not idx.is_empty() else v.size() / 3
			for t in range(tri_n):
				var a := v[idx[t * 3]] if not idx.is_empty() else v[t * 3]
				var b := v[idx[t * 3 + 1]] if not idx.is_empty() else v[t * 3 + 1]
				var c := v[idx[t * 3 + 2]] if not idx.is_empty() else v[t * 3 + 2]
				if maxf(a.y, maxf(b.y, c.y)) <= cut:
					continue
				# Godot front faces wind clockwise: (c - a) x (b - a) points out of the surface.
				var nrm := (c - a).cross(b - a)
				var area := nrm.length() * 0.5
				if area < 1e-9:
					continue
				nrm /= area * 2.0
				if absf(nrm.y) < 0.35:
					if glass:
						glass_area += area
						if mname.begins_with("WindowLit"):
							lit_area += area
					else:
						wall += Vector3(col.r, col.g, col.b) * area
						wall_area += area
						var bi := clampi(int((a.y + b.y + c.y) / 3.0 / BAND_H), 0, BANDS - 1)
						bands[bi] += Vector4(col.r * area, col.g * area, col.b * area, area)
				if nrm.y > 0.2:
					_raster(a, b, c, col, hgt, top, step)
	root.free()
	var maxh := 0.0
	for k in range(n2):
		maxh = maxf(maxh, hgt[k])
	if maxh <= cut:
		return {}
	# Drop low clutter (parked cars, low walls, mailboxes) that would only add tiny bumps.
	var floor_h := maxf(0.03, 0.1 * maxh)
	var body := AABB()
	var pal: Array = []
	var cells := PackedInt32Array()
	cells.resize(n2)
	var hs: Array = []
	for k in range(n2):
		if hgt[k] < floor_h:
			hgt[k] = 0.0
		hs.append(snappedf(hgt[k], 0.001))
		var ci := -1
		if hgt[k] > 0.0:
			var q := [snappedf(top[k].r, 0.01), snappedf(top[k].g, 0.01), snappedf(top[k].b, 0.01)]
			ci = pal.find(q)
			if ci < 0:
				pal.append(q)
				ci = pal.size() - 1
			if hgt[k] >= 0.5 * maxh:
				var x0 := -HALF + float(k % GRID) * step
				var z0 := -HALF + float(k / GRID) * step
				var cb := AABB(Vector3(x0, WS.LOT_TOP, z0), Vector3(step, hgt[k] - WS.LOT_TOP, step))
				body = cb if body.size == Vector3.ZERO else body.merge(cb)
		cells[k] = ci
	if not colboxes.is_empty():
		body = colboxes[0]
		for cb: AABB in colboxes:
			body = body.merge(cb)
	var wc := wall / wall_area if wall_area > 0.0 else Vector3(0.6, 0.6, 0.58)
	# Mid-rise and taller buildings often stand on a different base (shopfronts, a brick podium):
	# facades below `split` take the base's colour, the rest the body's.
	var split := 0.0
	var lo := wc
	if maxh >= TALL:
		split = minf(BASE_MAX, 0.4 * maxh)
		var acc_lo := Vector4.ZERO
		var acc_hi := Vector4.ZERO
		for bi in range(BANDS):
			if (float(bi) + 0.5) * BAND_H < split:
				acc_lo += bands[bi]
			else:
				acc_hi += bands[bi]
		if acc_lo.w > 0.0 and acc_hi.w > 0.0:
			lo = Vector3(acc_lo.x, acc_lo.y, acc_lo.z) / acc_lo.w
			wc = Vector3(acc_hi.x, acc_hi.y, acc_hi.z) / acc_hi.w
		else:
			split = 0.0
	var vert := wall_area + glass_area
	return {
		"h": hs, "c": Array(cells), "pal": pal, "maxh": snappedf(maxh, 0.001),
		"wall": [snappedf(wc.x, 0.01), snappedf(wc.y, 0.01), snappedf(wc.z, 0.01)],
		"wall_lo": [snappedf(lo.x, 0.01), snappedf(lo.y, 0.01), snappedf(lo.z, 0.01)],
		"split": snappedf(split, 0.001),
		"win": snappedf(glass_area / vert if vert > 0.0 else 0.0, 0.01),
		"lit": snappedf(lit_area / glass_area if glass_area > 0.0 else 0.0, 0.01),
		"body": [snappedf(body.position.x, 0.001), snappedf(body.position.y, 0.001), snappedf(body.position.z, 0.001),
			snappedf(body.end.x, 0.001), snappedf(body.end.y, 0.001), snappedf(body.end.z, 0.001)],
		"colbox": not colboxes.is_empty(),
		"mats": mats,
	}


## Every mesh under n with its transform relative to the model root; ColBox empties as boxes.
func _walk(n: Node, xf: Transform3D, parts: Array, colboxes: Array[AABB], is_root: bool) -> void:
	var t := xf
	if n is Node3D and not is_root:
		t = xf * (n as Node3D).transform
	var nm := str(n.name)
	if nm.begins_with(AP.COLBOX_PREFIX) and n is Node3D:
		var he := (n as Node3D).scale.abs()
		colboxes.append(AABB(t.origin - he, he * 2.0))
		return
	if not is_root and _skipped(nm):
		return
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		parts.append({"mesh": (n as MeshInstance3D).mesh, "xform": t})
	for c in n.get_children():
		_walk(c, t, parts, colboxes, false)


## Writes the triangle's height at every cell centre it covers when it is the highest so far.
static func _raster(a: Vector3, b: Vector3, c: Vector3, col: Color, hgt: PackedFloat32Array, top: PackedColorArray, step: float) -> void:
	var mn := Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z)))
	var mx := Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z)))
	var i0 := clampi(ceili((mn.x + HALF) / step - 0.5), 0, GRID - 1)
	var i1 := clampi(floori((mx.x + HALF) / step - 0.5), 0, GRID - 1)
	var j0 := clampi(ceili((mn.y + HALF) / step - 0.5), 0, GRID - 1)
	var j1 := clampi(floori((mx.y + HALF) / step - 0.5), 0, GRID - 1)
	var d := (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
	if absf(d) < 1e-12:
		return
	for j in range(j0, j1 + 1):
		var pz := -HALF + (float(j) + 0.5) * step
		for i in range(i0, i1 + 1):
			var px := -HALF + (float(i) + 0.5) * step
			var w1 := ((px - a.x) * (c.z - a.z) - (c.x - a.x) * (pz - a.z)) / d
			var w2 := ((b.x - a.x) * (pz - a.z) - (px - a.x) * (b.z - a.z)) / d
			var w0 := 1.0 - w1 - w2
			if w0 < -1e-4 or w1 < -1e-4 or w2 < -1e-4:
				continue
			var y := a.y * w0 + b.y * w1 + c.y * w2
			var k := j * GRID + i
			if y > hgt[k]:
				hgt[k] = y
				top[k] = col


## Albedo colour times the average of the source albedo image (sRGB), cached per image.
func _surface_color(mat: Material) -> Color:
	if not (mat is BaseMaterial3D):
		return Color(0.6, 0.6, 0.6)
	var bm := mat as BaseMaterial3D
	var c := bm.albedo_color
	if bm.albedo_texture != null and not bm.albedo_texture.resource_path.is_empty():
		var p := bm.albedo_texture.resource_path
		if not _tex_avg.has(p):
			_tex_avg[p] = _image_average(p)
		c *= _tex_avg[p] as Color
	return Color(c.r, c.g, c.b)


static func _image_average(p: String) -> Color:
	var fallback := Color(0.7, 0.7, 0.7)
	var img := Image.load_from_file(ProjectSettings.globalize_path(p))
	if img == null or img.is_empty():
		return fallback
	if img.is_compressed() and img.decompress() != OK:
		push_warning("proxy_bake: cannot decompress %s; using grey" % p)
		return fallback
	img.convert(Image.FORMAT_RGBA8)
	if img.is_empty() or img.get_format() != Image.FORMAT_RGBA8:
		push_warning("proxy_bake: cannot read %s as RGBA8; using grey" % p)
		return fallback
	# shrink_x2 halves both sides, so it fails (leaving the image as it was) once a non-square
	# image is one pixel thin: halve while both sides allow it, then average the last row or column.
	while img.get_width() > 1 and img.get_height() > 1:
		var size := img.get_size()
		img.shrink_x2()
		if img.get_size() == size or img.is_empty():
			push_warning("proxy_bake: cannot shrink %s; using grey" % p)
			return fallback
	var sum := Color(0, 0, 0, 0)
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			sum += img.get_pixel(x, y)
	return sum / float(img.get_width() * img.get_height())
