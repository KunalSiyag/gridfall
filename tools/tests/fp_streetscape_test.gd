extends SceneTree
## Slice G1 acceptance (docs/fp/slices/G1-streetscape.md): the orbit -> street-level mode switch,
## building scale and street-facing yaws, the ground / water / curb datum, street furniture with its
## colliders, poster slots and street-name signs, road decals, vacant lots, the budgeted rebuild
## queue, tree layers, the light profile, sky and weather hooks, the construction kit scale and the
## texture imports.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const STREET := preload("res://scripts/fp/street/street_dressing.gd")

var fails: Array[String] = []
var _built_log: Array[int] = []
var _built_cols: Dictionary = {}


## Stands in for E's traffic feature: a pole marker at the NE corner of every cross tile.
class PoleStub:
	extends Node3D
	var view: CityView

	func light_pole(i: int, corner: int) -> Node3D:
		if corner != 0:
			return null
		var n := get_node_or_null("P%d" % i) as Node3D
		if n == null:
			n = Node3D.new()
			n.name = "P%d" % i
			add_child(n)
			n.global_position = Vector3(D.tx(i) + 0.4, WS.SIDEWALK_TOP, D.ty(i) - 0.4)
		return n


func _init() -> void:
	await process_frame
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "render": true, "player": false, "hud": false})
	var view := ctx.view
	var sim := ctx.sim
	K.check(fails, view != null and not view.fp_mode, "make_ctx built the view in orbit")
	_check_orbit_queue(view, sim)
	_check_mode_switch(view)
	_check_scale(view, sim)
	_check_orientation(view, sim)
	_check_ground(view, sim)
	_check_furniture(view, sim)
	_check_signs_with_poles(view, sim)
	_check_lots(view, sim)
	_check_trees(view)
	await _check_queue(view, sim)
	_check_imports()
	K.finish(self, "FP_STREETSCAPE_TEST", fails)


# ------------------------------------------------------------------ mode switch

func _check_mode_switch(view: CityView) -> void:
	var rebuilt := [0]
	var changed := [0]
	view.world_rebuilt.connect(func() -> void: rebuilt[0] += 1)
	view.fp_mode_changed.connect(func(_on: bool) -> void: changed[0] += 1)
	view.tile_built.connect(_on_built.bind(view))
	var t0 := Time.get_ticks_msec()
	view.set_fp_mode(true)
	print("  info set_fp_mode(true) rebuild took %d ms" % (Time.get_ticks_msec() - t0))
	K.check(fails, rebuilt[0] == 1 and changed[0] == 1, "set_fp_mode(true) emits world_rebuilt once and fp_mode_changed once (%d, %d)" % [rebuilt[0], changed[0]])
	var n0 := _built_log.size()
	view.set_fp_mode(true)
	K.check(fails, rebuilt[0] == 1 and changed[0] == 1 and _built_log.size() == n0, "set_fp_mode(true) again rebuilds nothing")
	var near_layers := 0
	for c: Vector3i in view._tree_chunks.keys():
		if c.z == 0:
			near_layers = -1000
		elif c.z == 1:
			near_layers += 1
	K.check(fails, near_layers > 0, "tree chunks are in their FP layers after the switch")


func _on_built(i: int, holder: Node3D, view: CityView) -> void:
	_built_log.append(i)
	if view.fp_mode and view.sim.kind[i] == D.ROAD:
		_built_cols[i] = (holder.get_meta("colliders", []) as Array).size()


# ------------------------------------------------------------------ scale, yaw, ground

func _check_scale(view: CityView, sim: CitySim) -> void:
	var n := 0
	var bad := []
	for i in sim.active:
		var holder := view.tile_holder(i)
		if not D.is_zone(sim.kind[i]) or holder == null or not str(holder.get_meta("building_path", "")).begins_with(CityView.R):
			continue
		var b := view.building_aabb(i)
		n += 1
		if b.size.x < 0.86 or b.size.x > 0.95 or b.size.z < 0.86 or b.size.z > 0.95:
			bad.append([i, b.size])
	K.check(fails, n > 0 and bad.is_empty(), "every real zone building is 0.86-0.95 u across (%d checked, bad %s)" % [n, str(bad.slice(0, 3))])


