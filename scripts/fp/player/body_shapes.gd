extends RefCounted
## Walking collision of a building or zone model from its own geometry (slice A deliverable 2).
## A building GLB merges a whole lot (grass, paths, the house, a parked car, lamps, benches,
## trees) into a few surfaces, so its AABB would block the yard. analyse() rasterises every
## triangle that can stop a walker (not ground, not under the step height, not overhead, not
## foliage) into a 25 cm footprint grid, fills enclosed interiors (a wall shell is a solid
## building), splits the grid into connected parts and returns, in model space:
##   bodies: at most MAX_BODIES boxes, the building masses;
##   walls:  thin boxes (fences, low walls, benches, a parked car), at most MAX_WALLS;
##   cyls:   posts (lamps, bollards) and tree trunks, as (x, z, r, top) quadruples.
## `ColBox_<n>` empties (AP.COLBOX_PREFIX) replace the bodies. body_bake.gd stores the results in
## body_table.gd; CollisionWorld analyses an unbaked model at runtime, once per file.

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const M := WS.M
const MAX_BODIES := 4
const MAX_WALLS := 24
const CELL := 0.25 * M
## Model-space heights: a triangle entirely under LOW_TOP is ground or steppable; one entirely
## over HEAD_Y is overhead (eaves, roofs, awnings) and never stops a walker.
const LOW_TOP := WS.LOT_TOP + WS.STEP_HEIGHT
const HEAD_Y := WS.LOT_TOP + WS.PLAYER_HEIGHT
## An enclosed hole is filled when at least half its rim is this tall (building walls, not fences).
const TALL_Y := WS.LOT_TOP + 2.2 * M
## Bark triangles starting below this belong to a trunk (the rest are branches).
const TRUNK_FOOT := WS.LOT_TOP + 0.5 * M
const TRUNK_R_MIN := 0.15 * M
const TRUNK_R_MAX := 0.35 * M
## Parts smaller than POST_MAX both ways are posts (cylinders).
const POST_MAX := 0.8 * M
const POST_R_MIN := 0.1 * M
const POST_R_MAX := 0.35 * M
## Rectangles of one part merge back while the merged box is at most this empty.
const PIECE_WASTE := 0.12
## A part is cut into at most this many rectangles.
const MAX_RECTS := 48
## A box at least BODY_MIN wide both ways and BODY_AREA in area is a body; smaller ones are walls.
const BODY_MIN := 1.5 * M
const BODY_AREA := 6.0 * M * M


