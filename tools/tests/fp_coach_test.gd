extends SceneTree
## The coach card (feature "coach_card", scripts/fp/coach): the first minute's guidance.
## - a fresh city's welcome is a bottom-centre key-cap card, up 15 real seconds or until J, Tab or
##   E (or another first action), never again once settings coach_seen is saved (and the setting
##   survives FpMode's settings loader, which drops unknown keys);
## - the "Click to look around" pill follows a pure function of mouse mode, pause, modal and
##   headless, and never shows in a headless or scripted run;
## - the ladder (first AI decision, first resident within 3 m, 60 s without input at 1x, first
##   Tab) shows each hint at most once, across sessions, one at a time and never over the card;
## - none of it carries a model name;
## - the real Main, with the feature off, still greets a fresh city with the old one-line toast.
## Prints FP_COACH_TEST: PASS|FAIL. Boots Main: run with a throwaway XDG_DATA_HOME (the gate does);
## it saves and restores the settings file it touches.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const L := preload("res://scripts/fp/coach/coach_logic.gd")
const TOKEN := "FP_COACH_TEST"

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 300.0)
	await process_frame
	check(FeatureFlags.enabled("coach_card"), "the flag coach_card is on by default")
	_check_pure()
	var ctx := K.make_ctx(get_root(), {"hud": true})
	ctx.sim.set_process(false)
	ctx.sim.set_speed(1)
	var f := K.make_feature(ctx, "coach_card")
	check(f != null and f.feature_id() == "coach_card", "the feature sets up under the registry id")
	await _frames(2)
	_check_idle_world(ctx, f)
	await _check_card(ctx, f)
	_check_dismissals(ctx, f)
	_check_seen(ctx, f)
	f.call("teardown")
	f.free()
	ctx.features.erase("coach_card")
	_check_ladder(ctx)
	_check_tool_run(ctx)
	_check_settings_file()
	_check_auto_low_kept()
	await _check_main_toast()
	K.finish(self, TOKEN, fails)


func _frames(n: int) -> void:
	for _k in range(n):
		await process_frame


func _action(f: FpFeature, a: String) -> void:
	var ev := InputEventAction.new()
	ev.action = a
	ev.pressed = true
	f.call("_input", ev)


func _fresh(ctx: FpContext) -> void:
	ctx.settings["coach_seen"] = false
	ctx.settings["coach_hints"] = ""


func _spend(f: FpFeature, secs: float) -> void:
	var left := secs
	while left > 0.0:
		var dt := minf(left, 0.5)
		f.call("_process", dt)
		left -= dt


func _owned(ctx: FpContext) -> PackedStringArray:
	return S.owned_texts(ctx.hud.slot("center").get_node("Coach"))


# ------------------------------------------------------------------ pure rules


func _check_pure() -> void:
	var cap := Input.MOUSE_MODE_CAPTURED
	var vis := Input.MOUSE_MODE_VISIBLE
	check(not L.should_show_capture_hint(cap, false, false, false), "captured pointer: no pill")
	check(
		L.should_show_capture_hint(vis, false, false, false),
		"free pointer on a desktop or web build: pill"
	)
	check(
		L.should_show_capture_hint(Input.MOUSE_MODE_HIDDEN, false, false, false),
		"a hidden but uncaptured pointer: pill"
	)
	check(not L.should_show_capture_hint(vis, true, false, false), "paused: no pill")
	check(not L.should_show_capture_hint(vis, false, true, false), "a modal UI open: no pill")
	check(not L.should_show_capture_hint(vis, false, false, true), "headless: no pill")
	var line := "WASD walk - Shift run - Tab city overview - J AI feed"
	line += " - E talk - Enter chat - Esc menu"
	check(L.card_text() == line, "the card reads the seven keys (%s)" % L.card_text())
	var all := PackedStringArray([L.card_text(), L.CAPTURE_TEXT])
	for id: String in L.HINTS:
		all.append(L.hint_text(id))
	check(
		L.hint_text("feed") == "J reads it" and L.hint_text("talk") == "E to talk",
		"feed and talk hints"
	)
	check(
		(
			L.hint_text("speed") == "] speeds time up"
			and L.hint_text("tab") == "Planner view button: the full city builder"
		),
		"speed and Tab hints"
	)
	var bad := PackedStringArray()
	for t: String in all:
		if S.branded(t):
			bad.append(t)
	check(bad.is_empty(), "no model or brand words in the coach's texts %s" % str(bad))
	check(
		L.with_hint("feed,talk", "talk") == "feed,talk" and L.with_hint("", "tab") == "tab",
		"with_hint adds once"
	)
	check(
		L.shown_hints("a, b,,c") == PackedStringArray(["a", "b", "c"]),
		"shown_hints splits the saved list"
	)
	var click := InputEventMouseButton.new()
	click.pressed = true
	var move := InputEventMouseMotion.new()
	var still := InputEventMouseMotion.new()
	move.relative = Vector2(3, 0)
	var rel := InputEventKey.new()
	rel.pressed = false
	check(
		L.is_player_input(click) and L.is_player_input(move), "a click and a mouse move are input"
	)
	check(
		not L.is_player_input(still) and not L.is_player_input(rel),
		"a still motion and a key release are not"
	)
	check(
		(
			FpMode.DEFAULT_SETTINGS.has("coach_seen")
			and typeof(FpMode.DEFAULT_SETTINGS["coach_seen"]) == TYPE_BOOL
			and not bool(FpMode.DEFAULT_SETTINGS["coach_seen"])
		),
		"coach_seen is a default setting, false"
	)
	check(FpMode.DEFAULT_SETTINGS.has("coach_hints"), "and so is the ladder's list")


