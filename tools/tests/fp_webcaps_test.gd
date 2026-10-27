extends SceneTree
## The web quality tier (flag web_quality): Quality.density_caps() is the single read point
## for the traffic, crowd and animal owners — empty off the web (no cap, current budgets), the
## WEB_DENSITY numbers on it, single values overridable from GRIDFALL_WEB_CAPS for profiling
## bisects — and the WEB render-knob overlay rides knobs() so every feature picks it up.

const Q := preload("res://scripts/fp/render/quality.gd")

var _fail := 0


func _check(ok: bool, name: String) -> void:
	if ok:
		print("PASS ", name)
	else:
		_fail += 1
		print("FAIL ", name)


func _init() -> void:
	_check(not Q.web_mode(), "web tier stays off on a desktop run")
	_check(Q.density_caps().is_empty(), "off the web: no density caps")
	var caps := Q.density_caps(true)
	_check(
		(
			int(caps.get("traffic", -1)) == 12
			and int(caps.get("crowd", -1)) == 24
			and int(caps.get("animals", -1)) == 6
			and caps.size() == 3
		),
		"web tier: caps for traffic, crowd and animals (%s)" % str(caps)
	)
	OS.set_environment("GRIDFALL_WEB_CAPS", "traffic=8,bogus=99")
	var tuned := Q.density_caps(true)
	OS.set_environment("GRIDFALL_WEB_CAPS", "")
	_check(
		(
			int(tuned.get("traffic", -1)) == 8
			and int(tuned.get("crowd", -1)) == 24
			and not tuned.has("bogus")
		),
		"GRIDFALL_WEB_CAPS overrides one cap, ignores unknown keys"
	)
	var plain := Q.knobs("low")
	_check(
		int(plain["atlas"]) == 2048 and is_equal_approx(float(plain["far"]), 45.0),
		"off the web: Low keeps its own knobs"
	)
	var web := Q.knobs("low", true)
	_check(
		(
			int(web["atlas"]) == 1024
			and is_equal_approx(float(web["vis"]), 0.55)
			and is_equal_approx(float(web["far"]), 35.0)
			and is_equal_approx(float(web["lod"]), 2.5)
			and int(web["lights"]) == 4
		),
		"web tier: atlas 1024, vis 0.55, far 35, LOD 2.5, 4 street lights"
	)
	var vk := Q.viewport_knobs("low", "gl_compatibility", true)
	_check(
		(
			int(vk["scaling_mode"]) == Viewport.SCALING_3D_MODE_BILINEAR
			and is_equal_approx(float(vk["scale"]), 0.6)
			and int(vk["msaa"]) == Viewport.MSAA_DISABLED
		),
		"web tier: bilinear 0.6 scale, MSAA off"
	)
	_check(
		(
			is_equal_approx(Q.camera_far("low", true), 35.0)
			and is_equal_approx(Q.vis_mult("low", true), 0.55)
			and Q.max_street_lights("low", true) == 4
		),
		"web tier reaches the helper readers (far, vis, lights)"
	)
	if _fail == 0:
		print("FP_WEBCAPS_TEST: PASS")
		quit(0)
	else:
		print("FP_WEBCAPS_TEST: FAIL (", _fail, ")")
		quit(1)
