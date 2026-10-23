extends SceneTree
## Slice A player and interaction (docs/fp/slices/A-player.md "Acceptance tests"): speeds and
## the crouched eye, curbs and ledges, the jump, walls and sliding, building bodies, the soft step,
## water, props, interaction (targets, priorities, normalising, E, modals), photo mode, the save
## and construction sites. First person (the kit default) on a grown city; movement asserts
## against collision.boxes(), never building_aabb.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DT := 1.0 / 60.0
const M := WS.M
const R := WS.PLAYER_RADIUS
const PROGRESS_GROUPS := [&"Trees", &"Stumps", &"Rebar", &"Debris", &"Planting"]

var fails: Array[String] = []


## A feature whose pick() answers every ray with a fixed target (at a fixed distance along it).
class StubPick extends FpFeature:
	var result: Dictionary = {}
	var at_dist: float = 0.0

	func feature_id() -> String:
		return "stub_pick"

	func pick(origin: Vector3, dir: Vector3, _max_dist: float) -> Dictionary:
		if result.is_empty():
			return {}
		var out := result.duplicate(true)
		out["pos"] = origin + dir * at_dist
		out["dist"] = at_dist
		return out


func _init() -> void:
	await process_frame
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true})
	ctx.player.set_process(false)
	_check_speeds(ctx)
	_check_curb(ctx)
	_check_jump(ctx)
	_check_walls(ctx)
	_check_slide(ctx)
	_check_bodies(ctx)
	_check_park(ctx)
	_check_soft_step(ctx)
	_check_water(ctx)
	_check_props(ctx)
	await _check_interact(ctx)
	await _check_photo(ctx)
	_check_save(ctx)
	_check_sites(ctx)
	K.finish(self, "FP_PLAYER_TEST", fails)


## Walk, run and crouch-walk for 3 s from rest along a clear sidewalk: within 10 % of speed * 3.
## The crouched eye sits at CROUCH_EYE.
func _check_speeds(ctx: FpContext) -> void:
	var p := ctx.player
	var s := K.sidewalk(ctx, 0.7)
	K.check(fails, not s.is_empty(), "fixture: a clear straight sidewalk")
	if s.is_empty():
		return
	var start: Vector3 = s["pos"]
	for row: Array in [["walk", false, false, WS.WALK], ["run", true, false, WS.RUN], ["crouch-walk", false, true, WS.CROUCH_WALK]]:
		p.teleport(start, s["yaw"])
		for k in range(180):
			p.simulate(Vector2(0, 1), row[1], DT, row[2])
		var d := Vector2(p.position.x - start.x, p.position.z - start.z).length()
		var want: float = float(row[3]) * 3.0
		K.check(fails, absf(d - want) <= want * 0.1, "%s 3 s covers %.3f m (%.1f %% of %.3f m)" % [row[0], d / M, d / want * 100.0, want / M])
	for k in range(60):
		p.simulate(Vector2.ZERO, false, DT, true)
	var eye := p.eye_position().y - ctx.collision.walk_height(p.position)
	K.check(fails, p.crouched and absf(eye - WS.CROUCH_EYE) <= 1e-4 and absf(p.position.y - ctx.collision.walk_height(p.position)) < 1e-6, "the crouched eye is %.4f m above the ground (CROUCH_EYE %.2f)" % [eye / M, WS.CROUCH_EYE / M])
	for k in range(60):
		p.simulate(Vector2.ZERO, false, DT, false)
	K.check(fails, not p.crouched and absf(p.eye_position().y - p.position.y - WS.EYE) <= 1e-4, "releasing crouch stands up to EYE")
	# No standing up under a ceiling: a box 1.4 m above the feet.
	p.teleport(start, s["yaw"])
	for k in range(30):
		p.simulate(Vector2.ZERO, false, DT, true)
	var gy := p.position.y
	ctx.collision.add_test_box(AABB(Vector3(start.x - 0.02, gy + 1.4 * M, start.z - 0.02), Vector3(0.04, 0.02, 0.04)))
	for k in range(30):
		p.simulate(Vector2.ZERO, false, DT, false)
	var stuck := p.crouched
	ctx.collision.clear_test_boxes()
	for k in range(30):
		p.simulate(Vector2.ZERO, false, DT, false)
	K.check(fails, stuck and not p.crouched, "you cannot stand up under a ceiling box; you can once it is gone")


