extends SceneTree
## Hero vs street props, per class (round 3, rigidity): no pass-throughs. Every solid class the
## street puts out -- the batched street placements (benches, bins, hydrants, bollards, meters,
## mailboxes, planters, utility boxes, racks, trees, lamps and the knockable clutter), the
## colliders-meta props (bus shelters, lease boards, billboards, sign poles, the cul-de-sac tree,
## the baked lamp poles), E's junction posts (signal poles, pedestrian signals, stop signs),
## parked cars, the site backhoe, a standing
## bicycle and construction-site hoarding -- has samples the hero walks into from up to four
## directions at walking pace: the hero must stop against it, knock it over (the clutter that
## gives way) or step onto it, and never end up inside its collider or its visual bounds. Standing
## placements keep a live, on-the-spot collider entry, and the test prints a visual-vs-collider
## coverage report per kind.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const AMB := preload("res://scripts/fp/traffic/ambient.gd")
const JN := preload("res://scripts/fp/traffic/junctions.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const PF := preload("res://scripts/fp/props/props_feature.gd")
const DT := 1.0 / 60.0
const R := WS.PLAYER_RADIUS
const BODY_H := WS.PLAYER_HEIGHT
## Overlap deeper than this (u) is a pass-through, not a touch.
const TOL := 0.002
## The hero starts this far (u) beyond touching distance of a shape.
const STANDOFF := 0.045
const DIRS := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]
## Placement kinds that are walkable on purpose (flat, no collider).
const FLAT_KINDS := ["pit", "ramp", "apron"]
## Clutter that goes over at walking pace (props KINDS: person threshold under WS.WALK).
const KNOCK_AT_WALK := ["cone", "carton"]
## Colliders-meta kinds that are not street placements.
const META_KINDS := ["shelter", "lease", "billboard", "sign", "lamp", "tree"]
## At most this many targets are walked per kind (this many scanned for a clear approach).
const WALKED := 3
const SCANNED := 6
## Shared props fixture: the grown city in fp mode with the traffic/props features attached
## (support/props_fixture.gd, on top of support/city_fixtures.gd's tile fixtures).
const FIX := preload("res://tools/tests/support/props_fixture.gd")

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var f: FpFeature
## Every parked vehicle's world box (with the target it belongs to): starts and approach paths
## stay out of all the others.
var _car_boxes: Array = []


func _init() -> void:
	await process_frame
	var made := FIX.make(get_root(), {"tee": true, "site": true, "jcb": true})
	ctx = made["ctx"]
	tr = made["tr"]
	f = made["f"]
	if tr == null or f == null:
		K.check(fails, false, "fixture: the traffic and props features are registered")
		K.finish(self, "FP_PROP_COLLISION_TEST", fails)
		return
	var targets := _targets()
	_check_colliders(targets)
	_check_post_colliders(targets)
	_check_remount(targets)
	_check_walk(targets)
	_check_building_meta_silent()
	_print_report(targets)
	K.finish(self, "FP_PROP_COLLISION_TEST", fails)


# ------------------------------------------------------------------ fixtures

# ------------------------------------------------------------------ targets


## Every walk-in target: {"kind", "tile", "slot", "shapes" ({"box": AABB} or
## {"c": Vector2, "r": float, "top": float}), "spot" (world, on the ground), "knock", "soft",
## "xf" (the placement transform, placements only)}.
func _targets() -> Array:
	var out: Array = []
	_placements(out)
	_meta_only(out)
	_junction_poles(out)
	_vehicles(out)
	_sites(out)
	return out


func _placements(out: Array) -> void:
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD:
			continue
		var holder := ctx.view.tile_holder(i)
		if holder == null:
			continue
		var placed: Array = ctx.view.street_placements(i)
		var index := _shape_index(holder)
		for slot in range(placed.size()):
			var kind := str(placed[slot][0])
			if FLAT_KINDS.has(kind):
				continue
			var xf: Transform3D = placed[slot][1]
			(
				out
				. append(
					{
						"kind": kind,
						"tile": i,
						"slot": slot,
						"shapes": index.get(_slot_key(kind, slot), []),
						"spot": xf.origin,
						"knock": KNOCK_AT_WALK.has(kind),
						"soft": false,
						"xf": xf,
					}
				)
			)


