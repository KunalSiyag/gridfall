extends SceneTree
## Body actions (integration feature "actions"; docs/fp/ARCHITECTURE.md, Body actions): the hero
## rig's action layer (strike times, the strike pose layer's turn into the blow, the guard,
## punches, the dance); the strike button punching whoever stands in front (the body turned to
## them, a press near the end queuing the next) in a jab-cross-hook combo whose hook knocks them
## down, R shoving (the one hit tipping back with the blow), X kicking further than a fist (the
## whole body, the foot out at contact), swings at nobody; emotes the people around answer; the
## guard squaring the body to the camera; what blocks the actions; presses (events, a trigger's
## edge) and held input; the player's car striking people (car_body.gd); person_hit and
## hero_action on the bus; teardown.
## Third person on a grown city; time runs through the feature's tick(1/60), traffic's step and
## the player's update_view.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const BODY := preload("res://scripts/fp/drive/car_body.gd")
const MODEL := preload("res://scripts/fp/drive/drive_model.gd")
const DT := 1.0 / 60.0
const POSE_BONES := [
	"Head",
	"LeftUpperArm",
	"LeftLowerArm",
	"LeftHand",
	"LeftMiddleDistal",
	"RightUpperArm",
	"RightLowerArm",
	"RightHand",
	"RightMiddleDistal",
]

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var f: FpFeature
var rig: RefCounted
## [at, cause, info] of every person_hit, and every hero_action's action.
var hits: Array = []
var acts: Array[String] = []
var _post: Dictionary = {}


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	tr = K.make_feature(ctx, "traffic")
	f = K.make_feature(ctx, "actions")
	if tr == null or f == null:
		K.check(fails, false, "the traffic and actions features are registered")
		K.finish(self, "FP_ACTIONS_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	f.set_process(false)
	_quiet()
	ctx.bus.person_hit.connect(
		func(at: Vector3, cause: String, info: Dictionary) -> void: hits.append([at, cause, info])
	)
	ctx.bus.hero_action.connect(func(a: String, _at: Vector3) -> void: acts.append(a))
	var p := ctx.player
	p.teleport(p.position, rad_to_deg(p.yaw))
	rig = p.avatar.get("rig")
	K.check(fails, rig != null, "fixture: the hero is HC's animated rig")
	_check_inputs()
	if rig != null:
		await _check_rig()
		_check_strike_pose()
		_sk().get_node("StrikePose").modification_processed.connect(_capture)
		await _check_guard_pose()
		await _check_shove_pose()
		await _check_combat_head()
	_check_punch()
	_check_aim_target()
	_check_aim_offset()
	_check_shove()
	_check_combo()
	_check_kick()
	_check_miss()
	_check_emotes()
	_check_guard()
	_check_blocked()
	await _check_held_input()
	_check_car()
	_check_recovery()
	_check_teardown()
	K.finish(self, "FP_ACTIONS_TEST", fails)


# ------------------------------------------------------------------ helpers


## Contact shortens the torso's follow-through; missing adds a brief next-attack recovery.
## The flag-off cases prove that target selection alone never changes the legacy timing.
func _check_recovery() -> void:
	var outcomes := []
	for on: bool in [true, false]:
		FeatureFlags.set_override("strike_recovery", on)
		for contact: bool in [true, false]:
			f.call("cancel")
			_quiet()
			_step(1.1)
			if contact:
				_person(0.8)
			K.check(fails, bool(f.call("strike")), "recovery fixture starts a jab")
			_step(0.38)
			outcomes.append([float(f.get("_len")), float(_pose().call("weight"))])
	FeatureFlags.set_override("strike_recovery", true)
	K.check(
		fails,
		float(outcomes[1][0]) > float(outcomes[0][0]) + 0.05,
		"a missed jab recovers longer than a landed jab (%s)" % str(outcomes)
	)
	K.check(
		fails,
		float(outcomes[0][1]) < 0.01 and float(outcomes[1][1]) > 0.1,
		"contact returns the torso to stance while a miss follows through"
	)
	K.check(
		fails,
		is_equal_approx(float(outcomes[2][0]), float(outcomes[3][0])),
		"recovery flag off keeps landed and missed timing equal"
	)
	_quiet()
	f.call("cancel")
	_step(1.1)


## Steps the actions feature (unless feature is false: the rig on its own), traffic and the player.
func _step(secs: float, feature: bool = true) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		if feature:
			f.call("tick", DT)
		tr.call("step", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)


## Removes every walker, so only the test's own people are about.
func _quiet() -> void:
	K.quiet_walkers(tr)


## Someone standing dist_m metres ahead of the hero (behind for a negative distance), facing them.
func _person(dist_m: float) -> WK.Walker:
	return K.person_ahead(ctx, tr, dist_m)


func _remove(w: WK.Walker) -> void:
	(tr.get("walkers") as WK).remove(w)


## Steps the hero up to dist_m metres from where w is drawn (a blow slides them back).
func _close_in(w: WK.Walker, dist_m: float) -> void:
	var p := ctx.player
	var q := w.pos + w.vis_off
	var d := Vector3(q.x - p.position.x, 0.0, q.z - p.position.z).normalized()
	p.position = Vector3(q.x, p.position.y, q.z) - d * dist_m * WS.M


## The higher hand above the feet (metres).
func _hands_up() -> float:
	var y := -INF
	for b: String in ["LeftHand", "RightHand"]:
		y = maxf(y, (rig.call("bone_world", b) as Vector3).y)
	return (y - ctx.player.position.y) / WS.M


## The rig's strike pose layer.
func _pose() -> RefCounted:
	return rig.get("strike_pose")


## Post-modifier world positions of the bones POSE_BONES, captured as the strike pose layer
## (last of the rig's modifiers) finishes each skeleton update.
func _capture() -> void:
	var sk := _sk()
	for b: String in POSE_BONES:
		_post[b] = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(b)).origin
	_post["head_forward"] = (
		(sk.global_basis * sk.get_bone_global_pose(sk.find_bone("Head")).basis.z).normalized()
	)


