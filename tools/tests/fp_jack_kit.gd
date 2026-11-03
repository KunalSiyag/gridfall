extends SceneTree
## The fixture the carjack flow tests share (fp_jack_flow_test.gd, fp_jack_grip_test.gd,
## fp_jack_entry_test.gd extend this): a grown city with the hero on foot, the traffic and drive
## features (time run by hand), a straight lane with room beside a car on it, a car of a chosen
## model stopped on it with a resident drawn at its wheel, and the hero's skeleton read as every
## modifier left it.

const DT := 1.0 / 60.0
const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const DOORS := preload("res://scripts/fp/traffic/car_doors.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const TRIPS := preload("res://scripts/fp/traffic/trips.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
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


## Brings the fixture up: the hit_feel and carjack_throw flags on, the city, the features, a lane
## and a driver drawn at a wheel; false (a failed check) when any is missing.
func _fixture() -> bool:
	await process_frame
	FeatureFlags.set_override("hit_feel", true)
	FeatureFlags.set_override("carjack_throw", true)
	if not _setup() or _models().size() < 17 or not _pick_lane():
		return false
	await _warm()
	return true


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
