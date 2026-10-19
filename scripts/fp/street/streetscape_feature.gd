extends FpFeature
## Street-level look on foot (slice G1). Applies the first-person light profile for the quality
## preset, runs the weather (rain, wet roads, overcast) and the street-light pool, adds the global
## `wetness` shader parameter, and feeds the player position to CityView's rebuild queue every frame
## (the queue loads building models on threads as tiles need them). The street geometry itself (ground, furniture, signs, decals,
## lots) is CityView's fp_mode.

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const LP := preload("res://scripts/fp/street/light_profile.gd")
const WEATHER := preload("res://scripts/fp/street/weather.gd")
const LIGHTS := preload("res://scripts/fp/street/street_lights.gd")
## Street-light pool size until G2's quality.max_street_lights() exists.
const DEFAULT_LIGHTS := 12

var weather: WEATHER
var lights: LIGHTS
var preset: String = "medium"
## True while the `wetness` global shader parameter exists (added here; the query for it is
## editor-only, so the flag is the record).
static var wetness_global: bool = false


func feature_id() -> String:
	return "streetscape"


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	preset = str(ctx.settings.get("quality", "medium"))
	LP.apply(ctx.env, ctx.sun, "fp", preset)
	if not wetness_global:
		RenderingServer.global_shader_parameter_add(&"wetness", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
		wetness_global = true
	weather = WEATHER.new()
	weather.name = "Weather"
	weather.push_global = wetness_global
	if OS.has_environment("GRIDFALL_FP_PHOTO_DIR") or OS.has_environment("FPBENCH_DIR"):
		weather.baseline = "clear"
		weather.forced = "clear"
	add_child(weather)
	weather.setup(ctx, preset)
	lights = LIGHTS.new()
	lights.name = "StreetLights"
	add_child(lights)
	lights.setup(ctx, _max_lights())
	if ctx.view != null:
		ctx.view.vis_mult = _vis_mult()
		ctx.view.tile_built.connect(lights.on_tile_built)
		ctx.view.tile_cleared.connect(lights.on_tile_cleared)
		_hook_traffic()
	if ctx.bus != null:
		ctx.bus.quality_changed.connect(_on_quality_changed)


func on_world_rebuilt() -> void:
	if lights != null:
		lights.rescan()
	_hook_traffic()


func _process(_delta: float) -> void:
	if ctx != null and ctx.view != null:
		ctx.view.priority_point = ctx.player_position()


func teardown() -> void:
	if ctx == null:
		return
	if ctx.bus != null and ctx.bus.quality_changed.is_connected(_on_quality_changed):
		ctx.bus.quality_changed.disconnect(_on_quality_changed)
	if ctx.view != null:
		if lights != null and ctx.view.tile_built.is_connected(lights.on_tile_built):
			ctx.view.tile_built.disconnect(lights.on_tile_built)
			ctx.view.tile_cleared.disconnect(lights.on_tile_cleared)
		ctx.view.light_pole_source = null
		ctx.view.set_wetness(0.0)
	if ctx.sky != null:
		ctx.sky.reset_weather()
	LP.apply(ctx.env, ctx.sun, "orbit", preset)
	if wetness_global:
		RenderingServer.global_shader_parameter_remove(&"wetness")
		wetness_global = false


func to_dict() -> Dictionary:
	return weather.to_dict() if weather != null else {}


func from_dict(d: Dictionary) -> void:
	if weather != null:
		weather.from_dict(d)


func _on_quality_changed(p: String) -> void:
	preset = p
	LP.apply(ctx.env, ctx.sun, "fp", preset)
	if lights != null:
		lights.set_count(_max_lights())
	if weather != null:
		weather.set_rain_amount(preset)
	if ctx.view != null:
		ctx.view.vis_mult = _vis_mult()


## Cross tiles hang their street-name blades on E's NE light pole when the traffic feature has one.
func _hook_traffic() -> void:
	if ctx.view == null:
		return
	var traffic := ctx.feature("traffic")
	ctx.view.light_pole_source = traffic if traffic != null and traffic.has_method("light_pole") else null


func _vis_mult() -> float:
	var q := LP.quality_script()
	return float(q.call("vis_mult", preset)) if q != null and q.has_method("vis_mult") else 1.0


func _max_lights() -> int:
	var q := LP.quality_script()
	return int(q.call("max_street_lights", preset)) if q != null and q.has_method("max_street_lights") else DEFAULT_LIGHTS


# ------------------------------------------------------------------ test and photo hooks

## Forces "clear", "overcast" or "rain" until clear_forced_weather().
func force_weather(state: String) -> void:
	weather.force(state)


## Rain with soaked streets at once (the "rain" photo's prepare).
func force_rain_for_photo() -> void:
	weather.force_soaked()


## Back to the day's weather, streets dry (the "rain" photo's restore).
func clear_forced_weather() -> void:
	weather.clear_forced()


func self_test() -> Dictionary:
	var notes: Array[String] = []
	var ok := ctx.env != null and is_equal_approx(ctx.env.ssao_radius, WS.SSAO_RADIUS) and ctx.env.fog_mode == Environment.FOG_MODE_DEPTH
	if not ok:
		notes.append("light profile not applied")
	var n := 0
	if ctx.view != null:
		for i in ctx.sim.active:
			var k := ctx.sim.kind[i]
			var holder := ctx.view.tile_holder(i)
			if not (D.is_zone(k) or D.is_service(k)) or holder == null or not holder.has_meta("building_xform"):
				continue
			var fy := ctx.view.directory.frontage_yaw(i)
			if is_nan(fy):
				continue
			var have := (holder.get_meta("building_xform") as Transform3D).basis.get_euler().y
			if absf(angle_difference(have, deg_to_rad(fy))) > deg_to_rad(0.5):
				ok = false
				notes.append("lot %d faces %.1f, frontage %.1f" % [i, rad_to_deg(have), fy])
			n += 1
			if n >= 10:
				break
	return {"ok": ok, "detail": "profile %s, %d lots face their street%s" % [preset, n, "" if notes.is_empty() else ": " + ", ".join(notes)]}


## Extra photo-tour shots: a junction street sign from 6 m, and the street in the rain at 16:00.
func photo_shots() -> Array:
	var out: Array = []
	var sign := _nearest_sign()
	if sign != null:
		var sp := sign.global_position
		var blades := sign.get_node_or_null("Blades") as Node3D
		var top := blades.global_position if blades != null else sp + Vector3(0, 2.75 * WS.M, 0)
		# Three-quarter view from the south-west, so both crossed blades read.
		var from := sp + Vector3(-0.21, 0.0, 0.21)
		var to := top - (from + Vector3(0, WS.EYE, 0))
		out.append({"name": "street_sign", "pos": from, "yaw": rad_to_deg(atan2(-to.x, -to.z)),
			"pitch": rad_to_deg(atan2(to.y, Vector2(to.x, to.z).length())), "hour": 11.0})
	if ctx.mode != null:
		var sp2: Dictionary = ctx.mode.spawn_point()
		out.append({"name": "rain", "pos": sp2["pos"], "yaw": float(sp2["yaw"]), "pitch": -4.0, "hour": 16.0,
			"prepare": "force_rain_for_photo", "restore": "clear_forced_weather"})
	return out


## The street-name sign nearest the spawn point, or null.
func _nearest_sign() -> Node3D:
	if ctx.view == null:
		return null
	var p := ctx.mode.spawn_point()["pos"] as Vector3 if ctx.mode != null else ctx.player_position()
	var best: Node3D = null
	var bd := INF
	for i: int in ctx.view._tile_nodes.keys():
		if ctx.sim.kind[i] != D.ROAD:
			continue
		var holder: Node3D = ctx.view._tile_nodes[i]
		var s := holder.get_node_or_null("StreetSign") as Node3D
		if s == null:
			continue
		var d := s.global_position.distance_to(p)
		if d < bd:
			bd = d
			best = s
	return best
