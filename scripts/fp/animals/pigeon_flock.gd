extends RefCounted
## The pigeons' behaviour; the pigeons node (pigeons.gd) decides where flocks live and feeds in the
## world before every step(). A flock forages round its spot: each bird walks from place to place
## with the pigeon's head bob, pecks at the ground, stands about, and now and then a cock puffs up
## and turns round cooing. Birds walk out of the way of people and off from the hero walking at
## them; one too close, or about to be run over, flutters a few metres off. A sprint close by, a
## swing or a shout, a blow, a dog near or running, or a crowd of birds in a car's way sends the
## flock up together (scatter(); a bird the hero strikes is knocked up and away first, hit()): they
## burst off with a clatter of wings, climb away from the fright, wheel round over the street or the
## park and glide back down to land once it is calm. Crumbs (feed()) bring the flock in close, round
## the hero's feet, until they are eaten.
##
## A perched flock (add_perched()) sits its birds each on one fixed point, a lamp top or a roof
## edge: they sit, preen and turn there above the street, and nothing passing below reaches them;
## only a fright on the street itself sends them up, to wheel round and glide back onto their
## perches.

const WS := preload("res://scripts/fp/world_scale.gd")

## Walking (m/s) foraging and hurrying (off, or to crumbs); a step's length (m), which sets the
## head's bob and the stride; turning on the ground (rad/s); the room each bird keeps (m).
const WALK := 0.32 * WS.M
const HURRY := 0.85 * WS.M
const STEP_M := 0.075
const TURN := 7.0
const SPACE := 0.13 * WS.M
## A peck lasts PECK_S (s); a bout is PECKS of them.
const PECK_S := 0.34
const PECKS := Vector2i(2, 5)
## The hero on foot walking at a bird within WARY (m) faster than WARY_MPS sends it off on foot;
## within SHY it flutters off; a sprint (SPRINT_MPS) within FRIGHT of the flock sends it up. Crumbs
## on the ground cut WARY and SHY to FED_K of themselves.
const WARY := 2.6 * WS.M
const WARY_MPS := 0.3 * WS.M
const SHY := 1.0 * WS.M
const SPRINT_MPS := 2.8 * WS.M
const FRIGHT := 6.0 * WS.M
const FED_K := 0.3
## People going by: within MAKE_WAY (m) a bird walks out of their way, within TRAMPLE it flutters.
const MAKE_WAY := 1.3 * WS.M
const TRAMPLE := 0.45 * WS.M
## A dog within DOG_NEAR (m) of a bird, or running (DOG_RUN_MPS, faster than a walk at heel)
## within DOG_FAR, sends the flock up; a cat only within CAT_NEAR (one stalking low and slow gets
## that close) or running (a pounce). The flock lands again once they are twice their near off.
const DOG_NEAR := 3.0 * WS.M
const DOG_FAR := 6.0 * WS.M
const DOG_RUN_MPS := 2.5 * WS.M
const CAT_NEAR := 0.8 * WS.M
## A car within DODGE_S seconds of travel and DODGE_SIDE (m) of its path makes a bird flutter off;
## CROWD birds in its way at once send the flock up.
const DODGE_S := 1.0
const DODGE_SIDE := 1.0 * WS.M
const CROWD := 3
## A flutter: HOP_M (m) away over HOP_S (s), HOP_UP (m) high at the top.
const HOP_M := Vector2(1.5, 3.0)
const HOP_S := 0.75
const HOP_UP := 0.5
## Taking off: up (m/s) and away from the fright for UP_S (s), the nearest birds DELAY_S (s) ahead
## of the far ones; flying (m/s) and its acceleration (m/s²).
const LIFT := 3.2 * WS.M
const AWAY := 2.4 * WS.M
const UP_S := Vector2(0.9, 1.3)
const DELAY_S := 0.25
const CRUISE := 8.5 * WS.M
## Struck by the hero (hit): the bird is knocked up and away at KNOCK (m/s) plus KNOCK_K times the
## blow's strength.
const KNOCK := 2.5 * WS.M
const KNOCK_K := 4.0 * WS.M
const AIR_ACCEL := 9.0 * WS.M
## A fright keeps the flock up ALARM_S (s). It wheels at least WHEEL_S, then lands once nothing is
## within CALM (m) of its spot, and after WHEEL_MAX anyway (as far from the trouble as it can).
const ALARM_S := Vector2(6.0, 9.0)
const WHEEL_S := 6.0
const WHEEL_MAX := 25.0
const CALM := 3.5 * WS.M
## Gliding in: height lost per metre, speed (m/s) and where the flare starts (m from the spot).
const GLIDE := 0.55
const LAND_MPS := Vector2(1.2, 6.0)
const FLARE := 0.9 * WS.M
## Wingbeats (Hz) taking off, cruising and flaring; the wing's angle (rad) at the bottom and top of
## a beat and held in a glide.
const BEAT_HZ := Vector3(9.5, 6.5, 8.0)
const BEAT := Vector2(-0.75, 1.2)
const GLIDE_WING := 0.42
## The wheels tried, first that fits between the buildings: (along, across, up) m, along the
## street (centred over the road) for a sidewalk flock, round the spot for a park's; LAST_WHEEL
## above the roofs when none fits.
const STREET_WHEELS := [Vector3(16.0, 5.0, 7.0), Vector3(16.0, 5.0, 12.0), Vector3(10.0, 4.0, 9.0)]
const PARK_WHEELS := [Vector3(12.0, 12.0, 8.0), Vector3(12.0, 12.0, 14.0)]
const LAST_WHEEL := Vector3(14.0, 14.0, 24.0)
const WHEEL_POINTS := 12
## Crumbs: CRUMBS scattered within CRUMB_R (m); a peck within EAT (m) of one eats it at EAT_CHANCE.
const CRUMBS := 24
const CRUMB_R := 0.45 * WS.M
const EAT := 0.1 * WS.M
const EAT_CHANCE := 0.35
## A calm flock within COO_AT (m) of the hero coos every COO_S (s); a cock's display turns him
## round over DISPLAY_S.
const COO_AT := 15.0 * WS.M
const COO_S := Vector2(5.0, 12.0)
const DISPLAY_S := 2.6
## Morphs (linear tints of the blue bar) and their shares: blue bar, checker, dark, red, pale.
const MORPHS := [
	[Color(1.0, 1.0, 1.0), 0.42],
	[Color(0.62, 0.62, 0.66), 0.25],
	[Color(0.25, 0.25, 0.27), 0.13],
	[Color(1.2, 0.72, 0.55), 0.08],
	[Color(1.35, 1.35, 1.35), 0.12],
]
const NO_POINT := Vector3(NAN, NAN, NAN)


