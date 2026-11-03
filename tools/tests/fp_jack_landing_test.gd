extends SceneTree
## Where a carjacked driver comes down (jack_landing.gd, the carjack_throw flag): straight out of
## the car's side from the seat, as far as the body can lie there, along the car's side as they sat.
## The open door (its outline in plan, the real panel with its thickness and glass, with the reach
## of the feet allowed for) is what the point they are let go at is moved down the car's side for,
## by the least that gets the line clear of it; the body's run is clear of what stands out there
## (the collision world's static boxes and posts, probed for the root and for the head the lying
## body reaches past it, toward the car's rear, and anyone on the pavement), the drop cut to that
## run.
## The geometry is pure (checked first); then the probe over a real collision world and bare
## walkers; then the whole drop_run the way carjack.gd asks for it, with the numbers of the real car
## and door the city test (fp_carjack_test) and its probes use (metres, in the car's frame: x out of
## the driver's side, z forward). The real doors of every model against the real skeleton are
## fp_jack_doors_test's.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const JL := preload("res://scripts/fp/traffic/jack_landing.gd")
const CJ := preload("res://scripts/fp/traffic/carjack.gd")
const HALF_W := 1.154
const SEAT_Z := -0.2
## The line out of the seat: the haul and the slide, from the sill.
const LEN := CJ.OUT + CJ.DROP_M * WS.M
## The open driver's door in plan (car_doors.gd outline, metres) of the first model, a coupe, whose
## long door hangs closest of any to the line out and needs the driver let go a little down the
## side, and of a van, whose door hangs close to the seat (its driver is let go further down the
## side). Half a dozen points of each hull, the real numbers.
const COUPE := [
	Vector2(0.90, 0.865),
	Vector2(1.63, 0.42),
	Vector2(2.31, 0.17),
	Vector2(2.38, 0.34),
	Vector2(1.39, 0.99),
	Vector2(0.93, 0.93),
]
## A door that hangs this much further up the car than the coupe's (m): the line is clear of it.
const FAR := 1.0
const VAN := [
	Vector2(0.96, 1.18),
	Vector2(1.15, 1.08),
	Vector2(1.83, 0.83),
	Vector2(1.87, 0.93),
	Vector2(1.0, 1.28),
]

var fails: Array[String] = []
var ran: Array[String] = []
var ctx: FpContext
var spot := Vector3.ZERO


func _init() -> void:
	await process_frame
	_check_geometry()
	_check_shift()
	ctx = K.make_ctx(get_root(), {"player": false, "hud": false})
	spot = _free_spot()
	K.check(fails, spot.is_finite(), "a bare piece of ground to drop across (%s)" % str(spot))
	if spot.is_finite():
		_check_free_run()
		_check_people()
		_check_drop_run()
	K.check(fails, ran.size() == 5, "every section ran to its end (%s)" % str(ran))
	K.finish(self, "FP_JACK_LANDING_TEST", fails)


# ------------------------------------------------------------------ the pure parts


## The distance from a point to the outline (negative inside) and what a line leaves clear of it
## once the feet's reach (FEET_REACH ahead of each point of it, less a limb) is allowed for.
func _check_geometry() -> void:
	var sq := _poly([Vector2(2, 1), Vector2(3, 1), Vector2(3, 2), Vector2(2, 2)])
	K.check(
		fails,
		is_equal_approx(JL.outline_dist(Vector2(2.5, 0.0) * WS.M, sq), 1.0 * WS.M),
		"a point a unit off a side of the outline"
	)
	K.check(
		fails,
		is_equal_approx(JL.outline_dist(Vector2(0.0, 0.0), sq), sqrt(5.0) * WS.M),
		"past a corner: the corner's distance"
	)
	K.check(
		fails,
		is_equal_approx(JL.outline_dist(Vector2(2.4, 1.5) * WS.M, sq), -0.4 * WS.M),
		"inside it: negative, the way out"
	)
	# A line along +x two units long at z = 0 passes a square (2..3, 1.5..2.5) 1.5 units off it,
	# which the feet, FEET_REACH ahead of each point of it, reach for: the gap is that distance less
	# the feet's reach and a limb.
	var far_sq := _poly([Vector2(2, 1.5), Vector2(3, 1.5), Vector2(3, 2.5), Vector2(2, 2.5)])
	var gap := JL.door_gap(Vector2.ZERO, 2.0 * WS.M, far_sq)
	var want := 1.5 * WS.M - JL.FEET_REACH - JL.LIMB
	K.check(
		fails,
		absf(gap - want) < 1e-4,
		(
			"a line's gap is the feet's distance less a limb (%.3f of %.3f m)"
			% [gap / WS.M, want / WS.M]
		)
	)
	var away := JL.door_gap(Vector2(0.0, -0.3 * WS.M), 2.0 * WS.M, far_sq)
	K.check(fails, away > gap, "let go further down the side (to the rear, -z) the gap is more")
	K.check(
		fails,
		JL.door_gap(Vector2(2.5, 1.5) * WS.M, 0.5 * WS.M, sq) < 0.0,
		"a line through the outline leaves nothing: negative"
	)
	# A door in the middle of the feet's reach, between the root and the end of it, is met all the
	# same: the whole of the reach is probed, not its end alone.
	var mid := _poly([Vector2(-0.2, 0.4), Vector2(0.2, 0.4), Vector2(0.2, 0.6), Vector2(-0.2, 0.6)])
	K.check(
		fails,
		JL.door_gap(Vector2.ZERO, 0.0, mid) < 0.0,
		"a door between the root and the end of the feet's reach is met"
	)
	ran.append("geometry")


