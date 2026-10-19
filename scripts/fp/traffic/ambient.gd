extends RefCounted
## Ambient filler (docs/fp/slices/E-traffic.md §6): unnamed commuters and pedestrians within
## TRAFFIC_RADIUS of the player, denser where sim.traffic and residents' trip_load are high (caps
## 40 cars, 60 people). New ones appear and old ones vanish only beyond 6 u and behind the player,
## or out of the camera on a synchronous (first or post-teleport) fill. Also the curb parking that
## makes streets look lived in: deterministic per slot, so it never changes as the player walks.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const SW := preload("res://scripts/fp/traffic/sidewalks.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const MAX_CARS := 40
const MAX_PEDS := 60
const MIN_SPAWN := 6.0
## People are drawn only to VIS_PERSON, so ambient walkers live in a tighter ring around the player
## (spawned between MIN_SPAWN and PED_RADIUS, removed beyond PED_RADIUS + 1 out of sight).
const PED_RADIUS := 7.5
## Nothing is ever placed this close to the player, even on a synchronous fill.
const PERSONAL := 2.5 * WS.M
## Kerbside parking density by the lot beside the slot.
const PARK_CHANCE := {D.ZONE_C: 0.55, D.ZONE_R: 0.45, D.ZONE_I: 0.25}
const PARK_OTHER := 0.18

var sim: CitySim
var people: Residents
var lg: LG
var sw: SW
var vh: VH
var wk: WK
var radius: float = WS.TRAFFIC_RADIUS
## Callables set by the feature: car_model(seed) -> int, person_model(seed) -> int, dims(model) -> Vector3,
## visible(pos) -> bool.
var car_model: Callable
var person_model: Callable
var dims_of: Callable
var visible: Callable
var _rng := RandomNumberGenerator.new()
var _road_tiles: PackedInt32Array = PackedInt32Array()


func setup(p_sim: CitySim, p_people: Residents, p_lg: LG, p_sw: SW, p_vh: VH, p_wk: WK) -> void:
	sim = p_sim
	people = p_people
	lg = p_lg
	sw = p_sw
	vh = p_vh
	wk = p_wk
	_rng.seed = sim.city_seed * 1777 + 5


## Re-reads the road tiles (after a lane rebuild).
func refresh_tiles() -> void:
	_road_tiles = PackedInt32Array(lg.tiles.keys())


func counts() -> Vector2i:
	var c := 0
	var p := 0
	for car: VH.Car in vh.cars:
		if car.role == "ambient" and not car.parked:
			c += 1
	for w: WK.Walker in wk.walkers:
		if w.role == "ambient":
			p += 1
	return Vector2i(c, p)


## [target cars, target pedestrians] near p from road density, congestion and trip load.
func targets(p: Vector3) -> Vector2i:
	var n := 0
	var np := 0
	var load := 0.0
	var load_p := 0.0
	var r2 := radius * radius
	var rp2 := PED_RADIUS * PED_RADIUS
	for i: int in _road_tiles:
		var dx := float(D.tx(i)) - p.x
		var dz := float(D.ty(i)) - p.z
		var d2 := dx * dx + dz * dz
		if d2 > r2:
			continue
		n += 1
		var l := sim.traffic[i] if i < sim.traffic.size() else 0.0
		if people != null and i < people.trip_load.size():
			l += minf(people.trip_load[i] / 120.0, 1.0)
		load += l
		if d2 <= rp2:
			np += 1
			load_p += l
	if n == 0:
		return Vector2i.ZERO
	var cars := clampi(int(float(n) * 0.16 + load * 1.5), 2, MAX_CARS)
	var peds := clampi(int(float(np) * 0.9 + load_p * 2.0), 2, MAX_PEDS)
	return Vector2i(cars, peds)


## Removes ambient agents beyond the radius (out of sight) and tops up toward the targets.
## sync: fill completely now (first fill or after a teleport), anywhere out of the camera's view.
func maintain(p: Vector3, fwd: Vector3, sync: bool) -> void:
	var r2 := (radius + 0.5) * (radius + 0.5)
	for c: VH.Car in vh.cars.duplicate():
		if c.role != "ambient" or c.parked:
			continue
		var d2 := _d2(c.pos, p)
		var gone: bool = d2 > r2 or (c.stuck and not visible.call(c.pos)) or (c.stalled_s > 40.0 and d2 > 36.0 and not visible.call(c.pos))
		if gone and not visible.call(c.pos):
			vh.remove(c)
	var rp2 := (PED_RADIUS + 1.0) * (PED_RADIUS + 1.0)
	for w: WK.Walker in wk.walkers.duplicate():
		if w.role != "ambient":
			continue
		var d2 := _d2(w.pos, p)
		var lost := w.edge == null or not w.edge.alive
		if (d2 > rp2 or (lost and not w.on_leg)) and not visible.call(w.pos):
			wk.remove(w)
	var want := targets(p)
	var have := counts()
	var budget := 200 if sync else 2
	var tries := 0
	while have.x < want.x and budget > 0 and tries < (400 if sync else 6):
		tries += 1
		if _spawn_car(p, fwd, sync):
			have.x += 1
			budget -= 1
	budget = 200 if sync else 2
	tries = 0
	while have.y < want.y and budget > 0 and tries < (600 if sync else 6):
		tries += 1
		if _spawn_ped(p, fwd, sync):
			have.y += 1
			budget -= 1


