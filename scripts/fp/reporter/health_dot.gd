extends Control
## A small health light (the league's mayor cell and its services page): a drawn shape, not
## text, coloured by ModelLedger health, with the sentence for it as its tooltip. The ledger's
## health word travels in `health`, so a test can read what a row shows.

const S := preload("res://scripts/fp/ui/hud_style.gd")
const LG := preload("res://scripts/fp/reporter/league_ledger.gd")
const SIZE := 12.0
const COLORS := {
	"green": S.GOOD,
	"amber": S.AMBER,
	"red": S.RED,
	"grey": S.TEXT_FAINT,
	"scripted": S.TEXT_FAINT,
	"idle": S.TEXT_FAINT,
}

var health: String = "idle"


## A light for this health word.
static func make(p_health: String) -> Control:
	var d: Control = (load("res://scripts/fp/reporter/health_dot.gd") as GDScript).new()
	d.set_health(p_health)
	return d


func set_health(p_health: String) -> void:
	health = p_health if COLORS.has(p_health) else "idle"
	custom_minimum_size = Vector2(SIZE, SIZE)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_PASS
	tooltip_text = LG.health_tip(health)
	queue_redraw()


## Shape as well as colour, so the states read without it: good is a filled circle, shaky a
## triangle, down a diamond, replay a ring with a dot, scripted a small square outline, idle an
## empty ring.
func _draw() -> void:
	var c: Color = COLORS[health]
	var mid := Vector2(SIZE, SIZE) * 0.5
	var r := SIZE * 0.4
	match health:
		"idle":
			draw_arc(mid, SIZE * 0.34, 0.0, TAU, 20, c, 1.6, true)
		"scripted":
			draw_rect(Rect2(mid - Vector2(r, r) * 0.85, Vector2(r, r) * 1.7), c, false, 1.6)
		"grey":
			draw_arc(mid, SIZE * 0.38, 0.0, TAU, 20, c, 1.6, true)
			draw_circle(mid, SIZE * 0.14, c)
		"amber":
			draw_colored_polygon(
				PackedVector2Array(
					[mid + Vector2(0, -r), mid + Vector2(r, r * 0.8), mid + Vector2(-r, r * 0.8)]
				),
				c
			)
		"red":
			draw_colored_polygon(
				PackedVector2Array(
					[
						mid + Vector2(0, -r),
						mid + Vector2(r, 0),
						mid + Vector2(0, r),
						mid + Vector2(-r, 0)
					]
				),
				c
			)
		_:
			draw_circle(mid, SIZE * 0.34, c)
