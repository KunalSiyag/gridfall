extends SceneTree
## One ground-height table (unit G1, flag ground_profile): GroundProfile is what the meshes are
## built from and what CollisionWorld.ground_height returns, so a step of the mesh is a step of the
## collision. A grid test reads the BUILT meshes of a seeded city on foot (day 1, and the grown
## save of tools/tests/fixtures/save_v3_seed7.json) and asserts the collision agrees within 1 cm at
## every lot slab corner and edge, every apron, every kerb and bridge deck, rubble and tracks. The
## meshes it reads: the lot models' own slabs and the road models (authored in Blender), the apron,
## rubble and track meshes (built by code), and the ground quads. Then the flag off (the old flat
## tiles and the soft step), the water's NAN (wading is fp_water_test's) and the tile rules.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const GP := preload("res://scripts/fp/world/ground_profile.gd")
const RB := preload("res://scripts/fp/world/riverbed.gd")
const FIXTURE := "res://tools/tests/fixtures/save_v3_seed7.json"
const FOUR: Array[Vector2i] = [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]
## 1 cm, in world units (0.05 units per metre).
const CM := 0.01 * WS.M
## Up-facing mesh triangles above this are not ground: fences, rails, steps up to a porch.
const SLAB_CAP := 0.0045
const ROAD_CAP := 0.0105

var fails: Array[String] = []
## Triangle caches of lot models, by model path, in the model's own frame (a, b, c in a row).
var _slab_tris: Dictionary = {}


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("ground_profile", true)
	_check_table()
	var ctx := K.make_ctx(get_root(), {"view": true, "hud": false, "player": false})
	_check_world(ctx, "day 1")
	_check_rules(ctx)
	_check_rubble_and_tracks(ctx)
	_check_models()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	K.check(fails, typeof(parsed) == TYPE_DICTIONARY, "fixture: the grown save parses")
	if typeof(parsed) == TYPE_DICTIONARY:
		var grown := K.make_ctx(get_root(), {"view": false, "hud": false, "player": false})
		K.check(fails, grown.sim.from_dict(parsed as Dictionary), "fixture: the grown save loads")
		grown.view = K.make_view(grown.collision.get_parent(), grown.sim)
		grown.collision.rebuild_all()
		grown.view.tile_built.connect(grown.collision.on_tile_built)
		grown.view.tile_cleared.connect(grown.collision.on_tile_cleared)
		_check_world(grown, "grown save")
		_check_flag_off(grown)
	var recipe := K.make_ctx(
		get_root(), {"view": true, "grow": true, "hud": false, "player": false}
	)
	K.place_open_services(fails, recipe.sim)
	_check_world(recipe, "grown city")
	FeatureFlags.set_override("ground_profile", false)
	_check_world(recipe, "grown city, ground_profile off", true)
	FeatureFlags.set_override("ground_profile", true)
	K.finish(self, "FP_GROUND_PROFILE_TEST", fails)


## The numbers themselves: the lot slab, the apron's two ends, the rubble, the rules.
func _check_table() -> void:
	K.check(
		fails,
		is_equal_approx(GP.LOT_HALF, WS.LOT_FOOTPRINT * 0.5),
		"the lot slab is LOT_FOOTPRINT wide"
	)
	K.check(
		fails,
		is_equal_approx(GP.apron_height(GP.APRON_FROM), WS.LOT_TOP),
		"the apron starts at the slab's top"
	)
	K.check(
		fails,
		is_equal_approx(GP.apron_height(GP.APRON_TO), WS.SIDEWALK_TOP),
		"the apron ends at the sidewalk's top"
	)
	K.check(
		fails,
		GP.apron_height(0.2) == WS.LOT_TOP and GP.apron_height(0.9) == WS.SIDEWALK_TOP,
		"the apron clamps"
	)
	var mid := GP.apron_height((GP.APRON_FROM + GP.APRON_TO) * 0.5)
	K.check(
		fails,
		is_equal_approx(mid, (WS.LOT_TOP + WS.SIDEWALK_TOP) * 0.5),
		"the apron is a straight ramp"
	)
	K.check(
		fails,
		GP.PAD_HALF > GP.LOT_HALF and GP.PAD_HALF < GP.TILE_HALF,
		"the rubble slab is a little wider than a lot's"
	)
	K.check(
		fails,
		(WS.SIDEWALK_TOP - WS.LOT_TOP) < WS.STEP_HEIGHT and WS.LOT_TOP < WS.STEP_HEIGHT,
		"every step of the profile is climbable"
	)


