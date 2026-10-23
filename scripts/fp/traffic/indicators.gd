extends RefCounted
## Turn signals: which side a car's indicators blink on, and when a blinking lamp is lit.
## A car signals the turn of the next junction move (a left or right at a tee or cross, left for a
## cul-de-sac U-turn) from AHEAD before the move until it has left it; bends in the road are not
## signalled. A car pulling into a curb slot signals right (toward the curb, right-hand traffic),
## and one stopped stunned after a knock (shoves.gd) or after running the hero down shows its
## hazards. render.gd blinks the Light_Indicator_L/R surfaces of the full models.

const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const NONE := 0
const LEFT := -1
const RIGHT := 1
const HAZARD := 2
## How far (u) before a junction move a car starts signalling it.
const AHEAD := 30.0 * WS.M
## Blinks per second and the lit share of each blink (about 90 a minute, as the rules ask).
const RATE := 1.5
const DUTY := 0.5


## The side c signals now: NONE, LEFT, RIGHT or HAZARD.
static func side(c: VH.Car) -> int:
	if c.stun_t > 0.0:
		return HAZARD
	if c.park_t >= 0.0:
		return RIGHT
	if c.lane == null:
		return NONE
	if _turns(c.lane):
		return _of(c.lane)
	var d := c.lane.length - c.s
	for l: LG.Lane in c.path:
		if d > AHEAD:
			break
		if _turns(l):
			return _of(l)
		d += l.length
	return NONE


## Whether a blinking lamp is lit at time t (s).
static func lit(t: float) -> bool:
	return fposmod(t * RATE, 1.0) < DUTY


## Whether the left (s < 0) or right lamps of a car signalling side are lit at time t.
static func on(side_: int, s: int, t: float) -> bool:
	if side_ == NONE or not lit(t):
		return false
	return side_ == HAZARD or side_ == s


static func _turns(l: LG.Lane) -> bool:
	return l.kind == LG.UTURN or (l.kind == LG.MOVE and l.turn != 0)


static func _of(l: LG.Lane) -> int:
	return LEFT if l.turn == 2 else clampi(l.turn, LEFT, RIGHT)
