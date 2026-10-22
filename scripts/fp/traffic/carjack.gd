extends RefCounted
## Taking a car with someone at the wheel (the carjack flag; docs/fp/ARCHITECTURE.md, Driving): a
## car stopped or crawling in traffic is the player's to take, an ambient driver's or a resident's,
## and its driver is dragged out first. They come out beside the driver's door and are knocked down
## away from the car by a blow of cause "carjack" (traffic_feature.gd hit_walker: reactions.gd has
## them lie a moment, get up, shout and run off; incidents.gd has them and those who saw it
## remember it, and calls the police). They run for the sidewalk round the car's rear, not through
## it. A resident's trip goes on on foot from there (trips.gd on_carjacked); an ambient driver
## wanders on along the sidewalk. Either keeps the look they had at the wheel (occupants.gd).

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const SW := preload("res://scripts/fp/traffic/sidewalks.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const TRIPS := preload("res://scripts/fp/traffic/trips.gd")
## The driver comes out OUT beyond the body side, level with the seat, and takes a blow of STRENGTH
## (hard enough to knock them down, reactions.gd DOWN) straight out from the car. Their way off the
## road passes CLEAR out from the car's rear corner on that side.
const OUT := 0.3 * WS.M
const STRENGTH := 0.85
const CLEAR := 1.2 * WS.M

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
	var seat: Variant = (f.door_info(c.id) as Dictionary).get("seat")
	var at := xf * Vector3(c.half_w + OUT, 0.0, (seat as Vector3).z if seat != null else 0.0)
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
	if proxy != null:
		w.av = proxy.av
		w.h_m = proxy.h_m
	return f.hit_walker(w.id, src, xf.basis.x, STRENGTH, "carjack")


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