## From the carriageway onto the sidewalk: the 12 cm curb is a step; a 40 cm ledge is not.
func _check_curb(ctx: FpContext) -> void:
	var p := ctx.player
	var col := ctx.collision
	var i := _straight_road(ctx)
	K.check(fails, i >= 0, "fixture: a straight road")
	if i < 0:
		return
	var m := RoadTopology.mask(ctx.sim, D.tx(i), D.ty(i))
	var side := RoadTopology.run_right(m)
	var c := Vector3(D.tx(i), 0, D.ty(i))
	var start := c + side * 0.2
	p.teleport(start, rad_to_deg(atan2(-side.x, -side.z)))
	K.check(fails, absf(p.position.y - WS.ASPHALT_TOP) < 1e-6, "fixture: the carriageway at ASPHALT_TOP")
	for k in range(120):
		p.simulate(Vector2(0, 1), false, DT)
	var out := (p.position - c).dot(side)
	K.check(fails, out > WS.SIDEWALK_INNER + R and absf(p.position.y - WS.SIDEWALK_TOP) <= 1e-4, "walking onto the sidewalk climbs the curb (feet %.4f, %.3f from the centre)" % [p.position.y, out])
	# A 0.02 u (40 cm) ledge across the path.
	var across := Vector3(side.z, 0, -side.x).abs()
	var ledge_c := c + side * 0.27
	var size := across * 1.0 + side.abs() * 0.02 + Vector3(0, 0.02, 0)
	col.add_test_box(AABB(Vector3(ledge_c.x - size.x * 0.5, WS.ASPHALT_TOP, ledge_c.z - size.z * 0.5), size))
	p.teleport(start, rad_to_deg(atan2(-side.x, -side.z)))
	for k in range(120):
		p.simulate(Vector2(0, 1), false, DT)
	var stop := (p.position - c).dot(side)
	col.clear_test_boxes()
	K.check(fails, stop <= 0.26 - R + 1e-4, "a 0.02 u ledge blocks the walk (stopped %.4f from the centre, face at 0.26)" % stop)


## Jump: apex 0.5-0.7 m above the take-off ground, back on the ground within 1 s.
func _check_jump(ctx: FpContext) -> void:
	var p := ctx.player
	var s := K.sidewalk(ctx, 0.2)
	if s.is_empty():
		return
	p.teleport(s["pos"], s["yaw"])
	var g0 := p.position.y
	var top := g0
	var landed := -1.0
	var steps := [0]
	var land_speeds: Array[float] = []
	var on_step := func(_surface: String, _pos: Vector3) -> void:
		steps[0] += 1
	var on_land := func(speed: float) -> void:
		land_speeds.append(speed)
	p.stepped.connect(on_step)
	p.landed.connect(on_land)
	p.simulate(Vector2.ZERO, false, DT, false, true)
	var left := not p.grounded
	for k in range(90):
		p.simulate(Vector2.ZERO, false, DT, false, false)
		top = maxf(top, p.position.y)
		if landed < 0.0 and p.grounded:
			landed = float(k + 2) * DT
	p.stepped.disconnect(on_step)
	p.landed.disconnect(on_land)
	var apex := top - g0
	K.check(fails, left and apex >= 0.5 * M and apex <= 0.7 * M and landed > 0.0 and landed <= 1.0, "jump: apex %.3f m, landed after %.2f s" % [apex / M, landed])
	var land_ok := land_speeds.size() == 1 and absf(land_speeds[0] - WS.JUMP_SPEED / M) < 0.3
	var land_msg := "a landing in place is one footstep (%d) and one landed at %s m/s"
	K.check(fails, int(steps[0]) == 1 and land_ok, land_msg % [int(steps[0]), str(land_speeds)])
	# Holding jump does not bounce; a press 0.1 s before landing is buffered.
	p.teleport(s["pos"], s["yaw"])
	var jumps := 0
	var was := true
	for k in range(120):
		p.simulate(Vector2.ZERO, false, DT, false, true)
		if was and not p.grounded:
			jumps += 1
		was = p.grounded
	K.check(fails, jumps == 1, "holding jump jumps once (%d)" % jumps)


## Walking into every building within 3 tiles of City Hall for 4 s never enters a box.
func _check_walls(ctx: FpContext) -> void:
	var p := ctx.player
	var sim := ctx.sim
	var hall := -1
	for i in sim.active:
		if sim.kind[i] == D.HALL:
			hall = i
	K.check(fails, hall >= 0, "fixture: City Hall")
	var tried := 0
	var bad: Array[String] = []
	var sides := [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]
	# Every building within 3 tiles of City Hall, topped up with the nearest others to six.
	var near: Array = []
	for i in sim.active:
		if ctx.view.building_aabb(i).size.x > 0.0:
			near.append([maxi(absi(D.tx(i) - D.tx(hall)), absi(D.ty(i) - D.ty(hall))), i])
	near.sort()
	var picked: Array[int] = []
	for e: Array in near:
		if int(e[0]) <= 3 or picked.size() < 6:
			picked.append(int(e[1]))
	for i: int in picked:
		var c := Vector3(D.tx(i), 0, D.ty(i))
		for dir: Vector3 in sides:
			var start := c + dir * 0.66
			start.y = ctx.collision.walk_height(start)
			if is_nan(start.y) or ctx.collision.is_blocked(start, R):
				continue
			p.teleport(start, rad_to_deg(atan2(dir.x, dir.z)))
			tried += 1
			for k in range(240):
				p.simulate(Vector2(0, 1), k % 80 > 40, DT)
				var hit := _inside_any(ctx, p.position, R * 0.99)
				if not hit.is_empty():
					bad.append("tile %d: %s" % [i, hit])
					break
	K.check(fails, picked.size() >= 6 and tried >= 6 and bad.is_empty(), "walking into %d buildings near City Hall from %d sides never enters a box %s" % [picked.size(), tried, str(bad.slice(0, 3))])


