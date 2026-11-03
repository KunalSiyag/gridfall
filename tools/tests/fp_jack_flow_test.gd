extends SceneTree
## The real flow of a carjack through a grown city (traffic and drive, the hero's own skeleton and
## the driver's, a frame at a time so the skeletons' modifiers run): the hero's hands are on the
## driver's collar, below the hero's own head the whole time (no overhead arm raise, no wind-up) and
## never jump a frame to the next (the hold is let go by easing, not by a snap); the driver rests
## 0.5 to 1.2 m from the door sill, no part of their body is ever more than 0.25 m above the road
## once out of the seat, their hips are not sat on the air for more than a moment (they come down
## as they come out), and the lowest vertex of their skinned body is never sunk into the road, not
## in the fall, not as the lying pose comes in; the hero starts into the car 0.45 s after the grab,
## is climbing in by 1.3 s with the driver clear of the door by then, never putting a foot on them,
## and has his hands on the wheel by 2.6 s; at a standstill and from a car at 6 m/s, for a coupe, a
## sedan, an SUV and a van, and for the coupe at 2x, 4x and 8x the sim speed too, where the driver
## is down on the road before the hero's hold is over and his hands let go of the collar as it gets
## away instead of following it (jack_pull.gd, car_entry.gd; the carjack_throw flag). The
## assertions use only what the traffic and drive features do, so they can be run on the old throw
## too (they fail on it). The curves and the reactions of the pull-out are fp_jack_pull_test's, the
## door clearance for every model fp_jack_doors_test's.

const DT := 1.0 / 60.0
const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const JL := preload("res://scripts/fp/traffic/jack_landing.gd")
const DOORS := preload("res://scripts/fp/traffic/car_doors.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const TRIPS := preload("res://scripts/fp/traffic/trips.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const SKIN := preload("res://tools/tests/fp_skin_pts.gd")
## Where the driver rests, out from the sill (m): the least and the most.
const REST := Vector2(0.5, 1.2)
## The most any part of the body may be above the road once it is out of the seat (m).
const AIR_MAX := 0.25
## The hero starts into the car within STEP_MAX_S of the grab, is climbing in by CLIMB_MAX_S and has
## his hands on the wheel (the door shutting) by SEATED_MAX_S: the climb in is the car_in clip's own
## 1.3 s, so the seat is taken about 2.5 s after the grab.
const STEP_MAX_S := 0.45
const CLIMB_MAX_S := 1.2
const SEATED_MAX_S := 2.55
## The lowest vertex of the driver's skinned body is never more than FLOOR_Y under the road (m): the
## lying pose itself rests 0.13 m under it, the sit-down and the blend into it a little more.
const FLOOR_Y := -0.22
## Once past the sill the drawn hips are above HIPS_SOFT (m) for at most HOVER_MAX_S s, never above
## HIPS_MAX: sat in the air a metre off the door is not a pull-out, it is a hover.
const HIPS_SOFT := 0.25
const HIPS_MAX := 0.5
const HOVER_MAX_S := 0.15
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
const HERO_BONES := [
	"LeftHand",
	"RightHand",
	"Head",
	"Neck",
	"Hips",
	"LeftFoot",
	"RightFoot",
	"LeftToes",
	"RightToes"
]

var fails: Array[String] = []
var ran: Array[String] = []
var ctx: FpContext
## The road lane the cars stand on, its tile, and the car model on it now.
var lane: LG.Lane = null
var lane_tile: int = -1
var door_model: int = -1
## The features under test, every person_hit and the one last hit; the next resident to try.
var traffic: FpFeature
var drive: FpFeature
var hits: Array = []
var victim: WK.Walker = null
var _ridx := 0
## The hero's skeleton and its hands, feet and head as the last skeleton update (every modifier)
## left them.
var hero_sk: Skeleton3D = null
var hero_post := {}
var hero_fresh := false
var skin := SKIN.new()
## The state of the flow under way (_flow_begin).
var _st := {}


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("hit_feel", true)
	FeatureFlags.set_override("carjack_throw", true)
	if _setup():
		var models := _models()
		if models.size() >= 17 and _pick_lane():
			await _warm()
			await _check_flow()
	K.check(fails, ran.size() == 1, "every section ran to its end (%s)" % str(ran))
	FeatureFlags.reload()
	K.finish(self, "FP_JACK_FLOW_TEST", fails)


# ------------------------------------------------------------------ the real flow


## A grown city with the hero on foot and the traffic and drive features (time run by hand, no
## ambient traffic); false (a failed check) when either feature is missing.
func _setup() -> bool:
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "first"})
	ctx.player.set_process(false)
	var made: Array[FpFeature] = []
	for id: String in ["traffic", "drive"]:
		made.append(K.make_feature(ctx, id))
	traffic = made[0]
	drive = made[1]
	var found := not made.has(null)
	K.check(fails, found, "the traffic and drive features are registered")
	if not found:
		return false
	for prop: String in ["auto_step", "ambient_enabled"]:
		traffic.set(prop, false)
	drive.set_process(false)
	for flag: String in ["car_doors", "carjack", "hit_feel", "carjack_throw"]:
		FeatureFlags.set_override(flag, true)
	ctx.bus.person_hit.connect(_on_hit)
	var rig: Variant = ctx.player.avatar.get("rig")
	hero_sk = (rig as RefCounted).get("skeleton") if rig is RefCounted else null
	K.check(fails, hero_sk != null, "the hero has a skeleton")
	if hero_sk != null:
		hero_sk.skeleton_updated.connect(_on_hero_updated)
	return found


