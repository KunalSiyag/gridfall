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
const JT := preload("res://scripts/fp/traffic/jack_throw.gd")
const JL := preload("res://scripts/fp/traffic/jack_landing.gd")
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
var traffic: FpFeature
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
## Where their drawn feet were as they began to get up.
var rest_at: Vector3 = Vector3.INF
## How many of those pulled out were drawn at the wheel first.
var drags: int = 0
## Reading the fall clip's mixer as the thrown body lands: on, the body drawn through the flight,
## the position at touchdown.
var watch_mixer: bool = false
var body_seen: bool = false
var land_pos: float = NAN


func _init() -> void:
	await process_frame
	if _setup():
		_check_occupied()
		door_model = _door_model()
		if door_model >= 0 and _pick_lane():
			_check_ambient()
			_check_resident()
			K.check(fails, drags > 0, "someone drawn at the wheel is pulled out (%d)" % drags)
			_check_fall_clip()
			_check_arguments_taken()
			_check_in_the_way()
			_check_pop_back()
			_check_turn_back()
			_check_flag_off()
	K.finish(self, "FP_CARJACK_TEST", fails)


## A grown city with the hero on foot and the traffic and drive features, their time run by hand
## and both car flags on; false (a failed check) when either feature is missing.
func _setup() -> bool:
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "first"})
	ctx.player.set_process(false)
	traffic = K.make_feature(ctx, "traffic")
	drive = K.make_feature(ctx, "drive")
	var ok := traffic != null and drive != null
	K.check(fails, ok, "the traffic and drive features are registered")
	if not ok:
		return false
	traffic.set("auto_step", false)
	traffic.set("ambient_enabled", false)
	drive.set_process(false)
	FeatureFlags.set_override("car_doors", true)
	FeatureFlags.set_override("carjack", true)
	# The throw's look is hit_feel's: the checks do not depend on the user's flags.
	FeatureFlags.set_override("hit_feel", true)
	FeatureFlags.set_override("carjack_throw", true)
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
	var seated: WK.Walker = (traffic.get("occupants") as RefCounted).call("driver_of", c.id)
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
	_check_lands_in(info)
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
	_check_line(c)


## The blow says when the body lands (the carjack_throw flag): the haul, if they were drawn at the
## wheel and so hauled out first (their clip starts on the drag's), and then the air; nothing
## without the flag. The clips come from the climb just run.
func _check_lands_in(info: Dictionary) -> void:
	var told := info.has("lands_in")
	if not FeatureFlags.enabled("carjack_throw"):
		K.check(fails, not told, "the blow says nothing of a landing without the flag")
		return
	var hauled: bool = not clips.is_empty() and clips[0] == RE.DRAG_CLIP
	var air := JT.make(JACK.STRENGTH, JACK.JACK_FLING, Vector3.RIGHT, 1.0).air
	var want := (JT.HAUL_S if hauled else 0.0) + air
	K.check(
		fails,
		told and absf(float(info["lands_in"]) - want) < 1e-6,
		(
			"the blow says when they land: %s the air (%s s of %.3f)"
			% ["the haul and" if hauled else "just", str(info.get("lands_in")), want]
		)
	)


## Where the driver came out (at, person_hit's point): beside car c's driver's door, level with
## its seat.
func _check_landing(c: VH.Car, at: Vector3) -> void:
	var seat: Vector3 = (traffic.call("door_info", -1) as Dictionary).get("seat", Vector3.ZERO)
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
	var out := (inv * rest_at).x - c.half_w if rest_at.is_finite() else NAN
	K.check(
		fails,
		out >= 1.5 * WS.M,
		"%s was flung clear of the car's side before getting up (%.2f m out)" % [who, out / WS.M]
	)


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
	_check_lands_in(info)
	var mem: Array = r["memory"]
	var last := str(mem.back()) if not mem.is_empty() else ""
	K.check(fails, last.contains("was carjacked by a visitor"), "they remember it: %s" % last)
	var mood := float(r["mood"])
	K.check(fails, is_equal_approx(mood, 4.0), "their mood drops by 3 (%.1f)" % mood)
	var on_foot := trip.mode == "walk" and trip.phase == "walk" and trip.car == null
	on_foot = on_foot and victim != null and trip.walker == victim and victim.resident_id == rid
	var trips: TRIPS = traffic.get("trips")
	K.check(
		fails,
		on_foot and not trips.cars.has(rid) and bool(drive.get("active")),
		"their trip goes on on foot, the car theirs no more, the hero at its wheel"
	)
	_check_drag(c, "the resident")
	_check_flight(c, "the resident")


