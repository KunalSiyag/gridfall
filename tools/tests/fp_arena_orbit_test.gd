extends SceneTree
## Ask the five in the orbit view (flag arena_ask): the Powers tab has the "Ask the five" button,
## it opens the same panel the street modal uses over the HUD, and without a key the five columns
## are recorded or offline answers that say they did not hear the question, the sim is untouched,
## the budget refuses a second ask, Esc closes the panel. Headless and offline, on the real Main in
## orbit. Prints FP_ARENA_ORBIT_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const TOKEN := "FP_ARENA_ORBIT_TEST"

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 120.0)
	await process_frame
	OS.set_environment("GRIDFALL_VIEW", "orbit")
	OS.set_environment("GRIDFALL_OFFLINE", "1")
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	for _i in range(5):
		await process_frame
	check(main.view_mode == "orbit", "fixture: main boots in orbit")
	main.sim.set_speed(0)
	var buttons: Array[Node] = main.hud.find_children("*", "Button", true, false)
	var ask: Button = null
	for b: Node in buttons:
		if (b as Button).text.begins_with("Ask the five"):
			ask = b
	check(ask != null, "the Powers tab has the Ask the five button")
	if ask == null:
		K.finish(self, TOKEN, fails)
		return
	var before := JSON.stringify(main.sim.to_dict()).hash()
	ask.pressed.emit()
	var panel: Control = main.hud._arena
	check(panel != null and panel.visible, "the button opens the panel over the HUD")
	var res: Dictionary = panel.submit("Your district lost power. What now?")
	check(bool(res.get("ok", false)), "the question goes out (%s)" % str(res))
	var tags := 0
	for c: Control in panel.columns:
		var t := "\n".join(c.call("texts"))
		if t.contains("did not hear your question"):
			tags += 1
	check(tags == D.MAYORS.size(), "five columns say they did not hear the question (%d)" % tags)
	check(JSON.stringify(main.sim.to_dict()).hash() == before, "the sim is untouched")
	var second: Dictionary = panel.submit("And again?")
	check(
		not bool(second.get("ok", true)) and str(second.get("code", "")) == "cooldown",
		"a second ask within a minute is refused (%s)" % str(second.get("code"))
	)
	panel._input(K.action_event("pause_menu"))
	check(not panel.visible, "Esc closes the panel")
	# A new city forgets the old answers (the engine is dropped with the old brain state).
	main.brain.setup(main.sim, main.client)
	check(main.brain.arena == null, "New City drops the asker")
	var again: Dictionary = main.brain.arena_asker().ask("Straight after New City")
	check(
		not bool(again.get("ok", true)) and str(again.get("code", "")) == "cooldown",
		"but not the budget: it lives on the client (%s)" % str(again.get("code"))
	)
	main.audio._exit_tree()
	K.finish(self, TOKEN, fails)
