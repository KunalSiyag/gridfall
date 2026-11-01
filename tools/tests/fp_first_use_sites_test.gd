extends SceneTree
## FirstUse's call sites in the game (docs/runbooks/web-probe-kit.md): each first-sight mark fires
## in the code that puts the thing on screen, once per sighting and not again on the frames it
## stays there, and the same code logs nothing with the marks off. Drives the street lights' pool,
## rain, an activity beacon, a construction site, the overview and the pause menu (with Quit to
## orbit) on a grown city; the car beams and the poster composite are held to their call sites by
## tools/pytests/test_web_probe_kit.py. The web path is forced with FirstUse.force
## (JavaScriptBridge does nothing on the desktop). Headless, offline.
## Prints FP_FIRST_USE_SITES_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WEATHER := preload("res://scripts/fp/street/weather.gd")

var fails: Array[String] = []


func _init() -> void:
	K.watchdog(self, "FP_FIRST_USE_SITES_TEST")
	await process_frame
	var flag_before := FeatureFlags.enabled("web_first_use_marks", false)
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "render": true})
	ctx.player.set_process(false)
	ctx.view.set_fp_mode(true)
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	var street: FpFeature = K.make_feature(ctx, "streetscape")
	K.make_feature(ctx, "render_opt")
	K.make_feature(ctx, "hud_widgets")
	K.check(fails, street != null, "fixture: the streetscape feature sets up")
	if street != null:
		_check_lamps(ctx, street)
		_check_rain(street)
		_check_rain_start(ctx, street)
	_check_beacon(ctx)
	_check_site(ctx)
	_check_overview(ctx)
	await _check_pause(ctx)
	FeatureFlags.set_override("web_first_use_marks", flag_before)
	FirstUse.force = false
	FirstUse.reset()
	K.finish(self, "FP_FIRST_USE_SITES_TEST", fails)


## The marks on (the web path forced, the flag set) or off, with nothing logged yet.
func _arm(on: bool = true) -> void:
	FirstUse.force = on
	FeatureFlags.set_override("web_first_use_marks", on)
	FirstUse.reset()


## The tag of every record logged since _arm().
func _tags() -> Array:
	var out := []
	for line: String in FirstUse.lines:
		out.append(str((JSON.parse_string(line) as Dictionary)["tag"]))
	return out


func _check_lamps(ctx: FpContext, street: FpFeature) -> void:
	var lights: Node = street.get("lights")
	var spot := -1
	for i in ctx.sim.active:
		var h := ctx.view.tile_holder(i)
		if (
			h != null
			and ctx.sim.kind[i] == D.ROAD
			and not h.find_children("Bulb*", "MeshInstance3D", true, false).is_empty()
		):
			spot = i
			break
	K.check(fails, spot >= 0, "fixture: a road tile with lamps exists")
	if spot < 0:
		return
	ctx.player.teleport(Vector3(D.tx(spot) + 0.4, WS.SIDEWALK_TOP, D.ty(spot)), 0.0)
	ctx.view.night = 0.0
	lights.call("_process", 0.3)
	_arm()
	lights.call("_process", 0.3)
	K.check(fails, _tags().is_empty(), "lamps: a day marks nothing")
	ctx.view.night = 1.0
	lights.call("_process", 0.3)
	K.check(
		fails,
		int(lights.call("lit_count")) > 0 and _tags() == ["lamp_pool"],
		"lamps: the pool is marked as it first lights (%s)" % str(_tags())
	)
	lights.call("_process", 0.3)
	K.check(fails, _tags() == ["lamp_pool"], "lamps: ...and not again while it stays lit")
	ctx.view.night = 0.0
	lights.call("_process", 0.3)
	ctx.view.night = 1.0
	lights.call("_process", 0.3)
	K.check(fails, _tags() == ["lamp_pool", "lamp_pool"], "lamps: ...but again at the next dusk")
	ctx.view.night = 0.0
	lights.call("_process", 0.3)
	_arm(false)
	ctx.view.night = 1.0
	lights.call("_process", 0.3)
	K.check(
		fails,
		int(lights.call("lit_count")) > 0 and FirstUse.lines.is_empty(),
		"lamps: off, the same dusk logs nothing"
	)
	ctx.view.night = 0.0
	lights.call("_process", 0.3)


