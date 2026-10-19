extends RefCounted
## Shared look of the on-foot HUD (slice B): colour tokens, fonts with tabular figures, and the
## widget helpers (restyled from city_hud.gd's _panel, _label and _fmt). Preload as S.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")

## Every Label, RichTextLabel and Button slice B creates carries this meta (the branding test reads it).
const OWNER_META := "fp_owner"
const OWNER := "hud_widgets"

const WHITE := Color(1, 1, 1)
const TEXT := Color(0.96, 0.97, 0.99)
const TEXT_DIM := Color(0.86, 0.9, 0.96, 0.66)
const TEXT_FAINT := Color(0.86, 0.9, 0.96, 0.42)
const AMBER := Color("#FFB547")
const RED := Color("#FF5A5A")
const ACCENT := Color("#00E0FF")
const GOOD := Color("#7CE0A3")
## Chip backing: the most a passive indicator may have (B contract, deliverable 1).
const CHIP_BG := Color(0.04, 0.05, 0.08, 0.35)
## Panels that hold controls (pause menu, place card, map).
const PANEL_BG := Color(0.055, 0.07, 0.11, 0.78)
const PANEL_LINE := Color(1, 1, 1, 0.08)
const OUTLINE := Color(0.01, 0.02, 0.04, 0.62)
const SHADOW := Color(0, 0, 0, 0.45)
const BRAND_RE := "(?i)(Argon|DeepSeek|Kimi|Qwen|Grok|GMI|gemini|MiniMax|model|latency|cache|heuristic)"
const TITLE_FONT_PATH := "res://fonts/lilita_one_regular.ttf"

static var _font: FontVariation
static var _bold: FontVariation
static var _caps: FontVariation
static var _title: Font


## The UI font (the project's fallback sans) with tabular figures, so numbers do not jitter.
static func font() -> Font:
	if _font == null:
		_font = FontVariation.new()
		_font.base_font = ThemeDB.fallback_font
		_font.opentype_features = {_tag("tnum"): 1, _tag("lnum"): 1}
	return _font


## A heavier cut of font() for values and titles.
static func bold() -> Font:
	if _bold == null:
		_bold = FontVariation.new()
		_bold.base_font = ThemeDB.fallback_font
		_bold.opentype_features = {_tag("tnum"): 1, _tag("lnum"): 1}
		_bold.variation_embolden = 0.55
	return _bold


## Tracked capitals for small headings ("SETTINGS", "CAMERA").
static func caps() -> Font:
	if _caps == null:
		_caps = FontVariation.new()
		_caps.base_font = ThemeDB.fallback_font
		_caps.variation_embolden = 0.35
		_caps.spacing_glyph = 2
	return _caps


## The game's display face (pause title only).
static func title() -> Font:
	if _title == null:
		_title = load(TITLE_FONT_PATH) if ResourceLoader.exists(TITLE_FONT_PATH) else bold()
	return _title


## Marks n as created by slice B (meta OWNER_META), for the branding test and smoke.
static func own(n: Node) -> Node:
	n.set_meta(OWNER_META, OWNER)
	return n


## A passive label: B's font, an outline and a soft shadow so it reads on sky and asphalt.
static func label(t: String, size_px: int, col: Color = TEXT, f: Font = null, outline: int = 3) -> Label:
	var l := Label.new()
	l.text = t
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", f if f != null else font())
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", col)
	if outline > 0:
		l.add_theme_constant_override("outline_size", outline)
		l.add_theme_color_override("font_outline_color", OUTLINE)
	l.add_theme_color_override("font_shadow_color", SHADOW)
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 1)
	own(l)
	return l


## A label for text inside a solid panel (no outline needed).
static func plain(t: String, size_px: int, col: Color = TEXT, f: Font = null) -> Label:
	var l := label(t, size_px, col, f, 0)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	return l


