extends SceneTree
## The key panel (the pause menu's GMI Cloud page) without a network: a 300-character key survives
## the field, the Test button says in plain words whether the key works (one test at a time, and a
## late answer for a key that is no longer in use is dropped), "Key saved on this device" shows only
## for a non-empty key, a typed key is saved only once a test passes, and the key never reaches a
## status. The client is a fake whose _post answers from a script (fp_keyflow_kit.gd).

const K := preload("res://tools/tests/fp_kit.gd")
const KIT := preload("res://tools/tests/fp_keyflow_kit.gd")
const PANEL := preload("res://scripts/fp/ui/gmi_key_panel.gd")

var fails: Array[String] = []


func _init() -> void:
	K.watchdog(self, "FP_KEYFLOW_PANEL_TEST")
	await process_frame
	# The gate (and a bare run) set GRIDFALL_OFFLINE=1, which refuses a key test by design. Every
	# transport here is a fake, so the switch is lifted for the run.
	var had_offline := OS.get_environment("GRIDFALL_OFFLINE")
	OS.unset_environment("GRIDFALL_OFFLINE")
	await _check_panel()
	if not had_offline.is_empty():
		OS.set_environment("GRIDFALL_OFFLINE", had_offline)
	FeatureFlags.set_override("gmi_live", true)
	K.finish(self, "FP_KEYFLOW_PANEL_TEST", fails)


func _client(key: String = "") -> KIT.FakeKeyNet:
	return KIT.client(get_root(), key)


func _make_panel(c: GmiClient) -> GmiKeyPanel:
	var ctx := FpContext.new()
	ctx.client = c
	var panel := GmiKeyPanel.new()
	get_root().add_child(panel)
	panel.setup(ctx)
	return panel


func _check_panel() -> void:
	var key := KIT.long_key()
	var c := _client()
	c.reply = {"ok": false, "error": "HTTP 401 bad key " + key, "http": 401, "service_fail": false}
	var panel := _make_panel(c)
	K.check(fails, panel.input.max_length >= 512, "the key field takes 512 characters or more")
	panel.input.insert_text_at_caret(key)
	K.check(
		fails,
		panel.input.text.length() == 300,
		"a pasted 300-character key survives the field (%d kept)" % panel.input.text.length()
	)
	panel.apply_key()
	K.check(
		fails,
		c.api_key == key and panel.status.text.contains("Key in use"),
		"Apply hands the whole key to the client"
	)
	K.check(fails, panel.test_button != null, "the page has a Test button")
	await panel.run_test()
	K.check(
		fails,
		panel.status.text == "Key rejected (401)" and not KIT.leaks(panel.status.text, key),
		"a rejected key reads 'Key rejected (401)' and never shows the key (%s)" % panel.status.text
	)
	var seconds := 0.0
	c.reply = {"ok": false, "error": "no JSON in reply", "http": 200}
	await panel.run_test()
	var rx := RegEx.create_from_string("^Key works \\(answered in \\d+\\.\\d s\\)$")
	K.check(
		fails,
		rx.search(panel.status.text) != null,
		"a working key reads 'Key works (answered in 1.1 s)' (%s)" % panel.status.text
	)
	var lines := {
		"rate_limited": "Rate limited, try again in a minute",
		"blocked": "Blocked by the browser or offline",
		"error": "Could not reach GMI",
	}
	for status: String in lines:
		var said := PANEL.test_line({"status": status, "seconds": seconds, "http": 0})
		K.check(fails, said == lines[status], "'%s' reads '%s'" % [status, lines[status]])
	K.check(
		fails,
		(
			(
				PANEL.test_line({"status": "ok", "seconds": 1.12, "http": 200})
				== "Key works (answered in 1.1 s)"
			)
			and (
				PANEL.test_line({"status": "rejected", "seconds": 0.2, "http": 403})
				== "Key rejected (403)"
			)
		),
		"the ok and rejected lines carry the seconds and the code"
	)
	c.reply = {"ok": false, "error": "network result 2", "http": 0, "result": 2}
	await panel.run_test()
	K.check(
		fails,
		panel.status.text == "Blocked by the browser or offline",
		"a network failure reads as blocked or offline (%s)" % panel.status.text
	)
	await _check_panel_busy(panel, c)
	_check_panel_saved()
	await _check_panel_typed(panel, c)
	_check_panel_words(panel)
	_check_panel_key_text(panel, c)
	await _check_panel_saving(panel, c)
	await _check_panel_stale(panel, c)
	panel.free()
	c.free()


