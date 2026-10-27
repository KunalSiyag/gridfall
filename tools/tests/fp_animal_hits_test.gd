extends SceneTree
## Animal hits (flag "animal_hits"; docs/fp/ARCHITECTURE.md, Animals and Body actions): a kick or a
## weapon swing of the hero's lands on the dog, cat or pigeon in front (the animals feature's
## strike). A struck cat yowls, is knocked away and bolts, skittish from then on; a fist goes over
## it, a kick and a bat land (actions' animal_hits, weapon_hit "animal", a hit-stop and a shake). A
## struck pigeon is knocked up and away in a puff of feathers and its flock goes up; one in the air
## is out of reach. A struck dog yelps, is knocked away and flinches, then runs off whining, shy of
## the hero; a barky dog struck lightly turns on the hero instead; one behind the hero or out of
## reach is not hit. animal_hit tells the bus; the flag off lets every blow through. Third person on
## a grown city; time runs through the features' tick(1/60), traffic's step and the player's
## update_view.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const AF := preload("res://scripts/fp/animals/animals_feature.gd")
const PACK := preload("res://scripts/fp/animals/dog_pack.gd")
const CATS := preload("res://scripts/fp/animals/cats.gd")
const LIFE := preload("res://scripts/fp/animals/cat_life.gd")
const PG := preload("res://scripts/fp/animals/pigeons.gd")
const FLOCK := preload("res://scripts/fp/animals/pigeon_flock.gd")
const DT := 1.0 / 60.0
const KICK := 0.75

var fails: Array[String] = []
var ctx: FpContext
var traffic: FpFeature
var f: FpFeature
var act: FpFeature
var feel: FpFeature
var melee: FpFeature
## The actions feature's constants (KICK_REACH, CONE).
var ac: Dictionary = {}
## Every animal_called call, animal_hit [kind, strength], weapon_hit what, and toast.
var calls: Array[String] = []
var hits: Array = []
var weapon_on: Array[String] = []
var toasts: Array[String] = []


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	traffic = K.make_feature(ctx, "traffic")
	f = K.make_feature(ctx, "animals")
	act = K.make_feature(ctx, "actions")
	feel = K.make_feature(ctx, "hit_feel")
	melee = K.make_feature(ctx, "melee")
	if traffic == null or f == null or act == null or feel == null or melee == null:
		K.check(fails, false, "fixture: traffic, animals, actions, hit_feel and melee registered")
		K.finish(self, "FP_ANIMAL_HITS_TEST", fails)
		return
	traffic.set("auto_step", false)
	traffic.set("ambient_enabled", false)
	for n: FpFeature in [f, act, feel, melee]:
		n.set_process(false)
	ac = (act.get_script() as GDScript).get_script_constant_map()
	K.quiet_walkers(traffic)
	_no_dogs_at_home()
	ctx.bus.animal_called.connect(func(_at: Vector3, c: String, _s: float) -> void: calls.append(c))
	ctx.bus.animal_hit.connect(
		func(_at: Vector3, kind: String, s: float) -> void: hits.append([kind, s])
	)
	ctx.bus.weapon_hit.connect(
		func(_at: Vector3, _k: String, what: String, _b: bool) -> void: weapon_on.append(what)
	)
	ctx.bus.toast.connect(func(t: String, _k: String) -> void: toasts.append(t))
	ctx.sky.fixed_hour = 12.0
	ctx.sky.hour = 12.0
	ctx.sky.night = 0.0
	_check_cat()
	_check_pigeon()
	_check_dog()
	_check_teardown()
	K.finish(self, "FP_ANIMAL_HITS_TEST", fails)


# ------------------------------------------------------------------ helpers