# ------------------------------------------------------------------ the card


func _check_idle_world(ctx: FpContext, f: FpFeature) -> void:
	_fresh(ctx)
	_spend(f, 5.0)
	check(not f.call("card_visible"), "no card until the city asks (smokes and tours never ask)")
	check(not f.call("capture_pill_visible"), "headless: no capture pill")
	check(f.call("hint_shown") == "", "and no hint")


func _check_card(ctx: FpContext, f: FpFeature) -> void:
	_fresh(ctx)
	ctx.bus.coach_requested.emit("welcome")
	await _frames(2)
	check(f.call("card_visible"), "a fresh city's welcome shows the card")
	var texts := _owned(ctx)
	var joined := " | ".join(texts)
	for w: String in [
		"WASD",
		"walk",
		"Shift",
		"run",
		"Tab",
		"city overview",
		"J",
		"AI feed",
		"E",
		"talk",
		"Enter",
		"chat",
		"Esc",
		"menu"
	]:
		check(texts.has(w), "the card names %s" % w)
	check(not joined.is_empty() and not S.branded(joined), "and nothing branded (%s)" % joined)
	f.call("_process", 0.5)
	await _frames(1)
	var box: Control = ctx.hud.slot("center").get_node("Coach")
	var card: Control = box.get_node("Card")
	var hud_rect: Rect2 = ctx.hud.slot("center").get_global_rect()
	var r := card.get_global_rect()
	check(
		card.is_visible_in_tree() and card.modulate.a > 0.0,
		"the card is on screen (alpha %.2f)" % card.modulate.a
	)
	check(
		absf((r.position.x + r.size.x * 0.5) - (hud_rect.position.x + hud_rect.size.x * 0.5)) < 2.0,
		"centred"
	)
	var gap := hud_rect.end.y - r.end.y
	check(
		gap >= 60.0 and gap <= 80.0,
		"above the overview's key bar, clear of the bottom edge (%.0f px up)" % gap
	)
	check(r.size.x <= 1040.0 and r.size.x > 300.0, "it fits the box (%.0f px wide)" % r.size.x)
	# Time: 15 real seconds, then gone for good.
	_spend(f, 13.0)
	check(f.call("card_visible"), "still up after 13.5 s")
	_spend(f, 2.0)
	check(not f.call("card_visible"), "gone after 15 s")
	check(bool(ctx.settings["coach_seen"]), "and coach_seen is set")
	await _frames(1)
	_spend(f, 1.0)
	check(not card.visible or card.modulate.a <= 0.01, "faded out")
	ctx.bus.coach_requested.emit("welcome")
	check(not f.call("card_visible"), "it never comes back once seen")


func _check_dismissals(ctx: FpContext, f: FpFeature) -> void:
	for a: String in ["ai_feed", "overview_toggle", "interact"]:
		_fresh(ctx)
		ctx.bus.coach_requested.emit("welcome")
		check(f.call("card_visible"), "(%s) the card is up" % a)
		_action(f, "time_faster")
		check(f.call("card_visible"), "(%s) an unrelated key leaves it" % a)
		_action(f, a)
		check(
			not f.call("card_visible") and bool(ctx.settings["coach_seen"]),
			"J, Tab and E dismiss it for good (%s)" % a
		)
	_fresh(ctx)
	ctx.bus.coach_requested.emit("welcome")
	ctx.bus.hero_action.emit("jab", Vector3.ZERO)
	check(not f.call("card_visible"), "acting (a hero action) dismisses it")
	_fresh(ctx)
	ctx.bus.coach_requested.emit("welcome")
	ctx.bus.interact_requested.emit({})
	check(not f.call("card_visible"), "so does interacting")
	_fresh(ctx)
	ctx.bus.coach_requested.emit("welcome")
	ctx.bus.coach_requested.emit("welcome")
	check(f.call("card_visible"), "a second request while it is up changes nothing")
	f.call("dismiss_welcome")
	ctx.bus.coach_requested.emit("not-a-topic")
	check(not f.call("card_visible"), "an unknown topic shows nothing")


