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
const LP := preload("res://scripts/fp/street/light_profile.gd")
const WEATHER := preload("res://scripts/fp/street/weather.gd")

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
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "render": true, "hud": false})
	var view := ctx.view
	var sim := ctx.sim
	K.check(fails, view != null and not view.fp_mode, "make_ctx built the view in orbit")
	_check_orbit_queue(view, sim)
	_check_mode_switch(view)
	_check_scale(view, sim)
	_check_orientation(view, sim)
	_check_ground(view, sim)
	_check_furniture(view, sim)
	_check_near_fade(view)
	_check_signs_with_poles(view, sim)
	_check_lots(view, sim)
	_check_trees(view)
	_check_sites(view, sim)
	await _check_queue(view, sim)
	var f := K.make_feature(ctx, "streetscape")
	K.check(fails, f != null, "the streetscape feature sets up")
	if f != null:
		_check_profile(ctx)
		_check_sky_hooks(ctx, f)
		_check_weather(ctx, f)
		_check_lights(ctx, f)
		_check_feature_hooks(ctx, f)
		f.teardown()
		K.check(fails, ctx.env.fog_mode == Environment.FOG_MODE_EXPONENTIAL and ctx.env.sky.process_mode == Sky.PROCESS_MODE_REALTIME, "teardown restores the orbit profile")
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

