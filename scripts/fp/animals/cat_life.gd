extends RefCounted
## The cats' behaviour; cats.gd decides where cats keep and feeds in the world before every step().
## A cat keeps to its spot (a house's front yard, the sidewalk by a shop's door, or by night a
## stray's patch of sidewalk by a works yard or a park): it sits, loafs, grooms and sleeps there,
## and now and then stretches and strolls to another place round it. A friendly cat comes over to a
## crouching hero with its tail up and meows, and purrs when petted; an aloof one walks off from the
## first pet and from the hero walking at it; a skittish one runs from the hero coming near. A
## sprint past, a blow or a shout makes a cat jump and run (one the hero strikes yowls, is knocked
## away and bolts); a dog close by makes it arch its back and hiss, one coming at it (or still
## there after the hiss) sends it running, and one charging (very close, or running at it) sends it
## up the nearest trunk, clinging there until the dog has been gone a while, then back down. A
## hunter chatters at the pigeons on the ground or a squirrel nearby, stalks it low and slow,
## crouches with its tail twitching and pounces (the flock goes up: pigeon_flock.gd's cats; the
## squirrel up its tree), then sits down to groom as if nothing happened; with them up out of
## reach it watches instead. A car about to run a cat down sends it running. Each cat plays its
## gait at the rate its speed asks for, and its CatRig
## sways the tail, lowers it on a frightened or wary cat and turns the head to what it watches.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DB := preload("res://scripts/fp/animals/dog_bodies.gd")
const BODIES := preload("res://scripts/fp/animals/cat_bodies.gd")
const CAT_RIG := preload("res://scripts/fp/animals/cat_rig.gd")
const DOGS := preload("res://scripts/fp/animals/dog_pack.gd")

