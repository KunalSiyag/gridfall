extends SceneTree
## Coming back to a tab that was hidden, and the boundaries of a session. A browser tab hidden for
## minutes hands the first frame after it the whole gap as its delta: Pacing.frame_dt bounds what
## the world integrates (flag frame_dt_clamp), and a TrafficFeature._process(600.0) at speed 8
## moves no car further than one clamped second of game time allows; ResumeGuard reports the tab
## going to the background once and Main autosaves then (the morning autosave's gap applies, quit
## and manual saves always go through); and a New City starts with none of the last city's live
## answers and zero counters. Headless, offline; the real Main is booted once for the last part.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const DT := 1.0 / 30.0
const SAVE := "user://resume_test_save.json"
## The fastest thing on the road in metres per second: the emergency speed with the personal
## factor's headroom.
const TOP_MPS := 19.4 * 1.6

var fails: Array[String] = []
var _now: int = 0


func _init() -> void:
	K.watchdog(self, "FP_RESUME_TEST", 420.0)
	await process_frame
	_check_frame_dt()
	_check_guard()
	await _check_traffic()
	await _check_main()
	K.finish(self, "FP_RESUME_TEST", fails)


func _check_frame_dt() -> void:
	K.check(
		fails,
		Pacing.frame_dt(0.016) == 0.016 and Pacing.frame_dt(1.0) == 1.0,
		"frame_dt: a normal frame and a 1 s frame pass through"
	)
	K.check(
		fails,
		Pacing.frame_dt(5.0) == Pacing.MAX_FRAME_DT and Pacing.frame_dt(600.0) == 1.0,
		"frame_dt: a longer frame is cut to 1 s (a tab hidden for ten minutes)"
	)
	K.check(
		fails,
		Pacing.frame_dt(-3.0) == 0.0 and Pacing.frame_dt(0.0) == 0.0,
		"frame_dt: no negative time"
	)
	FeatureFlags.set_override("frame_dt_clamp", false)
	K.check(fails, Pacing.frame_dt(600.0) == 600.0, "flag off: the raw delta, as before")
	FeatureFlags.set_override("frame_dt_clamp", true)
	K.check(
		fails,
		FeatureFlags.enabled("frame_dt_clamp") and FeatureFlags.enabled("visibility_autosave"),
		"both flags default on"
	)


func _check_guard() -> void:
	var g := ResumeGuard.new()
	get_root().add_child(g)
	var events: Array[String] = []
	g.hidden.connect(func() -> void: events.append("hidden"))
	g.shown.connect(func() -> void: events.append("shown"))
	g.on_visibility("visible", 10000)
	K.check(
		fails,
		events.is_empty() and not g.is_hidden,
		"a tab that is visible and stays so says nothing"
	)
	g.on_visibility("hidden", 20000)
	g.on_visibility("hidden", 20100)
	K.check(
		fails, events == ["hidden"] and g.is_hidden, "going to the background is announced once"
	)
	g.on_visibility("visible", 20500)
	K.check(fails, events == ["hidden", "shown"] and not g.is_hidden, "coming back is announced")
	g.on_visibility("hidden", 21000)
	K.check(
		fails,
		events == ["hidden", "shown"],
		(
			"a flicker (hidden again within %d ms of the last) is not announced"
			% ResumeGuard.MIN_REPEAT_MS
		)
	)
	g.on_visibility("visible", 21100)
	g.on_visibility("hidden", 60000)
	K.check(fails, events == ["hidden", "shown", "hidden"], "a later background is announced again")
	g.queue_free()


## Cars of the street: the ones that exist, their places, and what one frame of 600 s does, with
## the clamp off (the old behaviour: cars are carried far along their lanes) and on.
func _check_traffic() -> void:
	var existing := get_root().get_children()
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true})
	var f: Node = K.make_feature(ctx, "traffic")
	K.check(
		fails, f.get("auto_step") == true, "fixture: the traffic feature steps itself from _process"
	)
	var vh: VH = f.get("vehicles")
	var budget := Pacing.MAX_FRAME_DT * 8.0 * TOP_MPS * WS.M
	ctx.sim.set_speed(8)
	_settle(f)
	var before := _places(vh)
	K.check(fails, before.size() >= 8, "fixture: %d cars on the street" % before.size())
	FeatureFlags.set_override("frame_dt_clamp", false)
	f._process(600.0)
	FeatureFlags.set_override("frame_dt_clamp", true)
	var raw := _worst_move(vh, before)
	var gone := before.size() - int(raw["seen"])
	K.check(
		fails,
		gone * 4 >= before.size() * 3 or float(raw["dist"]) > budget * 4.0,
		(
			(
				"fixture: without the clamp the same frame works off minutes of driving: "
				+ "%d of %d cars are gone (the rest moved up to %.0f m, budget %.0f m)"
			)
			% [gone, before.size(), float(raw["dist"]) / WS.M, budget / WS.M]
		)
	)
	_settle(f)
	before = _places(vh)
	f._process(600.0)
	var worst := _worst_move(vh, before)
	var seen := int(worst["seen"])
	K.check(
		fails,
		seen * 2 >= before.size(),
		(
			"with the clamp most cars are still on the street after the frame (%d of %d)"
			% [seen, before.size()]
		)
	)
	K.check(
		fails,
		float(worst["dist"]) <= budget,
		(
			(
				"one frame of 600 s at speed 8 moves no car further than %.1f m (the lane budget): "
				+ "the worst moved %.1f m"
			)
			% [budget / WS.M, float(worst["dist"]) / WS.M]
		)
	)
	# The next ordinary frames go on from there.
	var after := _places(vh)
	for _k in range(30):
		f._process(DT)
	var calm := _worst_move(vh, after)
	K.check(
		fails,
		float(calm["dist"]) <= TOP_MPS * 8.0 * 1.2 * WS.M,
		"and 30 ordinary frames after it are ordinary (%.1f m)" % (float(calm["dist"]) / WS.M)
	)
	print(
		(
			(
				"FP_RESUME: one 600 s frame at speed 8: with the clamp the worst car moved %.1f m "
				+ "(budget %.1f m), %d of %d cars still there; without it %d of them were gone"
			)
			% [float(worst["dist"]) / WS.M, budget / WS.M, seen, before.size(), gone]
		)
	)
	# Take the fixture's world down before Main boots its own (two worlds poll each other's
	# features).
	ctx.sim.set_speed(0)
	for n: Node in get_root().get_children():
		if not existing.has(n):
			n.queue_free()
	await process_frame
	await process_frame