## Day 1 and the grown save, on foot: the meshes against the collision.
func _check_world(ctx: FpContext, label: String, contrast: bool = false) -> void:
	var view := ctx.view
	view.set_fp_mode(true)
	view.flush_rebuild_queue()
	var sim := ctx.sim
	var stats := {
		"lots": 0,
		"lot_pts": 0,
		"aprons": 0,
		"apron_pts": 0,
		"roads": 0,
		"road_pts": 0,
		"skipped": 0,
		"rubble": 0,
		"tracks": 0,
		"bridges": 0
	}
	var worst := {"lot": 0.0, "apron": 0.0, "road": 0.0}
	var bad: Array[String] = []
	var seen_slab := {}
	var lots := 0
	var roads := 0
	for i in sim.active:
		var k := sim.kind[i]
		var holder := view._tile_nodes.get(i) as Node3D
		if holder == null:
			continue
		if k == D.ROAD:
			if (
				roads < 90
				and (
					roads % 2 == 0
					or sim.terrain[i] == D.WATER
					or (
						RoadTopology.mask(sim, D.tx(i), D.ty(i))
						not in [RoadTopology.NS, RoadTopology.EW]
					)
				)
			):
				_check_road(ctx, i, holder, stats, worst, bad)
			roads += 1
		elif k == D.RUBBLE:
			_check_rubble(ctx, i, holder, stats, bad)
		elif holder.has_meta("building_path") and GP.slab_top(sim, i) > WS.GROUND_Y:
			if lots < 80:
				_check_lot(ctx, i, holder, stats, worst, bad, seen_slab)
			lots += 1
	if contrast:
		K.check(
			fails,
			not bad.is_empty() and float(worst["lot"]) > 2.0 * CM,
			(
				"%s: old flat tiles are off by %.1f cm (lots), %.1f cm (aprons), %d pts"
				% [label, float(worst["lot"]) / CM, float(worst["apron"]) / CM, bad.size()]
			)
		)
		return
	K.check(
		fails,
		bad.is_empty(),
		(
			"%s: collision = meshes (%d lots/%d, %d aprons/%d, %d roads/%d, %d skip, %d/%d/%d): %s"
			% [
				label,
				stats["lots"],
				stats["lot_pts"],
				stats["aprons"],
				stats["apron_pts"],
				stats["roads"],
				stats["road_pts"],
				stats["skipped"],
				stats["rubble"],
				stats["tracks"],
				stats["bridges"],
				str(bad.slice(0, 6))
			]
		)
	)
	K.check(
		fails,
		stats["roads"] > 0 and stats["road_pts"] > 300,
		"%s: roads were sampled (%d tiles, %d points)" % [label, stats["roads"], stats["road_pts"]]
	)
	print(
		(
			"  note %s: worst disagreement lot %.2f cm, apron %.2f cm, road %.2f cm"
			% [
				label,
				float(worst["lot"]) / CM,
				float(worst["apron"]) / CM,
				float(worst["road"]) / CM
			]
		)
	)
	var want_lots := {"day 1": 1, "grown save": 6, "grown city": 14}
	K.check(
		fails,
		stats["lots"] >= int(want_lots[label]) and stats["lot_pts"] >= 68 * int(want_lots[label]),
		"%s: lots were sampled (%d, wanted %d)" % [label, stats["lots"], int(want_lots[label])]
	)
	if label != "day 1":
		K.check(
			fails,
			stats["aprons"] >= 5 and stats["apron_pts"] > 100,
			"%s: aprons were sampled (%d)" % [label, stats["aprons"]]
		)
		K.check(
			fails,
			seen_slab.size() >= 5,
			"%s: several lot models' own slabs were measured (%d)" % [label, seen_slab.size()]
		)


