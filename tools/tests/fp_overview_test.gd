extends SceneTree
## City overview (integration feature "overview"): Tab lifts the camera into an aerial view with a
## marker per open construction site; N / B select sites, F walks the hero there, G sets a waypoint,
## Tab / Esc return to the hero's own camera; the same from a gamepad. Runs in third person on a
## grown city.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const HLOD := preload("res://scripts/fp/render/hlod.gd")
const DT := 1.0 / 60.0
## Actions a controller player needs on foot and in the overview.
const ON_FOOT_PAD := [
	"move_forward", "move_back", "move_left", "move_right",
	"look_left", "look_right", "look_up", "look_down",
	"jump", "crouch", "sprint", "interact", "view_toggle", "shoulder_swap",
	"zoom_in", "zoom_out", "photo_mode", "map_toggle", "pause_menu",
	"time_faster", "time_slower", "overview_toggle", "act_strike", "act_aim",
	"site_next", "site_prev", "site_go", "site_waypoint",
]
## Live at the same time on the street; the overview's site actions reuse buttons while it owns
## input.
const ON_FOOT_UNIQUE := [
	"jump", "crouch", "sprint", "interact", "view_toggle", "shoulder_swap", "zoom_in",
	"zoom_out", "photo_mode", "map_toggle", "pause_menu", "time_faster", "time_slower",
	"overview_toggle", "act_strike", "act_aim",
]

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	var opts := {"view": true, "grow": true, "render": true, "camera_mode": "third"}
	var ctx := K.make_ctx(get_root(), opts)
	var p := ctx.player
	p.set_process(false)
	ctx.view.set_fp_mode(true)
	var ro: FpFeature = K.make_feature(ctx, "render_opt")
	K.make_feature(ctx, "hud_widgets")
	var f: FpFeature = K.make_feature(ctx, "overview")
	K.check(fails, f != null and f.feature_id() == "overview", "the overview feature is registered")
	if f == null:
		K.finish(self, "FP_OVERVIEW_TEST", fails)
		return
	f.set_process(false)
	var extra := 0
	while (f.call("site_list") as Array).is_empty() and extra < 60:
		ctx.sim.step_tick()
		extra += 1
	K.check(fails, not (f.call("site_list") as Array).is_empty(), "fixture: the grown city has open construction sites (%d extra ticks)" % extra)
	_check_enter(ctx, f)
	_check_markers(ctx, f)
	_check_select(ctx, f)
	_check_time(ctx, f)
	_check_waypoint(ctx, f)
	_check_walk(ctx, f)
	_check_keys(ctx, f)
	_check_gamepad(ctx, f)
	_check_guards(ctx, f)
	_check_first_person(ctx, f)
	_check_toast(ctx, f)
	await _check_sky_view(ctx, f, ro)
	_check_teardown(ctx, f)
	_check_orbit_focus()
	K.finish(self, "FP_OVERVIEW_TEST", fails)


func _step(ctx: FpContext, f: FpFeature, secs: float) -> void:
	var n := ceili(secs / DT)
	for _k in range(n):
		f._process(DT)
		ctx.player.update_view(DT)


func _cam(ctx: FpContext) -> Transform3D:
	return ctx.player.camera.global_transform


## Where the camera's view axis meets the ground (y = 0).
func _ground_hit(xf: Transform3D) -> Vector3:
	var n := -xf.basis.z
	if n.y > -1e-4:
		return Vector3(NAN, NAN, NAN)
	return xf.origin + n * (-xf.origin.y / n.y)


func _check_enter(ctx: FpContext, f: FpFeature) -> void:
	var p := ctx.player
	_step(ctx, f, 0.5)
	var head := p.eye_position()
	K.check(fails, f.call("enter") == true and bool(f.get("active")), "enter() opens the overview")
	K.check(fails, ctx.has_modal(&"overview") and p.view_override, "it pushes the overview modal and takes the player's camera")
	_step(ctx, f, 1.0)
	var xf := _cam(ctx)
	K.check(fails, xf.origin.y > 4.0 and xf.origin.y - head.y > 4.0, "the camera is high over the city (%.1f u, 20 m per u)" % xf.origin.y)
	K.check(fails, -xf.basis.z.y < -0.7, "it looks down on the city (%.2f)" % -xf.basis.z.y)
	var hit := _ground_hit(xf)
	K.check(fails, Vector2(hit.x - p.position.x, hit.z - p.position.z).length() < 0.2, "it starts centred over the hero")
	K.check(fails, xf.origin.distance_to((f.call("camera_xform") as Transform3D).origin) < 1e-3, "after the blend the camera is the overview rig's")
	var ui: CanvasLayer = f.get("_layer")
	K.check(fails, ui != null and ui.visible, "the site panel shows")
	K.check(fails, get_root().get_viewport().get_camera_3d() == p.camera, "player.camera stays the current camera (features keep streaming around it)")


