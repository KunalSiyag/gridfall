extends SceneTree
## Slice G2 acceptance (docs/fp/slices/G2-renderperf.md): visibility ranges and shadows of the
## tile post-pass, per-chunk occluders and impostors, quality presets with a full restore on
## teardown, the undo when leaving first person, and the import settings (optimize_imports.py),
## including byte-identical character imports.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const HLOD := preload("res://scripts/fp/render/hlod.gd")
const OCC := preload("res://scripts/fp/render/occluders.gd")
const EPS := 1e-5
## A character scene import with HC's retarget settings (D13): must survive --apply untouched.
const CHAR_GLB_IMPORT := "[remap]\n\nimporter=\"scene\"\nimporter_version=1\ntype=\"PackedScene\"\nuid=\"uid://g2testchar\"\npath=\"res://.godot/imported/hero.glb-0.scn\"\n\n[deps]\n\nsource_file=\"res://models/characters/bodies/hero.glb\"\ndest_files=[\"res://.godot/imported/hero.glb-0.scn\"]\n\n[params]\n\nnodes/use_name_suffixes=true\nmeshes/generate_lods=true\nanimation/fps=30\n_subresources={\n\"nodes\": {\n\"PATH:Armature/Skeleton3D\": {\n\"retarget/bone_map\": Resource(\"res://models/characters/bonemap.tres\"),\n\"retarget/bone_renamer/rename_bones\": true,\n\"retarget/rest_fixer/normalize_position_tracks\": true,\n\"retarget/remove_tracks/unmapped_bones\": true\n}\n}\n}\ngltf/embedded_image_handling=0\n"
const CHAR_TEX_IMPORT := "[remap]\n\nimporter=\"texture\"\ntype=\"CompressedTexture2D\"\nuid=\"uid://g2testtex\"\npath=\"res://.godot/imported/hero_body.png-0.ctex\"\n\n[deps]\n\nsource_file=\"res://models/characters/bodies/hero_body.png\"\n\n[params]\n\ncompress/mode=0\ncompress/normal_map=0\nmipmaps/generate=false\n"

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_static()
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "player": true, "hud": false})
	var sim := ctx.sim
	var view := ctx.view
	sim.mayors[0]["treasury"] = 200000
	_place_open_services(sim)
	view.set_fp_mode(true)
	if view.has_method("flush_rebuild_queue"):
		view.call("flush_rebuild_queue")
	# A part another slice ranged before G2 runs must keep its range.
	var foreign := _foreign_part(view, sim)
	# The windowed game's root viewport carries the project's MSAA 2x; headless roots start at 0.
	get_root().msaa_3d = Viewport.MSAA_2X
	var f := K.make_feature(ctx, "render_opt")
	K.check(fails, f != null and f.get("active") == true, "render_opt is active on foot")
	if f == null:
		K.finish(self, "FP_RENDERPERF_TEST", fails)
		return
	var hlod: RefCounted = f.get("hlod")
	var occ: RefCounted = f.get("occluders")
	var mult := Q.vis_mult("medium")
	_check_ranges(f, hlod, view, mult, foreign)
	_check_occluders(hlod, occ, view, sim)
	_check_impostors(hlod, view, mult)
	_check_bulldoze(f, hlod, occ, view, sim)
	_check_presets(ctx, f, hlod)
	var st: Dictionary = f.self_test()
	K.check(fails, bool(st["ok"]), "self_test ok: %s" % st["detail"])
	_check_undo(ctx, f, hlod, view)
	_check_teardown(ctx, f)
	_check_imports()
	K.finish(self, "FP_RENDERPERF_TEST", fails)


