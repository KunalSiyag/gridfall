extends SceneTree
## Squirrels (the animals feature; docs/fp/ARCHITECTURE.md, Animals): by day a lawn with a tree
## near the player — a tree in the woods that ring the city, a street tree, a lot's own — keeps a
## squirrel, drawn by one MultiMesh of the squirrel an instance: it bounds about its patch of
## grass at the foot of its trunk, stops and sits up on its haunches to nibble with its paws at its
## mouth, its tail swaying behind it; two whose lawns touch now and then chase one another in
## spirals round a trunk, chattering, a catch swapping who chases whom. The hero walking up to
## it (or sprinting near) makes it
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
		_check_play()
		_check_night()
		_check_rain()
		_check_flag()
		_check_lod()
	_check_capped_out()
	_check_teardown()
	K.finish(self, "FP_SQUIRRELS_TEST", fails)


## A CollisionWorld that declares the disc round block_at unwalkable and leaves the rest to the
## real world: how the block-in-the-spiral check stages its wall.
class BlockedCol:
	extends CollisionWorld
	var real: CollisionWorld = null
	var block_at := Vector3.ZERO
	var block_r: float = 0.0

	func walk_height(p: Vector3) -> float:
		if Vector2(p.x - block_at.x, p.z - block_at.z).length() < block_r:
			return NAN
		return real.walk_height(p)

	func surface_at(p: Vector3) -> String:
		return real.surface_at(p)

	func is_blocked(p: Vector3, radius: float) -> bool:
		return real.is_blocked(p, radius)


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


## Two squirrels whose lawns touch now and then chase one another, in spirals round a trunk,
## chattering, until a catch swaps their parts or the round ends; and the game yields to any
## real fright. The trigger, the motion, the game's course and the fright, each a check below;
## then the fixture is put back clean for the checks that follow.
func _check_play() -> void:
	var s := _squirrel()
	K.check(fails, s != null, "play: the spot's squirrel is out to test")
	if s == null:
		return
	var mate := _forge_mate(s)
	if not _play_triggered(s, mate):
		sq.clear()
		_step(AF.SCAN_S + 0.1)
		return
	_play_motion(s, mate)
	_play_round(s, mate)
	_play_blocked(s, mate)
	_play_threat(s, mate)
	sq.clear()
	_step(AF.SCAN_S + 0.1)


## A playmate for s whose lawn touches its own, sharing its trunk (and its tint row, so the one
## MultiMesh draws it too).
func _forge_mate(s: LIFE.Squirrel) -> LIFE.Squirrel:
	var mate := life.add(spot["home"] + Vector3(1.2 * WS.M, 0.0, 0.0), s.tree, "sq:test-mate")
	sq._tints.append(sq._tint("sq:test-mate"))
	sq._draw()
	return mate


## The chase breaks out on its own within a spell of shared calm foraging.
func _play_triggered(s: LIFE.Squirrel, mate: LIFE.Squirrel) -> bool:
	calls.clear()
	var t := 0.0
	var on := false
	while t <= 90.0:
		_step(0.5)
		t += 0.5
		if s.state == "play" or mate.state == "play":
			on = true
			break
	K.check(fails, on, "play: two squirrels whose lawns touch now and then chase one another")
	return on


## The chase's motion: the chaser closes on the one it chases; the one chased runs a spiral
## round its trunk.
func _play_motion(s: LIFE.Squirrel, mate: LIFE.Squirrel) -> void:
	var chaser: LIFE.Squirrel = s if s.play_chaser else mate
	var leader: LIFE.Squirrel = mate if s.play_chaser else s
	var trunk := Vector3(s.tree[0], 0.0, s.tree[1])
	var gap0 := _flat(chaser.pos, leader.pos)
	var gap_min := gap0
	var r_max := 0.0
	var p0a := s.pos
	var p0b := mate.pos
	var moved := 0.0
	var t := 0.0
	while t <= 2.5 and (s.state == "play" or mate.state == "play"):
		_step(0.25)
		t += 0.25
		gap_min = minf(gap_min, _flat(s.pos, mate.pos))
		moved = maxf(moved, maxf(_flat(s.pos, p0a), _flat(mate.pos, p0b)))
		if leader.state == "play" and not leader.play_chaser:
			r_max = maxf(r_max, _flat(leader.pos, trunk))
	K.check(
		fails,
		gap_min < gap0 - 0.2 * WS.M or gap_min <= LIFE.PLAY_CATCH * 1.2,
		"play: the chaser cuts after the one it chases and closes"
	)
	K.check(
		fails,
		moved > 0.3 * WS.M and r_max < LIFE.SPIRAL_R.y * WS.M + float(s.tree[2]) + 0.4 * WS.M,
		"play: the one chased runs a spiral round its trunk"
	)


