extends FpFeature
## Render performance (slice G2): applies the quality preset (FSR2 scaling, shadow atlas and filter,
## SSAO and SSIL quality, mesh LOD threshold, camera far plane) and restores every knob on teardown;
## on foot it ranges every tile holder's parts (hlod.gd), draws far buildings as merged chunk
## impostors and culls with per-chunk occluders (occluders.gd), rebuilding at most one chunk a frame.

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const HLOD := preload("res://scripts/fp/render/hlod.gd")
const OCCLUDERS := preload("res://scripts/fp/render/occluders.gd")
## A preset switch re-ranges cached parts for at most this long per frame.
const JOB_BUDGET_USEC := 3000
## Tiles re-passed per frame once their mid-LOD merges finish, at most this long.
const WAIT_BUDGET_USEC := 2000
## Project defaults of the global RenderingServer knobs (headless has no getters for them).
const RS_SETTINGS := {
	"atlas": "rendering/lights_and_shadows/directional_shadow/size",
	"atlas_16": "rendering/lights_and_shadows/directional_shadow/16_bits",
	"soft": "rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality",
	"ssao": "rendering/environment/ssao/quality", "ssao_half": "rendering/environment/ssao/half_size",
	"ssao_target": "rendering/environment/ssao/adaptive_target", "ssao_blur": "rendering/environment/ssao/blur_passes",
	"ssao_from": "rendering/environment/ssao/fadeout_from", "ssao_to": "rendering/environment/ssao/fadeout_to",
	"ssil": "rendering/environment/ssil/quality", "ssil_half": "rendering/environment/ssil/half_size",
	"ssil_target": "rendering/environment/ssil/adaptive_target", "ssil_blur": "rendering/environment/ssil/blur_passes",
	"ssil_from": "rendering/environment/ssil/fadeout_from", "ssil_to": "rendering/environment/ssil/fadeout_to",
}
const RS_DEFAULTS := {
	"atlas": 4096, "atlas_16": true, "soft": 2, "ssao": 2, "ssao_half": true, "ssao_target": 0.5,
	"ssao_blur": 2, "ssao_from": 50.0, "ssao_to": 300.0, "ssil": 2, "ssil_half": true,
	"ssil_target": 0.5, "ssil_blur": 4, "ssil_from": 50.0, "ssil_to": 300.0,
}
const VIEWPORT_KEYS := ["scaling_3d_mode", "scaling_3d_scale", "msaa_3d", "mesh_lod_threshold", "use_occlusion_culling"]

## The applied preset: "low", "medium" or "high".
var preset: String = Q.DEFAULT
var hlod: RefCounted
var occluders: RefCounted
## Last arguments of every RenderingServer setter this feature called (headless has no getters).
var rs_calls: Dictionary = {}
## The post-pass is live (on foot, set up).
var active: bool = false
var _vp: Viewport
var _vp_snap: Dictionary = {}
var _rs_snap: Dictionary = {}
var _cam_far: float = -1.0
var _dirty: Dictionary = {}
var _job: Array = []
var _night: float = -1.0
var _imp_root: Node3D
var _occ_root: Node3D
var _waiting_ready: bool = false
var _wait_queue: Array = []


func feature_id() -> String:
	return "render_opt"


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	# Preset switches come from the pause menu while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_vp = get_viewport()
	_snapshot()
	hlod = HLOD.new()
	occluders = OCCLUDERS.new()
	if ctx.world_root != null:
		_imp_root = _child_root("Impostors")
		_occ_root = _child_root("Occluders")
	if ctx.view != null:
		hlod.setup(ctx.view, ctx.sim, _imp_root)
		# Headless runs (tests) merge on the calling thread, so results are deterministic.
		hlod.midlod.threaded = DisplayServer.get_name() != "headless"
		occluders.setup(_occ_root)
		ctx.view.tile_built.connect(_on_tile_built)
		ctx.view.tile_cleared.connect(_on_tile_cleared)
		ctx.view.fp_mode_changed.connect(_on_fp_mode_changed)
	if ctx.bus != null:
		ctx.bus.quality_changed.connect(_on_quality_changed)
	apply_preset(str(ctx.settings.get("quality", Q.DEFAULT)))


