extends RefCounted
## Ambient filler (docs/fp/slices/E-traffic.md §6): unnamed commuters (some of them cyclists)
## and pedestrians around the player, denser where sim.traffic and residents' trip_load are high
## (caps 40 vehicles, 60 people). The caps are spent where they can be seen: cars live within
## CAR_RING (just past VIS_CAR) and people within PED_RING (just past VIS_PERSON), both inside
## TRAFFIC_RADIUS. Cars appear and vanish only beyond MIN_SPAWN and out of the camera's view;
## people appear out of view beyond PED_MIN_SPAWN, or fade in (render.gd) far enough away that
## the fade is all one sees. A
## synchronous fill (first fill, load, teleport: the whole view is new) places agents anywhere
## outside the player's personal space. Also the curb parking that makes streets look lived in:
## deterministic per slot, so it never changes as the player walks.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const SW := preload("res://scripts/fp/traffic/sidewalks.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const MAX_CARS := 40
const MAX_PEDS := 60
## The web quality mode (its static density_caps(): {"traffic": n, "crowd": n, "animals": n};
## empty off-web, so there the caps below stand).
const QUALITY := preload("res://scripts/fp/render/quality.gd")
## Cars per road tile within the ring, before congestion and trip load.
const CARS_PER_TILE := 0.3
const PEDS_PER_TILE := 1.6
const MIN_SPAWN := 6.0
## Ambient cars live within this (VIS_CAR + 1, capped by TRAFFIC_RADIUS) and leave out of sight
## beyond it plus 0.5.
const CAR_RING := 11.0
## People are drawn only to VIS_PERSON, so ambient walkers live in a ring just past it: spawned
## out of view beyond PED_MIN_SPAWN (in view, fading in, beyond PED_FADE_SPAWN), removed beyond
## PED_RING + 0.7 out of sight.
const PED_RING := 4.8
const PED_MIN_SPAWN := 2.0
const PED_FADE_SPAWN := 3.0
## Nothing is ever placed this close to the player, even on a synchronous fill.
const PERSONAL := 2.5 * WS.M
## A synchronous fill keeps cars at least this far from the camera (no car parked in one's face).
const SYNC_CAR_CLEAR := 0.35
## Kerbside parking density by the lot beside the slot.
const PARK_CHANCE := {D.ZONE_C: 0.55, D.ZONE_R: 0.45, D.ZONE_I: 0.25}
const PARK_OTHER := 0.18
## Share of the ambient traffic that is cyclists (the cyclists flag; 0 off), riding at about
## BIKE_V0 on a bicycle of BIKE_DIMS (as a resident's, trips.gd).
const BIKE_CHANCE := 0.18
const BIKE_V0 := 4.0 * WS.M
const BIKE_DIMS := Vector3(0.6 * WS.M, 1.8 * WS.M, 1.8 * WS.M)
## On an unpaved road (D.ROAD_GRADES) the cyclist chance is TRACK_BIKE_BOOST times higher (at most
## TRACK_BIKE_MAX), and only TRACK_CARS of the cars that would spawn there do.
const TRACK_BIKE_BOOST := 3.0
const TRACK_BIKE_MAX := 0.6
const TRACK_CARS := 0.35

var sim: CitySim
var people: Residents
var lg: LG
var sw: SW
var vh: VH
var wk: WK
var radius: float = minf(CAR_RING, WS.TRAFFIC_RADIUS)
## Callables set by the feature: car_model(seed) -> int, person_model(seed) -> int, dims(model) -> Vector3,
## visible(pos) -> bool (inside the camera frustum and within car range).
var car_model: Callable
var person_model: Callable
var dims_of: Callable
var visible: Callable
## bike_model() -> int (traffic_feature.bike_model), and the share of cyclists.
var bike_model: Callable
var bike_chance: float = 0.0
## Test hook: a Dictionary used as the density caps instead of quality.gd's (null: read it).
var caps_override: Variant = null
var _caps_cache: Dictionary = {}
var _caps_dirty := true
## jcb_model() -> int (traffic_feature.jcb_model): the backhoe loader parked at a rare share of
## curb slots (a parked work machine the player can drive, not one in traffic).
var jcb_model: Callable
const JCB_IN := 37
## At most this many backhoes park beside construction sites at once, however many sites are open.
const SITE_MACHINES_MAX := 6
## Site id -> the backhoe parked beside that site (a work machine on the job), cleared when the
## site is finished.
var _site_machines: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _road_tiles: PackedInt32Array = PackedInt32Array()
var _near_cache: Dictionary = {}


