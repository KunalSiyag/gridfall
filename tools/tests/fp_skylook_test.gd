extends SceneTree
## The sky director's renderer looks across the whole day: what it puts on the Environment, the sun
## and the sky material for Forward+ and for Compatibility (the web build) at day, dusk, night and
## dawn, dry and soaked. Forward+ must be exactly the formulas it always ran (written out below)
## and write nothing else; Compatibility's day and dusk must be its old look (exposure x1.6,
## saturation x0.85) and only its night may differ (a lower exposure and contrast that make up for
## the dark end its tonemap path crushes, Forward+'s own moonlit ambient with none of the sky's
## share, the sky shader's sRGB night, and more ambient as the streets get wet); and nothing may
## jump: no Environment property, sun or sky value steps by more than MAX_STEP between samples 15
## game seconds apart, through dusk and dawn alike and as the wetness rises, and the ambient
## source never switches. setup() must pick the look of the renderer that is running (the gate
## runs this test on Forward+ and on Compatibility).

const K := preload("res://tools/tests/fp_kit.gd")
## The scene's own Environment, which the sweeps start from: its many properties off their defaults
## (contrast, glow, SSAO, fog...) let a write of any of them show.
const SCENE_ENV := preload("res://scenes/main-environment.tres")
## The saturation and the contrast that Environment carries before any look.
const BASE_SAT := 1.08
const BASE_CON := 1.05
## Hours between samples (15 game seconds).
const STEP := 1.0 / 240.0
const EPS := 1e-6
## The real ramps move a property by under 0.006 a sample; a switch at a threshold, by tenths.
const MAX_STEP := 0.02
## What a sample records besides the Environment snapshot, and so what the continuity check
## watches there.
const TRACKED := [
	"amb_e",
	"amb_sky",
	"exp",
	"sat",
	"con",
	"fog_r",
	"fog_g",
	"fog_b",
	"sun_e",
	"srgb",
	"night_u",
	"dusk_u"
]
## What the looks must leave to the day curve, renderer for renderer, at every hour.
const UNTOUCHED := ["fog_r", "fog_g", "fog_b", "sun_e", "night_u", "dusk_u", "tint_x"]
## The Environment properties the director rewrites; on Compatibility, saturation and contrast as
## well. Every other one must stay what it was set to, but for the three that building its sky sets
## once.
const WRITTEN := [
	"ambient_light_color",
	"ambient_light_sky_contribution",
	"ambient_light_energy",
	"fog_light_color",
	"tonemap_exposure"
]
const SET_UP := ["background_mode", "ambient_light_source", "reflected_light_source"]

var fails: Array[String] = []
## The Environment's scalar properties a snapshot holds, and for each snapshot entry its name
## (colours one entry a channel).
var _props: Array[String] = []
var _is_color: Array[bool] = []
var _names := PackedStringArray()
## The Environment as _director() found it, before the director touched it.
var _pre_snap := PackedFloat64Array()


func _init() -> void:
	var fwd := _sweep("forward_plus")
	var gl := _sweep("gl_compatibility")
	var fwd_wet := _sweep("forward_plus", 1.0)
	var gl_wet := _sweep("gl_compatibility", 1.0)
	var ran := not fwd.is_empty() and not gl.is_empty()
	K.check(fails, ran, "both sweeps ran (%d samples each)" % gl.size())
	if ran:
		_check_forward_is_the_baseline(fwd)
		_check_compat_day_is_the_old_look(gl)
		_check_looks_leave_the_rest_alone(gl, fwd)
		_check_writes_nothing_else(fwd, gl)
		_check_compat_night(gl, fwd)
		_check_twilight_is_between(gl)
		_check_continuity(fwd, "Forward+")
		_check_continuity(gl, "Compatibility")
		_check_continuity(gl_wet, "Compatibility, soaked")
		_check_wetness(fwd, fwd_wet, gl, gl_wet)
		_check_weather_and_setup()
		_check_setup_picks_the_running_renderer()
	K.finish(self, "FP_SKYLOOK_TEST", fails)