## One bird.
class Bird:
	extends RefCounted
	var pos := Vector3.ZERO
	## u/s: in the air its flight, on the ground unused.
	var vel := Vector3.ZERO
	var yaw: float = 0.0
	var pitch: float = 0.0
	var roll: float = 0.0
	var size: float = 1.0
	var tint := Color.WHITE
	var air: bool = false
	## On the ground "" (deciding), "walk", "peck", "stand" or "display"; in the air "up" (taking
	## off), "wheel", "down" (gliding in to goal) or "hop" (a flutter to goal).
	var act: String = ""
	var act_t: float = 0.0
	var goal := Vector3.ZERO
	var hurry: bool = false
	## Seconds until it takes off with its flock (0: not going).
	var delay: float = 0.0
	var land_in: float = 0.0
	## The step's phase (0..1) and count on the ground, the wingbeat's phase in the air.
	var phase: float = 0.0
	var steps: int = 0
	var pecks: int = 0
	## The pose the shader takes: the wing's angle in the air or the stride on the ground, how far
	## the wings are open, the peck (0..1) and the head's bob (-1..1).
	var wing: float = 0.0
	var open: float = 0.0
	var peck: float = 0.0
	var bob: float = 0.0
	var flap_t: float = 0.0
	var flare: bool = false
	## Its place round the wheel: the angle, and its offsets out and up (u).
	var theta: float = 0.0
	var lane := Vector2.ZERO
	var hop_from := Vector3.ZERO
	var hop_t: float = 0.0
	var hop_len: float = 1.0


## One flock and the spot it keeps to.
class Flock:
	extends RefCounted
	var key: String = ""
	var home := Vector3.ZERO
	var radius: float = 0.1
	## A sidewalk flock: along the street and toward the lot (units); ZERO for a park's.
	var run := Vector3.ZERO
	var across := Vector3.ZERO
	## A perched flock (add_perched()): its birds sit each on one fixed point (its b.goal) above
	## the street and land back on it.
	var perched: bool = false
	var birds: Array = []
	## Seconds it keeps off the ground after a fright, how long it has been up, and whether it is
	## coming down.
	var alarm: float = 0.0
	var aloft: float = 0.0
	var landing: bool = false
	var fear := Vector3.ZERO
	var wheel_fit: bool = false
	var wheel_c := Vector3.ZERO
	var wheel_a := Vector3.ZERO
	var wheel_b := Vector3.ZERO
	var wheel_r: float = 1.0
	var wheel_dir: float = 1.0
	var crumb_spots := PackedVector3Array()
	var crumbs_moved: bool = false
	var coo_t: float = 0.0
	## The pigeons node's MultiMeshInstance3D and crumbs.
	var node: Node3D = null
	var crumbs_node: Node3D = null


var flocks: Array = []
var col: CollisionWorld = null
## Called with (at, call) for a "coo", a lone bird's "flap" and a flock's "takeoff".
var on_call: Callable
## The world this step, set by the pigeons node: the hero's feet and velocity and whether they are
## on foot; dogs as [feet, velocity] (and cats as [feet, velocity, CAT_NEAR]); the feet of the
## people on foot around; moving cars as [pos, vel, half length, half width].
var hero := Vector3(INF, INF, INF)
var hero_vel := Vector3.ZERO
var hero_on_foot: bool = false
var dogs: Array = []
var passers: Array = []
var cars: Array = []
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.seed = 7411


