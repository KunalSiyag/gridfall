extends "res://tools/tests/fp_jack_kit.gd"
## The hero's two-hand grip on a driver he pulls out of a car, frame by frame (car_entry.gd,
## jack_hold.gd, carjack.gd grips; the carjack_throw flag), through a grown city with the hero's own
## skeleton and the driver's, as fp_jack_flow_test.gd has it. For a coupe, a sedan, an SUV and a van
## at a standstill: both hands are on the driver's collar and near upper arm (within HAND_TOL of the
## points read off the driver's skeleton) for at least HOLD_MIN_S, from before the pull and for the
## first of it, at least GRAB_LEAD_S of it before the driver is pulled; the hands never jump more
## than HAND_STEP_MAX from one frame to the next and are never above the hero's head; from the first
## reach to the step into the opening takes SPAN_S (1.6 to 2.2 s); the driver's root never goes
## faster than ROOT_V_MAX (m/s: the haul ends at the slide's pace and the drift down the car's side;
## it was 6 to 9.5 before) along the ground while they are pulled and is never more than AIR_MAX
## over the road; the hero's root keeps ROOT_MIN m from every bone of the driver from the pull to
## the step; the door camera can see the driver's collar past the hero (VIEW_MIN degrees from his
## body); the hands stay on through the pull: on the grips (HAND_TOL) for PULL_EARLY_ON_S s of its
## first PULL_EARLY_S s (they were off 0.3 s into it: the frame the grips pass from the seated body
## to the hauled one is the one frame they trail), within PULL_NEAR m of them for PULL_NEAR_FRAC of
## its frames, and within SKIN_TOL m of the driver's skinned body (the surface itself, not the
## points the grip function gives: the test does not use its own oracle) for SKIN_FRAC of the
## frames of the struggle and the pull, the collar and the arm held apart (GRIPS_APART m: two
## points, not one); and the hero does not run: his root goes at most HERO_V_AVG m/s over a tenth
## of a second (3.7 to 3.9 for a coupe, a sedan and an SUV, 4.4 for a van, whose driver sits higher
## and swings out wider through him: 5 m/s for 0.3 s ahead of them before, with the hands
## trailing) and HERO_V_MAX in a frame.

## A hand (its wrist bone) within HAND_TOL m of its grip is on it; both for at least HOLD_MIN_S s,
## of which GRAB_LEAD_S before the pull.
const HAND_TOL := 0.1
const HOLD_MIN_S := 0.7
const GRAB_LEAD_S := 0.4
const HAND_STEP_MAX := 0.15
const BELOW_HEAD := 0.05
const SPAN_S := Vector2(1.6, 2.2)
const ROOT_V_MAX := 5.5
const AIR_MAX := 0.25
const ROOT_MIN := 0.25
const VIEW_MIN := 5.0
const PULL_NEAR := 0.25
const PULL_NEAR_FRAC := 0.85
const PULL_EARLY_S := 0.4
const PULL_EARLY_ON_S := 0.2
const SKIN_FRAC := 0.9
const SKIN_TOL := 0.13
const GRIPS_APART := 0.08
const HERO_V_MAX := 5.0
const HERO_V_AVG := 4.5
const HERO_V_WINDOW := 6
const SKIN := preload("res://tools/tests/fp_skin_pts.gd")
const MODELS := ["coupe_navy", "sedan_blue", "suv_black", "van_white"]

var _st := {}
var _skin := SKIN.new()


func _init() -> void:
	if await _fixture():
		for key: String in MODELS:
			var m := _model_by_key(key)
			if m < 0:
				K.check(fails, false, "fixture: a %s model" % key)
				continue
			_judge(key, await _flow(m))
		ran.append("grip")
	K.check(fails, ran.size() == 1, "every section ran to its end (%s)" % str(ran))
	FeatureFlags.reload()
	K.finish(self, "FP_JACK_GRIP_TEST", fails)


