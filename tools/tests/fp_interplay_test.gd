extends SceneTree
## The animals' interplay: a free dog spots the pigeons feeding on the ground and gives chase —
## the flock goes up — then stands and sniffs where they went; a free dog after a cat sends it
## bolting up the nearest trunk (cat_life.gd's tree refuge), barks up at it and gives up below,
## and the cat comes back down once the dog has gone; a free dog after a squirrel sends it up its
## own trunk the same way (the squirrels' feed into the pack's prey, squirrels.world); a hunter
## cat stalks a squirrel low and slow
## — it holds its nerve until the pounce, then goes up its tree — grooms, and watches it up there
## as it does the perched birds; with the pigeons up out of reach a hunter watches the birds
## perched on a lamp instead of stalking: it sits still with its tail twitching and its eyes on
## the nearest, the bout ends and it rests; the cats see the perched birds and the squirrels
## through the feature's wiring (cats.world feeding cat_life.gd's birds_up); self_test and
## teardown.
## Third person on a grown city; stepped through traffic's step and the feature's tick (1/60).

const K := preload("res://tools/tests/fp_kit.gd")
const AF := preload("res://scripts/fp/animals/animals_feature.gd")
const PG := preload("res://scripts/fp/animals/pigeons.gd")
const PERCH := preload("res://scripts/fp/animals/perches.gd")
const PACK := preload("res://scripts/fp/animals/dog_pack.gd")
const DB := preload("res://scripts/fp/animals/dog_bodies.gd")
const FLOCK := preload("res://scripts/fp/animals/pigeon_flock.gd")
const LIFE := preload("res://scripts/fp/animals/cat_life.gd")
const CATS := preload("res://scripts/fp/animals/cats.gd")
const CAT_RIG := preload("res://scripts/fp/animals/cat_rig.gd")
const SQ_LIFE := preload("res://scripts/fp/animals/squirrel_life.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const SD := preload("res://scripts/sim/sim_defs.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []
var ctx: FpContext
var traffic: FpFeature
var f: FpFeature
var pigeons: PG
var perches: PERCH
var cats: CATS
var pack: PACK


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	traffic = K.make_feature(ctx, "traffic")
	f = K.make_feature(ctx, "animals")
	if traffic == null or f == null:
		K.check(fails, false, "fixture: traffic and animals registered")
		K.finish(self, "FP_INTERPLAY_TEST", fails)
		return
	traffic.set("auto_step", false)
	traffic.set("ambient_enabled", false)
	f.set_process(false)
	pigeons = f.get("pigeons")
	perches = f.get("perches")
	cats = f.get("cats")
	pack = f.get("pack")
	(f.get("bodies") as DB).blocking = true
	cats.bodies.blocking = true
	ctx.sky.fixed_hour = 12.0
	ctx.sky.hour = 12.0
	ctx.sky.night = 0.0
	_quiet()
	_check_dog_chases_cat()
	_check_dog_chases_squirrel()
	_check_dog_chase()
	_check_cat_stalks_squirrel()
	_check_cat_watches()
	_check_self_test()
	_check_teardown()
	K.finish(self, "FP_INTERPLAY_TEST", fails)


## Nobody walks about and nobody lives with a dog, so only the test's own animals are about.
func _quiet() -> void:
	var wk: WK = traffic.get("walkers")
	for w: WK.Walker in wk.walkers.duplicate():
		wk.remove(w)
	for r: Dictionary in ctx.residents.people:
		if str(r.get("household", "")) == AF.DOG_HOUSEHOLD:
			r["household"] = "lives alone"


## Steps traffic and the animals secs (in 1/60 s steps).
func _step(secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		traffic.call("step", DT)
		f.call("tick", DT)


## The first street flock spot (run nonzero) or perch spot of kind, else {}.
func _spot_of(node: Node, want_run: bool) -> Dictionary:
	for i in range(ctx.sim.kind.size()):
		var s: Dictionary = node.call("_spot_of", i)
		if s.is_empty():
			continue
		if want_run and (s.get("run", Vector3.ZERO) as Vector3) == Vector3.ZERO:
			continue
		return s
	return {}


## A walkable point on the ground within RINGS (m) of at, or Vector3.INF.
func _ground_near(at: Vector3) -> Vector3:
	for m: float in [1.0, 2.0, 3.0, 4.0]:
		for k in range(8):
			var a := TAU * k / 8.0
			var p := at + Vector3(cos(a), 0.0, sin(a)) * m * WS.M
			var y := ctx.collision.walk_height(p)
			if is_nan(y) or ctx.collision.surface_at(p) == "asphalt":
				continue
			if not ctx.collision.is_blocked(Vector3(p.x, y, p.z), 0.12 * WS.M):
				return Vector3(p.x, y, p.z)
	return Vector3.INF


## The test's chase dog: a friendly shiba out at at facing yaw, loose in the yard box around
## home; null when the body will not come out (the check logged).
func _chaser(key: String, at: Vector3, yaw: float, home: Vector3) -> PACK.Dog:
	var d: PACK.Dog = f.call("_spawn", key, at, yaw, false, "shiba")
	if d == null:
		K.check(fails, false, "fixture: the test's dog comes out")
		return null
	d.temper = "friendly"
	d.chases = true
	d.chase_cool = 0.0
	pack.to_yard(d, -1, home, Rect2(home.x - 0.6, home.z - 0.6, 1.2, 1.2))
	return d


## A lawn spot with a squirrel's tree, no pigeons, cats or other squirrels about, the player
## 30 m off it — the stage for the squirrel checks. {} when the city has none (the check logged).
func _squirrel_stage(what: String) -> Dictionary:
	var sq: Node = f.get("squirrels")
	var spot := _spot_of(sq, false)
	K.check(fails, not spot.is_empty(), "fixture: a lawn with a squirrel's tree (%s)" % what)
	if spot.is_empty():
		return {}
	FeatureFlags.set_override("pigeons", false)
	pigeons.clear()
	cats.clear()
	sq.call("clear")
	ctx.player.teleport((spot["home"] as Vector3) + Vector3(30.0 * WS.M, 0.0, 0.0), 0.0)
	return spot


# ------------------------------------------------------------------ checks


## A free dog after a squirrel out on its lawn: the squirrel goes up its own trunk, the dog barks
## up at it and gives up below — the cat beat, by the squirrels' feed into the pack's prey
## (squirrels.world).
func _check_dog_chases_squirrel() -> void:
	var spot := _squirrel_stage("the chase")
	if spot.is_empty():
		return
	var sq_life: SQ_LIFE = (f.get("squirrels") as Node).get("life")
	var home: Vector3 = spot["home"]
	var tree: Array = spot["tree"]
	var trunk := Vector3(tree[0], 0.0, tree[1])
	# The squirrel 2.5 m out from its trunk, so the dash and the climb read.
	var out := home - trunk
	out.y = 0.0
	out = out.normalized() if out.length_squared() > 1e-12 else Vector3.RIGHT
	var s := sq_life.add(home, tree, str(spot["key"]))
	s.pos = home + out * 2.5 * WS.M
	var d := _chaser("test:sq-chaser", s.pos + out * 3.5 * WS.M, atan2(-out.x, -out.z), home)
	if d == null:
		return
	var chased := false
	var gave_up := false
	for _k in range(ceili(15.0 / DT)):
		_step(DT)
		if d.act == "chase" and d.chase == s.key:
			chased = true
		if chased and d.act == "sniff" and d.chase == "":
			gave_up = true
			break
	# The give-up bark is a volley: it plays out over the next seconds.
	_step(2.0)
	var barked := int((f.get("calls") as Dictionary).get("bark", 0))
	K.check(fails, chased, "dog-squirrel: the dog gives chase (%s)" % d.chase)
	K.check(
		fails,
		s.state in ["climb", "hold"],
		"dog-squirrel: the squirrel goes up its trunk (%s)" % s.state
	)
	K.check(
		fails,
		gave_up and barked >= 1,
		"dog-squirrel: it barks up at the trunk and gives up (%d barks, %s)" % [barked, d.act]
	)
	f.call("_drop", d)
	(f.get("squirrels") as Node).call("clear")
	FeatureFlags.set_override("pigeons", true)


## A free dog after a cat with a tree at hand: the cat bolts up the trunk (cat_life.gd's tree
## refuge), the dog barks up at it and gives up below, and once the dog has gone the cat comes
## back down.
func _check_dog_chases_cat() -> void:
	var sq: Node = f.get("squirrels")
	# A street or lot tree, not a forest one: the woods' trees carry no collider, so
	# cat_life.gd's refuge (a trunk cylinder) is only a town tree's.
	var spot := {}
	for i in range(ctx.sim.kind.size()):
		if ctx.sim.kind[i] == SD.FOREST:
			continue
		spot = sq.call("_spot_of", i)
		if not spot.is_empty():
			break
	K.check(fails, not spot.is_empty(), "fixture: a lawn with a tree for the cat's refuge")
	if spot.is_empty():
		return
	var home: Vector3 = spot["home"]
	var tree: Array = spot["tree"]
	var trunk := Vector3(tree[0], 0.0, tree[1])
	# No pigeons and no other cats about, so the chaser's only game is the test's cat.
	FeatureFlags.set_override("pigeons", false)
	pigeons.clear()
	cats.clear()
	ctx.player.teleport(home + Vector3(40.0 * WS.M, 0.0, 0.0), 0.0)
	# The cat on the lawn 2.5 m out from its trunk, so the dash to the bark reads.
	var out := home - trunk
	out.y = 0.0
	out = out.normalized() if out.length_squared() > 1e-12 else Vector3.RIGHT
	var at := home + out * 2.5 * WS.M
	var b := cats.bodies.make("cat", 1.0, cats)
	if b == null:
		K.check(fails, false, "fixture: the test's cat comes out")
		return
	var c := cats.life.add(b, at, 0.0, Rect2())
	c.key = "test:prey"
	c.hunter = false
	c.meow_t = 1e9
	var dog_at := at + out * 3.5 * WS.M
	var d := _chaser("test:cat-chaser", dog_at, atan2(-out.x, -out.z), home)
	if d == null:
		return
	var chased := false
	var gave_up := false
	for _k in range(ceili(15.0 / DT)):
		_step(DT)
		if d.act == "chase" and d.chase == c.key:
			chased = true
		if chased and d.act == "sniff" and d.chase == "":
			gave_up = true
			break
	# The give-up bark is a volley: it plays out over the next seconds.
	_step(2.0)
	var barked := int((f.get("calls") as Dictionary).get("bark", 0))
	K.check(fails, chased, "dog-cat: the dog gives chase (%s)" % d.chase)
	K.check(
		fails,
		c.act in ["climb", "hold"] and not c.tree.is_empty(),
		"dog-cat: the cat bolts up the trunk (%s)" % c.act
	)
	K.check(
		fails,
		gave_up and barked >= 1,
		"dog-cat: it barks up at the trunk and gives up (%d barks, %s)" % [barked, d.act]
	)
	# The dog called off: the cat clings a calm while, then comes back down.
	f.call("_drop", d)
	var down := false
	for _k in range(ceili(9.0 / DT)):
		_step(DT)
		if c.tree.is_empty() and c.act in ["rest", "stroll"]:
			down = true
			break
	K.check(
		fails,
		down and c.climb_y <= 0.0,
		"dog-cat: once the dog has gone it comes back down (%s)" % c.act
	)
	cats.call("_drop", c)
	FeatureFlags.set_override("pigeons", true)


## A hunter cat and a squirrel: it stalks it low and slow — the squirrel holds its nerve until
## the pounce (a stalking cat reads no nearer than CAT_NEAR to it), then goes up its tree — the
## cat grooms, and with it up out of reach the hunter sits watching it as it does the birds.
func _check_cat_stalks_squirrel() -> void:
	var spot := _squirrel_stage("the stalk")
	if spot.is_empty():
		return
	var sq_life: SQ_LIFE = (f.get("squirrels") as Node).get("life")
	var home: Vector3 = spot["home"]
	var s := sq_life.add(home, spot["tree"], str(spot["key"]))
	var at := home + Vector3(2.5 * WS.M, 0.0, 0.0)
	var b := cats.bodies.make("cat", 1.0, cats)
	if b == null:
		K.check(fails, false, "fixture: the test's hunter comes out")
		return
	var c := cats.life.add(b, at, 0.0, Rect2())
	c.key = "test:hunter"
	c.hunter = true
	c.meow_t = 1e9
	c.hunt_cool = 0.0
	var stalked := false
	var crouched_still := false
	var bolted := false
	var treed := false
	var ended := false
	for _k in range(ceili(30.0 / DT)):
		_step(DT)
		if c.act == "stalk" and _flat(c.prey, s.pos) < 0.2 * WS.M:
			stalked = true
		if c.act == "crouch" and s.state in ["forage", "nibble"]:
			crouched_still = true
		if s.state in ["flee", "climb", "hold"]:
			bolted = true
		if s.climb_y > 0.0:
			treed = true
		if treed and (c.act == "watch" or c.act == "rest"):
			ended = true
			break
	K.check(fails, stalked, "cat-squirrel: a hunter stalks the squirrel (%s)" % c.act)
	K.check(
		fails,
		crouched_still,
		"cat-squirrel: stalking low and slow, it does not frighten it off (%s)" % s.state
	)
	K.check(
		fails,
		bolted and treed,
		"cat-squirrel: it goes up its tree as the cat closes in (%s)" % s.state
	)
	# A clean pounce ends in a groom; one the squirrel hops out of mid-stalk ends in a watch.
	K.check(fails, ended, "cat-squirrel: the bout ends, in a groom or a watch (%s)" % c.act)
	# With it up out of reach the hunter sits watching it, as it does the perched birds.
	c.hunt_cool = 0.0
	var watched := false
	for _k in range(ceili(12.0 / DT)):
		_step(DT)
		if c.act == "watch" and c.prey.y > home.y + 0.5 * WS.M:
			watched = true
			break
	K.check(fails, watched, "cat-squirrel: then it watches it up the tree (%s)" % c.act)
	cats.call("_drop", c)
	sq_life.remove(s)


## A dog free by a street flock with its birds on the ground: it goes for them (chase), they get
## away (up, or it never reaches them), and it gives up and sniffs where they went.
func _check_dog_chase() -> void:
	# No cats about, so the chaser's only game is the flock.
	FeatureFlags.set_override("cats", false)
	cats.clear()
	var s := _spot_of(pigeons, true)
	K.check(fails, not s.is_empty(), "fixture: a street that keeps a flock")
	if s.is_empty():
		return
	var home: Vector3 = s["home"]
	var run: Vector3 = s["run"]
	ctx.player.teleport(home + Vector3(20.0 * WS.M, 0.0, 0.0), 0.0)
	_step(0.8)
	var flk: FLOCK.Flock = null
	var key := str(s["key"])
	for e: FLOCK.Flock in pigeons.flock.flocks:
		if str(e.key) == key:
			flk = e
	if flk == null:
		K.check(fails, false, "fixture: the flock comes out (%s)" % key)
		return
	ctx.player.teleport(home + Vector3(60.0 * WS.M, 0.0, 0.0), 0.0)
	var at := home - run * 3.0 * WS.M
	var d := _chaser("test:chaser", at, atan2(home.x - at.x, home.z - at.z), home)
	if d == null:
		return
	var start := _flat(d.pos, home) / WS.M
	var chased := false
	var up := false
	var sniffed := false
	var nearest := start
	for _k in range(ceili(10.0 / DT)):
		_step(DT)
		if d.act == "chase" and d.chase == key:
			chased = true
			nearest = minf(nearest, _flat(d.pos, home) / WS.M)
			var all_air := true
			for b: FLOCK.Bird in flk.birds:
				all_air = all_air and b.air
			up = up or all_air
		elif chased and d.act == "sniff" and d.chase == "":
			sniffed = true
			break
	K.check(fails, chased, "chase: the dog goes for the pigeons on the ground (%s)" % d.chase)
	K.check(
		fails,
		up or nearest > 1.0,
		"chase: the birds get away (up, or it never reaches them: %.1f m away)" % nearest
	)
	K.check(fails, sniffed, "chase: it gives up and sniffs where they went (%s)" % d.act)
	f.call("_drop", d)
	FeatureFlags.set_override("cats", true)


## With no pigeons on the ground about and a flock perched on a lamp: a hunter cat by the lamp
## sits watching them — still, its eyes up on the nearest — until the bout ends and it rests; the
## perched birds reach it through the feature's wiring.
func _check_cat_watches() -> void:
	# No pigeons feeding about: the birds worth watching are the perched ones; no squirrels
	# about either, or a hunter would sooner stalk one.
	FeatureFlags.set_override("pigeons", false)
	pigeons.clear()
	FeatureFlags.set_override("squirrels", false)
	(f.get("squirrels") as Node).call("clear")
	var s := _spot_of(perches, false)
	K.check(fails, not s.is_empty(), "fixture: a street that keeps a perch")
	if s.is_empty():
		return
	var home: Vector3 = s["home"]
	ctx.player.teleport(home + Vector3(20.0 * WS.M, 0.0, 0.0), 0.0)
	_step(0.8)
	var perched := false
	for e: FLOCK.Flock in perches.flock.flocks:
		if str(e.key) == str(s["key"]):
			perched = true
	if not perched:
		K.check(fails, false, "fixture: the perch's birds come out (%s)" % str(s["key"]))
		return
	var stand := _ground_near(home)
	if not stand.is_finite():
		K.check(fails, false, "fixture: a spot under the perch to stand")
		return
	ctx.player.teleport(home + Vector3(40.0 * WS.M, 0.0, 20.0 * WS.M), 0.0)
	var b := cats.bodies.make("cat", 1.0, cats)
	if b == null:
		K.check(fails, false, "fixture: the test's cat comes out")
		return
	var c := cats.life.add(b, stand, 0.0, Rect2())
	c.hunter = true
	c.meow_t = 1e9
	c.hunt_cool = 0.0
	_step(DT)
	var seen_up := cats.life.birds_up.size() > 0
	var watched := false
	var look := Vector3.INF
	var rested := false
	for _k in range(ceili(18.0 / DT)):
		_step(DT)
		if c.act == "watch":
			watched = true
			look = (c.body.rig as CAT_RIG).look
		elif watched and c.act == "rest":
			rested = true
			break
	K.check(fails, seen_up, "watch: the perched birds reach the cats' world")
	K.check(
		fails,
		watched and c.speed < 0.05 * WS.M and look.distance_to(c.prey) < 0.5 * WS.M,
		"watch: a hunter sits watching them, eyes up (%s)" % c.act
	)
	K.check(fails, rested, "watch: the bout ends and it rests again (%s)" % c.act)


func _check_self_test() -> void:
	var st := f.self_test()
	K.check(fails, bool(st["ok"]), "self_test: %s" % st["detail"])


func _check_teardown() -> void:
	f.teardown()
	K.check(fails, pack.dogs.is_empty() and cats.life.cats.is_empty(), "teardown: no animals left")


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
