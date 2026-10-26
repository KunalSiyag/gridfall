extends SceneTree
## Web-build support. scripts/ops/web_support.gd answers the thread questions (desktop: plain yes;
## GRIDFALL_NO_THREADS=1 forces the no-threads web build's answers so the fallbacks can be tested
## here): scene_loads.gd and poster_worker.gd then run on the calling thread, and the player GMI
## key (GmiClient.set_player_key) reaches the client, is masked by the redactor, keeps offline
## switches winning, and the GMI Cloud panel applies and forgets it. The pause menu offers the
## page only with the player_gmi_key flag.

const K := preload("res://tools/tests/fp_kit.gd")
const LOADS := preload("res://scripts/fp/scene_loads.gd")
const WORKER := preload("res://scripts/fp/posters/poster_worker.gd")
const PAUSE := preload("res://scripts/fp/ui/pause_menu.gd")

const TEST_KEY := "gmi_webtest_0123456789abcdef"
const PANEL_KEY := "gmi_webpanel_0123456789abcdef"

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_threads()
	_check_store()
	_check_scene_loads()
	_check_poster_worker()
	_check_player_key()
	_check_panel()
	_check_pause_tab()
	K.finish(self, "WEB_TEST", fails)


func _check_threads() -> void:
	OS.unset_environment("GRIDFALL_NO_THREADS")
	K.check(fails, WebSupport.threads_supported(), "desktop: threads supported")
	OS.set_environment("GRIDFALL_NO_THREADS", "1")
	K.check(fails, not WebSupport.threads_supported(), "GRIDFALL_NO_THREADS=1: no threads")
	K.check(fails, not WebSupport.is_web(), "desktop: not the web build")
	OS.unset_environment("GRIDFALL_NO_THREADS")
	K.check(fails, WebSupport.threads_supported(), "the switch restores threads")


func _check_store() -> void:
	WebSupport.store_set("gridfall.test", "abc")
	K.check(fails, WebSupport.store_get("gridfall.test") == "", "desktop: the store stays empty")
	WebSupport.store_erase("gridfall.test")


func _check_scene_loads() -> void:
	var loads := LOADS.new()
	var path := "res://scenes/main.tscn"
	OS.set_environment("GRIDFALL_NO_THREADS", "1")
	loads.request(path)
	K.check(fails, not loads.pending(path), "no threads: a requested scene is not in flight")
	var ps := loads.scene(path, false)
	K.check(
		fails,
		ps is PackedScene and not loads.pending(path),
		"no threads: the scene loads on the caller's thread"
	)
	OS.unset_environment("GRIDFALL_NO_THREADS")
	var loads2 := LOADS.new()
	loads2.request(path)
	K.check(fails, loads2.scene(path, true) is PackedScene, "threads: the threaded path loads")
	loads2.finish()


func _check_poster_worker() -> void:
	var data := PackedByteArray()
	data.resize(8 * 8 * 4)
	data.fill(128)
	var input := {"id": "test", "data": data, "px": Vector2i(8, 8)}
	OS.set_environment("GRIDFALL_NO_THREADS", "1")
	var worker := WORKER.new()
	worker.push(Callable(WORKER, "finish_image"), input)
	var done := worker.take_done()
	K.check(
		fails,
		done.size() == 1 and bool(done[0].get("ok", false)) and worker.pending() == 0,
		"no threads: a poster job runs at once on the calling thread"
	)
	worker.stop()
	OS.unset_environment("GRIDFALL_NO_THREADS")


func _check_player_key() -> void:
	# Hermetic: the gate exports GRIDFALL_OFFLINE=1 for every test run; a bare run sets it here
	# so the offline-wins check does not depend on how the test was started.
	OS.set_environment("GRIDFALL_OFFLINE", "1")
	var client := GmiClient.new()
	var boot_key := client.call("_resolve_api_key") as String
	client.set_player_key(TEST_KEY)
	K.check(
		fails, client.has_key() and client.api_key == TEST_KEY, "set_player_key puts the key in use"
	)
	K.check(fails, client.player_key == TEST_KEY, "and remembers it as the player's key")
	var scrubbed := Redact.scrub("Authorization: Bearer %s plain %s" % [TEST_KEY, TEST_KEY])
	K.check(
		fails,
		not scrubbed.contains(TEST_KEY) and scrubbed.contains("[REDACTED]"),
		"the key never survives the redactor"
	)
	K.check(fails, not client.live_enabled, "a key does not turn live on while GRIDFALL_OFFLINE=1")
	client.remember_player_key(TEST_KEY)
	K.check(fails, not client.has_remembered_key(), "desktop: nothing is remembered on the device")
	client.forget_remembered_key()
	client.set_player_key("")
	K.check(
		fails,
		client.has_key() == (not boot_key.is_empty()),
		"an empty key puts the boot key back (this machine's boot key stays untold)"
	)
	OS.unset_environment("GRIDFALL_OFFLINE")
	client.free()


func _check_panel() -> void:
	var client := GmiClient.new()
	var boot_key := client.call("_resolve_api_key") as String
	var ctx := FpContext.new()
	ctx.client = client
	var panel := GmiKeyPanel.new()
	get_root().add_child(panel)
	panel.setup(ctx)
	K.check(fails, panel.input != null and panel.status != null, "the panel builds")
	K.check(fails, not panel.status.text.is_empty(), "the status line says how the mayors run")
	panel.input.text = PANEL_KEY
	panel.apply_key()
	K.check(
		fails,
		client.has_key() and client.api_key == PANEL_KEY,
		"Apply routes the key to the client"
	)
	K.check(
		fails, panel.status.text.contains("Key in use"), "the status line reports the key in use"
	)
	panel.forget_key()
	K.check(
		fails,
		client.has_key() == (not boot_key.is_empty()) and panel.input.text.is_empty(),
		"Forget drops the player's key (the boot key, if this machine has one, returns)"
	)
	panel.free()
	client.free()


func _check_pause_tab() -> void:
	var client := GmiClient.new()
	var ctx := FpContext.new()
	ctx.client = client
	FeatureFlags.set_override("player_gmi_key", true)
	var menu := PAUSE.new()
	get_root().add_child(menu)
	menu.setup(ctx, null)
	K.check(
		fails,
		menu._tabs.has(menu.GMI_TAB),
		"the settings offer the GMI Cloud page with the flag on"
	)
	menu.call("_show_tab", menu.GMI_TAB)
	K.check(
		fails,
		(menu._tabs[menu.GMI_TAB] as Control).visible,
		"the GMI Cloud page shows when its tab is picked"
	)
	FeatureFlags.set_override("player_gmi_key", false)
	var menu2 := PAUSE.new()
	get_root().add_child(menu2)
	menu2.setup(ctx, null)
	K.check(fails, not menu2._tabs.has(menu2.GMI_TAB), "flag off: the page is not offered")
	FeatureFlags.set_override("player_gmi_key", true)
	menu.free()
	menu2.free()
	client.free()