func _sk() -> Skeleton3D:
	for n in ctx.player.avatar.find_children("*", "Skeleton3D", true, false):
		return n
	return null


## Guard and strikes keep the chin down even while the camera looks high above the street.
func _check_combat_head() -> void:
	var p := ctx.player
	p.look(0.0, -1.0)
	f.call("set_guard", true)
	var guard_pitch := 0.0
	for _k in 24:
		_step(DT)
		await process_frame
		if _k > 12:
			var dir: Vector3 = _post.get("head_forward", p.body_forward())
			guard_pitch = maxf(guard_pitch, absf(asin(clampf(dir.y, -1.0, 1.0))))
	K.check(
		fails,
		guard_pitch < deg_to_rad(8.0),
		"guard keeps head level (%.1f deg)" % rad_to_deg(guard_pitch)
	)
	f.call("set_guard", false)
	f.call("strike")
	var strike_pitch := 0.0
	for _k in 20:
		_step(DT)
		await process_frame
		var dir: Vector3 = _post.get("head_forward", p.body_forward())
		strike_pitch = maxf(strike_pitch, absf(asin(clampf(dir.y, -1.0, 1.0))))
	K.check(
		fails,
		strike_pitch < deg_to_rad(8.0),
		"strike keeps head level (%.1f deg)" % rad_to_deg(strike_pitch)
	)
	p.look(0.0, 1.0)
	f.call("cancel")
	_step(1.1)


## Bone b as captured, in the hero's frame (metres): x to the right, y up off the feet, z ahead.
func _at(b: String) -> Vector3:
	var p := ctx.player
	var fwd := p.body_forward()
	var d: Vector3 = (_post.get(b, p.position) as Vector3) - p.position
	return Vector3(d.dot(Vector3(-fwd.z, 0.0, fwd.x)), d.y, d.dot(fwd)) / WS.M


## The fighting guard: closed fists up at the chin on their own sides, forearms angled up from
## elbows tucked in under them.
func _check_guard_pose() -> void:
	_quiet()
	f.call("set_guard", true)
	_step(1.0)
	await process_frame
	var head := _at("Head")
	var ok := true
	var msg := ""
	for side: String in ["Left", "Right"]:
		var s := -1.0 if side == "Left" else 1.0
		var hand := _at(side + "Hand")
		var elbow := _at(side + "LowerArm")
		var tip := _at(side + "MiddleDistal")
		var rise := rad_to_deg(
			atan2(hand.y - elbow.y, Vector2(hand.x - elbow.x, hand.z - elbow.z).length())
		)
		var curl := (tip - hand).length()
		ok = (
			ok
			and hand.x * s > 0.03
			and hand.y > head.y - 0.25
			and tip.y < head.y + 0.05
			and hand.z > 0.12
			and rise > 40.0
			and absf(elbow.x) < 0.24
			and curl < 0.1
		)
		msg += (
			(
				" %s fist %.2f m under the head, %.2f out, %.2f to the side; forearm %.0f deg"
				+ " up, elbow %.2f out; fingertip %.3f m from the wrist;"
			)
			% [side, head.y - hand.y, hand.z, hand.x, rise, absf(elbow.x), curl]
		)
	K.check(fails, ok, "the guard: closed fists at the chin, elbows tucked in (%s)" % msg)
	f.call("set_guard", false)
	_step(0.6)