## Speeds (m/s): strolling, trotting over to the hero, running and stalking; acceleration (m/s²)
## and turn rate (rad/s).
const STROLL := 0.5 * WS.M
const TROT := 1.3 * WS.M
const RUN := 3.6 * WS.M
const STALK := 0.14 * WS.M
const ACCEL := 8.0 * WS.M
const TURN := 6.0
## Collision radius and height as shares of the height at the shoulder.
const RADIUS_K := 0.5
const HEIGHT_K := 1.5
## Gaits: Trot above TROT_AT (m/s), Run above RUN_AT; clip rates within RATES.
const TROT_AT := 0.9 * WS.M
const LOD := preload("res://scripts/fp/animals/settle_lod.gd")
## The acts the slow cadence may coarse (settle_lod.gd); a hunt, a fright, a climb or a greeting
## always runs at full rate.
const CALM_ACTS := ["rest", "watch", "stretch", "purr", "stroll"]
const RUN_AT := 2.2 * WS.M
const RATES := Vector2(0.5, 4.5)
## The poses a cat rests in, their odds and how long one lasts (s).
const RESTS := {
	&"Sit": [0.35, Vector2(6.0, 16.0)],
	&"Loaf": [0.3, Vector2(10.0, 30.0)],
	&"Groom": [0.15, Vector2(4.0, 9.0)],
	&"Sleep": [0.2, Vector2(20.0, 60.0)],
}
## A stroll goes within ROAM (m) of its spot (inside its box); a hunt goes no further than
## HUNT_LEASH from it.
const ROAM := 3.0 * WS.M
const HUNT_LEASH := 12.0 * WS.M
## The hero: noticed within NOTICE (m); a crouching hero within GREET draws a friendly cat over to
## GREET_AT; a skittish cat runs from them within SHY unless they crouch still; an aloof or skittish
## one walks off from them walking at it (faster than WARY_MPS) within WARY. Sprinting past within
## BRUSH faster than BRUSH_MPS startles any cat.
const NOTICE := 6.0 * WS.M
const GREET := 4.0 * WS.M
const GREET_AT := 0.5 * WS.M
const SHY := 3.0 * WS.M
const WARY := 1.3 * WS.M
const WARY_MPS := 0.4 * WS.M
const BRUSH := 2.5 * WS.M
const BRUSH_MPS := 2.8 * WS.M
const STILL_MPS := 0.1 * WS.M
## Dogs: within HISS (m) the cat hisses; one within BOLT, running at it (DOG_RUN_MPS) within HISS,
## or still there after a hiss sends it running.
const HISS := 4.0 * WS.M
const BOLT := 1.6 * WS.M
const DOG_RUN_MPS := 2.0 * WS.M
const HISS_S := Vector2(1.6, 2.4)
## Running off: to a spot FLEE_M (m) away, frightened for SCARED_S (s).
const FLEE_M := Vector2(5.0, 9.0)
const FLEE_S := 4.0
const SCARED_S := 10.0
const STARTLE_S := 0.75
## The tree refuge from a charging dog: with a trunk (a street tree's or a lot tree's cylinder,
## TRUNK_MIN_R and TREE_TOP as in squirrels.gd) within REFUGE_R (m) the cat bolts up it instead of
## along the ground, climbing at CLIMB_MPS (m/s) to CLING_H (m) and clinging, pitched CLIMB_PITCH
## against the bark, until no dog has been within HISS for CALM_S (s), then down at DOWN_MPS.
const REFUGE_R := 6.0 * WS.M
const TRUNK_MIN_R := 0.2 * WS.M
const TREE_TOP := 0.15
const CLIMB_MPS := 1.6 * WS.M
const CLING_H := 2.0 * WS.M
const CLIMB_PITCH := -1.1
const CALM_S := 3.0
const DOWN_MPS := 1.2 * WS.M
## Struck by the hero (hit): knocked away at KNOCK (m/s) plus KNOCK_K times the blow's strength,
## sliding to a stop at PUSH_BRAKE (m/s²), and frightened HIT_FEAR times as long.
const KNOCK := 1.5 * WS.M
const KNOCK_K := 3.0 * WS.M
const PUSH_BRAKE := 14.0 * WS.M
const HIT_FEAR := 3.0
## Hunting: a hunter sees a pigeon on the ground within PREY (m), stalks to POUNCE_AT, crouches
## CROUCH_S and pounces, leaping at LEAP (m/s) through LEAP_T (s into the clip); after a hunt it
## leaves the birds be for HUNT_REST (s).
const PREY := 9.0 * WS.M
const POUNCE_AT := 1.0 * WS.M
const CROUCH_S := Vector2(0.8, 1.8)
const POUNCE_S := 1.0
## How long a bout of watching the birds up out of reach lasts (s).
const WATCH_S := Vector2(4.0, 9.0)
const LEAP := 3.5 * WS.M
const LEAP_T := Vector2(0.2, 0.55)
const HUNT_REST := Vector2(25.0, 50.0)
## Now and then a cat meows at the hero within MEOW_AT (m), MEOW_S (s) apart; a pet's purr lasts
## PURR_S.
const MEOW_AT := 5.0 * WS.M
const MEOW_S := Vector2(15.0, 35.0)
const PURR_S := 4.0
## People going by take this much room (m); the hero GAP more than their own.
const PERSON_R := 0.3 * WS.M
const GAP := 0.1 * WS.M
## A car within its length plus a second of travel and DODGE_SIDE (m) of its path sends it off.
const DODGE_SIDE := 1.0 * WS.M
## Where the hero's eyes are for a cat looking up at them (m), standing and crouched.
const EYES := Vector2(1.55 * WS.M, 0.95 * WS.M)
const ONE_SHOTS := {
	"startle": &"Startle",
	"hiss": &"Hiss",
	"crouch": &"Crouch",
	"pounce": &"Pounce",
	"stretch": &"Stretch",
	"purr": &"Idle",
	"greet": &"Idle"
}
const NO_POINT := Vector3(NAN, NAN, NAN)


## One cat.
class Cat:
	extends RefCounted
	var id: int = 0
	## The cats node's key for it ("c:<lot>" or "photo:<k>").
	var key: String = ""
	var name: String = ""
	var he: bool = true
	## A cat_bodies.gd COATS key.
	var coat: String = "brown tabby"
	var size: float = 1.0
	## "friendly", "aloof" or "skittish"; whether it hunts the pigeons.
	var temper: String = "friendly"
	var hunter: bool = false
	## Where it keeps: "house", "shop" or "stray".
	var home: String = "house"
	var body: DB.Body = null
	## Its spot and the xz rectangle it strolls in (no area: round the spot).
	var anchor := Vector3.ZERO
	var box := Rect2()
	var pos := Vector3.ZERO
	## Facing (sin yaw, 0, cos yaw).
	var yaw: float = 0.0
	var speed: float = 0.0
	## A knock (u/s) from a blow, dying away.
	var push := Vector3.ZERO
	## What it does: "rest" (in its pose), "stretch", "stroll", "greet", "purr", "startle", "flee",
	## "hiss", "stalk", "crouch", "pounce", "watch" or up its refuge tree ("climb", "hold", "down").
	var act: String = "rest"
	var act_t: float = 0.0
	var act_age: float = 0.0
	## Slow-cadence accumulator while at leisure far from the hero (step()).
	var hz_t: float = 0.0
	var act_dir := Vector3.ZERO
	var rest: StringName = &"Sit"
	var goal := NO_POINT
	var prey := NO_POINT
	## Its refuge from a charging dog: the trunk it bolts up ([x, z, r], empty while it has none),
	## how far up it clings (m), and since when no dog has been about while it is up there.
	var tree: Array = []
	var climb_y: float = 0.0
	var calm_t: float = 0.0
	## What frightened it last (a dog it hisses at, the hero, a car) and for how long it stays wary.
	var threat := NO_POINT
	var scared: float = 0.0
	## An aloof cat walked off from a pet once already (the next one it takes).
	var snubbed: bool = false
	var hunt_cool: float = 0.0
	var meow_t: float = 0.0
	var restart: bool = false


