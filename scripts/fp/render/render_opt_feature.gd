extends FpFeature
## Render performance (slice G2): applies the quality preset (FSR2 scaling, shadow atlas and filter,
## SSAO and SSIL quality, mesh LOD threshold, camera far plane) and restores every knob on teardown;
## on foot it ranges every tile holder's parts (hlod.gd), draws far buildings as merged chunk
## impostors and culls with per-chunk occluders (occluders.gd). Tile post-passes queue on tile_built
## and run under a per-frame budget (FRAME_BUDGET_USEC), followed by at most one chunk rebuild.
## Aerial coverage: once the camera is AERIAL_MIN above the hero (the city overview lifts it, and so
## does a photo fly), roads, open construction sites, far trees, the fog end and the far plane widen
## so the city stays whole from the sky at every zoom. Every value is re-derived on exit, so a
## preset or weather change mid-air never leaves a stale value behind.

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const HLOD := preload("res://scripts/fp/render/hlod.gd")
const OCCLUDERS := preload("res://scripts/fp/render/occluders.gd")
## A preset switch re-ranges cached parts for at most this long per frame.
const JOB_BUDGET_USEC := 3000
## Tiles re-passed per frame once their mid-LOD merges finish, at most this long.
const WAIT_BUDGET_USEC := 2000
## Queued tile post-passes, mid-LOD uploads and the chunk rebuild share this much of a frame. A
## tick emission builds 10 to 40 tiles, so the queue drains within a few frames; one step always
## runs, so nothing starves on a slow frame.
const FRAME_BUDGET_USEC := 2000
## The camera is aerial once it is this far above the hero's feet (60 m: over every roof), and
## stops once it sinks back below AERIAL_OFF (hysteresis, so the toggle never flaps at the line).
const AERIAL_MIN := 3.0
const AERIAL_OFF := 2.4
## While aerial, open sites re-scan for parts this often (update_site adds parts without a
## tile_built), so a rising frame's new floor shows from the sky too.
const SITE_RESCAN := 0.5
## Project defaults of the global RenderingServer knobs (headless has no getters for them).
const RS_SETTINGS := {
	"atlas": "rendering/lights_and_shadows/directional_shadow/size",
	"atlas_16": "rendering/lights_and_shadows/directional_shadow/16_bits",
	"soft": "rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality",
	"ssao": "rendering/environment/ssao/quality",
	"ssao_half": "rendering/environment/ssao/half_size",
	"ssao_target": "rendering/environment/ssao/adaptive_target",
	"ssao_blur": "rendering/environment/ssao/blur_passes",
	"ssao_from": "rendering/environment/ssao/fadeout_from",
	"ssao_to": "rendering/environment/ssao/fadeout_to",
	"ssil": "rendering/environment/ssil/quality",
	"ssil_half": "rendering/environment/ssil/half_size",
	"ssil_target": "rendering/environment/ssil/adaptive_target",
	"ssil_blur": "rendering/environment/ssil/blur_passes",
	"ssil_from": "rendering/environment/ssil/fadeout_from",
	"ssil_to": "rendering/environment/ssil/fadeout_to",
}
const RS_DEFAULTS := {
	"atlas": 4096,
	"atlas_16": true,
	"soft": 2,
	"ssao": 2,
	"ssao_half": true,
	"ssao_target": 0.5,
	"ssao_blur": 2,
	"ssao_from": 50.0,
	"ssao_to": 300.0,
	"ssil": 2,
	"ssil_half": true,
	"ssil_target": 0.5,
	"ssil_blur": 4,
	"ssil_from": 50.0,
	"ssil_to": 300.0,
}
## The sun keys the aerial coverage widens (the reach, then the three cascade splits).
const SHADOW_KEYS := [
	"directional_shadow_max_distance",
	"directional_shadow_split_1",
	"directional_shadow_split_2",
	"directional_shadow_split_3",
]
const VIEWPORT_KEYS := [
	"scaling_3d_mode", "scaling_3d_scale", "msaa_3d", "mesh_lod_threshold", "use_occlusion_culling"
]

