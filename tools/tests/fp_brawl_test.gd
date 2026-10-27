extends SceneTree
## Brawl (integration feature "brawl"; docs/fp/ARCHITECTURE.md, Brawl): grabbing the person in
## front (held in the hands, the clip stopped, the hero slowed to a drag), dragging them along,
## punches landing on someone held (they hang on until the hook floors them), throwing them (R;
## with hit_feel up on an arc and tipped back), letting go and breaking free, the hold ending in a
## car; counters (the counters flag): the cue as a fighter's punch starts, the guard raised in time
## countering it (the punch misses, the hook floors them), a guard held up since earlier only
## blocking, and the flag off; the counter window reading (counter_cues): the wind-up holding back
## then snapping with the blow's own timing kept, the cue growing through the wind-up and fading
## once the blow has landed, and the flag off; the crowd gasp (crowd_gasp): a knock-down rocking
## the onlookers who stay back as one, once per crowd, and the flag off; teardown. Third person
## on a grown city; time runs
## through traffic's step, the features' tick(1/60) and the player's simulate and update_view.

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
var _grip_bones: Dictionary = {}


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
	ctx.bus.hero_threatened.connect(func(_at: Vector3, _s: float, _w: int) -> void: threats += 1)
	ctx.player.input_enabled = true
	_check_setup()
	await _check_grab()
	_check_punch_held()
	await _check_throw()
	_check_throw_impact()
	_check_let_go()
	_check_counter()
	_check_guard_held()
	_check_counters_off()
	_check_cue_window()
	_check_gasp()
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


## Someone fighting the hero, metres ahead: a jab makes them fight back (fight_odds 1, plain
## temper: the counter and cue checks ride the jab's timing).
func _fighter(metres: float) -> WK.Walker:
	react.set("fight_odds", {"punch": 1.0, "shove": 1.0})
	var w := _stranger(metres)
	react.set("fight_temper", {w.id: 0})
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
	K.check(fails, gap > 0.52, "their bodies clear each other (feet %.2f m apart)" % gap)
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
	var limbs: RefCounted = rig.get("limbs")
	var iks: Array = limbs.get("iks")
	for i in 2:
		(iks[i] as TwoBoneIK3D).modification_processed.connect(
			_capture_arm.bind("Left" if i == 0 else "Right")
		)
	for _k in 3:
		_step(DT)
		await process_frame
	var ends: Array = limbs.get("ends")
	var targets: Array = limbs.get("targets")
	var sk: Skeleton3D = rig.get("skeleton")
	var fwd := p.body_forward()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	var ok := true
	var msg := ""
	for i in 2:
		var s := -1.0 if i == 0 else 1.0
		var side := "Left" if i == 0 else "Right"
		var arm := _feet(w) - fwd * 0.08 * WS.M + Vector3.UP * 1.3 * WS.M + right * s * 0.19 * WS.M
		var hand: Vector3 = ends[i]
		var off := (hand - arm).length() / WS.M
		var on_side := (hand - p.position).dot(right) * s > (_feet(w) - p.position).dot(right) * s
		var shoulder_i := sk.find_bone(side + "UpperArm")
		var elbow_i := sk.find_bone(side + "LowerArm")
		var hand_i := sk.find_bone(side + "Hand")
		var chain_len := (
			sk.get_bone_global_rest(shoulder_i).origin.distance_to(
				sk.get_bone_global_rest(elbow_i).origin
			)
			+ sk.get_bone_global_rest(elbow_i).origin.distance_to(
				sk.get_bone_global_rest(hand_i).origin
			)
		)
		var shoulder: Vector3 = _grip_bones[side + "UpperArm"]
		var elbow: Vector3 = _grip_bones[side + "LowerArm"]
		hand = _grip_bones[side + "Hand"]
		var reach_ratio := (
			shoulder.distance_to((targets[i] as Marker3D).global_position)
			/ (chain_len * sk.global_basis.y.length())
		)
		var bend := 180.0 - rad_to_deg((shoulder - elbow).angle_to(hand - elbow))
		ok = ok and off < 0.2 and on_side and reach_ratio < 0.85 and bend > 25.0
		msg += " %s hand %.2f m from their arm;" % ["left" if i == 0 else "right", off]
		msg += " arm uses %.0f%% of full reach;" % (reach_ratio * 100.0)
		msg += " elbow bends %.0f deg;" % bend
	for i in 2:
		(iks[i] as TwoBoneIK3D).modification_processed.disconnect(
			_capture_arm.bind("Left" if i == 0 else "Right")
		)
	K.check(fails, ok, "both hands hold them by the arms with bent elbows (%s)" % msg)
	var people: Variant = tr.get("people")
	var hero_head: Vector3 = rig.call("bone_world", "Head")
	var walker_head: Vector3 = people.call("head_of", w, _feet(w))
	var head_gap := hero_head.distance_to(walker_head) / WS.M
	K.check(fails, head_gap > 0.4, "their heads stay apart (%.2f m)" % head_gap)


