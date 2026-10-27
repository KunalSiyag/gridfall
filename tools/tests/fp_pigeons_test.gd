extends SceneTree
## Pigeons (the animals feature; docs/fp/ARCHITECTURE.md, Animals): by day a sidewalk spot near the
## player gets its flock (one MultiMesh of the pigeon) and at night none comes out; the birds
## forage round their spot, walking with the head's bob and pecking, and coo with the hero about;
## a lone bird walks off from the hero walking at it and flutters off from one stepping up to it
## and from a car about to hit it; a sprint at the flock sends it up together with one take-off
## clatter, it climbs, wheels and glides back down to its spot once the hero has gone, and a
## shout, a dog close by and a car driving into it send it up too; the hero's car horn sends it up
## as well, out of earshot leaves it be, and in the rain there is nothing to flush; E throws crumbs
## (the pick, a toast) and the birds gather round them and eat them up; pause freezes them; beyond
## FAR they go and come back; the flag off takes them away; the photo shot; a fresh city (only the
## founding roads and City Hall) still shows pigeons by the spawn, and where no spot of any kind
## is near the ambient flock keeps to a sidewalk by the player, none by night, out at dawn;
## self_test and teardown. Third
## person on a grown city; time runs through the feature's tick(1/60) and traffic's step.

const K := preload("res://tools/tests/fp_kit.gd")
const FRESH := preload("res://tools/tests/fp_fresh_city.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AF := preload("res://scripts/fp/animals/animals_feature.gd")
const PG := preload("res://scripts/fp/animals/pigeons.gd")
const FLOCK := preload("res://scripts/fp/animals/pigeon_flock.gd")
const BODY := preload("res://scripts/fp/animals/pigeon_body.gd")
const DRIVE := preload("res://scripts/fp/drive/drive_feature.gd")
const DT := 1.0 / 60.0
## The hero waits this far (m) along the street from the spot while the flock lands.
const AWAY_M := 20.0

var fails: Array[String] = []
var ctx: FpContext
var traffic: FpFeature
var f: FpFeature
var pg: PG
var fl: FLOCK
## The sidewalk spot the test's flock keeps to (pigeons.gd _spot_of()) and the flock's key.
var spot: Dictionary = {}
var key: String = ""
## Every animal_called [call, size] and every toast.
var calls: Array = []
var toasts: Array[String] = []


func _init() -> void:
	await process_frame
	var fx := FRESH.make_grown(
		get_root(), func(_at: Vector3, c: String, s: float) -> void: calls.append([c, s])
	)
	ctx = fx["ctx"]
	traffic = fx["traffic"]
	f = fx["animals"]
	if not bool(fx["ok"]):
		K.check(fails, false, "fixture: traffic and animals registered")
		K.finish(self, "FP_PIGEONS_TEST", fails)
		return
	ctx.bus.toast.connect(func(t: String, _k: String) -> void: toasts.append(t))
	pg = fx["pigeons"]
	fl = fx["flock"]
	spot = _street_spot()
	K.check(fails, not spot.is_empty(), "fixture: a sidewalk where pigeons keep")
	if not spot.is_empty():
		key = "s:%d" % int(spot["lot"])
		var fk := _check_spawn()
		if fk != null:
			_check_forage(fk)
			_check_solo()
			_check_scatter(fk)
			_check_frights(fk)
			_check_horn(fk)
			_check_feed(fk)
			_check_pause(fk)
		_check_far()
		_check_rain()
		_check_horn_rain()
		_check_flag()
		_check_photo()
	_check_fresh_city()
	_check_teardown()
	K.finish(self, "FP_PIGEONS_TEST", fails)


# ------------------------------------------------------------------ helpers


## Steps traffic and the animals secs (in 1/60 s steps).
func _step(secs: float) -> void:
	FRESH.step(traffic, f, secs)


## The first flock spot on a sidewalk (in front of a shop or a civic building), else {}.
func _street_spot() -> Dictionary:
	for i in range(ctx.sim.kind.size()):
		if not PG.FRONTS.has(ctx.sim.kind[i]):
			continue
		var s: Dictionary = pg.call("_spot_of", i)
		if not s.is_empty():
			return s
	return {}


func _flock(k: String = "") -> FLOCK.Flock:
	for fk: FLOCK.Flock in fl.flocks:
		if fk.key == (key if k.is_empty() else k):
			return fk
	return null


## The hero along_m metres along the street from the spot's home, facing it.
func _hero_at(along_m: float) -> void:
	var run: Vector3 = spot["run"]
	var look := -run if along_m >= 0.0 else run
	var at: Vector3 = (spot["home"] as Vector3) + run * along_m * WS.M
	ctx.player.teleport(at, rad_to_deg(atan2(-look.x, -look.z)))


## The flock's own world for fl.step(): the hero on foot at hero moving at vel, and cars.
func _world(hero: Vector3, vel: Vector3, cars: Array) -> void:
	fl.hero = hero
	fl.hero_vel = vel
	fl.hero_on_foot = true
	fl.cars = cars
	fl.passers = []
	fl.dogs = []


## Where p is across the sidewalk (toward the lot) and along the street from the spot's home (m).
func _offset(p: Vector3) -> Vector2:
	var off := p - (spot["home"] as Vector3)
	return Vector2(off.dot(spot["across"]), off.dot(spot["run"])) / WS.M


## True when every bird of fk is on the ground on the sidewalk round its spot, off the road.
func _home_ok(fk: FLOCK.Flock) -> bool:
	var r_m := float(spot["radius"]) / WS.M
	for b: FLOCK.Bird in fk.birds:
		var o := _offset(b.pos)
		if b.air or absf(o.x) > 1.7 or absf(o.y) > r_m + 0.8:
			return false
		if ctx.collision.surface_at(b.pos) == "asphalt":
			return false
	return true


func _all_up(fk: FLOCK.Flock) -> bool:
	return fk.birds.all(func(b: FLOCK.Bird) -> bool: return b.air)


## Steps until every bird of fk is on the ground with no take-off pending (at most max_s); the
## seconds it took, or -1.
func _wait_down(fk: FLOCK.Flock, max_s: float) -> float:
	var t := 0.0
	while t <= max_s:
		if fk.birds.all(func(b: FLOCK.Bird) -> bool: return not b.air and b.delay <= 0.0):
			return t
		_step(0.25)
		t += 0.25
	return -1.0


func _middle(fk: FLOCK.Flock) -> Vector3:
	var s := Vector3.ZERO
	for b: FLOCK.Bird in fk.birds:
		s += b.pos
	return s / maxf(fk.birds.size(), 1)


## The bird of fk on the ground nearest p, or the furthest along dir when dir is not zero.
func _bird(fk: FLOCK.Flock, p: Vector3, dir: Vector3 = Vector3.ZERO) -> FLOCK.Bird:
	var best: FLOCK.Bird = null
	var score := INF
	for b: FLOCK.Bird in fk.birds:
		var s := -b.pos.dot(dir) if dir != Vector3.ZERO else _flat(b.pos, p)
		if not b.air and s < score:
			score = s
			best = b
	return best


## The size the first call c was heard with, or -1.
func _heard(c: String) -> float:
	for e: Array in calls:
		if str(e[0]) == c:
			return float(e[1])
	return -1.0


func _count(c: String) -> int:
	return calls.filter(func(e: Array) -> bool: return str(e[0]) == c).size()


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# ------------------------------------------------------------------ checks


## At night the spot stays empty; by day the scan brings out its flock (spot "n" birds) on the
## sidewalk round it, drawn as one MultiMesh of the pigeon with each bird's tint and pose.
func _check_spawn() -> FLOCK.Flock:
	_hero_at(8.0)
	ctx.sky.night = 1.0
	f.on_world_rebuilt()
	_step(0.1)
	K.check(fails, _flock() == null, "spawn: at night no pigeons come out")
	ctx.sky.night = 0.0
	f.on_world_rebuilt()
	_step(0.1)
	var fk := _flock()
	var n := int(spot["n"])
	K.check(
		fails,
		fk != null and fk.birds.size() == n and _home_ok(fk),
		"spawn: by day the spot's flock comes out on the sidewalk (%d birds)" % n
	)
	if fk == null:
		return null
	var mi := fk.node as MultiMeshInstance3D
	var mm := mi.multimesh if mi != null else null
	var drawn := mm != null and mm.instance_count == n and mm.mesh == BODY.mesh()
	drawn = drawn and mm.use_colors and mm.use_custom_data
	K.check(
		fails,
		drawn and mi.material_override == BODY.material(),
		"spawn: one MultiMesh of the pigeon, with a tint and a pose for each bird"
	)
	return fk


## 20 s of foraging with the hero 8 m off: the birds walk about with the head's bob and peck, keep
## to the sidewalk round their spot (never the road), and one coos (animal_called at a pigeon's
## size).
func _check_forage(fk: FLOCK.Flock) -> void:
	calls.clear()
	var start: Array = []
	for b: FLOCK.Bird in fk.birds:
		start.append(b.pos)
	var pecked := 0.0
	var bobbed := 0.0
	var inside := true
	for _k in range(roundi(20.0 / DT)):
		_step(DT)
		for b: FLOCK.Bird in fk.birds:
			pecked = maxf(pecked, b.peck)
			if b.act == "walk":
				bobbed = maxf(bobbed, absf(b.bob))
		inside = inside and _home_ok(fk)
	var moved := 0
	for k in range(fk.birds.size()):
		if (fk.birds[k] as FLOCK.Bird).pos.distance_to(start[k]) > 0.3 * WS.M:
			moved += 1
	K.check(
		fails,
		moved * 2 >= fk.birds.size() and pecked > 0.8 and bobbed > 0.8,
		(
			"forage: they walk about (%d of %d), bobbing (%.2f) and pecking (%.2f)"
			% [moved, fk.birds.size(), bobbed, pecked]
		)
	)
	K.check(fails, inside, "forage: they keep to the sidewalk round their spot, off the road")
	var coo := _heard("coo")
	K.check(
		fails,
		is_equal_approx(coo, PG.SIZE_M),
		"forage: a bird coos with the hero about (animal_called, %.2f m)" % coo
	)


## A lone bird (a flock of its own, stepped directly with the others set aside): the hero walking
## at it from 2 m sends it off on foot, briskly; stepping up to it makes it flutter off ("flap")
## and land a metre or more on; a car about to run it over makes it flutter off too.
func _check_solo() -> void:
	var run: Vector3 = spot["run"]
	var home: Vector3 = spot["home"]
	var others: Array = fl.flocks.duplicate()
	fl.flocks.clear()
	var s := fl.add("test:solo", home, float(spot["radius"]), run, spot["across"], 1)
	var b: FLOCK.Bird = s.birds[0]
	b.act = "stand"
	b.act_t = 5.0
	var hero := b.pos - run * 2.0 * WS.M
	var vel := run * 0.8 * WS.M
	var p0 := b.pos
	var flew := false
	for _k in range(roundi(0.8 / DT)):
		_world(hero, vel, [])
		fl.step(DT)
		flew = flew or b.air
		hero += vel * DT
	K.check(
		fails,
		not flew and b.hurry and _flat(b.pos, p0) > 0.25 * WS.M,
		"solo: the hero walking at it sends it off on foot (%.2f m)" % (_flat(b.pos, p0) / WS.M)
	)
	b.pos = home
	b.act = "stand"
	b.act_t = 5.0
	calls.clear()
	hero = home - run * 0.7 * WS.M
	_world(hero, Vector3.ZERO, [])
	fl.step(DT)
	var hopped := b.act == "hop" and _heard("flap") >= 0.0
	for _k in range(roundi(1.5 / DT)):
		_world(hero, Vector3.ZERO, [])
		fl.step(DT)
	var on := _flat(b.pos, home) / WS.M
	K.check(
		fails,
		hopped and not b.air and on > 1.0,
		"solo: stepping up to it makes it flutter off (flap) and land %.1f m on" % on
	)
	b.act = "stand"
	b.act_t = 5.0
	var car := [b.pos - run * 6.0 * WS.M, run * 10.0 * WS.M, 2.3 * WS.M, 1.0 * WS.M]
	_world(home + run * 30.0 * WS.M, Vector3.ZERO, [car])
	fl.step(DT)
	K.check(fails, b.air, "solo: a car about to run it over makes it flutter off (%s)" % b.act)
	fl.remove(s)
	fl.flocks.append_array(others)


## The hero sprinting at the flock from 5 m: every bird is up within 0.6 s with one take-off
## clatter; they climb over 3 m and wheel, and once the hero has gone they glide back down to
## their spot.
func _check_scatter(fk: FLOCK.Flock) -> void:
	_hero_at(AWAY_M)
	_wait_down(fk, 40.0)
	var run: Vector3 = spot["run"]
	var lead := _bird(fk, Vector3.ZERO, run)
	var p := ctx.player
	p.teleport(lead.pos + run * 5.0 * WS.M, rad_to_deg(atan2(run.x, run.z)))
	p.velocity = -run * 4.5 * WS.M
	calls.clear()
	for _k in range(roundi(0.6 / DT)):
		p.position += p.velocity * DT
		_step(DT)
	var clatter := _count("takeoff")
	K.check(
		fails,
		_all_up(fk) and clatter >= 1 and clatter <= fl.flocks.size(),
		"scatter: a sprint at the flock sends every bird up with one clatter (%d)" % clatter
	)
	_hero_at(AWAY_M)
	var top := 0.0
	var wheeled := false
	for _k in range(roundi(4.0 / DT)):
		_step(DT)
		for b: FLOCK.Bird in fk.birds:
			top = maxf(top, b.pos.y - (spot["home"] as Vector3).y)
			wheeled = wheeled or b.act == "wheel"
	K.check(
		fails,
		top > 3.0 * WS.M and wheeled and fk.wheel_fit,
		"scatter: they climb (%.1f m) and wheel round" % (top / WS.M)
	)
	var t := _wait_down(fk, 40.0)
	K.check(
		fails,
		t >= 0.0 and _home_ok(fk),
		"scatter: with the hero gone they glide back down to their spot (%.1f s)" % t
	)


## A shout 8 m off, a dog 2 m from a bird and a car driving into the flock each send it up.
func _check_frights(fk: FLOCK.Flock) -> void:
	var run: Vector3 = spot["run"]
	var away: Vector3 = (spot["home"] as Vector3) + run * AWAY_M * WS.M
	_hero_at(8.0)
	ctx.bus.hero_action.emit("shout", ctx.player.position)
	_step(0.5)
	var shout := _all_up(fk)
	_hero_at(AWAY_M)
	_wait_down(fk, 40.0)
	var b := _bird(fk, _middle(fk))
	for _k in range(30):
		_world(away, Vector3.ZERO, [])
		fl.dogs = [[b.pos + (spot["across"] as Vector3) * 2.0 * WS.M, Vector3.ZERO]]
		fl.step(DT)
	var dog := _all_up(fk)
	_wait_down(fk, 40.0)
	var car := [_middle(fk) - run * 8.0 * WS.M, run * 10.0 * WS.M, 2.3 * WS.M, 3.0 * WS.M]
	for _k in range(30):
		_world(away, Vector3.ZERO, [car])
		fl.step(DT)
		car[0] = (car[0] as Vector3) + (car[1] as Vector3) * DT
	var crowd := _all_up(fk)
	K.check(
		fails,
		shout and dog and crowd,
		(
			"frights: a shout (%s), a dog close by (%s) and a car driving in (%s) send it up"
			% [shout, dog, crowd]
		)
	)
	_wait_down(fk, 40.0)


## The hero's car horn (horn_sounded): a horn at the flock's spot with the drive feature's reach
## sends every bird up, and one out of earshot (a small radius at a far point) leaves them be.
func _check_horn(fk: FLOCK.Flock) -> void:
	var home: Vector3 = spot["home"]
	var run: Vector3 = spot["run"]
	_hero_at(AWAY_M)
	_wait_down(fk, 40.0)
	ctx.bus.horn_sounded.emit(Vector2(home.x, home.z), DRIVE.HORN_STREET_R, false)
	_step(0.5)
	var near := _all_up(fk)
	_wait_down(fk, 40.0)
	# A horn whose reach stops short of the flock (the hero in a car well down the street).
	var far := home + run * 40.0 * WS.M
	ctx.bus.horn_sounded.emit(Vector2(far.x, far.z), 5.0 * WS.M, true)
	_step(0.5)
	var untouched := fk.birds.all(func(b: FLOCK.Bird) -> bool: return not b.air)
	K.check(fails, near, "horn: a horn at the flock sends every bird up")
	K.check(fails, untouched, "horn: one out of earshot leaves them be")


## While the rain holds (the P2 shelter), a horn finds nothing to flush: no flock is out to hear
## it, and none comes back out for it either.
func _check_horn_rain() -> void:
	var home: Vector3 = spot["home"]
	FRESH.force_weather(ctx, "rain")
	_step(AF.SCAN_S + 0.2)
	var sheltered := _flock() == null
	ctx.bus.horn_sounded.emit(Vector2(home.x, home.z), DRIVE.HORN_STREET_R, true)
	_step(0.5)
	K.check(
		fails,
		sheltered and _flock() == null,
		"horn: in the rain there is nothing to flush (the birds shelter)"
	)
	FRESH.force_weather(ctx, "clear")
	_step(AF.SCAN_S + 0.2)


## E on the flock from 3 m: the pick ("Feed the pigeons"), crumbs (drawn) and a toast; the birds
## gather round the crumbs (most within 0.9 m of them after 8 s) and eat them up.
func _check_feed(fk: FLOCK.Flock) -> void:
	var run: Vector3 = spot["run"]
	ctx.player.teleport(_middle(fk) - run * 3.0 * WS.M, rad_to_deg(atan2(-run.x, -run.z)))
	var target := _bird(fk, ctx.player.position)
	var eye := ctx.player.eye_position()
	var t := f.pick(eye, (target.pos - eye).normalized(), 6.0) if target != null else {}
	K.check(
		fails,
		str(t.get("kind", "")) == "pigeons" and str(t.get("id", "")) == key,
		"feed: the flock in front is picked (%s)" % str(t.get("label", ""))
	)
	toasts.clear()
	ctx.bus.interact_requested.emit(t)
	_step(DT)
	var mi := fk.crumbs_node as MultiMeshInstance3D
	var n := mi.multimesh.instance_count if mi != null else 0
	K.check(
		fails,
		int(pg.feeds) == 1 and n == FLOCK.CRUMBS and toasts.size() == 1,
		"feed: E throws %d crumbs with a toast (%s)" % [n, str(toasts)]
	)
	var c := Vector3.ZERO
	for p: Vector3 in fk.crumb_spots:
		c += p / maxf(fk.crumb_spots.size(), 1)
	_step(8.0)
	var close := 0
	for b: FLOCK.Bird in fk.birds:
		if not b.air and _flat(b.pos, c) < 0.9 * WS.M:
			close += 1
	K.check(
		fails,
		close * 10 >= fk.birds.size() * 6,
		"feed: the birds gather round the crumbs (%d of %d)" % [close, fk.birds.size()]
	)
	_step(15.0)
	var left := fk.crumb_spots.size()
	n = mi.multimesh.instance_count if mi != null else -1
	K.check(
		fails,
		left <= FLOCK.CRUMBS / 4 and n == left,
		"feed: they eat them up (%d of %d left)" % [left, FLOCK.CRUMBS]
	)


## Paused (sim speed 0) the birds stand frozen in their poses; running again, they move on.
func _check_pause(fk: FLOCK.Flock) -> void:
	ctx.sim.speed = 0
	_step(DT)
	var before: Array = []
	for b: FLOCK.Bird in fk.birds:
		before.append([b.pos, FLOCK.pose(b)])
	_step(1.0)
	var still := true
	for k in range(fk.birds.size()):
		var b: FLOCK.Bird = fk.birds[k]
		still = still and b.pos == before[k][0] and FLOCK.pose(b) == before[k][1]
	ctx.sim.speed = 1
	_step(3.0)
	var moved := false
	for k in range(fk.birds.size()):
		moved = moved or (fk.birds[k] as FLOCK.Bird).pos != before[k][0]
	K.check(fails, still and moved, "pause: the birds freeze and come back to life")


## The hero going beyond FAR takes the flock away (its MultiMesh freed); coming back brings it.
func _check_far() -> void:
	var fk := _flock()
	var node: Node = fk.node if fk != null else null
	var p := ctx.player
	var home := p.position
	p.teleport(home + Vector3(PG.FAR + 1.0, 0.0, 0.0), 0.0)
	_step(AF.SCAN_S + 0.1)
	var gone := _flock() == null and not is_instance_valid(node)
	p.teleport(home, 0.0)
	_step(AF.SCAN_S + 0.1)
	K.check(fails, gone, "far: beyond FAR the flock goes")
	K.check(fails, _flock() != null, "far: back again, it comes out again")


## In the rain no flock comes out (they shelter, as the cats do); once it clears they come back.
func _check_rain() -> void:
	FRESH.rain_gate(ctx, traffic, f, fails, "pigeons", func() -> int: return fl.flocks.size())


## The flag off takes every flock away (nothing to pick); on again, they come back.
func _check_flag() -> void:
	FeatureFlags.set_override("pigeons", false)
	_step(DT)
	var none := fl.flocks.is_empty() and pg.get_child_count() == 0
	var eye := ctx.player.eye_position()
	var t := f.pick(eye, ((spot["home"] as Vector3) - eye).normalized(), 6.0)
	FeatureFlags.set_override("pigeons", true)
	_step(AF.SCAN_S + 0.1)
	K.check(fails, none and str(t.get("kind", "")) != "pigeons", "flag: off takes the pigeons away")
	K.check(fails, _flock() != null, "flag: on again, they come back")


## The photo shot ("pigeons", photo_pigeons): with the sim paused, its flock feeds round crumbs
## in front of the camera; restore takes it away.
func _check_photo() -> void:
	var shot := {}
	for s: Dictionary in f.photo_shots():
		if str(s["name"]) == "pigeons":
			shot = s
	K.check(
		fails,
		str(shot.get("prepare", "")) == "photo_pigeons",
		"photo: a pigeons shot (%s)" % str(shot.get("pos", ""))
	)
	if shot.is_empty():
		return
	ctx.sim.speed = 0
	f.call(str(shot["prepare"]))
	ctx.player.teleport(shot["pos"], float(shot["yaw"]), float(shot["pitch"]))
	_step(1.6)
	var pf := _flock(PG.PHOTO_KEY)
	var seen := 0
	var c := Vector3.ZERO
	if pf != null:
		for p: Vector3 in pf.crumb_spots:
			c += p / maxf(pf.crumb_spots.size(), 1)
		var eye := ctx.player.eye_position()
		for b: FLOCK.Bird in pf.birds:
			var ahead := (
				(b.pos - eye).normalized().dot(ctx.player.forward()) > cos(deg_to_rad(30.0))
			)
			if ahead and not b.air and _flat(b.pos, c) < 1.0 * WS.M:
				seen += 1
	var all := pf != null and seen == pf.birds.size() and not pf.crumb_spots.is_empty()
	K.check(fails, all, "photo: its birds feed round crumbs in front of the camera (%d)" % seen)
	f.call(str(shot["restore"]))
	ctx.sim.speed = 1
	K.check(fails, _flock(PG.PHOTO_KEY) == null, "photo: restore takes them away")


## A fresh city (no growth: only the founding roads and City Hall): by day pigeons still come out
## near the player at once (the hall's flock, the street flocks, or the ambient one), their birds on
## walkable ground; where no spot of any kind is near, the ambient flock (BASELINE_KEY) keeps to a
## sidewalk point by the player; by night nothing comes out, and at dawn (a new city's first
## hour) they are out again.
func _check_fresh_city() -> void:
	var fresh := FRESH.make(get_root())
	if not bool(fresh["ok"]):
		K.check(fails, false, "fresh: fixture: traffic and animals registered")
		return
	var fpg: PG = fresh["pigeons"]
	var ffl: FLOCK = fresh["flock"]
	var fctx: FpContext = fresh["ctx"]
	var ftr: FpFeature = fresh["traffic"]
	var ff: FpFeature = fresh["animals"]
	FRESH.step(ftr, ff, AF.SCAN_S + 0.1)
	var birds := 0
	var ground := true
	for fk: FLOCK.Flock in ffl.flocks:
		birds += fk.birds.size()
		for b: FLOCK.Bird in fk.birds:
			ground = ground and not is_nan(fctx.collision.walk_height(b.pos))
			ground = ground and fctx.collision.surface_at(b.pos) != "asphalt"
	K.check(
		fails,
		not ffl.flocks.is_empty() and birds >= PG.ROAD_N.x and ground,
		(
			"fresh: pigeons come out by the spawn at once (%d birds in %d flocks)"
			% [birds, ffl.flocks.size()]
		)
	)
	var quiet := _quiet_tile(fctx, fpg)
	K.check(fails, quiet >= 0, "fresh: fixture: a street with no flock spot near")
	if quiet < 0:
		return
	var at := Vector3(D.tx(quiet), 0.0, D.ty(quiet))
	var g := fctx.collision.walk_height(at)
	at.y = g if not is_nan(g) else 0.0
	fctx.player.teleport(at, 0.0)
	FRESH.step(ftr, ff, AF.SCAN_S + 0.1)
	var fk := _flock_of(ffl, PG.BASELINE_KEY)
	var near := fk != null and _flat(fk.home, fctx.player.position) <= PG.NEAR
	var on_ground := true
	if fk != null:
		for b: FLOCK.Bird in fk.birds:
			on_ground = on_ground and not is_nan(fctx.collision.walk_height(b.pos))
			on_ground = on_ground and fctx.collision.surface_at(b.pos) != "asphalt"
	var n := fk.birds.size() if fk != null else 0
	K.check(
		fails,
		near and n >= PG.ROAD_N.x and on_ground,
		"fresh: no spot near, the ambient flock keeps to a sidewalk by the player (%d)" % n
	)
	fctx.sky.night = 1.0
	fctx.player.teleport(at + Vector3(PG.FAR + 1.0, 0.0, 0.0), 0.0)
	FRESH.step(ftr, ff, AF.SCAN_S + 0.1)
	K.check(fails, ffl.flocks.is_empty(), "fresh: by night nothing comes out")
	# The sky's night at 6:15, the hour a new city starts (sky_director.gd _apply()); back on the
	# quiet street, the first light brings the ambient flock out again.
	var dawn := 1.0 - smoothstep(-0.12, 0.3, sin(PI * 0.25 / 12.0))
	fctx.sky.night = dawn
	fctx.player.teleport(at, 0.0)
	FRESH.step(ftr, ff, AF.SCAN_S + 0.1)
	K.check(
		fails,
		dawn > AF.NIGHT and not ffl.flocks.is_empty(),
		"fresh: at dawn (night %.2f) the pigeons are out already" % dawn
	)


## The flock of key in the flocks of the flock list fl (the shared helper for another context).
func _flock_of(fl: FLOCK, k: String) -> FLOCK.Flock:
	for fk: FLOCK.Flock in fl.flocks:
		if fk.key == k:
			return fk
	return null


## A straight road tile with no flock spot of any kind within FAR of it (so a scan there brings out
## nothing but the ambient flock), or -1 when the city has none.
func _quiet_tile(fctx: FpContext, fpg: PG) -> int:
	var r := ceili(PG.FAR)
	for i: int in fctx.sim.active:
		if fctx.sim.kind[i] != D.ROAD:
			continue
		var m := RoadTopology.mask(fctx.sim, D.tx(i), D.ty(i))
		if m != RoadTopology.NS and m != RoadTopology.EW:
			continue
		var clear := true
		for y in range(D.ty(i) - r, D.ty(i) + r + 1):
			for x in range(D.tx(i) - r, D.tx(i) + r + 1):
				if not D.in_bounds(x, y):
					continue
				if not (fpg.call("_spot_of", D.idx(x, y)) as Dictionary).is_empty():
					clear = false
					break
			if not clear:
				break
		if clear:
			return i
	return -1


func _check_teardown() -> void:
	var st := f.self_test()
	K.check(
		fails, bool(st["ok"]) and "pigeons in" in str(st["detail"]), "self_test: %s" % st["detail"]
	)
	f.teardown()
	K.check(
		fails,
		fl.flocks.is_empty() and pg.get_child_count() == 0,
		"teardown: no flocks or crumbs left"
	)
