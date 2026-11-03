extends SceneTree
## The fixture and helpers of the police response tests (fp_police_response_test.gd: the scene, the
## warning and the arrest; fp_police_chase_test.gd: the chase, the flag and the safety checks): a
## grown city with the hero on a sidewalk, the traffic feature stepped by hand with no ambient
## traffic, and a police station built on demand. Time runs by hand: the traffic feature's step and
## the bust's tick.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const POLICE := preload("res://scripts/fp/traffic/police_response.gd")
const DT := 0.05
const BODIES := ["Police_Male_01", "Police_Male_05", "Security_Female_01"]

var fails: Array[String] = []
var ctx: FpContext
var tr: Variant
## Every toast as [text, kind, clock], every hero_busted as [fine, why, clock], every person_hit
## cause.
var toasts: Array = []
var busts: Array = []
var hit_causes: Array = []
## A sidewalk spot on a straight road (the scene), and the station built later.
var here := Vector3.ZERO
var station := Vector2i(-1, -1)


## A grown city with the hero on a sidewalk, the traffic feature stepped by hand and no ambient
## traffic; false when either is missing.
func _setup() -> bool:
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "first"})
	ctx.player.set_process(false)
	tr = K.make_feature(ctx, "traffic")
	K.check(fails, tr != null, "the traffic feature is registered")
	if tr == null:
		return false
	tr.auto_step = false
	tr.ambient_enabled = false
	ctx.sim.construction_mode = "instant"
	FeatureFlags.set_override("police_response", true)
	var sw := K.sidewalk(ctx, 1.0)
	K.check(fails, not sw.is_empty(), "fixture: a straight sidewalk")
	if sw.is_empty():
		return false
	here = sw["pos"]
	ctx.bus.toast.connect(func(t: String, k: String) -> void: toasts.append([t, k, tr.clock]))
	ctx.bus.hero_busted.connect(
		func(fine: int, why: String, _at: Vector3) -> void: busts.append([fine, why, tr.clock])
	)
	ctx.bus.person_hit.connect(
		func(_at: Vector3, cause: String, _info: Dictionary) -> void: hit_causes.append(cause)
	)
	_hero_at(here)
	return true


func _pol() -> RefCounted:
	return tr.police


## One second-scale step of the street and of the bust's fade.
func _step(secs: float) -> void:
	var t := 0.0
	while t < secs - 1e-6:
		tr.step(DT)
		tr.police.bust.tick(DT)
		t += DT


## Steps until cond holds (true) or max_s seconds pass (false).
func _wait(cond: Callable, max_s: float) -> bool:
	var t := 0.0
	while t < max_s:
		if cond.call():
			return true
		_step(DT)
		t += DT
	return cond.call()


func _car() -> VH.Car:
	for c: VH.Car in tr.vehicles.cars:
		if c.role == "crew" and not c.dead:
			return c
	return null


func _phase(c: VH.Car) -> String:
	return str((c.owner as Dictionary).get("phase", "")) if c != null else ""


func _at_scene() -> bool:
	return _phase(_car()) == "at_scene"


func _hero_at(p: Vector3) -> void:
	ctx.player.teleport(p, 0.0)


## The hero's feet `m` metres from car c along the road (+z, away from the end the cars come to).
func _along(c: VH.Car, m: float) -> Vector3:
	return Vector3(here.x, here.y, c.pos.z + m * WS.M)


## Clears every crew and response, the toasts and the arrest cooldown, and stands the hero at the
## scene on foot.
func _reset() -> void:
	tr._driven = null
	for c: VH.Car in tr.vehicles.cars.duplicate():
		if c.role == "crew":
			tr.vehicles.remove(c)
	tr.fleets.pending.clear()
	tr.fleets.homing.clear()
	tr.police.reset()
	tr.police._last_bust = -INF
	toasts.clear()
	busts.clear()
	ctx.player.input_enabled = false
	_hero_at(here)


## A police car at the scene (called from the station built for the test), called for why.
func _quick(why: String) -> VH.Car:
	return _arrive(why, 120.0)


## A crew called from the street's own station through the incident's path, driven to the scene.
func _arrive(why: String, max_s: float) -> VH.Car:
	_reset()
	var ok: bool = tr.call_crew("police", here, 40.0, why)
	K.check(fails, ok, "a police crew is called for %s" % why)
	_wait(_at_scene, max_s)
	return _car()


func _toasted(prefix: String) -> int:
	var n := 0
	for t: Array in toasts:
		if str(t[0]).begins_with(prefix):
			n += 1
	return n


## The traffic clock of the first toast starting with prefix, -1 when there is none.
func _toast_at(prefix: String) -> float:
	for t: Array in toasts:
		if str(t[0]).begins_with(prefix):
			return float(t[2])
	return -1.0


## Whether car c has a response (the officers out, or the car sent after a far hero).
func _responded(c: VH.Car) -> bool:
	return c != null and _pol()._resp.has(c.id)


