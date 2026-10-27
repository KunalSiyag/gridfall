extends SceneTree
## Slice E acceptance (docs/fp/slices/E-traffic.md, Acceptance tests): fixtures, the lane graph
## (arms, shared endpoints, right-hand offsets beside parked cars, corner radii, carriageway,
## rebuild on tile_cleared only), car following, parking clearance, a parked car the player's car
## knocks out of its slot (and its tow back), traffic lights, tee yield,
## player yield, a resident driver (from trip_started to a curb slot, position_of, pick,
## visible_near), a walking trip on sidewalks and zebras, conversations, save and load, the
## CityLife and ResidentAvatars hooks, and API compatibility. Time runs through feature.step(1/30).

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const DRIVE_PLAN := {
	"commute": "car", "go_to_work": true, "spend": 0, "spend_where": "none", "evening": "home"
}
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const SW := preload("res://scripts/fp/traffic/sidewalks.gd")
const JN := preload("res://scripts/fp/traffic/junctions.gd")
const IDM := preload("res://scripts/fp/traffic/idm.gd")
const TRIPS := preload("res://scripts/fp/traffic/trips.gd")
const PPL := preload("res://scripts/fp/traffic/people.gd")
const SHOVES := preload("res://scripts/fp/traffic/shoves.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const RD := preload("res://scripts/fp/traffic/render.gd")
const IND := preload("res://scripts/fp/traffic/indicators.gd")
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
	if f.get("people") != null:
		(f.get("people") as PPL).blocking = true
	K.check(
		fails,
		f.self_test().get("ok", false),
		"self_test right after the first fill: %s" % f.self_test().get("detail", "")
	)
	_check_attach()
	_check_lane_graph()
	_check_api_compat()
	_check_agents_api()
	_check_people_draw()
	_check_fold_rig_silent()
	_check_grounding()
	_check_contact_shadows()
	_check_drivers()
	_check_wait_crowd()
	_check_ambient_spawns()
	_check_density_caps()
	_check_following()
	_check_parking_clearance()
	_check_parked_shove()
	_check_lights()
	_check_night_lamps()
	_check_bike_lamps()
	_check_indicators()
	_check_tee()
	_check_player_yield()
	_check_person_give_way()
	sim.set_day_seconds(WS.FP_DAY_SECONDS)
	f.set("jitter_enabled", false)
	_check_resident_driver()
	_check_walker()
	_check_conversation()
	_check_people_e2()
	_check_save()
	_check_save_reclaim()
	_check_save_owned()
	_check_buses()
	_check_fleets()
	_check_people_async()
	_check_people_fallback()
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
	fixture_rid = _pick_driver()
	K.check(fails, corner_tile >= 0, "fixture: a corner road tile (mask 3, 6, 9 or 12)")
	K.check(fails, tee_tile >= 0, "fixture: a tee")
	K.check(fails, cross_tile >= 0, "fixture: a cross")
	K.check(fails, bus >= 1, "fixture: a bus stop (%d)" % bus)
	K.check(fails, not fixture_rid.is_empty(), "fixture: a resident at home with work >= 0")
	return fails.is_empty()


## A resident who can drive to work from where they are (at home unless anywhere): there and work
## on different streets, 4+ road tiles apart.
func _pick_driver(anywhere := false) -> String:
	for r: Dictionary in ctx.residents.people:
		# Cyclists ride, so they never put a driver in a car.
		if (r["skills"] as Array).has("construction") or ctx.residents.keeps_bike(r):
			continue
		var at := int(r["at"])
		var home: bool = str(r["state"]) == "home" and at == int(r["home"])
		if (
			(home or (anywhere and str(r["state"]) != "work"))
			and int(r["work"]) >= 0
			and ctx.directory.frontage(at) >= 0
			and ctx.directory.frontage(int(r["work"])) >= 0
			and int(r["helping"]) < 0
		):
			if ctx.residents.route_between(at, int(r["work"])).size() >= 6:
				return str(r["id"])
	return ""


# ------------------------------------------------------------------ hooks


## Every walker's feet and every car's wheels sit on the surface under them (sidewalk, zebra,
## carriageway or lot) while ambient traffic runs: nobody floats over the road or sinks into a kerb.
func _check_grounding() -> void:
	var col := ctx.collision
	var wk: WK = f.get("walkers")
	var vh := _vh()
	var stats := {"walk": [0, 0, 0.0, ""], "car": [0, 0, 0.0, ""]}
	for k in range(40):
		_step(0.5)
		for w: WK.Walker in wk.walkers:
			if w.on_leg or w.state == "hidden":
				continue
			var zebra := w.edge != null and w.edge.zebra
			var what := "%s %s zebra=%s" % [w.state, str(w.pos), str(zebra)]
			_ground_sample(stats["walk"], w.pos, col.ground_height(w.pos), what)
		for c: VH.Car in vh.cars:
			var what := "%s %s" % ["parked" if c.parked else "moving", str(c.pos)]
			_ground_sample(stats["car"], c.pos, col.ground_height(c.pos), what)
	_check_body_feet()
	for key: String in stats:
		var s: Array = stats[key]
		var gap := float(s[2]) / WS.M
		print("GROUNDING %s samples=%d off=%d gap_m=%.3f %s" % [key, s[0], s[1], gap, s[3]])
		var why := "%d of %d off by > 2 cm, worst %.3f m: %s" % [s[1], s[0], gap, s[3]]
		var ok := int(s[0]) > 50 and int(s[1]) == 0
		K.check(fails, ok, "grounding: %s stand on the surface (%s)" % [key, why])


## Rendered feet: the lowest toe bone of every posed body (T0-T2, any clip) and the bottom of every
## T3 lod mesh, against the ground under the walker.
func _check_body_feet() -> void:
	var pp: PPL = f.get("people")
	if pp == null:
		return
	var wk: WK = f.get("walkers")
	var by := {}
	var pl := ctx.player
	var saved := pl.position
	for k in range(60):
		if k % 10 == 0:
			_look_at_walker(wk, true)
		f.step(DT * 5.0)
		f.sync_visuals(DT)
		for w: WK.Walker in wk.walkers:
			_feet_sample(by, pp, w)
	pl.teleport(saved, 0.0)
	# The lowest the feet get over a clip: a toe bone sits inside the shoe, a little above the sole
	# (the highest is a stride's lifted foot, so it says nothing).
	var bad: Array[String] = []
	for key: String in by:
		var e: Array = by[key]
		if float(e[1]) < -0.04 or float(e[1]) > 0.05:
			bad.append("%s %.3f..%.3f m" % [key, e[1], e[2]])
	var what := "%d tier/clip groups, off: %s" % [by.size(), ", ".join(bad)]
	var ok := not by.is_empty() and bad.is_empty()
	K.check(fails, ok, "grounding: posed feet touch the ground (%s)" % what)


## Points the camera at a visible walker: from 4 m away when stand_by, else from where it stands.
func _look_at_walker(wk: WK, stand_by: bool) -> void:
	var cam: Vector3 = f.call("_camera_pos")
	var near: WK.Walker = null
	for w: WK.Walker in wk.walkers:
		if w.state == "hidden" or w.on_leg:
			continue
		if near == null or w.pos.distance_to(cam) < near.pos.distance_to(cam):
			near = w
	if near == null:
		return
	if stand_by:
		ctx.player.teleport(near.pos + Vector3(4.0 * WS.M, 0, 4.0 * WS.M), 0.0, 0.0, false)
	ctx.player.look_toward(near.pos + Vector3(0, 1.0 * WS.M, 0))


## Adds w's lowest drawn foot point (m above the ground) to by["T<tier> <state> <clip>"].
func _feet_sample(by: Dictionary, pp: PPL, w: WK.Walker) -> void:
	if w.on_leg or w.state == "hidden" or w.tier < 0:
		return
	var g := ctx.collision.ground_height(w.pos)
	var low := _lowest_foot(pp, w)
	if is_nan(g) or is_inf(low):
		return
	var e: Array = by.get_or_add("T%d %s %s" % [w.tier, w.state, str(w.anim_clip)], [0, INF, -INF])
	e[0] = int(e[0]) + 1
	e[1] = minf(float(e[1]), (low - g) / WS.M)
	e[2] = maxf(float(e[2]), (low - g) / WS.M)


static func _lowest_foot(pp: PPL, w: WK.Walker) -> float:
	var low := INF
	var b: PPL.Body = w.body
	if b != null and b.skel != null and b.root.visible:
		var sk := b.skel
		for bn: String in ["LeftToes", "RightToes"]:
			var bi := sk.find_bone(bn)
			if bi >= 0:
				low = minf(low, (sk.global_transform * sk.get_bone_global_pose(bi)).origin.y)
	elif w.tier == 3:
		var a: PPL.Avatar = pp.avatars[w.av]
		if a.lod_mesh != null:
			var xf := Transform3D(Basis(Vector3.UP, w.yaw) * pp.scale_of(w), w.pos) * a.lod_xf
			low = (xf * a.lod_mesh.get_aabb()).position.y
	return low


## A contact shadow lies on the ground under every vehicle and person drawn this frame.
func _check_contact_shadows() -> void:
	var cs = f.get("contact")
	var wk: WK = f.get("walkers")
	_look_at_walker(wk, false)
	for _k in range(10):
		f.step(DT)
		f.sync_visuals(DT)
	var cam: Vector3 = f.call("_camera_pos")
	var cars := 0
	for c: VH.Car in _vh().cars:
		if not c.dead and c.lod >= 0 and cam.distance_to(c.pos) < cs.CAR_RANGE:
			cars += 1
	var people := _drawn_people(wk, cam)
	var off := 0
	for k in range(cs.count):
		var o: Vector3 = cs.origin(k)
		var g := ctx.collision.ground_height(o)
		if not is_nan(g) and absf(o.y - g - cs.LIFT) > 0.02 * WS.M:
			off += 1
	var counts := "%d patches for %d vehicles and %d people drawn" % [cs.count, cars, people]
	var ok_n: bool = cars > 0 and people > 0 and cs.count > cars and cs.count <= cars + people
	K.check(fails, ok_n, "contact shadows: " + counts)
	var shown: bool = cs.mmi.visible and cs.mmi.multimesh.visible_instance_count == cs.count
	K.check(fails, off == 0 and shown, "contact shadows: every patch on the surface (%d off)" % off)


## A seated driver in every nearby moving vehicle drawn in full: hips on the Seat_Driver marker,
## facing the way the vehicle points, head under the roof, released once the car is not drawn.
func _check_drivers() -> void:
	var occ = f.get("occupants")
	var pp: PPL = f.get("people")
	if occ == null or pp == null or not pp.ok:
		return
	var pl := ctx.player
	var saved := pl.position
	var seated := {}
	var bad: Array[String] = []
	var missing := 0
	for k in range(12):
		if k % 4 == 0:
			_look_at_car()
		f.step(DT * 5.0)
		f.sync_visuals(DT)
		missing += _unseated(occ)
		for c: VH.Car in _vh().cars:
			var b: PPL.Body = occ.body_of(c.id)
			if b != null:
				seated[c.id] = true
				_driver_sample(bad, c, b)
	pl.teleport(saved, 0.0)
	var off := ", ".join(bad.slice(0, 4))
	var what := "%d vehicles seated, %d unseated, off: %s" % [seated.size(), missing, off]
	var ok := seated.size() >= 1 and missing == 0 and bad.is_empty()
	K.check(fails, ok, "drivers: seated in their cars (%s)" % what)
	var ids: Array = seated.keys()
	occ.clear()
	var left := 0
	for id: int in ids:
		left += 1 if occ.body_of(id) != null else 0
	K.check(fails, occ.seated == 0 and left == 0, "drivers: clear() releases every seated body")


## Moving vehicles drawn in full within occ.RANGE of the camera, with a seat and no driver (all of
## them are within the cap in this city).
func _unseated(occ: Variant) -> int:
	var cam: Vector3 = f.call("_camera_pos")
	var n := 0
	for c: VH.Car in _vh().cars:
		if c.dead or c.parked or c.node == null or cam.distance_to(c.pos) > occ.RANGE:
			continue
		if c.node.find_child("Seat_Driver", true, false) != null and occ.body_of(c.id) == null:
			n += 1
	return n


## Points the camera at the nearest moving vehicle from 5 m to its side.
func _look_at_car() -> void:
	var cam: Vector3 = f.call("_camera_pos")
	var near: VH.Car = null
	for c: VH.Car in _vh().cars:
		if c.dead or c.parked or c.far or c.kind == "bike":
			continue
		if near == null or c.pos.distance_to(cam) < near.pos.distance_to(cam):
			near = c
	if near == null:
		return
	var side := Basis(Vector3.UP, near.yaw) * Vector3(5.0 * WS.M, 0, 0)
	ctx.player.teleport(near.pos + side, 0.0, 0.0, false)
	ctx.player.look_toward(near.pos + Vector3(0, 1.0 * WS.M, 0))


func _driver_sample(bad: Array[String], c: VH.Car, b: PPL.Body) -> void:
	var sk := b.skel
	var hips := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Hips"))).origin
	var head := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Head"))).origin
	var seat_n: Node3D = null
	if c.node != null:
		seat_n = c.node.find_child("Seat_Driver", true, false) as Node3D
	var fwd := Basis(Vector3.UP, c.yaw + c.vis_yaw) * Vector3(0, 0, 1)
	var facing := b.root.global_transform.basis.z.normalized().dot(fwd)
	var roof := c.pos.y + c.height
	var why := ""
	if seat_n == null or not c.node.visible or not b.root.visible:
		why = "not drawn in full"
	elif hips.distance_to(seat_n.global_position) > 0.03 * WS.M:
		why = "hips %.3f m off the seat" % (hips.distance_to(seat_n.global_position) / WS.M)
	elif facing < 0.99:
		why = "facing %.2f" % facing
	elif c.kind != "bike" and head.y > roof:
		why = "head %.2f m over the roof" % ((head.y - roof) / WS.M)
	if not why.is_empty():
		bad.append("%s %s: %s" % [c.kind, c.label, why])


## People drawn this frame within VIS_PERSON of cam (any tier, fading in or not).
func _drawn_people(wk: WK, cam: Vector3) -> int:
	var pp: PPL = f.get("people")
	var hc := pp != null and pp.ok
	var n := 0
	for w: WK.Walker in wk.walkers:
		var drawn := (w.tier >= 0 and w.tier <= 3) if hc else w.lod >= 0
		if not drawn or w.dead or w.state == "hidden" or w.fade <= 0.0:
			continue
		if cam.distance_to(w.pos) < WS.VIS_PERSON:
			n += 1
	return n


static func _ground_sample(s: Array, p: Vector3, g: float, what: String) -> void:
	if is_nan(g):
		return
	s[0] = int(s[0]) + 1
	var gap := p.y - g
	if absf(gap) > 0.02 * WS.M:
		s[1] = int(s[1]) + 1
	if absf(gap) > absf(float(s[2])):
		s[2] = gap
		s[3] = what


func _check_attach() -> void:
	K.check(
		fails,
		ctx.view.life.external == f and ctx.view.avatars.external == f,
		"on_world_rebuilt sets CityLife.external and ResidentAvatars.external"
	)
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
	K.check(
		fails,
		tiles > 0 and bad_arm == 0,
		(
			"every road tile (%d) has a lane in and out of each open arm (%d missing)"
			% [tiles, bad_arm]
		)
	)
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
	K.check(
		fails,
		pairs > 0 and mism == 0,
		"lane endpoints on shared tile edges coincide (%d joins, %d off)" % [pairs, mism]
	)
	_check_offsets(lg)
	# Corner arcs about the shared tile corner.
	var t: LG.TileInfo = lg.info(corner_tile)
	var worst := 0.0
	var arms: Array[Vector2i] = RoadTopology.arms(t.mask)
	var cc := (
		Vector2(D.tx(corner_tile), D.ty(corner_tile)) + (Vector2(arms[0]) + Vector2(arms[1])) * 0.5
	)
	for l: LG.Lane in t.lanes:
		for p: Vector2 in l.pts:
			var r := p.distance_to(cc)
			worst = maxf(worst, minf(absf(r - WS.CORNER_LANE_R_IN), absf(r - WS.CORNER_LANE_R_OUT)))
	K.check(
		fails,
		t.lanes.size() == 2 and worst <= 0.005,
		(
			"corner lanes at (%d,%d) stay within 0.005 of radius 0.35 or 0.65 (worst %.4f)"
			% [D.tx(corner_tile), D.ty(corner_tile), worst]
		)
	)
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
	(
		K
		. check(
			fails,
			uturns > 0 and off == 0,
			(
				"every lane polyline stays on the carriageway, U-turns included (%d samples, %d off, %d U-turns)"
				% [samples, off, uturns]
			)
		)
	)
	_check_rebuild(lg)


## A mask-5 tile: the lane heading -Z sits at x + LANE_OFFSET, and at PASS_OFFSET beside a parked car.
func _check_offsets(lg: LG) -> void:
	var tile := -1
	for i: int in lg.tiles.keys():
		var t: LG.TileInfo = lg.tiles[i]
		if (
			t.mask == RoadTopology.NS
			and lg.parkable(i)
			and (lg.slot_valid(i, 0) or lg.slot_valid(i, 1))
		):
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
	K.check(
		fails,
		l != null and absf(mid.x - (float(D.tx(tile)) + WS.LANE_OFFSET)) < 1e-4,
		"mask-5 lane heading -Z at x + LANE_OFFSET (%.4f)" % (mid.x - float(D.tx(tile)))
	)
	var k0 := 0 if lg.slot_valid(tile, 0) else 1
	lg.set_slot(tile, k0, "test")
	mid = lg.pos_at(l, l.length * 0.5)
	K.check(
		fails,
		absf(mid.x - (float(D.tx(tile)) + WS.PASS_OFFSET)) < 1e-4,
		"with a car parked on that run it moves to PASS_OFFSET (%.4f)" % (mid.x - float(D.tx(tile)))
	)
	lg.set_slot(tile, k0, "")
	mid = lg.pos_at(l, l.length * 0.5)
	K.check(
		fails,
		absf(mid.x - (float(D.tx(tile)) + WS.LANE_OFFSET)) < 1e-4,
		"and back to LANE_OFFSET when the slot frees"
	)
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
	K.check(
		fails,
		lg.tiles.has(end_tile) and lg.builds == builds0,
		"sim.tiles_changed alone does not touch the lane graph"
	)
	view.tile_cleared.emit(end_tile)
	var nt: LG.TileInfo = lg.info(nb)
	K.check(
		fails,
		not lg.tiles.has(end_tile) and nt != null and not (nt.mask & (1 << LG.OPP[arm])),
		"view.tile_cleared rebuilds the tile and its neighbours"
	)
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
	K.check(
		fails,
		keys == ["aircraft", "boats", "buses", "crews", "trucks"],
		"vehicle_counts() keeps exactly the 5 legacy keys (%s)" % str(keys)
	)
	var ac: Dictionary = ctx.view.avatars.visible_count()
	var ak := ac.keys()
	ak.sort()
	K.check(
		fails,
		ak == ["driving", "standing", "total", "walking"],
		"visible_count() keeps its 4 keys (%s)" % str(ak)
	)
	K.check(
		fails,
		typeof(ctx.view.avatars.pick(Vector2(400, 300))) == TYPE_STRING,
		"avatars.pick(Vector2) returns a String"
	)
	K.check(
		fails,
		typeof(ctx.view.avatars.position_of(fixture_rid)) == TYPE_VECTOR3,
		"avatars.position_of(id) returns a Vector3"
	)
	# Orbit: a CityView without FpMode keeps the legacy avatars exactly.
	var v2 := K.make_view(get_root(), sim)
	var av: ResidentAvatars = v2.avatars
	var r := ctx.residents.find(fixture_rid)
	var saved_route: Variant = r.get("route", [])
	var home := int(r["home"])
	r["route"] = [
		Vector2i(D.tx(home), D.ty(home)),
		Vector2i(D.tx(home) + 1, D.ty(home)),
		Vector2i(D.tx(home) + 2, D.ty(home))
	]
	av.call("_on_moved", r)
	var a: Dictionary = av.get("_avatars")[fixture_rid]
	var tick_len := sim.tick_seconds() / float(maxi(sim.speed, 1))
	var want := 2.0 / clampf(tick_len * 0.85, 0.6, 2.8)
	K.check(
		fails,
		is_equal_approx(float(a["speed"]), want),
		(
			"orbit _on_moved still sets speed from sim.tick_seconds() (%.3f vs %.3f)"
			% [float(a["speed"]), want]
		)
	)
	av.call("_advance", a, r, 0.05)
	var y := (a["root"] as Node3D).position.y
	var sc := (a["person"] as Node3D).scale.x
	K.check(
		fails,
		y >= 0.05 and y <= 0.06 and is_equal_approx(sc, 1.5),
		"orbit avatars keep y = 0.05 and scale 1.5 (y %.4f, scale %.2f)" % [y, sc]
	)
	K.check(fails, av.external == null, "orbit avatars have no external")
	r["route"] = saved_route
	v2.free()


# ------------------------------------------------------------------ agents_near, people, crowds, spawns


## agents_near entries carry every key, headings follow S0 §11 (forward = (-sin h, 0, -cos h)),
## and agents_packed lists the same agents.
func _check_agents_api() -> void:
	f.set("ambient_enabled", true)
	f.call("_maintain", true)
	_step(1.0)
	var p := ctx.player_position()
	var list: Array = f.agents_near(p, 40.0)
	var keys := ["id", "pos", "vel", "speed", "kind", "driver_id", "heading", "stalled_s"]
	var bad_keys := 0
	var moving := 0
	var bad_head := 0
	for a: Dictionary in list:
		for k: String in keys:
			if not a.has(k):
				bad_keys += 1
		var v: Vector3 = a["vel"]
		if v.length() > 0.5 * WS.M:
			moving += 1
			var h := float(a["heading"])
			if Vector3(-sin(h), 0, -cos(h)).dot(v.normalized()) < 0.97:
				bad_head += 1
	K.check(
		fails,
		not list.is_empty() and bad_keys == 0,
		"agents_near: %d agents, every entry has the 8 keys (%d missing)" % [list.size(), bad_keys]
	)
	K.check(
		fails,
		moving > 0 and bad_head == 0,
		(
			"agents_near: heading is S0's convention for all %d moving agents (%d off)"
			% [moving, bad_head]
		)
	)
	var packed: Dictionary = f.agents_packed(p, 40.0)
	K.check(
		fails,
		(
			(packed["pos"] as PackedVector3Array).size() == list.size()
			and (packed["kind"] as PackedStringArray).size() == list.size()
		),
		"agents_packed lists the same %d agents" % list.size()
	)


## People draw as the merged body through the people shader (never a full GLB), with stride data.
## With HC's bodies (stage E2) they draw as skinned bodies near and lod1 MultiMeshes far instead.
func _check_people_draw() -> void:
	var wk: WK = f.get("walkers")
	var rd = f.get("render")
	for _k in range(20):
		f.step(DT)
		f.sync_visuals(DT)
	var pp: PPL = f.get("people")
	if pp != null and pp.ok:
		# Look at the nearest walker, then every walker in view and range is drawn.
		var cam0: Vector3 = f.call("_camera_pos")
		var near: WK.Walker = null
		for w: WK.Walker in wk.walkers:
			if near == null or w.pos.distance_to(cam0) < near.pos.distance_to(cam0):
				near = w
		if near != null:
			ctx.player.look_toward(near.pos + Vector3(0, 1.0 * WS.M, 0))
		for _k in range(10):
			f.step(DT)
			f.sync_visuals(DT)
		var legacy := 0
		for m: Variant in rd.models:
			if m.person:
				legacy += 1
		var in_view := 0
		var drawn := 0
		var cam1: Vector3 = f.call("_camera_pos")
		for w: WK.Walker in wk.walkers:
			if (
				w.dead
				or w.far
				or w.state == "hidden"
				or w.pos.distance_to(cam1) > WS.VIS_PERSON * 0.98
				or not pp.on_screen(w.pos + w.vis_off)
			):
				continue
			in_view += 1
			if w.tier >= 0 and w.tier <= 3:
				drawn += 1
		(
			K
			. check(
				fails,
				legacy == 0 and in_view > 0 and drawn == in_view,
				(
					"people: HC bodies draw all %d people in view and range (%d), no legacy people models (%d)"
					% [in_view, drawn, legacy]
				)
			)
		)
		return
	var nodes := 0
	var striding := 0
	var cam: Vector3 = f.call("_camera_pos")
	for w: WK.Walker in wk.walkers:
		if w.node != null:
			nodes += 1
		if (
			w.v > 0.5 * WS.M
			and w.gait > 0.5
			and w.lod > 0
			and cam.distance_to(w.pos) < WS.VIS_PERSON
		):
			striding += 1
	var people_mm := 0
	for m: Variant in rd.models:
		if m.person:
			for k in range(2):
				var mmi: MultiMeshInstance3D = m.mms[k]
				if (
					mmi != null
					and mmi.visible
					and mmi.multimesh.use_custom_data
					and mmi.material_override is ShaderMaterial
				):
					people_mm += 1
	K.check(
		fails,
		nodes == 0 and rd.full_people == 0,
		"people: no full GLB nodes for people (%d)" % nodes
	)
	K.check(
		fails,
		people_mm > 0 and striding > 0,
		(
			"people: drawn by %d shader MultiMeshes with stride data, %d walking in stride"
			% [people_mm, striding]
		)
	)


## People waiting at a zebra take distinct places along the curb, clear of the light poles.
## A body back in the pool is folded (render.gd's _fold_rig), and only a backhoe's node ever
## carries a rig, so folding a plain pooled body must be silent. The missing-meta read it once
## made is an engine-level error a SceneTree test cannot see, so the fold runs in a child Godot
## (fp_fold_check.gd) and its captured output is grepped.
func _check_fold_rig_silent() -> void:
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
				"res://tools/tests/fp_fold_check.gd",
			],
			out,
			true
		)
	)
	var log := "\n".join(PackedStringArray(out))
	K.check(
		fails,
		code == 0 and "FP_FOLD_CHECK: DONE" in log,
		"fold-rig: the child fold ran (exit %d)" % code
	)
	K.check(
		fails,
		not "does not have any 'meta' values" in log and not "SCRIPT ERROR" in log,
		"fold-rig: folding a plain pooled body prints no missing-meta engine error"
	)


