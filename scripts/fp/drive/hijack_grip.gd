extends RefCounted
## The hero's hands in an action hijack (drive_feature.gd, hijack.gd): at the driver's window he
## takes hold of the driver with both hands (their collar and near upper arm, as in jack_hold.gd)
## during the hold the hijack's jack phase ends with, keeps them while the driver is pulled out
## through the window (the haul phase) and lets go as they are out. Nothing here moves the hero:
## hijack.gd carries him.

const WS := preload("res://scripts/fp/world_scale.gd")
const HOLD := preload("res://scripts/fp/drive/jack_hold.gd")
## He turns from facing along the car to facing the driver over the swing, and leans in to reach.
const LEAN_IN := -0.9
const LEAN_BACK := 0.7


## The hero's body yaw at the window: from along the car (the leap's) to facing the driver across it
## as the swing comes down, for the car with heading yaw car_yaw.
static func yaw(hj: RefCounted, car_yaw: float) -> float:
	if hj.phase == "in":
		return lerp_angle(car_yaw + 0.5 * PI, car_yaw + PI, smoothstep(0.0, hj.IN_S, hj.t))
	if hj.phase != "jack" and hj.phase != "haul":
		return car_yaw + PI
	var k := 1.0 if hj.phase == "haul" else smoothstep(0.0, hj.SWING_S, hj.t)
	return lerp_angle(car_yaw + PI, car_yaw + 0.5 * PI, k)


## One frame of the hands: while the hijack is in its jack or haul phase both go to the driver's
## grips (traffic's jack_grips: car to_id's driver while it is at the wheel, the one pulled out
## after), the weight coming on over the swing's second half; the hero leans in at the hold and back
## as they come out.
static func hold(ctx: FpContext, traffic: FpFeature, hj: RefCounted) -> void:
	if hj.phase != "jack" and hj.phase != "haul":
		return
	var feet := ctx.player.position
	var id: int = hj.to_id if hj.phase == "jack" else -1
	var g: Dictionary = traffic.call("jack_grips", id, feet, feet.y + HOLD.REACH_TOP)
	if not (g.get("collar", Vector3(NAN, NAN, NAN)) as Vector3).is_finite():
		return
	if not (g["arm"] as Vector3).is_finite():
		g["arm"] = g["collar"]
	var k := 1.0 if hj.phase == "haul" else smoothstep(0.5 * hj.SWING_S, hj.SWING_S, hj.t)
	var lean := (
		lerpf(0.0, LEAN_IN, k)
		if hj.phase == "jack"
		else lerpf(LEAN_IN, LEAN_BACK, smoothstep(0.0, hj.HAUL_MIN, hj.t))
	)
	HOLD.grip(ctx, g, k, ctx.player.yaw, lean, 0.0)


## True once the driver is out of the seat and let go, the haul having been held for HAUL_MIN s at
## least.
static func out(traffic: FpFeature, hj: RefCounted) -> bool:
	return hj.phase == "haul" and hj.t >= hj.HAUL_MIN and bool(traffic.call("jack_hauled"))


## The hands let go (the hijack is over, or ends half way).
static func release(ctx: FpContext) -> void:
	var zero := {"collar": Vector3.ZERO, "arm": Vector3.ZERO}
	HOLD.grip(ctx, zero, 0.0, ctx.player.yaw, 0.0, 0.25)