func _on_hit(at: Vector3, cause: String, info: Dictionary) -> void:
	hits.append([at, cause, info])
	victim = traffic.call("_walker_by_id", int(info.get("walker", -1)))


## The hero's bones as every modifier left them this update (the strike pose layer is the last).
func _on_hero_updated() -> void:
	for bn: String in HERO_BONES:
		var i := hero_sk.find_bone(bn)
		if i >= 0:
			hero_post[bn] = hero_sk.global_transform * hero_sk.get_bone_global_pose(i).origin
	hero_fresh = true


## The car models traffic hands out whose door opens.
func _models() -> Array:
	var opens := func(m: int) -> bool:
		var mo: RefCounted = (traffic.get("render") as RefCounted).call("model", m)
		return DOORS.of(str(mo.get("key")), mo.get("scene")).ok
	return (traffic.get("_car_models") as Array).filter(opens)


func _key_of(m: int) -> String:
	var mo: RefCounted = (traffic.get("render") as RefCounted).call("model", m)
	return str(mo.get("key")).get_file().split(".")[0]


## The first model whose key starts with prefix, or -1.
func _model_by_key(prefix: String) -> int:
	for m: int in _models():
		if _key_of(m).begins_with(prefix):
			return m
	return -1


## The roster's avatar scenes load in the background, a frame at a time: run frames until a driver
## is drawn at the wheel.
func _warm() -> void:
	K.quiet_walkers(traffic)
	for _k in range(600):
		var seated: Variant = (traffic.get("occupants") as RefCounted).call(
			"driver_of", _driven_car().id
		)
		if seated != null:
			K.check(fails, true, "fixture: a driver drawn at the wheel (the scenes have loaded)")
			return
		await process_frame
	K.check(fails, false, "fixture: a driver drawn at the wheel (the scenes have loaded)")


## The first straight lane of a road tile (not a bridge) with free ground out to 3 m off the
## driver's side of a car halfway along it and 30 m ahead (a moving car's way); false (a failed
## fixture) for none.
func _pick_lane() -> bool:
	door_model = int(_models()[0])
	var tiles: Dictionary = (traffic.get("lanes") as LG).tiles
	var found: Array = []
	for i: int in tiles:
		var info: LG.TileInfo = tiles[i]
		for l: LG.Lane in info.lanes:
			if l.kind == LG.STRAIGHT and not info.bridge:
				found.append([i, l])
	found.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	for pair: Array in found:
		if _free_beside(pair[1]):
			lane_tile = pair[0]
			lane = pair[1]
			return true
	K.check(fails, false, "fixture: a straight lane with room beside a car on it")
	return false


