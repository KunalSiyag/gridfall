extends RefCounted
## Every road vehicle (docs/fp/slices/E-traffic.md §3): ambient filler, resident cars, buses,
## trucks, crews and cyclists. Each moving vehicle holds its front's lane and distance s, follows
## the Intelligent Driver Model behind the next vehicle on its path, a held stop line, a parking or
## bus-stop goal, people on a zebra it must cross, or the player, and is hard-clamped so it never
## passes through any of them. Junction entry needs a light, a gap (tees, left turns), a clear box
## and room on the exit lane. Parked cars stand in curb slots off the lanes. Beyond the traffic
## radius a vehicle with a destination keeps moving as data only (no lane occupancy, no IDM).

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const IDM := preload("res://scripts/fp/traffic/idm.gd")
const JN := preload("res://scripts/fp/traffic/junctions.gd")
const SW := preload("res://scripts/fp/traffic/sidewalks.gd")
## Half width of a sedan at VEHICLE_SCALE (the vehicle PASS_OFFSET is sized for).
const SEDAN_HW := 0.063 * WS.VEHICLE_SCALE
## Hard minimum bumper gap; IDM keeps s0 = 2 m, this only stops a car from ever touching.
const MIN_GAP := 0.5 * WS.M
## Seconds a held car waits before it stops yielding at all (never at a red light); before that
## the gap it needs shrinks from the junction's gap to GAP_MIN over GAP_PATIENCE seconds.
const IMPATIENCE := 14.0
const GAP_MIN := 1.8
const GAP_PATIENCE := 8.0
## Pull-in / pull-out duration at the curb, seconds.
const PARK_TIME := 1.6
## Cyclists ride this far right of the lane centre (carriageway edge at ROAD_HALF - 0.04).
const BIKE_LAT := WS.ROAD_HALF - 0.04 - WS.LANE_OFFSET
## Through a red light a crew rolls at most this fast.
const SIREN_RED_SPEED := 5.0 * WS.M
## A vehicle this close to its goal point, nearly stopped, has arrived (the settle rule stops
## cars up to 0.3 m short of a held point).
const ARRIVE_TOL := 0.45 * WS.M
## Speed past a blocked tile (cars avoid them when choosing a way; committed ones creep by).
const BLOCKED_SPEED := 2.5 * WS.M
## Simulation LOD: within LOD_FULL of the player a vehicle steps every step, out to LOD_NEAR at
## most every LOD_MID_DT seconds, beyond that every LOD_DT; draws extrapolate in between.
const LOD_FULL := 3.0
const LOD_MID_DT := 1.0 / 20.0
const LOD_NEAR := 6.0
const LOD_DT := 1.0 / 10.0
## Data-only vehicles beyond the traffic radius cruise at this share of their own speed.
const FAR_SPEED := 0.9
## Role of the player's own cars: never on a lane, posed by the drive feature or left standing.
const PLAYER := "player"
## A car the player's car hit brakes this hard while stunned (its driver stands on the brakes).
const STUN_BRAKE := 6.0 * WS.M


## One vehicle.
class Car extends RefCounted:
	var id: int = 0
	var kind: String = "car"        # car | bus | truck | emergency | bike
	var role: String = "ambient"    # ambient | resident | bus | truck | garbage | crew
	var model: int = -1             # render model index
	var length: float = 0.24
	var half_w: float = SEDAN_HW
	var height: float = 0.075
	var lane: LG.Lane = null
	var s: float = 0.0              # front, along lane
	var v: float = 0.0
	var a: float = 0.0
	var v0: float = 0.0             # top speed when > 0 (else the lane limit)
	var speed_f: float = 1.0        # personal factor on the lane limit
	var path: Array = []            # upcoming lanes
	var trail: Array = []           # previous lanes the body may still cover, most recent first
	var goal_lane: LG.Lane = null   # stop with the front at goal_s on this lane
	var goal_s: float = -1.0
	var gate: int = -1              # approach lane id this vehicle may pass the stop point of
	var wait_t: float = 0.0
	var stalled_s: float = 0.0
	var hold: bool = false          # conversation: stop and wait
	var stun_t: float = 0.0         # s it stays braking after the player's car hit it (shoves.gd)
	var siren: bool = false
	var far: bool = false
	var parked: bool = false
	var slot_tile: int = -1
	var slot_k: int = -1
	var park_t: float = -1.0        # >= 0 while pulling in (0..1)
	var park_from := Vector3.ZERO
	var park_from_yaw: float = 0.0
	var pos := Vector3.ZERO
	var yaw: float = 0.0
	var vel := Vector3.ZERO
	var vis_off := Vector3.ZERO
	var vis_yaw: float = 0.0
	var lat_off: float = 0.0
	var driver_id: String = ""
	var label: String = ""
	var dest_label: String = ""
	var state: String = ""
	var owner: Variant = null       # trip or fleet record
	var node: Node3D = null         # full model (render)
	var lod: int = -1
	var wheel_spin: float = 0.0
	var driven: bool = false        # the player is driving it (role "player": posed from outside)
	var door: float = 0.0           # its driver's door: 0 shut .. 1 open (the player's cars)
	var dead: bool = false
	var arrived: bool = false
	var stuck: bool = false         # its lane vanished in view: frozen until out of sight
	var acc_dt: float = 0.0         # time not yet simulated (simulation LOD)
	var info: Dictionary = {}       # its agents_near entry (refreshed in place)
	var info_serial: int = -1
	var ext_room: float = 0.0       # how far the last step allowed it to move on (draw extrapolation)


