extends SceneTree
## Orbit tree chunks (flag orbit_tree_chunks, scripts/world/city_view.gd): the Planner view plants
## its trees in 16-tile chunks, so the renderer can cull the forest to what the view reaches;
## with the flag off they are the old 48-tile chunks. Either way the same trees stand in the same
## places (the spots are a pure function of the world), every layer of a chunk sits inside its own
## chunk's box, and on foot (fp_mode) the chunk size is the street's, unchanged by the flag.
## The full-tree / stand-in switch is per 48-tile cell (OrbitTreeLod), as it was with the big
## chunks, not per small chunk: the same cells are near for the same camera, a chunk near the camera
## in a far cell is far, and a replanted chunk takes its cell's state.
## Headless, offline. Prints FP_ORBIT_TREES_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const TOKEN := "FP_ORBIT_TREES_TEST"
const FLAG := "orbit_tree_chunks"

var fails: Array[String] = []
var holder: Node3D
var sim: CitySim


func _init() -> void:
	K.watchdog(self, TOKEN, 200.0)
	await process_frame
	holder = Node3D.new()
	holder.name = "OrbitTreesKit"
	get_root().add_child(holder)
	sim = K.make_sim(holder, 7)["sim"]
	sim.set_speed(0)
	var flag_before := FeatureFlags.enabled(FLAG, true)
	K.check(fails, bool(FeatureFlags.defaults().get(FLAG, false)), "the flag ships on")
	FeatureFlags.set_override(FLAG, true)
	var small := _orbit_view()
	var small_spots := _spots(small)
	K.check(
		fails,
		small._tree_chunk_size(0) == CityView.TREE_CHUNK_ORBIT,
		"flag on: orbit chunks are small"
	)
	K.check(
		fails,
		small._tree_chunk_size(1) == CityView.TREE_CHUNK_FP,
		"the street's chunks are not touched"
	)
	FeatureFlags.set_override(FLAG, false)
	var big := _orbit_view()
	var big_spots := _spots(big)
	K.check(
		fails, big._tree_chunk_size(0) == CityView.TREE_CHUNK, "flag off: the old 48-tile chunks"
	)
	K.check(
		fails,
		small._tree_chunks.size() > big._tree_chunks.size(),
		(
			"small chunks make more of them (%d against %d)"
			% [small._tree_chunks.size(), big._tree_chunks.size()]
		)
	)
	K.check(
		fails,
		int(small_spots["n"]) > 1000,
		"the world has woods to compare (%d trees)" % int(small_spots["n"])
	)
	K.check(
		fails, _same(small_spots, big_spots), "the same trees stand in the same places either way"
	)
	_check_boxes(small)
	_check_lod(small, big)
	_check_lod_camera(small)
	_check_lod_refresh(small)
	FeatureFlags.set_override(FLAG, flag_before)
	K.finish(self, TOKEN, fails)


func _orbit_view() -> CityView:
	var cam := Camera3D.new()
	holder.add_child(cam)
	var v := CityView.new()
	holder.add_child(v)
	v.fp_mode = false
	v.setup(sim, cam)
	return v


## The trees the chunks plant as {n, x, z, xx, zz}: their count and the sums of their world x and z
## (and squares), read from the pure spot function the planting uses (a headless renderer keeps no
## multimesh buffer to read back). Sums, not text: the two chunkings add in another order.
func _spots(v: CityView) -> Dictionary:
	var out := {"n": 0, "x": 0.0, "z": 0.0, "xx": 0.0, "zz": 0.0}
	var lo := v._tree_chunk_of(D.X0 - CityView.TREE_RING, D.Y0 - CityView.TREE_RING, 0)
	var hi := v._tree_chunk_of(
		D.X0 + D.W + CityView.TREE_RING - 1, D.Y0 + D.H + CityView.TREE_RING - 1, 0
	)
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			for kit: Array in v._tree_chunk_spots(Vector3i(cx, cy, 0)):
				for t: Transform3D in kit:
					out["n"] += 1
					out["x"] += t.origin.x
					out["z"] += t.origin.z
					out["xx"] += t.origin.x * t.origin.x
					out["zz"] += t.origin.z * t.origin.z
	return out


