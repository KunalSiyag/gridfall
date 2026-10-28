extends SceneTree
## Cats (the animals feature; docs/fp/ARCHITECTURE.md, Animals): a shop's or a house's cat comes out
## near the player in its coat (one shared coat material per coat) and stays in in the rain; it
## rests in its poses and strolls round its spot; a friendly cat comes over to a crouching hero and
## meows; E picks it and pets it (it purrs), an aloof cat walks off from the first pet, a skittish
## one hisses and runs and runs from the hero walking up; a shout makes it jump and run with its
## tail low; a dog close by makes it hiss and then run; a car coming makes it bolt; a hunter
## chatters at a pigeon, stalks it, crouches and pounces, then grooms; a cat stalking a flock does
## not send it up but its pounce does; pause freezes it; strays come out only at night; a grown
## city keeps a fair share of cats; beyond FAR
## they go and come back; the flag off takes them away; the photo shot; a fresh city (only the
## founding roads and City Hall) keeps one ambient stray near the player, day and night, in from
## the rain, and none once the city has grown; self_test and teardown.
## Third person on a grown city; the behaviour is stepped directly (cat_life.gd step) where the
## test sets the world, else through traffic's step and the feature's tick(1/60).

const K := preload("res://tools/tests/fp_kit.gd")
const FRESH := preload("res://tools/tests/fp_fresh_city.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const AF := preload("res://scripts/fp/animals/animals_feature.gd")
const CATS := preload("res://scripts/fp/animals/cats.gd")
const LIFE := preload("res://scripts/fp/animals/cat_life.gd")
const SLOD := preload("res://scripts/fp/animals/settle_lod.gd")
const FT := preload("res://scripts/fp/forest_trees.gd")
const CB := preload("res://scripts/fp/animals/cat_bodies.gd")
const FLOCK := preload("res://scripts/fp/animals/pigeon_flock.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []
var ctx: FpContext
var traffic: FpFeature
var f: FpFeature
var cats: CATS
var life: LIFE
## The spot the test's cat keeps to (cats.gd _spot_of()), its key and the way along its street.
var spot: Dictionary = {}
var key: String = ""
var along := Vector3.RIGHT
## Every animal_called [call, size] and every toast.
var calls: Array = []
var toasts: Array[String] = []


func _init() -> void:
	K.watchdog(self, "FP_CATS_TEST")
	await process_frame
	# Pigeon flocks about would draw the cat's hunts (the hunt check brings its own).
	FeatureFlags.set_override("pigeons", false)
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	traffic = K.make_feature(ctx, "traffic")
	f = K.make_feature(ctx, "animals")
	if traffic == null or f == null:
		K.check(fails, false, "fixture: traffic and animals registered")
		K.finish(self, "FP_CATS_TEST", fails)
		return
	traffic.set("auto_step", false)
	traffic.set("ambient_enabled", false)
	f.set_process(false)
	cats = f.get("cats")
	cats.bodies.blocking = true
	life = cats.life
	ctx.sky.fixed_hour = 12.0
	ctx.sky.hour = 12.0
	ctx.sky.night = 0.0
	_quiet()
	ctx.bus.animal_called.connect(
		func(_at: Vector3, c: String, s: float) -> void: calls.append([c, s])
	)
	ctx.bus.toast.connect(func(t: String, _k: String) -> void: toasts.append(t))
	spot = _find_spot("shop")
	if spot.is_empty():
		spot = _find_spot("house")
	K.check(fails, not spot.is_empty(), "fixture: a shop or a house that keeps a cat")
	if not spot.is_empty():
		key = "c:%d" % int(spot["lot"])
		var yaw := float(spot["yaw"])
		along = Vector3(cos(yaw), 0.0, -sin(yaw))
		_run(_check_spawn())
		_check_strays()
		_check_density()
		_check_far()
		_check_flag()
	_check_photo()
	_check_fresh_city()
	_check_teardown()
	K.finish(self, "FP_CATS_TEST", fails)


func _run(c: LIFE.Cat) -> void:
	if c == null:
		return
	_check_rest(c)
	_check_greet(c)
	_check_pet(c)
	_check_shy(c)
	_check_startle(c)
	_check_dog(c)
	_check_car(c)
	_check_hunt(c)
	_check_pounce_flock(c)
	_check_pause(c)
	_check_lod(c)
	_check_wood_refuge(c)


# ------------------------------------------------------------------ helpers


## Steps traffic and the animals secs (in 1/60 s steps).
## A cat at leisure far from the hero ticks at 4 Hz (settle_lod.gd): short ticks bank until
## SETTLE_S, then it steps once with the banked time. The hero coming close, or anything active
## (a hunt here), runs at full rate.
func _check_lod(c: LIFE.Cat) -> void:
	_reset(c)
	life.hero_on_foot = true
	life.hero_vel = Vector3.ZERO
	life.dogs = []
	life.cars = []
	life.prey = []
	life.passers = []
	var far := c.pos + Vector3(SLOD.NEAR * 2.0, 0.0, 0.0)
	life.hero = far
	c.hz_t = 0.0
	var t0: float = c.act_t
	for _k in range(3):
		life.step(0.05)
	K.check(fails, c.act_t == t0 and c.hz_t > 0.0, "lod: a resting far cat banks short ticks")
	for _k in range(2):
		life.step(0.05)
	# The banked 0.25 s steps it once: the nap resets, and the time came off the act's clock
	# (act_t counts the seconds left; the rest ending and a new act beginning also proves it).
	K.check(
		fails,
		c.hz_t == 0.0 and (c.act_t < t0 - 0.24 or c.act != "rest"),
		"lod: the banked time steps it at the slow cadence"
	)
	life.hero = c.pos + Vector3(SLOD.NEAR * 0.5, 0.0, 0.0)
	c.hz_t = 0.0
	life.step(0.05)
	K.check(fails, c.hz_t == 0.0, "lod: the hero close by keeps the full rate")
	life.hero = far
	c.act = "stalk"
	c.hz_t = 0.0
	life.step(0.05)
	K.check(fails, c.hz_t == 0.0, "lod: a hunt runs at full rate however far")
	_reset(c)


## A cat cornered in the woods — the forest tiles carry no trunk colliders — bolts up one of
## the tile's own trees: forest_trees.gd's hash, the same trees city_view.gd draws.
func _check_wood_refuge(c: LIFE.Cat) -> void:
	var clear := -1
	for i in range(ctx.sim.kind.size()):
		if not _trunks_near(i):
			clear = i
			break
	K.check(fails, clear >= 0, "woods: a clearing with no trunk cylinder about")
	if clear < 0:
		return
	var at := Vector3(D.tx(clear), 0.0, D.ty(clear))
	c.pos = at
	c.act = "rest"
	c.tree = []
	var kinds := PackedInt32Array()
	kinds.resize(ctx.sim.kind.size())
	for dy: int in [-1, 0, 1]:
		for dx: int in [-1, 0, 1]:
			var x := D.tx(clear) + dx
			var y := D.ty(clear) + dy
			if D.in_bounds(x, y):
				kinds[D.idx(x, y)] = D.FOREST
	life.kinds = kinds
	var t: Array = life.call("_refuge", c)
	K.check(fails, not t.is_empty(), "woods: a trunk the hash plants is the refuge")
	var drawn := false
	for dy: int in [-1, 0, 1]:
		for dx: int in [-1, 0, 1]:
			for k in range(FT.N):
				if FT.tree(D.tx(clear) + dx, D.ty(clear) + dy, k) == t:
					drawn = true
	K.check(fails, drawn, "woods: the refuge is a tree the view really draws")
	# A dog charging at it sends it up that trunk.
	life.hero = Vector3(INF, INF, INF)
	life.hero_on_foot = false
	life.prey = []
	var dog := at + Vector3(0.06, 0.0, 0.0)
	life.dogs = [[dog, (at - dog).normalized() * 3.0 * WS.M]]
	# A resting cat this far from the hero may bank the first ticks (settle_lod.gd): the dog's
	# charge registers within the slow cadence, so give it a nap's worth of ticks.
	var went_up := false
	for _k in range(20):
		life.step(DT)
		if c.act in ["flee", "climb", "hold"] and not c.tree.is_empty():
			went_up = true
			break
	K.check(fails, went_up, "woods: the charging dog sends it up the tree (%s)" % c.act)
	life.dogs = []
	life.kinds = PackedInt32Array()
	_reset(c)


## True when the 3x3 tiles round tile i hold a trunk cylinder a cat could climb.
func _trunks_near(i: int) -> bool:
	for dy: int in [-1, 0, 1]:
		for dx: int in [-1, 0, 1]:
			var x := D.tx(i) + dx
			var y := D.ty(i) + dy
			if not D.in_bounds(x, y):
				continue
			var cyls: PackedFloat32Array = ctx.collision.cylinders(D.idx(x, y))
			var j := 0
			while j + 3 < cyls.size():
				if cyls[j + 2] >= LIFE.TRUNK_MIN_R and cyls[j + 3] >= LIFE.TREE_TOP:
					return true
				j += 4
	return false


func _step(secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		traffic.call("step", DT)
		f.call("tick", DT)


## Steps the cats' behaviour alone secs with the hero on foot at hero moving at vel (crouched or
## not), dogs and cars ([pos, vel, ...]) and pigeons on the ground at prey; each(cat) after every
## step when given.
func _live(secs: float, hero: Vector3, opts: Dictionary = {}, each: Callable = Callable()) -> void:
	var vel: Vector3 = opts.get("vel", Vector3.ZERO)
	for _k in range(ceili(secs / DT - 1e-6)):
		life.hero = hero
		life.hero_vel = vel
		life.hero_on_foot = true
		life.crouched = bool(opts.get("crouched", false))
		life.dogs = opts.get("dogs", [])
		life.cars = opts.get("cars", [])
		life.prey = opts.get("prey", [])
		life.passers = []
		life.time_scale = 1.0
		life.step(DT)
		hero += vel * DT
		if each.is_valid():
			for c: LIFE.Cat in life.cats:
				each.call(c)


## Nobody walks about and nobody lives with a dog, so only the test's frights are about.
func _quiet() -> void:
	var wk: WK = traffic.get("walkers")
	for w: WK.Walker in wk.walkers.duplicate():
		wk.remove(w)
	for r: Dictionary in ctx.residents.people:
		if str(r.get("household", "")) == AF.DOG_HOUSEHOLD:
			r["household"] = "lives alone"


## The first cat spot of kind, else {}.
func _find_spot(kind: String) -> Dictionary:
	for i in range(ctx.sim.kind.size()):
		var s: Dictionary = cats.call("_spot_of", i, {})
		if not s.is_empty() and str(s["kind"]) == kind:
			return s
	return {}


func _cat(k: String = "") -> LIFE.Cat:
	for c: LIFE.Cat in life.cats:
		if c.key == (key if k.is_empty() else k):
			return c
	return null


## The hero m metres along the street from at, facing it.
func _hero_at(at: Vector3, m: float) -> void:
	var p := at + along * m * WS.M
	var look := at - p
	ctx.player.teleport(p, rad_to_deg(atan2(-look.x, -look.z)))


## The cat back on its spot, a friendly homebody resting in pose, calm.
func _reset(c: LIFE.Cat, pose: StringName = &"Sit") -> void:
	c.pos = c.anchor
	c.speed = 0.0
	c.temper = "friendly"
	c.hunter = false
	c.scared = 0.0
	c.snubbed = false
	c.meow_t = 1e9
	c.hunt_cool = 0.0
	life.call("_rest", c, pose)
	c.act_t = 1e9


func _heard(c: String) -> float:
	for e: Array in calls:
		if str(e[0]) == c:
			return float(e[1])
	return -1.0


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# ------------------------------------------------------------------ checks


## By day the scan brings out the spot's cat on its spot, in the Quaternius cat's body with the coat
## shader and its coat's colours; the rain takes it in and it comes out again after.
func _check_spawn() -> LIFE.Cat:
	_hero_at(spot["anchor"], 8.0)
	f.on_world_rebuilt()
	_step(0.1)
	var c := _cat()
	K.check(
		fails,
		c != null and _flat(c.pos, spot["anchor"]) < 0.2 * WS.M,
		"spawn: the %s's cat comes out on its spot" % str(spot["kind"])
	)
	if c == null:
		return null
	var mi: MeshInstance3D = null
	for n: Node in c.body.root.find_children("*", "MeshInstance3D", true, false):
		mi = n as MeshInstance3D
	var coat_mat := mi.material_override as ShaderMaterial if mi != null else null
	var dressed := coat_mat != null and coat_mat == CB.material_for(c.coat)
	dressed = dressed and coat_mat.get_shader_parameter(&"look") == CB.COATS[c.coat][3]
	var clips := c.body.ap != null and c.body.ap.has_animation(&"Loaf")
	K.check(
		fails,
		dressed and clips and c.body.rig is CB.CAT_RIG and not c.name.is_empty(),
		"spawn: %s, a %s %s cat in the cat's body and its coat" % [c.name, c.temper, c.coat]
	)
	K.check(
		fails,
		(
			c.body.skel != null
			and (
				c.body.skel.modifier_callback_mode_process
				== Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
			)
		),
		"spawn: the CatRig runs on the idle frame, not once per physics frame"
	)
	K.check_modifier_modes(fails, get_root())
	cats.scan(ctx.player.position, false, true, {})
	var gone := _cat() == null
	_step(AF.SCAN_S + 0.1)
	c = _cat()
	K.check(fails, gone and c != null, "spawn: the rain takes it in; after it, it comes out again")
	return c


## A minute and a half with the hero 10 m off: it rests in more than one pose and strolls (Walk),
## keeping near its spot and off the road.
func _check_rest(c: LIFE.Cat) -> void:
	_reset(c)
	c.act_t = 2.0
	var hero := c.anchor + along * 10.0 * WS.M
	var seen := {}
	var got := {"far": 0.0, "road": false}
	var watch := func(x: LIFE.Cat) -> void:
		seen[x.body.clip] = true
		got["far"] = maxf(got["far"], _flat(x.pos, x.anchor))
		got["road"] = got["road"] or ctx.collision.surface_at(x.pos) == "asphalt"
	_live(90.0, hero, {}, watch)
	var poses := 0
	for p: StringName in LIFE.RESTS:
		poses += 1 if seen.has(p) else 0
	K.check(
		fails,
		poses >= 2 and seen.has(&"Walk"),
		"rest: it rests in %d poses and strolls (%s)" % [poses, str(seen.keys())]
	)
	K.check(
		fails,
		float(got["far"]) < LIFE.ROAM + 0.5 * WS.M and not got["road"],
		"rest: it keeps near its spot (%.1f m) and off the road" % (float(got["far"]) / WS.M)
	)


## A friendly cat comes over to the hero crouching 3 m off and meows (at a cat's size); with the
## hero up and walking off, it stops.
func _check_greet(c: LIFE.Cat) -> void:
	_reset(c)
	calls.clear()
	var hero := c.anchor + along * 3.0 * WS.M
	_live(5.0, hero, {"crouched": true})
	var close := _flat(c.pos, hero) / WS.M
	var meow := _heard("meow")
	K.check(
		fails,
		close < 1.2 and c.act == "greet" and is_equal_approx(meow, life.shoulder_m(c)),
		"greet: it comes over to the crouching hero (%.2f m) and meows (%.2f m)" % [close, meow]
	)
	_live(2.0, hero + along * 8.0 * WS.M)
	K.check(fails, c.act != "greet", "greet: with the hero gone it stops (%s)" % c.act)


## E on it from 1.2 m: the pick, a purr and a toast; an aloof cat walks off from the first pet and
## takes the second; a skittish one hisses and runs.
func _check_pet(c: LIFE.Cat) -> void:
	_reset(c)
	var hero := c.anchor + along * 1.2 * WS.M
	_hero_at(c.anchor, 1.2)
	life.hero = hero
	var eye := ctx.player.eye_position()
	var back := c.pos + Vector3(0.0, 0.2 * WS.M, 0.0)
	var t := f.pick(eye, (back - eye).normalized(), 6.0)
	K.check(
		fails,
		str(t.get("kind", "")) == "cat" and str(t.get("id", "")) == str(c.id),
		"pet: the cat in front is picked (%s)" % str(t.get("label", ""))
	)
	calls.clear()
	toasts.clear()
	ctx.bus.interact_requested.emit(t)
	K.check(
		fails,
		c.act == "purr" and _heard("purr") > 0.0 and cats.pets == 1 and toasts.size() == 1,
		"pet: it purrs (%s)" % str(toasts)
	)
	_reset(c)
	c.temper = "aloof"
	cats.pet({"id": str(c.id)})
	var first := c.act == "stroll"
	var second := false
	if first:
		cats.pet({"id": str(c.id)})
		second = c.act == "purr"
	K.check(
		fails, first and second, "pet: an aloof cat walks off from the first pet, takes the next"
	)
	_reset(c)
	c.temper = "skittish"
	calls.clear()
	cats.pet({"id": str(c.id)})
	K.check(fails, c.act == "flee" and _heard("hiss") > 0.0, "pet: a skittish cat hisses and runs")


## A skittish cat runs from the hero walking up from 5 m; an aloof one walks off from the hero
## walking at it.
func _check_shy(c: LIFE.Cat) -> void:
	_reset(c)
	c.temper = "skittish"
	var acts := {}
	var watch := func(x: LIFE.Cat) -> void: acts[x.act] = true
	_live(2.5, c.anchor + along * 5.0 * WS.M, {"vel": -along * 1.4 * WS.M}, watch)
	K.check(fails, acts.has("flee"), "shy: a skittish cat runs from the hero walking up")
	_reset(c)
	c.temper = "aloof"
	acts.clear()
	_live(1.2, c.anchor + along * 2.0 * WS.M, {"vel": -along * 1.0 * WS.M}, watch)
	K.check(fails, acts.has("stroll"), "shy: an aloof cat walks off from the hero walking at it")


## A shout 4 m off: it jumps (Startle) and runs (Run) over 3 m away with its tail low.
func _check_startle(c: LIFE.Cat) -> void:
	_reset(c)
	var hero := c.anchor + along * 4.0 * WS.M
	ctx.bus.hero_action.emit("shout", hero)
	var jumped := c.act == "startle"
	var clips := {}
	var got := {"droop": 0.0}
	var watch := func(x: LIFE.Cat) -> void:
		clips[x.body.clip] = true
		got["droop"] = maxf(got["droop"], (x.body.rig as CB.CAT_RIG).droop)
	_live(3.0, hero, {}, watch)
	var ran := _flat(c.pos, c.anchor) / WS.M
	var droop := float(got["droop"])
	K.check(
		fails,
		jumped and clips.has(&"Startle") and clips.has(&"Run") and ran > 3.0 and droop > 0.5,
		"startle: a shout makes it jump and run %.1f m, tail low (%.2f)" % [ran, droop]
	)


## A dog standing 3 m off: it hisses at it (Hiss, facing it), then runs from it.
func _check_dog(c: LIFE.Cat) -> void:
	_reset(c)
	calls.clear()
	var dog := c.anchor + along * 3.0 * WS.M
	var hero := c.anchor - along * 20.0 * WS.M
	_live(0.5, hero, {"dogs": [[dog, Vector3.ZERO]]})
	var face := absf(angle_difference(c.yaw, atan2(dog.x - c.pos.x, dog.z - c.pos.z)))
	K.check(
		fails,
		c.act == "hiss" and c.body.clip == &"Hiss" and _heard("hiss") > 0.0 and face < 0.5,
		"dog: it hisses at a dog close by, facing it (%s)" % c.act
	)
	var acts := {}
	var watch := func(x: LIFE.Cat) -> void: acts[x.act] = true
	_live(4.0, hero, {"dogs": [[dog, Vector3.ZERO]]}, watch)
	K.check(
		fails,
		acts.has("flee") and _flat(c.pos, dog) > 4.0 * WS.M,
		"dog: then it runs from it (%.1f m)" % (_flat(c.pos, dog) / WS.M)
	)


## A car coming at it makes it bolt.
func _check_car(c: LIFE.Cat) -> void:
	_reset(c)
	var car := [c.pos - along * 8.0 * WS.M, along * 10.0 * WS.M, 2.3 * WS.M, 1.0 * WS.M]
	_live(DT, c.anchor + along * 20.0 * WS.M, {"cars": [car]})
	K.check(fails, c.act == "flee", "car: a car coming at it makes it bolt (%s)" % c.act)


## A hunter and a pigeon 5 m off: it chatters, stalks (Stalk, slowly), crouches within reach and
## pounces (leaping faster than a running dog), then grooms.
func _check_hunt(c: LIFE.Cat) -> void:
	_reset(c)
	c.hunter = true
	c.act_t = 0.5
	calls.clear()
	var bird := c.anchor + along * 5.0 * WS.M
	var hero := c.anchor - along * 20.0 * WS.M
	var seen := {}
	var got := {"top": 0.0, "stalk": 0.0, "groom": false}
	var watch := func(x: LIFE.Cat) -> void:
		seen[x.act] = true
		got["top"] = maxf(got["top"], x.speed)
		if x.act == "stalk":
			got["stalk"] = maxf(got["stalk"], x.speed)
		var after := seen.has("pounce") and x.act == "rest" and x.rest == &"Groom"
		got["groom"] = got["groom"] or (after and x.hunt_cool > 0.0)
	_live(45.0, hero, {"prey": [bird]}, watch)
	var hunted := seen.has("stalk") and seen.has("crouch") and seen.has("pounce")
	var stalk := float(got["stalk"])
	K.check(
		fails,
		hunted and _heard("chatter") > 0.0 and stalk <= LIFE.STALK * 1.01,
		"hunt: it chatters, stalks (%.2f m/s), crouches and pounces" % (stalk / WS.M)
	)
	K.check(
		fails,
		float(got["top"]) >= FLOCK.DOG_RUN_MPS and got["groom"],
		"hunt: it leaps (%.1f m/s) and then grooms" % (float(got["top"]) / WS.M)
	)


## A flock at a park-like spot: a cat creeping 1.6 m from the nearest bird leaves it be, the same
## cat pouncing sends it up; a dog there sends it up too.
func _check_pounce_flock(c: LIFE.Cat) -> void:
	var fl := FLOCK.new()
	fl.col = ctx.collision
	var home := c.anchor
	var fk := fl.add("test", home, 0.05, Vector3.ZERO, Vector3.ZERO, 6)
	var out := home + along * (0.05 + 1.6 * WS.M)
	var slow := along * -LIFE.STALK
	var results: Array = []
	for who: Array in [[slow, FLOCK.CAT_NEAR], [along * -LIFE.LEAP, FLOCK.CAT_NEAR], [slow]]:
		for b: FLOCK.Bird in fk.birds:
			b.air = false
			b.delay = 0.0
			b.act = ""
			b.pos = home
		fk.alarm = 0.0
		for _k in range(40):
			fl.hero_on_foot = false
			fl.cars = []
			fl.passers = []
			var entry := [out, who[0]]
			if who.size() > 1:
				entry.append(who[1])
			fl.dogs = [entry]
			fl.step(DT)
		results.append(fk.birds.any(func(b: FLOCK.Bird) -> bool: return b.air or b.delay > 0.0))
	K.check(
		fails,
		not results[0] and results[1] and results[2],
		(
			"pigeons: a creeping cat (%s) leaves them be, a pounce (%s) or a dog (%s) sends them up"
			% results
		)
	)


## Paused (sim speed 0) the cat and its clip stand still; running again, it lives on.
func _check_pause(c: LIFE.Cat) -> void:
	_reset(c)
	c.act_t = 0.5
	_hero_at(c.anchor, 10.0)
	ctx.sim.speed = 0
	_step(DT)
	var at := c.pos
	_step(2.0)
	var still := c.pos == at and c.body.ap.speed_scale == 0.0 and c.act == "rest"
	ctx.sim.speed = 1
	_step(1.0)
	K.check(
		fails, still and c.body.ap.speed_scale > 0.0, "pause: it freezes and comes back to life"
	)


## A stray's spot (a works yard's or a park's): nobody there by day, a skittish or aloof stray by
## night.
func _check_strays() -> void:
	var s := _find_spot("stray")
	K.check(fails, not s.is_empty(), "strays: a works yard or a park where a stray keeps")
	if s.is_empty():
		return
	var k := "c:%d" % int(s["lot"])
	ctx.player.teleport((s["anchor"] as Vector3) + Vector3(0.1, 0.0, 0.0), 0.0)
	_step(AF.SCAN_S + 0.1)
	var day := _cat(k) == null
	ctx.sky.night = 1.0
	_step(AF.SCAN_S + 0.1)
	var c := _cat(k)
	ctx.sky.night = 0.0
	_step(AF.SCAN_S + 0.1)
	K.check(
		fails,
		day and c != null and c.home == "stray" and _cat(k) == null,
		(
			"strays: none by day, one by night (%s), gone again by day"
			% (c.temper if c != null else "-")
		)
	)


## A grown city keeps a fair share of cats: of its built homes (no dog) and shops that could keep
## one (a house with a front yard free of props, a shop with a free bit of sidewalk by its door),
## about HOUSE_SHARE and SHOP_SHARE have a cat spot, and the city keeps a few of them all told.
func _check_density() -> void:
	var lots := 0
	var with_cat := 0
	var open_lots := 0
	var open_cat := 0
	for i: int in ctx.sim.active:
		var k := ctx.sim.kind[i]
		if (k != D.ZONE_R and k != D.ZONE_C) or ctx.sim.level[i] <= 0:
			continue
		lots += 1
		var s: Dictionary = cats.call("_spot_of", i, f.get("_dog_lots"))
		with_cat += 1 if not s.is_empty() else 0
		# Only some of the fixture's lots can keep a cat at all (a house needs a front yard free of
		# props, a shop a free bit of sidewalk by its door), so the shares are measured among those.
		var open := false
		if k == D.ZONE_R:
			open = not (cats.call("_house", i) as Dictionary).is_empty()
		else:
			open = not (cats.call("_side", i, "shop") as Dictionary).is_empty()
		if open:
			open_lots += 1
			open_cat += 1 if not s.is_empty() else 0
	var share := float(open_cat) / float(maxi(open_lots, 1))
	K.check(
		fails,
		open_lots >= 8 and share > 0.2 and share < 0.7 and with_cat >= 3,
		(
			(
				"density: %d of the %d built homes and shops where a cat could keep have one (%.2f)"
				+ "; %d of %d lots all told"
			)
			% [open_cat, open_lots, share, with_cat, lots]
		)
	)


## The hero going beyond FAR takes the cat away; coming back brings it.
func _check_far() -> void:
	_hero_at(spot["anchor"], 8.0)
	_step(AF.SCAN_S + 0.1)
	var p := ctx.player
	var home := p.position
	p.teleport(home + Vector3(CATS.FAR + 1.0, 0.0, 0.0), 0.0)
	_step(AF.SCAN_S + 0.1)
	var gone := _cat() == null
	p.teleport(home, 0.0)
	_step(AF.SCAN_S + 0.1)
	K.check(fails, gone, "far: beyond FAR the cat goes")
	K.check(fails, _cat() != null, "far: back again, it comes out again")


## The flag off takes every cat away (nothing to pick); on again, they come back.
func _check_flag() -> void:
	var c := _cat()
	var at := c.pos if c != null else (spot["anchor"] as Vector3)
	FeatureFlags.set_override("cats", false)
	_step(DT)
	var none := life.cats.is_empty() and cats.get_child_count() == 0
	var eye := ctx.player.eye_position()
	var t := f.pick(eye, (at - eye).normalized(), 12.0)
	FeatureFlags.set_override("cats", true)
	_step(AF.SCAN_S + 0.1)
	K.check(fails, none and str(t.get("kind", "")) != "cat", "flag: off takes the cats away")
	K.check(fails, _cat() != null, "flag: on again, they come back")


## The photo shot ("cats", photo_cats): with the sim paused, three cats in their coats rest in their
## poses in front of the camera, with no other cat near them; restore takes them away.
func _check_photo() -> void:
	var shot := {}
	for s: Dictionary in f.photo_shots():
		if str(s["name"]) == "cats":
			shot = s
	K.check(
		fails,
		str(shot.get("prepare", "")) == "photo_cats",
		"photo: a cats shot (%s)" % str(shot.get("pos", ""))
	)
	if shot.is_empty():
		return
	ctx.sim.speed = 0
	f.call(str(shot["prepare"]))
	ctx.player.teleport(shot["pos"], float(shot["yaw"]), float(shot["pitch"]))
	_step(1.0)
	var seen := 0
	var eye := ctx.player.eye_position()
	for k in range(CATS.PHOTO_COATS.size()):
		var c := _cat("photo:%d" % k)
		if c == null:
			continue
		var ahead := (c.pos - eye).normalized().dot(ctx.player.forward()) > cos(deg_to_rad(30.0))
		var posed := c.act == "rest" and c.body.clip == CATS.PHOTO_POSES[k]
		if ahead and posed and c.coat == CATS.PHOTO_COATS[k]:
			seen += 1
	K.check(fails, seen == 3, "photo: three cats rest in front of the camera (%d)" % seen)
	cats.scan(ctx.player.position, true, false, {})
	var mid := _cat("photo:1")
	var others := 0
	for c: LIFE.Cat in life.cats:
		var near := mid != null and _flat(c.pos, mid.anchor) < CATS.PHOTO_CLEAR * WS.M
		if near and not c.key.begins_with("photo:"):
			others += 1
	K.check(
		fails, mid != null and others == 0, "photo: no other cat comes into the shot (%d)" % others
	)
	f.call(str(shot["restore"]))
	ctx.sim.speed = 1
	K.check(fails, _cat("photo:0") == null, "photo: restore takes them away")


## A fresh city (no growth: only the founding roads and City Hall) is young: with no house, shop,
## works yard or park for a cat anywhere, one ambient stray keeps to a sidewalk near the player by
## day and by night, the rain takes it in and it comes back after; once the city has grown past
## YOUNG_LOTS built lots no ambient stray comes out.
func _check_fresh_city() -> void:
	var fresh := FRESH.make(get_root())
	if not bool(fresh["ok"]):
		K.check(fails, false, "fresh: fixture: traffic and animals registered")
		return
	var fcats: CATS = fresh["cats"]
	fcats.bodies.blocking = true
	var flife: LIFE = fresh["life"]
	var fctx: FpContext = fresh["ctx"]
	var ftr: FpFeature = fresh["traffic"]
	var ff: FpFeature = fresh["animals"]
	FRESH.step(ftr, ff, AF.SCAN_S + 0.1)
	var c := _cat_of(flife, CATS.AMBIENT_KEY)
	var out := (
		c != null
		and c.home == "ambient"
		and str(c.temper) in ["aloof", "skittish", "friendly"]
		and _flat(c.pos, fctx.player.position) <= CATS.NEAR
		and fctx.collision.surface_at(c.pos) != "asphalt"
	)
	K.check(
		fails,
		out and bool(fcats.call("_young")),
		(
			"fresh: a young city keeps an ambient stray near the player by day (%s)"
			% (c.temper if c != null else "-")
		)
	)
	fctx.sky.night = 1.0
	FRESH.step(ftr, ff, AF.SCAN_S + 0.1)
	K.check(
		fails,
		_cat_of(flife, CATS.AMBIENT_KEY) != null and flife.cats.size() == 1,
		"fresh: by night the same stray is still about"
	)
	fctx.sky.night = 0.0
	fcats.call("scan", fctx.player_position(), false, true, {})
	K.check(fails, _cat_of(flife, CATS.AMBIENT_KEY) == null, "fresh: the rain takes the stray in")
	FRESH.step(ftr, ff, AF.SCAN_S + 0.1)
	K.check(
		fails, _cat_of(flife, CATS.AMBIENT_KEY) != null, "fresh: after the rain it comes out again"
	)
	K.grow(fctx.sim, fctx.residents)
	var tries := 0
	while bool(fcats.call("_young")) and tries < 6:
		K.ticks(fctx.sim, 40)
		tries += 1
	K.check(
		fails,
		not bool(fcats.call("_young")),
		"fresh: grown past YOUNG_LOTS built lots the city is not young anymore"
	)
	fctx.player.teleport(fctx.player_position() + Vector3(CATS.FAR + 1.0, 0.0, 0.0), 0.0)
	fcats.call("scan", fctx.player_position(), false, false, {})
	K.check(
		fails,
		_cat_of(flife, CATS.AMBIENT_KEY) == null,
		"fresh: grown, no ambient stray comes out where no spot is"
	)


## The cat of key in the cats of another context's life.
func _cat_of(cats_life: LIFE, k: String) -> LIFE.Cat:
	for c: LIFE.Cat in cats_life.cats:
		if c.key == k:
			return c
	return null


func _check_teardown() -> void:
	var st := f.self_test()
	K.check(
		fails, bool(st["ok"]) and "cats out" in str(st["detail"]), "self_test: %s" % st["detail"]
	)
	f.teardown()
	K.check(fails, life.cats.is_empty() and cats.get_child_count() == 0, "teardown: no cats left")