var lg: LG
var jn: JN
var sw: SW
var cars: Array = []
var by_id: Dictionary = {}
var player_pos := Vector3(INF, 0, INF)
var player_on: bool = false
## What lane traffic stops for, rebuilt each step: the player on foot, the player's cars and the
## extra_blocks, each [xz centre, unit heading, half length, half width, xz velocity] (an extra
## block adds the car id it stands for, which does not stop for itself); half length < 0 is the
## player on foot (a circle).
var _blocks: Array = []
## Returns more blocks each step (shoves.gd: cars knocked off their lanes or slots).
var extra_blocks: Callable
## Bumped whenever the set of parked cars changes (the renderer's static layer rebuilds).
var parked_version: int = 0
var _next_id: int = 1
var _rng := RandomNumberGenerator.new()
## Called with (car) when a vehicle reaches its goal (owner reacts), and when one is removed.
var on_arrive: Callable
var on_removed: Callable


func setup(p_lg: LG, p_jn: JN, p_sw: SW, seed: int) -> void:
	lg = p_lg
	jn = p_jn
	sw = p_sw
	_rng.seed = seed * 92821 + 3
	cars.clear()
	by_id.clear()


# ------------------------------------------------------------------ creation and removal

## A new vehicle (not on any lane yet).
func make(kind: String, role: String, dims: Vector3) -> Car:
	var c := Car.new()
	c.id = _next_id
	_next_id += 1
	c.kind = kind
	c.role = role
	c.half_w = dims.x * 0.5
	c.height = dims.y
	c.length = dims.z
	c.speed_f = _rng.randf_range(0.92, 1.08)
	cars.append(c)
	by_id[c.id] = c
	return c


## Puts c on lane l with its front at s (registers it in the lane's sorted list).
func place(c: Car, l: LG.Lane, s: float) -> void:
	_unregister(c)
	c.lane = l
	c.s = s
	c.parked = false
	c.far = false
	_insert(l, c)
	update_pose(c)


## True when a vehicle of length `length` fits with its front at s on l (gap s0 both ways).
func fits(l: LG.Lane, s: float, length: float) -> bool:
	if s - length < -0.001:
		for p: LG.Lane in lg.prev_lanes(l):
			for o: Car in p.cars:
				if o.s > p.length - (length - s) - IDM.S0:
					return false
	for o: Car in l.cars:
		if o.s > s - length - IDM.S0 and o.s - o.length < s + IDM.S0:
			return false
	for o: Car in l.tails:
		var r := rear_on(o, l)
		if r < s + IDM.S0:
			return false
	if s > l.length - IDM.S0 - 0.02:
		for n: LG.Lane in lg.next_lanes(l):
			for o: Car in n.cars:
				if o.s - o.length < s - l.length + IDM.S0:
					return false
	return true


## Removes c everywhere (lanes, slot, lists).
func remove(c: Car) -> void:
	if c.dead:
		return
	c.dead = true
	if c.parked:
		parked_version += 1
	_unregister(c)
	if c.slot_tile >= 0:
		lg.set_slot(c.slot_tile, c.slot_k, "")
		c.slot_tile = -1
	cars.erase(c)
	by_id.erase(c.id)
	if on_removed.is_valid():
		on_removed.call(c)


func _unregister(c: Car) -> void:
	if c.lane != null:
		c.lane.cars.erase(c)
	for t: LG.Lane in c.trail:
		t.tails.erase(c)
	c.trail.clear()
	c.lane = null


func _insert(l: LG.Lane, c: Car) -> void:
	var k := l.cars.size()
	while k > 0 and (l.cars[k - 1] as Car).s > c.s:
		k -= 1
	l.cars.insert(k, c)


## Parks c in curb slot k of tile i (off the lanes).
func park_at(c: Car, i: int, k: int) -> void:
	_unregister(c)
	if c.slot_tile >= 0 and (c.slot_tile != i or c.slot_k != k):
		lg.set_slot(c.slot_tile, c.slot_k, "")
	c.slot_tile = i
	c.slot_k = k
	lg.set_slot(i, k, "car:%d" % c.id)
	var pose := lg.slot_pose(i, k)
	var p: Vector2 = pose[0]
	var h: Vector2 = pose[1]
	parked_version += 1
	c.parked = true
	c.far = false
	c.park_t = -1.0
	c.v = 0.0
	c.a = 0.0
	c.path.clear()
	c.goal_lane = null
	c.gate = -1
	c.vis_off = Vector3.ZERO
	c.vis_yaw = 0.0
	c.pos = Vector3(p.x, WS.ASPHALT_TOP, p.y)
	c.yaw = atan2(h.x, h.y)
	c.vel = Vector3.ZERO


