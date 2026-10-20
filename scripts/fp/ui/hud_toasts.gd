extends Control
## Toasts and the alert banner (slice B), laid out by hand in the "toasts" slot so they can slide:
## at most 3 toasts with a 4 s life, identical consecutive toasts collapse into one ("×2"), each
## slides and fades in and out over 0.2 s, and the stack closes up smoothly. A red banner for
## reported incidents sits above them and blinks twice on arrival. Every string is de-branded.

const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const HudIcon := preload("res://scripts/fp/ui/hud_icon.gd")

const MAX_TOASTS := 3
const LIFE := 4.0
const FADE := 0.2
const SLIDE_PX := 10.0
const GAP := 6.0
## Widest toast or banner text before it ends in an ellipsis.
const MAX_TEXT_W := 560.0
const BANNER_LIFE := 6.5
const BANNER_BLINK := 0.8
## The slot starts at y 76; the compass and its distance labels end at y 106.
const TOP := 34.0
const KIND_STYLE := {
	"info": ["dot", S.TEXT],
	"success": ["check", S.GOOD],
	"alert": ["alert", S.AMBER],
	"system": ["info", S.TEXT_DIM],
	"chat": ["dot", S.TEXT_DIM],
}

## Each: {"panel": PanelContainer, "label": Label, "text": String, "count": int, "age": float, "life": float, "y": float}
var _items: Array[Dictionary] = []
var _banner: PanelContainer
var _banner_label: Label
var _banner_t: float = 0.0
var _banner_age: float = 0.0


## Builds the banner; toasts are made on demand.
func setup() -> void:
	name = "Toasts"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_banner = PanelContainer.new()
	_banner.name = "Banner"
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := S.stripe(S.box(Color(0.3, 0.04, 0.05, 0.72), S.RADIUS, 14, 7), S.RED, 3)
	_banner.add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 10)
	_banner.add_child(h)
	var ic := HudIcon.new("alert", S.RED, 18.0)
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(ic)
	_banner_label = S.caps_label("", 15, S.WHITE, 2)
	_banner_label.name = "BannerText"
	_banner_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(_banner_label)
	_banner.visible = false
	add_child(_banner)


## Queues a toast. kind: info|alert|success|system|chat. An identical text to the newest live
## toast refreshes it instead (with a count).
func show_toast(text: String, kind: String = "info") -> void:
	var t := D.debrand(text).strip_edges()
	if t.is_empty():
		return
	if not _items.is_empty():
		var last: Dictionary = _items[_items.size() - 1]
		if str(last["text"]) == t and float(last["life"]) > 0.0:
			last["count"] = int(last["count"]) + 1
			last["life"] = LIFE
			var ll: Label = last["label"]
			ll.text = "%s  ×%d" % [t, int(last["count"])]
			ll.custom_minimum_size.x = minf(
				ceilf(S.font().get_string_size(ll.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x) + 2.0,
				MAX_TEXT_W
			)
			(last["panel"] as Control).reset_size()
			return
	while _items.size() >= MAX_TOASTS:
		var old: Dictionary = _items.pop_front()
		(old["panel"] as Node).queue_free()
	var style: Array = KIND_STYLE.get(kind, KIND_STYLE["info"])
	var p := PanelContainer.new()
	p.name = "Toast"
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := S.box(Color(0.04, 0.05, 0.08, 0.58), S.RADIUS, 12, 6)
	p.add_theme_stylebox_override("panel", S.stripe(sb, Color(style[1], 0.9), 2))
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 9)
	p.add_child(h)
	var ic := HudIcon.new(str(style[0]), style[1], 15.0)
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(ic)
	var l := S.label(t, 16, S.TEXT, S.font(), 2)
	l.name = "Text"
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	# An ellipsis label has no minimum width of its own: size it to the text, capped.
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.custom_minimum_size.x = minf(
		ceilf(S.font().get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x) + 2.0, MAX_TEXT_W
	)
	h.add_child(l)
	add_child(p)
	p.reset_size()
	p.modulate.a = 0.0
	_items.append(
		{
			"panel": p,
			"label": l,
			"text": t,
			"count": 1,
			"age": 0.0,
			"life": LIFE,
			"y": _stack_end() - SLIDE_PX
		}
	)


## Shows the red alert banner (replacing any current one); it blinks twice, then holds.
func show_banner(text: String) -> void:
	_banner_label.text = D.debrand(text)
	var w := ceilf(S.caps_width(_banner_label.text, 15)) + 2.0
	_banner_label.custom_minimum_size.x = minf(w, MAX_TEXT_W)
	_banner.reset_size()
	_banner.visible = true
	_banner_t = BANNER_LIFE
	_banner_age = 0.0


## The banner text while it shows, else "".
func banner_text() -> String:
	return _banner_label.text if _banner.visible else ""


## Texts of the live toasts, oldest first (tests).
func texts() -> PackedStringArray:
	var out := PackedStringArray()
	for e: Dictionary in _items:
		out.append((e["label"] as Label).text)
	return out


## Drops every toast and the banner (reload).
func clear() -> void:
	for e: Dictionary in _items:
		(e["panel"] as Node).queue_free()
	_items.clear()
	_banner.visible = false
	_banner_t = 0.0


func _process(delta: float) -> void:
	var y := TOP
	if _banner.visible:
		_banner_t -= delta
		_banner_age += delta
		if _banner_t <= 0.0:
			_banner.visible = false
		else:
			var a := clampf(_banner_age / FADE, 0.0, 1.0) * clampf(_banner_t / FADE, 0.0, 1.0)
			if (
				_banner_age < BANNER_LIFE
				and _banner_age > FADE
				and _banner_age < FADE + BANNER_BLINK
			):
				a *= 1.0 - 0.7 * absf(sin((_banner_age - FADE) / BANNER_BLINK * TAU))
			_banner.modulate.a = a
			_banner.position = Vector2(roundf((size.x - _banner.size.x) * 0.5), y)
			y += _banner.size.y + GAP
	var k := 0
	while k < _items.size():
		var e: Dictionary = _items[k]
		e["age"] = float(e["age"]) + delta
		e["life"] = float(e["life"]) - delta
		var p: PanelContainer = e["panel"]
		if float(e["life"]) <= 0.0:
			p.queue_free()
			_items.remove_at(k)
			continue
		var fin := clampf(float(e["age"]) / FADE, 0.0, 1.0)
		var fout := clampf(float(e["life"]) / FADE, 0.0, 1.0)
		var target := y + (1.0 - fin) * -SLIDE_PX - (1.0 - fout) * SLIDE_PX * 0.5
		e["y"] = lerpf(float(e["y"]), target, S.damp(0.06, delta))
		p.position = Vector2(roundf((size.x - p.size.x) * 0.5), roundf(float(e["y"])))
		p.modulate.a = fin * fout
		y += p.size.y + GAP
		k += 1


func _stack_end() -> float:
	var y := TOP
	if _banner.visible:
		y += _banner.size.y + GAP
	for e: Dictionary in _items:
		y += (e["panel"] as Control).size.y + GAP
	return y