func _check_markers(ctx: FpContext, f: FpFeature) -> void:
	var list: Array = f.call("site_list")
	var markers: Dictionary = f.get("markers")
	K.check(fails, markers.size() == list.size(), "one marker per open site (%d / %d)" % [markers.size(), list.size()])
	var ok := true
	for i: int in markers.keys():
		var lbl := (markers[i] as Node3D).get_node("Label") as Label3D
		if lbl == null or not lbl.text.contains("%") or not lbl.no_depth_test:
			ok = false
		if ctx.sim.sites.has(i) and str(ctx.sim.sites[i]["type"]) == "road":
			ok = false
	K.check(fails, ok, "markers show name, stage and percent, draw through buildings, skip road paving")
	var rows: VBoxContainer = f.get("_rows")
	var shown := 0
	for b in rows.get_children():
		if (b as Control).visible:
			shown += 1
	K.check(fails, shown == mini(list.size(), 8), "the panel lists the sites (%d rows)" % shown)


func _check_select(ctx: FpContext, f: FpFeature) -> void:
	var list: Array = f.call("site_list")
	K.check(fails, f.call("select_step", 1) == true and int(f.get("selected")) == int(list[0]["i"]), "N selects the newest site")
	_step(ctx, f, 2.5)
	var i := int(f.get("selected"))
	var hit := _ground_hit(_cam(ctx))
	K.check(fails, Vector2(hit.x - D.tx(i), hit.z - D.ty(i)).length() < 0.1, "the camera flies over the selected site")
	if list.size() > 1:
		f.call("select_step", 1)
		K.check(fails, int(f.get("selected")) == int(list[1]["i"]), "N again moves on to the next site")
		f.call("select_step", -1)
		K.check(fails, int(f.get("selected")) == int(list[0]["i"]), "B goes back")
	var markers: Dictionary = f.get("markers")
	var lbl := (markers[i] as Node3D).get_node("Label") as Label3D
	K.check(fails, lbl.modulate.is_equal_approx(Color("#00E0FF")), "the selected marker is highlighted")
	var detail: Label = f.get("_detail")
	K.check(fails, detail.text.contains("Stage"), "the panel details the selected site (%s)" % detail.text.replace("\n", " / "))


func _check_time(ctx: FpContext, f: FpFeature) -> void:
	var before := ctx.mode.time_scale
	f._unhandled_input(_action("time_faster"))
	K.check(fails, ctx.mode.time_scale > before, "] still speeds time up in the overview (%d -> %d)" % [before, ctx.mode.time_scale])
	f._unhandled_input(_action("time_slower"))
	K.check(fails, ctx.mode.time_scale == before, "[ slows it back down")


func _check_waypoint(ctx: FpContext, f: FpFeature) -> void:
	var i := int(f.get("selected"))
	K.check(fails, f.call("waypoint_to_selected") == true, "G sets a waypoint to the selected site")
	var wp: Variant = ctx.hud.waypoint()
	K.check(fails, wp != null and Vector2((wp as Vector3).x - D.tx(i), (wp as Vector3).z - D.ty(i)).length() < 1.6, "the waypoint is at a vantage point by the site")
	K.check(fails, not bool(f.get("active")) and not ctx.has_modal(&"overview") and not ctx.player.view_override, "and the camera returns to the hero")
	ctx.hud.clear_waypoint()