## Walking diagonally into a long wall keeps at least half the speed along it.
func _check_slide(ctx: FpContext) -> void:
	var p := ctx.player
	var sim := ctx.sim
	var col := ctx.collision
	for i in sim.active:
		if not D.is_zone(sim.kind[i]) or sim.level[i] <= 0:
			continue
		for b: AABB in col.body_boxes(i):
			if b.size.x < 0.3:
				continue
			# Along the box's north face (-z), 0.5 m out, walking west-north-west into it.
			var start := Vector3(b.position.x + 0.05, 0, b.position.z - R - 0.5 * M)
			var g := col.walk_height(start)
			if is_nan(g):
				continue
			start.y = g
			var clear := true
			for k in range(12):
				var q := start + Vector3(0.02 * k, 0, 0)
				clear = clear and not col.is_blocked(Vector3(q.x, col.walk_height(q), q.z), R * 1.2)
			if not clear:
				continue
			# Facing +x along the wall; wish 45 degrees into it (toward +z is "right").
			p.teleport(start, -90.0)
			for k in range(60):
				p.simulate(Vector2(0.7071, 0.7071), false, DT)
			var x0 := p.position.x
			for k in range(60):
				p.simulate(Vector2(0.7071, 0.7071), false, DT)
			var along := (p.position.x - x0) / 1.0
			var tangential := WS.WALK * 0.7071
			K.check(fails, along >= 0.5 * tangential and p.position.z <= b.position.z - R * 0.99, "a diagonal walk into a wall slides along it at %.0f %% of the tangential speed" % (along / tangential * 100.0))
			return
	K.check(fails, false, "fixture: a building wall with a clear walk along it")


## Bodies: at most 4 per building, inside view.building_aabb; every building answers a ray from
## its frontage sidewalk within INTERACT_RANGE.
func _check_bodies(ctx: FpContext) -> void:
	var sim := ctx.sim
	var col := ctx.collision
	var n := 0
	var bad: Array[String] = []
	var unreach: Array[String] = []
	var smaller := 0
	for i in sim.active:
		var b := ctx.view.building_aabb(i)
		if b.size.x <= 0.0:
			continue
		var bodies := col.body_boxes(i)
		if D.is_zone(sim.kind[i]) and sim.level[i] > 0:
			n += 1
			if bodies.size() > 4:
				bad.append("tile %d: %d bodies" % [i, bodies.size()])
			for a: AABB in bodies:
				if not b.grow(1e-4).encloses(a):
					bad.append("tile %d: body %s outside %s" % [i, a, b])
			var area := 0.0
			for a: AABB in bodies:
				area += a.size.x * a.size.z
			if area < b.size.x * b.size.z * 0.9:
				smaller += 1
		var f := ctx.directory.frontage(i)
		if f < 0 or sim.sites.has(i):
			continue
		var dir := Vector3(D.tx(i) - D.tx(f), 0, D.ty(i) - D.ty(f))
		var eye := Vector3(D.tx(f), 0, D.ty(f)) + dir * WS.SIDEWALK_CENTER
		eye.y = col.walk_height(eye) + WS.EYE
		var hit := col.raycast(eye, dir, WS.INTERACT_RANGE, false)
		if not bool(hit["hit"]) or str(hit["kind"]) != "building" or int(hit["tile"]) != i:
			unreach.append(str(i))
	K.check(fails, n > 5 and bad.is_empty(), "%d buildings: at most 4 bodies each, all inside building_aabb %s" % [n, str(bad.slice(0, 3))])
	# Colliders rebuild per tile on demand, within 0.2 ms a tile.
	col.rebuild_all()
	var built := 0
	var worst := 0
	var t_all := Time.get_ticks_usec()
	for i in sim.active:
		if ctx.view.tile_holder(i) == null:
			continue
		var t0 := Time.get_ticks_usec()
		col.boxes(i)
		worst = maxi(worst, Time.get_ticks_usec() - t0)
		built += 1
	var avg := float(Time.get_ticks_usec() - t_all) / float(maxi(built, 1))
	K.check(fails, built > 20 and avg < 200.0, "colliders build in %.0f us a tile on average (%d tiles, worst %d us)" % [avg, built, worst])
	K.check(fails, smaller * 2 > n, "bodies leave the yards open: %d of %d lots block under 90 %% of their bounds" % [smaller, n])
	K.check(fails, unreach.is_empty(), "every building answers a ray from its frontage sidewalk %s" % str(unreach.slice(0, 5)))