## Batched props dither out right in front of the camera (a third-person camera backed into them),
## and so do street-tree leaves; flat kinds (aprons, pits, ramps) never fade.
func _check_near_fade(view: CityView) -> void:
	var bad := []
	for kind: String in ["bench", "bin", "bollard", "lamp", "tree", "apron"]:
		for part: Dictionary in view._street._kit(kind)["parts"]:
			var mats: Array = []
			if part.get("mat") != null:
				mats.append(part["mat"])
			else:
				var mesh := part["mesh"] as Mesh
				for k in range(mesh.get_surface_count()):
					mats.append(mesh.surface_get_material(k))
			for m: Variant in mats:
				var faded := false
				if m is BaseMaterial3D:
					faded = (m as BaseMaterial3D).distance_fade_mode == BaseMaterial3D.DISTANCE_FADE_PIXEL_DITHER and (m as BaseMaterial3D).distance_fade_max_distance > (m as BaseMaterial3D).distance_fade_min_distance
					faded = faded or m == view._lamp_material()
				elif m is ShaderMaterial:
					faded = ((m as ShaderMaterial).get_shader_parameter("near_fade") as Vector2).y > 0.0
				if faded == (kind == "apron"):
					bad.append([kind, str(m)])
	K.check(fails, bad.is_empty(), "props and leaves dither out near the camera, ground kinds do not %s" % str(bad.slice(0, 4)))


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
	var pool_bad := []
	var lamp_bad := []
	var straights := 0
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
		var pools := 0
		for c2 in holder.get_children():
			if c2 is Decal and c2.has_meta("light_pool"):
				pools += 1
				if not (c2 as Decal).distance_fade_enabled:
					pool_bad.append(i)
			elif c2 is Decal:
				nd += 1
				decals += 1
				if not (c2 as Decal).distance_fade_enabled:
					decal_bad.append(i)
		if nd > 3:
			decal_bad.append(i)
		# Unlit straights carry one batched lamp, with its bulb in the holder's `bulbs` meta and a
		# lamplight decal under it.
		var lamps := 0
		for e4: Array in view._street.placements(i):
			if str(e4[0]) == "lamp":
				lamps += 1
		var unlit := straight and not RoadTopology.is_bridge(sim, i) and holder.find_children("Bulb*", "", true, false).is_empty()
		if unlit:
			straights += 1
		if (unlit and lamps != 1) or lamps != (holder.get_meta("bulbs", []) as Array).size() or lamps != pools:
			lamp_bad.append([i, lamps, (holder.get_meta("bulbs", []) as Array).size(), pools])
	K.check(fails, roads > 20 and furnished > 10 and batched > 20, "road sidewalks are furnished (%d of %d roads, %d batched items, %d prop roots)" % [furnished, roads, batched, props])
	K.check(fails, on_road.is_empty(), "no furniture on the carriageway %s" % str(on_road.slice(0, 4)))
	K.check(fails, in_band.is_empty(), "no furniture in the pedestrian band %s" % str(in_band.slice(0, 4)))
	K.check(fails, missing_cols.is_empty(), "every furniture item has a collider entry %s" % str(missing_cols.slice(0, 4)))
	K.check(fails, late_cols.is_empty(), "colliders are complete when tile_built fires %s" % str(late_cols.slice(0, 4)))
	K.check(fails, no_prop_meta.is_empty(), "every prop root has prop meta %s" % str(no_prop_meta.slice(0, 4)))
	K.check(fails, tees > 0 and bad_tee.is_empty(), "every tee has one street sign with the directory names (%d tees, bad %s)" % [tees, str(bad_tee.slice(0, 4))])
	K.check(fails, bad_cross.is_empty(), "every cross tile has one G1 sign pole at NE without a traffic feature (%d, bad %s)" % [crosses, str(bad_cross.slice(0, 4))])
	K.check(fails, decals > 0 and decal_bad.is_empty(), "road decals fade with distance, at most 3 per tile (%d decals, bad %s)" % [decals, str(decal_bad.slice(0, 4))])
	K.check(fails, straights > 0 and lamp_bad.is_empty() and pool_bad.is_empty(), "unlit straights have a lamp with its bulb and a fading lamplight decal (%d, bad %s %s)" % [straights, str(lamp_bad.slice(0, 4)), str(pool_bad.slice(0, 4))])
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
	var crosses: Array[int] = []
	var bad := []
	for i in sim.active:
		if sim.kind[i] == D.ROAD and str(RoadTopology.piece(RoadTopology.mask(sim, D.tx(i), D.ty(i)))[0]) == "cross":
			view._build_tile(i, false)
			var holder := view.tile_holder(i)
			crosses.append(i)
			var pole := stub.light_pole(i, 0)
			if not _cross_signs_ok(view, i, holder, false) or _blades_at(holder).distance_to(holder.to_local(pole.global_position) + Vector3(0, STREET.E_BLADE_Y, 0)) > 0.002:
				bad.append(i)
	view._street.flush()
	K.check(fails, not crosses.is_empty() and bad.is_empty(), "cross tiles hang their blades on the traffic feature's NE pole (%d, bad %s)" % [crosses.size(), str(bad)])
	# Tiles built before the traffic feature existed (boot) are re-hung when it appears, and get
	# G1's own pole back when it goes; the colliders meta follows.
	var back := []
	view.set_light_pole_source(null)
	for i: int in crosses:
		if not _cross_signs_ok(view, i, view.tile_holder(i), true):
			back.append(i)
	var hung := []
	view.set_light_pole_source(stub)
	for i: int in crosses:
		if not _cross_signs_ok(view, i, view.tile_holder(i), false):
			hung.append(i)
	view.set_light_pole_source(null)
	K.check(fails, back.is_empty() and hung.is_empty(), "cross-tile signs follow the traffic feature coming and going (own pole bad %s, hung bad %s)" % [str(back.slice(0, 4)), str(hung.slice(0, 4))])
	stub.queue_free()


## One set of blades with the junction's names on the cross holder; with own_pole one G1 pole at the
## NE corner and its collider, else neither.
func _cross_signs_ok(view: CityView, i: int, holder: Node3D, own_pole: bool) -> bool:
	var signs := holder.find_children("StreetSign", "", false, false)
	var marked := 0
	for c in holder.get_children():
		if c.has_meta("street_sign"):
			marked += 1
	var sign_cols := 0
	for e: Dictionary in holder.get_meta("colliders", []):
		if str(e.get("kind", "")) == "sign":
			sign_cols += 1
	if marked != 1 or not _blades_ok(view, i, holder):
		return false
	if own_pole:
		return signs.size() == 1 and sign_cols == 1 and (signs[0] as Node3D).position.is_equal_approx(STREET.OWN_POLE)
	return signs.is_empty() and sign_cols == 0


