extends SceneTree
## Fallen street props keep a solid drawn body (round 3, rigidity): the knockdown marks the
## standing collider "down" and nothing else would block the way through the drawn mesh that
## lies there. Once a tumble rests, the props feature writes the lying box into the colliders
## meta (kind "fallen", no slot, so standing the prop up again can never leave it behind), and
## only once no body stands within it -- it never materializes around someone. The hero must
## stop against the fallen thing (or step onto it, when it lies short enough) instead of
## strolling through it, and standing it up again must take the box away.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const FIX := preload("res://tools/tests/support/props_fixture.gd")
const DT := 1.0 / 60.0
const R := WS.PLAYER_RADIUS
const BODY_H := WS.PLAYER_HEIGHT
## Overlap deeper than this (u) is a pass-through, not a touch.
const TOL := 0.002
## Sent flying faster than any knockable kind's threshold (m/s), so the first knock lands.
const KNOCK_MPS := 3.0
const DIRS := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]

var fails: Array[String] = []
var ctx: FpContext
var f: FpFeature


func _init() -> void:
	await process_frame
	var made := FIX.make(get_root())
	ctx = made["ctx"]
	f = made["f"]
	if f == null:
		K.check(fails, false, "fixture: the traffic and props features are registered")
		K.finish(self, "FP_FALLEN_PROPS_TEST", fails)
		return
	_knock_one()


## Knocks one standing knockable prop over and walks the whole lying-box lifecycle.
func _knock_one() -> void:
	var pick := FIX.pick_knockable(ctx, KNOCK_MPS)
	K.check(fails, not pick.is_empty(), "fixture: a knockable prop standing in the street")
	if pick.is_empty():
		K.finish(self, "FP_FALLEN_PROPS_TEST", fails)
		return
	var tile: int = pick["tile"]
	# The hero steps aside first: the lying box is written only once no body stands within it.
	var spot: Vector3 = pick["spot"]
	ctx.player.teleport(Vector3(spot.x + 5.0, spot.y, spot.z + 5.0), 0.0)
	var fell: bool = f.call(
		"knock", tile, int(pick["slot"]), spot, Vector3(KNOCK_MPS * WS.M, 0.0, 0.0)
	)
	var settled := FIX.settle(f, tile, int(pick["slot"]))
	K.check(
		fails,
		fell and not settled.is_empty(),
		(
			"a fallen prop writes its lying box once it rests (a %s fell %s, box written %s)"
			% [str(pick["kind"]), str(fell), str(not settled.is_empty())]
		)
	)
	if settled.is_empty():
		K.finish(self, "FP_FALLEN_PROPS_TEST", fails)
		return
	var lying_at := int(settled["fallen_tile"])
	var box := FIX.lying_box(ctx, tile, int(pick["slot"]))
	var res := _walk_through(box)
	var blocking := float(box.size.y) > WS.STEP_HEIGHT
	K.check(
		fails,
		float(res["depth"]) <= TOL and (not blocking or not bool(res["passed"])),
		(
			(
				"the hero never passes through a fallen %s (lying %.0f cm tall, deepest %.0f mm, "
				+ "got past %s)"
			)
			% [
				str(pick["kind"]),
				float(box.size.y) / WS.M * 100.0,
				float(res["depth"]) / WS.M * 1000.0,
				str(bool(res["passed"]))
			]
		)
	)
	f.call("stand_all")
	var gone := true
	var holder: Node3D = ctx.view.tile_holder(lying_at)
	if holder != null:
		for c: Variant in holder.get_meta("colliders", []):
			if typeof(c) == TYPE_DICTIONARY and str((c as Dictionary).get("kind", "")) == "fallen":
				gone = false
	K.check(fails, gone, "standing the prop up again takes the lying box away")
	K.finish(self, "FP_FALLEN_PROPS_TEST", fails)


## Walks the hero from the first clear direction straight through box: the deepest overlap with
## it (u) and whether the hero got past it. The depth ignores standing on top (feet at its
## top): a lying body short enough to step onto is walked over, never through.
func _walk_through(box: AABB) -> Dictionary:
	var res := {"depth": 0.0, "passed": false}
	if box.size.y < 0.05 * WS.M:
		return res
	var stand := 0.05 * WS.M
	for dir: Vector3 in DIRS:
		var half := absf(dir.x) * box.size.x * 0.5 + absf(dir.z) * box.size.z * 0.5
		var centre := Vector3(box.get_center().x, 0.0, box.get_center().z)
		var start := centre - dir * (half + R + stand)
		var g := ctx.collision.walk_height(start)
		if is_nan(g):
			continue
		start.y = g
		if ctx.collision.body_blocked(start, R * 1.02, BODY_H):
			continue
		var p := ctx.player
		var to := Vector3(centre.x, start.y, centre.z) - start
		to.y = 0.0
		to = to.normalized()
		p.teleport(start, rad_to_deg(atan2(-to.x, -to.z)))
		p.velocity = to * WS.WALK
		p.update_view(DT)
		var depth := 0.0
		var passed := false
		for _k in range(300):
			p.simulate(Vector2(0.0, 1.0), false, DT)
			p.update_view(DT)
			depth = maxf(depth, _box_depth(p.position, box))
			var s := (Vector3(p.position.x, 0.0, p.position.z) - centre).dot(
				Vector3(to.x, 0.0, to.z)
			)
			if s > half + R + 0.02:
				passed = true
				break
		res["depth"] = depth
		res["passed"] = passed
		return res
	return res


## How far p sits inside box (u): standing on top (feet at its top) does not count.
func _box_depth(p: Vector3, box: AABB) -> float:
	if p.y >= box.end.y - 1e-4 or box.position.y >= p.y + BODY_H - 1e-4:
		return 0.0
	var q := Vector2(clampf(p.x, box.position.x, box.end.x), clampf(p.z, box.position.z, box.end.z))
	return maxf(0.0, R - Vector2(p.x, p.z).distance_to(q))