var cats: Array = []
var col: CollisionWorld = null
## Called with (cat, call) for a "meow", a "purr", a "hiss" and a hunter's "chatter".
var on_call: Callable
## The world this step, set by the cats node: the hero's feet and velocity, whether they are on
## foot and crouched; moving cars as [pos, vel, half length, half width]; the feet of the people on
## foot around; dogs as [feet, velocity]; the pigeons on the ground; the birds perched up out of
## reach; the game's time scale.
var hero := Vector3(INF, INF, INF)
var hero_vel := Vector3.ZERO
var hero_on_foot: bool = false
var crouched: bool = false
var cars: Array = []
var passers: Array = []
var dogs: Array = []
var prey: Array = []
var birds_up: Array = []
var time_scale: float = 1.0
var _rng := RandomNumberGenerator.new()
var _next_id: int = 1


func _init() -> void:
	_rng.seed = 9161


## A new cat with body b resting at pos facing yaw, keeping to anchor (pos) inside box.
func add(b: DB.Body, pos: Vector3, yaw: float, box: Rect2) -> Cat:
	var c := Cat.new()
	c.id = _next_id
	_next_id += 1
	c.body = b
	c.pos = pos
	c.anchor = pos
	c.box = box
	c.yaw = yaw
	c.meow_t = _rng.randf_range(MEOW_S.x * 0.3, MEOW_S.y)
	c.hunt_cool = _rng.randf_range(0.0, 6.0)
	_rest(c, &"")
	c.act_t *= _rng.randf()
	cats.append(c)
	return c


func remove(c: Cat) -> void:
	cats.erase(c)


## One step of dt game seconds for every cat.
func step(dt: float) -> void:
	if dt <= 0.0:
		_freeze()
		return
	for c: Cat in cats:
		var cdt := LOD.step_dt(c, c.pos, hero, dt, c.act in CALM_ACTS)
		if cdt <= 0.0:
			continue
		_tick(c, cdt)
		_sense(c)
		_move(c, _want(c), cdt)
		_hold(c)
		_animate(c)
		_pose(c, cdt)


## Something went off at src close by (a blow, a shout, a sprint past): the cat jumps and runs;
## one up its refuge tree just holds on there.
func startle(c: Cat, src: Vector3) -> void:
	if c.act in ["startle", "flee", "climb", "hold", "down"]:
		return
	c.threat = src
	c.scared = SCARED_S
	_start(c, "startle", STARTLE_S)


## The hero struck the cat (a kick or a weapon) from src at strength 0..1: it yowls, is knocked
## away and bolts, frightened HIT_FEAR times as long, and is skittish of the hero from then on.
func hit(c: Cat, src: Vector3, strength: float) -> void:
	var away := c.pos - src
	away.y = 0.0
	away = away.normalized() if away.length_squared() > 1e-12 else -_fwd(c)
	c.push = away * (KNOCK + KNOCK_K * strength)
	c.temper = "skittish"
	c.prey = NO_POINT
	_call(c, "yowl")
	_flee(c, away, src)
	c.scared = SCARED_S * HIT_FEAR


## The cat's collision radius (u).
func girth(c: Cat) -> float:
	return _radius(c)


## The hero pets the cat: "purr" (it leans in and purrs), "snub" (an aloof cat's first pet: it
## sniffs the hand and strolls off) or "hiss" (a frightened or skittish cat hisses and runs).
func pet(c: Cat) -> String:
	if c.scared > 0.0 or c.temper == "skittish":
		_call(c, "hiss")
		_flee(c, c.pos - hero, hero)
		return "hiss"
	if c.temper == "aloof" and not c.snubbed:
		c.snubbed = true
		_call(c, "meow")
		_stroll(c, c.pos - hero)
		return "snub"
	_start(c, "purr", PURR_S)
	_call(c, "purr")
	return "purr"


## Height at the shoulder (m).
func shoulder_m(c: Cat) -> float:
	return float(BODIES.CATS["cat"]["shoulder_m"]) * c.size