## {"bounds": AABB, "bodies": Array[AABB], "walls": Array[AABB], "cyls": PackedFloat32Array},
## everything relative to the model root. bounds is the merged mesh AABB (the model's identity
## for body_table.gd).
static func analyse(model: Node3D) -> Dictionary:
	var parts: Array = []
	_collect(model, Transform3D.IDENTITY, parts, false)
	var bounds := AABB()
	for e: Dictionary in parts:
		var a: AABB = (e["xform"] as Transform3D) * ((e["node"] as MeshInstance3D).mesh.get_aabb())
		bounds = a if bounds.size == Vector3.ZERO else bounds.merge(a)
	var none: Array[AABB] = []
	var out := {"bounds": bounds, "bodies": none, "walls": none.duplicate(), "cyls": PackedFloat32Array()}
	if parts.is_empty():
		return out
	var g := Grid.new(bounds)
	var bark := Grid.new(bounds)
	for e: Dictionary in parts:
		if bool(e["foliage"]):
			continue
		var mi: MeshInstance3D = e["node"]
		var mesh := mi.mesh
		var xf: Transform3D = e["xform"]
		for s in range(mesh.get_surface_count()):
			var mat := mi.get_surface_override_material(s)
			if mat == null:
				mat = mesh.surface_get_material(s)
			var mname := mat.resource_name if mat != null else ""
			if mname.begins_with("Leaves") or mname.begins_with("Hedge"):
				continue
			var is_bark := mname.begins_with("Bark")
			var arrays := mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = xf * (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array)
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var n := idx.size() if not idx.is_empty() else verts.size()
			for t in range(0, n - 2, 3):
				var a := verts[idx[t]] if not idx.is_empty() else verts[t]
				var b := verts[idx[t + 1]] if not idx.is_empty() else verts[t + 1]
				var c := verts[idx[t + 2]] if not idx.is_empty() else verts[t + 2]
				var lo := minf(a.y, minf(b.y, c.y))
				var hi := maxf(a.y, maxf(b.y, c.y))
				if is_bark:
					if lo <= TRUNK_FOOT and hi > LOW_TOP:
						bark.tri(a, b, c, lo, hi)
					continue
				if hi <= LOW_TOP or lo >= HEAD_Y:
					continue
				g.tri(a, b, c, lo, hi)
	var colboxes := model.find_children(AP.COLBOX_PREFIX + "*", "Node3D", true, false)
	var bodies: Array[AABB] = []
	var walls: Array[AABB] = []
	var cyls := PackedFloat32Array()
	if not colboxes.is_empty():
		for cb: Node in colboxes:
			var xf := _relative(model, cb as Node3D)
			var he := xf.basis.get_scale()
			bodies.append(AABB(xf.origin - he, he * 2.0))
	else:
		g.fill_enclosed()
		for comp: PackedInt32Array in g.components():
			var r := g.rect_of(comp)
			if float(r.size.x) * CELL < POST_MAX and float(r.size.y) * CELL < POST_MAX:
				var c := g.centre(r)
				cyls.append_array([c.x, c.y, clampf(float(maxi(r.size.x, r.size.y)) * CELL * 0.5, POST_R_MIN, POST_R_MAX), g.top_of(comp)])
				continue
			var pieces: Array[AABB] = []
			for part: PackedInt32Array in g.rects(comp):
				var pb := g.box_of(part).intersection(bounds)
				if pb.size.x > 0.0 and pb.size.z > 0.0:
					pieces.append(pb)
			# Strips left along a wall by the rectangle cut rejoin the block they belong to.
			for box: AABB in merge_tight(pieces, PIECE_WASTE):
				if minf(box.size.x, box.size.z) >= BODY_MIN and box.size.x * box.size.z >= BODY_AREA:
					bodies.append(box)
				else:
					walls.append(box)
		bodies = merge_tight(bodies, 0.15)
		while bodies.size() > MAX_BODIES:
			var small := 0
			for k in range(bodies.size()):
				if _area(bodies[k]) < _area(bodies[small]):
					small = k
			walls.append(bodies[small])
			bodies.remove_at(small)
		walls = merge_tight(walls, 0.25)
		walls = merge_to(walls, MAX_WALLS)
	for comp: PackedInt32Array in bark.components():
		var r := bark.rect_of(comp)
		var c := bark.centre(r)
		if _inside_any(c, bodies):
			continue
		cyls.append_array([c.x, c.y, clampf(float(maxi(r.size.x, r.size.y)) * CELL * 0.5, TRUNK_R_MIN, TRUNK_R_MAX), bark.top_of(comp)])
	# Posts standing inside a body add nothing.
	var kept := PackedFloat32Array()
	for k in range(0, cyls.size(), 4):
		if not _inside_any(Vector2(cyls[k], cyls[k + 1]), bodies):
			kept.append_array([cyls[k], cyls[k + 1], cyls[k + 2], cyls[k + 3]])
	out["bodies"] = bodies
	out["walls"] = walls
	out["cyls"] = kept
	return out


## Merges pairs whose merged box is at most `waste` empty (added xz area over merged area),
## least added area first.
static func merge_tight(boxes: Array[AABB], waste: float) -> Array[AABB]:
	var list: Array[AABB] = boxes.duplicate()
	while list.size() > 1:
		var best := INF
		var bi := -1
		var bj := -1
		for i in range(list.size()):
			for j in range(i + 1, list.size()):
				var m := list[i].merge(list[j])
				var add := _area(m) - _area(list[i]) - _area(list[j]) + _area(list[i].intersection(list[j]))
				if add <= waste * _area(m) and add < best:
					best = add
					bi = i
					bj = j
		if bi < 0:
			break
		list[bi] = list[bi].merge(list[bj])
		list.remove_at(bj)
	return list