func _check_static() -> void:
	K.check(fails, is_equal_approx(Q.vis_mult("low"), 0.7) and is_equal_approx(Q.vis_mult("medium"), 1.0) and is_equal_approx(Q.vis_mult("high"), 1.3), "vis_mult 0.7 / 1.0 / 1.3")
	K.check(fails, Q.max_street_lights("low") == 6 and Q.max_street_lights("medium") == 12 and Q.max_street_lights("high") == 16, "max_street_lights 6 / 12 / 16")
	K.check(fails, is_equal_approx(Q.camera_far("low"), 45.0) and is_equal_approx(Q.camera_far("medium"), WS.CAMERA_FAR) and is_equal_approx(Q.camera_far("high"), 75.0), "camera_far 45 / 60 / 75")
	K.check(fails, Q.normalize("ultra") == "medium", "unknown preset falls back to medium")
	# G1 ends the Low fog inside 95 % of the far plane; the far plane must lie beyond it.
	var fog_low := minf(WS.FOG_DEPTH_END, 0.95 * Q.camera_far("low"))
	if ResourceLoader.exists("res://scripts/fp/street/light_profile.gd"):
		var lp := load("res://scripts/fp/street/light_profile.gd") as GDScript
		if lp != null and lp.has_method("fog_end"):
			fog_low = float(lp.call("fog_end", "low"))
	K.check(fails, Q.camera_far("low") > fog_low, "Low far plane %.1f beyond the Low fog end %.1f" % [Q.camera_far("low"), fog_low])


## Builds a park, a wind farm and a stadium instantly when the grown city has none.
func _place_open_services(sim: CitySim) -> void:
	var mode := sim.construction_mode
	sim.construction_mode = "instant"
	for key: String in ["park", "wind_farm", "stadium"]:
		var kind := int(D.BUILDINGS[key]["kind"])
		var have := false
		for i in sim.active:
			have = have or sim.kind[i] == kind
		if not have:
			var r: Dictionary = sim.apply_action(0, {"type": "build", "building": key, "x": 12, "y": 10})
			K.check(fails, bool(r.get("ok", false)), "fixture: built a %s (%s)" % [key, r.get("reason", "")])
	sim.construction_mode = mode


func _foreign_part(view: CityView, sim: CitySim) -> GeometryInstance3D:
	for i in sim.active:
		if D.is_zone(sim.kind[i]) and sim.level[i] >= 1:
			var h := view.tile_holder(i)
			if h == null:
				continue
			for n in h.find_children("*", "GeometryInstance3D", true, false):
				var gi := n as GeometryInstance3D
				if gi.visibility_range_end == 0.0:
					gi.visibility_range_end = 3.21
					return gi
	return null


func _check_ranges(f: Node, hlod: RefCounted, view: CityView, mult: float, foreign: GeometryInstance3D) -> void:
	var tiles: Dictionary = hlod.tiles
	var nb := 0
	var np := 0
	var nr := 0
	var nm := 0
	var bad: Array[String] = []
	for i: int in tiles.keys():
		var e: Dictionary = tiles[i]
		var gis: Array = e["gis"]
		var cls: PackedByteArray = e["cls"]
		for k in range(gis.size()):
			var gi := gis[k] as GeometryInstance3D
			if absf(gi.visibility_range_end - _want_end(cls[k], mult)) > EPS or absf(gi.visibility_range_begin - _want_begin(cls[k], mult)) > EPS or not gi.has_meta("g2_vis"):
				bad.append("%d:%s" % [i, gi.name])
			if cls[k] == HLOD.Cls.MID:
				nm += 1
				var src := gi.get_parent() as MeshInstance3D
				if src == null or not (e["gis"] as Array).has(src) or cls[(e["gis"] as Array).find(src)] != HLOD.Cls.NEAR or gi.transform != Transform3D.IDENTITY or not src.get_aabb().is_equal_approx(gi.get_aabb()) or (gi as MeshInstance3D).mesh.get_surface_count() != 1 or gi.cast_shadow != src.cast_shadow:
					bad.append("%d:%s twin" % [i, gi.name])
			if cls[k] == HLOD.Cls.PROP:
				np += 1
				if gi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
					bad.append("%d:%s casts" % [i, gi.name])
			elif cls[k] == HLOD.Cls.ROAD:
				nr += 1
			elif gi is MeshInstance3D:
				nb += 1
	K.check(fails, nb >= 50 and np >= 5 and nr >= 50 and nm >= 20, "fixtures: %d building meshes, %d mid-LOD twins, %d prop parts, %d road parts" % [nb, nm, np, nr])
	K.check(fails, bad.is_empty(), "building meshes end at VIS_BUILDING_NEAR*mult where their one-surface twin (same bounds, shadows as authored) takes over to VIS_BUILDING*mult; other building/road parts end at VIS_BUILDING*mult, props at VIS_PROP*mult with no shadow %s" % str(bad.slice(0, 5)))
	# Every building mesh under a holder is ranged.
	var unranged := 0
	for i: int in tiles.keys():
		var h := view.tile_holder(i)
		if h == null or not h.has_meta("building_path"):
			continue
		for n in h.find_children("*", "MeshInstance3D", true, false):
			var site := h.get_node_or_null("Site")
			if site != null and site.is_ancestor_of(n):
				continue
			if n != foreign and not n.has_meta("g2_vis"):
				unranged += 1
	K.check(fails, unranged == 0, "every building MeshInstance3D under a holder carries g2_vis (%d missing)" % unranged)
	# Site parts and parts ranged by others are untouched.
	var site_touched := 0
	var sites := 0
	for i: int in tiles.keys():
		var h := view.tile_holder(i)
		var site := h.get_node_or_null("Site") if h != null else null
		if site == null:
			continue
		sites += 1
		for n in site.find_children("*", "GeometryInstance3D", true, false):
			if n.has_meta("g2_vis"):
				site_touched += 1
	K.check(fails, site_touched == 0, "no node under %d Site children touched (%d)" % [sites, site_touched])
	K.check(fails, foreign != null and is_equal_approx(foreign.visibility_range_end, 3.21) and not foreign.has_meta("g2_vis"), "a part ranged before the post-pass keeps its range")


