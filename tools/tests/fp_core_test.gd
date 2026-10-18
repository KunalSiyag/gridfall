extends SceneTree
## S0 core (docs/fp/S0-foundation.md §17.3): kit fixtures, the feature registry, CollisionWorld
## ground / surface / blocking / raycast, construction sites blocking at their hoarding, walking
## out of a box that appeared underfoot, nearest_free, FpPlayer walking, mouse look under a window
## stretch and save round trip, FpContext modals, FpHud slots and AP.load_scene. Movement asserts
## against collision.boxes(), never building_aabb.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const REGISTRY := preload("res://scripts/fp/fp_features.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []


## Records the mouse motions the root viewport delivers (after its stretch transform).
class MotionRecorder extends Node:
	var got: Array[InputEventMouseMotion] = []

	func _unhandled_input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			got.append(event as InputEventMouseMotion)


func _init() -> void:
	# The root joins the tree after the first frame; nodes need get_tree() (pause, tweens).
	await process_frame
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true})
	_check_fixtures(ctx)
	_check_registry(ctx)
	_check_ground(ctx)
	_check_walk(ctx)
	await _check_mouse_look(ctx)
	_check_blocking(ctx)
	_check_context(ctx)
	_check_assets()
	_check_trapped(ctx)
	_check_site(ctx)
	K.finish(self, "FP_CORE_TEST", fails)


func _check_fixtures(ctx: FpContext) -> void:
	var sim := ctx.sim
	var people := ctx.residents
	K.check(fails, people.people.size() >= 5, "fixture: at least 5 residents (%d)" % people.people.size())
	var commuter := false
	for r: Dictionary in people.people:
		if int(r["at"]) == int(r["home"]) and int(r["work"]) >= 0:
			commuter = true
	K.check(fails, commuter, "fixture: a resident at home with a job")
	var shop := false
	for i in sim.active:
		if sim.kind[i] == D.ZONE_C and sim.level[i] > 0 and not ctx.directory.business_name(i).is_empty():
			shop = true
	K.check(fails, shop, "fixture: a named C lot")
	K.check(fails, not ctx.view.bus_stops.is_empty(), "fixture: a bus stop (%d)" % ctx.view.bus_stops.size())
	var pieces := {}
	for i in sim.active:
		if sim.kind[i] == D.ROAD:
			pieces[str(RoadTopology.piece(RoadTopology.mask(sim, D.tx(i), D.ty(i)))[0])] = true
	for p: String in ["corner", "tee", "cross", "straight", "end"]:
		K.check(fails, pieces.has(p), "fixture: a %s road piece" % p)


func _check_registry(ctx: FpContext) -> void:
	var ids := {}
	var ok := true
	for e: Dictionary in REGISTRY.FEATURES:
		var path := str(e["path"])
		var script: GDScript = load(path) if ResourceLoader.exists(path) else null
		var f: Variant = script.new() if script != null else null
		var good: bool = f is FpFeature and (f as FpFeature).feature_id() == str(e["id"]) and not ids.has(str(e["id"]))
		if not good:
			ok = false
			print("  bad registry entry %s" % str(e))
		ids[str(e["id"])] = true
		if f is Node:
			(f as Node).free()
	K.check(fails, ok and ids.size() == 9, "all 9 registry entries load as FpFeatures with matching unique ids")
	var feat := K.make_feature(ctx, "traffic")
	K.check(fails, feat != null and feat.is_inside_tree() and ctx.feature("traffic") == feat, "make_feature puts the feature in the tree and ctx.features")
	var st: Dictionary = feat.self_test() if feat != null else {}
	K.check(fails, bool(st.get("ok", false)), "stub self_test is ok")