## A flock of n foraging round home (on the ground) within radius (u): along run and across it
## (unit vectors, across toward the lot) on a sidewalk, round home in a park (run ZERO).
func add(key: String, home: Vector3, radius: float, run: Vector3, across: Vector3, n: int) -> Flock:
	var f := Flock.new()
	f.key = key
	f.home = home
	f.radius = radius
	f.run = run
	f.across = across
	f.wheel_dir = 1.0 if _rng.randf() < 0.5 else -1.0
	f.coo_t = _rng.randf_range(COO_S.x, COO_S.y)
	for _k in range(n):
		var b := Bird.new()
		var p := _spot(f, 6)
		b.pos = p if not is_nan(p.x) else home
		b.yaw = _rng.randf() * TAU
		b.size = _rng.randf_range(0.92, 1.08)
		b.tint = _morph()
		b.act_t = _rng.randf_range(0.0, 2.0)
		b.lane = Vector2(_rng.randf_range(-2.5, 2.5), _rng.randf_range(-1.5, 1.5)) * WS.M
		f.birds.append(b)
	flocks.append(f)
	return f


func remove(f: Flock) -> void:
	flocks.erase(f)


## A flock of birds perched on points, one each: they sit and preen there until a fright on the
## street sends them up, wheel round and glide back onto their own point.
func add_perched(key: String, points: PackedVector3Array) -> Flock:
	var f := Flock.new()
	f.key = key
	f.perched = true
	var mid := Vector3.ZERO
	for p: Vector3 in points:
		mid += p
	f.home = mid / maxf(points.size(), 1)
	var spread := 0.1
	for p: Vector3 in points:
		spread = maxf(spread, _flat(p, f.home))
	f.radius = spread
	f.wheel_dir = 1.0 if _rng.randf() < 0.5 else -1.0
	f.coo_t = _rng.randf_range(COO_S.x, COO_S.y)
	for k in range(points.size()):
		var b := Bird.new()
		b.pos = points[k]
		b.goal = points[k]
		b.yaw = _rng.randf() * TAU
		b.size = _rng.randf_range(0.92, 1.08)
		b.tint = _morph()
		b.act = "perch"
		b.act_t = _rng.randf_range(0.5, 2.5)
		f.birds.append(b)
	flocks.append(f)
	return f


## One step of dt game seconds for every flock.
func step(dt: float) -> void:
	if dt <= 0.0:
		return
	for f: Flock in flocks:
		_flock_rules(f, dt)
		for b: Bird in f.birds:
			if b.air:
				_fly(f, b, dt)
			else:
				_ground(f, b, dt)
		_space_out(f)


## A fright at src sends the whole flock up, the birds nearest it first, with one clatter of wings
## (a lone bird's flap); birds coming down climb again.
func scatter(f: Flock, src: Vector3) -> void:
	f.fear = src
	f.alarm = maxf(f.alarm, _rng.randf_range(ALARM_S.x, ALARM_S.y))
	f.landing = false
	if not f.wheel_fit:
		_fit_wheel(f)
	var going: Array = []
	for b: Bird in f.birds:
		if b.air:
			if b.act == "down" or b.act == "hop":
				_take_off(f, b)
			continue
		if b.delay <= 0.0:
			var near := clampf(_flat(b.pos, src) / (3.0 * WS.M), 0.0, 1.0)
			b.delay = 0.02 + DELAY_S * near + _rng.randf() * 0.1
			going.append(b)
	if going.size() >= CROWD:
		_call(_middle(going) + Vector3(0.0, 0.2 * WS.M, 0.0), "takeoff")
	elif not going.is_empty():
		_call((going[0] as Bird).pos + Vector3(0.0, 0.2 * WS.M, 0.0), "flap")


## A fright at src (a blow, a shout, a bark) sends up every flock with a bird on the ground within
## r (u) of it. Returns how many flocks went.
func startle(src: Vector3, r: float) -> int:
	var n := 0
	for f: Flock in flocks:
		for b: Bird in f.birds:
			if not b.air and _flat(b.pos, src) < r:
				scatter(f, src)
				n += 1
				break
	return n


## The hero struck bird b of flock f (a kick or a weapon) from src at strength 0..1: it is knocked
## up and away, and the whole flock goes up.
func hit(f: Flock, b: Bird, src: Vector3, strength: float) -> void:
	scatter(f, src)
	_take_off(f, b)
	b.vel = _away(b, src) * (KNOCK + KNOCK_K * strength) + Vector3.UP * LIFT


## Crumbs scattered at at (on the ground): the flock comes for them, walking or flying in, and
## pecks round them until they are eaten.
func feed(f: Flock, at: Vector3) -> void:
	f.crumb_spots.clear()
	for _k in range(CRUMBS):
		var a := _rng.randf() * TAU
		var p := at + Vector3(cos(a), 0.0, sin(a)) * CRUMB_R * sqrt(_rng.randf())
		var y := col.walk_height(p) if col != null else at.y
		p.y = y if not is_nan(y) else at.y
		f.crumb_spots.append(p)
	f.crumbs_moved = true
	f.alarm = 0.0
	for b: Bird in f.birds:
		if b.air:
			f.landing = true
			b.land_in = _rng.randf_range(0.0, 1.0)
		else:
			b.delay = 0.0
			b.act = ""
			_next(f, b)


