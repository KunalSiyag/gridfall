extends Control
## The global chat panel (slice C §2), Clash of Clans style: a drawer that slides out of the left
## edge of chat_slot (440 px) with a 20 px edge tab and an unread badge, City / District tabs, the
## pinned Gazette headline, one row per message (round avatar, role-coloured name, district badge,
## relative time, reply arrow) or a tinted system card, a "New messages" pill while scrolled up and
## the input line. Closed, the last three messages fade out as a ticker above the minimap.
## Rows are appended and never re-rendered; only their time labels refresh every 10 s of feed time.

const S := preload("res://scripts/fp/ui/chat_panel_style.gd")
const W := preload("res://scripts/fp/ui/chat_panel_widgets.gd")
const ROW := preload("res://scripts/fp/ui/chat_panel_row.gd")
const TICKER := preload("res://scripts/fp/ui/chat_panel_ticker.gd")
const T := preload("res://scripts/fp/chat/chat_text.gd")
const D := preload("res://scripts/sim/sim_defs.gd")

const PANEL_W := 440.0
const TAB_W := 20.0
const TAB_H := 64.0
const SLIDE_SECONDS := 0.18
const MAX_ROWS := 120
const TICKER_LINES := 3
const TICKER_SECONDS := 8.0
const TICKER_FADE := 1.2
const TICKER_CHARS := 118
const TIME_REFRESH_MS := 10000
const FADE_IN := 0.2
const INPUT_MAX := 140
## Width rows are first shaped for (the list width with the always-on scroll bar).
const ROW_W := PANEL_W - 8.0
const HELP := "Enter sends, Esc closes.\nType @ and the start of a name, then Tab, to call a neighbour within 10 blocks.\nStart a line with /mayor to write to every mayor (once a day)."
## Residents within this many tiles of the player can be @-mentioned.
const MENTION_TILES := 10.0

## The player sent a line (already trimmed, at most INPUT_MAX characters).
signal submitted(text: String)
## The drawer opened (true) or closed (false).
signal open_changed(open: bool)

var ctx: FpContext
var feed: ChatFeed
var is_open: bool = false
var unread: int = 0
## "city" or "district".
var tab: String = "city"
var player_district: int = -1
## The chat input line (tests focus it).
var input: LineEdit

var _drawer: Control
var _body: PanelContainer
var _tab: Button
var _tab_icon: Control
var _badge: PanelContainer
var _badge_label: Label
var _city_btn: Button
var _district_btn: Button
var _online: Label
var _pinned: PanelContainer
var _pinned_title: Label
var _pinned_headline: Label
var _pinned_more: VBoxContainer
var _pinned_chev: Control
var _pinned_open: bool = false
var _scroll: ScrollContainer
var _list: VBoxContainer
var _pill: Button
var _ticker: VBoxContainer
## Each: {"node": ticker line, "t": seconds shown}.
var _ticker_items: Array[Dictionary] = []
## One row Control per shown message, oldest first.
var _rows: Array[ROW] = []
var _follow: bool = true
var _last_refresh_ms: int = 0
var _tween: Tween
var _dots: Dictionary = {}


## Builds the drawer, the edge tab and the ticker inside chat_slot.
func setup(p_ctx: FpContext, p_feed: ChatFeed) -> void:
	ctx = p_ctx
	feed = p_feed
	name = "ChatPanel"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ticker()
	_build_drawer()
	_drawer.position.x = -PANEL_W
	_body.visible = false
	_update_tab()


func _unhandled_input(event: InputEvent) -> void:
	if is_open or event.is_echo() or not event.is_action_pressed("chat_open"):
		return
	if ctx == null or ctx.is_modal() or (ctx.player != null and ctx.player.photo_mode):
		return
	if ctx.hud != null and not ctx.hud.is_hud_visible():
		return
	open()
	get_viewport().set_input_as_handled()