func _check_ground(ctx: FpContext) -> void:
	var sim := ctx.sim
	var col := ctx.collision
	var straight := _straight_road(sim, false)
	K.check(fails, straight >= 0, "a straight road tile exists")
	if straight >= 0:
		var m := RoadTopology.mask(sim, D.tx(straight), D.ty(straight))
		var c := Vector3(D.tx(straight), 0, D.ty(straight))
		var side := RoadTopology.run_right(m) * WS.SIDEWALK_CENTER
		K.check(fails, is_equal_approx(col.ground_height(c), WS.ASPHALT_TOP), "road centre is asphalt height")
		K.check(fails, is_equal_approx(col.ground_height(c + side), WS.SIDEWALK_TOP) and is_equal_approx(col.ground_height(c - side), WS.SIDEWALK_TOP), "sidewalk at 0.4 is SIDEWALK_TOP")
		K.check(fails, col.surface_at(c) == "asphalt" and col.surface_at(c + side) == "sidewalk", "surface_at: asphalt centre, sidewalk edge")
		var sp := RoadTopology.sidewalk_point(sim, straight, 1)
		K.check(fails, is_equal_approx(col.ground_height(sp), WS.SIDEWALK_TOP), "sidewalk_point is on the sidewalk")
	var water := -1
	var end_tile := -1
	var grass := -1
	var lot := -1
	for i in sim.active:
		var k := sim.kind[i]
		if water < 0 and sim.terrain[i] == D.WATER and k != D.ROAD:
			water = i
		if end_tile < 0 and k == D.ROAD and sim.terrain[i] != D.WATER and RoadTopology.arms(RoadTopology.mask(sim, D.tx(i), D.ty(i))).size() == 1:
			end_tile = i
		if grass < 0 and (k == D.EMPTY or k == D.PARK) and sim.terrain[i] != D.WATER:
			grass = i
		if lot < 0 and D.is_zone(k) and sim.level[i] > 0:
			lot = i
	K.check(fails, water >= 0 and is_nan(ctx.collision.ground_height(_centre(water))) and col.surface_at(_centre(water)) == "water", "non-road water is unwalkable")
	K.check(fails, end_tile >= 0, "an end road tile exists")
	if end_tile >= 0:
		var arm := Vector2(RoadTopology.arms(RoadTopology.mask(sim, D.tx(end_tile), D.ty(end_tile)))[0])
		var o := -arm * WS.END_CIRCLE_OFFSET
		var island := _centre(end_tile) + Vector3(o.x, 0, o.y)
		var ring := _centre(end_tile) + Vector3(o.x, 0, o.y) + Vector3(-arm.y, 0, arm.x) * 0.25
		K.check(fails, is_equal_approx(col.ground_height(island), WS.SIDEWALK_TOP) and col.surface_at(island) == "sidewalk", "the cul-de-sac island is raised")
		K.check(fails, is_equal_approx(col.ground_height(ring), WS.ASPHALT_TOP), "the turning circle is asphalt")
	K.check(fails, grass >= 0 and col.surface_at(_centre(grass)) == "grass" and is_equal_approx(col.ground_height(_centre(grass)), WS.GROUND_Y), "empty land and parks are grass")
	K.check(fails, lot >= 0 and col.surface_at(_centre(lot)) == "lot", "developed lots are lot surface")
	var corner := -1
	for i in sim.active:
		if sim.kind[i] == D.ROAD and str(RoadTopology.piece(RoadTopology.mask(sim, D.tx(i), D.ty(i)))[0]) == "corner":
			corner = i
			break
	if corner >= 0:
		var am := RoadTopology.arms(RoadTopology.mask(sim, D.tx(corner), D.ty(corner)))
		var cc := (Vector2(am[0]) + Vector2(am[1])) * 0.5
		var on_arc := cc - cc.normalized() * 0.5
		K.check(fails, RoadTopology.is_carriageway(RoadTopology.mask(sim, D.tx(corner), D.ty(corner)), on_arc), "corner carriageway follows the arc")
		K.check(fails, not RoadTopology.is_carriageway(RoadTopology.mask(sim, D.tx(corner), D.ty(corner)), -cc * 0.9), "corner outer sidewalk is not carriageway")


