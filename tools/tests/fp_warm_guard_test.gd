extends SceneTree
## CityView._warm_one falls back to a blocking main-thread load when threaded loading is
## unavailable (headless, or a web build without thread support) and must report that once per
## path — the 65-100 ms first-of-kind load is the street-level pop-in spike, and a silent
## fallback is how it shipped unnoticed. Headless always takes the fallback, so this suite
## checks the bookkeeping: every warmed path is recorded exactly once, repeats are free.

var _fail := 0


func _check(ok: bool, name: String) -> void:
	if ok:
		print("PASS ", name)
	else:
		_fail += 1
		print("FAIL ", name)


func _initialize() -> void:
	var view := CityView.new()
	root.add_child(view)
	var a := "res://models/real/props/bench_park.glb"
	var b := "res://models/real/props/bollard.glb"
	_check((view as CityView)._warm_one(a), "warm_one loads synchronously headless")
	_check((view as CityView)._sync_load_reported.has(a), "fallback recorded the path")
	_check((view as CityView)._warm_one(a), "second warm of the same path is a cache hit")
	_check((view as CityView)._sync_load_reported.size() == 1, "the repeat was not reported twice")
	(view as CityView)._report_sync_load(a)
	_check(
		(view as CityView)._sync_load_reported.size() == 1, "report_sync_load dedupes a known path"
	)
	_check((view as CityView)._warm_one(b), "a second kind still warms")
	_check(
		(view as CityView)._sync_load_reported.size() == 2,
		"the second kind is reported once of its own"
	)
	view.free()
	if _fail == 0:
		print("FP_WARM_GUARD_TEST: PASS")
		quit(0)
	else:
		print("FP_WARM_GUARD_TEST: FAIL (", _fail, ")")
		quit(1)
