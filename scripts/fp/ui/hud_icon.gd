extends Control
## A small vector icon drawn in code (no texture assets), crisp at any window scale:
## person, face, coin, bolt, drop, clock, alert, speed, info, check, pin, dot, hall.
## The glyph is laid out on a 20 x 20 grid centred in the control and scaled to its size.

## Which glyph to draw.
var icon: String = "dot":
	set(v):
		icon = v
		queue_redraw()
## Fill colour.
var color: Color = Color(1, 1, 1):
	set(v):
		color = v
		queue_redraw()
## Face icon only: 0 (sad) .. 1 (happy).
var mood: float = 0.6:
	set(v):
		mood = v
		queue_redraw()
## Draws a 1 px drop shadow under the glyph (for icons over the 3D world).
var shadow: bool = true


func _init(p_icon: String = "dot", p_color: Color = Color(1, 1, 1), px: float = 18.0) -> void:
	icon = p_icon
	color = p_color
	custom_minimum_size = Vector2(px, px)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var s := minf(size.x, size.y) / 20.0
	var c := size * 0.5
	if shadow:
		_glyph(c + Vector2(0, 1.0 * s), s, Color(0, 0, 0, 0.42 * color.a), true)
	_glyph(c, s, color, false)


func _glyph(c: Vector2, s: float, col: Color, is_shadow: bool) -> void:
	var dark := Color(0.04, 0.05, 0.08, col.a) if not is_shadow else col
	match icon:
		"person":
			draw_circle(c + Vector2(0, -4.6) * s, 3.4 * s, col, true, -1.0, true)
			var body := PackedVector2Array()
			for k in range(13):
				var a := PI + PI * float(k) / 12.0
				body.append(c + Vector2(cos(a) * 6.6, 8.2 + sin(a) * 6.4) * s)
			_poly(body, col)
		"face":
			draw_circle(c, 7.6 * s, col, true, -1.0, true)
			if not is_shadow:
				draw_circle(c + Vector2(-2.6, -1.9) * s, 1.15 * s, dark, true, -1.0, true)
				draw_circle(c + Vector2(2.6, -1.9) * s, 1.15 * s, dark, true, -1.0, true)
				var curve := (clampf(mood, 0.0, 1.0) - 0.5) * 2.0
				var pts := PackedVector2Array()
				for k in range(9):
					var t := float(k) / 8.0 * 2.0 - 1.0
					pts.append(c + Vector2(t * 3.6, 2.6 + (1.0 - t * t) * 1.9 * curve) * s)
				draw_polyline(pts, dark, 1.5 * s, true)
		"coin":
			draw_circle(c, 7.6 * s, col, true, -1.0, true)
			if not is_shadow:
				draw_arc(c, 5.6 * s, 0.0, TAU, 32, Color(dark, 0.35), 1.0 * s, true)
				var f: Font = ThemeDB.fallback_font
				var fs := int(round(10.5 * s))
				var w := f.get_string_size("$", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				draw_string(f, c + Vector2(-w * 0.5, f.get_ascent(fs) * 0.5 - 1.0 * s), "$", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, dark)
		"bolt":
			_poly(PackedVector2Array([c + Vector2(2.2, -9.0) * s, c + Vector2(-5.6, 1.4) * s, c + Vector2(-0.6, 1.4) * s,
				c + Vector2(-2.4, 9.0) * s, c + Vector2(5.6, -1.6) * s, c + Vector2(0.6, -1.6) * s]), col)
		"drop":
			var pts := PackedVector2Array([c + Vector2(0, -9.0) * s])
			for k in range(17):
				var a := deg_to_rad(-38.0 + 256.0 * float(k) / 16.0)
				pts.append(c + Vector2(cos(a) * 5.8, 2.6 + sin(a) * 5.8) * s)
			_poly(pts, col)
		"clock":
			draw_arc(c, 7.0 * s, 0.0, TAU, 40, col, 1.8 * s, true)
			draw_line(c, c + Vector2(0, -4.6) * s, col, 1.8 * s, true)
			draw_line(c, c + Vector2(3.4, 0.8) * s, col, 1.8 * s, true)
		"alert":
			_poly(PackedVector2Array([c + Vector2(0, -8.6) * s, c + Vector2(8.8, 7.4) * s, c + Vector2(-8.8, 7.4) * s]), col)
			if not is_shadow:
				draw_line(c + Vector2(0, -3.2) * s, c + Vector2(0, 2.0) * s, dark, 1.9 * s, true)
				draw_circle(c + Vector2(0, 4.6) * s, 1.1 * s, dark, true, -1.0, true)
		"speed":
			for dx: float in [-4.6, 1.4]:
				_poly(PackedVector2Array([c + Vector2(dx - 2.2, -5.6) * s, c + Vector2(dx + 4.6, 0) * s, c + Vector2(dx - 2.2, 5.6) * s]), col)
		"info":
			draw_circle(c, 7.6 * s, col, true, -1.0, true)
			if not is_shadow:
				draw_line(c + Vector2(0, -0.6) * s, c + Vector2(0, 4.4) * s, dark, 2.0 * s, true)
				draw_circle(c + Vector2(0, -3.6) * s, 1.2 * s, dark, true, -1.0, true)
		"check":
			draw_circle(c, 7.6 * s, col, true, -1.0, true)
			if not is_shadow:
				draw_polyline(PackedVector2Array([c + Vector2(-3.6, 0.2) * s, c + Vector2(-1.0, 2.9) * s, c + Vector2(3.8, -2.6) * s]), dark, 2.0 * s, true)
		"pin":
			var pts := PackedVector2Array([c + Vector2(0, 9.0) * s])
			for k in range(19):
				var a := deg_to_rad(140.0 + 260.0 * float(k) / 18.0)
				pts.append(c + Vector2(cos(a) * 6.2, -2.4 + sin(a) * 6.2) * s)
			_poly(pts, col)
			if not is_shadow:
				draw_circle(c + Vector2(0, -2.4) * s, 2.3 * s, dark, true, -1.0, true)
		"hall":
			_poly(PackedVector2Array([c + Vector2(-8, -2.5) * s, c + Vector2(0, -8.5) * s, c + Vector2(8, -2.5) * s]), col)
			for dx: float in [-5.5, -1.8, 1.8, 5.5]:
				draw_rect(Rect2(c + Vector2(dx - 1.0, -1.5) * s, Vector2(2.0, 7.0) * s), col)
			draw_rect(Rect2(c + Vector2(-8, 6.0) * s, Vector2(16, 2.2) * s), col)
		_:
			draw_circle(c, 4.0 * s, col, true, -1.0, true)


## A filled polygon with an antialiased rim (draw_colored_polygon has no AA of its own).
func _poly(pts: PackedVector2Array, col: Color) -> void:
	draw_colored_polygon(pts, col)
	var rim := pts.duplicate()
	rim.append(pts[0])
	draw_polyline(rim, col, 1.0, true)