## An answer for a key that is no longer in use says nothing: press Test on key A, apply key B (or
## Forget) while the call is out, and the late "Key works" for A must not be shown as B's status.
func _check_panel_stale(panel: GmiKeyPanel, c: KIT.FakeKeyNet) -> void:
	var key_a := "keyAAAAAAAA_0123456789"
	var key_b := "keyBBBBBBBB_0123456789"
	panel.forget_key()
	c.api_key = ""
	c.remembered.clear()
	var on := Button.new()
	on.toggle_mode = true
	on.set_meta("value", true)
	on.button_pressed = true
	panel.remember.append(on)
	c.reply = {"ok": true, "data": {"ok": 1}, "http": 200}
	c.delay_frames = 5
	c.posts = 0
	panel.input.text = key_a
	panel.run_test()
	await process_frame
	K.check(
		fails,
		panel.test_button.disabled and c.api_key == key_a and c.posts == 1,
		"setup: the test of key A is out"
	)
	panel.input.text = key_b
	panel.apply_key()
	for _i in range(12):
		await process_frame
	K.check(
		fails,
		c.api_key == key_b and not panel.test_button.disabled,
		"setup: key B was applied during the call and the Test button is back"
	)
	K.check(
		fails,
		(
			not panel.status.text.begins_with("Key works")
			and panel.status.text.begins_with("Key in use")
		),
		"the late answer for key A is not shown as 'Key works' for key B (%s)" % panel.status.text
	)
	K.check(
		fails,
		c.remembered == [key_b],
		"key A, which the answer was about, is not saved on the device (%s)" % [c.remembered]
	)
	panel.run_test()
	for _i in range(12):
		await process_frame
	K.check(
		fails,
		panel.status.text.begins_with("Key works") and c.posts == 2,
		"a Test of key B afterwards reports its own answer (%s)" % panel.status.text
	)
	# The same when the key is forgotten while the call is out.
	panel.input.text = key_a
	panel.apply_key()
	panel.run_test()
	await process_frame
	panel.forget_key()
	c.api_key = ""
	for _i in range(12):
		await process_frame
	K.check(
		fails,
		not panel.status.text.begins_with("Key works") and not panel.test_button.disabled,
		"Forget during a test: the late answer is not shown as 'Key works' (%s)" % panel.status.text
	)
	# The same key applied again while it is tested is still the key tested: its answer shows.
	panel.input.text = key_a
	panel.run_test()
	await process_frame
	panel.apply_key()
	for _i in range(12):
		await process_frame
	K.check(
		fails,
		panel.status.text.begins_with("Key works"),
		"applying the very key under test again does not hide its answer (%s)" % panel.status.text
	)
	c.delay_frames = 0
	panel.remember.erase(on)
	on.free()
	panel.forget_key()
	c.api_key = ""


## One test at a time: while a call is out the button is off and a second press adds no call.
func _check_panel_busy(panel: GmiKeyPanel, c: KIT.FakeKeyNet) -> void:
	c.reply = {"ok": true, "data": {"ok": 1}, "http": 200}
	c.delay_frames = 3
	c.posts = 0
	panel.run_test()
	K.check(
		fails,
		panel.test_button.disabled and panel.status.text.begins_with("Testing"),
		"while the call is out the Test button is off and the line says so"
	)
	panel.run_test()
	for _i in range(8):
		await process_frame
	K.check(
		fails,
		(
			c.posts == 1
			and not panel.test_button.disabled
			and panel.status.text.begins_with("Key works")
		),
		"a second press during a test sends nothing; the button comes back with the answer"
	)
	c.delay_frames = 0


