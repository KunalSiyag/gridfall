extends Node3D
## Street weather (slice G1): a deterministic daily state (clear 60%, overcast 25%, rain 15%) from the
## city seed and day, forced by incidents (a flood brings rain, smog a brown haze), drives SkyDirector's
## weather hooks, CityView's wetness and the global `wetness` shader parameter, and a rain-streak
## emitter that follows the camera. Wetness rises 0 -> 1 over 120 real seconds of rain at 1x
## (scaled by sim.speed) and dries over 300.

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const STATES := ["clear", "overcast", "rain"]
const WET_SECONDS := 120.0
const DRY_SECONDS := 300.0
## Hook targets per state: sun energy and exposure multipliers, sky grey, fog-begin override and sun
## shadow opacity (cloud cover leaves only soft, faint shadows).
const LOOK := {
	"clear": {"energy": 1.0, "exposure": 1.0, "grey": 0.0, "fog": -1.0, "shadow": 1.0},
	"overcast": {"energy": 0.55, "exposure": 0.96, "grey": 0.85, "fog": 15.0, "shadow": 0.3},
	"rain": {"energy": 0.32, "exposure": 0.86, "grey": 1.0, "fog": 9.0, "shadow": 0.12},
}
const RAIN_AMOUNT := {"low": 800, "medium": 1600, "high": 3000}

var ctx: FpContext
## The state shown now and how wet the streets are (0..1).
var state: String = "clear"
var wet: float = 0.0
## A state forced by tests and photos ("" follows the day and incidents).
var forced: String = ""
## Whether to write the `wetness` global shader parameter (the streetscape feature added it).
var push_global: bool = false
## The state clear_forced() returns to: "" (the day's weather) in play; "clear" in tool runs (photo
## tour, fp_bench), so their baselines and timings do not depend on the day's weather.
var baseline: String = ""
var rain: GPUParticles3D
## The quality preset: on "high" (the only preset with volumetric fog) a smog incident also gets a
## brown FogVolume box over its radius.
var preset: String = "medium"
## Smog FogVolumes by event key ("x,y").
var smog_volumes: Dictionary = {}
var _look: Dictionary = {"energy": 1.0, "exposure": 1.0, "grey": 0.0, "fog": -1.0, "shadow": 1.0}
var _smog: float = 0.0
var _smog_mat: FogMaterial


func setup(p_ctx: FpContext, p_preset: String) -> void:
	ctx = p_ctx
	preset = p_preset
	_build_rain(preset)
	state = target_state()
	_look = (LOOK[state] as Dictionary).duplicate()
	_apply_hooks()


## The weather for a city seed and day, the same on every run: clear 60%, overcast 25%, rain 15%.
static func daily_state(seed: int, day: int) -> String:
	var r := posmod(hash([seed, day, "gridfall-weather"]), 100)
	if r < 60:
		return "clear"
	if r < 85:
		return "overcast"
	return "rain"


## What the weather should be now: forced, else an incident's (flood rain, smog overcast), else the day's.
func target_state() -> String:
	if not forced.is_empty():
		return forced
	if ctx == null or ctx.sim == null:
		return "clear"
	for ev: Dictionary in ctx.sim.events:
		var t := str(ev.get("type", ""))
		if t == "flood":
			return "rain"
		if t == "smog":
			return "overcast"
	return daily_state(ctx.sim.city_seed, ctx.sim.day)


func _process(delta: float) -> void:
	step(delta)


## One weather update over delta real seconds (tests call it directly).
func step(delta: float) -> void:
	state = target_state()
	var speed := float(ctx.sim.speed) if ctx != null and ctx.sim != null else 1.0
	if state == "rain":
		wet = minf(1.0, wet + delta * speed / WET_SECONDS)
	else:
		wet = maxf(0.0, wet - delta * speed / DRY_SECONDS)
	var goal: Dictionary = LOOK[state]
	var k := minf(1.0, delta * 0.5)
	for key: String in ["energy", "exposure", "grey", "shadow"]:
		_look[key] = lerpf(float(_look[key]), float(goal[key]), k)
	_look["fog"] = goal["fog"]
	_smog = lerpf(_smog, _smog_near(), k)
	_apply_hooks()
	_update_smog_volumes()
	if rain != null:
		rain.emitting = state == "rain"
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		if cam != null:
			rain.global_position = cam.global_position + Vector3(0, 0.35, 0)


func _apply_hooks() -> void:
	if ctx == null:
		return
	if ctx.sky != null:
		ctx.sky.weather_energy_mult = float(_look["energy"])
		ctx.sky.weather_exposure_mult = float(_look["exposure"])
		ctx.sky.weather_shadow_mult = float(_look["shadow"])
		ctx.sky.weather_grey = float(_look["grey"])
		var fog := float(_look["fog"])
		if _smog > 0.01:
			fog = 5.0 if fog < 0.0 else minf(fog, 5.0)
		ctx.sky.fog_begin_override = fog
		ctx.sky.weather_fog_tint = Color(0.62, 0.55, 0.36, clampf(_smog, 0.0, 0.85))
	if ctx.view != null:
		ctx.view.set_wetness(wet)
		ctx.view.set_rain(1.0 if state == "rain" else 0.0)
	if push_global:
		RenderingServer.global_shader_parameter_set(&"wetness", wet)