## A door that hangs too close to the seat for the line straight out to keep the arms clear of it
## (a van's, a coupe's: the numbers measured on the real models, as the doors test has them all):
## the point the body is let go at moved down the car's side by the least that gets the line
## SHIFT_MARGIN clear, never past SHIFT_MAX, none where there is no need.
func _check_shift() -> void:
	var van_pan := _poly(VAN)
	var van_start := Vector2(1.225, 0.67) * WS.M
	var straight := JL.door_gap(van_start, LEN, van_pan)
	K.check(
		fails,
		straight < JL.SHIFT_MARGIN,
		(
			"a van's door: straight out is %.2f m clear, short of SHIFT_MARGIN (%.3f)"
			% [straight / WS.M, JL.SHIFT_MARGIN / WS.M]
		)
	)
	var shift := JL.exit_shift(van_start, LEN, van_pan)
	var moved := Vector2(van_start.x, van_start.y - shift)
	K.check(
		fails,
		shift > 0.0 and shift <= JL.SHIFT_MAX and JL.door_gap(moved, LEN, van_pan) > straight,
		(
			"the van's driver is let go %.2f m down the side: the line %.2f m clear (was %.2f)"
			% [shift / WS.M, JL.door_gap(moved, LEN, van_pan) / WS.M, straight / WS.M]
		)
	)
	var less := Vector2(van_start.x, van_start.y - (shift - JL.SHIFT_STEP))
	K.check(
		fails,
		shift >= JL.SHIFT_MAX - 1e-9 or JL.door_gap(less, LEN, van_pan) < JL.SHIFT_MARGIN,
		"and by the least it takes: a step less is short of SHIFT_MARGIN"
	)
	var coupe_shift := JL.exit_shift(_start(), LEN, _poly(COUPE))
	K.check(
		fails,
		coupe_shift > 0.0 and coupe_shift <= JL.SHIFT_MAX,
		"a coupe's driver is let go a little down the side (%.2f m)" % (coupe_shift / WS.M)
	)
	K.check(
		fails,
		JL.exit_shift(_start(), LEN, _far()) == 0.0,
		(
			"a door further off than that needs none (its line is %.2f m clear)"
			% (JL.door_gap(_start(), LEN, _far()) / WS.M)
		)
	)
	K.check(fails, JL.exit_shift(van_start, LEN, PackedVector2Array()) == 0.0, "no door, no shift")
	var moved_coupe := Vector2(_start().x, _start().y - coupe_shift)
	K.check(
		fails,
		JL.door_gap(moved_coupe, LEN, _poly(COUPE)) >= JL.SHIFT_MARGIN,
		"and where it is let go the line is SHIFT_MARGIN clear of the door"
	)
	var hug := _poly([Vector2(1.0, -1.0), Vector2(3.0, -1.0), Vector2(3.0, 1.2), Vector2(1.0, 1.2)])
	K.check(
		fails,
		is_equal_approx(JL.exit_shift(van_start, LEN, hug), JL.SHIFT_MAX),
		"a door that no shift gets clear of: the most, SHIFT_MAX"
	)
	ran.append("shift")


# ------------------------------------------------------------------ the world