func on_world_rebuilt() -> void:
	if ctx.view != null and ctx.view.fp_mode:
		_activate()


func teardown() -> void:
	_deactivate()
	if ctx.view != null:
		for pair: Array in [[ctx.view.tile_built, _on_tile_built], [ctx.view.tile_cleared, _on_tile_cleared], [ctx.view.fp_mode_changed, _on_fp_mode_changed]]:
			if (pair[0] as Signal).is_connected(pair[1]):
				(pair[0] as Signal).disconnect(pair[1])
	if ctx.bus != null and ctx.bus.quality_changed.is_connected(_on_quality_changed):
		ctx.bus.quality_changed.disconnect(_on_quality_changed)
	_restore()
	for r: Node3D in [_imp_root, _occ_root]:
		if r != null and is_instance_valid(r):
			r.queue_free()


## Applies preset p (unknown names give Medium) to the viewport, the RenderingServer, the camera and
## the visibility ranges; cached parts are re-ranged over the next frames.
func apply_preset(p: String) -> void:
	preset = Q.normalize(p)
	var k := Q.knobs(preset)
	if _vp != null:
		_vp.scaling_3d_mode = int(k["scaling_mode"]) as Viewport.Scaling3DMode
		_vp.scaling_3d_scale = float(k["scale"])
		_vp.msaa_3d = int(k["msaa"]) as Viewport.MSAA
		_vp.mesh_lod_threshold = float(k["lod"])
	_rs("directional_shadow_atlas_set_size", [int(k["atlas"]), bool(k["atlas_16"])])
	_rs("directional_soft_shadow_filter_set_quality", [int(k["soft"])])
	_rs("environment_set_ssao_quality", [int(k["ssao"]), bool(k["ssao_half"]), float(_rs_snap["ssao_target"]), int(_rs_snap["ssao_blur"]), float(_rs_snap["ssao_from"]), float(_rs_snap["ssao_to"])])
	_rs("environment_set_ssil_quality", [int(k["ssil"]), bool(k["ssil_half"]), float(_rs_snap["ssil_target"]), int(_rs_snap["ssil_blur"]), float(_rs_snap["ssil_from"]), float(_rs_snap["ssil_to"])])
	var cam := _camera()
	if cam != null:
		if _cam_far < 0.0:
			_cam_far = cam.far
		cam.far = Q.camera_far(preset)
	var mult := Q.vis_mult(preset)
	if hlod != null and hlod.view != null:
		hlod.set_ranges(WS.VIS_BUILDING * mult, WS.VIS_BUILDING_NEAR * mult, WS.VIS_PROP * mult)
		_job = hlod.tiles.keys()


## True when the viewport and camera carry preset p's knobs (self-test and tests).
func preset_applied(p: String) -> bool:
	var k := Q.knobs(p)
	if _vp == null:
		return false
	var ok := _vp.scaling_3d_mode == int(k["scaling_mode"]) and is_equal_approx(_vp.scaling_3d_scale, float(k["scale"]))
	ok = ok and _vp.msaa_3d == int(k["msaa"]) and is_equal_approx(_vp.mesh_lod_threshold, float(k["lod"]))
	var cam := _camera()
	return ok and (cam == null or is_equal_approx(cam.far, Q.camera_far(p)))


## Tiles still waiting to be re-ranged after a preset switch.
func job_pending() -> int:
	return _job.size()


## Runs every pending re-range, mid-LOD merge and chunk rebuild now (tests and tools).
func flush() -> void:
	if hlod.view != null:
		hlod.midlod.wait_all()
		_run_waiting(1 << 30)
	_run_job(1 << 30)
	while not _dirty.is_empty():
		_rebuild_one()