## A focused LineEdit swallows Esc before _unhandled_input, so the open panel catches it here.
## Tab completes an @-mention instead of moving the focus (which would close the chat).
func _input(event: InputEvent) -> void:
	if not is_open:
		return
	if not event.is_echo() and event.is_action_pressed("pause_menu"):
		close()
		get_viewport().set_input_as_handled()
	elif input.has_focus() and (event.is_action_pressed("ui_focus_next") or event.is_action_pressed("ui_focus_prev")):
		complete_mention()
		get_viewport().set_input_as_handled()


## Completes the "@na" before the caret to "@Name " with the nearest resident within
## MENTION_TILES whose first or last name starts with it. Returns the name, or "".
func complete_mention() -> String:
	var text := input.text
	var caret := input.caret_column
	var start := text.rfind("@", maxi(caret - 1, 0))
	if start < 0:
		return ""
	var token := text.substr(start + 1, caret - start - 1).to_lower()
	if token.is_empty() or token.contains(" ") or ctx == null or ctx.residents == null:
		return ""
	var p := ctx.player_position()
	var best := ""
	var bd := INF
	for r: Dictionary in ctx.residents.people:
		var nm := str(r["name"])
		var low := nm.to_lower()
		if not (low.begins_with(token) or low.get_slice(" ", 1).begins_with(token)):
			continue
		var at := int(r.get("at", r["home"]))
		var d := Vector2(D.tx(at) - p.x, D.ty(at) - p.z).length()
		if d <= MENTION_TILES and d < bd:
			bd = d
			best = nm
	if best.is_empty():
		return ""
	var first := best.get_slice(" ", 0)
	input.text = text.substr(0, start) + "@" + first + " " + text.substr(caret)
	input.caret_column = start + first.length() + 2
	return best


func _process(delta: float) -> void:
	var k := 0
	while k < _ticker_items.size():
		var it: Dictionary = _ticker_items[k]
		it["t"] = float(it["t"]) + delta
		var node: Control = it["node"]
		var left := TICKER_SECONDS - float(it["t"])
		if left <= 0.0:
			node.queue_free()
			_ticker_items.remove_at(k)
			continue
		node.modulate.a = clampf(left / TICKER_FADE, 0.0, 1.0)
		k += 1


# ---------------------------------------------------------------- open / close

## Slides the drawer out, pushes the &"chat" modal and focuses the input.
func open() -> void:
	if is_open:
		return
	is_open = true
	if ctx != null:
		ctx.push_modal(&"chat")
	_body.visible = true
	_body.mouse_filter = Control.MOUSE_FILTER_STOP
	unread = 0
	_update_tab()
	_clear_ticker()
	_refresh_online()
	_refresh_times(true)
	_slide(0.0)
	_follow = true
	_scroll_to_end.call_deferred()
	input.grab_focus()
	input.edit()
	open_changed.emit(true)


## Slides the drawer back, releases the input and pops &"chat". Safe to call when closed.
func close() -> void:
	if not is_open:
		return
	is_open = false
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if input.has_focus():
		input.unedit()
		input.release_focus()
	if ctx != null:
		ctx.pop_modal(&"chat")
	_slide(-PANEL_W)
	_update_tab()
	open_changed.emit(false)


func _slide(x: float) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if not is_inside_tree():
		_drawer.position.x = x
		_body.visible = is_open
		return
	_tween = create_tween()
	_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_drawer, "position:x", x, SLIDE_SECONDS)
	if x < 0.0:
		_tween.tween_callback(func() -> void: _body.visible = is_open)


# ---------------------------------------------------------------- rows

## Appends one shown message: one row Control in the list, a ticker line while closed and the
## unread badge. Prunes the oldest row past MAX_ROWS.
func append(msg: Dictionary) -> void:
	var row := _make_row(msg)
	_list.add_child(row)
	_rows.append(row)
	_apply_filter(row)
	while _rows.size() > MAX_ROWS:
		_rows.pop_front().queue_free()
	if is_open:
		if row.visible:
			_fade_in(row)
		if not _follow and row.visible:
			_pill.visible = true
	else:
		_push_ticker(msg)
		if str(msg.get("role", "")) != "player":
			unread += 1
			_update_tab()