## Holder-local position of the cross tile's blades root.
func _blades_at(holder: Node3D) -> Vector3:
	for c in holder.get_children():
		if c.has_meta("street_sign") and c.name == &"Blades":
			return (c as Node3D).position
	return Vector3.INF


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
			if not is_instance_valid(mmi) or c.z != 1:
				continue
			if mmi.visibility_range_begin <= 0.0:
				near_end = maxf(near_end, mmi.visibility_range_end)
			else:
				far_end.append(mmi.visibility_range_end)
	K.check(fails, near_end > 0.0 and near_end <= 15.0, "near trees end by 15 u (%.1f)" % near_end)
	var far_ok := not far_end.is_empty()
	for e: float in far_end:
		far_ok = far_ok and absf(e - 50.0) < 1e-3
	K.check(fails, far_ok, "far tree stand-ins end at 50 u")
	# Leaf cards are recentred: every card spans exactly uv_offset .. uv_offset + 1, so the round
	# leaf cluster sits whole in the middle of the card instead of being cut at its corners.
	var cards := 0
	var bad := []
	for c: Vector3i in view._tree_chunks.keys():
		for mmi: MultiMeshInstance3D in view._tree_chunks[c]:
			if not is_instance_valid(mmi) or c.z != 1 or not (mmi.material_override is ShaderMaterial):
				continue
			var sm := mmi.material_override as ShaderMaterial
			if sm.get_shader_parameter("uv_offset") == null:
				continue
			var off: Vector2 = sm.get_shader_parameter("uv_offset")
			var arr := mmi.multimesh.mesh.surface_get_arrays(0)
			var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			for t in range(0, mini(idx.size(), 60), 3):
				var lo := Vector2(INF, INF)
				var hi := -lo
				for k in range(3):
					var q := uv[idx[t + k]] - off
					lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
					hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
				cards += 1
				if lo.length() > 1e-3 or (hi - Vector2.ONE).length() > 1e-3:
					bad.append([str(lo), str(hi)])
	K.check(fails, cards > 0 and bad.is_empty(), "near leaf cards are recentred (%d checked, bad %s)" % [cards, str(bad.slice(0, 3))])
	var hedges := 0
	var flat := 0
	var where := []
	for h: Node in view.get_node("Tiles").get_children():
		if h.is_queued_for_deletion():
			continue
		for n in h.find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi.mesh == null:
				continue
			for k in range(mi.mesh.get_surface_count()):
				var m := mi.mesh.surface_get_material(k)
				if m != null and m.resource_name == "Hedge_Core":
					hedges += 1
					if mi.get_active_material(k) == m:
						flat += 1
						where.append(str(h.get_path_to(mi)))
	K.check(fails, flat == 0, "hedge cores are leafy on foot (%d of %d flat: %s)" % [flat, hedges, str(where.slice(0, 3))])


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


# ------------------------------------------------------------------ construction sites

