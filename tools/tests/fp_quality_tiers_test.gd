extends SceneTree
## The web quality tiers (unit A1): Low, Medium and High each have their own browser overlay
## instead of one overlay over every preset; Low stays exactly what the browser build ships (it
## starts on Low), the tiers rise monotonically, the desktop presets are untouched, and the web
## density ceilings hold the lighter traffic. Prints FP_QUALITY_TIERS_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const PM := preload("res://scripts/fp/ui/pause_menu.gd")
const KEYS := ["scale", "atlas", "vis", "far", "lod", "lights"]

var fails: Array[String] = []


func _init() -> void:
	_check_low_unchanged()
	_check_monotonic()
	_check_merge()
	_check_viewport()
	_check_density()
	_check_desktop()
	_check_migration()
	_check_label()
	K.finish(self, "FP_QUALITY_TIERS_TEST", fails)


## The default (Low) tier is the overlay that shipped: scale 0.6, atlas 1024, vis 0.55, far 35,
## lod 2.5, 4 lights.
func _check_low_unchanged() -> void:
	var w := Q.knobs("low", true)
	var ok := (
		is_equal_approx(float(w["scale"]), 0.6)
		and int(w["atlas"]) == 1024
		and is_equal_approx(float(w["vis"]), 0.55)
	)
	ok = (
		ok
		and is_equal_approx(float(w["far"]), 35.0)
		and is_equal_approx(float(w["lod"]), 2.5)
		and int(w["lights"]) == 4
	)
	K.check(fails, ok, "web Low is the tier that shipped (0.6, 1024, 0.55, 35, 2.5, 4 lights)")
	K.check(fails, Q.WEB_TIERS["low"] == Q.WEB, "WEB is the Low tier")


## Every knob rises (or stays) from Low to High, and the tiers really differ.
func _check_monotonic() -> void:
	K.check(fails, Q.WEB_TIERS.keys() == Q.NAMES, "one web tier per preset name")
	for key: String in KEYS:
		var lo := float(Q.web_knobs("low")[key])
		var me := float(Q.web_knobs("medium")[key])
		var hi := float(Q.web_knobs("high")[key])
		# lod is a threshold in pixels of error: it falls as the quality rises.
		var rises := (lo >= me and me >= hi) if key == "lod" else (lo <= me and me <= hi)
		K.check(
			fails,
			rises and lo != hi,
			"web tiers rise from Low to High on %s (%s, %s, %s)" % [key, lo, me, hi]
		)
	K.check(
		fails,
		(
			Q.WEB_TIERS["medium"] != Q.WEB_TIERS["low"]
			and Q.WEB_TIERS["high"] != Q.WEB_TIERS["medium"]
		),
		"the three tiers are three different tables"
	)


## knobs() merges the preset's own overlay, not one for all.
func _check_merge() -> void:
	for p: String in Q.NAMES:
		var k := Q.knobs(p, true)
		var t: Dictionary = Q.web_knobs(p)
		var same := true
		for key: String in KEYS:
			same = same and k[key] == t[key]
		K.check(fails, same, "knobs(%s, web) carries the %s web tier" % [p, p])
		K.check(
			fails,
			k["soft"] == Q.PRESETS[p]["soft"] and k["scaling_mode"] == Q.PRESETS[p]["scaling_mode"],
			"%s keeps the preset's other knobs under the web overlay" % p
		)
	K.check(
		fails,
		Q.web_knobs("bogus") == Q.web_knobs(Q.DEFAULT),
		"an unknown preset takes the default tier"
	)
	K.check(
		fails,
		(
			is_equal_approx(Q.vis_mult("high", true), float(Q.WEB_HIGH["vis"]))
			and Q.max_street_lights("medium", true) == int(Q.WEB_MEDIUM["lights"])
			and is_equal_approx(Q.camera_far("high", true), 45.0)
		),
		"the helper readers follow the tier"
	)


