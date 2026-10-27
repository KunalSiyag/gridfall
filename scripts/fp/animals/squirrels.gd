extends Node3D
## The squirrels (part of the animals feature): where they keep (a lawn with a tree — the woods
## that ring the city, the street's own trees and the lots that have one), coming out by day near
## the player and going beyond FAR; the world fed to their behaviour (squirrel_life.gd) before
## every step; one MultiMesh of squirrel_body.gd's squirrel, one instance and tint a squirrel. A
## squirrel bounds about its patch, stops, sits up on its haunches to nibble and sways its tail;
## the hero walking up to it or sprinting near, a dog close by or running, a cat pouncing at it
## (CAT_NEAR, squirrel_life.gd), a person stepping on it or a shout sends it chattering up its
## trunk, where it clings head-up until the trouble has gone and then comes back down to its
## lawn. Its chatters go out on the bus (animal_called).

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LIFE := preload("res://scripts/fp/animals/squirrel_life.gd")
const FT := preload("res://scripts/fp/forest_trees.gd")
const BODY := preload("res://scripts/fp/animals/squirrel_body.gd")
const PACK := preload("res://scripts/fp/animals/dog_pack.gd")
const CAT_LIFE := preload("res://scripts/fp/animals/cat_life.gd")

const MAX_STEP := 1.0 / 30.0
## A squirrel's height at the shoulder (m): animal_called's size.
const SIZE_M := 0.09
## Squirrels come out within NEAR of the player (u) and go beyond FAR, at most MAX_SQUIRRELS at
## once.
const NEAR := 3.0
const FAR := 3.6
const MAX_SQUIRRELS := 3
## A tree to climb: the collision world's trunk cylinder (0.25 m across; a lamp pole is 0.15 m, so
## never mistaken for a tree), at least TREE_TOP (u) tall. The woods' trees carry no collider, so
## they are read from the planting hash (forest_trees.gd).
const TRUNK_MIN_R := 0.20 * WS.M
const TREE_TOP := 0.15
## The woods: this share of the map's forest tiles keeps a squirrel, at one of the tile's own
## trees.
const FOREST_SHARE := 0.5
## Its lawn: a patch within FORAGE_R (m) of its trunk, a point of it picked FORAGE_TRIES angles
## round the trunk at one of FORAGE_STEPS (m) out.
const FORAGE_R := 0.5
const FORAGE_TRIES := 12
const FORAGE_STEPS: Array[float] = [0.2, 0.32, 0.46]
const FORAGE_ROOM := 0.1
## The tint of each squirrel's coat, rolled per spot: greys, browns and a near-black.
const COATS: Array[Color] = [
	Color(0.62, 0.6, 0.58),
	Color(0.5, 0.44, 0.37),
	Color(0.4, 0.33, 0.27),
	Color(0.72, 0.68, 0.6),
	Color(0.34, 0.3, 0.28),
]
## The hero's swings, shove, shout and parkour moves startle the squirrels within these (m);
## someone hit those within SEEN_HIT, a crash those within CRASH_M, a prop knocked over those
## within KNOCK_M and a bark those within BARK_M.
const STARTLE := {
	"jab": 3.0,
	"cross": 3.0,
	"hook": 3.0,
	"kick": 3.5,
	"swing": 3.5,
	"shove": 3.0,
	"dance": 2.5,
	"shout": 10.0,
	"vault": 3.0,
	"wall_run": 3.0,
	"ledge_grab": 3.0,
	"hop": 3.0,
	"climb": 3.0,
	"roll": 4.0,
	"run_up": 3.0,
	"catch": 3.0,
	"leap": 3.5,
	"hijack": 3.5,
}
const SEEN_HIT := 6.0
const CRASH_M := 20.0
const KNOCK_M := 6.0
const BARK_M := 5.0