func _check_wait_crowd() -> void:
	var sw: SW = f.get("peds")
	var wk: WK = f.get("walkers")
	var z: SW.PedEdge = null
	for e: Variant in sw.edges:
		if e != null and (e as SW.PedEdge).zebra:
			var t: LG.TileInfo = _lg().info((e as SW.PedEdge).tile)
			if z == null or (t != null and t.lights):
				z = e
			if t != null and t.lights:
				break
	K.check(fails, z != null, "fixture: a zebra")
	if z == null:
		return
	var at := sw.pos_at(z, 0.0)
	var crowd: Array = []
	for k in range(6):
		var w := wk.make("ambient")
		w.pos = at
		w.plan = [{"edge": z.id, "dir": 1}]
		wk.call("_begin_wait", w)
		crowd.append(w)
	for _k in range(90):
		for w: WK.Walker in crowd:
			wk.ease_visuals(w, DT)
	var slots := {}
	var min_d := INF
	for i in range(crowd.size()):
		slots[(crowd[i] as WK.Walker).wait_slot] = true
		for j in range(i + 1, crowd.size()):
			var a: WK.Walker = crowd[i]
			var b: WK.Walker = crowd[j]
			min_d = minf(min_d, (a.pos + a.vis_off).distance_to(b.pos + b.vis_off))
	K.check(
		fails,
		slots.size() == crowd.size() and min_d >= 0.45 * WS.M,
		(
			"wait crowd: %d people at one zebra stand apart (closest %.2f m)"
			% [crowd.size(), min_d / WS.M]
		)
	)
	var zt: LG.TileInfo = _lg().info(z.tile)
	if zt != null and zt.lights:
		# Light poles stand at (+-0.42, +-0.42) with a 0.24 m footing; a body is about 0.25 m deep.
		var pole_d := INF
		for w: WK.Walker in crowd:
			var q := w.pos + w.vis_off
			for cn: Vector2 in [Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1)]:
				var pp := Vector2(D.tx(z.tile), D.ty(z.tile)) + cn * 0.42
				pole_d = minf(pole_d, Vector2(q.x, q.z).distance_to(pp))
		K.check(
			fails,
			pole_d >= 0.5 * WS.M,
			(
				"wait crowd: everyone stands clear of the light poles (closest %.2f m)"
				% [pole_d / WS.M]
			)
		)
	for w: WK.Walker in crowd:
		wk.remove(w)


