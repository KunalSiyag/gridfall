extends SceneTree
## The line a carjacked driver is thrown along (jack_landing.gd, the carjack_throw flag): turned off
## straight out by the smallest turn that keeps the open door panel clear of the flung arms and the
## body's run clear of what stands out there (the collision world's static boxes and posts, probed
## for the root and the head, and anyone on the pavement), the fling cut to that run. The choice is
## a pure function of the geometry (choose, with the run given as a function), checked first;
## then the probe over a real collision world and bare walkers; then the whole throw_line the way
## carjack.gd asks for it, with the numbers of the real car and door the city test (fp_carjack_test)
## and its probes use (metres, in the car's frame: x out of the driver's side, z forward).

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const JL := preload("res://scripts/fp/traffic/jack_landing.gd")
const CJ := preload("res://scripts/fp/traffic/carjack.gd")
const HALF_W := 1.154
const HINGE := Vector2(0.927, 0.930)
const FREE := Vector2(2.375, 0.323)
const SEAT_Z := -0.2
const LEN := 1.8 * WS.M

var fails: Array[String] = []
var ran: Array[String] = []
var ctx: FpContext
var spot := Vector3.ZERO


func _init() -> void:
	await process_frame
	_check_turns()
	_check_geometry()
	_check_choose()
	ctx = K.make_ctx(get_root(), {"player": false, "hud": false})
	spot = _free_spot()
	K.check(fails, spot.is_finite(), "a bare piece of ground to throw across (%s)" % str(spot))
	if spot.is_finite():
		_check_free_run()
		_check_people()
		_check_throw_line()
	K.check(fails, ran.size() == 6, "every section ran to its end (%s)" % str(ran))
	K.finish(self, "FP_JACK_LANDING_TEST", fails)


# ------------------------------------------------------------------ the pure parts


## The turns tried: none first, then one step to the rear, one to the front, two to the rear, ...
## to AIM_MAX; the rear is -z.
func _check_turns() -> void:
	K.check(fails, JL.turn_at(0) == 0.0, "the first try is straight out")
	K.check(
		fails,
		(
			is_equal_approx(JL.turn_at(1), JL.AIM_STEP)
			and is_equal_approx(JL.turn_at(2), -JL.AIM_STEP)
		),
		"then a step to the rear, a step to the front"
	)
	var seen := {}
	var inside := true
	for k in range(11):
		seen[snappedf(JL.turn_at(k), 1e-6)] = true
		inside = inside and absf(JL.turn_at(k)) <= JL.AIM_MAX + 1e-9
	K.check(
		fails,
		seen.size() == 11 and inside and is_equal_approx(JL.turn_at(9), JL.AIM_MAX),
		"11 different turns, none past AIM_MAX either way (%d)" % seen.size()
	)
	var straight := JL.dir_at(0.0)
	var rear := JL.dir_at(JL.AIM_STEP)
	K.check(
		fails,
		(
			straight.is_equal_approx(Vector2(1.0, 0.0))
			and rear.y < 0.0
			and rear.x > 0.0
			and is_equal_approx(rear.length(), 1.0)
		),
		"a turn to the rear heads out and towards -z"
	)
	ran.append("turns")