## The holder's colliders meta in world space, keyed "kind:slot" (entries knocked down excluded).
func _shape_index(holder: Node3D) -> Dictionary:
	var out := {}
	for c: Variant in holder.get_meta("colliders", []):
		if typeof(c) != TYPE_DICTIONARY or bool((c as Dictionary).get("down", false)):
			continue
		var d: Dictionary = c
		var slot := int(d.get("slot", -1))
		if slot < 0:
			continue
		var key := _slot_key(str(d.get("kind", "?")), slot)
		if not out.has(key):
			out[key] = []
		(out[key] as Array).append(_world_shape(d, holder))
	return out


func _slot_key(kind: String, slot: int) -> String:
	return "%s:%d" % [kind, slot]


func _world_shape(d: Dictionary, holder: Node3D) -> Dictionary:
	if str(d.get("shape", "box")) == "cyl":
		var p: Vector3 = holder.transform * (d.get("pos", Vector3.ZERO) as Vector3)
		return {
			"c": Vector2(p.x, p.z),
			"r": float(d.get("r", 0.0)),
			"top": p.y + float(d.get("h", 3.0 * WS.M))
		}
	return {"box": holder.transform * ConstructionKit.collider_aabb(d)}


## The colliders-meta props that are no placement: bus shelters, lease boards, billboards, street
## sign poles, the cul-de-sac island tree and the baked lamp poles of lit straights, grouped per
## tile and kind.
func _meta_only(out: Array) -> void:
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD:
			continue
		var holder := ctx.view.tile_holder(i)
		if holder == null:
			continue
		var groups := {}
		for c: Variant in holder.get_meta("colliders", []):
			if typeof(c) != TYPE_DICTIONARY or bool((c as Dictionary).get("down", false)):
				continue
			var d: Dictionary = c
			var kind := str(d.get("kind", "?"))
			if int(d.get("slot", -1)) >= 0 or not META_KINDS.has(kind):
				continue
			if not groups.has(kind):
				groups[kind] = []
			(groups[kind] as Array).append(_world_shape(d, holder))
		for kind: String in groups:
			out.append(
				{
					"kind": kind,
					"tile": i,
					"slot": -1,
					"shapes": groups[kind],
					"spot": _group_spot(groups[kind]),
					"knock": false,
					"soft": false
				}
			)


func _group_spot(shapes: Array) -> Vector3:
	var sum := Vector3.ZERO
	for s: Dictionary in shapes:
		if s.has("box"):
			var b: AABB = s["box"]
			sum += Vector3(b.get_center().x, b.position.y, b.get_center().z)
		else:
			sum += Vector3((s["c"] as Vector2).x, 0.0, (s["c"] as Vector2).y)
	return sum / float(shapes.size())


## E's junction posts: a cross tile gets four corner signal poles (a plinth and a shaft each)
## and four pedestrian signals beside its zebras, a tee a stop or yield sign. The test knows
## their shapes from E's own build constants, and _check_post_colliders verifies the colliders
## junctions writes against them.
func _junction_poles(out: Array) -> void:
	var jn: JN = tr.get("junctions")
	if jn == null:
		return
	var poles := 0
	var ped_sigs := 0
	var stop_signs := 0
	for i: int in jn.props.keys():
		var pr: Dictionary = jn.props[i]
		var piece := str(RoadTopology.piece(RoadTopology.mask(ctx.sim, D.tx(i), D.ty(i)))[0])
		if piece == "cross":
			var built: Array = pr.get("poles", [])
			for corner in range(mini(built.size(), 4)):
				var c: Vector2 = JN.CORNERS[corner] * JN.POLE_AT
				var w := Vector3(D.tx(i) + c.x, WS.SIDEWALK_TOP, D.ty(i) + c.y)
				var plinth := AABB(
					Vector3(w.x - 0.285 * WS.M, w.y, w.z - 0.285 * WS.M),
					Vector3(0.57 * WS.M, 0.15 * WS.M, 0.57 * WS.M)
				)
				out.append(
					_post_target(
						"signal pole",
						i,
						w,
						[
							{"c": Vector2(w.x, w.z), "r": 0.11 * WS.M, "top": w.y + 6.3 * WS.M},
							{"box": plinth}
						]
					)
				)
				poles += 1
			# Pedestrian signals at both ends of each zebra, in the furniture band beside it.
			var lat := (WS.CURB_FURNITURE[0] + WS.CURB_FURNITURE[1]) * 0.5
			for arm in range(4):
				var a: Vector2 = LG.DIRS[arm]
				var p := Vector2(-a.y, a.x)
				for s: float in [1.0, -1.0]:
					var at := a * JN.PED_SIGNAL_AT + p * (s * lat)
					var w2 := Vector3(D.tx(i) + at.x, WS.SIDEWALK_TOP, D.ty(i) + at.y)
					out.append(
						_post_target(
							"ped signal",
							i,
							w2,
							[{"c": Vector2(w2.x, w2.z), "r": 0.06 * WS.M, "top": w2.y + 2.9 * WS.M}]
						)
					)
					ped_sigs += 1
		elif piece == "tee" and pr.has("sign"):
			# The stop or yield sign at the mouth of the stem (pr["sign"] is its world spot).
			var sg: Vector2 = pr["sign"]
			var w3 := Vector3(sg.x, WS.SIDEWALK_TOP, sg.y)
			out.append(
				_post_target(
					"stop sign",
					i,
					w3,
					[{"c": Vector2(w3.x, w3.z), "r": 0.045 * WS.M, "top": w3.y + 2.55 * WS.M}]
				)
			)
			stop_signs += 1
	K.check(fails, poles > 0, "fixture: E's signal poles on the cross tile (%d)" % poles)
	K.check(fails, ped_sigs > 0, "fixture: E's pedestrian signals (%d)" % ped_sigs)
	K.check(fails, stop_signs > 0, "fixture: E's stop sign on a tee (%d)" % stop_signs)