## Every real lot model's own slab (the authored assets): a quad of LOT_FOOTPRINT at LOT_TOP, and
## nothing of the slab's height beyond its edge.
func _check_models() -> void:
	var paths: Array[String] = []
	for d in (
		["res://models/real/buildings/"]
		+ ["r1", "r2", "r3", "c1", "c2", "c3", "i1", "i2", "i3"].map(
			func(z: String) -> String: return "res://models/real/zones/%s/" % z
		)
	):
		for f in DirAccess.get_files_at(d):
			if f.get_extension() == "glb":
				paths.append(d + f)
	var bad: Array[String] = []
	var high: Array[String] = []
	for p in paths:
		var tris := _model_slab_tris(p)
		var lo := Vector2(9.0, 9.0)
		var hi := Vector2(-9.0, -9.0)
		var y := NAN
		for k in range(0, tris.size(), 3):
			if tris[k].y < WS.LOT_TOP - 0.0003:
				continue
			for q in range(3):
				var v := tris[k + q]
				lo = Vector2(minf(lo.x, v.x), minf(lo.y, v.z))
				hi = Vector2(maxf(hi.x, v.x), maxf(hi.y, v.z))
				y = v.y if is_nan(y) else maxf(y, v.y)
		var half := minf(minf(-lo.x, hi.x), minf(-lo.y, hi.y))
		if absf(y - WS.LOT_TOP) > 1e-6 and absf(y - WS.LOT_TOP) <= CM + 1e-6:
			high.append(p.get_file())
		if (
			tris.is_empty()
			or is_nan(y)
			or absf(y - WS.LOT_TOP) > CM + 1e-6
			or half < GP.LOT_HALF - 0.002
			or maxf(maxf(-lo.x, hi.x), maxf(-lo.y, hi.y)) > GP.LOT_HALF + 0.002
		):
			bad.append(
				(
					"%s: slab y %.4f half %.3f..%.3f"
					% [p.get_file(), y, half, maxf(maxf(-lo.x, hi.x), maxf(-lo.y, hi.y))]
				)
			)
	K.check(
		fails,
		paths.size() >= 40 and bad.is_empty(),
		(
			"every real lot model stands on the %.2f-wide LOT_TOP slab within 1 cm (%d): %s"
			% [GP.LOT_HALF * 2.0, paths.size(), str(bad.slice(0, 5))]
		)
	)
	print(
		"  note: lot models with the slab a few mm above LOT_TOP (left as authored): %s" % str(high)
	)


# ------------------------------------------------------------------ lots, aprons


## A built lot: its model's slab (measured on the model's own mesh) against the profile at the slab
## edge and corners, and its apron meshes against the profile across their width.
func _check_lot(
	ctx: FpContext,
	i: int,
	holder: Node3D,
	stats: Dictionary,
	worst: Dictionary,
	bad: Array[String],
	seen: Dictionary
) -> void:
	var col := ctx.collision
	var path := str(holder.get_meta("building_path"))
	var xf: Transform3D = holder.get_meta("building_xform", Transform3D())
	if not _slab_tris.has(path):
		_slab_tris[path] = _model_slab_tris(path)
	var tris: PackedVector3Array = _slab_tris[path]
	if tris.is_empty():
		bad.append("tile %d: %s has no slab triangle" % [i, path.get_file()])
		return
	stats["lots"] += 1
	seen[path] = true
	var local := PackedVector3Array()
	for v in tris:
		local.append(xf * v)
	var cx := float(D.tx(i))
	var cz := float(D.ty(i))
	# The apron meshes this lot's tile owns: the street's placements, apron kind.
	var aprons: Array[PackedVector3Array] = []
	var apron_dirs := 0
	for pl: Array in view_street(ctx).placements(i):
		if str(pl[0]) != "apron":
			continue
		var t: Transform3D = pl[1]
		t.origin -= Vector3(cx, 0.0, cz)
		var dv := Vector2i(roundi(t.basis.z.x), roundi(t.basis.z.z))
		apron_dirs |= 1 << FOUR.find(dv)
		aprons.append(_apron_tris(ctx, t))
	var want := GP.apron_mask(ctx.sim, i, ctx.directory.frontage(i))
	if apron_dirs != want:
		bad.append("tile %d: aprons built %s but the profile says %s" % [i, apron_dirs, want])
	stats["aprons"] += aprons.size()
	# Grid: five places along each side, five distances from the centre across the slab edge.
	for s in range(4):
		var dv := Vector2(FOUR[s])
		var side := Vector2(-dv.y, dv.x)
		for along: float in [-0.4, -0.2, 0.0, 0.2, 0.4]:
			for t: float in [0.45, 0.466, 0.474, 0.485, 0.497]:
				var l := dv * t + side * along
				var mesh_y := _mesh_y(local, aprons, l)
				var got := col.ground_height(Vector3(cx + l.x, 0.0, cz + l.y))
				var err := absf(got - mesh_y)
				var kind := "apron" if t > 0.475 else "lot"
				stats["apron_pts" if kind == "apron" else "lot_pts"] += 1
				worst[kind] = maxf(float(worst[kind]), err)
				if is_nan(got) or err > CM:
					bad.append(
						(
							"lot %d side %d at %.3f/%.2f: mesh %.4f collision %.4f"
							% [i, s, t, along, mesh_y, got]
						)
					)
	# The four corners of the slab: inside and outside.
	for corner: Vector2 in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
		for t: float in [0.462, 0.478]:
			var l := corner * t
			var mesh_y := _mesh_y(local, aprons, l)
			var got := col.ground_height(Vector3(cx + l.x, 0.0, cz + l.y))
			stats["lot_pts"] += 1
			worst["lot"] = maxf(float(worst["lot"]), absf(got - mesh_y))
			if is_nan(got) or absf(got - mesh_y) > CM:
				bad.append(
					(
						"lot %d corner %s at %.3f: mesh %.4f collision %.4f"
						% [i, str(corner), t, mesh_y, got]
					)
				)


