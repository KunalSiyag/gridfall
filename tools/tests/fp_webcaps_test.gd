extends SceneTree
## The web quality tier (flag web_quality): Quality.density_caps() is the single read point
## for the traffic, crowd and animal owners — empty off the web (no cap, current budgets), the
## WEB_DENSITY numbers on it, single values overridable from GRIDFALL_WEB_CAPS for profiling
## bisects — and the WEB render-knob overlay rides knobs() so every feature picks it up. Also the
## SSAO rule that goes with the tier's 3D scale: Compatibility's SSAO prints rows of dark horizontal
## lines below native size, so Quality.ssao_ok says off there (render_opt applies it). And the
## rain emitter's web cap: Weather.rain_count holds every preset's streak count to the "rain"
## ceiling in the web tier (the emitter's desktop counts stand elsewhere), never below one streak,
## and the emitter Weather.setup builds starts at that count.

const Q := preload("res://scripts/fp/render/quality.gd")
const WEATHER := preload("res://scripts/fp/street/weather.gd")

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
			int(caps.get("traffic", -1)) == 8
			and int(caps.get("crowd", -1)) == 24
			and int(caps.get("animals", -1)) == 6
			and int(caps.get("rain", -1)) == 600
			and caps.size() == 4
		),
		"web tier: caps for traffic, crowd, animals and rain (%s)" % str(caps)
	)
	OS.set_environment("GRIDFALL_WEB_CAPS", "traffic=5,bogus=99")
	var tuned := Q.density_caps(true)
	OS.set_environment("GRIDFALL_WEB_CAPS", "")
	_check(
		(
			int(tuned.get("traffic", -1)) == 5
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
	_check_ssao()
	_check_rain()
	if _fail == 0:
		print("FP_WEBCAPS_TEST: PASS")
		quit(0)
	else:
		print("FP_WEBCAPS_TEST: FAIL (", _fail, ")")
		quit(1)


## Q.ssao_ok: off on Compatibility whenever the preset renders scaled (the web tier at every preset,
## desktop Compatibility Low), on at native size and on Forward+. render_opt applies it to the
## Environment with the scale (fp_ssao_test).
func _check_ssao() -> void:
	var fwd := true
	var web_off := true
	for p: String in Q.NAMES:
		fwd = fwd and Q.ssao_ok(p, "forward_plus") and Q.ssao_ok(p, "forward_plus", true)
		web_off = web_off and not Q.ssao_ok(p, "gl_compatibility", true)
	_check(fwd, "Forward+: SSAO stays on at every preset, web tier or not")
	_check(web_off, "Compatibility web tier: SSAO off at every preset (3D scale 0.6)")
	_check(
		not Q.ssao_ok("low", "gl_compatibility") and Q.ssao_ok("medium", "gl_compatibility"),
		"Compatibility desktop: Low (0.77) off, Medium (native, MSAA) on"
	)


## Weather.rain_count: the desktop counts (800 / 1600 / 3000) stand off the web; in the web tier no
## preset draws more streaks than the "rain" ceiling, so a higher preset adds no lines there, and
## the ceiling never raises a preset's own count. GRIDFALL_WEB_CAPS="rain=n" moves it for bisects.
func _check_rain() -> void:
	var cap := int(Q.WEB_DENSITY["rain"])
	_check(
		(
			WEATHER.rain_count("low") == 800
			and WEATHER.rain_count("medium") == 1600
			and WEATHER.rain_count("high") == 3000
		),
		"off the web: the rain keeps 800 / 1600 / 3000 streaks"
	)
	var held := true
	var same := true
	for p: String in Q.NAMES:
		var n := WEATHER.rain_count(p, true)
		held = held and n == mini(int(WEATHER.RAIN_AMOUNT[p]), cap)
		same = same and n == WEATHER.rain_count("high", true)
	_check(held, "web tier: each preset's streaks are held to the rain cap (%d)" % cap)
	_check(same, "web tier: Low, Medium and High draw the same streak count")
	OS.set_environment("GRIDFALL_WEB_CAPS", "rain=120")
	var low_cap := WEATHER.rain_count("high", true)
	OS.set_environment("GRIDFALL_WEB_CAPS", "rain=99999")
	var high_cap := [WEATHER.rain_count("low", true), WEATHER.rain_count("high", true)]
	OS.set_environment("GRIDFALL_WEB_CAPS", "")
	_check(
		low_cap == 120 and high_cap == [800, 3000],
		(
			"GRIDFALL_WEB_CAPS rain=n moves the ceiling, which never raises a preset (%d, %s)"
			% [low_cap, str(high_cap)]
		)
	)
	# An emitter takes no fewer than one particle (it errors and keeps its old count), so a cap
	# of 0, a negative one or one that is no number leaves a single streak.
	var floors: Array[int] = []
	for bad: String in ["rain=0", "rain=-5", "rain=junk"]:
		OS.set_environment("GRIDFALL_WEB_CAPS", bad)
		floors.append(WEATHER.rain_count("high", true))
	OS.set_environment("GRIDFALL_WEB_CAPS", "")
	_check(
		floors == [1, 1, 1],
		"GRIDFALL_WEB_CAPS rain=0, -5, junk leave one streak (%s)" % str(floors)
	)
	_check_rain_setup(cap)


## The emitter Weather.setup builds is counted by the same rule, so a game that boots in the web
## tier never draws a preset's own count (set_rain_amount only runs when the preset changes).
## force_web before setup() stands for the browser build there; no context is needed to set up.
func _check_rain_setup(cap: int) -> void:
	var web_ok := true
	var desktop_ok := true
	var seen: Array[int] = []
	for p: String in Q.NAMES:
		var web_weather := WEATHER.new()
		web_weather.force_web = true
		web_weather.setup(null, p)
		var desktop_weather := WEATHER.new()
		desktop_weather.setup(null, p)
		seen.append(web_weather.rain.amount)
		web_ok = web_ok and web_weather.rain.amount == mini(int(WEATHER.RAIN_AMOUNT[p]), cap)
		desktop_ok = desktop_ok and desktop_weather.rain.amount == int(WEATHER.RAIN_AMOUNT[p])
		web_weather.free()
		desktop_weather.free()
	_check(web_ok, "web tier: the emitter set up at each preset starts at the cap (%s)" % str(seen))
	_check(desktop_ok, "off the web: the emitter set up at each preset starts at its own count")