## One director per renderer, set to every sample hour of the day in turn (blended in at once) with
## the streets as wet as asked. Returns the samples, the first one as the director left things
## before the sweep: the hour, the values the director wrote to the sun and the sky shader, and a
## snapshot of the Environment (see _snap).
func _sweep(method: String, wet: float = 0.0) -> Array:
	var sky := _director(method, wet)
	var mat: ShaderMaterial = sky._sky_mat
	K.check(fails, mat != null, "%s: the sky material builds" % method)
	if mat == null:
		sky.sun.free()
		sky.free()
		return []
	var names: Array[String] = []
	for u: Dictionary in mat.shader.get_shader_uniform_list():
		names.append(str(u["name"]))
	K.check(fails, "srgb_sky" in names, "%s: sky_blend has the srgb_sky parameter" % method)
	var first := _sample(sky, -1.0)
	first["snap"] = _pre_snap
	var out: Array = [first]
	for i in range(int(round(24.0 / STEP)) + 1):
		var h := float(i) * STEP
		sky.hour = h
		sky._apply(1.0)
		out.append(_sample(sky, h))
	sky.sun.free()
	sky.free()
	return out


## A director with its own Environment, sun and sky material, set up for a renderer.
func _director(method: String, wet: float) -> SkyDirector:
	var sky := SkyDirector.new()
	sky.env = SCENE_ENV.duplicate() as Environment
	sky.env.adjustment_saturation = BASE_SAT
	sky.env.adjustment_contrast = BASE_CON
	_pre_snap = _snap(sky.env)
	sky.sun = DirectionalLight3D.new()
	sky.refresh_pack_assets()
	sky.apply_renderer_look(method)
	sky.weather_wet = wet
	return sky


## What the director has written at its current hour.
func _sample(sky: SkyDirector, h: float) -> Dictionary:
	var env := sky.env
	var mat: ShaderMaterial = sky._sky_mat
	var fog := env.fog_light_color
	var tint: Vector3 = mat.get_shader_parameter("tint")
	return {
		"h": h,
		"amb_e": env.ambient_light_energy,
		"amb_sky": env.ambient_light_sky_contribution,
		"amb_src": env.ambient_light_source,
		"exp": env.tonemap_exposure,
		"sat": env.adjustment_saturation,
		"con": env.adjustment_contrast,
		"fog_r": fog.r,
		"fog_g": fog.g,
		"fog_b": fog.b,
		"sun_e": sky.sun.light_energy,
		"srgb": float(mat.get_shader_parameter("srgb_sky")),
		"night_u": float(mat.get_shader_parameter("night")),
		"dusk_u": float(mat.get_shader_parameter("dusk")),
		"tint_x": tint.x,
		"snap": _snap(env),
	}


## Every scalar property of the Environment (float, int, bool, and colours by channel) as numbers,
## in the order of _names: what the continuity and "writes nothing else" checks compare.
func _snap(env: Environment) -> PackedFloat64Array:
	if _props.is_empty():
		for p: Dictionary in env.get_property_list():
			var kind := int(p["type"])
			if (int(p["usage"]) & PROPERTY_USAGE_STORAGE) == 0:
				continue
			if kind == TYPE_COLOR:
				for ch: String in ["r", "g", "b", "a"]:
					_names.append("%s.%s" % [p["name"], ch])
			elif kind == TYPE_FLOAT or kind == TYPE_INT or kind == TYPE_BOOL:
				_names.append(str(p["name"]))
			else:
				continue
			_props.append(str(p["name"]))
			_is_color.append(kind == TYPE_COLOR)
	var out := PackedFloat64Array()
	for i in range(_props.size()):
		var v: Variant = env.get(_props[i])
		if _is_color[i]:
			var c: Color = v
			out.append(c.r)
			out.append(c.g)
			out.append(c.b)
			out.append(c.a)
		else:
			out.append(float(v))
	return out