## The shove: no windup overhead (neither hand above the shoulders before the contact), then both
## palms out at chest height on their own sides, reaching the chest of the person shoved.
func _check_shove_pose() -> void:
	_quiet()
	var w := _person(0.8)
	hits.clear()
	f.call("strike", "shove")
	var high := -INF
	var shoulder := INF
	for _k in range(30):
		_step(DT)
		await process_frame
		shoulder = minf(_at("LeftUpperArm").y, _at("RightUpperArm").y)
		if not hits.is_empty():
			break
		high = maxf(high, maxf(_at("LeftHand").y, _at("RightHand").y) - shoulder)
	K.check(
		fails,
		not hits.is_empty() and high < 0.0,
		"the shove winds up low (hands at most %.2f m off the shoulders before contact)" % high
	)
	var p := ctx.player
	var feet := w.pos + w.vis_off
	var chest_front := (feet - p.position).dot(p.body_forward()) / WS.M - 0.12
	var ok := true
	var msg := ""
	for side: String in ["Left", "Right"]:
		var s := -1.0 if side == "Left" else 1.0
		var hand := _at(side + "Hand")
		var short := chest_front - (_at(side + "MiddleDistal").z)
		ok = ok and hand.x * s > 0.05 and hand.y > 1.05 and hand.y < shoulder and short < 0.2
		msg += (
			" %s palm %.2f m up, %.2f to the side, %.2f short of their chest;"
			% [side, hand.y, hand.x, short]
		)
	K.check(fails, ok, "both palms meet their chest at contact (%s)" % msg)
	_step(1.0)
	_remove(w)
	_step(0.3)


func _causes() -> Array[String]:
	var out: Array[String] = []
	for h: Array in hits:
		out.append(str(h[1]))
	return out


# ------------------------------------------------------------------ checks


func _check_inputs() -> void:
	var st := f.self_test()
	K.check(
		fails,
		bool(st.get("ok", false)),
		"self_test: every input exists (%s)" % st.get("detail", "")
	)
	var pads := [_pad("act_strike"), _pad("act_aim")]
	K.check(
		fails, pads == ["a5+", "a4+"], "the right trigger strikes, the left guards (%s)" % str(pads)
	)
	var mice := [_mouse("act_strike"), _mouse("act_aim")]
	var mice_ok := mice == [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]
	K.check(fails, mice_ok, "the left mouse button strikes, the right guards (%s)" % str(mice))
	var keys: Array[int] = []
	for a: String in ["emote_wave", "emote_yes", "emote_no", "emote_shout", "emote_dance"]:
		keys.append(_key(a))
	var keys_ok := keys == [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5]
	K.check(fails, keys_ok, "keys 1-5 wave, nod, shake the head, shout and dance (%s)" % str(keys))
	K.check(fails, _key("act_shove") == KEY_R, "R shoves (%d)" % _key("act_shove"))
	var kick := [_key("act_kick"), _mouse("act_kick")]
	var kick_ok := kick == [KEY_X, MOUSE_BUTTON_MIDDLE]
	K.check(fails, kick_ok, "X and the middle mouse button kick (%s)" % str(kick))


func _check_rig() -> void:
	_step(0.5, false)
	var jab := float(_pose().call("measure", "punch_jab"))
	var cross := float(_pose().call("measure", "punch_cross"))
	for c: String in ["punch_hook", "push", "throw"]:
		print("FP_ACTIONS_TEST: strike contact %s %.3f" % [c, float(_pose().call("measure", c))])
	var times_ok := jab > 0.07 and jab < 0.3 and cross > jab and cross < 0.42
	K.check(
		fails,
		times_ok,
		"each punch is furthest out early on (jab %.3f s, cross %.3f s)" % [jab, cross]
	)
	var low := _hands_up()
	rig.call("set_guard", true)
	_step(0.4, false)
	await process_frame
	var g := float(rig.get("guard"))
	var limbs: RefCounted = rig.get("limbs")
	var ends: Array = limbs.get("ends")
	var left_end: Vector3 = ends[0]
	var right_end: Vector3 = ends[1]
	var left_y := (left_end.y - ctx.player.position.y) / WS.M
	var right_y := (right_end.y - ctx.player.position.y) / WS.M
	var up_msg := "the guard raises both fists (%.2f, ends %.2f/%.2f m vs %.2f m before)"
	K.check(
		fails,
		g > 0.95 and left_y > low + 0.15 and right_y > low + 0.15,
		up_msg % [g, left_y, right_y, low]
	)
	rig.call("set_guard", false)
	_step(0.4, false)
	K.check(fails, float(rig.get("guard")) < 0.05, "and drops them again")
	K.check(fails, rig.call("play_action", "punch_jab") == true, "a jab plays")
	_step(DT, false)
	K.check(fails, bool(rig.call("action_active")), "on the upper body")
	_step(1.2, false)
	K.check(fails, not bool(rig.call("action_active")), "and ends by itself")
	K.check(fails, rig.call("play_action", "bogus") == false, "an unknown action is refused")
	_check_rig_kick()
	K.check(fails, rig.call("play_action", "dance") == true, "the hero dances standing")
	_step(1.0, false)
	K.check(fails, bool(rig.call("action_active")), "and keeps dancing")
	for _k in range(40):
		rig.call("update", DT, 1.3, true, 0.0, false, false)
	K.check(fails, not bool(rig.call("action_active")), "walking off ends the dance")
	_step(1.0, false)