func _check_walk(ctx: FpContext) -> void:
	var p := ctx.player
	var straight := _straight_road(ctx.sim, true)
	K.check(fails, straight >= 0, "a straight road with straight neighbours exists")
	if straight < 0:
		return
	var m := RoadTopology.mask(ctx.sim, D.tx(straight), D.ty(straight))
	var run := RoadTopology.run_dir(m)
	var start := RoadTopology.sidewalk_point(ctx.sim, straight, 1) - run * 0.1
	p.teleport(start, rad_to_deg(atan2(-run.x, -run.z)))
	K.check(fails, p.forward().distance_to(run) < 1e-4, "teleport yaw faces along the run")
	var tiles: Array = []
	ctx.bus.player_tile_changed.connect(func(x: int, y: int) -> void: tiles.append(Vector2i(x, y)))
	var p0 := p.position
	for _k in range(180):
		p.simulate(Vector2(0, 1), false, DT)
	var moved := Vector2(p.position.x - p0.x, p.position.z - p0.z).length()
	K.check(fails, absf(moved - WS.WALK * 3.0) <= WS.WALK * 3.0 * 0.15, "3 s of walking covers %.4f (expected %.4f +-15%%)" % [moved, WS.WALK * 3.0])
	K.check(fails, absf(p.position.y - ctx.collision.ground_height(p.position)) < 0.002, "the feet stay on the sidewalk")
	var p1 := p.position
	for _k in range(60):
		p.simulate(Vector2(0, 1), true, DT)
	var ran := Vector2(p.position.x - p1.x, p.position.z - p1.z).length()
	K.check(fails, ran > WS.WALK * 1.5, "sprinting is faster than walking (%.4f in 1 s)" % ran)
	p.teleport(start, rad_to_deg(atan2(-run.x, -run.z)))
	ctx.push_modal(&"test")
	var p2 := p.position
	for _k in range(180):
		p.simulate(Vector2(0, 1), false, DT)
	ctx.pop_modal(&"test")
	K.check(fails, Vector2(p.position.x - p2.x, p.position.z - p2.z).length() < 1e-6, "with a modal pushed the same calls move nothing")
	var d0 := p.to_dict()
	var saved := JSON.parse_string(JSON.stringify(d0)) as Dictionary
	var here := p.position
	var yaw_deg := rad_to_deg(p.yaw)
	p.teleport(here + Vector3(2, 0, 2), 33.0)
	p.from_dict(saved)
	K.check(fails, p.position.distance_to(here) < 1e-4 and absf(rad_to_deg(p.yaw) - yaw_deg) < 0.01, "to_dict/from_dict round-trips position and yaw")
	p.from_dict({})
	var sp: Dictionary = ctx.mode.spawn_point()
	K.check(fails, p.position.distance_to(sp["pos"]) < 1e-4, "from_dict({}) spawns at spawn_point")
	K.check(fails, not tiles.is_empty(), "player_tile_changed fired (%d)" % tiles.size())


## Look speed is mouse_sensitivity radians per screen pixel whatever the window stretch: the same
## 100 x 40 px motion, delivered through the root viewport at three content-scale factors, turns
## the player by exactly px * sensitivity (the stretched `relative` differs between them).
func _check_mouse_look(ctx: FpContext) -> void:
	var p := ctx.player
	var win := get_root()
	var factor0 := win.content_scale_factor
	var rec := MotionRecorder.new()
	win.add_child(rec)
	var sens := float(ctx.settings.get("mouse_sensitivity", WS.MOUSE_SENSITIVITY))
	var px := Vector2(100.0, 40.0)
	var rels: Array[Vector2] = []
	var exact := true
	for f: float in [1.0, 2.0, 0.5]:
		win.content_scale_factor = f
		await process_frame
		var ev := InputEventMouseMotion.new()
		ev.relative = px
		ev.screen_relative = px
		rec.got.clear()
		win.push_input(ev)
		if rec.got.is_empty():
			exact = false
			print("  no motion delivered at content_scale_factor %.1f" % f)
			continue
		var got: InputEventMouseMotion = rec.got.back()
		rels.append(got.relative)
		p.teleport(p.position, 0.0, 0.0, false)
		p.mouse_look(got)
		var dyaw := -p.yaw
		var dpitch := -p.pitch
		if not (is_equal_approx(dyaw, px.x * sens) and is_equal_approx(dpitch, px.y * sens)):
			exact = false
			print("  factor %.1f: relative %s turned yaw %.5f pitch %.5f (expected %.5f, %.5f)" % [f, str(got.relative), dyaw, dpitch, px.x * sens, px.y * sens])
	win.content_scale_factor = factor0
	rec.free()
	K.check(fails, rels.size() == 3 and not rels[0].is_equal_approx(rels[1]), "fixture: the window stretch scales `relative` (%s)" % str(rels))
	K.check(fails, exact, "mouse look turns px * sensitivity at every window stretch")


