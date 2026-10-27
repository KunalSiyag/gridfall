extends SceneTree
## Squirrels (the animals feature; docs/fp/ARCHITECTURE.md, Animals): by day a lawn with a tree
## near the player — a tree in the woods that ring the city, a street tree, a lot's own — keeps a
## squirrel, drawn by one MultiMesh of the squirrel an instance: it bounds about its patch of
## grass at the foot of its trunk, stops and sits up on its haunches to nibble with its paws at its
## mouth, its tail swaying behind it. The hero walking up to it (or sprinting near) makes it
## chatter once, dash for its tree and run up the trunk, where it clings head-up until the trouble
## has been gone, then comes back down to its lawn; a shout and a dog close by do the same. By
## night none comes out; the flag off takes them away; self_test and teardown. Third person on a
## grown city; time runs through the feature's tick(1/60) and traffic's step.

const K := preload("res://tools/tests/fp_kit.gd")
const FRESH := preload("res://tools/tests/fp_fresh_city.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AF := preload("res://scripts/fp/animals/animals_feature.gd")
const SQ := preload("res://scripts/fp/animals/squirrels.gd")
const LIFE := preload("res://scripts/fp/animals/squirrel_life.gd")
const SLOD := preload("res://scripts/fp/animals/settle_lod.gd")
const DT := 1.0 / 60.0
## How long the squirrel may take to reach its tree and climb it (s), to come back down (s), and
## how long the hero waits off for it (s).
const UP_S := 6.0
const DOWN_S := 15.0
## The hero stands this far off the squirrel's lawn (u, about 20 m): outside WARY (2.6 m) and
## SPRINT (5.5 m), so the squirrel is not frightened, and well within FAR (3.6 u), so the scan
## keeps it out.
const STAND_U := 1.0

var fails: Array[String] = []
var ctx: FpContext
var traffic: FpFeature
var f: FpFeature
var sq: SQ
var life: LIFE
## The squirrel spot the test's animal keeps to (squirrels.gd _spot_of()), with where the player
## stands off it, and its key.
var spot: Dictionary = {}
var key: String = ""
## Every animal_called call.
var calls: Array = []


func _init() -> void:
	await process_frame
	var fx := FRESH.open_grown(self, "FP_SQUIRRELS_TEST", fails, calls)
	if fx.is_empty():
		return
	ctx = fx["ctx"]
	traffic = fx["traffic"]
	f = fx["animals"]
	sq = fx["squirrels"]
	life = fx["sq_life"]
	spot = _squirrel_spot()
	K.check(fails, not spot.is_empty(), "fixture: a lawn with a tree, with ground to stand on")
	if not spot.is_empty():
		key = str(spot["key"])
		var home: Vector3 = spot["home"]
		ctx.player.teleport(_stand(home), 0.0)
		_step(AF.SCAN_S + 0.1)
		_check_spawn()
		_check_forage()
		_check_flee()
		_check_down()
		_check_shout()
		_check_dog()
		_check_night()
		_check_rain()
		_check_flag()
		_check_lod()
	_check_teardown()
	K.finish(self, "FP_SQUIRRELS_TEST", fails)


# ------------------------------------------------------------------ helpers


## Steps traffic and the animals feature secs (in 1/60 s steps).
func _step(secs: float) -> void:
	FRESH.step(traffic, f, secs)


## The first squirrel spot of the grown city with walkable ground within 8 m of its lawn for the
## player to stand on, else {}.
func _squirrel_spot() -> Dictionary:
	for i in range(ctx.sim.kind.size()):
		var s: Dictionary = sq.call("_spot_of", i)
		if s.is_empty():
			continue
		var home: Vector3 = s["home"]
		if ctx.collision.surface_at(home) == "asphalt":
			continue
		var g := ctx.collision.walk_height(home)
		if is_nan(g):
			continue
		var stand := _stand(home)
		if not stand.is_finite():
			continue
		s["stand"] = stand
		return s
	return {}


## A point STAND_U (u) off home on free walkable ground, else NAN.
func _stand(home: Vector3) -> Vector3:
	for k in range(12):
		var a := TAU * float(k) / 12.0
		var p := home + Vector3(cos(a), 0.0, sin(a)) * STAND_U
		var h := ctx.collision.walk_height(p)
		if is_nan(h) or ctx.collision.surface_at(p) in ["asphalt", "water"]:
			continue
		if ctx.collision.is_blocked(Vector3(p.x, h, p.z), WS.PLAYER_RADIUS):
			continue
		return Vector3(p.x, h, p.z)
	return LIFE.NO_POINT


func _squirrel() -> LIFE.Squirrel:
	return life.squirrel(key)


func _count(c: String) -> int:
	return calls.filter(func(e: String) -> bool: return e == c).size()


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# ------------------------------------------------------------------ checks


## By day the spot's squirrel comes out on its lawn, drawn by one MultiMesh of the squirrel with a
## coat of its own; its tree is the trunk it will climb.
func _check_spawn() -> void:
	var s := _squirrel()
	K.check(fails, s != null, "spawn: the spot's squirrel comes out")
	if s == null:
		return
	var mm := (sq.get("_node") as MultiMeshInstance3D).multimesh
	var on_lawn := _flat(s.pos, s.home) <= SQ.FORAGE_R * 3.0
	var tree: Array = s.tree
	var grounded := not is_nan(ctx.collision.walk_height(s.pos))
	K.check(
		fails,
		on_lawn and grounded and tree.size() == 3,
		(
			"spawn: it keeps to the lawn by its trunk (%.3f u off), on the ground"
			% _flat(s.pos, s.home)
		)
	)
	K.check(
		fails,
		mm != null and mm.visible_instance_count == life.squirrels.size(),
		(
			"spawn: one MultiMesh draws every squirrel (%d of %d instances, %d out)"
			% [mm.visible_instance_count, mm.instance_count, life.squirrels.size()]
		)
	)


## It bounds about its patch: it covers ground, sits up on its haunches to nibble (the pose the
## shader takes) and sways its tail.
func _check_forage() -> void:
	var s := _squirrel()
	if s == null:
		return
	var path := 0.0
	var was := s.pos
	var sat := 0.0
	var nibbled := false
	var tail := 0.0
	var bounded := false
	for _k in range(ceili(30.0 / 0.25)):
		_step(0.25)
		path += _flat(s.pos, was)
		was = s.pos
		sat = maxf(sat, s.sit)
		tail = maxf(tail, absf(s.tail))
		if s.state == "nibble":
			nibbled = true
		if LIFE.lift(s) > 0.0:
			bounded = true
	var home_kept := _flat(s.pos, s.home) <= SQ.FORAGE_R + 0.05
	var lively := path > 0.1 and bounded and nibbled and sat > 0.8 and tail > 0.05
	K.check(
		fails, lively, "forage: it bounds about (%.3f u) and sits up to nibble (%.2f)" % [path, sat]
	)
	K.check(fails, home_kept, "forage: it keeps to its own patch of lawn")


## The hero walking up to it: it chatters once, dashes for its tree and runs up the trunk to cling
## there head-up.
func _check_flee() -> void:
	var s := _squirrel()
	if s == null:
		return
	calls.clear()
	var home: Vector3 = spot["home"]
	ctx.player.teleport(home + Vector3(0.2 * WS.M, 0.0, 0.0), 0.0)
	var up := false
	var climbing := false
	var t := 0.0
	while t <= UP_S:
		_step(0.25)
		t += 0.25
		climbing = climbing or s.state in ["flee", "climb"]
		if s.state == "hold":
			up = true
			break
	var tree: Array = s.tree
	var at_trunk := _flat(s.pos, Vector3(tree[0], 0.0, tree[1])) <= float(tree[2]) + 0.03
	var high := s.climb_y >= LIFE.CLING_H - 0.005
	K.check(fails, climbing, "fright: the hero walking up sends it dashing for its tree")
	K.check(fails, up and high, "fright: it climbs and clings up its trunk (%.3f u up)" % s.climb_y)
	K.check(fails, at_trunk, "fright: it clings against the trunk, not out on the lawn")
	K.check(
		fails,
		_count("chatter") >= 1,
		"fright: it chatters once as it goes (%d)" % _count("chatter")
	)


## The hero off, it comes back down the trunk and forages on its lawn again.
func _check_down() -> void:
	var s := _squirrel()
	if s == null:
		return
	# Off the lawn but well within FAR, so the scan keeps the squirrel out.
	var home: Vector3 = spot["home"]
	ctx.player.teleport(home + Vector3(STAND_U, 0.0, 0.0), 0.0)
	var down := false
	var foraged := false
	var t := 0.0
	while t <= DOWN_S:
		_step(0.25)
		t += 0.25
		if s.state in ["forage", "nibble"] and _flat(s.pos, s.home) <= SQ.FORAGE_R + 0.05:
			down = true
			foraged = true
			break
	K.check(fails, down, "down: once the hero is off it comes back down to its lawn")
	K.check(fails, foraged, "down: and goes back to foraging there")


## A shout close by sends it up its tree too (the hero's own actions startle it).
func _check_shout() -> void:
	var s := _squirrel()
	if s == null:
		return
	var up := false
	var t := 0.0
	# Close by in metres: a shout reaches SQUIRRELS.STARTLE["shout"] (10 m) of the hero's feet.
	ctx.bus.hero_action.emit("shout", s.pos + Vector3(0.2 * WS.M, 0.0, 0.0))
	while t <= UP_S:
		_step(0.25)
		t += 0.25
		if s.state == "hold":
			up = true
			break
	K.check(fails, up, "shout: a shout close by sends it up its tree")
	# Bring it down again for the checks that follow.
	ctx.player.teleport(spot["home"] + Vector3(STAND_U, 0.0, 0.0), 0.0)
	t = 0.0
	while t <= DOWN_S and s.state != "forage" and s.state != "nibble":
		_step(0.25)
		t += 0.25


## A dog running up to it sends it up its tree as well.
func _check_dog() -> void:
	var s := _squirrel()
	if s == null:
		return
	var up := false
	var t := 0.0
	sq.startle(s.pos, SQ.BARK_M)
	while t <= UP_S:
		_step(0.25)
		t += 0.25
		if s.state == "hold":
			up = true
			break
	K.check(fails, up, "dog: a bark by the lawn sends it up its tree")
	ctx.player.teleport(spot["home"] + Vector3(STAND_U, 0.0, 0.0), 0.0)
	t = 0.0
	while t <= DOWN_S and s.state != "forage" and s.state != "nibble":
		_step(0.25)
		t += 0.25


## By night nothing comes out; by day they come out again.
func _check_night() -> void:
	ctx.sky.night = 1.0
	f.on_world_rebuilt()
	_step(AF.SCAN_S + 0.1)
	K.check(fails, life.squirrels.is_empty(), "night: by night none comes out")
	ctx.sky.night = 0.0
	f.on_world_rebuilt()
	ctx.player.teleport(spot["stand"], 0.0)
	_step(AF.SCAN_S + 0.1)
	K.check(fails, _squirrel() != null, "night: by day they come out again")


## In the rain no squirrel comes out (it shelters in its drey, as the cats do); once it clears they
## come back.
func _check_rain() -> void:
	ctx.player.teleport(spot["stand"], 0.0)
	FRESH.rain_gate(
		ctx, traffic, f, fails, "squirrels out", func() -> int: return life.squirrels.size()
	)


## The flag off takes the squirrels away; on again they come back.
func _check_flag() -> void:
	FeatureFlags.set_override("squirrels", false)
	_step(DT)
	K.check(fails, life.squirrels.is_empty(), "flag: off takes the squirrels away")
	FeatureFlags.set_override("squirrels", true)
	_step(AF.SCAN_S + 0.1)
	K.check(fails, _squirrel() != null, "flag: on again, they come back")


## A quiet squirrel far from the hero ticks at 4 Hz (settle_lod.gd): short ticks bank until
## SETTLE_S, then it steps once with the banked time. The hero coming close, or any escape
## state, runs at full rate.
func _check_lod() -> void:
	var s := _squirrel()
	K.check(fails, s != null, "lod: the spot's squirrel")
	if s == null:
		return
	s.state = "forage"
	s.hz_t = 0.0
	life.hero_on_foot = false
	life.dogs = []
	life.passers = []
	life.hero = s.pos + Vector3(SLOD.NEAR * 2.0, 0.0, 0.0)
	s.dirty = false
	for _k in range(3):
		life.step(0.05)
	K.check(fails, not s.dirty and s.hz_t > 0.0, "lod: a quiet far squirrel banks short ticks")
	for _k in range(2):
		life.step(0.05)
	K.check(fails, s.dirty and s.hz_t == 0.0, "lod: the banked time steps it at the slow cadence")
	life.hero = s.pos + Vector3(0.2, 0.0, 0.0)
	s.dirty = false
	life.step(0.05)
	K.check(fails, s.dirty, "lod: the hero close by keeps the full rate")
	life.hero = s.pos + Vector3(SLOD.NEAR * 2.0, 0.0, 0.0)
	s.state = "climb"
	s.hz_t = 0.0
	s.dirty = false
	life.step(0.05)
	K.check(fails, s.dirty, "lod: an escape runs at full rate however far")


func _check_teardown() -> void:
	var st := f.self_test()
	K.check(
		fails,
		bool(st["ok"]) and "squirrels about" in str(st["detail"]),
		"self_test: %s" % st["detail"]
	)
	f.teardown()
	K.check(fails, life.squirrels.is_empty(), "teardown: no squirrels left")