## Steps secs real seconds at sim speed `speed` (the street gets speed times as much game time).
func _step_speed(secs: float, speed: int) -> void:
	ctx.sim.speed = speed
	var t := 0.0
	while t < secs - 1e-6:
		for _k in range(speed):
			tr.step(DT)
		tr.police.bust.tick(DT)
		t += DT
	ctx.sim.speed = 1


func _modes(c: VH.Car) -> Array:
	var out: Array = []
	var r: Variant = _pol()._resp.get(c.id)
	if r != null:
		for off: Variant in r.officers:
			out.append(off.mode)
	return out


func _officer(c: VH.Car, k: int) -> Variant:
	return _pol()._resp[c.id].officers[k]


## Freezes the officers where they stand (a mode no branch of the response moves).
func _freeze(c: VH.Car) -> void:
	for off: Variant in _pol()._resp[c.id].officers:
		off.mode = "frozen"
		off.w.v = 0.0


## The point `m` metres to the side of car c (level with it), where a hero's car can stand.
func _beside(c: VH.Car, m: float) -> Vector3:
	return Vector3(c.pos.x + m * WS.M, here.y, c.pos.z)


## Puts the officers of car c at their posts (they come out at the car's flank and walk there).
func _to_posts(c: VH.Car) -> void:
	var r: Variant = _pol()._resp[c.id]
	for off: Variant in r.officers:
		off.w.pos = _pol()._spot(r, off.k, POLICE.POST_OUT)
		off.mode = "post"


func _drive(pos: Vector3, speed_m: float) -> VH.Car:
	var d := VH.Car.new()
	d.pos = pos
	d.v = speed_m * WS.M
	tr._driven = d
	return d


func _flat_m(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length() / WS.M


func _stations() -> int:
	var n := 0
	for i in ctx.sim.active:
		if ctx.sim.kind[i] == D.POLICE:
			n += 1
	return n


func _build_station() -> void:
	var lots := ctx.sim.open_lots(0, 200)
	var best: Array = []
	var best_d := 99.0
	for lot: Array in lots:
		var d := Vector2(float(lot[0]) - here.x, float(lot[1]) - here.z).length()
		if d < best_d and d > 4.0:
			best_d = d
			best = lot
	var res := ctx.sim.apply_action(
		0, {"type": "build", "building": "police", "x": int(best[0]), "y": int(best[1])}
	)
	K.check(fails, bool(res.get("ok", false)), "fixture: a police station (%s)" % str(res))
	station = Vector2i(int(best[0]), int(best[1]))


## A crew called to the scene with the hero `off_m` metres down the road from it by the time the
## car gets there; returns once the car has its response.
func _arrive_far(why: String, off_m: float) -> VH.Car:
	_reset()
	K.check(fails, tr.call_crew("police", here, 40.0, why), "a police crew is called (%s)" % why)
	_hero_at(Vector3(here.x, here.y, here.z + off_m * WS.M))
	_wait(func() -> bool: return _responded(_car()), 200.0)
	return _car()


## Chase car c (put at its posts) after a hero who runs to `far` (61 m off first) and stands there,
## or jogs on the spot (6 m/s); the car "closing" on them or not by the response's own record:
## seconds from the chase's start to "Police lost you" (-1 when it was not lost in 75 s).
func _lost_after(c: VH.Car, far: Vector3, moving: bool, closing: bool) -> float:
	_to_posts(c)
	_hero_at(_along(c, 61.0))
	_wait(func() -> bool: return _pol().phase_of(c.id) == "chase", 12.0)
	_hero_at(far)
	var r: Variant = _pol()._resp.get(c.id)
	var t0: float = tr.clock
	var jit := 0.0
	while r != null and tr.clock - t0 < 75.0 and _toasted("Police lost") == 0:
		r.mark_d = INF if closing else -INF
		if moving:
			jit = 0.15 * WS.M if jit <= 0.0 else -0.15 * WS.M
			_hero_at(far + Vector3(jit, 0.0, 0.0))
		_step(DT)
	return tr.clock - t0 if _toasted("Police lost") > 0 else -1.0


func _officers_alive() -> int:
	return tr.walkers.walkers.filter(func(w: WK.Walker) -> bool: return w.role == "officer").size()


## Metres from p to the nearest road tile's centre.
func _gap_m(p: Vector3) -> float:
	var gap := INF
	for i: int in tr.lanes.tiles.keys():
		gap = minf(gap, Vector2(D.tx(i) - p.x, D.ty(i) - p.z).length() / WS.M)
	return gap


## A point 70 m to far m from car c with its nearest road tile between lo and hi metres off (the
## officers get out for a hero within 50 m of the car, 60 m after a chase, so the default is a hero
## out of every chase's reach); (INF, INF, INF) when there is none.
func _far_spot(c: VH.Car, lo: float = 60.0, hi: float = INF, far: float = 300.0) -> Vector3:
	for gx in range(0, 38):
		for gz in range(0, 38):
			var p := Vector3(float(gx), 0.0, float(gz))
			var d := _flat_m(p, c.pos)
			if d < 70.0 or d > far:
				continue
			var gap := _gap_m(p)
			if gap >= lo and gap <= hi:
				return p
	return Vector3(INF, INF, INF)