## A park: its trees never block, most of it is open and it can be walked across.
func _check_park(ctx: FpContext) -> void:
	var p := ctx.player
	var sim := ctx.sim
	var col := ctx.collision
	var lot := -1
	for i in sim.active:
		if sim.kind[i] == D.EMPTY and sim.terrain[i] != D.WATER and not sim.sites.has(i) and ctx.directory.frontage(i) >= 0 and col.boxes(i).is_empty():
			var free := true
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var j := D.idx(D.tx(i) + dx, D.ty(i) + dz)
					free = free and (dx == 0 and dz == 0 or sim.kind[j] != D.SITE)
			if free:
				lot = i
				break
	K.check(fails, lot >= 0, "fixture: an empty lot for a park")
	if lot < 0:
		return
	sim.kind[lot] = D.PARK
	ctx.view.call("_on_tiles_changed", PackedInt32Array([lot]))
	var c := Vector3(D.tx(lot), 0, D.ty(lot))
	var open := 0
	var total := 0
	for z in range(-8, 9):
		for x in range(-8, 9):
			var q := c + Vector3(x * 0.05, 0, z * 0.05)
			q.y = col.walk_height(q)
			total += 1
			if not col.is_blocked(q, R):
				open += 1
	K.check(fails, open >= total * 0.8, "the park is %.0f %% open (trees do not block)" % (open * 100.0 / total))
	# Across the park through (or, past a fountain, just beside) its centre.
	var best_off := NAN
	for off: float in [0.0, 0.03, -0.03, 0.06, -0.06, 0.1, -0.1, 0.14, -0.14]:
		var ok := true
		for k in range(-9, 10):
			var q := c + Vector3(k * 0.05, 0, off)
			q.y = col.walk_height(q)
			ok = ok and not col.is_blocked(q, R)
		if ok:
			best_off = off
			break
	K.check(fails, not is_nan(best_off), "a clear line crosses the park within 0.14 of its centre")
	if is_nan(best_off):
		return
	var start := c + Vector3(-0.45, 0, best_off)
	p.teleport(start, -90.0)
	for k in range(int(0.9 / WS.WALK / DT) + 60):
		p.simulate(Vector2(0, 1), false, DT)
	K.check(fails, p.position.x > c.x + 0.4, "walked across the park (to %.3f past its centre, line %.2f off)" % [p.position.x - c.x, best_off])


## Interim soft step: from grass, onto a lot and a sidewalk, and back.
func _check_soft_step(ctx: FpContext) -> void:
	var p := ctx.player
	var sim := ctx.sim
	var col := ctx.collision
	var done := 0
	var bad: Array[String] = []
	for i in sim.active:
		if sim.kind[i] != D.EMPTY or sim.terrain[i] == D.WATER or not col.boxes(i).is_empty() or not col.cylinders(i).is_empty():
			continue
		for dv: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var x := D.tx(i) + dv.x
			var y := D.ty(i) + dv.y
			if not D.in_bounds(x, y):
				continue
			var j := D.idx(x, y)
			var gj := col.ground_height(Vector3(x, 0, y))
			if is_nan(gj) or gj <= WS.GROUND_Y + 1e-6:
				continue
			var dir := Vector3(dv.x, 0, dv.y)
			var c := Vector3(D.tx(i), 0, D.ty(i))
			# A clear straight line from the grass centre 0.3 into the higher tile.
			var clear := true
			for k in range(17):
				var q := c + dir * (0.05 * k)
				q.y = col.walk_height(q)
				clear = clear and not col.is_blocked(q, R * 1.2)
			if not clear:
				continue
			p.teleport(c, rad_to_deg(atan2(-dir.x, -dir.z)))
			for k in range(240):
				p.simulate(Vector2(0, 1), true, DT)
				if (p.position - c).dot(dir) >= 0.75:
					break
			var up := (p.position - c).dot(dir) >= 0.7 and col.tile_at(p.position) == j and absf(p.position.y - col.walk_height(p.position)) < 1e-4
			for k in range(240):
				p.simulate(Vector2(0, -1), true, DT)
				if (p.position - c).dot(dir) <= 0.2:
					break
			var back := (p.position - c).dot(dir) <= 0.25 and col.tile_at(p.position) == i
			if not (up and back):
				bad.append("grass %d -> %s %d (up %s back %s at %s)" % [i, "road" if sim.kind[j] == D.ROAD else "lot", j, up, back, str(p.position)])
			done += 1
			break
		if done >= 4:
			break
	K.check(fails, done >= 2 and bad.is_empty(), "grass to a higher tile and back over the soft step (%d edges) %s" % [done, str(bad)])


## Walking toward the river stops at the edge: never over a water tile.
func _check_water(ctx: FpContext) -> void:
	var p := ctx.player
	var sim := ctx.sim
	var col := ctx.collision
	for i in sim.active:
		if sim.terrain[i] != D.WATER or sim.kind[i] == D.ROAD:
			continue
		for dv: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var x := D.tx(i) + dv.x
			var y := D.ty(i) + dv.y
			if not D.in_bounds(x, y):
				continue
			var j := D.idx(x, y)
			if sim.terrain[j] == D.WATER or not col.boxes(j).is_empty() or sim.kind[j] == D.ROAD:
				continue
			var start := Vector3(x, 0, y)
			var to := Vector3(-dv.x, 0, -dv.y)
			p.teleport(start, rad_to_deg(atan2(-to.x, -to.z)))
			var wet := false
			for k in range(300):
				p.simulate(Vector2(0, 1), true, DT)
				var t := col.tile_at(p.position)
				wet = wet or t < 0 or sim.terrain[t] == D.WATER and sim.kind[t] != D.ROAD or is_nan(col.ground_height(p.position))
			var edge := (p.position - start).dot(to)
			K.check(fails, not wet and edge > 0.45, "walking toward the river stops at the edge (%.3f from the bank tile centre), never over water" % edge)
			return
	K.check(fails, false, "fixture: a river bank")


