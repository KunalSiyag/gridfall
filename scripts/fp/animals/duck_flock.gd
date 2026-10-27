extends "res://scripts/fp/animals/pigeon_flock.gd"
## The waterfowl's behaviour; the waterfowl node (waterfowl.gd) decides where flocks live (a spot
## on the water) and feeds in the world before every step(). A flock of mallards sits on the
## water: each duck paddles from place to place round its spot, now and then tips tail-up to feed
## under the surface or preens its feathers with a little shake of its wings, a drake among the
## hens. A fright — the hero wading in or walking down to the bank close by, a shout, a crash, a
## dog coming at the water — and the flock bursts off with a clatter of wings: they run along the
## surface beating hard, climb away, wheel round over the water and glide back down to land once
## it is calm.
## The birds are the pigeons' (pigeon_flock.gd's Bird) with the shader's channels read the duck's
## way: its "wing" the wingbeat's angle, "open" how far the wings are spread, "peck" the dabble
## share (the neck and head pitched down, the body tipped with it) and "bob" the drake share
## (pose()'s fourth channel); the poses the statics inherited from pigeon_flock.gd produce are
## just so.

## Paddling about (m/s), turning (rad/s) and the room each duck keeps on the water (m).
const PADDLE := 0.3 * WS.M
const PADDLE_TURN := 2.5
const DUCK_SPACE := 0.3 * WS.M
## How long a dabble (its neck under), an up-end (tipped tail-up) and a preen last (s), and the
## odds of each when a duck decides what to do next.
const DABBLE_S := Vector2(1.5, 3.5)
const UP_END_S := Vector2(1.0, 2.2)
const PREEN_S := Vector2(3.0, 7.0)
const ODDS := Vector3(0.55, 0.2, 0.15)
## The hero on foot within DUCK_WARY (m) of a duck, or sprinting within DUCK_SPRINT, a dog within
## DUCK_DOG_NEAR or running within DUCK_DOG_FAR, and anyone wading within TRAMPLE_M send the
## flock up. Nothing on the water can be run down: cars keep to the road.
const DUCK_WARY := 6.0 * WS.M
const DUCK_SPRINT := 12.0 * WS.M
const DUCK_SPRINT_MPS := 2.8 * WS.M
const DUCK_DOG_NEAR := 4.0 * WS.M
const DUCK_DOG_FAR := 8.0 * WS.M
const TRAMPLE_M := 2.0 * WS.M
## Taking off: a run of RUN_M (m) along the water beating hard, then climbing at DUCK_LIFT (m/s)
## away from the fright for DUCK_UP_S (s); flying (m/s) and its acceleration.
const RUN_M := 2.0 * WS.M
const DUCK_LIFT := 3.0 * WS.M
const DUCK_UP_S := Vector2(0.8, 1.2)
const DUCK_CRUISE := 7.5 * WS.M
const DUCK_AIR_ACCEL := 8.0 * WS.M
## The flush keeps the flock up DUCK_ALARM_S (s); it wheels at least DUCK_WHEEL_S and lands once
## nothing is within DUCK_CALM (m) of its spot, and after DUCK_WHEEL_MAX anyway.
const DUCK_ALARM_S := Vector2(8.0, 14.0)
const DUCK_WHEEL_S := 8.0
const DUCK_WHEEL_MAX := 30.0
const DUCK_CALM := 5.0 * WS.M
## The wheel, over the water round the home: its radius and height (m), a duck a lane out and up
## of it.
const DUCK_WHEEL_R := 14.0 * WS.M
const DUCK_WHEEL_UP := 10.0 * WS.M
## Gliding in: height lost per metre, the speeds (m/s) and where the flare starts (m from the
## landing point).
const DUCK_GLIDE := 0.5
const DUCK_LAND_MPS := Vector2(1.2, 5.0)
const DUCK_FLARE := 1.2 * WS.M
## Wingbeats (Hz) on the run, cruising and flaring; the wing's angle (rad) at the bottom and top
## of a beat and held in a glide.
const DUCK_BEAT_HZ := Vector3(8.0, 5.0, 7.0)
const DUCK_BEAT := Vector2(-0.7, 1.1)
const DUCK_GLIDE_WING := 0.38
## Drakes among a flock.
const DRAKE_K := 0.4
## The bob of the water under a paddling duck (m) and how deep its up-end's tail rides.
const WATER_BOB := 0.004 * WS.M


