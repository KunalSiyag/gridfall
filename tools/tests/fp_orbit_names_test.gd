extends SceneTree
## The orbit view and the street name a mayor the same way (owner report: the orbit view showed
## "Kimi", "Argon" and the like as the mayors while the street, the log and the Gazette name
## Mei Kimura and Ada Okafor, so it read as a different city). Every mayor label of the orbit HUD
## and of the orbit world leads with the person's display name; the model brand ("Argon-4") stays
## as the sub-line and in the Mayor tab's "Model:" line, because the model is the point of the demo.
## Headless and offline, on the real Main in orbit. Prints FP_ORBIT_NAMES_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const HudChips := preload("res://scripts/fp/ui/hud_chips.gd")
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
	_check_vocabulary()
	_check_top_bar_width()
	_check_mayor_tab()
	_check_council_and_people()
	_check_arena_tab()
	_check_mood_source()
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


## The Arena tab (flag arena_tab, appended after People) leads every block with the person's name
## and keeps the model brand in the sub-line, like the dock and the Mayor tab.
func _check_arena_tab() -> void:
	var tabs: TabContainer = main.hud.get("_tabs")
	check(
		tabs.get_tab_count() == 8 and tabs.get_tab_title(7) == "Arena",
		"arena: the tab is appended after People (index 7)"
	)
	var m: Dictionary = D.MAYORS[1]
	main.brain.ledger.note_call(
		{
			"role": "mayor",
			"agent": str(m["id"]),
			"model": str(m["model"]),
			"source": "live",
			"latency_ms": 6000,
			"attempts": 1
		}
	)
	tabs.current_tab = 7
	main.hud.call("_render_arena")
	var rt: RichTextLabel = main.hud.get("_arena_rt")
	var shown := rt.get_parsed_text()
	for mi in range(D.MAYORS.size()):
		var person := shown.find(str(D.MAYORS[mi]["display"]))
		var brand := shown.find(str(D.MAYORS[mi]["name"]), maxi(person, 0))
		check(
			person >= 0 and brand > person,
			"arena: %s leads, %s is the sub-line" % [D.MAYORS[mi]["display"], D.MAYORS[mi]["name"]]
		)
	check(
		shown.contains("time to answer"),
		"arena: the speed is called time to answer, not model speed"
	)
	tabs.current_tab = 0


## One mood, one word: the Planner's "Mood" is the street's mood function, tile happiness has its
## own name, and nothing there still says "Happy NN%".
func _check_vocabulary() -> void:
	main.hud.call("_refresh_top")
	var shown: String = main.hud._stat_labels["mood"].text
	var street := HudChips.mood_text(HudChips.mood_of(main.sim, main.residents))
	check(
		shown == "Mood " + street,
		"planner: Mood reads the street's mood function (%s vs %s)" % [shown, street]
	)
	var tiles: String = main.hud._stat_labels["happy"].text
	check(
		tiles.begins_with("Tiles happy ") and tiles.ends_with("%"),
		"planner: tile happiness is named as such (%s)" % tiles
	)
	check(not _any_has(_texts(main.hud), "Happy "), "planner: no bare Happy NN% left in the HUD")
	# Before anybody lives here the street falls back to tile happiness, so the Planner does too.
	check(not main.residents.is_active(), "fixture: no residents yet")
	main.sim.stats["happiness"] = 0.31
	main.hud.call("_refresh_top")
	check(
		str(main.hud._stat_labels["mood"].text) == "Mood 3.1",
		(
			"planner: without residents Mood is tile happiness (%s)"
			% main.hud._stat_labels["mood"].text
		)
	)