## Props: the lamp pole of a lit straight, a bus shelter, and a holder colliders meta.
func _check_props(ctx: FpContext) -> void:
	var p := ctx.player
	var col := ctx.collision
	var sim := ctx.sim
	# The pole derived from Bulb_0.
	var lamp := Vector3(NAN, 0, NAN)
	var lamp_tile := -1
	for i in sim.active:
		if sim.kind[i] != D.ROAD:
			continue
		var h := ctx.view.tile_holder(i)
		if h == null:
			continue
		for ch: Node in h.get_children():
			if ch is Node3D and (ch as Node3D).scene_file_path.ends_with("road_straight_lights.glb"):
				var bulb := (ch as Node3D).get_node_or_null("Bulb_0") as Node3D
				if bulb != null:
					var bp := bulb.position
					lamp = h.transform * ((ch as Node3D).transform * Vector3(bp.x + signf(bp.x) * 0.08, 0, bp.z))
					lamp_tile = i
		if lamp_tile >= 0:
			break
	K.check(fails, lamp_tile >= 0, "fixture: a lit straight road")
	if lamp_tile >= 0:
		var closest := INF
		for a: float in [0.0, 90.0, 180.0, 270.0, 45.0]:
			var from := lamp + Vector3(sin(deg_to_rad(a)), 0, cos(deg_to_rad(a))) * 0.06
			from.y = col.walk_height(from)
			if is_nan(from.y) or col.is_blocked(from, R):
				continue
			var to := lamp - from
			p.teleport(from, rad_to_deg(atan2(-to.x, -to.z)))
			for k in range(120):
				p.simulate(Vector2(0, 1), false, DT)
				closest = minf(closest, Vector2(p.position.x - lamp.x, p.position.z - lamp.z).length())
		K.check(fails, closest < INF and closest >= R + 0.008 - 1e-5, "the Bulb_0 lamp pole blocks (closest %.4f, pole + radius %.4f)" % [closest, R + 0.008])
	# A bus shelter.
	var stop := -1
	for i: int in ctx.view.bus_stops.keys():
		stop = i
		break
	K.check(fails, stop >= 0, "fixture: a bus stop")
	if stop >= 0:
		var shelter := AABB()
		var h := ctx.view.tile_holder(stop)
		for ch: Node in h.get_children():
			if ch is Node3D and ((ch as Node3D).scene_file_path.contains("bus_stop") or (ch as Node3D).scene_file_path.is_empty() and not (ch is MeshInstance3D)):
				var off := Vector2((ch as Node3D).position.x, (ch as Node3D).position.z)
				if off.length() > 0.3:
					shelter = AABB(h.transform * (ch as Node3D).position, Vector3.ZERO)
		var found := false
		var inside := false
		for b: AABB in col.boxes(stop):
			if b.grow(0.05).has_point(shelter.position + Vector3(0, 0.05, 0)):
				found = true
				var c := Vector3(D.tx(stop), 0, D.ty(stop))
				var from := c + (shelter.position - c) * 0.6
				from.y = col.walk_height(from)
				var to := shelter.position - from
				p.teleport(from, rad_to_deg(atan2(-to.x, -to.z)))
				for k in range(120):
					p.simulate(Vector2(0, 1), false, DT)
					inside = inside or b.grow(R * 0.99).has_point(p.position)
		K.check(fails, found and not inside, "the bus shelter is a box and walking into it stops outside")
	# A holder `colliders` meta (G1) replaces every other prop source on that holder.
	var holder := ctx.view.tile_holder(lamp_tile) if lamp_tile >= 0 else null
	if holder != null:
		holder.set_meta("colliders", [{"shape": "box", "pos": Vector3(0.1, 0, 0.1), "size": Vector3(0.05, 0.05, 0.05), "yaw": 0.0}, {"shape": "cyl", "pos": Vector3(-0.1, 0, -0.1), "r": 0.01}])
		col.on_tile_built(lamp_tile, holder)
		var bx := col.boxes(lamp_tile)
		var cy := col.cylinders(lamp_tile)
		var want := holder.transform * Vector3(0.1, 0, 0.1)
		var ok := bx.size() == 1 and bx[0].get_center().is_equal_approx(want + Vector3(0, 0.025, 0)) and cy.size() == 4 and is_equal_approx(cy[2], 0.01)
		holder.remove_meta("colliders")
		col.on_tile_built(lamp_tile, holder)
		K.check(fails, ok, "a holder colliders meta is the only prop source for that holder (%d boxes, %d cylinders)" % [bx.size(), cy.size() / 4])