## The index of every snapshot entry whose property is one of owned.
func _owned(owned: Array) -> Dictionary:
	var idx: Dictionary = {}
	for k in range(_names.size()):
		if _names[k].get_slice(".", 0) in owned:
			idx[k] = true
	return idx


## The day curve as it ran before the looks had a night, for an hour: the ambient energy, the sky's
## share of the ambient, the exposure, and how dark it is (0 by day and at dusk, 1 at deep night).
func _curve(h: float) -> Dictionary:
	var d := sin(PI * (h - 6.0) / 12.0)
	var day_f := smoothstep(-0.12, 0.3, d)
	var dark := smoothstep(-0.05, -0.35, d)
	return {
		"amb_e": lerpf(0.55, 1.0, day_f),
		"amb_sky": lerpf(1.0, 0.25, dark),
		"exp": lerpf(1.2, 1.0, day_f),
		"dark": dark,
	}


func _near(a: float, b: float) -> bool:
	return absf(a - b) < EPS


func _check_forward_is_the_baseline(fwd: Array) -> void:
	var worst := 0.0
	var flat := true
	for k in range(1, fwd.size()):
		var s: Dictionary = fwd[k]
		var c := _curve(float(s["h"]))
		worst = maxf(worst, absf(float(s["amb_e"]) - float(c["amb_e"])))
		worst = maxf(worst, absf(float(s["amb_sky"]) - float(c["amb_sky"])))
		worst = maxf(worst, absf(float(s["exp"]) - float(c["exp"])))
		worst = maxf(worst, absf(float(s["sat"]) - BASE_SAT))
		worst = maxf(worst, absf(float(s["con"]) - BASE_CON))
		flat = (
			flat and float(s["srgb"]) == 0.0 and int(s["amb_src"]) == Environment.AMBIENT_SOURCE_SKY
		)
	K.check(fails, worst < EPS, "Forward+: look scales keep the old curves (%.9f)" % worst)
	K.check(
		fails,
		flat,
		"Forward+: the sky stays linear (srgb_sky 0) and the ambient source stays the sky"
	)


func _check_compat_day_is_the_old_look(gl: Array) -> void:
	var worst := 0.0
	var seen := 0
	for k in range(1, gl.size()):
		var s: Dictionary = gl[k]
		var c := _curve(float(s["h"]))
		if float(c["dark"]) > 0.0:
			continue
		seen += 1
		worst = maxf(worst, absf(float(s["exp"]) - float(c["exp"]) * 1.6))
		worst = maxf(worst, absf(float(s["sat"]) - BASE_SAT * 0.85))
		worst = maxf(worst, absf(float(s["con"]) - BASE_CON))
		worst = maxf(worst, absf(float(s["amb_e"]) - float(c["amb_e"])))
		worst = maxf(worst, absf(float(s["amb_sky"]) - 1.0))
	K.check(fails, seen > 2000, "Compatibility: %d samples before the sky goes dark" % seen)
	var msg := "Compatibility: day and dusk are its old look, x1.6 exposure, x0.85 saturation"
	K.check(fails, worst < EPS, "%s (%.9f off)" % [msg, worst])


## The looks touch the exposure, saturation, contrast, ambient and sky encode; the fog, the sun and
## the sky's own dusk, night and tint are the day curve's, the same on both renderers at every hour.
func _check_looks_leave_the_rest_alone(gl: Array, fwd: Array) -> void:
	var worst := 0.0
	for k in range(1, gl.size()):
		for key: String in UNTOUCHED:
			worst = maxf(
				worst, absf(float((gl[k] as Dictionary)[key]) - float((fwd[k] as Dictionary)[key]))
			)
	K.check(
		fails,
		worst == 0.0,
		(
			"Compatibility: fog, sun, dusk, night and tint are Forward+'s at every hour (%.9f off)"
			% worst
		)
	)


