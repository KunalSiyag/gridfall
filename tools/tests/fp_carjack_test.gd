extends SceneTree
## Carjacks (traffic's carjack.gd, the drive feature's carjack flag): by a car stopped in traffic
## with someone at the wheel the prompt is "Pull the driver out"; F holds the car while the hero
## walks to the driver's door and opens it, drags the driver out (person_hit "carjack": pulled
## from the seat over the sill and knocked down beside the door, then up, shouting and running off
## round the car to the sidewalk; the police called) and climbs in to drive. A resident's trip
## goes on on foot and they remember it; F on the way turns back and lets the car go with its
## driver; with the flag off a resident's car cannot be taken and an ambient one is taken with
## nobody pulled out. Time runs through climb_step(1/60), the player's update_view and the traffic
## feature's step.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const DOORS := preload("res://scripts/fp/traffic/car_doors.gd")
const JACK := preload("res://scripts/fp/traffic/carjack.gd")
const TRIPS := preload("res://scripts/fp/traffic/trips.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const DT := 1.0 / 60.0
const JACK_PHASES := ["walk", "align", "open", "jack", "step", "turn", "climb", "close"]
## What the one dragged out does: falls, gets up, shouts, runs.
const PULLED := [&"knockback", &"get_up", &"shout", &"run"]
## [kind, role, parked] of a vehicle and whether someone sits at its wheel.
const WHEELS := [
	["car", "ambient", false, true],
	["car", "resident", false, true],
	["car", "ambient", true, false],
	["bike", "resident", false, false],
	["bus", "bus", false, false],
	["car", "player", false, false],
]

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var drive: FpFeature
## A straight lane with free ground beside the driver's side of a car halfway along it, and the
## road tile it is on.
var lane: LG.Lane = null
var lane_tile: int = -1
## A car model whose driver's door opens.
var door_model: int = -1
## [at, cause, info] of every person_hit; the walker last hit, its reaction clips in order and
## where its drawn feet were on the first step after the hit.
var hits: Array = []
var victim: WK.Walker = null
var clips: Array = []
var first_at: Vector3 = Vector3.INF
## How many of those pulled out were drawn at the wheel first.
var drags: int = 0


func _init() -> void:
	await process_frame
	if _setup():
		_check_occupied()
		door_model = _door_model()
		if door_model >= 0 and _pick_lane():
			_check_ambient()
			_check_resident()
			K.check(fails, drags > 0, "someone drawn at the wheel is pulled out (%d)" % drags)
			_check_turn_back()
			_check_flag_off()
	K.finish(self, "FP_CARJACK_TEST", fails)


## A grown city with the hero on foot and the traffic and drive features, their time run by hand
## and both car flags on; false (a failed check) when either feature is missing.
func _setup() -> bool:
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "first"})
	ctx.player.set_process(false)
	tr = K.make_feature(ctx, "traffic")
	drive = K.make_feature(ctx, "drive")
	var ok := tr != null and drive != null
	K.check(fails, ok, "the traffic and drive features are registered")
	if not ok:
		return false
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	drive.set_process(false)
	FeatureFlags.set_override("car_doors", true)
	FeatureFlags.set_override("carjack", true)
	ctx.bus.person_hit.connect(_on_hit)
	return true


## Someone sits at the wheel of an ambient or a resident car on the road; not of a parked one, a
## bike, a bus or the player's own.
func _check_occupied() -> void:
	var wrong: Array = []
	for spec: Array in WHEELS:
		var c := VH.Car.new()
		c.kind = spec[0]
		c.role = spec[1]
		c.parked = spec[2]
		if JACK.occupied(c) != bool(spec[3]):
			wrong.append(spec)
	K.check(
		fails,
		wrong.is_empty(),
		"someone at the wheel of ambient and resident cars on the road only %s" % str(wrong)
	)


# ------------------------------------------------------------------ carjacks


