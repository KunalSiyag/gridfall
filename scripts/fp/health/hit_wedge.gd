extends Control
## The blow-direction marker (hit_direction, first person): a short red arc a little in from the
## screen's edge, toward the side a blow came from (angle 0 dead ahead, +PI/2 from the right, PI
## from behind), fading away over about FADE_S. health_screen.gd hosts it and flashes it on a
## hurt that carries a push; health_feature.gd only asks in first person.

const S := preload("res://scripts/fp/ui/hud_style.gd")
## The marker fades with this half-life (s), gone (under 2%) in about FADE_S.
const FADE_S := 0.5
const HL := FADE_S / 5.6
## The arc spans SPAN rad each way of the blow's angle, WIDTH px thick, INSET of the way out to
## the screen's edge.
const SPAN := 0.45
const WIDTH := 10.0
const INSET := 0.86

## The blow's angle round the view and how bright the marker still is (tests).
var ang := 0.0
var alpha := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## A blow from angle a (0 dead ahead, +PI/2 from the right): the marker shows full and fades.
func flash(a: float) -> void:
	ang = a
	alpha = 1.0
	visible = true
	queue_redraw()


## dt seconds pass; the marker fades away.
func fade(dt: float) -> void:
	if alpha <= 0.0:
		return
	alpha *= 1.0 - S.damp(HL, dt)
	if alpha < 0.02:
		alpha = 0.0
		visible = false
	else:
		queue_redraw()


func _draw() -> void:
	if alpha <= 0.0:
		return
	# Screen angles: 0 is +x (right), growing clockwise with y down — dead ahead is -PI/2.
	var c := size * 0.5
	var r := minf(c.x, c.y) * INSET
	var mid := ang - PI * 0.5
	draw_arc(c, r, mid - SPAN, mid + SPAN, 24, Color(S.RED, alpha), WIDTH, true)
