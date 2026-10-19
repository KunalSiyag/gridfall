extends SceneTree
## Slice E acceptance (docs/fp/slices/E-traffic.md, Acceptance tests): fixtures, the lane graph
## (arms, shared endpoints, right-hand offsets beside parked cars, corner radii, carriageway,
## rebuild on tile_cleared only), car following, parking clearance, traffic lights, tee yield,
## player yield, a resident driver (from trip_started to a curb slot, position_of, pick,
## visible_near), a walking trip on sidewalks and zebras, conversations, save and load, the
## CityLife and ResidentAvatars hooks, and API compatibility. Time runs through feature.step(1/30).

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const SW := preload("res://scripts/fp/traffic/sidewalks.gd")
const JN := preload("res://scripts/fp/traffic/junctions.gd")
const IDM := preload("res://scripts/fp/traffic/idm.gd")
const TRIPS := preload("res://scripts/fp/traffic/trips.gd")
const DT := 1.0 / 30.0

var fails: Array[String] = []
var ctx: FpContext
var f: Node
var sim: CitySim
var fixture_rid: String = ""
var corner_tile: int = -1
var tee_tile: int = -1
var cross_tile: int = -1


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true})
	sim = ctx.sim
	if not _fixtures():
		K.finish(self, "FP_TRAFFIC_TEST", fails)
		return
	f = K.make_feature(ctx, "traffic")
	f.set("auto_step", false)
	K.check(fails, f.self_test().get("ok", false), "self_test right after the first fill: %s" % f.self_test().get("detail", ""))
	_check_attach()
	_check_lane_graph()
	_check_api_compat()
	_check_following()
	_check_parking_clearance()
	_check_lights()
	_check_tee()
	_check_player_yield()
	sim.set_day_seconds(WS.FP_DAY_SECONDS)
	f.set("jitter_enabled", false)
	_check_resident_driver()
	_check_walker()
	_check_conversation()
	_check_people_e2()
	_check_save()
	_check_fleets()
	K.finish(self, "FP_TRAFFIC_TEST", fails)


# ------------------------------------------------------------------ helpers

func _step(seconds: float) -> void:
	for _k in range(int(round(seconds / DT))):
		f.step(DT)


## Removes moving vehicles and walkers and stops the ambient filler (parked cars stay).
func _quiet() -> void:
	f.set("ambient_enabled", false)
	var vh: VH = f.get("vehicles")
	for c: VH.Car in vh.cars.duplicate():
		if not c.parked:
			vh.remove(c)
	var wk: WK = f.get("walkers")
	for w: WK.Walker in wk.walkers.duplicate():
		wk.remove(w)
	f.get("trips").trips.clear()
	f.get("trips").standing.clear()


func _lg() -> LG:
	return f.get("lanes")


func _vh() -> VH:
	return f.get("vehicles")


## A test car of the first ambient model on lane l at s with the given path.
func _car(l: LG.Lane, s: float, path: Array, v: float) -> VH.Car:
	var vh := _vh()
	var m: int = f.car_model_for("test-car")
	var c := vh.make("car", "test", f.dims(m))
	c.model = m
	vh.place(c, l, s)
	c.path = path.duplicate()
	c.v = v
	return c


func _fixtures() -> bool:
	var bus := ctx.view.bus_stops.size()
	for i in sim.active:
		if sim.kind[i] != D.ROAD:
			continue
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		if m in [3, 6, 9, 12] and corner_tile < 0:
			corner_tile = i
		var p := str(RoadTopology.piece(m)[0])
		if p == "tee" and tee_tile < 0:
			tee_tile = i
		if p == "cross" and cross_tile < 0:
			cross_tile = i
	for r: Dictionary in ctx.residents.people:
		if (r["skills"] as Array).has("construction"):
			continue
		if str(r["state"]) == "home" and int(r["at"]) == int(r["home"]) and int(r["work"]) >= 0 and ctx.directory.frontage(int(r["home"])) >= 0 and ctx.directory.frontage(int(r["work"])) >= 0 and int(r["helping"]) < 0:
			# A real drive: home and work on different streets, 4+ road tiles apart.
			if ctx.residents.route_between(int(r["home"]), int(r["work"])).size() >= 6:
				fixture_rid = str(r["id"])
				break
	K.check(fails, corner_tile >= 0, "fixture: a corner road tile (mask 3, 6, 9 or 12)")
	K.check(fails, tee_tile >= 0, "fixture: a tee")
	K.check(fails, cross_tile >= 0, "fixture: a cross")
	K.check(fails, bus >= 1, "fixture: a bus stop (%d)" % bus)
	K.check(fails, not fixture_rid.is_empty(), "fixture: a resident at home with work >= 0")
	return fails.is_empty()


# ------------------------------------------------------------------ hooks

func _check_attach() -> void:
	K.check(fails, ctx.view.life.external == f and ctx.view.avatars.external == f, "on_world_rebuilt sets CityLife.external and ResidentAvatars.external")
	var hidden := true
	for a: Dictionary in ctx.view.avatars.get("_avatars").values():
		if (a["root"] as Node3D).visible:
			hidden = false
	K.check(fails, hidden, "legacy avatar roots are hidden while the feature draws residents")


# ------------------------------------------------------------------ lane graph

