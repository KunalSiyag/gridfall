extends SceneTree
## The web quality tier's density contract (flag web_quality): Quality.density_caps() is the
## single read point for the traffic, crowd and animal owners — empty off the web (no cap,
## current budgets), the WEB_DENSITY numbers on it, single values overridable from
## GRIDFALL_WEB_CAPS for profiling bisects.

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
	if _fail == 0:
		print("FP_WEBCAPS_TEST: PASS")
		quit(0)
	else:
		print("FP_WEBCAPS_TEST: FAIL (", _fail, ")")
		quit(1)