## The distance between two segments: across, along an end, crossing, parallel.
func _check_geometry() -> void:
	var gap := JL.seg_gap(Vector2(0, 0), Vector2(2, 0), Vector2(0, 1), Vector2(2, 1))
	K.check(fails, is_equal_approx(gap, 1.0), "parallel segments a unit apart")
	gap = JL.seg_gap(Vector2(0, 0), Vector2(2, 0), Vector2(3, 0), Vector2(5, 3))
	K.check(fails, is_equal_approx(gap, 1.0), "past an end: the end's distance (%.3f)" % gap)
	gap = JL.seg_gap(Vector2(0, 0), Vector2(2, 2), Vector2(0, 2), Vector2(2, 0))
	K.check(fails, gap == 0.0, "crossing segments touch")
	gap = JL.seg_gap(Vector2(2, 0), Vector2(2, 0), Vector2(1, 1), Vector2(3, 1))
	K.check(fails, is_equal_approx(gap, 1.0), "a point against a segment")
	K.check(fails, JL.panel({}).is_empty(), "a car with no door (or a shut one, {}) has no panel")
	var pan := JL.panel(_door())
	K.check(
		fails,
		(
			pan.size() == 2
			and (pan[0] as Vector2).is_equal_approx(HINGE * WS.M)
			and (pan[1] as Vector2).is_equal_approx(FREE * WS.M)
		),
		"the open panel runs from the hinge to the door's free end"
	)
	ran.append("geometry")


## The choice over the given geometry: the smallest turn that clears the panel, the first that has
## the whole run, a turn only for what it buys, the door ahead of the run.
func _check_choose() -> void:
	var start := _start()
	var pan := JL.panel(_door())
	var full := func(_d: Vector2) -> float: return LEN
	K.check(
		fails,
		JL.door_gap(start, JL.dir_at(0.0), LEN, pan) < JL.DOOR_CLEAR,
		(
			"straight out, the arms' line passes the door's end at %.2f m (a clearance of %.2f)"
			% [JL.door_gap(start, JL.dir_at(0.0), LEN, pan) / WS.M, JL.DOOR_CLEAR / WS.M]
		)
	)
	var pick := JL.choose(start, LEN, pan, full)
	var a := pick.x
	var g := JL.door_gap(start, JL.dir_at(a), LEN, pan)
	var g_less := JL.door_gap(start, JL.dir_at(a - JL.AIM_STEP), LEN, pan)
	var shown := "turned %.0f degrees to the rear, the least that clears it" % rad_to_deg(a)
	K.check(
		fails,
		a > 0.0 and a <= JL.AIM_MAX and g >= JL.DOOR_CLEAR and g_less < JL.DOOR_CLEAR,
		"an open door: %s (%.2f m, %.2f less)" % [shown, g / WS.M, g_less / WS.M]
	)
	K.check(fails, is_equal_approx(pick.y, LEN), "with the whole run")
	var plain := JL.choose(start, LEN, [], full)
	K.check(fails, plain.x == 0.0 and is_equal_approx(plain.y, LEN), "no door: straight out")
	var wall := func(d: Vector2) -> float:
		return 0.3 * WS.M if absf(atan2(-d.y, d.x)) < deg_to_rad(7.0) else LEN
	pick = JL.choose(start, LEN, [], wall)
	K.check(
		fails,
		is_equal_approx(pick.x, 2.0 * JL.AIM_STEP) and is_equal_approx(pick.y, LEN),
		(
			"a post in the line: the first turn past it, to the rear (%.0f degrees)"
			% rad_to_deg(pick.x)
		)
	)
	var better := func(d: Vector2) -> float:
		var a_d := atan2(-d.y, d.x)
		return 0.9 * LEN if is_equal_approx(a_d, -2.0 * JL.AIM_STEP) else 0.5 * LEN
	pick = JL.choose(start, LEN, [], better)
	K.check(
		fails,
		is_equal_approx(pick.x, -2.0 * JL.AIM_STEP) and is_equal_approx(pick.y, 0.9 * LEN),
		"no turn clear, the one with the most run (%.0f degrees)" % rad_to_deg(pick.x)
	)
	var meh := func(d: Vector2) -> float: return 0.5 * WS.M + (0.02 * WS.M if d.y != 0.0 else 0.0)
	pick = JL.choose(start, LEN, [], meh)
	K.check(fails, pick.x == 0.0, "a turn that buys under TURN_WORTH is not taken")
	var late := func(d: Vector2) -> float:
		var turned := atan2(-d.y, d.x)
		return 0.2 * WS.M if turned >= 3.0 * JL.AIM_STEP - 1e-6 else 1.0 * WS.M
	pick = JL.choose(start, LEN, pan, late)
	K.check(
		fails,
		(
			pick.x >= JL.turn_at(1)
			and JL.door_gap(start, JL.dir_at(pick.x), LEN, pan) >= JL.DOOR_CLEAR
		),
		(
			"the door first: a line clear of the panel even where the run is short (%.2f m)"
			% (pick.y / WS.M)
		)
	)
	var stuck := JL.choose(start, LEN, [Vector2(0.5, 0.0) * WS.M, Vector2(3.0, 0.0) * WS.M], full)
	K.check(
		fails, stuck.x == 0.0 and is_equal_approx(stuck.y, LEN), "a panel no turn clears: no worse"
	)
	var again := JL.choose(start, LEN, pan, full)
	K.check(fails, again == JL.choose(start, LEN, pan, full), "the same twice")
	ran.append("choose")


