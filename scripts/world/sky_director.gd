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
## Compatibility (the web build) draws the same scene darker and punchier than Forward+: no SSIL
## bounce fill lifts the mid-tones, and its tonemap runs on different output buffers. Its exposure
## is scaled up and saturation down to match Forward+ shots taken at the same hour (frozen-city
## street view: luma 0.143 -> 0.248 vs Forward+ 0.241, saturation 0.421 -> 0.243 vs 0.203);
## Forward+ keeps 1.0.
## "night" is where those scales (and the ambient) end up at full dark, tuned the same way against
## Forward+ night frames (the street half of five poses, clear: mean luma 1.31x Forward+'s ->
## 1.00x; the sky half 0.52x -> 0.88x). The day boost makes up for light only the sun gives
## Forward+, so it falls back to Forward+'s exposure and saturation. "ambient" lifts the fixed
## moonlit colour and "sky_share" 0 takes the ambient over from the sky: Compatibility reads the
## sky through cheap sRGB conversions that black the night out (see sky_blend.gdshader, whose
## night "srgb_sky" encodes for them). The lift is not SSIL's bounce: on Forward+ at night SSIL,
## SSAO and the sky's share of the ambient each move the street half's mean luma by 1% or less
## (6% in the worst pose). It stands in for light Compatibility draws too little of, mostly at the
## dark end, which the same conversions crush (linear 0.002 draws as 0 and 0.004 as 8 of 255,
## against 13 on Forward+): the mean matches and the distribution does not, with more near-black
## pixels and brighter highlights, and the hue is a little further off (the street half's mean RGB
## over luma sits 0.12 from Forward+'s, 0.10 before the night look). The planner view at its
## default zoom stays 13% under Forward+'s (19% at the end of dusk). Measured against the build
## before this look, where the player looks gets DARKER, not brighter: the street half was 1.31x
## Forward+'s and drops 24% (exposure 1.92 -> 1.2), the planner view drops 28-31% in absolute luma;
## only the sky half (0.52x) was too dark. The near-black share of the street half grew too (27.8%
## against Forward+'s 15.8%; 23.1% before). A night contrast + exposure + saturation retune
## (0.97 / 0.90 / 1.25) reached both the mean and that distribution at clear 23:00, but was only
## checked on five clear poses: a follow-up, not shipped.
## "wet_exposure" is the night exposure scale once the streets are soaked (weather_wet 1): part
## of the day boost comes back with the wetness. Wet roads and ground go dark on Compatibility,
## which has no screen-space reflections, draws no Decal (lamp pools, puddles and cracks are
## missing) and crushes the dark end, and it is the wetness that does it, not the rain: soaked
## streets under a clear sky read 0.71x Forward+'s, in the rain 0.66x, with the dark night look
## alone. Scaled by 1.3 they read 0.97x and 0.89x, with the sky half 1.11x (1.18x of same-tier
## Forward+ at the web tier; exposure takes the whole frame with it). The build before this look
## read 0.94x and 0.85x there, so the term mostly restores what that build had.
const COMPAT_LOOK := {
	"exposure": 1.6,
	"saturation": 0.85,
	"contrast": 1.0,
	"ambient": 1.0,
	"sky_share": 1.0,
	"srgb_sky": 1.0,
	"night":
	{
		"exposure": 0.83,
		"saturation": 1.0,
		"contrast": 0.92,
		"ambient": 0.75,
		"sky_share": 0.0,
		"wet_ambient": 1.25,
	},
}
## Every other renderer: the day curve as it always ran (its night half is the curve's own 25%
## sky share).
const NEUTRAL_LOOK := {
	"exposure": 1.0,
	"saturation": 1.0,
	"contrast": 1.0,
	"ambient": 1.0,
	"sky_share": 1.0,
	"srgb_sky": 0.0,
	"night":
	{
		"exposure": 1.0,
		"saturation": 1.0,
		"contrast": 1.0,
		"ambient": 1.0,
		"sky_share": 0.25,
	},
}
## The Environment adjustments a look scales (adjustment_<name>), each remembered as it was before
## any scale in a meta of its own (BASE_META + name), so that setting the look up twice does not
## stack.
const ADJUSTED := ["saturation", "contrast"]
const BASE_META := "renderer_base_"

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
## grey the sky is (0 clear .. 1 overcast), a fog tint (smog), how dark sun shadows are (cloud
## cover diffuses them) and how wet the streets are (0 dry .. 1 soaked; the look's "wet_exposure"
## follows it).
var weather_energy_mult: float = 1.0
var weather_shadow_mult: float = 1.0
var weather_exposure_mult: float = 1.0
var fog_begin_override: float = -1.0
var weather_grey: float = 0.0
var weather_fog_tint: Color = Color(1, 1, 1, 0)
var weather_wet: float = 0.0
var _sky_mat: ShaderMaterial
var _dusk_fp: bool = false
## The depth-fog begin that fog_begin_override replaced (negative: nothing replaced).
var _fog_begin_saved: float = -1.0
## The scene's sun shadow opacity, which weather_shadow_mult scales.
var _shadow_opacity: float = 1.0
## The running renderer's look (renderer_look()): _apply scales the day curve by it and fades its
## "night" half in with the dark.
var look: Dictionary = NEUTRAL_LOOK