## A StyleBoxFlat with one corner radius and content margins (h, v).
static func box(bg: Color, radius: int, h: int, v: int, border: Color = Color(0, 0, 0, 0), bw: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = h
	sb.content_margin_right = h
	sb.content_margin_top = v
	sb.content_margin_bottom = v
	if bw > 0:
		sb.border_color = border
		sb.set_border_width_all(bw)
	sb.anti_aliasing = true
	return sb


## The pill behind a passive indicator chip: at most CHIP_BG, fully rounded (own instance, so a
## chip can pulse its own backing).
static func chip_box(h: int = 11, v: int = 4) -> StyleBoxFlat:
	var sb := box(CHIP_BG, 15, h, v)
	sb.corner_detail = 10
	return sb


## A PanelContainer with a rounded, optionally bordered background (restyled CityHud._panel).
static func panel(bg: Color = PANEL_BG, radius: int = 10, h: int = 14, v: int = 10, border: Color = PANEL_LINE) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := box(bg, radius, h, v, border, 1 if border.a > 0.0 else 0)
	sb.shadow_color = Color(0, 0, 0, 0.28)
	sb.shadow_size = 10
	p.add_theme_stylebox_override("panel", sb)
	return p


## A menu button: flat text on idle, a light bar when focused or hovered.
static func menu_button(t: String, size_px: int = 19) -> Button:
	var b := Button.new()
	b.text = t
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.add_theme_font_override("font", bold())
	b.add_theme_font_size_override("font_size", size_px)
	b.add_theme_color_override("font_color", Color(1, 1, 1, 0.78))
	b.add_theme_color_override("font_hover_color", WHITE)
	b.add_theme_color_override("font_focus_color", Color(0.04, 0.05, 0.08))
	b.add_theme_color_override("font_pressed_color", Color(0.04, 0.05, 0.08))
	b.add_theme_color_override("font_hover_pressed_color", Color(0.04, 0.05, 0.08))
	var idle := box(Color(1, 1, 1, 0.0), 6, 16, 9)
	var hover := box(Color(1, 1, 1, 0.1), 6, 16, 9)
	var focus := box(Color(1, 1, 1, 0.92), 6, 16, 9)
	b.add_theme_stylebox_override("normal", idle)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", focus)
	b.add_theme_stylebox_override("hover_pressed", focus)
	b.add_theme_stylebox_override("focus", focus)
	own(b)
	return b


## A compact pill button (card actions, segmented choices).
static func pill_button(t: String, size_px: int = 15) -> Button:
	var b := Button.new()
	b.text = t
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.add_theme_font_override("font", bold())
	b.add_theme_font_size_override("font_size", size_px)
	b.add_theme_color_override("font_color", Color(1, 1, 1, 0.72))
	b.add_theme_color_override("font_hover_color", WHITE)
	b.add_theme_color_override("font_pressed_color", Color(0.04, 0.05, 0.08))
	b.add_theme_color_override("font_hover_pressed_color", Color(0.04, 0.05, 0.08))
	b.add_theme_color_override("font_focus_color", WHITE)
	b.add_theme_stylebox_override("normal", box(Color(1, 1, 1, 0.06), 6, 12, 6, Color(1, 1, 1, 0.12), 1))
	b.add_theme_stylebox_override("hover", box(Color(1, 1, 1, 0.14), 6, 12, 6, Color(1, 1, 1, 0.2), 1))
	b.add_theme_stylebox_override("pressed", box(Color(1, 1, 1, 0.92), 6, 12, 6))
	b.add_theme_stylebox_override("hover_pressed", box(Color(1, 1, 1, 0.92), 6, 12, 6))
	b.add_theme_stylebox_override("focus", box(Color(0, 0, 0, 0), 6, 12, 6, Color(1, 1, 1, 0.85), 2))
	own(b)
	return b


## A key cap ("E", "M", "Esc") for prompts and hints.
static func key_cap(k: String, size_px: int = 13) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := box(Color(1, 1, 1, 0.92), 4, 6, 1)
	sb.content_margin_left = 6 if k.length() == 1 else 7
	sb.content_margin_right = sb.content_margin_left
	p.add_theme_stylebox_override("panel", sb)
	var l := plain(k, size_px, Color(0.05, 0.06, 0.09), bold())
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(maxf(0.0, size_px * 0.62), 0)
	p.add_child(l)
	return p


## Thousands separators: 1168 -> "1,168", -3222 -> "−3,222" (true minus sign). Restyled CityHud._fmt.
static func fmt(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("−" if n < 0 else "") + s + out


## Compact money: "$950", "$3.2k", "$124k", "$1.2M"; a deficit stays exact so it reads at a glance
## ("−$3,222", true minus sign) until it passes 100k ("−$124k").
static func money(n: int) -> String:
	var a := absi(n)
	if n < 0 and a < 100000:
		return "−$" + fmt(a)
	var s := ""
	if a >= 999500:
		s = "$%.1fM" % (a / 1000000.0)
	elif a >= 99950:
		s = "$%dk" % int(round(a / 1000.0))
	elif a >= 1000:
		s = "$%.1fk" % (a / 1000.0)
	else:
		s = "$" + fmt(a)
	return ("−" if n < 0 else "") + s


## Distance in metres from world units: "8 m", "45 m" (5 m steps from 20 m), "1.2 km".
static func distance(units: float) -> String:
	var m := units / WS.M
	if m >= 1000.0:
		return "%.1f km" % (m / 1000.0)
	return "%d m" % int(round(m / 5.0) * 5.0) if m >= 20.0 else "%d m" % int(round(m))


## True when text matches the model-branding regex (the B contract's no-branding check).
static func branded(text: String) -> bool:
	var re := RegEx.create_from_string(BRAND_RE)
	return re.search(text) != null


## Every Label, RichTextLabel and Button text under n that slice B created (OWNER_META).
static func owned_texts(n: Node, out: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	if n.get_meta(OWNER_META, "") == OWNER:
		if n is Label:
			out.append((n as Label).text)
		elif n is RichTextLabel:
			out.append((n as RichTextLabel).get_parsed_text())
		elif n is Button:
			out.append((n as Button).text)
	for c in n.get_children():
		owned_texts(c, out)
	return out


## Exponential smoothing factor for a halflife in seconds.
static func damp(halflife: float, dt: float) -> float:
	return 1.0 - pow(0.5, dt / maxf(halflife, 1e-4))


static func _tag(name: String) -> int:
	return TextServerManager.get_primary_interface().name_to_tag(name)