func _check_walk(ctx: FpContext, f: FpFeature) -> void:
	var p := ctx.player
	f.call("enter")
	_step(ctx, f, 1.0)
	f.call("select_step", 1)
	_step(ctx, f, 1.0)
	var i := int(f.get("selected"))
	K.check(fails, f.call("walk_to_selected") == true, "F walks the hero to the selected site")
	var gap := Vector2(p.position.x - D.tx(i), p.position.z - D.ty(i)).length()
	K.check(fails, gap > 0.7 and gap < 1.6, "the hero stands back from the site, clear of its hoarding (%.2f u from the lot centre)" % gap)
	K.check(fails, not ctx.collision.is_blocked(p.position, WS.PLAYER_RADIUS), "on free ground, not inside a hoarding")
	var to_site := Vector2(D.tx(i) - p.position.x, D.ty(i) - p.position.z).normalized()
	var fwd := Vector2(-sin(p.yaw), -cos(p.yaw))
	K.check(fails, fwd.dot(to_site) > 0.7, "facing the site")
	_step(ctx, f, 1.0)
	var cam := _cam(ctx)
	K.check(fails, cam.origin.distance_to(p.eye_position()) < 0.4, "the camera is back behind the hero (%.2f u)" % cam.origin.distance_to(p.eye_position()))


func _check_keys(ctx: FpContext, f: FpFeature) -> void:
	f._unhandled_input(_action("overview_toggle"))
	K.check(fails, bool(f.get("active")), "Tab opens the overview")
	f._unhandled_input(_action("pause_menu"))
	K.check(fails, not bool(f.get("active")) and not ctx.mode.paused, "Esc closes it without pausing")
	f._unhandled_input(_action("overview_toggle"))
	f._unhandled_input(_action("overview_toggle"))
	K.check(fails, not bool(f.get("active")), "Tab closes it again")
	_step(ctx, f, 1.0)

## Every on-foot action works from a controller, the on-foot buttons do not collide, and the
## overview runs from the pad (Back opens it, the D-pad picks sites without touching time, Y sets
## the waypoint).
func _check_gamepad(ctx: FpContext, f: FpFeature) -> void:
	var missing: Array[String] = []
	var used := {}
	var clash: Array[String] = []
	for a: String in ON_FOOT_PAD:
		var pad := _pad_key(a)
		if pad.is_empty():
			missing.append(a)
		elif ON_FOOT_UNIQUE.has(a):
			if used.has(pad):
				clash.append("%s/%s" % [used[pad], a])
			used[pad] = a
	var miss_msg := "every on-foot action has a gamepad binding (missing %s)"
	K.check(fails, missing.is_empty(), miss_msg % str(missing))
	K.check(fails, clash.is_empty(), "no two on-foot actions share a pad input (%s)" % str(clash))
	var before := ctx.mode.time_scale
	f._unhandled_input(_pad(JOY_BUTTON_BACK))
	K.check(fails, bool(f.get("active")), "Back opens the overview")
	_step(ctx, f, 0.5)
	var list: Array = f.call("site_list")
	f.set("selected", -1)
	f._unhandled_input(_pad(JOY_BUTTON_DPAD_RIGHT))
	var picked := int(f.get("selected")) == int(list[0]["i"])
	var time_kept := ctx.mode.time_scale == before
	K.check(fails, picked and time_kept, "D-pad right picks the next site and leaves time alone")
	f._unhandled_input(_pad(JOY_BUTTON_Y))
	var waypoint_set := ctx.hud.waypoint() != null
	var back := not bool(f.get("active"))
	K.check(fails, waypoint_set and back, "Y sets the waypoint and returns to the hero")
	ctx.hud.clear_waypoint()
	_step(ctx, f, 1.0)


## "b<index>" or "a<axis><sign>" for the action's first pad event, "" when it has none.
func _pad_key(action: String) -> String:
	for e: InputEvent in InputMap.action_get_events(action):
		if e is InputEventJoypadButton:
			return "b%d" % (e as InputEventJoypadButton).button_index
		if e is InputEventJoypadMotion:
			var m := e as InputEventJoypadMotion
			return "a%d%s" % [m.axis, "+" if m.axis_value > 0.0 else "-"]
	return ""


func _pad(button: JoyButton) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.pressed = true
	return e

func _check_guards(ctx: FpContext, f: FpFeature) -> void:
	ctx.push_modal(&"test")
	K.check(fails, f.call("enter") == false, "it does not open over another modal (map, chat, pause)")
	ctx.pop_modal(&"test")
	ctx.player.set_photo_mode(true)
	K.check(fails, f.call("enter") == false, "nor in photo mode")
	ctx.player.set_photo_mode(false)
	f.call("enter")
	f.call("from_dict", {})
	K.check(fails, not bool(f.get("active")) and not ctx.has_modal(&"overview"), "a load closes it")
	_step(ctx, f, 1.0)