## Outside a sync fill, cars never appear in view, and people appear in view only fading in from
## PED_FADE_SPAWN; both keep out of the player's personal space.
func _check_ambient_spawns() -> void:
	_quiet()
	f.set("ambient_enabled", true)
	var vh := _vh()
	var wk: WK = f.get("walkers")
	var amb = f.get("ambient")
	var p := ctx.player_position()
	var seen_c := {}
	var seen_w := {}
	for c: VH.Car in vh.cars:
		seen_c[c.id] = true
	var cars_bad := 0
	var cars_new := 0
	var peds_bad := 0
	var peds_new := 0
	var faded := 0
	for _k in range(60):
		f.call("_maintain", false)
		for c: VH.Car in vh.cars:
			if seen_c.has(c.id):
				continue
			seen_c[c.id] = true
			cars_new += 1
			if (
				f.on_screen(c.pos)
				or Vector2(c.pos.x - p.x, c.pos.z - p.z).length() < amb.MIN_SPAWN - 0.5
			):
				cars_bad += 1
		for w: WK.Walker in wk.walkers:
			if seen_w.has(w.id):
				continue
			seen_w[w.id] = true
			peds_new += 1
			var d := Vector2(w.pos.x - p.x, w.pos.z - p.z).length()
			if f.on_screen(w.pos + Vector3(0, 0.05, 0)):
				if w.fade >= 1.0 or d < amb.PED_FADE_SPAWN - 0.05:
					peds_bad += 1
				else:
					faded += 1
			elif d < amb.PERSONAL:
				peds_bad += 1
		for _j in range(3):
			f.step(DT)
	K.check(
		fails,
		cars_new > 0 and cars_bad == 0,
		(
			"ambient: %d new cars, none appears in view or within MIN_SPAWN (%d bad)"
			% [cars_new, cars_bad]
		)
	)
	K.check(
		fails,
		peds_new > 0 and peds_bad == 0,
		(
			"ambient: %d new people appear out of view or fading in from 60 m (%d fading, %d bad)"
			% [peds_new, faded, peds_bad]
		)
	)


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
			if (
				back >= 0
				and lg.info(back) != null
				and (lg.info(back) as LG.TileInfo).piece == "straight"
				and (lg.info(back) as LG.TileInfo).mask == t.mask
			):
				continue
			var run: Array[int] = [i]
			var cur := i
			while true:
				var nx := lg.across(cur, e)
				if (
					nx < 0
					or lg.info(nx) == null
					or (lg.info(nx) as LG.TileInfo).piece != "straight"
					or (lg.info(nx) as LG.TileInfo).mask != t.mask
				):
					break
				run.append(nx)
				cur = nx
			if run.size() > best.size():
				best = run
				best_e = e
	return [best, best_e]


## The web density caps (quality.gd, through ambient's caps_override hook): a present
## "traffic"/"crowd" key clamps that spawn target and the fill it drives; a missing key or an
## empty Dictionary caps nothing.
func _check_density_caps() -> void:
	_quiet()
	f.set("ambient_enabled", true)
	var vh := _vh()
	var wk: WK = f.get("walkers")
	var amb = f.get("ambient")
	var p := ctx.player_position()
	var t0: Vector2i = amb.targets(p)
	K.check(
		fails, t0.x > 3 and t0.y > 3, "fixture: uncapped targets above the test caps (%s)" % str(t0)
	)
	if t0.x <= 3 or t0.y <= 3:
		return
	amb.set("caps_override", {})
	K.check(
		fails,
		amb.targets(p) == t0,
		"density caps: an empty Dictionary changes nothing (%s)" % str(amb.targets(p))
	)
	amb.set("caps_override", {"traffic": t0.x - 2})
	var t1: Vector2i = amb.targets(p)
	K.check(
		fails,
		t1 == Vector2i(t0.x - 2, t0.y),
		(
			"density caps: only a present key clamps (traffic %d: %s -> %s)"
			% [t0.x - 2, str(t0), str(t1)]
		)
	)
	amb.set("caps_override", {"traffic": 999, "crowd": 999})
	K.check(
		fails, amb.targets(p) == t0, "density caps: caps above the internal targets change nothing"
	)
	# The fill respects the clamp: with both caps 0 a synchronous fill spawns nothing.
	var seen := {}
	for c: VH.Car in vh.cars:
		seen[c.id] = true
	for w: WK.Walker in wk.walkers:
		seen[w.id] = true
	amb.set("caps_override", {"traffic": 0, "crowd": 0})
	var want0: Vector2i = amb.targets(p)
	f.call("_maintain", true)
	var spawned := 0
	for c: VH.Car in vh.cars:
		if c.role == "ambient" and not seen.has(c.id):
			spawned += 1
	for w: WK.Walker in wk.walkers:
		if w.role == "ambient" and not seen.has(w.id):
			spawned += 1
	amb.set("caps_override", null)
	K.check(
		fails,
		spawned == 0 and want0 == Vector2i.ZERO,
		"density caps: a zero cap spawns nothing on a synchronous fill (%d spawned)" % spawned
	)


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
	K.check(
		fails, min_gap > 0.0, "following: no overlap over 30 s (min gap %.2f m)" % (min_gap / WS.M)
	)
	(
		K
		. check(
			fails,
			final_gap >= IDM.S0 * 0.9 and follower.v < 0.05 * WS.M and leader.v < 0.01,
			(
				"following: the follower stops >= s0 * 0.9 behind the stopped leader (%.2f m, v %.2f m/s)"
				% [final_gap / WS.M, follower.v / WS.M]
			)
		)
	)
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
						worst = (
							"car %d (%s) at %s vs parked %d at %s"
							% [c.id, c.role, str(c.pos), p.id, str(p.pos)]
						)
	K.check(
		fails,
		passes > 0,
		"parking clearance: moving cars pass parked ones (%d close passes)" % passes
	)
	K.check(
		fails,
		overlaps == 0,
		(
			"parking clearance: no moving AABB overlaps a parked AABB in 60 s (%d) %s"
			% [overlaps, worst]
		)
	)


# ------------------------------------------------------------------ shoves


## The player's car knocks a parked car toward the road (bump_car): it slides off its slot for
## good, braking on its tyres, and blocks lane traffic until, having stood out of sight for
## TOW_AFTER s, it is towed back to its slot.
func _check_parked_shove() -> void:
	_quiet()
	var c: VH.Car = null
	for p: VH.Car in _vh().cars:
		if p.parked and not p.dead and not p.far and p.slot_tile >= 0:
			c = p
			break
	K.check(fails, c != null, "fixture: a parked car")
	if c == null:
		return
	var sh: SHOVES = f.get("shoves")
	var home := c.pos
	var yaw0 := c.yaw
	var q := Vector2(c.pos.x, c.pos.z)
	var side := OBB.side_axis(c.yaw)
	if (Vector2(roundf(q.x), roundf(q.y)) - q).dot(side) < 0.0:
		side = -side
	f.call("bump_car", c.id, side * (4.0 * WS.M * SHOVES.mass_of(c)), q)
	var shoved := sh.is_shoved(c)
	_step(3.0)
	var moved := Vector2(c.pos.x - home.x, c.pos.z - home.z).length()
	K.check(
		fails,
		shoved and not sh.is_shoved(c) and moved > 0.5 * WS.M and moved < 3.0 * WS.M,
		"shoves: a parked car hit at 4 m/s slides %.1f m off its slot and stops" % (moved / WS.M)
	)
	var blocks := sh.blocks().filter(func(b: Array) -> bool: return int(b[5]) == c.id)
	K.check(fails, not blocks.is_empty(), "shoves: out of its slot it blocks lane traffic")
	sh.visible = func(_p: Vector3) -> bool: return false
	_step(SHOVES.TOW_AFTER + 1.0)
	K.check(
		fails,
		(
			c.pos.distance_to(home) < 0.01 * WS.M
			and is_equal_approx(c.yaw, yaw0)
			and sh.blocks().is_empty()
		),
		"shoves: having stood out of sight %.0f s it is towed back to its slot" % SHOVES.TOW_AFTER
	)
	sh.visible = Callable(f, "on_screen")


# ------------------------------------------------------------------ lights