func _check_orientation(view: CityView, sim: CitySim) -> void:
	var n := 0
	var bad := []
	for i in sim.active:
		var k := sim.kind[i]
		var holder := view.tile_holder(i)
		if not (D.is_zone(k) or D.is_service(k)) or holder == null or not holder.has_meta("building_xform"):
			continue
		var fy := view.directory.frontage_yaw(i)
		if is_nan(fy):
			continue
		n += 1
		var have := rad_to_deg((holder.get_meta("building_xform") as Transform3D).basis.get_euler().y)
		if absf(angle_difference(deg_to_rad(have), deg_to_rad(fy))) > deg_to_rad(0.5):
			bad.append([i, have, fy])
	K.check(fails, n >= 10 and bad.is_empty(), "every lot with a frontage faces it (%d checked, bad %s)" % [n, str(bad.slice(0, 3))])


func _check_ground(view: CityView, sim: CitySim) -> void:
	var water := 0
	for i in range(D.W * D.H):
		if sim.terrain[i] == D.WATER:
			water += 1
	K.check(fails, water > 0, "the city has water tiles (%d)" % water)
	var on_water := 0
	var ys := {}
	for g: MeshInstance3D in view._ground_chunks:
		var arr := g.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for t in range(0, v.size(), 3):
			ys[snappedf(v[t].y, 0.0001)] = true
			# Every quad is a run of whole land tiles: test the centre of each tile it covers.
			var lo := Vector2(minf(v[t].x, minf(v[t + 1].x, v[t + 2].x)), minf(v[t].z, minf(v[t + 1].z, v[t + 2].z)))
			var hi := Vector2(maxf(v[t].x, maxf(v[t + 1].x, v[t + 2].x)), maxf(v[t].z, maxf(v[t + 1].z, v[t + 2].z)))
			for x in range(ceili(lo.x), floori(hi.x) + 1):
				for y in range(ceili(lo.y), floori(hi.y) + 1):
					if D.in_bounds(x, y) and sim.terrain[D.idx(x, y)] == D.WATER:
						on_water += 1
	K.check(fails, not view._ground_chunks.is_empty() and on_water == 0, "no ground triangle covers a water tile (%d)" % on_water)
	K.check(fails, ys.size() == 1 and ys.has(snappedf(WS.GROUND_Y, 0.0001)), "the ground lies at GROUND_Y (%s)" % str(ys.keys()))
	var wv: PackedVector3Array = view._water_node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	K.check(fails, wv.size() > 0 and is_equal_approx(wv[0].y, WS.WATER_Y) and WS.WATER_Y < WS.GROUND_Y, "water at WATER_Y below the ground")
	K.check(fails, WS.SIDEWALK_TOP - WS.GROUND_Y <= WS.STEP_HEIGHT + 1e-6, "sidewalk to ground is one step")
	K.check(fails, absf(WS.LOT_TOP - WS.GROUND_Y) <= 0.005, "lot slab top within 10 cm of the ground")
	var bv: PackedVector3Array = view._bed_node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var lo_y := 1.0
	for p in bv:
		lo_y = minf(lo_y, p.y)
	K.check(fails, is_equal_approx(lo_y, WS.RIVERBED_Y) and WS.RIVERBED_Y < WS.WATER_Y, "the riverbed reaches RIVERBED_Y under the water")


# ------------------------------------------------------------------ furniture