## Greedy merge of the pair that adds the least xz area until at most n boxes remain.
static func merge_to(boxes: Array[AABB], n: int) -> Array[AABB]:
	var list: Array[AABB] = boxes.duplicate()
	while list.size() > n:
		var best := INF
		var bi := 0
		var bj := 1
		for i in range(list.size()):
			for j in range(i + 1, list.size()):
				var m := list[i].merge(list[j])
				var add := _area(m) - _area(list[i]) - _area(list[j]) + _area(list[i].intersection(list[j]))
				if add < best:
					best = add
					bi = i
					bj = j
		list[bi] = list[bi].merge(list[bj])
		list.remove_at(bj)
	return list


static func _area(b: AABB) -> float:
	return b.size.x * b.size.z


static func _inside_any(p: Vector2, boxes: Array[AABB]) -> bool:
	for b: AABB in boxes:
		if p.x >= b.position.x and p.x <= b.end.x and p.y >= b.position.z and p.y <= b.end.z:
			return true
	return false


## Every MeshInstance3D under n with its transform relative to the model root; foliage marks the
## `*_foliage` subtree (one merged mesh of every tree crown).
static func _collect(n: Node, xf: Transform3D, out: Array, foliage: bool) -> void:
	var fol := foliage or str(n.name).ends_with("_foliage")
	for c: Node in n.get_children():
		var t := xf
		if c is Node3D:
			t = xf * (c as Node3D).transform
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			out.append({"node": c, "xform": t, "foliage": fol or str(c.name).ends_with("_foliage")})
		_collect(c, t, out, fol)


