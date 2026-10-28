extends SceneTree
## Waterfowl (the animals feature; docs/fp/ARCHITECTURE.md, Animals): by day a spot on the river's
## open water near the player keeps its flock of mallards, a drake or two among the hens, one
## MultiMesh of the duck an instance a bird: they paddle about their spot on the water, tip
## tail-up to feed under the surface and preen their feathers with a shake of their wings; the
## hero walking down to the bank close by sends the whole flock up together with a clatter of
## wings — they run along the water, climb away and wheel round over it — and once the hero is
## off, they glide back down and land on the water; the hero's car horn sends them up too, heard
## a share wider over the open water, and in the rain finds nothing to flush; by night none comes
## out; the flag off takes them away; self_test and teardown. Third person on a grown city; time
## runs through the feature's tick(1/60) and traffic's step.

const K := preload("res://tools/tests/fp_kit.gd")
const FRESH := preload("res://tools/tests/fp_fresh_city.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AF := preload("res://scripts/fp/animals/animals_feature.gd")
const DRIVE := preload("res://scripts/fp/drive/drive_feature.gd")
const WF := preload("res://scripts/fp/animals/waterfowl.gd")
const FLOCK := preload("res://scripts/fp/animals/pigeon_flock.gd")
const DT := 1.0 / 60.0
## How long the flock may take to come back down and land (s), and how long to go up (s).
const LAND_S := 45.0
const UP_S := 12.0
## How far above the water a duck in the wheel rides (m).
const WHEEL_M := 2.0

var fails: Array[String] = []
var ctx: FpContext
var traffic: FpFeature
var f: FpFeature
var wf: WF
var fl: FLOCK
## The water spot the test's flock keeps to (waterfowl.gd _spot_of()), with where the player
## stands on the bank by it, and the flock's key.
var spot: Dictionary = {}
var key: String = ""
## Every animal_called call.
var calls: Array = []


func _init() -> void:
	await process_frame
	var fx := FRESH.open_grown(self, "FP_WATERFOWL_TEST", fails, calls)
	if fx.is_empty():
		return
	ctx = fx["ctx"]
	traffic = fx["traffic"]
	f = fx["animals"]
	wf = fx["waterfowl"]
	fl = wf.flock
	spot = _water_spot()
	K.check(fails, not spot.is_empty(), "fixture: a water spot with a bank to stand on")
	if not spot.is_empty():
		key = str(spot["key"])
		var home: Vector3 = spot["home"]
		# Away from the water first, so the flock is not frightened the moment it comes out.
		ctx.player.teleport(home + Vector3(20.0 * WS.M, 0.0, 0.0), 0.0)
		_step(AF.SCAN_S + 0.1)
		_check_spawn()
		_check_float()
		_check_flush()
		_check_land()
		_check_night()
		_check_rain()
		_check_flag()
		_check_horn()
		_check_horn_rain()
	_check_teardown()
	K.finish(self, "FP_WATERFOWL_TEST", fails)


# ------------------------------------------------------------------ helpers


## Steps traffic and the animals feature secs (in 1/60 s steps).
func _step(secs: float) -> void:
	FRESH.step(traffic, f, secs)


## The first water spot of the grown city with a walkable bank point within 8 m of it (the flock
## would otherwise never be frightened from land), else {}.
func _water_spot() -> Dictionary:
	for i in range(ctx.sim.kind.size()):
		var s: Dictionary = wf.call("_spot_of", i)
		if s.is_empty():
			continue
		var home: Vector3 = s["home"]
		for m: float in [1.5, 3.0, 5.0, 8.0]:
			for k in range(8):
				var a := TAU * k / 8.0
				var p := home + Vector3(cos(a), 0.0, sin(a)) * m * WS.M
				var y := ctx.collision.walk_height(p)
				if is_nan(y) or ctx.collision.surface_at(p) == "water":
					continue
				s["stand"] = Vector3(p.x, y, p.z)
				return s
	return {}


func _flock() -> FLOCK.Flock:
	for fk: FLOCK.Flock in fl.flocks:
		if fk.key == key:
			return fk
	return null


func _count(c: String) -> int:
	return calls.filter(func(e: String) -> bool: return e == c).size()


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# ------------------------------------------------------------------ checks


## By day the spot's flock comes out: its ducks on the water's surface within their spot, a drake
## or two among the hens, drawn by one MultiMesh of the duck.
func _check_spawn() -> void:
	var fk := _flock()
	var n := 0 if fk == null else fk.birds.size()
	K.check(
		fails, fk != null and n >= WF.DUCKS.x, "spawn: the spot's flock comes out (%d ducks)" % n
	)
	if fk == null:
		return
	var home: Vector3 = spot["home"]
	var drakes := 0
	var hens := 0
	var on_water := true
	for b: FLOCK.Bird in fk.birds:
		on_water = on_water and ctx.collision.surface_at(b.pos) == "water"
		on_water = on_water and absf(b.pos.y - WS.WATER_Y) < 0.01 * WS.M
		on_water = on_water and _flat(b.pos, home) <= float(spot["radius"]) + 0.05
		if b.bob > 0.5:
			drakes += 1
		else:
			hens += 1
	var mm := (fk.node as MultiMeshInstance3D).multimesh if fk.node != null else null
	K.check(
		fails,
		on_water and drakes >= 1 and hens >= 1 and mm != null and mm.instance_count == n,
		"spawn: %d drakes and %d hens floating on the water, drawn" % [drakes, hens]
	)


## About their spot: the ducks paddle from place to place, now and then tip tail-up to feed under
## the surface or preen their wings; none leaves the water.
func _check_float() -> void:
	var fk := _flock()
	if fk == null:
		return
	var home: Vector3 = spot["home"]
	var moved := 0.0
	var dabbed := false
	var preened := false
	for _k in range(ceili(25.0 / 0.25)):
		_step(0.25)
		for b: FLOCK.Bird in fk.birds:
			moved = maxf(moved, _flat(b.pos, b.goal))
			if b.peck > 0.5:
				dabbed = true
			if b.open > 0.2 and not b.air:
				preened = true
	var stayed := true
	for b: FLOCK.Bird in fk.birds:
		stayed = stayed and _flat(b.pos, home) <= float(spot["radius"]) * 2.0 + 0.1
		stayed = stayed and ctx.collision.surface_at(b.pos) == "water"
	K.check(
		fails,
		moved > 0.1 and dabbed and preened and stayed,
		"water: they paddle, dabble (%s), preen (%s) and keep to the water" % [dabbed, preened]
	)


## The hero walking down to the bank by the flock sends it up: every duck in the air, wings
## spread, a take-off's clatter, wheeling high over the water.
func _check_flush() -> void:
	var fk := _flock()
	if fk == null:
		return
	calls.clear()
	ctx.player.teleport(spot["stand"], 0.0)
	var up := false
	var heard := 0
	var high := false
	var t := 0.0
	while t <= UP_S:
		_step(0.25)
		t += 0.25
		var all := true
		for b: FLOCK.Bird in fk.birds:
			all = all and b.air and b.open > 0.5
			high = high or (b.air and b.pos.y > WHEEL_M * WS.M)
		up = up or all
		if up and high:
			break
	heard = _count("takeoff") + _count("flap")
	K.check(
		fails,
		up and high and heard > 0,
		"fright: the hero at the bank sends the flock up and wheeling (%d calls)" % heard
	)


## The hero off, the flock glides back down and lands on the water and goes back to feeding.
func _check_land() -> void:
	var fk := _flock()
	if fk == null:
		return
	var home: Vector3 = spot["home"]
	ctx.player.teleport(home + Vector3(30.0 * WS.M, 0.0, 30.0 * WS.M), 0.0)
	var t := 0.0
	var landed := false
	var feeding := false
	while t <= LAND_S:
		var down := true
		for b: FLOCK.Bird in fk.birds:
			down = down and not b.air and absf(b.pos.y - WS.WATER_Y) < 0.003 * WS.M
		if down:
			landed = true
			_step(3.0)
			for b: FLOCK.Bird in fk.birds:
				feeding = feeding or b.act in ["paddle", "dabble", "up_end", "preen"]
			break
		_step(0.25)
		t += 0.25
	K.check(fails, landed, "land: once the hero is off they glide back down and land")
	K.check(fails, feeding, "land: and go back to feeding on the water")


## By night nothing comes out; by day they come out again.
func _check_night() -> void:
	ctx.sky.night = 1.0
	f.on_world_rebuilt()
	_step(AF.SCAN_S + 0.1)
	K.check(fails, fl.flocks.is_empty(), "night: by night none comes out")
	ctx.sky.night = 0.0
	f.on_world_rebuilt()
	ctx.player.teleport(spot["stand"], 0.0)
	_step(AF.SCAN_S + 0.1)
	K.check(fails, _flock() != null, "night: by day they come out again")


## In the rain no flock keeps to the water (they shelter on the bank, as the cats do); once it
## clears they come back.
func _check_rain() -> void:
	ctx.player.teleport(spot["stand"], 0.0)
	FRESH.rain_gate(
		ctx, traffic, f, fails, "ducks on the water", func() -> int: return fl.flocks.size()
	)


## The flag off takes the flocks away; on again they come back.
func _check_flag() -> void:
	FeatureFlags.set_override("waterfowl", false)
	_step(DT)
	K.check(fails, fl.flocks.is_empty(), "flag: off takes the ducks away")
	FeatureFlags.set_override("waterfowl", true)
	_step(AF.SCAN_S + 0.1)
	K.check(fails, _flock() != null, "flag: on again, they come back")


## The hero's car horn (horn_sounded): one at the flock's spot with the street's reach sends
## every duck up; one past the street's reach but within the water's carry (HORN_CARRY wider)
## still flushes them; one well out of earshot leaves them be.
func _check_horn() -> void:
	var fk := _flock()
	if fk == null:
		return
	var home: Vector3 = spot["home"]
	ctx.player.teleport(home + Vector3(20.0 * WS.M, 0.0, 0.0), 0.0)
	if not _wait_down(fk):
		return
	ctx.bus.horn_sounded.emit(Vector2(home.x, home.z), DRIVE.HORN_STREET_R, false)
	_step(0.5)
	var near := _all_up(fk)
	if not _wait_down(fk):
		return
	# Between the street's reach and the water's carry: a street flock would not hear it.
	var side := home + Vector3(DRIVE.HORN_STREET_R * 1.2, 0.0, 0.0)
	ctx.bus.horn_sounded.emit(Vector2(side.x, side.z), DRIVE.HORN_STREET_R, true)
	_step(0.5)
	var carried := _all_up(fk)
	if not _wait_down(fk):
		return
	var far := home + Vector3(100.0 * WS.M, 0.0, 0.0)
	ctx.bus.horn_sounded.emit(Vector2(far.x, far.z), DRIVE.HORN_STREET_R * WF.HORN_CARRY, false)
	_step(0.5)
	var untouched := fk.birds.all(func(b: FLOCK.Bird) -> bool: return not b.air)
	K.check(fails, near, "horn: a horn at the flock sends the ducks up")
	K.check(fails, carried, "horn: over the water it carries a share wider than the street's")
	K.check(fails, untouched, "horn: one out of earshot leaves them be")


## In the rain no flock is out (they shelter on the bank): a horn finds nothing to flush, and
## brings nothing out either.
func _check_horn_rain() -> void:
	var home: Vector3 = spot["home"]
	FRESH.force_weather(ctx, "rain")
	_step(AF.SCAN_S + 0.2)
	var sheltered := fl.flocks.is_empty()
	ctx.bus.horn_sounded.emit(Vector2(home.x, home.z), DRIVE.HORN_STREET_R * WF.HORN_CARRY, true)
	_step(1.0)
	K.check(
		fails, sheltered and fl.flocks.is_empty(), "horn: in the rain there is nothing to flush"
	)
	FRESH.force_weather(ctx, "clear")
	_step(AF.SCAN_S + 0.2)


## Waits until every duck is back on the water (LAND_S at most); false when they never settle.
func _wait_down(fk: FLOCK.Flock) -> bool:
	var t := 0.0
	while t <= LAND_S:
		var down := true
		for b: FLOCK.Bird in fk.birds:
			down = down and not b.air
		if down:
			return true
		_step(0.25)
		t += 0.25
	K.check(fails, false, "horn: the flock settles back on the water")
	return false


## Every duck in the air.
func _all_up(fk: FLOCK.Flock) -> bool:
	return fk.birds.all(func(b: FLOCK.Bird) -> bool: return b.air)


func _check_teardown() -> void:
	var st := f.self_test()
	K.check(
		fails,
		bool(st["ok"]) and "ducks on the water" in str(st["detail"]),
		"self_test: %s" % st["detail"]
	)
	f.teardown()
	K.check(fails, fl.flocks.is_empty(), "teardown: no ducks left")