func _check_rain(street: FpFeature) -> void:
	var weather: Node = street.get("weather")
	weather.set_process(false)
	# .forced is set directly here (a change of state step() sees); _check_rain_start has force().
	weather.set("forced", "clear")
	weather.call("step", 0.1)
	_arm()
	weather.call("step", 0.1)
	K.check(fails, _tags().is_empty(), "rain: a clear sky marks nothing")
	weather.set("forced", "rain")
	weather.call("step", 0.1)
	K.check(fails, _tags() == ["rain"], "rain: marked when it starts to fall (%s)" % str(_tags()))
	weather.call("step", 0.1)
	K.check(fails, _tags() == ["rain"], "rain: ...and not on the frames it keeps falling")
	weather.set("forced", "clear")
	weather.call("step", 0.1)
	weather.set("forced", "rain")
	weather.call("step", 0.1)
	K.check(fails, _tags() == ["rain", "rain"], "rain: ...but again when it comes back")
	weather.set("forced", "clear")
	weather.call("step", 0.1)
	_arm(false)
	weather.set("forced", "rain")
	weather.call("step", 0.1)
	K.check(fails, FirstUse.lines.is_empty(), "rain: off, the same start logs nothing")
	weather.set("forced", "")


## Rain that is already falling when the weather is set up (the default city's day 1 is rain, so
## that is every first boot of a fresh browser profile), loaded or forced has its state set before
## the first step(), so the mark rides on the emitter going on and not on a change of state.
func _check_rain_start(ctx: FpContext, street: FpFeature) -> void:
	var sim: CitySim = ctx.sim
	var day_before := sim.day
	var events_before: Array[Dictionary] = sim.events.duplicate()
	var rainy := -1
	var dry := -1
	for d in range(1, 400):
		var s := WEATHER.daily_state(sim.city_seed, d)
		if s == "rain" and rainy < 0:
			rainy = d
		elif s == "clear" and dry < 0:
			dry = d
	K.check(fails, rainy > 0 and dry > 0, "fixture: the seed has a rainy and a clear day")
	if rainy < 0 or dry < 0:
		return
	sim.events.clear()
	var w: Node3D = WEATHER.new()
	street.add_child(w)
	w.set_process(false)
	# A fresh boot: set up on a rainy day, nothing forced.
	sim.day = rainy
	w.call("setup", ctx, "medium")
	K.check(fails, w.get("state") == "rain", "fixture: a set up weather on a rainy day is rain")
	K.check(fails, not (w.get("rain") as GPUParticles3D).emitting, "fixture: its drops are off")
	_arm()
	w.call("step", 0.1)
	K.check(
		fails,
		_tags() == ["rain"] and (w.get("rain") as GPUParticles3D).emitting,
		"rain: a rainy day at setup is marked at the first draw of the drops (%s)" % str(_tags())
	)
	w.call("step", 0.1)
	K.check(fails, _tags() == ["rain"], "rain: ...and not on the frames it keeps falling")
	# A flood on top of rain that is falling already changes nothing on screen.
	w.call("force", "rain")
	w.call("step", 0.1)
	K.check(fails, _tags() == ["rain"], "rain: ...nor when the same rain is forced")
	# A clear day, then Continue into a rainy one (from_dict sets the state itself).
	sim.day = dry
	w.call("force", "")
	w.call("step", 0.1)
	_arm()
	w.call("step", 0.1)
	K.check(fails, _tags().is_empty(), "rain: a clear day marks nothing")
	sim.day = rainy
	w.call("from_dict", {"wet": 0.4})
	K.check(fails, w.get("state") == "rain", "fixture: a load on a rainy day is rain at once")
	w.call("step", 0.1)
	K.check(fails, _tags() == ["rain"], "rain: a load into rain is marked (%s)" % str(_tags()))
	# force() moves the state at once, too.
	w.call("force", "clear")
	w.call("step", 0.1)
	_arm()
	w.call("force", "rain")
	w.call("step", 0.1)
	K.check(fails, _tags() == ["rain"], "rain: forcing rain is marked (%s)" % str(_tags()))
	_arm(false)
	w.call("force", "clear")
	w.call("step", 0.1)
	w.call("force", "rain")
	w.call("step", 0.1)
	K.check(fails, FirstUse.lines.is_empty(), "rain: off, a rainy start logs nothing")
	w.queue_free()
	sim.day = day_before
	sim.events.assign(events_before)


