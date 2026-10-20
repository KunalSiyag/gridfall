extends Control
## The AI activity feed (feature "activity"), top right under the compass: a header with the key
## and whether the city's agents answer live, a line for who is deciding now (or who goes next),
## then the newest decisions as cards. The newest card is open: who decided (in their colour) with
## the model badge, what they did, why (their private thought or ruling), any votes, and a footer
## with where the answer came from (live, a replay, a fallback or the offline planner) and where it
## happened. Older cards fold to who and what. J cycles full (MAX_CARDS), brief (the newest card)
## and hidden (the header only).

const S := preload("res://scripts/fp/ui/hud_style.gd")
const W := preload("res://scripts/fp/activity/activity_words.gd")

const WIDTH := 360.0
## Text width inside a card: WIDTH less the 12 px side margins and the 3 px stripe.
const INNER := WIDTH - 27.0
const SAFE := 24.0
## Under the compass strip (it ends at y 106 in the 1600x900 base).
const TOP := 118.0
const MAX_CARDS := 4
const FADE := 0.25
const FLASH := 1.6
## Room kept at the end of a card's top row for its age ("12 min").
const AGO_W := 44.0
const MODES := ["full", "brief", "hidden"]
const OPEN_BG := Color(0.03, 0.04, 0.07, 0.74)
const FOLDED_BG := Color(0.03, 0.04, 0.07, 0.52)
const TAG_COLORS := {"LIVE": S.GOOD, "REPLAY": S.ACCENT, "FALLBACK": S.RED, "OFFLINE": S.AMBER}
const STATES := {
	"live": ["Live", S.GOOD], "down": ["Reconnecting", S.RED], "offline": ["Offline", S.AMBER]
}

var mode: String = "full"
var _col: VBoxContainer
var _title: Label
var _status_slot: HBoxContainer
var _state: String = ""
var _line_box: PanelContainer
var _line: Label
var _line_pulse: bool = false
var _list: VBoxContainer
## Newest first: {"item": Dictionary, "panel": PanelContainer, "box": StyleBoxFlat,
## "headline": Label, "ago": Label, "where": Label, "rich": Array[Control], "age": float}
var _cards: Array[Dictionary] = []
var _pulse: float = 0.0


func setup() -> void:
	name = "ActivityFeed"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_col = VBoxContainer.new()
	_col.name = "Column"
	_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_theme_constant_override("separation", 6)
	_col.anchor_left = 1.0
	_col.anchor_right = 1.0
	_col.offset_left = -SAFE - WIDTH
	_col.offset_right = -SAFE
	_col.offset_top = TOP
	add_child(_col)
	_col.add_child(_header())
	_line_box = PanelContainer.new()
	_line_box.name = "LineBox"
	_line_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lb := S.box(Color(0.03, 0.04, 0.07, 0.5), S.RADIUS, 10, 4)
	_line_box.add_theme_stylebox_override("panel", lb)
	_line = S.plain("", 13, S.TEXT_DIM, S.font())
	_line.name = "Line"
	_line_box.add_child(_line)
	_line_box.visible = false
	_col.add_child(_line_box)
	_list = VBoxContainer.new()
	_list.name = "Cards"
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_theme_constant_override("separation", 4)
	_col.add_child(_list)


func _header() -> HBoxContainer:
	var h := _row(8)
	h.name = "Header"
	_title = S.caps_label("AI activity", 12, S.ACCENT, 2)
	_title.name = "Title"
	h.add_child(_title)
	var key := S.key_cap("J", 11)
	key.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(key)
	h.add_child(_fill())
	_status_slot = _row(0)
	_status_slot.name = "State"
	h.add_child(_status_slot)
	return h


## Whether the city's agents answer from live model calls: "live", "down" (live calls are
## failing, so fallbacks answer) or "offline".
func set_state(state: String) -> void:
	if state == _state or not STATES.has(state):
		return
	_state = state
	for c in _status_slot.get_children():
		_status_slot.remove_child(c)
		c.queue_free()
	var s: Array = STATES[state]
	_status_slot.add_child(S.badge(str(s[0]), s[1], 10))


