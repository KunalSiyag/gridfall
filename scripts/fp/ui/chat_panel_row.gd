extends Control
## One chat message drawn as a single Control (slice C §2): a resident, mayor, press, council or
## player row (round avatar, role-coloured name, role tag and district chips, job, relative time,
## reply arrow with a quote of the parent, word-wrapped text in a speech bubble) or a full-width
## system card (tinted, accent rim, icon, title, time, text). Text is shaped once with TextServer
## lines; a width change reflows the paragraph, a time refresh redraws only the time.

const S := preload("res://scripts/fp/ui/chat_panel_style.gd")
const T := preload("res://scripts/fp/chat/chat_text.gd")

const PAD_L := 10.0
const PAD_R := 12.0
const AV := 34.0
const GAP := 8.0
const IN_L := 10.0
const IN_R := 10.0
const IN_T := 6.0
const IN_B := 7.0
const HEAD_H := 20.0
## Baseline of the header line (name, job, time) below the bubble's inner top.
const HEAD_BASE := 15.0
const REPLY_H := 17.0
const CHIP_H := 15.0
const CARD_ICON := 22.0
const ROLE_TAGS := {"mayor": "MAYOR", "press": "PRESS", "council": "COUNCIL"}
## Card icon per incident type (refs.type).
const INCIDENT_ICONS := {
	"fire": "fire", "blackout": "bolt", "power_line": "bolt", "sewage_burst": "drop", "water_main": "drop",
	"flood": "drop", "gridlock": "alert", "car_crash": "alert", "smog": "alert", "earthquake": "alert", "tornado": "alert",
}

static var _cache: Dictionary = {}

## The message this row shows.
var msg: Dictionary = {}
## Feed time the message was shown (for the relative time).
var t_ms: int = 0
## District used by the District tab (-1: city-wide).
var district: int = -1

var _card: bool = false
var _name: TextLine
var _name_col: Color = Color.WHITE
var _job: TextLine
var _time: TextLine
var _chips: Array[Dictionary] = []
var _reply_name: TextLine
var _reply_quote: TextLine
var _text: TextParagraph
var _text_col: Color = Color.WHITE
var _title: TextLine
var _accent: Color = Color.WHITE
var _icon: String = ""
var _box: StyleBox
var _avatar_fill: Color = Color.GRAY
var _initials: String = ""
var _avatar_icon: String = ""
var _laid_w: float = -1.0


## Shapes msg for width w. parent: {"author", "text"} of the message it replies to, or {}.
## row_district: the district the District tab files it under.
func setup(p_msg: Dictionary, parent: Dictionary, w: float, time_text: String, row_district: int) -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	district = row_district
	_shape(p_msg, parent, time_text)
	_layout(w)


## Replaces the message in place (the Breaking card replacing its incident card).
func set_msg(p_msg: Dictionary, parent: Dictionary, time_text: String) -> void:
	_shape(p_msg, parent, time_text)
	_layout(size.x if size.x > 0.0 else _laid_w)


## Refreshes the relative time (the only thing that changes after a row is shown).
func set_time(time_text: String) -> void:
	_time = S.text_line(time_text, S.body_font(), 11)
	queue_redraw()


## The visible text (tests and tooltips).
func text() -> String:
	return str(msg.get("text", ""))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and size.x > 0.0 and absf(size.x - _laid_w) > 0.5:
		_layout(size.x)