## A junction post as a walk-in target: solid, never knockable, slotless (it is no placement).
func _post_target(kind: String, tile: int, spot: Vector3, shapes: Array) -> Dictionary:
	return {
		"kind": kind,
		"tile": tile,
		"slot": -1,
		"shapes": shapes,
		"spot": spot,
		"knock": false,
		"soft": false
	}


## Parked cars, the site backhoe (parked at the kerb when none of the fill parked one) and a
## bicycle standing on a lane, all as dynamic blockers through blockers_near().
func _vehicles(out: Array) -> void:
	var amb: AMB = tr.get("ambient")
	amb.call("fill_parking")
	var vh: VH = tr.get("vehicles")
	var cars := 0
	var backhoe: VH.Car = null
	# Every parked vehicle goes into _car_boxes (the walked ones with their target, the rest on
	# their own): no start or approach path may land inside one of them.
	for c: VH.Car in vh.cars.duplicate():
		if c.dead or c.driven or not (c.parked and c.slot_tile >= 0):
			continue
		var kind := "backhoe" if c.label == "a backhoe" else "parked car"
		var t := {}
		if kind == "backhoe" and backhoe == null:
			backhoe = c
			t = _vehicle_target("backhoe", c, vh)
			out.append(t)
		elif kind == "parked car" and cars < WALKED:
			cars += 1
			t = _vehicle_target("parked car", c, vh)
			out.append(t)
		_car_boxes.append({"box": vh.aabb(c), "self": t})
	if backhoe == null:
		backhoe = _park_backhoe(vh)
		if backhoe != null:
			var tb := _vehicle_target("backhoe", backhoe, vh)
			out.append(tb)
			_car_boxes.append({"box": vh.aabb(backhoe), "self": tb})
	var bike := _stand_a_bike(vh)
	if bike != null:
		var tk := _vehicle_target("bicycle", bike, vh)
		out.append(tk)
		_car_boxes.append({"box": vh.aabb(bike), "self": tk})
	K.check(fails, cars > 0, "fixture: parked cars at the kerb (%d walked)" % cars)
	K.check(fails, backhoe != null, "fixture: a backhoe parked at the kerb")
	K.check(fails, bike != null, "fixture: a bicycle standing on a lane")


func _vehicle_target(kind: String, c: VH.Car, vh: VH) -> Dictionary:
	return {
		"kind": kind,
		"tile": c.slot_tile,
		"slot": -1,
		"shapes": [{"box": vh.aabb(c)}],
		"spot": Vector3(c.pos.x, 0.0, c.pos.z),
		"knock": false,
		"soft": false
	}


## Parks a backhoe at the first free kerb slot (fill_parking's rare share gave none).
func _park_backhoe(vh: VH) -> VH.Car:
	var m: int = tr.call("jcb_model")
	if m < 0:
		return null
	var lanes: LG = tr.get("lanes")
	var tiles: Array = []
	tiles.assign(lanes.tiles.keys())
	tiles.sort()
	for i: int in tiles:
		if not lanes.parkable(i):
			continue
		for k in range(LG.SLOTS):
			if not lanes.slot_valid(i, k) or not lanes.slot_free(i, k):
				continue
			var c := vh.make("car", "decor", tr.call("dims", m))
			c.model = m
			c.label = "a backhoe"
			c.mass = 5.5
			vh.park_at(c, i, k)
			return c
	return null


