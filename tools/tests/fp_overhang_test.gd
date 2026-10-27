extends SceneTree
## What street furniture draws above a mover's head span is an overhang and stays visual, on
## purpose: a tree's crown (its leaves NEAR_FADE near the camera), a signal's heads and mast
## arm, the name blades -- none of it is a wall, and none of it ever becomes one. The only
## solid shape is the ground-rooted footprint: the trunk column, the pole shaft, the plinth
## box. This locks that contract where a mover would feel a violation, against the real
## furniture of the fixture city (no test boxes): the hero walks the crown line and the
## junction lane at head height unimpeded while the trunk and the shaft still stop them, a
## body thrown across a crown sweeps the band freely and comes to rest clear of the trunk, and
## the colliders-meta entries themselves stay footprint-sized -- so a future "fix" that gives
## the crown or the heads a collider fails here first.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const FIX := preload("res://tools/tests/support/props_fixture.gd")
const DT := 1.0 / 60.0
## The hero's body the way the mover moves it.
const R := WS.PLAYER_RADIUS
const BODY_H := WS.PLAYER_HEIGHT
## The crown band (u): leaves live above CROWN_BOTTOM (fp_prop_coverage_test sweeps the trunk
## under it), and a walking hero's head (1.8 m) and eyes (1.65 m) pass through it.
const CROWN_BOTTOM := 1.4 * WS.M
const CROWN_TOP := 2.1 * WS.M
## The crown line runs this far (u) from the trunk axis: inside the crown (r ~1.1 m), outside
## the trunk's reach (r 0.18 m + the hero's 0.3 m).
const CROWN_OFFSET := 0.65 * WS.M
## The flight line runs this far (u) from the trunk axis: still inside the crown, but outside
## the fall reservation a down slide keeps around solid shapes (BODY_R + DOWN_REACH = 0.65 m),
## so the throw's skid is not the trunk's to stop -- only the leaves lie over this line.
const FLIGHT_OFFSET := 0.85 * WS.M
## A blow this strong knocks down; each flight runs to its end by this cap (s).
const STRENGTH := 0.95
const REACT_S := 10.0
## Touching is fine, inside is not (u).
const TOL := 0.005 * WS.M
## A band vertex this close to the crown line (u) means the line really runs under leaves.
const COVERED_BY := 0.25 * WS.M
## How far the lane walk reaches each way from the junction centre (u).
const LANE_HALF := 10.0 * WS.M

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var react: RefCounted
var pe: Object
var wk: WK
## How many dressed trees the fixture scan has seen (for the fixture message).
var _trees_seen := 0
## The tree kit's fetched vertex arrays (one fetch, many placements).
var _tree_parts_cache: Array = []


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("hit_feel", true)
	var made := FIX.make(get_root(), {})
	ctx = made["ctx"]
	tr = made["tr"]
	if tr == null:
		K.check(fails, false, "fixture: the traffic feature is registered")
		K.finish(self, "FP_OVERHANG_TEST", fails)
		return
	var parts := FIX.reactions_wired(fails, tr)
	react = parts["react"] as RefCounted
	pe = parts["pe"] as Object
	wk = parts["wk"] as WK
	var tree := _find_tree()
	K.check(
		fails,
		not tree.is_empty(),
		(
			"fixture: a street tree whose crown hangs over a clear line (%d trees scanned)"
			% _trees_seen
		)
	)
	if not tree.is_empty():
		_check_tree_entry(tree)
		_check_walk_under_crown(tree)
		_check_flight_through_crown(tree)
	var junc := _find_junction()
	K.check(fails, not junc.is_empty(), "fixture: a junction with heads hanging over its lanes")
	if not junc.is_empty():
		_check_pole_entries(junc)
		_check_walk_under_heads(junc)
	Engine.time_scale = 1.0
	K.finish(self, "FP_OVERHANG_TEST", fails)


# ------------------------------------------------------------------ fixtures


## The first curb tree whose crown covers a walkable line offset CROWN_OFFSET to its sidewalk
## side, with a clear standing spot before it for the flight victim: {"trunk" (world, at the
## ground), "axis" (along-street), "across" (signed, toward the line), "crown_r" (u), "band"
## [lo, hi] (world y), "fling" (m), "stand" (world), "entry"}.
func _find_tree() -> Dictionary:
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD:
			continue
		var holder := ctx.view.tile_holder(i)
		if holder == null:
			continue
		var placed: Array = ctx.view.street_placements(i)
		for slot in placed.size():
			if str(placed[slot][0]) != "tree":
				continue
			_trees_seen += 1
			var t := _tree_at(holder, placed, slot)
			if not t.is_empty():
				return t
	return {}


