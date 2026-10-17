class_name SkyDirector
extends Node
## Day/night cycle tied to the sim clock: tick 0 is morning, 3 is night. Moves the sun and
## moon, blends the day and night HDRIs, fades ambient light and fog, and tells the city
## view how dark it is so windows and street lamps light up.

const DAY_HDRI := "res://env/sky.hdr"
## Poly Haven sunset panorama; true night is drawn procedurally in the sky shader.
const DUSK_HDRI := "res://env/sky_night.hdr"
const SKY_SHADER := "res://shaders/sky_blend.gdshader"
## Above this speed a day lasts under 3 seconds, so the cycle holds at midday instead of strobing.
const MAX_CYCLE_SPEED := 4
const HOLD_HOUR := 13.0

var sim: CitySim
var env: Environment
var sun: DirectionalLight3D
var view: CityView
var crisis: float = 0.0
## Fixed clock hour for screenshots and tests; negative follows the sim.
var fixed_hour: float = -1.0
var hour: float = 9.0
var night: float = 0.0
var _sky_mat: ShaderMaterial


func setup(p_sim: CitySim, p_env: Environment, p_sun: DirectionalLight3D, p_view: CityView) -> void:
	sim = p_sim
	env = p_env
	sun = p_sun
	view = p_view
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
	if sim == null or sim.speed > MAX_CYCLE_SPEED:
		return HOLD_HOUR
	return fmod(6.0 + sim.day_progress() * 24.0, 24.0)


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
		energy *= lerpf(1.0, 0.55, crisis)
		col = col.lerp(Color(0.9, 0.45, 0.45), crisis * 0.5)
		sun.light_energy = lerpf(sun.light_energy, energy, blend)
		sun.light_color = sun.light_color.lerp(col, blend)
		sun.shadow_enabled = energy > 0.02
	if env != null:
		# The night sky is nearly black, so a fixed moonlit blue keeps streets readable.
		env.ambient_light_color = Color(0.16, 0.2, 0.32)
		env.ambient_light_sky_contribution = lerpf(1.0, 0.25, dark)
		env.ambient_light_energy = lerpf(0.55, 1.0, day_f)
		env.fog_light_color = Color(0.03, 0.04, 0.08).lerp(Color(0.62, 0.70, 0.80), day_f).lerp(Color(0.85, 0.55, 0.4), dusk * (1.0 - dark) * 0.5)
		env.tonemap_exposure = lerpf(1.2, 1.0, day_f)
	if _sky_mat != null:
		_sky_mat.set_shader_parameter("dusk", dusk)
		_sky_mat.set_shader_parameter("night", dark)
		_sky_mat.set_shader_parameter("tint", Vector3(1.0, 1.0, 1.0).lerp(Vector3(1.15, 0.9, 0.75), dusk))
		_sky_mat.set_shader_parameter("exposure", 1.0)
	if view != null:
		view.set_night(night)