## 1 inside a smog incident's radius around the player, fading to 0 three tiles beyond it.
func _smog_near() -> float:
	if ctx == null or ctx.sim == null:
		return 0.0
	var p := ctx.player_position()
	var best := 0.0
	for ev: Dictionary in ctx.sim.events:
		if str(ev.get("type", "")) != "smog":
			continue
		var d := Vector2(float(ev.get("x", 0)) - p.x, float(ev.get("y", 0)) - p.z).length()
		var r := float(ev.get("radius", 3))
		best = maxf(best, 1.0 - smoothstep(r, r + 3.0, d))
	return best


## Forces a state ("clear", "overcast" or "rain"); "" goes back to the day's weather.
func force(s: String) -> void:
	forced = s if s in STATES else ""
	state = target_state()


## Rain with the streets fully wet at once (the "rain" photo).
func force_soaked() -> void:
	force("rain")
	wet = 1.0
	_look = (LOOK["rain"] as Dictionary).duplicate()
	_apply_hooks()


## Back to the baseline weather with dry streets and the hooks at their targets.
func clear_forced() -> void:
	forced = baseline
	wet = 0.0
	state = target_state()
	_look = (LOOK[state] as Dictionary).duplicate()
	_apply_hooks()


func set_rain_amount(p_preset: String) -> void:
	preset = p_preset
	if rain != null:
		rain.amount = int(RAIN_AMOUNT.get(preset, 1600))
	_update_smog_volumes()


## On "high", one FogVolume box per smog incident, 20 m tall over its radius plus a tile, thinning
## upward and at its edges; none on the other presets (they have no volumetric fog).
func _update_smog_volumes() -> void:
	var want := {}
	if preset == "high" and ctx != null and ctx.sim != null:
		for ev: Dictionary in ctx.sim.events:
			if str(ev.get("type", "")) == "smog":
				want["%d,%d" % [int(ev.get("x", 0)), int(ev.get("y", 0))]] = ev
	for key: String in smog_volumes.keys():
		if not want.has(key):
			var old: Variant = smog_volumes[key]
			if is_instance_valid(old):
				(old as Node).queue_free()
			smog_volumes.erase(key)
	for key: String in want.keys():
		if smog_volumes.has(key):
			continue
		var ev: Dictionary = want[key]
		if _smog_mat == null:
			_smog_mat = FogMaterial.new()
			_smog_mat.density = 0.15
			_smog_mat.albedo = Color(0.62, 0.55, 0.36)
			_smog_mat.height_falloff = 1.5
			_smog_mat.edge_fade = 0.4
		var fv := FogVolume.new()
		fv.name = "Smog"
		fv.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
		var r := float(ev.get("radius", 3)) + 1.0
		fv.size = Vector3(r * 2.0, 20.0 * WS.M, r * 2.0)
		fv.material = _smog_mat
		add_child(fv)
		fv.global_position = Vector3(float(ev.get("x", 0)), WS.GROUND_Y + 10.0 * WS.M, float(ev.get("y", 0)))
		smog_volumes[key] = fv


func to_dict() -> Dictionary:
	return {"weather": state, "wet": wet}


func from_dict(d: Dictionary) -> void:
	wet = clampf(float(d.get("wet", 0.0)), 0.0, 1.0)
	state = target_state()
	_look = (LOOK[state] as Dictionary).duplicate()
	_apply_hooks()


## Falling streaks in a 1 u box above and around the camera, simulated in world space.
func _build_rain(p_preset: String) -> void:
	rain = GPUParticles3D.new()
	rain.name = "Rain"
	rain.amount = int(RAIN_AMOUNT.get(p_preset, 1600))
	rain.lifetime = 1.3
	rain.local_coords = false
	rain.emitting = false
	rain.visibility_aabb = AABB(Vector3(-0.6, -1.2, -0.6), Vector3(1.2, 1.4, 1.2))
	rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.5, 0.05, 0.5)
	pm.direction = Vector3(0.05, -1.0, 0.02)
	pm.spread = 2.0
	pm.initial_velocity_min = 8.0 * WS.M
	pm.initial_velocity_max = 10.0 * WS.M
	pm.gravity = Vector3(0, -2.0 * WS.M, 0)
	rain.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.012, 0.55) * WS.M
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.billboard_keep_scale = true
	mat.albedo_color = Color(0.78, 0.82, 0.88, 0.26)
	# Drops passing right by the lens would be metre-long bars: fade them in from 0.4 to 1.6 m.
	mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	mat.distance_fade_min_distance = 0.4 * WS.M
	mat.distance_fade_max_distance = 1.6 * WS.M
	mat.disable_receive_shadows = true
	q.material = mat
	rain.draw_pass_1 = q
	add_child(rain)
