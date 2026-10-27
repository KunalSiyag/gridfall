extends SceneTree
## Aerial coverage acceptance (split out of fp_renderperf_test.gd, which crossed the 1000-line
## lint limit): once the camera is over the city, roads, open site parts, far trees, the fog end,
## the far plane and the sun's shadows widen so the sky view keeps the whole city; on the way
## down each value is re-derived, so a preset or weather change mid-air never leaves a stale
## value behind.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const HLOD := preload("res://scripts/fp/render/hlod.gd")
const LP := preload("res://scripts/fp/street/light_profile.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const EPS := 1e-5

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	var ctx := K.render_street_ctx(get_root(), fails)
	var sim := ctx.sim
	var view := ctx.view
	# The windowed game's root viewport carries the project's MSAA 2x; headless roots start at 0.
	get_root().msaa_3d = Viewport.MSAA_2X
	var f := K.make_feature(ctx, "render_opt")
	K.check(fails, f != null and f.get("active") == true, "render_opt is active on foot")
	if f == null:
		K.finish(self, "FP_AERIAL_TEST", fails)
		return
	var hlod: RefCounted = f.get("hlod")
	# The aerial checks audit the Medium preset's coverage.
	ctx.bus.quality_changed.emit("medium")
	f.call("flush")
	_check_aerial(ctx, f, hlod)
	K.finish(self, "FP_AERIAL_TEST", fails)


## Aerial coverage: once the camera is over the city (the overview, a photo fly), roads, open site
## parts, far trees, the fog end and the far plane widen so the sky view keeps the whole city; on
## the way down each value is re-derived, so a preset or weather change mid-air never leaves a
## stale value behind.
func _check_aerial(ctx: FpContext, f: Node, hlod: RefCounted) -> void:
	var cam := ctx.player.camera
	var env: Environment = cam.environment
	K.check(fails, env != null, "fixture: the camera carries the environment")
	if env == null:
		return
	var pick := _aerial_fixtures(hlod, ctx.view)
	var want := "fixtures: road %d, twin %d, open site %d, %d full parts"
	var got: Array = [pick["road"], pick["twin"], pick["site"], pick["full"]]
	K.check(fails, bool(pick["ok"]), want % got)
	var site_ends := _site_ends(ctx.view, ctx.sim)
	# The camera over the hero turns the coverage on within a frame (AERIAL_MIN is 3 u).
	cam.global_position = ctx.player.position + Vector3.UP * 3.5
	f.call("_process", 0.0)
	f.call("flush")
	var up := bool(f.get("aerial")) and bool(hlod.get("aerial"))
	K.check(fails, up, "the camera over the city turns the coverage on")
	var far := Q.aerial_far("medium")
	var far_msg := "the far plane covers the city (%.0f u)" % cam.far
	K.check(fails, is_equal_approx(cam.far, far), far_msg)
	var fog_end := Q.aerial_fog_end("medium")
	var fog_msg := "the fog ends past it (%.0f u)" % env.fog_depth_end
	K.check(fails, is_equal_approx(env.fog_depth_end, fog_end), fog_msg)
	_check_aerial_shadows(ctx, hlod, "medium")
	_check_aerial_roads(hlod)
	_check_aerial_parts(ctx.view, ctx.sim)
	_check_aerial_midair(ctx, f, hlod)
	_check_aerial_new_sites(ctx, f, site_ends)
	_check_aerial_off(ctx, f, hlod, site_ends)
	env.fog_depth_begin = WS.FOG_DEPTH_BEGIN
	ctx.bus.quality_changed.emit("medium")
	f.call("flush")


## While aerial the sun's shadows reach the aerial plane and the impostor chunks cast them.
func _check_aerial_shadows(ctx: FpContext, hlod: RefCounted, preset: String) -> void:
	var sun := ctx.sun
	var reach := is_equal_approx(sun.directional_shadow_max_distance, Q.aerial_shadow(preset))
	for k in range(3):
		reach = reach and is_equal_approx(_split(sun, k), float(Q.AERIAL_SHADOW_SPLITS[k]))
	var msg := "aerial %s: shadows reach %.0f u (split %.2f)"
	K.check(fails, reach, msg % [preset, sun.directional_shadow_max_distance, _split(sun, 0)])
	var on := GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	K.check(fails, _chunks_cast(hlod, on), "aerial: the impostor chunks cast shadows")


## Cascade split k + 1 of the sun (0, 1, 2).
static func _split(sun: DirectionalLight3D, k: int) -> float:
	return float(sun.get("directional_shadow_split_%d" % (k + 1)))


## Do all impostor chunks (at least one) carry this shadow setting?
func _chunks_cast(hlod: RefCounted, want: int) -> bool:
	var chunks: Array = (hlod.get("chunk_nodes") as Dictionary).values()
	var same := func(mi: MeshInstance3D) -> bool: return mi.cast_shadow == want
	return not chunks.is_empty() and chunks.all(same)


## One road main, one road twin, one open site and one full-detail part, for the checks below.
func _aerial_fixtures(hlod: RefCounted, view: CityView) -> Dictionary:
	var road := -1
	var twin := -1
	var site := -1
	var full := 0
	for i: int in hlod.tiles.keys():
		var e: Dictionary = hlod.tiles[i]
		var h := view.tile_holder(i)
		if site < 0 and h != null and h.get_node_or_null("Site") != null:
			site = i
		var cls: PackedByteArray = e["cls"]
		var gis: Array = e["gis"]
		for k in range(gis.size()):
			if cls[k] == HLOD.Cls.FULL:
				full += 1
			if road < 0 and cls[k] == HLOD.Cls.ROAD:
				road = i
			if twin < 0 and cls[k] == HLOD.Cls.MID and bool(e["road"]):
				twin = i
	var ok := road >= 0 and twin >= 0 and site >= 0 and full > 0
	return {"road": road, "twin": twin, "site": site, "full": full, "ok": ok}


## Every part of every open site, in tile order: the coverage re-ranges exactly these.
func _site_parts(view: CityView, sim: CitySim) -> Array:
	var parts: Array = []
	for i: int in sim.sites.keys():
		var h := view.tile_holder(i)
		if h == null or not is_instance_valid(h):
			continue
		var site := h.get_node_or_null("Site") as Node3D
		if site == null:
			continue
		parts.append_array(site.find_children("*", "GeometryInstance3D", true, false))
	return parts


## Each site part's own visibility end, keyed by instance id, to compare against on the way down.
func _site_ends(view: CityView, sim: CitySim) -> Dictionary:
	var ends := {}
	for n in _site_parts(view, sim):
		var gi := n as GeometryInstance3D
		ends[gi.get_instance_id()] = gi.visibility_range_end
	return ends


## The far tree layers (the ones that draw only at distance): two checks range them.
func _far_trees(view: CityView) -> Array:
	var out: Array = []
	for layer: Array in (view.get("_tree_chunks") as Dictionary).values():
		for n in layer:
			var mmi := n as MultiMeshInstance3D
			if mmi != null and mmi.visibility_range_begin > 0.0:
				out.append(mmi)
	return out


## While aerial the street grid draws to the horizon: road mains and their twins drop their end,
## building twins keep the street ladder.
func _check_aerial_roads(hlod: RefCounted) -> void:
	var roads := true
	var twin := false
	for i: int in hlod.tiles.keys():
		var e: Dictionary = hlod.tiles[i]
		var cls: PackedByteArray = e["cls"]
		var gis: Array = e["gis"]
		for k in range(gis.size()):
			var end := (gis[k] as GeometryInstance3D).visibility_range_end
			if cls[k] == HLOD.Cls.ROAD:
				roads = roads and end == 0.0
			elif cls[k] == HLOD.Cls.MID and bool(e["road"]):
				twin = twin or end == 0.0
			elif cls[k] == HLOD.Cls.MID:
				roads = roads and absf(end - WS.VIS_BUILDING) < EPS
	K.check(fails, roads and twin, "aerial: road mains and twins lose their end, buildings keep it")


## The open sites' parts and the far tree layers cover the whole sky view.
func _check_aerial_parts(view: CityView, sim: CitySim) -> void:
	var parts := _site_parts(view, sim)
	var sites := true
	for n in parts:
		var gi := n as GeometryInstance3D
		sites = sites and gi.visibility_range_end == 0.0 and gi.has_meta("ck_aerial_far")
	var msg := "every part of the open sites (%d) draws out, own end kept" % parts.size()
	K.check(fails, sites and not parts.is_empty(), msg)
	var trees := false
	for n in _far_trees(view):
		trees = trees or (n as MultiMeshInstance3D).visibility_range_end == 0.0
	K.check(fails, trees, "the far tree layers draw to the horizon")


## Mid-air changes: a preset switch keeps the coverage, and a road built now covers to the horizon.
func _check_aerial_midair(ctx: FpContext, f: Node, hlod: RefCounted) -> void:
	LP.apply(ctx.player.camera.environment, ctx.sun, "fp", "high")
	ctx.player.camera.environment.fog_depth_begin = 9.0
	ctx.bus.quality_changed.emit("high")
	f.call("flush")
	var env: Environment = ctx.player.camera.environment
	var kept := is_equal_approx(env.fog_depth_end, Q.aerial_fog_end("high"))
	kept = kept and is_equal_approx(ctx.player.camera.far, Q.aerial_far("high"))
	var msg := "a preset switch mid-air keeps the coverage (fog %.0f, far %.0f)"
	K.check(fails, kept, msg % [env.fog_depth_end, ctx.player.camera.far])
	_check_aerial_shadows(ctx, hlod, "high")
	var built := _pave_a_road(ctx.sim)
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	f.call("flush")
	K.check(fails, built and _roads_reach_horizon(hlod), "a road built mid-air covers out")


## Sites mid-air: a site opened now draws out once its tile is built, and a part a site gains
## without a tile rebuild (update_site's path) is caught by the next SITE_RESCAN. Both get their
## own end back on the way down (their ends join site_ends).
func _check_aerial_new_sites(ctx: FpContext, f: Node, site_ends: Dictionary) -> void:
	var before := ctx.sim.sites.keys()
	var built := _pave_a_road(ctx.sim, "staged")
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	var fresh: Array = []
	for i: int in ctx.sim.sites.keys():
		var h := ctx.view.tile_holder(i)
		if i not in before and h != null and h.get_node_or_null("Site") != null:
			var site_node := h.get_node("Site") as Node3D
			fresh.append_array(site_node.find_children("*", "GeometryInstance3D", true, false))
	for n in fresh:
		site_ends[n.get_instance_id()] = (n as GeometryInstance3D).visibility_range_end
	f.call("flush")
	var out := not fresh.is_empty()
	for n in fresh:
		out = out and (n as GeometryInstance3D).visibility_range_end == 0.0
	K.check(fails, built and out, "a site opened mid-air draws out (%d parts)" % fresh.size())
	var site := _first_site(ctx.view, ctx.sim)
	K.check(fails, site != null, "fixture: an open site to grow a part on")
	if site == null:
		return
	var part := MeshInstance3D.new()
	part.mesh = BoxMesh.new()
	part.visibility_range_end = ctx.view.kit.FAR
	site.add_child(part)
	site_ends[part.get_instance_id()] = part.visibility_range_end
	var rescan: float = f.get("SITE_RESCAN")
	f.call("_process", rescan * 0.5)
	var early := part.visibility_range_end
	f.call("_process", rescan * 0.5)
	var msg := "a part grown mid-air draws out by the next re-scan (end %.1f, then %.1f)"
	var caught := early > 0.0 and part.visibility_range_end == 0.0
	K.check(fails, caught, msg % [early, part.visibility_range_end])


## The Site node of the first open site whose tile is built, or null.
func _first_site(view: CityView, sim: CitySim) -> Node3D:
	for i: int in sim.sites.keys():
		var h := view.tile_holder(i)
		if h != null and is_instance_valid(h) and h.get_node_or_null("Site") != null:
			return h.get_node("Site") as Node3D
	return null


## Paves the first buildable tile beside a road (instantly, or as a site with mode "staged");
## false if the city left no room.
func _pave_a_road(sim: CitySim, how: String = "instant") -> bool:
	var mode := sim.construction_mode
	sim.construction_mode = how
	var built := false
	for i: int in sim.active.duplicate():
		if sim.kind[i] != D.ROAD or not _empty_neighbour(sim, i):
			continue
		var r: Dictionary = sim.apply_action(0, {"type": "road", "x": D.tx(i) + 1, "y": D.ty(i)})
		built = bool(r.get("ok", false))
		if built:
			break
	sim.construction_mode = mode
	return built


## Is the tile one east of i inside the map and empty (the one _pave_a_road lays a road on)?
func _empty_neighbour(sim: CitySim, i: int) -> bool:
	if not D.in_bounds(D.tx(i) + 1, D.ty(i)):
		return false
	return sim.kind[D.idx(D.tx(i) + 1, D.ty(i))] == D.EMPTY


## Does some road tile still carry a main or a twin that draws with no end?
func _roads_reach_horizon(hlod: RefCounted) -> bool:
	for i: int in hlod.tiles.keys():
		var e: Dictionary = hlod.tiles[i]
		if not bool(e["road"]):
			continue
		var cls: PackedByteArray = e["cls"]
		var gis: Array = e["gis"]
		for k in range(gis.size()):
			if cls[k] != HLOD.Cls.ROAD and cls[k] != HLOD.Cls.MID:
				continue
			if (gis[k] as GeometryInstance3D).visibility_range_end == 0.0:
				return true
	return false


## Back on the street: the coverage goes off and every value re-derives from the preset.
func _check_aerial_off(ctx: FpContext, f: Node, hlod: RefCounted, site_ends: Dictionary) -> void:
	var cam := ctx.player.camera
	var env: Environment = cam.environment
	cam.global_position = ctx.player.position + Vector3.UP * 1.0
	f.call("_process", 0.0)
	f.call("flush")
	K.check(fails, not bool(f.get("aerial")), "the camera back at the hero turns the coverage off")
	var derived := is_equal_approx(cam.far, Q.camera_far("high"))
	derived = derived and is_equal_approx(env.fog_depth_end, Q.street_fog_end("high"))
	var msg := "the far plane and fog end re-derive from the preset (far %.0f, fog %.0f)"
	K.check(fails, derived, msg % [cam.far, env.fog_depth_end])
	K.check(fails, is_equal_approx(env.fog_depth_begin, 9.0), "the weather's fog begin survives")
	var street: Dictionary = LP.PRESETS["high"]
	var sun := ctx.sun
	var shadow := is_equal_approx(sun.directional_shadow_max_distance, float(street["shadow"]))
	for k in range(3):
		shadow = shadow and is_equal_approx(_split(sun, k), float((street["splits"] as Array)[k]))
	var sh_msg := "the street profile's shadows come back (reach %.0f, split %.2f)"
	K.check(fails, shadow, sh_msg % [sun.directional_shadow_max_distance, _split(sun, 0)])
	var off := GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	K.check(fails, _chunks_cast(hlod, off), "the impostor chunks stop casting")
	K.check(fails, _ranges_back(hlod), "the street ranges are back exactly")
	var back := _sites_back(ctx.view, ctx.sim, site_ends)
	K.check(fails, back.x > 0 and back.y == 0, "site parts keep their ends (%d checked)" % back.x)
	var trees := false
	for n in _far_trees(ctx.view):
		var mmi := n as MultiMeshInstance3D
		var want := ctx.view.TREE_FAR_FP * float(ctx.view.vis_mult)
		trees = trees or absf(mmi.visibility_range_end - want) < EPS
	K.check(fails, trees, "the far tree layers end at TREE_FAR_FP again")


## Every cached instance back at its street end and begin for the High preset.
func _ranges_back(hlod: RefCounted) -> bool:
	var ok := true
	var mult := Q.vis_mult("high")
	for i: int in hlod.tiles.keys():
		var e: Dictionary = hlod.tiles[i]
		var cls: PackedByteArray = e["cls"]
		var gis: Array = e["gis"]
		for k in range(gis.size()):
			var gi := gis[k] as GeometryInstance3D
			ok = ok and absf(gi.visibility_range_end - K.vis_want_end(cls[k], mult)) < EPS
			ok = ok and absf(gi.visibility_range_begin - K.vis_want_begin(cls[k], mult)) < EPS
	return ok


## How many site parts came back and how many did not, as Vector2i(checked, bad).
func _sites_back(view: CityView, sim: CitySim, site_ends: Dictionary) -> Vector2i:
	var checked := 0
	var bad := 0
	for n in _site_parts(view, sim):
		var gi := n as GeometryInstance3D
		var id := gi.get_instance_id()
		if not site_ends.has(id):
			continue
		checked += 1
		var want: float = site_ends[id]
		if gi.has_meta("ck_aerial_far") or not is_equal_approx(gi.visibility_range_end, want):
			bad += 1
	return Vector2i(checked, bad)
