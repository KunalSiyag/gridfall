extends RefCounted
## Look of the chat panel and the talk dialogue (slice C): palette, fonts, style boxes, vector
## icons drawn in code (the project fonts carry no arrow or emoji glyphs) and the small custom
## controls' drawing helpers (chat_panel_widgets.gd holds the controls). Every control made here is
## passive (MOUSE_FILTER_IGNORE) unless the caller changes it.

const D := preload("res://scripts/sim/sim_defs.gd")
const T := preload("res://scripts/fp/chat/chat_text.gd")
const DISPLAY_FONT_PATH := "res://fonts/lilita_one_regular.ttf"

const PANEL_BG := Color(0.047, 0.066, 0.094, 0.9)
const HEADER_BG := Color(0.075, 0.1, 0.137, 0.96)
const INPUT_BG := Color(0.035, 0.05, 0.072, 0.97)
const EDGE := Color(1, 1, 1, 0.075)
const TEXT := Color("#E8EEF5")
const TEXT_DIM := Color("#9AA9BA")
const TEXT_FAINT := Color("#6C7C90")
const GOLD := Color("#FFC24A")
const PIN_BLUE := Color("#4C9BFF")
const BADGE_RED := Color("#E5484D")
const ROLE_COLORS := {
	"resident": Color("#DDE6F0"), "press": Color("#FFD27F"), "council": Color("#C9B6FF"), "player": Color("#5CFF9D"),
}
## [background, accent, title] per system card kind.
const CARDS := {
	"alert": [Color(0.4, 0.075, 0.07, 0.86), Color("#FF6B57"), "BREAKING"],
	"incident": [Color(0.36, 0.22, 0.04, 0.84), Color("#FFB547"), "INCIDENT"],
	"opened": [Color(0.06, 0.27, 0.15, 0.84), Color("#5CE08A"), "NOW OPEN"],
	"people": [Color(0.11, 0.17, 0.25, 0.84), Color("#8FB8E8"), "NEIGHBOURS"],
	"notice": [Color(0.05, 0.22, 0.26, 0.84), Color("#6FD6E8"), "GRID"],
	"log": [Color(0.13, 0.15, 0.19, 0.84), Color("#C9D2DE"), "CITY"],
	"status": [Color(0.15, 0.12, 0.26, 0.84), Color("#B9A4FF"), "CHAT"],
}
const CARD_ICONS := {"alert": "alert", "incident": "fire", "opened": "door", "people": "person", "notice": "bolt", "log": "coin", "status": "chat"}

static var _display: Font
static var _body: Font
static var _italic: FontVariation
static var _bold: FontVariation


## Lilita One: names, titles, badges, buttons.
static func display_font() -> Font:
	if _display == null:
		_display = load(DISPLAY_FONT_PATH) if ResourceLoader.exists(DISPLAY_FONT_PATH) else ThemeDB.fallback_font
	return _display


## The clean body font (the engine's Open Sans SemiBold).
static func body_font() -> Font:
	if _body == null:
		_body = ThemeDB.fallback_font
	return _body


## A slanted body font for editorials and the player's previous line.
static func italic_font() -> Font:
	if _italic == null:
		_italic = FontVariation.new()
		_italic.base_font = body_font()
		_italic.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.2, 1), Vector2.ZERO)
	return _italic


## A heavier body font for emphasis.
static func bold_font() -> Font:
	if _bold == null:
		_bold = FontVariation.new()
		_bold.base_font = body_font()
		_bold.variation_embolden = 0.55
	return _bold


## The name colour for a message: mayors use their mayor colour, the rest ROLE_COLORS.
static func role_color(role: String, district: int) -> Color:
	if role == "mayor" and district >= 0 and district < D.MAYORS.size():
		return Color(str(D.MAYORS[district]["color"]))
	return ROLE_COLORS.get(role, TEXT)


## The avatar fill: SHIRTS[hash(author_id)] for residents, mayor colour, press gold, player green.
static func avatar_color(author_id: String, role: String, district: int) -> Color:
	match role:
		"mayor":
			return role_color(role, district)
		"press":
			return Color("#E8B64C")
		"council":
			return Color("#8A72D8")
		"player":
			return Color("#3FD27F")
	return ResidentAvatars.SHIRTS[T.h(author_id) % ResidentAvatars.SHIRTS.size()]


