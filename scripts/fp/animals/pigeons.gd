extends "res://scripts/fp/animals/bird_flocks.gd"
## The pigeons (part of the animals feature): where flocks keep (the sidewalk in front of some
## shops and of the civic buildings people gather at, the parks, and a share of the plain street
## corners), coming out by day near the player and going beyond FAR; and where none of those is
## about, one ambient flock near the player (a young city shows pigeons from its first day). The
## world fed to their behaviour (pigeon_flock.gd) before every step; one MultiMesh of
## pigeon_body.gd's bird per flock, and the crumbs the hero throws them (E on a flock close by).
## Their coos and wingbeats go out on the bus (animal_called). The shared flock wiring lives in
## bird_flocks.gd.

const STREETS := preload("res://scripts/fp/animals/street_spots.gd")

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
## Plain street flocks (no shop or civic lot in front needed): this share of the straight road
## tiles keeps a few pigeons on its own sidewalk. When no flock of any kind is near the player, the
## scan also puts out one ambient flock (BASELINE_KEY) on the nearest free sidewalk point, so a
## young city still shows pigeons; the spot's birds come from its tile's roll like any other's.
const ROAD_SHARE := 0.15
const ROAD_N := Vector2i(3, 6)
const ROAD_R := 0.2
const BASELINE_KEY := "b:pigeons"
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
	"hook": 3.0,
	"kick": 3.5,
	"swing": 3.5,
	"shove": 3.0,
	"wave": 3.0,
	"dance": 3.5,
	"shout": 12.0,
	"vault": 4.0,
	"hop": 3.0,
	"climb": 3.0,
	"roll": 5.0,
	"run_up": 3.0,
	"catch": 3.0,
	"leap": 4.0,
	"hijack": 4.0,
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
## Feathers in the puff of a bird the hero strikes.
const FEATHERS := 14
## A crumb's size (m) and colour.
const CRUMB := Vector3(0.016, 0.007, 0.012)
const CRUMB_COL := Color(0.86, 0.74, 0.52)
## The photo shot stands STAND_M (m) from the flock's crumbs, looking PHOTO_PITCH (degrees) down.
const PHOTO_KEY := "photo:pigeons"
const STAND_M := 2.6
const PHOTO_PITCH := -28.0
const NO_POINT := Vector3(NAN, NAN, NAN)

static var _crumb_mesh: BoxMesh = null

## The times the hero fed a flock.
var feeds: int = 0
## The photo shot's {"spot", "cam"}, {} without one.
var _photo: Dictionary = {}


func setup(p_ctx: FpContext) -> void:
	setup_flocks(p_ctx)
	name = "Pigeons"


## Every scan: the flocks too far off go; in the rain they all stay in (they shelter); else by day
## (and with the flag on) the spots near me get theirs, the nearest first; and with no flock near me
## after that, one ambient flock comes out anyway (_baseline).
func scan(me: Vector3, by_day: bool, rain := false) -> void:
	var on := by_day and not rain and FeatureFlags.enabled("pigeons")
	scan_flocks(me, on, MAX_FLOCKS, NEAR, FAR, rain)
	if on:
		_baseline(me)


## dt game seconds of the flocks (bird_flocks.gd step_flocks()). The flag off takes them away.
func step(dt: float) -> void:
	step_flocks(dt, FeatureFlags.enabled("pigeons"))