func _check_furniture(view: CityView, sim: CitySim) -> void:
	var roads := 0
	var furnished := 0
	var props := 0
	var batched := 0
	var on_road := []
	var in_band := []
	var missing_cols := []
	var late_cols := []
	var no_prop_meta := []
	var tees := 0
	var bad_tee := []
	var crosses := 0
	var bad_cross := []
	var decal_bad := []
	var decals := 0
	for i in sim.active:
		if sim.kind[i] != D.ROAD:
			continue
		var holder := view.tile_holder(i)
		if holder == null:
			continue
		roads += 1
		var mask := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		var straight := mask == RoadTopology.NS or mask == RoadTopology.EW
		var cols: Array = holder.get_meta("colliders", [])
		var n_items := view._street.placements(i).size()
		batched += n_items
		var roots := 0
		for c in holder.get_children():
			if c.has_meta("prop"):
				roots += 1
				props += 1
				var p := (c as Node3D).position
				if RoadTopology.is_carriageway(mask, Vector2(p.x, p.z)) and not RoadTopology.is_bridge(sim, i):
					on_road.append([i, c.name, p])
				if straight and _in_ped_band(mask, p):
					in_band.append([i, c.name, p])
			elif c is Node3D and c.name.begins_with("BusShelter"):
				no_prop_meta.append(i)
		for e: Dictionary in cols:
			var p: Vector3 = e["pos"]
			if RoadTopology.is_carriageway(mask, Vector2(p.x, p.z)) and not RoadTopology.is_bridge(sim, i):
				on_road.append([i, e.get("kind", "?"), p])
			if straight and _in_ped_band(mask, p):
				in_band.append([i, e.get("kind", "?"), p])
		for e2: Array in view._street.placements(i):
			var lp: Vector3 = (e2[1] as Transform3D).origin - Vector3(D.tx(i), 0, D.ty(i))
			if RoadTopology.is_carriageway(mask, Vector2(lp.x, lp.z)) and not RoadTopology.is_bridge(sim, i):
				on_road.append([i, e2[0], lp])
			if straight and _in_ped_band(mask, lp):
				in_band.append([i, e2[0], lp])
		# Every batched item but tree grates and kerb ramps (walkable) has a collider.
		var solid := 0
		for e3: Array in view._street.placements(i):
			if not str(e3[0]) in ["pit", "ramp"]:
				solid += 1
		if n_items + roots > 0:
			furnished += 1
			if cols.size() < solid:
				missing_cols.append([i, cols.size(), solid])
			if int(_built_cols.get(i, -1)) != cols.size():
				late_cols.append([i, _built_cols.get(i, -1), cols.size()])
		var signs := holder.find_children("StreetSign", "", false, false)
		var piece := RoadTopology.piece(mask)
		if str(piece[0]) == "tee":
			tees += 1
			if signs.size() != 1 or not _blades_ok(view, i, holder):
				bad_tee.append(i)
		elif str(piece[0]) == "cross":
			crosses += 1
			if signs.size() != 1 or (signs[0] as Node3D).position.distance_to(Vector3(0.345, WS.SIDEWALK_TOP, -0.345)) > 0.01 or not _blades_ok(view, i, holder):
				bad_cross.append(i)
		var nd := 0
		for c2 in holder.get_children():
			if c2 is Decal:
				nd += 1
				decals += 1
				if not (c2 as Decal).distance_fade_enabled:
					decal_bad.append(i)
		if nd > 3:
			decal_bad.append(i)
	K.check(fails, roads > 20 and furnished > 10 and batched > 20, "road sidewalks are furnished (%d of %d roads, %d batched items, %d prop roots)" % [furnished, roads, batched, props])
	K.check(fails, on_road.is_empty(), "no furniture on the carriageway %s" % str(on_road.slice(0, 4)))
	K.check(fails, in_band.is_empty(), "no furniture in the pedestrian band %s" % str(in_band.slice(0, 4)))
	K.check(fails, missing_cols.is_empty(), "every furniture item has a collider entry %s" % str(missing_cols.slice(0, 4)))
	K.check(fails, late_cols.is_empty(), "colliders are complete when tile_built fires %s" % str(late_cols.slice(0, 4)))
	K.check(fails, no_prop_meta.is_empty(), "every prop root has prop meta %s" % str(no_prop_meta.slice(0, 4)))
	K.check(fails, tees > 0 and bad_tee.is_empty(), "every tee has one street sign with the directory names (%d tees, bad %s)" % [tees, str(bad_tee.slice(0, 4))])
	K.check(fails, bad_cross.is_empty(), "every cross tile has one G1 sign pole at NE without a traffic feature (%d, bad %s)" % [crosses, str(bad_cross.slice(0, 4))])
	K.check(fails, decals > 0 and decal_bad.is_empty(), "road decals fade with distance, at most 3 per tile (%d decals, bad %s)" % [decals, str(decal_bad.slice(0, 4))])
	var slots_bad := []
	var boards := 0
	var stops_bad := []
	for i: int in view.bus_stops.keys():
		if not (view.bus_stops[i] is Vector2i):
			stops_bad.append(i)
	for i in sim.active:
		var holder := view.tile_holder(i)
		if holder == null:
			continue
		for c in holder.find_children("*", "Node3D", true, false):
			var nm := str(c.name)
			if nm.begins_with("Billboard") or nm.begins_with("BusShelter") or nm.begins_with("LeaseBoard"):
				boards += 1
				var slot: Dictionary = c.get_meta("poster_slot", {})
				if not (slot.has("kind") and slot.has("size") and slot.has("xform")):
					slots_bad.append([i, nm])
	K.check(fails, boards > 0 and slots_bad.is_empty(), "billboards, shelters and lease boards carry poster_slot meta (%d, bad %s)" % [boards, str(slots_bad.slice(0, 3))])
	K.check(fails, stops_bad.is_empty(), "every bus_stops value is a Vector2i side")
	var depth_bad := 0
	for lbl in view.find_children("*", "Label3D", true, false):
		if lbl.has_meta("sign_text") and (lbl as Label3D).no_depth_test:
			depth_bad += 1
	K.check(fails, depth_bad == 0, "no street-sign label ignores depth")