func _check_viewport() -> void:
	var last := 0.0
	for p: String in Q.NAMES:
		var vk := Q.viewport_knobs(p, "gl_compatibility", true)
		var s := float(vk["scale"])
		K.check(
			fails,
			is_equal_approx(s, float(Q.web_knobs(p)["scale"])) and s > last and s < 1.0,
			"web %s renders at its tier's scale %.2f" % [p, s]
		)
		K.check(
			fails,
			(
				int(vk["scaling_mode"]) == Viewport.SCALING_3D_MODE_BILINEAR
				and int(vk["msaa"]) == Viewport.MSAA_DISABLED
			),
			"web %s: bilinear, MSAA off" % p
		)
		last = s
		K.check(
			fails,
			not Q.ssao_ok(p, "gl_compatibility", true),
			"web %s: SSAO stays off below native scale" % p
		)


func _check_density() -> void:
	var caps := Q.density_caps(true)
	K.check(
		fails,
		(
			int(caps["traffic"]) == 8
			and int(caps["crowd"]) == 24
			and int(caps["animals"]) == 6
			and int(caps["rain"]) == 600
		),
		"web density: traffic 8 (was 12), crowd 24, animals 6, rain 600 (%s)" % str(caps)
	)


## Off the web nothing moves.
func _check_desktop() -> void:
	for p: String in Q.NAMES:
		var k := Q.knobs(p)
		K.check(fails, k == Q.PRESETS[p], "desktop %s: knobs are the preset's own" % p)


## A Medium or High saved by an older build (when those presets did nothing in the browser) maps to
## Low on the web until the player picks it again in this build; nothing changes off the web, for
## Low, or for a preset stamped with the current web tier version.
func _check_migration() -> void:
	var cur := FpMode.WEB_TIER_VERSION
	var old_med := {"quality": "medium"}
	var old_high := {"quality": "high", "quality_web_v": 0}
	var picked := {"quality": "high", "quality_web_v": cur}
	K.check(fails, FpMode.web_quality_migrates(old_med, true), "web: an old saved Medium migrates")
	K.check(fails, FpMode.web_quality_migrates(old_high, true), "web: an old saved High migrates")
	K.check(fails, not FpMode.web_quality_migrates(picked, true), "web: a pick made here stays")
	K.check(fails, not FpMode.web_quality_migrates({"quality": "low"}, true), "web: Low stays")
	K.check(fails, not FpMode.web_quality_migrates({}, true), "web: no saved preset, nothing to do")
	K.check(fails, not FpMode.web_quality_migrates(old_high, false), "desktop: nothing migrates")
	# A scratch file: the player's own settings are never read or written here.
	var path := "user://fp_quality_tiers_test_settings.json"
	# [saved file, web, quality that loads, auto-low]
	var cases := [
		[old_med, true, "low", true],
		[picked, true, "high", false],
		[old_med, false, "medium", false],
	]
	for case: Array in cases:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(case[0]))
		f.close()
		var mode := FpMode.new()
		mode.force_web = bool(case[1])
		mode.settings_path = path
		var s: Dictionary = mode.call("_load_settings")
		K.check(
			fails,
			str(s["quality"]) == str(case[2]) and mode.auto_low_quality == bool(case[3]),
			(
				"loading %s (web %s): quality %s, auto-low %s"
				% [JSON.stringify(case[0]), mode.force_web, s["quality"], mode.auto_low_quality]
			)
		)
		mode.free()
	# A pick made in this build is stamped, so the next load keeps it.
	var picker := FpMode.new()
	picker.settings_path = path
	picker.ctx = FpContext.new()
	picker.ctx.settings = FpMode.DEFAULT_SETTINGS.duplicate(true)
	picker.apply_settings({"quality": "medium"}, true)
	K.check(
		fails,
		int(picker.ctx.settings["quality_web_v"]) == FpMode.WEB_TIER_VERSION,
		"choosing a preset stamps the web tier version"
	)
	picker.free()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## The Quality row states the web cost in the browser build and keeps its plain label elsewhere.
func _check_label() -> void:
	K.check(
		fails,
		PM.row_label("quality", "Quality", true) == PM.WEB_QUALITY_LABEL,
		"web: the Quality row states what Medium and High cost"
	)
	K.check(
		fails,
		"cost" in PM.WEB_QUALITY_LABEL and PM.WEB_QUALITY_LABEL.length() <= 36,
		"the label names the cost and stays short (%s)" % PM.WEB_QUALITY_LABEL
	)
	K.check(
		fails,
		(
			PM.row_label("quality", "Quality", false) == "Quality"
			and PM.row_label("fov", "Field of view", true) == "Field of view"
		),
		"desktop and other rows keep their label"
	)