func self_test() -> Dictionary:
	if ctx.view == null:
		return {"ok": preset_applied(preset), "detail": "no view; preset %s" % preset}
	var fails: Array[String] = []
	if not preset_applied(preset):
		fails.append("preset %s not applied" % preset)
	if not active:
		fails.append("post-pass inactive")
	elif _vp == null or not _vp.use_occlusion_culling:
		fails.append("occlusion culling off")
	var solid := 0
	for e: Dictionary in hlod.tiles.values():
		if bool(e["solid"]):
			solid += 1
	var boxes: int = occluders.box_count()
	if boxes * 10 < solid:
		fails.append("occluder boxes %d for %d solid tiles" % [boxes, solid])
	var near := 0
	var p := ctx.player_position()
	for i: int in hlod.tiles.keys():
		var e: Dictionary = hlod.tiles[i]
		if Vector2(D.tx(i) - p.x, D.ty(i) - p.z).length() > 10.0 or str(e["path"]).is_empty():
			continue
		for k in range((e["gis"] as Array).size()):
			var gi: Variant = (e["gis"] as Array)[k]
			if is_instance_valid(gi) and (e["cls"] as PackedByteArray)[k] == HLOD.Cls.BUILDING and (gi as GeometryInstance3D).visibility_range_end <= 0.0:
				fails.append("tile %d unranged" % i)
				break
		near += 1
	var detail := "preset=%s tiles=%d near=%d solid=%d boxes=%d impostor_chunks=%d" % [preset, hlod.tiles.size(), near, solid, boxes, hlod.chunk_nodes.size()]
	return {"ok": fails.is_empty(), "detail": detail if fails.is_empty() else detail + " " + str(fails)}


## A skyline from a road just beyond the impostor switch, facing the tallest part of the city, by
## day and by night (the far buildings there are impostors).
func photo_shots() -> Array:
	if ctx.view == null or ctx.collision == null or not active:
		return []
	var mass := Vector3.ZERO
	var w := 0.0
	var solid: Array[Vector3] = []
	for e: Dictionary in hlod.tiles.values():
		if bool(e["solid"]):
			var p: Vector3 = e["center"]
			solid.append(p)
			mass += Vector3(p.x, 0.0, p.z) * p.y
			w += p.y
	if w <= 0.0:
		return []
	mass /= w
	var vis: float = hlod.vis_building
	var best := Vector3(NAN, NAN, NAN)
	var best_n := -1
	for i in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD or ctx.sim.terrain[i] == D.WATER:
			continue
		var at := Vector3(D.tx(i), 0.0, D.ty(i))
		var d := at.distance_to(mass)
		if d < vis + 3.0 or d > vis + 12.0:
			continue
		var dir := (mass - at).normalized()
		var n := 0
		for p: Vector3 in solid:
			var to := Vector3(p.x, 0.0, p.z) - at
			if to.length() > vis and to.normalized().dot(dir) > 0.85:
				n += 1
		if n > best_n:
			best_n = n
			best = at
	if is_nan(best.x):
		return []
	var g := ctx.collision.ground_height(best)
	best.y = g if not is_nan(g) else 0.0
	var look := mass - best
	var yaw := rad_to_deg(atan2(-look.x, -look.z))
	return [
		{"name": "g2_skyline", "pos": best, "yaw": yaw, "pitch": 3.0, "hour": 10.5},
		{"name": "g2_skyline_night", "pos": best, "yaw": yaw, "pitch": 3.0, "hour": 22.5},
	]


func _process(_delta: float) -> void:
	if not active:
		return
	if not _job.is_empty():
		_run_job(JOB_BUDGET_USEC)
	if hlod.midlod.poll() > 0:
		_waiting_ready = true
	if _waiting_ready:
		_run_waiting(WAIT_BUDGET_USEC)
	if not _dirty.is_empty():
		_rebuild_one()
	var n: float = ctx.view.night
	if absf(n - _night) > 0.002:
		_night = n
		hlod.material.set_shader_parameter("night", n)
		hlod.midlod.material.set_shader_parameter("night", n)


func _activate() -> void:
	if hlod.view == null:
		return
	active = true
	hlod.clear()
	occluders.clear()
	_dirty.clear()
	_job.clear()
	for i: int in ctx.sim.active:
		var h := ctx.view.tile_holder(i)
		if h != null and is_instance_valid(h):
			hlod.post_pass(i, h)
	for c: Vector2i in hlod.chunk_tiles.keys():
		hlod.rebuild_chunk(c)
		occluders.rebuild_chunk(c, hlod)
	if _vp != null:
		_vp.use_occlusion_culling = true


