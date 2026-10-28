extends SceneTree
## The low-shape collision matrix (round 4, item 3): what every mover does with a collider
## whose top sits under WS.STEP_HEIGHT (25 cm), measured at the junction signal plinth -- a
## 0.57 x 0.15 x 0.57 m box on the sidewalk with the pole's shaft on it -- and at test boxes
## straddling the step boundary. The matrix exists so a low prop collider added later is
## tested per mover, not assumed to block everything alike.
##
## Which mover reads which collider data (the contract this suite pins):
##
## - The hero (and anything driven through move_body with a STEP_HEIGHT max_rise: reacting
##   walkers' held/slide moves, animals, the hero's knock-down slide) steps ONTO a top within
##   25 cm of the feet -- collision_world.support_height adopts the low top as the ground and
##   _can_stand lets the move pass, the caller snaps y. A low box is never a horizontal
##   barrier to them; above 25 cm it blocks.
## - A walking walker never queries collision at all (walkers.gd writes w.pos along its
##   edge); low junction posts are avoided at the data level -- rebuild_posts feeds the pole
##   points to _walk_edge's sidestep, which routes the lane around them.
## - An airborne or posed body is pressed OUT of a low box by body_spheres.press_out, which
##   reads boxes_near + cylinders with no step allowance and no height exemption inside the
##   box's y-span; the only exemption is a sphere resting dead-centre on the lid or hanging
##   under (the way clear there is vertical), so nothing is shoved off a rest.
## - A car reads the world through body_contacts.gather with top = feet + STEP_HEIGHT: a box
##   whose top is at most 25 cm above the car's feet is nosed over like a curb and only the
##   shaft holds the stop. Caveat pinned below: the plinth top is 27 cm over ASPHALT, so a
##   car whose feet are still at road level technically gathers it; the curb mount snaps the
##   feet to sidewalk height before the bumper reaches the plinth, so the shaft owns every
##   real stop.

