extends SceneTree
## The planner (orbit) HUD has a "Walk the streets" button that takes the player back to the
## first-person character, the same trip as Tab. A real CityHud must carry the button, and
## pressing it must emit walk_requested exactly once. Headless, offline. Prints CITY_HUD_WALK_TEST:
## PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
const HUD := preload("res://scripts/ui/city_hud.gd")
const TOKEN := "CITY_HUD_WALK_TEST"

var fails: Array[String] = []
var walks := 0


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 60.0)
	await process_frame
	var w := SK.make_world(get_root(), 7)
	var hud: CityHud = HUD.new()
	get_root().add_child(hud)
	hud.setup(w["sim"], w["brain"], w["client"])
	hud.walk_requested.connect(func() -> void: walks += 1)
	var btn := _find_button(hud, "Walk the streets")
	check(btn != null, "the planner HUD has a Walk the streets button")
	if btn != null:
		check(btn.visible and not btn.disabled, "the button is visible and enabled")
		btn.pressed.emit()
		check(walks == 1, "pressing it emits walk_requested once (%d)" % walks)
	K.finish(self, TOKEN, fails)


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n as Button
	for c in n.get_children():
		var r := _find_button(c, text)
		if r != null:
			return r
	return null
