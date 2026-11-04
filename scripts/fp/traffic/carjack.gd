extends RefCounted
## Taking a car with someone at the wheel (the carjack flag; docs/fp/ARCHITECTURE.md, Driving): a
## car stopped or crawling in traffic is the player's to take, an ambient driver's or a resident's,
## and its driver is dragged out first. They come out beside the driver's door and go down there by
## a blow of cause "carjack" (traffic_feature.gd hit_walker: reactions.gd has them lie a moment, get
## up, shout and run off; incidents.gd has them and those who saw it remember it, and calls the
## police). Drawn at the wheel, they are dragged out of the seat over the sill first (reactions.gd
## drag_out) and the blow drops them DROP_M beyond it (the carjack_throw flag, with hit_feel: pulled
## out sideways by the collar, down onto the road beside the door and lying along the car, never in
## the air, carried on at a moving car's pace; the point they are let go at moved down the car's
## side as the model's door asks, and the distance cut to the room there is, by a car, a wall, a
## post or a bystander beside the door, jack_landing.gd: they come down in the gap, not through it).
## They run for the sidewalk round the car's rear, not through it. A resident's trip goes on on foot
## from there (trips.gd on_carjacked); an ambient driver wanders on along the sidewalk. Either keeps
## the look they had at the wheel (occupants.gd).

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const SW := preload("res://scripts/fp/traffic/sidewalks.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const TRIPS := preload("res://scripts/fp/traffic/trips.gd")
const JL := preload("res://scripts/fp/traffic/jack_landing.gd")
const JP := preload("res://scripts/fp/traffic/jack_pull.gd")
const JG := preload("res://scripts/fp/traffic/jack_grip.gd")
const JC := preload("res://scripts/fp/traffic/jack_cab.gd")
## The driver comes out OUT beyond the body side, level with the seat, and sits down DROP_M beyond
## that (their root comes to rest OUT + DROP_M from the sill: 1.15 m, never more than 1.2) by a blow
## of STRENGTH (hard enough to knock them down, reactions.gd DOWN), straight out from the car. Their
## way off the road passes CLEAR out from the car's rear corner on that side. With the carjack_throw
## flag off they come out PLAIN_OUT beyond the body side and the blow knocks them PLAIN_SLIDE metres
## clear instead, as it always did.
const OUT := 0.55 * WS.M
const PLAIN_OUT := 0.3 * WS.M
const STRENGTH := 0.85
const CLEAR := 1.2 * WS.M
const DROP_M := 0.6
const PLAIN_SLIDE := 1.8
## A car faster than CARRY_FROM (u/s) as its driver is pulled out carries them on at its pace.
const CARRY_FROM := 1.0 * WS.M
## A car beside the door (its near flank outboard of the car's own side, within the drop and
## BODY_CLEAR metres of it; not one ahead or behind in the lane) shortens the drop to the room there
## is, down to MIN_DROP metres (the root then rests 0.75 m from the sill), the body's root coming to
## rest BODY_CLEAR from the flank: the lying body's own reach (reactions.gd BODY_R and DOWN_REACH,
## 0.65 m, and a hand's breadth), within which the body is pressed back out of a car at touchdown.
## Between the cars a gap under OUT + BODY_CLEAR + MIN_DROP (1.45 m) has no room for it: it lands in
## the next car, pressed back. Cars within the door's reach along the road (half their length,
## SPAN_M metres and the seconds SWEEP_S of the moving car's own travel) count: they close on the
## place the body lands.
const MIN_DROP := 0.2
const BODY_CLEAR := 0.7
const SPAN_M := 1.0
const SWEEP_S := 1.5
## A driver with no sidewalk on their tile makes for the nearest one within NEAR_TILES tiles.
const NEAR_TILES := 3

var f: Object  # the traffic feature
## The walker id of the driver pulled out last (the hero's hands follow them: jack_collar).
var victim: int = -1


func setup(p_f: Object) -> void:
	f = p_f


## True when c is a car on the road with someone at the wheel: an ambient driver or a resident.
static func occupied(c: VH.Car) -> bool:
	if c.parked:
		return false
	if c.kind == "car":
		return c.role == "ambient" or c.role == "resident"
	# The town's working vehicles (their driver sits in the cab) and a rider on a bicycle or scooter
	# are pulled out as a driver is: they have no door of their own, see door_info.
	return c.role != VH.PLAYER and c.kind in ["bus", "truck", "bike", "scooter"]


## Drags car c's driver out, the hero standing at src: they come out beside the driver's door,
## down on the road there, and set off on foot once they are up. c is left for the caller to take
## (its trip let go). Returns the person_hit info, {} when nobody could be put there.
func eject(c: VH.Car, src: Vector3) -> Dictionary:
	var xf := Transform3D(Basis(Vector3.UP, c.yaw + c.vis_yaw), c.pos + c.vis_off)
	var seat: Variant = f.door_info(c.id).get("seat")
	var seat_z: float = (seat as Vector3).z if seat != null else 0.0
	# Where they come out: level with the seat, or (the carjack_throw flag) further down the car's
	# side when the open door, as far as it is open, hangs too near the seat for the body to clear.
	var pan := PackedVector2Array()
	if c.door > 0.02 and JP.on():
		pan = f.door_outline(c.id, c.door)
	var out := Vector2(c.half_w + (OUT if JP.on() else PLAIN_OUT), seat_z)
	# They lie along the car's side, as they sat, so the door is kept off by their feet's reach.
	var shift := JL.exit_shift(Vector2(c.half_w, seat_z), OUT + DROP_M * WS.M, pan)
	out.y -= shift
	var at := xf * Vector3(out.x, 0.0, out.y)
	var via := xf * Vector3(c.half_w + CLEAR, 0.0, -0.5 * c.length - CLEAR)
	var cell := Vector2i(roundi(via.x), roundi(via.z))
	var tile := D.idx(cell.x, cell.y) if D.in_bounds(cell.x, cell.y) else -1
	var w: WK.Walker = null
	var stranger := not (c.owner is TRIPS.Trip)
	if stranger:
		w = _stranger(at, via, tile, c.yaw)
	else:
		w = f.trips.on_carjacked(c.owner, at, via, tile)
	c.owner = null
	if w == null:
		return {}
	var from := _dress(w, c)
	w.carry = _carry(c)
	w.seated = from.is_finite()
	var drop := PLAIN_SLIDE
	if JP.on():
		drop = _drop_run(c, xf, out, w)
	var info: Dictionary = f.hit_walker(w.id, src, xf.basis.x, STRENGTH, "carjack", drop)
	if info.is_empty() and stranger:
		# The blow found no one to hit: the stand-in on the road goes again and the driver is
		# still at the wheel (claim_car leaves the car where it is).
		f.walkers.remove(w)
		w.carry = Vector3.ZERO
		w.seated = false
		return {}
	# The blow's argument, taken (or not, with the flag off) as it landed.
	w.carry = Vector3.ZERO
	w.seated = false
	if not info.is_empty() and from.is_finite():
		var back := xf.basis * Vector3(0.0, 0.0, -shift) if shift > 0.0 else Vector3.ZERO
		var lean: Vector2 = f.occupants.resist_of(c.id)
		# A body with no door: the driver is lifted over its solid side, not drawn through it.
		var x0 := (xf.affine_inverse() * from).x
		var hips := JC.hips_of(from.y - c.pos.y, w.h_m)
		var gap := JC.clear(c.kind, c.half_w, x0, out.x, hips)
		var pose := Vector4(lean.x, lean.y, gap.x, gap.y)
		f.reactions.drag_out(w, from, c.yaw + c.vis_yaw, back, pose)
	victim = w.id if not info.is_empty() else -1
	return info


## Gives walker w the look of car c's driver drawn at its wheel (their avatar and stature) and
## returns where the seated body's root is (world; NAN when none is drawn).
func _dress(w: WK.Walker, c: VH.Car) -> Vector3:
	var proxy: WK.Walker = f.occupants.driver_of(c.id)
	var seated: Node3D = proxy.body.get("root") if proxy != null and proxy.body != null else null
	var from := seated.global_position if seated != null else Vector3(NAN, NAN, NAN)
	if seated != null and f.occupants.rest_of(c.id).is_finite():
		from = f.occupants.rest_of(c.id)
	if proxy != null:
		w.av = proxy.av
		w.h_m = proxy.h_m
	return from


## The metres w is dropped beyond the door (out: where they come out, car frame): straight out of
## the door, as far as there is room beside it; from a moving car the body is carried down the road:
## what is beside the door is not in its way.
func _drop_run(c: VH.Car, xf: Transform3D, out: Vector2, w: WK.Walker) -> float:
	var still := w.carry == Vector3.ZERO
	var drop := _drop(c, xf, out.y)
	var coll: Variant = f.ctx.collision if still else null
	var run := JL.drop_run(xf, out, drop, coll, f.walkers.walkers if still else [], w.id)
	return clampf(run, MIN_DROP, drop)


## Forgets the driver pulled out last (the world is rebuilt: ids start over).
func forget() -> void:
	victim = -1


## True when a driver is pulled out the way jack_pull.gd has it (its on(): the carjack_throw flag
## with hit_feel), so the hero's part (car_entry.gd) goes with it.
static func pulls() -> bool:
	return JP.on()


## The two points the hero's hands take hold of on the driver he has (jack_grip.gd points: "collar"
## and "arm", world, NAN with no body drawn: far off or loading) seen from toward, none above top:
## car id's driver drawn at the wheel, or (id < 0) the one pulled out last, wherever they are now.
func grips(id: int, toward: Vector3, top: float = INF, side: String = "") -> Dictionary:
	var w: WK.Walker = f.occupants.driver_of(id) if id >= 0 else _victim()
	var skel: Skeleton3D = w.body.get("skel") if w != null and w.body != null else null
	return JG.points(skel, toward, top, side)


## True once the driver pulled out last is out of the seat: the haul is over and they are let go
## beside the door (the hero lets go of them then). True too when there is none to hold.
func hauled() -> bool:
	var w := _victim()
	return w == null or not f.reactions.hauling(w)


## True from the haul through the driver's fall, lie and get-up (not the shout and the run after):
## the beat the street is held at real time for at any sim speed (traffic_feature.gd sim_dt).
func busy() -> bool:
	if victim < 0:
		return false
	var w := _victim()
	return w != null and (f.reactions.hauling(w) or f.reactions.is_down(w))


## The driver pulled out last, while they are in the street (null otherwise).
func _victim() -> WK.Walker:
	for w: WK.Walker in f.walkers.walkers:
		if w.id == victim and not w.dead:
			return w
	return null


## The pace of car c (u/s, level, along its heading) its driver keeps as they are pulled out (the
## walker's carry, which the pull-out takes: the haul keeps all of it, the slide at most
## jack_pull.gd's CARRY_MAX of it); none from a car stopped or crawling.
static func _carry(c: VH.Car) -> Vector3:
	if c.v <= CARRY_FROM:
		return Vector3.ZERO
	return Vector3(sin(c.yaw + c.vis_yaw), 0.0, cos(c.yaw + c.vis_yaw)) * c.v


## The metres car c's driver is dropped beyond the door's side: DROP_M, or the room before the
## nearest other vehicle beside it when that is less (see MIN_DROP), so they come down in the gap
## between the cars and not through the next car, or in its path.
func _drop(c: VH.Car, xf: Transform3D, seat_z: float) -> float:
	return clampf((_nearest(c, xf, seat_z) - BODY_CLEAR * WS.M) / WS.M, MIN_DROP, DROP_M)


## The least room (u) of _room over the vehicles beside car c's door: INF with none.
func _nearest(c: VH.Car, xf: Transform3D, seat_z: float) -> float:
	var inv := xf.affine_inverse()
	var reach := SWEEP_S * maxf(c.v, 0.0)
	var room := INF
	for o: VH.Car in f.vehicles.cars:
		if o != c and not o.dead:
			room = minf(room, _room(c, o, inv, seat_z, reach))
	return room


## Room (u) from where car c's driver comes out (inv: the world in c's frame, seat_z the place
## along it) to car o's near flank, INF when o is not beside the door. It is when its flank lies
## outboard of c's own side (a car ahead or behind in c's lane is not, however it sits across the
## lane: its flank is inboard of c's side) and its middle is within the door's reach along the road
## (o's own extent along it, SPAN_M metres and reach u: o's and the body's travel meanwhile). Both
## in c's frame, o's footprint as it lies in it (turned by the difference of their headings).
static func _room(c: VH.Car, o: VH.Car, inv: Transform3D, seat_z: float, reach: float) -> float:
	var q := inv * (o.pos + o.vis_off)
	var d := (o.yaw + o.vis_yaw) - (c.yaw + c.vis_yaw)
	var ext_x := absf(cos(d)) * o.half_w + absf(sin(d)) * 0.5 * o.length
	var ext_z := absf(sin(d)) * o.half_w + absf(cos(d)) * 0.5 * o.length
	var flank := q.x - ext_x
	if flank < c.half_w or absf(q.z - seat_z) > ext_z + SPAN_M * WS.M + reach:
		return INF
	return flank - (c.half_w + OUT)


## An ambient driver on foot at at, making by way of via for the sidewalk nearest it (on tile, else
## on the nearest tile round it that has one, up to NEAR_TILES away) and walking on along it the way
## the car was heading (yaw). With no sidewalk anywhere near (a bridge, a track) they walk to via
## and stand there: never nobody.
func _stranger(at: Vector3, via: Vector3, tile: int, yaw: float) -> WK.Walker:
	var near := _edge_near(Vector2(via.x, via.z), tile)
	var w: WK.Walker = f.walkers.make("ambient")
	w.model = f.ambient.person_model.call(w.id)
	w.pos = at
	if near.is_empty():
		f.walkers.start_plan(w, [{"pt": via}])
		return w
	var e: SW.PedEdge = near[0]
	var u: float = near[1]
	var ahead := (f.peds.dir_at(e, u) as Vector2).dot(Vector2(sin(yaw), cos(yaw))) >= 0.0
	var on := {"edge": e.id, "dir": 1 if ahead else -1, "t0": u if ahead else e.length - u}
	f.walkers.start_plan(w, [{"pt": via}, {"pt": f.peds.pos_at(e, u)}, on])
	return w


## [edge, u] of the sidewalk nearest p: on tile if it has one, else on the nearest of the tiles
## round it (within NEAR_TILES of it); [] when there is none.
func _edge_near(p: Vector2, tile: int) -> Array:
	if tile < 0:
		return []
	var best: Array = f.peds.nearest_on_tile(p, tile)
	if not best.is_empty():
		return best
	var bd := INF
	var cx := D.tx(tile)
	var cy := D.ty(tile)
	for dy in range(-NEAR_TILES, NEAR_TILES + 1):
		for dx in range(-NEAR_TILES, NEAR_TILES + 1):
			if not D.in_bounds(cx + dx, cy + dy) or (dx == 0 and dy == 0):
				continue
			var hit: Array = f.peds.nearest_on_tile(p, D.idx(cx + dx, cy + dy))
			if hit.is_empty():
				continue
			var q: Vector3 = f.peds.pos_at(hit[0], hit[1])
			var d := Vector2(q.x, q.z).distance_to(p)
			if d < bd:
				bd = d
				best = hit
	return best