func _in_ped_band(mask: int, p: Vector3) -> bool:
	var across := absf(p.x) if mask == RoadTopology.NS else absf(p.z)
	return across > WS.PED_BAND[0] + 1e-4 and across < WS.PED_BAND[1] - 1e-4


## The blades under holder read the junction's two street names.
func _blades_ok(view: CityView, i: int, holder: Node3D) -> bool:
	var want := Array(view.directory.intersection_name(i).split(" & "))
	var got := {}
	for lbl in holder.find_children("*", "Label3D", true, false):
		if lbl.has_meta("sign_text"):
			got[(lbl as Label3D).text] = true
	want.sort()
	var have := got.keys()
	have.sort()
	return want == have


func _check_signs_with_poles(view: CityView, sim: CitySim) -> void:
	var stub := PoleStub.new()
	stub.name = "PoleStub"
	stub.view = view
	get_root().add_child(stub)
	view.light_pole_source = stub
	var crosses := 0
	var bad := []
	for i in sim.active:
		if sim.kind[i] == D.ROAD and str(RoadTopology.piece(RoadTopology.mask(sim, D.tx(i), D.ty(i)))[0]) == "cross":
			view._build_tile(i, false)
			var holder := view.tile_holder(i)
			crosses += 1
			if not holder.find_children("StreetSign", "", false, false).is_empty() or not _blades_ok(view, i, holder):
				bad.append(i)
	view._street.flush()
	view.light_pole_source = null
	K.check(fails, crosses > 0 and bad.is_empty(), "cross tiles hang their blades on the traffic feature's NE pole (%d, bad %s)" % [crosses, str(bad)])
	stub.queue_free()


# ------------------------------------------------------------------ lots

func _check_lots(view: CityView, sim: CitySim) -> void:
	var vacant := 0
	var glowing := []
	var posts := []
	for i in sim.active:
		if not D.is_zone(sim.kind[i]) or sim.level[i] > 0 or sim.sites.has(i):
			continue
		var holder := view.tile_holder(i)
		if holder == null:
			continue
		vacant += 1
		for m: Material in _materials(holder):
			if m is BaseMaterial3D and (m as BaseMaterial3D).emission_enabled:
				glowing.append(i)
				break
		if holder.find_children("VacantLot", "", false, false).is_empty():
			posts.append(i)
	K.check(fails, vacant > 0 and glowing.is_empty(), "no vacant lot glows on foot (%d lots, bad %s)" % [vacant, str(glowing.slice(0, 4))])
	K.check(fails, posts.is_empty(), "vacant lots show rough ground on foot %s" % str(posts.slice(0, 4)))


func _materials(n: Node) -> Array:
	var out: Array = []
	for c in n.find_children("*", "GeometryInstance3D", true, false):
		var g := c as GeometryInstance3D
		if g.material_override != null:
			out.append(g.material_override)
		if g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
			var mi := g as MeshInstance3D
			for s in range(mi.mesh.get_surface_count()):
				var m := mi.get_active_material(s)
				if m != null:
					out.append(m)
	return out


# ------------------------------------------------------------------ trees

func _check_trees(view: CityView) -> void:
	K.check(fails, view._tree_chunk_size(1) == 8, "FP near tree chunks are 8 tiles")
	var near_end := 0.0
	var far_end := []
	for c: Vector3i in view._tree_chunks.keys():
		for mmi: MultiMeshInstance3D in view._tree_chunks[c]:
			if not is_instance_valid(mmi):
				continue
			if c.z == 1:
				near_end = maxf(near_end, mmi.visibility_range_end)
			elif c.z == 2:
				far_end.append(mmi.visibility_range_end)
	K.check(fails, near_end > 0.0 and near_end <= 15.0, "near trees end by 15 u (%.1f)" % near_end)
	var far_ok := not far_end.is_empty()
	for e: float in far_end:
		far_ok = far_ok and absf(e - 50.0) < 1e-3
	K.check(fails, far_ok, "far tree stand-ins end at 50 u")


# ------------------------------------------------------------------ rebuild queue

func _check_orbit_queue(view: CityView, sim: CitySim) -> void:
	var picks := _pick_tiles(sim, 30, Vector3(1000, 0, 1000))
	var seen := {}
	var cb := func(i: int, _h: Node3D) -> void: seen[i] = true
	view.tile_built.connect(cb)
	view._on_tiles_changed(PackedInt32Array(picks))
	view.tile_built.disconnect(cb)
	var all := true
	for i: int in picks:
		all = all and seen.has(i)
	K.check(fails, all and view.rebuild_pending() == 0, "orbit rebuilds changed tiles synchronously")