## The asset poles' pedestrian heads (Walk_*, DontWalk_*) are bound to the zebra they look
## across and follow its walk phase: at c0 E-W has just turned green, so the zebras across the
## N/S arms (ped axis 1) show walk and those across E/W (axis 0) don't walk.
func _check_walk_heads(jn: JN, x: int, c0: float) -> void:
	if AP.load_scene(AP.TRAFFIC_LIGHT) == null:
		print("  skip walk heads: no traffic light asset")
		return
	var peds: Array = jn.props[x]["peds"]
	var mats: Array = jn.get("_walk_mats")
	jn.clock = c0
	jn.update_lamps(Vector3(D.tx(x), 0, D.ty(x)), 1.0)
	var bad: Array[String] = []
	var heads := 0
	for corner in range(4):
		var pole := jn.light_pole(x, corner)
		var c := Vector2(pole.position.x, pole.position.z)
		var face := -pole.global_transform.basis.x.normalized()
		for n: Node in pole.find_children("*Walk_*", "GeometryInstance3D", true, false):
			heads += 1
			var k := -1
			for g in range(4):
				if (peds[g] as Array).has(n):
					k = g
			var axis := k / 2
			var walk := k % 2 == 1
			# The pole sits in the band of the zebra it serves and looks along it.
			var across := absf(c.y) if axis == 1 else absf(c.x)
			var along := absf(face.x) if axis == 1 else absf(face.z)
			var in_band := across >= WS.ZEBRA_NEAR and across <= WS.ZEBRA_FAR
			var lit := axis == 1
			var want: Material = mats[3 if lit else 2] if walk else mats[0 if lit else 1]
			var shown := (n as GeometryInstance3D).material_override
			if k < 0 or not in_band or along < 0.9 or shown != want:
				bad.append("%d:%s k%d band%.3f along%.2f" % [corner, n.name, k, across, along])
	var msg := "walk heads: %d asset heads face their zebra and follow its phase %s"
	K.check(fails, heads >= 8 and bad.is_empty(), msg % [heads, str(bad)])


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
	(
		K
		. check(
			fails,
			(
				stopped_at >= LG.STOP_FRONT - 0.0005
				and stopped_at <= LG.STOP_FRONT + 0.03
				and stop_red
			),
			(
				"light: a car arriving on red stops with its front %.3f from the centre (window %.3f..%.3f)"
				% [stopped_at, LG.STOP_FRONT, LG.STOP_FRONT + 0.03]
			)
		)
	)
	var entered_on := -1
	for _k in range(int(25.0 / DT)):
		var was_on_a := car.lane == a
		f.step(DT)
		if was_on_a and car.lane == mv:
			entered_on = jn.light(x, 2)
			break
	K.check(
		fails,
		entered_on == JN.GREEN or entered_on == JN.AMBER,
		"light: it proceeds on green (entered the box on %d)" % entered_on
	)
	_vh().remove(car)
	# Lamps: per-instance overrides from shared on/off materials; the shared ones never change.
	var pr: Dictionary = jn.props.get(x, {})
	var groups: Array = pr.get("groups", [])
	var on_red: StandardMaterial3D = jn.get("_on_mats")[0]
	var energy := on_red.emission_energy_multiplier
	var col := on_red.albedo_color
	jn.clock = c0
	jn.update_lamps(Vector3(D.tx(x), 0, D.ty(x)), 1.0)
	var ns_red: GeometryInstance3D = (
		(groups[0] as Array)[0]
		if groups.size() == 6 and not (groups[0] as Array).is_empty()
		else null
	)
	var ns_green: GeometryInstance3D = (
		(groups[2] as Array)[0]
		if groups.size() == 6 and not (groups[2] as Array).is_empty()
		else null
	)
	K.check(
		fails,
		(
			ns_red != null
			and ns_red.material_override == on_red
			and ns_green.material_override == jn.get("_off_mats")[2]
		),
		"lamps: N-S red lit, green dark (material_override)"
	)
	jn.clock = fposmod(-jn.offset(x) + 1.0, JN.CYCLE)
	jn.update_lamps(Vector3(D.tx(x), 0, D.ty(x)), 1.0)
	K.check(
		fails,
		(
			ns_red != null
			and ns_red.material_override == jn.get("_off_mats")[0]
			and ns_green.material_override == jn.get("_on_mats")[2]
		),
		"lamps: N-S green lit after the change"
	)
	K.check(
		fails,
		is_equal_approx(on_red.emission_energy_multiplier, energy) and on_red.albedo_color == col,
		"lamps: the shared materials are never edited"
	)
	K.check(
		fails,
		(
			f.light_pole(x, 0) != null
			and f.light_pole(x, 0).find_child("SignText_A", true, false) != null
		),
		"light_pole(i, 0) is the NE pole with SignText_A / SignText_B mounts"
	)
	_check_walk_heads(jn, x, c0)
	# The poles and pedestrian signals stand beside the zebras, never in the walking line: every
	# zebra point keeps 0.3 m clear even at the widest lateral offset a crosser takes (half the band).
	var sw: SW = f.get("peds")
	var zd := INF
	var zn := 0
	for arm in range(4):
		var z: SW.PedEdge = sw.zebra_at(x, arm)
		if z == null:
			continue
		zn += 1
		for q: Vector2 in z.pts:
			zd = minf(zd, _furniture_dist(q - Vector2(D.tx(x), D.ty(x))))
	var reach := (WK.BAND + 0.012) * 0.5
	(
		K
		. check(
			fails,
			zn == 4 and zd - reach >= 0.3 * WS.M,
			(
				"furniture: light poles and pedestrian signals stand clear of the 4 zebras (closest %.2f m from a crosser)"
				% [(zd - reach) / WS.M]
			)
		)
	)
	f.set("clock", 0.0)
	jn.clock = 0.0


## After dark a moving car near the camera lights its head and tail lamps (per-instance surface
## overrides; the imported materials are untouched) and throws a headlight beam down the road
## ahead of it. By day the imported lamps are back and the beams are off.
func _check_night_lamps() -> void:
	_quiet()
	var run: Array = _straight_run()
	var tiles: Array[int] = run[0]
	var e: int = run[1]
	if tiles.size() < 3:
		K.check(fails, false, "fixture: a straight run for the night lamps")
		return
	var lanes := _lg().lanes_along(tiles, LG.OPP[e], e)
	var car := _car(lanes[1], 0.5, lanes.slice(2), WS.CAR_CITY)
	var dir := Vector3(LG.DIRS[e].x, 0, LG.DIRS[e].y)
	var right := Vector3(-dir.z, 0, dir.x)
	var saved := ctx.player.position
	ctx.player.teleport(car.pos + dir * 0.6 + right * 0.23, 0.0)
	var rd = f.get("render")
	rd.set_glow(1.0)
	f.sync_visuals(DT)
	var lit := false
	var node: Node3D = car.node
	var head_mat: Material = null
	if node != null and node.has_meta("head") and node.has_meta("tail"):
		var head: Array = node.get_meta("head")
		var tail: Array = node.get_meta("tail")
		var hm: MeshInstance3D = head[0]
		var tm: MeshInstance3D = tail[0]
		head_mat = hm.mesh.surface_get_material(int(head[1]))
		lit = (
			hm.get_surface_override_material(int(head[1])) == rd.get("_head_mat")
			and tm.get_surface_override_material(int(tail[1])) != null
			and head_mat != rd.get("_head_mat")
		)
	(
		K
		. check(
			fails,
			car.lod == 0 and lit,
			(
				"night: a near car lights its head and tail lamps through per-instance overrides (lod %d)"
				% car.lod
			)
		)
	)
	var beams: Array = rd.get("_beams")
	var beam_ok := false
	var fwd: Vector3 = (_vh().draw_xform(car) as Transform3D).basis.z.normalized()
	for b: SpotLight3D in beams:
		if (
			b.visible
			and b.position.distance_to(car.pos + car.vis_off + fwd * (car.length * 0.5)) < 0.06
			and (-b.transform.basis.z).dot(fwd) > 0.95
		):
			beam_ok = true
	K.check(
		fails,
		int(rd.get("beams_on")) >= 1 and beam_ok,
		(
			"night: its headlight beam starts at its front and points down the road (%d beams)"
			% int(rd.get("beams_on"))
		)
	)
	rd.set_glow(0.0)
	f.sync_visuals(DT)
	var day_ok := node != null and car.node == node
	if day_ok and node.has_meta("head"):
		var head: Array = node.get_meta("head")
		day_ok = (head[0] as MeshInstance3D).get_surface_override_material(int(head[1])) == null
	K.check(
		fails,
		day_ok and int(rd.get("beams_on")) == 0,
		"night: by day the imported lamps are back and no beam is on"
	)
	_check_wet_paint(node)
	_vh().remove(car)
	ctx.player.teleport(saved, 0.0)


## A bicycle's own lamps after dark: the far LOD's merged mesh carries lamp-flagged vertices
## (vertex alpha under 0.75, from the lod1's emissive Light_Head / Light_Tail lens materials), so
## a cyclist glows at distance like any car, and the full model's small lenses light through the
## same per-instance overrides as a car's (no headlight beam: a bicycle never takes one). By day
## the imported lamps are back.
func _check_bike_lamps() -> void:
	_quiet()
	var m: int = f.call("bike_model")
	K.check(fails, m >= 0, "bike lamps: the bicycle model is loaded")
	if m < 0:
		return
	var rd = f.get("render")
	var lod_mesh: Mesh = null
	for mod in rd.get("models"):
		if str(mod.get("key")).begins_with(AP.BICYCLE):
			lod_mesh = mod.get("lod_mesh")
			break
	var flagged := 0
	if lod_mesh != null and lod_mesh.get_surface_count() > 0:
		var arrays: Array = lod_mesh.surface_get_arrays(0)
		var raw: Variant = arrays[Mesh.ARRAY_COLOR]
		for col: Color in raw if raw is PackedColorArray else PackedColorArray():
			if col.a < 0.75:
				flagged += 1
	K.check(
		fails,
		flagged >= 16,
		"bike lamps: the far LOD's lamp vertices are flagged to glow (%d)" % flagged
	)
	var run: Array = _straight_run()
	var tiles: Array[int] = run[0]
	var e: int = run[1]
	if tiles.size() < 3:
		K.check(fails, false, "fixture: a straight run for the bike lamps")
		return
	var lanes := _lg().lanes_along(tiles, LG.OPP[e], e)
	var bike := _vh().make("bike", "test", f.call("dims", m))
	bike.model = m
	_vh().place(bike, lanes[1], 0.5)
	bike.v = 0.0
	var dir := Vector3(LG.DIRS[e].x, 0, LG.DIRS[e].y)
	var right := Vector3(-dir.z, 0, dir.x)
	var saved := ctx.player.position
	ctx.player.teleport(bike.pos + dir * 0.6 + right * 0.23, 0.0)
	rd.set_glow(1.0)
	f.sync_visuals(DT)
	var node: Node3D = bike.node
	var lit := false
	if node != null and node.has_meta("head") and node.has_meta("tail"):
		var head: Array = node.get_meta("head")
		var tail: Array = node.get_meta("tail")
		lit = (
			bike.lod == 0
			and (head[0] as MeshInstance3D).get_surface_override_material(int(head[1])) != null
			and (tail[0] as MeshInstance3D).get_surface_override_material(int(tail[1])) != null
		)
	K.check(
		fails,
		lit and int(rd.get("beams_on")) == 0,
		"bike lamps: a near bicycle lights its own small lamps after dark, no beam"
	)
	rd.set_glow(0.0)
	f.sync_visuals(DT)
	var day_ok := node != null and bike.node == node
	if day_ok and node.has_meta("head"):
		var head: Array = node.get_meta("head")
		day_ok = (head[0] as MeshInstance3D).get_surface_override_material(int(head[1])) == null
	K.check(fails, day_ok, "bike lamps: by day the imported lamps are back")
	_vh().remove(bike)
	ctx.player.teleport(saved, 0.0)


## A full car's paint wears a clear coat; with the streets soaked it darkens and turns glossier (and
## the merged bodies with it), and dried it is back to its own values.
func _check_wet_paint(node: Node3D) -> void:
	var rd = f.get("render")
	var paint: StandardMaterial3D = null
	for mi in node.find_children("*", "MeshInstance3D", true, false) if node != null else []:
		var mesh := (mi as MeshInstance3D).mesh
		for s in range(mesh.get_surface_count() if mesh != null else 0):
			var m := mesh.surface_get_material(s)
			if m is StandardMaterial3D and m.resource_name.begins_with("Paint_"):
				paint = m
	if paint == null:
		K.check(fails, false, "paint: the near car has a Paint_ surface")
		return
	var dry := [paint.roughness, paint.albedo_color, paint.clearcoat_roughness]
	ctx.view.set_wetness(1.0)
	f.sync_visuals(DT)
	var lod: ShaderMaterial = rd.get("_lod_mat")
	var wet_ok := paint.roughness < float(dry[0]) and paint.albedo_color.v < (dry[1] as Color).v
	wet_ok = wet_ok and is_equal_approx(paint.clearcoat_roughness, RD.PAINT_COAT_WET)
	wet_ok = wet_ok and is_equal_approx(float(lod.get_shader_parameter("wet")), 1.0)
	ctx.view.set_wetness(0.0)
	f.sync_visuals(DT)
	var dry_ok := is_equal_approx(paint.roughness, float(dry[0]))
	dry_ok = dry_ok and paint.albedo_color.is_equal_approx(dry[1])
	dry_ok = dry_ok and is_equal_approx(paint.clearcoat_roughness, RD.PAINT_COAT)
	dry_ok = dry_ok and float(lod.get_shader_parameter("wet")) == 0.0
	K.check(
		fails,
		paint.clearcoat_enabled and wet_ok and dry_ok,
		"paint: clear coat, darker and glossier in the wet, dry again after (%.2f)" % float(dry[0])
	)