func _check_seen(ctx: FpContext, f: FpFeature) -> void:
	_fresh(ctx)
	ctx.settings["coach_seen"] = true
	ctx.bus.coach_requested.emit("welcome")
	check(
		not f.call("card_visible") and not f.call("show_welcome"),
		"coach_seen: the welcome never shows"
	)
	_fresh(ctx)


# ------------------------------------------------------------------ the ladder


func _check_ladder(ctx: FpContext) -> void:
	_fresh(ctx)
	var f := K.make_feature(ctx, "coach_card")
	f.call("dismiss_welcome")
	# 1. the first AI decision.
	ctx.bus.ai_decision_shown.emit("1")
	check(
		f.call("hint_shown") == "J reads it",
		"the first AI decision: J reads it (%s)" % f.call("hint_shown")
	)
	check(
		f.call("hint_seen", "feed") and str(ctx.settings["coach_hints"]) == "feed",
		"it is remembered in the settings"
	)
	_spend(f, 7.0)
	check(f.call("hint_shown") == "", "the hint goes after a few seconds")
	ctx.bus.ai_decision_shown.emit("2")
	check(f.call("hint_shown") == "", "and never comes back")
	# 2. a resident within 3 m.
	ctx.bus.interact_target_changed.emit({"kind": "building", "dist": 1.0 * WS.M})
	ctx.bus.interact_target_changed.emit({"kind": "resident", "dist": 5.0 * WS.M})
	check(f.call("hint_shown") == "", "a building, or a resident 5 m off, earns nothing")
	ctx.bus.interact_target_changed.emit({"kind": "resident", "dist": 2.5 * WS.M})
	check(f.call("hint_shown") == "E to talk", "a resident within 3 m: E to talk")
	_spend(f, 7.0)
	ctx.bus.interact_target_changed.emit({"kind": "resident", "dist": 1.0 * WS.M})
	check(f.call("hint_shown") == "", "once only")
	# 3. a minute without input at 1x.
	ctx.sim.speed = 1
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_W
	f.call("_input", key)
	_spend(f, 50.0)
	check(f.call("hint_shown") == "", "50 s of quiet: nothing yet")
	f.call("_input", key)
	_spend(f, 50.0)
	check(f.call("hint_shown") == "", "input restarts the minute")
	ctx.sim.speed = 4
	_spend(f, 90.0)
	check(f.call("hint_shown") == "", "at 4x the speed hint stays quiet")
	ctx.sim.speed = 1
	_spend(f, 61.0)
	check(f.call("hint_shown") == "] speeds time up", "60 s without input at 1x: ] speeds time up")
	_spend(f, 7.0)
	_spend(f, 90.0)
	check(f.call("hint_shown") == "", "once only")
	# 4. the first Tab: the overview pushes its modal.
	ctx.push_modal(&"overview")
	check(
		f.call("hint_shown") == "Planner view button: the full city builder",
		"the first Tab: the Planner view button (%s)" % f.call("hint_shown")
	)
	var texts := S.owned_texts(ctx.hud.slot("center").get_node("Coach"))
	check(
		texts.has("Planner view button:") and texts.has("the full city builder"),
		"drawn as text: the overview has no Space key to advertise (%s)" % str(texts)
	)
	ctx.pop_modal(&"overview")
	_spend(f, 7.0)
	ctx.push_modal(&"overview")
	check(f.call("hint_shown") == "", "and once only")
	ctx.pop_modal(&"overview")
	check(
		str(ctx.settings["coach_hints"]) == "feed,talk,speed,tab",
		"all four are remembered (%s)" % ctx.settings["coach_hints"]
	)
	# 5. a later session: nothing shows again.
	f.call("teardown")
	f.free()
	var g := K.make_feature(ctx, "coach_card")
	ctx.bus.ai_decision_shown.emit("3")
	ctx.bus.interact_target_changed.emit({"kind": "resident", "dist": 1.0 * WS.M})
	check(g.call("hint_shown") == "", "a new session with the saved settings shows none of them")
	g.call("teardown")
	g.free()
	# 6. one at a time, and never over the card.
	_fresh(ctx)
	var h := K.make_feature(ctx, "coach_card")
	ctx.bus.coach_requested.emit("welcome")
	ctx.bus.ai_decision_shown.emit("1")
	check(
		h.call("card_visible") and h.call("hint_shown") == "", "a hint waits while the card is up"
	)
	check(not h.call("hint_seen", "feed"), "and is not used up")
	ctx.bus.interact_target_changed.emit({"kind": "resident", "dist": 1.0 * WS.M})
	_action(h, "ai_feed")
	check(not h.call("card_visible"), "J dismisses the card")
	_spend(h, 0.5)
	check(
		h.call("hint_shown") == "J reads it",
		"the waiting hint shows next (%s)" % h.call("hint_shown")
	)
	_spend(h, 7.0)
	check(h.call("hint_shown") == "E to talk", "then the next one")
	h.call("teardown")
	h.free()
	_fresh(ctx)