func _check_beacon(ctx: FpContext) -> void:
	var f: FpFeature = K.make_feature(ctx, "activity")
	K.check(fails, f != null, "fixture: the activity feature sets up")
	if f == null:
		return
	f.set_process(false)
	var beacons: Node3D = f.get("beacons")
	var at := ctx.player.position
	_arm()
	beacons.call("place", "test:a", at, Color.RED)
	K.check(fails, _tags() == ["beacon"], "beacon: a new one is marked (%s)" % str(_tags()))
	beacons.call("place", "test:a", at + Vector3(1, 0, 0), Color.RED)
	K.check(fails, _tags() == ["beacon"], "beacon: ...moving or refreshing it is not")
	beacons.call("place", "test:b", at, Color.BLUE)
	K.check(fails, _tags() == ["beacon", "beacon"], "beacon: ...another one is")
	beacons.call("clear")
	_arm(false)
	beacons.call("place", "test:c", at, Color.RED)
	K.check(fails, FirstUse.lines.is_empty(), "beacon: off, a new one logs nothing")
	beacons.call("clear")


func _check_site(ctx: FpContext) -> void:
	var holder := Node3D.new()
	get_root().add_child(holder)
	var spec := {"type": "build", "plan": "build", "target_kind": D.ZONE_C}
	var at := {"h": 7, "height": 1.2, "foot": Vector2(0.7, 0.7)}
	_arm()
	var site: Node3D = ctx.view.kit.build_site(holder, spec, "frame", 0.2, at)
	K.check(
		fails,
		site != null and _tags() == ["site"],
		"site: marked as a construction site is built (%s)" % str(_tags())
	)
	ctx.view.kit.build_site(holder, spec, "frame", 0.4, at)
	K.check(fails, _tags() == ["site", "site"], "site: ...and at every build")
	_arm(false)
	ctx.view.kit.build_site(holder, spec, "frame", 0.6, at)
	K.check(fails, FirstUse.lines.is_empty(), "site: off, building one logs nothing")
	holder.free()


func _check_overview(ctx: FpContext) -> void:
	var f: FpFeature = ctx.feature("overview")
	if f == null:
		f = K.make_feature(ctx, "overview")
	K.check(fails, f != null, "fixture: the overview feature sets up")
	if f == null:
		return
	f.set_process(false)
	_arm()
	K.check(fails, f.call("enter") == true, "fixture: the overview opens")
	K.check(fails, _tags() == ["overview"], "overview: marked as it opens (%s)" % str(_tags()))
	f.call("exit", 0.0)
	K.check(fails, f.call("enter") == true, "fixture: the overview opens again")
	K.check(fails, _tags() == ["overview", "overview"], "overview: ...and at every opening")
	f.call("exit", 0.0)
	_arm(false)
	K.check(fails, f.call("enter") == true, "fixture: the overview opens a third time")
	K.check(fails, FirstUse.lines.is_empty(), "overview: off, opening it logs nothing")
	f.call("exit", 0.0)


func _check_pause(ctx: FpContext) -> void:
	var menu := ctx.hud.pause_menu
	_arm()
	ctx.mode.set_paused(true)
	await process_frame
	K.check(
		fails,
		menu.is_open() and _tags() == ["pause_menu"],
		"pause menu: marked as it opens (%s)" % str(_tags())
	)
	menu.call("_on_button", "Quit to orbit")
	K.check(
		fails,
		_tags() == ["pause_menu", "quit_to_orbit"],
		"pause menu: Quit to orbit is marked (%s)" % str(_tags())
	)
	ctx.mode.set_paused(false)
	await process_frame
	ctx.mode.set_paused(true)
	await process_frame
	K.check(
		fails,
		_tags() == ["pause_menu", "quit_to_orbit", "pause_menu"],
		"pause menu: ...and at every opening (%s)" % str(_tags())
	)
	ctx.mode.set_paused(false)
	await process_frame
	_arm(false)
	ctx.mode.set_paused(true)
	await process_frame
	K.check(
		fails,
		menu.is_open() and FirstUse.lines.is_empty(),
		"pause menu: off, opening it logs nothing"
	)
	ctx.mode.set_paused(false)
	await process_frame