## A bicycle standing still on a lane, as the cyclists leave them: blockers_near() picks it up
## while it is slow.
func _stand_a_bike(vh: VH) -> VH.Car:
	var m: int = tr.call("bike_model")
	if m < 0:
		return null
	var tile := -1
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD or RoadTopology.is_bridge(ctx.sim, i):
			continue
		var piece := str(RoadTopology.piece(RoadTopology.mask(ctx.sim, D.tx(i), D.ty(i)))[0])
		if piece == "straight" or piece == "lights":
			tile = i
			break
	if tile < 0:
		return null
	var lanes: LG = tr.get("lanes")
	var tiles: Array[int] = [tile]
	var along: Array = lanes.lanes_along(tiles)
	if along.is_empty():
		return null
	var c := vh.make("bike", "ambient", AMB.BIKE_DIMS)
	c.model = m
	vh.place(c, along[0], 0.5)
	c.v = 0.0
	return c


## A few blocking site parts to walk into: the hoarding fence and the machines (soft: a busy site
## can keep every side blocked, then it only reports).
func _sites(out: Array) -> void:
	var boxes := 0
	for i: int in ctx.sim.sites.keys():
		for b: AABB in ctx.view.site_boxes(i):
			if b.size.y < 0.05:
				continue
			out.append(
				{
					"kind": "site hoarding",
					"tile": i,
					"slot": -1,
					"shapes": [{"box": b}],
					"spot": b.get_center(),
					"knock": false,
					"soft": true
				}
			)
			boxes += 1
			if boxes >= WALKED:
				break
		if boxes >= WALKED:
			break
	K.check(fails, boxes > 0, "fixture: a construction site with hoarding to walk into")


# ------------------------------------------------------------------ coverage


## Every standing placement keeps a live collider entry that sits at its place, and the street
## dresses at least six solid classes.
func _check_colliders(targets: Array) -> void:
	var missing: Array = []
	var away: Array = []
	var kinds := {}
	for t: Dictionary in targets:
		if not t.has("xf"):
			continue
		var kind := str(t["kind"])
		kinds[kind] = true
		if (t["shapes"] as Array).is_empty():
			missing.append([t["tile"], kind, t["slot"]])
		elif not _at_the_place(t):
			away.append([t["tile"], kind, t["slot"]])
	K.check(
		fails,
		kinds.size() >= 6,
		"fixture: the street dresses six solid classes (%d)" % kinds.size()
	)
	K.check(
		fails,
		missing.is_empty(),
		"every standing street prop keeps a collider entry %s" % str(missing.slice(0, 4))
	)
	K.check(
		fails,
		away.is_empty(),
		"every street prop's collider sits at its place %s" % str(away.slice(0, 4))
	)


## E's posts are solid only because junctions writes them into the tile's `colliders` meta: every
## post shape must have its own matching "signal" entry (cylinders by position and radius, the
## plinth box by its place and size), since that meta -- not the drawn mesh -- is what the hero's
## movement reads.
func _check_post_colliders(targets: Array) -> void:
	var posts := {"signal pole": 0, "ped signal": 0, "stop sign": 0}
	var missing: Array = []
	for t: Dictionary in targets:
		var kind := str(t["kind"])
		if not posts.has(kind):
			continue
		var holder := ctx.view.tile_holder(int(t["tile"]))
		var meta: Array = holder.get_meta("colliders", []) if holder != null else []
		var unmatched := 0
		for s: Dictionary in t["shapes"]:
			var matched := false
			for c: Variant in meta:
				if typeof(c) != TYPE_DICTIONARY:
					continue
				var d: Dictionary = c
				if str(d.get("kind", "")) != "signal":
					continue
				var w := _world_shape(d, holder)
				if s.has("box"):
					# The plinth: a "signal" box entry exactly where the drawn base is.
					if str(d.get("shape", "box")) != "box":
						continue
					var b: AABB = w["box"]
					var want: AABB = s["box"]
					if (
						(b.position - want.position).length() <= 0.0001
						and (b.size - want.size).length() <= 0.0001
					):
						matched = true
						break
				else:
					if str(d.get("shape", "")) != "cyl":
						continue
					if (
						(w["c"] as Vector2).distance_to(s["c"]) <= 0.0001
						and absf(float(w["r"]) - float(s["r"])) <= 0.0001
					):
						matched = true
						break
			if not matched:
				unmatched += 1
		posts[kind] = int(posts[kind]) + 1
		if unmatched > 0:
			missing.append([t["tile"], kind, unmatched])
	K.check(
		fails,
		missing.is_empty(),
		"every junction post keeps its own colliders-meta entry %s" % str(missing.slice(0, 4))
	)
	for kind: String in posts.keys():
		K.check(
			fails, int(posts[kind]) > 0, "fixture: the walk covers %s (%d)" % [kind, posts[kind]]
		)