func _check_blocking(ctx: FpContext) -> void:
	var sim := ctx.sim
	var col := ctx.collision
	var p := ctx.player
	var target := -1
	for i in sim.active:
		if D.is_zone(sim.kind[i]) and sim.level[i] > 0 and not sim.sites.has(i) and ctx.directory.frontage(i) >= 0 and not col.boxes(i).is_empty():
			target = i
			break
	K.check(fails, target >= 0, "a building with a frontage exists")
	if target < 0:
		return
	var f := ctx.directory.frontage(target)
	var dir := Vector3(D.tx(target) - D.tx(f), 0, D.ty(target) - D.ty(f))
	var start := Vector3(D.tx(f), 0, D.ty(f)) + dir * WS.SIDEWALK_CENTER
	p.teleport(start, rad_to_deg(atan2(-dir.x, -dir.z)))
	var r := WS.PLAYER_RADIUS * 0.99
	var inside := false
	for _k in range(300):
		p.simulate(Vector2(0, 1), true, DT)
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var x := roundi(p.position.x) + dx
				var y := roundi(p.position.z) + dz
				if not D.in_bounds(x, y):
					continue
				for b: AABB in col.boxes(D.idx(x, y)):
					if b.grow(r).has_point(p.position):
						inside = true
	var travelled := Vector2(p.position.x - start.x, p.position.z - start.z).length()
	K.check(fails, not inside and travelled > 0.01, "walking into a building for 5 s never enters its boxes (stopped after %.3f)" % travelled)
	p.teleport(start, rad_to_deg(atan2(-dir.x, -dir.z)))
	var hit := col.raycast(p.eye_position(), dir, WS.INTERACT_RANGE)
	K.check(fails, bool(hit["hit"]) and str(hit["kind"]) == "building" and int(hit["tile"]) == target and float(hit["dist"]) <= WS.INTERACT_RANGE, "raycast from the sidewalk hits the building (%s)" % str(hit))
	var down := col.raycast(p.eye_position(), Vector3(0.3, -1, 0), 1.0)
	K.check(fails, bool(down["hit"]) and str(down["kind"]) == "ground", "raycast down hits the ground")
	K.check(fails, col.is_blocked(Vector3(D.tx(target), WS.LOT_TOP, D.ty(target)), WS.PLAYER_RADIUS), "a building centre is blocked")


## A building appears on the empty lot the player stands on: the player must still walk out.
func _check_trapped(ctx: FpContext) -> void:
	var sim := ctx.sim
	var col := ctx.collision
	var p := ctx.player
	var lot := -1
	for i in sim.active:
		if sim.kind[i] == D.EMPTY and sim.terrain[i] != D.WATER and not sim.sites.has(i) and ctx.directory.frontage(i) >= 0 and col.boxes(i).is_empty():
			lot = i
			break
	K.check(fails, lot >= 0, "fixture: an empty lot with a frontage road")
	if lot < 0:
		return
	var f := ctx.directory.frontage(lot)
	var out := Vector3(D.tx(f) - D.tx(lot), 0, D.ty(f) - D.ty(lot))
	p.teleport(_centre(lot), rad_to_deg(atan2(-out.x, -out.z)))
	K.check(fails, not col.is_blocked(p.position, WS.PLAYER_RADIUS), "the empty lot is free to stand on")
	sim.kind[lot] = D.ZONE_R
	sim.level[lot] = 1
	ctx.view.call("_on_tiles_changed", PackedInt32Array([lot]))
	K.check(fails, col.is_blocked(p.position, WS.PLAYER_RADIUS), "a house built on the lot now surrounds the player")
	for _k in range(300):
		p.simulate(Vector2(0, 1), true, DT)
	K.check(fails, not col.is_blocked(p.position, WS.PLAYER_RADIUS), "the player walks out of the new house (at %s)" % str(p.position))
	# Just inside the front face, backing into the house goes no deeper.
	var b := col.box(lot).grow(WS.PLAYER_RADIUS)
	var c := _centre(lot)
	var face := (b.end.x - c.x if out.x > 0.0 else c.x - b.position.x) if out.x != 0.0 else (b.end.z - c.z if out.z > 0.0 else c.z - b.position.z)
	var near := c + out * (face - 0.02)
	p.teleport(near, rad_to_deg(atan2(-out.x, -out.z)))
	K.check(fails, col.is_blocked(p.position, WS.PLAYER_RADIUS), "a point just inside the front face is blocked")
	for _k in range(30):
		p.simulate(Vector2(0, -1), false, DT)
	var moved := Vector2(p.position.x - near.x, p.position.z - near.z).dot(Vector2(out.x, out.z))
	K.check(fails, moved > -1e-6, "backing deeper into the house is refused (moved %.5f)" % moved)
	var q := col.nearest_free(_centre(lot), WS.PLAYER_RADIUS, 2.0)
	K.check(fails, not is_nan(q.x) and not col.is_blocked(q, WS.PLAYER_RADIUS) and Vector2(q.x - D.tx(lot), q.z - D.ty(lot)).length() < 1.0, "nearest_free finds a free point next to the house (%s)" % str(q))


