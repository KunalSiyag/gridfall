extends SceneTree
## CityView.building_aabb reads the holder's building_xform meta: a lot mid-rebuild can keep
## building_path while the xform is gone, and get_meta on a missing key prints an engine ERROR
## (4.7) even with a default. The guard lives in city_view.gd; the error is engine-level, so
## this suite runs the check scene in a child Godot and greps its captured output (the #60/#67
## idiom).

var _fail := 0


func _check(ok: bool, name: String) -> void:
	if ok:
		print("PASS ", name)
	else:
		_fail += 1
		print("FAIL ", name)


func _init() -> void:
	var out: Array = []
	var code := (
		OS
		. execute(
			OS.get_executable_path(),
			[
				"--headless",
				"--path",
				ProjectSettings.globalize_path("res://"),
				"-s",
				"res://tools/tests/fp_cityview_meta_check.gd",
			],
			out,
			true
		)
	)
	var log := "\n".join(PackedStringArray(out))
	_check(
		code == 0 and "FP_CITYVIEW_META_CHECK: DONE" in log,
		"building_aabb: the child run fell back on half-dressed holders (exit %d)" % code
	)
	_check(
		not "does not have any 'meta' values" in log and not "SCRIPT ERROR" in log,
		"building_aabb: a half-dressed holder prints no missing-meta engine error"
	)
	if _fail == 0:
		print("FP_CITYVIEW_META_TEST: PASS")
		quit(0)
	else:
		print("FP_CITYVIEW_META_TEST: FAIL (", _fail, ")")
		quit(1)