## With residents active the Planner's Mood follows their sentiment (as the street chip does),
## not the tiles' happiness: a path of its own for the Planner would show Mood 7.7 here.
func _check_mood_source() -> void:
	check(main.residents.is_active(), "fixture: residents are active")
	main.residents.sentiment["mood"] = 0.31
	main.sim.stats["happiness"] = 0.77
	main.hud.call("_refresh_top")
	check(
		str(main.hud._stat_labels["mood"].text) == "Mood 3.1",
		(
			"planner: with residents Mood follows their sentiment (%s)"
			% main.hud._stat_labels["mood"].text
		)
	)
	check(
		str(main.hud._stat_labels["happy"].text) == "Tiles happy 77%",
		(
			"planner: Tiles happy stays the tiles' own number (%s)"
			% main.hud._stat_labels["happy"].text
		)
	)
	var street := HudChips.mood_text(HudChips.mood_of(main.sim, main.residents))
	check(street == "3.1", "planner: the street's mood function agrees (%s)" % street)


## The Planner top bar fits the 1600 px base viewport (8 px margin each side) with the widest
## plausible stat texts: a 16:9 or 16:10 page gets no more width than that, and a wider bar pushed
## the New and Mute buttons off the right edge when Mood was added.
func _check_top_bar_width() -> void:
	var worst := {
		"pop": "Pop 999,999",
		"jobs": "Jobs 999,999",
		"funds": "Funds $99,999,999",
		"mood": "Mood 10.0",
		"happy": "Tiles happy 100%",
		"unemp": "Jobless 100%",
		"events": "Events 12",
	}
	for k: String in worst:
		main.hud._stat_labels[k].text = worst[k]
	var panel: Control = main.hud._stat_labels["pop"].get_parent().get_parent().get_parent()
	var base_w: float = ProjectSettings.get_setting("display/window/size/viewport_width")
	var need := panel.get_combined_minimum_size().x
	check(
		need <= base_w - 16.0,
		"planner top bar: minimum width %.0f fits the %.0f px base viewport" % [need, base_w - 16.0]
	)
	main.hud.call("_refresh_top")


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
	# The vote board: a five-seat row per proposal and the Speaker's record (CouncilBoard).
	main.brain.proposals = {
		"curfew":
		{"by": "Ada Okafor", "day": 3, "votes": {"argon": "yes", "grok": "no", "kimi": "yes"}}
	}
	main.brain.council_history.assign(
		[
			{
				"day": 3,
				"key": "recycling",
				"by": "Rosa Quintero",
				"by_id": "qwen",
				"votes": {"qwen": "yes", "argon": "yes"},
				"notes": {},
				"yes": 2,
				"no": 0,
				"outcome": "enacted",
				"override": true,
				"statement": "",
				"source": "live"
			}
		]
	)
	main.hud._render_council()
	council = main.hud._council_rt.get_parsed_text()
	check(
		council.contains("Youth Curfew by Ada Okafor  2-1"),
		"city hall: a proposal shows its tally, not 'N yes N no'"
	)
	check(
		council.contains("Ada *Y  Viktor -  Mei Y  Rosa -  Duke N"),
		"city hall: five seats, a star on the proposer"
	)
	check(
		council.contains("Day 3  Recycling Program: OVERRIDE: passed with 2"),
		"city hall: the Speaker's override is on the record"
	)
	# A vote cast on a mayor's turn shows on the board at once, without a tab change.
	main.brain.proposals["curfew"]["votes"]["qwen"] = "no"
	main.brain.mayor_decided.emit(
		3,
		{
			"day": 3,
			"thought": "t",
			"post": "p",
			"mood": "calm",
			"actions": [],
			"source": "live",
			"latency_ms": 5,
			"error": "",
			"model": "m",
			"focus": D.NO_TILE,
			"proposal": "",
			"votes": {"curfew": "no"}
		}
	)
	council = main.hud._council_rt.get_parsed_text()
	check(
		council.contains("Youth Curfew by Ada Okafor  2-2") and council.contains("Rosa N"),
		"city hall: a vote appears on the board as the mayor decides"
	)
	main.brain.proposals = {}
	main.brain.council_history.clear()
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