## The hero struck bird b of flock f from src at strength 0..1: it is knocked off in a puff of
## feathers and the flock goes up.
func hit(f: FLOCK.Flock, b: FLOCK.Bird, src: Vector3, strength: float) -> void:
	flock.hit(f, b, src, strength)
	if not is_inside_tree():
		return
	var fx := CPUParticles3D.new()
	fx.name = "Feathers"
	fx.top_level = true
	fx.one_shot = true
	fx.amount = FEATHERS
	fx.lifetime = 1.4
	fx.explosiveness = 0.9
	fx.direction = Vector3.UP
	fx.spread = 80.0
	fx.initial_velocity_min = 0.4 * WS.M
	fx.initial_velocity_max = 1.2 * WS.M
	fx.gravity = Vector3.DOWN * 0.8 * WS.M
	fx.damping_min = 1.5 * WS.M
	fx.damping_max = 2.5 * WS.M
	fx.angular_velocity_min = -360.0
	fx.angular_velocity_max = 360.0
	var quill := QuadMesh.new()
	quill.size = Vector2(0.03, 0.012) * WS.M
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.74, 0.78)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	quill.material = mat
	fx.mesh = quill
	add_child(fx)
	fx.global_position = b.pos + Vector3.UP * 0.12 * WS.M
	fx.emitting = true
	get_tree().create_timer(fx.lifetime + 0.5).timeout.connect(fx.queue_free)


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


## The spot's flock foraging round it (bird_flocks.gd add()), drawn at once.
func _make(key: String, s: Dictionary) -> FLOCK.Flock:
	var f := flock.add(key, s["home"], s["radius"], s["run"], s["across"], int(s["n"]))
	_make_node(f)
	return f


func _bird_near(f: FLOCK.Flock, g: Vector3) -> bool:
	for b: FLOCK.Bird in f.birds:
		if not b.air and _flat(b.pos, g) < FEED_NEAR * WS.M:
			return true
	return false


# ------------------------------------------------------------------ draw


## The flock's crumbs once they have moved.
func _after_draw(f: FLOCK.Flock) -> void:
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
		var turn := Basis(Vector3.UP, k * 2.39996).scaled(Vector3.ONE * WS.M)
		var at := f.crumb_spots[k] + Vector3(0.0, 0.5 * CRUMB.y * WS.M, 0.0)
		mm.set_instance_transform(k, Transform3D(turn, at))


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


## Tile i's flock spot: {"key", "lot", "home", "radius" (u), "run", "across", "n"} (pigeon_flock.gd
## add()), or {} for none.
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
		elif k == D.ROAD and _roll("street:%d" % i) < ROAD_SHARE:
			out = _road_spot(i)
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


## The sidewalk of a straight road tile itself (no lot in front of it): a small flock on either
## side of the street, the first free point winning.
func _road_spot(i: int) -> Dictionary:
	var m := RoadTopology.mask(ctx.sim, D.tx(i), D.ty(i))
	if m != RoadTopology.NS and m != RoadTopology.EW:
		return {}
	var run := RoadTopology.run_dir(m)
	var right := Vector3(-run.z, 0.0, run.x)
	for s: float in [1.0, -1.0]:
		for along: float in STREET_TRIES:
			var p := _tile_pos(i) + right * (s * WS.SIDEWALK_CENTER) + run * along
			if not _room(p):
				continue
			p.y = ctx.collision.walk_height(p)
			return _spot_dict(i, p, ROAD_R, run, right * s, ROAD_N)
	return {}


## The guaranteed flock: with no other flock about (none within NEAR, the cap not reached), one
## ambient flock (BASELINE_KEY) keeps to the free sidewalk point of the nearest straight road tile
## to me (street_spots.gd), so a young city without shops, civic buildings or parks still shows
## pigeons. Nothing when the player is off the streets (no free point near them).
func _baseline(me: Vector3) -> void:
	if _flock(BASELINE_KEY) != null or flock.flocks.size() >= MAX_FLOCKS:
		return
	for f: FLOCK.Flock in flock.flocks:
		if not f.key.begins_with("photo:") and _flat(f.home, me) <= NEAR:
			return
	var best := STREETS.nearest_road(ctx.sim, me, NEAR, _road_spot)
	if best.is_empty():
		return
	_make(BASELINE_KEY, best)


func _spot_dict(
	i: int, home: Vector3, r: float, run: Vector3, across: Vector3, n: Vector2i
) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("pigeons:%d" % i) ^ (ctx.sim.city_seed * 7919)
	var out := {
		"key": "s:%d" % i, "lot": i, "home": home, "radius": r, "run": run, "across": across
	}
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