## One carjack of a car of model m at a standstill with a resident drawn at the wheel, the hero on
## foot beside it: the record of what the frames add up to (_note).
func _flow(m: int) -> Dictionary:
	door_model = m
	K.quiet_walkers(traffic)
	var c := _driven_car(0.5)
	hits.clear()
	victim = null
	hero_post.clear()
	_st = {
		"c": c,
		"sim_t": 0.0,
		"t_hit": -1.0,
		"t_reach": -1.0,
		"t_step": -1.0,
		"on_before": 0.0,
		"on_total": 0.0,
		"step_max": 0.0,
		"hand_up": -INF,
		"root_v": 0.0,
		"air": -INF,
		"bones": INF,
		"view": INF,
		"hands": [],
		"was": Vector3.ZERO,
		"frames": 0,
		"pull_frames": 0,
		"pull_on": 0,
		"pull_near": 0,
		"early_on": 0.0,
		"skin_frames": 0,
		"skin_on": 0,
		"skin_worst": 0.0,
		"apart": INF,
		"hero_v": 0.0,
		"hero_v_avg": 0.0,
		"hero_hist": [],
		"hero_was": Vector3.INF,
	}
	drive.call("board")
	for _step in range(60 * 12):
		_frame()
		hero_fresh = false
		await process_frame
		if (
			_note()
			or (float(_st["t_step"]) >= 0.0 and float(_st["sim_t"]) - float(_st["t_step"]) > 0.3)
		):
			break
	drive.call("exit", true)
	if traffic.get("_driven") != null:
		traffic.call("leave_car")
	return _st


## One frame of the game: the climb, the player's view, traffic.
func _frame() -> void:
	if drive.call("_climbing"):
		drive.call("climb_step", DT)
	elif bool(drive.get("active")):
		drive.call("drive_step", 0.0, 0.0, 0.0, 0.0, DT)
	ctx.player.update_view(DT)
	_st["sim_t"] = float(_st["sim_t"]) + DT
	traffic.call("step", DT)
	traffic.call("sync_visuals", DT)


## The frame's numbers (after the skeletons updated); true when the flow is over (the hero seated).
func _note() -> bool:
	var entry: RefCounted = drive.get("entry")
	var hold: RefCounted = entry.get("_hold")
	var beat := str(hold.get("beat"))
	var ph := str(entry.get("phase"))
	var t: float = _st["sim_t"]
	if not hits.is_empty() and float(_st["t_hit"]) < 0.0:
		_st["t_hit"] = t
	if beat == "reach" and float(_st["t_reach"]) < 0.0:
		_st["t_reach"] = t
	if ph == "step" and float(_st["t_step"]) < 0.0:
		_st["t_step"] = t
	if not hero_post.has("Head") or beat.is_empty():
		return bool(drive.get("active"))
	var feet: Vector3 = ctx.player.position
	var jid := int(drive.get("_jack_id"))
	var g: Dictionary = traffic.call(
		"jack_grips",
		jid if jid >= 0 else -1,
		feet,
		float(hold.call("_top")),
		str(hold.get("_arm_side"))
	)
	if not (g.get("collar", Vector3(NAN, NAN, NAN)) as Vector3).is_finite():
		return false
	var lh: Vector3 = hero_post["LeftHand"]
	var rh: Vector3 = hero_post["RightHand"]
	var collar_left := int(hold.get("_left")) == 1
	var dl := lh.distance_to(g["collar"] if collar_left else g["arm"]) / WS.M
	var dr := rh.distance_to(g["arm"] if collar_left else g["collar"]) / WS.M
	var both := dl <= HAND_TOL and dr <= HAND_TOL
	if both:
		_st["on_total"] = float(_st["on_total"]) + DT
		if float(_st["t_hit"]) < 0.0:
			_st["on_before"] = float(_st["on_before"]) + DT
	_note_pull(beat, both, g, lh, rh, maxf(dl, dr) <= PULL_NEAR)
	var up := maxf(lh.y, rh.y)
	_st["hand_up"] = maxf(float(_st["hand_up"]), (up - (hero_post["Head"] as Vector3).y) / WS.M)
	var hands: Array = [lh, rh]
	var prior: Array = _st["hands"]
	if not prior.is_empty():
		for i in range(2):
			_st["step_max"] = maxf(
				float(_st["step_max"]), (hands[i] as Vector3).distance_to(prior[i]) / WS.M
			)
	_st["hands"] = hands
	_note_driver(beat, feet, g)
	return false