## Tries to pull a parked car out into the lane beside its slot. Returns true when it left.
func unpark(c: Car) -> bool:
	if not c.parked or c.slot_tile < 0:
		return false
	var i := c.slot_tile
	var pose := lg.slot_pose(i, c.slot_k)
	var p: Vector2 = pose[0]
	var h: Vector2 = pose[1]
	var l := _lane_heading(i, h)
	if l == null:
		return false
	var s := lg.project(l, p) + c.length * 0.5
	s = clampf(s, c.length * 0.5, l.length)
	if not fits(l, s, c.length) or _traffic_behind(l, s - c.length) < 0.0:
		return false
	var from := c.pos
	var from_yaw := c.yaw
	parked_version += 1
	lg.set_slot(i, c.slot_k, "")
	c.slot_tile = -1
	c.slot_k = -1
	place(c, l, s)
	c.vis_off = from - c.pos
	c.vis_off.y = 0.0
	c.vis_yaw = wrapf(from_yaw - c.yaw, -PI, PI)
	return true


## Takes a parked car (beyond the traffic radius) straight onto its lane as data only.
func unpark_far(c: Car, fallback_tile: int) -> bool:
	var l: LG.Lane = null
	var s := 0.0
	if c.slot_tile >= 0:
		var pose := lg.slot_pose(c.slot_tile, c.slot_k)
		l = _lane_heading(c.slot_tile, pose[1])
		if l != null:
			s = clampf(lg.project(l, pose[0]) + c.length * 0.5, c.length * 0.5, l.length)
		lg.set_slot(c.slot_tile, c.slot_k, "")
		c.slot_tile = -1
	if l == null and fallback_tile >= 0:
		var t: LG.TileInfo = lg.info(fallback_tile)
		if t != null:
			for x: LG.Lane in t.lanes:
				if x.kind != LG.MOVE:
					l = x
					s = x.length * 0.5
					break
	if l == null:
		return false
	_unregister(c)
	parked_version += 1
	c.parked = false
	c.lane = l
	c.s = s
	c.far = true
	c.vis_off = Vector3.ZERO
	return true


## Seconds before the nearest vehicle behind reaches s on l (negative: too close now).
func _traffic_behind(l: LG.Lane, s: float) -> float:
	var best := INF
	for o: Car in l.cars:
		if o.s <= s:
			var d := s - o.s
			if d < IDM.S0 + 0.02:
				return -1.0
			best = minf(best, d / maxf(o.v, 0.01))
	for p: LG.Lane in lg.prev_lanes(l):
		for o: Car in p.cars:
			var d := s + p.length - o.s
			if d < IDM.S0 + 0.02:
				return -1.0
			best = minf(best, d / maxf(o.v, 0.01))
	return best if best > 2.5 else -1.0


## The straight (or any) lane of tile i whose direction matches h.
func _lane_heading(i: int, h: Vector2) -> LG.Lane:
	var t: LG.TileInfo = lg.info(i)
	if t == null:
		return null
	var best: LG.Lane = null
	var bd := -2.0
	for l: LG.Lane in t.lanes:
		if l.kind == LG.MOVE or l.kind == LG.UTURN:
			continue
		var d := lg.tan_at(l, l.length * 0.5).dot(h)
		if d > bd:
			bd = d
			best = l
	return best if bd > 0.5 else null


# ------------------------------------------------------------------ geometry

## Distance along lane X of o's rear when o's body covers X from behind its front lane, else -INF.
func rear_on(o: Car, x: LG.Lane) -> float:
	if o.lane == x:
		return o.s - o.length
	var rem := o.length - o.s
	for y: LG.Lane in o.trail:
		if y == x:
			return y.length - rem
		rem -= y.length
	return -INF


## World xz of the point `back` behind c's front along its path (lane, then trail, then extrapolated).
func point_back(c: Car, back: float) -> Vector2:
	if back <= c.s:
		return lg.pos_at(c.lane, c.s - back)
	var d := back - c.s
	var last := c.lane
	for t: LG.Lane in c.trail:
		if d <= t.length:
			return lg.pos_at(t, t.length - d)
		d -= t.length
		last = t
	var p0 := last.pts[0]
	return p0 - lg.tan_at(last, 0.0) * d


## Updates pos, yaw and vel from the lane state (vis_off decays separately).
func update_pose(c: Car) -> void:
	if c.parked or c.lane == null:
		return
	var L := c.length
	var pf := point_back(c, 0.2 * L)
	var pr := point_back(c, 0.8 * L)
	var h := pf - pr
	if h.length_squared() < 1e-12:
		h = lg.tan_at(c.lane, c.s)
	h = h.normalized()
	var ctr := pf - h * (0.3 * L)
	var lat := c.lat_off
	if c.kind == "bike":
		lat = BIKE_LAT * (1.0 - lg.pass_factor(c.lane, c.s)) if c.lane.kind == LG.STRAIGHT else BIKE_LAT * 0.5
	elif c.lane.shifted and c.half_w > SEDAN_HW:
		lat -= lg.pass_factor(c.lane, maxf(c.s - L * 0.5, 0.0)) * (c.half_w - SEDAN_HW + 0.004)
	ctr += Vector2(-h.y, h.x) * lat
	var p := Vector3(ctr.x, WS.ASPHALT_TOP, ctr.y)
	c.vel = Vector3(h.x, 0, h.y) * c.v
	c.pos = p
	c.yaw = atan2(h.x, h.y)


