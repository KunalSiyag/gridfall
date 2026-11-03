extends "res://tools/tests/fp_jack_kit.gd"
## The real flow of a carjack through a grown city (traffic and drive, the hero's own skeleton and
## the driver's, a frame at a time so the skeletons' modifiers run): the hero's hands are on the
## driver, below the hero's own head the whole time (no overhead arm raise, no wind-up) and never
## jump a frame to the next (the hold is let go by easing, not by a snap); the driver rests 0.5 to
## 1.2 m from the door sill, no part of their body is ever more than 0.25 m above the road once out
## of the seat, their hips are not sat on the air for more than a moment (they come down as they
## come out), and the lowest vertex of their skinned body is never sunk into the road, not in the
## fall, not as the lying pose comes in; the hero steps into the car 0.55 to 1.1 s after the pull,
## is climbing in by 1.95 s with the driver clear of the door by then, never putting a foot on them,
## and has his hands on the wheel by 3.3 s; at a standstill and from a car at 6 m/s, for a coupe, a
## sedan, an SUV and a van, and for the coupe at 2x, 4x and 8x the sim speed too, where the driver
## is down on the road before the hero's hold is over and his hands let go of the driver as they get
## away instead of following them (jack_pull.gd, jack_hold.gd; the carjack_throw flag). The
## assertions use only what the traffic and drive features do. The curves and the reactions of the
## pull-out are fp_jack_pull_test's, the door clearance for every model fp_jack_doors_test's, the
## hands' grip frame by frame fp_jack_grip_test's and every way into a vehicle fp_jack_entry_test's.

const SKIN := preload("res://tools/tests/fp_skin_pts.gd")
const JL := preload("res://scripts/fp/traffic/jack_landing.gd")
## Where the driver rests, out from the sill (m): the least and the most.
const REST := Vector2(0.5, 1.2)
## The most any part of the body may be above the road once it is out of the seat (m).
const AIR_MAX := 0.25
## The hero starts into the car STEP_MIN_S to STEP_MAX_S after the pull (the driver is drawn out of
## the seat over HAUL_S and let go, and he lets go in his turn: jack_hold.gd), is climbing in by
## CLIMB_MAX_S and has his hands on the wheel (the door shutting) by SEATED_MAX_S: the climb in is
## the car_in clip's own 1.3 s, so the seat is taken about 3.2 s after the pull (the driver is drawn
## out over 0.7 s: 3.1 at 0.6).
const STEP_MIN_S := 0.55
const STEP_MAX_S := 1.1
const CLIMB_MAX_S := 1.95
const SEATED_MAX_S := 3.4
## The lowest vertex of the driver's skinned body is never more than FLOOR_Y under the road (m): the
## lying pose itself rests 0.13 m under it, the sit-down and the blend into it a little more.
const FLOOR_Y := -0.28
## Once past the sill the drawn hips are above HIPS_SOFT (m) for at most HOVER_MAX_S s, never above
## HIPS_MAX: sat in the air a metre off the door is not a pull-out, it is a hover.
const HIPS_SOFT := 0.25
const HIPS_MAX := 0.5
const HOVER_MAX_S := 0.25
## Either hand moves at most HAND_STEP_MAX (m) from one frame to the next (the driver's collar they
## follow goes at up to 9 m/s as the haul ends, 0.15 m a frame), from the grab to HAND_STEP_S s
## after it (the pull, the let go and the easing out of the hold; the hero's jog into the car, which
## starts then, swings the arms as a run does). A hold let go all at once moves them 0.5 m and more.
const HAND_STEP_MAX := 0.2
const HAND_STEP_S := 0.45
## The hero's feet stay at least FEET_MIN (m) from any followed vertex of the driver's skinned body
## from FEET_FROM_S s after the grab (the pull is over, the hero is walking into the opening) until
## the climb in: nobody walks on the man on the road. Every sixth vertex is followed
## (fp_skin_pts.gd).
const FEET_MIN := 0.12
const FEET_FROM_S := 0.45
## The hands stay at least this far below the hero's head (m) and never above their shoulders, from
## the grab to HANDS_S s after it (the pull and the let go; the climb in is the hero's own clip).
const BELOW_HEAD := 0.05
const HANDS_S := 1.2
## The models of the flow part (a key's start), its speeds (m/s) and, for the first model, the sim
## speeds it is also run at (the hero acts on real time, the driver and the traffic on the sim's:
## at 4x and 8x the driver is down on the road in a fraction of the time the hero's hold takes, and
## his hands must not follow the collar there, car_entry.gd SLIP_V).
const MODELS := ["coupe_navy", "sedan_blue", "suv_black", "van_white"]
const SPEED := 6.0
const SIM_SPEEDS := [2.0, 4.0, 8.0]
var skin := SKIN.new()
## The state of the flow under way (_flow_begin).
var _st := {}