## Steps traffic, the animals and the player secs (in 1/60 s steps).
func _step(secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		traffic.call("step", DT)
		f.call("tick", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)


## Steps the hero's swing alone secs (the animals stand still for it).
func _swing(secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		act.call("tick", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)


## Nobody in the city lives with a dog but the test's own owner.
func _no_dogs_at_home() -> void:
	for r: Dictionary in ctx.residents.people:
		if str(r.get("household", "")) == AF.DOG_HOUSEHOLD:
			r["household"] = "lives alone"


## The hero dist_m metres from at along way, facing it.
func _hero_at(at: Vector3, way: Vector3, dist_m: float) -> void:
	var p := at + way * dist_m * WS.M
	var look := at - p
	ctx.player.teleport(p, rad_to_deg(atan2(-look.x, -look.z)))


## A kick at what stands dist_m off along way (from that side): animals' strike.
func _kick_at(at: Vector3, way: Vector3, dist_m: float, strength: float = KICK) -> Dictionary:
	var feet := at + way * dist_m * WS.M
	feet.y = at.y
	return f.call("strike", feet, -way, float(ac["KICK_REACH"]), float(ac["CONE"]), strength)


func _toasted(part: String) -> bool:
	return toasts.any(func(t: String) -> bool: return part in t)


## The cat back on its spot, a friendly homebody resting in pose, calm.
func _calm(life: LIFE, c: LIFE.Cat) -> void:
	c.pos = c.anchor
	c.speed = 0.0
	c.push = Vector3.ZERO
	c.temper = "friendly"
	c.hunter = false
	c.scared = 0.0
	life.call("_rest", c, &"Sit")
	c.act_t = 1e9


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# ------------------------------------------------------------------ cats


## The first shop or house cat's spot ({} for none) and its cat brought out by day.
func _cat_spot() -> Dictionary:
	var cats: CATS = f.get("cats")
	for kind: String in ["shop", "house"]:
		for i in range(ctx.sim.kind.size()):
			var s: Dictionary = cats.call("_spot_of", i, {})
			if not s.is_empty() and str(s["kind"]) == kind:
				return s
	return {}


## A kick on a cat: it yowls (animal_called "yowl"), is knocked away at KNOCK + KNOCK_K x strength
## and bolts, frightened HIT_FEAR times as long and skittish from then on; animal_hit and a toast.
## Then through the actions feature: a punch goes over it, a kick and a bat swing land.
func _check_cat() -> void:
	var cats: CATS = f.get("cats")
	cats.bodies.blocking = true
	var spot := _cat_spot()
	K.check(fails, not spot.is_empty(), "fixture: a shop or a house that keeps a cat")
	if spot.is_empty():
		return
	var yaw := float(spot["yaw"])
	var along := Vector3(cos(yaw), 0.0, -sin(yaw))
	_hero_at(spot["anchor"], along, 8.0)
	f.on_world_rebuilt()
	_step(0.1)
	var life := cats.life
	var key := "c:%d" % int(spot["lot"])
	var c: LIFE.Cat = null
	for k: LIFE.Cat in life.cats:
		if k.key == key:
			c = k
	K.check(fails, c != null, "fixture: the spot's cat is out")
	if c == null:
		return
	_calm(life, c)
	calls.clear()
	hits.clear()
	var at := c.pos
	var r := _kick_at(at, along, 0.9)
	var knock := LIFE.KNOCK + LIFE.KNOCK_K * KICK
	var pushed := absf(c.push.length() - knock) < 1e-3 and c.push.dot(-along) > 0.0
	K.check(
		fails,
		str(r.get("kind", "")) == "cat" and str(r.get("name", "")) == c.name and "yowl" in calls,
		"cat: a kick lands on %s, who yowls (%s)" % [c.name, str(r)]
	)
	var scared := is_equal_approx(c.scared, LIFE.SCARED_S * LIFE.HIT_FEAR)
	K.check(
		fails,
		pushed and c.act == "flee" and c.temper == "skittish" and scared,
		(
			"cat: knocked away (%.2f u/s), it bolts (%s), skittish and scared %.1f s"
			% [c.push.length(), c.act, c.scared]
		)
	)
	K.check(
		fails,
		hits == [["cat", KICK]] and _toasted("yowls and bolts"),
		"cat: animal_hit (%s) and a toast" % str(hits)
	)
	_step(0.5)
	var off := _flat(c.pos, at) / WS.M
	K.check(fails, off > 0.4, "cat: half a second on it is %.2f m from where it was struck" % off)
	_check_cat_actions(life, c, along)


## Through the actions feature, facing the calm cat 1 m off: a punch goes over it, a kick lands
## (animal_hits, a hit-stop and a shake) and so does a bat swing (weapon_hit "animal").
func _check_cat_actions(life: LIFE, c: LIFE.Cat, along: Vector3) -> void:
	_calm(life, c)
	_hero_at(c.pos, along, 1.0)
	_swing(0.1)
	calls.clear()
	hits.clear()
	var struck := int(f.get("struck"))
	act.call("strike")
	_swing(0.8)
	K.check(
		fails,
		int(f.get("struck")) == struck and hits.is_empty() and not "yowl" in calls,
		"actions: a punch goes over the cat"
	)
	var stops := int(feel.get("stops"))
	var shakes := int(feel.get("shakes"))
	var kicked: bool = act.call("strike", "kick")
	_swing(0.45)
	feel.call("tick", 1.0)
	K.check(
		fails,
		kicked and hits.size() == 1 and int(act.get("animal_hits")) == 1 and "yowl" in calls,
		"actions: a kick lands on the cat (%s)" % str(hits)
	)
	K.check(
		fails,
		int(feel.get("stops")) > stops and int(feel.get("shakes")) > shakes,
		"hit feel: a blow on an animal stops the world a moment and shakes the camera"
	)
	K.check(fails, is_equal_approx(Engine.time_scale, 1.0), "hit feel: the time scale comes back")
	_swing(0.8)
	_calm(life, c)
	melee.call("from_dict", {"held": "bat"})
	weapon_on.clear()
	var swung: bool = act.call("strike") and str(act.get("swing")) == "swing"
	_swing(0.8)
	feel.call("tick", 1.0)
	K.check(
		fails,
		swung and hits.size() == 2 and weapon_on == ["animal"],
		"actions: a bat swing lands on the cat (weapon_hit %s)" % str(weapon_on)
	)
	melee.call("drop")


# ------------------------------------------------------------------ pigeons


## The first flock spot on a sidewalk, else {}.
func _pigeon_spot() -> Dictionary:
	var pg: PG = f.get("pigeons")
	for i in range(ctx.sim.kind.size()):
		if PG.FRONTS.has(ctx.sim.kind[i]):
			var s: Dictionary = pg.call("_spot_of", i)
			if not s.is_empty():
				return s
	return {}


## A kick at a pigeon on the ground: it is knocked up and away in a puff of feathers (pigeons'
## Feathers particles) and the whole flock goes up; one in the air is out of reach.
func _check_pigeon() -> void:
	var pg: PG = f.get("pigeons")
	var spot := _pigeon_spot()
	K.check(fails, not spot.is_empty(), "fixture: a sidewalk where pigeons keep")
	if spot.is_empty():
		return
	var run: Vector3 = spot["run"]
	_hero_at(spot["home"], run, 8.0)
	f.on_world_rebuilt()
	_step(0.1)
	var fk := _flock_of(pg, "s:%d" % int(spot["lot"]))
	K.check(fails, fk != null and not fk.birds.is_empty(), "fixture: the spot's flock is out")
	if fk == null or fk.birds.is_empty():
		return
	var b: FLOCK.Bird = fk.birds[0]
	for o: FLOCK.Bird in fk.birds:
		if not o.air and o.pos.dot(run) > b.pos.dot(run):
			b = o
	var before := {}
	for o: FLOCK.Bird in fk.birds:
		before[o] = o.pos
	hits.clear()
	var r := _kick_at(b.pos, run, 0.6)
	var hit: FLOCK.Bird = null
	for o: FLOCK.Bird in fk.birds:
		if (before[o] as Vector3).is_equal_approx(r.get("pos", Vector3.INF)):
			hit = o
	var knocked := hit != null and hit.air and hit.vel.y > 0.0 and hit.vel.dot(-run) > 0.0
	K.check(
		fails,
		str(r.get("kind", "")) == "pigeon" and knocked and hits == [["pigeon", KICK]],
		"pigeon: a kick knocks a pigeon up and away (animal_hit %s)" % str(hits)
	)
	var puff := pg.find_child("Feathers", false, false) as CPUParticles3D
	K.check(
		fails,
		puff != null and puff.emitting and puff.amount == PG.FEATHERS,
		"pigeon: in a puff of %d feathers" % PG.FEATHERS
	)
	_step(1.5)
	var up := fk.birds.all(func(o: FLOCK.Bird) -> bool: return o.air)
	K.check(fails, up, "pigeon: the whole flock goes up")
	_check_high_bird(fk, run, (before[b] as Vector3).y)


func _flock_of(pg: PG, key: String) -> FLOCK.Flock:
	for k: FLOCK.Flock in pg.flock.flocks:
		if k.key == key:
			return k
	return null


## A kick right under a bird of fk in the air (the ground at ground) does not reach it.
func _check_high_bird(fk: FLOCK.Flock, run: Vector3, ground: float) -> void:
	var flier: FLOCK.Bird = fk.birds[0]
	var feet := flier.pos + run * 0.5 * WS.M
	feet.y = ground
	var high: Dictionary = f.call(
		"strike", feet, -run, float(ac["KICK_REACH"]), float(ac["CONE"]), KICK
	)
	var up_m := (flier.pos.y - ground) / WS.M
	K.check(
		fails,
		up_m > AF.BIRD_LOW / WS.M and high.is_empty(),
		"pigeon: one %.1f m up, right over the kick, is out of reach (%s)" % [up_m, str(high)]
	)


# ------------------------------------------------------------------ dogs


## The first resident with a home, made to live with a dog and to be out (state).
func _owner(state: String) -> Dictionary:
	for r: Dictionary in ctx.residents.people:
		if int(r.get("home", -1)) >= 0:
			r["household"] = AF.DOG_HOUSEHOLD
			r["state"] = state
			return r
	return {}


## A kick on a friendly dog: it yelps, is knocked away and flinches, then runs off whining, shy of
## the hero from then on. A barky one struck lightly turns on the hero instead. A dog behind the
## kick or out of its reach is not hit, nor any with the flag off.
func _check_dog() -> void:
	var walk := K.sidewalk(ctx, 0.6)
	var r := _owner("park")
	K.check(fails, not walk.is_empty() and not r.is_empty(), "fixture: a sidewalk and an owner")
	if walk.is_empty() or r.is_empty():
		return
	ctx.player.teleport(walk["pos"], float(walk["yaw"]))
	var wk: WK = traffic.get("walkers")
	var w := wk.make("resident")
	w.extra = 0
	w.resident_id = str(r["id"])
	var run: Vector3 = walk["run"]
	wk.stand(w, (walk["pos"] as Vector3) + run * 0.05, atan2(run.x, run.z))
	_step(AF.SCAN_S + 0.1)
	var pack: PACK = f.get("pack")
	var d: PACK.Dog = null
	for k: PACK.Dog in pack.dogs:
		if k.walker == w.id:
			d = k
	K.check(fails, d != null, "fixture: the owner's dog is out on its lead")
	if d == null:
		return
	var side := Vector3(-run.z, 0.0, run.x)
	hits.clear()
	var behind: Dictionary = f.call(
		"strike", d.pos + side * 0.8 * WS.M, side, float(ac["KICK_REACH"]), float(ac["CONE"]), KICK
	)
	var far := _kick_at(d.pos, side, 3.0)
	K.check(
		fails,
		behind.is_empty() and far.is_empty() and hits.is_empty(),
		"dog: not hit behind the kick or out of its reach"
	)
	FeatureFlags.set_override("animal_hits", false)
	var off := _kick_at(d.pos, side, 0.8)
	FeatureFlags.set_override("animal_hits", true)
	K.check(fails, off.is_empty() and hits.is_empty(), "flag: off, a kick goes through the dog")
	d.temper = "friendly"
	d.angry = 0.0
	calls.clear()
	var at := d.pos
	var hit := _kick_at(at, side, 0.8)
	var knock := PACK.KNOCK + PACK.KNOCK_K * KICK
	var pushed := absf(d.push.length() - knock) < 1e-3 and d.push.dot(-side) > 0.0
	K.check(
		fails,
		str(hit.get("kind", "")) == "dog" and "yelp" in calls and _toasted("yelps and runs off"),
		"dog: a kick lands on %s, who yelps (%s)" % [d.name, str(hit)]
	)
	K.check(
		fails,
		pushed and d.act == "flinch" and hits == [["dog", KICK]],
		"dog: knocked away (%.2f u/s), it flinches (%s)" % [d.push.length(), d.act]
	)
	_step(PACK.HIT_FLINCH + 0.1)
	K.check(
		fails,
		d.act == "flee" and d.temper == "shy" and "whine" in calls,
		"dog: then runs off whining (%s), shy of the hero (%s)" % [d.act, d.temper]
	)
	_step(PACK.HIT_FLEE)
	d.temper = "barky"
	d.angry = 0.0
	toasts.clear()
	var light := _kick_at(d.pos, side, 0.8, 0.4)
	K.check(
		fails,
		not light.is_empty() and d.angry > 0.0 and _toasted("goes for you"),
		"dog: a barky dog struck lightly turns on the hero (angry %.1f s)" % d.angry
	)
	d.angry = 0.0
	_step(0.5)
	wk.remove(w)


func _check_teardown() -> void:
	var st := act.self_test()
	K.check(
		fails,
		bool(st["ok"]) and "2 on animals" in str(st["detail"]),
		"self_test: %s" % st["detail"]
	)
	var fs := f.self_test()
	K.check(fails, bool(fs["ok"]), "animals self_test: %s" % fs["detail"])
	for n: FpFeature in [melee, feel, act, f]:
		n.teardown()
	K.check(fails, is_equal_approx(Engine.time_scale, 1.0), "teardown: the time scale is 1")