# ------------------------------------------------------------------ the world


## The run over the collision world: a wall's face WALL m ahead stops the run where the head the
## lying body reaches LIE_FAR past it would meet it; a post the same; a wall behind or to the side
## out of the way is none; no water.
func _check_free_run() -> void:
	var col := ctx.collision
	var xf := Transform3D(Basis.IDENTITY, spot)
	var start := Vector2(0.0, 0.0)
	var east := Vector2(1.0, 0.0)
	var none := PackedVector2Array()
	var open: Array[AABB] = []
	K.check(
		fails,
		is_equal_approx(JL.free_run(xf, start, east, LEN, col, open, none), LEN),
		"open ground: the whole run"
	)
	K.check(
		fails,
		is_equal_approx(JL.free_run(xf, start, east, LEN, null, open, none), LEN),
		"no collision world: the whole run"
	)
	var face := 1.5 * WS.M
	var box := _wall(face, 0.0)
	col.add_test_box(box)
	var boxes := col.boxes_near(spot, 1.0, 0.0)
	var run := JL.free_run(xf, start, east, LEN, col, boxes, none)
	var want := face - JL.LIE_FAR - JL.HEAD_R
	K.check(
		fails,
		run <= want + 1e-6 and run > want - 1.5 * JL.PROBE,
		(
			"a wall's face 1.5 m out stops the run where the head would meet it (%.2f m of %.2f)"
			% [run / WS.M, want / WS.M]
		)
	)
	var side := JL.free_run(xf, start, Vector2(0.0, 1.0), LEN, col, boxes, none)
	K.check(
		fails,
		is_equal_approx(side, LEN),
		"the same wall, thrown along it: nothing in the way (%.2f m)" % (side / WS.M)
	)
	col.clear_test_boxes()
	col.add_test_cylinder(spot.x + 2.2 * WS.M, spot.z, 0.15 * WS.M, 3.0 * WS.M)
	boxes = col.boxes_near(spot, 1.0, 0.0)
	run = JL.free_run(xf, start, east, LEN, col, boxes, none)
	want = 2.2 * WS.M - 0.15 * WS.M - JL.LIE_FAR - JL.HEAD_R
	K.check(
		fails,
		run <= want + 1e-6 and run > want - 1.5 * JL.PROBE,
		(
			"a lamp post 2.2 m out: the run ends short of it (%.2f m of %.2f)"
			% [run / WS.M, want / WS.M]
		)
	)
	col.clear_test_boxes()
	K.check(
		fails,
		is_equal_approx(
			JL.free_run(xf, start, east, LEN, col, col.boxes_near(spot, 1.0, 0.0), none), LEN
		),
		"and with it gone the whole run again"
	)
	col.add_test_box(_wall(face, 4.0 * WS.M))
	boxes = col.boxes_near(spot, 1.0, 0.0)
	K.check(
		fails,
		is_equal_approx(JL.free_run(xf, start, east, LEN, col, boxes, none), LEN),
		"a ceiling above the body (an awning) is no wall"
	)
	col.clear_test_boxes()
	ran.append("free_run")