## The cat's head (a world point).
func head_of(c: Cat) -> Vector3:
	return DB.bone_point(c.body, c.body.head, Vector2(2.6, 2.75))


## The cat's velocity (u/s).
func velocity(c: Cat) -> Vector3:
	return Vector3(sin(c.yaw), 0.0, cos(c.yaw)) * c.speed


# ------------------------------------------------------------------ per step


func _tick(c: Cat, dt: float) -> void:
	c.act_t -= dt
	c.act_age += dt
	c.scared = maxf(0.0, c.scared - dt)
	c.hunt_cool -= dt
	c.meow_t -= dt
	if c.meow_t <= 0.0:
		c.meow_t = _rng.randf_range(MEOW_S.x, MEOW_S.y)
		var near := hero_on_foot and _flat(c.pos, hero) < MEOW_AT
		if near and c.temper != "skittish" and c.act in ["rest", "stroll", "greet"]:
			_call(c, "meow")
	_act_tick(c, dt)


## The act's own step: arrivals at the goal, the tree states' climb, hold and down, and an act
## run out runs _done.
func _act_tick(c: Cat, dt: float) -> void:
	if c.act == "stroll" and _flat(c.pos, c.goal) < 0.15 * WS.M:
		_rest(c, &"")
	elif c.act == "flee" and not is_nan(c.goal.x):
		# A tree flee ends at the bark (the trunk's width counts as reached) and goes up it; a
		# ground one just stops there.
		var reach := 0.3 * WS.M if c.tree.is_empty() else float(c.tree[2]) + _radius(c) + 0.1 * WS.M
		if _flat(c.pos, c.goal) <= reach:
			if c.tree.is_empty():
				_rest(c, &"Sit")
			else:
				_up_tree(c)
	elif c.act == "climb":
		c.climb_y = minf(c.climb_y + CLIMB_MPS * dt, CLING_H)
		if c.climb_y >= CLING_H:
			c.calm_t = 0.0
			_start(c, "hold", 1e9)
	elif c.act == "hold":
		var dogged := false
		for dg: Array in dogs:
			if _flat(c.pos, dg[0]) < HISS * 1.5:
				dogged = true
				break
		c.calm_t = 0.0 if dogged else c.calm_t + dt
		if c.calm_t >= CALM_S:
			_start(c, "down", 1e9)
	elif c.act == "down":
		c.climb_y = maxf(c.climb_y - DOWN_MPS * dt, 0.0)
		if c.climb_y <= 0.0:
			c.tree = []
			_rest(c, &"Sit")
	elif c.act_t <= 0.0:
		_done(c)


## The act ran its time: what the cat does next.
func _done(c: Cat) -> void:
	match c.act:
		"startle":
			_flee(c, c.pos - c.threat, c.threat)
		"crouch":
			_start(c, "pounce", POUNCE_S)
			var to := c.prey - c.pos if not is_nan(c.prey.x) else velocity(c)
			to.y = 0.0
			c.act_dir = to.normalized() if to.length_squared() > 1e-12 else _fwd(c)
		"pounce":
			c.hunt_cool = _rng.randf_range(HUNT_REST.x, HUNT_REST.y)
			_rest(c, &"Groom")
		"watch":
			c.hunt_cool = _rng.randf_range(HUNT_REST.x, HUNT_REST.y) * 0.25
			_rest(c, &"Sit")
		"rest":
			var lazy := c.rest == &"Sleep" or c.rest == &"Loaf"
			if lazy and _rng.randf() < 0.5:
				_start(c, "stretch", 2.0)
			elif _rng.randf() < 0.6:
				_stroll(c, Vector3.ZERO)
			else:
				_rest(c, &"")
		"stretch":
			_stroll(c, Vector3.ZERO)
		_:
			_rest(c, &"Sit")


func _sense(c: Cat) -> void:
	if c.act in ["startle", "pounce", "climb", "hold", "down"]:
		return
	if _dodge(c) or _dogs(c):
		return
	if c.act == "flee":
		return
	if _hero(c):
		return
	_hunt(c)


func _dodge(c: Cat) -> bool:
	for car: Array in cars:
		var side := DOGS.car_danger(c.pos, car, DODGE_SIDE)
		if side != Vector3.ZERO:
			if c.act != "flee":
				_flee(c, side, car[0])
			return true
	return false


