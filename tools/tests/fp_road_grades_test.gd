extends SceneTree
## Road grades (the road_grades flag; sim_defs ROAD_GRADES): mayors order gravel roads, dirt tracks
## and grass trails, which cost less, resurface to a better grade, cap the density of the lots
## beside them, and on foot are a bare surface at carriageway height with no curbs, signals or
## parking. Traffic slows and gives way to the right on them, more of it is cyclists, the phone
## orders them, the minimap and the footsteps tell them apart.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const AMB := preload("res://scripts/fp/traffic/ambient.gd")
const RULES := preload("res://scripts/fp/phone/build_rules.gd")
const MINIMAP := preload("res://scripts/fp/ui/minimap_model.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")
const ROADS := preload("res://scripts/ai/road_plans.gd")
## Half-size of the open square the test crossroads needs (tiles).
const ROOM := 3

var fails: Array[String] = []
var ctx: FpContext
var sim: CitySim
var f: FpFeature
## Centre of the test crossroads: arms of 2 tiles each way, all dirt.
var centre := D.NO_TILE
## The mayor whose district holds it.
var mi := 0


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true})
	sim = ctx.sim
	sim.construction_mode = "instant"
	centre = _open_square()
	K.check(fails, centre != D.NO_TILE, "fixture: open land for a crossroads (district %d)" % mi)
	sim.mayors[mi]["treasury"] = 50000
	if centre != D.NO_TILE:
		_check_orders()
		_rebuild()
		_check_ground()
		_check_view()
		f = K.make_feature(ctx, "traffic")
		K.check(fails, f != null, "the traffic feature is registered")
		if f != null:
			f.set("auto_step", false)
			_check_lanes()
			_check_ambient()
		_check_residents()
		_check_brain()
		_check_phone()
		_check_staged()
	_check_bits()
	K.finish(self, "FP_ROAD_GRADES_TEST", fails)


## City_sim._act_road: grades cost what ROAD_GRADES says, a better grade resurfaces a rougher one
## and a rougher one is refused, an unknown grade is refused, lots grow only as dense as their
## best road allows, and with the flag off every road is paved.
func _check_orders() -> void:
	var c := centre
	var t0 := int(sim.mayors[mi]["treasury"])
	var r := sim.apply_action(
		mi, {"type": "road", "x": c.x - 2, "y": c.y, "x2": c.x + 2, "y2": c.y, "grade": "track"}
	)
	var spent := t0 - int(sim.mayors[mi]["treasury"])
	K.check(
		fails,
		(
			bool(r.get("ok", false))
			and spent == 5 * 3
			and _levels(c, Vector2i(1, 0)) == [2, 2, 2, 2, 2]
		),
		"a dirt track: 5 tiles at $3, grade 2 (%s, $%d)" % [str(r.get("reason", "")), spent]
	)
	K.check(fails, sim.tile_char(D.idx(c.x, c.y)) == "-", "a dirt track maps as '-'")
	t0 = int(sim.mayors[mi]["treasury"])
	r = sim.apply_action(
		mi, {"type": "road", "x": c.x - 2, "y": c.y, "x2": c.x + 2, "y2": c.y, "grade": "gravel"}
	)
	spent = t0 - int(sim.mayors[mi]["treasury"])
	K.check(
		fails,
		(
			bool(r.get("ok", false))
			and spent == 5 * 6
			and _levels(c, Vector2i(1, 0)) == [1, 1, 1, 1, 1]
		),
		"gravel over it resurfaces all 5 tiles at $6 (%s)" % str(r.get("reason", ""))
	)
	r = sim.apply_action(
		mi, {"type": "road", "x": c.x - 2, "y": c.y, "x2": c.x + 2, "y2": c.y, "grade": "dirt"}
	)
	K.check(fails, not bool(r.get("ok", true)), "a dirt track over gravel is refused")
	r = sim.apply_action(
		mi, {"type": "road", "x": c.x, "y": c.y - 2, "x2": c.x, "y2": c.y - 1, "grade": "mud"}
	)
	K.check(fails, not bool(r.get("ok", true)), "an unknown grade is refused")
	var below := D.idx(c.x + 1, c.y + 1)
	K.check(
		fails,
		sim.road_density_cap(below) == 2,
		"a lot beside gravel grows to density 2 (%d)" % sim.road_density_cap(below)
	)
	# Back down to dirt (test only), then the vertical arms.
	for k in range(-2, 3):
		sim.level[D.idx(c.x + k, c.y)] = D.GRADE_DIRT
	for a: Array in [[c.y - 2, c.y - 1], [c.y + 1, c.y + 2]]:
		r = sim.apply_action(
			mi, {"type": "road", "x": c.x, "y": a[0], "x2": c.x, "y2": a[1], "grade": "dirt"}
		)
		K.check(
			fails, bool(r.get("ok", false)), "dirt arm %s (%s)" % [str(a), str(r.get("reason", ""))]
		)
	K.check(fails, sim.road_density_cap(below) == 1, "a lot beside dirt grows to density 1")
	var paved := _paved_road()
	K.check(
		fails,
		paved >= 0 and sim.road_density_cap(paved) == 3,
		"a lot beside a paved road grows to density 3"
	)
	# With the flag off a trail order is paved.
	sim.road_grades = false
	var ox := c.x + ROOM
	r = sim.apply_action(
		mi, {"type": "road", "x": ox, "y": c.y - 3, "x2": ox, "y2": c.y - 3, "grade": "trail"}
	)
	var off_level := sim.level[D.idx(ox, c.y - 3)]
	sim.road_grades = true
	K.check(
		fails,
		bool(r.get("ok", false)) and off_level == D.GRADE_PAVED,
		"flag off: a trail order builds a paved road (%s)" % str(r.get("reason", ""))
	)