## Drawn transform of c (with the smoothing offsets, and carried on by the time its simulation
## LOD has not stepped yet, never past what its last step allowed).
func draw_xform(c: Car) -> Transform3D:
	var b := Basis(Vector3.UP, c.yaw + c.vis_yaw)
	var p := c.pos + c.vis_off
	if c.acc_dt > 0.0 and c.v > 0.0 and not c.parked and not c.far and c.park_t < 0.0:
		p += c.vel * (minf(c.v * c.acc_dt, c.ext_room) / c.v)
	return Transform3D(b, p)


## World AABB of c (from its oriented box).
func aabb(c: Car) -> AABB:
	var b := Basis(Vector3.UP, c.yaw + c.vis_yaw)
	var hx := b.x * c.half_w
	var hz := b.z * (c.length * 0.5)
	var ext := Vector3(absf(hx.x) + absf(hz.x), c.height * 0.5, absf(hx.z) + absf(hz.z))
	var ctr := c.pos + c.vis_off + Vector3(0, c.height * 0.5, 0)
	return AABB(ctr - ext, ext * 2.0)


# ------------------------------------------------------------------ stepping

## Advances every vehicle by dt seconds of game-scaled time.
func step(dt: float) -> void:
	var decay := exp(-dt * 1.6)
	var near2 := LOD_NEAR * LOD_NEAR
	var full2 := LOD_FULL * LOD_FULL
	_gather_blocks()
	for c: Car in cars.duplicate():
		if c.dead or c.parked or c.role == PLAYER:
			continue
		var h := dt
		if not c.far and c.park_t < 0.0:
			var dx := c.pos.x - player_pos.x
			var dz := c.pos.z - player_pos.z
			var d2 := dx * dx + dz * dz
			c.acc_dt += dt
			if player_on and d2 > full2 and c.acc_dt < (LOD_DT if d2 > near2 else LOD_MID_DT):
				continue
			h = c.acc_dt
			c.acc_dt = 0.0
		if c.park_t >= 0.0:
			_pull_in(c, h)
		elif c.far:
			_advance_far(c, h)
		elif c.stuck:
			c.v = 0.0
		else:
			_drive(c, h)
		if c.vis_off != Vector3.ZERO:
			c.vis_off *= decay
			if c.vis_off.length_squared() < 1e-10:
				c.vis_off = Vector3.ZERO
		if c.vis_yaw != 0.0:
			c.vis_yaw *= decay
			if absf(c.vis_yaw) < 1e-4:
				c.vis_yaw = 0.0


func _drive(c: Car, dt: float) -> void:
	if c.lane == null or not c.lane.alive:
		c.stuck = true
		c.v = 0.0
		return
	var vmax := _vmax(c)
	var lead := _leader(c)
	var gap: float = lead[0]
	var vl: float = lead[1]
	var hard: float = gap - MIN_GAP
	var held := false
	var stop := _stops(c)
	var sgap: float = stop[0]
	if sgap < INF:
		held = true
		if sgap + IDM.S0 < gap:
			gap = sgap + IDM.S0
			vl = 0.0
		hard = minf(hard, sgap)
	var pl := _player_gap(c)
	var pg: float = pl[0]
	if pg < INF:
		if pg < gap:
			gap = pg
			vl = pl[1]
		hard = minf(hard, pg - MIN_GAP - WS.PLAYER_RADIUS)
	var acc := IDM.acc(c.v, vmax, gap, c.v - vl)
	var hb := _hold_brake(c)
	if hb > 0.0:
		acc = minf(acc, -hb)
	c.stun_t = maxf(0.0, c.stun_t - dt)
	var v1 := maxf(0.0, c.v + acc * dt)
	var ds := (c.v + v1) * 0.5 * dt
	if ds > hard:
		ds = maxf(0.0, hard)
		v1 = minf(v1, ds / maxf(dt, 1e-4))
	# A car a hair from its stop settles instead of creeping for ever.
	if held and sgap < 0.3 * WS.M and v1 < 0.6 * WS.M:
		v1 = 0.0
	c.a = (v1 - c.v) / maxf(dt, 1e-4)
	c.v = v1
	c.ext_room = maxf(0.0, hard - ds)
	if c.v < 0.1 * WS.M:
		c.stalled_s += dt
		if held:
			c.wait_t += dt
	else:
		c.stalled_s = 0.0
		c.wait_t = 0.0
	_advance(c, ds)
	if not c.dead and c.goal_lane != null and c.lane == c.goal_lane and c.s >= c.goal_s - ARRIVE_TOL and c.v < 0.4 * WS.M:
		c.v = 0.0
		if not c.arrived:
			c.arrived = true
			if on_arrive.is_valid():
				on_arrive.call(c)
	if not c.dead:
		update_pose(c)
		c.wheel_spin += ds


