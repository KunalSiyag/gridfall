extends SceneTree
## Hit feel (integration feature "hit_feel"; docs/fp/ARCHITECTURE.md, Hit feel): a punch that
## lands stops the world for a moment (Engine.time_scale) and shakes the camera, a harder blow
## and a knock-down for longer; the stop runs out in real seconds; a blow on the hero and a crash
## shake the camera, a fall or a crash does not stop it; nothing stops in photo mode; someone
## kicked down is thrown up, lands and bounces (and stays on the ground with the flag off);
## teardown gives the time scale back.
## Third person on a grown city; time runs through the features' tick(1/60), traffic's step and
## the player's update_view.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const HF := preload("res://scripts/fp/hitfeel/hitfeel_feature.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var act: FpFeature
var hf: FpFeature
var hits: Array = []


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	tr = K.make_feature(ctx, "traffic")
	act = K.make_feature(ctx, "actions")
	hf = K.make_feature(ctx, "hit_feel")
	if tr == null or act == null or hf == null:
		K.check(fails, false, "the traffic, actions and hit_feel features are registered")
		K.finish(self, "FP_HITFEEL_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	act.set_process(false)
	hf.set_process(false)
	_quiet()
	ctx.bus.person_hit.connect(
		func(_at: Vector3, cause: String, info: Dictionary) -> void: hits.append([cause, info])
	)
	var p := ctx.player
	p.teleport(p.position, rad_to_deg(p.yaw))
	_check_punch()
	_check_strength()
	_check_hero_hurt()
	_check_crash()
	_check_photo_mode()
	_check_throw()
	_check_throw_off()
	_check_teardown()
	Engine.time_scale = 1.0
	K.finish(self, "FP_HITFEEL_TEST", fails)


# ------------------------------------------------------------------ helpers


## Steps the actions feature, traffic and the player (not the hit-stop clock: that is real time).
func _step(secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		act.call("tick", DT)
		tr.call("step", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)


## Runs the hit-stop clock on by real seconds.
func _real(secs: float) -> void:
	hf.call("tick", secs)


func _quiet() -> void:
	K.quiet_walkers(tr)


## Someone standing dist_m metres ahead of the hero, facing them.
func _person(dist_m: float) -> WK.Walker:
	return K.person_ahead(ctx, tr, dist_m)


func _remove(w: WK.Walker) -> void:
	(tr.get("walkers") as WK).remove(w)


## Waits for the stop and the shake to be over.
func _settle() -> void:
	_real(1.0)
	_step(1.5)


## How far w's drawn feet are above the ground under them (m).
func _air(w: WK.Walker) -> float:
	var q := w.pos + w.vis_off
	var g := ctx.collision.walk_height(q)
	return (q.y - (w.pos.y if is_nan(g) else g)) / WS.M


# ------------------------------------------------------------------ checks


## A jab that lands stops the world and shakes the camera; the stop runs out in real time.
func _check_punch() -> void:
	var w := _person(0.9)
	hits.clear()
	var s0 := int(hf.get("stops"))
	act.call("strike")
	for _k in range(60):
		_step(DT)
		if not hits.is_empty():
			break
	K.check(fails, not hits.is_empty(), "fixture: the jab lands")
	var stopped := bool(hf.call("stopped")) and is_equal_approx(Engine.time_scale, HF.STOP_SCALE)
	K.check(fails, stopped, "a blow that lands stops the world (scale %.2f)" % Engine.time_scale)
	K.check(fails, int(hf.get("stops")) == s0 + 1, "one stop per blow")
	K.check(fails, ctx.player.shake_amount() > 0.1, "and shakes the camera")
	var xf := ctx.player.camera.global_transform
	_step(0.1)
	var moved := not ctx.player.camera.global_transform.is_equal_approx(xf)
	K.check(fails, moved, "the shake moves the view")
	_real(0.03)
	K.check(fails, bool(hf.call("stopped")), "the stop holds a few hundredths of a second")
	_real(0.1)
	var back := not bool(hf.call("stopped")) and is_equal_approx(Engine.time_scale, 1.0)
	K.check(fails, back, "then time runs again (scale %.2f)" % Engine.time_scale)
	_step(1.5)
	K.check(fails, ctx.player.shake_amount() == 0.0, "the shake dies away")
	_remove(w)
	_settle()


## A harder blow stops longer and shakes more, a knock-down more again.
func _check_strength() -> void:
	var p := ctx.player
	var out := []
	for c: Array in [[0.3, false], [0.9, false], [0.9, true]]:
		ctx.bus.person_hit.emit(p.position, "punch", {"strength": c[0], "down": c[1]})
		out.append([float(hf.get("_stop_left")), p.shake_amount()])
		_settle()
	var ok: bool = out[0][0] < out[1][0] and out[1][0] < out[2][0]
	ok = ok and out[0][1] < out[1][1] and out[1][1] < out[2][1]
	print("FP_HITFEEL_TEST: [stop s, shake] by blow %s" % str(out))
	K.check(fails, ok, "harder blows and knock-downs stop longer and shake more (%s)" % str(out))
	K.check(fails, float(out[2][0]) <= HF.STOP_MAX, "never longer than STOP_MAX")


## A blow on the hero shakes the view and stops it; a fall shakes it without a stop.
func _check_hero_hurt() -> void:
	var p := ctx.player
	ctx.bus.hero_hurt.emit(12.0, "punch", 88.0, false)
	var ok := bool(hf.call("stopped")) and p.shake_amount() > 0.2
	K.check(fails, ok, "a punch on the hero stops and shakes (%.2f)" % p.shake_amount())
	_settle()
	ctx.bus.hero_hurt.emit(20.0, "fall", 68.0, false)
	ok = not bool(hf.call("stopped")) and p.shake_amount() > 0.2
	K.check(fails, ok, "a hard landing shakes without a stop")
	_settle()


## A crash shakes the view by its speed; a nudge does not.
func _check_crash() -> void:
	var p := ctx.player
	ctx.bus.car_impact.emit(p.position, 1.0 * WS.M, "wall")
	K.check(fails, p.shake_amount() == 0.0, "a nudge at 1 m/s does not shake")
	ctx.bus.hero_hurt.emit(10.0, "crash", 90.0, false)
	K.check(fails, p.shake_amount() == 0.0, "the crash's hurt leaves the shake to car_impact")
	ctx.bus.car_impact.emit(p.position, 6.0 * WS.M, "car")
	var low := p.shake_amount()
	_settle()
	ctx.bus.car_impact.emit(p.position, 16.0 * WS.M, "wall")
	var high := p.shake_amount()
	var ok := low > 0.0 and high > low and not bool(hf.call("stopped"))
	K.check(fails, ok, "a crash shakes, a harder one more (%.2f, %.2f)" % [low, high])
	_settle()


## Photo mode neither stops nor shakes.
func _check_photo_mode() -> void:
	var p := ctx.player
	p.photo_mode = true
	ctx.bus.person_hit.emit(p.position, "punch", {"strength": 1.0, "down": true})
	var ok := not bool(hf.call("stopped")) and p.shake_amount() == 0.0
	K.check(fails, ok, "nothing stops or shakes in photo mode")
	p.photo_mode = false


## A kick knocks someone down: they leave the ground, land and bounce, and lie on it.
func _check_throw() -> void:
	var w := _person(1.3)
	hits.clear()
	act.call("strike", "kick")
	var peak := 0.0
	var t := 0.0
	var landed_at := -1.0
	while t < 1.2:
		_step(DT)
		t += DT
		if hits.is_empty():
			continue
		var a := _air(w)
		peak = maxf(peak, a)
		if peak > 0.05 and a < 0.005 and landed_at < 0.0:
			landed_at = t
	var down := not hits.is_empty() and bool((hits[0][1] as Dictionary).get("down", false))
	print("FP_HITFEEL_TEST: throw peak=%.2f m, down again at %.2f s" % [peak, landed_at])
	K.check(fails, down, "fixture: the kick knocks them down")
	K.check(fails, peak > 0.1 and peak < 0.45, "the blow throws them up (%.2f m)" % peak)
	K.check(fails, landed_at > 0.0, "and they come back down")
	K.check(fails, absf(_air(w)) < 0.005, "and lie on the ground (%.3f m)" % _air(w))
	_remove(w)
	_settle()


## With the flag off a knock-down stays on the ground.
func _check_throw_off() -> void:
	FeatureFlags.set_override("hit_feel", false)
	var w := _person(1.3)
	hits.clear()
	act.call("strike", "kick")
	var peak := 0.0
	for _k in range(60):
		_step(DT)
		peak = maxf(peak, _air(w))
	FeatureFlags.set_override("hit_feel", true)
	K.check(fails, not hits.is_empty(), "fixture: the kick lands with the flag off")
	K.check(fails, peak < 0.005, "flag off: they fall where they stand (%.3f m)" % peak)
	_remove(w)
	_settle()


## Teardown in a stop gives the time scale back.
func _check_teardown() -> void:
	ctx.bus.person_hit.emit(ctx.player.position, "punch", {"strength": 1.0})
	hf.teardown()
	var ok := is_equal_approx(Engine.time_scale, 1.0) and not bool(hf.call("stopped"))
	K.check(fails, ok, "teardown gives the time scale back")
	var s0 := int(hf.get("stops"))
	ctx.bus.person_hit.emit(ctx.player.position, "punch", {"strength": 1.0})
	K.check(fails, int(hf.get("stops")) == s0, "and stops listening")