func _init() -> void:
	if await _fixture():
		await _check_flow()
	K.check(fails, ran.size() == 1, "every section ran to its end (%s)" % str(ran))
	FeatureFlags.reload()
	K.finish(self, "FP_JACK_FLOW_TEST", fails)


# ------------------------------------------------------------------ the real flow


## Every model of MODELS at a standstill and, for the first and the last, from a car at SPEED:
## the hands, the place the driver rests, nothing in the air, the hero's way into the car.
func _check_flow() -> void:
	for key: String in MODELS:
		var m := _model_by_key(key)
		if m < 0:
			K.check(fails, false, "fixture: a %s model" % key)
			continue
		var r := await _flow(m, 0.0)
		_judge(key, r, false)
		if key == MODELS[0] or key == MODELS[3]:
			var rm := await _flow(m, SPEED * WS.M)
			_judge(key + " at 6 m/s", rm, true)
		if key == MODELS[0]:
			for scale: float in SIM_SPEEDS:
				var rf := await _flow(m, 0.0, scale)
				_judge_fast("%s at %dx the sim speed" % [key, int(scale)], rf)
	ran.append("flow")


## One carjack of a car of model m (stopped, or driving on at speed u/s) with a resident drawn at
## the wheel, taken by the hero on foot (the climb in with the real hero skeleton at every frame; a
## moving car claimed as the action hijack does). The record: "hand" (the most any hand was above
## the hero's head, m), "above_neck", "rest" (m out from the sill as they begin to get up), "air"
## (the greatest height over the road of the driver's lowest bone, then of their root, m), "step",
## "climb" (seconds from the grab to each phase), "clear" (the driver's skinned-bone distance from
## the door's outline as the climb starts, m: not asked of a moving car), "floor" (the lowest the
## driver's skinned body has been under the road once past the sill, m, negative under it),
## "hips_max" and "hover" (how high the drawn hips have been, m, and for how long above HIPS_SOFT,
## s, past the sill), "hand_step" (the most either hand moved in a frame, m, to HAND_STEP_S) and
## "feet" (the hero's feet's least distance to the driver's body, m, to the climb: not asked of a
## moving car). The traffic runs at scale times the hero's clock, as the sim speed has it.
func _flow(m: int, speed: float, scale: float = 1.0) -> Dictionary:
	_flow_begin(m, speed, scale)
	for _step in range(60 * 12):
		_flow_step()
		hero_fresh = false
		await process_frame
		if _flow_note():
			break
	ctx.sim.speed = 1
	traffic.call("set_hero_aboard", false)
	drive.call("exit", true)
	if traffic.get("_driven") != null:
		traffic.call("leave_car")
	return _st["rec"]


## The car and the hero for one flow: the state its steps share in _st.
func _flow_begin(m: int, speed: float, scale: float = 1.0) -> void:
	door_model = m
	K.quiet_walkers(traffic)
	var c := _driven_car(0.15 if speed > 0.0 else 0.5)
	hits.clear()
	victim = null
	hero_post.clear()
	var seat: Vector3 = (traffic.call("door_info", c.id) as Dictionary).get("seat", Vector3.ZERO)
	_st = {
		"c": c,
		"speed": speed,
		"scale": scale,
		"seat": seat,
		"yaw0": c.yaw,
		"t_hit": -1.0,
		"sim_t": 0.0,
		"claimed": false,
		"rest_set": false,
		"rec":
		{
			"hand": -INF,
			"above_neck": -INF,
			"rest": NAN,
			"air": -INF,
			"root_air": -INF,
			"step": NAN,
			"climb": NAN,
			"close": NAN,
			"clear": NAN,
			"floor": INF,
			"hips_max": -INF,
			"hover": 0.0,
			"hand_step": 0.0,
			"feet": INF,
			"grabbed": false
		}
	}
	if speed > 0.0:
		c.hold = false
		c.v = speed
		ctx.player.set_camera_mode("third", false)
		traffic.call("set_hero_aboard", true)
	else:
		drive.call("board")
	ctx.sim.speed = int(scale)