## Whatever else sits on the Environment stays as the scene set it, at every hour: Forward+ gets
## only what the day curve always wrote, Compatibility its saturation and contrast on top.
func _check_writes_nothing_else(fwd: Array, gl: Array) -> void:
	var cases := [
		["Forward+", fwd, _owned(WRITTEN + SET_UP)],
		[
			"Compatibility",
			gl,
			_owned(WRITTEN + SET_UP + ["adjustment_saturation", "adjustment_contrast"])
		],
	]
	for row: Array in cases:
		var samples: Array = row[1]
		var skip: Dictionary = row[2]
		var first: PackedFloat64Array = (samples[0] as Dictionary)["snap"]
		var moved := ""
		for k in range(1, samples.size()):
			var snap: PackedFloat64Array = (samples[k] as Dictionary)["snap"]
			for i in range(snap.size()):
				if not skip.has(i) and snap[i] != first[i]:
					moved = "%s at %.2f h" % [_names[i], float((samples[k] as Dictionary)["h"])]
					break
			if not moved.is_empty():
				break
		K.check(
			fails,
			moved.is_empty(),
			(
				"%s: the director writes no other Environment property (%d watched) %s"
				% [row[0], _names.size(), moved]
			)
		)


func _check_compat_night(gl: Array, fwd: Array) -> void:
	var look := SkyDirector.renderer_look("gl_compatibility")
	var night := look["night"] as Dictionary
	var at := 1 + int(round(1.0 / STEP))
	var s: Dictionary = gl[at]
	var f: Dictionary = fwd[at]
	var c := _curve(float(s["h"]))
	K.check(fails, float(c["dark"]) == 1.0, "01:00 is fully dark")
	K.check(
		fails,
		_near(float(s["exp"]), float(c["exp"]) * float(night["exposure"])),
		"Compatibility night: exposure is the curve's x%.2f (%.3f)" % [night["exposure"], s["exp"]]
	)
	K.check(
		fails,
		_near(float(s["sat"]), BASE_SAT * float(night["saturation"])),
		"Compatibility night: saturation is Forward+'s (%.3f)" % float(s["sat"])
	)
	K.check(
		fails,
		_near(float(s["con"]), BASE_CON * float(night["contrast"])),
		"Compatibility night: contrast is lowered to %.3f" % float(s["con"])
	)
	K.check(
		fails,
		_near(float(s["amb_e"]), float(c["amb_e"]) * float(night["ambient"])),
		(
			"Compatibility night: the ambient energy is the curve's x%.2f (%.3f)"
			% [night["ambient"], s["amb_e"]]
		)
	)
	K.check(
		fails,
		_near(float(s["amb_sky"]), float(night["sky_share"])),
		"Compatibility night: the sky's share of the ambient is %.2f" % float(night["sky_share"])
	)
	# Forward+ lights the night with the moonlit colour at 75% of the ambient and the sky at the
	# other 25%; the sky is black on Compatibility, so the colour alone has to carry the same light.
	var fwd_colour := float(f["amb_e"]) * (1.0 - float(f["amb_sky"]))
	var gl_colour := float(s["amb_e"]) * (1.0 - float(s["amb_sky"]))
	K.check(
		fails,
		_near(gl_colour, fwd_colour),
		(
			"Compatibility night: the moonlit ambient is Forward+'s (%.4f vs %.4f)"
			% [gl_colour, fwd_colour]
		)
	)
	K.check(
		fails,
		_near(float(s["srgb"]), 1.0) and _near(float(s["night_u"]), 1.0),
		"Compatibility night: the sky shader encodes its night"
	)
	K.check(
		fails,
		float(night["exposure"]) < float(look["exposure"]) and float(night["contrast"]) < 1.0,
		"Compatibility: the night boosts less than the day, and lowers the contrast"
	)
	# The tuned numbers themselves, from the A/B against Forward+ night frames (street half of five
	# poses, clear weather: mean luma 1.01x, median 0.94x, and the near-black, blown-out and hue
	# measures all closer to Forward+'s than before). A retune is a new measurement, so a change has
	# to change these too: the old night look (exposure x1.0, no contrast, ambient x1.1, 1.31x
	# Forward+'s mean at x1.6) and the ambient of Forward+ minus its sky all fail.
	var tuned := (
		absf(float(night["exposure"]) - 0.83) <= 0.04
		and absf(float(night["contrast"]) - 0.92) <= 0.02
		and absf(float(night["ambient"]) - 0.75) <= 0.03
		and float(night["sky_share"]) == 0.0
		and absf(float(night["saturation"]) - 1.0) <= 0.05
		and float(look["srgb_sky"]) == 1.0
	)
	K.check(
		fails,
		tuned,
		(
			"Compatibility night: the tuned exposure x0.83, contrast x0.92, ambient x0.75 (%s)"
			% str(night)
		)
	)
	var wet := float(night["wet_ambient"])
	K.check(
		fails,
		wet > float(night["ambient"]) and absf(wet - 1.25) <= 0.15,
		"Compatibility: soaked streets get more of the moonlit ambient (x%.2f)" % wet
	)


