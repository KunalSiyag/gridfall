extends SceneTree
## The fp_kit watchdog's self-test: arm it with a tiny budget and autokill off, never call
## K.finish until the watchdog has provably fired -- proving a dead test coroutine (a script
## error mid-await) can no longer idle the engine forever; the watchdog prints the FAIL line
## and quits 1 on its own. autokill=false lets this run observe the fire and still exit clean
## (its log line reads "watchdog fired (self-test)", not the FAIL wording).

const K := preload("res://tools/tests/fp_kit.gd")


func _init() -> void:
	var fails: Array[String] = []
	K.watchdog(self, "FP_WATCHDOG_TEST", 0.2, false)
	var t0 := Time.get_ticks_msec()
	while not K.watchdog_fired() and Time.get_ticks_msec() - t0 < 5000:
		await process_frame
	K.check(fails, K.watchdog_fired(), "the watchdog fires within budget when finish never runs")
	# A re-armed watchdog stays quiet once finish disarms it: finish must not trip it.
	K.finish(self, "FP_WATCHDOG_TEST", fails)