## A dog close by: the cat hisses at it, and runs from one coming at it, one very close or one
## still there after the hiss. From one charging (very close or running at it) it bolts up the
## nearest trunk instead when there is one (the tree refuge).
func _dogs(c: Cat) -> bool:
	for dg: Array in dogs:
		var at: Vector3 = dg[0]
		var d := _flat(c.pos, at)
		if d > HISS:
			continue
		var vel: Vector3 = dg[1]
		var coming := Vector2(vel.x, vel.z).length() > DOG_RUN_MPS and vel.dot(c.pos - at) > 0.0
		var hissed := c.scared > 0.0 and c.act != "hiss"
		if c.act != "flee" and (d < BOLT or coming or hissed):
			var t: Array = []
			if d < BOLT or coming:
				t = _refuge(c)
			if t.is_empty():
				_flee(c, c.pos - at, at)
			else:
				_flee_tree(c, t, at)
			return true
		if c.act != "hiss" and c.act != "flee":
			_start(c, "hiss", _rng.randf_range(HISS_S.x, HISS_S.y))
			c.scared = SCARED_S
			_call(c, "hiss")
		c.threat = at
		return true
	return false


## The nearest trunk worth bolting up within REFUGE_R of the cat, as [x, z, r]: a street tree's or
## a lot tree's cylinder (tall enough to hold it), or [] for none about.
func _refuge(c: Cat) -> Array:
	var best: Array = []
	if col == null:
		return best
	var i0 := col.tile_at(c.pos)
	if i0 < 0:
		return best
	var bd := REFUGE_R
	for dy: int in [-1, 0, 1]:
		for dx: int in [-1, 0, 1]:
			var x := D.tx(i0) + dx
			var y := D.ty(i0) + dy
			if not D.in_bounds(x, y):
				continue
			var cyls := col.cylinders(D.idx(x, y))
			var j := 0
			while j + 3 < cyls.size():
				var r := cyls[j + 2]
				if r >= TRUNK_MIN_R and cyls[j + 3] >= TREE_TOP:
					var dist := _flat(c.pos, Vector3(cyls[j], 0.0, cyls[j + 1]))
					if dist < bd:
						bd = dist
						best = [cyls[j], cyls[j + 1], r]
				j += 4
	return best


## Bolts for the refuge trunk t ([x, z, r]) away from the dog at src, and up it.
func _flee_tree(c: Cat, t: Array, src: Vector3) -> void:
	c.threat = src
	c.scared = SCARED_S
	c.tree = t
	var at := Vector3(t[0], c.pos.y, t[1])
	var to := at - c.pos
	to.y = 0.0
	c.act_dir = to.normalized() if to.length_squared() > 1e-12 else _fwd(c)
	c.goal = at
	_start(c, "flee", FLEE_S * 2.0)


## At the bark on a tree flee: up the trunk it goes, facing out from it.
func _up_tree(c: Cat) -> void:
	c.yaw = atan2(c.pos.x - float(c.tree[0]), c.pos.z - float(c.tree[1]))
	c.pos = Vector3(c.tree[0], c.pos.y, c.tree[1]) + _fwd(c) * (float(c.tree[2]) + _radius(c))
	c.climb_y = 0.0
	c.speed = 0.0
	_start(c, "climb", 1e9)


## The hero close by: a sprint past startles the cat; a skittish cat runs from them, a friendly one
## comes over to them crouching, an aloof or skittish one walks off from them walking at it.
func _hero(c: Cat) -> bool:
	var dh := _flat(c.pos, hero)
	if not hero_on_foot or dh > NOTICE:
		if c.act == "greet":
			_rest(c, &"Sit")
		return false
	var hs := Vector2(hero_vel.x, hero_vel.z).length()
	if dh < BRUSH and hs > BRUSH_MPS:
		startle(c, hero)
		return true
	if c.act == "purr" or c.act == "hiss":
		return true
	if c.temper == "skittish" and dh < SHY and not (crouched and hs < STILL_MPS):
		_flee(c, c.pos - hero, hero)
		return true
	if c.temper == "friendly" and c.scared <= 0.0:
		return _greet(c, dh)
	return _wary(c, dh, hs)


## A friendly cat comes over to the hero crouching within GREET, meowing; true while it greets.
func _greet(c: Cat, dh: float) -> bool:
	var beside := dh < GREET_AT + WS.PLAYER_RADIUS + 0.3 * WS.M
	if crouched and dh < GREET and not beside and c.act != "greet":
		_start(c, "greet", 8.0)
		_call(c, "meow")
	return c.act == "greet"


## An aloof or skittish cat walks off from the hero walking at it within WARY; true when it does.
func _wary(c: Cat, dh: float, hs: float) -> bool:
	var at_it := hero_vel.dot(c.pos - hero) > 0.0
	if dh < WARY and hs > WARY_MPS and at_it and c.act != "stroll":
		_stroll(c, c.pos - hero)
		return true
	return false