## Re-renders the row of msg in place (the Breaking card replacing its incident card).
func replace(msg: Dictionary) -> void:
	for row in _rows:
		if int(row.msg.get("seq", -1)) == int(msg.get("seq", -2)):
			row.set_msg(msg, _parent_of(msg), T.rel_time(_now() - int(msg.get("t_ms", 0))))
			row.district = _row_district(msg)
			_apply_filter(row)
			return


## Drops every row and the ticker (load, New City).
func clear_rows() -> void:
	for row in _rows:
		row.queue_free()
	_rows.clear()
	_clear_ticker()
	_pill.visible = false
	unread = 0
	_update_tab()


## Clears, then appends msgs (after a load) without touching the ticker or the badge.
func rebuild(msgs: Array, p_unread: int) -> void:
	clear_rows()
	for m: Dictionary in msgs.slice(-MAX_ROWS):
		var row := _make_row(m)
		_list.add_child(row)
		_rows.append(row)
		_apply_filter(row)
	unread = maxi(p_unread, 0)
	_update_tab()
	_follow = true
	_scroll_to_end.call_deferred()


## Rows currently in the list (tests; never more than MAX_ROWS).
func row_count() -> int:
	return _rows.size()


## The row Controls, oldest first (tests).
func rows() -> Array[ROW]:
	return _rows


## Refreshes the relative times every TIME_REFRESH_MS of feed time while open.
func on_pump(now_ms: int) -> void:
	if is_open and now_ms - _last_refresh_ms >= TIME_REFRESH_MS:
		_refresh_times(false)


## The player's district (from the tile under their feet); refilters the District tab.
func set_player_district(d: int) -> void:
	if d == player_district:
		return
	player_district = d
	_refresh_district_tab()
	if tab == "district":
		for row in _rows:
			_apply_filter(row)


## Shows the pinned Gazette (paper: {"headline", "editorial", "stories": [{"title", "body"}],
## "day"}, already filtered); {} hides it.
func set_pinned(paper: Dictionary) -> void:
	var hl := str(paper.get("headline", "")).strip_edges()
	_pinned.visible = not hl.is_empty()
	if hl.is_empty():
		return
	_pinned_title.text = "GRIDFALL GAZETTE  \u00b7  DAY %d" % int(paper.get("day", 0))
	_pinned_headline.text = hl
	for c in _pinned_more.get_children():
		c.queue_free()
	for st: Variant in (paper.get("stories", []) as Array).slice(0, 3):
		var sd: Dictionary = st if typeof(st) == TYPE_DICTIONARY else {}
		var title := str(sd.get("title", "")).strip_edges()
		var body := str(sd.get("body", "")).strip_edges()
		if title.is_empty() and body.is_empty():
			continue
		var box := VBoxContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_theme_constant_override("separation", 1)
		if not title.is_empty():
			box.add_child(S.wrap_label(title, S.bold_font(), 13, Color("#BFD8FF")))
		if not body.is_empty():
			box.add_child(S.wrap_label(T.clip(body, 170), S.body_font(), 12, S.TEXT_DIM))
		_pinned_more.add_child(box)
	var ed := str(paper.get("editorial", "")).strip_edges()
	if not ed.is_empty():
		_pinned_more.add_child(S.wrap_label("\u201C" + ed + "\u201D", S.italic_font(), 13, S.TEXT))
	_set_pinned_open(false)


## The pinned headline text ("" when none).
func pinned_text() -> String:
	return _pinned_headline.text if _pinned.visible else ""


func _make_row(msg: Dictionary) -> ROW:
	var row := ROW.new()
	row.setup(msg, _parent_of(msg), ROW_W, T.rel_time(_now() - int(msg.get("t_ms", 0))), _row_district(msg))
	return row