## The hands over the pull: on the grips every frame of it (and from its start without a break),
## on the driver's skinned body, the collar and the arm two points; how fast the hero's root goes.
func _note_pull(
	beat: String, both: bool, g: Dictionary, lh: Vector3, rh: Vector3, close: bool
) -> void:
	var feet: Vector3 = ctx.player.position
	var was: Vector3 = _st["hero_was"]
	if was.is_finite() and beat in ["pull", "release"]:
		var flat := feet - was
		_st["hero_v"] = maxf(float(_st["hero_v"]), Vector2(flat.x, flat.z).length() / DT / WS.M)
	_st["hero_was"] = feet
	if beat in ["pull", "release"]:
		var hist: Array = _st["hero_hist"]
		hist.append(feet)
		if hist.size() > HERO_V_WINDOW:
			var past: Vector3 = hist[hist.size() - 1 - HERO_V_WINDOW]
			var run := Vector2(feet.x - past.x, feet.z - past.z).length()
			_st["hero_v_avg"] = maxf(float(_st["hero_v_avg"]), run / (HERO_V_WINDOW * DT) / WS.M)
	if beat == "struggle" or beat == "pull":
		_st["apart"] = minf(
			float(_st["apart"]), (g["collar"] as Vector3).distance_to(g["arm"]) / WS.M
		)
		var b: Object = victim.body if victim != null and victim.body != null else null
		if b == null:
			var proxy: Variant = (traffic.get("occupants") as RefCounted).call(
				"driver_of", int(drive.get("_jack_id"))
			)
			b = (proxy as WK.Walker).body if proxy != null else null
		if b != null:
			var pts := _skin.points(b)
			var worst := 0.0
			for h: Vector3 in [lh, rh]:
				var near := INF
				for q: Vector3 in pts:
					near = minf(near, q.distance_to(h))
				worst = maxf(worst, near / WS.M)
			_st["skin_frames"] = int(_st["skin_frames"]) + 1
			if worst <= SKIN_TOL:
				_st["skin_on"] = int(_st["skin_on"]) + 1
			_st["skin_worst"] = maxf(float(_st["skin_worst"]), worst)
	if beat != "pull":
		return
	_st["pull_frames"] = int(_st["pull_frames"]) + 1
	if both:
		_st["pull_on"] = int(_st["pull_on"]) + 1
	if close:
		_st["pull_near"] = int(_st["pull_near"]) + 1
	if both and float(_st["pull_frames"]) * DT <= PULL_EARLY_S:
		_st["early_on"] = float(_st["early_on"]) + DT


## The driver: how fast their root goes, how high over the road, how near the hero's root every bone
## of theirs comes, and how far from the hero's body the door camera sees the collar.
func _note_driver(beat: String, feet: Vector3, g: Dictionary) -> void:
	if victim == null or victim.body == null or victim.body.get("skel") == null:
		return
	var root := victim.pos + victim.vis_off
	if bool(_st.get("have_root", false)) and beat == "pull":
		var flat: Vector3 = root - (_st["was"] as Vector3)
		_st["root_v"] = maxf(float(_st["root_v"]), Vector2(flat.x, flat.z).length() / DT / WS.M)
	_st["was"] = root
	_st["have_root"] = true
	var ground := ctx.collision.walk_height(root)
	_st["air"] = maxf(
		float(_st["air"]), (root.y - (ground if not is_nan(ground) else root.y)) / WS.M
	)
	if beat == "pull" or beat == "release":
		var sk: Skeleton3D = victim.body.get("skel")
		var near := INF
		for i in range(sk.get_bone_count()):
			if (
				sk.get_bone_name(i)
				in ["Root", "CharacterRoot", "Armature", "Pelvis", "neutral_bone"]
			):
				continue
			var q := (sk.global_transform * sk.get_bone_global_pose(i)).origin
			near = minf(near, Vector2(q.x - feet.x, q.z - feet.z).length())
		_st["bones"] = minf(float(_st["bones"]), near / WS.M)
	var entry: RefCounted = drive.get("entry")
	entry.call("camera", Transform3D.IDENTITY)
	var cam: Transform3D = entry.get("_cam")
	var to_target := ((g["collar"] as Vector3) - cam.origin).normalized()
	var least := INF
	for bn: String in ["Head", "Neck", "Hips"]:
		var at: Vector3 = (hero_post[bn] as Vector3) - cam.origin
		# Only what stands between the camera and the collar can hide it.
		if at.length() < ((g["collar"] as Vector3) - cam.origin).length():
			least = minf(least, rad_to_deg(to_target.angle_to(at.normalized())))
	if beat == "struggle" or beat == "pull":
		_st["view"] = minf(float(_st["view"]), least)