func state() -> String:
	return _state


## The line under the header: who is deciding now (pulse) or who goes next; "" hides it.
func set_line(t: String, pulse: bool) -> void:
	_line.text = t
	_line_pulse = pulse
	if not pulse:
		_line.modulate.a = 1.0
	_line_box.visible = not t.is_empty() and mode != "hidden"


func line_text() -> String:
	return _line.text if _line_box.visible else ""


## Adds a card for item (fields in ActivityFeature.items) on top and folds the one below. A fresh
## card fades in and flashes in its colour; a restored one (from a save) appears as it is.
func add_item(item: Dictionary, fresh: bool = true) -> void:
	var c := _card(item)
	_list.add_child(c["panel"])
	_list.move_child(c["panel"], 0)
	c["age"] = 0.0 if fresh else FADE + FLASH
	if fresh:
		(c["panel"] as Control).modulate.a = 0.0
	_cards.push_front(c)
	while _cards.size() > MAX_CARDS:
		var old: Dictionary = _cards.pop_back()
		_list.remove_child(old["panel"])
		(old["panel"] as Node).queue_free()
	_apply_mode()


## Drops every card (load, New City).
func clear() -> void:
	for c: Dictionary in _cards:
		_list.remove_child(c["panel"])
		(c["panel"] as Node).queue_free()
	_cards.clear()


## Refreshes every card's age and the open card's place line: where_of(item) -> String; now is
## the feature clock in seconds.
func refresh(where_of: Callable, now: float) -> void:
	for k in range(_cards.size()):
		var c: Dictionary = _cards[k]
		var item: Dictionary = c["item"]
		var clock := float(item.get("clock", -1.0))
		var a := W.ago(now - clock if clock >= 0.0 else -1.0, int(item.get("day", 0)))
		var al: Label = c["ago"]
		if al.text != a:
			al.text = a
		if k == 0:
			var wl: Label = c["where"]
			var wt := str(where_of.call(item))
			if wl.text != wt:
				wl.text = wt


## J: full -> brief -> hidden -> full.
func cycle_mode() -> String:
	set_mode(MODES[(MODES.find(mode) + 1) % MODES.size()])
	return mode


func set_mode(m: String) -> void:
	mode = m if MODES.has(m) else "full"
	_apply_mode()


## Headlines of the cards on screen, newest first.
func headlines() -> PackedStringArray:
	var out := PackedStringArray()
	for c: Dictionary in _cards:
		if (c["panel"] as Control).visible:
			out.append(str(c["item"].get("headline", "")))
	return out


## The newest (open) card's panel, or null.
func open_card() -> Control:
	return _cards[0]["panel"] if not _cards.is_empty() else null


## How many cards the feed holds (shown or not).
func card_count() -> int:
	return _cards.size()


## The header, line and cards as they sit on screen (HUD coordinates).
func column_rect() -> Rect2:
	return _col.get_global_rect()


func _apply_mode() -> void:
	var shown := MAX_CARDS if mode == "full" else (1 if mode == "brief" else 0)
	for k in range(_cards.size()):
		var c: Dictionary = _cards[k]
		(c["panel"] as Control).visible = k < shown
		var open := k == 0
		for r: Control in c["rich"]:
			r.visible = open and bool(r.get_meta("has", true))
		(c["headline"] as Label).max_lines_visible = 2 if open else 1
		if not open:
			c["age"] = FADE + FLASH
			(c["panel"] as Control).modulate.a = 1.0
			(c["box"] as StyleBoxFlat).bg_color = FOLDED_BG
	_line_box.visible = not _line.text.is_empty() and mode != "hidden"
	_title.modulate.a = 0.55 if mode == "hidden" else 1.0