## The pose the shader takes from INSTANCE_CUSTOM.
static func pose(b: Bird) -> Color:
	return Color(b.wing, b.open, b.peck, b.bob)


## The bird's transform, scale the units per metre of its mesh times its size.
static func xform(b: Bird) -> Transform3D:
	var basis := Basis(Vector3.UP, b.yaw) * Basis(Vector3.RIGHT, -b.pitch)
	basis = (basis * Basis(Vector3.BACK, b.roll)).scaled(Vector3.ONE * (WS.M * b.size))
	return Transform3D(basis, b.pos)


# ------------------------------------------------------------------ the flock


func _flock_rules(f: Flock, dt: float) -> void:
	f.alarm -= dt
	var up := 0
	for b: Bird in f.birds:
		if b.air:
			up += 1
	f.aloft = f.aloft + dt if up > 0 else 0.0
	if up < f.birds.size():
		var src := _threat(f)
		if not is_nan(src.x):
			scatter(f, src)
	if up > 0:
		_maybe_land(f)
	elif f.alarm <= 0.0:
		_coo(f, dt)


## Where a fright for the whole flock comes from: the hero sprinting close, a dog near or running,
## a crowd of birds in a car's way; NO_POINT when there is none. A perched flock looks down on the
## street: its distances are straight-line ones, and no car below can reach it.
func _threat(f: Flock) -> Vector3:
	var reach := f.radius + FRIGHT + 2.0 * WS.M
	var fast := Vector2(hero_vel.x, hero_vel.z).length() > SPRINT_MPS
	if hero_on_foot and fast and _apart(f, hero, f.home) < reach and _nearest(f, hero) < FRIGHT:
		return hero
	for dg: Array in dogs:
		var at: Vector3 = dg[0]
		if _apart(f, at, f.home) > reach:
			continue
		var d := _nearest(f, at)
		var running := Vector2((dg[1] as Vector3).x, (dg[1] as Vector3).z).length() > DOG_RUN_MPS
		if d < (float(dg[2]) if dg.size() > 2 else DOG_NEAR) or (running and d < DOG_FAR):
			return at
	if not f.perched:
		for c: Array in cars:
			var hits := 0
			for b: Bird in f.birds:
				if not b.air and _in_path(b, c):
					hits += 1
			if hits >= CROWD:
				return c[0]
	return NO_POINT


## A flock up long enough (or with crumbs waiting) lands once its spot is calm, or anyway after
## WHEEL_MAX: each wheeling bird peels off in turn.
func _maybe_land(f: Flock) -> void:
	if f.landing or f.alarm > 0.0:
		return
	if f.aloft < WHEEL_S and f.crumb_spots.is_empty():
		return
	if not _calm(f) and f.aloft < WHEEL_MAX:
		return
	f.landing = true
	for b: Bird in f.birds:
		b.land_in = _rng.randf_range(0.0, 1.8)


func _calm(f: Flock) -> bool:
	if hero_on_foot and _apart(f, hero, f.home) < CALM + f.radius:
		return false
	for dg: Array in dogs:
		var near := 2.0 * float(dg[2]) if dg.size() > 2 else DOG_FAR
		if _apart(f, dg[0], f.home) < near + f.radius:
			return false
	return true


## Now and then, with the hero about, a bird coos; a cock may puff up and turn round with it.
func _coo(f: Flock, dt: float) -> void:
	if not hero_on_foot or _flat(hero, f.home) > COO_AT:
		return
	f.coo_t -= dt
	if f.coo_t > 0.0:
		return
	f.coo_t = _rng.randf_range(COO_S.x, COO_S.y)
	var b: Bird = f.birds[_rng.randi() % f.birds.size()]
	if b.delay > 0.0:
		return
	if b.act != "peck" and _rng.randf() < 0.4:
		b.act = "display"
		b.act_t = DISPLAY_S
	_call(b.pos + Vector3(0.0, 0.18 * WS.M, 0.0), "coo")


## Ground birds keep SPACE apart; a perched flock sits on points already spaced.
func _space_out(f: Flock) -> void:
	if f.perched:
		return
	var n := f.birds.size()
	for i in range(n):
		var a: Bird = f.birds[i]
		if a.air:
			continue
		for j in range(i + 1, n):
			var b: Bird = f.birds[j]
			if b.air:
				continue
			var off := a.pos - b.pos
			off.y = 0.0
			var d := off.length()
			if d < SPACE and d > 1e-6:
				var push := off / d * (SPACE - d) * 0.5
				a.pos += push
				b.pos -= push


# ------------------------------------------------------------------ on the ground