## The applied preset: "low", "medium" or "high".
var preset: String = Q.DEFAULT
## Aerial coverage on: the camera is over the city (the overview, a photo fly).
var aerial: bool = false
var hlod: RefCounted
var occluders: RefCounted
## Last arguments of every RenderingServer setter this feature called (headless has no getters).
var rs_calls: Dictionary = {}
## The post-pass is live (on foot, set up).
var active: bool = false
## Main-thread cost of this feature's per-frame work (µs): the last frame and the worst since
## reset_stats(); the bench reports both.
var frame_us: int = 0
var frame_us_max: int = 0
## Worst single tile post-pass (µs) since reset_stats().
var pass_us_max: int = 0
## Worst warm step (one model proxy or one mid-LOD gather before a pass, µs) since reset_stats().
var warm_us_max: int = 0
## Worst chunk rebuild (impostor and occluder, µs) since reset_stats().
var rebuild_us_max: int = 0
## Microsecond clock for the frame budget; tests inject a fake one so budgets are deterministic.
var clock: Callable = Time.get_ticks_usec
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
## The street profile's sun shadow reach and three splits, as it last set them; empty when none is
## held. _shadow_set is the aerial reach this feature last wrote.
var _street_shadow: Array = []
var _shadow_set: float = -1.0
## Seconds since the last open-site re-scan while aerial.
var _aerial_site_t: float = 0.0
## Tiles built since their last post-pass: tile index -> holder, in arrival order.
var _pass_queue: Dictionary = {}


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
		for pair: Array in [
			[ctx.view.tile_built, _on_tile_built],
			[ctx.view.tile_cleared, _on_tile_cleared],
			[ctx.view.fp_mode_changed, _on_fp_mode_changed]
		]:
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
	_rs(
		"environment_set_ssao_quality",
		[
			int(k["ssao"]),
			bool(k["ssao_half"]),
			float(_rs_snap["ssao_target"]),
			int(_rs_snap["ssao_blur"]),
			float(_rs_snap["ssao_from"]),
			float(_rs_snap["ssao_to"])
		]
	)
	_rs(
		"environment_set_ssil_quality",
		[
			int(k["ssil"]),
			bool(k["ssil_half"]),
			float(_rs_snap["ssil_target"]),
			int(_rs_snap["ssil_blur"]),
			float(_rs_snap["ssil_from"]),
			float(_rs_snap["ssil_to"])
		]
	)
	var cam := _camera()
	if cam != null:
		if _cam_far < 0.0:
			_cam_far = cam.far
		cam.far = _far_now()
	var mult := Q.vis_mult(preset)
	if hlod != null and hlod.view != null:
		hlod.set_ranges(WS.VIS_BUILDING * mult, WS.VIS_BUILDING_NEAR * mult, WS.VIS_PROP * mult)
		_job = hlod.tiles.keys()
	# A preset switch re-applies the street profile's fog end and shadows; the aerial push goes back
	# on top.
	if aerial and cam != null and cam.environment != null:
		cam.environment.fog_depth_end = Q.aerial_fog_end(preset)
	if aerial:
		_aerial_shadows(true)


## True when the viewport and camera carry preset p's knobs (self-test and tests).
func preset_applied(p: String) -> bool:
	var k := Q.knobs(p)
	if _vp == null:
		return false
	var ok := (
		_vp.scaling_3d_mode == int(k["scaling_mode"])
		and is_equal_approx(_vp.scaling_3d_scale, float(k["scale"]))
	)
	ok = (
		ok
		and _vp.msaa_3d == int(k["msaa"])
		and is_equal_approx(_vp.mesh_lod_threshold, float(k["lod"]))
	)
	var cam := _camera()
	return ok and (cam == null or is_equal_approx(cam.far, _far_now()))


## The far plane the camera should carry now: the aerial plane while it is over the city, else the
## preset's street plane.
func _far_now() -> float:
	return Q.aerial_far(preset) if aerial else Q.camera_far(preset)


## Turns the aerial coverage on or off: while on, the camera is over the city, so road mains and
## twins (hlod.set_aerial, re-ranged through _job), far trees (CityView.set_aerial), open site
## parts (ConstructionKit.aerial_ranges), the fog end and the far plane widen to keep the whole
## city visible at every zoom. On exit each value is re-derived from the preset and the kit, never
## from an entry snapshot, so a preset or weather change mid-air cannot leave a stale value.
func set_aerial(on: bool) -> void:
	if aerial == on:
		return
	aerial = on
	hlod.set_aerial(on)
	_job = hlod.tiles.keys()
	if ctx.view != null:
		ctx.view.set_aerial(on)
	_range_sites(on)
	var cam := _camera()
	if cam != null:
		cam.far = _far_now()
		if cam.environment != null:
			# The fog begin stays untouched (the street profile and weather's override own it);
			# only the end moves, and it comes back as the street profile's own value on exit.
			var fog_end := Q.aerial_fog_end(preset) if on else Q.street_fog_end(preset)
			cam.environment.fog_depth_end = fog_end
	_aerial_shadows(on)
	_aerial_site_t = 0.0