## On foot an unpaved road is all one height, its carriageway named for its grade and its verge
## grass.
func _check_ground() -> void:
	var i := D.idx(centre.x + 1, centre.y)
	var col := ctx.collision
	var hv := RoadTopology.surface_height(sim, i, Vector2(0.0, 0.42))
	var gv := col.ground_height(Vector3(centre.x + 1, 0.0, centre.y + 0.42))
	K.check(
		fails,
		is_equal_approx(hv, WS.ASPHALT_TOP) and is_equal_approx(gv, WS.ASPHALT_TOP),
		"no curb: the verge is at carriageway height (%.4f, %.4f)" % [hv, gv]
	)
	var on := col.surface_at(Vector3(centre.x + 1, 0.0, centre.y + 0.1))
	var off := col.surface_at(Vector3(centre.x + 1, 0.0, centre.y + 0.42))
	K.check(
		fails,
		on == "dirt" and off == "grass",
		"surface: dirt on the track, grass beside (%s, %s)" % [on, off]
	)
	var sp := RoadTopology.sidewalk_point(sim, i, 1)
	K.check(fails, is_equal_approx(sp.y, WS.ASPHALT_TOP), "the verge walk point is on the ground")


## The view draws a track quad told the tile's mask and grade, and no road model, lamp or bus stop.
func _check_view() -> void:
	var view := ctx.view
	var h := view._tile_nodes.get(D.idx(centre.x, centre.y), null) as Node3D
	K.check(fails, h != null, "the crossroads tile is built")
	if h == null:
		return
	var tr := h.get_node_or_null("Track") as MeshInstance3D
	K.check(
		fails,
		tr != null and h.get_child_count() == 1,
		"a track quad and nothing else (%d nodes)" % h.get_child_count()
	)
	if tr == null:
		return
	var mat := tr.material_override as ShaderMaterial
	var m := float(mat.get_shader_parameter(&"track_mask")) if mat != null else -1.0
	var g := float(mat.get_shader_parameter(&"track_grade")) if mat != null else -1.0
	K.check(
		fails,
		m == 15.0 and g == 2.0 and mat == view.track_material_for(15, 2),
		"the quad wears the shared material for its mask and grade (%d, %d)" % [m, g]
	)
	K.check(
		fails, is_equal_approx(tr.position.y, WS.ASPHALT_TOP), "the quad lies at carriageway height"
	)
	K.check(
		fails,
		(
			mat != null
			and bool(mat.get_shader_parameter("track"))
			and bool(mat.get_shader_parameter("cut_grass")) != view.fp_mode
		),
		"the ground shader in track mode, grass cut in orbit"
	)


## Lanes on dirt are half as fast, the crossroads has no signals and each arm gives way to the one
## on its right, no car parks and no junction props stand there.
func _check_lanes() -> void:
	var lg: LG = f.get("lanes")
	var ci := D.idx(centre.x, centre.y)
	var t: LG.TileInfo = lg.info(ci)
	K.check(
		fails,
		t != null and t.grade == D.GRADE_DIRT and not t.lights,
		"an unsignalled dirt crossroads"
	)
	if t == null:
		return
	var fast := 0
	for e in range(4):
		var arm: LG.TileInfo = lg.info(
			D.idx(centre.x + [0, 1, 0, -1][e], centre.y + [-1, 0, 1, 0][e])
		)
		for l: LG.Lane in arm.lanes:
			if l.base_limit > WS.CAR_CITY * 0.5 + 1e-5:
				fast += 1
	K.check(fails, fast == 0, "dirt lanes are at most half the city limit (%d faster)" % fast)
	var bad := 0
	var n := 0
	for e in range(4):
		for mv: LG.Lane in t.moves[e]:
			n += 1
			if not ((e + 3) % 4 in mv.yield_to):
				bad += 1
	K.check(
		fails,
		n > 0 and bad == 0,
		"every move gives way to the arm on its right (%d of %d not)" % [bad, n]
	)
	K.check(fails, not lg.parkable(D.idx(centre.x + 1, centre.y)), "no curb parking on a track")
	var jn: Variant = f.get("junctions")
	if jn != null:
		K.check(
			fails,
			not (jn.get("props") as Dictionary).has(ci),
			"no signs or signals at the crossroads"
		)