## The run over the collision world: a wall's face WALL m out stops the run where the root would
## meet it (it lies along the car's side, so only the root is out in front); a post the same; a wall
## behind, where the head lies, stops it there; a wall along the line is none, nor one high above;
## no water.
func _check_free_run() -> void:
	var col := ctx.collision
	var xf := Transform3D(Basis.IDENTITY, spot)
	var start := Vector2(0.0, 0.0)
	var none := PackedVector2Array()
	var open: Array[AABB] = []
	K.check(
		fails,
		is_equal_approx(JL.free_run(xf, start, LEN, col, open, none), LEN),
		"open ground: the whole run"
	)
	K.check(
		fails,
		is_equal_approx(JL.free_run(xf, start, LEN, null, open, none), LEN),
		"no collision world: the whole run"
	)
	var face := 1.5 * WS.M
	var box := _wall(face, 0.0)
	col.add_test_box(box)
	var boxes := col.boxes_near(spot, 1.0, 0.0)
	var run := JL.free_run(xf, start, LEN, col, boxes, none)
	var want := face - JL.ROOT_R
	K.check(
		fails,
		run <= want + 1e-6 and run > want - 1.5 * JL.PROBE,
		(
			"a wall's face 1.5 m out stops the run where the root would meet it (%.2f m of %.2f)"
			% [run / WS.M, want / WS.M]
		)
	)
	col.clear_test_boxes()
	col.add_test_cylinder(spot.x + 1.8 * WS.M, spot.z, 0.15 * WS.M, 3.0 * WS.M)
	boxes = col.boxes_near(spot, 1.0, 0.0)
	run = JL.free_run(xf, start, LEN, col, boxes, none)
	want = 1.8 * WS.M - 0.15 * WS.M - JL.ROOT_R
	K.check(
		fails,
		run <= want + 1e-6 and run > want - 1.5 * JL.PROBE,
		(
			"a lamp post 1.8 m out: the run ends short of it (%.2f m of %.2f)"
			% [run / WS.M, want / WS.M]
		)
	)
	col.clear_test_boxes()
	K.check(
		fails,
		is_equal_approx(
			JL.free_run(xf, start, LEN, col, col.boxes_near(spot, 1.0, 0.0), none), LEN
		),
		"and with it gone the whole run again"
	)
	# The head lies toward the car's rear: a wall behind the root, where it would be, stops it.
	var behind := AABB(
		Vector3(spot.x - 1.0 * WS.M, spot.y, spot.z - (JL.LIE_FAR + 0.3 * WS.M)),
		Vector3(5.0 * WS.M, 3.0 * WS.M, 0.3 * WS.M)
	)
	col.add_test_box(behind)
	boxes = col.boxes_near(spot, 3.0 * WS.M, 0.0)
	K.check(
		fails,
		JL.free_run(xf, start, LEN, col, boxes, none) < 0.5 * LEN,
		"a wall where the head would lie, toward the car's rear, stops it"
	)
	col.clear_test_boxes()
	# A wall along the line, a body's width off it: nothing in the way.
	var along := AABB(
		Vector3(spot.x - 1.0 * WS.M, spot.y, spot.z + 1.6 * WS.M),
		Vector3(5.0 * WS.M, 3.0 * WS.M, 0.3 * WS.M)
	)
	col.add_test_box(along)
	boxes = col.boxes_near(spot, 3.0 * WS.M, 0.0)
	K.check(
		fails,
		is_equal_approx(JL.free_run(xf, start, LEN, col, boxes, none), LEN),
		"a wall running along the line, well to the side: nothing in the way"
	)
	col.clear_test_boxes()
	col.add_test_box(_wall(face, 4.0 * WS.M))
	boxes = col.boxes_near(spot, 1.0, 0.0)
	K.check(
		fails,
		is_equal_approx(JL.free_run(xf, start, LEN, col, boxes, none), LEN),
		"a ceiling above the body (an awning) is no wall"
	)
	col.clear_test_boxes()
	ran.append("free_run")