func _ground(f: Flock, b: Bird, dt: float) -> void:
	b.open = move_toward(b.open, 0.0, dt * 3.0)
	if b.delay > 0.0:
		b.delay -= dt
		if b.delay <= 0.0:
			_take_off(f, b)
		return
	if f.perched:
		_perch(b, dt)
		return
	if _shy(f, b):
		return
	b.act_t -= dt
	if b.act != "walk":
		b.bob = move_toward(b.bob, 0.0, dt * 4.0)
		b.wing = move_toward(b.wing, 0.0, dt * 3.0)
	if b.act != "peck" and b.act != "display":
		b.peck = move_toward(b.peck, 0.0, dt * 4.0)
	match b.act:
		"walk":
			_walk(f, b, dt)
		"peck":
			_peck(f, b)
		"display":
			b.yaw += 2.4 * dt
			b.peck = 0.18 * (0.5 - 0.5 * cos(TAU * 1.5 * b.act_t))
			if b.act_t <= 0.0:
				_next(f, b)
		_:
			if b.act_t <= 0.0:
				_next(f, b)


## A perched bird: sits still on its point, now and then turning round on it or dipping into a
## preen. The street below never reaches it; only the flock's frights (scatter) send it up.
func _perch(b: Bird, dt: float) -> void:
	b.act_t -= dt
	match b.act:
		"turn":
			b.yaw += 1.4 * dt
			if b.act_t <= 0.0:
				b.act = "perch"
				b.act_t = _rng.randf_range(1.5, 4.0)
		"preen":
			b.peck = 0.35 * (0.5 - 0.5 * cos(TAU * 1.1 * b.act_t))
			if b.act_t <= 0.0:
				b.peck = 0.0
				b.act = "perch"
				b.act_t = _rng.randf_range(1.5, 4.0)
		_:
			if b.act_t <= 0.0:
				b.act = "preen" if _rng.randf() < 0.3 else "turn"
				b.act_t = _rng.randf_range(1.2, 3.0)
				b.yaw = fposmod(b.yaw + PI * 0.25 * _rng.randf_range(-1.0, 1.0), TAU)


## The hero or someone walking at the bird, or a car about to hit it: it walks out of the way or
## flutters off. True when it took off.
func _shy(f: Flock, b: Bird) -> bool:
	var k := FED_K if not f.crumb_spots.is_empty() else 1.0
	if hero_on_foot:
		var to := b.pos - hero
		to.y = 0.0
		var d := to.length()
		if d < SHY * k:
			_hop(f, b, hero)
			return true
		if d < WARY * k and not b.hurry and hero_vel.dot(to / maxf(d, 1e-6)) > WARY_MPS:
			_walk_off(f, b, hero)
	for p: Vector3 in passers:
		var d := _flat(p, b.pos)
		if d < TRAMPLE:
			_hop(f, b, p)
			return true
		if d < MAKE_WAY and not b.hurry:
			_walk_off(f, b, p)
	for c: Array in cars:
		if _in_path(b, c):
			_hop(f, b, c[0])
			return true
	return false


## What the bird does next: pecks at crumbs, else pecks, stands about or walks somewhere.
func _next(f: Flock, b: Bird) -> void:
	b.hurry = false
	if not f.crumb_spots.is_empty():
		var c := _crumb(f, b)
		if _flat(c, b.pos) < EAT:
			_start_pecks(b)
		else:
			_go(b, c + Vector3(_rng.randf() - 0.5, 0.0, _rng.randf() - 0.5) * EAT, true)
		return
	var r := _rng.randf()
	if r < 0.5:
		_start_pecks(b)
		return
	var p := _spot(f, 3) if r > 0.75 else NO_POINT
	if is_nan(p.x):
		b.act = "stand"
		b.act_t = _rng.randf_range(0.6, 2.5)
		b.yaw += _rng.randf_range(-0.8, 0.8)
	else:
		_go(b, p, false)


func _go(b: Bird, p: Vector3, hurry: bool) -> void:
	b.act = "walk"
	b.goal = p
	b.hurry = hurry
	b.act_t = 8.0


func _start_pecks(b: Bird) -> void:
	b.act = "peck"
	b.pecks = _rng.randi_range(PECKS.x, PECKS.y)
	b.act_t = PECK_S


## Off from src: a couple of metres, briskly.
func _walk_off(f: Flock, b: Bird, src: Vector3) -> void:
	var away := b.pos - src
	away.y = 0.0
	if away.length_squared() < 1e-12:
		away = Vector3(sin(b.yaw), 0.0, cos(b.yaw))
	var side := Vector3(-away.z, 0.0, away.x).normalized() * _rng.randf_range(-0.6, 0.6)
	var p := b.pos + (away.normalized() + side) * 1.4 * WS.M
	if _ground_ok(p):
		p.y = col.walk_height(p) if col != null else b.pos.y
		_go(b, p, true)
	else:
		var q := _spot(f, 3)
		if not is_nan(q.x):
			_go(b, q, true)


func _walk(f: Flock, b: Bird, dt: float) -> void:
	var to := b.goal - b.pos
	to.y = 0.0
	var d := to.length()
	if d < 0.03 * WS.M or b.act_t <= 0.0:
		_next(f, b)
		return
	b.yaw = rotate_toward(b.yaw, atan2(to.x, to.z), TURN * dt)
	var fwd := Vector3(sin(b.yaw), 0.0, cos(b.yaw))
	var dist := minf((HURRY if b.hurry else WALK) * maxf(0.0, fwd.dot(to / d)) * dt, d)
	if dist <= 0.0:
		return
	_stride(b, dist)
	var np := b.pos + fwd * dist
	var y := col.walk_height(np) if col != null else b.pos.y
	if is_nan(y) or absf(y - b.pos.y) > 0.2 * WS.M:
		_next(f, b)
		return
	b.pos = Vector3(np.x, y, np.z)


