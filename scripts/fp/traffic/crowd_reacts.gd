extends RefCounted
## The crowd's answer to what the street sees and hears, split out of reactions.gd (which keeps
## the Reaction records, the blow, the fall and the witness loop that picks who reacts): a
## knock-down rocks the onlookers who stay back as one (crowd_gasp), and the hero's horn startles
## the people it reaches (horn_street). Wired like fight_back.gd: the walkers, the roll and the
## record lifecycle shared from reactions.gd's setup, the records untyped, and reactions.gd's
## clock read through now.

const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")

## A knock-down the street sees (severity 2) rocks the onlookers who stay back as one
## (crowd_gasp): no beat of looking first, a sharp backward tip (GASP_TIP rad over GASP_S)
## before they shout. Once per crowd: another body falling within GASP_CD seconds and GASP_R of
## the last gets the plain reaction.
const GASP_TIP := 0.12
const GASP_S := 0.5
const GASP_CD := 6.0
const GASP_R := 10.0 * WS.M
## A horn (horn_street) startles the people it reaches: a beat turned toward the car, rocked back
## a touch (HORN_TIP over HORN_TIP_S), the ones within HORN_NEAR stepping back off the road — a
## long press reaches HORN_LONG_NEAR and they shake their head at it. Once per crowd: a horn
## within HORN_CD seconds and HORN_R of the last gets no answer. One exception: a long press on
## the heels of its own tap (within ESCALATE_S, from the same place within ESCALATE_R) escalates
## the ripple in flight instead — the cooldown is for honk spam, not for leaning on the horn.
const HORN_TIP := 0.08
const HORN_TIP_S := 0.4
const HORN_NEAR := 8.0 * WS.M
const HORN_LONG_NEAR := 12.0 * WS.M
const HORN_STEP := 0.25 * WS.M
const HORN_CD := 5.0
const HORN_R := 20.0 * WS.M
const ESCALATE_S := 1.0
const ESCALATE_R := 2.0 * WS.M
## A brawl with a ring on it (brawl_ring — three or more fighting the hero) draws jeers from the
## crowd: every JEER_CD seconds one of the onlookers within JEER_R of the hero turns to the
## fight and shouts a beat (JEER_S). The fight's own never jeer (they are not free).
const RING_MIN := 3
const JEER_CD := 1.4
const JEER_R := 10.0 * WS.M
const JEER_S := 0.9

## Shared from reactions.gd's setup: the walkers, the roll, the record lifecycle and the clock.
var wk: WK
var rng: RandomNumberGenerator
var new_reaction: Callable
var is_free: Callable
var now: Callable
## The live reactions (walker id -> record), for the horn escalation to find the tap's own.
var active: Dictionary
var _gasp_p := Vector3.ZERO  # where the street last gasped (crowd_gasp)
var _gasp_t := -INF  # and when, on reactions.gd's clock
var _horn_p := Vector3.ZERO  # where a horn last startled the street (horn_street)
var _horn_t := -INF  # and when, on reactions.gd's clock
var _horn_long := false  # the ripple in flight came from a held press
var _jeer_t := 0.0  # the crowd's next jeer, on reactions.gd's clock (brawl_ring)


## True when a knock-down at at may rock the crowd as one (crowd_gasp): the flag on, and no gasp
## within GASP_CD seconds and GASP_R of it.
func gasp_due(at: Vector3) -> bool:
	if not FeatureFlags.enabled("crowd_gasp"):
		return false
	var t: float = now.call()
	return t - _gasp_t > GASP_CD or at.distance_to(_gasp_p) > GASP_R


## r is one of the crowd who stays: it rocks back as one with them — no beat of looking first, a
## sharp backward tip before the shout.
func apply_gasp(r) -> void:
	r.delay = 0.0
	r.tip = GASP_TIP
	r.tip_t = 0.0
	r.tip_s = GASP_S
	r.lean = Vector2(-1.0, 0.0)


## The gasp played: the crowd round at is quiet for GASP_CD seconds.
func noted_gasp(at: Vector3) -> void:
	_gasp_t = now.call()
	_gasp_p = at


