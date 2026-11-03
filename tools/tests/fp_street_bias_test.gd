extends SceneTree
## The street sun's shadow bias per renderer (unit A1): Forward+ keeps 0.6 / 0.02, Compatibility
## (the web build) takes the raised normal bias that clears the fine stripes shadow-map acne draws
## on the roads and sidewalks of a clear-sky street. Prints FP_STREET_BIAS_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const LP := preload("res://scripts/fp/street/light_profile.gd")

var fails: Array[String] = []


func _init() -> void:
	_check_table()
	_check_profile()
	K.finish(self, "FP_STREET_BIAS_TEST", fails)


func _check_table() -> void:
	K.check(
		fails,
		is_equal_approx(Q.street_normal_bias("forward_plus"), 0.6),
		"Forward+ street normal bias is 0.6"
	)
	K.check(
		fails,
		is_equal_approx(Q.street_depth_bias("forward_plus"), 0.02),
		"Forward+ street depth bias is 0.02"
	)
	K.check(
		fails,
		is_equal_approx(Q.street_normal_bias("mobile"), 0.6),
		"any non-Compatibility renderer keeps 0.6"
	)
	var c := Q.street_normal_bias("gl_compatibility")
	K.check(
		fails,
		is_equal_approx(c, Q.COMPAT_STREET_NORMAL_BIAS) and c > 0.6,
		"Compatibility raises the normal bias (%.2f)" % c
	)
	K.check(
		fails, c >= 1.0 and c <= 2.0, "the raise stays inside the swept range 1.0 to 2.0 (%.2f)" % c
	)
	K.check(
		fails,
		is_equal_approx(Q.street_depth_bias("gl_compatibility"), Q.COMPAT_STREET_DEPTH_BIAS),
		"Compatibility's depth bias is its constant"
	)
	# The aerial table (the overview's wider cascades) is never below the street's own value.
	for p: String in Q.NAMES:
		K.check(
			fails,
			float(Q.COMPAT_AERIAL_NORMAL_BIAS[p]) >= c,
			"aerial bias of %s is not below the street's" % p
		)


func _check_profile() -> void:
	for preset: String in Q.NAMES:
		var sun := DirectionalLight3D.new()
		var env := Environment.new()
		sun.shadow_normal_bias = 0.9
		sun.shadow_bias = 0.07
		LP.apply(env, sun, "fp", preset, "gl_compatibility")
		K.check(
			fails,
			is_equal_approx(sun.shadow_normal_bias, Q.COMPAT_STREET_NORMAL_BIAS),
			(
				"%s on Compatibility: the sun takes the raised normal bias (%.2f)"
				% [preset, sun.shadow_normal_bias]
			)
		)
		LP.apply(env, sun, "orbit", preset, "gl_compatibility")
		K.check(
			fails,
			is_equal_approx(sun.shadow_normal_bias, 0.9) and is_equal_approx(sun.shadow_bias, 0.07),
			"%s: the orbit values come back" % preset
		)
		LP.apply(env, sun, "fp", preset, "forward_plus")
		K.check(
			fails,
			is_equal_approx(sun.shadow_normal_bias, 0.6) and is_equal_approx(sun.shadow_bias, 0.02),
			"%s on Forward+: the street profile's 0.6 and 0.02" % preset
		)
		sun.free()