## Someone in the line is in the way; the victim, the gone and those out of reach are not.
func _check_people() -> void:
	var xf := Transform3D(Basis(Vector3.UP, 0.7), spot)
	var origin := xf * Vector3.ZERO
	var at := func(m_out: float, m_along: float) -> WK.Walker:
		var w := WK.Walker.new()
		w.pos = xf * Vector3(m_out * WS.M, 0.0, m_along * WS.M)
		w.id = 7 + int(m_out * 10.0)
		w.state = "walk"
		return w
	var ahead: WK.Walker = at.call(1.6, 0.0)
	var all: Array = [ahead]
	var near := JL.standing(all, -1, origin, 4.0 * WS.M)
	var none: Array[AABB] = []
	var run := JL.free_run(xf, Vector2.ZERO, LEN, null, none, near)
	var want := 1.6 * WS.M - JL.PED_CLEAR
	K.check(
		fails,
		near.size() == 1 and run <= want + 1e-6 and run > want - 1.5 * JL.PROBE,
		(
			"someone 1.6 m out in the line: the run ends short of them (%.2f m of %.2f)"
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
	K.check(fails, JL.standing(all, -1, origin, 0.5 * WS.M).is_empty(), "nor someone out of reach")
	var aside: WK.Walker = at.call(1.6, 1.5)
	near = JL.standing([aside], -1, origin, 4.0 * WS.M)
	run = JL.free_run(xf, Vector2.ZERO, LEN, null, none, near)
	K.check(
		fails,
		is_equal_approx(run, LEN),
		"someone 1.5 m ahead along the car, past the feet, is not in it (%.2f m)" % (run / WS.M)
	)
	# The head lies toward the car's rear, LIE_FAR past the root: someone just past it is in the
	# way.
	var beyond: WK.Walker = at.call(1.1, -1.2)
	near = JL.standing([beyond], -1, origin, 4.0 * WS.M)
	run = JL.free_run(xf, Vector2.ZERO, LEN, null, none, near)
	K.check(
		fails,
		near.size() == 1 and run < 0.6 * LEN,
		(
			"someone just past where the head lies, toward the rear, is in it (%.2f m of %.2f)"
			% [run / WS.M, LEN / WS.M]
		)
	)
	ran.append("people")


## The whole drop as carjack.gd asks for it: the real car's frame and a bystander where the head
## would lie, with and without them; the same twice; no room at all is under MIN_DROP, which
## carjack.gd then keeps.
func _check_drop_run() -> void:
	var xf := Transform3D(Basis(Vector3.UP, 0.7), spot)
	var start := _start()
	var col := ctx.collision
	var clear := JL.drop_run(xf, start, CJ.DROP_M, col, [], -1)
	K.check(
		fails,
		is_equal_approx(clear, CJ.DROP_M),
		"open ground: the whole drop of %.2f m (%.2f)" % [CJ.DROP_M, clear]
	)
	var someone := WK.Walker.new()
	someone.id = 41
	someone.state = "walk"
	someone.pos = xf * Vector3(start.x + 1.0 * WS.M, 0.0, start.y)
	var blocked := JL.drop_run(xf, start, CJ.DROP_M, col, [someone], -1)
	K.check(
		fails,
		blocked < CJ.DROP_M,
		"someone where they would land: a shorter drop (%.2f m of %.2f)" % [blocked, CJ.DROP_M]
	)
	var gone := JL.drop_run(xf, start, CJ.DROP_M, col, [someone], someone.id)
	K.check(fails, is_equal_approx(gone, clear), "the victim themself is no obstacle")
	K.check(
		fails,
		JL.drop_run(xf, start, CJ.DROP_M, col, [someone], -1) == blocked,
		"the same street, the same drop"
	)
	var all_blocked := WK.Walker.new()
	all_blocked.id = 42
	all_blocked.state = "walk"
	all_blocked.pos = xf * Vector3(start.x + 0.2 * WS.M, 0.0, start.y)
	var tight := JL.drop_run(xf, start, CJ.DROP_M, col, [all_blocked], -1)
	K.check(
		fails,
		tight >= 0.0 and tight < CJ.MIN_DROP,
		"no room at all: the run is under MIN_DROP, which carjack.gd then keeps (%.2f m)" % tight
	)
	ran.append("drop_run")


# ------------------------------------------------------------------ the fixtures


## The coupe's door hung FAR m further up the car: the line is clear of it, no shift is needed.
func _far() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Vector2 in COUPE:
		out.append((p + Vector2(0.0, FAR)) * WS.M)
	return out


## A door outline given in metres (the car's frame) as the world units the planner takes.
func _poly(pts: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Vector2 in pts:
		out.append(p * WS.M)
	return out


## Where the driver is let go from: the body side, level with the seat (car frame x, z).
func _start() -> Vector2:
	return Vector2(HALF_W * WS.M, SEAT_Z * WS.M)


## A wall 3 m wide and 0.3 m thick across the +x line from the spot, its near face face out, from
## the ground up 3 m; or, with a ceiling, a metre-thick slab that high above the ground (an awning).
func _wall(face: float, ceiling: float) -> AABB:
	var a := Vector3(spot.x + face, spot.y, spot.z - 1.5 * WS.M)
	var b := Vector3(spot.x + face + 0.3 * WS.M, spot.y + 3.0 * WS.M, spot.z + 1.5 * WS.M)
	if ceiling > 0.0:
		a.y = spot.y + ceiling
		b.y = a.y + 1.0 * WS.M
	return AABB(a, b - a)


## A point with walkable ground and nothing built within a tile of it (the run, the lying body and
## a probe's margin all stay on it), NAN vector when the little city has none.
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