## One frame of the game: the hero's walk, climb or drive (a moving car's rider carried beside the
## window, then claimed as the action hijack ends), the player's view, traffic.
func _flow_step() -> void:
	var c: VH.Car = _st["c"]
	if float(_st["speed"]) > 0.0 and not _st["claimed"]:
		var xf0 := Transform3D(Basis(Vector3.UP, c.yaw + c.vis_yaw), c.pos + c.vis_off)
		var feet := xf0 * Vector3(c.half_w + 0.3 * WS.M, 0.0, (_st["seat"] as Vector3).z)
		var g := ctx.collision.walk_height(feet)
		feet.y = g if not is_nan(g) else feet.y
		ctx.player.carry(feet, c.yaw + c.vis_yaw + PI, Vector3.ZERO, true)
		if float(_st["sim_t"]) >= 1.2:
			_st["claimed"] = true
			var hj: RefCounted = drive.get("hijack")
			hj.set("to_id", c.id)
			hj.set("phase", "jack")
			drive.call("_hijack_in", traffic, feet)
			hj.call("cancel")
	elif drive.call("_climbing"):
		drive.call("climb_step", DT)
	elif bool(drive.get("active")):
		drive.call("drive_step", 0.0, 0.0, 0.0, 0.0, DT)
	ctx.player.update_view(DT)
	_st["sim_t"] = float(_st["sim_t"]) + DT
	traffic.call("step", DT * float(_st["scale"]))
	traffic.call("sync_visuals", DT)


## What one frame (after the skeletons updated) adds to the record; true when the flow is done.
func _flow_note() -> bool:
	var rec: Dictionary = _st["rec"]
	var sim_t: float = _st["sim_t"]
	if not hits.is_empty() and float(_st["t_hit"]) < 0.0:
		_st["t_hit"] = sim_t
		rec["grabbed"] = true
	if float(_st["t_hit"]) < 0.0 or victim == null:
		return false
	var since := sim_t - float(_st["t_hit"])
	var entry: RefCounted = drive.get("entry")
	var ph := str(entry.get("phase")) if entry != null else ""
	var cur: VH.Car = (traffic.get("vehicles") as VH).by_id.get(int(traffic.call("driven_id")))
	if cur == null:
		cur = _st["c"]
	_note_phases(rec, ph, since, cur)
	if hero_fresh and hero_post.has("Head") and ph != "climb" and ph != "close":
		_note_hands(rec, since)
	_note_driver(rec, cur)
	_note_body(rec, cur, since, ph)
	return since > SEATED_MAX_S + 0.1 or (_st["rest_set"] and not is_nan(rec["close"]))


## The first time the hero's way into the car reaches each phase, and the door as it starts.
func _note_phases(rec: Dictionary, ph: String, since: float, cur: VH.Car) -> void:
	if ph == "step" and is_nan(rec["step"]):
		rec["step"] = since
	if ph == "climb" and is_nan(rec["climb"]):
		rec["climb"] = since
		rec["clear"] = _door_clear(cur, victim)
	if ph == "close" and is_nan(rec["close"]):
		rec["close"] = since


## The highest either hand has been over the hero's head and neck (m), until HANDS_S after the grab.
func _note_hands(rec: Dictionary, since: float) -> void:
	if since > HANDS_S:
		return
	var up := maxf((hero_post["LeftHand"] as Vector3).y, (hero_post["RightHand"] as Vector3).y)
	rec["hand"] = maxf(rec["hand"], (up - (hero_post["Head"] as Vector3).y) / WS.M)
	rec["above_neck"] = maxf(rec["above_neck"], (up - (hero_post["Neck"] as Vector3).y) / WS.M)
	if since > HAND_STEP_S:
		return
	var hands: Array = [hero_post["LeftHand"], hero_post["RightHand"]]

	if _st.has("hands"):
		for i in range(2):
			var step := ((hands[i] as Vector3) - ((_st["hands"] as Array)[i] as Vector3)).length()
			rec["hand_step"] = maxf(rec["hand_step"], step / WS.M)
	_st["hands"] = hands


