extends Node3D
## The pigeons (part of the animals feature): where flocks keep (the sidewalk in front of some
## shops and of the civic buildings people gather at, and the parks), coming out by day near the
## player and going beyond FAR; the world fed to their behaviour (pigeon_flock.gd) before every
## step; one MultiMesh of pigeon_body.gd's bird per flock, and the crumbs the hero throws them
## (E on a flock close by). Their coos and wingbeats go out on the bus (animal_called).

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const FLOCK := preload("res://scripts/fp/animals/pigeon_flock.gd")
const BODY := preload("res://scripts/fp/animals/pigeon_body.gd")
const PACK := preload("res://scripts/fp/animals/dog_pack.gd")

const MAX_STEP := 1.0 / 30.0
## Flocks come out within NEAR of the player (u) and go beyond FAR, at most MAX_FLOCKS at once.
const NEAR := 2.2
const FAR := 2.8
const MAX_FLOCKS := 4
## A flock keeps to the sidewalk in front of these kinds of lot (this share of them; a shop must
## be built) and to this share of the parks.
const FRONTS := {
	D.ZONE_C: 0.3, D.HALL: 1.0, D.TRAIN: 1.0, D.STADIUM: 0.7, D.UNIVERSITY: 0.7, D.SCHOOL: 0.3
}
const PARK_SHARE := 0.8
## A sidewalk flock forages STREET_R (u) either way along the street, a park's within PARK_R of its
## spot; how many birds (min, max).
const STREET_R := 0.25
const PARK_R := 0.3
const STREET_N := Vector2i(5, 10)
const PARK_N := Vector2i(8, 14)
## Homes tried along the street from the middle of the lot's front (u), and round a park's middle;
## a home needs HOME_ROOM (m) clear of props.
const STREET_TRIES: Array[float] = [0.0, 0.12, -0.12, 0.24, -0.24]
const PARK_TRIES: Array[Vector2] = [
	Vector2.ZERO, Vector2(0.15, 0.0), Vector2(-0.15, 0.0), Vector2(0.0, 0.15), Vector2(0.0, -0.15)
]
const HOME_ROOM := 0.6
## The hero's swings, shove, wave, dance, shout and parkour moves send up the flocks within these
## (m); someone hit in the street those within SEEN_HIT, a dog's bark those within BARK_M, a crash
## those within CRASH_M and a prop knocked over those within KNOCK_M.
const STARTLE := {
	"jab": 3.0,
	"cross": 3.0,
	"shove": 3.0,
	"wave": 3.0,
	"dance": 3.5,
	"shout": 12.0,
	"vault": 4.0,
	"hop": 3.0,
	"climb": 3.0,
	"roll": 5.0,
}
const SEEN_HIT := 8.0
const BARK_M := 6.0
const CRASH_M := 25.0
const KNOCK_M := 8.0
## E feeds a flock with a bird on the ground within FEED_NEAR (m) of where the view meets the
## ground, FEED_REACH (m) or less from the hero's feet; the crumbs land FEED_TOSS (m) in front of
## them, toward it.
const FEED_REACH := 4.5
const FEED_NEAR := 1.5
const FEED_TOSS := 1.2
## A pigeon's height at the shoulder (m): animal_called's size.
const SIZE_M := 0.13
## A crumb's size (m) and colour.
const CRUMB := Vector3(0.016, 0.007, 0.012)
const CRUMB_COL := Color(0.86, 0.74, 0.52)
## The player's car while they drive, half length and half width (m), for the birds' dodge.
const CAR := Vector2(2.3, 1.0)
## The photo shot stands STAND_M (m) from the flock's crumbs, looking PHOTO_PITCH (degrees) down.
const PHOTO_KEY := "photo:pigeons"
const STAND_M := 2.6
const PHOTO_PITCH := -28.0
const NO_POINT := Vector3(NAN, NAN, NAN)

static var _crumb_mesh: BoxMesh = null

var ctx: FpContext
var flock: FLOCK
## Calls made so far by kind ("coo", "flap", "takeoff") and the times the hero fed a flock.
var calls: Dictionary = {}
var feeds: int = 0
## Tile -> the spot of the flock keeping there (_spot_of()), {} for none.
var _spots: Dictionary = {}
var _car_was := Vector3.INF
## The photo shot's {"spot", "cam"}, {} without one.
var _photo: Dictionary = {}


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	name = "Pigeons"
	flock = FLOCK.new()
	flock.col = ctx.collision
	flock.on_call = _on_call


