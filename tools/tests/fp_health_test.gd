extends SceneTree
## Hero health (integration feature "health"; docs/fp/ARCHITECTURE.md, Health): the bar and its
## HUD (the arc round the minimap, the vignette, photo mode); crashes and hard landings by their
## speed (softer rolled off); punches, the guard and the guard's poise (guard_chip); the flinch
## the way a blow came from, with
## the view jolt (hero_flinch); a car's blow knocking the hero down (the
## throw, the rig, input back once up); health coming back; a knock-out (the fade, the wake outside
## the nearest hospital, healed, the toast; City Hall without one); save and load; people who fight
## back (fight_back) and cars that cannot stop running the hero down (hit_by_cars), each off with
## its flag; teardown. Third person on a grown city; time runs through traffic's step, the
## features' tick(1/60) and the player's simulate and update_view.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const HEALTH := preload("res://scripts/fp/health/health_feature.gd")
const TF := preload("res://scripts/fp/traffic/traffic_feature.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var act: FpFeature
var f: FpFeature
var rig: RefCounted
## [amount, cause, health, down] of every hero_hurt, and the text of every toast.
var hurts: Array = []
var toasts: Array[String] = []


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	tr = K.make_feature(ctx, "traffic")
	act = K.make_feature(ctx, "actions")
	f = K.make_feature(ctx, "health")
	if tr == null or act == null or f == null:
		K.check(fails, false, "the traffic, actions and health features are registered")
		K.finish(self, "FP_HEALTH_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	act.set_process(false)
	f.set_process(false)
	_quiet()
	ctx.bus.hero_hurt.connect(_on_hurt)
	ctx.bus.toast.connect(func(t: String, _kind: String) -> void: toasts.append(t))
	var p := ctx.player
	p.input_enabled = true
	p.teleport(p.position, rad_to_deg(p.yaw))
	rig = p.avatar.get("rig")
	K.check(fails, rig != null, "fixture: the hero is HC's animated rig")
	if rig == null:
		K.finish(self, "FP_HEALTH_TEST", fails)
		return
	_check_setup()
	_check_hud()
	_check_crash()
	_check_fall()
	_check_punch()
	_check_guard_chip()
	_check_flinch()
	_check_hit_attacker()
	_check_regen()
	_check_car()
	_check_knock_out()
	_check_save()
	_check_fight_back()
	_check_run_down()
	_check_teardown()
	K.finish(self, "FP_HEALTH_TEST", fails)


func _on_hurt(amount: float, cause: String, health: float, down: bool) -> void:
	hurts.append([amount, cause, health, down])


# ------------------------------------------------------------------ helpers


## Runs the street for secs: traffic, the actions, health, then the player.
func _step(secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		tr.call("step", DT)
		act.call("tick", DT)
		f.call("tick", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)


func _hp() -> float:
	return float(f.get("hp"))


## A fresh hero where they stand: a full bar, on their feet and in control.
func _heal() -> void:
	f.call("from_dict", {"hp": HEALTH.MAX_HP})
	var p := ctx.player
	p.input_enabled = true
	p.teleport(p.position, rad_to_deg(p.yaw))
	_step(0.1)
	hurts.clear()


## The last hero_hurt for cause, [] when none.
func _last(cause: String) -> Array:
	for k in range(hurts.size() - 1, -1, -1):
		if str(hurts[k][1]) == cause:
			return hurts[k]
	return []


func _count(cause: String) -> int:
	var n := 0
	for h: Array in hurts:
		if str(h[1]) == cause:
			n += 1
	return n


## No moving traffic, no trips and nobody walking (parked cars stay).
func _quiet() -> void:
	var vh: VH = tr.get("vehicles")
	for c: VH.Car in vh.cars.duplicate():
		if not c.parked:
			vh.remove(c)
	var people: WK = tr.get("walkers")
	for w: WK.Walker in people.walkers.duplicate():
		people.remove(w)
	tr.get("trips").trips.clear()
	tr.get("trips").standing.clear()


## A passer-by standing metres ahead of the hero, turned to them.
func _stranger(metres: float) -> WK.Walker:
	var people: WK = tr.get("walkers")
	var ahead := ctx.player.body_forward()
	var w := people.make("ambient")
	w.extra = 0
	var at := ctx.player.position + ahead * (metres * WS.M)
	people.stand(w, at, atan2(-ahead.x, -ahead.z))
	return w


## The eastbound lanes along a straight east-west road three tiles long, [] without one.
func _east_lanes() -> Array:
	var lg: LG = tr.get("lanes")
	for i: int in lg.tiles.keys():
		var x := D.tx(i)
		var y := D.ty(i)
		if not D.in_bounds(x + 2, y):
			continue
		var run: Array[int] = [i, D.idx(x + 1, y), D.idx(x + 2, y)]
		if run.all(func(t: int) -> bool: return _straight(lg, t)):
			return lg.lanes_along(run, 3, 1)
	return []


static func _straight(lg: LG, i: int) -> bool:
	var t: LG.TileInfo = lg.info(i)
	return t != null and t.piece == "straight" and not t.bridge and t.mask == 10


## A test car at s on lane l with the lanes after it as its path, at mps (and wanting it).
func _car_at(l: LG.Lane, s: float, path: Array, mps: float) -> VH.Car:
	var vh: VH = tr.get("vehicles")
	var model: int = tr.call("car_model_for", "health-test")
	var c := vh.make("car", "test", tr.call("dims", model))
	c.model = model
	vh.place(c, l, s)
	c.path = path.duplicate()
	c.v0 = mps * WS.M
	c.v = c.v0
	return c


## The hero on c's lane (or path) metres ahead of its front, facing it; returns c's heading there.
func _hero_ahead(c: VH.Car, metres: float) -> Vector3:
	var lg: LG = tr.get("lanes")
	var l: LG.Lane = c.lane
	var s := c.s + metres * WS.M
	for nx: LG.Lane in c.path:
		if s <= l.length:
			break
		s -= l.length
		l = nx
	var at := lg.pos_at(l, s)
	var head := lg.tan_at(l, s)
	ctx.player.teleport(Vector3(at.x, 0.0, at.y), rad_to_deg(atan2(head.x, head.y)))
	return Vector3(head.x, 0.0, head.y)


## Ground distance from p to c's body (its box as drawn; 0 inside it).
func _gap(c: VH.Car, p: Vector3) -> float:
	var h := Vector2(sin(c.yaw), cos(c.yaw))
	var ctr := c.pos + c.vis_off
	var rel := Vector2(p.x - ctr.x, p.z - ctr.z)
	var out := Vector2(absf(rel.dot(h)) - c.length * 0.5, absf(rel.cross(h)) - c.half_w)
	return Vector2(maxf(out.x, 0.0), maxf(out.y, 0.0)).length()


## Seconds the rig takes to fall, lie lie seconds and get up.
func _down_secs(lie: float) -> float:
	var lens: Dictionary = rig.get("lengths")
	return float(lens["knockback"]) + lie + float(lens["get_up"])


## Two lots beside roads made hospitals for the test, the nearer to the hero first, each with the
## kind it had: [[tile, kind], ...]; fewer when the city has not got them.
func _hospitals() -> Array:
	var sim := ctx.sim
	var p := ctx.player.position
	var lots: Array = []
	for i in sim.active:
		var k := sim.kind[i]
		if k != D.ROAD and k != D.HALL and k != D.EMPTY and ctx.directory.frontage(i) >= 0:
			lots.append([Vector2(D.tx(i) - p.x, D.ty(i) - p.z).length(), i])
	lots.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var out: Array = []
	var near_d := INF
	for l: Array in lots:
		var d := float(l[0])
		if out.size() == 2:
			break
		if out.is_empty() and d >= 2.0:
			near_d = d
		elif out.is_empty() or d < near_d + 3.0:
			continue
		out.append([int(l[1]), sim.kind[int(l[1])]])
	for m: Array in out:
		sim.kind[int(m[0])] = D.HOSPITAL
	return out


# ------------------------------------------------------------------ checks


func _check_setup() -> void:
	var st := f.self_test()
	K.check(fails, bool(st.get("ok", false)), "self_test (%s)" % st.get("detail", ""))
	K.check(fails, is_equal_approx(_hp(), HEALTH.MAX_HP), "the hero starts on a full bar")
	var arc := ctx.hud.slot("minimap_slot").get_node_or_null("HealthArc")
	K.check(fails, arc != null, "the arc sits in the minimap slot")
	var screen := ctx.hud.slot("overlay").get_node_or_null("HealthScreen")
	var under := screen != null and screen.get_index() == 0
	K.check(fails, under, "the screen layer lies under the rest of the overlay")
	K.check(fails, not bool(f.call("knocked")), "on their feet")


func _check_hud() -> void:
	var arc: Control = ctx.hud.slot("minimap_slot").get_node("HealthArc")
	var screen: Control = ctx.hud.slot("overlay").get_node("HealthScreen")
	var vignette: TextureRect = screen.get("vignette")
	K.check(fails, not vignette.visible, "no vignette on a full bar")
	f.call("hurt", 60.0, "punch")
	_step(0.1)
	var shown := float(arc.get("value"))
	var trail := float(arc.get("trail"))
	K.check(
		fails,
		absf(shown - 0.4) < 1e-3 and trail > 0.99,
		"the arc drops to 40%%, a trail left behind for a moment (%.2f, %.2f)" % [shown, trail]
	)
	K.check(fails, arc.call("colour") == S.AMBER, "amber below half")
	_step(1.5)
	trail = float(arc.get("trail"))
	K.check(fails, absf(trail - 0.4) < 0.01, "then the trail eats down (%.3f)" % trail)
	f.call("hurt", 25.0, "punch")
	_step(0.1)
	var red: Color = arc.call("colour")
	K.check(fails, Color(red, 1.0) == Color(S.RED, 1.0), "red below a quarter")
	_step(1.5)
	K.check(fails, vignette.visible, "low on health the vignette stays")
	ctx.player.photo_mode = true
	_step(1.5)
	K.check(fails, not vignette.visible, "photo mode hides it")
	ctx.player.photo_mode = false
	_heal()
	_step(1.5)
	var full := not vignette.visible and is_equal_approx(float(arc.get("value")), 1.0)
	K.check(fails, full, "healed: a full arc and no vignette")


func _check_crash() -> void:
	_heal()
	var at := ctx.player.position
	ctx.bus.car_impact.emit(at, (HEALTH.CRASH_SAFE - 1.0) * WS.M, "car")
	K.check(fails, hurts.is_empty(), "a crash at 6 m/s costs nothing")
	ctx.bus.car_impact.emit(at, 19.5 * WS.M, "wall")
	var want := HEALTH.MAX_HP * (19.5 - HEALTH.CRASH_SAFE) / (HEALTH.CRASH_KO - HEALTH.CRASH_SAFE)
	var got := _last("crash")
	var cost := float(got[0]) if not got.is_empty() else 0.0
	K.check(
		fails,
		hurts.size() == 1 and absf(cost - want) < 0.01,
		"one at 19.5 m/s costs %.0f (%s)" % [want, str(hurts)]
	)
	var standing := not got.is_empty() and not bool(got[3]) and not bool(f.call("knocked"))
	K.check(fails, standing, "and leaves the hero on their feet")
	K.check(fails, absf(_hp() - (HEALTH.MAX_HP - want)) < 0.01, "health %.0f" % _hp())
	_step(0.1)
	K.check(fails, bool(rig.call("action_active")), "the body flinches")
	var kick: Vector2 = ctx.player.get("_kick")
	K.check(fails, kick.length() > 1e-4, "and the view jolts")


func _check_fall() -> void:
	_heal()
	var p := ctx.player
	p.landed.emit(HEALTH.FALL_SAFE - 0.5, false)
	K.check(fails, hurts.is_empty(), "landing at 5.5 m/s (a 1.5 m drop) costs nothing")
	_check_rolled_fall()
	p.teleport(p.position + Vector3(0.0, 6.0 * WS.M, 0.0), rad_to_deg(p.yaw), 0.0, false)
	var t := 0.0
	while hurts.is_empty() and t < 3.0:
		_step(DT)
		t += DT
	var v := sqrt(2.0 * 9.81 * 6.0)
	var want := HEALTH.MAX_HP * (v - HEALTH.FALL_SAFE) / (HEALTH.FALL_KO - HEALTH.FALL_SAFE)
	var got := _last("fall")
	var cost := float(got[0]) if not got.is_empty() else 0.0
	K.check(fails, absf(cost - want) < 4.0, "a 6 m drop costs about %.0f (%.1f)" % [want, cost])
	var down := not got.is_empty() and bool(got[3]) and bool(f.call("knocked"))
	K.check(fails, down and not p.input_enabled, "and knocks the hero down, input held")
	_step(0.3)
	K.check(fails, str(rig.call("state")) == "knockback", "the body falls (%s)" % rig.call("state"))
	_step(_down_secs(HEALTH.LIE_S) - 0.5)
	K.check(fails, bool(f.call("knocked")), "still down while the rig gets up")
	_step(0.3)
	K.check(fails, not bool(f.call("knocked")) and p.input_enabled, "up again: input back")
	var st := str(rig.call("state"))
	K.check(fails, st in ["get_up", "loco"], "on their feet (%s)" % st)


## A landing rolled off (the parkour feature carrying the body on) counts ROLL_SAVE m/s slower and
## never knocks the hero down: 9.5 m/s costs nothing; 13 m/s costs what 9 would, enough to knock
## them down had they landed it, and leaves them standing. The carried body only feels it in the
## view.
func _check_rolled_fall() -> void:
	var p := ctx.player
	p.landed.emit(HEALTH.FALL_SAFE + HEALTH.ROLL_SAVE - 0.5, true)
	K.check(fails, hurts.is_empty(), "rolled off, a landing at 9.5 m/s costs nothing")
	p.carry(p.position, p.yaw, Vector3.ZERO, true)
	p.landed.emit(13.0, true)
	var v := 13.0 - HEALTH.ROLL_SAVE
	var want := HEALTH.MAX_HP * (v - HEALTH.FALL_SAFE) / (HEALTH.FALL_KO - HEALTH.FALL_SAFE)
	var got := _last("fall")
	var cost := float(got[0]) if not got.is_empty() else 0.0
	var standing := not got.is_empty() and not bool(got[3]) and not bool(f.call("knocked"))
	K.check(
		fails,
		absf(cost - want) < 0.01 and want >= HEALTH.FALL_DOWN and standing,
		"rolled off, one at 13 m/s costs %.1f (%.1f) and leaves the hero standing" % [want, cost]
	)
	_step(0.1)
	var kick: Vector2 = p.get("_kick")
	K.check(
		fails,
		not bool(rig.call("action_active")) and kick.length() > 1e-4,
		"the carried body does not flinch, the view jolts"
	)
	p.release(true)
	_heal()


func _check_punch() -> void:
	_heal()
	var p := ctx.player
	var fwd := p.body_forward()
	var up := Vector3(0.0, 1.45 * WS.M, 0.0)
	ctx.bus.hero_hit.emit(p.position + fwd * (0.6 * WS.M) + up, "punch", 0.5, -fwd * 0.07)
	var want := HEALTH.PUNCH + HEALTH.PUNCH_K * 0.5
	var got := _last("punch")
	var cost := float(got[0]) if not got.is_empty() else 0.0
	K.check(
		fails,
		absf(cost - want) < 0.01 and not bool(f.call("knocked")),
		"a punch of 0.5 costs %.0f (%.1f) and the hero keeps their feet" % [want, cost]
	)
	act.call("set_guard", true)
	_step(0.4)
	K.check(fails, bool(act.get("guarding")), "fixture: the guard is up")
	fwd = p.body_forward()
	hurts.clear()
	ctx.bus.hero_hit.emit(p.position + fwd * (0.6 * WS.M) + up, "punch", 0.5, -fwd * 0.07)
	got = _last("punch")
	cost = float(got[0]) if not got.is_empty() else 0.0
	var guarded := want * HEALTH.GUARD_K
	K.check(
		fails, absf(cost - guarded) < 0.01, "the guard takes most of one from ahead (%.1f)" % cost
	)
	ctx.bus.hero_hit.emit(p.position - fwd * (0.6 * WS.M) + up, "punch", 0.5, fwd * 0.07)
	got = _last("punch")
	cost = float(got[0]) if not got.is_empty() else 0.0
	K.check(fails, absf(cost - want) < 0.01, "but none of one from behind (%.1f)" % cost)
	act.call("set_guard", false)
	_step(0.2)


## The guard's poise (guard_chip): each punch the guard catches drains it, the one that beats it
## lands in full and drops the guard — a beat of stagger — and the poise knits back once the
## blows stop. With the flag off the guard never tires.
func _check_guard_chip() -> void:
	_heal()
	var p := ctx.player
	var up := Vector3(0.0, 1.45 * WS.M, 0.0)
	var want := HEALTH.PUNCH + HEALTH.PUNCH_K * 0.5
	var guarded := want * HEALTH.GUARD_K
	act.call("set_guard", true)
	_step(0.2)
	var fwd := p.body_forward()
	var costs: Array = []
	for _i: int in 3:
		hurts.clear()
		ctx.bus.hero_hit.emit(p.position + fwd * (0.6 * WS.M) + up, "punch", 0.5, -fwd * 0.07)
		var got := _last("punch")
		costs.append(float(got[0]) if not got.is_empty() else 0.0)
	K.check(
		fails,
		absf(float(costs[0]) - guarded) < 0.01 and absf(float(costs[1]) - guarded) < 0.01,
		"the guard takes most of the first two (%.1f, %.1f)" % [float(costs[0]), float(costs[1])]
	)
	K.check(
		fails,
		absf(float(costs[2]) - want) < 0.01,
		"the third beats the guard and lands in full (%.1f)" % float(costs[2])
	)
	K.check(fails, not p.input_enabled, "and the break staggers the hero")
	_step(0.05)
	K.check(fails, not bool(act.get("guarding")), "the broken guard drops")
	_step(1.0)
	K.check(fails, p.input_enabled, "for a beat, then the input is back")
	_step(2.2)
	K.check(
		fails,
		float(f.get("poise")) > 0.5,
		"the poise knits back once the blows stop (%.2f)" % float(f.get("poise"))
	)
	FeatureFlags.set_override("guard_chip", false)
	act.call("set_guard", true)
	_step(0.2)
	for _i: int in 3:
		ctx.bus.hero_hit.emit(p.position + fwd * (0.6 * WS.M) + up, "punch", 0.5, -fwd * 0.07)
	var got := _last("punch")
	var last_cost := float(got[0]) if not got.is_empty() else 0.0
	K.check(
		fails,
		absf(last_cost - guarded) < 0.01 and bool(act.get("guarding")),
		"with the flag off the guard never tires (%.1f)" % last_cost
	)
	act.call("set_guard", false)
	FeatureFlags.set_override("guard_chip", true)
	_step(0.2)


## A blow that lands flinches the body the way it came from — one in the face snaps the head
## back, one in the back folds the chest — the camera rolling toward the side that was hit,
## harder for a harder blow (hero_flinch); with the flag off the two fixed flinches alternate.
func _check_flinch() -> void:
	_heal()
	var p := ctx.player
	var fwd := p.body_forward()
	ctx.bus.hero_hit.emit(p.position, "punch", 0.5, -fwd * 0.07)
	K.check(fails, f.get("flinch_clip") == "hit_head", "a blow in the face snaps the head back")
	_step(1.0)
	ctx.bus.hero_hit.emit(p.position, "punch", 0.5, fwd * 0.07)
	K.check(fails, f.get("flinch_clip") == "hit_chest", "one in the back folds the chest")
	# The view jolt scales with the blow while hit_feel is on.
	_step(1.0)
	f.set("hp", HEALTH.MAX_HP)
	var k0: Vector2 = p.get("_kick")
	ctx.bus.hero_hit.emit(p.position, "punch", 0.1, -fwd * 0.07)
	var light: Vector2 = (p.get("_kick") as Vector2) - k0
	_step(1.0)
	k0 = p.get("_kick")
	ctx.bus.hero_hit.emit(p.position, "punch", 1.0, -fwd * 0.07)
	var hard: Vector2 = (p.get("_kick") as Vector2) - k0
	K.check(
		fails,
		hard.length() > light.length() * 1.5,
		"a harder blow jolts the view harder (%.4f over %.4f)" % [hard.length(), light.length()]
	)
	# The camera rolls toward the side that was hit (right is (cos, -sin) of the yaw).
	var right3 := Vector3(cos(p.yaw), 0.0, -sin(p.yaw))
	_step(1.0)
	f.set("hp", HEALTH.MAX_HP)
	k0 = p.get("_kick")
	ctx.bus.hero_hit.emit(p.position, "punch", 0.5, -right3 * 0.07)
	var from_right: Vector2 = (p.get("_kick") as Vector2) - k0
	_step(1.0)
	k0 = p.get("_kick")
	ctx.bus.hero_hit.emit(p.position, "punch", 0.5, right3 * 0.07)
	var from_left: Vector2 = (p.get("_kick") as Vector2) - k0
	K.check(
		fails,
		absf(from_right.y) > 1e-4 and signf(from_right.y) == -signf(from_left.y),
		(
			"and the camera rolls toward the side that was hit (%.4f, %.4f)"
			% [from_right.y, from_left.y]
		)
	)
	# With the flag off the two fixed flinches alternate, whatever the direction.
	FeatureFlags.set_override("hero_flinch", false)
	_step(1.0)
	f.set("hp", HEALTH.MAX_HP)
	ctx.bus.hero_hit.emit(p.position, "punch", 0.5, -fwd * 0.07)
	var first: String = f.get("flinch_clip")
	_step(1.0)
	ctx.bus.hero_hit.emit(p.position, "punch", 0.5, -fwd * 0.07)
	var second: String = f.get("flinch_clip")
	FeatureFlags.set_override("hero_flinch", true)
	K.check(
		fails,
		first != second and first in HEALTH.FLINCHES and second in HEALTH.FLINCHES,
		"hero_flinch off: the two fixed flinches alternate (%s, %s)" % [first, second]
	)


func _check_regen() -> void:
	_heal()
	f.call("hurt", 40.0, "punch")
	_step(HEALTH.REGEN_DELAY - 0.5)
	K.check(
		fails,
		is_equal_approx(_hp(), 60.0),
		"no health comes back for %.0f s after a hurt (%.1f)" % [HEALTH.REGEN_DELAY, _hp()]
	)
	_step(2.5)
	var want := 60.0 + HEALTH.REGEN_RATE * 2.0
	K.check(
		fails,
		absf(_hp() - want) < 0.3,
		"then it comes back %.0f a second (%.1f)" % [HEALTH.REGEN_RATE, _hp()]
	)
	_step(10.0)
	K.check(fails, is_equal_approx(_hp(), HEALTH.MAX_HP), "up to a full bar")


func _check_car() -> void:
	var lanes := _east_lanes()
	K.check(fails, not lanes.is_empty(), "fixture: a straight east-west road three tiles long")
	if lanes.is_empty():
		return
	var lg: LG = tr.get("lanes")
	var head := lg.tan_at(lanes[1], 0.5)
	var spot := lg.pos_at(lanes[1], 0.5)
	var p := ctx.player
	p.teleport(Vector3(spot.x, 0.0, spot.y), 0.0)
	_heal()
	var dir := Vector3(head.x, 0.0, head.y)
	var start := p.position
	ctx.bus.hero_hit.emit(start - dir * WS.PLAYER_RADIUS, "car", 0.4, dir * (6.0 * WS.M))
	var got := _last("car")
	var cost := float(got[0]) if not got.is_empty() else 0.0
	var down := not got.is_empty() and bool(got[3])
	K.check(fails, absf(cost - 40.0) < 0.01 and down, "a car's blow of 0.4 costs 40, knocking down")
	K.check(fails, bool(f.call("knocked")) and not p.input_enabled, "down: no input")
	var facing := p.body_forward().dot(dir)
	K.check(fails, facing < -0.95, "turned to face the car (%.2f)" % facing)
	_step(1.5)
	var slid := (p.position - start).dot(dir) / WS.M
	var want := 36.0 / (2.0 * HEALTH.SLIDE_DECEL / WS.M)
	K.check(fails, absf(slid - want) < 0.3, "thrown %.2f m on (%.2f)" % [slid, want])
	K.check(fails, str(rig.call("state")) == "knockback", "lying (%s)" % rig.call("state"))
	_step(_down_secs(HEALTH.LIE_S) - 1.5 - 0.2)
	K.check(fails, bool(f.call("knocked")), "still down just before the get-up ends")
	_step(0.3)
	K.check(fails, not bool(f.call("knocked")) and p.input_enabled, "up again with input back")
	hurts.clear()
	ctx.bus.hero_hit.emit(p.position - dir * WS.PLAYER_RADIUS, "car", 0.1, dir * (1.5 * WS.M))
	got = _last("car")
	var light := not got.is_empty() and not bool(got[3]) and not bool(f.call("knocked"))
	K.check(fails, light, "a light knock (0.1) only makes the hero flinch (%s)" % str(got))


func _check_knock_out() -> void:
	_heal()
	var made := _hospitals()
	K.check(fails, made.size() == 2, "fixture: two lots made hospitals (%d)" % made.size())
	if made.size() < 2:
		return
	var p := ctx.player
	var near: int = made[0][0]
	var road := ctx.directory.frontage(near)
	var out_dir := Vector3(D.tx(near) - D.tx(road), 0.0, D.ty(near) - D.ty(road))
	var door := Vector3(D.tx(road), 0.0, D.ty(road)) + out_dir * WS.SIDEWALK_CENTER
	var spot: Dictionary = f.call("hospital_spot", p.position)
	var at: Vector3 = spot["pos"]
	var flat := Vector2(at.x - door.x, at.z - door.z).length()
	K.check(fails, flat < 1e-4, "the nearer hospital's sidewalk is where they would come round")
	var screen: Control = ctx.hud.slot("overlay").get_node("HealthScreen")
	var black: ColorRect = screen.get("black")
	var caption: Label = screen.get("caption")
	toasts.clear()
	ctx.bus.hero_hit.emit(p.position, "car", 1.0, Vector3.ZERO)
	var got := _last("car")
	var empty := not got.is_empty() and float(got[2]) == 0.0 and bool(got[3])
	K.check(fails, empty and bool(f.get("out")), "a full-strength car knocks the hero out")
	K.check(fails, bool(f.call("knocked")) and not p.input_enabled, "down, no input")
	_step(HEALTH.KO_FADE * 0.5)
	var a := black.modulate.a
	K.check(fails, black.visible and absf(a - 0.5) < 0.05, "the screen fades to black (%.2f)" % a)
	_step(HEALTH.KO_FADE * 0.5 + HEALTH.KO_HOLD * 0.25)
	K.check(fails, black.modulate.a > 0.99 and caption.visible, "black, with the caption")
	K.check(fails, _hp() == 0.0, "still out")
	_step(HEALTH.KO_HOLD * 0.5)
	flat = Vector2(p.position.x - at.x, p.position.z - at.z).length()
	var healed := is_equal_approx(_hp(), HEALTH.MAX_HP)
	K.check(
		fails, flat < 0.02 and healed, "in the dark they come round there, healed (%.3f)" % flat
	)
	K.check(fails, not caption.visible, "the caption goes")
	_step(HEALTH.KO_HOLD * 0.25 + HEALTH.KO_IN + 0.1)
	var back := not bool(f.get("out")) and p.input_enabled and not black.visible
	K.check(fails, back, "the screen comes back and the input with it")
	var line := "You came round outside %s." % spot["name"]
	K.check(fails, toasts == [line], "a toast says where (%s)" % str(toasts))
	var count := int(f.get("knockouts")) == 1 and str(f.get("woke_at")) == str(spot["name"])
	K.check(fails, count, "one knock-out, at %s" % spot["name"])
	for m: Array in made:
		ctx.sim.kind[int(m[0])] = int(m[1])
	var hall: Dictionary = f.call("hospital_spot", p.position)
	var sp: Vector3 = ctx.mode.spawn_point()["pos"]
	var at_hall := str(hall["name"]).is_empty() and (hall["pos"] as Vector3).distance_to(sp) < 1e-4
	K.check(fails, at_hall, "with no hospital they would come round outside City Hall")


func _check_save() -> void:
	_heal()
	f.call("hurt", 36.6, "punch")
	var d: Dictionary = f.call("to_dict")
	var kept := absf(float(d.get("hp", -1.0)) - 63.4) < 1e-4
	K.check(fails, kept and d.size() == 1, "to_dict keeps the health (%s)" % str(d))
	f.call("from_dict", {"hp": 0.0})
	K.check(fails, is_equal_approx(_hp(), 1.0), "a save at nothing loads at 1 (%.1f)" % _hp())
	f.call("from_dict", {})
	K.check(fails, is_equal_approx(_hp(), HEALTH.MAX_HP), "none loads a full bar")
	ctx.bus.hero_hit.emit(ctx.player.position, "car", 0.5, Vector3.ZERO)
	_step(0.5)
	f.call("from_dict", {"hp": 50.0})
	var up := not bool(f.call("knocked")) and ctx.player.input_enabled
	up = up and str(rig.call("state")) == "loco"
	K.check(fails, up and is_equal_approx(_hp(), 50.0), "a load mid knock-down stands the hero up")


## Who struck is named in the blow's info ("by": -1 the hero, else a walker's id): an NPC's
## punches never feed the assault streak nor call a crew on the hero; the hero's knock-down does.
func _check_hit_attacker() -> void:
	_heal()
	_quiet()
	var p := ctx.player
	var streak: Array = (tr.get("incidents") as RefCounted).get("_punches")
	var n0 := streak.size()
	var w := _stranger(1.0)
	var other := _stranger(2.0)
	var push := p.body_forward() * (1.5 * WS.M)
	var info: Dictionary = tr.call(
		"hit_walker", w.id, p.position, push, 0.45, "punch", 0.0, other.id
	)
	K.check(
		fails,
		not info.is_empty() and int(info.get("by", -1)) == other.id,
		"a blow by another walker names them in the info"
	)
	K.check(
		fails,
		str(info.get("crew", "")) == "",
		"and calls no crew (a punch down by the hero would call the police)"
	)
	info = tr.call("hit_walker", w.id, p.position, push, 1.0, "punch", 0.0, other.id)
	K.check(
		fails,
		bool(info.get("down", false)) and str(info.get("crew", "")) == "",
		"even their knock-down calls no crew on the hero"
	)
	K.check(fails, streak.size() == n0, "someone else's blows never feed the assault streak")
	K.check(
		fails,
		int(info.get("by", TF.BY_HERO)) != TF.BY_HERO,
		"and a walker's blow never names the hero (BY_HERO is the hero's alone)"
	)
	var own: Dictionary = tr.call("hit_walker", other.id, p.position, push, 1.0, "punch")
	K.check(
		fails,
		not own.is_empty() and int(own.get("by", -2)) == TF.BY_HERO,
		"the hero's own knock-down names the hero (%s)" % str(own.get("by", "?"))
	)
	K.check(
		fails, streak.size() == n0 + 1, "the hero's own does (fp_carjack sees it call the police)"
	)
	(tr.get("walkers") as WK).remove(w)
	(tr.get("walkers") as WK).remove(other)


func _check_fight_back() -> void:
	_heal()
	_quiet()
	var react: RefCounted = tr.get("reactions")
	react.set("fight_odds", {"punch": 1.0, "shove": 1.0})
	var p := ctx.player
	var w := _stranger(1.0)
	react.set("fight_temper", {w.id: 0})  # plain (fight_tempers): jabs, as the checks expect
	var push := p.body_forward() * (1.5 * WS.M)
	var info: Dictionary = tr.call("hit_walker", w.id, p.position, push, 0.45, "punch")
	K.check(fails, not info.is_empty() and not bool(info["down"]), "a jab makes them reel")
	var fought := false
	var jabbed := false
	var t := 0.0
	while t < 8.0 and not (fought and jabbed and _count("punch") >= 2):
		_step(0.05)
		t += 0.05
		fought = fought or bool(react.call("fighting", w))
		jabbed = jabbed or w.react == &"punch_jab"
	K.check(fails, fought and jabbed, "with fight_back they square up and throw jabs")
	var landed := int(react.get("punches_landed"))
	var hurt := _count("punch")
	K.check(fails, landed >= 2 and hurt == landed, "their punches land and hurt (%d)" % landed)
	K.check(fails, not bool(f.call("knocked")), "the hero flinches on their feet (%.0f)" % _hp())
	act.call("set_guard", true)
	t = 0.0
	while t < 6.0 and _count("punch") < hurt + 1:
		_step(0.05)
		t += 0.05
	var got := _last("punch")
	var cost := float(got[0]) if _count("punch") > hurt else -1.0
	K.check(fails, cost > 0.0 and cost < 4.0, "the guard up takes most of a punch (%.1f)" % cost)
	act.call("set_guard", false)
	ctx.bus.hero_hit.emit(p.position, "car", 0.3, Vector3.ZERO)
	_step(1.0)
	K.check(fails, not bool(react.call("fighting", w)), "once the hero is down they let it be")
	(tr.get("walkers") as WK).remove(w)
	FeatureFlags.set_override("fight_back", false)
	_heal()
	var calm := _stranger(1.0)
	tr.call("hit_walker", calm.id, p.position, push, 0.45, "punch")
	var any := false
	for _k in range(80):
		_step(0.05)
		any = any or bool(react.call("fighting", calm))
	K.check(fails, not any and _count("punch") == 0, "with fight_back off nobody fights back")
	FeatureFlags.set_override("fight_back", true)
	(tr.get("walkers") as WK).remove(calm)
	react.set("fight_odds", {"punch": 0.4, "shove": 0.3})


func _check_run_down() -> void:
	_heal()
	_quiet()
	var lanes := _east_lanes()
	if lanes.size() < 3:
		return
	var vh: VH = tr.get("vehicles")
	var p := ctx.player
	# 4 m ahead of a car at 12 m/s (its whole body on the middle tile), which needs 9 m to stop at
	# full braking.
	var c := _car_at(lanes[1], 0.3, lanes.slice(2), 12.0)
	var dir := _hero_ahead(c, 4.0)
	hurts.clear()
	var start := p.position
	var before := INF
	var after := INF
	for _k in range(int(4.0 / DT)):
		_step(DT)
		if _count("car") == 0:
			before = minf(before, _gap(c, p.position))
		else:
			after = minf(after, _gap(c, p.position))
	var got := _last("car")
	var cost := float(got[0]) if not got.is_empty() else 0.0
	K.check(
		fails,
		not got.is_empty() and bool(got[3]),
		"a car 4 m off at 43 km/h cannot stop and runs the hero down (%s)" % str(got)
	)
	K.check(fails, cost > 45.0 and cost < 85.0, "hard, though it braked: %.0f" % cost)
	K.check(fails, before >= WS.PLAYER_RADIUS * 0.9, "it comes up to the body, not into it")
	var thrown := (p.position - start).dot(dir) / WS.M
	K.check(fails, thrown > 3.0, "the hero is thrown %.1f m on along the road" % thrown)
	var stopped := c.v < 0.05 * WS.M
	K.check(
		fails, stopped and after > 0.0, "it brakes to a stop behind them (%.2f m)" % (after / WS.M)
	)
	vh.remove(c)
	FeatureFlags.set_override("hit_by_cars", false)
	_check_stops_short(lanes, 4.0, "with hit_by_cars off the same car stops short")
	FeatureFlags.set_override("hit_by_cars", true)
	_check_stops_short(lanes, 30.0, "a car with room to stop does, short of the hero")


## A car at 12 m/s with the hero metres ahead stops without touching them.
func _check_stops_short(lanes: Array, metres: float, what: String) -> void:
	_heal()
	_quiet()
	var c := _car_at(lanes[1], 0.3, lanes.slice(2), 12.0)
	_hero_ahead(c, metres)
	hurts.clear()
	var closest := INF
	for _k in range(int(12.0 / DT)):
		_step(DT)
		closest = minf(closest, _gap(c, ctx.player.position))
	var ok := _count("car") == 0 and c.v < 0.05 * WS.M and closest >= WS.PLAYER_RADIUS
	var got := [closest / WS.M, c.v / WS.M, _count("car")]
	K.check(fails, ok, "%s (closest %.2f m, %.2f m/s, %d hits)" % ([what] + got))
	(tr.get("vehicles") as VH).remove(c)


func _check_teardown() -> void:
	_heal()
	var p := ctx.player
	ctx.bus.hero_hit.emit(p.position, "car", 0.5, Vector3.ZERO)
	_step(0.5)
	var arc := ctx.hud.slot("minimap_slot").get_node_or_null("HealthArc")
	var screen := ctx.hud.slot("overlay").get_node_or_null("HealthScreen")
	f.teardown()
	var up := p.input_enabled and not bool(f.call("knocked")) and str(rig.call("state")) == "loco"
	K.check(fails, up, "teardown puts the hero on their feet, input back")
	var gone := arc.is_queued_for_deletion() and screen.is_queued_for_deletion()
	K.check(fails, gone, "and takes the arc and the screen away")
	hurts.clear()
	ctx.bus.hero_hit.emit(p.position, "punch", 1.0, Vector3.ZERO)
	ctx.bus.car_impact.emit(p.position, 30.0 * WS.M, "wall")
	K.check(fails, hurts.is_empty(), "and hears of no more blows")