## An ambient car stopped in traffic: "Pull the driver out"; F holds it while the hero walks to
## the door and opens it, the driver is dragged out beside it and knocked down (the police are
## called), gets up, shouts and runs off, and the hero climbs in and drives.
func _check_ambient() -> void:
	var c := _lane_car("ambient")
	var seated: WK.Walker = (tr.get("occupants") as RefCounted).call("driver_of", c.id)
	var t: Dictionary = drive.call("enter_target")
	var offer := bool(t.get("jack", false)) and int(t.get("id", -1)) == c.id
	offer = offer and str(drive.call("_prompt_for", t)) == "Pull the driver out"
	K.check(fails, offer, 'by a car stopped in traffic with its driver: "Pull the driver out"')
	hits.clear()
	K.check(fails, drive.call("board") == true and c.hold, "F sets off for its door, the car held")
	var r := _jack_climb(c, 16.0)
	K.check(
		fails,
		r["phases"] == JACK_PHASES,
		(
			"it walks, reaches, opens, drags the driver out, steps up, climbs in, shuts: %s"
			% str(r["phases"])
		)
	)
	K.check(
		fails,
		float(r["moved"]) < 0.01 * WS.M,
		"the car stands still until the pull (%.3f m)" % (float(r["moved"]) / WS.M)
	)
	var info: Dictionary = hits[0][2] if hits.size() == 1 else {}
	var down := hits.size() == 1 and str(hits[0][1]) == "carjack" and bool(info.get("down", false))
	K.check(fails, down, "person_hit carjack: the driver is knocked down (%s)" % str(hits))
	K.check(fails, str(info.get("crew", "")) == "police", "and the police are called")
	if down:
		_check_landing(c, hits[0][0])
	_check_drag(c, "the driver")
	if seated != null:
		var same := victim != null and victim.av == seated.av and victim.h_m == seated.h_m
		K.check(fails, same, "the one dragged out is the driver who sat there")
	else:
		print("  note: no driver was drawn in the car (no seated body to compare)")
	var mine: VH.Car = _vh().by_id.get(int(drive.get("car_id")))
	var driving := bool(drive.get("active")) and c.dead and mine != null and mine.driven
	K.check(fails, driving and mine.role == VH.PLAYER, "the hero drives off in it, its own now")
	_check_flight(c, "the driver")


## Where the driver came out (at, person_hit's point): beside car c's driver's door, level with
## its seat.
func _check_landing(c: VH.Car, at: Vector3) -> void:
	var seat: Vector3 = (tr.call("door_info", -1) as Dictionary).get("seat", Vector3.ZERO)
	var q := Transform3D(Basis(Vector3.UP, c.yaw), c.pos).affine_inverse() * at
	var out := (q.x - c.half_w) / WS.M
	var off := absf(q.z - seat.z) / WS.M
	K.check(
		fails,
		out > 0.0 and out < 0.6 and off < 0.15,
		"they come out beside the driver's door (%.2f m out, %.2f m off the seat)" % [out, off]
	)


## A driver drawn at the wheel of car c is pulled from the seat first: the drag clip, its feet
## inside the car on the first step after the hit. Nothing to check when none was drawn.
func _check_drag(c: VH.Car, who: String) -> void:
	if clips.is_empty() or clips[0] != RE.DRAG_CLIP:
		print("  note: %s was not drawn at the wheel (clips %s)" % [who, str(clips)])
		return
	drags += 1
	var q := Transform3D(Basis(Vector3.UP, c.yaw), c.pos).affine_inverse() * first_at
	K.check(
		fails,
		absf(q.x) < c.half_w,
		"%s is pulled from the seat over the sill first (%.2f m out)" % [who, q.x / WS.M]
	)


## The one dragged out of car c (left standing where it was) lies a moment, gets up, shouts and
## runs off to the sidewalk, round the car rather than through it.
func _check_flight(c: VH.Car, who: String) -> void:
	if hits.is_empty() or victim == null:
		return
	var from: Vector3 = hits[0][0]
	var inv := Transform3D(Basis(Vector3.UP, c.yaw), c.pos).affine_inverse()
	var through := 0
	var secs := 0.0

	while secs < 20.0 and (victim.edge == null or victim.on_leg):
		_tick(1.0 / 30.0)
		secs += 1.0 / 30.0
		var q := inv * (victim.pos + victim.vis_off)
		if absf(q.x) < c.half_w and absf(q.z) < c.length * 0.5:
			through += 1
	var gone := victim.pos.distance_to(from) / WS.M

	var seen := clips.filter(func(n: StringName) -> bool: return n != RE.DRAG_CLIP)
	var fled := seen.slice(0, PULLED.size()) == PULLED and victim.edge != null and gone >= 2.5
	K.check(
		fails,
		fled,
		(
			"%s: down, up, a shout, then off at a run to the sidewalk: %s, %.1f m away"
			% [who, str(clips), gone]
		)
	)
	K.check(fails, through == 0, "%s runs round the car, not through it (%d)" % [who, through])