## Desired speed: own cap or the lane limit, braking ahead for slower (curved) lanes and creeping
## past a blocked tile (a crash or a downed line) when the path still runs through it.
func _vmax(c: Car) -> float:
	var base := c.v0 if c.v0 > 0.0 else c.lane.base_limit * c.speed_f
	var v := minf(base, c.lane.limit * (1.0 if c.v0 > 0.0 else c.speed_f))
	if lg.is_blocked(c.lane.tile) and not c.siren:
		v = minf(v, BLOCKED_SPEED)
	var d := c.lane.length - c.s
	for l: LG.Lane in c.path:
		if d > 0.6:
			break
		var lim := l.limit * (1.0 if c.v0 > 0.0 else c.speed_f)
		if c.v0 > 0.0:
			lim = minf(lim, c.v0)
		if lg.is_blocked(l.tile) and not c.siren:
			lim = minf(lim, BLOCKED_SPEED)
		v = minf(v, IDM.approach_speed(lim, d))
		d += l.length
	if c.kind == "bike":
		v = minf(v, c.v0 if c.v0 > 0.0 else 4.0 * WS.M)
	return maxf(v, 0.5 * WS.M)


## [gap to the nearest vehicle ahead along the path (front to its rear), its speed].
func _leader(c: Car) -> Array:
	var look := clampf(c.v * c.v / (2.0 * IDM.B) + c.v * 1.6 + 0.25, 0.3, 1.0)
	var best := INF
	var bv := 0.0
	var l := c.lane
	var idx := l.cars.find(c)
	for k in range(idx + 1, l.cars.size()):
		var o: Car = l.cars[k]
		if _ignores(c, o):
			continue
		best = o.s - o.length - c.s
		bv = o.v
		break
	for o: Car in l.tails:
		if o == c or _ignores(c, o):
			continue
		var r := rear_on(o, l)
		if r > c.s - 0.01 and r - c.s < best:
			best = r - c.s
			bv = o.v
	if best < INF:
		return [best, bv]
	var d := l.length - c.s
	for x: LG.Lane in c.path:
		if d > look:
			break
		for o: Car in x.cars:
			if o == c or _ignores(c, o):
				continue
			var g := d + o.s - o.length
			if g < best:
				best = g
				bv = o.v
			break
		for o: Car in x.tails:
			if o == c or _ignores(c, o):
				continue
			var g := d + rear_on(o, x)
			if g < best:
				best = g
				bv = o.v
		if best < INF:
			break
		d += x.length
	return [best, bv]


## Cars pass cyclists riding at the carriageway edge.
func _ignores(c: Car, o: Car) -> bool:
	return o.kind == "bike" and c.kind != "bike" and o.lane != null and lg.pass_factor(o.lane, o.s) < 0.3


## [distance from c's front to the nearest point it must stop at (INF when none)].
func _stops(c: Car) -> Array:
	var look := clampf(c.v * c.v / (2.0 * IDM.B) + 0.35, 0.35, 1.1)
	var best := INF
	var d := -c.s
	var n := c.path.size() + 1
	for k in range(n):
		var x: LG.Lane = c.lane if k == 0 else c.path[k - 1]
		if d > look:
			break
		if not x.alive:
			best = minf(best, maxf(d, 0.0))
			break
		if c.goal_lane == x and c.goal_s >= 0.0:
			var dg := d + c.goal_s
			if dg >= -0.002:
				best = minf(best, maxf(dg, 0.0))
				break
		if x.kind == LG.APPROACH:
			var ds := d + x.stop_s
			if ds >= -0.001 and c.gate != x.id:
				var mv: LG.Lane = c.path[k] if k < c.path.size() else null
				var after: LG.Lane = c.path[k + 1] if k + 1 < c.path.size() else null
				if permit(c, x, mv, after, ds):
					c.gate = x.id
				else:
					best = minf(best, maxf(ds, 0.0))
					break
			# People already on the entry zebra.
			var dz := d + x.zebra_s0 - 0.004
			if dz >= 0.0 and _zebra_busy(x.tile, x.zebra_arm):
				best = minf(best, dz)
				break
		elif x.kind == LG.MOVE and x.zebra_arm >= 0:
			var dz := d + x.zebra_s0 - 0.006
			if dz >= 0.0 and _zebra_busy(x.tile, x.zebra_arm):
				best = minf(best, dz)
				break
		if k == n - 1 and c.goal_lane == null and lg.next_lanes(x).is_empty():
			best = minf(best, maxf(d + x.length, 0.0))
		d += x.length
	var hb := _hold_brake(c)
	if hb > 0.0:
		best = minf(best, c.v * c.v / (2.0 * hb))
	return [best]


## How hard c brakes to stand still: stunned by a knock, or held by a conversation; 0 when free.
func _hold_brake(c: Car) -> float:
	if c.stun_t > 0.0:
		return STUN_BRAKE
	return IDM.B * 1.5 if c.hold else 0.0