func _at_the_place(t: Dictionary) -> bool:
	var spot: Vector3 = t["spot"]
	for s: Dictionary in t["shapes"]:
		if s.has("box"):
			if (s["box"] as AABB).grow(0.03).has_point(spot):
				return true
		elif (s["c"] as Vector2).distance_to(Vector2(spot.x, spot.z)) <= float(s["r"]) + 0.03:
			return true
	return false


# ------------------------------------------------------------------ remount


## A knocked-down street prop and the tile's re-dress (the holder rebuild the view's fp queue
## does whenever the sim changes a tile, re-writing street dressing's colliders from scratch)
## must never cost the junction its colliders: the knockdown marks only that prop's entry down,
## and the rebuilt holder must come back with the same "signal" entries, the pole still solid
## underfoot, the clutter standing again, and no signal entry lost or duplicated anywhere.
func _check_remount(targets: Array) -> void:
	var pick := _remount_pick(targets)
	K.check(fails, not pick.is_empty(), "fixture: a junction tile carrying knockable clutter")
	if pick.is_empty():
		return
	var tile: int = pick["tile"]
	var holder: Node3D = ctx.view.tile_holder(tile)
	var shaft: Dictionary = _shaft_of(targets, tile)
	_check_knockdown(pick, holder, shaft)
	_check_redress(tile, int(pick["slot"]), str(pick["kind"]), holder, shaft, _signals(holder))


## The first placement that a car's nudge can send flying (any knockable kind whose fly
## threshold sits under the 3 m/s the scenario sends it off at) on a junction tile: a signal
## holder with a shaft to press, {} when the fixture grew none.
func _remount_pick(targets: Array) -> Dictionary:
	var on_a_junction := func(i: int, h: Node3D) -> bool:
		return _signals(h) > 0 and not _shaft_of(targets, i).is_empty()
	return FIX.pick_knockable(ctx, 3.0, on_a_junction)


## The knockdown: only the knocked prop's collider goes down, the pole stays solid.
func _check_knockdown(pick: Dictionary, holder: Node3D, shaft: Dictionary) -> void:
	var tile: int = pick["tile"]
	var fell: bool = f.call(
		"knock", tile, int(pick["slot"]), pick["spot"], Vector3(3.0 * WS.M, 0.0, 0.0)
	)
	var down := _entry_down(holder, int(pick["slot"]))
	var press := _press_shaft(shaft)
	K.check(
		fails,
		fell and down and bool(press["reached"]) and float(press["depth"]) <= TOL,
		(
			(
				"a knockdown drops only the knocked clutter's collider "
				+ "(a %s fell %s, marked down %s, the pole reached %s, %.0f mm)"
			)
			% [
				str(pick["kind"]),
				str(fell),
				str(down),
				str(bool(press["reached"])),
				float(press["depth"]) / WS.M * 1000.0
			]
		)
	)


## The re-dress: the rebuilt holder keeps the junction colliders exactly, the clutter stands
## again, and no signal entry is lost or duplicated anywhere in the city.
func _check_redress(
	tile: int, slot: int, kind: String, holder: Node3D, shaft: Dictionary, n0: int
) -> void:
	var total := _signals_total()
	var q: Dictionary = ctx.view.get("_queue")
	q[tile] = 0.0
	ctx.view.set("_queue", q)
	ctx.view.call("flush_rebuild_queue")
	var fresh: Node3D = ctx.view.tile_holder(tile)
	var n1 := _signals(fresh) if fresh != null else -1
	var press := _press_shaft(shaft) if fresh != null else {"depth": 9.9, "reached": false}
	var entry := _slot_entry(fresh, slot) if fresh != null else {}
	var stands := not entry.is_empty() and not bool(entry.get("down", false))
	var same_kind := fresh != null and str(ctx.view.street_placements(tile)[slot][0]) == kind
	K.check(
		fails,
		(
			fresh != holder
			and n1 == n0
			and bool(press["reached"])
			and float(press["depth"]) <= TOL
			and stands
			and same_kind
		),
		(
			(
				"a re-dress restores the junction colliders (holder rebuilt %s, %d of %d signal "
				+ "entries, the pole reached %s, %.0f mm, the %s stands %s)"
			)
			% [
				str(fresh != holder),
				n1,
				n0,
				str(bool(press["reached"])),
				float(press["depth"]) / WS.M * 1000.0,
				kind,
				str(stands)
			]
		)
	)
	K.check(
		fails,
		_signals_total() == total,
		(
			"a re-dress loses or duplicates no signal entry city-wide (%d -> %d)"
			% [total, _signals_total()]
		)
	)