## The parent of a reply ({"author", "text"}) while its row is in the list, else {}.
func _parent_of(msg: Dictionary) -> Dictionary:
	var rt := int(msg.get("reply_to", -1))
	if rt <= 0:
		return {}
	for k in range(_rows.size() - 1, -1, -1):
		var m: Dictionary = _rows[k].msg
		if int(m.get("seq", -1)) == rt:
			return {"author": str(m.get("author", "")), "text": str(m.get("text", ""))}
	return {}


func _row_district(msg: Dictionary) -> int:
	var d := int(msg.get("district", -1))
	var refs: Dictionary = msg.get("refs", {})
	if d < 0 and refs.has("tile") and ctx != null and ctx.sim != null:
		var t := int(refs["tile"])
		if t >= 0 and t < ctx.sim.district.size():
			d = ctx.sim.district[t]
	return d


func _apply_filter(row: ROW) -> void:
	row.visible = tab == "city" or row.district == player_district


func _refresh_times(all_rows: bool) -> void:
	var now := _now()
	_last_refresh_ms = now
	for row in _rows:
		if all_rows or row.visible:
			row.set_time(T.rel_time(now - row.t_ms))
	_refresh_online()


func _now() -> int:
	return feed.now_ms if feed != null else 0


func _set_tab(t: String) -> void:
	tab = t
	_style_tab_button(_city_btn, tab == "city")
	_style_tab_button(_district_btn, tab == "district")
	for row in _rows:
		_apply_filter(row)
	_follow = true
	_pill.visible = false
	_scroll_to_end.call_deferred()


func _refresh_district_tab() -> void:
	if _district_btn == null:
		return
	var label := "Frontier"
	if player_district >= 0 and player_district < D.MAYORS.size():
		label = str(D.MAYORS[player_district]["district"])
	_district_btn.text = label
	_district_btn.icon = _dot_texture(S.district_color(player_district))


func _refresh_online() -> void:
	if _online == null or ctx == null or ctx.residents == null:
		return
	var n := ctx.residents.people.size()
	_online.text = "%d neighbour%s" % [n, "" if n == 1 else "s"]


func _update_tab() -> void:
	if _tab == null:
		return
	(_tab_icon as W.Icon).set_icon("chevron_left" if is_open else "chevron_right", S.GOLD)
	_badge.visible = unread > 0 and not is_open
	_badge_label.text = "99+" if unread > 99 else str(unread)


func _set_pinned_open(o: bool) -> void:
	_pinned_open = o and _pinned_more.get_child_count() > 0
	_pinned_more.visible = _pinned_open
	(_pinned_chev as W.Icon).set_icon("chevron_up" if _pinned_open else "chevron_down", S.PIN_BLUE)


func _scroll_to_end() -> void:
	if _scroll == null:
		return
	var bar := _scroll.get_v_scroll_bar()
	_scroll.scroll_vertical = int(bar.max_value)
	_pill.visible = false


func _on_bar_changed() -> void:
	if _follow:
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _on_scrolled(value: float) -> void:
	var bar := _scroll.get_v_scroll_bar()
	_follow = value >= bar.max_value - bar.page - 6.0
	if _follow:
		_pill.visible = false


func _on_submitted(text: String) -> void:
	var t := text.strip_edges()
	if t.is_empty():
		close()
		return
	input.clear()
	submitted.emit(t.left(INPUT_MAX))
	_follow = true
	_scroll_to_end.call_deferred()


func _on_editing_toggled(on: bool) -> void:
	if not on and is_open:
		close()


# ---------------------------------------------------------------- ticker

