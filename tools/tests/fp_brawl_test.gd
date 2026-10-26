extends SceneTree
## Brawl (integration feature "brawl"; docs/fp/ARCHITECTURE.md, Brawl): grabbing the person in
## front (held in the hands, the clip stopped, the hero slowed to a drag), dragging them along,
## punches landing on someone held (they hang on until the hook floors them), throwing them (R;
## with hit_feel up on an arc and tipped back), letting go and breaking free, the hold ending in a
## car; counters (the counters flag): the cue as a fighter's punch starts, the guard raised in time
## countering it (the punch misses, the hook floors them), a guard held up since earlier only
## blocking, and the flag off; teardown. Third person on a grown city; time runs through traffic's
## step, the features' tick(1/60) and the player's simulate and update_view.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const BRAWL := preload("res://scripts/fp/brawl/brawl_feature.gd")
const ACTIONS := preload("res://scripts/fp/actions/actions_feature.gd")
const DT := 1.0 / 60.0

## The hold's gap (feet to feet, metres).
const HOLD_M := BRAWL.HOLD_GAP / WS.M

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var act: FpFeature
var hp: FpFeature
var f: FpFeature
var react: RefCounted
## [amount, cause] of every hero_hurt; how many hero_threatened.
var hurts: Array = []
var threats: int = 0


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	tr = K.make_feature(ctx, "traffic")
	act = K.make_feature(ctx, "actions")
	hp = K.make_feature(ctx, "health")
	f = K.make_feature(ctx, "brawl")
	if tr == null or act == null or hp == null or f == null:
		K.check(fails, false, "the traffic, actions, health and brawl features are registered")
		K.finish(self, "FP_BRAWL_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	for n: Node in [act, hp, f]:
		n.set_process(false)
	react = tr.get("reactions")
	ctx.bus.hero_hurt.connect(
		func(a: float, cause: String, _h: float, _d: bool) -> void: hurts.append([a, cause])
	)
	ctx.bus.hero_threatened.connect(func(_at: Vector3, _s: float) -> void: threats += 1)
	ctx.player.input_enabled = true
	_check_setup()
	await _check_grab()
	_check_punch_held()
	_check_throw()
	_check_let_go()
	_check_counter()
	_check_guard_held()
	_check_counters_off()
	_check_teardown()
	K.finish(self, "FP_BRAWL_TEST", fails)


# ------------------------------------------------------------------ helpers


## Runs the street for secs: traffic, the actions, health, brawl, then the player moving by wish.
func _step(secs: float, wish := Vector2.ZERO, sprint := false) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		tr.call("step", DT)
		act.call("tick", DT)
		hp.call("tick", DT)
		f.call("tick", DT)
		ctx.player.simulate(wish, sprint, DT)
		ctx.player.update_view(DT)


## A fresh scene: nobody about, a full bar, the hero in control where they stand, nothing held.
func _fresh() -> void:
	f.call("release")
	act.call("cancel")
	_quiet()
	hp.call("from_dict", {"hp": 100.0})
	var p := ctx.player
	p.input_enabled = true
	p.teleport(p.position, rad_to_deg(p.yaw))
	_step(0.1)
	hurts.clear()
	threats = 0


## Nobody walking, no trips to start and only the parked cars left.
func _quiet() -> void:
	K.quiet_walkers(tr)
	var trips: RefCounted = tr.get("trips")
	trips.trips.clear()
	trips.standing.clear()
	var vh: VH = tr.get("vehicles")
	var moving := vh.cars.filter(func(c: VH.Car) -> bool: return not c.parked)
	for c: VH.Car in moving:
		vh.remove(c)


## A passer-by standing metres ahead of the hero, turned to them.
func _stranger(metres: float) -> WK.Walker:
	return K.person_ahead(ctx, tr, metres)


func _feet(w: WK.Walker) -> Vector3:
	return w.pos + w.vis_off


## How high w's drawn feet are off the ground under them (m).
func _air(w: WK.Walker) -> float:
	var q := _feet(w)
	var g := ctx.collision.walk_height(q)
	return (q.y - (w.pos.y if is_nan(g) else g)) / WS.M


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _hurt(cause: String) -> int:
	return hurts.filter(func(h: Array) -> bool: return str(h[1]) == cause).size()


## Someone fighting the hero, metres ahead: a jab makes them fight back (fight_odds 1).
func _fighter(metres: float) -> WK.Walker:
	react.set("fight_odds", {"punch": 1.0, "shove": 1.0})
	var w := _stranger(metres)
	var push := ctx.player.body_forward() * WS.M
	tr.call("hit_walker", w.id, ctx.player.position, push, 0.45, "punch")
	return w


## Steps until w starts a punch (at most secs); true once it has.
func _until_punch(w: WK.Walker, secs: float) -> bool:
	var t := 0.0
	while t < secs:
		_step(DT)
		t += DT
		if w.react in [&"punch_jab", &"punch_cross"] and bool(react.call("fighting", w)):
			return true
	return false


# ------------------------------------------------------------------ checks


func _check_setup() -> void:
	var st := f.self_test()
	K.check(fails, bool(st.get("ok", false)), "self_test (%s)" % st.get("detail", ""))
	var cue := ctx.hud.slot("center").get_node_or_null("CounterCue")
	K.check(fails, cue != null and not (cue as Control).visible, "the counter cue waits, hidden")


func _check_grab() -> void:
	_fresh()
	var p := ctx.player
	K.check(fails, not bool(f.call("grab")), "nobody in front: nothing to grab")
	var w := _stranger(0.9)
	K.check(fails, bool(f.call("grab")), "the person in front is grabbed")
	var held := bool(react.call("held", w)) and int(f.get("held_id")) == w.id
	K.check(fails, held and is_equal_approx(p.speed_cap, BRAWL.DRAG_SPEED), "held; the hero drags")
	_step(0.5)
	var gap := _flat(_feet(w), p.position) / WS.M
	var still := w.react == RE.HOLD_CLIP and w.react_rate == 0.0
	K.check(
		fails,
		absf(gap - HOLD_M) < 0.08 and still,
		"in the hands, %.2f m ahead (%.2f)" % [HOLD_M, gap]
	)
	K.check(fails, gap > 0.6, "the two bodies clear each other (feet %.2f m apart)" % gap)
	await _check_grip(w)
	var forward := p.body_forward()
	var side := Vector3(forward.z, 0.0, -forward.x).normalized()
	var sway_min := INF
	var sway_max := -INF
	for _k in range(60):
		_step(DT)
		var lateral := (_feet(w) - p.position).dot(side)
		sway_min = minf(sway_min, lateral)
		sway_max = maxf(sway_max, lateral)
	K.check(
		fails,
		sway_max - sway_min > 0.2 * WS.M,
		"the held person sways visibly within a second (%.3f m)" % ((sway_max - sway_min) / WS.M)
	)
	var start := p.position
	var top := 0.0
	for _k in range(90):
		_step(DT, Vector2(0.0, 1.0), true)
		top = maxf(top, p.speed())
	var moved := _flat(p.position, start) / WS.M
	gap = _flat(_feet(w), p.position) / WS.M
	K.check(
		fails,
		top <= BRAWL.DRAG_SPEED + 1e-3 and moved > 0.8,
		"a sprint drags them at %.2f m/s at most (%.2f m)" % [top / WS.M, moved]
	)
	K.check(fails, absf(gap - HOLD_M) < 0.15, "and they come along (%.2f m ahead)" % gap)
	f.call("release")
	K.check(fails, not bool(react.call("held", w)) and p.speed_cap == INF, "let go: free again")
	f.call("_unhandled_input", K.action_event("act_grab"))
	K.check(fails, bool(react.call("held", w)), "H grabs")
	f.call("_unhandled_input", K.action_event("act_grab"))
	K.check(fails, not bool(react.call("held", w)), "H again lets go")


## Both of the hero's hands on the person held (each within reach of their arm on its own side)
## while their bodies stay apart.
func _check_grip(w: WK.Walker) -> void:
	var p := ctx.player
	var rig: Variant = p.avatar.get("rig") if p.avatar != null else null
	if not rig is RefCounted:
		return
	_step(DT)
	await process_frame
	var ends: Array = (rig as RefCounted).get("limbs").get("ends")
	var fwd := p.body_forward()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	var ok := true
	var msg := ""
	for i in 2:
		var s := -1.0 if i == 0 else 1.0
		var arm := _feet(w) - fwd * 0.08 * WS.M + Vector3.UP * 1.3 * WS.M + right * s * 0.19 * WS.M
		var hand: Vector3 = ends[i]
		var off := (hand - arm).length() / WS.M
		var on_side := (hand - p.position).dot(right) * s > (_feet(w) - p.position).dot(right) * s
		ok = ok and off < 0.2 and on_side
		msg += " %s hand %.2f m from their arm;" % ["left" if i == 0 else "right", off]
	K.check(fails, ok, "both hands hold them by the arms (%s)" % msg)


func _check_punch_held() -> void:
	_fresh()
	var w := _stranger(0.9)
	f.call("grab")
	_step(0.3)
	act.call("strike")
	_step(0.5)
	var hung := bool(react.call("held", w)) and not bool(react.call("is_down", w))
	K.check(fails, int(act.get("hits")) >= 1 and hung, "a jab lands on them and they hang on")
	act.call("strike")
	_step(0.55)
	K.check(fails, bool(react.call("held", w)), "so does a cross")
	_step(0.3)
	var gap := _flat(_feet(w), ctx.player.position) / WS.M
	K.check(fails, absf(gap - HOLD_M) < 0.1, "back in the hands after the reel (%.2f m)" % gap)
	act.call("strike")
	_step(0.8)
	var down := bool(react.call("is_down", w)) and not bool(react.call("held", w))
	K.check(fails, down and int(f.get("held_id")) == -1, "the hook floors them out of the hold")
	K.check(fails, ctx.player.speed_cap == INF, "and the hero is free to run")


func _check_throw() -> void:
	_fresh()
	var p := ctx.player
	var w := _stranger(0.9)
	f.call("grab")
	_step(0.4)
	var before := _feet(w)
	var aim := Vector3(-sin(p.cam_yaw), 0.0, -cos(p.cam_yaw))
	K.check(fails, bool(act.call("strike", "shove")), "R with someone held throws")
	K.check(fails, str(act.get("swing")) == "throw", "a throw (%s)" % act.get("swing"))
	var peak := 0.0
	var tip := 0.0
	var let_go := -1
	var sep0 := 0.0
	var sep10 := 0.0
	var tip10 := 0.0
	for k in range(90):
		_step(DT)
		peak = maxf(peak, _air(w))
		tip = minf(tip, w.vis_tilt)
		var sep := _flat(_feet(w), p.position) / WS.M
		if let_go < 0 and int(f.get("held_id")) == -1:
			let_go = k
			sep0 = sep
		if let_go >= 0 and k == let_go + 10:
			sep10 = sep
			tip10 = w.vis_tilt
	K.check(
		fails,
		let_go >= 0 and sep10 - sep0 > 0.3 and tip10 < -0.2,
		(
			"10 frames after the throw lets go they are %.2f m further off and tipping (%.2f rad)"
			% [sep10 - sep0, tip10]
		)
	)
	var flung := (_feet(w) - before).dot(aim) / WS.M
	var down := bool(react.call("is_down", w)) and int(f.get("held_id")) == -1
	K.check(fails, down, "they go down out of the hands")
	K.check(
		fails, flung > 1.8, "flung %.2f m along the camera (a punch slides 1.4 at most)" % flung
	)
	if FeatureFlags.enabled("hit_feel"):
		var arc := peak > 0.6 and tip < -0.5 and w.vis_tilt == 0.0 and absf(_air(w)) < 0.005
		K.check(
			fails,
			arc,
			"up on an arc (%.2f m), tipped back (%.2f rad), down again flat" % [peak, tip]
		)


func _check_let_go() -> void:
	_fresh()
	var w := _stranger(0.9)
	f.call("grab")
	_step(RE.HOLD_S + 0.3)
	var free := not bool(react.call("held", w)) and int(f.get("held_id")) == -1
	K.check(fails, free and ctx.player.speed_cap == INF, "after %.0f s they break free" % RE.HOLD_S)
	K.check(fails, w.react != RE.HOLD_CLIP or w.react_rate == 1.0, "and move again")
	(tr.get("walkers") as WK).remove(w)
	var other := _stranger(0.9)
	f.call("grab")
	ctx.bus.drive_changed.emit(true)
	K.check(fails, not bool(react.call("held", other)), "getting into a car lets go")
	ctx.bus.drive_changed.emit(false)
	f.call("grab")
	_step(0.2)
	ctx.player.input_enabled = false
	_step(0.1)
	K.check(fails, not bool(react.call("held", other)), "so does losing control (knocked down)")
	ctx.player.input_enabled = true


func _check_counter() -> void:
	_fresh()
	var w := _fighter(1.0)
	var punch := _until_punch(w, 8.0)
	K.check(fails, punch, "fixture: they square up and throw a punch")
	if not punch:
		return
	f.call("tick", 0.0)
	var cue: Control = f.get("cue")
	K.check(fails, threats >= 1 and cue.visible, "the punch starts: the cue flashes (%d)" % threats)
	act.call("set_guard", true)
	_step(0.6)
	var countered := int(act.get("counters")) == 1 and int(react.get("punches_parried")) == 1
	K.check(fails, countered and _hurt("punch") == 0, "the guard just in time counters it")
	K.check(fails, bool(react.call("is_down", w)), "the counter hook floors them")
	_step(0.4)
	K.check(fails, not cue.visible, "the cue goes")
	act.call("set_guard", false)
	_step(0.1)


func _check_guard_held() -> void:
	_fresh()
	var w := _fighter(1.0)
	act.call("set_guard", true)
	var counters := int(act.get("counters"))
	var t := 0.0
	while t < 8.0 and _hurt("punch") == 0:
		_step(0.05)
		t += 0.05
	var blocked := _hurt("punch") >= 1 and float(hurts[0][0]) < 4.0
	K.check(fails, blocked, "a guard up since earlier only blocks (%s)" % str(hurts))
	K.check(fails, int(act.get("counters")) == counters, "no counter")
	act.call("set_guard", false)
	(tr.get("walkers") as WK).remove(w)


func _check_counters_off() -> void:
	_fresh()
	FeatureFlags.set_override("counters", false)
	var w := _fighter(1.0)
	var counters := int(act.get("counters"))
	if _until_punch(w, 8.0):
		act.call("set_guard", true)
		_step(0.6)
	var landed := _hurt("punch") >= 1 and int(act.get("counters")) == counters
	K.check(fails, landed and threats >= 1, "with counters off the punch lands on the guard")
	K.check(fails, not (f.get("cue") as Control).visible, "and no cue shows")
	FeatureFlags.set_override("counters", true)
	act.call("set_guard", false)
	react.set("fight_odds", RE.FIGHT_ODDS.duplicate())
	(tr.get("walkers") as WK).remove(w)


func _check_teardown() -> void:
	_fresh()
	var w := _stranger(0.9)
	f.call("grab")
	_step(0.2)
	var cue: Control = f.get("cue")
	f.teardown()
	var gone := not bool(react.call("held", w)) and ctx.player.speed_cap == INF
	K.check(fails, gone and cue.is_queued_for_deletion(), "teardown lets go and takes the cue away")
	ctx.bus.hero_threatened.emit(ctx.player.position, 0.3)
	K.check(fails, f.get("cue") == null, "and hears no more threats")