## The strike pose layer: each strike clip drives a hand, the chest coils back through the windup
## and turns into the blow as it lands, and eases back to nothing once the strike is over.
func _check_strike_pose() -> void:
	var pose: RefCounted = rig.get("strike_pose")
	var hand: float = pose.call("hand", "punch_hook")
	K.check(fails, absf(hand) > 0.5, "each strike clip drives a hand (%+.0f)" % hand)
	K.check(fails, float(pose.call("weight")) == 0.0, "the pose layer waits, off")
	rig.call("play_action", "punch_hook")
	var contact := float(pose.call("measure", "punch_hook"))
	var coiled := 0.0
	var peak := 0.0
	for _k in range(ceili((contact + 0.05) / DT)):
		_step(DT, false)
		var w := float(pose.call("weight"))
		coiled = minf(coiled, w)
		peak = maxf(peak, w)
	K.check(fails, coiled < -0.05, "the windup coils the chest back (%.2f)" % coiled)
	K.check(fails, peak > 0.8, "and the blow lands at the turn's height (%.2f)" % peak)
	_step(1.5, false)
	K.check(fails, float(pose.call("weight")) == 0.0, "the pose eases back to nothing")
	rig.call("stop_action")
	_step(0.5, false)


## With the guard down the strike button throws a punch at whoever stands in front, and the body
## turns to them; a press near the end of a swing queues the next punch.
func _check_punch() -> void:
	var p := ctx.player
	var w := _person(0.8)
	hits.clear()
	acts.clear()
	var d := w.pos - p.position
	var to_w := atan2(-d.x, -d.z)
	p.yaw = wrapf(to_w + 0.6, -PI, PI)
	p.cam_yaw = to_w
	var started: bool = f.call("strike") == true and str(f.get("swing")) == "jab"
	K.check(fails, started, "with the guard down the strike button punches (a jab)")
	K.check(fails, f.call("strike", "bogus") == false, "an unknown swing is refused")
	_step(0.4)
	K.check(fails, _causes() == ["punch"], "it lands on the person in front (%s)" % str(_causes()))
	var info: Dictionary = hits[0][2] if not hits.is_empty() else {}
	K.check(
		fails, absf(float(info.get("strength", 0.0)) - 0.45) < 0.01, "a standing jab (%s)" % info
	)
	var off := absf(angle_difference(p.yaw, to_w))
	K.check(fails, off < 0.2, "the body turns to them (%.2f rad off)" % off)
	K.check(fails, acts == ["jab"], "hero_action hears the jab (%s)" % str(acts))
	_remove(w)
	_step(1.1)
	f.call("strike")
	_step(0.3)
	K.check(fails, f.call("strike") == false, "a press near the end of the swing is queued")
	_step(0.15)
	K.check(fails, str(f.get("swing")) == "cross", "and the cross follows (%s)" % f.get("swing"))
	_step(0.7)
	K.check(fails, str(f.get("swing")).is_empty(), "then the hands come down")
	p.teleport(p.position, rad_to_deg(p.cam_yaw))
	_step(1.1)