## The first signal-pole target's shaft shape (the tallest solid part of the pole) on tile.
func _shaft_of(targets: Array, tile: int) -> Dictionary:
	for t: Dictionary in targets:
		if str(t["kind"]) == "signal pole" and int(t["tile"]) == tile:
			var shapes: Array = t["shapes"]
			return shapes[0] if not shapes.is_empty() else {}
	return {}


## How many "signal" entries holder's colliders meta carries.
func _signals(holder: Node3D) -> int:
	if holder == null:
		return -1
	var n := 0
	for c: Variant in holder.get_meta("colliders", []):
		if typeof(c) == TYPE_DICTIONARY and str((c as Dictionary).get("kind", "")) == "signal":
			n += 1
	return n


## Every "signal" entry in every tile's meta, city-wide.
func _signals_total() -> int:
	var n := 0
	for i: int in ctx.sim.active:
		var holder := ctx.view.tile_holder(i)
		if holder != null:
			n += _signals(holder)
	return n


## The colliders-meta entry of clutter `slot`, {} when the tile has none for it.
func _slot_entry(holder: Node3D, slot: int) -> Dictionary:
	if holder == null:
		return {}
	for c: Variant in holder.get_meta("colliders", []):
		if typeof(c) == TYPE_DICTIONARY and int((c as Dictionary).get("slot", -1)) == slot:
			return c
	return {}


## True when that entry is marked down (knocked over).
func _entry_down(holder: Node3D, slot: int) -> bool:
	var e := _slot_entry(holder, slot)
	return not e.is_empty() and bool(e.get("down", false))


## Walks the hero into the signal shaft from the first clear direction: the deepest body overlap
## with it (u). The pole must stop the hero, never let it through; the walk first steps onto the
## plinth box like a curb, as every ground body does. {"depth" (u), "reached" (the hero got to
## touching it -- without this, a "0 mm" could just mean the walk never arrived)}.
func _press_shaft(shaft: Dictionary) -> Dictionary:
	var c: Vector2 = shaft["c"]
	var rad: float = shaft["r"]
	for dir: Vector3 in DIRS:
		var start := Vector3(c.x, 0.0, c.y) - dir * (R + rad + STANDOFF)
		var g := ctx.collision.walk_height(start)
		if is_nan(g):
			continue
		start.y = g
		if ctx.collision.body_blocked(start, R * 1.02, BODY_H):
			continue
		var p := ctx.player
		var to := Vector3(c.x, start.y, c.y) - start
		to.y = 0.0
		to = to.normalized()
		p.teleport(start, rad_to_deg(atan2(-to.x, -to.z)))
		p.velocity = to * WS.WALK
		p.update_view(DT)
		var depth := 0.0
		var reached := false
		for _k in range(240):
			p.simulate(Vector2(0.0, 1.0), false, DT)
			p.update_view(DT)
			var dist := Vector2(p.position.x, p.position.z).distance_to(c)
			depth = maxf(depth, R + rad - dist)
			if dist <= R + rad + 0.05:
				reached = true
				break
		return {"depth": depth, "reached": reached}
	return {"depth": -1.0, "reached": false}


# ------------------------------------------------------------------ walking


func _check_walk(targets: Array) -> void:
	var by_kind := {}
	for t: Dictionary in targets:
		if not by_kind.has(str(t["kind"])):
			by_kind[str(t["kind"])] = []
		(by_kind[str(t["kind"])] as Array).append(t)
	var order: Array = by_kind.keys()
	order.sort()
	for kind: String in order:
		var list: Array = by_kind[kind]
		var walked := 0
		var dirs := 0
		var deepest := 0.0
		var knocked := 0
		var soft := bool(list[0]["soft"])
		for t: Dictionary in list.slice(0, SCANNED):
			if walked >= WALKED:
				break
			var res := _walk_target(t)
			if int(res["dirs"]) == 0:
				continue
			dirs += int(res["dirs"])
			walked += 1
			deepest = maxf(deepest, float(res["depth"]))
			if bool(res["knocked"]):
				knocked += 1
		var note := "" if knocked == 0 else " (%d knocked over)" % knocked
		if walked == 0:
			if not soft:
				K.check(fails, false, "fixture: a clear approach to a %s" % kind)
			continue
		K.check(
			fails,
			deepest <= TOL,
			(
				"the hero never passes through a %s (deepest %.0f mm over %d walks%s)"
				% [kind, deepest * 1000.0 / WS.M, dirs, note]
			)
		)