func _init() -> void:
	_rng.seed = 5233


## A flock of n mallards on the water round home (at the water's surface) within radius (u), a
## drake or two among the hens.
func add_waterfowl(key: String, home: Vector3, radius: float, n: int) -> Flock:
	var f := Flock.new()
	f.key = key
	f.home = home
	f.radius = radius
	f.wheel_dir = 1.0 if _rng.randf() < 0.5 else -1.0
	for _k in range(n):
		var b := Bird.new()
		b.pos = _water_point(home, radius)
		b.pos.y = WS.WATER_Y
		b.yaw = _rng.randf() * TAU
		b.size = _rng.randf_range(0.92, 1.08)
		b.bob = 1.0 if _rng.randf() < DRAKE_K else 0.0
		b.tint = Color.WHITE * _rng.randf_range(0.94, 1.05)
		b.act_t = _rng.randf_range(0.0, 2.0)
		b.lane = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.5, 1.5)) * WS.M
		f.birds.append(b)
	flocks.append(f)
	return f


## One step of dt game seconds for every flock: its rules, then each duck on the water or in the
## air, then their room on the water kept.
func step(dt: float) -> void:
	if dt <= 0.0:
		return
	for f: Flock in flocks:
		_rules(f, dt)
		for b: Bird in f.birds:
			if b.air:
				_fly(f, b, dt)
			else:
				_float(f, b, dt)
		_space_out(f)
		for b: Bird in f.birds:
			if not b.air:
				_hold_water(f, b)


## A fright at src sends the whole flock off the water, the ducks nearest it first off the water
## with one clatter of wings; those coming down climb again.
func scatter(f: Flock, src: Vector3) -> void:
	f.fear = src
	f.alarm = maxf(f.alarm, _rng.randf_range(DUCK_ALARM_S.x, DUCK_ALARM_S.y))
	f.landing = false
	var going: Array = []
	for b: Bird in f.birds:
		if b.air:
			if b.act == "down":
				_take_off(f, b)
			continue
		if b.delay <= 0.0:
			var near := clampf(_flat(b.pos, src) / (4.0 * WS.M), 0.0, 1.0)
			b.delay = 0.02 + DELAY_S * near + _rng.randf() * 0.1
			going.append(b)
	if going.size() >= CROWD:
		_call(_middle(going) + Vector3(0.0, 0.2 * WS.M, 0.0), "takeoff")
	elif not going.is_empty():
		_call((going[0] as Bird).pos + Vector3(0.0, 0.2 * WS.M, 0.0), "flap")


# ------------------------------------------------------------------ the flock


## The alarm clock, the frights that flush it and the landing once it is calm.
func _rules(f: Flock, dt: float) -> void:
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


## Where a fright for the whole flock comes from: the hero near the water or sprinting past, a
## dog at it or running near, someone wading among the ducks; NO_POINT when there is none.
func _threat(f: Flock) -> Vector3:
	var fast := Vector2(hero_vel.x, hero_vel.z).length() > DUCK_SPRINT_MPS
	if hero_on_foot and _nearest(f, hero) < (DUCK_SPRINT if fast else DUCK_WARY):
		return hero
	for dg: Array in dogs:
		var at: Vector3 = dg[0]
		var running := Vector2((dg[1] as Vector3).x, (dg[1] as Vector3).z).length() > DOG_RUN_MPS
		if _nearest(f, at) < DUCK_DOG_NEAR or (running and _nearest(f, at) < DUCK_DOG_FAR):
			return at
	for p: Vector3 in passers:
		if _nearest(f, p) < TRAMPLE_M:
			return p
	return NO_POINT


