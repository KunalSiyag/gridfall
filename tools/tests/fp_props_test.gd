extends SceneTree
## Street props the player's car knocks over (integration feature "props"): the tumble on its own,
## the knockable props and their colliders, a soft hit that holds, a hard hit that knocks a bin
## down (not drawn, no longer blocking, prop_knocked on the bus) and sends a copy tumbling to rest
## on a face on the ground, a second hit on the fallen bin, standing up again only out of sight and
## away from the player, a rebuilt tile, the player's car stopping against a bin it creeps into
## and knocking it flying at speed, the photo shot and teardown.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const TUMBLE := preload("res://scripts/fp/props/tumble.gd")
const PROPS := preload("res://scripts/fp/props/props_feature.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const MODEL := preload("res://scripts/fp/drive/drive_model.gd")
const DT := 1.0 / 60.0
const KMH := WS.M / 3.6
## The car starts this far from the bin toward the road's middle, facing it.
const RUN_UP := 0.28

var fails: Array[String] = []
var ctx: FpContext
var f: FpFeature
var tr: FpFeature
var drive: FpFeature
## [at, kind, speed] of every prop_knocked and [at, speed, what] of every car_impact.
var knocked: Array = []
var impacts: Array = []
## The bin under test: its knockables_near() entry plus "xf" (its placement), "face" (unit, level,
## toward the road) and "along" (unit, level, along the street).
var bin: Dictionary = {}
## Batched bin instances drawn while every bin stands.
var standing: int = 0


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true})
	ctx.player.set_process(false)
	# Street props are drawn on foot only.
	ctx.view.set_fp_mode(true)
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	ctx.collision.rebuild_all()
	tr = K.make_feature(ctx, "traffic")
	f = K.make_feature(ctx, "props")
	drive = K.make_feature(ctx, "drive")
	K.check(fails, f != null and f.feature_id() == "props", "the props feature is registered")
	if f == null or tr == null or drive == null:
		K.finish(self, "FP_PROPS_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	f.set_process(false)
	drive.set_process(false)
	# The car it takes has nobody at the wheel to pull out (fp_carjack_test covers that).
	FeatureFlags.set_override("carjack", false)
	ctx.bus.prop_knocked.connect(
		func(at: Vector3, kind: String, v: float) -> void: knocked.append([at, kind, v])
	)
	ctx.bus.car_impact.connect(
		func(at: Vector3, v: float, what: String) -> void: impacts.append([at, v, what])
	)
	var st := f.self_test()
	K.check(fails, bool(st.get("ok", false)), "self_test: %s" % st.get("detail", ""))
	_check_tumble()
	bin = _find_bin()
	K.check(fails, not bin.is_empty(), "fixture: a curb bin on a straight road, clear in front")
	if bin.is_empty():
		K.finish(self, "FP_PROPS_TEST", fails)
		return
	standing = _instances("bin")
	_check_listing()
	_check_hold()
	_check_knock()
	_check_rest()
	_check_kick()
	_check_respawn()
	_check_rebuild()
	_check_car()
	_check_photo()
	_check_teardown()
	K.finish(self, "FP_PROPS_TEST", fails)


# ------------------------------------------------------------------ the tumble alone


## On flat ground: a 1 m box hit at 5 m/s flies, tips over and rests on a face with its lowest
## point on the ground, down the push; a wall 1 m off stops it.
func _check_tumble() -> void:
	var flat := func(_p: Vector3) -> float: return 0.0
	var open := func(_p: Vector3, _r: float, _h: float) -> bool: return false
	var bb := AABB(Vector3(-0.3, 0.0, -0.3) * WS.M, Vector3(0.6, 1.0, 0.6) * WS.M)
	var t := TUMBLE.new()
	t.launch(Transform3D(), bb, Vector3(0.0, 0.5, -0.3) * WS.M, Vector3(0.0, 0.0, 5.0 * WS.M))
	var n := _settle(t, flat, open)
	K.check(
		fails,
		t.resting and n < roundi(TUMBLE.MAX_LIFE / DT),
		"tumble: a box hit at 5 m/s comes to rest (%.1f s)" % (n * DT)
	)
	K.check(
		fails,
		_on_face(t) and absf(wrapf(t.angle, -PI, PI)) > 0.1,
		"tumble: tipped over onto a face (%.0f deg)" % rad_to_deg(t.angle)
	)
	K.check(fails, absf(t.pos.y - t.drop()) < 1e-5, "tumble: its lowest point on the ground")
	K.check(
		fails,
		t.pos.z > 1.0 * WS.M and absf(t.pos.x) < 0.2 * WS.M,
		"tumble: down the push (%.1f m on, %.2f m aside)" % [t.pos.z / WS.M, t.pos.x / WS.M]
	)
	var wall := func(p: Vector3, r: float, _h: float) -> bool: return p.z + r > 1.0 * WS.M
	var w := TUMBLE.new()
	w.launch(Transform3D(), bb, Vector3(0.0, 0.5, -0.3) * WS.M, Vector3(0.0, 0.0, 5.0 * WS.M))
	var far := 0.0
	for _k in range(roundi(TUMBLE.MAX_LIFE / DT)):
		if not w.step(DT, flat, wall):
			break
		far = maxf(far, w.pos.z)
	K.check(fails, far < 1.0 * WS.M, "tumble: a wall 1 m off stops it (%.2f m)" % (far / WS.M))
	# A bench-shaped box hit end-on falls over a long side, not onto its end.
	var long := AABB(Vector3(-0.9, 0.0, -0.25) * WS.M, Vector3(1.8, 0.8, 0.5) * WS.M)
	var b := TUMBLE.new()
	b.launch(Transform3D(), long, Vector3(-0.9, 0.4, 0.0) * WS.M, Vector3(5.0 * WS.M, 0.0, 0.0))
	_settle(b, flat, open)
	var up := absf(b.xform().basis.x.normalized().y)
	K.check(
		fails,
		b.resting and _on_face(b) and absf(wrapf(b.angle, -PI, PI)) > 0.1 and up < 0.05,
		"tumble: a long box hit end-on falls over a long side (%.0f deg)" % rad_to_deg(b.angle)
	)


# ------------------------------------------------------------------ the feature


func _check_listing() -> void:
	var i := int(bin["tile"])
	K.check(
		fails,
		bin.has("box") and is_equal_approx(float(bin["mass"]), float(PROPS.KINDS["bin"][0])),
		"a standing bin is listed with its box and a bin's mass"
	)
	K.check(
		fails, ctx.collision.boxes(i).has(bin["box"]), "its box is one of CollisionWorld's boxes"
	)
	var bad: Array[String] = []
	var p := Vector3(D.tx(i), 0.0, D.ty(i))
	for k: Dictionary in f.call("knockables_near", p, 2.0):
		var kind := str(ctx.view.street_placements(int(k["tile"]))[int(k["slot"])][0])
		if not PROPS.KINDS.has(kind):
			bad.append(kind)
	K.check(fails, bad.is_empty(), "lamps, trees, bollards and hydrants are not listed " + str(bad))


func _check_hold() -> void:
	var slow: Vector3 = bin["along"] * (0.5 * WS.M)
	K.check(
		fails,
		not f.call("knock", bin["tile"], bin["slot"], _spot(), slow) and _down().is_empty(),
		"a bin sent off at 0.5 m/s holds"
	)
	K.check(
		fails,
		ctx.collision.boxes(int(bin["tile"])).has(bin["box"]) and knocked.is_empty(),
		"and still blocks, nothing on the bus"
	)


func _check_knock() -> void:
	var fly: Vector3 = bin["along"] * (5.0 * WS.M)
	var parts := (ctx.view.street_kit("bin")["parts"] as Array).size()
	K.check(fails, f.call("knock", bin["tile"], bin["slot"], _spot(), fly), "a hard hit knocks it")
	K.check(
		fails,
		_down().size() == 1 and knocked.size() == 1 and str(knocked[0][1]) == "bin",
		"one bin down, prop_knocked(bin) on the bus (%s)" % str(knocked)
	)
	K.check(
		fails,
		knocked.size() == 1 and absf(float(knocked[0][2]) - 5.0 * WS.M) < 1e-4,
		"at the speed it flies off"
	)
	K.check(
		fails,
		_instances("bin") == standing - parts,
		"the batched bin is not drawn (%d -> %d)" % [standing, _instances("bin")]
	)
	K.check(
		fails,
		not ctx.collision.boxes(int(bin["tile"])).has(bin["box"]),
		"and no longer blocks the walker or the car"
	)
	var listed := _listed()
	K.check(
		fails, not listed.is_empty() and not listed.has("box"), "it is listed fallen, without a box"
	)
	K.check(
		fails,
		not f.call("knock", bin["tile"], bin["slot"], _spot(), fly),
		"hit again at once, it already flies off that fast"
	)


func _check_rest() -> void:
	var t: TUMBLE = _down()[0]["t"]
	var n := 0
	while not t.resting and n < roundi(12.0 / DT):
		f.call("_process", DT)
		n += 1
	var e: Dictionary = _down()[0]
	var node: Node3D = e["node"]
	var low := t.pos.y - t.drop()
	var g := ctx.collision.walk_height(t.pos)
	var moved := Vector2(t.pos.x - _spot().x, t.pos.z - _spot().z).length()
	K.check(fails, t.resting, "the fallen bin comes to rest (%.1f s)" % (n * DT))
	K.check(fails, _on_face(t), "lying on a face (%.0f deg)" % rad_to_deg(t.angle))
	K.check(
		fails,
		not is_nan(g) and absf(low - g) < 1e-4,
		"on the ground (%.3f m off)" % (absf(low - g) / WS.M)
	)
	K.check(fails, moved > 1.0 * WS.M, "away from its place (%.1f m)" % (moved / WS.M))
	K.check(
		fails,
		node.is_inside_tree() and node.transform.is_equal_approx(t.xform()),
		"a copy of its meshes is drawn where it lies"
	)
	K.check(
		fails,
		node.get_child_count() == (ctx.view.street_kit("bin")["parts"] as Array).size(),
		"with every part of the bin"
	)


func _check_kick() -> void:
	var t: TUMBLE = _down()[0]["t"]
	var from := t.pos
	var fly: Vector3 = bin["face"] * (3.0 * WS.M)
	K.check(
		fails,
		f.call("knock", bin["tile"], bin["slot"], t.pos, fly) and not t.resting,
		"the fallen bin hit again moves off"
	)
	K.check(
		fails,
		knocked.size() == 2 and _down().size() == 1,
		"reported again, still one bin down (%d reports)" % knocked.size()
	)
	_settle(t, ctx.collision.walk_height, ctx.collision.body_blocked)
	var moved := Vector2(t.pos.x - from.x, t.pos.z - from.z).length()
	K.check(fails, moved > 0.3 * WS.M, "and comes to rest elsewhere (%.1f m)" % (moved / WS.M))


func _check_respawn() -> void:
	var e: Dictionary = _down()[0]
	var spot := _spot()
	var face: Vector3 = bin["face"]
	var along: Vector3 = bin["along"]
	e["age"] = PROPS.RESPAWN + 1.0
	_stand_at(spot + face * 0.3, spot)
	f.call("_process", DT)
	K.check(fails, _down().size() == 1, "it does not stand up with the player 6 m away")
	var far := spot + face * 0.325 + along * 1.5
	_stand_at(far, spot)
	f.call("_process", DT)
	K.check(fails, _down().size() == 1, "nor in sight of the player 30 m off")
	_stand_at(far, far + (far - spot))
	f.call("_process", DT)
	K.check(fails, _down().is_empty(), "out of sight after %.0f s it stands up" % PROPS.RESPAWN)
	K.check(
		fails,
		_instances("bin") == standing and ctx.collision.boxes(int(bin["tile"])).has(bin["box"]),
		"drawn and blocking in its place again"
	)
	K.check(fails, _listed().has("box"), "and listed standing")


func _check_rebuild() -> void:
	var fly: Vector3 = bin["along"] * (3.0 * WS.M)
	f.call("knock", bin["tile"], bin["slot"], _spot(), fly)
	var node: Node3D = _down()[0]["node"] if not _down().is_empty() else null
	ctx.view._build_tile(int(bin["tile"]), false)
	ctx.view._street.flush()
	K.check(
		fails,
		_down().is_empty() and (node == null or node.is_queued_for_deletion()),
		"a rebuilt tile drops its fallen props"
	)
	bin.merge(_listed(), true)
	K.check(
		fails,
		bin.has("box") and _instances("bin") == standing,
		"and stands them in their places (%d bins drawn)" % _instances("bin")
	)


## The player's car creeping into the bin for 8 s stops against it; at 25 km/h it knocks the bin
## flying ahead of it and drives on.
func _check_car() -> void:
	if not _enter():
		return
	var model: MODEL = drive.get("model")
	var face: Vector3 = bin["face"]
	var start := _spot() + face * RUN_UP
	start.y = ctx.collision.walk_height(start)
	var yaw := atan2(-face.x, -face.z)
	var dims: Vector3 = drive.get("_dims")
	var reports := knocked.size()
	drive.set("_pos", start)
	model.reset(yaw, dims.z)
	for _k in range(roundi(8.0 / DT)):
		model.vel = model.heading() * (2.0 * KMH)
		drive.call("drive_step", 0.0, 0.0, 0.0, 0.0, DT)
	var p: Vector3 = drive.get("_pos")
	var box: AABB = bin["box"]
	var side := (box.get_center() - _spot()).dot(face) + absf(box.size.dot(face)) * 0.5
	var gap := RUN_UP - (start - p).dot(face) - dims.z * 0.5 - side
	K.check(
		fails,
		_down().is_empty() and knocked.size() == reports,
		"a car creeping into the bin at 2 km/h does not knock it over"
	)
	K.check(
		fails,
		absf(gap) < 0.05 * WS.M,
		"it stops against the bin (%.2f m off its side)" % (gap / WS.M)
	)
	drive.set("_pos", start)
	model.reset(yaw, dims.z)
	model.vel = model.heading() * (25.0 * KMH)
	var before := model.speed()
	var hit := -1
	for k in range(roundi(1.5 / DT)):
		drive.call("drive_step", 0.3, 0.0, 0.0, 0.0, DT)
		if hit < 0 and not _down().is_empty():
			hit = k
		if hit >= 0 and k >= hit + 3:
			break
	K.check(
		fails,
		_down().size() == 1 and int(_down()[0]["tile"]) == int(bin["tile"]),
		"at 25 km/h the car knocks the bin over"
	)
	K.check(
		fails,
		knocked.size() == reports + 1 and float(knocked[-1][2]) > 5.0 * WS.M,
		"prop_knocked: it flies off faster than 5 m/s"
	)
	K.check(
		fails,
		model.speed() > 0.7 * before,
		"the car drives on (%.0f -> %.0f km/h)" % [before / KMH, model.speed() / KMH]
	)
	var props_hit := impacts.filter(func(h: Array) -> bool: return str(h[2]) == "prop")
	K.check(fails, props_hit.is_empty(), "car_impact leaves the prop to prop_knocked")
	if not _down().is_empty():
		var t: TUMBLE = _down()[0]["t"]
		K.check(
			fails,
			t.vel.dot(-face) > model.speed() * 0.9,
			"the bin flies ahead of the car (%.1f m/s)" % (t.vel.dot(-face) / WS.M)
		)
	for _k in range(roundi(2.0 / DT)):
		drive.call("drive_step", 0.0, 1.0, 0.0, 0.0, DT)
	drive.call("exit", true)
	f.call("stand_all")


func _check_photo() -> void:
	var shots: Array = f.photo_shots()
	K.check(
		fails,
		shots.size() == 1 and str(shots[0].get("name", "")) == "props",
		'one photo shot, "props"'
	)
	if shots.size() != 1:
		return
	f.call(str(shots[0]["prepare"]))
	var rest: Vector3 = (f.get("_photo") as Dictionary).get("rest", Vector3.ZERO)
	var ok := _down().size() == 1 and (_down()[0]["t"] as TUMBLE).resting
	K.check(fails, ok, "its prepare knocks a prop over, at rest")
	if ok:
		var off := (_down()[0]["t"] as TUMBLE).pos.distance_to(rest)
		K.check(fails, off < 1.0 * WS.M, "where the shot looks (%.2f m off)" % (off / WS.M))
	f.call(str(shots[0]["restore"]))
	K.check(fails, _down().is_empty(), "its restore stands it up again")


func _check_teardown() -> void:
	f.call("knock", bin["tile"], bin["slot"], _spot(), bin["along"] * (3.0 * WS.M))
	f.teardown()
	K.check(
		fails,
		(
			_down().is_empty()
			and _instances("bin") == standing
			and ctx.collision.boxes(int(bin["tile"])).has(bin["box"])
		),
		"teardown stands every fallen prop up again"
	)


# ------------------------------------------------------------------ helpers


func _down() -> Array:
	return f.get("down")


## The bin's base in its place.
func _spot() -> Vector3:
	return (bin["xf"] as Transform3D).origin


## The bin's knockables_near() entry now, or {}.
func _listed() -> Dictionary:
	for k: Dictionary in f.call("knockables_near", _spot(), 0.05):
		if int(k["tile"]) == int(bin["tile"]) and int(k["slot"]) == int(bin["slot"]):
			return k
	return {}


## Batched instances of kind drawn now (every part of every instance).
func _instances(kind: String) -> int:
	var n := 0
	for c: Node in ctx.view._street.root.get_children():
		var mmi := c as MultiMeshInstance3D
		if mmi != null and not mmi.is_queued_for_deletion() and mmi.get_meta("street_kind") == kind:
			n += mmi.multimesh.instance_count
	return n


## The player at p, looking at `look`, the camera placed.
func _stand_at(p: Vector3, look: Vector3) -> void:
	ctx.player.teleport(p, 0.0)
	ctx.player.look_toward(look + Vector3(0, 0.5 * WS.M, 0))
	ctx.player.update_view(DT)


func _settle(t: TUMBLE, floor_at: Callable, blocked: Callable) -> int:
	var n := 0
	while t.step(DT, floor_at, blocked):
		n += 1
	return n


func _on_face(t: TUMBLE) -> bool:
	var q := PI * 0.5
	return absf(t.angle - roundf(t.angle / q) * q) < 1e-3


## A bin in the curb band of a plain straight road whose way in from the road's middle is clear
## for a car; {} when the city has none.
func _find_bin() -> Dictionary:
	for i in range(ctx.sim.kind.size()):
		if ctx.sim.kind[i] != D.ROAD or RoadTopology.is_bridge(ctx.sim, i):
			continue
		var piece := str(RoadTopology.piece(RoadTopology.mask(ctx.sim, D.tx(i), D.ty(i)))[0])
		if piece != "straight" and piece != "lights":
			continue
		for k: Dictionary in f.call("knockables_near", Vector3(D.tx(i), 0.0, D.ty(i)), 0.5):
			var b := _bin_on(i, k)
			if not b.is_empty():
				return b
	return {}


func _bin_on(i: int, k: Dictionary) -> Dictionary:
	if int(k["tile"]) != i or not k.has("box"):
		return {}
	var placed: Array = ctx.view.street_placements(i)[int(k["slot"])]
	if str(placed[0]) != "bin":
		return {}
	var xf: Transform3D = placed[1]
	var face := Vector3(xf.basis.z.x, 0.0, xf.basis.z.z).normalized()
	var across := (xf.origin - Vector3(D.tx(i), xf.origin.y, D.ty(i))).dot(face)
	if absf(absf(across) - 0.325) > 0.01:
		return {}
	var b := k.duplicate()
	b.merge({"xf": xf, "face": face, "along": Vector3(face.z, 0.0, -face.x)})
	return b if _clear_run(b) else {}


## True when nothing but the bin stands in a car's way from RUN_UP out to just past it.
func _clear_run(b: Dictionary) -> bool:
	var i := int(b["tile"])
	var slot := int(b["slot"])
	var face: Vector3 = b["face"]
	var spot := (b["xf"] as Transform3D).origin
	ctx.view.set_street_prop_down(i, slot, true)
	ctx.collision.invalidate(i)
	var ok := true
	var s := -0.06
	while ok and s <= RUN_UP:
		var p := spot + face * s
		var g := ctx.collision.walk_height(p)
		ok = not is_nan(g) and not ctx.collision.body_blocked(Vector3(p.x, g, p.z), 0.06, 0.07)
		s += 0.02
	ctx.view.set_street_prop_down(i, slot, false)
	ctx.collision.invalidate(i)
	return ok


## Gets the hero into a car on the bin's road, every other vehicle gone.
func _enter() -> bool:
	var vh: VH = tr.get("vehicles")
	for c: VH.Car in vh.cars.duplicate():
		vh.remove(c)
	var lg: LG = tr.get("lanes")
	var seq: Array[int] = [int(bin["tile"])]
	var lanes := lg.lanes_along(seq)
	K.check(fails, not lanes.is_empty(), "fixture: a lane on the bin's road")
	if lanes.is_empty():
		return false
	var m: int = tr.call("car_model_for", "props-test")
	var c := vh.make("car", "ambient", tr.call("dims", m))
	c.model = m
	vh.place(c, lanes[0], 0.5)
	c.v = 0.0
	ctx.player.teleport(
		c.pos + Basis(Vector3.UP, c.yaw) * Vector3(c.half_w + 0.6 * WS.M, 0, 0), 0.0
	)
	var ok: bool = drive.call("enter")
	K.check(fails, ok, "fixture: the hero gets into a car")
	return ok