## Interaction: targets, priorities, normalising, E, modals.
func _check_interact(ctx: FpContext) -> void:
	var p := ctx.player
	var feat := K.make_feature(ctx, "interact")
	var targets: Array[Dictionary] = []
	var requested: Array[Dictionary] = []
	var talks: Array[String] = []
	ctx.bus.interact_target_changed.connect(func(t: Dictionary) -> void: targets.append(t))
	ctx.bus.interact_requested.connect(func(t: Dictionary) -> void: requested.append(t))
	ctx.bus.talk_requested.connect(func(id: String) -> void: talks.append(id))
	var b := _frontage(ctx, WS.SIDEWALK_CENTER)
	K.check(fails, not b.is_empty() and feat != null, "fixture: a building and the interact feature")
	if b.is_empty() or feat == null:
		return
	p.teleport(b["pos"], b["yaw"])
	targets.clear()
	feat.call("evaluate")
	feat.call("evaluate")
	K.check(fails, targets.size() == 1 and str(targets[0].get("kind", "")) == "building" and int(targets[0].get("tile", -1)) == int(b["tile"]) and not str(targets[0].get("label", "")).is_empty(), "facing a building gives exactly one building target (%s)" % str(targets.map(func(t: Dictionary) -> String: return str(t.get("label", "")))))
	# A resident 2 m away beats a building 5 m away.
	# Back off along the ray until the building's bounds are 5 m ahead of the eye.
	var bdir := Vector3(-sin(deg_to_rad(float(b["yaw"]))), 0, -cos(deg_to_rad(float(b["yaw"]))))
	var bhit := ctx.collision.raycast((b["pos"] as Vector3) + Vector3.UP * WS.EYE, bdir, 1.0, false)
	var far_pos: Vector3 = (bhit["pos"] as Vector3) - bdir * (5.0 * M)
	far_pos.y = ctx.collision.walk_height(far_pos)
	var far := {"pos": far_pos, "yaw": b["yaw"]}
	var stub := StubPick.new()
	stub.name = "stub_pick"
	ctx.world_root.get_parent().get_node("Features").add_child(stub)
	ctx.features["stub_pick"] = stub
	stub.setup(ctx)
	var rid := str(ctx.residents.people[0]["id"])
	p.teleport(far["pos"], far["yaw"])
	feat.call("evaluate")
	var bdist := float((feat.get("target") as Dictionary).get("dist", 0.0))
	stub.result = {"kind": "resident", "id": rid, "tile": -1, "label": "Talk to Someone", "data": {}}
	stub.at_dist = 2.0 * M
	var t: Dictionary = feat.call("evaluate")
	K.check(fails, bdist > 4.0 * M and str(t.get("kind", "")) == "resident" and str(t.get("id", "")) == rid, "a resident 2 m away wins over the building %.1f m away" % (bdist / M))
	stub.result = {"kind": "pedestrian", "id": "ped_7", "tile": -1, "label": "a pedestrian", "data": {"driver_id": rid}}
	t = feat.call("evaluate")
	var name := str(ctx.residents.find(rid).get("name", ""))
	K.check(fails, str(t.get("kind", "")) == "resident" and str(t.get("id", "")) == rid and str(t.get("label", "")).contains(name), "a pedestrian with a driver_id becomes that resident (%s)" % str(t.get("label", "")))
	# E: interact_requested, and talk_requested for residents.
	requested.clear()
	talks.clear()
	_press("interact")
	await process_frame
	K.check(fails, requested.size() == 1 and talks == [rid], "E emits interact_requested and talk_requested (%d, %s)" % [requested.size(), str(talks)])
	# Modal: the prompt clears, E does nothing, the frame that pops the modal ignores E.
	targets.clear()
	ctx.push_modal(&"test")
	var cleared := not targets.is_empty() and (targets.back() as Dictionary).is_empty()
	requested.clear()
	_press("interact")
	await process_frame
	var p0 := p.position
	for k in range(30):
		p.simulate(Vector2(0, 1), true, DT)
	K.check(fails, cleared and requested.is_empty() and p.position.distance_to(p0) < 1e-9, "a modal clears the prompt, freezes the walker and blocks E")
	ctx.pop_modal(&"test")
	_press("interact")
	await process_frame
	K.check(fails, requested.is_empty(), "E in the frame that popped the modal does nothing")
	_press("interact")
	await process_frame
	K.check(fails, requested.size() == 1, "E works again on the next frame")
	stub.result = {}
	ctx.features.erase("stub_pick")
	stub.queue_free()


