extends Node3D
## The cats (part of the animals feature): where cats keep, coming out within NEAR of the player
## and going beyond FAR; the world fed to their behaviour (cat_life.gd) before every step; their
## bodies (cat_bodies.gd) in their coats; and E to pet one close by. A share of the houses with a
## front yard (and no dog) keep a cat there, a share of the shops a shop cat by the door, and by
## night strays come out by the works yards and in the parks; in the rain they all stay in. Their
## meows, purrs, hisses and chatter go out on the bus (animal_called), and a dog a cat hisses at
## barks back.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LIFE := preload("res://scripts/fp/animals/cat_life.gd")
const BODIES := preload("res://scripts/fp/animals/cat_bodies.gd")
const PACK := preload("res://scripts/fp/animals/dog_pack.gd")
const FLOCK := preload("res://scripts/fp/animals/pigeon_flock.gd")

const MAX_STEP := 1.0 / 30.0
## Cats come out within NEAR of the player (u) and go beyond FAR, at most MAX_CATS at once.
const NEAR := 2.4
const FAR := 3.0
const MAX_CATS := 6
## Shares of the houses with a front yard (and no dog) that keep a cat, of the shops with a shop
## cat and, by night, of the works yards and the parks with a stray.
const HOUSE_SHARE := 0.3
const SHOP_SHARE := 0.3
const STRAY_SHARE := {D.ZONE_I: 0.4, D.PARK: 0.35}
## A shop cat or a works yard's stray keeps to the sidewalk against the lot, SIDE_ACROSS tiles from
## the road's middle, its spot tried SIDE_ALONG along the street, strolling within SIDE_BOX (tiles
## along and across, either way) of it; a park's stray round a spot PARK_TRIES off the park's
## middle, within PARK_BOX. A spot needs ROOM (m) clear of props.
const SIDE_ACROSS := 0.455
const SIDE_ALONG: Array[float] = [0.2, -0.2, 0.3, -0.3, 0.1, -0.1]
const SIDE_BOX := Vector2(0.15, 0.035)
const PARK_TRIES: Array[Vector2] = [
	Vector2(0.2, 0.2), Vector2(-0.2, 0.2), Vector2(0.2, -0.2), Vector2(-0.2, -0.2)
]
const PARK_BOX := 0.3
const ROOM := 0.5
## By where it keeps: the odds of a friendly and of an aloof cat (the rest are skittish) and the
## share of hunters.
const TEMPERS := {
	"house": Vector3(0.45, 0.4, 0.5),
	"shop": Vector3(0.6, 0.3, 0.5),
	"stray": Vector3(0.1, 0.35, 0.8)
}
## Coats (cat_bodies.gd COATS) and their odds; calicos and torties are she-cats, gingers mostly he.
const COAT_ODDS := {
	"brown tabby": 0.22,
	"silver tabby": 0.1,
	"ginger": 0.15,
	"black": 0.14,
	"tuxedo": 0.12,
	"grey": 0.08,
	"calico": 0.07,
	"tortoiseshell": 0.06,
	"white": 0.06,
}
const HE_NAMES := "Milo Oliver Leo Simba Jasper Oscar Tiger Felix Smokey Toby Ziggy Pumpkin"
const SHE_NAMES := "Luna Bella Cleo Nala Mittens Pepper Willow Hazel Misty Kiki Maple Olive"
const SIZES := Vector2(0.9, 1.1)
## The hero's swings, shove, shout, dance and parkour moves startle the cats within these (m);
## someone hit those within SEEN_HIT, a crash those within CRASH_M and a prop knocked over those
## within KNOCK_M.
const STARTLE := {
	"jab": 2.5,
	"cross": 2.5,
	"hook": 2.5,
	"kick": 3.0,
	"shove": 2.5,
	"dance": 2.0,
	"shout": 10.0,
	"vault": 3.0,
	"hop": 2.5,
	"climb": 2.5,
	"roll": 4.0,
}
const SEEN_HIT := 6.0
const CRASH_M := 20.0
const KNOCK_M := 6.0
## A dog within BARK_BACK (m) of a cat hissing at it barks back.
const BARK_BACK := 5.0
## E pets a cat within PET_REACH (m) of the eyes whose middle the view passes within PET_R (m) of
## (times its size), with nothing in between (OCCLUDE before it).
const PET_REACH := 2.4
const PET_R := 0.3
const OCCLUDE := 0.3 * WS.M
## The photo shot: three cats on the front yard of a house, seen from PHOTO_STAND (m) toward the
## road, looking PHOTO_PITCH (degrees) down; they sit PHOTO_GAP (m) apart.
const PHOTO_COATS: Array[String] = ["ginger", "tuxedo", "calico"]
const PHOTO_POSES: Array[StringName] = [&"Sit", &"Loaf", &"Groom"]
const PHOTO_STAND := 2.6
const PHOTO_PITCH := -30.0
const PHOTO_GAP := 0.45
## While the photo's cats are out, no other cat comes within PHOTO_CLEAR (m) of them.
const PHOTO_CLEAR := 4.0
const NO_POINT := Vector3(NAN, NAN, NAN)