## The sun's shadow reach while aerial. The street profile (G1) owns the street values, so they
## are read off the sun as it last set them: on entry, and after a preset switch (G1 registers
## first, so its quality handler has re-applied them before apply_preset runs). Exit writes back
## that latest street value, never one from before a preset switch.
func _aerial_shadows(on: bool) -> void:
	var sun := ctx.sun
	if sun == null or not is_instance_valid(sun):
		return
	var keys := SHADOW_KEYS
	if on:
		var reach := sun.directional_shadow_max_distance
		if _street_shadow.is_empty() or not is_equal_approx(reach, _shadow_set):
			_street_shadow = keys.map(func(k: String) -> float: return float(sun.get(k)))
		_shadow_set = Q.aerial_shadow(preset)
		var vals: Array = [_shadow_set] + Q.AERIAL_SHADOW_SPLITS
		for k in range(keys.size()):
			sun.set(keys[k], vals[k])
	elif not _street_shadow.is_empty():
		for k in range(keys.size()):
			sun.set(keys[k], _street_shadow[k])
		_street_shadow = []
		_shadow_set = -1.0


## The camera is over the city once it is AERIAL_MIN above the hero's feet (the overview's rig and a
## photo fly lift it; the drive camera rides at car height and never trips this).
func _check_aerial() -> void:
	if ctx.player == null or not is_instance_valid(ctx.player):
		return
	var cam := _camera()
	if cam == null:
		return
	var h := cam.global_position.y - ctx.player.position.y
	if aerial:
		if h <= AERIAL_OFF:
			set_aerial(false)
	elif h > AERIAL_MIN:
		set_aerial(true)


## Ranges every open site's parts for the aerial coverage (construction_kit.gd snapshots and
## restores each part's own end).
func _range_sites(on: bool) -> void:
	if ctx.view == null or ctx.sim == null or ctx.view.kit == null:
		return
	for i: int in ctx.sim.sites.keys():
		var h := ctx.view.tile_holder(i)
		var site: Node3D = null
		if h != null and is_instance_valid(h):
			site = h.get_node_or_null("Site")
		if site != null:
			ctx.view.kit.aerial_ranges(site, on)


## Tiles still waiting to be re-ranged after a preset switch.
func job_pending() -> int:
	return _job.size()


## Tiles whose post-pass is still queued.
func pass_pending() -> int:
	return _pass_queue.size()


## Runs every pending re-range, post-pass, mid-LOD merge and chunk rebuild now (tests and tools).
func flush() -> void:
	if hlod.view != null:
		_run_passes(1 << 62)
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
			if (
				is_instance_valid(gi)
				and (e["cls"] as PackedByteArray)[k] == HLOD.Cls.BUILDING
				and (gi as GeometryInstance3D).visibility_range_end <= 0.0
			):
				fails.append("tile %d unranged" % i)
				break
		near += 1
	var detail := (
		"preset=%s tiles=%d near=%d solid=%d boxes=%d impostor_chunks=%d"
		% [preset, hlod.tiles.size(), near, solid, boxes, hlod.chunk_nodes.size()]
	)
	return {
		"ok": fails.is_empty(), "detail": detail if fails.is_empty() else detail + " " + str(fails)
	}


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


## Clears the worst-case timings (the bench calls it before each measurement).
func reset_stats() -> void:
	frame_us_max = 0
	pass_us_max = 0
	warm_us_max = 0
	rebuild_us_max = 0


func _process(delta: float) -> void:
	if not active:
		return
	var t0: int = clock.call()
	_frame_work(t0 + FRAME_BUDGET_USEC)
	_check_aerial()
	if aerial:
		# update_site raises frames and adds parts without a tile_built: re-range them now and then.
		_aerial_site_t += delta
		if _aerial_site_t >= SITE_RESCAN:
			_aerial_site_t = 0.0
			_range_sites(true)
	frame_us = int(clock.call()) - t0
	frame_us_max = maxi(frame_us_max, frame_us)