## Gap from c's front to the player when they stand in its forward corridor, else INF.
func _gather_blocks() -> void:
	_blocks.clear()
	var driving := false
	for c: Car in cars:
		if c.role != PLAYER or c.dead:
			continue
		driving = driving or c.driven
		var h := Vector2(sin(c.yaw), cos(c.yaw))
		var v := Vector2(c.vel.x, c.vel.z)
		_blocks.append([Vector2(c.pos.x, c.pos.z), h, c.length * 0.5, c.half_w, v])
	if player_on and not driving:
		_blocks.append([Vector2(player_pos.x, player_pos.z), Vector2.ZERO, -1.0, 0.0, Vector2.ZERO])
	if extra_blocks.is_valid():
		_blocks.append_array(extra_blocks.call())


## [gap, speed] to the nearest block on c's path: the distance from its front to the block's
## edge along the path, and the block's speed along the path there; [INF, 0] when none.
func _player_gap(c: Car) -> Array:
	var best := [INF, 0.0]
	if _blocks.is_empty():
		return best
	var front := lg.pos_at(c.lane, c.s)
	var look := c.v * c.v / (2.0 * IDM.B) + 2.0 * WS.M + c.v * 0.5 + 0.1
	for b: Array in _blocks:
		if b.size() > 5 and int(b[5]) == c.id:
			continue
		if front.distance_to(b[0]) > look + 0.2 + maxf(float(b[2]), 0.0):
			continue
		var g := _gap_to(c, b, look)
		if float(g[0]) < float(best[0]):
			best = g
	return best


func _gap_to(c: Car, b: Array, look: float) -> Array:
	var d := 0.0
	var x := c.lane
	var s := c.s
	var k := -1
	while d <= look:
		var q := lg.pos_at(x, s)
		if _in_block(q, b, c.half_w):
			var along := maxf(0.0, (b[4] as Vector2).dot(lg.tan_at(x, s)))
			# Distance from the front to the player's edge (a car's box is grown by c's half width).
			return [maxf(d - WS.PLAYER_RADIUS, 0.0) if float(b[2]) < 0.0 else d, along]
		s += 0.02
		d += 0.02
		if s > x.length:
			k += 1
			if k >= c.path.size():
				break
			s -= x.length
			x = c.path[k]
	return [INF, 0.0]


static func _in_block(q: Vector2, b: Array, half_w: float) -> bool:
	var rel: Vector2 = q - (b[0] as Vector2)
	if float(b[2]) < 0.0:
		return rel.length() <= WS.ROAD_HALF * 0.5
	var h: Vector2 = b[1]
	var grow := half_w + 0.2 * WS.M
	return absf(rel.dot(h)) <= float(b[2]) + grow and absf(rel.cross(h)) <= float(b[3]) + grow


## True when walkers are on (or stepping onto) the zebra across `arm` of tile i.
func _zebra_busy(i: int, arm: int) -> bool:
	if sw == null or arm < 0:
		return false
	var z := sw.zebra_at(i, arm)
	return z != null and not z.walkers.is_empty()


## True when c may pass the stop point of approach x into move mv (then the lane `after`).
func permit(c: Car, x: LG.Lane, mv: LG.Lane, after: LG.Lane, d_stop: float) -> bool:
	return hold_reason(c, x, mv, after, d_stop).is_empty()


## Why c must hold at the stop point of approach x ("" when it may go): red, amber, zebra, yield,
## box, room.
func hold_reason(c: Car, x: LG.Lane, mv: LG.Lane, after: LG.Lane, d_stop: float) -> String:
	if mv == null:
		return ""
	var t: LG.TileInfo = lg.info(x.tile)
	if t == null:
		return ""
	if t.lights:
		var st := jn.light(x.tile, x.from_e)
		if c.siren:
			if st != JN.GREEN:
				if c.v > SIREN_RED_SPEED or _box_busy(mv):
					return "red"
				for e in range(4):
					if e != x.from_e and _threat(t, e, mv, 3.0):
						return "red"
		elif st == JN.RED:
			return "red"
		elif st == JN.AMBER:
			if d_stop > c.v * c.v / (2.0 * IDM.B) + 0.01:
				return "amber"
		elif jn.green_left(x.tile, x.from_e) < 1.0 and d_stop > c.v * c.v / (2.0 * IDM.B) + 0.02:
			return "amber"
	if _zebra_busy(x.tile, x.zebra_arm):
		return "zebra"
	if mv.gap_s > 0.0 and (c.wait_t < IMPATIENCE or c.siren):
		# A driver kept waiting accepts a shorter gap (never a crew under sirens).
		var need := mv.gap_s if c.siren else lerpf(mv.gap_s, GAP_MIN, clampf(c.wait_t / GAP_PATIENCE, 0.0, 1.0))
		for e: int in mv.yield_to:
			if _threat(t, e, mv, need):
				return "yield"
	if _box_busy(mv):
		return "box"
	if after != null and _room(after, mv, c) < c.length + IDM.S0:
		return "room"
	return ""