func _check_panel_saved() -> void:
	var on := PANEL.status_line(true, true, true)
	var off := PANEL.status_line(true, true, false)
	var none := PANEL.status_line(false, false, true)
	K.check(
		fails,
		on.contains("Key saved on this device") and not off.contains("saved on this device"),
		"'Key saved on this device' shows when a key is in use and kept on the device only"
	)
	K.check(
		fails,
		not none.contains("saved") and none.begins_with("No key"),
		"and never for an empty key (%s)" % none
	)
	K.check(
		fails,
		(
			on.begins_with("Key in use. Live mayors: on.")
			and PANEL.status_line(true, false, false).contains("off")
		),
		"the live state still reads as before"
	)


## The pasted key is tidied and checked before it is used, and the status never says "saved" for a
## key other than the one in use.
func _check_panel_key_text(panel: GmiKeyPanel, c: KIT.FakeKeyNet) -> void:
	K.check(
		fails,
		(
			PANEL.tidy_key("\u00a0 gmi_abc123\u200b \n") == "gmi_abc123"
			and PANEL.tidy_key("  gmi_abc123\r\n") == "gmi_abc123"
			and PANEL.tidy_key("\u00a0\ufeff") == ""
			and PANEL.tidy_key("gmi_a b") == "gmi_a b"
		),
		"tidy_key drops spaces, no-break spaces, zero-width marks and a BOM at the ends only"
	)
	K.check(
		fails,
		(
			PANEL.key_problem("gmi_abc-123.XYZ_~").is_empty()
			and not PANEL.key_problem("gmi_a b").is_empty()
			and not PANEL.key_problem("gmi_a\nb").is_empty()
			and not PANEL.key_problem("gmi_a\u200bb").is_empty()
			and not PANEL.key_problem("gmi_ä").is_empty()
		),
		"key_problem takes printable ASCII, refuses a space, newline or non-ASCII character"
	)
	panel.forget_key()
	c.api_key = ""
	c.posts = 0
	panel.input.text = "gmi_with space_0123456789"
	panel.apply_key()
	K.check(
		fails,
		(
			not c.has_key()
			and panel.status.text.contains("space or an odd character")
			and not panel.status.text.contains("0123456789")
		),
		(
			"Apply refuses a key with a space inside and says so without echoing it (%s)"
			% panel.status.text
		)
	)
	panel.input.text = "gmi_zero\u200bwidth_0123456789"
	await panel.run_test()
	K.check(
		fails,
		c.posts == 0 and not c.has_key() and panel.status.text.contains("odd character"),
		"Test refuses it too and sends nothing"
	)
	panel.input.text = "\u00a0gmi_nbsp_0123456789\u00a0"
	panel.apply_key()
	K.check(
		fails,
		c.api_key == "gmi_nbsp_0123456789",
		"a key wrapped in no-break spaces is put in use without them"
	)
	c.saved = "gmi_other_saved_9876543210"
	panel.refresh()
	K.check(
		fails,
		(
			panel.status.text.contains("A different key is saved")
			and not panel.status.text.contains("Key saved on this device")
		),
		"a saved copy of another key is not reported as this key's copy (%s)" % panel.status.text
	)
	c.saved = c.api_key
	panel.refresh()
	K.check(
		fails,
		panel.status.text.contains("Key saved on this device"),
		"the saved copy of the key in use reads 'Key saved on this device'"
	)
	c.saved = ""
	panel.forget_key()
	K.check(
		fails,
		PANEL.status_line(true, true, false, true).ends_with(
			"A different key is saved on this device."
		),
		"status_line names a saved copy of another key"
	)