func _check_shove() -> void:
	var w := _person(0.8)
	hits.clear()
	acts.clear()
	var started: bool = f.call("strike", "shove") == true and str(f.get("swing")) == "shove"
	K.check(fails, started, 'strike("shove") shoves')
	K.check(fails, f.call("strike") == false, "one swing at a time")
	_step(0.1)
	K.check(fails, hits.is_empty(), "the shove lands once the arms are out, not at once")
	var limbs: RefCounted = rig.get("limbs")
	var weights: PackedFloat32Array = limbs.get("weights")
	var push_weight := float(_pose().call("push_weight"))
	K.check(
		fails,
		push_weight > 0.2 and weights[0] > 0.05 and weights[1] > 0.05,
		(
			"the shove starts driving both hands forward (pose %.2f, IK %.2f/%.2f)"
			% [push_weight, weights[0], weights[1]]
		)
	)
	_step(0.15)
	weights = limbs.get("weights")
	K.check(
		fails,
		weights[0] > 0.55 and weights[1] > 0.55,
		"both hands stay out through shove contact (IK %.2f/%.2f)" % [weights[0], weights[1]]
	)
	K.check(fails, _causes() == ["shove"], "it lands on the person in front (%s)" % str(_causes()))
	var info: Dictionary = hits[0][2] if not hits.is_empty() else {}
	var reel := not bool(info.get("down", true)) and w.state == "react"
	K.check(
		fails, reel, "they reel but keep their feet (%s, %s)" % [str(info.get("down")), w.state]
	)
	K.check(
		fails, absf(float(info.get("strength", 0.0)) - 0.35) < 0.01, "a standing shove is light"
	)
	var kick: Vector2 = ctx.player.get("_kick")
	K.check(fails, kick.length() > 1e-4, "the view jolts as it lands")
	K.check(fails, acts == ["shove"], "hero_action hears the shove (%s)" % str(acts))
	var tipped := 0.0
	for _k in range(21):
		_step(DT)
		tipped = minf(tipped, w.vis_tilt)
	var upright := w.vis_tilt == 0.0
	K.check(
		fails,
		tipped < -0.01 and upright,
		"they tip back with the blow (%.2f rad) and come upright" % tipped
	)
	_step(0.6)
	K.check(fails, str(f.get("swing")).is_empty(), "the swing ends")
	_remove(w)
	_step(0.5)


func _check_combo() -> void:
	var w := _person(0.8)
	hits.clear()
	acts.clear()
	var downs: Array[bool] = []
	for _k in range(3):
		_close_in(w, 0.8)
		f.call("strike")
		_step(0.55)
	for h: Array in hits:
		downs.append(bool((h[2] as Dictionary).get("down", false)))
	var combo := acts == ["jab", "cross", "hook"]
	K.check(fails, combo, "the punches go jab, cross, hook (%s)" % str(acts))
	K.check(fails, _causes() == ["punch", "punch", "punch"], "each lands (%s)" % str(_causes()))
	K.check(fails, downs == [false, false, true], "the hook knocks them down %s" % str(downs))
	var hook: Dictionary = hits[2][2] if hits.size() == 3 else {}
	var hard := float(hook.get("strength", 0.0)) >= 0.84
	K.check(fails, hard, "a hook is the hardest punch (%s)" % hook.get("strength"))
	K.check(fails, str(w.react) == "knockback", "they fall (%s)" % str(w.react))
	_close_in(w, 0.8)
	f.call("strike")
	_step(0.55)
	K.check(fails, hits.size() == 3, "nobody is punched lying down")
	_remove(w)
	_step(0.5)


## A kick reaches someone a fist cannot and knocks them down; crouched the hero does not kick.
func _check_kick() -> void:
	var w := _person(1.35)
	hits.clear()
	acts.clear()
	f.call("strike")
	_step(0.7)
	K.check(fails, hits.is_empty(), "a punch does not reach someone 1.35 m off")
	acts.clear()
	var started: bool = f.call("strike", "kick") == true and str(f.get("swing")) == "kick"
	K.check(fails, started and acts == ["kick"], 'strike("kick") kicks (%s)' % str(acts))
	_step(0.15)
	K.check(fails, hits.is_empty(), "the kick lands once the leg is out, not at once")
	_step(0.2)
	K.check(fails, _causes() == ["punch"], "it lands on them (%s)" % str(_causes()))
	var info: Dictionary = hits[0][2] if not hits.is_empty() else {}
	var hard := absf(float(info.get("strength", 0.0)) - 0.75) < 0.01
	var down := bool(info.get("down", false)) and hard
	K.check(fails, down, "a standing kick knocks them down (%s)" % str(info))
	_step(0.8)
	K.check(fails, str(f.get("swing")).is_empty(), "the kick ends")
	_remove(w)
	ctx.player.crouched = true
	K.check(fails, f.call("strike", "kick") == false, "no kick crouched")
	ctx.player.crouched = false
	_step(0.5)