## One tree placement measured, {} when it cannot stage the scenarios.
func _tree_at(holder: Node3D, placed: Array, slot: int) -> Dictionary:
	var entry := FIX.entry_of(holder, slot)
	if entry.is_empty() or str(entry.get("shape", "cyl")) != "cyl":
		return {}
	var kit: Dictionary = ctx.view.street_kit("tree")
	if kit.is_empty() or (kit["parts"] as Array).is_empty():
		return {}
	var lp: Vector3 = entry["pos"]
	var trunk := holder.to_global(lp)
	var g := ctx.collision.walk_height(trunk)
	if is_nan(g):
		return {}
	trunk.y = g
	# The curb offset sits across the street (CURB_FURNITURE), so the other local axis runs
	# along it; the sidewalk side of the trunk is away from the tile centre's road line.
	var run_local := Vector3(0.0, 0.0, 1.0) if absf(lp.x) > absf(lp.z) else Vector3(1.0, 0.0, 0.0)
	var axis := holder.to_global(lp + run_local) - holder.to_global(lp)
	axis.y = 0.0
	axis = axis.normalized()
	var across := Vector3(axis.z, 0.0, -axis.x)
	if (trunk - holder.to_global(Vector3.ZERO)).dot(across) < 0.0:
		across = -across
	var crown := _crown_geometry(kit, placed[slot][1], trunk, across)
	var line := {
		"trunk": trunk,
		"axis": axis,
		"across": across,
		"crown_r": float(crown["r"]),
		"band": crown["band"],
		"entry": entry
	}
	if _tree_stages(line, crown):
		return line
	return {}


## Whether the measured tree can stage the scenarios: a crown that covers the walk line, ends
## to walk between, and a clear standing spot for the flight victim (which fills stand+fling).
func _tree_stages(line: Dictionary, crown: Dictionary) -> bool:
	if float(line["crown_r"]) < CROWN_OFFSET + 0.35 * WS.M:
		return false
	if float(crown["cover"]) > COVERED_BY:
		return false
	if not _line_walkable(line):
		return false
	var stand := _stand_spot(line, FLIGHT_OFFSET)
	if stand.is_empty():
		return false
	line["stand"] = stand["at"]
	line["fling"] = clampf(stand["back"] / WS.M + line["crown_r"] / WS.M + 0.6, 1.5, 5.0)
	return true


## The crown of one placement: the widest band vertex's reach from the trunk axis (r, u), the
## band's world y span, and how close a band vertex comes to the offset line (cover, u). The
## placement transform is world (street_placements), so the swept vertices are too.
func _crown_geometry(
	kit: Dictionary, xf: Transform3D, trunk: Vector3, across: Vector3
) -> Dictionary:
	var r := 0.0
	var band := [trunk.y + CROWN_TOP, trunk.y + CROWN_BOTTOM]
	var cover := INF
	for part: Dictionary in _tree_parts(kit):
		var pxf: Transform3D = part["xform"]
		for v: Vector3 in part["verts"]:
			var w: Vector3 = xf * (pxf * v)
			if w.y < trunk.y + CROWN_BOTTOM or w.y > trunk.y + CROWN_TOP:
				continue
			var rel := w - trunk
			r = maxf(r, Vector2(rel.x, rel.z).length())
			band[0] = minf(band[0], w.y)
			band[1] = maxf(band[1], w.y)
			cover = minf(cover, absf(rel.dot(across) - CROWN_OFFSET))
	return {"r": r, "band": band, "cover": cover}


## The tree kit's vertex arrays, fetched once (a per-tree sweep of the fetched arrays is what
## makes scanning many trees affordable): [{"xform", "verts"}].
func _tree_parts(kit: Dictionary) -> Array:
	if not _tree_parts_cache.is_empty():
		return _tree_parts_cache
	for part: Dictionary in kit["parts"]:
		var mesh: Mesh = part["mesh"]
		for s in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(s)
			if arr.size() <= Mesh.ARRAY_VERTEX:
				continue
			_tree_parts_cache.append({"xform": part["xform"], "verts": arr[Mesh.ARRAY_VERTEX]})
	return _tree_parts_cache