## A key typed but not applied yet is applied by Test; an empty field with no key says so.
func _check_panel_typed(panel: GmiKeyPanel, c: KIT.FakeKeyNet) -> void:
	panel.forget_key()
	c.api_key = ""
	c.posts = 0
	await panel.run_test()
	K.check(
		fails,
		c.posts == 0 and panel.status.text == "Paste a key first.",
		"Test with no key sends nothing and asks for one (%s)" % panel.status.text
	)
	var typed := "typed_0123456789abcdef"
	panel.input.text = typed
	await panel.run_test()
	K.check(
		fails,
		c.api_key == typed and c.posts == 1,
		"Test applies the key in the field first, then tests it"
	)


## Words for the answers a slow or odd GMI gives, and the over-long paste.
func _check_panel_words(panel: GmiKeyPanel) -> void:
	var slow := PANEL.test_line(
		{"status": "blocked", "seconds": 12.0, "http": 0, "timed_out": true}
	)
	K.check(
		fails,
		slow == "No answer from GMI in 12 s, try again" and not slow.contains("Blocked"),
		"a timeout reads as no answer in time, not as a browser block (%s)" % slow
	)
	K.check(
		fails,
		(
			PANEL.test_line({"status": "blocked", "seconds": 0.1, "http": 0, "timed_out": false})
			== "Blocked by the browser or offline"
		),
		"a refused connection still reads as blocked or offline"
	)
	var coded := {
		"400": "GMI answered an error (HTTP 400)", "402": "GMI answered an error (HTTP 402)"
	}
	for code: String in coded:
		var line := PANEL.test_line({"status": "error", "seconds": 0.3, "http": int(code)})
		K.check(fails, line == coded[code], "HTTP %s reads '%s' (%s)" % [code, coded[code], line])
	K.check(
		fails,
		PANEL.test_line({"status": "error", "seconds": 0.0, "http": 0}) == "Could not reach GMI",
		"an error with no HTTP answer still reads 'Could not reach GMI'"
	)
	panel.input.text = ""
	panel.status.text = ""
	panel.input.insert_text_at_caret("gmi_" + "z".repeat(596))
	K.check(
		fails,
		panel.input.text.length() == 512 and panel.status.text.contains("longer than 512"),
		(
			"a paste over 512 characters is cut and the page says so (%d kept, '%s')"
			% [panel.input.text.length(), panel.status.text]
		)
	)
	panel.input.text = ""


## The Remember switch: a typed key that Test has not passed is not saved, a passing one is, once.
func _check_panel_saving(panel: GmiKeyPanel, c: KIT.FakeKeyNet) -> void:
	panel.forget_key()
	c.remembered.clear()
	var on := Button.new()
	on.toggle_mode = true
	on.set_meta("value", true)
	on.button_pressed = true
	panel.remember.append(on)
	c.reply = {"ok": false, "error": "HTTP 401 bad", "http": 401, "service_fail": false}
	panel.input.text = "typo_0123456789abcdef"
	await panel.run_test()
	K.check(
		fails,
		panel.status.text == "Key rejected (401)" and c.remembered.is_empty(),
		"a typed key GMI rejects is not saved on the device, though Remember is on"
	)
	panel.input.text = "good_0123456789abcdef"
	c.reply = {"ok": true, "data": {"ok": 1}, "http": 200}
	await panel.run_test()
	K.check(
		fails,
		c.remembered == ["good_0123456789abcdef"],
		"the corrected key is saved once it works (%s)" % [c.remembered]
	)
	await panel.run_test()
	K.check(fails, c.remembered.size() == 1, "and a second test does not save it again")
	panel.input.text = "applied_0123456789abcdef"
	panel.apply_key()
	K.check(
		fails,
		c.remembered.size() == 2 and c.remembered[1] == "applied_0123456789abcdef",
		"Apply still saves at once, without a test"
	)
	panel.remember.erase(on)
	on.free()
	panel.forget_key()
