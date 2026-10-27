extends SceneTree
## Perched birds (the animals feature; docs/fp/ARCHITECTURE.md, Animals): by day a street lamp or
## a built lot's roof edge near the player gets its perch flock, one MultiMesh of the pigeon with
## a bird on each fixed point above the street, from a fresh city's City Hall; the hero walking
## below and a car passing under never stir them; a shout below, or the hero's car horn, sends
## them up together with one clatter of wings, and they wheel over the roofs and glide back onto
## their own points, while a horn out of earshot leaves them be, and in the rain there is nothing
## to flush; beyond FAR they go and come back to the same points; by night none comes out; the
## flag off takes them away; self_test and teardown. Third person on a grown city; time runs
## through the feature's tick(1/60) and traffic's step.

const K := preload("res://tools/tests/fp_kit.gd")
const FRESH := preload("res://tools/tests/fp_fresh_city.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AF := preload("res://scripts/fp/animals/animals_feature.gd")
const PR := preload("res://scripts/fp/animals/perches.gd")
const FLOCK := preload("res://scripts/fp/animals/pigeon_flock.gd")
const DRIVE := preload("res://scripts/fp/drive/drive_feature.gd")
const DT := 1.0 / 60.0
## How long the flock may take to wheel and come back down (s).
const LAND_S := 30.0

var fails: Array[String] = []
var ctx: FpContext
var traffic: FpFeature
var f: FpFeature
var pr: PR
var fl: FLOCK
## The perch spot the test's flock keeps to (perches.gd _spot_of()), with where the player stands
## by it, and the flock's key.
var spot: Dictionary = {}
var key: String = ""
## Every animal_called call.
var calls: Array = []


func _init() -> void:
	await process_frame
	var fx := FRESH.open_grown(self, "FP_PERCHES_TEST", fails, calls)
	if fx.is_empty():
		return
	ctx = fx["ctx"]
	traffic = fx["traffic"]
	f = fx["animals"]
	pr = fx["perches"]
	fl = pr.flock
	spot = _perch_spot()
	K.check(fails, not spot.is_empty(), "fixture: a perch spot in the grown city")
	if not spot.is_empty():
		key = str(spot["key"])
		ctx.player.teleport(spot["stand"], 0.0)
		_step(AF.SCAN_S + 0.1)
		_check_spawn()
		_check_roof_flat()
		_check_still()
		_check_car()
		_check_shout()
		_check_horn()
		_check_far()
		_check_night()
		_check_rain()
		_check_horn_rain()
		_check_flag()
	_check_fresh_city()
	_check_teardown()
	K.finish(self, "FP_PERCHES_TEST", fails)


# ------------------------------------------------------------------ helpers


## Steps traffic and the animals feature secs (in 1/60 s steps).
func _step(secs: float) -> void:
	FRESH.step(traffic, f, secs)


## The first perch spot of the grown city (a street's lamp or a built lot's roof edge), with where
## the player stands by it (the shared fixture in fp_fresh_city.gd).
func _perch_spot() -> Dictionary:
	return FRESH.perch_spot(ctx, pr)


func _flock() -> FLOCK.Flock:
	for fk: FLOCK.Flock in fl.flocks:
		if fk.key == key:
			return fk
	return null


## Steps until every bird of fk is back on its perch with no take-off pending (at most LAND_S);
## the seconds it took, or -1.
func _wait_perched(fk: FLOCK.Flock) -> float:
	var t := 0.0
	while t <= LAND_S:
		var back := true
		for b: FLOCK.Bird in fk.birds:
			back = back and not b.air and b.delay <= 0.0 and b.pos.distance_to(b.goal) < 1e-6
		if back:
			return t
		_step(0.25)
		t += 0.25
	return -1.0


func _count(c: String) -> int:
	return calls.filter(func(e: String) -> bool: return e == c).size()


# ------------------------------------------------------------------ checks


## By day the spot's flock comes out, its birds sitting each on one point well above the street
## and one MultiMesh of the pigeon drawing them.
func _check_spawn() -> void:
	var fk := _flock()
	var pts: PackedVector3Array = spot["points"]
	var n := pts.size() if fk == null else fk.birds.size()
	K.check(fails, fk != null and n >= 1, "spawn: the spot's flock comes out (%d birds)" % n)
	if fk == null:
		return
	var sit := n == pts.size()
	for b: FLOCK.Bird in fk.birds:
		var g := ctx.collision.walk_height(Vector3(b.pos.x, 0.0, b.pos.z))
		sit = sit and not b.air and b.pos.distance_to(b.goal) < 1e-6
		sit = sit and not is_nan(g) and b.pos.y - g >= 2.0 * WS.M
	K.check(fails, sit, "spawn: each bird sits on its point, above the street")
	var mi := fk.node as MultiMeshInstance3D
	var drawn := mi != null and mi.multimesh.instance_count == fk.birds.size()
	K.check(fails, drawn, "spawn: one MultiMesh of the pigeon with a bird a point")


## A roof-edge perch: every point stands on the horizontal top of the roof block (its y is the
## block's top, or a parapet or coping at most ROOF_LIFT_MAX above it), inset from the block's
## footprint, so no bird is left on the wall face of a facade or a ledge band.
func _check_roof_flat() -> void:
	var roof := _roof_spot()
	K.check(fails, not roof.is_empty(), "roof: a roof-edge perch in the grown city")
	if roof.is_empty():
		return
	var top := AABB()
	for b: AABB in ctx.collision.body_boxes(int(roof["tile"])):
		if b.size.x < PR.MIN_BLOCK or b.size.z < PR.MIN_BLOCK:
			continue
		if top.size.x <= 0.0 or b.end.y > top.end.y:
			top = b
	var on_top := top.size.x > 0.0
	var lift := 0.0
	for p: Vector3 in roof["points"] as PackedVector3Array:
		on_top = on_top and p.y >= top.end.y - 1e-6 and p.y <= top.end.y + PR.ROOF_LIFT_MAX + 1e-6
		on_top = on_top and p.x > top.position.x and p.x < top.end.x
		on_top = on_top and p.z > top.position.z and p.z < top.end.z
		lift = maxf(lift, p.y - top.end.y)
	K.check(
		fails,
		on_top,
		(
			"roof: each point stands on the block's horizontal top (lift %.4f, inset from the lip)"
			% lift
		)
	)


## The first roof-edge spot of the grown city (with its tile), else {}.
func _roof_spot() -> Dictionary:
	for i in range(ctx.sim.kind.size()):
		var s: Dictionary = pr.call("_spot_of", i)
		if not s.is_empty() and str(s["key"]).begins_with("roof:"):
			s["tile"] = i
			return s
	return {}


## The hero walking to and fro right under the perch never stirs the flock.
func _check_still() -> void:
	var fk := _flock()
	if fk == null:
		return
	var under := Vector3(fk.home.x, 0.0, fk.home.z)
	var g := ctx.collision.walk_height(under)
	under.y = g if not is_nan(g) else 0.0
	ctx.player.teleport(under, 0.0)
	ctx.player.velocity = Vector3(1.45 * WS.M, 0.0, 0.0)
	_step(2.0)
	ctx.player.velocity = Vector3.ZERO
	var sit := true
	for b: FLOCK.Bird in fk.birds:
		sit = sit and not b.air and b.pos.distance_to(b.goal) < 1e-6
	K.check(fails, sit, "still: the hero walking below never stirs them")


## A car driving through under the perch, and a person walking under it, never send the flock up.
func _check_car() -> void:
	var fk := _flock()
	if fk == null:
		return
	var under := Vector3(fk.home.x, 0.02, fk.home.z)
	var car: Array = [
		under - Vector3(6.0 * WS.M, 0.0, 0.0),
		Vector3(13.9 * WS.M, 0.0, 0.0),
		2.3 * WS.M,
		1.0 * WS.M
	]
	fl.hero_on_foot = true
	fl.hero = ctx.player.position
	fl.hero_vel = Vector3.ZERO
	fl.passers = [under + Vector3(0.5 * WS.M, 0.0, 0.0)]
	fl.dogs = []
	fl.cars = [car]
	var sit := true
	for _k in range(40):
		fl.step(DT)
		car[0] = (car[0] as Vector3) + (car[1] as Vector3) * DT
		for b: FLOCK.Bird in fk.birds:
			sit = sit and not b.air
	K.check(fails, sit, "car: a car and a person below never send them up")


## A shout below the perch: the flock goes up together with one clatter (animal_called), wheels
## over the roofs and glides back onto its own points.
func _check_shout() -> void:
	var fk := _flock()
	if fk == null:
		return
	calls.clear()
	var under := Vector3(fk.home.x, 0.0, fk.home.z)
	var g := ctx.collision.walk_height(under)
	under.y = g if not is_nan(g) else 0.0
	ctx.player.teleport(under, 0.0)
	pr.startle(under, float(PR.STARTLE["shout"]))
	_step(0.7)
	var up := true
	for b: FLOCK.Bird in fk.birds:
		up = up and b.air
	K.check(
		fails, up and (_count("takeoff") >= 1 or _count("flap") >= 1), "shout: the flock goes up"
	)
	var took := _wait_perched(fk)
	var off := 0.0
	for b: FLOCK.Bird in fk.birds:
		off = maxf(off, b.pos.distance_to(b.goal))
	K.check(
		fails,
		took >= 0.0 and off < 1e-6,
		"shout: they glide back onto their own perches (%.1f s, off by %.4f)" % [took, off]
	)


## The hero's car horn (horn_sounded) from the street below sends the perch flock up together,
## like a shout, and they glide back onto their points; a horn out of earshot leaves them be.
func _check_horn() -> void:
	var fk := _flock()
	if fk == null:
		return
	var under := Vector3(fk.home.x, 0.0, fk.home.z)
	ctx.bus.horn_sounded.emit(Vector2(under.x, under.z), DRIVE.HORN_STREET_R, false)
	_step(0.7)
	var up := true
	for b: FLOCK.Bird in fk.birds:
		up = up and b.air
	K.check(fails, up, "horn: a horn below sends the perched flock up")
	var took := _wait_perched(fk)
	var off := 0.0
	for b: FLOCK.Bird in fk.birds:
		off = maxf(off, b.pos.distance_to(b.goal))
	K.check(
		fails,
		took >= 0.0 and off < 1e-6,
		"horn: they glide back onto their own perches (%.1f s)" % took
	)
	var far := Vector2(under.x + 40.0 * WS.M, under.z)
	ctx.bus.horn_sounded.emit(far, 5.0 * WS.M, true)
	_step(0.5)
	var stayed := true
	for b: FLOCK.Bird in fk.birds:
		stayed = stayed and not b.air
	K.check(fails, stayed, "horn: one out of earshot leaves them perched")


## While the rain holds (the P2 shelter), a horn finds nothing to flush: no perch flock is out to
## hear it, and none comes back out for it either.
func _check_horn_rain() -> void:
	var fk := _flock()
	if fk == null:
		return
	var under := Vector3(fk.home.x, 0.0, fk.home.z)
	FRESH.force_weather(ctx, "rain")
	_step(AF.SCAN_S + 0.2)
	var sheltered := _flock() == null
	ctx.bus.horn_sounded.emit(Vector2(under.x, under.z), DRIVE.HORN_STREET_R, true)
	_step(0.5)
	K.check(
		fails,
		sheltered and _flock() == null,
		"horn: in the rain there is nothing to flush (the perched birds shelter)"
	)
	FRESH.force_weather(ctx, "clear")
	_step(AF.SCAN_S + 0.2)


## Beyond FAR the flock goes, and back within it the same points fill again.
func _check_far() -> void:
	var fk := _flock()
	if fk == null:
		return
	var n := fk.birds.size()
	var home: Vector3 = fk.home
	ctx.player.teleport(Vector3(home.x + PR.FAR + 1.0, 0.0, home.z), 0.0)
	_step(AF.SCAN_S + 0.1)
	K.check(fails, _flock() == null, "far: beyond FAR the flock goes")
	ctx.player.teleport(spot["stand"], 0.0)
	_step(AF.SCAN_S + 0.1)
	var again := _flock()
	var pts: PackedVector3Array = spot["points"]
	var same := again != null and again.birds.size() == n and again.birds.size() == pts.size()
	if same:
		for k in range(pts.size()):
			same = same and (again.birds[k] as FLOCK.Bird).goal.distance_to(pts[k]) < 1e-9
	K.check(fails, same, "far: back within FAR, the same points fill again")


## By night nothing comes out; by day they come back.
func _check_night() -> void:
	ctx.sky.night = 1.0
	ctx.player.teleport((spot["stand"] as Vector3) + Vector3(PR.FAR + 1.0, 0.0, 0.0), 0.0)
	_step(AF.SCAN_S + 0.1)
	K.check(fails, fl.flocks.is_empty(), "night: by night, away from the player, they go")
	ctx.sky.night = 0.0
	ctx.player.teleport(spot["stand"], 0.0)
	_step(AF.SCAN_S + 0.1)
	K.check(fails, _flock() != null, "night: by day they come out again")


## In the rain no perched flock comes out (they shelter, as the cats do); once it clears they come
## back.
func _check_rain() -> void:
	ctx.player.teleport(spot["stand"], 0.0)
	FRESH.rain_gate(ctx, traffic, f, fails, "perched birds", func() -> int: return fl.flocks.size())


## The flag off takes the perched flocks away; on again they come back.
func _check_flag() -> void:
	FeatureFlags.set_override("perched_birds", false)
	_step(DT)
	K.check(fails, fl.flocks.is_empty(), "flag: off takes the perched flocks away")
	FeatureFlags.set_override("perched_birds", true)
	_step(AF.SCAN_S + 0.1)
	K.check(fails, _flock() != null, "flag: on again, they come back")


## A fresh city (no growth: only the founding roads and City Hall): the hall's roof edge keeps its
## row of perched birds from the first day; by night nothing comes out.
func _check_fresh_city() -> void:
	var fresh := FRESH.make(get_root())
	if not bool(fresh["ok"]):
		K.check(fails, false, "fresh: fixture: traffic and animals registered")
		return
	var fctx: FpContext = fresh["ctx"]
	var ftr: FpFeature = fresh["traffic"]
	var ff: FpFeature = fresh["animals"]
	var fpr: PR = ff.get("perches")
	var ffl: FLOCK = fpr.flock
	var hall := -1
	for i in range(fctx.sim.kind.size()):
		if fctx.sim.kind[i] == D.HALL:
			hall = i
			break
	K.check(fails, hall >= 0, "fresh: fixture: City Hall is built")
	if hall < 0:
		return
	var fr: int = fctx.directory.frontage(hall)
	var at := Vector3(D.tx(hall), 0.0, D.ty(hall)) if fr < 0 else Vector3(D.tx(fr), 0.0, D.ty(fr))
	var g := fctx.collision.walk_height(at)
	at.y = g if not is_nan(g) else 0.0
	fctx.player.teleport(at, 0.0)
	FRESH.step(ftr, ff, AF.SCAN_S + 0.1)
	var n := 0
	var out := false
	for fk: FLOCK.Flock in ffl.flocks:
		n += fk.birds.size()
		out = out or fk.key == "roof:%d" % hall
	K.check(
		fails,
		out and n >= PR.ROOF_N.x,
		"fresh: City Hall keeps its row of perched birds from the first day (%d)" % n
	)
	fctx.sky.night = 1.0
	fctx.player.teleport(at + Vector3(PR.FAR + 1.0, 0.0, 0.0), 0.0)
	FRESH.step(ftr, ff, AF.SCAN_S + 0.1)
	K.check(fails, ffl.flocks.is_empty(), "fresh: by night nothing comes out")


func _check_teardown() -> void:
	var st := f.self_test()
	K.check(
		fails, bool(st["ok"]) and "perched in" in str(st["detail"]), "self_test: %s" % st["detail"]
	)
	f.teardown()
	K.check(
		fails,
		fl.flocks.is_empty() and pr.get_child_count() == 0,
		"teardown: no perched flocks left"
	)