## Photo mode: HUD hidden, fly up and down, E ignored; exit restores the feet and the HUD.
func _check_photo(ctx: FpContext) -> void:
	var p := ctx.player
	var feat := ctx.feature("interact")
	var s := K.sidewalk(ctx, 0.2)
	p.teleport(s["pos"], s["yaw"])
	var feet := p.position
	var hud_was := ctx.hud.is_hud_visible()
	var requested: Array[Dictionary] = []
	var on_req := func(t: Dictionary) -> void: requested.append(t)
	ctx.bus.interact_requested.connect(on_req)
	p.set_photo_mode(true)
	K.check(fails, p.photo_mode and not ctx.hud.is_hud_visible() and not ctx.is_modal(), "photo mode hides the HUD without a modal")
	var y0 := p.view_position().y
	for k in range(30):
		p.simulate(Vector2.ZERO, false, DT, true, false)
		p.update_view(DT)
	var y1 := p.view_position().y
	for k in range(60):
		p.simulate(Vector2.ZERO, false, DT, false, true)
		p.update_view(DT)
	var y2 := p.view_position().y
	K.check(fails, y1 < y0 - 0.1 * M and y2 > y1 + 0.5 * M, "crouch flies down (%.2f m) and jump up (%.2f m)" % [(y1 - y0) / M, (y2 - y1) / M])
	for _k in range(180):
		p.simulate(Vector2.ZERO, false, DT, true, false)
		p.update_view(DT)
	var low := p.view_position()
	var clear := (low.y - ctx.collision.ground_height(low)) / M
	var stop_msg := "the ground stops the flight down (%.2f m above it)" % clear
	K.check(fails, clear > 0.19 and clear < 0.21, stop_msg)
	if feat != null:
		feat.call("evaluate")
	_press("interact")
	await process_frame
	K.check(fails, requested.is_empty() and (feat == null or (feat.get("target") as Dictionary).is_empty()), "E does nothing in photo mode")
	p.set_photo_mode(false)
	K.check(fails, not p.photo_mode and p.position.distance_to(feet) < 1e-6 and ctx.hud.is_hud_visible() == hud_was, "leaving photo mode restores the feet and the HUD")
	ctx.bus.interact_requested.disconnect(on_req)


## Save: to_dict / from_dict round-trips the pose, the view and crouch; old saves load.
func _check_save(ctx: FpContext) -> void:
	var p := ctx.player
	var s := K.sidewalk(ctx, 0.2)
	p.teleport(s["pos"], s["yaw"])
	for k in range(30):
		p.simulate(Vector2.ZERO, false, DT, true)
	p.look(0.3, -0.1)
	var d := JSON.parse_string(JSON.stringify(p.to_dict())) as Dictionary
	var pos := p.position
	var cy := p.cam_yaw
	var cp := p.cam_pitch
	p.teleport(pos + Vector3(1, 0, 1), 10.0)
	for k in range(30):
		p.simulate(Vector2.ZERO, false, DT, false)
	p.from_dict(d)
	K.check(fails, p.position.distance_to(pos) < 1e-4 and p.crouched and absf(wrapf(p.cam_yaw - cy, -PI, PI)) < 1e-4 and absf(p.cam_pitch - cp) < 1e-4 and not bool(d.get("photo", true)) and str(d.get("camera_mode", "")) == "first", "to_dict/from_dict round-trips the pose, the view and crouch")
	p.from_dict({"pos": [pos.x, pos.y, pos.z], "yaw": 30.0, "pitch": 5.0})
	K.check(fails, absf(rad_to_deg(p.cam_yaw) - 30.0) < 1e-3 and absf(rad_to_deg(p.cam_pitch) - 5.0) < 1e-3 and p.camera_mode == "first", "an S0 save loads with the view from the body")
	for k in range(30):
		p.simulate(Vector2.ZERO, false, DT, false)


## Construction sites: the hoarding stops a walker at its face, long frames never tunnel, the
## gate lets nobody into a part, and every drawn part a walker can hit lies in a collision box.
func _check_sites(ctx: FpContext) -> void:
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
	var face := 0.474
	var sides := [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]
	var walks := 0
	var stops_ok := true
	var long_ok := true
	var gate_ok := true
	var gates := 0
	var parts_ok := true
	var parts := 0
	for i: int in sim.sites.keys():
		if str((sim.sites[i] as Dictionary)["type"]) != "build" or sim.terrain[i] == D.WATER or ctx.view.site_boxes(i).is_empty():
			continue
		var c := Vector3(D.tx(i), 0, D.ty(i))
		var open := ctx.view.site_gate(i)
		var gate := sides.find(Vector3(open.x, 0, open.y))
		for k in range(4):
			var dir: Vector3 = sides[k]
			var start := c + dir * 0.66
			start.y = col.walk_height(start)
			if is_nan(start.y) or col.is_blocked(start, R):
				continue
			p.teleport(start, rad_to_deg(atan2(dir.x, dir.z)))
			var inside := false
			for _s in range(150):
				p.simulate(Vector2(0, 1), true, DT)
				inside = inside or not _inside_sites(ctx, p.position, R * 0.99).is_empty()
			var out := (p.position - c).dot(dir)
			if k == gate:
				gates += 1
				gate_ok = gate_ok and not inside
				continue
			walks += 1
			if inside or out < face + R * 0.99 or out > face + R + 0.02:
				stops_ok = false
				print("  site %d side %d stopped %.4f from the centre (inside %s)" % [i, k, out, inside])
			for st: Array in [[0.7, false], [2.72, false], [2.72, true]]:
				if st[1]:
					p.teleport(start, rad_to_deg(atan2(dir.x, dir.z)))
				p.simulate(Vector2(0, 1), true, st[0])
				var o := (p.position - c).dot(dir)
				if not _inside_any(ctx, p.position, R * 0.99).is_empty() or o < face + R * 0.99:
					long_ok = false
					print("  site %d side %d: a %.2f s step ended %.4f from the centre" % [i, k, st[0], o])
		var site := ctx.view.tile_holder(i).get_node_or_null("Site") as Node3D if ctx.view.tile_holder(i) != null else null
		if site != null:
			for a: AABB in _walker_parts(site):
				parts += 1
				if not _covered(a, ctx, i):
					parts_ok = false
					print("  site %d: part x[%.3f,%.3f] z[%.3f,%.3f] y[%.3f,%.3f] in no collision box" % [i, a.position.x, a.end.x, a.position.z, a.end.z, a.position.y, a.end.y])
	K.check(fails, walks > 0 and stops_ok, "walking at a hoarding stops at its face (%d walks)" % walks)
	K.check(fails, walks > 0 and long_ok, "0.7 and 2.72 s steps against a hoarding never tunnel")
	K.check(fails, gates > 0 and gate_ok, "walking in through the gate never enters a site part (%d gates)" % gates)
	K.check(fails, parts > 0 and parts_ok, "every drawn site part a walker can hit lies in a collision box (%d parts)" % parts)