## One frame's share: queued post-passes until deadline (at least one step), finished mid-LOD
## merges, then one chunk rebuild if time is left once every queued tile has its pass.
func _frame_work(deadline: int) -> void:
	if not _job.is_empty():
		_run_job(JOB_BUDGET_USEC)
	var ran := _run_passes(deadline)
	if (not ran or int(clock.call()) < deadline) and hlod.midlod.poll(deadline, clock) > 0:
		_waiting_ready = true
	if _waiting_ready and _pass_queue.is_empty():
		_run_waiting(mini(WAIT_BUDGET_USEC, maxi(0, deadline - int(clock.call()))))
	if (
		not _dirty.is_empty()
		and _pass_queue.is_empty()
		and (not ran or int(clock.call()) < deadline)
	):
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
	_pass_queue.clear()
	for i: int in ctx.sim.active:
		var h := ctx.view.tile_holder(i)
		if h != null and is_instance_valid(h):
			hlod.post_pass(i, h)
	for c: Vector2i in hlod.chunk_tiles.keys():
		hlod.rebuild_chunk(c)
		occluders.rebuild_chunk(c, hlod)
	if _vp != null:
		_vp.use_occlusion_culling = true
	if aerial and ctx.view != null:
		# The rebuild replaced the trees and the sites; the coverage goes back on.
		ctx.view.set_aerial(true)
		_range_sites(true)


## Undo: no ranges, authored shadows, no impostors or occluders, occlusion culling as before.
func _deactivate() -> void:
	if not active:
		return
	active = false
	if aerial:
		# Restores the fog end, the far plane, the trees and the sites before the teardown undoes
		# the rest.
		set_aerial(false)
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
	_pass_queue.clear()
	if _vp != null and _vp_snap.has("use_occlusion_culling"):
		_vp.use_occlusion_culling = bool(_vp_snap["use_occlusion_culling"])


func _on_tile_built(i: int, holder: Node3D) -> void:
	# G1 rebuilds every tile for orbit before it announces fp_mode_changed(false).
	if not active or ctx.view.in_setup or not ctx.view.fp_mode:
		return
	_pass_queue.erase(i)
	_pass_queue[i] = holder


func _on_tile_cleared(i: int) -> void:
	if active:
		_pass_queue.erase(i)
		_dirty[hlod.drop(i)] = true


## Post-passes queued tiles, oldest first, until deadline; the first step always runs. A tile whose
## model is new first warms its proxy and mid-LOD merges, one step each. True if any step ran.
func _run_passes(deadline: int) -> bool:
	var ran := false
	while not _pass_queue.is_empty() and (not ran or int(clock.call()) < deadline):
		var i: int = _pass_queue.keys()[0]
		var holder: Node3D = _pass_queue[i]
		if holder == null or not is_instance_valid(holder):
			holder = ctx.view.tile_holder(i)
			_pass_queue[i] = holder
		ran = true
		var t0: int = clock.call()
		if hlod.warm(holder):
			warm_us_max = maxi(warm_us_max, int(clock.call()) - t0)
			continue
		_pass_queue.erase(i)
		_dirty[hlod.post_pass(i, holder)] = true
		pass_us_max = maxi(pass_us_max, int(clock.call()) - t0)
		if aerial and ctx.view != null and ctx.view.kit != null:
			# A tile rebuilt mid-air: its site's parts (a new site, a paved road) draw out too.
			var site := holder.get_node_or_null("Site") as Node3D
			if site != null:
				ctx.view.kit.aerial_ranges(site, true)
	return ran


func _on_fp_mode_changed(on: bool) -> void:
	# G1's set_fp_mode emits world_rebuilt first, which FpMode turns into on_world_rebuilt().
	if on and not ctx.view.in_setup and not active:
		_activate()
	elif not on:
		_deactivate()


func _on_quality_changed(p: String) -> void:
	apply_preset(p)


## Re-passes the tiles that waited for a mid-LOD merge (some may wait again for another mesh).
func _run_waiting(budget_usec: int) -> void:
	if _wait_queue.is_empty():
		_wait_queue = hlod.waiting.keys()
	var t0: int = clock.call()
	while not _wait_queue.is_empty() and int(clock.call()) - t0 < budget_usec:
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
	var t0: int = clock.call()
	hlod.rebuild_chunk(c)
	occluders.rebuild_chunk(c, hlod)
	rebuild_us_max = maxi(rebuild_us_max, int(clock.call()) - t0)


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
	_rs(
		"environment_set_ssao_quality",
		[
			int(s["ssao"]),
			bool(s["ssao_half"]),
			float(s["ssao_target"]),
			int(s["ssao_blur"]),
			float(s["ssao_from"]),
			float(s["ssao_to"])
		]
	)
	_rs(
		"environment_set_ssil_quality",
		[
			int(s["ssil"]),
			bool(s["ssil_half"]),
			float(s["ssil_target"]),
			int(s["ssil_blur"]),
			float(s["ssil_from"]),
			float(s["ssil_to"])
		]
	)
	var cam := _camera()
	if cam != null and _cam_far > 0.0:
		cam.far = _cam_far