var ctx: FpContext
var life: LIFE
var bodies: BODIES
## Lot -> its front yard ({"anchor", "box", "yaw"} or {}), the animals feature's.
var yard_of: Callable
## Calls made so far by kind ("meow", "purr", "hiss", "chatter") and the times a cat purred for the
## hero.
var calls: Dictionary = {}
var pets: int = 0
## Tile -> the spot of the cat keeping there (_spot_of()), {} for none.
var _spots: Dictionary = {}
var _pack: PACK = null
## The photo shot's {"lot", "yard", "cam"}, {} without one.
var _photo: Dictionary = {}
## The lot the photo's cats sit on while they are out, -1 otherwise.
var _photo_lot := -1


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	name = "Cats"
	life = LIFE.new()
	life.col = ctx.collision
	life.on_call = _on_call
	bodies = BODIES.new()
	bodies.check()
	bodies.start()


func _notification(what: int) -> void:
	# Quitting frees the tree without teardown, and released bodies are out of the tree.
	if what == NOTIFICATION_PREDELETE and bodies != null:
		bodies.clear()


## Boot, load or New City: no cats until the next scan.
func rebuilt() -> void:
	clear()
	life.col = ctx.collision
	_spots.clear()


func tile_built(_i: int) -> void:
	_spots.clear()


func clear() -> void:
	if life == null:
		return
	for c: LIFE.Cat in life.cats.duplicate():
		_drop(c)


## Teardown: no cats, the loads finished and the spare bodies freed.
func free_bodies() -> void:
	clear()
	bodies.finish_loads()
	bodies.clear()


## Every scan: the cats too far off go (and the strays by day, and all of them in the rain); with
## the flag on the spots near me get theirs, the nearest first. dog_lots: the lots whose household
## keeps a dog.
func scan(me: Vector3, night: bool, rain: bool, dog_lots: Dictionary) -> void:
	for c: LIFE.Cat in life.cats.duplicate():
		if c.key.begins_with("photo:"):
			continue
		if _flat(c.anchor, me) > FAR or rain or (c.home == "stray" and not night):
			_drop(c)
	if rain or not FeatureFlags.enabled("cats"):
		return
	var near: Array = []
	var r := ceili(NEAR)
	var mid := Vector2i(roundi(me.x), roundi(me.z))
	for y in range(mid.y - r, mid.y + r + 1):
		for x in range(mid.x - r, mid.x + r + 1):
			if not D.in_bounds(x, y):
				continue
			var i := D.idx(x, y)
			var s := _spot_of(i, dog_lots)
			if not _open(i, s, night):
				continue
			var d := _flat(s["anchor"], me)
			if d <= NEAR:
				near.append([d, i, s])
	near.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for e: Array in near:
		if life.cats.size() >= MAX_CATS:
			return
		_spawn("c:%d" % int(e[1]), e[2])