func _check_first_person(ctx: FpContext, f: FpFeature) -> void:
	var p := ctx.player
	p.set_camera_mode("first", false)
	f.call("enter")
	_step(ctx, f, 1.0)
	K.check(fails, _cam(ctx).origin.y > 4.0, "first person: the overview lifts the camera too")
	f.call("exit")
	_step(ctx, f, 1.0)
	K.check(fails, not p.camera.top_level and _cam(ctx).origin.distance_to(p.eye_position()) < 0.05, "and gives the eye back")
	p.set_camera_mode("third", false)


func _check_toast(ctx: FpContext, f: FpFeature) -> void:
	var got: Array[String] = []
	var cb := func(t: String, _k: String) -> void: got.append(t)
	ctx.bus.toast.connect(cb)
	f.set("_toast_cool", 0.0)
	var i := int((f.call("site_list") as Array)[0]["i"])
	f.call("_on_site_started", {"type": "build", "plan": "build", "i": i})
	f.call("_on_site_started", {"type": "build", "plan": "build", "i": i})
	K.check(fails, got.size() == 1 and got[0].contains("Tab"), "a new civic project toasts once, pointing at Tab (%s)" % str(got))
	got.clear()
	f.set("_toast_cool", 0.0)
	f.call("_on_site_started", {"type": "zone", "plan": "zone_house", "i": i})
	K.check(fails, got.is_empty(), "everyday house building does not toast")
	ctx.bus.toast.disconnect(cb)


## The sky view itself, at max zoom-out (the user's report): every sampled building stays visible
## (inside the real or mid range, or behind its chunk impostor's switch-on), sparse kinds draw in
## full, the street grid, the woods and the open sites keep drawing, and the far plane and the fog
## reach past the whole visible city. Back on the street everything is restored.
func _check_sky_view(ctx: FpContext, f: FpFeature, ro: FpFeature) -> void:
	var hlod: RefCounted = ro.get("hlod")
	_sky_fixtures(ctx)
	ro.call("flush")
	f.call("enter")
	for _k in range(40):
		f.call("nudge", Vector2.ZERO, 0.0, 0.0, 1.6)
	_step(ctx, f, 1.2)
	for _k in range(4):
		await process_frame
	var cam := ctx.player.camera
	var cam_pos := cam.global_position
	var preset := str(ro.get("preset"))
	var up := bool(ro.get("aerial")) and cam_pos.y > 3.0
	K.check(fails, up, "max zoom-out turns the aerial coverage on (%.1f u up)" % cam_pos.y)
	var max_d := _sky_buildings(ctx, hlod, cam_pos, preset)
	_sky_sparse(ctx, hlod)
	_sky_roads(ctx, hlod)
	K.check(fails, _sky_far_trees(ctx.view), "the far tree layers draw to the horizon")
	var parts := _sky_site_parts(ctx.view, true)
	var sites_msg := "every part of the open sites draws out (%d)" % parts.x
	K.check(fails, parts.x > 0 and parts.y == 0, sites_msg)
	# The horizon: the far plane and fog reach past the farthest sampled building.
	var horizon := is_equal_approx(cam.far, Q.aerial_far(preset))
	horizon = horizon and is_equal_approx(cam.environment.fog_depth_end, Q.aerial_fog_end(preset))
	var msg := "the far plane (%.0f u) and fog end (%.0f u) are the aerial ones"
	K.check(fails, horizon, msg % [cam.far, cam.environment.fog_depth_end])
	var reach := cam.far >= max_d and cam.environment.fog_depth_end >= max_d
	K.check(fails, reach, "past the farthest sampled building too (%.1f u)" % max_d)
	# Back to the street: the coverage goes off and everything is restored.
	f.call("exit")
	_step(ctx, f, 1.5)
	for _k in range(4):
		await process_frame
	_sky_restore(ctx, ro, hlod)


## A park and a wind farm, built instantly when the grown city has neither (the sparse kinds).
func _sky_fixtures(ctx: FpContext) -> void:
	var mode := ctx.sim.construction_mode
	ctx.sim.construction_mode = "instant"
	for key: String in ["park", "wind_farm"]:
		if _has_kind(ctx.sim, int(D.BUILDINGS[key]["kind"])):
			continue
		var act := {"type": "build", "building": key, "x": 12, "y": 10}
		var r: Dictionary = ctx.sim.apply_action(0, act)
		var msg := "sky-view fixture: built a %s (%s)" % [key, r.get("reason", "")]
		K.check(fails, bool(r.get("ok", false)), msg)
	ctx.sim.construction_mode = mode
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")