## Turn signals (indicators.gd): a car waiting to turn left at a cross signals left and its full
## model blinks the Light_Indicator_L surface (which sits on its left) and only that one; going
## straight on it signals nothing, on the turn itself still left, pulling in to the curb right and
## stunned after a knock its hazards.
func _check_indicators() -> void:
	_quiet()
	var lg := _lg()
	var t: LG.TileInfo = null
	for i: int in lg.tiles.keys():
		var ti: LG.TileInfo = lg.tiles[i]
		if ti.lights and ti.approach[2] != null:
			t = ti
			break
	var left: LG.Lane = null
	var ahead: LG.Lane = null
	for mv: LG.Lane in t.moves[2] if t != null else []:
		if mv.turn == IND.LEFT:
			left = mv
		elif mv.turn == 0:
			ahead = mv
	if left == null or ahead == null:
		K.check(fails, false, "fixture: a cross with a left and a straight move from the south")
		return
	var a: LG.Lane = t.approach[2]
	var car := _car(a, a.length * 0.5, [left], 0.0)
	var sides := [IND.side(car)]
	car.path = [ahead]
	sides.append(IND.side(car))
	car.path = [left]
	car.park_t = 0.5
	sides.append(IND.side(car))
	car.park_t = -1.0
	car.stun_t = 1.0
	sides.append(IND.side(car))
	car.stun_t = 0.0
	var want := [IND.LEFT, IND.NONE, IND.RIGHT, IND.HAZARD]
	var msg := "indicators: left turn, straight on, pulling in, stunned signal %s" % [sides]
	K.check(fails, sides == want, msg)
	var blinks := _blink_states(car)
	var blink_ok := blinks == [true, false, false, false]
	msg = "indicators: the left lamps blink on and off, the right stay dark %s" % [blinks]
	K.check(fails, blink_ok, msg)
	var side := _indicator_side(car, "Light_Indicator_L")
	msg = "indicators: Light_Indicator_L sits on the car's left (%.3f u right)" % side
	K.check(fails, side < 0.0, msg)
	var on_turn := _car(left, left.length * 0.3, [], 0.0)
	msg = "indicators: still signalling left on the turn itself"
	K.check(fails, IND.side(on_turn) == IND.LEFT, msg)
	_vh().remove(on_turn)
	_vh().remove(car)


## Whether the [left, right] lamps are lit in a lit blink phase, then in a dark one.
func _blink_states(car: VH.Car) -> Array:
	var rd = f.get("render")
	var saved := ctx.player.position
	ctx.player.teleport(car.pos + Vector3(0.3, 0.0, 0.3), 0.0)
	var out := []
	for phase: float in [0.1, 0.75]:
		rd.set("time", phase / IND.RATE - DT)
		f.sync_visuals(DT)
		var node: Node3D = car.node
		if node == null or car.lod != 0 or not node.has_meta("ind_l") or not node.has_meta("ind_r"):
			out.append_array([null, null])
			continue
		for key: String in ["ind_l", "ind_r"]:
			var surf: Array = node.get_meta(key)
			var m := (surf[0] as MeshInstance3D).get_surface_override_material(int(surf[1]))
			out.append(m == rd.get("_ind_mat"))
	ctx.player.teleport(saved, 0.0)
	return out


## How far (u) to the car's right the centre of the surface with material mat_name lies.
func _indicator_side(car: VH.Car, mat_name: String) -> float:
	var node: Node3D = car.node
	if node == null:
		return INF
	var xf: Transform3D = _vh().draw_xform(car)
	var fwd := xf.basis.z.normalized()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var mesh := (mi as MeshInstance3D).mesh
		for s in range(mesh.get_surface_count() if mesh != null else 0):
			var m := mesh.surface_get_material(s)
			if m == null or m.resource_name != mat_name:
				continue
			var verts: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
			var sum := Vector3.ZERO
			for v in verts:
				sum += v
			var mean := sum / maxf(verts.size(), 1)
			var ctr: Vector3 = (mi as MeshInstance3D).global_transform * mean
			return (ctr - xf.origin).dot(right)
	return INF


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
			if (
				not pv.is_empty()
				and (pv[0] as LG.Lane).kind == LG.STRAIGHT
				and not stem_prev.is_empty()
			):
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
	var stem_car := _car(
		sp, sp.length - 0.05, [sa, smv] + s_after.slice(0, 1), WS.CAR_RESIDENTIAL * 0.5
	)
	var ta: LG.Lane = t.approach[through]
	var tmv := lg.lane_between(tile, through, LG.OPP[through])
	var tp: LG.Lane = lg.prev_lanes(ta)[0]
	var t_after: Array = lg.next_lanes(tmv)
	# Through car ~1.5 s from its stop point at speed.
	var v := tp.limit * 0.9
	var through_car := _car(
		tp,
		clampf(tp.length + ta.stop_s - v * 1.5, 0.3, tp.length - 0.01),
		[ta, tmv] + t_after.slice(0, 1),
		v
	)
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
	(
		K
		. check(
			fails,
			through_in_at >= 0.0 and stem_in_at > through_in_at,
			(
				"tee: the stem car waits for the through car within 2 s (stem in at %.1f s, through in at %.1f s)"
				% [stem_in_at, through_in_at]
			)
		)
	)
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
	K.check(
		fails,
		car.v < 0.05 * WS.M and d_end >= WS.PLAYER_RADIUS + 1.5 * WS.M,
		(
			"player yield: the car stops %.2f m from the player (>= %.2f)"
			% [d_end / WS.M, (WS.PLAYER_RADIUS + 1.5 * WS.M) / WS.M]
		)
	)
	K.check(
		fails,
		min_d >= WS.PLAYER_RADIUS,
		"player yield: no car AABB comes within PLAYER_RADIUS (closest %.2f m)" % (min_d / WS.M)
	)
	_vh().remove(car)
	ctx.player.teleport(saved, 0.0)


# ------------------------------------------------------------------ soft-solid people


## The hero never passes through people (the player's soft circles and the walker's give-way are
## each other's halves of one hold): a walker met head-on on the sidewalk stops or steps past the
## band while overlapped, the separation never breaks, and they both walk on after. Shoves, holds
## and knockdowns are reactions.gd's (the impact agent's).
func _check_person_give_way() -> void:
	_quiet()
	var s := K.sidewalk(ctx, 1.1)
	K.check(fails, not s.is_empty(), "fixture: a clear straight sidewalk")
	if s.is_empty():
		return
	var wk: WK = f.get("walkers")
	var sw: SW = f.get("peds")
	# Loud guards: a check that aborts on a missing module still prints PASS (a harness
	# hazard); a wrong member name must fail as a fixture, never silently.
	if wk == null or sw == null:
		K.check(
			fails, false, "fixture: the walkers module and the sidewalk graph (f.walkers, f.peds)"
		)
		return
	var run: Vector3 = s["run"]
	var found := _give_way_edge(sw, s)
	var edge: SW.PedEdge = found[0]
	var u_hero: float = found[1]
	K.check(fails, edge != null, "fixture: a sidewalk edge through the hero's position")
	if edge == null:
		return
	# A walker 0.35 m ahead, inside the combined reach, walking straight at the hero: the hero
	# walked into them a frame ago, and the pair must untangle without ever passing through.
	var sign := signf(sw.dir_at(edge, u_hero).dot(Vector2(run.x, run.z)))
	var u_at := u_hero + sign * 0.0175
	var room := edge.length - 0.02 - u_at if sign > 0.0 else u_at - 0.02
	var behind := u_hero if sign > 0.0 else edge.length - u_hero
	if room < 0.0 or behind < 0.075:
		K.check(fails, false, "fixture: room on the edge ahead")
		return
	var w: WK.Walker = wk.make("ambient")
	var dir := -1 if sign > 0.0 else 1
	wk.place(w, edge, edge.length - u_at if dir < 0 else u_at, dir)
	var saved := ctx.player.position
	ctx.player.teleport(sw.pos_at(edge, u_hero), s["yaw"])
	var reach := WS.PLAYER_RADIUS + WK.PERSON_R
	var seen := _give_way_watch(w, reach)
	var separated: bool = seen[0]
	var worst_after: float = seen[1]
	var gave_way: bool = seen[2]
	var recovered: bool = seen[3]
	wk.remove(w)
	ctx.player.teleport(saved, 0.0)
	K.check(
		fails,
		separated,
		"fixture: the overlapped pair untangled (worst after %.2f m)" % (worst_after / WS.M)
	)
	(
		K
		. check(
			fails,
			worst_after >= reach - 0.008,
			(
				"soft-solid: after the untangle the hero never enters the walker again (closest %.2f m, their combined reach %.2f m)"
				% [worst_after / WS.M, reach / WS.M]
			)
		)
	)
	K.check(
		fails, gave_way, "soft-solid: an overlapped walker gives way (stops or steps past the band)"
	)
	K.check(
		fails,
		recovered,
		"soft-solid: they both walk on after the pass (the sidewalk keeps flowing)"
	)


## Walks the overlapped pair for 12 s and reports what they did: [separated, the closest they came
## once apart (world units), the walker gave way, both walk on again]. The hero holds forward the
## whole time, so the pair must untangle by the walker yielding, never by passing through.
func _give_way_watch(w: WK.Walker, reach: float) -> Array:
	var overlap := true
	var separated := false
	var gave_way := false
	var recovered := false
	var worst_after := INF
	for _k in range(int(12.0 / DT)):
		f.step(DT)
		ctx.player.simulate(Vector2(0, 1), false, 1.0 / 60.0)
		ctx.player.simulate(Vector2(0, 1), false, 1.0 / 60.0)
		var wp: Vector3 = w.pos + w.vis_off
		var d := Vector2(wp.x - ctx.player.position.x, wp.z - ctx.player.position.z).length()
		if d < reach:
			overlap = true
			gave_way = gave_way or w.v < 0.05 * WS.M or absf(w.lat) > WK.BAND + 0.0125
		elif overlap:
			overlap = false
			separated = true
		if separated:
			worst_after = minf(worst_after, d)
		if separated and not overlap and d > reach + 0.25 * WS.M and w.v > 0.5 * w.speed:
			recovered = true
			break
	return [separated, worst_after, gave_way, recovered]


## The sidewalk edge through the hero's start (K.sidewalk's s), running along the way they face:
## [edge, the u along it of the point nearest the start], or [null, 0.0] when the city has none.
## The start's own point must stand clear on the edge (the hero meets the walker standing on it,
## so the meeting is head-on whatever line the band runs on).
func _give_way_edge(sw: SW, s: Dictionary) -> Array:
	var run: Vector3 = s["run"]
	for e: SW.PedEdge in sw.edges:
		if e == null or e.zebra or e.length < 0.45:
			continue
		if absf(sw.dir_at(e, e.length * 0.5).dot(Vector2(run.x, run.z))) < 0.9:
			continue
		var best := INF
		var u := 0.0
		for k in range(int(e.length / 0.01) + 1):
			var q := sw.pos_at(e, 0.01 * k)
			var d := (
				Vector2(q.x - (s["pos"] as Vector3).x, q.z - (s["pos"] as Vector3).z)
				. length_squared()
			)
			if d < best:
				best = d
				u = 0.01 * k
		if best >= (1.2 * WS.M) * (1.2 * WS.M):
			continue
		var at := sw.pos_at(e, u)
		at.y = ctx.collision.walk_height(at)
		if is_nan(at.y) or ctx.collision.is_blocked(at, WS.PLAYER_RADIUS):
			continue
		return [e, u]
	return [null, 0.0]


func _aabb_dist(b: AABB, p: Vector3) -> float:
	var q := Vector2(clampf(p.x, b.position.x, b.end.x), clampf(p.z, b.position.z, b.end.z))
	return q.distance_to(Vector2(p.x, p.z))


# ------------------------------------------------------------------ resident driver