var ctx: FpContext
var life: LIFE
## Calls made so far by kind ("chatter").
var calls: Dictionary = {}
## The squirrels' ceiling: MAX_SQUIRRELS, or the web tier's share of the animals cap (the
## feature's setup()); read by the scan and the MultiMesh's size (setup()).
var max_squirrels := MAX_SQUIRRELS
## Tile -> the spot of the squirrel keeping there (_spot_of()), {} for none.
var _spots: Dictionary = {}
## The one MultiMesh every squirrel is drawn by (max_squirrels instances, the spare ones scaled
## away), and the tint each instance keeps.
var _node: MultiMeshInstance3D
var _tints: Array[Color] = []
## How many slots the last draw wrote (a change refreshes every slot once).
var _drew_n: int = -1


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	name = "Squirrels"
	life = LIFE.new()
	life.col = ctx.collision
	life.on_call = _on_call
	# A web-tier share of 0 (cap_split()) sets none up at all: no MultiMesh, and the scan
	# spawns nobody, so nothing is drawn or logged.
	if max_squirrels > 0:
		_node = MultiMeshInstance3D.new()
		_node.name = "Squirrels"
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = BODY.mesh()
		mm.instance_count = max_squirrels
		mm.visible_instance_count = 0
		_node.multimesh = mm
		_node.material_override = BODY.material()
		add_child(_node)


## Boot, load or New City: no squirrels until the next scan.
func rebuilt() -> void:
	clear()
	life.col = ctx.collision
	_spots.clear()


## A tile rebuilt: its spots are looked for again.
func tile_built(_i: int) -> void:
	_spots.clear()


func clear() -> void:
	if life == null:
		return
	for s: LIFE.Squirrel in life.squirrels.duplicate():
		_drop(s)
	_draw()


## Every scan: the squirrels too far off go; in the rain they all stay in (they shelter in their
## dreys, as the cats do); else while the flag is on and it is day the spots near me get theirs, the
## nearest first, up to MAX_SQUIRRELS of them.
func scan(me: Vector3, by_day: bool, rain := false) -> void:
	for s: LIFE.Squirrel in life.squirrels.duplicate():
		if rain or _flat(s.home, me) > FAR:
			_drop(s)
	if rain or not by_day or not FeatureFlags.enabled("squirrels"):
		return
	var near: Array = []
	var r := ceili(NEAR)
	for y in range(roundi(me.z) - r, roundi(me.z) + r + 1):
		for x in range(roundi(me.x) - r, roundi(me.x) + r + 1):
			if not D.in_bounds(x, y):
				continue
			var i := D.idx(x, y)
			var s := _spot_of(i)
			if s.is_empty() or life.squirrel(str(s["key"])) != null:
				continue
			var d := _flat(s["home"], me)
			if d <= NEAR:
				near.append([d, s])
	near.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for e: Array in near:
		if life.squirrels.size() >= max_squirrels:
			return
		_make(str((e[1] as Dictionary)["key"]), e[1])


## The world for this step from the dogs' pack and the cats: the hero on foot and their velocity,
## the dogs around, the cats (close by or pouncing, as CAT_NEAR entries) and the people on foot,
## all of which frighten a squirrel.
func world(pack: PACK, cat_life: CAT_LIFE) -> void:
	life.hero_on_foot = pack.hero_on_foot
	life.hero = pack.hero
	life.hero_vel = pack.hero_vel
	life.passers = pack.passers
	life.dogs.clear()
	for d: PACK.Dog in pack.dogs:
		life.dogs.append([d.pos, Vector3(sin(d.yaw), 0.0, cos(d.yaw)) * d.speed])
	if cat_life != null:
		for c: CAT_LIFE.Cat in cat_life.cats:
			if not (c.act in ["climb", "hold", "down"]):
				life.dogs.append([c.pos, cat_life.velocity(c), LIFE.CAT_NEAR])


## dt game seconds of the squirrels (in MAX_STEP steps), then their draw; the flag off takes them
## away.
func step(dt: float) -> void:
	if not FeatureFlags.enabled("squirrels"):
		clear()
		return
	var left := dt
	while left > 0.0:
		var h := minf(left, MAX_STEP)
		life.step(h)
		left -= h
	_draw()


## A fright at at (a blow, a shout, a crash, a bark) sends the squirrels within r_m metres of it up
## their trees.
func startle(at: Vector3, r_m: float) -> void:
	if r_m > 0.0:
		life.startle(at, r_m)


func on_crash(at: Vector3, _speed: float, _cause: String) -> void:
	startle(at, CRASH_M)


func on_knock(at: Vector3, _kind: String, _speed: float) -> void:
	startle(at, KNOCK_M)


## Self-test line: how many squirrels keep about their trees.
func detail() -> String:
	return "%d squirrels about" % life.squirrels.size()


