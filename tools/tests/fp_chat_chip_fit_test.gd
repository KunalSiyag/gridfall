extends SceneTree
## The chips on a mayor's chat line (scripts/fp/ui/chat_panel_row.gd): PRESS OFFICE or OWN WORDS
## beside MAYOR and the district tag must never run into the time stamp, whatever the mayor's name
## and however narrow the row. The row falls back to the short forms (PR, OWN) and, failing that,
## leaves a chip out; a chip says what it means as its tooltip. Measured with the real row class
## and the five real mayor names. Headless, offline. Prints FP_CHAT_CHIP_FIT_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const ROW := preload("res://scripts/fp/ui/chat_panel_row.gd")
const TOKEN := "FP_CHAT_CHIP_FIT_TEST"

var fails: Array[String] = []


func _init() -> void:
	K.watchdog(self, TOKEN, 60.0)
	await process_frame
	_check_every_name()
	_check_short_forms()
	_check_tooltips()
	K.finish(self, TOKEN, fails)


func _row(author: String, via: String, district: int, w: float) -> Control:
	var row: Control = ROW.new()
	get_root().add_child(row)
	var refs := {"via": via} if not via.is_empty() else {}
	var msg := {
		"seq": 1,
		"author": author,
		"author_id": "mayor:%d" % district,
		"role": "mayor",
		"district": district,
		"text": "Hello city, a short line.",
		"kind": "chatter",
		"day": 1,
		"clock": "10:00",
		"t_ms": 0,
		"reply_to": -1,
		"refs": refs
	}
	row.call("setup", msg, {}, w, "just now", district)
	row.size = Vector2(w, row.custom_minimum_size.y)
	return row


func _shown(row: Control) -> PackedStringArray:
	var run: Dictionary = row.call("_chip_run", row.size.x)
	var out := PackedStringArray()
	for c: Dictionary in run["chips"]:
		out.append(
			TextServerManager.get_primary_interface().shaped_get_text(
				(c["line"] as TextLine).get_rid()
			)
		)
	return out


## Every real mayor name, both chips, panel widths from the chat panel's own down to a narrow one:
## the last chip ends before the time stamp starts.
func _check_every_name() -> void:
	var bad := PackedStringArray()
	var rows := 0
	for w: float in [432.0, 380.0, 352.0, 338.0, 300.0]:
		for mi in range(D.MAYORS.size()):
			for via: String in ["press_office", "own_voice"]:
				var row := _row(str(D.MAYORS[mi]["display"]), via, mi, w)
				var lay: Dictionary = row.call("header_layout", w)
				rows += 1
				for r: Rect2 in lay["rects"]:
					if r.end.x > float(lay["time_left"]) - 1.0:
						bad.append("%s/%s@%d" % [D.MAYORS[mi]["display"], via, int(w)])
						break
				row.queue_free()
	K.check(
		fails, bad.is_empty(), "no chip reaches the time stamp (%d rows; %s)" % [rows, str(bad)]
	)


## A wide row keeps the full words; a narrow one, with the longest names, takes the short forms.
func _check_short_forms() -> void:
	var wide := _row("Rosa Quintero", "press_office", 3, 432.0)
	K.check(
		fails,
		_shown(wide).has("PRESS OFFICE") and _shown(wide).has("MAYOR"),
		"432 px: the full chip (%s)" % str(_shown(wide))
	)
	wide.queue_free()
	var narrow := _row("Rosa Quintero", "press_office", 3, 338.0)
	var tags := _shown(narrow)
	K.check(
		fails,
		tags.has("PR") and not tags.has("PRESS OFFICE") and tags.has("MAYOR"),
		"338 px: the short chip PR, MAYOR kept (%s)" % str(tags)
	)
	narrow.queue_free()
	var own := _row("Duke Granger", "own_voice", 4, 338.0)
	var own_tags := _shown(own)
	K.check(
		fails,
		own_tags.has("OWN") and not own_tags.has("OWN WORDS"),
		"338 px: OWN WORDS becomes OWN (%s)" % str(own_tags)
	)
	own.queue_free()
	# A row so narrow that even the short chip would touch the time loses the chip, not the name.
	var tiny := _row("Rosa Quintero", "press_office", 3, 240.0)
	var lay: Dictionary = tiny.call("header_layout", 240.0)
	var clear := true
	for r: Rect2 in lay["rects"]:
		clear = clear and r.end.x <= float(lay["time_left"]) - 1.0
	K.check(fails, clear, "240 px: whatever is drawn stays clear of the time")
	tiny.queue_free()


## Hovering a chip explains it (also in its short form); elsewhere the row keeps its day and time.
func _check_tooltips() -> void:
	var row := _row("Rosa Quintero", "press_office", 3, 338.0)
	var lay: Dictionary = row.call("header_layout", 338.0)
	var rects: Array = lay["rects"]
	var tip := str(row.call("_get_tooltip", (rects[1] as Rect2).get_center()))
	K.check(
		fails, rects.size() >= 2 and tip.begins_with("Press office"), "a chip's tooltip: %s" % tip
	)
	var other := str(row.call("_get_tooltip", Vector2(5, 5)))
	K.check(
		fails, other.begins_with("Day 1"), "off the chips the tooltip is the row's (%s)" % other
	)
	row.queue_free()
