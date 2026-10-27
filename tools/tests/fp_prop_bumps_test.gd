extends SceneTree
## Knocking street props about on foot and in traffic (props feature, flag prop_bumps) and the
## clutter there is to knock about (street dressing, flag street_clutter). Clutter: cones in threes
## at the curb in front of construction sites, wheelie bins out at homes and cartons by shop doors,
## all knockable and clear of the pedestrian band and the carriageway; none with the flag off,
## the furniture keeping its places. On foot: walking into a bin holds and running into it knocks
## it over, walking into a cone knocks it over, a bench holds at a run; nothing goes over at the
## wheel, for a hero put down beside a prop or with prop_bumps off. A blow with nobody in reach
## (the actions feature) knocks the bin in front over, not one behind or a bench, and knocks a
## fallen one along. The hero, someone walking and a car in traffic kick fallen props along, and a
## cone skidding into the next one knocks it over.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const SD := preload("res://scripts/fp/street/street_dressing.gd")
const TUMBLE := preload("res://scripts/fp/props/tumble.gd")
const PROPS := preload("res://scripts/fp/props/props_feature.gd")
const ACTIONS := preload("res://scripts/fp/actions/actions_feature.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const FIX := preload("res://tools/tests/support/props_fixture.gd")
const DT := 1.0 / 60.0
const KMH := WS.M / 3.6
const CLUTTER := ["cone", "wheelie", "carton"]
## The hero starts this far (u) from a prop's place, on the pedestrian band's side of it.
const APPROACH := 0.06
## A blow: the hero stands this far (u) from the prop's place.
const BLOW_AT := 0.04

var fails: Array[String] = []
var ctx: FpContext
var f: FpFeature
var tr: FpFeature
var act: FpFeature
## [at, kind, speed] of every prop_knocked.
var knocked: Array = []


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("prop_bumps", true)
	FeatureFlags.set_override("street_clutter", true)
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	ctx.view.set_fp_mode(true)
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	ctx.collision.rebuild_all()
	tr = K.make_feature(ctx, "traffic")
	f = K.make_feature(ctx, "props")
	act = K.make_feature(ctx, "actions")
	if tr == null or f == null or act == null:
		K.check(fails, false, "the traffic, props and actions features are registered")
		K.finish(self, "FP_PROP_BUMPS_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	f.set_process(false)
	act.set_process(false)
	_quiet()
	ctx.bus.prop_knocked.connect(
		func(at: Vector3, kind: String, v: float) -> void: knocked.append([at, kind, v])
	)
	_check_clutter()
	_check_clutter_flag()
	var bin := _find("bin")
	var row := _cone_row()
	K.check(fails, not bin.is_empty(), "fixture: a curb bin the hero can walk straight into")
	K.check(
		fails, not row.is_empty(), "fixture: a row of cones the hero can walk into the middle of"
	)
	if not bin.is_empty() and not row.is_empty():
		_check_walk_into(bin, row[1])
		_check_not_on_foot(row[1])
		_check_blows(bin)
		_check_hero_kick(bin)
		_check_walker_kick(bin)
		_check_car_kick(bin)
		_check_chain(row)
	K.finish(self, "FP_PROP_BUMPS_TEST", fails)


# ------------------------------------------------------------------ clutter


func _check_clutter() -> void:
	var items := _clutter_items()
	var n := {"cone": 0, "wheelie": 0, "carton": 0}
	for it: Dictionary in items:
		n[it["kind"]] = int(n[it["kind"]]) + 1
	K.check(
		fails,
		int(n["cone"]) >= 3 and int(n["wheelie"]) >= 1 and int(n["carton"]) >= 1,
		"the city has cones, wheelie bins and cartons on its sidewalks (%s)" % str(n)
	)
	var bad: Array = []
	for it: Dictionary in items:
		if not _placed_right(it):
			bad.append([it["kind"], it["tile"], snappedf(float(it["across"]), 0.001)])
	K.check(
		fails,
		bad.is_empty(),
		"cones at the curb by sites, wheelie bins at the curb of homes, cartons by shops %s" % [bad]
	)
	var rows := _cone_rows()
	var odd: Array = []
	for key: String in rows:
		var row: Array = rows[key]
		var gap := _along_gap(row)
		if row.size() != 3 or absf(gap - SD.CONE_GAP) > 1e-4:
			odd.append([key, row.size(), gap])
	K.check(fails, odd.is_empty(), "cones stand in threes, CONE_GAP apart %s" % [odd])
	_check_clutter_room(items)


## Every clutter item is listed knockable with its kind's mass and keeps out of the pedestrian
## band and off the carriageway.
func _check_clutter_room(items: Array[Dictionary]) -> void:
	var unlisted: Array = []
	var in_way: Array = []
	for it: Dictionary in items:
		var k := _listed(it)
		if k.is_empty() or not is_equal_approx(float(k["mass"]), float(PROPS.KINDS[it["kind"]][0])):
			unlisted.append([it["kind"], it["tile"]])
			continue
		var span := _span(it, k)
		var band: Array = WS.PED_BAND
		var clear := span.y <= float(band[0]) or span.x >= float(band[1])
		if span.x < WS.SIDEWALK_INNER or not clear:
			in_way.append([it["kind"], it["tile"], span])
	K.check(fails, unlisted.is_empty(), "every clutter item is a knockable prop %s" % [unlisted])
	K.check(
		fails,
		in_way.is_empty(),
		"clutter keeps out of the pedestrian band and off the carriageway %s" % [in_way]
	)


## street_clutter off: the tiles with clutter are drawn again without it, every other item in its
## place; back on, the same clutter returns.
func _check_clutter_flag() -> void:
	var tiles := {}
	for it: Dictionary in _clutter_items():
		tiles[int(it["tile"])] = true
	var before := {}
	for i: int in tiles:
		before[i] = (ctx.view.street_placements(i) as Array).duplicate()
	FeatureFlags.set_override("street_clutter", false)
	_rebuild(tiles.keys())
	var left := 0
	var moved: Array[int] = []
	for i: int in tiles:
		var now: Array = ctx.view.street_placements(i)
		var kept := (before[i] as Array).filter(
			func(p: Array) -> bool: return not CLUTTER.has(str(p[0]))
		)
		left += now.size() - kept.size()
		if not _same(now, kept):
			moved.append(i)
	K.check(
		fails, left == 0 and not tiles.is_empty(), "street_clutter off: no clutter (%d left)" % left
	)
	K.check(fails, moved.is_empty(), "and the furniture keeps its places %s" % [moved])
	FeatureFlags.set_override("street_clutter", true)
	_rebuild(tiles.keys())
	var back: Array[int] = []
	for i: int in tiles:
		if not _same(ctx.view.street_placements(i), before[i]):
			back.append(i)
	K.check(fails, back.is_empty(), "back on, the same clutter returns %s" % [back])


## True when clutter item it stands where its kind belongs: a cone at the curb in front of a
## construction site, a wheelie bin at the curb of a home, a carton by a shop's door.
func _placed_right(it: Dictionary) -> bool:
	var i := int(it["tile"])
	var out: Vector3 = it["out"]
	var x := D.tx(i) + roundi(out.x)
	var y := D.ty(i) + roundi(out.z)
	var j := D.idx(x, y)
	var across := float(it["across"])
	match str(it["kind"]):
		"cone":
			return absf(across - SD.CURB) < 1e-4 and ctx.sim.sites.has(j)
		"wheelie":
			var home := ctx.sim.kind[j] == D.ZONE_R and ctx.sim.level[j] > 0
			return absf(across - SD.CURB) < 1e-4 and home and not ctx.sim.sites.has(j)
		"carton":
			var shop := ctx.sim.kind[j] == D.ZONE_C and ctx.sim.level[j] > 0
			return absf(across - SD.FRONT) < 1e-4 and shop
	return false


# ------------------------------------------------------------------ on foot


## Walking into a bin holds (the hero stops against it), running into it knocks it over the way
## the hero ran; walking into a cone knocks it over; a bench holds at a run.
func _check_walk_into(bin: Dictionary, cone: Dictionary) -> void:
	var to := _toward(bin)
	_walk(bin["from"], to, WS.WALK, 1.5, _is_down.bind(bin))
	K.check(
		fails, not _is_down(bin) and knocked.is_empty(), "walking into a bin does not knock it over"
	)
	var gap := _gap_to(bin) - WS.PLAYER_RADIUS
	K.check(fails, gap < 0.1 * WS.M, "the hero stops against it (%.2f m off)" % (gap / WS.M))
	_walk(bin["from"], to, WS.RUN, 1.5, _is_down.bind(bin))
	K.check(fails, _is_down(bin), "running into it knocks it over")
	K.check(
		fails,
		knocked.size() == 1 and str(knocked[0][1]) == "bin",
		"prop_knocked(bin) on the bus (%s)" % [knocked]
	)
	if _is_down(bin):
		var t: TUMBLE = _entry(bin)["t"]
		var v := Vector3(t.vel.x, 0.0, t.vel.z).dot(to)
		K.check(fails, v > 2.0 * WS.M, "it flies off the way the hero ran (%.1f m/s)" % (v / WS.M))
	_reset()
	_walk(cone["from"], _toward(cone), WS.WALK, 1.5, _is_down.bind(cone))
	K.check(fails, _is_down(cone), "walking into a traffic cone knocks it over")
	_reset()
	var bench := _find("bench")
	K.check(fails, not bench.is_empty(), "fixture: a bench the hero can run into")
	if not bench.is_empty():
		_walk(bench["from"], _toward(bench), WS.RUN, 1.5, _is_down.bind(bench))
		K.check(
			fails,
			not _is_down(bench) and knocked.is_empty(),
			"a bench holds against a running hero"
		)
	_reset()


## Nothing goes over for a hero put down touching a cone straight from a run elsewhere, nor at
## the wheel; on foot again the same push knocks it; with prop_bumps off neither a run nor a blow
## does.
func _check_not_on_foot(cone: Dictionary) -> void:
	var to := _toward(cone)
	var spot: Vector3 = cone["spot"]
	var p := ctx.player
	p.teleport(spot - to * 0.11, rad_to_deg(atan2(-to.x, -to.z)))
	p.velocity = to * WS.RUN
	f.call("_process", DT)
	p.teleport(spot - to * (WS.PLAYER_RADIUS + 0.01), rad_to_deg(atan2(-to.x, -to.z)))
	f.call("_process", DT)
	K.check(
		fails, not _is_down(cone), "a hero put down touching a cone from a run does not knock it"
	)
	ctx.bus.drive_changed.emit(true)
	p.velocity = to * WS.RUN
	f.call("_process", DT)
	K.check(fails, not _is_down(cone), "nor at the wheel")
	ctx.bus.drive_changed.emit(false)
	f.call("_process", DT)
	K.check(fails, _is_down(cone), "on foot again, the same push knocks it over")
	_reset()
	FeatureFlags.set_override("prop_bumps", false)
	_walk(cone["from"], to, WS.RUN, 1.0, _is_down.bind(cone))
	var struck: bool = f.call("strike", p.position, to, ACTIONS.REACH, ACTIONS.CONE, 1.0)
	K.check(
		fails,
		not _is_down(cone) and not struck and knocked.is_empty(),
		"prop_bumps off: neither a run into a cone nor a blow knocks it"
	)
	FeatureFlags.set_override("prop_bumps", true)
	_reset()


# ------------------------------------------------------------------ blows


## A punch with nobody in reach lands on the bin in front: it goes over, away from the hero, and
## the actions feature counts a blow on a prop; facing away, or facing a bench, nothing; a punch at
## a fallen bin knocks it along.
func _check_blows(bin: Dictionary) -> void:
	var to := _toward(bin)
	var spot: Vector3 = bin["spot"]
	_face(spot - to * BLOW_AT, to)
	_punch()
	K.check(fails, _is_down(bin), "a punch with nobody in reach knocks the bin in front over")
	K.check(
		fails,
		int(act.get("prop_hits")) == 1 and int(act.get("hits")) == 0,
		(
			"the actions feature counts a blow on a prop (%d), none on people"
			% int(act.get("prop_hits"))
		)
	)
	if _is_down(bin):
		var t: TUMBLE = _entry(bin)["t"]
		var v := Vector3(t.vel.x, 0.0, t.vel.z).dot(to)
		K.check(fails, v > 1.0 * WS.M, "it flies off away from the hero (%.1f m/s)" % (v / WS.M))
		_settle()
		var from := t.pos
		_face(from - to * BLOW_AT, to)
		_punch()
		var moved := Vector3(t.pos.x - from.x, 0.0, t.pos.z - from.z).dot(to)
		K.check(
			fails,
			int(act.get("prop_hits")) == 2 and (not t.resting or moved > 0.0),
			"a punch at the fallen bin knocks it along"
		)
	_reset()
	var landed := int(act.get("prop_hits"))
	_face(spot - to * BLOW_AT, -to)
	_punch()
	K.check(
		fails,
		not _is_down(bin) and int(act.get("prop_hits")) == landed,
		"nor a bin behind the hero"
	)
	var bench := _find("bench")
	if not bench.is_empty():
		var bt := _toward(bench)
		_face((bench["spot"] as Vector3) - bt * BLOW_AT, bt)
		_punch()
		K.check(
			fails,
			not _is_down(bench) and int(act.get("prop_hits")) == landed,
			"a bench in reach takes no blow (it holds against people)"
		)
	_reset()


# ------------------------------------------------------------------ fallen props


## The hero running into a fallen bin kicks it along.
func _check_hero_kick(bin: Dictionary) -> void:
	# The hero steps clear first: the lying box is written only once no body stands within it.
	var clear_of: Vector3 = bin["spot"]
	ctx.player.teleport(Vector3(clear_of.x + 0.5, clear_of.y, clear_of.z), 0.0)
	var t := _fell(bin)
	if t == null:
		return
	var from := t.pos
	var dir := _clear_dir(from, FIX.lying_box(ctx, int(bin["tile"]), int(bin["slot"])))
	K.check(fails, dir != Vector3.ZERO, "fixture: a clear run at the fallen bin")
	if dir == Vector3.ZERO:
		_reset()
		return
	_walk(from - dir * APPROACH, dir, WS.RUN, 1.0, func() -> bool: return not t.resting)
	var peak := Vector3(t.vel.x, 0.0, t.vel.z).dot(dir)
	_settle()
	var moved := Vector3(t.pos.x - from.x, 0.0, t.pos.z - from.z).dot(dir)
	K.check(
		fails,
		peak > 1.0 * WS.M and moved > 0.3 * WS.M,
		(
			"the hero running into the fallen bin kicks it along (%.1f m/s, %.1f m on)"
			% [peak / WS.M, moved / WS.M]
		)
	)
	_reset()


## Someone walking into a fallen bin kicks it along.
func _check_walker_kick(bin: Dictionary) -> void:
	var t := _fell(bin)
	if t == null:
		return
	var from := t.pos
	var dir := _clear_dir(from, FIX.lying_box(ctx, int(bin["tile"]), int(bin["slot"])))
	if dir == Vector3.ZERO:
		dir = Vector3(1.0, 0.0, 0.0)
	var side := Vector3(dir.z, 0.0, -dir.x)
	ctx.player.teleport(from + side * 0.2, 0.0)
	var wk: WK = tr.get("walkers")
	var w := wk.make("ambient")
	w.extra = 0
	var start := _on_ground(from - dir * 0.04)
	wk.stand(w, start, atan2(dir.x, dir.z))
	wk.start_plan(w, [{"pt": _on_ground(from + dir * 0.06)}])
	var peak := 0.0
	for _k in range(roundi(3.0 / DT)):
		tr.call("step", DT)
		f.call("_process", DT)
		peak = maxf(peak, Vector3(t.vel.x, 0.0, t.vel.z).dot(dir))
	var moved := Vector3(t.pos.x - from.x, 0.0, t.pos.z - from.z).dot(dir)
	K.check(
		fails,
		peak > 0.5 * WS.M and moved > 0.0,
		(
			"someone walking into the fallen bin kicks it along (%.1f m/s, %.2f m on)"
			% [peak / WS.M, moved / WS.M]
		)
	)
	_quiet()
	_reset()


## A car in traffic running into a fallen bin sends it flying ahead of it.
func _check_car_kick(bin: Dictionary) -> void:
	var t := _fell(bin)
	if t == null:
		return
	var c := _lane_car(int(bin["tile"]))
	K.check(fails, c != null, "fixture: a car alone on a lane of the bin's road")
	if c == null:
		_reset()
		return
	var h := OBB.heading(c.yaw)
	var head := Vector3(h.x, 0.0, h.y)
	# The car's nose just reaches the bin where it lies.
	c.pos = Vector3(t.pos.x, c.pos.y, t.pos.z) - head * (c.length * 0.5 + 0.005)
	c.v = 30.0 * KMH
	c.vel = head * c.v
	ctx.player.teleport(t.pos + Vector3(head.z, 0.0, -head.x) * 0.2, 0.0)
	knocked.clear()
	f.call("_process", DT)
	var v := Vector3(t.vel.x, 0.0, t.vel.z).dot(head)
	K.check(
		fails,
		v > c.v and not knocked.is_empty(),
		"a car in traffic kicks the fallen bin ahead of it (%.1f m/s)" % (v / WS.M)
	)
	(tr.get("vehicles") as VH).remove(c)
	_reset()


## The end cone of a row knocked toward the middle one skids into it and knocks it over.
func _check_chain(row: Array) -> void:
	var a: Dictionary = row[0]
	var b: Dictionary = row[1]
	var dir := ((b["spot"] as Vector3) - (a["spot"] as Vector3)).normalized()
	f.call("knock", a["tile"], a["slot"], a["spot"], dir * (4.0 * WS.M))
	for _k in range(roundi(2.0 / DT)):
		if _is_down(b):
			break
		f.call("_process", DT)
	K.check(fails, _is_down(a) and _is_down(b), "a cone skidding into the next knocks it over")
	var cones := knocked.filter(func(k: Array) -> bool: return str(k[1]) == "cone")
	K.check(fails, cones.size() >= 2, "both on the bus (%d cone reports)" % cones.size())
	_reset()


# ------------------------------------------------------------------ helpers


## The hero from `from` heading along the level unit dir at speed (u/s; a run above WS.WALK) for
## at most secs, the props feature looking each frame, until done() is true.
func _walk(from: Vector3, dir: Vector3, speed: float, secs: float, done: Callable) -> void:
	var p := ctx.player
	p.teleport(from, rad_to_deg(atan2(-dir.x, -dir.z)))
	p.velocity = dir * speed
	for _k in range(roundi(secs / DT)):
		if bool(done.call()):
			return
		p.simulate(Vector2(0.0, 1.0), speed > WS.WALK, DT)
		f.call("_process", DT)


## The hero standing at p, body and view along the level unit dir.
func _face(p: Vector3, dir: Vector3) -> void:
	ctx.player.teleport(p, rad_to_deg(atan2(-dir.x, -dir.z)))
	ctx.player.update_view(DT)


## A punch (the combo's jab or cross), stepped until the swing is over.
func _punch() -> void:
	K.check(fails, bool(act.call("strike", "punch")), "fixture: the hero throws a punch")
	for _k in range(roundi(1.0 / DT)):
		act.call("tick", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)
		if str(act.get("swing")) == "":
			return


## Every fallen prop at rest.
func _settle() -> void:
	for _k in range(roundi(TUMBLE.MAX_LIFE / DT)):
		var moving := false
		for e: Dictionary in f.get("down"):
			moving = moving or not (e["t"] as TUMBLE).resting
		if not moving:
			return
		f.call("_process", DT)


## Knocks it over toward the road and lets it come to rest: its tumble, null when it holds.
func _fell(it: Dictionary) -> TUMBLE:
	var fly := -(it["out"] as Vector3) * (3.0 * WS.M)
	if not bool(f.call("knock", it["tile"], it["slot"], it["spot"], fly)):
		K.check(fails, false, "fixture: the bin goes over")
		return null
	_settle()
	knocked.clear()
	return _entry(it)["t"]


## Every prop stands, the bus record empty.
func _reset() -> void:
	f.call("stand_all")
	knocked.clear()


## A car alone in traffic, on a lane of road tile i; null when the road has none.
func _lane_car(i: int) -> VH.Car:
	var vh: VH = tr.get("vehicles")
	for old: VH.Car in vh.cars.duplicate():
		vh.remove(old)
	var tiles: Array[int] = [i]
	var lanes := (tr.get("lanes") as LG).lanes_along(tiles)
	if lanes.is_empty():
		return null
	var m: int = tr.call("car_model_for", "prop-bumps-test")
	var c := vh.make("car", "ambient", tr.call("dims", m))
	c.model = m
	vh.place(c, lanes[0], 0.5)
	return c


## Removes every walker, so only the test's own people are about.
func _quiet() -> void:
	var wk: WK = tr.get("walkers")
	for w: WK.Walker in wk.walkers.duplicate():
		wk.remove(w)


func _rebuild(tiles: Array) -> void:
	for i: int in tiles:
		ctx.view._build_tile(i, false)
	ctx.view._street.flush()


## True when placement lists a and b hold the same kinds at the same transforms.
func _same(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for k in range(a.size()):
		if str(a[k][0]) != str(b[k][0]):
			return false
		if not (a[k][1] as Transform3D).is_equal_approx(b[k][1]):
			return false
	return true


func _on_ground(p: Vector3) -> Vector3:
	var g := ctx.collision.walk_height(p)
	return Vector3(p.x, g if not is_nan(g) else p.y, p.z)


func _entry(it: Dictionary) -> Dictionary:
	for e: Dictionary in f.get("down"):
		if int(e["tile"]) == int(it["tile"]) and int(e["slot"]) == int(it["slot"]):
			return e
	return {}


func _is_down(it: Dictionary) -> bool:
	return not _entry(it).is_empty()


## Item it's knockables_near() entry while it stands, or {}.
func _listed(it: Dictionary) -> Dictionary:
	for k: Dictionary in f.call("knockables_near", it["spot"], 0.02):
		if int(k["tile"]) == int(it["tile"]) and int(k["slot"]) == int(it["slot"]):
			return k if not k.has("down") else {}
	return {}


## How far the hero's feet are from the side of item it (u).
func _gap_to(it: Dictionary) -> float:
	var k := _listed(it)
	var c := Vector2(ctx.player.position.x, ctx.player.position.z)
	if k.has("box"):
		var b: AABB = k["box"]
		var lo := Vector2(b.position.x, b.position.z)
		return c.clamp(lo, lo + Vector2(b.size.x, b.size.z)).distance_to(c)
	return (k["c"] as Vector2).distance_to(c) - float(k["r"])


## The nearest and furthest item it reaches across from its road's middle (u).
func _span(it: Dictionary, k: Dictionary) -> Vector2:
	var out: Vector3 = it["out"]
	var mid := Vector3(D.tx(int(it["tile"])), 0.0, D.ty(int(it["tile"])))
	if k.has("box"):
		var b: AABB = k["box"]
		var lo := (b.position - mid).dot(out)
		var hi := (b.end - mid).dot(out)
		return Vector2(minf(lo, hi), maxf(lo, hi))
	var c: Vector2 = k["c"]
	var at := (Vector3(c.x, 0.0, c.y) - mid).dot(out)
	return Vector2(at - float(k["r"]), at + float(k["r"]))


## The level unit direction from the pedestrian band toward item it: roadward for a curb item,
## toward the lot for one by the lot's edge.
func _toward(it: Dictionary) -> Vector3:
	var out: Vector3 = it["out"]
	return -out if float(it["across"]) < float(WS.PED_BAND[0]) else out


## Street prop `slot` of straight road tile i: {"tile", "slot", "kind", "spot" (its place),
## "out" (level unit from the road's middle toward its side), "along", "across" (u from the
## middle)}.
func _item(i: int, slot: int) -> Dictionary:
	var placed: Array = ctx.view.street_placements(i)[slot]
	var spot := (placed[1] as Transform3D).origin
	var local := spot - Vector3(D.tx(i), 0.0, D.ty(i))
	var ew := (RoadTopology.mask(ctx.sim, D.tx(i), D.ty(i)) & RoadTopology.NS) == 0
	var out := Vector3(0.0, 0.0, signf(local.z)) if ew else Vector3(signf(local.x), 0.0, 0.0)
	var it := {"tile": i, "slot": slot, "kind": str(placed[0]), "spot": spot, "out": out}
	it.merge({"along": Vector3(out.z, 0.0, -out.x), "across": local.dot(out)})
	return it


## Straight, non-bridge road tiles.
func _straights() -> Array[int]:
	var out: Array[int] = []
	for i in range(ctx.sim.kind.size()):
		if ctx.sim.kind[i] != D.ROAD or RoadTopology.is_bridge(ctx.sim, i):
			continue
		var piece := str(RoadTopology.piece(RoadTopology.mask(ctx.sim, D.tx(i), D.ty(i)))[0])
		if piece == "straight" or piece == "lights":
			out.append(i)
	return out


func _clutter_items() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i: int in _straights():
		var placed: Array = ctx.view.street_placements(i)
		for s in range(placed.size()):
			if CLUTTER.has(str(placed[s][0])):
				out.append(_item(i, s))
	return out


## The cones on each side of each tile ("tile:out" -> items in order along the street).
func _cone_rows() -> Dictionary:
	var rows := {}
	for it: Dictionary in _clutter_items():
		if str(it["kind"]) != "cone":
			continue
		var key := "%d:%s" % [int(it["tile"]), str(it["out"])]
		if not rows.has(key):
			rows[key] = []
		(rows[key] as Array).append(it)
	for key: String in rows:
		(rows[key] as Array).sort_custom(_before)
	return rows


func _before(a: Dictionary, b: Dictionary) -> bool:
	var along: Vector3 = a["along"]
	return (a["spot"] as Vector3).dot(along) < (b["spot"] as Vector3).dot(along)


## The along-street gap between neighbours of a row (the largest; 0 for fewer than two).
func _along_gap(row: Array) -> float:
	var gap := 0.0
	for k in range(1, row.size()):
		var d: Vector3 = (row[k]["spot"] as Vector3) - (row[k - 1]["spot"] as Vector3)
		gap = maxf(gap, absf(d.dot(row[k]["along"])))
	return gap


## The first row of three cones whose middle one the hero can walk straight into (each item with
## "from" where to start), [] when there is none.
func _cone_row() -> Array:
	var rows := _cone_rows()
	for key: String in rows:
		var row: Array = rows[key]
		if row.size() != 3:
			continue
		var from := _approach(row[1])
		if not is_nan(from.x):
			(row[1] as Dictionary)["from"] = from
			return row
	return []


## The first standing prop of kind on a straight that the hero can walk straight into from the
## pedestrian band (its item with "from"), {} when there is none.
func _find(kind: String) -> Dictionary:
	for i: int in _straights():
		var placed: Array = ctx.view.street_placements(i)
		for s in range(placed.size()):
			if str(placed[s][0]) != kind:
				continue
			var it := _item(i, s)
			var from := _approach(it)
			if not is_nan(from.x):
				it["from"] = from
				return it
	return {}


## Where the hero starts to walk straight into item it, APPROACH from its place on the pedestrian
## band's side; NAN when anything but the item stands in the way.
func _approach(it: Dictionary) -> Vector3:
	var to := _toward(it)
	var start: Vector3 = (it["spot"] as Vector3) - to * APPROACH
	var i := int(it["tile"])
	ctx.view.set_street_prop_down(i, int(it["slot"]), true)
	ctx.collision.invalidate(i)
	var ok := _clear(start, to, APPROACH)
	ctx.view.set_street_prop_down(i, int(it["slot"]), false)
	ctx.collision.invalidate(i)
	return start if ok else Vector3(NAN, NAN, NAN)


## True when the hero can walk len (u) from p along dir on walkable ground with nothing in the way.
func _clear(p: Vector3, dir: Vector3, len: float) -> bool:
	var s := 0.0
	while s <= len + 1e-6:
		var q := p + dir * s
		var g := ctx.collision.walk_height(q)
		if is_nan(g):
			return false
		if ctx.collision.body_blocked(Vector3(q.x, g, q.z), WS.PLAYER_RADIUS, WS.PLAYER_HEIGHT):
			return false
		s += 0.005
	return true


## A level axis direction the hero can run along through p from APPROACH back to the fallen
## bin's lying box (its face ends the run: the box is the target, not an obstacle), or zero.
func _clear_dir(p: Vector3, lying: AABB) -> Vector3:
	for d: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]:
		var face := absf(d.x) * lying.size.x * 0.5 + absf(d.z) * lying.size.z * 0.5
		if _clear(p - d * APPROACH, d, APPROACH - face - WS.PLAYER_RADIUS):
			return d
	return Vector3.ZERO