func _shape(p_msg: Dictionary, parent: Dictionary, time_text: String) -> void:
	msg = p_msg
	t_ms = int(msg.get("t_ms", 0))
	tooltip_text = "Day %d  ·  %s" % [int(msg.get("day", 0)), str(msg.get("clock", ""))]
	var role := str(msg.get("role", "resident"))
	var d := int(msg.get("district", -1))
	var kind := str(msg.get("kind", ""))
	var refs: Dictionary = msg.get("refs", {})
	_card = role == "system"
	_time = S.text_line(time_text, S.body_font(), 11)
	_chips.clear()
	_reply_name = null
	_reply_quote = null
	_job = null
	var body := str(msg.get("text", ""))
	if _card:
		var spec: Array = S.CARDS.get(kind, S.CARDS["log"])
		var bg: Color = spec[0]
		_accent = spec[1]
		_icon = S.CARD_ICONS.get(kind, "coin")
		var title := str(spec[2])
		var phase := str(refs.get("phase", ""))
		if kind in ["incident", "alert"]:
			_icon = INCIDENT_ICONS.get(str(refs.get("type", "")), _icon)
		if kind == "incident" and phase == "ended":
			bg = S.CARDS["opened"][0]
			_accent = S.CARDS["opened"][1]
			_icon = "wrench"
			title = "ALL CLEAR"
		elif kind == "people":
			title = "MOVED AWAY" if phase == "left" else "NEW NEIGHBOUR"
		if kind == "alert" and body.begins_with("Breaking: "):
			body = body.substr(10)
		_title = S.text_line(title, S.display_font(), 12)
		_box = _card_style(bg, _accent)
		_text = S.text_para(body, S.bold_font() if kind == "alert" else S.body_font(), 14, 100.0)
		_text_col = S.TEXT
		return
	var author := str(msg.get("author", ""))
	_name_col = S.role_color(role, d)
	_name = S.text_line(author, S.display_font(), 15)
	_avatar_fill = S.avatar_color(str(msg.get("author_id", "")), role, d)
	_initials = T.initials(author)
	_avatar_icon = "news" if role == "press" else ("person" if role == "player" else "")
	if ROLE_TAGS.has(role):
		_chips.append({"line": S.text_line(str(ROLE_TAGS[role]), S.display_font(), 10), "box": _chip_style(Color(0, 0, 0, 0), _name_col, true), "fg": _name_col})
	var badge := T.district_badge(d)
	if not badge.is_empty() and role not in ["press", "council"]:
		var dc := S.district_color(d)
		_chips.append({"line": S.text_line(badge, S.display_font(), 10), "box": _chip_style(dc, dc, false), "fg": S.ink_on(dc)})
	var job := str(refs.get("job", ""))
	if role == "resident" and not job.is_empty():
		_job = S.text_line(job, S.body_font(), 12)
		_job.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if not parent.is_empty():
		_reply_name = S.text_line(str(parent.get("author", "")), S.bold_font(), 12)
		_reply_quote = S.text_line(T.clip(str(parent.get("text", "")), 60), S.body_font(), 12)
		_reply_quote.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_box = _bubble_style(role, d)
	_text = S.text_para(body, S.italic_font() if kind == "letter" else S.body_font(), 14, 100.0)
	_text_col = Color("#FFF3DA") if role == "press" else S.TEXT


func _layout(w: float) -> void:
	if w <= 0.0:
		return
	_laid_w = w
	var h := 0.0
	if _card:
		_text.width = maxf(40.0, w - PAD_L - PAD_R - 10.0 - CARD_ICON - 10.0 - 10.0)
		h = 4.0 + 7.0 + 17.0 + _text.get_size().y + 8.0 + 4.0
	else:
		_text.width = maxf(40.0, w - (PAD_L + AV + GAP) - PAD_R - IN_L - IN_R)
		h = 3.0 + IN_T + HEAD_H + (REPLY_H if _reply_name != null else 0.0) + 1.0 + _text.get_size().y + IN_B + 3.0
		h = maxf(h, AV + 6.0)
	h = ceilf(h)
	if not is_equal_approx(custom_minimum_size.y, h):
		custom_minimum_size = Vector2(0, h)
	queue_redraw()