## Walks the hero at target t from every clear direction: {"dirs", "depth" (the deepest overlap
## with the target's shapes or any blocker at all), "knocked"}.
func _walk_target(t: Dictionary) -> Dictionary:
	var res := {"dirs": 0, "depth": 0.0, "knocked": false}
	if (t["shapes"] as Array).is_empty():
		return res
	var spot: Vector3 = t["spot"]
	for d: Vector3 in DIRS:
		var extent := _extent(t["shapes"], spot, d)
		var start := spot - d * (extent + R + STANDOFF)
		var g := ctx.collision.walk_height(start)
		if is_nan(g):
			continue
		start.y = g
		if ctx.collision.body_blocked(start, R * 1.02, BODY_H) or _in_a_car(start, t):
			continue
		if not _path_clear(start, spot, extent, t):
			continue
		res["dirs"] = int(res["dirs"]) + 1
		var depth := _walk(start, spot, t, res)
		res["depth"] = maxf(float(res["depth"]), depth)
		if bool(res["knocked"]):
			break
	return res


func _walk(start: Vector3, spot: Vector3, t: Dictionary, res: Dictionary) -> float:
	var p := ctx.player
	var to := spot - start
	to.y = 0.0
	to = to.normalized()
	var depth := 0.0
	p.teleport(start, rad_to_deg(atan2(-to.x, -to.z)))
	p.velocity = to * WS.WALK
	p.update_view(DT)
	var last := p.position
	var stall := 0
	for _k in range(240):
		p.simulate(Vector2(0.0, 1.0), false, DT)
		p.update_view(DT)
		f.call("_process", DT)
		depth = maxf(depth, _depth_at(p.position, t["shapes"]))
		depth = maxf(depth, _blocked_depth(p.position))
		if bool(t["knock"]) and _is_down(t):
			res["knocked"] = true
			break
		if (p.position - spot).dot(to) > _extent(t["shapes"], spot, to) + R + 0.02:
			break
		stall = stall + 1 if p.position.distance_to(last) < 1e-6 else 0
		if stall > 30:
			break
		last = p.position
	depth = maxf(depth, _depth_at(p.position, t["shapes"]))
	depth = maxf(depth, _blocked_depth(p.position))
	return depth


## How far p sits inside the shapes (u): a hero standing on top (feet at the shape's top) or under
## it (head below its base) does not count.
func _depth_at(p: Vector3, shapes: Array) -> float:
	var worst := 0.0
	for s: Dictionary in shapes:
		if s.has("box"):
			var b: AABB = s["box"]
			if p.y >= b.end.y - 1e-4 or b.position.y >= p.y + BODY_H - 1e-4:
				continue
			var q := Vector2(clampf(p.x, b.position.x, b.end.x), clampf(p.z, b.position.z, b.end.z))
			worst = maxf(worst, R - Vector2(p.x, p.z).distance_to(q))
		else:
			if p.y >= float(s["top"]) - 1e-4:
				continue
			var dist := Vector2(p.x, p.z).distance_to(s["c"] as Vector2)
			worst = maxf(worst, float(s["r"]) + R - dist)
	return worst


## How far the hero sits inside any hard blocker at all (u), the global no-clip invariant.
func _blocked_depth(p: Vector3) -> float:
	var worst := 0.0
	for v: float in (ctx.collision._overlaps(p, R * 0.98, BODY_H) as Dictionary).values():
		worst = maxf(worst, v)
	return worst


## How far the shapes reach from spot along d (u).
func _extent(shapes: Array, spot: Vector3, d: Vector3) -> float:
	var out := 0.0
	for s: Dictionary in shapes:
		if s.has("box"):
			var b: AABB = s["box"]
			var c := b.get_center()
			out = maxf(
				out, (c - spot).dot(d) + absf(d.x) * b.size.x * 0.5 + absf(d.z) * b.size.z * 0.5
			)
		else:
			var c2 := s["c"] as Vector2
			out = maxf(
				out, absf((c2 - Vector2(spot.x, spot.z)).dot(Vector2(d.x, d.z))) + float(s["r"])
			)
	return out


