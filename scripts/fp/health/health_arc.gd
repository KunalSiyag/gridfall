extends Control
## The hero's health (the health feature) as an arc round the left of the minimap in
## minimap_slot: it fills from the bottom up, green when well, amber below AMBER_AT and red below
## RED_AT, where it pulses; after a hurt a pale trail eats down to the new value.

const S := preload("res://scripts/fp/ui/hud_style.gd")
## The minimap's circle in the slot (minimap_view.gd ORIGIN + DIAM / 2, radius 100) and the arc
## just outside its ring and shadow, from FROM (the bottom) round the left to TO (the top). On
## screen 0 points along +x and angles turn clockwise.
const CENTRE := Vector2(108.0, 100.0)
const RADIUS := 114.0
const WIDTH := 5.0
const FROM := deg_to_rad(100.0)
const TO := deg_to_rad(260.0)
const POINTS := 40
const AMBER_AT := 0.5
const RED_AT := 0.25
const TRACK := Color(0.02, 0.03, 0.05, 0.55)
const TRAIL := Color(1.0, 1.0, 1.0, 0.6)
## The trail waits TRAIL_WAIT seconds after a hurt, then eats down with this half-life (s).
const TRAIL_WAIT := 0.35
const HL_TRAIL := 0.18
const PULSE_HZ := 1.6

## Health shown (0..1) and the trail behind it.
var value: float = 1.0
var trail: float = 1.0
var _wait: float = 0.0
var _t: float = 0.0
var _drawn := Vector3(-1.0, -1.0, -1.0)


func setup() -> void:
	name = "HealthArc"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## Shows health v (0..1) after dt seconds: a drop leaves the trail behind for a moment.
func set_health(v: float, dt: float) -> void:
	var nv := clampf(v, 0.0, 1.0)
	if nv < value - 1e-4:
		_wait = TRAIL_WAIT
	value = nv
	_t += dt
	if trail <= value:
		trail = value
	elif _wait > 0.0:
		_wait -= dt
	else:
		trail = lerpf(trail, value, S.damp(HL_TRAIL, dt))
		if trail - value < 1e-3:
			trail = value
	var key := Vector3(value, trail, colour().a)
	if not key.is_equal_approx(_drawn):
		_drawn = key
		queue_redraw()


## The fill's colour: green, amber, then a pulsing red.
func colour() -> Color:
	if value < RED_AT:
		return Color(S.RED, 0.7 + 0.3 * sin(_t * TAU * PULSE_HZ))
	return S.AMBER if value < AMBER_AT else S.GOOD


func _draw() -> void:
	draw_arc(CENTRE, RADIUS, FROM, TO, POINTS, TRACK, WIDTH + 2.0, true)
	var span := TO - FROM
	if trail > value:
		var a := FROM + span * value
		draw_arc(CENTRE, RADIUS, a, FROM + span * trail, _points(trail - value), TRAIL, WIDTH, true)
	if value > 0.0:
		draw_arc(CENTRE, RADIUS, FROM, FROM + span * value, _points(value), colour(), WIDTH, true)


static func _points(share: float) -> int:
	return maxi(2, ceili(POINTS * share))