## The feet carried the bird dist (u): the stride and the head's bob follow the step (the head
## thrust forward, then held still while the body catches up).
func _stride(b: Bird, dist: float) -> void:
	b.phase += dist / (STEP_M * WS.M)
	while b.phase >= 1.0:
		b.phase -= 1.0
		b.steps += 1
	var ph := b.phase
	b.bob = -1.0 + 2.0 * smoothstep(0.0, 0.3, ph) if ph < 0.3 else 1.0 - 2.0 * (ph - 0.3) / 0.7
	b.wing = 0.4 * cos(PI * ph) * (1.0 if b.steps % 2 == 0 else -1.0)


func _peck(f: Flock, b: Bird) -> void:
	var t := 1.0 - b.act_t / PECK_S
	b.peck = smoothstep(0.0, 0.35, t) * (1.0 - smoothstep(0.5, 1.0, t))
	if b.act_t > 0.0:
		return
	_eat(f, b)
	b.pecks -= 1
	if b.pecks <= 0:
		_next(f, b)
	else:
		b.act_t = PECK_S * _rng.randf_range(0.85, 1.15)


func _eat(f: Flock, b: Bird) -> void:
	if f.crumb_spots.is_empty() or _rng.randf() > EAT_CHANCE:
		return
	for k in range(f.crumb_spots.size()):
		if _flat(f.crumb_spots[k], b.pos) < EAT:
			f.crumb_spots.remove_at(k)
			f.crumbs_moved = true
			return


## The crumb nearest the bird.
func _crumb(f: Flock, b: Bird) -> Vector3:
	var best := f.crumb_spots[0]
	for c: Vector3 in f.crumb_spots:
		if _flat(c, b.pos) < _flat(best, b.pos):
			best = c
	return best


# ------------------------------------------------------------------ in the air


func _take_off(f: Flock, b: Bird) -> void:
	b.air = true
	b.act = "up"
	b.act_t = _rng.randf_range(UP_S.x, UP_S.y)
	b.delay = 0.0
	b.hurry = false
	b.wing = 0.0
	b.phase = 0.0
	if not f.wheel_fit:
		_fit_wheel(f)
	b.vel = _away(b, f.fear) * AWAY + Vector3.UP * LIFT


## A flutter off from src to the ground a couple of metres away (or up with the flock when there
## is nowhere to land).
func _hop(f: Flock, b: Bird, src: Vector3) -> void:
	var away := _away(b, src)
	var side := Vector3(-away.z, 0.0, away.x) * _rng.randf_range(-0.5, 0.5)
	var to := b.pos + (away + side).normalized() * _rng.randf_range(HOP_M.x, HOP_M.y) * WS.M
	_call(b.pos + Vector3(0.0, 0.15 * WS.M, 0.0), "flap")
	if not _ground_ok(to):
		f.fear = src
		f.alarm = maxf(f.alarm, 2.0)
		_take_off(f, b)
		return
	to.y = col.walk_height(to) if col != null else b.pos.y
	b.air = true
	b.act = "hop"
	b.hop_from = b.pos
	b.goal = to
	b.hop_t = 0.0
	b.hop_len = HOP_S * _rng.randf_range(0.85, 1.2)
	b.delay = 0.0


func _fly(f: Flock, b: Bird, dt: float) -> void:
	b.open = move_toward(b.open, 1.0, dt * 5.0)
	b.peck = 0.0
	b.bob = 0.0
	b.act_t -= dt
	b.flare = false
	if b.act == "hop":
		_hop_step(f, b, dt)
		return
	match b.act:
		"up":
			b.vel = b.vel.move_toward(_away(b, f.fear) * AWAY + Vector3.UP * LIFT, AIR_ACCEL * dt)
			_beat(b, BEAT_HZ.x, dt)
			if b.act_t <= 0.0:
				b.act = "wheel"
				b.theta = _theta_of(f, b.pos)
		"wheel":
			_wheel(f, b, dt)
		_:
			_glide(f, b, dt)
	var was := b.yaw
	b.pos += b.vel * dt
	_attitude(b, was, dt)


func _wheel(f: Flock, b: Bird, dt: float) -> void:
	b.theta += f.wheel_dir * CRUISE / f.wheel_r * dt
	var to := _wheel_point(f, b, b.theta + f.wheel_dir * 0.6) - b.pos
	b.vel = b.vel.move_toward(to.normalized() * CRUISE, AIR_ACCEL * dt)
	b.flap_t = fposmod(b.flap_t + dt, 1.7)
	if b.flap_t < 1.2:
		_beat(b, BEAT_HZ.y, dt)
	else:
		b.wing = move_toward(b.wing, 0.12, dt * 4.0)
	if f.landing:
		b.land_in -= dt
		if b.land_in <= 0.0:
			b.act = "down"
			b.goal = _land_goal(f, b)