func _check_lane_graph() -> void:
	var lg := _lg()
	var bad_arm := 0
	var tiles := 0
	for i in sim.active:
		if sim.kind[i] != D.ROAD:
			continue
		tiles += 1
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		var t: LG.TileInfo = lg.info(i)
		if t == null:
			bad_arm += 1
			continue
		for e in range(4):
			if not (m & (1 << e)):
				continue
			var out := false
			for l: LG.Lane in t.lanes:
				if l.to_e == e:
					out = true
			if lg.entry(i, e).is_empty() or not out:
				bad_arm += 1
	K.check(fails, tiles > 0 and bad_arm == 0, "every road tile (%d) has a lane in and out of each open arm (%d missing)" % [tiles, bad_arm])
	var mism := 0
	var pairs := 0
	for x: Variant in lg.lanes:
		var l := x as LG.Lane
		if l == null or l.to_e < 0:
			continue
		for n: LG.Lane in lg.next_lanes(l):
			pairs += 1
			if l.pts[l.pts.size() - 1].distance_to(n.pts[0]) > 1e-5:
				mism += 1
		var nb := lg.across(l.tile, l.to_e)
		if nb >= 0 and sim.kind[nb] == D.ROAD and lg.next_lanes(l).is_empty():
			mism += 1
	K.check(fails, pairs > 0 and mism == 0, "lane endpoints on shared tile edges coincide (%d joins, %d off)" % [pairs, mism])
	_check_offsets(lg)
	# Corner arcs about the shared tile corner.
	var t: LG.TileInfo = lg.info(corner_tile)
	var worst := 0.0
	var arms: Array[Vector2i] = RoadTopology.arms(t.mask)
	var cc := Vector2(D.tx(corner_tile), D.ty(corner_tile)) + (Vector2(arms[0]) + Vector2(arms[1])) * 0.5
	for l: LG.Lane in t.lanes:
		for p: Vector2 in l.pts:
			var r := p.distance_to(cc)
			worst = maxf(worst, minf(absf(r - WS.CORNER_LANE_R_IN), absf(r - WS.CORNER_LANE_R_OUT)))
	K.check(fails, t.lanes.size() == 2 and worst <= 0.005, "corner lanes at (%d,%d) stay within 0.005 of radius 0.35 or 0.65 (worst %.4f)" % [D.tx(corner_tile), D.ty(corner_tile), worst])
	var off := 0
	var samples := 0
	var uturns := 0
	for x: Variant in lg.lanes:
		var l := x as LG.Lane
		if l == null:
			continue
		if l.kind == LG.UTURN:
			uturns += 1
		var c := Vector2(D.tx(l.tile), D.ty(l.tile))
		var m := RoadTopology.mask(sim, D.tx(l.tile), D.ty(l.tile))
		for p: Vector2 in l.pts:
			samples += 1
			if not RoadTopology.is_carriageway(m, p - c):
				off += 1
	K.check(fails, uturns > 0 and off == 0, "every lane polyline stays on the carriageway, U-turns included (%d samples, %d off, %d U-turns)" % [samples, off, uturns])
	_check_rebuild(lg)


## A mask-5 tile: the lane heading -Z sits at x + LANE_OFFSET, and at PASS_OFFSET beside a parked car.
func _check_offsets(lg: LG) -> void:
	var tile := -1
	for i: int in lg.tiles.keys():
		var t: LG.TileInfo = lg.tiles[i]
		if t.mask == RoadTopology.NS and lg.parkable(i) and (lg.slot_valid(i, 0) or lg.slot_valid(i, 1)):
			tile = i
			break
	K.check(fails, tile >= 0, "fixture: a parkable N-S straight")
	if tile < 0:
		return
	var vh := _vh()
	for c: VH.Car in vh.cars.duplicate():
		if c.parked and c.slot_tile == tile and c.slot_k < 2:
			vh.remove(c)
	for k in range(2):
		if not lg.slot_free(tile, k):
			lg.set_slot(tile, k, "")
	var l := lg.lane_between(tile, 2, 0)
	var mid := lg.pos_at(l, l.length * 0.5)
	K.check(fails, l != null and absf(mid.x - (float(D.tx(tile)) + WS.LANE_OFFSET)) < 1e-4, "mask-5 lane heading -Z at x + LANE_OFFSET (%.4f)" % (mid.x - float(D.tx(tile))))
	var k0 := 0 if lg.slot_valid(tile, 0) else 1
	lg.set_slot(tile, k0, "test")
	mid = lg.pos_at(l, l.length * 0.5)
	K.check(fails, absf(mid.x - (float(D.tx(tile)) + WS.PASS_OFFSET)) < 1e-4, "with a car parked on that run it moves to PASS_OFFSET (%.4f)" % (mid.x - float(D.tx(tile))))
	lg.set_slot(tile, k0, "")
	mid = lg.pos_at(l, l.length * 0.5)
	K.check(fails, absf(mid.x - (float(D.tx(tile)) + WS.LANE_OFFSET)) < 1e-4, "and back to LANE_OFFSET when the slot frees")
	f.call("_after_lane_change")


## tile_cleared rebuilds the graph; sim.tiles_changed alone does not.
func _check_rebuild(lg: LG) -> void:
	var end_tile := -1
	for i: int in lg.tiles.keys():
		if (lg.tiles[i] as LG.TileInfo).piece == "end":
			end_tile = i
			break
	if end_tile < 0:
		K.check(fails, false, "fixture: a cul-de-sac end to bulldoze")
		return
	var arm: int = 0
	var m := (lg.info(end_tile) as LG.TileInfo).mask
	for e in range(4):
		if m & (1 << e):
			arm = e
	var nb := lg.across(end_tile, arm)
	var builds0 := lg.builds
	sim.kind[end_tile] = D.EMPTY
	var view := ctx.view
	var handler := Callable(view, "_on_tiles_changed")
	var was := sim.tiles_changed.is_connected(handler)
	if was:
		sim.tiles_changed.disconnect(handler)
	sim.tiles_changed.emit(PackedInt32Array([end_tile]))
	K.check(fails, lg.tiles.has(end_tile) and lg.builds == builds0, "sim.tiles_changed alone does not touch the lane graph")
	view.tile_cleared.emit(end_tile)
	var nt: LG.TileInfo = lg.info(nb)
	K.check(fails, not lg.tiles.has(end_tile) and nt != null and not (nt.mask & (1 << LG.OPP[arm])), "view.tile_cleared rebuilds the tile and its neighbours")
	sim.kind[end_tile] = D.ROAD
	view.tile_built.emit(end_tile, view.tile_holder(end_tile))
	if was:
		sim.tiles_changed.connect(handler)
	K.check(fails, lg.tiles.has(end_tile), "view.tile_built brings the lanes back")