func _free_beside(l: LG.Lane) -> bool:
	var vh: VH = traffic.get("vehicles")
	var car := vh.make("car", "ambient", traffic.call("dims", door_model))
	vh.place(car, l, 0.15)
	var xf := Transform3D(Basis(Vector3.UP, car.yaw), car.pos)
	vh.remove(car)
	var zs: Array[float] = [-0.45 * car.length, 0.0, 0.45 * car.length]
	for k in range(1, 9):
		zs.append(float(k) * 2.0 * WS.M + 0.45 * car.length)
	for x_m: float in [0.4, 1.2, 2.0, 3.0]:
		for z: float in zs:
			var q := xf * Vector3(car.half_w + x_m * WS.M, 0.0, z)
			var g := ctx.collision.walk_height(q)
			if is_nan(g) or ctx.collision.is_blocked(Vector3(q.x, g, q.z), WS.PLAYER_RADIUS):
				return false
	return true


## A car of door_model of role stopped on the lane, drawn, every other vehicle gone, the hero on
## foot beside its driver's side (at the lane's start for a car that will drive on).
func _lane_car(role: String, rid: String = "", at: float = 0.5) -> VH.Car:
	var vh: VH = traffic.get("vehicles")
	_clear_stage(vh)
	var c := vh.make("car", role, traffic.call("dims", door_model))
	c.model = door_model
	c.driver_id = rid
	vh.place(c, lane, at)
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	ctx.player.teleport(xf * Vector3(c.half_w + WS.M, 0.0, -0.35 * c.length), 0.0)
	ctx.player.update_view(DT)
	traffic.call("sync_visuals", DT)
	return c


## No car or driven car left, nothing in the way: the stage for the next car.
func _clear_stage(vh: VH) -> void:
	if traffic.get("_driven") != null:
		traffic.call("leave_car")
	drive.call("exit", true)
	for o: VH.Car in vh.cars.duplicate():
		vh.remove(o)
	ctx.collision.dynamic_boxes = []


## Resident r on a drive to work (or home) in a car stopped on the lane: their trip, bound for the
## road tile in front of it.
func _trip_for(r: Dictionary) -> TRIPS.Trip:
	var home := int(r["home"])
	var work := int(r["work"])
	var trip := TRIPS.Trip.new()
	trip.rid = str(r["id"])
	trip.mode = "car"
	trip.phase = "drive"
	trip.from_i = home
	trip.to_i = work if work >= 0 else home
	var frontage: int = ctx.directory.frontage(trip.to_i)
	var drivable := (traffic.get("lanes") as LG).tiles.has(frontage)
	trip.dest_tile = frontage if drivable else lane_tile
	return trip


## A resident's car of door_model on the lane with the resident drawn at its wheel (the next
## resident who can be, of up to a dozen tried), on a drive.
func _driven_car(at: float = 0.5) -> VH.Car:
	var people: Array = ctx.residents.people
	var c: VH.Car = null
	var trips: TRIPS = traffic.get("trips")
	for _try in range(12):
		var trip := _trip_for(people[_ridx % people.size()])
		_ridx += 1
		c = _lane_car("resident", trip.rid, at)
		trip.car = c
		c.owner = trip
		trips.trips[trip.rid] = trip
		trips.cars[trip.rid] = c
		traffic.call("sync_visuals", DT)
		if (traffic.get("occupants") as RefCounted).call("driver_of", c.id) != null:
			break
	return c


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
	return since > 3.2 or (_st["rest_set"] and not is_nan(rec["close"]))


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
		step <= STEP_MAX_S and climb <= CLIMB_MAX_S and close <= SEATED_MAX_S,
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