func _draw() -> void:
	var ci := get_canvas_item()
	if _card:
		var r := Rect2(PAD_L, 4.0, size.x - PAD_L - PAD_R, size.y - 8.0)
		draw_style_box(_box, r)
		S.draw_icon(self, _icon, Rect2(r.position.x + 10.0, r.position.y + 8.0, CARD_ICON, CARD_ICON), _accent)
		var tx := r.position.x + 10.0 + CARD_ICON + 10.0
		var tb := r.position.y + 7.0 + _title.get_line_ascent()
		_title.draw(ci, Vector2(tx, r.position.y + 7.0), _accent)
		_time.draw(ci, Vector2(r.end.x - 10.0 - _time.get_size().x, tb - _time.get_line_ascent()), S.TEXT_FAINT)
		_text.draw(ci, Vector2(tx, r.position.y + 7.0 + 17.0), _text_col)
		return
	S.draw_avatar(self, Rect2(PAD_L, 3.0, AV, AV), _avatar_fill, _initials, _avatar_icon)
	var x0 := PAD_L + AV + GAP
	var bw := size.x - x0 - PAD_R
	draw_style_box(_box, Rect2(x0, 3.0, bw, size.y - 6.0))
	var cx := x0 + IN_L
	var cy := 3.0 + IN_T
	var right := x0 + bw - IN_R
	var base := cy + HEAD_BASE
	var name_sz := _name.get_size()
	_name.draw(ci, Vector2(cx, base - _name.get_line_ascent()), _name_col)
	var x := cx + name_sz.x + 6.0
	for c: Dictionary in _chips:
		var line: TextLine = c["line"]
		var lsz := line.get_size()
		var cw := lsz.x + 10.0
		var cr := Rect2(x, cy + (HEAD_H - CHIP_H) * 0.5, cw, CHIP_H)
		draw_style_box(c["box"], cr)
		line.draw(ci, Vector2(x + 5.0, cr.position.y + (CHIP_H - lsz.y) * 0.5), c["fg"])
		x += cw + 5.0
	var tsz := _time.get_size()
	_time.draw(ci, Vector2(right - tsz.x, base - _time.get_line_ascent()), S.TEXT_FAINT)
	if _job != null:
		var avail := right - tsz.x - 8.0 - x
		if avail > 24.0:
			_job.width = avail
			_job.draw(ci, Vector2(x, base - _job.get_line_ascent()), S.TEXT_FAINT)
	cy += HEAD_H
	if _reply_name != null:
		S.draw_icon(self, "reply", Rect2(cx, cy + 2.0, 12.0, 12.0), S.TEXT_FAINT)
		var rn := _reply_name.get_size()
		_reply_name.draw(ci, Vector2(cx + 16.0, cy + (REPLY_H - rn.y) * 0.5), S.TEXT_DIM)
		var qx := cx + 16.0 + rn.x + 6.0
		var qavail := right - qx
		if qavail > 24.0:
			_reply_quote.width = qavail
			_reply_quote.draw(ci, Vector2(qx, cy + (REPLY_H - _reply_quote.get_size().y) * 0.5), S.TEXT_FAINT)
		cy += REPLY_H
	_text.draw(ci, Vector2(cx, cy + 1.0), _text_col)


func _chip_style(bg: Color, fg: Color, outline: bool) -> StyleBox:
	var key := "chip|%s|%s|%s" % [bg.to_html(), fg.to_html(), outline]
	if not _cache.has(key):
		_cache[key] = S.box(bg, 5, Color(fg, 0.8) if outline else Color(0, 0, 0, 0), 1 if outline else 0, Vector4(0, 0, 0, 0))
	return _cache[key]


func _bubble_style(role: String, d: int) -> StyleBox:
	var key := "bubble|%s|%d" % [role, d if role == "mayor" else -1]
	if _cache.has(key):
		return _cache[key]
	var bg := Color(1, 1, 1, 0.05)
	var border := Color(0, 0, 0, 0)
	match role:
		"player":
			bg = Color(0.36, 1.0, 0.62, 0.09)
			border = Color(0.36, 1.0, 0.62, 0.45)
		"mayor":
			var mc := S.district_color(d)
			bg = Color(mc.r, mc.g, mc.b, 0.14)
			border = Color(mc, 0.9)
		"press":
			bg = Color(1.0, 0.78, 0.35, 0.11)
			border = Color(1.0, 0.82, 0.5, 0.75)
		"council":
			bg = Color(0.79, 0.71, 1.0, 0.11)
			border = Color(0.79, 0.71, 1.0, 0.75)
	var sb := S.box(bg, [4, 14, 14, 14], Color(0, 0, 0, 0), 0, Vector4(0, 0, 0, 0))
	if border.a > 0.0:
		sb.border_color = border
		sb.border_width_left = 2
	_cache[key] = sb
	return sb


func _card_style(bg: Color, accent: Color) -> StyleBox:
	var key := "card|%s" % bg.to_html()
	if _cache.has(key):
		return _cache[key]
	var sb := S.box(bg, 10, Color(accent, 0.95), 0, Vector4(0, 0, 0, 0))
	sb.border_width_left = 3
	sb.shadow_color = Color(0, 0, 0, 0.25)
	sb.shadow_size = 3
	sb.shadow_offset = Vector2(0, 1)
	_cache[key] = sb
	return sb