## Someone standing in the line is in the way; the victim, the gone and those out of reach are not.
func _check_people() -> void:
	var xf := Transform3D(Basis(Vector3.UP, 0.7), spot)
	var origin := xf * Vector3.ZERO
	var east := Vector2(1.0, 0.0)
	var at := func(m_along: float, m_across: float) -> WK.Walker:
		var w := WK.Walker.new()
		w.pos = xf * Vector3(m_along * WS.M, 0.0, m_across * WS.M)
		w.id = 7 + int(m_along * 10.0)
		w.state = "walk"
		return w
	var ahead: WK.Walker = at.call(2.2, 0.0)
	var all: Array = [ahead]
	var near := JL.standing(all, -1, origin, 4.0 * WS.M)
	var none: Array[AABB] = []
	var run := JL.free_run(xf, Vector2.ZERO, east, LEN, null, none, near)
	var want := 2.2 * WS.M - JL.LIE_FAR - JL.PED_CLEAR
	K.check(
		fails,
		near.size() == 1 and run <= want + 1e-6 and run > want - 1.5 * JL.PROBE,
		(
			"someone 2.2 m out in the line: the run ends short of them (%.2f m of %.2f)"
			% [run / WS.M, want / WS.M]
		)
	)
	K.check(
		fails,
		JL.standing(all, ahead.id, origin, 4.0 * WS.M).is_empty(),
		"but not the victim themself"
	)
	ahead.dead = true
	K.check(fails, JL.standing(all, -1, origin, 4.0 * WS.M).is_empty(), "nor someone gone")
	ahead.dead = false
	ahead.state = "hidden"
	K.check(fails, JL.standing(all, -1, origin, 4.0 * WS.M).is_empty(), "nor someone indoors")
	ahead.state = "walk"
	K.check(fails, JL.standing(all, -1, origin, 1.0 * WS.M).is_empty(), "nor someone out of reach")
	var aside: WK.Walker = at.call(2.2, 1.2)
	near = JL.standing([aside], -1, origin, 4.0 * WS.M)
	run = JL.free_run(xf, Vector2.ZERO, east, LEN, null, none, near)
	K.check(
		fails,
		is_equal_approx(run, LEN),
		"someone 1.2 m off the line is not in it (%.2f m)" % (run / WS.M)
	)
	ran.append("people")


