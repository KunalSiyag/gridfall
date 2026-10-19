class_name SkyDirector
extends Node
## Day/night cycle tied to the sim clock: tick 0 is morning, 3 is night. Moves the sun and
## moon, blends the day and night HDRIs, fades ambient light and fog, and tells the city
## view how dark it is so windows and street lamps light up.

const DAY_HDRI := "res://env/sky.hdr"
## Poly Haven sunset panorama; true night is drawn procedurally in the sky shader.
const DUSK_HDRI := "res://env/sky_night.hdr"
## On foot the horizon is in view, and sky_night's city skyline would loom over the streets: a
## pure-sky dusk replaces it (orbit keeps the old one), scaled to the same mean brightness.
const DUSK_HDRI_FP := "res://env/sky_dusk.hdr"
const DUSK_GAIN := 0.3
const DUSK_GAIN_FP := 0.38
const SKY_SHADER := "res://shaders/sky_blend.gdshader"
## Above this speed a day lasts under 3 seconds, so the cycle holds at midday instead of strobing.
const MAX_CYCLE_SPEED := 4
const HOLD_HOUR := 13.0
## Days shorter than this many real seconds hold at HOLD_HOUR instead of strobing.
const MIN_CYCLE_DAY_SECONDS := 3.0

var sim: CitySim
var env: Environment
var sun: DirectionalLight3D
var view: CityView
var crisis: float = 0.0
## Fixed clock hour for screenshots and tests; negative follows the sim.
var fixed_hour: float = -1.0
var hour: float = 9.0
var night: float = 0.0
## Weather hooks (slice G1's streetscape weather), read inside _apply so they survive the per-frame
## rewrite: sun energy and exposure multipliers, a depth-fog begin override (negative: none), how
## grey the sky is (0 clear .. 1 overcast), a fog tint (smog) and how dark sun shadows are (cloud
## cover diffuses them).
var weather_energy_mult: float = 1.0
var weather_shadow_mult: float = 1.0
var weather_exposure_mult: float = 1.0
var fog_begin_override: float = -1.0
var weather_grey: float = 0.0
var weather_fog_tint: Color = Color(1, 1, 1, 0)
var _sky_mat: ShaderMaterial
var _dusk_fp: bool = false
## The depth-fog begin that fog_begin_override replaced (negative: nothing replaced).
var _fog_begin_saved: float = -1.0
## The scene's sun shadow opacity, which weather_shadow_mult scales.
var _shadow_opacity: float = 1.0


func setup(p_sim: CitySim, p_env: Environment, p_sun: DirectionalLight3D, p_view: CityView) -> void:
	sim = p_sim
	env = p_env
	sun = p_sun
	view = p_view
	if sun != null:
		_shadow_opacity = sun.shadow_opacity
	if OS.has_environment("GRIDFALL_HOUR"):
		fixed_hour = float(OS.get_environment("GRIDFALL_HOUR"))
	if env != null and ResourceLoader.exists(SKY_SHADER) and ResourceLoader.exists(DAY_HDRI):
		_sky_mat = ShaderMaterial.new()
		_sky_mat.shader = load(SKY_SHADER)
		_sky_mat.set_shader_parameter("day_sky", load(DAY_HDRI))
		_sky_mat.set_shader_parameter("dusk_sky", load(DUSK_HDRI) if ResourceLoader.exists(DUSK_HDRI) else load(DAY_HDRI))
		var sky := Sky.new()
		sky.sky_material = _sky_mat
		sky.radiance_size = Sky.RADIANCE_SIZE_256
		sky.process_mode = Sky.PROCESS_MODE_REALTIME
		env.sky = sky
		env.background_mode = Environment.BG_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	hour = _target_hour()
	_apply(1.0)


func _target_hour() -> float:
	if fixed_hour >= 0.0:
		return fixed_hour
	if sim == null or sim.day_seconds / float(maxi(sim.speed, 1)) < MIN_CYCLE_DAY_SECONDS:
		return HOLD_HOUR
	return fmod(6.0 + sim.day_progress() * 24.0, 24.0)


## Clear sky again: drops every weather hook and puts back the fog begin an override replaced.
func reset_weather() -> void:
	weather_energy_mult = 1.0
	weather_shadow_mult = 1.0
	weather_exposure_mult = 1.0
	weather_grey = 0.0
	weather_fog_tint = Color(1, 1, 1, 0)
	fog_begin_override = -1.0
	if _fog_begin_saved >= 0.0 and env != null:
		env.fog_depth_begin = _fog_begin_saved
	_fog_begin_saved = -1.0