## The mayor colour of district d (grey outside the five districts).
static func district_color(d: int) -> Color:
	return Color(str(D.MAYORS[d]["color"])) if d >= 0 and d < D.MAYORS.size() else Color(0.45, 0.5, 0.58)


## Dark or white text, whichever reads on bg.
static func ink_on(bg: Color) -> Color:
	return Color(0.05, 0.07, 0.1) if bg.get_luminance() > 0.55 else Color.WHITE


## A flat style box. radius: one value or [tl, tr, br, bl].
static func box(bg: Color, radius: Variant = 10, border: Color = Color(0, 0, 0, 0), border_w: int = 0, pad: Vector4 = Vector4(10, 8, 10, 8)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	if typeof(radius) == TYPE_ARRAY:
		var r: Array = radius
		sb.corner_radius_top_left = int(r[0])
		sb.corner_radius_top_right = int(r[1])
		sb.corner_radius_bottom_right = int(r[2])
		sb.corner_radius_bottom_left = int(r[3])
	else:
		sb.set_corner_radius_all(int(radius))
	sb.corner_detail = 6
	if border_w > 0:
		sb.border_color = border
		sb.set_border_width_all(border_w)
	sb.content_margin_left = pad.x
	sb.content_margin_top = pad.y
	sb.content_margin_right = pad.z
	sb.content_margin_bottom = pad.w
	sb.anti_aliasing = true
	return sb


## Draws a round avatar into rect: soft shadow, darker rim, tinted disc, a top highlight and the
## initials (or an icon) in readable ink.
static func draw_avatar(ci: CanvasItem, rect: Rect2, fill: Color, initials: String, icon: String) -> void:
	var side := minf(rect.size.x, rect.size.y)
	var c := rect.position + rect.size * 0.5
	var r := side * 0.5
	ci.draw_circle(c + Vector2(0, 1.5), r, Color(0, 0, 0, 0.35), true, -1.0, true)
	ci.draw_circle(c, r, fill.darkened(0.28), true, -1.0, true)
	ci.draw_circle(c, r - 2.0, fill, true, -1.0, true)
	ci.draw_circle(c - Vector2(0, r * 0.32), r * 0.6, Color(1, 1, 1, 0.07), true, -1.0, true)
	ci.draw_arc(c, r - 0.5, 0.0, TAU, 48, Color(1, 1, 1, 0.2), 1.0, true)
	var ink := ink_on(fill)
	if not icon.is_empty():
		var k := side * 0.56
		draw_icon(ci, icon, Rect2(c - Vector2(k, k) * 0.5, Vector2(k, k)), ink)
		return
	var f := display_font()
	var fs := int(side * (0.42 if initials.length() > 1 else 0.5))
	var tw := f.get_string_size(initials, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var asc := f.get_ascent(fs)
	var dsc := f.get_descent(fs)
	ci.draw_string(f, Vector2(c.x - tw * 0.5, c.y + (asc - dsc) * 0.5), initials, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)


## A shaped single line of text (TextServer, no node).
static func text_line(text: String, font: Font, size: int) -> TextLine:
	var tl := TextLine.new()
	tl.add_string(text, font, size)
	return tl


## A shaped, word-wrapped paragraph of the given width.
static func text_para(text: String, font: Font, size: int, width: float) -> TextParagraph:
	var tp := TextParagraph.new()
	tp.add_string(text, font, size)
	tp.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	tp.width = width
	return tp


## A passive Label.
static func label(text: String, font: Font, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## A passive word-wrapping Label that fills the width.
static func wrap_label(text: String, font: Font, size: int, color: Color) -> Label:
	var l := label(text, font, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size.x = 1
	return l


## A pill button with the given colours.
static func pill_button(text: String, bg: Color, fg: Color, size: int = 13, font: Font = null) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_override("font", font if font != null else body_font())
	b.add_theme_font_size_override("font_size", size)
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, fg)
	b.add_theme_stylebox_override("normal", box(bg, 14, Color(1, 1, 1, 0.1), 1, Vector4(12, 5, 12, 5)))
	b.add_theme_stylebox_override("hover", box(bg.lightened(0.12), 14, Color(1, 1, 1, 0.22), 1, Vector4(12, 5, 12, 5)))
	b.add_theme_stylebox_override("pressed", box(bg.darkened(0.15), 14, Color(1, 1, 1, 0.22), 1, Vector4(12, 5, 12, 5)))
	b.add_theme_stylebox_override("hover_pressed", box(bg.darkened(0.1), 14, Color(1, 1, 1, 0.22), 1, Vector4(12, 5, 12, 5)))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


## Applies the dark pill look to a LineEdit.
static func style_line_edit(le: LineEdit, size: int = 14) -> void:
	le.add_theme_font_override("font", body_font())
	le.add_theme_font_size_override("font_size", size)
	le.add_theme_color_override("font_color", TEXT)
	le.add_theme_color_override("font_placeholder_color", Color(TEXT_DIM, 0.75))
	le.add_theme_color_override("caret_color", GOLD)
	le.add_theme_color_override("selection_color", Color(GOLD, 0.3))
	le.add_theme_stylebox_override("normal", box(Color(1, 1, 1, 0.065), 18, Color(1, 1, 1, 0.08), 1, Vector4(14, 7, 14, 7)))
	le.add_theme_stylebox_override("focus", box(Color(1, 1, 1, 0.0), 18, Color(GOLD, 0.7), 2, Vector4(14, 7, 14, 7)))
	le.add_theme_stylebox_override("read_only", box(Color(1, 1, 1, 0.04), 18, Color(1, 1, 1, 0.05), 1, Vector4(14, 7, 14, 7)))


## A thin translucent vertical scroll bar.
static func style_scroll(sc: ScrollContainer) -> void:
	var vb := sc.get_v_scroll_bar()
	vb.add_theme_stylebox_override("scroll", box(Color(0, 0, 0, 0), 3, Color(0, 0, 0, 0), 0, Vector4(2, 0, 2, 0)))
	vb.add_theme_stylebox_override("scroll_focus", box(Color(0, 0, 0, 0), 3, Color(0, 0, 0, 0), 0, Vector4(2, 0, 2, 0)))
	vb.add_theme_stylebox_override("grabber", box(Color(1, 1, 1, 0.16), 3, Color(0, 0, 0, 0), 0, Vector4(3, 0, 3, 0)))
	vb.add_theme_stylebox_override("grabber_highlight", box(Color(1, 1, 1, 0.3), 3, Color(0, 0, 0, 0), 0, Vector4(3, 0, 3, 0)))
	vb.add_theme_stylebox_override("grabber_pressed", box(Color(1, 1, 1, 0.38), 3, Color(0, 0, 0, 0), 0, Vector4(3, 0, 3, 0)))
	vb.custom_minimum_size.x = 6


## Draws a named vector icon into rect (unit-box shapes scaled to rect).
static func draw_icon(ci: CanvasItem, icon: String, rect: Rect2, col: Color) -> void:
	var o := rect.position
	var s := rect.size
	var p := func(x: float, y: float) -> Vector2: return o + Vector2(x * s.x, y * s.y)
	var w := maxf(1.5, s.x * 0.12)
	match icon:
		"fire":
			var outer := PackedVector2Array()
			for v: Vector2 in [Vector2(0.52, 0.04), Vector2(0.67, 0.22), Vector2(0.79, 0.41), Vector2(0.82, 0.6), Vector2(0.76, 0.78), Vector2(0.62, 0.91), Vector2(0.46, 0.94), Vector2(0.3, 0.87), Vector2(0.2, 0.71), Vector2(0.21, 0.52), Vector2(0.31, 0.36), Vector2(0.37, 0.5), Vector2(0.44, 0.33), Vector2(0.5, 0.18)]:
				outer.append(p.call(v.x, v.y))
			ci.draw_colored_polygon(outer, col)
			var inner := PackedVector2Array()
			for v: Vector2 in [Vector2(0.53, 0.44), Vector2(0.64, 0.6), Vector2(0.65, 0.74), Vector2(0.56, 0.85), Vector2(0.44, 0.85), Vector2(0.37, 0.75), Vector2(0.4, 0.62), Vector2(0.46, 0.68)]:
				inner.append(p.call(v.x, v.y))
			ci.draw_colored_polygon(inner, Color(1, 0.95, 0.75, 0.9))
		"alert":
			var tri := PackedVector2Array([p.call(0.5, 0.06), p.call(0.96, 0.9), p.call(0.04, 0.9)])
			ci.draw_colored_polygon(tri, col)
			var ink := Color(0.12, 0.03, 0.02)
			ci.draw_line(p.call(0.5, 0.36), p.call(0.5, 0.62), ink, maxf(2.0, s.x * 0.11), true)
			ci.draw_circle(p.call(0.5, 0.76), maxf(1.2, s.x * 0.065), ink)
		"door":
			ci.draw_rect(Rect2(p.call(0.22, 0.1), Vector2(s.x * 0.56, s.y * 0.84)), col, false, maxf(1.5, s.x * 0.08))
			var leaf := PackedVector2Array([p.call(0.22, 0.1), p.call(0.6, 0.2), p.call(0.6, 0.98), p.call(0.22, 0.94)])
			ci.draw_colored_polygon(leaf, col)
			ci.draw_circle(p.call(0.52, 0.56), maxf(1.0, s.x * 0.05), Color(0, 0, 0, 0.6))
		"news":
			ci.draw_rect(Rect2(p.call(0.1, 0.16), Vector2(s.x * 0.8, s.y * 0.68)), Color(col, 0.22))
			ci.draw_rect(Rect2(p.call(0.1, 0.16), Vector2(s.x * 0.8, s.y * 0.68)), col, false, maxf(1.2, s.x * 0.07))
			ci.draw_rect(Rect2(p.call(0.2, 0.27), Vector2(s.x * 0.6, s.y * 0.12)), col)
			ci.draw_rect(Rect2(p.call(0.2, 0.47), Vector2(s.x * 0.24, s.y * 0.24)), col)
			for y in [0.5, 0.6, 0.7]:
				ci.draw_line(p.call(0.5, y), p.call(0.8, y), col, maxf(1.0, s.x * 0.05))
		"person":
			ci.draw_circle(p.call(0.5, 0.32), s.x * 0.17, col)
			var body := PackedVector2Array()
			for k in range(13):
				var a := PI + PI * float(k) / 12.0
				body.append(p.call(0.5 + 0.32 * cos(a), 0.92 + 0.36 * sin(a)))
			ci.draw_colored_polygon(body, col)
		"bolt":
			var b := PackedVector2Array([p.call(0.6, 0.04), p.call(0.22, 0.56), p.call(0.47, 0.56), p.call(0.38, 0.96), p.call(0.8, 0.4), p.call(0.54, 0.4)])
			ci.draw_colored_polygon(b, col)
		"coin":
			ci.draw_circle(p.call(0.5, 0.5), s.x * 0.4, col)
			ci.draw_circle(p.call(0.5, 0.5), s.x * 0.27, Color(0, 0, 0, 0.25))
			ci.draw_line(p.call(0.5, 0.3), p.call(0.5, 0.7), col.lightened(0.3), maxf(1.2, s.x * 0.08))
		"pin":
			ci.draw_set_transform(o + s * 0.5, 0.5, Vector2.ONE)
			var q := func(x: float, y: float) -> Vector2: return Vector2((x - 0.5) * s.x, (y - 0.5) * s.y)
			ci.draw_colored_polygon(PackedVector2Array([q.call(0.32, 0.06), q.call(0.68, 0.06), q.call(0.62, 0.42), q.call(0.38, 0.42)]), col)
			ci.draw_colored_polygon(PackedVector2Array([q.call(0.2, 0.42), q.call(0.8, 0.42), q.call(0.8, 0.54), q.call(0.2, 0.54)]), col)
			ci.draw_line(q.call(0.5, 0.54), q.call(0.5, 0.98), col, maxf(1.2, s.x * 0.08), true)
			ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		"chevron_right", "chevron_left", "chevron_down", "chevron_up":
			var pts: Array = {
				"chevron_right": [Vector2(0.38, 0.2), Vector2(0.66, 0.5), Vector2(0.38, 0.8)],
				"chevron_left": [Vector2(0.62, 0.2), Vector2(0.34, 0.5), Vector2(0.62, 0.8)],
				"chevron_down": [Vector2(0.2, 0.38), Vector2(0.5, 0.66), Vector2(0.8, 0.38)],
				"chevron_up": [Vector2(0.2, 0.62), Vector2(0.5, 0.34), Vector2(0.8, 0.62)],
			}[icon]
			var pl := PackedVector2Array()
			for v: Vector2 in pts:
				pl.append(p.call(v.x, v.y))
			ci.draw_polyline(pl, col, w * 1.1, true)
		"arrow_down":
			ci.draw_line(p.call(0.5, 0.14), p.call(0.5, 0.8), col, w, true)
			ci.draw_polyline(PackedVector2Array([p.call(0.24, 0.56), p.call(0.5, 0.84), p.call(0.76, 0.56)]), col, w, true)
		"reply":
			ci.draw_polyline(PackedVector2Array([p.call(0.18, 0.12), p.call(0.18, 0.44), p.call(0.24, 0.58), p.call(0.38, 0.64), p.call(0.8, 0.64)]), col, w, true)
			ci.draw_polyline(PackedVector2Array([p.call(0.62, 0.44), p.call(0.82, 0.64), p.call(0.62, 0.84)]), col, w, true)
		"send":
			ci.draw_colored_polygon(PackedVector2Array([p.call(0.12, 0.16), p.call(0.9, 0.5), p.call(0.12, 0.84), p.call(0.25, 0.5)]), col)
			ci.draw_line(p.call(0.25, 0.5), p.call(0.55, 0.5), Color(0, 0, 0, 0.35), maxf(1.0, s.x * 0.06), true)
		"location":
			ci.draw_circle(p.call(0.5, 0.38), s.x * 0.3, col)
			ci.draw_colored_polygon(PackedVector2Array([p.call(0.24, 0.5), p.call(0.76, 0.5), p.call(0.5, 0.96)]), col)
			ci.draw_circle(p.call(0.5, 0.38), s.x * 0.12, Color(0, 0, 0, 0.55))
		"chat":
			ci.draw_rect(Rect2(p.call(0.1, 0.14), Vector2(s.x * 0.8, s.y * 0.56)), col)
			ci.draw_colored_polygon(PackedVector2Array([p.call(0.24, 0.66), p.call(0.48, 0.66), p.call(0.24, 0.9)]), col)
		"drop":
			var pts := PackedVector2Array()
			pts.append(p.call(0.5, 0.06))
			for k in range(17):
				var ang := PI * 0.15 - PI * 1.3 * float(k) / 16.0
				pts.append(p.call(0.5 + 0.3 * cos(ang), 0.62 + 0.3 * sin(-ang)))
			ci.draw_colored_polygon(pts, col)
			ci.draw_arc(p.call(0.5, 0.64), s.x * 0.17, PI * 0.55, PI * 0.95, 8, Color(1, 1, 1, 0.55), maxf(1.2, s.x * 0.06), true)
		"wrench":
			var a0: Vector2 = p.call(0.24, 0.76)
			var a1: Vector2 = p.call(0.62, 0.38)
			ci.draw_line(a0, a1, col, maxf(2.5, s.x * 0.17), true)
			ci.draw_circle(a0, s.x * 0.1, col, true, -1.0, true)
			ci.draw_arc(p.call(0.68, 0.32), s.x * 0.2, -PI * 0.15, PI * 1.35, 16, col, maxf(2.0, s.x * 0.13), true)
		"close":
			ci.draw_line(p.call(0.24, 0.24), p.call(0.76, 0.76), col, w, true)
			ci.draw_line(p.call(0.76, 0.24), p.call(0.24, 0.76), col, w, true)
		"check":
			ci.draw_polyline(PackedVector2Array([p.call(0.18, 0.52), p.call(0.42, 0.76), p.call(0.84, 0.26)]), col, w * 1.2, true)
		"help":
			ci.draw_arc(p.call(0.5, 0.5), s.x * 0.42, 0.0, TAU, 32, col, maxf(1.2, s.x * 0.08), true)
			ci.draw_arc(p.call(0.5, 0.4), s.x * 0.14, PI * 1.05, PI * 2.25, 12, col, maxf(1.4, s.x * 0.09), true)
			ci.draw_line(p.call(0.53, 0.5), p.call(0.5, 0.6), col, maxf(1.4, s.x * 0.09), true)
			ci.draw_circle(p.call(0.5, 0.73), maxf(1.0, s.x * 0.055), col)


## Mood 0-10 to a colour: red, amber, yellow-green, green.
static func mood_color(m: float) -> Color:
	if m >= 7.0:
		return Color("#5CE08A")
	if m >= 5.0:
		return Color("#E8D25A")
	if m >= 3.0:
		return Color("#FFA24A")
	return Color("#FF6B57")


## A word for a 0-10 mood.
static func mood_word(m: float) -> String:
	if m >= 8.5:
		return "Thriving"
	if m >= 7.0:
		return "Content"
	if m >= 5.0:
		return "Getting by"
	if m >= 3.0:
		return "Stressed"
	return "Miserable"