func view_street(ctx: FpContext) -> RefCounted:
	return ctx.view._street


## The height the built meshes give at tile-local l: the lawn, the lot model's slab triangles
## `slab`, the aprons' triangles, whichever is highest.
func _mesh_y(slab: PackedVector3Array, aprons: Array[PackedVector3Array], l: Vector2) -> float:
	var y := WS.GROUND_Y
	var hit := _top_at(slab, l.x, l.y, SLAB_CAP)
	if not is_nan(hit):
		y = maxf(y, hit)
	for ap in aprons:
		var h := _top_at(ap, l.x, l.y, 1.0)
		if not is_nan(h):
			y = maxf(y, h)
	return y


## The up-facing slab-level triangles (y at most SLAB_CAP) of the model at path, in its own frame.
func _model_slab_tris(path: String) -> PackedVector3Array:
	var out := PackedVector3Array()
	var ps := load(path) as PackedScene
	if ps == null:
		return out
	var root := ps.instantiate() as Node3D
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := Transform3D.IDENTITY
		var q: Node = mi
		while q != null and q != root:
			if q is Node3D:
				xf = (q as Node3D).transform * xf
			q = q.get_parent()
		out.append_array(_up_tris(mi.mesh.get_faces(), xf, SLAB_CAP, 0.002))
	root.free()
	return out


## The apron mesh of placement t, as up-facing triangles in world space.
func _apron_tris(ctx: FpContext, t: Transform3D) -> PackedVector3Array:
	var m: ArrayMesh = ctx.view._street._apron_mesh()
	return _up_tris(m.get_faces(), t, 1.0, -1.0)


## The up-facing (clockwise from above: Godot's front face) triangles of faces transformed by xf
## whose highest corner is at most cap and above floor; a, b, c in a row.
func _up_tris(
	faces: PackedVector3Array, xf: Transform3D, cap: float, floor_y: float
) -> PackedVector3Array:
	var out := PackedVector3Array()
	for t in range(0, faces.size(), 3):
		var a := xf * faces[t]
		var b := xf * faces[t + 1]
		var c := xf * faces[t + 2]
		var n := (b - a).cross(c - a)
		if n.y >= 0.0 or absf(n.y) < 0.9 * n.length():
			continue
		var top := maxf(a.y, maxf(b.y, c.y))
		if top > cap or top < floor_y:
			continue
		out.append(a)
		out.append(b)
		out.append(c)
	return out


## The highest height among the triangles tris over (x, z), or NAN where none lies over it.
func _top_at(tris: PackedVector3Array, x: float, z: float, cap: float) -> float:
	var best := NAN
	for t in range(0, tris.size(), 3):
		var a := tris[t]
		var b := tris[t + 1]
		var c := tris[t + 2]
		var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(d) < 1e-12:
			continue
		var u := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / d
		var v := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / d
		var w := 1.0 - u - v
		if u < -1e-9 or v < -1e-9 or w < -1e-9:
			continue
		var y := u * a.y + v * b.y + w * c.y
		if y <= cap and (is_nan(best) or y > best):
			best = y
	return best


# ------------------------------------------------------------------ roads, kerbs, bridges