## The standing spot for the flight victim: on its offset line, stepping back from crown_r + 1 m
## before the trunk until the ground is walkable and nothing blocks a body there;
## {"at" (world), "back" (u along the axis)} or {}.
func _stand_spot(line: Dictionary, offset: float) -> Dictionary:
	for back in range(0, 5):
		var dist := (float(line["crown_r"]) + (1.0 + 0.5 * back) * WS.M) as float
		var at: Vector3 = line["trunk"] - line["axis"] * dist + line["across"] * offset
		var g := ctx.collision.walk_height(at)
		if is_nan(g):
			continue
		at.y = g
		if ctx.collision.body_blocked(at, 0.3 * WS.M, 1.75 * WS.M):
			continue
		return {"at": at, "back": dist}
	return {}


## The first dressed junction whose mast and heads hang over its lanes (a cross; a tee's
## tallest part is its stop sign): {"holder", "centre" (world), "node", "top" (highest drawn,
## u)}.
func _find_junction() -> Dictionary:
	var jn = tr.get("junctions")
	if jn == null:
		return {}
	for i: int in (jn.props as Dictionary).keys():
		var p: Dictionary = (jn.props as Dictionary)[i]
		if not p.has("node") or not is_instance_valid(p["node"]):
			continue
		var holder := ctx.view.tile_holder(i)
		if holder == null:
			continue
		var top := _highest_drawn(p["node"])
		if top < 4.0 * WS.M:
			continue
		return {
			"holder": holder,
			"centre": holder.to_global(Vector3.ZERO),
			"node": p["node"],
			"top": top
		}
	return {}


# ------------------------------------------------------------------ tree: the entry and the walk


## The contract in data: the tree's collider is its trunk, a column from the ground through
## the crown band, and the crown really overhangs it into the hero's head span.
func _check_tree_entry(tree: Dictionary) -> void:
	var r := float(tree["entry"]["r"])
	K.check(
		fails,
		r <= 0.25 * WS.M,
		(
			"the tree's collider is its trunk (r %.2f m), never its crown (r %.2f m)"
			% [r / WS.M, float(tree["crown_r"]) / WS.M]
		)
	)
	K.check(
		fails,
		float(tree["entry"]["h"]) >= CROWN_BOTTOM + 0.3 * WS.M,
		"the trunk column spans the crown band (top %.2f m)" % [float(tree["entry"]["h"]) / WS.M]
	)
	var band: Array = tree["band"]
	var base := (tree["trunk"] as Vector3).y
	K.check(
		fails,
		float(band[0]) < base + BODY_H and float(band[1]) > base + WS.EYE,
		(
			"fixture: the crown band (%.2f-%.2f m) brushes a standing hero's eyes and head"
			% [float(band[0]) / WS.M, float(band[1]) / WS.M]
		)
	)


## The hero crosses the crown zone at head height along the offset line unimpeded, and the
## trunk on the axis line still stops them at its face.
func _check_walk_under_crown(tree: Dictionary) -> void:
	var under := _walk_line(tree, CROWN_OFFSET)
	K.check(
		fails,
		not bool(under["blocked"]),
		(
			"the hero walks the crown line at head height touching nothing (%.0f mm deepest)"
			% (float(under["depth"]) / WS.M * 1000.0)
		)
	)
	K.check(
		fails,
		bool(under["done"]),
		(
			"the crown never stalls the walk (%.2f of %.2f m crossed)"
			% [float(under["travel"]) / WS.M, float(under["span"]) / WS.M]
		)
	)
	var into := _walk_line(tree, 0.0)
	var face := float(tree["entry"]["r"]) + R - 0.03 * WS.M
	K.check(
		fails,
		not bool(into["done"]) and float(into["axis_dist"]) >= face and float(into["depth"]) <= TOL,
		(
			"the trunk still stops the hero at its face (%.2f m from the axis, %.0f mm inside)"
			% [float(into["axis_dist"]) / WS.M, float(into["depth"]) / WS.M * 1000.0]
		)
	)


## Walks the hero along the street through the crown zone at lateral offset (u) from the trunk
## axis: {"blocked" (any hard blocker along the way), "depth" (deepest into the trunk, u),
## "done" (crossed the span), "travel", "span", "axis_dist" (final distance to the trunk, u)}.
func _walk_line(tree: Dictionary, offset: float) -> Dictionary:
	var trunk: Vector3 = tree["trunk"]
	var axis: Vector3 = tree["axis"]
	var across: Vector3 = tree["across"]
	var half := float(tree["crown_r"]) + 0.4 * WS.M
	var start := trunk - axis * half + across * offset
	var g := ctx.collision.walk_height(start)
	if is_nan(g):
		return {
			"blocked": true,
			"depth": 0.0,
			"done": false,
			"travel": 0.0,
			"span": 2.0 * half,
			"axis_dist": 0.0
		}
	start.y = g
	var res := _walk_straight(start, axis, half, tree)
	var rel: Vector3 = res["end"] - trunk
	return {
		"blocked": res["blocked"],
		"depth": res["depth"],
		"done": res["done"],
		"travel": res["travel"],
		"span": 2.0 * half,
		"axis_dist": Vector2(rel.x, rel.z).length(),
	}