## Does the city already hold a tile of that kind?
func _has_kind(sim: CitySim, kind: int) -> bool:
	for i: int in sim.active:
		if sim.kind[i] == kind:
			return true
	return false


## Samples up to 24 buildings: each must sit inside the real/mid ladder or behind its chunk
## impostor's switch-on. Returns the farthest sampled distance.
func _sky_buildings(ctx: FpContext, hlod: RefCounted, cam_pos: Vector3, preset: String) -> float:
	var builds: Array[int] = []
	for i: int in ctx.sim.active:
		if D.is_zone(ctx.sim.kind[i]) and ctx.sim.level[i] >= 1:
			builds.append(i)
	K.check(fails, builds.size() >= 20, "fixtures: %d buildings to sample" % builds.size())
	var mult := Q.vis_mult(preset)
	var bad: Array[String] = []
	var max_d := 0.0
	var stride := maxi(1, int(builds.size() / 24.0))
	for n in range(0, builds.size(), stride):
		var i := builds[n]
		var d := cam_pos.distance_to(ctx.view.building_aabb(i).get_center())
		max_d = maxf(max_d, d)
		if not (d <= WS.VIS_BUILDING * mult or _behind_impostor(hlod, i, cam_pos)):
			bad.append("%d@%.1fu" % [i, d])
	var sampled := int(ceili(float(builds.size()) / stride))
	var ok_msg := "%d sampled buildings stay visible %s" % [sampled, str(bad.slice(0, 4))]
	K.check(fails, bad.is_empty(), ok_msg)
	return max_d


## Is tile i already inside the switch-on range of its chunk's merged impostor?
func _behind_impostor(hlod: RefCounted, i: int, cam_pos: Vector3) -> bool:
	var chunk: MeshInstance3D = hlod.chunk_nodes.get(HLOD.chunk_of(i), null)
	if chunk == null:
		return false
	var center := (chunk.global_transform * chunk.get_aabb()).get_center()
	return cam_pos.distance_to(center) >= chunk.visibility_range_begin


## Parks and wind farms draw in full at every distance, from the sky too.
func _sky_sparse(ctx: FpContext, hlod: RefCounted) -> void:
	var parts := 0
	var ok := true
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] not in HLOD.FULL_KINDS:
			continue
		var gis := _tile_gis(hlod, i)
		for k in range(gis.size()):
			parts += 1
			ok = ok and (gis[k] as GeometryInstance3D).visibility_range_end == 0.0
	K.check(fails, ok and parts > 0, "parks and wind farms draw in full (%d parts)" % parts)


## The cached instances of tile i, as post_pass left them.
func _tile_gis(hlod: RefCounted, i: int) -> Array:
	return (hlod.tiles.get(i, {}) as Dictionary).get("gis", [])


## Every road tile keeps at least one part that draws to the horizon.
func _sky_roads(ctx: FpContext, hlod: RefCounted) -> void:
	var roads := 0
	var bad := 0
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD:
			continue
		roads += 1
		if not _road_reaches(hlod, i):
			bad += 1
	K.check(fails, roads > 0 and bad == 0, "all %d road tiles reach the horizon" % roads)


## Does tile i's cached road piece still hold a main or a twin that draws with no end?
func _road_reaches(hlod: RefCounted, i: int) -> bool:
	var e: Dictionary = hlod.tiles.get(i, {})
	var cls: PackedByteArray = e.get("cls", PackedByteArray())
	var gis: Array = e.get("gis", [])
	for k in range(gis.size()):
		if cls[k] != HLOD.Cls.ROAD and cls[k] != HLOD.Cls.MID:
			continue
		if (gis[k] as GeometryInstance3D).visibility_range_end == 0.0:
			return true
	return false


## Every part of the open sites, and how many of them are wrong: Vector2i(parts, bad). While the
## coverage is on each part must draw out; back on the street each must hold its own end again.
func _sky_site_parts(view: CityView, aerial: bool) -> Vector2i:
	var parts := view.site_parts()
	var bad := 0
	for n in parts:
		var gi := n as GeometryInstance3D
		if aerial:
			bad += int(gi.visibility_range_end != 0.0)
		else:
			bad += int(gi.has_meta("ck_aerial_far"))
	return Vector2i(parts.size(), bad)