const K := preload("res://tools/tests/fp_kit.gd")
const FIX := preload("res://tools/tests/support/props_fixture.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const JN := preload("res://scripts/fp/traffic/junctions.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const BS := preload("res://scripts/fp/traffic/body_spheres.gd")
const BC := preload("res://scripts/fp/body_contacts.gd")

const DT := 1.0 / 60.0
const STRENGTH := 0.95
## 5 mm: the press tolerance the react suite holds bodies to.
const TOL := 0.005 * WS.M
## A sweep-driven overlap must clear within this; the react suite's bound.
const CLEAR_S := 0.25
const BODY_R := 0.25 * WS.M
const HEAD_R := 0.14 * WS.M

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var wk: WK
var react: RefCounted
var pe: Object


func _init() -> void:
	var m := FIX.make(get_root())
	ctx = m["ctx"]
	tr = m["tr"]
	if tr == null:
		K.check(fails, false, "fixture: the traffic feature")
		K.finish(self, "FP_LOW_SHAPES_TEST", fails)
		return
	wk = tr.get("walkers")
	react = tr.get("reactions")
	pe = tr.get("people")
	var pole := _find_pole()
	if pole == Vector3.INF:
		K.check(fails, false, "fixture: a cross tile with E's corner poles")
		K.finish(self, "FP_LOW_SHAPES_TEST", fails)
		return
	_check_hero_steps_then_shaft(pole)
	_check_walkers_sidestep(pole)
	_check_fall_beside_plinth(pole)
	_check_fall_on_plinth(pole)
	_check_throw_at_plinth(pole)
	_check_press_exemptions(pole)
	_check_car_oracle(pole)
	_check_step_boundary()
	K.finish(self, "FP_LOW_SHAPES_TEST", fails)


## The first cross tile's NE corner pole in world units, or Vector3.INF when there is none.
func _find_pole() -> Vector3:
	var jn = tr.get("junctions")
	for i: int in jn.props.keys():
		var piece := str(RoadTopology.piece(RoadTopology.mask(ctx.sim, D.tx(i), D.ty(i)))[0])
		if piece == "cross" and (jn.props[i].get("poles", []) as Array).size() >= 4:
			var c: Vector2 = JN.CORNERS[0] * JN.POLE_AT
			return Vector3(D.tx(i) + c.x, WS.SIDEWALK_TOP, D.ty(i) + c.y)
	return Vector3.INF


## The plinth box in world units, base-centre the pole axis.
func _plinth(pole: Vector3) -> AABB:
	return AABB(
		Vector3(pole.x - 0.285 * WS.M, pole.y, pole.z - 0.285 * WS.M),
		Vector3(0.57 * WS.M, 0.15 * WS.M, 0.57 * WS.M)
	)


## Signed depth of sphere q/r against the box: negative = overlapping by that much.
func _box_depth(q: Vector3, r: float, b: AABB) -> float:
	var cx := clampf(q.x, b.position.x, b.end.x)
	var cy := clampf(q.y, b.position.y, b.end.y)
	var cz := clampf(q.z, b.position.z, b.end.z)
	var d := Vector3(cx, cy, cz).distance_to(q)
	if d > 1e-9:
		return d - r
	return -(
		minf(minf(q.x - b.position.x, b.end.x - q.x), minf(q.z - b.position.z, b.end.z - q.z)) + r
	)


func _victim(at: Vector3, dir: Vector3) -> WK.Walker:
	var w := wk.make("ambient")
	wk.stand(w, at, atan2(dir.x, dir.z))
	return w


func _extent() -> Callable:
	return func(w, feet: Vector3) -> Array[Vector3]: return BS.of(feet, pe.call("head_of", w, feet))


## Knocks the walker down with the given cause/fling and watches all three body spheres
## against the plinth for the whole reaction: [deepest overlap (u), longest run above TOL
## (s), end overlap (u)].
func _fall_watch(pole: Vector3, at: Vector3, dir: Vector3, cause: String, fling_m: float) -> Array:
	var plinth := _plinth(pole)
	var w := _victim(at, dir)
	var src := at - dir * (0.5 * WS.M)
	var ret: Dictionary = react.call("hit", w, src, dir * WS.M, STRENGTH, cause, fling_m)
	K.check(fails, bool(ret.get("down", false)), "fixture: the hit knocks them down (%s)" % cause)
	var deepest := 0.0
	var run := 0
	var longest := 0
	var t := 0.0
	while t < 8.0:
		tr.call("step", DT)
		tr.call("sync_visuals", DT)
		t += DT
		var feet: Vector3 = w.pos + w.vis_off
		var head: Vector3 = pe.call("head_of", w, feet)
		var mid := feet.lerp(head, 0.55)
		var d := maxf(
			-_box_depth(feet, BODY_R, plinth),
			maxf(-_box_depth(mid, BODY_R, plinth), -_box_depth(head, HEAD_R, plinth))
		)
		deepest = maxf(deepest, d)
		if d > TOL:
			run += 1
			longest = maxi(longest, run)
		else:
			run = 0
	var end_feet: Vector3 = w.pos + w.vis_off
	var end_head: Vector3 = pe.call("head_of", w, end_feet)
	var end_d := maxf(
		-_box_depth(end_feet, BODY_R, plinth),
		maxf(
			-_box_depth(end_feet.lerp(end_head, 0.55), BODY_R, plinth),
			-_box_depth(end_head, HEAD_R, plinth)
		)
	)
	wk.remove(w)
	return [deepest, longest * DT, maxf(end_d, 0.0)]


## Ground hero: the walk steps onto the 15 cm plinth like a curb (feet reach its top), then
## the shaft holds the stop at shaft radius + player radius from the axis, nothing embedded.
func _check_hero_steps_then_shaft(pole: Vector3) -> void:
	var out := Vector3(JN.CORNERS[0].x, 0, JN.CORNERS[0].y).normalized()
	var p = ctx.player
	var start := pole + out * (1.4 * WS.M)
	start.y = ctx.collision.walk_height(start)
	p.teleport(start, rad_to_deg(atan2(out.x, out.z)))
	p.velocity = -out * WS.WALK
	p.input_enabled = false
	var top := 0.0
	var near := INF
	for _k in range(300):
		p.simulate(Vector2(0.0, 1.0), false, DT)
		p.update_view(DT)
		top = maxf(top, p.position.y)
		near = minf(near, Vector2(p.position.x - pole.x, p.position.z - pole.z).length())
	var plinth_top: float = pole.y + 0.15 * WS.M
	K.check(
		fails,
		absf(top - plinth_top) <= 0.02 * WS.M,
		(
			"the hero steps onto the plinth like a curb (feet top %.3f m, plinth top %.3f m)"
			% [top / WS.M, plinth_top / WS.M]
		)
	)
	var stop := (0.11 + 0.30) * WS.M
	K.check(
		fails,
		near >= stop - 0.01 * WS.M and near <= stop + 0.05 * WS.M,
		(
			"then the shaft holds the stop (%.3f m from the axis, shaft+radius %.3f m)"
			% [near / WS.M, stop / WS.M]
		)
	)
	# The fixture's hero rig is detached from the tree: bone_world must answer its NaN
	# sentinel (callers read NaN as "skip", never as a position), and the walk's foot
	# contacts must never carry a NaN or garbage position from such a rig.
	var rig: Variant = p.avatar.get("rig")
	var hw: Vector3 = rig.call("bone_world", "Hips")
	K.check(
		fails, is_nan(hw.x), "an off-tree rig's bone_world answers the NaN sentinel, not a position"
	)
	var bad_contacts := 0
	for c: Dictionary in rig.get("contacts"):
		var cp: Vector3 = c["pos"]
		if is_nan(cp.x) or is_nan(cp.y) or is_nan(cp.z):
			bad_contacts += 1
	K.check(
		fails, bad_contacts == 0, "foot contacts never carry a NaN position (%d)" % bad_contacts
	)


## Walking walkers: never a collision query -- the pole point is in the sidestep data and the
## crowd's lane bends around it. A crowd walked the cross tile's edges must never come within
## the plinth's reach of the axis.
func _check_walkers_sidestep(pole: Vector3) -> void:
	var tile := D.idx(roundi(pole.x), roundi(pole.z))
	var spawned := 0
	for e in wk.sw.by_tile.get(tile, []):
		if e == null or e.zebra or not e.alive:
			continue
		for k in range(4):
			wk.place(wk.make("ambient"), e, e.length * (0.15 + 0.2 * k), 1 if k % 2 == 0 else -1)
			spawned += 1
	K.check(fails, spawned >= 12, "fixture: a crowd on the cross tile's edges (%d)" % spawned)
	var near := INF
	var close := 0
	for _k in range(1200):
		tr.call("step", DT)
		tr.call("sync_visuals", DT)
		for w in wk.walkers:
			var d := Vector2(w.pos.x - pole.x, w.pos.z - pole.z).length()
			if d < 2.0 * WS.M:
				close += 1
				near = minf(near, d)
	K.check(fails, close > 0, "fixture: walkers really passed the pole (%d samples)" % close)
	K.check(
		fails,
		near >= 0.5 * WS.M,
		(
			"walking walkers sidestep the pole at the data level (nearest %.2f m, floor 0.50 m)"
			% (near / WS.M)
		)
	)
	for w in wk.walkers.duplicate():
		wk.remove(w)


## A body knocked down half a metre out, falling across the plinth: nothing embeds, the rest
## is clear of the base.
func _check_fall_beside_plinth(pole: Vector3) -> void:
	var out := Vector3(JN.CORNERS[0].x, 0, JN.CORNERS[0].y).normalized()
	var at := pole + out * (0.55 * WS.M)
	at.y = ctx.collision.walk_height(at)
	var got := _fall_watch(pole, at, -out, "punch", 0.4)
	K.check(
		fails,
		float(got[1]) <= CLEAR_S and float(got[2]) <= TOL,
		(
			"a fall across the plinth never embeds (deepest %.0f mm, longest %.2f s, end %.0f mm)"
			% [float(got[0]) / WS.M * 1000.0, float(got[1]), float(got[2]) / WS.M * 1000.0]
		)
	)


## Knocked down while standing ON the plinth (a thrown body can land there): the fold's deep
## transient is pressed out within the sweep bound and the body ends clear beside the base.
func _check_fall_on_plinth(pole: Vector3) -> void:
	var out := Vector3(JN.CORNERS[0].x, 0, JN.CORNERS[0].y).normalized()
	var at := Vector3(pole.x, ctx.collision.walk_height(pole), pole.z)
	var got := _fall_watch(pole, at, -out, "punch", 0.2)
	K.check(
		fails,
		float(got[1]) <= CLEAR_S and float(got[2]) <= TOL,
		(
			"a fall on the plinth clears (deepest %.0f mm, longest %.2f s of %.2f s, end %.0f mm)"
			% [float(got[0]) / WS.M * 1000.0, float(got[1]), CLEAR_S, float(got[2]) / WS.M * 1000.0]
		)
	)


## A 1 m throw at the pole: the arc and the throw_impact bounce never leave the body in the
## base.
func _check_throw_at_plinth(pole: Vector3) -> void:
	var out := Vector3(JN.CORNERS[0].x, 0, JN.CORNERS[0].y).normalized()
	var at := pole + out * (0.9 * WS.M)
	at.y = ctx.collision.walk_height(at)
	var got := _fall_watch(pole, at, -out, "car", 1.0)
	K.check(
		fails,
		float(got[1]) <= CLEAR_S and float(got[2]) <= TOL,
		(
			"a throw at the plinth never sticks (deepest %.0f mm, longest %.2f s, end %.0f mm)"
			% [float(got[0]) / WS.M * 1000.0, float(got[1]), float(got[2]) / WS.M * 1000.0]
		)
	)


## The press-out's only height exemption: dead-centre on the lid stays (a rest), a sphere into
## the side is pressed out exactly the overlap, and the same overlap lifted past the box's top
## is left alone.
func _check_press_exemptions(pole: Vector3) -> void:
	var plinth := _plinth(pole)
	var ext := _extent()
	var w := _victim(Vector3(pole.x, plinth.end.y, pole.z), Vector3.FORWARD)
	w.vis_off = Vector3.ZERO
	BS.press_out(w, ext, ctx.collision, [])
	K.check(
		fails,
		w.vis_off.length() <= TOL,
		"a body resting on the lid is not shoved (press %.3f m)" % (w.vis_off.length() / WS.M)
	)
	# Into the +x face near the corner, clear of the shaft: pressed back exactly the overlap.
	var side := Vector3(pole.x + 0.34 * WS.M, WS.SIDEWALK_TOP, pole.z + 0.28 * WS.M)
	wk.stand(w, side, 0.0)
	w.vis_off = Vector3.ZERO
	BS.press_out(w, ext, ctx.collision, [])
	var want := (0.25 - (0.34 - 0.285)) * WS.M
	K.check(
		fails,
		absf(w.vis_off.x - want) <= 0.01 * WS.M and absf(w.vis_off.z) <= TOL,
		(
			"a sphere into the plinth's side is pressed out the overlap (%.3f m, want %.3f m)"
			% [w.vis_off.x / WS.M, want / WS.M]
		)
	)
	# The same side overlap with the body lifted past the box's top: untouched.
	wk.stand(w, Vector3(side.x, plinth.end.y + 0.30 * WS.M, side.z), 0.0)
	w.vis_off = Vector3.ZERO
	BS.press_out(w, ext, ctx.collision, [])
	K.check(
		fails,
		w.vis_off.length() <= TOL,
		(
			"the same overlap past the plinth's top is left alone (press %.3f m)"
			% (w.vis_off.length() / WS.M)
		)
	)
	wk.remove(w)


## The car's eye: body_contacts.gather with top = feet + STEP_HEIGHT. Feet at sidewalk height:
## the plinth is under the step (nosed over like a curb) and only the shaft is an obstacle.
## Feet still at asphalt (before the curb mount snaps them up): the plinth top is 27 cm over
## the road, 2 cm past the step, so it IS gathered -- the curb mount, not the filter, is what
## keeps real stops at the shaft.
func _check_car_oracle(pole: Vector3) -> void:
	var plinth := _plinth(pole)
	var c := Vector2(pole.x, pole.z)
	var on: Dictionary = BC.gather(ctx.collision, c, 1.5 * WS.M, WS.SIDEWALK_TOP, 1.5 * WS.M)
	K.check(
		fails,
		not _has_box(on, plinth) and _has_shaft(on, c),
		"a car on the sidewalk noses over the plinth; the shaft holds the stop"
	)
	var off: Dictionary = BC.gather(ctx.collision, c, 1.5 * WS.M, WS.ASPHALT_TOP, 1.5 * WS.M)
	K.check(
		fails,
		_has_box(off, plinth),
		"before the curb mount (feet at road level) the plinth is 2 cm over the step and gathers"
	)


func _has_box(got: Dictionary, plinth: AABB) -> bool:
	for b: AABB in got["boxes"]:
		if (
			b.position.distance_to(plinth.position) < 0.001
			and b.size.distance_to(plinth.size) < 0.001
		):
			return true
	return false


func _has_shaft(got: Dictionary, c: Vector2) -> bool:
	var cy: PackedFloat32Array = got["cyls"]
	for k in range(0, cy.size(), 3):
		var near_axis := Vector2(cy[k], cy[k + 1]).distance_to(c) < 0.05 * WS.M
		if near_axis and absf(cy[k + 2] - 0.11 * WS.M) < 0.01 * WS.M:
			return true
	return false


## The step boundary itself, on test boxes: 15 cm of box on the sidewalk is a support the
## mover steps onto; 30 cm is a wall the move refuses. The city's curb (12 cm) steps the same
## way -- support_height adopts the sidewalk top from asphalt feet.
func _check_step_boundary() -> void:
	var spot := Vector3(2.5, 0.0, 2.5)
	spot.y = ctx.collision.ground_height(spot)
	var stepped: float = ctx.collision.support_height(
		spot, WS.PLAYER_RADIUS, spot.y, WS.STEP_HEIGHT
	)
	K.check(fails, not is_nan(stepped), "fixture: plain ground is a support")
	# A 15 cm box: steppable.
	var low := AABB(
		spot + Vector3(0.6 * WS.M, 0, -0.3 * WS.M), Vector3(0.6 * WS.M, 0.15 * WS.M, 0.6 * WS.M)
	)
	ctx.collision.add_test_box(low)
	var on_low: float = ctx.collision.support_height(
		low.get_center(), WS.PLAYER_RADIUS, spot.y, WS.STEP_HEIGHT
	)
	K.check(
		fails,
		absf(on_low - low.end.y) <= 1e-6,
		(
			"a 15 cm box is a support the mover steps onto (top %.3f m, got %.3f m)"
			% [low.end.y / WS.M, on_low / WS.M]
		)
	)
	var to := ctx.collision.move_body(
		spot + Vector3(0.1 * WS.M, 0, 0),
		Vector3(0.5 * WS.M, 0, 0),
		WS.PLAYER_RADIUS,
		1.7 * WS.M,
		WS.STEP_HEIGHT
	)
	K.check(
		fails,
		low.has_point(Vector3(to.x, spot.y, to.z)),
		"the step-up move crosses onto the low box"
	)
	ctx.collision.clear_test_boxes()
	# A 30 cm box: not a support, and the walk stops at its face.
	var high := AABB(
		spot + Vector3(0.6 * WS.M, 0, -0.3 * WS.M), Vector3(0.6 * WS.M, 0.30 * WS.M, 0.6 * WS.M)
	)
	ctx.collision.add_test_box(high)
	var on_high: float = ctx.collision.support_height(
		high.get_center(), WS.PLAYER_RADIUS, spot.y, WS.STEP_HEIGHT
	)
	K.check(
		fails,
		on_high < high.end.y,
		"a 30 cm box is not a support within the 25 cm step (got %.3f m)" % (on_high / WS.M)
	)
	var to2 := ctx.collision.move_body(
		spot + Vector3(0.1 * WS.M, 0, 0),
		Vector3(0.5 * WS.M, 0, 0),
		WS.PLAYER_RADIUS,
		1.7 * WS.M,
		WS.STEP_HEIGHT
	)
	K.check(
		fails,
		to2.x <= high.position.x + 1e-6,
		(
			"the walk stops at the 30 cm box's face (x %.3f m, face %.3f m)"
			% [to2.x / WS.M, high.position.x / WS.M]
		)
	)
	ctx.collision.clear_test_boxes()