## Undo: no ranges, authored shadows, no impostors or occluders, occlusion culling as before.
func _deactivate() -> void:
	if not active:
		return
	active = false
	hlod.midlod.wait_all()
	_wait_queue.clear()
	_waiting_ready = false
	for e: Dictionary in hlod.tiles.values():
		HLOD.restore(e)
	hlod.set_visible(false)
	occluders.set_visible(false)
	hlod.clear()
	occluders.clear()
	_dirty.clear()
	_job.clear()
	if _vp != null and _vp_snap.has("use_occlusion_culling"):
		_vp.use_occlusion_culling = bool(_vp_snap["use_occlusion_culling"])


func _on_tile_built(i: int, holder: Node3D) -> void:
	if not active or ctx.view.in_setup:
		return
	_dirty[hlod.post_pass(i, holder)] = true


func _on_tile_cleared(i: int) -> void:
	if active:
		_dirty[hlod.drop(i)] = true


func _on_fp_mode_changed(on: bool) -> void:
	if on and not ctx.view.in_setup:
		_activate()
	elif not on:
		_deactivate()


func _on_quality_changed(p: String) -> void:
	apply_preset(p)


## Re-passes the tiles that waited for a mid-LOD merge (some may wait again for another mesh).
func _run_waiting(budget_usec: int) -> void:
	if _wait_queue.is_empty():
		_wait_queue = hlod.waiting.keys()
	var t0 := Time.get_ticks_usec()
	while not _wait_queue.is_empty() and Time.get_ticks_usec() - t0 < budget_usec:
		var i: int = _wait_queue.pop_back()
		if not hlod.waiting.has(i):
			continue
		var h := ctx.view.tile_holder(i)
		if h != null and is_instance_valid(h):
			_dirty[hlod.post_pass(i, h)] = true
		else:
			hlod.waiting.erase(i)
	if _wait_queue.is_empty():
		_waiting_ready = false


func _run_job(budget_usec: int) -> void:
	var t0 := Time.get_ticks_usec()
	while not _job.is_empty() and Time.get_ticks_usec() - t0 < budget_usec:
		var i: int = _job.pop_back()
		if hlod.tiles.has(i):
			hlod.apply_ranges(hlod.tiles[i])


func _rebuild_one() -> void:
	var c: Vector2i = _dirty.keys()[0]
	_dirty.erase(c)
	hlod.rebuild_chunk(c)
	occluders.rebuild_chunk(c, hlod)


func _rs(fn: String, args: Array) -> void:
	RenderingServer.callv(fn, args)
	rs_calls[fn] = args.duplicate()


func _camera() -> Camera3D:
	return ctx.player.camera if ctx.player != null and is_instance_valid(ctx.player) else null


func _child_root(n: String) -> Node3D:
	var r := ctx.world_root.get_node_or_null(n) as Node3D
	if r == null:
		r = Node3D.new()
		r.name = n
		ctx.world_root.add_child(r)
	return r


## Every knob this feature touches, from its current value or the project settings.
func _snapshot() -> void:
	if _vp != null:
		for key: String in VIEWPORT_KEYS:
			_vp_snap[key] = _vp.get(key)
	for key: String in RS_SETTINGS:
		_rs_snap[key] = ProjectSettings.get_setting(RS_SETTINGS[key], RS_DEFAULTS[key])


func _restore() -> void:
	if _vp != null:
		for key: String in _vp_snap:
			_vp.set(key, _vp_snap[key])
	var s := _rs_snap
	_rs("directional_shadow_atlas_set_size", [int(s["atlas"]), bool(s["atlas_16"])])
	_rs("directional_soft_shadow_filter_set_quality", [int(s["soft"])])
	_rs("environment_set_ssao_quality", [int(s["ssao"]), bool(s["ssao_half"]), float(s["ssao_target"]), int(s["ssao_blur"]), float(s["ssao_from"]), float(s["ssao_to"])])
	_rs("environment_set_ssil_quality", [int(s["ssil"]), bool(s["ssil_half"]), float(s["ssil_target"]), int(s["ssil_blur"]), float(s["ssil_from"]), float(s["ssil_to"])])
	var cam := _camera()
	if cam != null and _cam_far > 0.0:
		cam.far = _cam_far