## Between dark 0 and 1 (about 18:11 to 19:22, and the same in the morning) every blended value
## sits between its day and its night end, and passes through them: dusk and dawn are a blend.
func _check_twilight_is_between(gl: Array) -> void:
	var look := SkyDirector.renderer_look("gl_compatibility")
	var night := look["night"] as Dictionary
	var ok := true
	var mid := 0
	for k in range(1, gl.size()):
		var s: Dictionary = gl[k]
		var c := _curve(float(s["h"]))
		var dark := float(c["dark"])
		if dark <= 0.0 or dark >= 1.0:
			continue
		var sat := float(s["sat"]) / BASE_SAT
		ok = ok and sat >= 0.85 - EPS and sat <= float(night["saturation"]) + EPS
		var con := float(s["con"]) / BASE_CON
		ok = ok and con >= float(night["contrast"]) - EPS and con <= 1.0 + EPS
		ok = ok and _near(con, lerpf(1.0, float(night["contrast"]), dark))
		var share := float(s["amb_sky"])
		ok = ok and share >= float(night["sky_share"]) - EPS and share <= 1.0 + EPS
		var energy := float(s["amb_e"]) / float(c["amb_e"])
		ok = ok and _near(energy, lerpf(1.0, float(night["ambient"]), dark))
		# Exposure is the day curve times a scale that slides from 1.6 to the night's with the dark.
		var scale := float(s["exp"]) / float(c["exp"])
		ok = (
			ok
			and scale >= float(night["exposure"]) - EPS
			and scale <= float(look["exposure"]) + EPS
		)
		ok = ok and _near(scale, lerpf(float(look["exposure"]), float(night["exposure"]), dark))
		if dark > 0.4 and dark < 0.6:
			mid += 1
	K.check(fails, ok, "Compatibility: dusk and dawn values sit between the day and night ends")
	K.check(
		fails, mid > 10, "Compatibility: the sweep samples the middle of dusk and dawn (%d)" % mid
	)


## No step between samples over MAX_STEP in any Environment property, nor in what the sample
## records of the sun and the sky shader, and no switch of the ambient source: a threshold flip
## anywhere in the look would show here, whichever property it flipped.
func _check_continuity(samples: Array, label: String) -> void:
	var worst := 0.0
	var at := ""
	var src_same := true
	for k in range(2, samples.size()):
		var a: Dictionary = samples[k - 1]
		var b: Dictionary = samples[k]
		src_same = src_same and int(a["amb_src"]) == int(b["amb_src"])
		for key: String in TRACKED:
			var step := absf(float(b[key]) - float(a[key]))
			if step > worst:
				worst = step
				at = "%s at %.2f h" % [key, float(b["h"])]
		var sa: PackedFloat64Array = a["snap"]
		var sb: PackedFloat64Array = b["snap"]
		for i in range(sa.size()):
			var step := absf(sb[i] - sa[i])
			if step > worst:
				worst = step
				at = "%s at %.2f h" % [_names[i], float(b["h"])]
	K.check(
		fails,
		worst <= MAX_STEP,
		"%s: no step over %.3f across the day (worst %.4f, %s)" % [label, MAX_STEP, worst, at]
	)
	K.check(fails, src_same, "%s: the ambient source never switches" % label)
	var first: Dictionary = samples[1]
	var last: Dictionary = samples[samples.size() - 1]
	var wrap := 0.0
	for key: String in TRACKED:
		wrap = maxf(wrap, absf(float(last[key]) - float(first[key])))
	var snap_first: PackedFloat64Array = first["snap"]
	var snap_last: PackedFloat64Array = last["snap"]
	for i in range(snap_first.size()):
		wrap = maxf(wrap, absf(snap_last[i] - snap_first[i]))
	K.check(fails, wrap < EPS, "%s: 24:00 is 00:00 (%.9f off)" % [label, wrap])