func _d2(a: Vector3, b: Vector3) -> float:
	return (a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z)


## A random road tile within the spawn ring (out to `r`), weighted toward busy streets.
func _pick_tile(p: Vector3, fwd: Vector3, sync: bool, r: float = -1.0) -> int:
	if _road_tiles.is_empty():
		return -1
	var rr := radius if r < 0.0 else r
	for _k in range(12):
		var i: int = _road_tiles[_rng.randi() % _road_tiles.size()]
		var dx := float(D.tx(i)) - p.x
		var dz := float(D.ty(i)) - p.z
		var d2 := dx * dx + dz * dz
		if d2 > rr * rr:
			continue
		if not sync:
			if d2 < MIN_SPAWN * MIN_SPAWN or dx * fwd.x + dz * fwd.z >= 0.0:
				continue
		var w := 0.35 + (sim.traffic[i] if i < sim.traffic.size() else 0.0)
		if _rng.randf() > w:
			continue
		return i
	return -1


func _spawn_car(p: Vector3, fwd: Vector3, sync: bool) -> bool:
	var i := _pick_tile(p, fwd, sync)
	if i < 0 or lg.is_blocked(i):
		return false
	var t: LG.TileInfo = lg.info(i)
	if t == null:
		return false
	var opts: Array = []
	for l: LG.Lane in t.lanes:
		if l.kind == LG.STRAIGHT or l.kind == LG.CORNER:
			opts.append(l)
	if opts.is_empty():
		return false
	var l: LG.Lane = opts[_rng.randi() % opts.size()]
	var m := int(car_model.call(_rng.randi()))
	var dims: Vector3 = dims_of.call(m)
	if l.length < dims.z + 0.05:
		return false
	var s := _rng.randf_range(dims.z + 0.02, l.length - 0.02)
	if not vh.fits(l, s, dims.z):
		return false
	var at := lg.pos_at(l, s - dims.z * 0.5)
	if visible.call(Vector3(at.x, 0.03, at.y)) or at.distance_to(Vector2(p.x, p.z)) < PERSONAL + dims.z:
		return false
	var c := vh.make("car", "ambient", dims)
	c.model = m
	c.label = "a commuter"
	vh.place(c, l, s)
	c.v = l.limit * c.speed_f * (_rng.randf_range(0.6, 1.0) if sync else 0.9)
	return true


func _spawn_ped(p: Vector3, fwd: Vector3, sync: bool) -> bool:
	var i := _pick_tile(p, fwd, sync, PED_RADIUS)
	if i < 0:
		return false
	var list: Array = sw.by_tile.get(i, [])
	if list.is_empty():
		return false
	var e: SW.PedEdge = list[_rng.randi() % list.size()]
	if e.zebra or e.length < 0.02:
		return false
	var t := _rng.randf_range(0.0, e.length)
	var at := sw.pos_at(e, t)
	if visible.call(at + Vector3(0, 0.05, 0)) or _d2(at, p) < PERSONAL * PERSONAL:
		return false
	# Keep the first placement apart from others.
	for o: WK.Walker in wk.walkers:
		if o.pos.distance_squared_to(at) < (WK.SEP * 1.5) * (WK.SEP * 1.5):
			return false
	var w := wk.make("ambient")
	w.model = person_model.call(_rng.randi())
	var dir := 1 if _rng.randf() < 0.5 else -1
	wk.place(w, e, t if dir > 0 else e.length - t, dir)
	return true


## Fills curb slots with parked cars, deterministically per slot (bulk: one lane rebuild after).
## Returns how many were parked.
func fill_parking() -> int:
	var n := 0
	lg.bulk = true
	for i: int in lg.tiles.keys():
		if not lg.parkable(i):
			continue
		for k in range(LG.SLOTS):
			if not lg.slot_valid(i, k) or not lg.slot_free(i, k):
				continue
			var chance := _park_chance(i, k)
			var h := absi(hash(Vector3i(i, k, sim.city_seed)))
			if float(h % 1000) / 1000.0 >= chance:
				continue
			var m := int(car_model.call(h / 1000))
			var dims: Vector3 = dims_of.call(m)
			var c := vh.make("car", "decor", dims)
			c.model = m
			c.label = "a parked car"
			vh.park_at(c, i, k)
			n += 1
	lg.bulk = false
	return n


func _park_chance(i: int, k: int) -> float:
	var f := lg.run_dir(i)
	var side := 1.0 if k < 2 else -1.0
	var r := Vector2(-f.y, f.x) * side
	var x := D.tx(i) + roundi(r.x)
	var y := D.ty(i) + roundi(r.y)
	if not D.in_bounds(x, y):
		return 0.0
	var j := D.idx(x, y)
	var kind := sim.kind[j]
	if D.is_zone(kind) and sim.level[j] <= 0:
		return 0.08
	return float(PARK_CHANCE.get(kind, PARK_OTHER))