## Calm again, and it has been up a while: every duck still flying is given a landing point on
## the water near the home, the first of them in a moment.
func _maybe_land(f: Flock) -> void:
	if f.landing or f.alarm > 0.0 or f.aloft < DUCK_WHEEL_S:
		return
	if f.aloft < DUCK_WHEEL_MAX and not _clear_of_trouble(f):
		return
	f.landing = true
	for b: Bird in f.birds:
		if b.air:
			b.act = "down"
			b.land_in = _rng.randf_range(0.0, 1.2)
			b.goal = _water_goal(f, b)


## Nothing the flock fled from within DUCK_CALM of its spot (a passer, a dog, the hero).
func _clear_of_trouble(f: Flock) -> bool:
	if hero_on_foot and _flat(f.home, hero) < DUCK_CALM:
		return false
	for dg: Array in dogs:
		if _flat(f.home, dg[0] as Vector3) < DUCK_CALM:
			return false
	for p: Vector3 in passers:
		if _flat(f.home, p) < DUCK_CALM:
			return false
	return true


## The room on the water: ducks on the water sit no closer than DUCK_SPACE; those in the air
## cross over one another.
func _space_out(f: Flock) -> void:
	for k in range(f.birds.size()):
		var a: Bird = f.birds[k]
		if a.air:
			continue
		for j in range(k + 1, f.birds.size()):
			var b: Bird = f.birds[j]
			if b.air:
				continue
			var off := a.pos - b.pos
			off.y = 0.0
			var apart := off.length()
			if apart >= DUCK_SPACE or apart < 1e-6:
				continue
			var push := off * ((DUCK_SPACE - apart) / apart * 0.5)
			a.pos += push
			b.pos -= push


# ------------------------------------------------------------------ on the water


## What a duck on the water does this step.
func _float(f: Flock, b: Bird, dt: float) -> void:
	if b.delay > 0.0:
		b.delay -= dt
		if b.delay <= 0.0:
			_take_off(f, b)
		return
	b.phase += dt * (0.6 if b.act == "paddle" else 0.3)
	match b.act:
		"paddle":
			_paddle(f, b, dt)
		"dabble", "up_end":
			_dabble(f, b, dt)
		"preen":
			_preen(f, b, dt)
		_:
			_next(f, b)
	b.pos.y = WS.WATER_Y + WATER_BOB * sin(TAU * b.phase)
	b.pos.y = maxf(b.pos.y, WS.WATER_Y)


## Paddles to its goal, wings folded, leaving a duck's little wake of bobs.
func _paddle(f: Flock, b: Bird, dt: float) -> void:
	b.wing = move_toward(b.wing, 0.0, dt * 4.0)
	b.open = move_toward(b.open, 0.0, dt * 4.0)
	b.peck = move_toward(b.peck, 0.0, dt * 2.0)
	var to := b.goal - b.pos
	to.y = 0.0
	if to.length() < 0.08 * WS.M:
		_next(f, b)
		return
	b.yaw = rotate_toward(b.yaw, atan2(to.x, to.z), PADDLE_TURN * dt)
	b.pos += Vector3(sin(b.yaw), 0.0, cos(b.yaw)) * PADDLE * dt


## Tips tail-up, its neck under the surface, held through the bout.
func _dabble(f: Flock, b: Bird, dt: float) -> void:
	var full := 1.0 if b.act == "up_end" else 0.7
	b.peck = move_toward(b.peck, full, dt * 2.5)
	b.wing = move_toward(b.wing, 0.0, dt * 4.0)
	b.open = move_toward(b.open, 0.0, dt * 4.0)
	if b.act == "up_end":
		b.roll = lerpf(b.roll, 0.12 * sin(TAU * b.phase), 1.0 - exp(-4.0 * dt))
	b.act_t -= dt
	if b.act_t <= 0.0:
		b.roll = 0.0
		_next(f, b)