func _check_tool_run(ctx: FpContext) -> void:
	_fresh(ctx)
	var f := K.make_feature(ctx, "coach_card")
	f.call("dismiss_welcome")
	for k: String in ["GRIDFALL_FP_SMOKE", "GRIDFALL_FP_PHOTO_DIR"]:
		OS.set_environment(k, "1")
		check(L.tool_run(), "%s marks a tool run" % k)
		ctx.bus.ai_decision_shown.emit("1")
		check(f.call("hint_shown") == "", "no hint in a scripted run (%s)" % k)
		OS.unset_environment(k)
	check(not L.tool_run(), "and the marks are gone")
	f.call("teardown")
	f.free()
	_fresh(ctx)


# ------------------------------------------------------------------ the settings file


func _check_settings_file() -> void:
	var path := FpMode.SETTINGS_PATH
	var had := FileAccess.file_exists(path)
	var old := FileAccess.get_file_as_string(path) if had else ""
	var w := FileAccess.open(path, FileAccess.WRITE)
	w.store_string(
		JSON.stringify({"coach_seen": true, "coach_hints": "feed,tab", "not_a_setting": 1})
	)
	w.close()
	var mode := FpMode.new()
	var s: Dictionary = mode.call("_load_settings")
	mode.free()
	check(
		bool(s.get("coach_seen", false)) and str(s.get("coach_hints", "")) == "feed,tab",
		"FpMode keeps coach_seen and the hint list from the file"
	)
	check(not s.has("not_a_setting"), "while an unknown key is still dropped")
	if had:
		var r := FileAccess.open(path, FileAccess.WRITE)
		r.store_string(old)
		r.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## The coach saves its own keys (coach_seen, coach_hints) through apply_settings, which writes the
## settings file. On a card that picked the Low preset by itself that must not turn the automatic
## preset into a saved choice: the next launch would skip the GPU check and its toast for good.
func _check_auto_low_kept() -> void:
	var path := FpMode.SETTINGS_PATH
	var had := FileAccess.file_exists(path)
	var old := FileAccess.get_file_as_string(path) if had else ""
	if had:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	GpuMemory.set_override(true)
	var mode := FpMode.new()
	mode.ctx = FpContext.new()
	mode.ctx.settings = mode.call("_load_settings")
	mode.set("_set_up", true)
	check(
		mode.auto_low_quality and mode.ctx.settings["quality"] == "low",
		"fixture: a low-memory card starts on Low by itself"
	)
	mode.apply_settings({L.SEEN_KEY: true, L.HINTS_KEY: "feed"})
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(
		typeof(saved) == TYPE_DICTIONARY and bool(saved.get(L.SEEN_KEY, false)),
		"the coach's settings reach the file"
	)
	check(
		typeof(saved) == TYPE_DICTIONARY and not saved.has("quality"),
		"but the automatic Low preset is not written as a saved quality (%s)" % str(saved)
	)
	var again := FpMode.new()
	again.call("_load_settings")
	check(again.auto_low_quality, "so the next launch still decides the preset itself")
	again.free()
	check(mode.ctx.settings["quality"] == "low", "and this run stays on Low")
	mode.apply_settings({"quality": "high"})
	saved = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(
		(
			not mode.auto_low_quality
			and typeof(saved) == TYPE_DICTIONARY
			and saved.get("quality") == "high"
		),
		"a quality the player picks is saved as theirs"
	)
	GpuMemory.set_override(false)
	mode.free()
	if had:
		var r := FileAccess.open(path, FileAccess.WRITE)
		r.store_string(old)
		r.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ------------------------------------------------------------------ Main, feature off


func _check_main_toast() -> void:
	OS.set_environment("GRIDFALL_VIEW", "fp")
	OS.set_environment("GRIDFALL_OFFLINE", "1")
	OS.set_environment("GRIDFALL_NEW_CITY", "1")
	FeatureFlags.set_override("coach_card", false)
	change_scene_to_packed(load("res://scenes/main.tscn") as PackedScene)
	await _frames(8)
	var main := current_scene
	check(main != null and main.fp != null, "fixture: Main boots on foot")
	if main == null or main.fp == null:
		return
	var texts: PackedStringArray = main.fp.ctx.hud.toasts.texts()
	check(main.fp.ctx.feature("coach_card") == null, "flag off: the feature is not set up")
	check(
		" ".join(texts).contains("Welcome to GridFall"),
		"flag off: the one-line welcome toast, as before (%s)" % str(texts)
	)
	main.audio._exit_tree()
	FeatureFlags.set_override("coach_card", true)