## True when tile i's spot s wants a cat now: there is one, it has none yet, a stray's only by
## night, and none within PHOTO_CLEAR of the photo's cats.
func _open(i: int, s: Dictionary, night: bool) -> bool:
	if s.is_empty() or (s["kind"] == "stray" and not night) or _cat("c:%d" % i) != null:
		return false
	return _photo_lot < 0 or _flat(s["anchor"], _photo["yard"]["anchor"]) >= PHOTO_CLEAR * WS.M


## The world for this step from the dogs' pack and the pigeons: the hero on foot, the cars (the
## player's too while they drive), the people on foot and the dogs around, and the birds on the
## ground; the cats go into the pigeons' frights as [feet, velocity, FLOCK.CAT_NEAR].
func world(pack: PACK, flock: FLOCK) -> void:
	_pack = pack
	life.hero_on_foot = pack.hero_on_foot
	life.hero = pack.hero
	life.hero_vel = pack.hero_vel
	life.crouched = pack.crouched
	life.time_scale = pack.time_scale
	life.passers = pack.passers
	life.cars = flock.cars
	life.dogs.clear()
	for d: PACK.Dog in pack.dogs:
		life.dogs.append([d.pos, Vector3(sin(d.yaw), 0.0, cos(d.yaw)) * d.speed])
	life.prey.clear()
	if life.cats.is_empty():
		return
	for f: FLOCK.Flock in flock.flocks:
		for b: FLOCK.Bird in f.birds:
			if not b.air:
				life.prey.append(b.pos)
	for c: LIFE.Cat in life.cats:
		flock.dogs.append([c.pos, life.velocity(c), FLOCK.CAT_NEAR])


## dt game seconds of the cats (in MAX_STEP steps); 0 freezes them. The flag off takes them away.
func step(dt: float) -> void:
	if not FeatureFlags.enabled("cats"):
		clear()
		return
	if dt <= 0.0:
		life.step(0.0)
	var left := dt
	while left > 0.0:
		var h := minf(left, MAX_STEP)
		life.step(h)
		left -= h


## A fright at at (a blow, a shout, a crash) startles the cats within r_m metres of it.
func startle(at: Vector3, r_m: float) -> void:
	for c: LIFE.Cat in life.cats:
		if r_m > 0.0 and _flat(c.pos, at) < r_m * WS.M:
			life.startle(c, at)


func on_crash(at: Vector3, _speed: float, _what: String) -> void:
	startle(at, CRASH_M)


func on_knock(at: Vector3, _kind: String, _speed: float) -> void:
	startle(at, KNOCK_M)