func _capture_arm(side: String) -> void:
	var rig: RefCounted = ctx.player.avatar.get("rig")
	var sk: Skeleton3D = rig.get("skeleton")
	for suffix: String in ["UpperArm", "LowerArm", "Hand"]:
		var bone := side + suffix
		_grip_bones[bone] = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(bone)).origin


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
	var draw_error := 0.0
	var drawn_frames := 0
	var people: RefCounted = tr.get("people")
	people.set("blocking", true)
	for k in range(90):
		_step(DT)
		tr.call("sync_visuals", DT)
		await process_frame
		if w.body != null:
			var expected := WK.body_xf(w, float(people.call("scale_of", w)), _feet(w))
			var drawn: Node3D = w.body.get("root")
			draw_error = maxf(
				draw_error, drawn.transform.origin.distance_to(expected.origin) / WS.M
			)
			drawn_frames += 1
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
	K.check(
		fails,
		drawn_frames > 60 and draw_error < 0.001,
		(
			"drawn body follows the simulated throw without lag (%d frames, %.4f m error)"
			% [drawn_frames, draw_error]
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


## A wall 1.5 m along the throw, thin and 3 m tall (the flight meets its face, 0.39 m of reach
## short of the plane).
func _impact_wall(feet: Vector3, run: Vector3, metres: float) -> AABB:
	var across := Vector3(absf(run.z), 0.0, absf(run.x))
	var c := feet + run * ((metres + 0.1) * WS.M) + Vector3.UP * (1.5 * WS.M)
	var size := across * (3.0 * WS.M) + Vector3(absf(run.x), 0.0, absf(run.z)) * (0.2 * WS.M)
	size.y = 3.0 * WS.M
	return AABB(c - size * 0.5, size)


func _check_throw_impact() -> void:
	# The throw's clear arc runs 3 m; a wall 1.5 m along it is met still on the arc (throw_impact).
	_fresh()
	var p := ctx.player
	var w := _stranger(0.9)
	f.call("grab")
	_step(0.4)
	var before := _feet(w)
	var aim := Vector3(-sin(p.cam_yaw), 0.0, -cos(p.cam_yaw))
	var hits: Array = []
	var on_hit := func(_at: Vector3, _cause: String, info: Dictionary) -> void: hits.append(info)
	ctx.bus.person_hit.connect(on_hit)
	ctx.collision.add_test_box(_impact_wall(before, aim, 1.5))
	K.check(fails, bool(act.call("strike", "shove")), "R with someone held throws toward the wall")
	var peak := 0.0
	for k in range(150):
		_step(DT)
		peak = maxf(peak, _air(w))
	ctx.collision.clear_test_boxes()
	ctx.bus.person_hit.disconnect(on_hit)
	var flung := (_feet(w) - before).dot(aim) / WS.M
	K.check(fails, bool(react.call("is_down", w)), "they go down out of the throw")
	K.check(
		fails,
		flung > 0.05 and flung < 0.65,
		"the wall stops the throw short, back off the face (%.2f m of a 3 m arc)" % flung
	)
	K.check(
		fails,
		peak > 0.3 and peak < 1.2,
		"and it meets the wall still on the arc (peak %.2f m)" % peak
	)
	K.check(fails, hits.size() == 1, "the throw emits its one person_hit (%d)" % hits.size())
	var impact := {}
	if hits.size() == 1:
		impact = hits[0].get("impact", {})
	K.check(
		fails,
		impact.has("at") and impact.has("in"),
		"marked with the predicted impact on that one emission (never a second)"
	)
	if impact.has("at") and impact.has("in"):
		var at: Vector3 = impact["at"]
		# The prediction should land where the flight truly met the wall: the observed stop is
		# the rest point plus the rebound back off the face.
		var gap := _flat(at, before + aim * ((flung + 0.35) * WS.M)) / WS.M
		var secs := float(impact["in"])
		K.check(fails, gap < 0.3, "predicted where the flight truly struck (%.2f m off)" % gap)
		K.check(fails, secs > 0.15 and secs < 0.8, "%.2f s into the flight" % secs)
	# Off: the flight stops dead at the face as before, nothing marked.
	FeatureFlags.set_override("throw_impact", false)
	_fresh()
	w = _stranger(0.9)
	f.call("grab")
	_step(0.4)
	before = _feet(w)
	hits.clear()
	ctx.bus.person_hit.connect(on_hit)
	ctx.collision.add_test_box(_impact_wall(before, aim, 1.5))
	act.call("strike", "shove")
	_step(2.5)
	ctx.collision.clear_test_boxes()
	ctx.bus.person_hit.disconnect(on_hit)
	FeatureFlags.set_override("throw_impact", true)
	var dead := (_feet(w) - before).dot(aim) / WS.M
	K.check(
		fails,
		bool(react.call("is_down", w)) and dead > 0.5 and dead < 1.05,
		"flag off: the flight stops dead at the face (%.2f m), no rebound" % dead
	)
	var marked := false
	for info in hits:
		marked = marked or info.has("impact")
	K.check(fails, not marked, "flag off: nothing is marked")


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


## The contact time (s) of the punch w is throwing.
func _contact(w: WK.Walker) -> float:
	for spec: Array in RE.FIGHT_BLOWS:
		if spec[0] == w.react:
			return float(spec[1])
	return 0.2


## The counter window reads (counter_cues): a punch holds its wind-up back through the first
## half of the run to contact, then snaps, the blow's own clock untouched; the cue grows through
## the wind-up and fades once the blow has landed, and with the flag off both keep their plain
## old look.
func _check_cue_window() -> void:
	_fresh()
	FeatureFlags.set_override("counter_cues", true)
	# The wind-up: the clip holds back, snaps in, and the blow lands on its own clock.
	var w := _fighter(1.0)
	K.check(fails, _until_punch(w, 8.0), "fixture: they throw a punch")
	K.check(
		fails,
		is_equal_approx(w.react_rate, RE.WIND_RATE),
		"the wind-up holds its clip back (%.2fx)" % w.react_rate
	)
	var people: RefCounted = tr.get("people")
	var head: Vector3 = (
		(people.call("head_of", w, w.pos + w.vis_off) as Vector3) + Vector3.UP * BRAWL.CUE_HEAD
	)
	K.check(
		fails,
		(f.get("cue_at") as Vector3).distance_to(head) < 0.05 * WS.M,
		"the cue anchors over the attacker's head"
	)
	var contact := _contact(w)
	_step(contact * 0.5 + 4.0 * DT)
	K.check(
		fails,
		is_equal_approx(w.react_rate, 2.0 - RE.WIND_RATE),
		"the strike snaps in (%.2fx)" % w.react_rate
	)
	_step(contact * 0.5 - 2.0 * DT)
	K.check(fails, w.react_rate == 1.0, "and the clip runs free again past the landing")
	K.check(fails, _hurt("punch") >= 1, "the blow still lands on its own clock")
	(tr.get("walkers") as WK).remove(w)
	# The cue, watched through the window of a blow landing in 0.29 s.
	var cue: Label = f.get("cue")
	f.call("_on_threatened", ctx.player.position, 0.29, -1)
	f.call("tick", 0.0)
	K.check(
		fails,
		cue.visible and cue.get_theme_font_size("font_size") <= 27 and cue.modulate.a > 0.99,
		"the cue opens small (%d px)" % cue.get_theme_font_size("font_size")
	)
	f.call("tick", 0.2)
	K.check(
		fails,
		cue.get_theme_font_size("font_size") > 30 and cue.modulate.a > 0.99,
		"grows through the wind-up (%d px)" % cue.get_theme_font_size("font_size")
	)
	f.call("tick", 0.085)
	K.check(
		fails,
		cue.get_theme_font_size("font_size") >= 39,
		"reaching full size as the blow closes (%d px)" % cue.get_theme_font_size("font_size")
	)
	f.call("tick", 0.08)
	var a := cue.modulate.a
	K.check(
		fails,
		cue.get_theme_font_size("font_size") == 26 and absf(a - 0.5) < 0.03,
		"fades after the landing (26 px, %.2f)" % a
	)
	f.call("tick", 0.1)
	K.check(fails, not cue.visible, "and goes")
	# The mark rides over the threat in the world, not parked at screen centre.
	var cam: Camera3D = ctx.player.camera
	f.call("_on_threatened", ctx.player.position, 0.4, -1)
	f.call("tick", 0.0)
	var at := Vector2(cue.position + cue.size * 0.5)
	var want := cam.unproject_position(ctx.player.position + Vector3.UP * BRAWL.CUE_LIFT)
	K.check(
		fails,
		cue.visible and at.distance_to(want) < 40.0,
		"the cue rides over the threat (%.0f px off)" % at.distance_to(want)
	)
	f.call("_on_threatened", ctx.player.position + ctx.player.body_forward() * WS.M, 0.6, -1)
	f.call("tick", 0.0)
	var moved := Vector2(cue.position + cue.size * 0.5)
	K.check(
		fails,
		moved.distance_to(at) > 20.0,
		"and follows it across the world (%.0f px)" % moved.distance_to(at)
	)
	var fade := BRAWL.cue_look(0.075, 0.29)
	K.check(
		fails,
		(
			is_equal_approx(BRAWL.cue_look(0.44, 0.29).x, 26.0)
			and BRAWL.cue_look(0.155, 0.29).x >= 39.0
			and is_equal_approx(fade.x, 26.0)
			and is_equal_approx(fade.y, 0.5)
		),
		"cue_look keeps the window's phases (26 to 40 px, the tail fading)"
	)
	# The flag off: the plain mark of before.
	FeatureFlags.set_override("counter_cues", false)
	f.call("_on_threatened", ctx.player.position, 0.29, -1)
	f.call("tick", 0.0)
	K.check(
		fails,
		cue.get_theme_font_size("font_size") == 34 and cue.modulate.a == 1.0,
		"counter_cues off keeps the plain mark (34 px, full)"
	)
	FeatureFlags.set_override("counter_cues", true)
	f.call("tick", 0.5)


## The crowd gasps (crowd_gasp): a knock-down in view rocks the onlookers who stay back as one
## (no beat of looking first, a sharp backward tip); the next body to fall right there gets the
## plain reaction (once per crowd); and nothing of it with the flag off.
func _check_gasp() -> void:
	_fresh()
	FeatureFlags.set_override("crowd_gasp", true)
	var rocked := _gaspers([2.0, 2.4, 2.8, 3.2])
	K.check(
		fails, rocked[0] > 0 and rocked[1] == 0, "the street gasps: %d rock back as one" % rocked[0]
	)
	var again := _gaspers([2.1, 2.5, 2.9])
	K.check(
		fails,
		again[0] == 0 and again[1] > 0,
		"one gasp per crowd: the next body there gets the plain reaction"
	)
	_fresh()
	FeatureFlags.set_override("crowd_gasp", false)
	var off := _gaspers([2.0, 2.4, 2.8])
	K.check(fails, off[0] == 0 and off[1] > 0, "no gasp with the flag off")
	FeatureFlags.reload()


## Downs a passer-by in front of the hero with bystanders standing at the given metres out, and
## counts the ones who stay: [how many rock back at once (the gasp), how many take the plain
## beat first]. Runners are neither.
func _gaspers(metres: Array) -> Array:
	var bys: Array = []
	for m: float in metres:
		bys.append(_stranger(m))
	var v := _stranger(1.2)
	var push := ctx.player.body_forward() * WS.M
	tr.call("hit_walker", v.id, ctx.player.position, push, 1.0, "punch")
	var rocked := 0
	var plain := 0
	for b: WK.Walker in bys:
		var r: RE.Reaction = (react.get("_active") as Dictionary).get(b.id, null)
		if r == null or r.steps.is_empty() or str(r.steps[0][0]) != "place":
			continue
		if r.tip > 0.0 and r.delay == 0.0:
			rocked += 1
		else:
			plain += 1
	return [rocked, plain]


func _check_teardown() -> void:
	_fresh()
	var w := _stranger(0.9)
	f.call("grab")
	_step(0.2)
	var cue: Control = f.get("cue")
	f.teardown()
	var gone := not bool(react.call("held", w)) and ctx.player.speed_cap == INF
	K.check(fails, gone and cue.is_queued_for_deletion(), "teardown lets go and takes the cue away")
	ctx.bus.hero_threatened.emit(ctx.player.position, 0.3, -1)
	K.check(fails, f.get("cue") == null, "and hears no more threats")