## Gliding in to goal on a slope, wings held up, slowing and flaring over the last metre.
func _glide(f: Flock, b: Bird, dt: float) -> void:
	var to := b.goal - b.pos
	var flat := Vector2(to.x, to.z).length()
	var dir := Vector3(to.x, 0.0, to.z) / maxf(flat, 1e-6)
	var h := b.pos.y - b.goal.y
	var speed := clampf(flat * 1.5, LAND_MPS.x * WS.M, LAND_MPS.y * WS.M)
	var vy := clampf((minf(flat * GLIDE, maxf(h, 0.0)) - h) * 2.5, -3.0 * WS.M, 1.5 * WS.M)
	b.flare = flat < FLARE
	if b.flare:
		speed = flat * 2.0
		vy = clampf(-h * 4.0, -1.5 * WS.M, 0.0)
	b.vel = b.vel.move_toward(dir * speed + Vector3.UP * vy, AIR_ACCEL * dt)
	if b.flare:
		_beat(b, BEAT_HZ.z, dt)
	else:
		b.wing = move_toward(b.wing, GLIDE_WING, dt * 3.0)
	if h < 0.04 * WS.M and flat < 0.25 * WS.M:
		_land(f, b)


func _hop_step(f: Flock, b: Bird, dt: float) -> void:
	b.hop_t += dt
	var s := clampf(b.hop_t / b.hop_len, 0.0, 1.0)
	var p := b.hop_from.lerp(b.goal, smoothstep(0.0, 1.0, s))
	p.y += HOP_UP * WS.M * 4.0 * s * (1.0 - s)
	var d := p - b.pos
	if Vector2(d.x, d.z).length_squared() > 1e-12:
		b.yaw = rotate_toward(b.yaw, atan2(d.x, d.z), 10.0 * dt)
	b.pos = p
	b.pitch = lerpf(0.5, 0.0, s)
	_beat(b, BEAT_HZ.x, dt)
	if s >= 1.0:
		_land(f, b)


func _land(f: Flock, b: Bird) -> void:
	b.air = false
	b.act = "perch" if f.perched else "stand"
	b.act_t = _rng.randf_range(0.4, 1.4)
	b.vel = Vector3.ZERO
	b.pitch = 0.0
	b.roll = 0.0
	b.wing = 0.0
	b.flare = false
	if f.perched:
		b.pos = b.goal
		return
	var y := col.walk_height(b.pos) if col != null else b.goal.y
	b.pos.y = y if not is_nan(y) else b.goal.y


## Faces where it flies, banks into turns and pitches with the climb (up, flaring).
func _attitude(b: Bird, was: float, dt: float) -> void:
	var hv := Vector2(b.vel.x, b.vel.z).length()
	if hv > 0.3 * WS.M:
		b.yaw = rotate_toward(b.yaw, atan2(b.vel.x, b.vel.z), 6.0 * dt)
	var rate := angle_difference(was, b.yaw) / maxf(dt, 1e-4)
	b.roll = lerpf(b.roll, clampf(-rate * 0.35, -0.9, 0.9), 1.0 - exp(-6.0 * dt))
	var climb := atan2(b.vel.y, maxf(hv, 0.01 * WS.M)) * 0.7 + (0.7 if b.flare else 0.0)
	b.pitch = lerpf(b.pitch, climb, 1.0 - exp(-5.0 * dt))


func _beat(b: Bird, hz: float, dt: float) -> void:
	b.phase = fposmod(b.phase + hz * dt, 1.0)
	b.wing = lerpf(BEAT.x, BEAT.y, 0.5 + 0.5 * cos(TAU * b.phase))


## Where a bird lands: its own perch for a perched one, by the crumbs, else a spot of the flock's
## (the furthest of a few from the hero when they are about).
func _land_goal(f: Flock, b: Bird) -> Vector3:
	if f.perched:
		return b.goal
	if not f.crumb_spots.is_empty():
		var c: Vector3 = f.crumb_spots[_rng.randi() % f.crumb_spots.size()]
		return c + Vector3(_rng.randf() - 0.5, 0.0, _rng.randf() - 0.5) * 2.0 * CRUMB_R
	var best := NO_POINT
	var far := -1.0
	for _k in range(5):
		var p := _spot(f, 2)
		if is_nan(p.x):
			continue
		var d := _flat(p, hero) if hero_on_foot else _rng.randf()
		if d > far:
			far = d
			best = p
	return best if not is_nan(best.x) else f.home


# ------------------------------------------------------------------ the wheel


## The flock's wheel: the first of its candidates whose ring clears the buildings.
func _fit_wheel(f: Flock) -> void:
	f.wheel_fit = true
	var street := f.run != Vector3.ZERO
	var a_dir := f.run if street else Vector3.RIGHT
	var b_dir := f.across if street else Vector3.BACK
	f.wheel_c = f.home - f.across * WS.SIDEWALK_CENTER if street else f.home
	var tries: Array = (STREET_WHEELS if street else PARK_WHEELS).duplicate()
	tries.append(LAST_WHEEL)
	for w: Vector3 in tries:
		f.wheel_a = a_dir * w.x * WS.M
		f.wheel_b = b_dir * w.y * WS.M
		f.wheel_c.y = f.home.y + w.z * WS.M
		f.wheel_r = (w.x + w.y) * 0.5 * WS.M
		if _ring_clear(f):
			return