## "box description" of the first collision box (grown by r) or cylinder containing p, else "".
func _inside_any(ctx: FpContext, p: Vector3, r: float) -> String:
	var col := ctx.collision
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var x := roundi(p.x) + dx
			var y := roundi(p.z) + dz
			if not D.in_bounds(x, y):
				continue
			var j := D.idx(x, y)
			for b: AABB in col.boxes(j):
				if b.grow(r).has_point(p):
					return "box %s" % str(b)
			var cy := col.cylinders(j)
			for k in range(0, cy.size(), 4):
				if p.y < cy[k + 3] and Vector2(p.x - cy[k], p.z - cy[k + 1]).length() < cy[k + 2] + r:
					return "cylinder (%.3f, %.3f)" % [cy[k], cy[k + 1]]
	return ""


func _inside_sites(ctx: FpContext, p: Vector3, r: float) -> String:
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var x := roundi(p.x) + dx
			var y := roundi(p.z) + dz
			if not D.in_bounds(x, y):
				continue
			for b: AABB in ctx.view.site_boxes(D.idx(x, y)):
				if b.grow(r).has_point(p):
					return str(b)
	return ""


## The visible meshes under a Site node a walker can bump into (fp_seams_test's rule).
func _walker_parts(site: Node3D) -> Array[AABB]:
	var out: Array[AABB] = []
	var stack: Array[Node] = [site]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null and mi.is_visible_in_tree():
			var a := mi.global_transform * mi.mesh.get_aabb()
			if a.size.y >= WS.STEP_HEIGHT and a.position.y < WS.PLAYER_HEIGHT:
				out.append(a)
		for ch in n.get_children():
			if ch.name != &"Boom" and not PROGRESS_GROUPS.has(ch.name):
				stack.append(ch)
	return out


func _covered(a: AABB, ctx: FpContext, i: int) -> bool:
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var x := D.tx(i) + dx
			var y := D.ty(i) + dz
			if not D.in_bounds(x, y):
				continue
			for b: AABB in ctx.collision.boxes(D.idx(x, y)):
				if a.position.x >= b.position.x - 1e-4 and a.end.x <= b.end.x + 1e-4 and a.position.z >= b.position.z - 1e-4 and a.end.z <= b.end.z + 1e-4:
					return true
	return false


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


## A straight road tile (N-S or E-W) on land, or -1.
func _straight_road(ctx: FpContext) -> int:
	var sim := ctx.sim
	for i in sim.active:
		if sim.kind[i] != D.ROAD or sim.terrain[i] == D.WATER or ctx.view.bus_stops.has(i):
			continue
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		if m == RoadTopology.NS or m == RoadTopology.EW:
			return i
	return -1


## A built lot facing its frontage road, standing `off` from the road centre toward it:
## {"pos", "yaw", "tile"}.
func _frontage(ctx: FpContext, off: float) -> Dictionary:
	var sim := ctx.sim
	for i in sim.active:
		if not D.is_zone(sim.kind[i]) or sim.level[i] <= 0 or sim.sites.has(i) or ctx.view.building_aabb(i).size.x <= 0.0:
			continue
		var f := ctx.directory.frontage(i)
		if f < 0:
			continue
		var dir := Vector3(D.tx(i) - D.tx(f), 0, D.ty(i) - D.ty(f))
		var pos := Vector3(D.tx(f), 0, D.ty(f)) + dir * off
		pos.y = ctx.collision.walk_height(pos)
		var hit := ctx.collision.raycast(pos + Vector3.UP * WS.EYE, dir, 0.6, false)
		if not bool(hit["hit"]) or int(hit["tile"]) != i:
			continue
		return {"pos": pos, "yaw": rad_to_deg(atan2(-dir.x, -dir.z)), "tile": i}
	return {}