## The streets' wetness (weather_wet) changes nothing on Forward+ and nothing by day on
## Compatibility; at night it raises the ambient from its dry to its soaked level, and only that.
func _check_wetness(fwd: Array, fwd_wet: Array, gl: Array, gl_wet: Array) -> void:
	var same := true
	for k in range(fwd.size()):
		var dry: Dictionary = fwd[k]
		var soaked: Dictionary = fwd_wet[k]
		same = same and dry["snap"] == soaked["snap"] and float(dry["exp"]) == float(soaked["exp"])
	K.check(fails, same, "Forward+: wet streets change nothing the director writes")
	var look := SkyDirector.renderer_look("gl_compatibility")
	var wet_amb := float((look["night"] as Dictionary)["wet_ambient"])
	var day_same := true
	var night_ok := true
	var night_n := 0
	for k in range(1, gl.size()):
		var dry: Dictionary = gl[k]
		var soaked: Dictionary = gl_wet[k]
		var c := _curve(float(dry["h"]))
		var dark := float(c["dark"])
		if dark == 0.0:
			day_same = day_same and dry["snap"] == soaked["snap"]
			continue
		night_n += 1
		var scale := float(soaked["amb_e"]) / float(c["amb_e"])
		night_ok = night_ok and _near(scale, lerpf(1.0, wet_amb, dark))
		night_ok = night_ok and float(soaked["amb_e"]) >= float(dry["amb_e"]) - EPS
		for key: String in ["exp", "sat", "con", "amb_sky"]:
			night_ok = night_ok and _near(float(soaked[key]), float(dry[key]))
	K.check(fails, day_same, "Compatibility: wet streets change nothing while it is light")
	K.check(
		fails,
		night_ok and night_n > 2000,
		"Compatibility: wet streets raise the night ambient to x%.2f, and only that" % wet_amb
	)
	_check_wet_sweep("gl_compatibility", 1.0)
	_check_wet_sweep("gl_compatibility", 19.0)
	_check_wet_sweep("forward_plus", 1.0)


## The wetness from 0 to 1 (and a little beyond both ends) at one hour: the ambient follows it
## linearly between the dry and the soaked night ambient, no Environment property steps, and 0 and
## below are dry, 1 and above soaked.
func _check_wet_sweep(method: String, h: float) -> void:
	var sky := _director(method, 0.0)
	sky.hour = h
	var night := SkyDirector.renderer_look(method)["night"] as Dictionary
	var c := _curve(h)
	var dark := float(c["dark"])
	var dry_scale := lerpf(1.0, float(night["ambient"]), dark)
	var soaked_scale := lerpf(1.0, float(night.get("wet_ambient", night["ambient"])), dark)
	var prev := PackedFloat64Array()
	var worst := 0.0
	var linear := true
	var amb_at := {}
	var steps := 240
	for i in range(-12, steps + 13):
		var w := float(i) / float(steps)
		sky.weather_wet = w
		sky._apply(1.0)
		var snap := _snap(sky.env)
		for j in range(prev.size()):
			worst = maxf(worst, absf(snap[j] - prev[j]))
		prev = snap
		var want := lerpf(dry_scale, soaked_scale, clampf(w, 0.0, 1.0)) * float(c["amb_e"])
		linear = linear and _near(sky.env.ambient_light_energy, want)
		amb_at[i] = sky.env.ambient_light_energy
	var label := "%s at %02d:00" % [method, int(h)]
	K.check(fails, worst <= MAX_STEP, "%s: wetness 0 to 1 steps nothing (%.5f)" % [label, worst])
	K.check(
		fails, linear, "%s: ambient follows the wetness between its dry and soaked ends" % label
	)
	var dry_end := _near(float(amb_at[-12]), float(amb_at[0]))
	var soaked_end := _near(float(amb_at[steps + 12]), float(amb_at[steps]))
	K.check(fails, dry_end and soaked_end, "%s: wetness outside 0..1 counts as the end" % label)
	sky.sun.free()
	sky.free()