func _judge(label: String, r: Dictionary) -> void:
	var note := "  note: %s: pull on %d (near %d)/%d early %.2f s, skin %d/%d worst %.3f, "
	note += "apart %.2f, hero %.2f (%.2f avg) m/s, driver %.2f m/s, bones %.2f m"
	print(
		(
			note
			% [
				label,
				r["pull_on"],
				r["pull_near"],
				r["pull_frames"],
				r["early_on"],
				r["skin_on"],
				r["skin_frames"],
				r["skin_worst"],
				r["apart"],
				r["hero_v"],
				r["hero_v_avg"],
				r["root_v"],
				r["bones"]
			]
		)
	)
	var span := float(r["t_step"]) - float(r["t_reach"])
	var said := "%s: from the first reach to the step into the opening %.2f s (%.1f to %.1f)"
	K.check(fails, span >= SPAN_S.x and span <= SPAN_S.y, said % [label, span, SPAN_S.x, SPAN_S.y])
	said = "%s: both hands on the collar and the arm for %.2f s (at least %.1f), "
	said += "%.2f s of it before the pull"
	K.check(
		fails,
		float(r["on_total"]) >= HOLD_MIN_S and float(r["on_before"]) >= GRAB_LEAD_S,
		said % [label, r["on_total"], HOLD_MIN_S, r["on_before"]]
	)
	var frames := maxi(int(r["pull_frames"]), 1)
	said = "%s: the hands stay on the driver through the pull: on the grips %.2f s of its first "
	said += "%.1f s (%.2f at least), within %.2f m of them in %d of %d frames (%.0f%% at least)"
	K.check(
		fails,
		(
			float(r["early_on"]) >= PULL_EARLY_ON_S
			and float(r["pull_near"]) / float(frames) >= PULL_NEAR_FRAC
		),
		(
			said
			% [
				label,
				r["early_on"],
				PULL_EARLY_S,
				PULL_EARLY_ON_S,
				PULL_NEAR,
				r["pull_near"],
				frames,
				100.0 * PULL_NEAR_FRAC
			]
		)
	)
	var sf := maxi(int(r["skin_frames"]), 1)
	said = "%s: the hands are on the driver's skinned body (%.3f m at the worst, %.2f at most) "
	said += "in %d of %d frames of the struggle and the pull, the collar and the arm %.2f m apart "
	said += "(%.2f at least)"
	K.check(
		fails,
		float(r["skin_on"]) / float(sf) >= SKIN_FRAC and float(r["apart"]) >= GRIPS_APART,
		said % [label, r["skin_worst"], SKIN_TOL, r["skin_on"], sf, r["apart"], GRIPS_APART]
	)
	said = "%s: the hero does not run: his root goes %.1f m/s over a tenth of a second at the most "
	said += "(%.1f), %.1f m/s in a frame (%.1f)"
	K.check(
		fails,
		float(r["hero_v_avg"]) <= HERO_V_AVG and float(r["hero_v"]) <= HERO_V_MAX,
		said % [label, r["hero_v_avg"], HERO_V_AVG, r["hero_v"], HERO_V_MAX]
	)
	said = "%s: the hands never jump (%.3f m the most in a frame, %.2f at most) and stay "
	said += "below his head (%+.2f m)"
	K.check(
		fails,
		float(r["step_max"]) <= HAND_STEP_MAX and float(r["hand_up"]) <= -BELOW_HEAD,
		said % [label, r["step_max"], HAND_STEP_MAX, r["hand_up"]]
	)
	said = "%s: the driver is pulled, not thrown: %.1f m/s along the ground at the most (%.1f), "
	said += "%.2f m over the road at the most (%.2f)"
	K.check(
		fails,
		(
			float(r["root_v"]) <= ROOT_V_MAX
			and float(r["air"]) <= AIR_MAX
			and float(r["root_v"]) > 0.0
		),
		said % [label, r["root_v"], ROOT_V_MAX, r["air"], AIR_MAX]
	)
	said = "%s: the hero's root keeps %.2f m from every bone of the driver through the pull "
	said += "(%.2f m at the nearest)"
	K.check(fails, float(r["bones"]) >= ROOT_MIN, said % [label, ROOT_MIN, r["bones"]])
	said = "%s: the door camera sees the driver %.0f degrees clear of the hero's body "
	said += "(%.0f at least)"
	K.check(fails, float(r["view"]) >= VIEW_MIN, said % [label, r["view"], VIEW_MIN])