func _check_sites(view: CityView, sim: CitySim) -> void:
	K.check(fails, is_equal_approx(ConstructionKit.MS, WS.MACHINE_SCALE), "construction machines at WS.MACHINE_SCALE")
	# The hoarding on foot: 2.2 m, solid, with D's poster slot on the frontage side (gate or not).
	var bad := []
	for front: Vector2i in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]:
		for h: int in [0, 1, 2, 3]:
			var root := Node3D.new()
			view.kit._fence(root, h, front)
			var segs := root.find_children("HoardingFront", "", true, false)
			var ok := segs.size() == 1
			if ok:
				var seg := segs[0] as MeshInstance3D
				var slot: Dictionary = seg.get_meta("poster_slot", {})
				var normal := ((slot.get("xform", Transform3D()) as Transform3D).basis * Vector3.BACK)
				ok = str(slot.get("kind", "")) == "hoarding" and Vector2(normal.x, normal.z).is_equal_approx(Vector2(front)) and seg.position.dot(Vector3(front.x, 0, front.y)) > 0.4
				ok = ok and is_equal_approx((seg.mesh as BoxMesh).size.y, 2.2 * WS.M)
			if not ok:
				bad.append([front, h])
			root.free()
	K.check(fails, bad.is_empty(), "the hoarding has a poster slot facing the frontage road %s" % str(bad))
	# Static site parts are merged per group and material (G2 measured about 1,050 site draws in one
	# street view): a 24 m frame with its crane and mixer stays within a few dozen surfaces, and its
	# floors still rise with progress.
	var holder := Node3D.new()
	get_root().add_child(holder)
	var s := {"type": "build", "plan": "build", "target_kind": D.ZONE_C}
	var site := view.kit.build_site(holder, s, "frame", 0.2, {"h": 7, "height": 1.2, "foot": Vector2(0.7, 0.7)})
	var surfaces := 0
	var merged := 0
	for n in site.find_children("*", "MeshInstance3D", true, false):
		surfaces += (n as MeshInstance3D).mesh.get_surface_count()
		if n.name == &"Merged":
			merged += 1
	var frame := site.get_node("Frame") as Node3D
	var low := _shown(frame)
	view.kit.update_site(holder, 1.0)
	var high := _shown(frame)
	var floors := frame.get_child_count()
	holder.free()
	K.check(fails, merged > 5 and surfaces <= 90 and low < high and high == floors, "a frame site draws %d surfaces (%d merged meshes), floors rise %d -> %d of %d" % [surfaces, merged, low, high, floors])


func _shown(frame: Node3D) -> int:
	var n := 0
	for c in frame.get_children():
		if (c as Node3D).visible:
			n += 1
	return n


# ------------------------------------------------------------------ light profile, sky, weather

