extends SceneTree
## The orbit view and the street name a mayor the same way (owner report: the orbit view showed
## "Kimi", "Argon" and the like as the mayors while the street, the log and the Gazette name
## Mei Kimura and Ada Okafor, so it read as a different city). Every mayor label of the orbit HUD
## and of the orbit world leads with the person's display name; the model brand ("Argon-4") stays
## as the sub-line and in the Mayor tab's "Model:" line, because the model is the point of the demo.
## Headless and offline, on the real Main in orbit. Prints FP_ORBIT_NAMES_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const TOKEN := "FP_ORBIT_NAMES_TEST"

var fails: Array[String] = []
var main: Node


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 120.0)
	await process_frame
	OS.set_environment("GRIDFALL_VIEW", "orbit")
	OS.set_environment("GRIDFALL_OFFLINE", "1")
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	for _i in range(5):
		await process_frame
	check(main.view_mode == "orbit", "fixture: main boots in orbit")
	main.sim.set_speed(0)
	_check_dock()
	_check_mayor_tab()
	_check_council_and_people()
	_check_world_labels()
	_check_grant_picker()
	main.audio._exit_tree()
	K.finish(self, TOKEN, fails)


## Every text under a node: Label, RichTextLabel and Label3D, with BBCode tags stripped.
func _texts(root: Node, out: Array[String] = []) -> Array[String]:
	var raw := ""
	if root is RichTextLabel:
		raw = (root as RichTextLabel).get_parsed_text()
	elif root is Label:
		raw = (root as Label).text
	elif root is Label3D:
		raw = (root as Label3D).text
	if not raw.is_empty():
		out.append(raw)
	for c in root.get_children():
		_texts(c, out)
	return out


func _any_has(texts: Array[String], needle: String) -> bool:
	for t in texts:
		if t.contains(needle):
			return true
	return false


func _check_dock() -> void:
	var texts := _texts(main.hud)
	for m: Dictionary in D.MAYORS:
		check(
			_any_has(texts, str(m["display"])),
			"dock: the card of %s leads with the person" % m["id"]
		)
		check(
			texts.has("%s · %s" % [m["district"], m["name"]]),
			"dock: %s keeps its model brand in the sub-line" % m["id"]
		)
		check(
			not texts.has(str(m["name"])),
			"dock: no card is headed by the bare brand %s" % m["name"]
		)


func _check_mayor_tab() -> void:
	for mi in range(D.MAYORS.size()):
		var m: Dictionary = D.MAYORS[mi]
		main.hud.select_mayor(mi)
		main.hud._render_mayor()
		var t: String = main.hud._mayor_rt.get_parsed_text()
		check(
			t.begins_with(str(m["display"])),
			"mayor tab: %s is headed by %s" % [m["id"], m["display"]]
		)
		check(
			t.contains("Model: %s" % m["name"]) and t.contains(str(m["model"])),
			"mayor tab: %s names its model brand and id on the Model line" % m["id"]
		)


func _check_council_and_people() -> void:
	main.hud._render_council()
	var council: String = main.hud._council_rt.get_parsed_text()
	var order := ""
	for d: Variant in main.sim.grid_priority:
		order += str(D.MAYORS[int(d)]["display"]) + " > "
	check(
		council.contains(order.trim_suffix(" > ")),
		"city hall: the load-shed order names the mayors by person (%s)" % order
	)
	# The district lines only exist once somebody lives in the city.
	K.grow(main.sim, main.residents, 40)
	check(main.residents.people.size() >= 5, "fixture: the grown city has residents")
	main.hud._render_people()
	var people: String = main.hud._people_rt.get_parsed_text()
	for m: Dictionary in D.MAYORS:
		check(
			people.contains("%s: " % m["display"]),
			"people tab: the %s district line is %s" % [m["id"], m["display"]]
		)
		check(
			not people.contains("%s: " % m["name"]),
			"people tab: no district line is headed by %s" % m["name"]
		)


func _check_world_labels() -> void:
	var texts := _texts(main.view)
	for m: Dictionary in D.MAYORS:
		check(
			texts.has("%s\n%s" % [m["display"], m["district"]]),
			"district sign: %s reads %s over the district" % [m["id"], m["display"]]
		)
		check(
			texts.has(str(m["display"])), "mayor avatar: %s is tagged %s" % [m["id"], m["display"]]
		)
		for t in texts:
			if t == str(m["name"]) or t.begins_with("%s\n" % m["name"]):
				check(false, "world: a label still reads the bare brand %s" % m["name"])
				break


func _check_grant_picker() -> void:
	var picker := _find_option_button(main.hud)
	check(picker != null, "fixture: the grant picker exists")
	if picker == null:
		return
	for mi in range(D.MAYORS.size()):
		var item := picker.get_item_text(mi)
		var m: Dictionary = D.MAYORS[mi]
		check(
			item == "%s (%s)" % [m["display"], m["district"]],
			"grant picker: entry %d is %s (%s)" % [mi, m["display"], item]
		)


func _find_option_button(root: Node) -> OptionButton:
	if root is OptionButton and (root as OptionButton).item_count == D.MAYORS.size():
		var t := (root as OptionButton).get_item_text(0)
		if t.contains(str(D.MAYORS[0]["district"])):
			return root as OptionButton
	for c in root.get_children():
		var found := _find_option_button(c)
		if found != null:
			return found
	return null