## Boot, load or New City: no flocks until the next scan.
func rebuilt() -> void:
	clear()
	flock.col = ctx.collision
	_spots.clear()


func tile_built(_i: int) -> void:
	_spots.clear()


func clear() -> void:
	if flock == null:
		return
	for f: FLOCK.Flock in flock.flocks.duplicate():
		_drop(f)


## Every scan: the flocks too far off go; by day (and with the flag on) the spots near me get
## theirs, the nearest first.
func scan(me: Vector3, by_day: bool) -> void:
	for f: FLOCK.Flock in flock.flocks.duplicate():
		if _flat(f.home, me) > FAR and not f.key.begins_with("photo:"):
			_drop(f)
	if not by_day or not FeatureFlags.enabled("pigeons"):
		return
	var near: Array = []
	var r := ceili(NEAR)
	for y in range(roundi(me.z) - r, roundi(me.z) + r + 1):
		for x in range(roundi(me.x) - r, roundi(me.x) + r + 1):
			if not D.in_bounds(x, y):
				continue
			var i := D.idx(x, y)
			var s := _spot_of(i)
			if not s.is_empty() and _flock("s:%d" % i) == null:
				var d := _flat(s["home"], me)
				if d <= NEAR:
					near.append([d, i, s])
	near.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for e: Array in near:
		if flock.flocks.size() >= MAX_FLOCKS:
			return
		_make("s:%d" % int(e[1]), e[2])


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


## dt game seconds of the flocks (in MAX_STEP steps), then their draw. The flag off takes them away.
func step(dt: float) -> void:
	if not FeatureFlags.enabled("pigeons"):
		clear()
		return
	var left := dt
	while left > 0.0:
		var h := minf(left, MAX_STEP)
		flock.step(h)
		left -= h
	_draw()


## A fright at at (a blow, a shout, a bark, a crash) sends up the flocks with a bird on the ground
## within r_m metres of it.
func startle(at: Vector3, r_m: float) -> void:
	if r_m > 0.0:
		flock.startle(at, r_m * WS.M)


func on_crash(at: Vector3, _speed: float, _what: String) -> void:
	startle(at, CRASH_M)


func on_knock(at: Vector3, _kind: String, _speed: float) -> void:
	startle(at, KNOCK_M)