## Setting the look up twice does not stack it, an unknown renderer is Forward+'s, the weather's
## hooks still ride on top of the look: under rain at night Compatibility's exposure is the
## night's whatever the wetness, and its ambient climbs with the wetness while Forward+'s stays.
func _check_weather_and_setup() -> void:
	var neutral := SkyDirector.renderer_look("some_future_renderer")
	K.check(
		fails,
		neutral == SkyDirector.renderer_look("forward_plus") and neutral["srgb_sky"] == 0.0,
		"an unknown renderer takes Forward+'s look"
	)
	var exp_by := {}
	var amb_by := {}
	var sat_by := {}
	for method: String in ["forward_plus", "gl_compatibility"]:
		var sky := SkyDirector.new()
		sky.env = Environment.new()
		sky.env.adjustment_saturation = BASE_SAT
		sky.env.adjustment_contrast = BASE_CON
		sky.apply_renderer_look(method)
		sky.apply_renderer_look(method)
		sky.weather_exposure_mult = 0.86
		sky.weather_grey = 1.0
		sky.hour = 1.0
		for wet: float in [0.0, 0.5, 1.0]:
			sky.weather_wet = wet
			sky._apply(1.0)
			exp_by["%s %.1f" % [method, wet]] = sky.env.tonemap_exposure
			amb_by["%s %.1f" % [method, wet]] = sky.env.ambient_light_energy
		sat_by[method] = sky.env.adjustment_saturation
		sky.hour = 12.0
		sky._apply(1.0)
		var look := SkyDirector.renderer_look(method)
		var want := BASE_SAT * float(look["saturation"])
		K.check(
			fails,
			_near(sky.env.adjustment_saturation, want),
			(
				"%s: saturation applied once, not stacked (%.4f)"
				% [method, sky.env.adjustment_saturation]
			)
		)
		var want_con := BASE_CON * float(look["contrast"])
		K.check(
			fails,
			_near(sky.env.adjustment_contrast, want_con),
			"%s: contrast applied once, not stacked (%.4f)" % [method, sky.env.adjustment_contrast]
		)
		sky.free()
	var rain := 1.2 * 0.86
	var night := SkyDirector.renderer_look("gl_compatibility")["night"] as Dictionary
	var low := 0.55 * float(night["ambient"])
	var soaked := 0.55 * float(night["wet_ambient"])
	K.check(
		fails,
		(
			_near(float(exp_by["forward_plus 0.0"]), rain)
			and _near(float(exp_by["forward_plus 1.0"]), rain)
			and _near(float(exp_by["gl_compatibility 0.0"]), rain * float(night["exposure"]))
			and _near(float(exp_by["gl_compatibility 1.0"]), rain * float(night["exposure"]))
		),
		(
			"rain at night: the weather's exposure rides on the look whatever the wetness (%.4f)"
			% float(exp_by["gl_compatibility 1.0"])
		)
	)
	K.check(
		fails,
		(
			_near(float(amb_by["forward_plus 0.0"]), 0.55)
			and _near(float(amb_by["forward_plus 1.0"]), 0.55)
			and _near(float(amb_by["gl_compatibility 0.0"]), low)
			and _near(float(amb_by["gl_compatibility 0.5"]), (low + soaked) / 2.0)
			and _near(float(amb_by["gl_compatibility 1.0"]), soaked)
		),
		(
			"rain at night, streets wet: Compatibility's ambient climbs with them (%.4f, %.4f)"
			% [float(amb_by["gl_compatibility 0.5"]), float(amb_by["gl_compatibility 1.0"])]
		)
	)
	K.check(
		fails,
		_near(float(sat_by["gl_compatibility"]), float(sat_by["forward_plus"])),
		"night: Compatibility's saturation is Forward+'s (%.4f)" % float(sat_by["gl_compatibility"])
	)
	_check_adjustments_are_left_alone()
	_check_reset_weather()