## The fall clip's back is on the ground as the body lands: with the walker's own body drawn every
## frame (as in play), the mixer's play position as the reaction's clock reaches touchdown is the
## clip's contact time, not short of it (a clip started past its start, or at the wrong pace,
## would hover there). A resident hauled out of the seat first, the body drawn since the pull.
func _check_fall_clip() -> void:
	if not FeatureFlags.enabled("carjack_throw"):
		return
	var trip := _drive_trip(ctx.residents.people[1 % ctx.residents.people.size()])
	hits.clear()
	watch_mixer = true
	land_pos = NAN
	body_seen = false
	drive.call("board")
	_jack_climb(trip.car, 16.0, 1)
	watch_mixer = false
	if not body_seen:
		print("  note: the driver's body was not drawn through the flight (no mixer to read)")
		return
	K.check(
		fails,
		not is_nan(land_pos) and absf(land_pos - JT.T_CONTACT) < 0.03,
		(
			"the fall clip is at its contact time as the body lands (%.3f of %.2f s)"
			% [land_pos, JT.T_CONTACT]
		)
	)


## The play position (s) of body b's mixer, NAN when it has none.
func _mixer_at(b: Object) -> float:
	var mode := int(b.get("mode"))
	if mode == 0 and b.get("playback") != null:
		var playback: AnimationNodeStateMachinePlayback = b.get("playback")
		return playback.get_current_play_position()
	if mode == 1 and b.get("ap") != null:
		return float((b.get("ap") as AnimationPlayer).current_animation_position)
	return NAN


## Pulled out of a car that is moving, with the flag on or off, the driver is left with none of the
## blow's arguments (the car's pace and the seat they came from): the throw took them or they were
## never needed, and nothing of them stays on the walker.
func _check_arguments_taken() -> void:
	for on: bool in [true, false]:
		FeatureFlags.set_override("carjack_throw", on)
		var c := _lane_car("ambient")
		c.v = 4.0 * WS.M
		hits.clear()
		var jack: RefCounted = traffic.get("carjack")
		var info: Dictionary = jack.call("eject", c, ctx.player.position)
		var clean := victim != null and victim.carry == Vector3.ZERO and not victim.seated
		K.check(
			fails,
			not info.is_empty() and clean,
			"flag %s: the pulled driver keeps no carry or seat" % ("on" if on else "off")
		)
	FeatureFlags.set_override("carjack_throw", true)


## The throw's line (jack_landing.gd, the carjack_throw flag): from where the driver came out to
## where they got up it is turned a few degrees to the car's rear, and passes the open door panel
## at DOOR_CLEAR (less a hand's breadth for the bounce at the end): the arms flung up as they twist
## past the panel's free end do not meet it. Not checked without the flag (straight out).
func _check_line(c: VH.Car) -> void:
	if hits.is_empty() or not rest_at.is_finite() or not FeatureFlags.enabled("carjack_throw"):
		return
	var inv := Transform3D(Basis(Vector3.UP, c.yaw), c.pos).affine_inverse()
	var a := inv * (hits[0][0] as Vector3)
	var b := inv * rest_at
	var pan := JL.panel(traffic.call("door_info", -1))
	if pan.is_empty():
		print("  note: the car's door has no panel to keep clear of")
		return
	var gap := JL.seg_gap(Vector2(a.x, a.z), Vector2(b.x, b.z), pan[0], pan[1])
	var turned := rad_to_deg(atan2(a.z - b.z, b.x - a.x))
	K.check(
		fails,
		gap >= JL.DOOR_CLEAR - 0.1 * WS.M and turned > 3.0 and turned <= 30.0,
		(
			"the flight is turned %.0f degrees to the rear and passes the open door panel at %.2f m"
			% [turned, gap / WS.M]
		)
	)


## Someone standing where the driver would land (jack_landing.gd, the carjack_throw flag): the
## throw is cut short or turned and comes to rest clear of them; the plain throw (flag off) lands
## on them as it always did; from a car moving on they are no obstacle (the body is carried down
## the road, not out to them). Door shut, so the bystander alone decides the line. And traffic's
## walker_here, which the landing's shake and thump ask: true for them, false once removed.
func _check_in_the_way() -> void:
	var on := _eject_beside(true, 0.0)
	var off := _eject_beside(false, 0.0)
	K.check(
		fails,
		not on.is_empty() and not off.is_empty(),
		"someone stood 2.1 m out: the driver is thrown, flag on and off"
	)
	if on.is_empty() or off.is_empty():
		return
	K.check(
		fails,
		float(on["gap"]) >= JL.PED_CLEAR / WS.M - 0.1 and float(off["gap"]) < 0.3,
		(
			"the lying driver is %.2f m off them (the plain throw %.2f m)"
			% [float(on["gap"]), float(off["gap"])]
		)
	)
	var moving := _eject_beside(true, 4.0 * WS.M)
	var want := JACK.OUT / WS.M + JACK.JACK_FLING  # straight out, the whole fling
	K.check(
		fails,
		not moving.is_empty() and absf(float(moving["out"]) - want) < 0.05,
		(
			"from a car moving on they are not in the way: flung %.2f m clear of its side (%.2f)"
			% [moving.get("out", NAN), want]
		)
	)