func _push_ticker(msg: Dictionary) -> void:
	var role := str(msg.get("role", ""))
	var text := T.clip(str(msg.get("text", "")), TICKER_CHARS)
	var head := str(msg.get("author", ""))
	var head_col := S.role_color(role, int(msg.get("district", -1)))
	var text_col := Color(0.95, 0.97, 1.0)
	if role == "system":
		var kind := str(msg.get("kind", "log"))
		var spec: Array = S.CARDS.get(kind, S.CARDS["log"])
		head_col = spec[1]
		head = str(spec[2])
		if kind == "incident" and str((msg.get("refs", {}) as Dictionary).get("phase", "")) == "ended":
			head_col = S.CARDS["opened"][1]
			head = "ALL CLEAR"
		elif kind == "people":
			head = ""
			text_col = Color(S.CARDS["people"][1]).lightened(0.35)
		if kind == "alert" and text.begins_with("Breaking: "):
			text = text.substr(10)
	var line := TICKER.new()
	line.setup(head, head_col, text, text_col, PANEL_W - 24.0)
	_ticker.add_child(line)
	_fade_in(line)
	_ticker_items.append({"node": line, "t": 0.0})
	while _ticker_items.size() > TICKER_LINES:
		var old: Dictionary = _ticker_items.pop_front()
		(old["node"] as Node).queue_free()


## A short fade for a row or ticker line that just appeared (the ticker's own fade-out drives
## modulate afterwards, so this one only runs for its first FADE_IN seconds).
func _fade_in(c: CanvasItem) -> void:
	if not is_inside_tree():
		return
	c.self_modulate.a = 0.0
	var tw := c.create_tween()
	tw.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(c, "self_modulate:a", 1.0, FADE_IN)


func _clear_ticker() -> void:
	for it: Dictionary in _ticker_items:
		(it["node"] as Node).queue_free()
	_ticker_items.clear()


# ---------------------------------------------------------------- construction

func _build_ticker() -> void:
	_ticker = VBoxContainer.new()
	_ticker.name = "Ticker"
	_ticker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ticker.anchor_left = 0.0
	_ticker.anchor_right = 0.0
	_ticker.anchor_top = 1.0
	_ticker.anchor_bottom = 1.0
	_ticker.offset_left = 14
	_ticker.offset_right = PANEL_W
	_ticker.offset_top = -230
	_ticker.offset_bottom = -6
	_ticker.alignment = BoxContainer.ALIGNMENT_END
	_ticker.add_theme_constant_override("separation", 3)
	add_child(_ticker)


func _build_drawer() -> void:
	_drawer = Control.new()
	_drawer.name = "Drawer"
	_drawer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drawer.anchor_top = 0.0
	_drawer.anchor_bottom = 1.0
	_drawer.offset_left = 0
	_drawer.offset_right = PANEL_W
	add_child(_drawer)
	_body = PanelContainer.new()
	_body.name = "Body"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bsb := S.box(S.PANEL_BG, [0, 18, 18, 0], S.EDGE, 0, Vector4(0, 0, 0, 0))
	bsb.border_width_right = 1
	bsb.border_width_top = 1
	bsb.border_width_bottom = 1
	bsb.shadow_color = Color(0, 0, 0, 0.35)
	bsb.shadow_size = 14
	bsb.shadow_offset = Vector2(3, 4)
	_body.add_theme_stylebox_override("panel", bsb)
	_drawer.add_child(_body)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 0)
	_body.add_child(col)
	col.add_child(_build_header())
	_pinned = _build_pinned()
	var pm := MarginContainer.new()
	pm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pm.add_theme_constant_override("margin_left", 10)
	pm.add_theme_constant_override("margin_right", 10)
	pm.add_theme_constant_override("margin_top", 8)
	pm.add_theme_constant_override("margin_bottom", 2)
	pm.add_child(_pinned)
	col.add_child(pm)
	_pinned.visibility_changed.connect(func() -> void: pm.visible = _pinned.visible)
	pm.visible = false
	col.add_child(_build_list())
	col.add_child(_build_input())
	_build_tab()