## The cat to pet along the ray: {"kind": "cat", "id", "tile", "pos" (its back), "dist", "label",
## "data": {"coat", "temper"}}, or {}.
func pick(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	if ctx.player == null or life == null or not FeatureFlags.enabled("cats"):
		return {}
	var eye := ctx.player.eye_position()
	var d := dir.normalized()
	var best: LIFE.Cat = null
	var bt := max_dist
	for c: LIFE.Cat in life.cats:
		var mid := _back(c)
		var t := (mid - origin).dot(d)
		if t <= 0.0 or t >= bt or mid.distance_to(eye) > PET_REACH * WS.M:
			continue
		if (origin + d * t).distance_to(mid) <= PET_R * WS.M * c.size:
			bt = t
			best = c
	if best == null or _hidden(origin, d, bt):
		return {}
	return {
		"kind": "cat",
		"id": str(best.id),
		"tile": ctx.collision.tile_at(_back(best)) if ctx.collision != null else -1,
		"pos": _back(best),
		"dist": bt,
		"label": "Pet %s, %s" % [best.name, _what(best)],
		"data": {"coat": best.coat, "temper": best.temper},
	}


## E on a cat (pick's target t): it purrs, walks off or hisses (cat_life.gd pet()), with a toast.
func pet(t: Dictionary) -> void:
	var c := _cat_id(str(t.get("id", "")).to_int())
	if c == null:
		return
	var was := c.temper
	var out := life.pet(c)
	var his := "his" if c.he else "her"
	if out == "purr":
		pets += 1
		_toast("%s pushes %s head into your hand and purrs." % [c.name, his], "chat")
	elif out == "snub":
		_toast("%s sniffs your fingers and strolls off." % c.name, "info")
	else:
		_toast("%s flattens %s ears, hisses and bolts." % [c.name, his], "info")
	Analytics.track("cat_pet", {"coat": c.coat, "temper": was, "outcome": out})


## "3 cats out".
func detail() -> String:
	return "%d cats out" % (life.cats.size() if life != null else 0)


# ------------------------------------------------------------------ photo


## The photo shot ("cats"): the house nearest me with a front yard (not avoid_lot, the dogs'
## shot's) and room to stand PHOTO_STAND toward the road from it; photo_prepare() sits three cats
## there. {} without one (or with the flag off).
func photo_shot(me: Vector3, avoid_lot: int) -> Dictionary:
	_photo = {}
	if not FeatureFlags.enabled("cats") or not yard_of.is_valid() or ctx.directory == null:
		return {}
	var best_d := INF
	for i in range(ctx.sim.kind.size()):
		if ctx.sim.kind[i] != D.ZONE_R or i == avoid_lot:
			continue
		var dist := _flat(_tile_pos(i), me)
		if dist >= best_d:
			continue
		var y: Dictionary = yard_of.call(i)
		var cam := _photo_cam(i, y) if not y.is_empty() else NO_POINT
		if not is_nan(cam.x):
			best_d = dist
			_photo = {"lot": i, "yard": y, "cam": cam}
	if _photo.is_empty():
		return {}
	var pos: Vector3 = _photo["cam"]
	var look: Vector3 = (_photo["yard"]["anchor"] as Vector3) - pos
	var shot := {"name": "cats", "pos": pos, "yaw": rad_to_deg(atan2(-look.x, -look.z))}
	shot.merge({"pitch": PHOTO_PITCH, "hour": 10.0})
	return shot


## The photo's three cats side by side on the yard, each in its own pose, facing the camera.
func photo_prepare() -> void:
	if _photo.is_empty():
		return
	bodies.blocking = true
	_photo_lot = int(_photo["lot"])
	var y: Dictionary = _photo["yard"]
	var at: Vector3 = y["anchor"]
	for c: LIFE.Cat in life.cats.duplicate():
		if _flat(c.pos, at) < PHOTO_CLEAR * WS.M or _flat(c.anchor, at) < PHOTO_CLEAR * WS.M:
			_drop(c)
	var to: Vector3 = (_photo["cam"] as Vector3) - at
	to.y = 0.0
	var side := Vector3(-to.z, 0.0, to.x).normalized()
	for k in range(PHOTO_COATS.size()):
		var p := at + side * (k - 1) * PHOTO_GAP * WS.M
		var h := ctx.collision.walk_height(p)
		p.y = h if not is_nan(h) else at.y
		var s := {
			"anchor": p, "box": Rect2(), "yaw": atan2(to.x, to.z) + 0.5 * (k - 1), "kind": "house"
		}
		var c := _spawn("photo:%d" % k, s, PHOTO_COATS[k])
		if c == null:
			continue
		c.temper = "friendly"
		c.hunter = false
		c.rest = PHOTO_POSES[k]
		c.act = "rest"
		c.act_t = 1e9
		c.meow_t = 1e9
		c.restart = true
	for _k in range(3):
		life.step(MAX_STEP)


func photo_restore() -> void:
	bodies.blocking = false
	_photo_lot = -1
	for c: LIFE.Cat in life.cats.duplicate():
		if c.key.begins_with("photo:"):
			_drop(c)


# ------------------------------------------------------------------ cats


## A new cat for key at spot s (of coat, or one picked by key); null while its body still loads or
## with MAX_CATS out.
func _spawn(key: String, s: Dictionary, coat := "") -> LIFE.Cat:
	if life.cats.size() >= MAX_CATS and not key.begins_with("photo:"):
		return null
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key) ^ (ctx.sim.city_seed * 7919)
	var size := rng.randf_range(SIZES.x, SIZES.y)
	var b := bodies.make("cat", size, self)
	if b == null:
		return null
	var at: Vector3 = s["anchor"]
	var c := life.add(b, at, float(s["yaw"]) + rng.randf_range(-0.8, 0.8), s["box"])
	c.key = key
	c.size = size
	c.home = str(s["kind"])
	c.coat = coat if not coat.is_empty() else _pick_coat(rng.randf())
	c.he = rng.randf() < (0.8 if c.coat == "ginger" else 0.5)
	if c.coat in ["calico", "tortoiseshell"]:
		c.he = false
	var names := (HE_NAMES if c.he else SHE_NAMES).split(" ")
	c.name = names[rng.randi() % names.size()]
	var odds: Vector3 = TEMPERS.get(c.home, TEMPERS["house"])
	var t := rng.randf()
	c.temper = "friendly" if t < odds.x else ("aloof" if t < odds.x + odds.y else "skittish")
	c.hunter = rng.randf() < odds.z
	BODIES.dress(b, c.coat)
	b.root.position = c.pos
	b.root.rotation = Vector3(0.0, c.yaw, 0.0)
	return c