## 40 s of street time in game steps: the ambient cars spawn and get going.
func _settle(f: Node) -> void:
	for _k in range(int(40.0 / DT)):
		f.step(DT)


func _places(vh: VH) -> Dictionary:
	var out := {}
	for c: VH.Car in vh.cars:
		if not c.parked and not c.dead:
			out[c.id] = c.pos
	return out


## The furthest any car still on the street from `before` has moved, and how many were found.
func _worst_move(vh: VH, before: Dictionary) -> Dictionary:
	var worst := 0.0
	var seen := 0
	for c: VH.Car in vh.cars:
		if c.dead or not before.has(c.id):
			continue
		seen += 1
		worst = maxf(worst, (c.pos - (before[c.id] as Vector3)).length())
	return {"dist": worst, "seen": seen}


# ------------------------------------------------------------------ the real Main


func _frames(n: int) -> void:
	for _k in range(n):
		await process_frame


func _check_main() -> void:
	OS.set_environment("GRIDFALL_VIEW", "fp")
	OS.set_environment("GRIDFALL_OFFLINE", "1")
	OS.set_environment("GRIDFALL_NEW_CITY", "1")
	change_scene_to_packed(load("res://scenes/main.tscn") as PackedScene)
	await _frames(8)
	var main: Node = current_scene
	K.check(
		fails,
		main != null and main.get("autosave_enabled") == true,
		"fixture: a player's launch boots with autosave"
	)
	main.sim.set_speed(0)
	var client: GmiClient = main.client
	K.check(
		fails,
		client.preflight.enabled and client.preflight.report.is_empty(),
		(
			"the game switches the readiness check on "
			+ "(and under the offline switch it asks for nothing)"
		)
	)
	main.autosave_path = SAVE
	main.autosave_clock = func() -> int: return _now
	main.set("_last_autosave_ms", -1)
	_now = 100000
	K.check(
		fails,
		main.autosave("hidden"),
		"a tab sent to the background saves when there has been no save yet"
	)
	K.check(fails, FileAccess.file_exists(SAVE), "and the save is there")
	_now += 30000
	K.check(
		fails,
		not main.autosave("hidden"),
		"a second background 30 s later is inside the gap and skipped"
	)
	K.check(fails, main.autosave("quit"), "a quit autosave goes through inside the gap")
	_now += 61000
	K.check(fails, main.autosave("hidden"), "a background after the gap saves again")
	FeatureFlags.set_override("autosave_gap", false)
	_now += 1000
	K.check(fails, main.autosave("hidden"), "autosave_gap off: every background saves")
	FeatureFlags.set_override("autosave_gap", true)
	# The wiring: the guard Main builds for the browser saves on `hidden`.
	K.check(fails, main._watch_tab_visibility(false) == null, "off the web there is no guard")
	FeatureFlags.set_override("visibility_autosave", false)
	K.check(
		fails,
		main._watch_tab_visibility(true) == null,
		"visibility_autosave off: no guard in the browser either"
	)
	FeatureFlags.set_override("visibility_autosave", true)
	var guard: ResumeGuard = main._watch_tab_visibility(true)
	K.check(
		fails, guard != null and guard.get_parent() == main, "in the browser Main watches the tab"
	)
	_now += 61000
	guard.on_visibility("hidden", 500000)
	K.check(
		fails,
		int(main.get("_last_autosave_ms")) == _now,
		"the tab going to the background autosaves through Main"
	)
	var stamp := int(main.get("_last_autosave_ms"))
	_now += 5000
	guard.on_visibility("visible", 600000)
	guard.on_visibility("hidden", 700000)
	K.check(
		fails,
		int(main.get("_last_autosave_ms")) == stamp,
		"and a second background inside the gap does not save again"
	)
	# A New City: none of the last city's answers, zero counters.
	client.session_cache = {
		"mayor|argon": [{"day": 1, "data": {"thought": "the old city's own turn"}}]
	}
	client.stats["live_ok"] = 9
	client.stats["retries"] = 3
	main.new_game()
	var zero := true
	for k: String in client.stats:
		zero = zero and (int(client.stats[k]) == 0 or k == "in_flight")
	K.check(
		fails,
		client.session_cache.is_empty() and zero,
		"a New City clears the session cache and zeroes the counters"
	)
	K.check(
		fails,
		client.lookup("mayor|argon", 1).get("thought", "") != "the old city's own turn",
		"and its mayors do not replay the old city's turn"
	)
	for path: String in [SAVE, SAVE + ".bak", SAVE + ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