func _build_header() -> Control:
	var hp := PanelContainer.new()
	hp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := S.box(S.HEADER_BG, [0, 18, 0, 0], S.EDGE, 0, Vector4(10, 8, 10, 8))
	sb.border_width_bottom = 1
	hp.add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 8)
	hp.add_child(h)
	var seg := PanelContainer.new()
	seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	seg.add_theme_stylebox_override("panel", S.box(Color(1, 1, 1, 0.06), 16, Color(1, 1, 1, 0.06), 1, Vector4(3, 3, 3, 3)))
	h.add_child(seg)
	var tabs := HBoxContainer.new()
	tabs.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tabs.add_theme_constant_override("separation", 2)
	seg.add_child(tabs)
	_city_btn = _tab_button("City")
	_city_btn.pressed.connect(_set_tab.bind("city"))
	tabs.add_child(_city_btn)
	_district_btn = _tab_button("District")
	_district_btn.pressed.connect(_set_tab.bind("district"))
	_district_btn.add_theme_constant_override("h_separation", 6)
	tabs.add_child(_district_btn)
	_style_tab_button(_city_btn, true)
	_style_tab_button(_district_btn, false)
	_refresh_district_tab()
	var sp := Control.new()
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)
	var dot := W.Dot.new(Color("#3DDC84"), 8.0)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(dot)
	_online = S.label("", S.body_font(), 12, S.TEXT_DIM)
	_online.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(_online)
	var close_b := Button.new()
	close_b.focus_mode = Control.FOCUS_NONE
	close_b.flat = true
	close_b.custom_minimum_size = Vector2(28, 28)
	close_b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_b.tooltip_text = "Close (Esc)"
	for st in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
		close_b.add_theme_stylebox_override(st, S.box(Color(1, 1, 1, 0.08 if st == "hover" else 0.0), 14))
	var ci := W.Icon.new("close", S.TEXT_DIM, 14.0)
	ci.position = Vector2(7, 7)
	close_b.add_child(ci)
	close_b.pressed.connect(close)
	h.add_child(close_b)
	return hp


func _tab_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_override("font", S.display_font())
	b.add_theme_font_size_override("font_size", 14)
	b.custom_minimum_size = Vector2(64, 28)
	return b