## A resident driving to work: dragged out the same way, they remember it and their mood drops,
## and their trip goes on on foot without the car, from the sidewalk they run to.
func _check_resident() -> void:
	var r: Dictionary = ctx.residents.people[0]
	var rid := str(r["id"])
	r["mood"] = 7.0
	var trip := _drive_trip(r)
	var c := trip.car
	var t: Dictionary = drive.call("enter_target")
	var offer := bool(t.get("jack", false)) and int(t.get("id", -1)) == c.id
	K.check(fails, offer, "a resident at the wheel in traffic can be pulled out too")
	hits.clear()
	drive.call("board")
	_jack_climb(c, 16.0)
	var info: Dictionary = hits[0][2] if hits.size() == 1 else {}
	var named := str(info.get("resident_id", "")) == rid and bool(info.get("down", false))
	K.check(fails, named, "person_hit names the resident, knocked down (%s)" % str(info))
	var mem: Array = r["memory"]
	var last := str(mem.back()) if not mem.is_empty() else ""
	K.check(fails, last.contains("was carjacked by a visitor"), "they remember it: %s" % last)
	var mood := float(r["mood"])
	K.check(fails, is_equal_approx(mood, 4.0), "their mood drops by 3 (%.1f)" % mood)
	var on_foot := trip.mode == "walk" and trip.phase == "walk" and trip.car == null
	on_foot = on_foot and victim != null and trip.walker == victim and victim.resident_id == rid
	var trips: TRIPS = tr.get("trips")
	K.check(
		fails,
		on_foot and not trips.cars.has(rid) and bool(drive.get("active")),
		"their trip goes on on foot, the car theirs no more, the hero at its wheel"
	)
	_check_drag(c, "the resident")
	_check_flight(c, "the resident")


## F on the way to the door turns back: nobody is dragged out, the door stays shut and the car is
## let go with its driver.
func _check_turn_back() -> void:
	var c := _lane_car("ambient")
	hits.clear()
	drive.call("board")
	for _k in range(roundi(0.4 / DT)):
		drive.call("climb_step", DT)
		ctx.player.update_view(DT)
	drive.call("_input", K.action_event("vehicle_enter"))
	var back := not bool(drive.call("_climbing")) and not bool(drive.get("active"))
	K.check(fails, back and ctx.player.input_enabled, "F on the way to the door turns back")
	var let_go := not c.hold and not c.dead and c.door == 0.0 and hits.is_empty()
	K.check(
		fails,
		let_go and bool(tr.call("jackable", c.id)),
		"the car is let go with its driver still at the wheel"
	)


## The flag off: a resident's car in traffic is not the hero's to take, and an ambient one is
## taken the plain way with nobody pulled out.
func _check_flag_off() -> void:
	FeatureFlags.set_override("carjack", false)
	var trip := _drive_trip(ctx.residents.people[1])
	var none: Dictionary = drive.call("enter_target")
	K.check(fails, none.is_empty(), "carjack off: a resident's car in traffic cannot be taken")
	var trips: TRIPS = tr.get("trips")
	trips.trips.erase(trip.rid)
	trips.cars.erase(trip.rid)
	var c := _lane_car("ambient")
	var t: Dictionary = drive.call("enter_target")
	var plain := int(t.get("id", -1)) == c.id and not bool(t.get("jack", true))
	plain = plain and str(drive.call("_prompt_for", t)) == "Get in the car"
	K.check(fails, plain, 'an ambient one offers a plain "Get in the car"')
	hits.clear()
	drive.call("board")
	var r := _jack_climb(c, 16.0)
	K.check(
		fails,
		"jack" not in r["phases"] and bool(drive.get("active")) and hits.is_empty(),
		"and is taken with nobody pulled out: %s" % str(r["phases"])
	)
	FeatureFlags.set_override("carjack", true)


# ------------------------------------------------------------------ helpers


func _vh() -> VH:
	return tr.get("vehicles")


## The first car model traffic hands out whose driver's door opens, or -1 (a failed fixture).
func _door_model() -> int:
	var render: RefCounted = tr.get("render")
	for m: int in tr.get("_car_models"):
		var mo: RefCounted = render.call("model", m)
		var d: DOORS.Door = DOORS.of(str(mo.get("key")), mo.get("scene"))
		if d.ok:
			return m
	K.check(fails, false, "fixture: a car model whose door opens")
	return -1