## A hunter by day: chatters at the nearest pigeon on the ground and stalks it, crouches within
## POUNCE_AT; gives up when the birds are gone or it strays too far. With the pigeons up out of
## reach it watches them instead: sits with its tail twitching and its eyes on the nearest, until
## they are gone or the bout runs out.
func _hunt(c: Cat) -> void:
	if not c.hunter or c.hunt_cool > 0.0 or c.act in ["greet", "purr", "stretch"]:
		return
	var p := _nearest_prey(c)
	if c.act == "stalk" or c.act == "crouch":
		var lost := is_nan(p.x) or _flat(c.pos, c.anchor) > HUNT_LEASH
		if lost:
			c.hunt_cool = _rng.randf_range(HUNT_REST.x, HUNT_REST.y) * 0.5
			_rest(c, &"Sit")
			return
		c.prey = p
		if c.act == "stalk" and _flat(c.pos, p) < POUNCE_AT:
			_start(c, "crouch", _rng.randf_range(CROUCH_S.x, CROUCH_S.y))
		return
	var up := _nearest_up(c)
	if c.act == "watch":
		if is_nan(up.x) or _flat(up, c.anchor) > HUNT_LEASH:
			_rest(c, &"Sit")
		else:
			c.prey = up
		return
	if not is_nan(p.x) and _flat(p, c.anchor) < HUNT_LEASH:
		c.prey = p
		_start(c, "stalk", 40.0)
		_call(c, "chatter")
	elif not is_nan(up.x) and _flat(up, c.anchor) < HUNT_LEASH:
		c.prey = up
		_start(c, "watch", _rng.randf_range(WATCH_S.x, WATCH_S.y))
		if _rng.randf() < 0.3:
			_call(c, "chatter")


func _nearest_prey(c: Cat) -> Vector3:
	var best := NO_POINT
	var bd := PREY
	for p: Vector3 in prey:
		var d := _flat(c.pos, p)
		if d < bd:
			bd = d
			best = p
	return best


## The nearest bird up out of reach (a perch), NO_POINT for none.
func _nearest_up(c: Cat) -> Vector3:
	var best := NO_POINT
	var bd := PREY
	for p: Vector3 in birds_up:
		var d := _flat(c.pos, p)
		if d < bd:
			bd = d
			best = p
	return best


func _want(c: Cat) -> Vector3:
	match c.act:
		"flee":
			if not is_nan(c.goal.x):
				return _arrive(c, c.goal, RUN)
			return c.act_dir * RUN
		"stroll":
			return _arrive(c, c.goal, STROLL)
		"greet":
			var to := c.pos - hero
			to.y = 0.0
			var dir := to.normalized() if to.length_squared() > 1e-12 else Vector3.BACK
			return _arrive(c, hero + dir * (GREET_AT + WS.PLAYER_RADIUS), TROT)
		"stalk":
			return _arrive(c, c.prey, STALK)
	return Vector3.ZERO


func _arrive(c: Cat, target: Vector3, vmax: float) -> Vector3:
	if is_nan(target.x):
		return Vector3.ZERO
	var to := target - c.pos
	to.y = 0.0
	var dist := to.length()
	if dist < 0.05 * WS.M:
		return Vector3.ZERO
	return to / dist * minf(vmax, dist * 3.0)


## Turns toward want (or what it faces) and moves at want's speed as far as it faces it; a pounce
## leaps along its way.
func _move(c: Cat, want: Vector3, dt: float) -> void:
	if c.push != Vector3.ZERO:
		_slide(c, c.push * dt)
		c.push = c.push.move_toward(Vector3.ZERO, PUSH_BRAKE * dt)
	if c.act == "pounce":
		var leaping := c.act_age >= LEAP_T.x and c.act_age <= LEAP_T.y
		c.speed = LEAP if leaping else 0.0
		c.yaw = rotate_toward(c.yaw, atan2(c.act_dir.x, c.act_dir.z), TURN * dt)
		_slide(c, c.act_dir * c.speed * dt)
		return
	var wl := Vector2(want.x, want.z).length()
	var face := c.yaw
	var at := _faces(c)
	if wl > 0.03 * WS.M:
		face = atan2(want.x, want.z)
	elif not is_nan(at.x):
		face = atan2(at.x - c.pos.x, at.z - c.pos.z)
	c.yaw = rotate_toward(c.yaw, face, TURN * dt)
	var align := maxf(0.0, cos(angle_difference(c.yaw, face)))
	c.speed = move_toward(c.speed, wl * align, ACCEL * dt)
	_slide(c, _fwd(c) * c.speed * dt)