## One carjack of an ambient car with a bystander standing 2.1 m out from its door, car speed v
## (u/s): {"gap" (m, the lying body off them), "out" (m, where the driver rests off the car's
## side)}, {} when nothing was thrown. Checks walker_here of the bystander on the way.
func _eject_beside(flag: bool, v: float) -> Dictionary:
	FeatureFlags.set_override("carjack_throw", flag)
	var wk: WK = traffic.get("walkers")
	var c := _lane_car("ambient")
	c.v = v
	K.quiet_walkers(traffic)
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	var door: Dictionary = traffic.call("door_info", c.id)
	var seat: Vector3 = door.get("seat", Vector3.ZERO)
	var by := wk.make("ambient")
	var out := c.half_w + JACK.OUT + JACK.JACK_FLING * WS.M
	var stood := xf * Vector3(out, 0.0, seat.z)
	wk.stand(by, stood, 0.0)
	var here := bool(traffic.call("walker_here", by.id))
	K.check(
		fails,
		here and not bool(traffic.call("walker_here", -5)),
		"walker_here: someone in the street is there, no one by a number nobody has is not"
	)
	hits.clear()
	var jack: RefCounted = traffic.get("carjack")
	var info: Dictionary = jack.call("eject", c, ctx.player.position)
	var secs := 0.0
	while not rest_at.is_finite() and secs < 8.0:
		_tick(DT)
		secs += DT
	wk.remove(by)
	K.check(fails, not bool(traffic.call("walker_here", by.id)), "walker_here: removed, not there")
	FeatureFlags.set_override("carjack_throw", true)
	if info.is_empty() or not rest_at.is_finite():
		return {}
	var lateral := (xf.affine_inverse() * rest_at).x - c.half_w
	return {"gap": _lie_gap(first_at, rest_at, stood) / WS.M, "out": lateral / WS.M}


## A car beside the door (carjack.gd _fling): the throw is cut so the driver comes down clear of
## it by the lying body's own reach (BODY_CLEAR), and the pressing-out that keeps a body out of a
## car does not shove them back at touchdown: the furthest the feet got out is where they rest, to
## a hand's breadth (a car's flank 2.3 m out from the door: the root planned 0.7 m short of it).
func _check_pop_back() -> void:
	var react: RE = traffic.get("reactions")
	var orig: Callable = react.cars_near
	# A resident at the wheel: their body is the one drawn, hauled out of the seat.
	var c := _drive_trip(ctx.residents.people[3 % ctx.residents.people.size()]).car
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	var other := _vh().make("car", "ambient", traffic.call("dims", door_model))
	other.model = door_model
	other.parked = true
	other.slot_tile = -1
	other.pos = xf * Vector3(c.half_w + 2.3 * WS.M + other.half_w, 0.0, 0.0)
	other.yaw = c.yaw
	var half := Vector2(other.half_w, 0.5 * other.length)
	var box := [Vector2(other.pos.x, other.pos.z), other.yaw, half, 0.0, 1.5 * WS.M]
	react.cars_near = func(p: Vector3, r: float) -> Array:
		var near: Array = orig.call(p, r)
		near.append(box)
		return near
	hits.clear()
	traffic.call("sync_visuals", DT)
	var jack: RefCounted = traffic.get("carjack")
	var info: Dictionary = jack.call("eject", c, ctx.player.position)
	var inv := xf.affine_inverse()
	var furthest := 0.0
	var secs := 0.0
	while not rest_at.is_finite() and secs < 8.0:
		_tick(DT)
		traffic.call("sync_visuals", DT)  # the body drawn: its posed head is what is pressed out
		secs += DT
		furthest = maxf(furthest, (inv * (victim.pos + victim.vis_off)).x - c.half_w)
	var rest := (inv * rest_at).x - c.half_w if rest_at.is_finite() else NAN
	react.cars_near = orig
	K.check(
		fails,
		not info.is_empty() and rest_at.is_finite() and furthest - rest < 0.08 * WS.M,
		(
			"a car's flank 2.3 m out: the driver went %.2f m out and rests at %.2f, not shoved back"
			% [furthest / WS.M, rest / WS.M]
		)
	)