## The far tree layers (the ones that draw only at distance) cover the sky view.
func _sky_far_trees(view: CityView) -> bool:
	var ok := false
	for layer: Array in (view.get("_tree_chunks") as Dictionary).values():
		for n in layer:
			var mmi := n as MultiMeshInstance3D
			if mmi != null and mmi.visibility_range_begin > 0.0:
				ok = ok or mmi.visibility_range_end == 0.0
	return ok


## Back on the street: the coverage is off, the far plane and fog end are the street values, the
## road pieces are ranged again and the site parts dropped the meta the coverage gave them.
func _sky_restore(ctx: FpContext, ro: FpFeature, hlod: RefCounted) -> void:
	var cam := ctx.player.camera
	var preset := str(ro.get("preset"))
	K.check(fails, not bool(ro.get("aerial")), "back on the street the aerial coverage is off")
	var street := is_equal_approx(cam.far, Q.camera_far(preset))
	street = street and is_equal_approx(cam.environment.fog_depth_end, Q.street_fog_end(preset))
	var msg := "the far plane and fog end are the street values again (%.0f, %.0f)"
	K.check(fails, street, msg % [cam.far, cam.environment.fog_depth_end])
	K.check(fails, _street_ranges(hlod), "the street grid is back on street ranges")
	var parts := _sky_site_parts(ctx.view, false)
	var sites_msg := "the site parts keep their own ends again (%d)" % parts.x
	K.check(fails, parts.x > 0 and parts.y == 0, sites_msg)


## Does a cached road tile's main or twin carry a street end again?
func _street_ranges(hlod: RefCounted) -> bool:
	var ok := true
	for i: int in hlod.tiles.keys():
		var e: Dictionary = hlod.tiles[i]
		if not bool(e["road"]):
			continue
		var cls: PackedByteArray = e["cls"]
		var gis: Array = e["gis"]
		for k in range(gis.size()):
			if cls[k] == HLOD.Cls.ROAD or cls[k] == HLOD.Cls.MID:
				ok = ok and (gis[k] as GeometryInstance3D).visibility_range_end > 0.0
		break
	return ok


func _check_teardown(ctx: FpContext, f: FpFeature) -> void:
	f.call("enter")
	f.teardown()
	K.check(fails, not ctx.has_modal(&"overview") and not ctx.player.view_override, "teardown pops the modal and frees the camera")


func _action(a: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = a
	e.pressed = true
	return e

## The planner camera's focus: a user's request zooms to it as before; attention nobody asked for
## (a sim event, the chaos director's disaster) only pans, so the zoom the user picked survives.
func _check_orbit_focus() -> void:
	var rig_script := load("res://scripts/world/camera_controller.gd") as GDScript
	var rig := rig_script.new() as GridFallCamera
	var cam := Camera3D.new()
	cam.name = "Camera"
	rig.add_child(cam)
	get_root().add_child(rig)
	rig.set_process(false)
	var m := (load("res://scripts/main.gd") as GDScript).new() as Node3D
	m.set("camera_rig", rig)
	var cases := [
		["tile", 30.0, 30.0], ["auto:tile", 30.0, 150.0], ["event:fire", 34.0, 150.0],
		["district:1", 36.0, 36.0],
	]
	for k in range(cases.size()):
		var c: Array = cases[k]
		rig.zoom = 150.0
		var at := Vector3(10.0 + 2.0 * k, 0.0, 12.0)
		m.call("focus", at, float(c[1]), str(c[0]))
		var panned := rig.target_position.is_equal_approx(at)
		var msg := "orbit focus %s at zoom 150: pans there, zoom %.0f (want %.0f)"
		var ok := panned and is_equal_approx(rig.zoom, float(c[2]))
		K.check(fails, ok, msg % [c[0], rig.zoom, c[2]])
	var hud_signals := (load("res://scripts/ui/city_hud.gd") as Script).get_script_signal_list()
	var auto := hud_signals.any(
		func(s: Dictionary) -> bool: return s["name"] == "auto_focus_requested"
	)
	K.check(fails, auto, "CityHud has a separate auto-focus signal for the chaos director")
	m.free()
	rig.queue_free()