func _drop(c: LIFE.Cat) -> void:
	bodies.release(c.body)
	life.remove(c)


func _cat(key: String) -> LIFE.Cat:
	for c: LIFE.Cat in life.cats:
		if c.key == key:
			return c
	return null


func _cat_id(id: int) -> LIFE.Cat:
	for c: LIFE.Cat in life.cats:
		if c.id == id:
			return c
	return null


static func _pick_coat(roll: float) -> String:
	for k: String in COAT_ODDS:
		roll -= float(COAT_ODDS[k])
		if roll < 0.0:
			return k
	return "brown tabby"


## "a ginger cat", "the shop's black cat", "a tabby stray".
func _what(c: LIFE.Cat) -> String:
	if c.home == "shop":
		return "the shop's %s cat" % c.coat
	if c.home == "stray":
		return "a %s stray" % c.coat
	return "a %s cat" % c.coat


func _on_call(c: LIFE.Cat, call: String) -> void:
	calls[call] = int(calls.get(call, 0)) + 1
	if ctx.bus != null:
		ctx.bus.animal_called.emit(life.head_of(c), call, life.shoulder_m(c))
	if call != "hiss" or _pack == null:
		return
	for d: PACK.Dog in _pack.dogs:
		if _flat(d.pos, c.pos) < BARK_BACK * WS.M:
			_pack.bark(d, 2, false)
			d.watch = c.pos
			d.watch_t = 2.0


## The middle of the cat's back (the pick target).
func _back(c: LIFE.Cat) -> Vector3:
	return c.pos + Vector3(0.0, 0.8 * life.shoulder_m(c) * WS.M, 0.0)


func _hidden(origin: Vector3, dir: Vector3, t: float) -> bool:
	if ctx.collision == null:
		return false
	var hit := ctx.collision.raycast(origin, dir, t, false)
	return bool(hit["hit"]) and float(hit["dist"]) < t - OCCLUDE


func _toast(t: String, kind: String) -> void:
	if ctx.bus != null:
		ctx.bus.toast.emit(t, kind)


# ------------------------------------------------------------------ spots


## Tile i's cat spot: {"lot", "kind" ("house", "shop" or "stray"), "anchor", "box" (Rect2 in xz),
## "yaw"}, or {} for none.
func _spot_of(i: int, dog_lots: Dictionary) -> Dictionary:
	if _spots.has(i):
		return _spots[i]
	var out := {}
	var k := ctx.sim.kind[i]
	if ctx.collision != null and ctx.directory != null:
		if k == D.ZONE_R and not dog_lots.has(i) and _roll("cat:house:%d" % i) < HOUSE_SHARE:
			out = _house(i)
		elif k == D.ZONE_C and ctx.sim.level[i] > 0 and _roll("cat:shop:%d" % i) < SHOP_SHARE:
			out = _side(i, "shop")
		elif STRAY_SHARE.has(k) and _roll("cat:stray:%d" % i) < float(STRAY_SHARE[k]):
			out = _side(i, "stray") if k == D.ZONE_I else _park(i)
	_spots[i] = out
	return out