## A construction site blocks where the kit draws it: walking at a hoarding side without the gate
## stops at the hoarding (0.474 from the centre, 1 m outside the future building's 0.423), and the
## feet never enter a collision box on the way. Runs last: it starts sites on open lots.
func _check_site(ctx: FpContext) -> void:
	var sim := ctx.sim
	var col := ctx.collision
	var p := ctx.player
	var mode := sim.construction_mode
	sim.construction_mode = "staged"
	var lots: Array = sim.open_lots(0, 12)
	var builds := ["police", "school", "fire_station"]
	for k in range(mini(lots.size(), builds.size())):
		sim.mayors[0]["treasury"] = int(sim.mayors[0]["treasury"]) + 50000
		sim.apply_action(0, {"type": "build", "building": builds[k], "x": int(lots[k][0]), "y": int(lots[k][1])})
	sim.step_tick()
	sim.construction_mode = mode
	var r := WS.PLAYER_RADIUS
	# Hoarding segments at ±0.47, 0.008 thick; side k of ConstructionKit._fence, gate side h % 4.
	var face := 0.474
	var sides := [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]
	var walks := 0
	var stops: Array[String] = []
	var ok := true
	for i: int in sim.sites.keys():
		if walks >= 4:
			break
		if str((sim.sites[i] as Dictionary)["type"]) != "build" or sim.terrain[i] == D.WATER or ctx.view.site_boxes(i).is_empty():
			continue
		var c := _centre(i)
		var gate := absi(D.tx(i) * 73856093 ^ D.ty(i) * 19349663) % 4
		for k in range(4):
			var dir: Vector3 = sides[k]
			var start := c + dir * 0.66
			start.y = col.ground_height(start)
			if k == gate or is_nan(start.y) or col.is_blocked(start, r):
				continue
			p.teleport(start, rad_to_deg(atan2(dir.x, dir.z)))
			var inside := false
			for _s in range(150):
				p.simulate(Vector2(0, 1), true, DT)
				inside = inside or _in_boxes(col, p.position, r * 0.99)
			var out := (p.position - c).dot(dir)
			stops.append("%.3f" % out)
			if inside or out < face + r * 0.99 or out > face + r + 0.02:
				ok = false
				print("  site %d side %d: stopped %.4f from the centre (hoarding face %.3f + r), inside a box: %s" % [i, k, out, face, inside])
			walks += 1
			if walks >= 4:
				break
	K.check(fails, walks > 0, "fixture: a fenced build site with a free approach to a side without the gate")
	K.check(fails, ok, "walking at a site's hoarding stops at the hoarding (%s)" % ", ".join(stops))


## True when p lies in a collision box (grown by r) of the 3x3 tiles around it.
func _in_boxes(col: CollisionWorld, p: Vector3, r: float) -> bool:
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var x := roundi(p.x) + dx
			var y := roundi(p.z) + dz
			if not D.in_bounds(x, y):
				continue
			for b: AABB in col.boxes(D.idx(x, y)):
				if b.grow(r).has_point(p):
					return true
	return false


