extends SceneTree
## City overview (integration feature "overview"): Tab lifts the camera into an aerial view with a
## marker per open construction site; N / B select sites, F walks the hero there, G sets a waypoint,
## Tab / Esc return to the hero's own camera; the same from a gamepad. Runs in third person on a
## grown city.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DT := 1.0 / 60.0
## Actions a controller player needs on foot and in the overview.
const ON_FOOT_PAD := [
	"move_forward", "move_back", "move_left", "move_right",
	"look_left", "look_right", "look_up", "look_down",
	"jump", "crouch", "sprint", "interact", "view_toggle", "shoulder_swap",
	"zoom_in", "zoom_out", "photo_mode", "map_toggle", "pause_menu",
	"time_faster", "time_slower", "overview_toggle",
	"site_next", "site_prev", "site_go", "site_waypoint",
]
## Live at the same time on the street; the overview's site actions reuse buttons while it owns
## input.
const ON_FOOT_UNIQUE := [
	"jump", "crouch", "sprint", "interact", "view_toggle", "shoulder_swap", "zoom_in",
	"zoom_out", "photo_mode", "map_toggle", "pause_menu", "time_faster", "time_slower",
	"overview_toggle",
]

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	var p := ctx.player
	p.set_process(false)
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
	_check_teardown(ctx, f)
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


func _check_teardown(ctx: FpContext, f: FpFeature) -> void:
	f.call("enter")
	f.teardown()
	K.check(fails, not ctx.has_modal(&"overview") and not ctx.player.view_override, "teardown pops the modal and frees the camera")


func _action(a: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = a
	e.pressed = true
	return e