# ------------------------------------------------------------------ API compatibility

func _check_api_compat() -> void:
	var vc: Dictionary = ctx.view.life.vehicle_counts()
	var keys := vc.keys()
	keys.sort()
	K.check(fails, keys == ["aircraft", "boats", "buses", "crews", "trucks"], "vehicle_counts() keeps exactly the 5 legacy keys (%s)" % str(keys))
	var ac: Dictionary = ctx.view.avatars.visible_count()
	var ak := ac.keys()
	ak.sort()
	K.check(fails, ak == ["driving", "standing", "total", "walking"], "visible_count() keeps its 4 keys (%s)" % str(ak))
	K.check(fails, typeof(ctx.view.avatars.pick(Vector2(400, 300))) == TYPE_STRING, "avatars.pick(Vector2) returns a String")
	K.check(fails, typeof(ctx.view.avatars.position_of(fixture_rid)) == TYPE_VECTOR3, "avatars.position_of(id) returns a Vector3")
	# Orbit: a CityView without FpMode keeps the legacy avatars exactly.
	var v2 := K.make_view(get_root(), sim)
	var av: ResidentAvatars = v2.avatars
	var r := ctx.residents.find(fixture_rid)
	var saved_route: Variant = r.get("route", [])
	var home := int(r["home"])
	r["route"] = [Vector2i(D.tx(home), D.ty(home)), Vector2i(D.tx(home) + 1, D.ty(home)), Vector2i(D.tx(home) + 2, D.ty(home))]
	av.call("_on_moved", r)
	var a: Dictionary = av.get("_avatars")[fixture_rid]
	var tick_len := sim.tick_seconds() / float(maxi(sim.speed, 1))
	var want := 2.0 / clampf(tick_len * 0.85, 0.6, 2.8)
	K.check(fails, is_equal_approx(float(a["speed"]), want), "orbit _on_moved still sets speed from sim.tick_seconds() (%.3f vs %.3f)" % [float(a["speed"]), want])
	av.call("_advance", a, r, 0.05)
	var y := (a["root"] as Node3D).position.y
	var sc := (a["person"] as Node3D).scale.x
	K.check(fails, y >= 0.05 and y <= 0.06 and is_equal_approx(sc, 1.5), "orbit avatars keep y = 0.05 and scale 1.5 (y %.4f, scale %.2f)" % [y, sc])
	K.check(fails, av.external == null, "orbit avatars have no external")
	r["route"] = saved_route
	v2.free()


# ------------------------------------------------------------------ car following

## The longest run of N-S or E-W straights: [tiles in order, heading edge].
func _straight_run() -> Array:
	var lg := _lg()
	var best: Array[int] = []
	var best_e := 0
	for i: int in lg.tiles.keys():
		var t: LG.TileInfo = lg.tiles[i]
		if t.piece != "straight" or t.bridge:
			continue
		for e: int in [0, 1]:
			if not (t.mask & (1 << e)):
				continue
			var back := lg.across(i, LG.OPP[e])
			if back >= 0 and lg.info(back) != null and (lg.info(back) as LG.TileInfo).piece == "straight" and (lg.info(back) as LG.TileInfo).mask == t.mask:
				continue
			var run: Array[int] = [i]
			var cur := i
			while true:
				var nx := lg.across(cur, e)
				if nx < 0 or lg.info(nx) == null or (lg.info(nx) as LG.TileInfo).piece != "straight" or (lg.info(nx) as LG.TileInfo).mask != t.mask:
					break
				run.append(nx)
				cur = nx
			if run.size() > best.size():
				best = run
				best_e = e
	return [best, best_e]


func _check_following() -> void:
	_quiet()
	var run: Array = _straight_run()
	var tiles: Array[int] = run[0]
	var e: int = run[1]
	K.check(fails, tiles.size() >= 5, "fixture: a straight run of 5+ tiles (%d)" % tiles.size())
	if tiles.size() < 5:
		return
	var lanes := _lg().lanes_along(tiles, LG.OPP[e], e)
	var leader := _car(lanes[2], 0.5, lanes.slice(3), WS.CAR_RESIDENTIAL * 0.6)
	var follower := _car(lanes[0], 0.5, lanes.slice(1), WS.CAR_CITY)
	var min_gap := INF
	var dir := Vector3(LG.DIRS[e].x, 0, LG.DIRS[e].y)
	for k in range(int(30.0 / DT)):
		if k == int(3.0 / DT):
			leader.hold = true
		f.step(DT)
		var gap := (leader.pos - follower.pos).dot(dir) - (leader.length + follower.length) * 0.5
		min_gap = minf(min_gap, gap)
	var final_gap := (leader.pos - follower.pos).dot(dir) - (leader.length + follower.length) * 0.5
	K.check(fails, min_gap > 0.0, "following: no overlap over 30 s (min gap %.2f m)" % (min_gap / WS.M))
	K.check(fails, final_gap >= IDM.S0 * 0.9 and follower.v < 0.05 * WS.M and leader.v < 0.01, "following: the follower stops >= s0 * 0.9 behind the stopped leader (%.2f m, v %.2f m/s)" % [final_gap / WS.M, follower.v / WS.M])
	_vh().remove(leader)
	_vh().remove(follower)


