extends Node3D
## The flock nodes' shared half, used by the pigeons' two nodes (pigeons.gd's foraging flocks and
## perches.gd's perched ones): the pigeon_flock.gd list each drives, the world the animals feature
## feeds it from the dogs' pack before every step (world()), the step loop and the draw
## (step_flocks(), _draw()), the MultiMesh each flock draws with (pigeon_body.gd's bird, one
## instance and tint a bird) and the tile spots the node's own _spot_of() finds (scan_flocks()
## brings the near ones out, the nearest first, within its cap). A fright reaches every flock
## through startle(); a dog barking, a crash and a knocked-over prop through the node's own
## on_crash()/on_knock().

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const FLOCK := preload("res://scripts/fp/animals/pigeon_flock.gd")
const BODY := preload("res://scripts/fp/animals/pigeon_body.gd")
const PACK := preload("res://scripts/fp/animals/dog_pack.gd")

const MAX_STEP := 1.0 / 30.0
## A pigeon's height at the shoulder (m): animal_called's size.
const SIZE_M := 0.13
## The player's car while they drive, half length and half width (m), for the birds' dodge.
const CAR := Vector2(2.3, 1.0)

var ctx: FpContext
var flock: FLOCK
## Calls made so far by kind ("coo", "flap", "takeoff").
var calls: Dictionary = {}
## Tile -> its spot (the node's _spot_of()), {} for none.
var _spots: Dictionary = {}
## Where the player was last step, for their car's speed while they drive.
var _car_was := Vector3.INF


## The node's wiring (from its own setup()): its flock list, the collision world and its calls.
func setup_flocks(p_ctx: FpContext) -> void:
	ctx = p_ctx
	flock = FLOCK.new()
	flock.col = ctx.collision
	flock.on_call = _on_call


## Boot, load or New City: no flocks until the next scan.
func rebuilt() -> void:
	clear()
	flock.col = ctx.collision
	_spots.clear()


## A tile rebuilt: its spots are looked for again.
func tile_built(_i: int) -> void:
	_spots.clear()


func clear() -> void:
	if flock == null:
		return
	for f: FLOCK.Flock in flock.flocks.duplicate():
		_drop(f)


## Every scan: the flocks too far off go (beyond far); in the rain they all stay in (they shelter,
## as the cats do) and none comes out; else, while on (the node's flag and by day), the spots near
## me (within near) get theirs, the nearest first, up to cap of them — each spot the node's own
## _make() by its "key", each tile's spot its own _spot_of().
func scan_flocks(me: Vector3, on: bool, cap: int, near: float, far: float, rain := false) -> void:
	for f: FLOCK.Flock in flock.flocks.duplicate():
		if f.key.begins_with("photo:"):
			continue
		if rain or _flat(f.home, me) > far:
			_drop(f)
	if rain or not on:
		return
	var near_spots: Array = []
	var r := ceili(near)
	for y in range(roundi(me.z) - r, roundi(me.z) + r + 1):
		for x in range(roundi(me.x) - r, roundi(me.x) + r + 1):
			if not D.in_bounds(x, y):
				continue
			var i := D.idx(x, y)
			var s := _spot_of(i)
			if not s.is_empty() and _flock(str(s["key"])) == null:
				var d := _flat(s["home"], me)
				if d <= near:
					near_spots.append([d, s])
	near_spots.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for e: Array in near_spots:
		if flock.flocks.size() >= cap:
			return
		_make(str((e[1] as Dictionary)["key"]), e[1])


## The world for this step from the dogs' pack: the hero on foot, the traffic's cars (and the
## player's while they drive) and the people on foot around, and the dogs. delta is real seconds.
func world(pack: PACK, driving: bool, delta: float) -> void:
	flock.hero_on_foot = pack.hero_on_foot
	flock.hero = pack.hero
	flock.hero_vel = pack.hero_vel
	flock.passers = pack.passers
	flock.cars = pack.cars.duplicate()
	flock.dogs.clear()
	for d: PACK.Dog in pack.dogs:
		flock.dogs.append([d.pos, Vector3(sin(d.yaw), 0.0, cos(d.yaw)) * d.speed])
	var at := ctx.player.position if ctx.player != null else Vector3.INF
	if driving and delta > 0.0 and _car_was.is_finite() and at.is_finite():
		flock.cars.append([at, (at - _car_was) / delta, CAR.x * WS.M, CAR.y * WS.M])
	_car_was = at if driving else Vector3.INF


## dt game seconds of the flocks (in MAX_STEP steps), then their draw, while on (the node's
## flag); off takes them away.
func step_flocks(dt: float, on: bool) -> void:
	if not on:
		clear()
		return
	var left := dt
	while left > 0.0:
		var h := minf(left, MAX_STEP)
		flock.step(h)
		left -= h
	_draw()


## A fright at at (a blow, a shout, a bark, a crash) sends up the flocks with a bird on the
## ground within r_m metres of it.
func startle(at: Vector3, r_m: float) -> void:
	if r_m > 0.0:
		flock.startle(at, r_m * WS.M)


## The hero's car horn sounded at at (street plane, xz): every flock with a bird within radius
## world units of it goes up together (the same fright a shout is), a long lean on it or a tap
## alike. In the rain no flock is out (scan_flocks() shelters them), so there is nothing to flush.
func on_horn(at: Vector2, radius: float, _long: bool) -> void:
	if radius > 0.0:
		flock.startle(Vector3(at.x, 0.0, at.y), radius)


## The node's own: tile i's spot ({}, none), the flock it makes of one (null). Both overridden
## (pigeons.gd, perches.gd).
func _spot_of(_i: int) -> Dictionary:
	return {}


func _make(_key: String, _s: Dictionary) -> FLOCK.Flock:
	return null


## The flock _make() just added, drawn at once by one MultiMesh of the pigeon, one instance and
## tint a bird: the node, set on the flock.
func _make_node(f: FLOCK.Flock) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = BODY.mesh()
	mm.instance_count = f.birds.size()
	for k in range(f.birds.size()):
		mm.set_instance_color(k, (f.birds[k] as FLOCK.Bird).tint)
	var mi := MultiMeshInstance3D.new()
	mi.name = "Flock"
	mi.multimesh = mm
	mi.material_override = BODY.material()
	add_child(mi)
	f.node = mi
	_draw_flock(f)
	return mi


func _drop(f: FLOCK.Flock) -> void:
	for n: Node3D in [f.node, f.crumbs_node]:
		if n != null and is_instance_valid(n):
			n.free()
	f.node = null
	f.crumbs_node = null
	flock.remove(f)


func _flock(key: String) -> FLOCK.Flock:
	for f: FLOCK.Flock in flock.flocks:
		if f.key == key:
			return f
	return null


func _on_call(at: Vector3, sound: String) -> void:
	calls[sound] = int(calls.get(sound, 0)) + 1
	if ctx.bus != null:
		ctx.bus.animal_called.emit(at, sound, SIZE_M)


func _draw() -> void:
	for f: FLOCK.Flock in flock.flocks:
		_draw_flock(f)


func _draw_flock(f: FLOCK.Flock) -> void:
	var mm := (f.node as MultiMeshInstance3D).multimesh
	for k in range(f.birds.size()):
		var b: FLOCK.Bird = f.birds[k]
		mm.set_instance_transform(k, FLOCK.xform(b))
		mm.set_instance_custom_data(k, FLOCK.pose(b))
	_after_draw(f)


## What the flock draws besides its birds (the pigeons' crumbs; nothing for a perched one).
func _after_draw(_f: FLOCK.Flock) -> void:
	pass


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