func _style_tab_button(b: Button, active: bool) -> void:
	var bg := S.GOLD if active else Color(0, 0, 0, 0)
	var fg := Color(0.13, 0.09, 0.02) if active else S.TEXT_DIM
	var pad := Vector4(12, 3, 12, 3)
	b.add_theme_stylebox_override("normal", S.box(bg, 13, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("hover", S.box(bg if active else Color(1, 1, 1, 0.07), 13, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("pressed", S.box(bg.darkened(0.1) if active else Color(1, 1, 1, 0.1), 13, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("hover_pressed", S.box(bg, 13, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(st, fg if not (st == "font_hover_color" and not active) else S.TEXT)


func _build_pinned() -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "Pinned"
	p.visible = false
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	p.tooltip_text = "Today's Gazette: click for the stories"
	var sb := S.box(Color(0.055, 0.11, 0.2, 0.97), 12, Color(S.PIN_BLUE, 0.95), 2, Vector4(10, 8, 10, 9))
	sb.shadow_color = Color(S.PIN_BLUE, 0.18)
	sb.shadow_size = 6
	p.add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 9)
	p.add_child(h)
	var pin := W.Icon.new("pin", S.PIN_BLUE, 18.0)
	pin.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	h.add_child(pin)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 3)
	h.add_child(v)
	_pinned_title = S.label("GRIDFALL GAZETTE", S.display_font(), 11, Color("#8DBBFF"))
	v.add_child(_pinned_title)
	_pinned_headline = S.wrap_label("", S.bold_font(), 14, Color.WHITE)
	v.add_child(_pinned_headline)
	_pinned_more = VBoxContainer.new()
	_pinned_more.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pinned_more.add_theme_constant_override("separation", 6)
	_pinned_more.visible = false
	v.add_child(_pinned_more)
	_pinned_chev = W.Icon.new("chevron_down", S.PIN_BLUE, 16.0)
	_pinned_chev.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	h.add_child(_pinned_chev)
	p.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_set_pinned_open(not _pinned_open))
	return p


func _build_list() -> Control:
	var area := Control.new()
	area.name = "ListArea"
	area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	area.clip_contents = true
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.follow_focus = false
	S.style_scroll(_scroll)
	_scroll.get_v_scroll_bar().focus_mode = Control.FOCUS_NONE
	area.add_child(_scroll)
	var pad := MarginContainer.new()
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_top", 6)
	pad.add_theme_constant_override("margin_bottom", 8)
	_scroll.add_child(pad)
	_list = VBoxContainer.new()
	_list.name = "Rows"
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 2)
	pad.add_child(_list)
	var fade := TextureRect.new()
	fade.name = "TopFade"
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade.anchor_right = 1.0
	fade.offset_right = -8
	fade.offset_bottom = 16
	fade.stretch_mode = TextureRect.STRETCH_SCALE
	fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var g := Gradient.new()
	g.set_color(0, Color(S.PANEL_BG, 1.0))
	g.set_color(1, Color(S.PANEL_BG, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_to = Vector2(0, 1)
	gt.width = 4
	gt.height = 32
	fade.texture = gt
	area.add_child(fade)
	var bar := _scroll.get_v_scroll_bar()
	bar.changed.connect(_on_bar_changed)
	bar.value_changed.connect(_on_scrolled)
	_pill = S.pill_button("New messages", S.GOLD, Color(0.13, 0.09, 0.02), 13, S.display_font())
	_pill.name = "NewMessages"
	_pill.visible = false
	_pill.anchor_left = 0.5
	_pill.anchor_right = 0.5
	_pill.anchor_top = 1.0
	_pill.anchor_bottom = 1.0
	_pill.offset_left = -88
	_pill.offset_right = 88
	_pill.offset_top = -44
	_pill.offset_bottom = -12
	_pill.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_pill.add_theme_stylebox_override("normal", S.box(S.GOLD, 16, Color(1, 1, 1, 0.35), 1, Vector4(16, 5, 40, 5)))
	_pill.add_theme_stylebox_override("hover", S.box(S.GOLD.lightened(0.12), 16, Color(1, 1, 1, 0.5), 1, Vector4(16, 5, 40, 5)))
	_pill.add_theme_stylebox_override("pressed", S.box(S.GOLD.darkened(0.12), 16, Color(1, 1, 1, 0.5), 1, Vector4(16, 5, 40, 5)))
	_pill.add_theme_constant_override("h_separation", 0)
	var arrow := W.Icon.new("arrow_down", Color(0.13, 0.09, 0.02), 14.0)
	arrow.anchor_left = 1.0
	arrow.anchor_right = 1.0
	arrow.anchor_top = 0.5
	arrow.anchor_bottom = 0.5
	arrow.offset_left = -28
	arrow.offset_right = -14
	arrow.offset_top = -7
	arrow.offset_bottom = 7
	_pill.add_child(arrow)
	_pill.pressed.connect(func() -> void:
		_follow = true
		_scroll_to_end())
	area.add_child(_pill)
	return area


func _build_input() -> Control:
	var ip := PanelContainer.new()
	ip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := S.box(S.INPUT_BG, [0, 0, 18, 0], S.EDGE, 0, Vector4(10, 9, 10, 10))
	sb.border_width_top = 1
	ip.add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 8)
	ip.add_child(h)
	input = LineEdit.new()
	input.name = "Input"
	input.placeholder_text = "Say something to the city…"
	input.max_length = INPUT_MAX
	input.keep_editing_on_text_submit = true
	input.context_menu_enabled = false
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.custom_minimum_size.y = 34
	S.style_line_edit(input, 14)
	input.text_submitted.connect(_on_submitted)
	input.editing_toggled.connect(_on_editing_toggled)
	h.add_child(input)
	var send := Button.new()
	send.name = "Send"
	send.focus_mode = Control.FOCUS_NONE
	send.custom_minimum_size = Vector2(34, 34)
	send.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	send.tooltip_text = "Send (Enter)"
	send.add_theme_stylebox_override("normal", S.box(S.GOLD, 17))
	send.add_theme_stylebox_override("hover", S.box(S.GOLD.lightened(0.15), 17))
	send.add_theme_stylebox_override("pressed", S.box(S.GOLD.darkened(0.15), 17))
	send.add_theme_stylebox_override("hover_pressed", S.box(S.GOLD.darkened(0.1), 17))
	send.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var si := W.Icon.new("send", Color(0.13, 0.09, 0.02), 16.0)
	si.position = Vector2(9, 9)
	send.add_child(si)
	send.pressed.connect(func() -> void: _on_submitted(input.text))
	h.add_child(send)
	var help := W.Icon.new("help", S.TEXT_FAINT, 18.0)
	help.mouse_filter = Control.MOUSE_FILTER_PASS
	help.tooltip_text = HELP
	help.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(help)
	return ip


func _build_tab() -> void:
	_tab = Button.new()
	_tab.name = "EdgeTab"
	_tab.focus_mode = Control.FOCUS_NONE
	_tab.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_tab.tooltip_text = "City chat (Enter)"
	_tab.anchor_left = 0.0
	_tab.anchor_right = 0.0
	_tab.anchor_top = 0.5
	_tab.anchor_bottom = 0.5
	_tab.offset_left = PANEL_W
	_tab.offset_right = PANEL_W + TAB_W
	_tab.offset_top = -TAB_H * 0.5
	_tab.offset_bottom = TAB_H * 0.5
	var bg := Color(0.06, 0.085, 0.12, 0.92)
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		var sb := S.box(bg.lightened(0.08) if st == "hover" else bg, [0, 10, 10, 0], S.EDGE, 0, Vector4(0, 0, 0, 0))
		sb.border_width_right = 1
		sb.border_width_top = 1
		sb.border_width_bottom = 1
		_tab.add_theme_stylebox_override(st, sb)
	_tab.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_tab_icon = W.Icon.new("chevron_right", S.GOLD, 16.0)
	_tab_icon.position = Vector2(2, TAB_H * 0.5 - 8.0)
	_tab.add_child(_tab_icon)
	_tab.pressed.connect(func() -> void:
		if is_open:
			close()
		elif ctx == null or not ctx.is_modal() or ctx.has_modal(&"chat"):
			open())
	_drawer.add_child(_tab)
	_badge = PanelContainer.new()
	_badge.name = "Unread"
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bsb := S.box(S.BADGE_RED, 9, Color(1, 1, 1, 0.85), 2, Vector4(5, 0, 5, 1))
	bsb.shadow_color = Color(0, 0, 0, 0.35)
	bsb.shadow_size = 3
	_badge.add_theme_stylebox_override("panel", bsb)
	_badge.position = Vector2(9, -10)
	_badge.custom_minimum_size = Vector2(20, 20)
	_badge_label = S.label("0", S.display_font(), 12, Color.WHITE)
	_badge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_badge.add_child(_badge_label)
	_badge.visible = false
	_tab.add_child(_badge)


## A small filled circle texture (the district tab's mayor-colour chip).
func _dot_texture(c: Color) -> Texture2D:
	var key := c.to_html()
	if _dots.has(key):
		return _dots[key]
	var img := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	for y in range(12):
		for x in range(12):
			var d := Vector2(x + 0.5 - 6.0, y + 0.5 - 6.0).length()
			img.set_pixel(x, y, Color(c, clampf(5.2 - d, 0.0, 1.0)))
	var tex := ImageTexture.create_from_image(img)
	_dots[key] = tex
	return tex