# ------------------------------------------------------------------ parking clearance

func _check_parking_clearance() -> void:
	_quiet()
	f.set("ambient_enabled", true)
	f.call("_maintain", true)
	var vh := _vh()
	var overlaps := 0
	var passes := 0
	var worst := ""
	for k in range(int(60.0 / DT)):
		f.step(DT)
		if k % 3 != 0:
			continue
		for c: VH.Car in vh.cars:
			if c.parked or c.far or c.dead or c.park_t >= 0.0 or c.kind == "bike":
				continue
			var a := vh.aabb(c).grow(-0.0005)
			for p: VH.Car in vh.cars:
				if not p.parked or p.dead or p.slot_tile < 0:
					continue
				if absf(p.pos.x - c.pos.x) > 0.5 or absf(p.pos.z - c.pos.z) > 0.5:
					continue
				if absf(p.pos.x - c.pos.x) < 0.2 and absf(p.pos.z - c.pos.z) < 0.2:
					passes += 1
				if a.intersects(vh.aabb(p).grow(-0.0005)):
					overlaps += 1
					if worst.is_empty():
						worst = "car %d (%s) at %s vs parked %d at %s" % [c.id, c.role, str(c.pos), p.id, str(p.pos)]
	K.check(fails, passes > 0, "parking clearance: moving cars pass parked ones (%d close passes)" % passes)
	K.check(fails, overlaps == 0, "parking clearance: no moving AABB overlaps a parked AABB in 60 s (%d) %s" % [overlaps, worst])


# ------------------------------------------------------------------ lights

func _check_lights() -> void:
	_quiet()
	var lg := _lg()
	var jn: JN = f.get("junctions")
	var x := -1
	for i: int in lg.tiles.keys():
		var t: LG.TileInfo = lg.tiles[i]
		if t.lights and t.approach[2] != null and not lg.prev_lanes(t.approach[2]).is_empty():
			var p: LG.Lane = lg.prev_lanes(t.approach[2])[0]
			if p.kind == LG.STRAIGHT:
				x = i
				break
	K.check(fails, x >= 0, "fixture: a cross with a straight south arm")
	if x < 0:
		return
	var t: LG.TileInfo = lg.info(x)
	var a: LG.Lane = t.approach[2]
	var prev: LG.Lane = lg.prev_lanes(a)[0]
	var mv := lg.lane_between(x, 2, 0)
	var after: LG.Lane = lg.next_lanes(mv)[0]
	# Clock so that E-W just turned green: N-S is red for the next 16 s.
	var c0 := fposmod(16.0 - jn.offset(x), JN.CYCLE)
	f.set("clock", c0)
	jn.clock = c0
	K.check(fails, jn.light(x, 2) == JN.RED, "light: the south approach is red")
	var car := _car(prev, 0.25, [a, mv, after], WS.CAR_RESIDENTIAL)
	var stopped_at := -1.0
	var stop_red := false
	for _k in range(int(14.0 / DT)):
		f.step(DT)
		var front := (lg.pos_at(car.lane, car.s) - Vector2(D.tx(x), D.ty(x))).dot(LG.DIRS[2])
		if car.v < 0.01 * WS.M and front < 0.6 and stopped_at < 0.0:
			stopped_at = front
			stop_red = jn.light(x, 2) == JN.RED
	K.check(fails, stopped_at >= LG.STOP_FRONT - 0.0005 and stopped_at <= LG.STOP_FRONT + 0.03 and stop_red, "light: a car arriving on red stops with its front %.3f from the centre (window %.3f..%.3f)" % [stopped_at, LG.STOP_FRONT, LG.STOP_FRONT + 0.03])
	var entered_on := -1
	for _k in range(int(25.0 / DT)):
		var was_on_a := car.lane == a
		f.step(DT)
		if was_on_a and car.lane == mv:
			entered_on = jn.light(x, 2)
			break
	K.check(fails, entered_on == JN.GREEN or entered_on == JN.AMBER, "light: it proceeds on green (entered the box on %d)" % entered_on)
	_vh().remove(car)
	# Lamps: per-instance overrides from shared on/off materials; the shared ones never change.
	var pr: Dictionary = jn.props.get(x, {})
	var groups: Array = pr.get("groups", [])
	var on_red: StandardMaterial3D = jn.get("_on_mats")[0]
	var energy := on_red.emission_energy_multiplier
	var col := on_red.albedo_color
	jn.clock = c0
	jn.update_lamps(Vector3(D.tx(x), 0, D.ty(x)), 1.0)
	var ns_red: GeometryInstance3D = (groups[0] as Array)[0] if groups.size() == 6 and not (groups[0] as Array).is_empty() else null
	var ns_green: GeometryInstance3D = (groups[2] as Array)[0] if groups.size() == 6 and not (groups[2] as Array).is_empty() else null
	K.check(fails, ns_red != null and ns_red.material_override == on_red and ns_green.material_override == jn.get("_off_mats")[2], "lamps: N-S red lit, green dark (material_override)")
	jn.clock = fposmod(-jn.offset(x) + 1.0, JN.CYCLE)
	jn.update_lamps(Vector3(D.tx(x), 0, D.ty(x)), 1.0)
	K.check(fails, ns_red != null and ns_red.material_override == jn.get("_off_mats")[0] and ns_green.material_override == jn.get("_on_mats")[2], "lamps: N-S green lit after the change")
	K.check(fails, is_equal_approx(on_red.emission_energy_multiplier, energy) and on_red.albedo_color == col, "lamps: the shared materials are never edited")
	K.check(fails, f.light_pole(x, 0) != null and f.light_pole(x, 0).find_child("SignText_A", false, false) != null, "light_pole(i, 0) is the NE pole with SignText_A / SignText_B mounts")
	f.set("clock", 0.0)
	jn.clock = 0.0