## The kick plays on the whole body: at contact the right foot is out in front at about hip height.
func _check_rig_kick() -> void:
	var p := ctx.player
	K.check(fails, rig.call("play_action", "kick") == true, "a kick plays")
	_step(0.24, false)
	var foot: Vector3 = rig.call("bone_world", "RightFoot")
	var rel := foot - p.position
	var ahead := rel.dot(p.body_forward()) / WS.M
	var up := rel.y / WS.M
	var out_msg := "the kicking foot is out in front (%.2f m ahead, %.2f m up)" % [ahead, up]
	K.check(fails, bool(rig.call("action_active")) and ahead > 0.5 and up > 0.5, out_msg)
	_step(0.8, false)
	K.check(fails, not bool(rig.call("action_active")), "and the kick ends by itself")


func _check_miss() -> void:
	hits.clear()
	var n0 := int(f.get("hits"))
	K.check(fails, f.call("strike") == true, "a swing at nobody still plays")
	_step(0.7)
	K.check(fails, hits.is_empty() and int(f.get("hits")) == n0, "and hits nobody")
	var w := _person(-0.8)
	f.call("strike")
	_step(0.7)
	K.check(fails, hits.is_empty(), "nor someone behind the hero")
	_remove(w)
	var far := _person(2.5)
	f.call("strike")
	_step(0.7)
	K.check(fails, hits.is_empty(), "nor someone out of reach")
	_remove(far)


func _check_emotes() -> void:
	var w := _person(3.0)
	acts.clear()
	var waved: bool = f.call("emote", "wave") == true
	K.check(
		fails,
		waved and int(f.get("answered")) == 1,
		"the person ahead answers a wave (%d)" % int(f.get("answered"))
	)
	K.check(fails, f.call("emote", "yes") == false, "emotes are a moment apart")
	_step(1.1)
	var dancing: bool = f.call("emote", "dance") == true
	_step(DT)
	K.check(
		fails,
		dancing and bool(rig.call("action_active")) if rig != null else dancing,
		"the hero dances"
	)
	K.check(fails, acts == ["wave", "dance"], "hero_action hears the emotes (%s)" % str(acts))
	_step(1.1)
	K.check(fails, f.call("emote", "bogus") == false, "an unknown emote is refused")
	f.call("cancel")
	_step(0.5)
	K.check(fails, rig == null or not bool(rig.call("action_active")), "cancel ends the dance")
	_remove(w)


func _check_guard() -> void:
	var p := ctx.player
	f.call("set_guard", true)
	p.cam_yaw = wrapf(p.yaw + 1.0, -PI, PI)
	_step(1.0)
	K.check(fails, bool(f.get("guarding")), "set_guard raises the guard")
	K.check(
		fails,
		is_equal_approx(p.aim_yaw, p.cam_yaw),
		"the guard aims the body where the camera looks"
	)
	var pose: RefCounted = _pose()
	var limbs: RefCounted = rig.get("limbs")
	var weights: PackedFloat32Array = limbs.get("weights")
	var stance := (
		float(pose.call("guard_weight")) > 0.9
		and weights[0] > 0.9
		and weights[1] > 0.9
		and weights[2] > 0.9
		and weights[3] > 0.9
	)
	K.check(fails, stance, "both hands rise and the feet set into a guard stance")
	var off := absf(angle_difference(p.yaw, p.cam_yaw))
	K.check(fails, off < 0.15, "and the body turns to it (%.2f rad off)" % off)
	K.check(fails, is_equal_approx(p.rig.arm_scale, 0.8), "the camera closes in")
	f.call("set_guard", false)
	_step(0.1)
	var back := is_nan(p.aim_yaw) and is_equal_approx(p.rig.arm_scale, 1.0)
	K.check(fails, back, "dropping the guard gives the body and the camera back")
	_step(0.4)
	K.check(fails, float(pose.call("guard_weight")) < 0.05, "the guard pose eases away")
	p.teleport(p.position, rad_to_deg(p.cam_yaw))


## A farther person centered under the aim ray (from the hero's chest along the camera) wins over
## a nearer person off to its side.
func _check_aim_target() -> void:
	_quiet()
	var p := ctx.player
	p.cam_pitch = 0.0
	p.pitch = 0.0
	p.update_view(0.0)
	var aim: Vector3 = p.forward().normalized()
	var side := Vector3(aim.z, 0.0, -aim.x).normalized()
	var near := _person(0.55)
	var centered := _person(0.95)
	near.pos = p.position + aim * 0.55 * WS.M + side * (0.65 * WS.M) * 0.4
	centered.pos = p.position + aim * 0.95 * WS.M
	var chosen: Dictionary = f.call("_find_target", aim)
	K.check(
		fails,
		int(chosen.get("id", -1)) == centered.id,
		"the target nearest the aim ray wins (%d over nearer %d)" % [centered.id, near.id]
	)
	_remove(near)
	_remove(centered)
	p.teleport(p.position, rad_to_deg(p.cam_yaw))