func _check_context(ctx: FpContext) -> void:
	var events: Array = []
	ctx.bus.modal_changed.connect(func(a: bool) -> void: events.append(a))
	ctx.push_modal(&"a")
	ctx.push_modal(&"b")
	ctx.pop_modal(&"a")
	K.check(fails, ctx.is_modal() and ctx.has_modal(&"b") and ctx.modal_count() == 1, "modal stack counts owners")
	ctx.pop_modal(&"b")
	K.check(fails, events == [true, false] and not ctx.is_modal(), "modal_changed fires on 0->1 and 1->0 only")
	var hud := ctx.hud
	var slots_ok := true
	for n: String in FpHud.SLOTS:
		slots_ok = slots_ok and hud.slot(n) != null
	K.check(fails, slots_ok, "FpHud has all six slots")
	hud.set_hud_visible(false)
	var hidden := not hud.slot("top_bar").visible and hud.slot("overlay").visible and not hud.is_hud_visible()
	hud.set_hud_visible(true)
	K.check(fails, hidden and hud.slot("top_bar").visible, "set_hud_visible hides every slot but the overlay")
	ctx.bus.toast.emit("Grok-4.5 says hello", "info")
	K.check(fails, hud.slot("toasts").get_child(0).get_child_count() == 1, "a bus toast shows in the toasts slot")
	var mode := ctx.mode
	var scales: Array = []
	ctx.bus.time_scale_changed.connect(func(s: int) -> void: scales.append(s))
	mode.set_time_scale(3)
	K.check(fails, mode.time_scale == 2 or mode.time_scale == 4, "set_time_scale snaps to 1/2/4/8 (%d)" % mode.time_scale)
	mode.set_time_scale(8)
	mode.step_time_scale(1)
	K.check(fails, mode.time_scale == 8 and ctx.sim.speed == 8, "step_time_scale clamps at 8x")
	mode.step_time_scale(-1)
	K.check(fails, mode.time_scale == 4 and scales.back() == 4, "step_time_scale steps down")
	mode.set_time_scale(1)
	mode.set_paused(true)
	K.check(fails, paused and ctx.has_modal(&"pause"), "set_paused pauses the tree and pushes the pause modal")
	mode.set_paused(false)
	K.check(fails, not paused and not ctx.is_modal(), "unpausing pops the modal")
	ctx.sim.set_speed(0)
	mode.apply_settings({"fov": 80.0, "quality": "high"})
	K.check(fails, is_equal_approx(ctx.player.camera.fov, 80.0) and mode.settings_log.size() == 1, "apply_settings reaches the player camera")


func _check_assets() -> void:
	K.check(fails, AP.load_scene("res://models/real/street/does_not_exist.glb") == null, "AP.load_scene returns null for a missing path")
	K.check(fails, AP.load_scene("res://icon.png") == null, "AP.load_scene returns null for a non-scene resource")
	K.check(fails, AP.load_scene("res://models/real/roads/road_straight.glb") != null, "AP.load_scene loads an existing GLB")
	K.check(fails, AP.first_existing(["res://nope.glb", "res://models/real/roads/road_cross.glb"]) == "res://models/real/roads/road_cross.glb", "AP.first_existing skips missing paths")


## A straight (N-S or E-W) land road tile; with `long`, also with road on both ends of its run.
func _straight_road(sim: CitySim, long: bool) -> int:
	for i in sim.active:
		if sim.kind[i] != D.ROAD or sim.terrain[i] == D.WATER:
			continue
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		if m != RoadTopology.NS and m != RoadTopology.EW:
			continue
		if not long:
			return i
		var run := RoadTopology.run_dir(m)
		var a := D.idx(D.tx(i) + int(run.x) * 2, D.ty(i) + int(run.z) * 2)
		var b := D.idx(D.tx(i) - int(run.x) * 2, D.ty(i) - int(run.z) * 2)
		if sim.kind[a] == D.ROAD and sim.kind[b] == D.ROAD:
			return i
	return -1


func _centre(i: int) -> Vector3:
	return Vector3(D.tx(i), 0, D.ty(i))