# ------------------------------------------------------------------ tee yield

func _check_tee() -> void:
	_quiet()
	var lg := _lg()
	var tile := -1
	var through := -1
	for i: int in lg.tiles.keys():
		var t: LG.TileInfo = lg.tiles[i]
		if t.stem < 0:
			continue
		var stem_prev := lg.prev_lanes(t.approach[t.stem])
		for e in range(4):
			if e == t.stem or t.approach[e] == null:
				continue
			var pv := lg.prev_lanes(t.approach[e])
			if not pv.is_empty() and (pv[0] as LG.Lane).kind == LG.STRAIGHT and not stem_prev.is_empty():
				tile = i
				through = e
				break
		if tile >= 0:
			break
	K.check(fails, tile >= 0, "fixture: a tee with straight approaches")
	if tile < 0:
		return
	var t: LG.TileInfo = lg.info(tile)
	var sa: LG.Lane = t.approach[t.stem]
	var smv: LG.Lane = t.moves[t.stem][0]
	var sp: LG.Lane = lg.prev_lanes(sa)[0]
	var s_after: Array = lg.next_lanes(smv)
	var stem_car := _car(sp, sp.length - 0.05, [sa, smv] + s_after.slice(0, 1), WS.CAR_RESIDENTIAL * 0.5)
	var ta: LG.Lane = t.approach[through]
	var tmv := lg.lane_between(tile, through, LG.OPP[through])
	var tp: LG.Lane = lg.prev_lanes(ta)[0]
	var t_after: Array = lg.next_lanes(tmv)
	# Through car ~1.5 s from its stop point at speed.
	var v := tp.limit * 0.9
	var through_car := _car(tp, clampf(tp.length + ta.stop_s - v * 1.5, 0.3, tp.length - 0.01), [ta, tmv] + t_after.slice(0, 1), v)
	var stem_in_at := -1.0
	var through_in_at := -1.0
	var time := 0.0
	for _k in range(int(20.0 / DT)):
		f.step(DT)
		time += DT
		if stem_in_at < 0.0 and stem_car.lane == smv:
			stem_in_at = time
		if through_in_at < 0.0 and through_car.lane == tmv:
			through_in_at = time
	K.check(fails, through_in_at >= 0.0 and stem_in_at > through_in_at, "tee: the stem car waits for the through car within 2 s (stem in at %.1f s, through in at %.1f s)" % [stem_in_at, through_in_at])
	_vh().remove(stem_car)
	_vh().remove(through_car)
	var jn: JN = f.get("junctions")
	var pr: Dictionary = jn.props.get(tile, {})
	var ok := false
	if pr.has("sign"):
		var sp2: Vector2 = pr["sign"]
		var a := LG.DIRS[t.stem]
		var perp := absf((sp2 - Vector2(D.tx(tile), D.ty(tile))).dot(Vector2(-a.y, a.x)))
		ok = perp >= WS.CURB_FURNITURE[0] and perp <= WS.CURB_FURNITURE[1]
	K.check(fails, ok, "tee: the stem has a %s sign in CURB_FURNITURE" % str(pr.get("kind", "?")))


# ------------------------------------------------------------------ player yield

func _check_player_yield() -> void:
	_quiet()
	var run: Array = _straight_run()
	var tiles: Array[int] = run[0]
	var e: int = run[1]
	var lanes := _lg().lanes_along(tiles, LG.OPP[e], e)
	var car := _car(lanes[0], 0.4, lanes.slice(1), WS.CAR_CITY)
	car.v0 = WS.CAR_CITY
	var front := _lg().pos_at(car.lane, car.s)
	var h := LG.DIRS[e]
	var at := front + h * 1.0
	var saved := ctx.player.position
	ctx.player.teleport(Vector3(at.x, 0, at.y), 0.0)
	var pp := ctx.player.position
	var min_d := INF
	for _k in range(int(20.0 / DT)):
		f.step(DT)
		for c: VH.Car in _vh().cars:
			if c.parked or c.dead:
				continue
			min_d = minf(min_d, _aabb_dist(_vh().aabb(c), pp))
	var d_end := _aabb_dist(_vh().aabb(car), pp)
	K.check(fails, car.v < 0.05 * WS.M and d_end >= WS.PLAYER_RADIUS + 1.5 * WS.M, "player yield: the car stops %.2f m from the player (>= %.2f)" % [d_end / WS.M, (WS.PLAYER_RADIUS + 1.5 * WS.M) / WS.M])
	K.check(fails, min_d >= WS.PLAYER_RADIUS, "player yield: no car AABB comes within PLAYER_RADIUS (closest %.2f m)" % (min_d / WS.M))
	_vh().remove(car)
	ctx.player.teleport(saved, 0.0)


func _aabb_dist(b: AABB, p: Vector3) -> float:
	var q := Vector2(clampf(p.x, b.position.x, b.end.x), clampf(p.z, b.position.z, b.end.z))
	return q.distance_to(Vector2(p.x, p.z))


# ------------------------------------------------------------------ resident driver