## True when the hero can walk from start up to the target's side without entering anything
## (the target itself excepted: the samples stop short of touching distance).
func _path_clear(start: Vector3, spot: Vector3, extent: float, t: Dictionary) -> bool:
	var to := spot - start
	to.y = 0.0
	var length := to.length()
	var stop := maxf(length - extent - R * 1.05, 0.0)
	to /= length
	var s := 0.0
	while s <= stop + 1e-9:
		var q := start + to * s
		var g := ctx.collision.walk_height(q)
		if is_nan(g):
			return false
		q.y = g
		if ctx.collision.body_blocked(q, R, BODY_H) or _in_a_car(q, t):
			return false
		s += 0.004
	return true


func _in_a_car(p: Vector3, t: Dictionary) -> bool:
	for e: Dictionary in _car_boxes:
		if e["self"] == t:
			continue
		var b: AABB = e["box"]
		if p.y >= b.end.y or b.position.y >= p.y + BODY_H:
			continue
		var q := Vector2(clampf(p.x, b.position.x, b.end.x), clampf(p.z, b.position.z, b.end.z))
		if Vector2(p.x, p.z).distance_to(q) < R:
			return true
	return false


func _is_down(t: Dictionary) -> bool:
	var down: Array = f.get("down")
	for e: Dictionary in down:
		if int(e["tile"]) == int(t["tile"]) and int(e["slot"]) == int(t["slot"]):
			return true
	return false


## A building holder whose model metas are missing or wrong-shaped falls back to the whole pick
## box, silently. The missing-meta read is an engine-level error a SceneTree test cannot see, so
## the shapes run in a child Godot (fp_building_meta_check.gd) and its captured output is
## grepped -- the same class as the fold-rig read fixed in #60.
func _check_building_meta_silent() -> void:
	var out: Array = []
	var code := (
		OS
		. execute(
			OS.get_executable_path(),
			[
				"--headless",
				"--path",
				ProjectSettings.globalize_path("res://"),
				"-s",
				"res://tools/tests/fp_building_meta_check.gd",
			],
			out,
			true
		)
	)
	var log := "\n".join(PackedStringArray(out))
	K.check(
		fails,
		code == 0 and "FP_BUILDING_META_CHECK: DONE" in log,
		"building meta: the child shapes run fell back four ways (exit %d)" % code
	)
	K.check(
		fails,
		not "does not have any 'meta' values" in log and not "SCRIPT ERROR" in log,
		"building meta: a half-dressed holder's shapes print no missing-meta engine error"
	)


# ------------------------------------------------------------------ report


func _print_report(targets: Array) -> void:
	var by_kind := {}
	for t: Dictionary in targets:
		var row: Dictionary = by_kind.get_or_add(str(t["kind"]), {"n": 0, "cov": 0.0, "cov_n": 0})
		row["n"] = int(row["n"]) + 1
		var cov := _coverage(t)
		if cov >= 0.0:
			row["cov"] = float(row["cov"]) + cov
			row["cov_n"] = int(row["cov_n"]) + 1
	var lines := ["prop collision coverage (collider footprint / visual footprint):"]
	for kind: String in by_kind.keys():
		var row: Dictionary = by_kind[kind]
		if int(row["cov_n"]) == 0:
			lines.append("  %s: %d placed, no visual bounds to compare" % [kind, int(row["n"])])
			continue
		var cov := float(row["cov"]) / float(int(row["cov_n"]))
		lines.append(
			(
				"  %s: %d placed, collider covers %.0f%% of the visual"
				% [kind, int(row["n"]), cov * 100.0]
			)
		)
	print("\n".join(lines))


## The collider footprint's share of the placement's visual footprint (kit bounds through the
## placement transform); -1 when there is nothing to compare.
func _coverage(t: Dictionary) -> float:
	if not t.has("xf"):
		return -1.0
	var kit: Dictionary = ctx.view.street_kit(str(t["kind"]))
	if not kit.has("aabb"):
		return -1.0
	var visual: AABB = (t["xf"] as Transform3D) * (kit["aabb"] as AABB)
	if visual.size.x < 1e-6 or visual.size.z < 1e-6:
		return -1.0
	var area := 0.0
	for s: Dictionary in t["shapes"]:
		if s.has("box"):
			var b: AABB = s["box"]
			area += b.size.x * b.size.z
		else:
			area += PI * float(s["r"]) * float(s["r"])
	return minf(area / (visual.size.x * visual.size.z), 1.0)
