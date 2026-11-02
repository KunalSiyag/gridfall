extends RefCounted
## Taking a car with someone at the wheel (the carjack flag; docs/fp/ARCHITECTURE.md, Driving): a
## car stopped or crawling in traffic is the player's to take, an ambient driver's or a resident's,
## and its driver is dragged out first. They come out beside the driver's door and are knocked down
## away from the car by a blow of cause "carjack" (traffic_feature.gd hit_walker: reactions.gd has
## them lie a moment, get up, shout and run off; incidents.gd has them and those who saw it remember
## it, and calls the police). Drawn at the wheel, they are dragged out of the seat over the sill
## first (reactions.gd drag_out) and the blow throws them JACK_FLING clear of the door (the
## carjack_throw flag, with hit_feel: hauled out head first, flung up on an arc and twisting,
## landing and skidding as jack_throw.gd has it, carried on at a moving car's pace; the line turned
## a few degrees, the point they are let go at moved down the car's side and the twist turned away
## from the open door panel, as the model's door asks, and the length cut to the room there is, by
## a car, a wall, a post or a bystander beside the door, jack_landing.gd: they come down in the gap,
## not through it). They run for the sidewalk round the car's rear, not through it. A resident's
## trip goes on on foot from there (trips.gd on_carjacked); an ambient driver wanders on along the
## sidewalk. Either keeps the look they had at the wheel (occupants.gd).

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const SW := preload("res://scripts/fp/traffic/sidewalks.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const TRIPS := preload("res://scripts/fp/traffic/trips.gd")
const JL := preload("res://scripts/fp/traffic/jack_landing.gd")
const JT := preload("res://scripts/fp/traffic/jack_throw.gd")
## The driver comes out OUT beyond the body side, level with the seat, and takes a blow of STRENGTH
## (hard enough to knock them down, reactions.gd DOWN) straight out from the car. Their way off the
## road passes CLEAR out from the car's rear corner on that side.
const OUT := 0.3 * WS.M
const STRENGTH := 0.85
const CLEAR := 1.2 * WS.M
const JACK_FLING := 1.8
## A car faster than CARRY_FROM (u/s) as its driver is pulled out carries them on at its pace.
const CARRY_FROM := 1.0 * WS.M
## A car beside the door (its near flank outboard of the car's own side, within the fling and
## BODY_CLEAR metres of it; not one ahead or behind in the lane) shortens the fling to the room
## there is, down to MIN_FLING metres, the body's root coming to rest BODY_CLEAR from the flank: the
## lying body's own reach (reactions.gd BODY_R and DOWN_REACH, 0.65 m, and a hand's breadth),
## within which the body is pressed back out of a car at touchdown. Between the cars a gap under
## OUT + BODY_CLEAR + MIN_FLING (1.5 m) has no room for it: it lands in the next car, pressed back.
## Cars within the door's reach along the road (half their length, SPAN_M metres, TURN_M and the
## seconds SWEEP_S of the moving car's own travel) count: they close on the place the body lands.
## TURN_M is how far along the car's side the turned line (jack_landing.gd, up to AIM_MAX either
## way, chosen after the cut) takes the landing from the point the body is let go at: it comes down
## that much behind, or ahead, of the seat's place, so a neighbour whose nose or tail is that much
## further along is as much in its way as one level with the door.
const MIN_FLING := 0.5
const BODY_CLEAR := 0.7
const SPAN_M := 1.0
const SWEEP_S := 1.5
const TURN_M := sin(JL.AIM_MAX) * JACK_FLING

var f: Object  # the traffic feature


func setup(p_f: Object) -> void:
	f = p_f


## True when c is a car on the road with someone at the wheel: an ambient driver or a resident.
static func occupied(c: VH.Car) -> bool:
	return c.kind == "car" and not c.parked and (c.role == "ambient" or c.role == "resident")


## Drags car c's driver out, the hero standing at src: they come out beside the driver's door,
## knocked down away from the car, and set off on foot once they are up. c is left for the caller
## to take (its trip let go). Returns the person_hit info, {} when nobody could be put there.
func eject(c: VH.Car, src: Vector3) -> Dictionary:
	var xf := Transform3D(Basis(Vector3.UP, c.yaw + c.vis_yaw), c.pos + c.vis_off)
	var seat: Variant = f.door_info(c.id).get("seat")
	var seat_z: float = (seat as Vector3).z if seat != null else 0.0
	# Where they come out: level with the seat, or (the carjack_throw flag) further down the car's
	# side when the open door, as far as it is open, hangs too near the seat for the flung arms to
	# clear it.
	var pan := PackedVector2Array()
	if c.door > 0.02 and JT.on():
		pan = f.door_outline(c.id, c.door)
	var out := Vector2(c.half_w + OUT, seat_z)
	var shift := JL.exit_shift(out, JACK_FLING * WS.M, pan)
	out.y -= shift
	var at := xf * Vector3(out.x, 0.0, out.y)
	var via := xf * Vector3(c.half_w + CLEAR, 0.0, -0.5 * c.length - CLEAR)
	var cell := Vector2i(roundi(via.x), roundi(via.z))
	var tile := D.idx(cell.x, cell.y) if D.in_bounds(cell.x, cell.y) else -1
	var w: WK.Walker = null
	if c.owner is TRIPS.Trip:
		w = f.trips.on_carjacked(c.owner, at, via, tile)
	else:
		w = _stranger(at, via, tile, c.yaw)
	c.owner = null
	if w == null:
		return {}
	var proxy: WK.Walker = f.occupants.driver_of(c.id)
	var seated: Node3D = proxy.body.get("root") if proxy != null and proxy.body != null else null
	var from := seated.global_position if seated != null else Vector3(NAN, NAN, NAN)
	if proxy != null:
		w.av = proxy.av
		w.h_m = proxy.h_m
	w.carry = _carry(c)
	w.seated = from.is_finite()
	var fling := _fling(c, xf, out.y)
	var push: Vector3 = xf.basis.x
	if JT.on():
		# Turned off straight out to clear the open door panel and what stands out there; from a
		# moving car the body is carried down the road: what is beside the door is not in its way.
		var still := w.carry == Vector3.ZERO
		var line := JL.throw_line(
			xf,
			out,
			fling,
			pan,
			f.ctx.collision if still else null,
			f.walkers.walkers if still else [],
			w.id
		)
		push = line["push"]
		fling = clampf(float(line["fling"]), MIN_FLING, fling)
		var turn := float(line["angle"])
		w.jack_flip = JL.spin_away(out, JL.dir_at(turn), pan)
		# Facing the car's side with the line turned off it (the arm flung up swings into the
		# door's corner otherwise); with no door open they face the way they came from.
		w.jack_face = -turn if not pan.is_empty() else 0.0
	var info: Dictionary = f.hit_walker(w.id, src, push, STRENGTH, "carjack", fling)
	# The blow's arguments, taken (or not, with the flag off) as it landed.
	w.carry = Vector3.ZERO
	w.seated = false
	w.jack_flip = 0.0
	w.jack_face = 0.0
	if not info.is_empty() and from.is_finite():
		var back := xf.basis * Vector3(0.0, 0.0, -shift) if shift > 0.0 else Vector3.ZERO
		f.reactions.drag_out(w, from, c.yaw + c.vis_yaw, back)
	return info


## The pace of car c (u/s, level, along its heading) its driver keeps as they are pulled out (the
## walker's carry, which the throw takes: the haul keeps all of it, the flight at most
## jack_throw.gd's CARRY_MAX of it); none from a car stopped or crawling.
static func _carry(c: VH.Car) -> Vector3:
	if c.v <= CARRY_FROM:
		return Vector3.ZERO
	return Vector3(sin(c.yaw + c.vis_yaw), 0.0, cos(c.yaw + c.vis_yaw)) * c.v


## The metres car c's driver is flung out of the door's side: JACK_FLING, or the room before the
## nearest other vehicle beside it when that is less (see MIN_FLING), so they come down in the gap
## between the cars and not through the next car, or in its path (the carjack_throw flag; JACK_FLING
## without it).
func _fling(c: VH.Car, xf: Transform3D, seat_z: float) -> float:
	if not JT.on():
		return JACK_FLING
	var inv := xf.affine_inverse()
	var reach := SWEEP_S * maxf(c.v, 0.0)
	var room := INF
	for o: VH.Car in f.vehicles.cars:
		if o != c and not o.dead:
			room = minf(room, _room(c, o, inv, seat_z, reach))
	return clampf((room - BODY_CLEAR * WS.M) / WS.M, MIN_FLING, JACK_FLING)


## Room (u) from where car c's driver comes out (inv: the world in c's frame, seat_z the place
## along it) to car o's near flank, INF when o is not beside the door. It is when its flank lies
## outboard of c's own side (a car ahead or behind in c's lane is not, however it sits across the
## lane: its flank is inboard of c's side) and its middle is within the door's reach along the road
## (o's own extent along it, SPAN_M and TURN_M metres and reach u: o's and the body's travel
## meanwhile). Both in c's frame, o's footprint as it lies in it (turned by the difference of their
## headings).
static func _room(c: VH.Car, o: VH.Car, inv: Transform3D, seat_z: float, reach: float) -> float:
	var q := inv * (o.pos + o.vis_off)
	var d := (o.yaw + o.vis_yaw) - (c.yaw + c.vis_yaw)
	var ext_x := absf(cos(d)) * o.half_w + absf(sin(d)) * 0.5 * o.length
	var ext_z := absf(sin(d)) * o.half_w + absf(cos(d)) * 0.5 * o.length
	var flank := q.x - ext_x
	if flank < c.half_w or absf(q.z - seat_z) > ext_z + (SPAN_M + TURN_M) * WS.M + reach:
		return INF
	return flank - (c.half_w + OUT)


## An ambient driver on foot at at, making by way of via for the sidewalk nearest it on tile and
## walking on along it the way the car was heading (yaw); null when the tile has none.
func _stranger(at: Vector3, via: Vector3, tile: int, yaw: float) -> WK.Walker:
	var near: Array = f.peds.nearest_on_tile(Vector2(via.x, via.z), tile) if tile >= 0 else []
	if near.is_empty():
		return null
	var e: SW.PedEdge = near[0]
	var u: float = near[1]
	var ahead := (f.peds.dir_at(e, u) as Vector2).dot(Vector2(sin(yaw), cos(yaw))) >= 0.0
	var w: WK.Walker = f.walkers.make("ambient")
	w.model = f.ambient.person_model.call(w.id)
	w.pos = at
	var on := {"edge": e.id, "dir": 1 if ahead else -1, "t0": u if ahead else e.length - u}
	f.walkers.start_plan(w, [{"pt": via}, {"pt": f.peds.pos_at(e, u)}, on])
	return w