static func _relative(root: Node3D, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


## A footprint grid over a model's xz bounds: per cell the lowest bottom and highest top of the
## triangles that cover it.
class Grid:
	var x0: float
	var z0: float
	var w: int
	var h: int
	var lo: PackedFloat32Array
	var hi: PackedFloat32Array
	var solid: PackedByteArray

	func _init(b: AABB) -> void:
		var cell: float = CELL
		x0 = floorf(b.position.x / cell) * cell - cell
		z0 = floorf(b.position.z / cell) * cell - cell
		w = clampi(ceili((b.end.x - x0) / cell) + 2, 3, 400)
		h = clampi(ceili((b.end.z - z0) / cell) + 2, 3, 400)
		lo.resize(w * h)
		hi.resize(w * h)
		solid.resize(w * h)
		lo.fill(INF)
		hi.fill(-INF)

	## Marks the cells under triangle abc (its edges, and the cells whose centre it covers).
	func tri(a: Vector3, b: Vector3, c: Vector3, ylo: float, yhi: float) -> void:
		var pa := Vector2(a.x, a.z)
		var pb := Vector2(b.x, b.z)
		var pc := Vector2(c.x, c.z)
		_edge(pa, pb, ylo, yhi)
		_edge(pb, pc, ylo, yhi)
		_edge(pc, pa, ylo, yhi)
		var cell: float = CELL
		var area := (pb - pa).cross(pc - pa)
		if absf(area) < cell * cell:
			return
		var i0 := clampi(floori((minf(pa.x, minf(pb.x, pc.x)) - x0) / cell), 0, w - 1)
		var i1 := clampi(floori((maxf(pa.x, maxf(pb.x, pc.x)) - x0) / cell), 0, w - 1)
		var j0 := clampi(floori((minf(pa.y, minf(pb.y, pc.y)) - z0) / cell), 0, h - 1)
		var j1 := clampi(floori((maxf(pa.y, maxf(pb.y, pc.y)) - z0) / cell), 0, h - 1)
		var sg := signf(area)
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				var p := Vector2(x0 + (float(i) + 0.5) * cell, z0 + (float(j) + 0.5) * cell)
				if (pb - pa).cross(p - pa) * sg >= 0.0 and (pc - pb).cross(p - pb) * sg >= 0.0 and (pa - pc).cross(p - pc) * sg >= 0.0:
					_mark(i, j, ylo, yhi)

	func _edge(p: Vector2, q: Vector2, ylo: float, yhi: float) -> void:
		var cell: float = CELL
		var steps := ceili(p.distance_to(q) / (cell * 0.5)) + 1
		for s in range(steps + 1):
			var r := p.lerp(q, float(s) / float(steps))
			_mark(clampi(floori((r.x - x0) / cell), 0, w - 1), clampi(floori((r.y - z0) / cell), 0, h - 1), ylo, yhi)

	func _mark(i: int, j: int, ylo: float, yhi: float) -> void:
		var k := j * w + i
		solid[k] = 1
		lo[k] = minf(lo[k], ylo)
		hi[k] = maxf(hi[k], yhi)

	## Fills every enclosed hole whose rim is mostly tall (TALL_Y): the inside of a closed wall shell
	## is part of the building, while a yard inside a fence or a low wall stays open.
	func fill_enclosed() -> void:
		var seen := PackedByteArray()
		seen.resize(w * h)
		var border := PackedInt32Array()
		for i in range(w):
			border.append(i)
			border.append((h - 1) * w + i)
		for j in range(h):
			border.append(j * w)
			border.append(j * w + w - 1)
		_flood(border, seen, null)
		for k0 in range(w * h):
			if solid[k0] == 1 or seen[k0] == 1:
				continue
			var rim := {}
			var hole := _flood(PackedInt32Array([k0]), seen, rim)
			var tall := 0
			for r: int in rim.keys():
				if hi[r] >= TALL_Y:
					tall += 1
			if rim.is_empty() or float(tall) >= 0.5 * float(rim.size()):
				for k in hole:
					solid[k] = 1

	## 4-connected flood over empty cells from seeds; returns the cells reached and, when rim is a
	## Dictionary, collects the solid cells bordering them as its keys.
	func _flood(seeds: PackedInt32Array, seen: PackedByteArray, rim: Variant) -> PackedInt32Array:
		var out := PackedInt32Array()
		var stack := seeds.duplicate()
		while not stack.is_empty():
			var k := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			if seen[k] == 1:
				continue
			if solid[k] == 1:
				if rim != null:
					(rim as Dictionary)[k] = true
				continue
			seen[k] = 1
			out.append(k)
			var i := k % w
			var j := k / w
			if i > 0:
				stack.append(k - 1)
			if i < w - 1:
				stack.append(k + 1)
			if j > 0:
				stack.append(k - w)
			if j < h - 1:
				stack.append(k + w)
		return out

	## Connected (8-neighbour) solid parts, as lists of cell indices.
	func components() -> Array[PackedInt32Array]:
		var out: Array[PackedInt32Array] = []
		var seen := PackedByteArray()
		seen.resize(w * h)
		for start in range(w * h):
			if solid[start] == 0 or seen[start] == 1:
				continue
			var comp := PackedInt32Array()
			var stack := PackedInt32Array([start])
			seen[start] = 1
			while not stack.is_empty():
				var k := stack[stack.size() - 1]
				stack.resize(stack.size() - 1)
				comp.append(k)
				var i := k % w
				var j := k / w
				for dj in range(-1, 2):
					for di in range(-1, 2):
						var ni := i + di
						var nj := j + dj
						if ni < 0 or nj < 0 or ni >= w or nj >= h:
							continue
						var nk := nj * w + ni
						if solid[nk] == 1 and seen[nk] == 0:
							seen[nk] = 1
							stack.append(nk)
			out.append(comp)
		return out

	## Cell rect (position, size) of a cell list.
	func rect_of(cells: PackedInt32Array) -> Rect2i:
		var a := Vector2i(w, h)
		var b := Vector2i(-1, -1)
		for k in cells:
			var i := k % w
			var j := k / w
			a = Vector2i(mini(a.x, i), mini(a.y, j))
			b = Vector2i(maxi(b.x, i), maxi(b.y, j))
		return Rect2i(a, b - a + Vector2i.ONE)

	## Model-space xz centre of a cell rect.
	func centre(r: Rect2i) -> Vector2:
		var cell: float = CELL
		return Vector2(x0 + (float(r.position.x) + float(r.size.x) * 0.5) * cell, z0 + (float(r.position.y) + float(r.size.y) * 0.5) * cell)

	## Highest top over the cells (filled interior cells have none and are skipped).
	func top_of(cells: PackedInt32Array) -> float:
		var t := -INF
		for k in cells:
			t = maxf(t, hi[k])
		return t if is_finite(t) else WS.LOT_TOP + WS.PLAYER_HEIGHT

	## Model-space box of a cell list: its cell rect in xz, the lowest bottom to the highest top.
	func box_of(cells: PackedInt32Array) -> AABB:
		var cell: float = CELL
		var r := rect_of(cells)
		var y0 := INF
		var y1 := -INF
		for k in cells:
			if is_finite(lo[k]):
				y0 = minf(y0, lo[k])
				y1 = maxf(y1, hi[k])
		if not is_finite(y0):
			y0 = WS.LOT_TOP
			y1 = WS.LOT_TOP + WS.PLAYER_HEIGHT
		y0 = minf(y0, LOW_TOP)
		return AABB(Vector3(x0 + float(r.position.x) * cell, y0, z0 + float(r.position.y) * cell), Vector3(float(r.size.x) * cell, y1 - y0, float(r.size.y) * cell))

	## Cuts a part into rectangles of solid cells, largest first (an L-shaped house becomes two
	## boxes, a fence ring its four sides), at most MAX_RECTS; the cells left after that join the
	## nearest rectangle.
	func rects(cells: PackedInt32Array) -> Array[PackedInt32Array]:
		var r := rect_of(cells)
		var rw := r.size.x
		var rh := r.size.y
		var mask := PackedByteArray()
		mask.resize(rw * rh)
		for k in cells:
			mask[(k / w - r.position.y) * rw + (k % w - r.position.x)] = 1
		var out: Array[PackedInt32Array] = []
		var left := cells.size()
		var heights := PackedInt32Array()
		heights.resize(rw)
		while left > 0 and out.size() < MAX_RECTS:
			# Largest all-solid rectangle: the histogram method, row by row.
			heights.fill(0)
			var best := 0
			var bx := 0
			var by := 0
			var bw := 0
			var bh := 0
			for j in range(rh):
				for i in range(rw):
					heights[i] = heights[i] + 1 if mask[j * rw + i] == 1 else 0
				var stack := PackedInt32Array()
				for i in range(rw + 1):
					var cur := heights[i] if i < rw else 0
					while not stack.is_empty() and heights[stack[stack.size() - 1]] >= cur:
						var top := stack[stack.size() - 1]
						stack.resize(stack.size() - 1)
						var hh := heights[top]
						var start := stack[stack.size() - 1] + 1 if not stack.is_empty() else 0
						var ww := i - start
						if hh * ww > best:
							best = hh * ww
							bx = start
							by = j - hh + 1
							bw = ww
							bh = hh
					stack.append(i)
			if best <= 0:
				break
			var part := PackedInt32Array()
			for j in range(by, by + bh):
				for i in range(bx, bx + bw):
					mask[j * rw + i] = 0
					part.append((j + r.position.y) * w + i + r.position.x)
			left -= part.size()
			out.append(part)
		if left > 0 and not out.is_empty():
			for j in range(rh):
				for i in range(rw):
					if mask[j * rw + i] == 0:
						continue
					var k := (j + r.position.y) * w + i + r.position.x
					var near := 0
					var near_d := INF
					for q in range(out.size()):
						var rr := rect_of(out[q])
						var d := Vector2(clampf(i + r.position.x, rr.position.x, rr.end.x - 1) - (i + r.position.x), clampf(j + r.position.y, rr.position.y, rr.end.y - 1) - (j + r.position.y)).length()
						if d < near_d:
							near_d = d
							near = q
					out[near].append(k)
		return out