static func _want_end(c: int, mult: float) -> float:
	match c:
		HLOD.Cls.PROP:
			return WS.VIS_PROP * mult
		HLOD.Cls.NEAR:
			return WS.VIS_BUILDING_NEAR * mult
	return WS.VIS_BUILDING * mult


static func _want_begin(c: int, mult: float) -> float:
	return WS.VIS_BUILDING_NEAR * mult if c == HLOD.Cls.MID else 0.0


func _check_occluders(hlod: RefCounted, occ: RefCounted, view: CityView, sim: CitySim) -> void:
	var tiles: Dictionary = hlod.tiles
	var solid_chunks := {}
	var solid := 0
	var bad: Array[String] = []
	for i: int in tiles.keys():
		var e: Dictionary = tiles[i]
		var k := sim.kind[i]
		var want_solid := (k == D.ZONE_R and sim.level[i] >= 2) or ((k == D.ZONE_C or k == D.ZONE_I) and sim.level[i] >= 1) or k in HLOD.SOLID_SERVICES
		if bool(e["solid"]) != (want_solid and not str(e["path"]).is_empty()):
			bad.append("%d kind %d solid=%s" % [i, k, str(e["solid"])])
		if not bool(e["solid"]):
			continue
		solid += 1
		solid_chunks[e["chunk"]] = int(solid_chunks.get(e["chunk"], 0)) + 1
		var box := OCC.shrink(e["body"] as AABB)
		var body: AABB = (e["body"] as AABB).grow(EPS)
		var full := view.building_aabb(i).grow(1e-4)
		if not (body.encloses(box) and full.encloses(box)):
			bad.append("%d box outside body/building_aabb" % i)
	K.check(fails, solid >= 5, "fixtures: %d solid buildings" % solid)
	K.check(fails, bad.is_empty(), "occluders only on solid kinds, each inside its body box and building_aabb %s" % str(bad.slice(0, 5)))
	var open_kinds := 0
	for i in sim.active:
		if sim.kind[i] in [D.PARK, D.WIND, D.STADIUM]:
			open_kinds += 1
			if tiles.has(i) and bool((tiles[i] as Dictionary)["solid"]):
				bad.append("open kind %d solid" % sim.kind[i])
	K.check(fails, open_kinds >= 3, "fixtures: park, wind farm and stadium tiles (%d)" % open_kinds)
	var per_chunk_ok := true
	for c: Vector2i in solid_chunks.keys():
		per_chunk_ok = per_chunk_ok and (occ.chunk_boxes.get(c, []) as Array).size() == int(solid_chunks[c])
	K.check(fails, per_chunk_ok and occ.chunk_nodes.size() == solid_chunks.size(), "one OccluderInstance3D per chunk with solid buildings (%d chunks, %d nodes), one box each" % [solid_chunks.size(), occ.chunk_nodes.size()])
	var under_world := true
	for oi: OccluderInstance3D in occ.chunk_nodes.values():
		under_world = under_world and oi.get_parent().name == "Occluders" and not view.is_ancestor_of(oi) and oi.occluder is ArrayOccluder3D
	K.check(fails, under_world, "occluders are ArrayOccluder3D under World/Occluders, never under CityView")