## Walks the hero from start along dir over the ±half span, watching the trunk of tree (when
## given) for how deep the body reaches into it: {"blocked", "done" (reached the far end),
## "travel", "depth", "end"}. The hero faces dir (yaw 0 faces -z, hence the atan2 form).
func _walk_straight(start: Vector3, dir: Vector3, half: float, tree: Dictionary) -> Dictionary:
	var p := ctx.player
	p.teleport(start, rad_to_deg(atan2(-dir.x, -dir.z)))
	p.velocity = dir * WS.WALK
	p.update_view(DT)
	var depth := 0.0
	var blocked := false
	var last := p.position
	var stall := 0
	var frames := int(ceil(2.0 * half / WS.WALK / DT)) + 120
	for _k in range(frames):
		p.simulate(Vector2(0.0, 1.0), false, DT)
		p.update_view(DT)
		if ctx.collision.body_blocked(p.position, R * 0.99, BODY_H):
			blocked = true
		if not tree.is_empty():
			depth = maxf(depth, _trunk_depth(tree, p.position, R))
		if (p.position - start).dot(dir) >= 2.0 * half - 0.15 * WS.M:
			break
		stall = stall + 1 if p.position.distance_to(last) < 1e-6 else 0
		if stall > 30:
			break
		last = p.position
	var rel := p.position - start
	return {
		"blocked": blocked,
		"done": rel.dot(dir) >= 2.0 * half - 0.15 * WS.M,
		"travel": rel.dot(dir),
		"depth": depth,
		"end": p.position,
	}


## How deep a body of radius r at p reaches into this tree's trunk column (u): the one solid
## thing in the crown zone.
func _trunk_depth(tree: Dictionary, p: Vector3, r: float) -> float:
	var trunk: Vector3 = tree["trunk"]
	var dist := Vector2(p.x - trunk.x, p.z - trunk.z).length()
	return maxf(0.0, r + float(tree["entry"]["r"]) - dist)


## The crown line's ends stand on walkable, unblocked ground (the walk can begin and end).
func _line_walkable(line: Dictionary) -> bool:
	var half := float(line["crown_r"]) + 0.4 * WS.M
	for s: float in [-1.0, 1.0]:
		var at: Vector3 = line["trunk"] + line["axis"] * (s * half) + line["across"] * CROWN_OFFSET
		var g := ctx.collision.walk_height(at)
		if is_nan(g) or ctx.collision.body_blocked(Vector3(at.x, g, at.z), R * 1.05, BODY_H):
			return false
	return true


# ------------------------------------------------------------------ tree: the flight


## A full-strength punch throws a victim across the crown zone: the posed head sweeps the
## band (through leaves, stopped by nothing), the throw carries past the crown's far edge,
## and the body never reaches into the trunk.
func _check_flight_through_crown(tree: Dictionary) -> void:
	var trunk: Vector3 = tree["trunk"]
	var axis: Vector3 = tree["axis"]
	var stand: Vector3 = tree["stand"]
	var w := wk.make("ambient")
	wk.stand(w, stand, atan2(axis.x, axis.z))
	var hero := stand - axis * (2.5 * WS.M)
	ctx.player.teleport(hero, rad_to_deg(atan2(axis.x, axis.z)))
	ctx.player.input_enabled = false
	tr.call("sync_visuals", DT)
	var src := stand - axis * (1.2 * WS.M)
	src.y = stand.y
	var ret: Dictionary = react.call("hit", w, src, axis * WS.M, STRENGTH, "punch", tree["fling"])
	K.check(fails, bool(ret.get("down", false)), "fixture: the punch knocks them down")
	var swept := 0
	var reach := 0.0
	var farthest := -INF
	var t := 0.0
	while t < REACT_S:
		tr.call("step", DT)
		tr.call("sync_visuals", DT)
		t += DT
		if int(t / DT) % 2 != 0:
			continue
		var feet: Vector3 = w.pos + w.vis_off
		var head: Vector3 = pe.call("head_of", w, feet)
		farthest = maxf(farthest, (feet - trunk).dot(axis))
		if (
			head.y >= trunk.y + CROWN_BOTTOM - TOL
			and head.y <= trunk.y + CROWN_TOP + TOL
			and Vector2(head.x - trunk.x, head.z - trunk.z).length() <= float(tree["crown_r"])
		):
			swept += 1
		reach = maxf(
			reach,
			maxf(_trunk_depth(tree, feet, 0.25 * WS.M), _trunk_depth(tree, head, 0.14 * WS.M))
		)
	print("  flight: %d sweeps, farthest %.2f m past the trunk" % [swept, farthest / WS.M])
	K.check(
		fails, swept > 0, "the flight sweeps the crown band through the leaves (%d samples)" % swept
	)
	K.check(
		fails,
		farthest >= float(tree["crown_r"]) - 0.2 * WS.M,
		(
			"the throw carries past the crown's far edge (%.2f m vs r %.2f m): leaves stop nothing"
			% [farthest / WS.M, float(tree["crown_r"]) / WS.M]
		)
	)
	K.check(
		fails,
		reach <= TOL,
		"the body never reaches into the trunk (%.0f mm at worst)" % (reach / WS.M * 1000.0)
	)
	wk.remove(w)


