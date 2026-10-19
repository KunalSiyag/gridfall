extends RefCounted
## Small passive controls of the chat panel and the talk dialogue (slice C): a vector icon, a round
## avatar with initials, a mood face and typing dots. Drawn in code: the project fonts carry no
## arrow or emoji glyphs.

const S := preload("res://scripts/fp/ui/chat_panel_style.gd")


## A passive control that draws one vector icon.
class Icon extends Control:
	var icon: String = ""
	var color: Color = Color.WHITE

	func _init(p_icon: String = "", p_color: Color = Color.WHITE, px: float = 16.0) -> void:
		icon = p_icon
		color = p_color
		custom_minimum_size = Vector2(px, px)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_icon(p_icon: String, p_color: Color) -> void:
		icon = p_icon
		color = p_color
		queue_redraw()

	func _draw() -> void:
		var side := minf(size.x, size.y)
		var r := Rect2((size - Vector2(side, side)) * 0.5, Vector2(side, side))
		S.draw_icon(self, icon, r, color)


## A round avatar: tinted disc, soft ring and initials (or an icon).
class Avatar extends Control:
	var fill: Color = Color.GRAY
	var initials: String = ""
	var icon: String = ""
	var ring: Color = Color(1, 1, 1, 0.18)

	func _init(p_fill: Color = Color.GRAY, p_initials: String = "", px: float = 36.0, p_icon: String = "") -> void:
		fill = p_fill
		initials = p_initials
		icon = p_icon
		custom_minimum_size = Vector2(px, px)
		size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		S.draw_avatar(self, Rect2(Vector2.ZERO, size), fill, initials, icon)


## A small face whose colour and mouth follow a 0-10 mood.
class MoodFace extends Control:
	var mood: float = 5.0

	func _init(px: float = 18.0) -> void:
		custom_minimum_size = Vector2(px, px)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_mood(m: float) -> void:
		mood = m
		queue_redraw()

	func _draw() -> void:
		var side := minf(size.x, size.y)
		var c := size * 0.5
		var r := side * 0.5
		var col := S.mood_color(mood)
		draw_circle(c, r, Color(0.04, 0.05, 0.07))
		draw_circle(c, r - 1.5, col)
		var ink := Color(0.08, 0.06, 0.04)
		draw_circle(c + Vector2(-r * 0.32, -r * 0.18), maxf(1.0, r * 0.12), ink)
		draw_circle(c + Vector2(r * 0.32, -r * 0.18), maxf(1.0, r * 0.12), ink)
		var curve := clampf((mood - 5.0) / 5.0, -1.0, 1.0)
		var pts := PackedVector2Array()
		for k in range(9):
			var t := float(k) / 8.0 * 2.0 - 1.0
			pts.append(c + Vector2(t * r * 0.45, r * 0.32 + curve * r * 0.22 * (1.0 - t * t)))
		draw_polyline(pts, ink, maxf(1.2, r * 0.14), true)


## Three pulsing dots ("typing...").
class Dots extends Control:
	var color: Color = Color(1, 1, 1, 0.8)
	var _t: float = 0.0

	func _init(p_color: Color = Color(1, 1, 1, 0.8)) -> void:
		color = p_color
		custom_minimum_size = Vector2(26, 12)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(delta: float) -> void:
		if is_visible_in_tree():
			_t += delta
			queue_redraw()

	func _draw() -> void:
		for k in range(3):
			var a := 0.35 + 0.65 * maxf(0.0, sin(_t * 6.0 - float(k) * 0.9))
			draw_circle(Vector2(5 + k * 8, size.y * 0.5), 2.6, Color(color, color.a * a))


## A small status dot with a soft halo.
class Dot extends Control:
	var color: Color = Color.WHITE

	func _init(p_color: Color = Color.WHITE, px: float = 8.0) -> void:
		color = p_color
		custom_minimum_size = Vector2(px, px)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := minf(size.x, size.y) * 0.5
		draw_circle(size * 0.5, r, Color(color, 0.28))
		draw_circle(size * 0.5, r * 0.62, color)