func _check_resident_driver() -> void:
	# The drive is timed on quiet streets: how long a queue at a busy tee lasts depends on the
	# ambient tuning, which the following, light, tee and clearance checks cover on their own.
	_quiet()
	var people := ctx.residents
	var r := people.find(fixture_rid)
	r["plan"] = DRIVE_PLAN.duplicate()
	var work := int(r["work"])
	sim.tick_in_day = 0
	sim.step_tick()
	var trips: TRIPS = f.get("trips")
	var tr: TRIPS.Trip = trips.trips.get(fixture_rid, null)
	if tr == null or tr.mode != "car":
		# The growth tick before the morning can close their workplace (power): send them anyway.
		print(
			(
				"  note: %s did not drive this morning (%s); sending them to work directly"
				% [
					fixture_rid,
					str(
						(
							(r["memory"] as Array).back()
							if not (r["memory"] as Array).is_empty()
							else ""
						)
					)
				]
			)
		)
		if tr != null:
			trips.complete_now(tr)
		# The same tick can also block a road beside their home (a crash): take another driver.
		if people.route_between(int(r["at"]), work).is_empty():
			fixture_rid = _pick_driver(true)
			r = people.find(fixture_rid)
			r["plan"] = DRIVE_PLAN.duplicate()
			work = int(r["work"])
		people.call("_go", r, work, "work")
		tr = trips.trips.get(fixture_rid, null)
	(
		K
		. check(
			fails,
			tr != null and tr.mode == "car",
			(
				"resident driver: trip_started makes a car trip (%s; %s state %s at %d work %d route %d trips %s)"
				% [
					tr.mode if tr != null else "none",
					fixture_rid,
					str(r["state"]),
					int(r["at"]),
					work,
					(r.get("route", []) as Array).size(),
					str(trips.trips.keys())
				]
			)
		)
	)
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
	K.check(
		fails,
		n == 1 and walkers <= 1,
		(
			"resident driver: exactly one vehicle with driver_id %s at once (%d, walkers %d)"
			% [fixture_rid, n, walkers]
		)
	)
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
				var o := (
					car.pos
					+ car.vis_off
					+ Vector3(0, 0.03, 0)
					+ Vector3(sin(car.yaw + 1.2), 0, cos(car.yaw + 1.2)) * 0.12
				)
				var hit: Dictionary = f.pick(
					o, (car.pos + car.vis_off + Vector3(0, 0.03, 0)) - o, WS.INTERACT_RANGE * 4.0
				)
				picked_car = (
					hit.get("kind", "") == "vehicle"
					and str(hit.get("data", {}).get("driver_id", "")) == fixture_rid
				)
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
				if (
					not trips.trips.has(rid)
					and (rr.is_empty() or TRIPS.inside_state(str(rr.get("state", ""))))
				):
					inside_seen = rid
		if parked_at >= 0.0 and not trips.trips.has(fixture_rid):
			break
	var fr := ctx.directory.frontage(work)
	var near_front := (
		car.parked
		and car.slot_tile >= 0
		and absi(D.tx(car.slot_tile) - D.tx(fr)) + absi(D.ty(car.slot_tile) - D.ty(fr)) <= 2
	)
	(
		K
		. check(
			fails,
			drove and parked_at >= 0.0 and parked_at <= limit and near_front,
			(
				(
					"resident driver: parks at the destination frontage in %.1f s (limit %.1f s; phase %s, car parked %s slot %d lane %s v %.2f far %s, t %.0f)"
					% [
						parked_at,
						limit,
						tr.phase,
						str(car.parked),
						car.slot_tile,
						(
							str(Vector2i(D.tx(car.lane.tile), D.ty(car.lane.tile)))
							if car.lane != null
							else "-"
						),
						car.v / WS.M,
						str(car.far),
						time
					]
				)
				+ " held: "
				+ _vh().why_held(car)
			)
		)
	)
	K.check(
		fails,
		drove and pos_err <= 0.05,
		(
			"resident driver: avatars.position_of follows the car while en route (max error %.4f)"
			% pos_err
		)
	)
	K.check(
		fails,
		not root_shown,
		"resident driver: the legacy avatar root stays hidden (no double draw)"
	)
	K.check(
		fails, picked_car, "resident driver: pick() into the car gives kind vehicle with driver_id"
	)
	K.check(
		fails, picked_res, "resident driver: pick() into the resident on foot gives kind resident"
	)
	K.check(
		fails,
		inside_seen.is_empty(),
		"visible_near never lists a resident who is indoors (%s)" % inside_seen
	)
	# An ambient walker picks as a pedestrian.
	f.set("ambient_enabled", true)
	f.call("_maintain", true)
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
			if (
				D.is_zone(sim.kind[y])
				and sim.level[y] > 0
				and ctx.directory.frontage(y) >= 0
				and people.route_between(at, y).size() >= 7
			):
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
	K.check(
		fails,
		not trips.trips.has(rid) and on_road > 100,
		"walker: the trip arrives (%.0f s, %d road samples, %d on zebras)" % [time, on_road, zebra]
	)
	K.check(
		fails,
		bad_surface == 0 and bad_band == 0,
		(
			"walker: every sidewalk sample is off the carriageway and inside PED_BAND (%d, %d) %s"
			% [bad_surface, bad_band, first_bad]
		)
	)
	K.check(
		fails, bad_feet == 0, "walker: feet at SIDEWALK_TOP on sidewalk samples (%d off)" % bad_feet
	)
	# stay_home commuters sent far arrive as walk trips.
	var r3: Dictionary = {}
	var far_lot := -1
	for x: Dictionary in people.people:
		if str(x["id"]) == rid or str(x["id"]) == fixture_rid:
			continue
		for i in sim.active:
			if (
				D.is_zone(sim.kind[i])
				and sim.level[i] > 0
				and ctx.directory.frontage(i) >= 0
				and people.route_between(int(x["at"]), i).size() > 6
			):
				far_lot = i
				break
		if far_lot >= 0:
			r3 = x
			break
	if far_lot >= 0:
		r3["plan"] = {"commute": "stay_home"}
		people.call("_go", r3, far_lot, "at the park")
		var t3: TRIPS.Trip = trips.trips.get(str(r3["id"]), null)
		K.check(
			fails,
			t3 != null and t3.mode == "walk",
			"walker: a stay_home commuter sent more than 6 tiles away arrives as a walk trip"
		)
		if t3 != null:
			trips.complete_now(t3)
	else:
		K.check(fails, false, "fixture: a lot more than 6 tiles away")
	ctx.player.teleport(saved, 0.0)


## Distance from tile-local lp on a cross tile to the nearest light pole or pedestrian signal.
func _furniture_dist(lp: Vector2) -> float:
	var best := INF
	for c: Vector2 in JN.CORNERS:
		best = minf(best, lp.distance_to(c * JN.POLE_AT))
	var lat := (WS.CURB_FURNITURE[0] + WS.CURB_FURNITURE[1]) * 0.5
	for a: Vector2 in LG.DIRS:
		var p := Vector2(-a.y, a.x)
		for sd: float in [1.0, -1.0]:
			best = minf(best, lp.distance_to(a * JN.PED_SIGNAL_AT + p * (sd * lat)))
	return best


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
				if (
					D.is_zone(sim.kind[y])
					and sim.level[y] > 0
					and ctx.directory.frontage(y) >= 0
					and absi(D.tx(y) - D.tx(h)) + absi(D.ty(y) - D.ty(h)) >= 5
				):
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
	K.check(
		fails,
		w.v < 0.01 * WS.M and face < deg_to_rad(15.0),
		(
			"conversation: the resident stops within 2 s and turns to the player (%.0f deg off)"
			% rad_to_deg(face)
		)
	)
	var head: Vector3 = f.anchor_of(rid)
	var pp: PPL = f.get("people")
	if pp != null and pp.ok:
		# The resident's body draws (T0, the player looks at them): anchor_of is its Head bone.
		ctx.player.look_toward(w.pos + Vector3(0, 1.5 * WS.M, 0))
		for _k in range(8):
			f.step(DT)
			f.sync_visuals(DT)
		head = f.anchor_of(rid)
		var b: PPL.Body = w.body
		var bone := Vector3(INF, INF, INF)
		if b != null:
			bone = (b.skel.global_transform * b.skel.get_bone_global_pose(b.head)).origin
		var hy := (head.y - w.pos.y) / WS.M
		(
			K
			. check(
				fails,
				(
					b != null
					and w.tier == 0
					and head.distance_to(bone) <= 0.1 * WS.M
					and hy > 1.35
					and hy < 1.75
				),
				(
					"conversation: anchor_of is the drawn body's Head bone (%.3f m off, %.2f m up, tier %d)"
					% [head.distance_to(bone) / WS.M, hy, w.tier]
				)
			)
		)
		var looking: bool = b != null and b.look != null and b.look.active
		K.check(
			fails,
			looking,
			"conversation: the partner's head turns to the player (LookAtModifier3D)"
		)
	else:
		K.check(
			fails,
			(
				head.distance_to(w.pos + Vector3(0, TRIPS.HEAD, 0)) <= 0.1 * WS.M
				and absf(head.y - w.pos.y - 1.62 * WS.M) < 0.12 * WS.M
			),
			"conversation: anchor_of stays at the head while they stand"
		)
	_check_street_bubble(r)
	ctx.bus.conversation_changed.emit(rid, false)
	_step(2.0)
	K.check(fails, w.dead or w.v > 0.0 or w.done, "conversation: they walk on when it ends")
	ctx.player.teleport(saved, 0.0)


## A line the resident says shows as a small depth-tested street bubble 0.12 u over their head
## (when the HUD lets bubbles show at all: never while avatars.fp_hidden).
func _check_street_bubble(r: Dictionary) -> void:
	var av: ResidentAvatars = ctx.view.avatars
	var cam := Camera3D.new()
	get_root().add_child(cam)
	cam.global_position = ctx.player.position + Vector3(0, WS.EYE, 0)
	var saved_cam := av.camera
	var saved_hidden := av.fp_hidden
	av.camera = cam
	av.fp_hidden = false
	for _k in range(ResidentAvatars.SAY_SLICES + 1):
		av.call("_process", DT)
	var saved_say: Variant = r.get("say", "")
	r["say"] = "Testing the street bubble"
	for _k in range(ResidentAvatars.SAY_SLICES + 1):
		av.call("_process", DT)
	var b: Label3D = (av.get("_street") as Dictionary).get(str(r["id"]), null)
	var at := b.position if b != null else Vector3(INF, INF, INF)
	K.check(
		fails,
		(
			b != null
			and b.visible
			and not b.no_depth_test
			and is_equal_approx(b.pixel_size, 0.0006)
			and at.distance_to(f.anchor_of(str(r["id"])) + Vector3(0, 0.12, 0)) < 1e-3
		),
		(
			"street bubble: a new line shows over the head, depth-tested at pixel_size 0.0006 (%s)"
			% (b.text if b != null else "none")
		)
	)
	av.fp_hidden = true
	av.call("_process", DT)
	K.check(fails, b != null and not b.visible, "street bubble: hidden while avatars.fp_hidden")
	r["say"] = saved_say
	av.fp_hidden = saved_hidden
	av.camera = saved_cam
	cam.queue_free()


# ------------------------------------------------------------------ people (stage E2)


func _check_people_e2() -> void:
	var pp: PPL = f.get("people")
	if pp == null or not pp.ok:
		print(
			(
				"  note: stage E2 people checks skipped (%s; legacy static people)"
				% (pp.why if pp != null else "no people module")
			)
		)
		return
	var speed := sim.speed
	sim.speed = 1
	_check_people_assignment(pp)
	_check_people_tiers(pp)
	_check_people_gait(pp)
	sim.speed = speed
	f.set("ambient_enabled", true)


## Bodies by job, gender and crc32(id): stable across fresh loads and save/load, never a hero,
## nurses from the medical pool; statures 1.61-1.80 m.
func _check_people_assignment(pp: PPL) -> void:
	K.check(
		fails,
		pp.crc32("hello") == 907060870 and pp.crc32("") == 0,
		"people: crc32 is zlib's CRC-32"
	)
	var heroes: Array = (pp.roster.get("heroes", {}) as Dictionary).values()
	var bodies: Dictionary = pp.roster.get("bodies", {})
	var fresh := PPL.new()
	fresh.load_assets()
	var n := 0
	var same := 0
	var bad := 0
	for r: Dictionary in ctx.residents.people:
		var id := str(r["id"])
		var a: String = f.resident_avatar(id)
		var ai := fresh.resident_avatar(id, str(r["name"]), str(r["job_title"]))
		n += 1
		if ai >= 0 and (fresh.avatars[ai] as PPL.Avatar).name == a:
			same += 1
		if a.is_empty() or a in heroes or not bodies.has(a):
			bad += 1
	(
		K
		. check(
			fails,
			n > 0 and same == n and bad == 0,
			(
				"people: all %d residents get the same body in a fresh load, never a hero (%d differ, %d bad)"
				% [n, n - same, bad]
			)
		)
	)
	# A resident's walker after a save and load (a new walker, new run of ids) looks the same.
	var wk: WK = f.get("walkers")
	var rid := fixture_rid
	var w1 := wk.make("resident")
	w1.resident_id = rid
	pp.dress(w1, ctx.residents)
	var d: Dictionary = JSON.parse_string(JSON.stringify(f.to_dict()))
	f.from_dict(d)
	var pp2: PPL = f.get("people")
	var w2 := wk.make("resident")
	w2.resident_id = rid
	pp2.dress(w2, ctx.residents)
	K.check(
		fails,
		w1.av >= 0 and w1.av == w2.av and is_equal_approx(w1.h_m, w2.h_m),
		(
			"people: resident %s keeps body %s and stature %.3f m after to_dict -> from_dict"
			% [rid, pp.avatar_name(w1), w1.h_m]
		)
	)
	wk.remove(w1)
	wk.remove(w2)
	# Nurses: the medical pool for their gender, else that gender's casual pool.
	var pools: Dictionary = pp.roster.get("job_pools", {})
	var casual: Dictionary = pp.roster.get("casual_pools", {})
	var nurse_bad := 0
	var nurse_n := 0
	for k in range(24):
		var full := ("Priya" if k % 2 == 0 else "Omar") + " Test"
		var id := "nurse-%d" % k
		var g := pp.resident_gender(id, full)
		var want: Array = []
		for nm: String in pools.get("nurse", []):
			if (bodies.get(nm, {}) as Dictionary).get("gender", "") == g:
				want.append(nm)
		if want.is_empty():
			want = casual.get(g, [])
		var ai := pp.resident_avatar(id, full, "nurse")
		nurse_n += 1
		if ai < 0 or not (pp.avatars[ai] as PPL.Avatar).name in want:
			nurse_bad += 1
	K.check(
		fails,
		nurse_bad == 0,
		(
			"people: %d nurses all get a medical (or casual) body of their gender (%d off)"
			% [nurse_n, nurse_bad]
		)
	)
	# Ambient walkers: never a hero; roughly 60 % casual, 25 % business, 15 % uniforms.
	var groups := {}
	var amb_hero := 0
	for k in range(400):
		var w := wk.make("ambient")
		pp.dress(w, ctx.residents)
		var a: PPL.Avatar = pp.avatars[w.av]
		var grp := a.group if a.group in ["casual", "business"] else "uniform"
		groups[grp] = int(groups.get(grp, 0)) + 1
		if a.name in heroes:
			amb_hero += 1
		wk.remove(w)
	var c := float(groups.get("casual", 0)) / 400.0
	var b := float(groups.get("business", 0)) / 400.0
	var u := float(groups.get("uniform", 0)) / 400.0
	K.check(
		fails,
		amb_hero == 0 and absf(c - 0.6) < 0.08 and absf(b - 0.25) < 0.07 and absf(u - 0.15) < 0.06,
		(
			"people: ambient mix %.0f/%.0f/%.0f %% casual/business/uniform, no hero"
			% [c * 100.0, b * 100.0, u * 100.0]
		)
	)
	# Statures: every avatar at both ends of the jitter stands 1.61-1.80 m (0.0805-0.090 u).
	var h_bad := 0
	for a: PPL.Avatar in pp.avatars:
		for j: float in [0.0, 1.0]:
			var h := pp.stature(a.gender, j)
			if h < 1.61 - 0.005 or h > 1.80 + 0.005:
				h_bad += 1
	K.check(fails, h_bad == 0, "people: statures stay within 1.61-1.80 m (%d off)" % h_bad)