# ------------------------------------------------------------------ junction: entries and the walk


## The contract in data: every signal entry is a footprint -- a plinth-class box at the
## ground or a shaft-thin column from the ground -- so the heads, mast arm and cap above
## every mover stay visual.
func _check_pole_entries(junc: Dictionary) -> void:
	var holder: Node3D = junc["holder"]
	var worst := ""
	for d: Dictionary in FIX.signal_entries(holder):
		if str(d.get("shape", "")) == "box":
			var size: Vector3 = d["size"]
			if size.x > 0.75 * WS.M or size.z > 0.75 * WS.M or size.y > 0.5 * WS.M:
				worst = "box %s" % [size / WS.M]
		else:
			var r := float(d.get("r", 0.0))
			var h := float(d.get("h", 0.0))
			var base: float = (d["pos"] as Vector3).y
			if r > 0.16 * WS.M or h < 2.0 * WS.M or base > 0.6 * WS.M:
				worst = "cyl (r %.2f, h %.2f, base %.2f m)" % [r / WS.M, h / WS.M, base / WS.M]
	K.check(
		fails,
		worst.is_empty(),
		"every signal entry is a footprint (plinth box or shaft column); first wide one: %s" % worst
	)


## The hero walks a lane through the junction at head height, under the mast arms and heads
## that hang over it, unimpeded.
func _check_walk_under_heads(junc: Dictionary) -> void:
	var centre: Vector3 = junc["centre"]
	var g := ctx.collision.walk_height(centre)
	if is_nan(g):
		K.check(fails, false, "fixture: the junction centre stands on walkable ground")
		return
	for a: Vector3 in [Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0)]:
		for side: float in [1.0, -1.0]:
			var across := Vector3(a.z, 0.0, -a.x) * side
			# WS.LANE_OFFSET is authored in units (0.15 u = 3 m), like the other road values.
			var lane := centre + across * WS.LANE_OFFSET
			if not _lane_clear(lane, a):
				continue
			var over := _over_line(junc, lane, across)
			if over <= 4.0 * WS.M:
				continue
			var start := lane - a * LANE_HALF
			start.y = g
			var res := _walk_straight(start, a, LANE_HALF, {})
			var msg := (
				"the hero walks the lane under the heads and mast unimpeded (%s, %.2f m over)"
				% [str(a), over / WS.M]
			)
			K.check(fails, bool(res["done"]) and not bool(res["blocked"]), msg)
			return
	K.check(fails, false, "fixture: a clear lane with heads hanging over it")


## Whether both ends of the lane walk stand on walkable, unblocked ground.
func _lane_clear(lane: Vector3, a: Vector3) -> bool:
	for s: float in [-1.0, 1.0]:
		var at := lane + a * (s * LANE_HALF)
		var gg := ctx.collision.walk_height(at)
		if is_nan(gg) or ctx.collision.body_blocked(Vector3(at.x, gg, at.z), R * 1.05, BODY_H):
			return false
	return true


## The highest vertex the junction's node draws within 2.5 m of the lane line (u): the mast
## arms and heads hanging over the walk.
func _over_line(junc: Dictionary, lane: Vector3, across: Vector3) -> float:
	var best := 0.0
	for w: Vector3 in FIX.drawn_verts(junc["node"]):
		if absf((w - lane).dot(across)) > 2.5 * WS.M:
			continue
		best = maxf(best, w.y)
	return best


## The highest vertex the junction's node draws anywhere (u).
func _highest_drawn(node: Node3D) -> float:
	var best := 0.0
	for w: Vector3 in FIX.drawn_verts(node):
		best = maxf(best, w.y)
	return best