func _check_impostors(hlod: RefCounted, view: CityView, mult: float) -> void:
	var tiles: Dictionary = hlod.tiles
	var want := {}
	var center_bad := 0
	for i: int in tiles.keys():
		var e: Dictionary = tiles[i]
		if not bool(e["impostor"]):
			continue
		want[e["chunk"]] = true
		# The shader's switch point is the engine's range point of the main mesh.
		var h := view.tile_holder(i)
		var model: Node3D = null
		for ch in h.get_children():
			if ch is Node3D and ch.scene_file_path == str(e["path"]):
				model = ch
		# A grow tween still running scales the model; the switch point uses its final transform.
		if model == null or not model.transform.is_equal_approx(h.get_meta("building_xform") as Transform3D):
			continue
		var best: MeshInstance3D = null
		for n in h.find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi.mesh != null and not str(mi.name).begins_with("Leaves") and not str(mi.name).contains("foliage") and (best == null or mi.get_aabb().get_volume() > best.get_aabb().get_volume()):
				if mi.has_meta("g2_vis") and (e["gis"] as Array).has(mi):
					best = mi
		if best != null and not (best.global_transform * best.get_aabb()).get_center().is_equal_approx(e["center"]):
			center_bad += 1
	K.check(fails, want.size() >= 2 and hlod.chunk_nodes.size() == want.size(), "one merged impostor mesh per chunk with impostor buildings, built synchronously (%d chunks, %d meshes)" % [want.size(), hlod.chunk_nodes.size()])
	K.check(fails, center_bad == 0, "impostor switch points match the engine's range points (%d off)" % center_bad)
	var vis := WS.VIS_BUILDING * mult
	var rng := float(hlod.material.get_shader_parameter("range_sq"))
	K.check(fails, absf(rng - vis * vis) < 1e-3, "impostor proxies switch at VIS_BUILDING*mult = %.2f (holders end there, no overlap band)" % vis)
	var begin_ok := true
	for mi: MeshInstance3D in hlod.chunk_nodes.values():
		var reach := float(mi.get_meta("reach", 0.0))
		begin_ok = begin_ok and mi.visibility_range_begin <= vis + EPS and absf(mi.visibility_range_begin - maxf(0.0, vis - reach)) < EPS
		begin_ok = begin_ok and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and not view.is_ancestor_of(mi)
		begin_ok = begin_ok and reach <= HLOD.CHUNK * 0.75 + 3.0 and mi.mesh != null and mi.mesh.get_surface_count() == 1
	K.check(fails, begin_ok, "chunk impostors begin where their nearest building switches, cast no shadow, live outside CityView")


func _check_bulldoze(f: Node, hlod: RefCounted, occ: RefCounted, view: CityView, sim: CitySim) -> void:
	var target := -1
	for i: int in hlod.tiles.keys():
		var e: Dictionary = hlod.tiles[i]
		if bool(e["solid"]) and sim.kind[i] != D.HALL:
			target = i
			break
	K.check(fails, target >= 0, "fixture: a solid building to bulldoze")
	if target < 0:
		return
	var c := HLOD.chunk_of(target)
	var before := (occ.chunk_boxes.get(c, []) as Array).size()
	var mode := sim.construction_mode
	sim.construction_mode = "instant"
	var r: Dictionary = sim.apply_action(0, {"type": "bulldoze", "x": D.tx(target), "y": D.ty(target)})
	sim.construction_mode = mode
	for _k in range(8):
		if sim.kind[target] == D.EMPTY:
			break
		K.ticks(sim, 1)
	if view.has_method("flush_rebuild_queue"):
		view.call("flush_rebuild_queue")
	f.call("flush")
	var inside := false
	for b: AABB in occ.chunk_boxes.get(c, []):
		inside = inside or (absf(b.get_center().x - D.tx(target)) < 0.5 and absf(b.get_center().z - D.ty(target)) < 0.5)
	K.check(fails, bool(r.get("ok", false)) and sim.kind[target] == D.EMPTY, "bulldozed tile %d cleared (%s)" % [target, r.get("reason", "")])
	K.check(fails, not inside and (occ.chunk_boxes.get(c, []) as Array).size() == before - 1, "its chunk dropped the box (%d -> %d)" % [before, (occ.chunk_boxes.get(c, []) as Array).size()])