func _same(a: Dictionary, b: Dictionary) -> bool:
	if a["n"] != b["n"]:
		return false
	for k: String in ["x", "z", "xx", "zz"]:
		if absf(float(a[k]) - float(b[k])) > 0.01 * maxf(1.0, absf(float(a[k])) * 1.0e-4):
			return false
	return true


## A layer's own position is the mean of its trees, so it lies inside its chunk's box (plus a tree).
func _check_boxes(v: CityView) -> void:
	var size: int = v._tree_chunk_size(0)
	var bad := 0
	for c: Vector3i in v._tree_chunks.keys():
		var x0 := float(D.X0 - CityView.TREE_RING + c.x * size) - 1.0
		var z0 := float(D.Y0 - CityView.TREE_RING + c.y * size) - 1.0
		for layer: Variant in v._tree_chunks[c]:
			var mmi := layer as MultiMeshInstance3D
			if mmi == null:
				continue
			if (
				mmi.position.x < x0
				or mmi.position.x > x0 + float(size) + 2.0
				or mmi.position.z < z0
				or mmi.position.z > z0 + float(size) + 2.0
			):
				bad += 1
	K.check(fails, bad == 0, "every layer sits inside its own chunk's box (%d outside)" % bad)


## The layers of a chunk by kind: {"near": [...], "far": [...]} (far ones are the stand-ins: they
## are the ones that cast no shadow and the engine's old rule began at the near end).
func _kinds(v: CityView, c: Vector3i) -> Dictionary:
	var out := {"near": [], "far": []}
	for layer: Variant in v._tree_chunks[c]:
		var mmi := layer as MultiMeshInstance3D
		if mmi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			(out["far"] as Array).append(mmi)
		else:
			(out["near"] as Array).append(mmi)
	return out


## Small chunks have no visibility range of their own; the near state of a layer follows the rule
## the 48-tile chunks had (the camera within TREE_NEAR of the centre of the 48-tile cell's trees),
## for cameras across and above the map.
func _check_lod(small: CityView, big: CityView) -> void:
	var lod: OrbitTreeLod = small._orbit_lod
	K.check(fails, lod != null, "flag on: the Planner's trees have a LOD")
	K.check(fails, big._orbit_lod == null, "flag off: no LOD object, the engine's ranges do it")
	if lod == null:
		return
	K.check(fails, lod.near_end == 120.0, "the full trees reach 120 from a cell's centre")
	var ranged := 0
	for c: Vector3i in small._tree_chunks.keys():
		for layer: Variant in small._tree_chunks[c]:
			var m := layer as MultiMeshInstance3D
			if m.visibility_range_begin != 0.0 or m.visibility_range_end != 0.0:
				ranged += 1
	K.check(
		fails, ranged == 0, "no layer of a small chunk carries a range of its own (%d)" % ranged
	)
	var old_near: MultiMeshInstance3D = null
	for bc: Vector3i in big._tree_chunks.keys():
		old_near = _old_near_layer(big, bc)
		if old_near != null:
			break
	K.check(
		fails,
		old_near != null and old_near.visibility_range_end == 120.0,
		"flag off: the near layers keep their 120 range (the rule to match)"
	)
	_check_lod_sweep(small, big, lod)
	_check_lod_line(small, lod)


## The layer of a 48-tile chunk (flag off) that draws the full trees (null when it has none).
func _old_near_layer(big: CityView, big_c: Vector3i) -> MultiMeshInstance3D:
	for l: Variant in big._tree_chunks.get(big_c, []):
		if (l as MultiMeshInstance3D).visibility_range_begin == 0.0:
			return l as MultiMeshInstance3D
	return null