## The whole throw as carjack.gd asks for it: the real door's panel and a bystander 2.3 m out beside
## the seat, with and without them; the push a level unit, within AIM_MAX of straight out; the
## same twice; nothing in reach changes nothing but the turn.
func _check_throw_line() -> void:
	var xf := Transform3D(Basis(Vector3.UP, 0.7), spot)
	var start := _start()
	var door := _door()
	var col := ctx.collision
	var clear := JL.throw_line(xf, start, 1.8, door, col, [], -1)
	var a: float = clear["angle"]
	var d := JL.dir_at(a)
	var want := (xf.basis * Vector3(d.x, 0.0, d.y)).normalized()
	var push: Vector3 = clear["push"]
	K.check(
		fails,
		(
			push.is_equal_approx(want)
			and is_zero_approx(push.y)
			and is_equal_approx(push.length(), 1.0)
		),
		"the push is the turned line in the world, level and a unit"
	)
	K.check(
		fails,
		a > 0.0 and a <= JL.AIM_MAX and is_equal_approx(float(clear["fling"]), 1.8),
		"open ground, open door: turned %.0f degrees to the rear, the whole 1.8 m" % rad_to_deg(a)
	)
	var shut := JL.throw_line(xf, start, 1.8, {}, col, [], -1)
	K.check(
		fails,
		float(shut["angle"]) == 0.0 and is_equal_approx(float(shut["fling"]), 1.8),
		"a shut door (nothing passed): straight out"
	)
	var someone := WK.Walker.new()
	someone.id = 41
	someone.state = "walk"
	someone.pos = xf * Vector3((start.x / WS.M + 2.1) * WS.M, 0.0, (start.y / WS.M - 0.5) * WS.M)
	var blocked := JL.throw_line(xf, start, 1.8, door, col, [someone], -1)
	K.check(
		fails,
		float(blocked["fling"]) < 1.8 or absf(float(blocked["angle"]) - a) > 1e-9,
		(
			"someone where they would land: a shorter fling or another line (%.2f m, %.0f deg)"
			% [float(blocked["fling"]), rad_to_deg(float(blocked["angle"]))]
		)
	)
	var gone := JL.throw_line(xf, start, 1.8, door, col, [someone], someone.id)
	K.check(
		fails,
		gone["angle"] == clear["angle"] and gone["fling"] == clear["fling"],
		"the victim themself is no obstacle"
	)
	var twice := JL.throw_line(xf, start, 1.8, door, col, [someone], -1)
	K.check(
		fails,
		(
			twice["angle"] == blocked["angle"]
			and twice["fling"] == blocked["fling"]
			and (twice["push"] as Vector3) == (blocked["push"] as Vector3)
		),
		"the same street, the same throw"
	)
	var all_blocked := WK.Walker.new()
	all_blocked.id = 42
	all_blocked.state = "walk"
	all_blocked.pos = xf * Vector3(start.x + 0.2 * WS.M, 0.0, start.y)
	var tight := JL.throw_line(xf, start, 1.8, door, col, [all_blocked], -1)
	K.check(
		fails,
		float(tight["fling"]) >= 0.0 and float(tight["fling"]) < 0.5,
		(
			"no room at all: the run is under MIN_FLING, which carjack.gd then keeps (%.2f m)"
			% float(tight["fling"])
		)
	)
	ran.append("throw_line")


# ------------------------------------------------------------------ the fixtures


## The car's driver's door as door_info reports it (world units, the car's frame).
func _door() -> Dictionary:
	return {
		"hinge": Vector3(HINGE.x, 0.58, HINGE.y) * WS.M,
		"open_rear": Vector3(FREE.x, 0.9, FREE.y) * WS.M,
	}


## Where the driver comes out: OUT past the body side, level with the seat (car frame x, z).
func _start() -> Vector2:
	return Vector2(HALF_W * WS.M + CJ.OUT, SEAT_Z * WS.M)


## A wall 3 m wide and 0.3 m thick across the +x line from the spot, its near face face out, from
## the ground up 3 m; or, with a ceiling, a metre-thick slab that high above the ground (an awning).
func _wall(face: float, ceiling: float) -> AABB:
	var a := Vector3(spot.x + face, spot.y, spot.z - 1.5 * WS.M)
	var b := Vector3(spot.x + face + 0.3 * WS.M, spot.y + 3.0 * WS.M, spot.z + 1.5 * WS.M)
	if ceiling > 0.0:
		a.y = spot.y + ceiling
		b.y = a.y + 1.0 * WS.M
	return AABB(a, b - a)


## A point with walkable ground and nothing built within a tile of it (the 3 m run, the lying
## body and a probe's margin all stay on it), NAN vector when the little city has none.
func _free_spot() -> Vector3:
	var col := ctx.collision
	for z in range(3, 28):
		for x in range(3, 28):
			var p := Vector3(float(x), 0.0, float(z))
			var ok := not is_nan(col.ground_height(p)) and col.boxes_near(p, 1.0, 0.0).is_empty()
			for q: Vector2 in [
				Vector2(0.1, 0.0), Vector2(-0.1, 0.0), Vector2(0.0, 0.1), Vector2(0.0, -0.1)
			]:
				ok = ok and not is_nan(col.ground_height(p + Vector3(q.x, 0.0, q.y)))
			if ok:
				p.y = col.ground_height(p)
				return p
	return Vector3(NAN, NAN, NAN)