## A straight lane on a road tile (not a bridge) with room beside the driver's side of a car of
## door_model halfway along it; false (a failed fixture) when there is none.
func _pick_lane() -> bool:
	var lg: LG = tr.get("lanes")
	var keys: Array = lg.tiles.keys()
	keys.sort()
	for i: int in keys:
		var info: LG.TileInfo = lg.tiles[i]
		if info.bridge:
			continue
		for l: LG.Lane in info.lanes:
			if l.kind == LG.STRAIGHT and _room_beside(l):
				lane = l
				lane_tile = i
				return true
	K.check(fails, false, "fixture: a straight lane with room beside a car on it")
	return false


## Free ground out to 2 m off the driver's side of a car of door_model halfway along l, by its
## front, middle and rear: where the hero walks, the door swings and the driver lands.
func _room_beside(l: LG.Lane) -> bool:
	var c := _vh().make("car", "ambient", tr.call("dims", door_model))
	_vh().place(c, l, 0.5)
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	var side := c.half_w
	var span := c.length * 0.45
	_vh().remove(c)
	for out: float in [0.4, 1.2, 2.0]:
		for z: float in [-span, 0.0, span]:
			var q := xf * Vector3(side + out * WS.M, 0.0, z)
			var g := ctx.collision.walk_height(q)
			if is_nan(g) or ctx.collision.is_blocked(Vector3(q.x, g, q.z), WS.PLAYER_RADIUS):
				return false
	return true


## A car of door_model of role ("ambient", or "resident" driven by resident rid) stopped halfway
## along the lane and drawn, every other vehicle gone, the hero on foot 1 m off its driver's side.
func _lane_car(role: String, rid: String = "") -> VH.Car:
	drive.call("exit", true)
	for o: VH.Car in _vh().cars.duplicate():
		_vh().remove(o)
	ctx.collision.dynamic_boxes = []
	var c := _vh().make("car", role, tr.call("dims", door_model))
	c.model = door_model
	c.driver_id = rid
	_vh().place(c, lane, 0.5)
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	ctx.player.teleport(xf * Vector3(c.half_w + 1.0 * WS.M, 0.0, -0.35 * c.length), 0.0)
	ctx.player.update_view(DT)
	tr.call("sync_visuals", DT)
	return c


## Resident r on a drive to work (or home: trips.gd's phase "drive") in a car stopped on the lane,
## bound for the road tile in front of it (the lane's own when that one has no lanes, as trips.gd
## _begin falls back to a road tile on the way).
func _drive_trip(r: Dictionary) -> TRIPS.Trip:
	var trip := TRIPS.Trip.new()
	trip.rid = str(r["id"])
	trip.mode = "car"
	trip.phase = "drive"
	trip.from_i = int(r["home"])
	trip.to_i = int(r["work"]) if int(r["work"]) >= 0 else trip.from_i
	var fr: int = ctx.directory.frontage(trip.to_i)
	trip.dest_tile = fr if (tr.get("lanes") as LG).tiles.has(fr) else lane_tile
	trip.car = _lane_car("resident", trip.rid)
	trip.car.owner = trip
	var trips: TRIPS = tr.get("trips")
	trips.trips[trip.rid] = trip
	trips.cars[trip.rid] = trip.car
	return trip


## Runs the climb in until it ends (or max_s) with traffic stepping too: the phases in order and
## how far car c moved before anyone was hit.
func _jack_climb(c: VH.Car, max_s: float) -> Dictionary:
	var entry: RefCounted = drive.get("entry")
	var phases: Array = []
	var start := c.pos
	var moved := 0.0
	var secs := 0.0
	var frame := 0
	while secs < max_s and bool(drive.call("_climbing")):
		drive.call("climb_step", DT)
		ctx.player.update_view(DT)
		_tick(DT)
		if frame % 4 == 0:
			tr.call("sync_visuals", DT * 4.0)
		frame += 1
		secs += DT
		var ph := str(entry.get("phase"))
		if not ph.is_empty() and (phases.is_empty() or phases.back() != ph):
			phases.append(ph)
		if hits.is_empty():
			moved = maxf(moved, c.pos.distance_to(start))
	return {"phases": phases, "moved": moved}


func _on_hit(at: Vector3, cause: String, info: Dictionary) -> void:
	hits.append([at, cause, info])
	victim = tr.call("_walker_by_id", int(info.get("walker", -1)))
	clips.clear()
	first_at = Vector3.INF


## One traffic step of dt, noting each new reaction clip of the one last hit.
func _tick(dt: float) -> void:
	tr.call("step", dt)
	if victim == null or victim.react == &"":
		return
	if not first_at.is_finite():
		first_at = victim.pos + victim.vis_off
	if clips.is_empty() or clips.back() != victim.react:
		clips.append(victim.react)