func _house(i: int) -> Dictionary:
	var y: Dictionary = yard_of.call(i) if yard_of.is_valid() else {}
	if y.is_empty():
		return {}
	return {"lot": i, "kind": "house", "anchor": y["anchor"], "box": y["box"], "yaw": y["yaw"]}


## The sidewalk against lot i on a straight road, by its front.
func _side(i: int, kind: String) -> Dictionary:
	var fr := ctx.directory.frontage(i)
	var m := RoadTopology.mask(ctx.sim, D.tx(fr), D.ty(fr)) if fr >= 0 else 0
	if m != RoadTopology.NS and m != RoadTopology.EW:
		return {}
	var run := RoadTopology.run_dir(m)
	var lot_dir := _tile_pos(i) - _tile_pos(fr)
	for along: float in SIDE_ALONG:
		var p := _tile_pos(fr) + lot_dir * SIDE_ACROSS + run * along
		if not _room(p):
			continue
		p.y = ctx.collision.walk_height(p)
		var half := run.abs() * SIDE_BOX.x + lot_dir.abs() * SIDE_BOX.y
		var box := Rect2(Vector2(p.x - half.x, p.z - half.z), Vector2(half.x, half.z) * 2.0)
		var yaw := atan2(-lot_dir.x, -lot_dir.z)
		return {"lot": i, "kind": kind, "anchor": p, "box": box, "yaw": yaw}
	return {}


func _park(i: int) -> Dictionary:
	for off: Vector2 in PARK_TRIES:
		var p := _tile_pos(i) + Vector3(off.x, 0.0, off.y)
		if not _room(p):
			continue
		p.y = ctx.collision.walk_height(p)
		var box := Rect2(Vector2(p.x, p.z) - Vector2.ONE * PARK_BOX, Vector2.ONE * PARK_BOX * 2.0)
		return {"lot": i, "kind": "stray", "anchor": p, "box": box, "yaw": off.angle()}
	return {}


## True when p is walkable ground (not the road, not water) with ROOM clear round it.
func _room(p: Vector3) -> bool:
	var h := ctx.collision.walk_height(p)
	if is_nan(h) or ctx.collision.surface_at(p) in ["asphalt", "water"]:
		return false
	return not ctx.collision.is_blocked(Vector3(p.x, h, p.z), ROOM * WS.M)


## Where the photo camera stands for lot's yard y: PHOTO_STAND toward the road from its spot, on
## free ground with a clear view of it; NAN when there is none.
func _photo_cam(lot: int, y: Dictionary) -> Vector3:
	var fr := ctx.directory.frontage(lot)
	if fr < 0:
		return NO_POINT
	var at: Vector3 = y["anchor"]
	var p := at + (_tile_pos(fr) - _tile_pos(lot)) * PHOTO_STAND * WS.M
	var h := ctx.collision.walk_height(p)
	if is_nan(h) or ctx.collision.is_blocked(Vector3(p.x, h, p.z), WS.PLAYER_RADIUS):
		return NO_POINT
	p.y = h
	var eye := p + Vector3(0.0, WS.EYE, 0.0)
	if not ctx.collision.line_of_sight(eye, at + Vector3(0.0, 0.15 * WS.M, 0.0)):
		return NO_POINT
	return p


## A number in [0, 1) that stays the same for key in this city.
func _roll(key: String) -> float:
	return float(absi(hash("%s:%d" % [key, ctx.sim.city_seed])) % 10000) / 10000.0


static func _tile_pos(i: int) -> Vector3:
	return Vector3(D.tx(i), 0.0, D.ty(i))


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