## Sits and preens, now and then shaking its wings out.
func _preen(f: Flock, b: Bird, dt: float) -> void:
	b.open = move_toward(b.open, 0.35 + 0.25 * sin(TAU * b.phase), dt * 3.0)
	b.wing = move_toward(b.wing, 0.1 * maxf(sin(TAU * b.phase), 0.0), dt * 3.0)
	b.peck = move_toward(b.peck, 0.2, dt * 2.0)
	b.act_t -= dt
	if b.act_t <= 0.0:
		_next(f, b)


## What it does next: mostly paddling to a new place, now and then a dabble, an up-end or a
## preen.
func _next(f: Flock, b: Bird) -> void:
	var roll := _rng.randf()
	b.goal = _water_goal(f, b)
	if roll < ODDS.x:
		b.act = "paddle"
		b.act_t = 1e9
	elif roll < ODDS.x + ODDS.y:
		b.act = "dabble"
		b.act_t = _rng.randf_range(DABBLE_S.x, DABBLE_S.y)
	elif roll < ODDS.x + ODDS.y + ODDS.z:
		b.act = "up_end"
		b.act_t = _rng.randf_range(UP_END_S.x, UP_END_S.y)
	else:
		b.act = "preen"
		b.act_t = _rng.randf_range(PREEN_S.x, PREEN_S.y)


## A point on the water within radius (u) of home, or home when none is found: a duck never sits
## on the bank.
func _water_point(home: Vector3, radius: float) -> Vector3:
	for _k in range(8):
		var a := _rng.randf() * TAU
		var p := home + Vector3(cos(a), 0.0, sin(a)) * radius * sqrt(_rng.randf())
		if col == null or col.surface_at(p) == "water":
			return p
	return home


## Keeps a duck on the water: one pushed up the bank is drawn back to the nearest water toward the
## flock's home.
func _hold_water(f: Flock, b: Bird) -> void:
	if col == null or col.surface_at(b.pos) == "water":
		return
	for k in range(6):
		var p := b.pos.lerp(f.home, float(k + 1) / 6.0)
		if col.surface_at(p) == "water":
			b.pos = p
			return
	b.pos = f.home


## A point on the water within the flock's radius of its home.
func _water_goal(f: Flock, _b: Bird) -> Vector3:
	return _water_point(f.home, f.radius)


# ------------------------------------------------------------------ in the air


## Off it goes: a run along the water away from the fright, its goal kept as where it set off
## from (the run's end measured from it).
func _take_off(f: Flock, b: Bird) -> void:
	var away := b.pos - f.fear
	away.y = 0.0
	away = (
		away.normalized()
		if away.length_squared() > 1e-12
		else -Vector3(sin(b.yaw), 0.0, cos(b.yaw))
	)
	b.air = true
	b.act = "run"
	b.goal = b.pos
	b.vel = away * PADDLE
	b.yaw = atan2(away.x, away.z)
	b.peck = 0.0


## What a duck in the air does this step: the run, the climb, the wheel, the glide back down.
func _fly(f: Flock, b: Bird, dt: float) -> void:
	match b.act:
		"run":
			_run(f, b, dt)
		"up":
			_climb(f, b, dt)
		"down":
			if b.land_in > 0.0:
				b.land_in -= dt
				_wheel(f, b, dt)
			else:
				_glide(f, b, dt)
		_:
			_wheel(f, b, dt)


## Runs along the water beating hard, its wings spread, then climbs away.
func _run(_f: Flock, b: Bird, dt: float) -> void:
	b.open = move_toward(b.open, 1.0, dt * 4.0)
	_beat_wings(b, DUCK_BEAT_HZ.x, dt)
	b.vel = b.vel.move_toward(b.vel.normalized() * DUCK_CRUISE * 0.4, DUCK_AIR_ACCEL * dt)
	b.yaw = atan2(b.vel.x, b.vel.z)
	b.pos += b.vel * dt
	b.pos.y = WS.WATER_Y
	b.phase += dt * 1.5
	if _flat(b.pos, b.goal) >= RUN_M:
		b.act = "up"
		b.act_t = _rng.randf_range(DUCK_UP_S.x, DUCK_UP_S.y)