## The hold reason for c at the next stop point within reach ("" when none), for tests and tuning.
func why_held(c: Car) -> String:
	if c.lane == null:
		return "no lane"
	var d := -c.s
	for k in range(c.path.size() + 1):
		var x: LG.Lane = c.lane if k == 0 else c.path[k - 1]
		if d > 1.2:
			break
		if x.kind == LG.APPROACH and d + x.stop_s >= -0.001 and c.gate != x.id:
			var mv: LG.Lane = c.path[k] if k < c.path.size() else null
			var after: LG.Lane = c.path[k + 1] if k + 1 < c.path.size() else null
			return hold_reason(c, x, mv, after, d + x.stop_s)
		d += x.length
	return ""


## True when a vehicle on a move that conflicts with mv has not yet cleared the conflict.
func _box_busy(mv: LG.Lane) -> bool:
	for k in range(mv.conflicts.size()):
		var cid: int = mv.conflicts[k]
		var o: LG.Lane = lg.lanes[cid] if cid < lg.lanes.size() else null
		if o == null:
			continue
		var clear: float = mv.conflict_clear[k] + 0.01
		for oc: Car in o.cars:
			if oc.s - oc.length < clear:
				return true
		for oc: Car in o.tails:
			if rear_on(oc, o) < clear:
				return true
	return false


## True when a vehicle coming from arm e of junction t would reach the box within `secs` on a
## move that conflicts with mv (unknown moves count as conflicting).
func _threat(t: LG.TileInfo, e: int, mv: LG.Lane, secs: float) -> bool:
	var a: LG.Lane = t.approach[e]
	if a == null:
		return false
	var feeders: Array = [[a, 0.0]]
	for p: LG.Lane in lg.prev_lanes(a):
		feeders.append([p, p.length])
	for f: Array in feeders:
		var l: LG.Lane = f[0]
		var extra: float = f[1]
		for o: Car in l.cars:
			if o.kind == "bike" and o.v < 0.05:
				continue
			var omv := _next_move(o, a)
			if omv != null and omv != mv and not mv.conflicts.has(omv.id):
				continue
			var dist := extra + a.stop_s - o.s
			if o.gate == a.id and dist > -0.4:
				return true
			if dist < -0.001:
				continue
			if o.v < 1.0 * WS.M:
				continue
			if dist / o.v < secs:
				return true
	return false


## The move o will take after approach a (null when unknown).
func _next_move(o: Car, a: LG.Lane) -> LG.Lane:
	if o.lane == a:
		return o.path[0] if not o.path.is_empty() else null
	for k in range(o.path.size() - 1):
		if o.path[k] == a:
			return o.path[k + 1]
	return null


## Free length from the start of lane `after` (beyond move mv) along c's own path, up to the first
## vehicle (a short approach lane of the next junction counts with what lies beyond it), minus
## what is queued on mv.
func _room(after: LG.Lane, mv: LG.Lane, c: Car) -> float:
	var need := c.length + IDM.S0
	var free := 0.0
	var k := c.path.find(after)
	var x := after
	while x != null:
		var block := INF
		for o: Car in x.cars:
			if o != c:
				block = o.s - o.length
				break
		for o: Car in x.tails:
			if o != c:
				block = minf(block, rear_on(o, x))
		if block < INF:
			free += maxf(block, 0.0)
			break
		free += x.length
		if free >= need + 0.05:
			break
		k = k + 1 if k >= 0 else -1
		x = c.path[k] if k >= 0 and k < c.path.size() else null
		if x == null:
			# Open-ended path: assume the road goes on.
			free += 0.5
	for o: Car in mv.cars:
		if o != c:
			free -= o.length + IDM.S0
	return free


## Moves c's front ds along its path, crossing into the next lanes.
func _advance(c: Car, ds: float) -> void:
	c.s += ds
	while c.s > c.lane.length:
		if c.path.is_empty():
			_extend(c)
		if c.path.is_empty():
			c.s = c.lane.length
			c.v = 0.0
			break
		var nxt: LG.Lane = c.path.pop_front()
		var over := c.s - c.lane.length
		var old := c.lane
		old.cars.erase(c)
		old.tails.append(c)
		c.trail.push_front(old)
		c.lane = nxt
		c.s = over
		_insert(nxt, c)
		if old.kind == LG.APPROACH and c.gate == old.id:
			c.gate = -1
	_trim_trail(c)
	if c.path.size() < 3:
		_extend(c)


func _trim_trail(c: Car) -> void:
	var rem := c.length - c.s
	var k := 0
	while k < c.trail.size():
		if rem <= 0.0:
			for j in range(k, c.trail.size()):
				(c.trail[j] as LG.Lane).tails.erase(c)
			c.trail.resize(k)
			break
		rem -= (c.trail[k] as LG.Lane).length
		k += 1