## Where the driver is, out from the sill, when they begin to get up, and how high over the road
## their body and root are once out of the seat.
func _note_driver(rec: Dictionary, cur: VH.Car) -> void:
	var c: VH.Car = _st["c"]
	var feet := victim.pos + victim.vis_off
	var car_xf := Transform3D(Basis(Vector3.UP, float(_st["yaw0"])), cur.pos)
	var out_m := ((car_xf.affine_inverse() * feet).x - c.half_w) / WS.M
	if victim.react == &"get_up" and not _st["rest_set"]:
		_st["rest_set"] = true
		rec["rest"] = out_m
	if out_m <= 0.05:
		return
	var g := ctx.collision.walk_height(feet)
	var ground := g if not is_nan(g) else feet.y
	rec["root_air"] = maxf(rec["root_air"], (feet.y - ground) / WS.M)
	rec["air"] = maxf(rec["air"], _lowest_bone(victim, ground))


## What the driver's skinned body and the hero's feet add to the record this frame: once the
## driver's root is past the sill, the height over the road of the lowest followed vertex (floor),
## of the hips (hips_max, and the time above HIPS_SOFT: hover); from FEET_FROM_S until the climb,
## the hero's feet's distance to the followed vertices (feet), the hero being on foot.
func _note_body(rec: Dictionary, cur: VH.Car, since: float, ph: String) -> void:
	var b: Object = victim.body
	if b == null or b.get("skel") == null:
		return
	var c: VH.Car = _st["c"]
	var feet := victim.pos + victim.vis_off
	var car_xf := Transform3D(Basis(Vector3.UP, float(_st["yaw0"])), cur.pos)
	if ((car_xf.affine_inverse() * feet).x - c.half_w) / WS.M > 0.05:
		_st["past_sill"] = true
	var g := ctx.collision.walk_height(feet)
	var ground := g if not is_nan(g) else feet.y
	var pts := skin.points(b)
	if bool(_st.get("past_sill", false)):
		var lo := INF
		for p: Vector3 in pts:
			lo = minf(lo, p.y)
		rec["floor"] = minf(rec["floor"], (lo - ground) / WS.M)
		var sk: Skeleton3D = b.get("skel")
		var hi := sk.find_bone("Hips")
		if hi >= 0 and victim.react == &"sit":
			var h := ((sk.global_transform * sk.get_bone_global_pose(hi)).origin.y - ground) / WS.M
			rec["hips_max"] = maxf(rec["hips_max"], h)
			rec["hover"] += DT if h > HIPS_SOFT else 0.0
	var on_foot := ph != "climb" and ph != "close" and since >= FEET_FROM_S
	if float(_st["speed"]) > 0.0 or not hero_fresh or not on_foot:
		return
	var least := INF
	for bn: String in ["LeftFoot", "RightFoot", "LeftToes", "RightToes"]:
		if hero_post.has(bn):
			for p: Vector3 in pts:
				least = minf(least, (hero_post[bn] as Vector3).distance_to(p))
	rec["feet"] = minf(rec["feet"], least / WS.M)


## The height (m) over ground (u) of the lowest bone of w's drawn body that is a part of it (the
## rig's helper bones at its origin are not), -INF when none is drawn.
func _lowest_bone(w: WK.Walker, ground: float) -> float:
	var b: Object = w.body
	if b == null or b.get("skel") == null:
		return -INF
	var sk: Skeleton3D = b.get("skel")
	var lo := INF
	for i in range(sk.get_bone_count()):
		if sk.get_bone_name(i) in ["Root", "CharacterRoot", "Armature", "Pelvis", "neutral_bone"]:
			continue
		lo = minf(lo, (sk.global_transform * sk.get_bone_global_pose(i)).origin.y)
	return (lo - ground) / WS.M


## How far (m) the driver's skinned bones are from the open door's outline as the hero starts to
## climb in: the least over their bones of the distance in plan from the outline (negative inside
## the panel's outline). INF with no door or body.
func _door_clear(c: VH.Car, w: WK.Walker) -> float:
	var b: Object = w.body
	if c == null or b == null or b.get("skel") == null:
		return INF
	var pan: PackedVector2Array = traffic.call("door_outline", c.id, 1.0)
	if pan.is_empty():
		return INF
	var inv := Transform3D(Basis(Vector3.UP, c.yaw + c.vis_yaw), c.pos + c.vis_off).affine_inverse()
	var sk: Skeleton3D = b.get("skel")
	var least := INF
	for i in range(sk.get_bone_count()):
		if sk.get_bone_name(i) in ["Root", "CharacterRoot", "Armature", "Pelvis", "neutral_bone"]:
			continue
		var p := inv * (sk.global_transform * sk.get_bone_global_pose(i)).origin
		if p.y < 0.05 * WS.M or p.y > 1.2 * WS.M:
			continue
		least = minf(least, JL.outline_dist(Vector2(p.x, p.z), pan))
	return least / WS.M


