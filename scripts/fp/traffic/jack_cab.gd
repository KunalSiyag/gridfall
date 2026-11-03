extends RefCounted
## Taking the driver out of a body with no door that opens (a bus, a truck, a bicycle, a scooter:
## traffic's door_info "doorless", carjack.gd): there is a solid side (the cab's skin, the frame or
## the footboard) between the seat and the road where a car has its door's opening, and the haul of
## jack_pull.gd must not draw the driver through it. The pull lifts them over it instead: the hips
## rise until the thighs clear the top of the side (SILL, metres over the road, measured on each
## model's skin at the seat: the cab of the bus is level with its belt at 1.1 m, the truck's cab
## skin reaches 1.4 m; a bicycle's top tube and a scooter's panel are lower), stay there while the
## body is across it, and come down only once past (Plan.lift, Plan.wall_k). Lengths are world units
## in the car's frame (+X out of the driver's side).

const WS := preload("res://scripts/fp/world_scale.gd")
const JP := preload("res://scripts/fp/traffic/jack_pull.gd")
## By vehicle kind: the top of the solid side over the road (m), how far over it the hips go (m: the
## thighs are under them, and for a bicycle's frame or a scooter's footboard the shins and feet too,
## which hang a sit pose's length below the hips and must come over it as well) and how far out
## from the middle line the side is (m; 0: at the body's half width: a cab's skin, a footboard's
## edge; a bicycle's frame is thin, on its middle line).
const SILL := {
	"bus": [1.1, 0.22, 0.0],
	"truck": [1.4, 0.22, 0.0],
	"bike": [0.85, 0.4, 0.12],
	"scooter": [0.75, 0.3, 0.0]
}
## The hips rise by at least LIFT_MIN.
const LIFT_MIN := 0.12 * WS.M
## The share of the way across at which the side is stays within these (the way out is short for a
## bicycle: the rider sits on its middle line).
const WALL_MIN := 0.1
const WALL_MAX := 0.6


## The {lift, wall_k} (Vector2: u, share) for the driver of a vehicle of kind with half width
## half_w whose body root starts at lateral x0 and is let go at x1 (car frame), hips hips_y over the
## road at the start (u): how far the hips are raised over the solid side and where it is on the
## way across; (0, 0) for a kind that has a door.
static func clear(kind: String, half_w: float, x0: float, x1: float, hips_y: float) -> Vector2:
	if not SILL.has(kind):
		return Vector2.ZERO
	var need := (float(SILL[kind][0]) + float(SILL[kind][1])) * WS.M - hips_y
	var span := maxf(x1 - x0, 0.1 * WS.M)
	var at: float = float(SILL[kind][2]) * WS.M
	var wall := clampf(((at if at > 0.0 else half_w) - x0) / span, WALL_MIN, WALL_MAX)
	return Vector2(maxf(need, LIFT_MIN), wall)


## The hips' height over the road (u) of a seated body whose root is root_y over it, for a body of
## stature h_m (the walker's, metres): the sit pose's hips stand SIT_HIP up (body metres).
static func hips_of(root_y: float, h_m: float) -> float:
	return root_y + JP.SIT_HIP * WS.M * h_m / JP.REF_H