## The live third-person case: the camera sits behind and off to a shoulder and looks off the
## body's facing. A farther person straight down the camera's line from the hero still wins over a
## nearer one off to the camera's side.
func _check_aim_offset() -> void:
	_quiet()
	var p := ctx.player
	p.cam_yaw = wrapf(p.yaw + 0.94, -PI, PI)
	p.cam_pitch = -0.15
	p.pitch = -0.15
	p.update_view(0.0)
	var aim := Vector3(-sin(p.cam_yaw), 0.0, -cos(p.cam_yaw))
	var right := Vector3(-aim.z, 0.0, aim.x)
	var cam_side := (p.view_position() - p.position).dot(right) / WS.M
	var s := 1.0 if cam_side >= 0.0 else -1.0
	var near := _person(0.5)
	var centered := _person(0.95)
	near.pos = p.position + aim * 0.45 * WS.M + right * s * 0.65 * WS.M
	centered.pos = p.position + aim * 0.95 * WS.M
	var chosen: Dictionary = f.call("_find_target", aim)
	K.check(
		fails,
		int(chosen.get("id", -1)) == centered.id,
		(
			(
				"seen over the shoulder (camera %.2f m to the side), the person centered"
				+ " ahead of the hero wins (%d, wanted %d over the nearer %d)"
			)
			% [cam_side, int(chosen.get("id", -1)), centered.id, near.id]
		)
	)
	_remove(near)
	_remove(centered)
	p.cam_pitch = 0.0
	p.pitch = 0.0
	p.teleport(p.position, rad_to_deg(p.cam_yaw))


func _check_blocked() -> void:
	var p := ctx.player
	ctx.push_modal(&"test")
	var none: bool = f.call("strike") == false and f.call("emote", "wave") == false
	K.check(fails, none, "no swing or emote while something modal is open")
	f.call("set_guard", true)
	_step(0.1)
	K.check(fails, not bool(f.get("guarding")), "nor a guard")
	ctx.pop_modal(&"test")
	f.call("set_guard", false)
	p.set_photo_mode(true)
	K.check(fails, f.call("strike") == false, "nor in photo mode")
	p.set_photo_mode(false)
	p.carry(p.position, p.yaw, Vector3.ZERO, true)
	K.check(fails, f.call("strike") == false, "nor while a parkour move carries the body")
	p.release(true)
	ctx.bus.drive_changed.emit(true)
	K.check(fails, f.call("strike") == false, "nor at the wheel")
	ctx.bus.drive_changed.emit(false)
	K.check(fails, f.call("strike") == true, "on foot again it swings")
	_step(0.7)
	f.call("strike")
	ctx.push_modal(&"test")
	_step(DT)
	K.check(fails, str(f.get("swing")).is_empty(), "a modal opening ends the swing")
	ctx.pop_modal(&"test")
	_step(0.5)


func _check_held_input() -> void:
	var p := ctx.player
	p.input_enabled = true
	_step(DT)
	var n0 := int(f.get("swings"))
	_send(K.action_event("act_strike"))
	K.check(fails, int(f.get("swings")) == n0 + 1, "a strike press swings")
	_step(0.7)
	K.check(fails, int(f.get("swings")) == n0 + 1, "once")
	for v: float in [0.6, 1.0, 0.8]:
		_send(K.trigger_event(v))
		_step(0.7)
	var held := int(f.get("swings")) - n0
	K.check(fails, held == 2, "a trigger held down swings once (%d)" % (held - 1))
	_send(K.trigger_event(0.1))
	_send(K.trigger_event(0.9))
	K.check(fails, int(f.get("swings")) == n0 + 3, "pulled again, it swings again")
	_step(0.7)
	ctx.push_modal(&"test")
	_send(K.action_event("act_strike"))
	ctx.pop_modal(&"test")
	p.input_enabled = false
	_send(K.action_event("act_strike"))
	p.input_enabled = true
	var taken := int(f.get("swings")) - n0 - 3
	K.check(fails, taken == 0, "no press is taken under a modal or with input off (%d)" % taken)
	acts.clear()
	_send(K.key_event(KEY_2, true))
	K.check(fails, acts.is_empty(), "a held key's echo does nothing")
	_send(K.key_event(KEY_2))
	K.check(fails, acts == ["yes"], "key 2 nods (%s)" % str(acts))
	f.call("cancel")
	_step(1.1)
	_send(K.key_event(KEY_R))
	K.check(fails, acts == ["yes", "shove"], "R shoves (%s)" % str(acts))
	f.call("cancel")
	_step(1.1)
	Input.action_press("act_aim")
	_step(0.1)
	K.check(fails, bool(f.get("guarding")), "holding aim keeps the guard up")
	Input.action_release("act_aim")
	_step(0.1)
	K.check(fails, not bool(f.get("guarding")), "letting go drops it")
	p.input_enabled = false
	await process_frame