## 80 people spread over 0-80 m, 64 in view and 16 behind: tier caps, T3 in MultiMeshes, off-screen
## mixers inactive, at most 150 character draws; drawn bodies stand 1.61-1.80 m (hair and hats add
## up to 4 %).
func _check_people_tiers(pp: PPL) -> void:
	_quiet()
	var wk: WK = f.get("walkers")
	var pl := ctx.player
	var base := pl.position
	var yaw := 0.0
	pl.teleport(base, rad_to_deg(yaw), 0.0, false)
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var crowd: Array = []
	for k in range(80):
		var w := wk.make("ambient")
		var front := k < 64
		var i := k if front else k - 64
		var dist := (0.5 + 79.0 * float(i) / (63.0 if front else 15.0)) * WS.M
		var ang := (float((i * 7) % 11) / 10.0 - 0.5) * deg_to_rad(40.0)
		var dir := fwd.rotated(Vector3.UP, ang) * (1.0 if front else -1.0)
		var p := base + dir * maxf(dist, 1.0 * WS.M)
		wk.stand(w, p, randf() * TAU)
		crowd.append(w)
	# Face the 16 behind first (they get bodies), then the 64 in front.
	pl.teleport(base, rad_to_deg(yaw) + 180.0, 0.0, false)
	for _k in range(12):
		f.sync_visuals(DT)
	pl.teleport(base, rad_to_deg(yaw), 0.0, false)
	for _k in range(30):
		f.sync_visuals(DT)
	var st: Dictionary = f.anim_stats()
	var t3_drawn := 0
	for a: PPL.Avatar in pp.avatars:
		if a.mmi != null and a.mmi.visible:
			t3_drawn += a.mmi.multimesh.visible_instance_count
	var t3_bodies := 0
	var off_active := 0
	var off_n := 0
	var t0_bad := 0
	var t12_bad := 0
	var surf := 0
	var h_bad := 0
	var h_lo := INF
	var h_hi := -INF
	for w: WK.Walker in crowd:
		if w.tier == 3 and w.body != null:
			t3_bodies += 1
		var b: PPL.Body = w.body
		if b == null:
			continue
		if w.tier == 4:
			off_n += 1
			if b.ap.active or b.tree.active:
				off_active += 1
			continue
		if (
			w.tier == 0
			and not (
				b.tree.active
				and not b.ap.active
				and (
					b.tree.callback_mode_process
					== AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
				)
			)
		):
			t0_bad += 1
		if (
			(w.tier == 1 or w.tier == 2)
			and not (
				b.ap.active
				and not b.tree.active
				and (
					b.ap.callback_mode_process
					== AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
				)
			)
		):
			t12_bad += 1
		for gi: GeometryInstance3D in b.meshes:
			if gi is MeshInstance3D:
				var mi := gi as MeshInstance3D
				surf += mi.mesh.get_surface_count()
				var hh := mi.mesh.get_aabb().size.y * b.root.scale.y
				h_lo = minf(h_lo, hh)
				h_hi = maxf(h_hi, hh)
				if hh < 0.080 or hh > 0.095:
					h_bad += 1
		if b.box != null and b.box.visible:
			surf += 1
	print("  people tiers: %s" % str(st))
	K.check(
		fails,
		(
			int(st["t0"]) == PPL.T0_CAP
			and int(st["t1"]) + int(st["t2"]) <= PPL.SKIN_CAP
			and int(st["t1"]) > 0
			and int(st["t2"]) > 0
			and int(st["t3"]) > 0
		),
		(
			"people tiers: T0 %d (cap 8), T1 %d + T2 %d (cap 40), T3 %d"
			% [st["t0"], st["t1"], st["t2"], st["t3"]]
		)
	)
	(
		K
		. check(
			fails,
			t0_bad == 0 and t12_bad == 0,
			(
				"people tiers: T0 bodies run the AnimationTree, T1/T2 a hand-advanced AnimationPlayer (%d, %d off)"
				% [t0_bad, t12_bad]
			)
		)
	)
	K.check(
		fails,
		t3_bodies == 0 and t3_drawn == int(st["t3"]),
		(
			"people tiers: the %d T3 people are lod1 MultiMesh instances (%d drawn, %d with a body)"
			% [st["t3"], t3_drawn, t3_bodies]
		)
	)
	K.check(
		fails,
		off_n > 0 and off_active == 0,
		(
			"people tiers: %d off-screen bodies keep their pose with inactive mixers (%d active)"
			% [off_n, off_active]
		)
	)
	K.check(
		fails,
		int(st["char_draws"]) <= PPL.DRAW_CAP and int(st["char_draws"]) >= surf,
		"people tiers: %d character draws (<= 150; %d skinned surfaces)" % [st["char_draws"], surf]
	)
	K.check(
		fails,
		h_bad == 0,
		(
			"people tiers: drawn bodies' mesh heights %.4f-%.4f u (0.080-0.095 with hair and hats)"
			% [h_lo, h_hi]
		)
	)
	for w: WK.Walker in crowd:
		wk.remove(w)
	f.sync_visuals(DT)
	K.check(
		fails,
		pp.get("_active").is_empty(),
		"people: removed walkers return their bodies to the pools"
	)


## One walker at 1.30 m/s in view: playback rate matched to the ground speed (HC's exact authored
## speed), feet on the ground, the planted foot not sliding, facing the way it walks.
func _check_people_gait(pp: PPL) -> void:
	_quiet()
	var wk: WK = f.get("walkers")
	var sw: SW = f.get("peds")
	var pl := ctx.player
	var saved := pl.position
	var e: SW.PedEdge = null
	for edge: Variant in sw.edges:
		var pe := edge as SW.PedEdge
		if pe != null and not pe.zebra and pe.length > 0.5:
			var t: LG.TileInfo = _lg().info(pe.tile)
			if t != null and t.piece == "straight":
				e = pe
				break
	K.check(fails, e != null, "fixture: a straight sidewalk edge 10 m long")
	if e == null:
		return
	var results := {}
	for extra: int in [0, 1, 2]:
		var w := wk.make("ambient")
		w.chatty = false
		w.extra = extra
		w.speed = 1.30 * WS.M
		wk.place(w, e, 0.05, 1)
		# Stand 6 m to the side of the walker's path, looking at it.
		var mid := sw.pos_at(e, 0.12)
		var d := sw.dir_at(e, 0.12)
		var side := Vector3(-d.y, 0, d.x) * (6.0 * WS.M)
		pl.teleport(mid + side, 0.0, 0.0, false)
		pl.look_toward(mid + Vector3(0, 1.0 * WS.M, 0))
		var slip := 0.0
		var slip_t := 0.0
		var foot_lo := INF
		var foot_hi := -INF
		var face_min := 1.0
		var last_foot := -1
		var last_p := Vector3.ZERO
		var rate_err := INF
		var rate_info := ""
		var tiers := {}
		for k in range(75):
			f.step(DT)
			f.sync_visuals(DT)
			var b: PPL.Body = w.body
			tiers[w.tier] = true
			if b == null or k < 20:
				continue
			var sk := b.skel
			var xf := sk.global_transform
			var low := INF
			var low_i := -1
			for bn: String in ["LeftFoot", "RightFoot", "LeftToes", "RightToes"]:
				var y := (xf * sk.get_bone_global_pose(sk.find_bone(bn))).origin.y - w.pos.y
				low = minf(low, y)
			foot_lo = minf(foot_lo, low)
			foot_hi = maxf(foot_hi, low)
			var lf := (xf * sk.get_bone_global_pose(sk.find_bone("LeftFoot"))).origin
			var rf := (xf * sk.get_bone_global_pose(sk.find_bone("RightFoot"))).origin
			low_i = 0 if lf.y < rf.y else 1
			var fp := lf if low_i == 0 else rf
			if low_i == last_foot and minf(lf.y, rf.y) - w.pos.y < 0.12 * WS.M:
				slip += Vector2(fp.x - last_p.x, fp.z - last_p.z).length()
				slip_t += DT
			last_foot = low_i
			last_p = fp
			if w.vel.length() > 0.1 * WS.M:
				face_min = minf(
					face_min,
					b.root.transform.basis.z.normalized().dot(
						Vector3(w.vel.x, 0, w.vel.z).normalized()
					)
				)
			var rate: float = (
				b.tree.get(&"parameters/rate/scale") if b.mode == 0 else b.ap.speed_scale
			)
			var a: PPL.Avatar = pp.avatars[w.av]
			var clip := w.anim_clip
			var lib := load(AP.CHAR_LIB_M if a.gender == "m" else AP.CHAR_LIB_F) as AnimationLibrary
			var src := lib.get_animation(&"walk")
			var authored := (
				float(src.get_meta("speed_mps"))
				* a.hip_m
				/ float(src.get_meta("speed_ref_hip_m"))
				* w.h_m
				/ a.rest_h
			)
			var want := (w.vis_v / WS.M) / authored
			var plan := (w.vis_v / WS.M) / (float(src.get_meta("speed_mps")) * w.h_m / 1.75)
			rate_err = absf(rate - want) / want
			rate_info = (
				"%s %s at %.2f m/s: rate %.3f, exact %.3f, plan formula %.3f (%+.1f %%)"
				% [a.name, clip, w.vis_v / WS.M, rate, want, plan, (plan / want - 1.0) * 100.0]
			)
		var slip_v := (slip / maxf(slip_t, 1e-4)) / WS.M
		results[extra] = [
			rate_err, foot_lo / WS.M, foot_hi / WS.M, slip_v, face_min, rate_info, tiers.keys()
		]
		print(
			(
				"  gait extra=%d: %s; feet %.3f..%.3f m; planted foot slides %.3f m/s; facing %.3f; tiers %s"
				% [
					extra,
					rate_info,
					foot_lo / WS.M,
					foot_hi / WS.M,
					slip_v,
					face_min,
					str(tiers.keys())
				]
			)
		)
		wk.remove(w)
	var r0: Array = results[0]
	K.check(
		fails,
		float(r0[0]) <= 0.02,
		"gait: playback rate within 2 %% of v / authored speed (%s)" % r0[5]
	)
	var feet_bad := 0
	var slide_bad := 0
	var face_bad := 0
	for extra: int in results.keys():
		var r: Array = results[extra]
		if float(r[1]) < -0.03 or float(r[1]) > 0.04 or float(r[2]) > 0.08:
			feet_bad += 1
		if float(r[3]) > 0.25:
			slide_bad += 1
		if float(r[4]) < 0.95:
			face_bad += 1
	K.check(fails, feet_bad == 0, "gait: a foot is on the ground all the way (walk, carry, phone)")
	K.check(
		fails,
		slide_bad == 0,
		"gait: the planted foot does not slide (< 0.25 m/s; walking 1.30 m/s)"
	)
	K.check(fails, face_bad == 0, "gait: bodies face the way they walk")
	pl.teleport(saved, 0.0)


# ------------------------------------------------------------------ save