## ambient.gd: of the traffic that spawns on the tracks most is cyclists.
func _check_ambient() -> void:
	var amb: AMB = f.get("ambient")
	if amb.bike_chance <= 0.0:
		print("  note: cyclists off (ambient not checked)")
		return
	ctx.player.teleport(Vector3(centre.x, WS.ASPHALT_TOP, centre.y), 0.0, 0.0, false)
	var rough := 0
	var bikes := 0
	for _k in range(12):
		for c: VH.Car in _vh().cars.duplicate():
			if not c.parked:
				_vh().remove(c)
		f.set("ambient_enabled", true)
		amb.maintain(ctx.player_position(), Vector3(0, 0, -1), true)
		f.set("ambient_enabled", false)
		for c: VH.Car in _vh().cars:
			if c.role != "ambient" or c.parked:
				continue
			var i := D.idx(roundi(c.pos.x), roundi(c.pos.z))
			if sim.kind[i] == D.ROAD and sim.level[i] > D.GRADE_PAVED:
				rough += 1
				bikes += 1 if c.kind == "bike" else 0
	var share := float(bikes) / maxf(float(rough), 1.0)
	if rough < 6:
		print("  note: only %d spawns on the tracks (share not checked)" % rough)
		return
	K.check(fails, share > 0.45, "most traffic on tracks is cyclists (%d of %d)" % [bikes, rough])


## residents.gd: a route mostly on tracks is rural, and more people bike a rural trip.
func _check_residents() -> void:
	var res: Residents = ctx.residents
	var route: Array = []
	for k in range(-2, 3):
		route.append(Vector2i(centre.x + k, centre.y))
	K.check(fails, res.is_rural(route), "a route along the dirt track is rural")
	var town: Array = []
	var p := _paved_road()
	if p >= 0:
		town.append(Vector2i(D.tx(p), D.ty(p)))
	K.check(fails, not res.is_rural(town), "a paved route is not")
	var plain := 0
	var rural := 0
	for r: Dictionary in res.people:
		plain += 1 if res.keeps_bike(r) else 0
		rural += 1 if res.keeps_bike(r, true) else 0
	K.check(fails, rural > plain, "more keep a bicycle for rural trips (%d vs %d)" % [rural, plain])


## road_plans.gd: a heuristic mayor short of money opens land with cheap grades, and a rich one
## paves an unpaved road with a built lot beside it.
func _check_brain() -> void:
	var got: Array[String] = []
	for funds: int in [500, 2000, 4000, 8000]:
		got.append(ROADS.thrifty_grade(funds))
	K.check(
		fails,
		got == ["trail", "dirt", "gravel", "paved"],
		"cheaper roads when poorer (%s)" % str(got)
	)
	var lot := D.idx(centre.x + 1, centre.y + 1)
	var was_k := sim.kind[lot]
	var was_l := sim.level[lot]
	sim.kind[lot] = D.ZONE_R
	sim.level[lot] = 1
	var a := ROADS.plan_paving(sim, mi)
	sim.kind[lot] = was_k
	sim.level[lot] = was_l
	K.check(
		fails,
		(
			str(a.get("grade", "")) == "paved"
			and int(a.get("y", -1)) == centre.y
			and int(a.get("y2", -1)) == centre.y
		),
		"a rich mayor paves the track beside a built lot (%s)" % str(a)
	)


## build_rules.gd: the phone previews a grade at its price, upgrades but never downgrades, and
## puts the grade in the order.
func _check_phone() -> void:
	var a := Vector2i(centre.x - 2, centre.y)
	var b := Vector2i(centre.x + 2, centre.y)
	var p := RULES.preview(sim, "road", a, b, "park", D.GRADE_GRAVEL)
	K.check(
		fails,
		bool(p["ok"]) and int(p["cost"]) == 5 * 6 and str(p["action"].get("grade", "")) == "gravel",
		"phone: gravel over the dirt track, 5 tiles at $6 (%s)" % str(p.get("reason", ""))
	)
	p = RULES.preview(sim, "road", a, b, "park", D.GRADE_TRAIL)
	K.check(fails, not bool(p["ok"]), "phone: a trail over dirt is already there")
	p = RULES.preview(sim, "road", a, b, "park")
	K.check(
		fails, bool(p["ok"]) and not p["action"].has("grade"), "phone: paved orders carry no grade"
	)