## The look for a renderer method (RenderingServer's name for it): COMPAT_LOOK on gl_compatibility,
## neutral everywhere else.
static func renderer_look(method: String) -> Dictionary:
	if method == "gl_compatibility":
		return COMPAT_LOOK
	return NEUTRAL_LOOK


## Takes on method's look: _apply follows it from here on, and its day adjustments (saturation,
## contrast) land on the shared Environment now (built on the Environment's own, remembered once,
## so a second call does not stack).
func apply_renderer_look(method: String) -> void:
	look = renderer_look(method)
	if env != null:
		for key: String in ADJUSTED:
			env.set("adjustment_" + key, _base_adjustment(key) * float(look[key]))


## One of the look's scales at the given dark and wetness: its day value at dark 0, its night value
## at dark 1, which "wet_<key>" (when the look has one) takes over as the streets get wet.
func _look_scale(key: String, dark: float, wet: float = 0.0) -> float:
	var dark_look: Dictionary = look["night"]
	var at_night := float(dark_look[key])
	var soaked := float(dark_look.get("wet_" + key, at_night))
	return lerpf(float(look[key]), lerpf(at_night, soaked, wet), dark)


## Whether the look scales an adjustment at all: one that does not leaves the Environment's own
## alone, whoever else sets it.
func _scales(key: String) -> bool:
	var dark_look: Dictionary = look["night"]
	return not (
		is_equal_approx(float(look[key]), 1.0) and is_equal_approx(float(dark_look[key]), 1.0)
	)


## An Environment adjustment before any look, remembered on it the first time it is asked.
func _base_adjustment(key: String) -> float:
	var meta := BASE_META + key
	if not env.has_meta(meta):
		env.set_meta(meta, env.get("adjustment_" + key))
	return float(env.get_meta(meta))


func setup(p_sim: CitySim, p_env: Environment, p_sun: DirectionalLight3D, p_view: CityView) -> void:
	sim = p_sim
	env = p_env
	sun = p_sun
	view = p_view
	if sun != null:
		_shadow_opacity = sun.shadow_opacity
	if OS.has_environment("GRIDFALL_HOUR"):
		fixed_hour = float(OS.get_environment("GRIDFALL_HOUR"))
	apply_renderer_look(RenderingServer.get_current_rendering_method())
	refresh_pack_assets()
	hour = _target_hour()
	_apply(1.0)


## Builds the sky material once its assets are available. Called from setup()
## and when the sky pack arrives on a split web build; idempotent — an
## existing sky, the hour, the weather state and the sun are left untouched.
func refresh_pack_assets() -> void:
	if _sky_mat != null:
		return
	if env == null or not ResourceLoader.exists(SKY_SHADER) or not ResourceLoader.exists(DAY_HDRI):
		return
	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = load(SKY_SHADER)
	_sky_mat.set_shader_parameter("day_sky", load(DAY_HDRI))
	_sky_mat.set_shader_parameter(
		"dusk_sky", load(DUSK_HDRI) if ResourceLoader.exists(DUSK_HDRI) else load(DAY_HDRI)
	)
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# Dress the new sky with the current hour/weather (dusk, night, tint, grey).
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
	weather_wet = 0.0
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
			sun.rotation_degrees = Vector3(
				-maxf(3.0, 62.0 * d), lerpf(105.0, 255.0, clampf(t, 0.0, 1.0)), 0.0
			)
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
		var wet := clampf(weather_wet, 0.0, 1.0)
		env.ambient_light_sky_contribution = _look_scale("sky_share", dark)
		env.ambient_light_energy = lerpf(0.55, 1.0, day_f) * _look_scale("ambient", dark, wet)
		var fog := Color(0.03, 0.04, 0.08).lerp(Color(0.62, 0.70, 0.80), day_f).lerp(
			Color(0.85, 0.55, 0.4), dusk * (1.0 - dark) * 0.5
		)
		fog = fog.lerp(Color(0.6, 0.62, 0.64) * lerpf(0.15, 1.0, day_f), weather_grey * 0.6)
		env.fog_light_color = fog.lerp(
			(
				Color(weather_fog_tint.r, weather_fog_tint.g, weather_fog_tint.b)
				* lerpf(0.2, 1.0, day_f)
			),
			weather_fog_tint.a
		)
		env.tonemap_exposure = (
			lerpf(1.2, 1.0, day_f) * weather_exposure_mult * _look_scale("exposure", dark)
		)
		for key: String in ADJUSTED:
			if _scales(key):
				env.set("adjustment_" + key, _base_adjustment(key) * _look_scale(key, dark))
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
			_sky_mat.set_shader_parameter(
				"dusk_sky",
				load(
					(
						DUSK_HDRI_FP
						if want_fp
						else (DUSK_HDRI if ResourceLoader.exists(DUSK_HDRI) else DAY_HDRI)
					)
				)
			)
			_sky_mat.set_shader_parameter("dusk_gain", DUSK_GAIN_FP if want_fp else DUSK_GAIN)
		_sky_mat.set_shader_parameter("dusk", dusk)
		_sky_mat.set_shader_parameter("night", dark)
		_sky_mat.set_shader_parameter(
			"tint", Vector3(1.0, 1.0, 1.0).lerp(Vector3(1.15, 0.9, 0.75), dusk)
		)
		_sky_mat.set_shader_parameter("exposure", 1.0)
		_sky_mat.set_shader_parameter("srgb_sky", float(look["srgb_sky"]))
		_sky_mat.set_shader_parameter("grey", weather_grey)
	if view != null:
		view.set_night(night)