## What a cat standing still turns to: the dog it hisses at, the bird it crouches at or watches,
## the hero it greets or purrs for; NO_POINT for nothing.
func _faces(c: Cat) -> Vector3:
	match c.act:
		"hiss":
			return c.threat
		"crouch", "watch":
			return c.prey
		"greet", "purr":
			return hero if hero_on_foot else NO_POINT
	return NO_POINT


## Nobody walks through the hero, the people going by or another cat; a cat up its tree is out of
## their way already.
func _hold(c: Cat) -> void:
	if c.act in ["climb", "hold", "down"]:
		return
	var r := _radius(c)
	if hero_on_foot:
		_keep_off(c, hero, r + WS.PLAYER_RADIUS + GAP)
	for p: Vector3 in passers:
		_keep_off(c, p, r + PERSON_R)
	for o: Cat in cats:
		if o != c:
			_keep_off(c, o.pos, r + _radius(o))


func _keep_off(c: Cat, p: Vector3, r: float) -> void:
	var away := c.pos - p
	away.y = 0.0
	if absf(away.x) > r or absf(away.z) > r:
		return
	var dist := away.length()
	if dist < r and dist > 1e-6:
		_slide(c, away * ((r - dist) / dist))


func _slide(c: Cat, motion: Vector3) -> void:
	motion.y = 0.0
	if motion.length_squared() < 1e-14:
		return
	var np := c.pos + motion
	if col != null:
		var tall := HEIGHT_K * shoulder_m(c) * WS.M
		np = col.move_body(c.pos, motion, _radius(c), tall, WS.STEP_HEIGHT)
		var y := col.walk_height(np)
		if is_nan(y):
			c.speed = 0.0
			return
		np.y = y
	c.pos = np


func _animate(c: Cat) -> void:
	var b := c.body
	if c.act in ["climb", "hold", "down"]:
		# Up the refuge trunk: against the bark at its climb height, pitched up, scrambling (Run)
		# or clinging (Crouch).
		b.root.position = c.pos + Vector3.UP * c.climb_y
		b.root.rotation = Vector3(CLIMB_PITCH, c.yaw, 0.0)
		var up_clip := &"Crouch" if c.act == "hold" else &"Run"
		DB.play(b, up_clip, (1.0 if c.act == "hold" else 1.3) * time_scale, c.restart)
		c.restart = false
		return
	b.root.position = c.pos
	b.root.rotation = Vector3(0.0, c.yaw, 0.0)
	var clip: StringName = ONE_SHOTS.get(c.act, &"")
	var rate := 1.0
	var moving := c.speed > 0.03 * WS.M and c.act != "pounce" and c.act != "crouch"
	if moving:
		clip = &"Walk"
		if c.act == "stalk":
			clip = &"Stalk"
		elif c.speed > RUN_AT:
			clip = &"Run"
		elif c.speed > TROT_AT:
			clip = &"Trot"
		rate = clampf(c.speed / BODIES.clip_speed(b, clip), RATES.x, RATES.y)
	elif c.act == "rest":
		clip = c.rest
	elif clip == &"":
		clip = &"Crouch" if c.act == "stalk" else &"Idle"
	DB.play(b, clip, rate * time_scale, c.restart)
	c.restart = false


## The tail and the head: the tail's droop and sway from the act (_tail), the eyes on the bird,
## the dog or the hero (_gaze), both eased toward their mark.
func _pose(c: Cat, dt: float) -> void:
	var rig := c.body.rig as CAT_RIG
	if rig == null:
		return
	rig.pace = time_scale
	var ts := _tail(c)
	var f := 1.0 - exp(-3.0 * dt)
	rig.droop = lerpf(rig.droop, ts.x, f)
	rig.wag = lerpf(rig.wag, ts.y, f)
	rig.look = _gaze(c)


## The tail for the act, as [droop, sway]: up (as the clips carry it) in greeting, low on a
## frightened cat and half down on a wary one strolling, twitching on the hunt and watching,
## lashing at a dog.
func _tail(c: Cat) -> Vector2:
	var droop := 0.0
	var sway := 0.15
	match c.act:
		"greet", "purr":
			sway = 0.2
		"flee", "startle":
			droop = 0.9
		"climb", "hold", "down":
			droop = 0.6
			sway = 0.4
		"stroll":
			droop = 0.0 if c.temper == "friendly" else 0.4
			sway = 0.25
		"stalk", "crouch", "watch":
			sway = 0.75
		"hiss":
			sway = 1.0
		"rest":
			sway = 0.0 if c.rest == &"Sleep" else 0.12
	if c.scared > 0.0 and c.act != "hiss":
		sway = maxf(sway, 0.6)
	return Vector2(droop, sway)