## The flock the hero can feed: the view meets the ground FEED_REACH or less from their feet and
## within FEED_NEAR of one of its birds there. {"kind": "pigeons", "id" (its key), "tile", "pos"
## (that point), "dist", "label", "data": {"birds"}}, or {}.
func pick(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var d := dir.normalized()
	if ctx.player == null or d.y > -0.02 or not FeatureFlags.enabled("pigeons"):
		return {}
	var feet := ctx.player.position
	for f: FLOCK.Flock in flock.flocks:
		var t := (f.home.y - origin.y) / d.y
		if t <= 0.0 or t > max_dist:
			continue
		var g := origin + d * t
		if _flat(g, feet) > FEED_REACH * WS.M or not _bird_near(f, g):
			continue
		return {
			"kind": "pigeons",
			"id": f.key,
			"tile": ctx.collision.tile_at(g) if ctx.collision != null else -1,
			"pos": g,
			"dist": t,
			"label": "Feed the pigeons",
			"data": {"birds": f.birds.size()},
		}
	return {}


## E on a flock (pick's target t): the hero throws crumbs FEED_TOSS in front of them toward it and
## the birds come for them. False when the flock is gone.
func feed(t: Dictionary) -> bool:
	var f := _flock(str(t.get("id", "")))
	if f == null or ctx.player == null:
		return false
	var feet := ctx.player.position
	var to: Vector3 = (t.get("pos", f.home) as Vector3) - feet
	to.y = 0.0
	var at := feet + to.limit_length(FEED_TOSS * WS.M)
	var y := ctx.collision.walk_height(at) if ctx.collision != null else NAN
	at.y = y if not is_nan(y) else feet.y
	flock.feed(f, at)
	feeds += 1
	return true


## "12 pigeons in 2 flocks".
func detail() -> String:
	var n := 0
	for f: FLOCK.Flock in flock.flocks:
		n += f.birds.size()
	return "%d pigeons in %d flocks" % [n, flock.flocks.size()]


# ------------------------------------------------------------------ photo


## The photo shot ("pigeons"): the flock spot nearest me with room to stand STAND_M from it, seen
## from there; photo_prepare() brings its birds in to feed on crumbs. {} without one (or with the
## flag off).
func photo_shot(me: Vector3) -> Dictionary:
	_photo = {}
	if not FeatureFlags.enabled("pigeons"):
		return {}
	var best_d := INF
	for i in range(ctx.sim.kind.size()):
		var k := ctx.sim.kind[i]
		if k != D.PARK and not FRONTS.has(k):
			continue
		var dist := _flat(_tile_pos(i), me)
		if dist >= best_d:
			continue
		var s := _spot_of(i)
		var cam := _photo_cam(s) if not s.is_empty() else NO_POINT
		if not is_nan(cam.x):
			best_d = dist
			_photo = {"spot": s, "cam": cam}
	if _photo.is_empty():
		return {}
	var pos: Vector3 = _photo["cam"]
	var look: Vector3 = (_photo["spot"]["home"] as Vector3) - pos
	var shot := {"name": "pigeons", "pos": pos, "yaw": rad_to_deg(atan2(-look.x, -look.z))}
	shot.merge({"pitch": PHOTO_PITCH, "hour": 10.0})
	return shot


## The photo's flock (pinned, so the scan keeps it while the camera moves there) feeding round
## crumbs at its home, the birds already about them.
func photo_prepare() -> void:
	if _photo.is_empty():
		return
	var s: Dictionary = _photo["spot"]
	var old := _flock("s:%d" % int(s["lot"]))
	if old != null:
		_drop(old)
	var f := _make(PHOTO_KEY, s)
	var at: Vector3 = s["home"]
	flock.feed(f, at)
	var n := f.birds.size()
	for k in range(n):
		var b: FLOCK.Bird = f.birds[k]
		var a := TAU * k / n + 0.4 * sin(k * 2.7)
		var p := at + Vector3(cos(a), 0.0, sin(a)) * (0.3 + 0.35 * fposmod(k * 0.618, 1.0)) * WS.M
		var y := ctx.collision.walk_height(p)
		b.pos = Vector3(p.x, y if not is_nan(y) else at.y, p.z)
		b.yaw = atan2(at.x - p.x, at.z - p.z) + 0.5 * sin(k * 1.3)
	for _k in range(3):
		flock.step(MAX_STEP)
	_draw()


func photo_restore() -> void:
	var f := _flock(PHOTO_KEY)
	if f != null:
		_drop(f)


# ------------------------------------------------------------------ flocks


func _make(key: String, s: Dictionary) -> FLOCK.Flock:
	var f := flock.add(key, s["home"], s["radius"], s["run"], s["across"], int(s["n"]))
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
	return f


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


func _bird_near(f: FLOCK.Flock, g: Vector3) -> bool:
	for b: FLOCK.Bird in f.birds:
		if not b.air and _flat(b.pos, g) < FEED_NEAR * WS.M:
			return true
	return false


func _on_call(at: Vector3, call: String) -> void:
	calls[call] = int(calls.get(call, 0)) + 1
	if ctx.bus != null:
		ctx.bus.animal_called.emit(at, call, SIZE_M)


# ------------------------------------------------------------------ draw


func _draw() -> void:
	for f: FLOCK.Flock in flock.flocks:
		_draw_flock(f)


func _draw_flock(f: FLOCK.Flock) -> void:
	var mm := (f.node as MultiMeshInstance3D).multimesh
	for k in range(f.birds.size()):
		var b: FLOCK.Bird = f.birds[k]
		mm.set_instance_transform(k, FLOCK.xform(b))
		mm.set_instance_custom_data(k, FLOCK.pose(b))
	if f.crumbs_moved:
		f.crumbs_moved = false
		_draw_crumbs(f)


func _draw_crumbs(f: FLOCK.Flock) -> void:
	if f.crumbs_node == null:
		var mi := MultiMeshInstance3D.new()
		mi.name = "Crumbs"
		mi.multimesh = MultiMesh.new()
		mi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		mi.multimesh.mesh = _crumb()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		f.crumbs_node = mi
	var mm := (f.crumbs_node as MultiMeshInstance3D).multimesh
	mm.instance_count = f.crumb_spots.size()
	for k in range(f.crumb_spots.size()):
		var basis := Basis(Vector3.UP, k * 2.39996).scaled(Vector3.ONE * WS.M)
		var at := f.crumb_spots[k] + Vector3(0.0, 0.5 * CRUMB.y * WS.M, 0.0)
		mm.set_instance_transform(k, Transform3D(basis, at))


static func _crumb() -> BoxMesh:
	if _crumb_mesh == null:
		_crumb_mesh = BoxMesh.new()
		_crumb_mesh.size = CRUMB
		var mat := StandardMaterial3D.new()
		mat.albedo_color = CRUMB_COL
		mat.roughness = 0.9
		_crumb_mesh.material = mat
	return _crumb_mesh


# ------------------------------------------------------------------ spots


## Tile i's flock spot: {"lot", "home", "radius" (u), "run", "across", "n"} (pigeon_flock.gd add()),
## or {} for none.
func _spot_of(i: int) -> Dictionary:
	if _spots.has(i):
		return _spots[i]
	var out := {}
	var k := ctx.sim.kind[i]
	if ctx.collision != null and ctx.directory != null:
		if k == D.PARK and _roll("park:%d" % i) < PARK_SHARE:
			out = _park_spot(i)
		elif FRONTS.has(k) and _roll("front:%d" % i) < float(FRONTS[k]):
			if k != D.ZONE_C or ctx.sim.level[i] > 0:
				out = _front_spot(i)
	_spots[i] = out
	return out


## The sidewalk in front of lot i, on a straight road: home on its middle where there is room.
func _front_spot(i: int) -> Dictionary:
	var fr := ctx.directory.frontage(i)
	if fr < 0:
		return {}
	var m := RoadTopology.mask(ctx.sim, D.tx(fr), D.ty(fr))
	if m != RoadTopology.NS and m != RoadTopology.EW:
		return {}
	var road := _tile_pos(fr)
	var across := _tile_pos(i) - road
	var run := RoadTopology.run_dir(m)
	for along: float in STREET_TRIES:
		var p := road + across * WS.SIDEWALK_CENTER + run * along
		if _room(p):
			p.y = ctx.collision.walk_height(p)
			return _spot_dict(i, p, STREET_R, run, across, STREET_N)
	return {}


func _park_spot(i: int) -> Dictionary:
	var c := _tile_pos(i)
	for off: Vector2 in PARK_TRIES:
		var p := c + Vector3(off.x, 0.0, off.y)
		if _room(p):
			p.y = ctx.collision.walk_height(p)
			return _spot_dict(i, p, PARK_R, Vector3.ZERO, Vector3.ZERO, PARK_N)
	return {}


func _spot_dict(
	i: int, home: Vector3, r: float, run: Vector3, across: Vector3, n: Vector2i
) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("pigeons:%d" % i) ^ (ctx.sim.city_seed * 7919)
	var out := {"lot": i, "home": home, "radius": r, "run": run, "across": across}
	out["n"] = rng.randi_range(n.x, n.y)
	return out


## True when p is walkable ground (not the road, not water) with HOME_ROOM clear round it.
func _room(p: Vector3) -> bool:
	var y := ctx.collision.walk_height(p)
	if is_nan(y) or ctx.collision.surface_at(p) in ["asphalt", "water"]:
		return false
	return not ctx.collision.is_blocked(Vector3(p.x, y, p.z), HOME_ROOM * WS.M)


## Where the photo camera stands for spot s: STAND_M from its home back along the street (either
## way), or round it in a park, on free ground with a clear view of it; NAN when there is none.
func _photo_cam(s: Dictionary) -> Vector3:
	var home: Vector3 = s["home"]
	var run: Vector3 = s["run"]
	var dirs: Array = [run, -run]
	if run == Vector3.ZERO:
		dirs = [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]
	for dv: Vector3 in dirs:
		var p := home - dv * STAND_M * WS.M
		var y := ctx.collision.walk_height(p)
		if is_nan(y):
			continue
		p.y = y
		var eye := p + Vector3(0.0, WS.EYE, 0.0)
		var seen := ctx.collision.line_of_sight(eye, home + Vector3(0.0, 0.1 * WS.M, 0.0))
		if seen and not ctx.collision.is_blocked(p, WS.PLAYER_RADIUS):
			return p
	return NO_POINT


## A number in [0, 1) that stays the same for key in this city.
func _roll(key: String) -> float:
	return float(absi(hash("%s:%d" % [key, ctx.sim.city_seed])) % 10000) / 10000.0


static func _tile_pos(i: int) -> Vector3:
	return Vector3(D.tx(i), 0.0, D.ty(i))


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