func setup(p_sim: CitySim, p_people: Residents, p_lg: LG, p_sw: SW, p_vh: VH, p_wk: WK) -> void:
	sim = p_sim
	people = p_people
	lg = p_lg
	sw = p_sw
	vh = p_vh
	wk = p_wk
	_site_machines.clear()
	_rng.seed = sim.city_seed * 1777 + 5


## Re-reads the road tiles (after a lane rebuild).
func refresh_tiles() -> void:
	_road_tiles = PackedInt32Array(lg.tiles.keys())
	_near_cache.clear()


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


## The web density caps (quality.gd's density_caps): a present "traffic"/"crowd" key clamps
## that spawn target, a missing one caps nothing, so off-web (an empty Dictionary) nothing
## changes. Cached at the first read: they only change with the quality mode, which re-reads
## them through refresh_caps() (settings_changed), instead of an environment read per fill.
func _caps() -> Dictionary:
	if caps_override != null:
		return caps_override
	if _caps_dirty:
		_caps_cache = QUALITY.density_caps()
		_caps_dirty = false
	return _caps_cache


## Marks the cached web density caps stale (the quality mode changed); the next fill re-reads.
func refresh_caps() -> void:
	_caps_dirty = true


## [target cars, target pedestrians] near p from road density, congestion and trip load.
func targets(p: Vector3) -> Vector2i:
	var n := 0
	var np := 0
	var load := 0.0
	var load_p := 0.0
	var r2 := radius * radius
	var rp2 := PED_RING * PED_RING
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
	var cars := clampi(int(float(n) * CARS_PER_TILE + load * 1.5), 2, MAX_CARS)
	var peds := clampi(int(float(np) * PEDS_PER_TILE + load_p * 2.0), 2, MAX_PEDS)
	var caps := _caps()
	if caps.has("traffic"):
		cars = mini(cars, int(caps["traffic"]))
	if caps.has("crowd"):
		peds = mini(peds, int(caps["crowd"]))
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
	var rp2 := (PED_RING + 0.7) * (PED_RING + 0.7)
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


## A random road tile within the spawn ring (min_r..r; r < 0: the car ring), weighted toward busy
## streets. Whether the spot is in view is the caller's check (never "behind the player" alone:
## at the edge of the city there may be no road behind).
func _pick_tile(p: Vector3, _fwd: Vector3, sync: bool, r: float = -1.0, min_r: float = MIN_SPAWN) -> int:
	if _road_tiles.is_empty():
		return -1
	var rr := radius if r < 0.0 else r
	var near := _near_tiles(p, rr)
	if near.is_empty():
		return -1
	for _k in range(12):
		var i: int = near[_rng.randi() % near.size()]
		var dx := float(D.tx(i)) - p.x
		var dz := float(D.ty(i)) - p.z
		var d2 := dx * dx + dz * dz
		if not sync and d2 < min_r * min_r:
			continue
		var w := 0.35 + (sim.traffic[i] if i < sim.traffic.size() else 0.0)
		if _rng.randf() > w:
			continue
		return i
	return -1


## Road tiles within r of p (cached while the player stays within a small step).
func _near_tiles(p: Vector3, r: float) -> PackedInt32Array:
	var key := Vector3(snappedf(p.x, 0.5), r, snappedf(p.z, 0.5))
	if _near_cache.has(key):
		return _near_cache[key]
	if _near_cache.size() > 8:
		_near_cache.clear()
	var out := PackedInt32Array()
	var r2 := r * r
	for i: int in _road_tiles:
		var dx := float(D.tx(i)) - p.x
		var dz := float(D.ty(i)) - p.z
		if dx * dx + dz * dz <= r2:
			out.append(i)
	_near_cache[key] = out
	return out


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
	var pick := _bike_or_car(t)
	if pick < 0:
		return false
	var bike := pick == 1
	var m := _model(bike)
	if m < 0:
		return false
	var dims: Vector3 = BIKE_DIMS if bike else dims_of.call(m)
	if l.length < dims.z + 0.05:
		return false
	var s := _rng.randf_range(dims.z + 0.02, l.length - 0.02)
	if not vh.fits(l, s, dims.z):
		return false
	var at := lg.pos_at(l, s - dims.z * 0.5)
	var dp := at.distance_to(Vector2(p.x, p.z))
	if dp < PERSONAL + dims.z or (sync and dp < SYNC_CAR_CLEAR):
		return false
	if not sync and _in_view(l, s, dims.z):
		return false
	var c := _place_new(l, s, m, dims, bike, sync)
	if not sync and visible.call(c.pos):
		vh.remove(c)
		return false
	return true