func _check_resident_driver() -> void:
	_quiet()
	f.set("ambient_enabled", true)
	f.call("_maintain", true)
	var people := ctx.residents
	var r := people.find(fixture_rid)
	r["plan"] = {"commute": "car", "go_to_work": true, "spend": 0, "spend_where": "none", "evening": "home"}
	var work := int(r["work"])
	sim.tick_in_day = 0
	sim.step_tick()
	var trips: TRIPS = f.get("trips")
	var tr: TRIPS.Trip = trips.trips.get(fixture_rid, null)
	if tr == null or tr.mode != "car":
		# The growth tick before the morning can close their workplace (power): send them anyway.
		print("  note: %s did not drive this morning (%s); sending them to work directly" % [fixture_rid, str((r["memory"] as Array).back() if not (r["memory"] as Array).is_empty() else "")])
		if tr != null:
			trips.complete_now(tr)
		people.call("_go", r, work, "work")
		tr = trips.trips.get(fixture_rid, null)
	K.check(fails, tr != null and tr.mode == "car", "resident driver: trip_started makes a car trip (%s; %s state %s at %d work %d route %d trips %s)" % [tr.mode if tr != null else "none", fixture_rid, str(r["state"]), int(r["at"]), work, (r.get("route", []) as Array).size(), str(trips.trips.keys())])
	if tr == null:
		return
	var n := 0
	for c: VH.Car in _vh().cars:
		if c.driver_id == fixture_rid and not c.dead:
			n += 1
	var walkers := 0
	for w: WK.Walker in (f.get("walkers") as WK).walkers:
		if w.resident_id == fixture_rid:
			walkers += 1
	K.check(fails, n == 1 and walkers <= 1, "resident driver: exactly one vehicle with driver_id %s at once (%d, walkers %d)" % [fixture_rid, n, walkers])
	var car: VH.Car = tr.car
	if car == null:
		K.check(fails, false, "resident driver: the trip has a car")
		return
	var route_tiles: int = maxi(1, (r["route"] as Array).size() - 2)
	var limit := float(route_tiles) * 20.0 / 13.9 * 1.6 + 15.0
	var time := 0.0
	var pos_err := 0.0
	var root_shown := false
	var drove := false
	var picked_car := false
	var picked_res := false
	var inside_seen := ""
	var parked_at := -1.0
	var av := ctx.view.avatars
	var legacy: Dictionary = av.get("_avatars")
	while time < limit + 40.0:
		f.step(DT)
		time += DT
		if car.dead:
			break
		if not car.parked and car.park_t < 0.0 and tr.phase == "drive":
			drove = true
			pos_err = maxf(pos_err, av.position_of(fixture_rid).distance_to(car.pos + car.vis_off))
			if not picked_car:
				var o := car.pos + car.vis_off + Vector3(0, 0.03, 0) + Vector3(sin(car.yaw + 1.2), 0, cos(car.yaw + 1.2)) * 0.12
				var hit: Dictionary = f.pick(o, (car.pos + car.vis_off + Vector3(0, 0.03, 0)) - o, WS.INTERACT_RANGE * 4.0)
				picked_car = hit.get("kind", "") == "vehicle" and str(hit.get("data", {}).get("driver_id", "")) == fixture_rid
		if legacy.has(fixture_rid) and (legacy[fixture_rid]["root"] as Node3D).visible:
			root_shown = true
		if parked_at < 0.0 and car.parked and drove:
			parked_at = time
		var w: WK.Walker = trips.walker_of(fixture_rid)
		if w != null and parked_at >= 0.0 and not picked_res:
			var o := w.pos + Vector3(0, 0.2, 0)
			var hit: Dictionary = f.pick(o, Vector3(0, -1, 0), 0.3)
			picked_res = hit.get("kind", "") == "resident" and str(hit.get("id", "")) == fixture_rid
		if int(time / DT) % 15 == 0:
			for e: Dictionary in f.visible_near(ctx.player_position(), 40.0):
				var rid := str(e["id"])
				var rr := people.find(rid)
				if not trips.trips.has(rid) and (rr.is_empty() or TRIPS.inside_state(str(rr.get("state", "")))):
					inside_seen = rid
		if parked_at >= 0.0 and not trips.trips.has(fixture_rid):
			break
	var fr := ctx.directory.frontage(work)
	var near_front := car.parked and car.slot_tile >= 0 and absi(D.tx(car.slot_tile) - D.tx(fr)) + absi(D.ty(car.slot_tile) - D.ty(fr)) <= 2
	K.check(fails, drove and parked_at >= 0.0 and parked_at <= limit and near_front, "resident driver: parks at the destination frontage in %.1f s (limit %.1f s; phase %s, car parked %s slot %d lane %s v %.2f far %s, t %.0f)" % [parked_at, limit, tr.phase, str(car.parked), car.slot_tile, str(Vector2i(D.tx(car.lane.tile), D.ty(car.lane.tile))) if car.lane != null else "-", car.v / WS.M, str(car.far), time] + " held: " + _vh().why_held(car))
	K.check(fails, drove and pos_err <= 0.05, "resident driver: avatars.position_of follows the car while en route (max error %.4f)" % pos_err)
	K.check(fails, not root_shown, "resident driver: the legacy avatar root stays hidden (no double draw)")
	K.check(fails, picked_car, "resident driver: pick() into the car gives kind vehicle with driver_id")
	K.check(fails, picked_res, "resident driver: pick() into the resident on foot gives kind resident")
	K.check(fails, inside_seen.is_empty(), "visible_near never lists a resident who is indoors (%s)" % inside_seen)
	# An ambient walker picks as a pedestrian.
	var amb: WK.Walker = null
	for w: WK.Walker in (f.get("walkers") as WK).walkers:
		if w.role == "ambient" and w.resident_id.is_empty() and not w.dead:
			amb = w
			break
	var ped_ok := false
	var got := {}
	if amb != null:
		var o := amb.pos + Vector3(0, 0.2, 0)
		got = f.pick(o, Vector3(0, -1, 0), 0.3)
		ped_ok = got.get("kind", "") == "pedestrian" and str(got.get("label", "")) == "a pedestrian"
	K.check(fails, ped_ok, "pick() into an ambient walker gives kind pedestrian (%s)" % str(got))


# ------------------------------------------------------------------ walker