func _check_profile(ctx: FpContext) -> void:
	var env := ctx.env
	var sun := ctx.sun
	K.check(fails, env.sky.process_mode == Sky.PROCESS_MODE_INCREMENTAL, "the sky updates incrementally on foot")
	LP.apply(env, sun, "fp", "medium")
	K.check(fails, is_equal_approx(env.ssao_radius, WS.SSAO_RADIUS) and is_equal_approx(env.ssil_radius, WS.SSIL_RADIUS), "SSAO and SSIL radii in metres")
	K.check(fails, env.fog_mode == Environment.FOG_MODE_DEPTH and is_equal_approx(env.fog_density, 1.0), "depth fog at full density")
	K.check(fails, is_equal_approx(sun.directional_shadow_max_distance, WS.SHADOW_MAX_DIST), "sun shadows end at SHADOW_MAX_DIST")
	for preset: String in ["low", "medium", "high"]:
		var far := LP.camera_far(preset)
		K.check(fails, LP.fog_end(preset) < far, "%s fog ends inside the far plane (%.2f < %.1f)" % [preset, LP.fog_end(preset), far])
	LP.apply(env, sun, "fp", "high")
	K.check(fails, env.volumetric_fog_enabled and is_equal_approx(sun.directional_shadow_max_distance, 16.0), "high adds volumetric fog and 16 u shadows")
	LP.apply(env, sun, "fp", "low")
	K.check(fails, not env.ssil_enabled and not env.volumetric_fog_enabled, "low drops SSIL and volumetric fog")
	# Orbit restores every owned key: env keys against a fresh load of the .tres, sun keys against
	# main.tscn's Sun (defaults for keys it leaves unset), the sky against SkyDirector's own sky.
	LP.apply(env, sun, "orbit", "low")
	var tres := ResourceLoader.load("res://scenes/main-environment.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as Environment
	var bad := []
	for k: String in LP.ENV_KEYS:
		if not _same(env.get(k), tres.get(k)):
			bad.append([k, env.get(k), tres.get(k)])
	var ref := _main_sun()
	for k: String in LP.SUN_KEYS:
		if not _same(sun.get(k), ref.get(k)):
			bad.append([k, sun.get(k), ref.get(k)])
	ref.free()
	if env.sky.process_mode != Sky.PROCESS_MODE_REALTIME or env.sky.radiance_size != Sky.RADIANCE_SIZE_256:
		bad.append(["sky", env.sky.process_mode, env.sky.radiance_size])
	K.check(fails, bad.is_empty(), "orbit restores every key the profile owns %s" % str(bad))
	LP.apply(env, sun, "fp", "medium")


func _same(a: Variant, b: Variant) -> bool:
	if a is float or b is float:
		return absf(float(a) - float(b)) < 1e-5
	return a == b


## A DirectionalLight3D with main.tscn's Sun properties (read from the scene state, not instanced).
func _main_sun() -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	var st := (load("res://scenes/main.tscn") as PackedScene).get_state()
	for n in range(st.get_node_count()):
		if str(st.get_node_name(n)) != "Sun":
			continue
		for k in range(st.get_node_property_count(n)):
			sun.set(st.get_node_property_name(n, k), st.get_node_property_value(n, k))
	return sun


func _check_sky_hooks(ctx: FpContext, f: FpFeature) -> void:
	var sky := ctx.sky
	var weather: Node = f.get("weather")
	weather.set_process(false)
	sky.reset_weather()
	sky.fixed_hour = 12.0
	sky.hour = 12.0
	sky.weather_energy_mult = 1.0
	sky._apply(1.0)
	var clear := ctx.sun.light_energy
	sky.weather_energy_mult = 0.55
	sky._apply(1.0)
	K.check(fails, clear > 0.1 and is_equal_approx(ctx.sun.light_energy, clear * 0.55), "the weather energy multiplier survives SkyDirector's rewrite (%.3f vs %.3f)" % [ctx.sun.light_energy, clear])
	var begin := ctx.env.fog_depth_begin
	sky.fog_begin_override = 15.0
	sky._apply(1.0)
	var over := ctx.env.fog_depth_begin
	sky.fog_begin_override = -1.0
	sky._apply(1.0)
	K.check(fails, is_equal_approx(over, 15.0) and is_equal_approx(ctx.env.fog_depth_begin, begin), "the fog-begin override applies and lets go")
	var base_opacity := ctx.sun.shadow_opacity
	sky.weather_shadow_mult = 0.12
	sky._apply(1.0)
	var faint := ctx.sun.shadow_opacity
	sky.reset_weather()
	sky._apply(1.0)
	K.check(fails, is_equal_approx(faint, base_opacity * 0.12) and is_equal_approx(ctx.sun.shadow_opacity, base_opacity), "cloud cover fades sun shadows and lets go (%.3f of %.3f)" % [faint, base_opacity])
	weather.call("force", "rain")
	weather.call("step", 30.0)
	K.check(fails, float(sky.weather_shadow_mult) < 0.5, "rain fades the sun shadows (%.2f)" % float(sky.weather_shadow_mult))
	weather.call("clear_forced")
	sky.reset_weather()
	weather.set_process(true)


func _check_weather(ctx: FpContext, f: FpFeature) -> void:
	var same := true
	var counts := {"clear": 0, "overcast": 0, "rain": 0}
	for day in range(400):
		var s := WEATHER.daily_state(ctx.sim.city_seed, day)
		same = same and s == WEATHER.daily_state(ctx.sim.city_seed, day)
		counts[s] += 1
	K.check(fails, same and counts["clear"] > 200 and counts["overcast"] > 70 and counts["rain"] > 30, "the daily weather is deterministic, about 60/25/15 (%s)" % str(counts))
	var weather: Node = f.get("weather")
	weather.set_process(false)
	var speed := ctx.sim.speed
	ctx.sim.speed = 1
	var results: Array = []
	for day_s: float in [12.0, 1200.0]:
		ctx.sim.day_seconds = day_s
		f.call("force_weather", "rain")
		weather.set("wet", 0.0)
		for _k in range(60):
			weather.call("step", 1.0)
		var w60 := float(weather.get("wet"))
		for _k in range(60):
			weather.call("step", 1.0)
		results.append([w60, float(weather.get("wet"))])
	ctx.sim.day_seconds = 12.0
	ctx.sim.speed = speed
	var r: Array = results[0]
	K.check(fails, float(r[0]) < 0.6 and float(r[1]) > 0.9 and results[0] == results[1], "rain wets the streets over 120 s at 1x, whatever the day length (%s)" % str(results))
	K.check(fails, is_equal_approx(ctx.view.wetness, float(r[1])) and ctx.sky.weather_grey > 0.0, "wetness reaches the view and the sky turns grey")
	f.call("clear_forced_weather")
	K.check(fails, is_equal_approx(ctx.view.wetness, 0.0), "clearing the forced weather dries the streets")
	f.call("force_rain_for_photo")
	K.check(fails, is_equal_approx(ctx.view.wetness, 1.0) and str((f.call("to_dict") as Dictionary).get("weather")) == "rain", "force_rain_for_photo soaks the streets at once")
	f.call("clear_forced_weather")
	# A smog incident: a FogVolume over its radius on High only, gone with the incident.
	var ev := {"type": "smog", "x": 10, "y": 12, "radius": 3}
	ctx.sim.events.append(ev)
	weather.call("set_rain_amount", "medium")
	var on_medium := (weather.get("smog_volumes") as Dictionary).size()
	weather.call("set_rain_amount", "high")
	var vols: Dictionary = weather.get("smog_volumes")
	var fv: FogVolume = vols.values()[0] if vols.size() == 1 else null
	var placed := fv != null and fv.global_position.is_equal_approx(Vector3(10, WS.GROUND_Y + 10.0 * WS.M, 12)) and is_equal_approx(fv.size.x, 8.0)
	ctx.sim.events.erase(ev)
	weather.call("step", 0.1)
	var after := (weather.get("smog_volumes") as Dictionary).size()
	weather.call("set_rain_amount", "medium")
	K.check(fails, on_medium == 0 and placed and after == 0, "smog gets a FogVolume on High only, and loses it with the incident (%d, %s, %d)" % [on_medium, placed, after])
	weather.set_process(true)


func _check_lights(ctx: FpContext, f: FpFeature) -> void:
	var lights: Node = f.get("lights")
	# Stand on a lit straight at midnight.
	var spot := -1
	for i in ctx.sim.active:
		var h := ctx.view.tile_holder(i)
		if h != null and ctx.sim.kind[i] == D.ROAD and not h.find_children("Bulb*", "MeshInstance3D", true, false).is_empty():
			spot = i
			break
	K.check(fails, spot >= 0, "a road tile with lamps exists")
	if spot < 0:
		return
	ctx.player.teleport(Vector3(D.tx(spot) + 0.4, WS.SIDEWALK_TOP, D.ty(spot)), 0.0)
	ctx.view.night = 1.0
	lights.call("_process", 0.3)
	var lit := int(lights.call("lit_count"))
	K.check(fails, lit > 0 and lit <= 16, "street lights light the nearby lamps at night (%d)" % lit)
	for l: OmniLight3D in lights.get("pool"):
		if l.shadow_enabled:
			K.check(fails, false, "street lights cast no shadows")
			break
	ctx.view.night = 0.0
	lights.call("_process", 0.3)
	K.check(fails, int(lights.call("lit_count")) == 0, "street lights are off by day")


func _check_feature_hooks(ctx: FpContext, f: FpFeature) -> void:
	var st: Dictionary = f.self_test()
	K.check(fails, bool(st.get("ok", false)), "streetscape self_test: %s" % str(st.get("detail", "")))
	var names := []
	for s: Dictionary in f.photo_shots():
		names.append(str(s["name"]))
		if str(s["name"]) == "rain":
			K.check(fails, str(s.get("prepare", "")) == "force_rain_for_photo" and str(s.get("restore", "")) == "clear_forced_weather" and is_equal_approx(float(s["hour"]), 16.0), "the rain shot forces and clears the rain at 16:00")
	K.check(fails, "street_sign" in names and "rain" in names, "photo shots: street_sign and rain (%s)" % str(names))
	f._process(0.016)
	K.check(fails, ctx.view.priority_point.distance_to(ctx.player_position()) < 1e-4, "the feature feeds the player position to the rebuild queue")
	K.check(fails, (f.get("weather") as Node).get("push_global") == true, "the wetness global shader parameter exists on foot")


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