func _check_queue(view: CityView, sim: CitySim) -> void:
	view.priority_point = Vector3(-70, 0, -70)
	var picks := _pick_tiles(sim, 120, view.priority_point)
	K.check(fails, picks.size() == 120, "120 built tiles to requeue")
	var counts := {}
	var order: Array[int] = []
	var cb := func(i: int, _h: Node3D) -> void:
		counts[i] = int(counts.get(i, 0)) + 1
		order.append(i)
	view.tile_built.connect(cb)
	view._on_tiles_changed(PackedInt32Array(picks))
	var queued := view._queue.keys()
	K.check(fails, counts.is_empty() and view.rebuild_pending() >= 120, "on foot changed tiles wait in the queue (%d)" % view.rebuild_pending())
	var nearest := -1
	var best := INF
	for i: int in queued:
		var d := Vector2(D.tx(i) - view.priority_point.x, D.ty(i) - view.priority_point.z).length()
		if d < best:
			best = d
			nearest = i
	view._process(1.0 / 60.0)
	var first := counts.size()
	K.check(fails, first > 0 and first < queued.size(), "one frame builds some but not all (%d of %d)" % [first, queued.size()])
	K.check(fails, not order.is_empty() and order[0] == nearest, "the nearest tile builds first")
	var frames := 1
	while view.rebuild_pending() > 0 and frames < 200:
		view._process(1.0 / 60.0)
		frames += 1
	var once := true
	for i: int in queued:
		once = once and int(counts.get(i, 0)) == 1
	K.check(fails, view.rebuild_pending() == 0 and once, "all %d build within 200 frames (%d), tile_built once each" % [queued.size(), frames])
	# Deferral: a tile beside the player and in view waits until the camera looks away.
	var t := picks[0]
	var cam := view.camera
	view.priority_point = Vector3(D.tx(t) + 0.6, 0.0, D.ty(t))
	cam.global_position = Vector3(D.tx(t) + 2.0, 0.08, D.ty(t))
	cam.look_at(Vector3(D.tx(t), 0.05, D.ty(t)))
	counts.clear()
	view._on_tiles_changed(PackedInt32Array([t]))
	for _k in range(120):
		view._process(1.0 / 60.0)
	var waited := not counts.has(t)
	K.check(fails, waited and view._in_view(t), "a tile beside the player in view waits (2 s)")
	cam.look_at(Vector3(D.tx(t) + 6.0, 0.05, D.ty(t)))
	view._process(1.0 / 60.0)
	K.check(fails, counts.has(t), "it builds once the camera looks away")
	cam.look_at(Vector3(D.tx(t), 0.05, D.ty(t)))
	counts.clear()
	view._on_tiles_changed(PackedInt32Array([t]))
	var f := 0
	while not counts.has(t) and f < 400:
		view._process(1.0 / 60.0)
		f += 1
	K.check(fails, counts.has(t) and f >= 299 and f <= 302, "a deferred tile builds after 5 s at most (%d frames)" % f)
	# flush_rebuild_queue builds the rest now.
	view.priority_point = Vector3(-70, 0, -70)
	counts.clear()
	view._on_tiles_changed(PackedInt32Array(picks.slice(0, 40)))
	var pending := view.rebuild_pending()
	view.flush_rebuild_queue()
	K.check(fails, view.rebuild_pending() == 0 and counts.size() == pending, "flush_rebuild_queue builds everything pending (%d)" % pending)
	view.tile_built.disconnect(cb)
	await process_frame


## n built tiles, at least 2 u from p.
func _pick_tiles(sim: CitySim, n: int, p: Vector3) -> Array[int]:
	var out: Array[int] = []
	for i in sim.active:
		if out.size() >= n:
			break
		var k := sim.kind[i]
		if k == D.EMPTY or k == D.FOREST:
			continue
		if Vector2(D.tx(i) - p.x, D.ty(i) - p.z).length() < 2.0:
			continue
		out.append(i)
	return out


# ------------------------------------------------------------------ imports

func _check_imports() -> void:
	var bad := []
	var files: Array[String] = []
	for dir: String in ["res://textures/real/", "res://textures/real/decals/", "res://env/"]:
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".import") and (dir != "res://env/" or f.ends_with(".hdr.import")):
				files.append(dir + f)
	for p in files:
		var cf := ConfigFile.new()
		if cf.load(p) != OK or cf.get_value("params", "mipmaps/generate", false) != true:
			bad.append(p.get_file())
	K.check(fails, files.size() >= 15 and bad.is_empty(), "texture and HDRI imports generate mipmaps (%d files, bad %s)" % [files.size(), str(bad)])