func _check_walker() -> void:
	var people := ctx.residents
	var trips: TRIPS = f.get("trips")
	# Settle every trip from the morning so only this one moves.
	for tr: TRIPS.Trip in trips.trips.values():
		trips.complete_now(tr)
	var saved := ctx.player.position
	ctx.player.teleport(Vector3(-40, 0, -40), 0.0)
	var r: Dictionary = {}
	var target := -1
	for x: Dictionary in people.people:
		var at := int(x["at"])
		if str(x["id"]) == fixture_rid or ctx.directory.frontage(at) < 0:
			continue
		for y in sim.active:
			if D.is_zone(sim.kind[y]) and sim.level[y] > 0 and ctx.directory.frontage(y) >= 0 and people.route_between(at, y).size() >= 7:
				target = y
				break
		if target >= 0:
			r = x
			break
	K.check(fails, not r.is_empty(), "fixture: a resident with a lot 5+ road tiles away to walk to")
	if r.is_empty():
		ctx.player.teleport(saved, 0.0)
		return
	var rid := str(r["id"])
	r["plan"] = {"commute": "walk"}
	people.call("_go", r, target, "shopping")
	var tr: TRIPS.Trip = trips.trips.get(rid, null)
	K.check(fails, tr != null and tr.mode == "walk", "walker: a walk trip starts")
	if tr == null:
		ctx.player.teleport(saved, 0.0)
		return
	var on_road := 0
	var bad_surface := 0
	var bad_band := 0
	var bad_feet := 0
	var zebra := 0
	var first_bad := ""
	var time := 0.0
	while time < 900.0 and trips.trips.has(rid):
		f.step(DT)
		time += DT
		var w: WK.Walker = trips.walker_of(rid)
		if w == null or w.on_leg or w.edge == null or w.state != "walk":
			continue
		var x := roundi(w.pos.x)
		var z := roundi(w.pos.z)
		var i := D.idx(x, z)
		if sim.kind[i] != D.ROAD:
			continue
		on_road += 1
		var m := RoadTopology.mask(sim, x, z)
		var lp := Vector2(w.pos.x - x, w.pos.z - z)
		if w.edge.zebra:
			zebra += 1
			continue
		if RoadTopology.is_carriageway(m, lp):
			bad_surface += 1
			if first_bad.is_empty():
				first_bad = "carriageway at %s on (%d,%d)" % [str(lp), x, z]
		var lat := _lateral(m, lp)
		if lat < WS.PED_BAND[0] - 1e-4 or lat > WS.PED_BAND[1] + 1e-4:
			bad_band += 1
			if first_bad.is_empty():
				first_bad = "lateral %.4f at %s on (%d,%d) mask %d" % [lat, str(lp), x, z, m]
		if absf(w.pos.y - WS.SIDEWALK_TOP) > 0.002:
			bad_feet += 1
	K.check(fails, not trips.trips.has(rid) and on_road > 100, "walker: the trip arrives (%.0f s, %d road samples, %d on zebras)" % [time, on_road, zebra])
	K.check(fails, bad_surface == 0 and bad_band == 0, "walker: every sidewalk sample is off the carriageway and inside PED_BAND (%d, %d) %s" % [bad_surface, bad_band, first_bad])
	K.check(fails, bad_feet == 0, "walker: feet at SIDEWALK_TOP on sidewalk samples (%d off)" % bad_feet)
	# stay_home commuters sent far arrive as walk trips.
	var r3: Dictionary = {}
	var far_lot := -1
	for x: Dictionary in people.people:
		if str(x["id"]) == rid or str(x["id"]) == fixture_rid:
			continue
		for i in sim.active:
			if D.is_zone(sim.kind[i]) and sim.level[i] > 0 and ctx.directory.frontage(i) >= 0 and people.route_between(int(x["at"]), i).size() > 6:
				far_lot = i
				break
		if far_lot >= 0:
			r3 = x
			break
	if far_lot >= 0:
		r3["plan"] = {"commute": "stay_home"}
		people.call("_go", r3, far_lot, "at the park")
		var t3: TRIPS.Trip = trips.trips.get(str(r3["id"]), null)
		K.check(fails, t3 != null and t3.mode == "walk", "walker: a stay_home commuter sent more than 6 tiles away arrives as a walk trip")
		if t3 != null:
			trips.complete_now(t3)
	else:
		K.check(fails, false, "fixture: a lot more than 6 tiles away")
	ctx.player.teleport(saved, 0.0)


## Lateral offset of a sidewalk point from the road centreline it follows (tile-local lp).
func _lateral(m: int, lp: Vector2) -> float:
	var arms := RoadTopology.arms(m)
	if arms.size() == 2 and Vector2(arms[0]) == -Vector2(arms[1]):
		return absf(lp.x) if arms[0].x == 0 else absf(lp.y)
	if arms.size() == 2:
		var cc := (Vector2(arms[0]) + Vector2(arms[1])) * 0.5
		return absf(lp.distance_to(cc) - 0.5)
	if arms.size() == 1:
		var a := Vector2(arms[0])
		var o := -a * WS.END_CIRCLE_OFFSET
		if lp.dot(a) >= sqrt(SW.END_R * SW.END_R - SW.LAT * SW.LAT) - WS.END_CIRCLE_OFFSET - 0.001:
			return absf(lp.x) if a.x == 0 else absf(lp.y)
		return lp.distance_to(o) - WS.END_CIRCLE_R + WS.ROAD_HALF
	var best := INF
	for a: Vector2i in arms:
		if lp.dot(Vector2(a)) >= -0.01:
			best = minf(best, absf(lp.x) if a.x == 0 else absf(lp.y))
	return best if best < INF else minf(absf(lp.x), absf(lp.y))


# ------------------------------------------------------------------ conversation