## The player's car runs into someone on a road at 36 km/h, then rolls into someone else at walking
## pace.
func _check_car() -> void:
	var lanes: LG = tr.get("lanes")
	var tile := -1
	for i: int in lanes.tiles.keys():
		if (
			lanes.tiles.has(D.idx(D.tx(i) + 1, D.ty(i)))
			and lanes.tiles.has(D.idx(D.tx(i) - 1, D.ty(i)))
		):
			tile = i
			break
	K.check(fails, tile >= 0, "fixture: a straight east-west road")
	if tile < 0:
		return
	var at := Vector3(D.tx(tile), 0.0, D.ty(tile))
	var g := ctx.collision.walk_height(at)
	at.y = 0.0 if is_nan(g) else g
	var fast := _run_car(at, 10.0)
	var info: Dictionary = fast[0]
	K.check(fails, not info.is_empty(), "a car at 36 km/h strikes the person in its way")
	K.check(
		fails,
		str(info.get("cause", "")) == "car" and bool(info.get("down", false)),
		"and knocks them down (%s)" % str(info)
	)
	var kept := float(fast[1]) / (10.0 * WS.M)
	K.check(
		fails,
		kept > 0.8 and kept < 1.0,
		"the car loses a little speed (keeps %.0f%%)" % (kept * 100.0)
	)
	K.check(fails, bool(fast[2]), "the body lists the hit as a person")
	var slow := _run_car(at + Vector3(0.0, 0.0, 0.2), 0.3)
	K.check(fails, (slow[0] as Dictionary).is_empty(), "a car creeping at 1 km/h strikes nobody")


## [the person_hit info (with "cause"), the car's speed after, whether body.hits had a person] for a
## car driving east at kmh... at mps metres a second into someone standing at at.
func _run_car(at: Vector3, mps: float) -> Array:
	var wk: WK = tr.get("walkers")
	var w := wk.make("ambient")
	wk.stand(w, at, 0.0)
	hits.clear()
	var body := BODY.new()
	body.setup(0.045, 0.24, 0.075)
	var m := MODEL.new()
	m.reset(PI * 0.5, 0.24)
	m.vel = Vector2(mps * WS.M, 0.0)
	var pos := at - Vector3(0.2, 0.0, 0.0)
	var person := false
	for _k in range(30):
		pos = body.move(m, pos, m.yaw, DT, ctx.collision, tr, null)
		for h: Array in body.hits:
			person = person or str(h[2]) == "person"
		tr.call("step", DT)
	var info: Dictionary = {}
	if not hits.is_empty():
		info = (hits[0][2] as Dictionary).duplicate()
		info["cause"] = hits[0][1]
	_remove(w)
	return [info, m.vel.length(), person]


func _check_teardown() -> void:
	f.call("set_guard", true)
	_step(0.1)
	f.teardown()
	var p := ctx.player
	var clean := (
		is_nan(p.aim_yaw) and is_equal_approx(p.rig.arm_scale, 1.0) and not bool(f.get("guarding"))
	)
	K.check(fails, clean, "teardown drops the guard and gives the body and camera back")


# ------------------------------------------------------------------ input


func _send(e: InputEvent) -> void:
	f.call("_unhandled_input", e)


func _pad(action: String) -> String:
	for e: InputEvent in InputMap.action_get_events(action):
		if e is InputEventJoypadMotion:
			var m := e as InputEventJoypadMotion
			return "a%d%s" % [m.axis, "+" if m.axis_value > 0.0 else "-"]
		if e is InputEventJoypadButton:
			return "b%d" % (e as InputEventJoypadButton).button_index
	return ""


func _mouse(action: String) -> int:
	for e: InputEvent in InputMap.action_get_events(action):
		if e is InputEventMouseButton:
			return (e as InputEventMouseButton).button_index
	return -1


func _key(action: String) -> int:
	for e: InputEvent in InputMap.action_get_events(action):
		if e is InputEventKey:
			return int((e as InputEventKey).physical_keycode)
	return -1