func _process(delta: float) -> void:
	_pulse += delta
	if _line_pulse and _line_box.visible:
		_line.modulate.a = 0.6 + 0.4 * absf(sin(_pulse * 2.4))
	for c: Dictionary in _cards:
		var age := float(c["age"])
		if age >= FADE + FLASH:
			continue
		age = minf(age + delta, FADE + FLASH)
		c["age"] = age
		(c["panel"] as Control).modulate.a = clampf(age / FADE, 0.0, 1.0)
		var k := 1.0 - clampf((age - FADE) / FLASH, 0.0, 1.0)
		var col: Color = c["item"]["color"]
		var flash := Color(col.r, col.g, col.b, 0.42)
		(c["box"] as StyleBoxFlat).bg_color = OPEN_BG.lerp(flash, k * 0.5)


func _card(item: Dictionary) -> Dictionary:
	var col: Color = item.get("color", S.ACCENT)
	var p := PanelContainer.new()
	p.name = "Card"
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := S.stripe(S.box(OPEN_BG, S.RADIUS, 12, 7), col, 3)
	p.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 3)
	p.add_child(v)
	var top := _row(6)
	top.name = "Top"
	v.add_child(top)
	var ago := _top_row(top, item, col)
	var head := _wrapped(str(item.get("headline", "")), 15, S.WHITE, S.bold(), "Headline", 2)
	v.add_child(head)
	var rich: Array[Control] = []
	var detail := str(item.get("detail", ""))
	var dl := _wrapped("“%s”" % detail, 13, S.TEXT_DIM, S.font(), "Detail", 3)
	dl.set_meta("has", not detail.is_empty())
	rich.append(dl)
	var extra := str(item.get("extra", ""))
	var el := _wrapped(extra, 12, col.lerp(S.WHITE, 0.3), S.bold(), "Politics", 2)
	el.set_meta("has", not extra.is_empty())
	rich.append(el)
	var foot := _footer(item)
	rich.append(foot)
	for r: Control in rich:
		v.add_child(r)
	return {
		"item": item,
		"panel": p,
		"box": sb,
		"headline": head,
		"ago": ago,
		"where": foot.get_node("Where"),
		"rich": rich,
		"age": 0.0,
	}


## Who decided (clipped to fit) and the model badge, then the age at the far end. Returns the
## age label.
func _top_row(top: HBoxContainer, item: Dictionary, col: Color) -> Label:
	var who_t := str(item.get("who", ""))
	var who := S.caps_label(who_t, 13, col.lerp(S.WHITE, 0.45), 0)
	who.name = "Who"
	who.clip_text = true
	who.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	top.add_child(who)
	var room := INNER - AGO_W - 12.0
	var model := str(item.get("model", ""))
	if not model.is_empty():
		var b := S.badge(model, col)
		b.name = "Model"
		top.add_child(b)
		room -= b.get_combined_minimum_size().x
	who.custom_minimum_size.x = clampf(S.caps_width(who_t, 13) + 2.0, 0.0, maxf(room, 40.0))
	top.add_child(_fill())
	var ago := S.plain("", 12, S.TEXT_FAINT, S.font())
	ago.name = "Ago"
	top.add_child(ago)
	return ago


## Where the answer came from, where it happened and, for a decision with a place, the G key
## that routes the GPS there.
func _footer(item: Dictionary) -> HBoxContainer:
	var foot := _row(6)
	foot.name = "Footer"
	var tag := W.source_tag(str(item.get("source", "")), bool(item.get("failed", false)))
	var sbadge := S.badge(tag, TAG_COLORS.get(tag, S.AMBER), 10)
	sbadge.name = "Source"
	foot.add_child(sbadge)
	var where := S.plain("", 12, S.TEXT_FAINT, S.font())
	where.name = "Where"
	where.clip_text = true
	where.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	where.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(where)
	var route := _row(4)
	route.name = "Route"
	var key := S.key_cap("G", 10)
	key.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	route.add_child(key)
	route.add_child(S.caps_label("Route", 10, S.TEXT_DIM, 0))
	route.visible = bool(item.get("placed", false))
	foot.add_child(route)
	return foot


func _wrapped(t: String, size_px: int, col: Color, f: Font, n: String, lines: int) -> Label:
	var l := S.plain(t, size_px, col, f)
	l.name = n
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(INNER, 0)
	l.max_lines_visible = lines
	return l


func _row(sep: int) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", sep)
	return h


func _fill() -> Control:
	var gap := Control.new()
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return gap