## Cameras across the map and above it: every layer of every small chunk is where the old layer of
## its 48-tile cell is, near for the cameras within 120 of that cell's centre. Counts the chunks
## seen near and far, and the ones a per-chunk rule would have put on the other side.
func _check_lod_sweep(small: CityView, big: CityView, lod: OrbitTreeLod) -> void:
	var mid := Vector3(D.X0 + D.W * 0.5, 40.0, D.Y0 + D.H * 0.5)
	var cams: Array[Vector3] = [
		mid,
		mid + Vector3(0, 60, 0),
		Vector3(D.X0, 30.0, D.Y0),
		Vector3(D.X0 + D.W, 30.0, D.Y0 + D.H),
		Vector3(D.X0 - 150.0, 30.0, D.Y0 + 10.0),
		Vector3(D.X0 + 10.0, 200.0, D.Y0 - 300.0),
		Vector3(D.X0 + D.W - 20.0, 20.0, D.Y0 + 25.0),
		mid + Vector3(90.0, 10.0, -70.0),
	]
	var seen := {"near": 0, "far": 0, "differs": 0, "wrong": 0, "boxed": 0}
	for cam in cams:
		lod.update(cam)
		for c: Vector3i in small._tree_chunks.keys():
			var cell := OrbitTreeLod.cell_of(c, CityView.TREE_CHUNK_ORBIT)
			var old_layer := _old_near_layer(big, Vector3i(cell.x, cell.y, 0))
			if old_layer == null:
				continue
			# What the engine measured: the centre of the box the cell's trees fill (its AABB).
			var centre := _old_centre(big, Vector3i(cell.x, cell.y, 0), lod, cell)
			if centre.distance_to(old_layer.position) > 1.0:
				seen["boxed"] += 1
			var d := cam.distance_to(centre)
			if absf(d - 120.0) <= lod.margin + 0.5:
				continue
			_sweep_chunk(small, c, cam, d < 120.0, seen)
	K.check(
		fails,
		int(seen["wrong"]) == 0,
		"every layer takes its cell's near/far state, the old rule (%d wrong)" % int(seen["wrong"])
	)
	K.check(
		fails,
		int(seen["near"]) > 0 and int(seen["far"]) > 0,
		"the sweep sees both near (%d) and far (%d) chunks" % [int(seen["near"]), int(seen["far"])]
	)
	K.check(
		fails,
		int(seen["boxed"]) > 0,
		"the box's centre is not the mean of the trees in some cells (%d)" % int(seen["boxed"])
	)
	K.check(
		fails,
		int(seen["differs"]) > 0,
		(
			"some chunks are on the other side of the line than their own centre says (%d)"
			% int(seen["differs"])
		)
	)


## The centre of the AABB the old 48-tile chunk's layers had: the box of the trees' origins in x
## and z (read from the pure spot function), and the LOD's own height (the tree models' mid height).
func _old_centre(big: CityView, big_c: Vector3i, lod: OrbitTreeLod, cell: Vector2i) -> Vector3:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for kit: Array in big._tree_chunk_spots(big_c):
		for t: Transform3D in kit:
			lo = Vector2(minf(lo.x, t.origin.x), minf(lo.y, t.origin.z))
			hi = Vector2(maxf(hi.x, t.origin.x), maxf(hi.y, t.origin.z))
	var mid := lod.centre_of(lod._cells[cell])
	return Vector3((lo.x + hi.x) * 0.5, mid.y, (lo.y + hi.y) * 0.5)


func _sweep_chunk(
	small: CityView, c: Vector3i, cam: Vector3, want_near: bool, seen: Dictionary
) -> void:
	var kinds := _kinds(small, c)
	for l: Variant in kinds["near"]:
		if (l as MultiMeshInstance3D).visible != want_near:
			seen["wrong"] += 1
	for l: Variant in kinds["far"]:
		if (l as MultiMeshInstance3D).visible == want_near:
			seen["wrong"] += 1
	seen["near" if want_near else "far"] += 1
	var own := kinds["near"] as Array
	if not own.is_empty():
		if (cam.distance_to((own[0] as Node3D).position) < 120.0) != want_near:
			seen["differs"] += 1