## Tile i's squirrel spot: its tree (a street or lot trunk, else one of the woods' own) and the
## lawn about it, {"key", "home", "tree" [x, z, trunk r]}, or {} for a tile without a tree or
## without free ground by it.
func _spot_of(i: int) -> Dictionary:
	if _spots.has(i):
		return _spots[i]
	var out := {}
	if ctx.collision != null:
		var t := _tree_at(i)
		if not t.is_empty():
			var home := _lawn_near(Vector3(t[0], 0.0, t[1]), float(t[2]))
			if home.is_finite():
				out = {"key": "sq:%d" % i, "home": home, "tree": [t[0], t[1], t[2]]}
	_spots[i] = out
	return out


## The tree of tile i as [x, z, trunk radius]: the first trunk cylinder the collision world holds
## for it (a street tree or a lot's), else — in the woods, which carry no colliders — one of the
## tile's own trees (forest_trees.gd's hash, city_view.gd's planting).
func _tree_at(i: int) -> Array:
	if ctx.sim.kind[i] == D.FOREST:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("squirrels:%d" % i) ^ (ctx.sim.city_seed * 7919)
		if rng.randf() >= FOREST_SHARE:
			return []
		return FT.tree(D.tx(i), D.ty(i), rng.randi_range(0, FT.N - 1))
	var cyls := ctx.collision.cylinders(i)
	var j := 0
	while j + 3 < cyls.size():
		if cyls[j + 2] >= TRUNK_MIN_R and cyls[j + 3] >= TREE_TOP:
			return [cyls[j], cyls[j + 1], cyls[j + 2]]
		j += 4
	return []


## The squirrel's lawn: a point of free ground within FORAGE_R (m) of its trunk, clear of the
## trunk itself, else NAN.
func _lawn_near(at: Vector3, trunk_r: float) -> Vector3:
	for step_m: float in FORAGE_STEPS:
		var rad := maxf(step_m * WS.M, trunk_r + FORAGE_ROOM * WS.M)
		for k in range(FORAGE_TRIES):
			var a := TAU * float(k) / float(FORAGE_TRIES)
			var p := at + Vector3(cos(a), 0.0, sin(a)) * rad
			if life.lawn_ok(p):
				var h := ctx.collision.walk_height(p)
				if not is_nan(h):
					return Vector3(p.x, h, p.z)
	return LIFE.NO_POINT


## The squirrel a spot makes: it takes the lawn, drawn at once.
func _make(key: String, s: Dictionary) -> LIFE.Squirrel:
	var sq := life.add(s["home"], s["tree"], key)
	if sq == null:
		return null
	_tints.append(_tint(key))
	_draw()
	return sq


func _drop(s: LIFE.Squirrel) -> void:
	var k := life.squirrels.find(s)
	if k >= 0 and k < _tints.size():
		_tints.remove_at(k)
	life.remove(s)


## A coat for the squirrel of this spot, the same in this city every time.
func _tint(key: String) -> Color:
	return COATS[absi(hash("%s:%d" % [key, ctx.sim.city_seed])) % COATS.size()]


## Every squirrel drawn by the one MultiMesh: its transform (its yaw, the climb's pitch up the
## trunk and the bound's lift), its pose (INSTANCE_CUSTOM) and its coat; the spare instances are
## not drawn.
func _draw() -> void:
	if _node == null:
		return
	var mm := _node.multimesh
	var n := mini(life.squirrels.size(), mm.instance_count)
	# The membership changing reshuffles the slots: refresh them all that tick.
	var force := n != _drew_n
	_drew_n = n
	for k in range(n):
		var s: LIFE.Squirrel = life.squirrels[k]
		if not force and not s.dirty:
			continue
		s.dirty = false
		mm.set_instance_transform(k, LIFE.xform(s, LIFE.lift(s)))
		mm.set_instance_custom_data(k, LIFE.pose(s))
		mm.set_instance_color(k, _tints[k] if k < _tints.size() else COATS[0])
	mm.visible_instance_count = n


## A squirrel called out at at (its chatter as it flees): on the bus, at a squirrel's size.
func _on_call(at: Vector3, sound: String) -> void:
	calls[sound] = int(calls.get(sound, 0)) + 1
	if ctx.bus != null:
		ctx.bus.animal_called.emit(at, sound, SIZE_M)


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