## Forward+'s look does not scale saturation or contrast, so ones set after setup (a photo mode, a
## slider) survive every frame; Compatibility's does, and owns them.
func _check_adjustments_are_left_alone() -> void:
	var sky := SkyDirector.new()
	sky.env = Environment.new()
	sky.env.adjustment_saturation = BASE_SAT
	sky.env.adjustment_contrast = BASE_CON
	sky.apply_renderer_look("forward_plus")
	sky.env.adjustment_saturation = 1.5
	sky.env.adjustment_contrast = 1.2
	for h: float in [1.0, 12.0, 19.0]:
		sky.hour = h
		sky._apply(1.0)
	var kept := sky.env.adjustment_saturation
	var kept_con := sky.env.adjustment_contrast
	K.check(
		fails,
		_near(kept, 1.5) and _near(kept_con, 1.2),
		(
			"Forward+: a saturation and contrast set after setup survive _apply (%.3f, %.3f)"
			% [kept, kept_con]
		)
	)
	sky.apply_renderer_look("gl_compatibility")
	sky.hour = 12.0
	sky._apply(1.0)
	var owned := sky.env.adjustment_saturation
	var owned_con := sky.env.adjustment_contrast
	K.check(
		fails,
		_near(owned, BASE_SAT * 0.85) and _near(owned_con, BASE_CON),
		"Compatibility: the look owns saturation, contrast (%.4f, %.4f)" % [owned, owned_con]
	)
	sky.free()


func _check_reset_weather() -> void:
	var sky := SkyDirector.new()
	sky.weather_wet = 0.7
	sky.weather_grey = 0.5
	sky.reset_weather()
	K.check(
		fails,
		sky.weather_wet == 0.0 and sky.weather_grey == 0.0,
		"reset_weather() dries the streets with the rest of the weather"
	)
	sky.free()


## setup() takes the look of the renderer that is running, not whichever the director started
## with: starting from the other look, a setup() that never picks one (or picks a fixed one on the
## wrong renderer) leaves the look wrong. The gate runs this test once on each renderer.
func _check_setup_picks_the_running_renderer() -> void:
	var method := RenderingServer.get_current_rendering_method()
	var want := SkyDirector.renderer_look(method)
	var other: Dictionary = (
		SkyDirector.NEUTRAL_LOOK if want == SkyDirector.COMPAT_LOOK else SkyDirector.COMPAT_LOOK
	)
	var sky := SkyDirector.new()
	sky.env = Environment.new()
	sky.env.adjustment_saturation = BASE_SAT
	sky.env.adjustment_contrast = BASE_CON
	sky.look = other
	sky.setup(null, sky.env, null, null)
	K.check(fails, sky.look == want, "setup() takes the running renderer's look (%s)" % method)
	var sat := sky.env.adjustment_saturation
	K.check(
		fails,
		_near(sat, BASE_SAT * float(want["saturation"])),
		"setup() puts that look's saturation on the Environment (%.4f)" % sat
	)
	var con := sky.env.adjustment_contrast
	K.check(
		fails,
		_near(con, BASE_CON * float(want["contrast"])),
		"setup() puts that look's contrast on the Environment (%.4f)" % con
	)
	var mat: ShaderMaterial = sky._sky_mat
	var encode := (
		mat != null and _near(float(mat.get_shader_parameter("srgb_sky")), float(want["srgb_sky"]))
	)
	K.check(fails, encode, "setup() sets the sky shader's sRGB encode for that renderer")
	sky.free()