## Standing on a cell's centre it is near and far away it is far (a changed TREE_NEAR fails), with a
## margin of hysteresis around the line each way.
func _check_lod_line(small: CityView, lod: OrbitTreeLod) -> void:
	var some: Vector3i = small._tree_chunks.keys()[0]
	var tiles := CityView.TREE_CHUNK_ORBIT
	var cell_key := OrbitTreeLod.cell_of(some, tiles)
	var centre: Vector3 = lod.centre_of(lod._cells[cell_key])
	lod.update(centre)
	K.check(fails, lod.is_near(some, tiles), "on the cell's centre its trees are near")
	lod.update(centre + Vector3(0, 400.0, 0))
	K.check(fails, not lod.is_near(some, tiles), "400 above it they are far")
	lod.update(centre + Vector3(0, 117.0, 0))
	K.check(fails, not lod.is_near(some, tiles), "117 away, coming in, still far (hysteresis)")
	lod.update(centre + Vector3(0, 100.0, 0))
	lod.update(centre + Vector3(0, 123.0, 0))
	K.check(fails, lod.is_near(some, tiles), "123 away, going out, still near (hysteresis)")


## The LOD follows the viewport's current camera (the one the engine measures from), not the
## view's `camera` field, which can still be the street's camera after a return to the Planner.
func _check_lod_camera(small: CityView) -> void:
	var lod: OrbitTreeLod = small._orbit_lod
	var some: Vector3i = small._tree_chunks.keys()[0]
	var tiles := CityView.TREE_CHUNK_ORBIT
	var centre: Vector3 = lod.centre_of(lod._cells[OrbitTreeLod.cell_of(some, tiles)])
	var street_cam := Camera3D.new()
	holder.add_child(street_cam)
	street_cam.global_position = centre
	var planner_cam := Camera3D.new()
	holder.add_child(planner_cam)
	planner_cam.global_position = centre + Vector3(0, 500.0, 0)
	planner_cam.make_current()
	small.camera = street_cam
	small._update_orbit_lod()
	K.check(
		fails,
		not lod.is_near(some, tiles),
		"the trees go by the camera that draws (500 away), not the view's own field (on them)"
	)
	street_cam.make_current()
	small._update_orbit_lod()
	K.check(fails, lod.is_near(some, tiles), "and by the street's when that is the one drawing")
	planner_cam.free()
	street_cam.free()


## A chunk replanted (a forest tile changed) takes the state of its cell, and a freed one leaves it.
func _check_lod_refresh(small: CityView) -> void:
	var lod: OrbitTreeLod = small._orbit_lod
	if lod == null:
		return
	var c: Vector3i = small._tree_chunks.keys()[0]
	var cell_key := OrbitTreeLod.cell_of(c, CityView.TREE_CHUNK_ORBIT)
	var centre: Vector3 = lod.centre_of(lod._cells[cell_key])
	lod.update(centre)
	small._refresh_tree_chunk(c)
	var kinds := _kinds(small, c)
	var ok := not (kinds["near"] as Array).is_empty()
	for l: Variant in kinds["near"]:
		ok = ok and (l as MultiMeshInstance3D).visible
	for l: Variant in kinds["far"]:
		ok = ok and not (l as MultiMeshInstance3D).visible
	K.check(fails, ok, "a replanted chunk in a near cell draws its full trees and no stand-ins")
	lod.update(centre + Vector3(0, 400.0, 0))
	small._refresh_tree_chunk(c)
	kinds = _kinds(small, c)
	ok = true
	for l: Variant in kinds["near"]:
		ok = ok and not (l as MultiMeshInstance3D).visible
	for l: Variant in kinds["far"]:
		ok = ok and (l as MultiMeshInstance3D).visible
	K.check(fails, ok, "and in a far cell the stand-ins")
	var cells := lod.cell_count()
	small._free_tree_chunk(c)
	K.check(fails, lod.cell_count() <= cells, "a freed chunk leaves the LOD")
	K.check(fails, not lod._chunk_cell.has(c), "and is forgotten by it")