## Extends an open-ended (ambient) path with random turns; trips and fleets keep their own paths.
func _extend(c: Car) -> void:
	if c.goal_lane != null:
		return
	if c.role != "ambient" and c.role != "truck" and c.role != "garbage":
		return
	var last: LG.Lane = c.path[c.path.size() - 1] if not c.path.is_empty() else c.lane
	var guard := 0
	while c.path.size() < 4 and guard < 6:
		guard += 1
		var opts := lg.next_lanes(last)
		if opts.is_empty():
			return
		var pick: LG.Lane = _choose(opts)
		if pick == null:
			return
		c.path.append(pick)
		last = pick


func _choose(opts: Array) -> LG.Lane:
	var total := 0.0
	var w: Array[float] = []
	for l: LG.Lane in opts:
		var x := 0.0
		var exit_t := lg.across(l.tile, l.to_e) if l.to_e >= 0 else -1
		if lg.is_blocked(l.tile) or (exit_t >= 0 and lg.is_blocked(exit_t)):
			x = 0.0001
		elif l.turn == 0:
			x = 0.55
		elif l.turn == 1:
			x = 0.25
		elif l.turn == -1:
			x = 0.2
		else:
			x = 0.02
		w.append(x)
		total += x
	var r := _rng.randf() * total
	for k in range(opts.size()):
		r -= w[k]
		if r <= 0.0:
			return opts[k]
	return opts[opts.size() - 1]


## Data-only motion beyond the traffic radius: along the path at FAR_SPEED of the driver's speed
## on each lane (lights and queues are averaged into that factor).
func _advance_far(c: Car, dt: float) -> void:
	var v := (c.v0 if c.v0 > 0.0 else c.lane.limit * c.speed_f) * FAR_SPEED
	c.v = v
	var ds := v * dt
	c.s += ds
	if c.goal_lane == c.lane and c.s >= c.goal_s:
		c.s = c.goal_s
		c.v = 0.0
		if not c.arrived:
			c.arrived = true
			if on_arrive.is_valid():
				on_arrive.call(c)
		return
	while c.s > c.lane.length:
		if c.path.is_empty():
			_extend(c)
		if c.path.is_empty():
			c.s = c.lane.length
			break
		c.s -= c.lane.length
		c.lane = c.path.pop_front()
		if c.goal_lane == c.lane and c.s >= c.goal_s:
			c.s = c.goal_s
	var p := lg.pos_at(c.lane, c.s)
	var h := lg.tan_at(c.lane, c.s)
	c.pos = Vector3(p.x, WS.ASPHALT_TOP, p.y)
	c.yaw = atan2(h.x, h.y)
	c.vel = Vector3(h.x, 0, h.y) * v


## Takes c off the lanes and keeps it moving as data.
func make_far(c: Car) -> void:
	if c.far or c.parked:
		return
	var l := c.lane
	var s := c.s
	_unregister(c)
	c.lane = l
	c.s = s
	c.far = true
	c.gate = -1


## Puts a data-only vehicle back on its lane when there is room. Returns true on success.
func make_near(c: Car) -> bool:
	if not c.far or c.lane == null or not c.lane.alive:
		return false
	if c.s < c.length or not fits(c.lane, c.s, c.length):
		return false
	var l := c.lane
	c.far = false
	_insert(l, c)
	c.v = minf(c.v, l.limit * 0.8)
	update_pose(c)
	return true


## Starts the slide from the lane into curb slot (i, k): the car must be stopped beside it.
func begin_pull_in(c: Car, i: int, k: int) -> void:
	c.park_t = 0.0
	c.park_from = c.pos
	c.park_from_yaw = c.yaw
	c.slot_tile = i
	c.slot_k = k
	if lg.slot_owner(i, k).is_empty():
		lg.set_slot(i, k, "car:%d" % c.id)


func _pull_in(c: Car, dt: float) -> void:
	c.park_t = minf(1.0, c.park_t + dt / PARK_TIME)
	var pose := lg.slot_pose(c.slot_tile, c.slot_k)
	var p: Vector2 = pose[0]
	var h: Vector2 = pose[1]
	var to := Vector3(p.x, WS.ASPHALT_TOP, p.y)
	var u := smoothstep(0.0, 1.0, c.park_t)
	var to_yaw := atan2(h.x, h.y)
	c.pos = c.park_from.lerp(to, u)
	# A slight angle in as it noses toward the curb.
	c.yaw = lerp_angle(c.park_from_yaw, to_yaw, u) + sin(u * PI) * 0.12
	c.v = 0.0
	if c.park_t >= 1.0:
		park_at(c, c.slot_tile, c.slot_k)


## Re-places vehicles on rebuilt tiles and keeps their drawn position continuous.
func on_lanes_rebuilt(tiles: Dictionary) -> void:
	if tiles.is_empty():
		return
	for c: Car in cars:
		if c.parked or c.far or c.lane == null or c.park_t >= 0.0:
			continue
		var hit := tiles.has(c.lane.tile)
		if not hit:
			for t: LG.Lane in c.trail:
				if tiles.has(t.tile):
					hit = true
					break
		if not hit:
			continue
		if not c.lane.alive:
			continue
		c.s = minf(c.s, c.lane.length)
		var before := c.pos + c.vis_off
		update_pose(c)
		c.vis_off = before - c.pos
		c.vis_off.y = 0.0