## A road tile on foot: the road model's own mesh against the profile on a 13 x 13 grid; the points
## next to a step of the profile (the kerb, a parapet) are skipped (the mesh's vertical face is a
## few cm wide there), everything else must agree within 1 cm.
func _check_road(
	ctx: FpContext, i: int, holder: Node3D, stats: Dictionary, worst: Dictionary, bad: Array[String]
) -> void:
	var col := ctx.collision
	var sim := ctx.sim
	var cx := float(D.tx(i))
	var cz := float(D.ty(i))
	var tris := PackedVector3Array()
	var track := false
	for n in holder.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		if mi.name == "Track":
			track = true
		var xf := holder.global_transform.affine_inverse() * mi.global_transform
		tris.append_array(_up_tris(mi.mesh.get_faces(), xf, ROAD_CAP, -1.0))
	if track:
		stats["tracks"] += 1
		var h := col.ground_height(Vector3(cx, 0.0, cz))
		var mesh_y := _top_at(tris, 0.0, 0.0, ROAD_CAP)
		if absf(h - mesh_y) > CM:
			bad.append("track %d: mesh %.4f collision %.4f" % [i, mesh_y, h])
		return
	stats["roads"] += 1
	if sim.terrain[i] == D.WATER:
		stats["bridges"] += 1
	var step := 0.04
	for gx in range(13):
		for gz in range(13):
			var l := Vector2(-0.48 + 0.08 * gx, -0.48 + 0.08 * gz)
			var p := Vector3(cx + l.x, 0.0, cz + l.y)
			var got := col.ground_height(p)
			if is_nan(got):
				continue
			if _near_step(col, p, step):
				stats["skipped"] += 1
				continue
			var mesh_y := _top_at(tris, l.x, l.y, ROAD_CAP)
			if is_nan(mesh_y):
				continue
			var err := absf(got - mesh_y)
			stats["road_pts"] += 1
			worst["road"] = maxf(float(worst["road"]), err)
			if err > CM:
				bad.append(
					(
						"road %d (%s) at %.2f/%.2f: mesh %.4f collision %.4f"
						% [
							i,
							str(RoadTopology.piece(RoadTopology.mask(sim, D.tx(i), D.ty(i)))[0]),
							l.x,
							l.y,
							mesh_y,
							got
						]
					)
				)


## True when the profile changes by more than 3 mm within `r` (tile units) of p, in any of eight
## directions: p is at an edge of a step.
func _near_step(col: CollisionWorld, p: Vector3, r: float) -> bool:
	var h0 := col.ground_height(p)
	for k in range(8):
		var a := TAU * float(k) / 8.0
		var q := p + Vector3(cos(a), 0.0, sin(a)) * r
		var h := col.ground_height(q)
		if is_nan(h) or absf(h - h0) > 0.0015:
			return true
	return false


# ------------------------------------------------------------------ rubble


## Rubble on foot is a closed slab (a box) at PAD_TOP: its size and top against the profile.
func _check_rubble(
	ctx: FpContext, i: int, holder: Node3D, stats: Dictionary, bad: Array[String]
) -> void:
	var col := ctx.collision
	for n in holder.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh is BoxMesh and (mi.mesh as BoxMesh).size.x > 0.9:
			var size := (mi.mesh as BoxMesh).size
			var top := mi.position.y + size.y * 0.5
			var cx := float(D.tx(i))
			var cz := float(D.ty(i))
			stats["rubble"] += 1
			var inside := col.ground_height(Vector3(cx + size.x * 0.5 - 0.01, 0.0, cz))
			var outside := col.ground_height(Vector3(cx + size.x * 0.5 + 0.01, 0.0, cz))
			if absf(inside - top) > CM or absf(outside - WS.GROUND_Y) > CM:
				bad.append(
					(
						"rubble %d: slab top %.4f edge %.3f; collision inside %.4f outside %.4f"
						% [i, top, size.x * 0.5, inside, outside]
					)
				)
			return


## Rubble and an unpaved road are not on the day-1 map, so make them: a land tile of open ground
## becomes rubble, a land road tile a dirt track, the view rebuilds both, and the built slab and
## track plane are held against the collision like any other mesh (a rubble slab the collision does
## not know, or a track at another height, fails here).
func _check_rubble_and_tracks(ctx: FpContext) -> void:
	var sim := ctx.sim
	var view := ctx.view
	var rubble := -1
	var road := -1
	for i in sim.active:
		if sim.terrain[i] == D.WATER:
			continue
		if rubble < 0 and sim.kind[i] == D.EMPTY:
			rubble = i
		if road < 0 and sim.kind[i] == D.ROAD:
			road = i
	K.check(fails, rubble >= 0 and road >= 0, "fixture: open ground and a land road tile exist")
	if rubble < 0 or road < 0:
		return
	sim.kind[rubble] = D.RUBBLE
	sim.level[road] = D.GRADE_DIRT
	view._build_tile(rubble, false)
	view._build_tile(road, false)
	var stats := {"rubble": 0, "tracks": 0, "roads": 0, "bridges": 0, "road_pts": 0, "skipped": 0}
	var worst := {"road": 0.0}
	var bad: Array[String] = []
	_check_rubble(ctx, rubble, view._tile_nodes.get(rubble) as Node3D, stats, bad)
	_check_road(ctx, road, view._tile_nodes.get(road) as Node3D, stats, worst, bad)
	K.check(
		fails,
		stats["rubble"] == 1 and stats["tracks"] == 1,
		"the rubble slab and the dirt track were built and measured (%s)" % str(stats)
	)
	K.check(fails, bad.is_empty(), "rubble slab and track: collision = meshes: %s" % str(bad))
	var c := Vector3(D.tx(rubble), 0.0, D.ty(rubble))
	K.check(
		fails,
		(
			ctx.collision.ground_height(c) == WS.PAD_TOP
			and ctx.collision.ground_height(c + Vector3(0.49, 0.0, 0.0)) == WS.GROUND_Y
		),
		"rubble: the slab's PAD_TOP, then the lawn past its edge"
	)


