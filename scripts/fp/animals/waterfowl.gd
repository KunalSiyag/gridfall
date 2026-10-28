extends "res://scripts/fp/animals/bird_flocks.gd"
## The waterfowl node: the ducks on the city's water (the river, the ponds), as the pigeons' two
## nodes are (bird_flocks.gd's shared half driving a duck_flock.gd list, one MultiMesh of the
## duck_body.gd duck an instance and tint a bird). Every open water tile has a share of a flock
## of mallards on it, brought out within NEAR of the player by the scan, the nearest first, up to
## MAX_FLOCKS of them, and dropped again beyond FAR; by night they are gone (off to roost) and
## the flag takes them away. Their take-offs at a fright — the hero at the bank, a crash, the
## car horn heard a share wider over the open water (HORN_CARRY) — go out on the bus
## (animal_called).

const DUCK := preload("res://scripts/fp/animals/duck_flock.gd")
const DUCK_BODY := preload("res://scripts/fp/animals/duck_body.gd")

## Ducks come out within NEAR of the player (u) and go beyond FAR, at most MAX_FLOCKS at once.
const NEAR := 3.0
const FAR := 3.6
const MAX_FLOCKS := 2
## The share of the open water tiles that keep a flock (no bridge over them), and the ducks on
## one (a drake or two among the hens).
const WATER_SHARE := 0.5
const DUCKS := Vector2i(3, 6)
## How much wider than the street's reach the hero's car horn carries over the open water
## (on_horn).
const HORN_CARRY := 1.3
## A flock keeps within SPOT_R (u) of its spot; the spot sits ON_BANK (tile units) off the middle
## of its tile, toward the nearest land, so the ducks feed near a bank the hero can walk down to
## (the tile's middle where its neighbours are all water).
const SPOT_R := 0.3
const ON_BANK := 0.4
## The hero's swings, shove, shout, dance and parkour moves startle the ducks within these (m);
## someone hit those within SEEN_HIT, a crash those within CRASH_M, a prop knocked over those
## within KNOCK_M and a bark those within BARK_M.
const STARTLE := {
	"jab": 3.0,
	"cross": 3.0,
	"hook": 3.0,
	"kick": 4.0,
	"swing": 4.0,
	"shove": 3.0,
	"dance": 2.5,
	"shout": 12.0,
	"vault": 3.0,
	"wall_run": 3.0,
	"ledge_grab": 3.0,
	"hop": 3.0,
	"climb": 3.0,
	"roll": 5.0,
	"run_up": 3.0,
	"catch": 3.0,
	"leap": 4.0,
	"hijack": 4.0,
}
const SEEN_HIT := 8.0
const CRASH_M := 25.0
const KNOCK_M := 8.0
const BARK_M := 6.0
## A duck's height at the shoulder (m): animal_called's size.
const DUCK_M := 0.15


## The node's wiring (the feature's setup()): the waterfowl's half of it.
func setup(p_ctx: FpContext) -> void:
	setup_flocks(p_ctx)
	name = "Waterfowl"


## The flocks' ceiling: MAX_FLOCKS, or the web tier's share of the animals cap (the feature's
## setup()).
var max_flocks := MAX_FLOCKS


## The node's wiring: its own flock list (duck_flock.gd, not the pigeons'), the collision world
## and its calls.
func setup_flocks(p_ctx: FpContext) -> void:
	ctx = p_ctx
	flock = DUCK.new()
	flock.col = ctx.collision
	flock.on_call = _on_call


## Every scan (the feature's): while the waterfowl flag is on and it is day, the near spots get
## their flocks; in the rain they all stay in (they shelter on the bank, as the cats do).
func scan(me: Vector3, by_day: bool, rain := false) -> void:
	var on := by_day and not rain and FeatureFlags.enabled("waterfowl")
	scan_flocks(me, on, max_flocks, NEAR, FAR, rain)


## dt game seconds of the flocks while the flag is on; off takes them away.
func step(dt: float) -> void:
	step_flocks(dt, FeatureFlags.enabled("waterfowl"))


## A car crashed into something at at, or a prop was knocked over there: the ducks near go up.
func on_crash(at: Vector3) -> void:
	startle(at, CRASH_M)


func on_knock(at: Vector3) -> void:
	startle(at, KNOCK_M)


## The hero's car horn sounded at at: the flock flushes as at any fright, hearing it HORN_CARRY
## wider than the street's reach — over the open water nothing swallows the sound
## (bird_flocks.gd's on_horn). In the rain no flock is out, so there is nothing to flush.
func on_horn(at: Vector2, radius: float, long: bool) -> void:
	super.on_horn(at, radius * HORN_CARRY, long)


## Self-test line: how many ducks sit on the water in how many flocks.
func detail() -> String:
	var n := 0
	for f: FLOCK.Flock in flock.flocks:
		n += f.birds.size()
	return "%d ducks on the water in %d flocks" % [n, flock.flocks.size()]


## Tile i's flock spot: a point on the water (a water tile no road is built over, and half of
## them), set toward the nearest land off its middle, {"key", "home", "radius", "n"} (duck_flock.gd
## add_waterfowl()), or {}.
func _spot_of(i: int) -> Dictionary:
	if _spots.has(i):
		return _spots[i]
	var out := {}
	if ctx.sim.terrain[i] == D.WATER and ctx.sim.kind[i] != D.ROAD:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("ducks:%d" % i) ^ (ctx.sim.city_seed * 7919)
		if rng.randf() < WATER_SHARE:
			var x := D.tx(i)
			var y := D.ty(i)
			var home := Vector3(float(x), 0.0, float(y))
			for d: Vector2 in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
				var nx := x + int(d.x)
				var ny := y + int(d.y)
				if not D.in_bounds(nx, ny) or ctx.sim.terrain[D.idx(nx, ny)] == D.WATER:
					continue
				var p := home + Vector3(d.x, 0.0, d.y) * ON_BANK
				if ctx.collision.surface_at(p) == "water":
					home = p
					break
			out = {
				"key": "w:%d" % i,
				"home": home,
				"radius": SPOT_R,
				"n": rng.randi_range(DUCKS.x, DUCKS.y),
			}
	_spots[i] = out
	return out


## The flock a spot makes: its ducks on the water, drawn at once.
func _make(key: String, s: Dictionary) -> FLOCK.Flock:
	var f := (flock as DUCK).add_waterfowl(key, s["home"], float(s["radius"]), int(s["n"]))
	if f != null:
		_make_node(f)
	return f


## The flock's ducks, drawn at once by one MultiMesh of the duck, one instance and tint a bird.
func _make_node(f: FLOCK.Flock) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = DUCK_BODY.mesh()
	mm.instance_count = f.birds.size()
	for k in range(f.birds.size()):
		mm.set_instance_color(k, (f.birds[k] as FLOCK.Bird).tint)
	var mi := MultiMeshInstance3D.new()
	mi.name = "Flock"
	mi.multimesh = mm
	mi.material_override = DUCK_BODY.material()
	add_child(mi)
	f.node = mi
	_draw_flock(f)
	return mi


## A duck called out at at (a take-off, a lone duck's flap): on the bus, at a duck's size.
func _on_call(at: Vector3, sound: String) -> void:
	calls[sound] = int(calls.get(sound, 0)) + 1
	if ctx.bus != null:
		ctx.bus.animal_called.emit(at, sound, DUCK_M)