func _check_presets(ctx: FpContext, f: Node, hlod: RefCounted) -> void:
	var vp := f.get_viewport()
	var walks: int = hlod.walks
	ctx.bus.quality_changed.emit("low")
	var atlas: Array = (f.get("rs_calls") as Dictionary).get("directional_shadow_atlas_set_size", [])
	K.check(fails, vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR2 and absf(vp.scaling_3d_scale - 0.59) < EPS and vp.msaa_3d == Viewport.MSAA_DISABLED, "Low: FSR2 at 0.59, MSAA off")
	K.check(fails, atlas == [2048, true], "Low: shadow atlas 2048 16-bit (recorded setter %s)" % str(atlas))
	K.check(fails, is_equal_approx(ctx.player.camera.far, 45.0) and is_equal_approx(vp.mesh_lod_threshold, 2.0), "Low: camera far 45, mesh LOD threshold 2")
	K.check(fails, int(f.call("job_pending")) > 0, "a preset switch re-ranges over frames, not in one stall")
	ctx.bus.quality_changed.emit("high")
	f.call("flush")
	K.check(fails, absf(vp.scaling_3d_scale - 0.9) < EPS and is_equal_approx(ctx.player.camera.far, 75.0), "High: FSR2 at 0.9, camera far 75")
	var ok := true
	for e: Dictionary in hlod.tiles.values():
		var gis: Array = e["gis"]
		for k in range(gis.size()):
			var c: int = (e["cls"] as PackedByteArray)[k]
			ok = ok and absf((gis[k] as GeometryInstance3D).visibility_range_end - _want_end(c, 1.3)) < EPS and absf((gis[k] as GeometryInstance3D).visibility_range_begin - _want_begin(c, 1.3)) < EPS
	K.check(fails, ok, "High: cached parts re-ranged to VIS_*×1.3")
	K.check(fails, hlod.walks == walks, "the preset switch walked only the cached lists (holder walks %d -> %d)" % [walks, hlod.walks])
	ctx.bus.quality_changed.emit("medium")
	f.call("flush")
	K.check(fails, bool(f.call("preset_applied", "medium")), "Medium applied again")


func _check_undo(ctx: FpContext, f: Node, hlod: RefCounted, view: CityView) -> void:
	var parts: Array = []
	for e: Dictionary in hlod.tiles.values():
		parts.append_array(e["gis"])
	var imps: Array = hlod.chunk_nodes.values()
	var occs: Array = (f.get("occluders") as RefCounted).chunk_nodes.values()
	view.set_fp_mode(false)
	var kept := 0
	for gi: Variant in parts:
		if is_instance_valid(gi) and not (gi as Node).is_queued_for_deletion() and ((gi as GeometryInstance3D).visibility_range_end != 0.0 or (gi as Node).has_meta("g2_vis")):
			kept += 1
	var shown := 0
	for n: Variant in imps + occs:
		if is_instance_valid(n) and (n as Node3D).visible and not (n as Node).is_queued_for_deletion():
			shown += 1
	K.check(fails, kept == 0 and not parts.is_empty(), "leaving first person: no g2_vis node keeps a range (%d of %d)" % [kept, parts.size()])
	K.check(fails, shown == 0 and not f.get_viewport().use_occlusion_culling, "leaving first person: impostors and occluders hidden, occlusion culling off")
	view.set_fp_mode(true)
	K.check(fails, f.get("active") == true and hlod.tiles.size() > 0, "re-entering first person re-runs the post-pass")