# ------------------------------------------------------------------ rules, flag off


## The tile rules on the live city: water is NAN, open ground is the lawn, a lot has its slab and an
## 8 cm step to the lawn, wading is untouched.
func _check_rules(ctx: FpContext) -> void:
	var col := ctx.collision
	var sim := ctx.sim
	var water := -1
	var grass := -1
	for i in sim.active:
		if water < 0 and sim.terrain[i] == D.WATER and sim.kind[i] != D.ROAD:
			water = i
		if grass < 0 and sim.kind[i] == D.EMPTY and sim.terrain[i] != D.WATER:
			grass = i
	if water >= 0:
		var c := Vector3(D.tx(water), 0, D.ty(water))
		K.check(fails, is_nan(col.ground_height(c)), "open water is still NAN")
		K.check(
			fails,
			not is_nan(col.walk_height(c, WS.WADE_MAX)) or RB.depth_at(sim, c.x, c.z) > WS.WADE_MAX,
			"a wader still gets the bed (or too deep)"
		)
		K.check(fails, is_nan(col.walk_height(c)), "everyone else still gets NAN over open water")
	if grass >= 0:
		K.check(
			fails,
			col.ground_height(Vector3(D.tx(grass), 0, D.ty(grass))) == WS.GROUND_Y,
			"open ground is the lawn"
		)
	K.check(
		fails,
		col.ground_height(Vector3(500.0, 0.0, 500.0)) == WS.GROUND_Y,
		"outside the world is the lawn"
	)


## ground_profile off: a lot is flat LOT_TOP across its whole tile and the soft step eases the
## edge toward open ground, as before; on again, the exact steps.
func _check_flag_off(ctx: FpContext) -> void:
	var col := ctx.collision
	var sim := ctx.sim
	var lot := -1
	var dir := Vector2i.ZERO
	for i in sim.active:
		if lot >= 0 or sim.kind[i] == D.ROAD or GP.slab_top(sim, i) != WS.LOT_TOP:
			continue
		for dv: Vector2i in FOUR:
			var x := D.tx(i) + dv.x
			var y := D.ty(i) + dv.y
			if (
				D.in_bounds(x, y)
				and sim.kind[D.idx(x, y)] == D.EMPTY
				and sim.terrain[D.idx(x, y)] != D.WATER
			):
				lot = i
				dir = dv
				break
	K.check(fails, lot >= 0, "fixture: a built lot next to open ground")
	if lot < 0:
		return
	var c := Vector3(D.tx(lot), 0, D.ty(lot))
	var edge := c + Vector3(dir.x, 0.0, dir.y) * 0.49
	var inside := c + Vector3(dir.x, 0.0, dir.y) * 0.46
	FeatureFlags.set_override("ground_profile", false)
	K.check(
		fails,
		col.ground_height(edge) == WS.LOT_TOP,
		"flag off: a lot is LOT_TOP across its whole tile"
	)
	K.check(
		fails,
		col.walk_height(edge) < WS.LOT_TOP - 0.0005,
		"flag off: the soft step eases the edge down (%.5f)" % col.walk_height(edge)
	)
	FeatureFlags.set_override("ground_profile", true)
	K.check(
		fails,
		col.ground_height(inside) == WS.LOT_TOP and col.walk_height(inside) == WS.LOT_TOP,
		"flag on: the slab, no soft step"
	)
	K.check(
		fails,
		col.ground_height(edge) == WS.GROUND_Y and col.walk_height(edge) == WS.GROUND_Y,
		"flag on: past the slab it is the lawn, a true step"
	)