## What the cat's eyes are on: the bird it stalks or watches, the dog it hisses at or watches
## from up the tree, or the hero close by; NO_POINT for no one.
func _gaze(c: Cat) -> Vector3:
	if c.act in ["climb", "hold", "down"] and not is_nan(c.threat.x):
		# Up the tree: its eyes stay on the dog below.
		return c.threat + Vector3(0.0, 0.3 * WS.M, 0.0)
	if c.act in ["stalk", "crouch", "watch"] and not is_nan(c.prey.x):
		return c.prey
	if c.act == "hiss":
		return c.threat + Vector3(0.0, 0.3 * WS.M, 0.0)
	if (c.act != "rest" or c.rest != &"Sleep") and hero_on_foot and _flat(c.pos, hero) < NOTICE:
		return hero + Vector3(0.0, EYES.y if crouched else EYES.x, 0.0)
	return NO_POINT


# ------------------------------------------------------------------ helpers


## The game is paused: every clip and every tail stops where it is.
func _freeze() -> void:
	for c: Cat in cats:
		if c.body.ap != null:
			c.body.ap.speed_scale = 0.0
		if c.body.rig != null:
			c.body.rig.pace = 0.0


func _start(c: Cat, act: String, secs: float) -> void:
	c.act = act
	c.act_t = secs
	c.act_age = 0.0
	c.restart = true


## Rests in pose (one picked by RESTS' odds for &"").
func _rest(c: Cat, pose: StringName) -> void:
	if pose == &"":
		var roll := _rng.randf()
		pose = &"Sit"
		for k: StringName in RESTS:
			roll -= float(RESTS[k][0])
			if roll < 0.0:
				pose = k
				break
	var span: Vector2 = RESTS[pose][1]
	c.rest = pose
	c.goal = NO_POINT
	c.tree = []
	_start(c, "rest", _rng.randf_range(span.x, span.y))


## Strolls to a free spot within ROAM of its own (kept inside its box), the way of away when that is
## not zero; rests where it is when there is none.
func _stroll(c: Cat, away: Vector3) -> void:
	away.y = 0.0
	for _k in range(10):
		var a := _rng.randf() * TAU
		var p := c.anchor + Vector3(cos(a), 0.0, sin(a)) * ROAM * sqrt(_rng.randf())
		if c.box.has_area():
			var q := Vector2(p.x, p.z).clamp(c.box.position, c.box.end)
			p = Vector3(q.x, p.y, q.y)
		var off := p - c.pos
		off.y = 0.0
		if off.length() < 0.3 * WS.M:
			continue
		if away.length_squared() > 1e-12 and off.dot(away) <= 0.0:
			continue
		if _free(c, p):
			c.goal = p
			_start(c, "stroll", 20.0)
			return
	_rest(c, &"Sit")


## Runs off the way of away from src, to a free spot FLEE_M off when there is one. A cat up its
## refuge tree drops to the ground first (the climb's height goes with the tree).
func _flee(c: Cat, away: Vector3, src: Vector3) -> void:
	away.y = 0.0
	if away.length_squared() < 1e-12:
		away = -_fwd(c)
	c.threat = src
	c.scared = SCARED_S
	c.tree = []
	c.climb_y = 0.0
	c.act_dir = away.normalized()
	c.goal = NO_POINT
	for turn: float in [0.0, 0.5, -0.5, 1.0, -1.0]:
		var dir := c.act_dir.rotated(Vector3.UP, turn)
		var p := c.pos + dir * _rng.randf_range(FLEE_M.x, FLEE_M.y) * WS.M
		if _free(c, p):
			c.goal = p
			c.act_dir = dir
			break
	_start(c, "flee", FLEE_S)


## True when p is walkable ground off the road with room for c.
func _free(c: Cat, p: Vector3) -> bool:
	if col == null:
		return true
	var y := col.walk_height(p)
	if is_nan(y) or col.surface_at(p) in ["asphalt", "water"]:
		return false
	return not col.is_blocked(Vector3(p.x, y, p.z), _radius(c))


func _call(c: Cat, sound: String) -> void:
	if on_call.is_valid():
		on_call.call(c, sound)
	if sound == "meow" and c.body.rig != null:
		c.body.rig.bark = 1.0


func _radius(c: Cat) -> float:
	return RADIUS_K * shoulder_m(c) * WS.M


static func _fwd(c: Cat) -> Vector3:
	return Vector3(sin(c.yaw), 0.0, cos(c.yaw))


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