func _ring_clear(f: Flock) -> bool:
	if col == null:
		return true
	var last := f.wheel_c + f.wheel_a
	for k in range(1, WHEEL_POINTS + 1):
		var t := TAU * k / WHEEL_POINTS
		var p := f.wheel_c + f.wheel_a * cos(t) + f.wheel_b * sin(t)
		if not col.line_of_sight(last, p):
			return false
		last = p
	return true


## A point of the bird's lane round the wheel at angle t.
func _wheel_point(f: Flock, b: Bird, t: float) -> Vector3:
	var la := 1.0 + b.lane.x / maxf(f.wheel_a.length(), 1e-4)
	var lb := 1.0 + b.lane.x / maxf(f.wheel_b.length(), 1e-4)
	var p := f.wheel_c + f.wheel_a * (cos(t) * la) + f.wheel_b * (sin(t) * lb)
	return p + Vector3(0.0, b.lane.y, 0.0)


func _theta_of(f: Flock, p: Vector3) -> float:
	var off := p - f.wheel_c
	var a2 := maxf(f.wheel_a.length_squared(), 1e-8)
	var b2 := maxf(f.wheel_b.length_squared(), 1e-8)
	return atan2(off.dot(f.wheel_b) / b2, off.dot(f.wheel_a) / a2)


# ------------------------------------------------------------------ helpers


## A free place in the flock's area on walkable ground (not the road, not water, not under a
## prop, not at the hero's feet), else NO_POINT.
func _spot(f: Flock, tries: int) -> Vector3:
	for _k in range(tries):
		var p := f.home
		if f.run != Vector3.ZERO:
			p += f.run * f.radius * _rng.randf_range(-1.0, 1.0)
			p += f.across * 1.4 * WS.M * _rng.randf_range(-1.0, 1.0)
		else:
			var a := _rng.randf() * TAU
			p += Vector3(cos(a), 0.0, sin(a)) * f.radius * sqrt(_rng.randf())
		if hero_on_foot and _flat(p, hero) < SHY * 1.4:
			continue
		if _ground_ok(p):
			var y := col.walk_height(p) if col != null else f.home.y
			return Vector3(p.x, y, p.z)
	return NO_POINT


func _ground_ok(p: Vector3) -> bool:
	if col == null:
		return true
	var y := col.walk_height(p)
	if is_nan(y) or col.surface_at(p) in ["asphalt", "water"]:
		return false
	return not col.is_blocked(Vector3(p.x, y, p.z), 0.08 * WS.M)


## True when car c ([pos, vel, half length, half width]) is about to run over the bird.
func _in_path(b: Bird, c: Array) -> bool:
	var v: Vector3 = c[1]
	var flat_v := Vector2(v.x, v.z)
	var sp := flat_v.length()
	var off := Vector2(b.pos.x - (c[0] as Vector3).x, b.pos.z - (c[0] as Vector3).z)
	if sp < 1.0 * WS.M or off.length() > 1.0:
		return false
	var ahead := off.dot(flat_v / sp)
	var aside := absf(off.cross(flat_v / sp))
	var reach := float(c[2]) + sp * DODGE_S
	return ahead > -float(c[2]) and ahead < reach and aside < float(c[3]) + DODGE_SIDE


## The way from src to the bird (flat, unit), or its facing when they coincide.
func _away(b: Bird, src: Vector3) -> Vector3:
	var a := b.pos - src
	a.y = 0.0
	if a.length_squared() < 1e-12 or not a.is_finite():
		return Vector3(sin(b.yaw), 0.0, cos(b.yaw))
	return a.normalized()


func _nearest(f: Flock, p: Vector3) -> float:
	var best := INF
	for b: Bird in f.birds:
		if not b.air:
			best = minf(best, _apart(f, b.pos, p))
	return best


## How far apart two places are for the flock: flat for a ground flock, whose birds share the
## street, straight-line for a perched one, which looks down on it.
func _apart(f: Flock, a: Vector3, b: Vector3) -> float:
	return a.distance_to(b) if f.perched else _flat(a, b)


func _middle(birds: Array) -> Vector3:
	var s := Vector3.ZERO
	for b: Bird in birds:
		s += b.pos
	return s / maxf(birds.size(), 1)


func _morph() -> Color:
	var r := _rng.randf()
	var tint := Color.WHITE
	for m: Array in MORPHS:
		tint = m[0]
		r -= float(m[1])
		if r <= 0.0:
			break
	var j := _rng.randf_range(0.95, 1.05)
	return Color(tint.r * j, tint.g * j, tint.b * j)


func _call(at: Vector3, sound: String) -> void:
	if on_call.is_valid():
		on_call.call(at, sound)


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