## The crowd's beat (reactions.gd's step): while a brawl has a ring on it (brawl_ring), someone
## near turns to the fight and jeers, one per JEER_CD seconds.
func step(dt: float) -> void:
	if not FeatureFlags.enabled("brawl_ring") or wk == null:
		return
	_jeer_t -= dt
	if _jeer_t > 0.0:
		return
	var fighting := 0
	for id in active:
		var o = active[id]
		if o.fighter and not o.down and o.mode == "fight":
			fighting += 1
	if fighting < RING_MIN:
		return
	_jeer_t = JEER_CD
	var at: Vector3 = wk.player_pos
	var r2 := JEER_R * JEER_R
	var near: Array = []
	for o: WK.Walker in wk.walkers:
		if not is_free.call(o):
			continue
		if (o.pos + o.vis_off).distance_squared_to(at) > r2:
			continue
		near.append(o)
	if near.is_empty():
		return
	var j = new_reaction.call(near[rng.randi() % near.size()])
	j.src = at
	j.delay = 0.0
	j.steps = [["place", &"shout", JEER_S]]


## A car horn sounded at src and carries radius (u; horn_street): the people it reaches who are
## free startle — a beat turned toward the car, rocked back a touch, the ones within HORN_NEAR
## stepping back off the road and then composing themselves (a long press reaches HORN_LONG_NEAR
## and they shake their head at it). Honk spam gets no answer: one ripple per HORN_CD seconds
## within HORN_R of the last. Returns those startled.
func startle(src: Vector3, radius: float, long: bool) -> Array:
	var out: Array = []
	if not FeatureFlags.enabled("horn_street"):
		return out
	var t: float = now.call()
	if t - _horn_t <= HORN_CD and src.distance_to(_horn_p) <= HORN_R:
		# A held press on the heels of its own tap escalates the ripple in flight.
		if (
			long
			and not _horn_long
			and t - _horn_t <= ESCALATE_S
			and src.distance_to(_horn_p) <= ESCALATE_R
		):
			_horn_long = true
			return _escalate(src, radius)
		return out
	var r2 := radius * radius
	var near := HORN_LONG_NEAR if long else HORN_NEAR
	var near2 := near * near
	for o: WK.Walker in wk.walkers:
		if not is_free.call(o):
			continue
		var q: Vector3 = o.pos + o.vis_off
		var d2 := q.distance_squared_to(src)
		if d2 > r2:
			continue
		var r = new_reaction.call(o)
		r.src = src
		r.delay = rng.randf_range(0.05, 0.4)
		r.tip = HORN_TIP * (1.4 if long else 1.0)
		r.tip_t = 0.0
		r.tip_s = HORN_TIP_S
		r.lean = Vector2(-1.0, 0.0)
		if d2 <= near2:
			var d := q - src
			d.y = 0.0
			if d.length_squared() > 1e-10:
				r.slide = d.normalized() * HORN_STEP
				r.slide_s = 0.25
			r.steps = [
				["place", &"no" if long else &"", 1.0 if long else 0.7],
				["back", &"", 4.0],
			]
		else:
			r.steps = [["place", &"", 0.8]]
		out.append(o)
	if not out.is_empty():
		_horn_t = t
		_horn_p = src
		_horn_long = long
	return out


## The held press turns its own tap's ripple long: the people within HORN_LONG_NEAR who are still
## answering the tap (their reaction is its own, from the same place) step back off the road after
## all — the annulus the tap did not reach included — and shake their head at the car once the
## step in flight finishes. Returns those escalated.
func _escalate(src: Vector3, radius: float) -> Array:
	var out: Array = []
	var r2 := minf(radius * radius, HORN_LONG_NEAR * HORN_LONG_NEAR)
	for o: WK.Walker in wk.walkers:
		var q: Vector3 = o.pos + o.vis_off
		var d2 := q.distance_squared_to(src)
		if d2 > r2:
			continue
		var r = active.get(o.id)
		if r == null:
			continue
		if (r.src as Vector3).distance_to(src) > ESCALATE_R:
			continue
		var d := q - src
		d.y = 0.0
		if r.slide.is_zero_approx() and d.length_squared() > 1e-10:
			r.slide = d.normalized() * HORN_STEP
			r.slide_s = 0.25
		r.steps = [["place", &"no", 1.0], ["back", &"", 4.0]]
		out.append(o)
	return out