func _check_save() -> void:
	var trips: TRIPS = f.get("trips")
	for tr: TRIPS.Trip in trips.trips.values():
		trips.complete_now(tr)
	var d: Dictionary = f.to_dict()
	var parked: Dictionary = d.get("parked", {})
	K.check(
		fails,
		parked.has(fixture_rid),
		"save: the resident's parked car is in to_dict (%d parked)" % parked.size()
	)
	var parsed: Variant = JSON.parse_string(JSON.stringify(d))
	K.check(fails, typeof(parsed) == TYPE_DICTIONARY, "save: to_dict survives JSON")
	if typeof(parsed) != TYPE_DICTIONARY or not parked.has(fixture_rid):
		return
	var want: Array = parked[fixture_rid]
	# A fresh world: everything rebuilt, then the save restored with no frame in between.
	f.on_world_rebuilt()
	f.from_dict(parsed)
	var c: VH.Car = trips.cars.get(fixture_rid, null)
	K.check(
		fails,
		c != null and c.parked and c.slot_tile == int(want[0]) and c.slot_k == int(want[1]),
		"save: the parked car is back in its slot after from_dict"
	)
	var cars := 0
	var peds := 0
	for x: VH.Car in _vh().cars:
		if not x.dead:
			cars += 1
	for w: WK.Walker in (f.get("walkers") as WK).walkers:
		if not w.dead:
			peds += 1
	K.check(
		fails,
		cars >= 2 and peds >= 2,
		"save: right after from_dict there are cars (%d) and pedestrians (%d)" % [cars, peds]
	)


## A fresh world, as a load rebuilds it, with the saved slot taken by a decor car (the audit
## condition): [tile, slot, the decor car, the whole save], or [] when the fixture fails.
func _reclaim_fixture() -> Array:
	var trips: TRIPS = f.get("trips")
	for tr: TRIPS.Trip in trips.trips.values():
		trips.complete_now(tr)
	var d: Dictionary = f.to_dict()
	var want: Variant = d.get("parked", {}).get(fixture_rid, null)
	if typeof(want) != TYPE_ARRAY or (want as Array).size() < 2:
		K.check(fails, false, "reclaim: fixture: the resident's car is parked")
		return []
	var i := int(want[0])
	var k := int(want[1])
	f.on_world_rebuilt()
	if not _lg().slot_valid(i, k):
		K.check(fails, false, "reclaim: fixture: the saved slot still stands")
		return []
	var decor: VH.Car = null
	for x: VH.Car in _vh().cars:
		if x.parked and x.slot_tile == i and x.slot_k == k:
			decor = x
			break
	if decor == null:
		var m: int = f.call("car_model_for", fixture_rid)
		decor = _vh().make("car", "decor", f.call("dims", m))
		decor.model = m
		_vh().park_at(decor, i, k)
	K.check(
		fails,
		decor.parked and decor.role == "decor" and decor.slot_tile == i,
		"reclaim: fixture: a decor car holds the saved slot"
	)
	return [i, k, decor, d]


## The audit case: after a load the deterministic decor fill has taken the saved slot, and the
## saved car takes its own slot back -- the decor car, nobody's, gives way out of sight.
func _check_save_reclaim() -> void:
	var fx := _reclaim_fixture()
	if fx.is_empty():
		return
	var i: int = fx[0]
	var k: int = fx[1]
	f.from_dict({"parked": {fixture_rid: [i, k]}})
	var c: VH.Car = (f.get("trips") as TRIPS).cars.get(fixture_rid, null)
	K.check(
		fails,
		(
			c != null
			and c.parked
			and c.slot_tile == i
			and c.slot_k == k
			and _lg().slot_owner(i, k) == "car:%d" % c.id
		),
		"reclaim: the saved car takes its slot back from the decor car"
	)
	K.check(fails, (fx[2] as VH.Car).dead, "reclaim: and the decor car gives way")


## A slot held by a car with an owner keeps it: another resident's car stays put, and the saved
## car parks nearby instead.
func _check_save_owned() -> void:
	var fx := _reclaim_fixture()
	if fx.is_empty():
		return
	var i: int = fx[0]
	var k: int = fx[1]
	var trips: TRIPS = f.get("trips")
	# The load fills the slot another way: another resident's car sits in it.
	_vh().remove(fx[2])
	var r2 := ""
	for r: Dictionary in ctx.residents.people:
		if str(r["id"]) != fixture_rid and not trips.cars.has(str(r["id"])):
			r2 = str(r["id"])
			break
	K.check(fails, not r2.is_empty(), "reclaim: fixture: a second resident")
	if r2.is_empty():
		return
	trips.restore_parked({r2: [i, k]})
	var c2: VH.Car = trips.cars.get(r2, null)
	f.from_dict({"parked": {fixture_rid: [i, k]}})
	var c3: VH.Car = trips.cars.get(fixture_rid, null)
	K.check(
		fails,
		c2 != null and c2.parked and c2.slot_tile == i and c2.slot_k == k,
		"reclaim: another resident's car keeps the slot"
	)
	K.check(
		fails,
		c3 != null and c3.parked and c3.slot_tile >= 0 and (c3.slot_tile != i or c3.slot_k != k),
		"reclaim: and the saved car parks nearby instead"
	)
	# Leave the world as _check_save left it: a fresh build with the whole save restored.
	f.on_world_rebuilt()
	f.from_dict(fx[3])


## Outside tests body scenes load in the background: a scene arrives within a few seconds and a
## missing path resolves to null without a request.
func _check_people_async() -> void:
	var pp: PPL = f.get("people")
	if pp == null or not pp.ok:
		return
	var bg := PPL.new()
	bg.load_assets()
	var path := (bg.avatars[bg.avatars.size() - 1] as PPL.Avatar).path.get_basename() + "_lod1.glb"
	var ps: PackedScene = null
	var waited := 0
	while ps == null and waited < 10000:
		ps = bg.call("_scene", path)
		if ps == null:
			OS.delay_msec(20)
			waited += 20
	var missing: Variant = bg.call("_scene", "res://models/characters/bodies/Nobody_00.glb")
	K.check(
		fails,
		ps != null and missing == null and (bg.get("_pending") as Dictionary).is_empty(),
		"people: background scene loads arrive (%d ms) and a missing body is null" % waited
	)
	var other := (bg.avatars[0] as PPL.Avatar).path.get_basename() + "_lod1.glb"
	bg.call("_scene", other)
	bg.finish_loads()
	var kept: Variant = (bg.get("_scenes") as Dictionary).get(other)
	var drained := (bg.get("_pending") as Dictionary).is_empty()
	K.check(fails, drained and kept is PackedScene, "people: finish_loads() waits for a load")


## Without HC's characters (people.ok false) a rebuilt world frees every HC body and draws the
## legacy static people again.
func _check_people_fallback() -> void:
	var pp: PPL = f.get("people")
	if pp == null or not pp.ok:
		return
	var off := PPL.new()
	off.why = "forced off by the test"
	f.set("people", off)
	f.on_world_rebuilt()
	var live := 0
	for n: Node in (f.get("_agents_root") as Node).get_children():
		if n.name.begins_with("CharacterRoot") and not n.is_queued_for_deletion():
			live += 1
	(
		K
		. check(
			fails,
			live == 0 and not (f.get("walkers") as WK).hc,
			(
				"people fallback: a rebuild without HC frees every body (%d left) and walkers leave HC speeds"
				% live
			)
		)
	)
	f.set("ambient_enabled", true)
	f.call("_refill", true)
	_check_people_draw()
	var st: Dictionary = f.anim_stats()
	K.check(
		fails,
		(
			int(st["t0"]) + int(st["t1"]) + int(st["t2"]) + int(st["t3"]) == 0
			and int(st["char_draws"]) > 0
		),
		"people fallback: anim_stats reports only the legacy people draws (%s)" % str(st)
	)
	f.set("people", pp)
	f.on_world_rebuilt()


# ------------------------------------------------------------------ buses


## Two stops on straights 4+ tiles apart make a line; a bus runs it, pulls in to the curb at a
## shelter for its dwell and leaves again.
func _check_buses() -> void:
	_quiet()
	var view := ctx.view
	var lg := _lg()
	var fleets = f.get("fleets")
	var cands: Array[int] = []
	for i: int in lg.tiles.keys():
		if (
			lg.parkable(i)
			and not view.bus_stops.has(i)
			and lg.slot_valid(i, 0)
			and lg.slot_valid(i, 2)
		):
			cands.append(i)
	cands.sort()
	# The farthest pair on one connected road network.
	var a := -1
	var b := -1
	var best := 0
	for i: int in cands:
		var comp := {i: true}
		var q: Array[int] = [i]
		while not q.is_empty():
			var t: int = q.pop_back()
			for n: int in lg.neighbours(t):
				if lg.tiles.has(n) and not comp.has(n):
					comp[n] = true
					q.append(n)
		for j: int in cands:
			var d := absi(D.tx(i) - D.tx(j)) + absi(D.ty(i) - D.ty(j))
			if comp.has(j) and d > best:
				best = d
				a = i
				b = j
	K.check(
		fails,
		a >= 0 and best >= 4,
		"fixture: two straights 4+ tiles apart for bus stops (%d)" % best
	)
	if a < 0 or best < 4:
		return
	var added: Array[int] = []
	for i: int in [a, b]:
		if not view.bus_stops.has(i):
			view.bus_stops[i] = true
			added.append(i)
	f.call("_maintain", false)
	K.check(
		fails,
		fleets.lines.size() >= 1,
		"buses: new stops make %d seeded line(s)" % fleets.lines.size()
	)
	if fleets.lines.is_empty():
		for i: int in added:
			view.bus_stops.erase(i)
		return
	f.spawn_fleet("bus", Vector2i.ZERO)
	var bus: VH.Car = null
	for c: VH.Car in _vh().cars:
		if c.role == "bus" and not c.dead:
			bus = c
	K.check(fails, bus != null, 'buses: spawn_fleet("bus") puts a bus on a line')
	if bus == null:
		return
	var stop_lanes: Array = []
	for line: Variant in fleets.lines:
		stop_lanes.append_array(line.stop_lanes)
	var dwell := 0.0
	var best_dwell := 0.0
	var curb := 0.0
	var left_after := false
	for _k in range(int(160.0 / DT)):
		f.step(DT)
		if bus.dead:
			break
		if bus.arrived and stop_lanes.has(bus.lane):
			dwell += DT
			curb = maxf(curb, bus.lat_off)
		elif dwell > 0.0:
			best_dwell = maxf(best_dwell, dwell)
			left_after = true
			dwell = 0.0
		if left_after and best_dwell > 0.0:
			break
	K.check(
		fails,
		best_dwell >= fleets.DWELL * 0.9 and left_after and curb >= fleets.CURB_LAT * 0.9,
		(
			"buses: the bus stands %.1f s at a shelter, pulled %.1f m to the curb, then leaves"
			% [best_dwell, curb / WS.M]
		)
	)
	if not bus.dead:
		_vh().remove(bus)
	for i: int in added:
		view.bus_stops.erase(i)
	f.call("_maintain", false)


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
	K.check(
		fails,
		crews0 > 0,
		"fleets: CityLife sends crews through E (%d) %s" % [crews0, fleets.last_dispatch_fail]
	)
	var counts: Dictionary = view.life.vehicle_counts()
	K.check(
		fails, int(counts.get("crews", 0)) == crews0, "fleets: vehicle_counts() reports E's crews"
	)
	# A second view.setup() makes new CityLife and ResidentAvatars instances.
	var old_life := view.life
	view.setup(sim, view.camera)
	f.on_world_rebuilt()
	K.check(
		fails,
		view.life != old_life and view.life.external == f and view.avatars.external == f,
		"fleets: world_rebuilt re-attaches the hooks to the new instances"
	)
	K.check(
		fails,
		fleets.count("crew") > 0,
		(
			"fleets: an event present before the rebuild gets a crew through E (%d live events) %s"
			% [sim.events.size(), fleets.last_dispatch_fail]
		)
	)
	# Crew routes take at most ASTAR_PER_FRAME A* builds per frame; the rest wait their turn.
	for c: VH.Car in _vh().cars.duplicate():
		if c.role == "crew":
			_vh().remove(c)
	var roads: Array = _lg().tiles.keys()
	var station: Vector2i = Vector2i(D.tx(roads[0]), D.ty(roads[0]))
	fleets.astar_left = fleets.ASTAR_PER_FRAME
	for k in range(6):
		var t: int = roads[(k + 1) * roads.size() / 8]
		fleets.dispatch_crew("ambulance", station, Vector2i(D.tx(t), D.ty(t)))
	var first: int = fleets.count("crew")
	var waiting: int = fleets.pending.size()
	f.step(DT)
	(
		K
		. check(
			fails,
			(
				first <= fleets.ASTAR_PER_FRAME
				and waiting == 6 - first
				and fleets.pending.is_empty()
				and fleets.count("crew") == 6
			),
			(
				"fleets: 6 crew routes in one frame build %d now, %d wait, all 6 after the next frame (%d)"
				% [first, waiting, fleets.count("crew")]
			)
		)
	)
	f.teardown()
	K.check(
		fails,
		view.life.external == null and view.avatars.external == null,
		"fleets: teardown() clears both hooks"
	)