## Climbs away from the fright, up and out, then joins the wheel.
func _climb(f: Flock, b: Bird, dt: float) -> void:
	b.open = 1.0
	_beat_wings(b, DUCK_BEAT_HZ.x, dt)
	var away := b.pos - f.fear
	away.y = 0.0
	away = away.normalized() if away.length_squared() > 1e-12 else Vector3.BACK
	b.vel = b.vel.move_toward(away * DUCK_CRUISE + Vector3.UP * DUCK_LIFT, DUCK_AIR_ACCEL * dt)
	b.pos += b.vel * dt
	b.yaw = atan2(b.vel.x, b.vel.z)
	b.pitch = lerpf(b.pitch, -0.5, 1.0 - exp(-3.0 * dt))
	b.act_t -= dt
	if b.act_t <= 0.0:
		b.pitch = 0.0
		b.theta = atan2(b.pos.z - f.home.z, b.pos.x - f.home.x)
		b.phase = _rng.randf()
		b.act = "wheel"


## Round and round over the water, wings held in a glide with a lazy beat now and then.
func _wheel(f: Flock, b: Bird, dt: float) -> void:
	b.open = move_toward(b.open, 0.15, dt * 3.0)
	b.pitch = move_toward(b.pitch, 0.0, dt)
	b.phase += dt * 0.35
	b.wing = lerpf(
		b.wing, DUCK_GLIDE_WING + 0.2 * maxf(sin(TAU * b.phase), 0.0), 1.0 - exp(-6.0 * dt)
	)
	b.theta += (DUCK_CRUISE / DUCK_WHEEL_R) * f.wheel_dir * dt
	var out := DUCK_WHEEL_R + b.lane.x
	b.pos = Vector3(
		f.home.x + cos(b.theta) * out, DUCK_WHEEL_UP + b.lane.y, f.home.z + sin(b.theta) * out
	)
	b.yaw = b.theta + f.wheel_dir * PI * 0.5
	b.roll = -0.25 * f.wheel_dir


## Glides in to its landing point, losing height, flaring its wings out over the water and
## settling onto it.
func _glide(f: Flock, b: Bird, dt: float) -> void:
	var to := b.goal - b.pos
	to.y = 0.0
	var dist := to.length()
	var near := dist < DUCK_FLARE
	b.open = move_toward(b.open, 1.0 if near else 0.15, dt * 3.0)
	_beat_wings(b, DUCK_BEAT_HZ.z if near else DUCK_BEAT_HZ.y, dt)
	if dist < 0.05 * WS.M or b.pos.y <= WS.WATER_Y + 0.01 * WS.M:
		b.air = false
		b.act = ""
		b.vel = Vector3.ZERO
		b.roll = 0.0
		b.pitch = 0.0
		b.pos.y = WS.WATER_Y
		_next(f, b)
		return
	b.yaw = rotate_toward(b.yaw, atan2(to.x, to.z), PADDLE_TURN * dt)
	var sp := clampf(dist * 1.5, DUCK_LAND_MPS.x, DUCK_LAND_MPS.y)
	b.pos += Vector3(sin(b.yaw), 0.0, cos(b.yaw)) * sp * dt
	b.pos.y = maxf(b.pos.y - sp * DUCK_GLIDE * dt, WS.WATER_Y)
	b.pitch = lerpf(b.pitch, 0.25, 1.0 - exp(-3.0 * dt))


## A duck's wings at hz beats a second.
func _beat_wings(b: Bird, hz: float, dt: float) -> void:
	b.phase += dt * hz
	b.wing = lerpf(DUCK_BEAT.x, DUCK_BEAT.y, 0.5 - 0.5 * cos(TAU * b.phase))