## How far (u) the lying body, its feet at rest and its length along the way it was flung (from
## from), is from the standing person at at: what jack_landing.gd keeps PED_CLEAR.
func _lie_gap(from: Vector3, rest: Vector3, at: Vector3) -> float:
	if not (from.is_finite() and rest.is_finite()):
		return NAN
	var way := Vector2(rest.x - from.x, rest.z - from.z).normalized()
	var a := Vector2(rest.x, rest.z)
	var q := Vector2(at.x, at.z)
	return q.distance_to(Geometry2D.get_closest_point_to_segment(q, a, a + way * JL.LIE_FAR))


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
		let_go and bool(traffic.call("jackable", c.id)),
		"the car is let go with its driver still at the wheel"
	)


## The flag off: a resident's car in traffic is not the hero's to take, and an ambient one is
## taken the plain way with nobody pulled out.
func _check_flag_off() -> void:
	FeatureFlags.set_override("carjack", false)
	var trip := _drive_trip(ctx.residents.people[1])
	var none: Dictionary = drive.call("enter_target")
	K.check(fails, none.is_empty(), "carjack off: a resident's car in traffic cannot be taken")
	var trips: TRIPS = traffic.get("trips")
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
	return traffic.get("vehicles")


## The first car model traffic hands out whose driver's door opens, or -1 (a failed fixture).
func _door_model() -> int:
	var render: RefCounted = traffic.get("render")
	for m: int in traffic.get("_car_models"):
		var mo: RefCounted = render.call("model", m)
		var d: DOORS.Door = DOORS.of(str(mo.get("key")), mo.get("scene"))
		if d.ok:
			return m
	K.check(fails, false, "fixture: a car model whose door opens")
	return -1


## A straight lane on a road tile (not a bridge) with room beside the driver's side of a car of
## door_model halfway along it; false (a failed fixture) when there is none.
func _pick_lane() -> bool:
	var lg: LG = traffic.get("lanes")
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
	var c := _vh().make("car", "ambient", traffic.call("dims", door_model))
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
	var c := _vh().make("car", role, traffic.call("dims", door_model))
	c.model = door_model
	c.driver_id = rid
	_vh().place(c, lane, 0.5)
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	ctx.player.teleport(xf * Vector3(c.half_w + 1.0 * WS.M, 0.0, -0.35 * c.length), 0.0)
	ctx.player.update_view(DT)
	traffic.call("sync_visuals", DT)
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
	trip.dest_tile = fr if (traffic.get("lanes") as LG).tiles.has(fr) else lane_tile
	trip.car = _lane_car("resident", trip.rid)
	trip.car.owner = trip
	var trips: TRIPS = traffic.get("trips")
	trips.trips[trip.rid] = trip
	trips.cars[trip.rid] = trip.car
	return trip


## Runs the climb in until it ends (or max_s) with traffic stepping too (the bodies drawn every
## sync_every frames): the phases in order and how far car c moved before anyone was hit.
func _jack_climb(c: VH.Car, max_s: float, sync_every: int = 4) -> Dictionary:
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
		if frame % sync_every == 0:
			traffic.call("sync_visuals", DT * float(sync_every))
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
	victim = traffic.call("_walker_by_id", int(info.get("walker", -1)))
	clips.clear()
	first_at = Vector3.INF
	rest_at = Vector3.INF


## One traffic step of dt, noting each new reaction clip of the one last hit.
func _tick(dt: float) -> void:
	traffic.call("step", dt)
	if victim == null or victim.react == &"":
		return
	if watch_mixer and victim.body != null:
		var active: Dictionary = (traffic.get("reactions") as RE).get("_active")
		var r: RE.Reaction = active.get(victim.id)
		if r != null and r.jack != null and r.fly_t > 0.0 and r.fly_t < r.air:
			body_seen = true
		if body_seen and r != null and r.fly_t >= r.air and is_nan(land_pos):
			land_pos = _mixer_at(victim.body)
	if not first_at.is_finite():
		first_at = victim.pos + victim.vis_off
	if victim.react == &"get_up" and not rest_at.is_finite():
		rest_at = victim.pos + victim.vis_off
	if clips.is_empty() or clips.back() != victim.react:
		clips.append(victim.react)