func clock_text() -> String:
	return "%02d:%02d" % [int(hour) % 24, int(fmod(hour, 1.0) * 60.0) / 15 * 15]


func _process(delta: float) -> void:
	var step := wrapf(_target_hour() - hour, -12.0, 12.0)
	hour = wrapf(hour + step * minf(1.0, delta * 3.0), 0.0, 24.0)
	_apply(minf(1.0, delta * 2.0))


func _apply(blend: float) -> void:
	# d is the sun's height: 1 at noon, 0 at 6:00 and 18:00, -1 at midnight.
	var d := sin(PI * (hour - 6.0) / 12.0)
	var day_f := smoothstep(-0.12, 0.3, d)
	night = 1.0 - day_f
	var dusk := smoothstep(0.5, 0.05, d)
	var dark := smoothstep(-0.05, -0.35, d)
	if sun != null:
		var energy := 0.0
		var col := Color(0.55, 0.65, 0.95)
		if d >= -0.1:
			var t := (hour - 6.0) / 12.0
			sun.rotation_degrees = Vector3(-maxf(3.0, 62.0 * d), lerpf(105.0, 255.0, clampf(t, 0.0, 1.0)), 0.0)
			energy = 1.3 * smoothstep(-0.1, 0.3, d)
			col = Color(1.0, 0.52, 0.28).lerp(Color(1.0, 0.96, 0.9), smoothstep(0.0, 0.55, d))
		else:
			sun.rotation_degrees = Vector3(-48.0, 210.0, 0.0)
			energy = 0.16 * smoothstep(-0.1, -0.4, d)
		energy *= lerpf(1.0, 0.55, crisis) * weather_energy_mult
		col = col.lerp(Color(0.9, 0.45, 0.45), crisis * 0.5)
		sun.light_energy = lerpf(sun.light_energy, energy, blend)
		sun.light_color = sun.light_color.lerp(col, blend)
		sun.shadow_enabled = energy > 0.02
		sun.shadow_opacity = _shadow_opacity * weather_shadow_mult
	if env != null:
		# The night sky is nearly black, so a fixed moonlit blue keeps streets readable.
		env.ambient_light_color = Color(0.16, 0.2, 0.32)
		env.ambient_light_sky_contribution = lerpf(1.0, 0.25, dark)
		env.ambient_light_energy = lerpf(0.55, 1.0, day_f)
		var fog := Color(0.03, 0.04, 0.08).lerp(Color(0.62, 0.70, 0.80), day_f).lerp(Color(0.85, 0.55, 0.4), dusk * (1.0 - dark) * 0.5)
		fog = fog.lerp(Color(0.6, 0.62, 0.64) * lerpf(0.15, 1.0, day_f), weather_grey * 0.6)
		env.fog_light_color = fog.lerp(Color(weather_fog_tint.r, weather_fog_tint.g, weather_fog_tint.b) * lerpf(0.2, 1.0, day_f), weather_fog_tint.a)
		env.tonemap_exposure = lerpf(1.2, 1.0, day_f) * weather_exposure_mult
		if fog_begin_override >= 0.0:
			if _fog_begin_saved < 0.0:
				_fog_begin_saved = env.fog_depth_begin
			env.fog_depth_begin = fog_begin_override
		elif _fog_begin_saved >= 0.0:
			env.fog_depth_begin = _fog_begin_saved
			_fog_begin_saved = -1.0
	if _sky_mat != null:
		var want_fp := view != null and view.fp_mode and ResourceLoader.exists(DUSK_HDRI_FP)
		if want_fp != _dusk_fp:
			_dusk_fp = want_fp
			_sky_mat.set_shader_parameter("dusk_sky", load(DUSK_HDRI_FP if want_fp else (DUSK_HDRI if ResourceLoader.exists(DUSK_HDRI) else DAY_HDRI)))
			_sky_mat.set_shader_parameter("dusk_gain", DUSK_GAIN_FP if want_fp else DUSK_GAIN)
		_sky_mat.set_shader_parameter("dusk", dusk)
		_sky_mat.set_shader_parameter("night", dark)
		_sky_mat.set_shader_parameter("tint", Vector3(1.0, 1.0, 1.0).lerp(Vector3(1.15, 0.9, 0.75), dusk))
		_sky_mat.set_shader_parameter("exposure", 1.0)
		_sky_mat.set_shader_parameter("grey", weather_grey)
	if view != null:
		view.set_night(night)