func _check_teardown(ctx: FpContext, f: Node) -> void:
	var vp := f.get_viewport()
	f.call("teardown")
	var rs: Dictionary = f.get("rs_calls")
	K.check(fails, vp.scaling_3d_mode == ProjectSettings.get_setting("rendering/scaling_3d/mode", 0) and is_equal_approx(vp.scaling_3d_scale, float(ProjectSettings.get_setting("rendering/scaling_3d/scale", 1.0))), "teardown: native scaling restored")
	K.check(fails, vp.msaa_3d == Viewport.MSAA_2X, "teardown: MSAA 2x restored")
	K.check(fails, rs.get("directional_shadow_atlas_set_size", []) == [8192, true], "teardown: 8192 atlas restored (%s)" % str(rs.get("directional_shadow_atlas_set_size")))
	K.check(fails, rs.get("directional_soft_shadow_filter_set_quality", []) == [3], "teardown: soft shadow quality 3 restored")
	var ssao: Array = rs.get("environment_set_ssao_quality", [])
	var ssil: Array = rs.get("environment_set_ssil_quality", [])
	K.check(fails, ssao.size() == 6 and ssao[0] == 3 and ssao[1] == bool(ProjectSettings.get_setting("rendering/environment/ssao/half_size")), "teardown: SSAO quality 3 and half size restored (%s)" % str(ssao))
	K.check(fails, ssil.size() == 6 and ssil[0] == 2 and ssil[1] == bool(ProjectSettings.get_setting("rendering/environment/ssil/half_size")), "teardown: SSIL quality 2 and half size restored (%s)" % str(ssil))
	K.check(fails, is_equal_approx(vp.mesh_lod_threshold, 1.0) and not vp.use_occlusion_culling and is_equal_approx(ctx.player.camera.far, WS.CAMERA_FAR), "teardown: mesh LOD threshold, occlusion culling and camera far restored")


func _check_imports() -> void:
	var script := ProjectSettings.globalize_path("res://tools/optimize_imports.py")
	var out: Array = []
	var code := OS.execute("python3", ["-I", script, "--check"], out, true)
	K.check(fails, code == 0, "optimize_imports --check passes on models/** (%s)" % str(out).right(160).strip_edges())
	# A scratch project root: a character scene import with retarget settings, a non-compliant
	# character texture import, and copies of HC's real character imports when present.
	var tmp := OS.get_user_data_dir().path_join("g2_import_test")
	DirAccess.make_dir_recursive_absolute(tmp.path_join("models/characters/bodies"))
	_write(tmp.path_join("models/characters/bodies/hero.glb.import"), CHAR_GLB_IMPORT)
	_write(tmp.path_join("models/characters/bodies/hero_body.png.import"), CHAR_TEX_IMPORT)
	var copied := _copy_imports("res://models/characters", tmp.path_join("models/characters/real"))
	var before := _hashes(tmp.path_join("models/characters"))
	var c1 := OS.execute("python3", ["-I", script, "--root", tmp, "--check"], out, true)
	var c2 := OS.execute("python3", ["-I", script, "--root", tmp, "--apply"], out, true)
	var after := _hashes(tmp.path_join("models/characters"))
	K.check(fails, c1 == 0 and c2 == 0 and before == after and before.size() >= 2, "characters: --check exits 0 and --apply without paths leaves %d files (%d of HC's) byte-identical" % [before.size(), copied])
	var c3 := OS.execute("python3", ["-I", script, "--root", tmp, "--apply", "models/characters/bodies"], out, true)
	var glb := FileAccess.get_file_as_string(tmp.path_join("models/characters/bodies/hero.glb.import"))
	var tex := FileAccess.get_file_as_string(tmp.path_join("models/characters/bodies/hero_body.png.import"))
	K.check(fails, c3 == 0 and glb == CHAR_GLB_IMPORT and tex.contains("compress/mode=2") and tex.contains("mipmaps/generate=true"), "characters: explicit --apply sets texture keys only; the retarget scene import stays byte-identical")
	_rm_rf(tmp)


static func _write(path: String, text: String) -> void:
	var fa := FileAccess.open(path, FileAccess.WRITE)
	fa.store_string(text)
	fa.close()


static func _copy_imports(src: String, dst: String) -> int:
	var n := 0
	var da := DirAccess.open(src)
	if da == null:
		return 0
	DirAccess.make_dir_recursive_absolute(dst)
	for f in da.get_files():
		if f.ends_with(".import"):
			_write(dst.path_join(f), FileAccess.get_file_as_string(src.path_join(f)))
			n += 1
	for d in da.get_directories():
		n += _copy_imports(src.path_join(d), dst.path_join(d))
	return n


static func _hashes(dir: String) -> Dictionary:
	var out := {}
	var da := DirAccess.open(dir)
	if da == null:
		return out
	for f in da.get_files():
		out[dir.path_join(f)] = FileAccess.get_md5(dir.path_join(f))
	for d in da.get_directories():
		out.merge(_hashes(dir.path_join(d)))
	return out


static func _rm_rf(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		da.remove(f)
	for d in da.get_directories():
		_rm_rf(dir.path_join(d))
	DirAccess.remove_absolute(dir)