## The assertions of one flow record.
func _judge(label: String, r: Dictionary, moving: bool) -> void:
	var pulled := bool(r["grabbed"]) and not is_nan(r["rest"])
	K.check(fails, pulled, "%s: the driver is pulled out, lies, and gets up" % label)
	if not bool(r["grabbed"]):
		return
	var hand := float(r["hand"])
	var neck := float(r["above_neck"])
	var said := "%s: the hero's hands stay below his head and no higher than his shoulders " % label
	said += "(the highest %+.2f m from his head, %+.2f m from his neck)" % [hand, neck]
	K.check(fails, hand <= -BELOW_HEAD and neck <= 0.1, said)
	var rest := float(r["rest"])
	said = "%s: the driver rests %.2f m from the door's sill (%.1f to %.1f)"
	K.check(fails, rest >= REST.x and rest <= REST.y, said % [label, rest, REST.x, REST.y])
	var air := float(r["air"])
	var root := float(r["root_air"])
	said = "%s: no part of the driver is ever more than %.2f m over the road once out "
	said += "(the lowest bone %.2f m, the root %.2f m)"
	K.check(fails, air <= AIR_MAX and root <= AIR_MAX, said % [label, AIR_MAX, air, root])
	var floor_y := float(r["floor"])
	said = "%s: the driver's skinned body is never sunk into the road (the lowest vertex %.2f m, "
	said += "not under %.2f)"
	K.check(fails, floor_y >= FLOOR_Y, said % [label, floor_y, FLOOR_Y])
	var hips := float(r["hips_max"])
	var hover := float(r["hover"])
	said = "%s: the hips come down as they come out: %.2f s over %.2f m, the highest %.2f m "
	said += "(%.2f s, %.2f m at the most)"
	K.check(
		fails,
		hover <= HOVER_MAX_S and hips <= HIPS_MAX,
		said % [label, hover, HIPS_SOFT, hips, HOVER_MAX_S, HIPS_MAX]
	)
	if moving:
		return
	var step := float(r["step"])
	var climb := float(r["climb"])
	var close := float(r["close"])
	said = "%s: the hero steps into the car %.2f s after the grab, is climbing in by %.2f s and "
	said += "seated by %.2f s"
	K.check(
		fails,
		(
			step >= STEP_MIN_S
			and step <= STEP_MAX_S
			and climb <= CLIMB_MAX_S
			and close <= SEATED_MAX_S
		),
		said % [label, step, climb, close]
	)
	var clear := float(r["clear"])
	said = "%s: the driver is clear of the open door's outline as the hero climbs in (%.2f m)"
	K.check(fails, clear >= 0.0, said % [label, clear])
	var hand_step := float(r["hand_step"])
	said = "%s: the hands never jump (%.3f m the most in a frame, %.2f at most) as they let go"
	K.check(fails, hand_step <= HAND_STEP_MAX, said % [label, hand_step, HAND_STEP_MAX])
	var feet := float(r["feet"])
	said = "%s: the hero's feet keep %.2f m off the driver's body (%.2f m closest)"
	K.check(fails, feet >= FEET_MIN, said % [label, FEET_MIN, feet])


## The assertions of a flow at a sim speed above 1: the driver is pulled out and rests where they
## should, and the hero's hands stay below his head and never jump from one frame to the next (the
## driver's collar is out of their reach and on the road in a fraction of the hold: the grip slips).
func _judge_fast(label: String, r: Dictionary) -> void:
	var pulled := bool(r["grabbed"]) and not is_nan(r["rest"])
	K.check(fails, pulled, "%s: the driver is pulled out, lies, and gets up" % label)
	if not pulled:
		return
	var rest := float(r["rest"])
	var said := "%s: the driver rests %.2f m from the door's sill (%.1f to %.1f)"
	K.check(fails, rest >= REST.x and rest <= REST.y, said % [label, rest, REST.x, REST.y])
	var hand := float(r["hand"])
	said = "%s: the hero's hands stay below his head (the highest %+.2f m from it)"
	K.check(fails, hand <= -BELOW_HEAD, said % [label, hand])

	var hand_step := float(r["hand_step"])
	said = "%s: the hands never jump (%.3f m the most in a frame, %.2f at most)"
	K.check(fails, hand_step <= HAND_STEP_MAX, said % [label, hand_step, HAND_STEP_MAX])