## The game's course: it goes with chatter; a catch swaps who chases whom, or a round simply
## ends; and when it ends both go back to foraging with the play fields cleared.
func _play_round(s: LIFE.Squirrel, mate: LIFE.Squirrel) -> void:
	var s_chased: bool = s.play_chaser
	var t := 0.0
	var swapped := false
	var over := false
	while t <= LIFE.PLAY_ROUND_S.y * 2.0 + 1.0:
		_step(0.25)
		t += 0.25
		if s.state != "play" and mate.state != "play":
			over = true
			break
		if s.state == "play" and s.play_chaser != s_chased:
			swapped = true
			break
	t = 0.0
	while not over and t <= 15.0:
		_step(0.25)
		t += 0.25
		if s.state != "play" and mate.state != "play":
			over = true
	K.check(fails, _count("chatter") > 0, "play: the chase goes with chatter")
	K.check(fails, swapped or over, "play: a catch swaps who chases whom, or the round ends")
	K.check(
		fails,
		over and s.play_with == "" and mate.play_with == "",
		"play: when the round is run both go back to their lawns"
	)


## Where the ground runs out, the game breaks up: with a block staged inside the spiral's ring
## (a wall where the circle would run), no step of the chase ever enters it, and the chase ends
## where it cannot run.
func _play_blocked(s: LIFE.Squirrel, mate: LIFE.Squirrel) -> void:
	var trunk := Vector3(s.tree[0], 0.0, s.tree[1])
	var fake := BlockedCol.new()
	fake.real = life.col
	fake.block_r = 0.45 * WS.M
	# The side of the trunk that stands clearer of the pair.
	var mid := (s.home + mate.home) * 0.5
	var away := trunk - mid
	away.y = 0.0
	if away.length_squared() < 1e-8:
		away = Vector3.RIGHT
	away = away.normalized()
	var best := -1.0
	for side: float in [1.0, -1.0]:
		var c := trunk + away * (0.8 * WS.M * side)
		var d := minf(_flat(c, s.pos), _flat(c, mate.pos))
		if d > best:
			best = d
			fake.block_at = c
	K.check(
		fails, best >= fake.block_r, "play: the block stands clear of the pair as the chase begins"
	)
	life.col = fake
	life._start_play(s, mate)
	var t := 0.0
	var entered := false
	# A tick at a time, and only a squirrel still in the game is measured: once the game has
	# broken up the pair goes back to foraging, whose hops are not the chase's steps.
	while t <= 15.0 and (s.state == "play" or mate.state == "play"):
		_step(DT)
		t += DT
		for one: LIFE.Squirrel in [s, mate]:
			if one.state != "play":
				continue
			var d := Vector2(one.pos.x - fake.block_at.x, one.pos.z - fake.block_at.z).length()
			entered = entered or d < fake.block_r
	life._stop_play(s)
	life.col = fake.real
	fake.free()
	K.check(fails, not entered, "play: no step of the chase enters a block inside the spiral")
	K.check(
		fails,
		t <= 15.0 and s.play_with == "" and mate.play_with == "",
		"play: where the ground runs out, the game breaks up"
	)


## The game yields to a real fright: a bark mid-chase breaks it and sends both up their trees.
func _play_threat(s: LIFE.Squirrel, mate: LIFE.Squirrel) -> void:
	life._start_play(s, mate)
	sq.startle(mate.pos, SQ.BARK_M)
	_step(0.5)
	var cleared: bool = s.play_with == "" and mate.play_with == ""
	var t := 0.0
	var up := false
	while t <= UP_S:
		_step(0.25)
		t += 0.25
		if s.state in ["climb", "hold"] and mate.state in ["climb", "hold"]:
			up = true
			break
	K.check(fails, cleared and up, "play: a bark mid-chase ends the game; both dash for the tree")


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


## The web tier's cap can give the squirrels nothing (cap_split()): none set up then — no
## MultiMesh — and a scan and a step spawn and draw nobody, with nothing logged.
func _check_capped_out() -> void:
	var s: SQ = SQ.new()
	s.max_squirrels = 0
	s.setup(ctx)
	K.check(fails, s.get("_node") == null, "caps: a share of 0 builds no MultiMesh")
	s.scan(ctx.player.position, true)
	s.step(0.1)
	var s_life: Object = s.get("life")
	K.check(
		fails, (s_life.get("squirrels") as Array).is_empty(), "caps: a share of 0 spawns nobody"
	)
	s.free()


func _check_teardown() -> void:
	var st := f.self_test()
	K.check(
		fails,
		bool(st["ok"]) and "squirrels about" in str(st["detail"]),
		"self_test: %s" % st["detail"]
	)
	f.teardown()
	K.check(fails, life.squirrels.is_empty(), "teardown: no squirrels left")