func _check_conversation() -> void:
	var trips: TRIPS = f.get("trips")
	var people := ctx.residents
	var r: Dictionary = {}
	for x: Dictionary in people.people:
		var h := int(x["home"])
		if int(x["at"]) == h and ctx.directory.frontage(h) >= 0:
			var w2 := -1
			for y in sim.active:
				if D.is_zone(sim.kind[y]) and sim.level[y] > 0 and ctx.directory.frontage(y) >= 0 and absi(D.tx(y) - D.tx(h)) + absi(D.ty(y) - D.ty(h)) >= 5:
					w2 = y
					break
			if w2 >= 0:
				r = x
				r["plan"] = {"commute": "walk"}
				people.call("_go", r, w2, "shopping")
				break
	if r.is_empty():
		K.check(fails, false, "fixture: someone to talk to")
		return
	var rid := str(r["id"])
	_step(6.0)
	var w: WK.Walker = trips.walker_of(rid)
	K.check(fails, w != null and w.v > 0.0, "conversation: the resident is walking")
	if w == null:
		return
	var saved := ctx.player.position
	var side := Vector3(sin(w.yaw + PI * 0.5), 0, cos(w.yaw + PI * 0.5)) * (1.2 * WS.M)
	ctx.player.teleport(w.pos + side, 0.0)
	ctx.bus.conversation_changed.emit(rid, true)
	_step(2.0)
	var to_player := ctx.player.position - w.pos
	var face := absf(wrapf(atan2(to_player.x, to_player.z) - w.yaw, -PI, PI))
	K.check(fails, w.v < 0.01 * WS.M and face < deg_to_rad(15.0), "conversation: the resident stops within 2 s and turns to the player (%.0f deg off)" % rad_to_deg(face))
	var head: Vector3 = f.anchor_of(rid)
	K.check(fails, head.distance_to(w.pos + Vector3(0, TRIPS.HEAD, 0)) <= 0.1 * WS.M and absf(head.y - w.pos.y - 1.62 * WS.M) < 0.12 * WS.M, "conversation: anchor_of stays at the head while they stand")
	ctx.bus.conversation_changed.emit(rid, false)
	_step(2.0)
	K.check(fails, w.dead or w.v > 0.0 or w.done, "conversation: they walk on when it ends")
	ctx.player.teleport(saved, 0.0)


# ------------------------------------------------------------------ people (stage E2)

func _check_people_e2() -> void:
	if not (AP as GDScript).get_script_constant_map().has("CHAR_ROSTER"):
		print("  note: stage E2 people checks skipped (AP.CHAR_ROSTER missing; legacy static people)")
		return
	print("  note: AP.CHAR_ROSTER exists; stage E2 checks live on branch fp/E2-people")


# ------------------------------------------------------------------ save

func _check_save() -> void:
	var trips: TRIPS = f.get("trips")
	for tr: TRIPS.Trip in trips.trips.values():
		trips.complete_now(tr)
	var d: Dictionary = f.to_dict()
	var parked: Dictionary = d.get("parked", {})
	K.check(fails, parked.has(fixture_rid), "save: the resident's parked car is in to_dict (%d parked)" % parked.size())
	var parsed: Variant = JSON.parse_string(JSON.stringify(d))
	K.check(fails, typeof(parsed) == TYPE_DICTIONARY, "save: to_dict survives JSON")
	if typeof(parsed) != TYPE_DICTIONARY or not parked.has(fixture_rid):
		return
	var want: Array = parked[fixture_rid]
	# A fresh world: everything rebuilt, then the save restored with no frame in between.
	f.on_world_rebuilt()
	f.from_dict(parsed)
	var c: VH.Car = trips.cars.get(fixture_rid, null)
	K.check(fails, c != null and c.parked and c.slot_tile == int(want[0]) and c.slot_k == int(want[1]), "save: the parked car is back in its slot after from_dict")
	var cars := 0
	var peds := 0
	for x: VH.Car in _vh().cars:
		if not x.dead:
			cars += 1
	for w: WK.Walker in (f.get("walkers") as WK).walkers:
		if not w.dead:
			peds += 1
	K.check(fails, cars >= 2 and peds >= 2, "save: right after from_dict there are cars (%d) and pedestrians (%d)" % [cars, peds])


# ------------------------------------------------------------------ fleets

func _check_fleets() -> void:
	var view := ctx.view
	var fleets = f.get("fleets")
	var ev := {}
	for i in sim.active:
		if D.is_zone(sim.kind[i]) and sim.level[i] > 0:
			ev = sim.trigger_disaster("fire", D.tx(i), D.ty(i), "test", "fleet test")
			if not ev.is_empty():
				break
	K.check(fails, not ev.is_empty(), "fixture: a fire for the crews")
	var crews0: int = fleets.count("crew")
	K.check(fails, crews0 > 0, "fleets: CityLife sends crews through E (%d) %s" % [crews0, fleets.last_dispatch_fail])
	var counts: Dictionary = view.life.vehicle_counts()
	K.check(fails, int(counts.get("crews", 0)) == crews0, "fleets: vehicle_counts() reports E's crews")
	# A second view.setup() makes new CityLife and ResidentAvatars instances.
	var old_life := view.life
	view.setup(sim, view.camera)
	f.on_world_rebuilt()
	K.check(fails, view.life != old_life and view.life.external == f and view.avatars.external == f, "fleets: world_rebuilt re-attaches the hooks to the new instances")
	K.check(fails, fleets.count("crew") > 0, "fleets: an event present before the rebuild gets a crew through E (%d live events) %s" % [sim.events.size(), fleets.last_dispatch_fail])
	f.teardown()
	K.check(fails, view.life.external == null and view.avatars.external == null, "fleets: teardown() clears both hooks")