## Staged: resurfacing opens a site per tile with the grade's plan and target level.
func _check_staged() -> void:
	sim.construction_mode = "staged"
	var c := centre
	var r := sim.apply_action(
		mi, {"type": "road", "x": c.x, "y": c.y - 2, "x2": c.x, "y2": c.y - 1, "grade": "gravel"}
	)
	var s: Dictionary = sim.sites.get(D.idx(c.x, c.y - 2), {})
	K.check(
		fails,
		(
			bool(r.get("ok", false))
			and str(s.get("plan", "")) == "gravel"
			and int(s.get("target_level", -1)) == D.GRADE_GRAVEL
		),
		"staged: a gravel site with the gravel plan (%s)" % str(r.get("reason", ""))
	)
	var tiles: Array[Vector2i] = []
	for _k in range(20):
		tiles.append(Vector2i(c.x, c.y))
	var est := RULES.crew_seconds(
		sim, "road", "park", {"ok": true, "tiles": tiles, "action": {"grade": "trail"}}
	)
	K.check(
		fails,
		is_equal_approx(est, 20.0 * float(D.CREW_TILE_S["trail"])),
		"crews: 20 tiles of trail take 20 trail times (%.0f s)" % est
	)
	sim.construction_mode = "instant"


## Constants other layers read: minimap colours and footstep surfaces.
func _check_bits() -> void:
	var paved := MINIMAP.tile_color(D.ROAD, 0, D.LAND, 0)
	var dirt := MINIMAP.tile_color(D.ROAD, D.GRADE_DIRT, D.LAND, 0)
	K.check(fails, paved != dirt, "minimap: a dirt track is drawn apart from a paved road")
	var steps := [
		BANK.step_surface("gravel"),
		BANK.step_surface("trail"),
		BANK.step_surface("dirt"),
		BANK.step_surface("x")
	]
	K.check(
		fails,
		steps == ["dirt", "grass", "dirt", "sidewalk"],
		"footsteps: gravel crunches like dirt (%s)" % str(steps)
	)
	K.check(
		fails,
		(
			D.grade_of("") == D.GRADE_PAVED
			and D.grade_of("track") == D.GRADE_DIRT
			and D.grade_of("x") == -1
		),
		"grade_of aliases"
	)


# ------------------------------------------------------------------ helpers


## Centre of a (2 ROOM + 1)^2 square of open dry land in one district (sets mi) with no road on
## or beside it.
func _open_square() -> Vector2i:
	for d in range(sim.mayors.size()):
		mi = d
		var b := sim.district_rect(d)
		for y in range(b.position.y, b.end.y):
			for x in range(b.position.x, b.end.x):
				if _open(x, y):
					return Vector2i(x, y)
	return D.NO_TILE


func _open(cx: int, cy: int) -> bool:
	for y in range(cy - ROOM - 1, cy + ROOM + 2):
		for x in range(cx - ROOM - 1, cx + ROOM + 2):
			if not D.in_bounds(x, y):
				return false
			var i := D.idx(x, y)
			if sim.kind[i] == D.ROAD or sim.sites.has(i):
				return false
			var inner := absi(x - cx) <= ROOM and absi(y - cy) <= ROOM
			if (
				inner
				and (
					sim.district[i] != mi
					or sim.terrain[i] != D.LAND
					or not (
						sim.kind[i] in [D.EMPTY, D.FOREST]
						or (D.is_zone(sim.kind[i]) and sim.level[i] == 0)
					)
				)
			):
				return false
	return true


## Levels of the 5 tiles through c along step.
func _levels(c: Vector2i, step: Vector2i) -> Array:
	var out := []
	for k in range(-2, 3):
		var p := c + step * k
		out.append(sim.level[D.idx(p.x, p.y)] if sim.kind[D.idx(p.x, p.y)] == D.ROAD else -1)
	return out


## A tile beside a paved road away from the test square, or -1.
func _paved_road() -> int:
	for i in range(sim.kind.size()):
		if sim.kind[i] == D.ROAD and sim.level[i] == D.GRADE_PAVED and sim.terrain[i] == D.LAND:
			if absi(D.tx(i) - centre.x) > ROOM + 3 or absi(D.ty(i) - centre.y) > ROOM + 3:
				return i
	return -1


## Rebuilds the view, collision and lanes for the new roads.
func _rebuild() -> void:
	ctx.view.rebuild_all(false)
	ctx.collision.rebuild_all()


func _vh() -> VH:
	return f.get("vehicles")