## True when a car of length len about to be placed at s on l would show: the two ends just above
## the road and, after placing, its drawn position (the lateral offset update_pose gives a bike, or
## the range and frustum boundary where a couple of centimetres of height decide it, can put the
## car in view even when both ends are not).
func _in_view(l: LG.Lane, s: float, len: float) -> bool:
	for q: Vector2 in [lg.pos_at(l, s), lg.pos_at(l, s - len)]:
		if visible.call(Vector3(q.x, 0.03, q.y)):
			return true
	return false


## 1 to spawn a cyclist on tile t, 0 for a car, -1 for nothing. Tracks and trails carry more
## cyclists, and most cars keep to paved streets.
func _bike_or_car(t: LG.TileInfo) -> int:
	var rough := t.grade != D.GRADE_PAVED
	var chance := minf(bike_chance * TRACK_BIKE_BOOST, TRACK_BIKE_MAX) if rough else bike_chance
	if bike_chance > 0.0 and bike_model.is_valid() and _rng.randf() < chance:
		return 1
	if rough and _rng.randf() > TRACK_CARS:
		return -1
	return 0


## The model of a new ambient vehicle: the bicycle, else a car model by the stream.
func _model(bike: bool) -> int:
	return int(bike_model.call()) if bike else int(car_model.call(_rng.randi()))


## A new ambient car (or cyclist, at their own speed) of model m on l at s.
func _place_new(l: LG.Lane, s: float, m: int, dims: Vector3, bike: bool, sync: bool) -> VH.Car:
	var c := vh.make("bike" if bike else "car", "ambient", dims)
	c.model = m
	c.label = "a cyclist" if bike else "a commuter"
	if bike:
		c.v0 = BIKE_V0 * _rng.randf_range(0.85, 1.15)
	vh.place(c, l, s)
	c.v = l.limit * c.speed_f * (_rng.randf_range(0.6, 1.0) if sync else 0.9)
	if bike:
		c.v = minf(c.v, c.v0)
	return c


func _spawn_ped(p: Vector3, fwd: Vector3, sync: bool) -> bool:
	var i := _pick_tile(p, fwd, sync, PED_RING, PED_MIN_SPAWN)
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
	var d2 := _d2(at, p)
	if d2 < PERSONAL * PERSONAL:
		return false
	var fade := false
	if not sync and visible.call(at + Vector3(0, 0.05, 0)):
		if d2 < PED_FADE_SPAWN * PED_FADE_SPAWN:
			return false
		fade = true
	# Keep the first placement apart from others.
	for o: WK.Walker in wk.walkers:
		if o.pos.distance_squared_to(at) < (WK.SEP * 1.5) * (WK.SEP * 1.5):
			return false
	var w := wk.make("ambient")
	w.model = person_model.call(_rng.randi())
	w.fade = 0.0 if fade else 1.0
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
			var jcb := int(jcb_model.call()) if jcb_model.is_valid() else -1
			var m := int(jcb if jcb >= 0 and h % JCB_IN == 0 else car_model.call(h / 1000))
			var dims: Vector3 = dims_of.call(m)
			var c := vh.make("car", "decor", dims)
			c.model = m
			if m == jcb:
				c.label = "a backhoe"
				c.mass = 5.5
			else:
				c.label = "a parked car"
			vh.park_at(c, i, k)
			n += 1
	lg.bulk = false
	return n


## Parks a backhoe at the kerb of a road tile beside the construction site (a work machine on the
## job), the slot nearest the site's own kerb, if one is free. Returns the car, or null when the
## flag is off, the site already has one, no slot is free or no road runs beside the site.
func park_site_machine(site: Dictionary) -> VH.Car:
	var jcb := int(jcb_model.call()) if jcb_model.is_valid() else -1
	if jcb < 0 or _site_machines.size() >= SITE_MACHINES_MAX:
		return null
	var sid := int(site.get("id", -1))
	var i := int(site.get("i", -1))
	if sid < 0 or i < 0 or _site_machines.has(sid):
		return null
	for n: int in lg.neighbours(i):
		if not lg.parkable(n):
			continue
		for k in range(LG.SLOTS):
			if not lg.slot_valid(n, k) or not lg.slot_free(n, k):
				continue
			var c := vh.make("car", "decor", dims_of.call(jcb))
			c.model = jcb
			c.label = "a backhoe"
			c.mass = 5.5
			vh.park_at(c, n, k)
			_site_machines[sid] = c.id
			return c
	return null


## The machine parked beside the site leaves with the crew (nothing when it had none).
func clear_site_machine(site: Dictionary) -> void:
	var sid := int(site.get("id", -1))
	if not _site_machines.has(sid):
		return
	var c: VH.Car = vh.by_id.get(int(_site_machines[sid]))
	_site_machines.erase(sid)
	if c != null:
		vh.remove(c)


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
