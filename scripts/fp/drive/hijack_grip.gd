extends RefCounted
## The hero's hands in an action hijack (drive_feature.gd, hijack.gd): at the driver's window he
## takes hold of the driver with both hands (their collar and near upper arm, as in jack_hold.gd)
## over the swing down and keeps them while the car pulls up (the hold phase), and lets go as he
## drops to the road (the drop phase): the pull that takes the driver out of the seat is the stopped
## car's (jack_hold.gd), nothing is pulled out of a moving car. Nothing here moves the hero:
## hijack.gd carries him.

const HOLD := preload("res://scripts/fp/drive/jack_hold.gd")
## He turns from facing along the car to facing the driver over the swing, and leans in to reach.
const LEAN_IN := -0.9


## The hero's body yaw at the window: from along the car (the leap's) to facing the driver across it
## as the swing comes down, for the car with heading yaw car_yaw.
static func yaw(hj: RefCounted, car_yaw: float) -> float:
	if hj.phase != "jack" and hj.phase != "hold" and hj.phase != "drop":
		return car_yaw + PI
	var k := smoothstep(0.0, hj.SWING_S, hj.t) if hj.phase == "jack" else 1.0
	return lerp_angle(car_yaw + PI, car_yaw + 0.5 * PI, k)


## One frame of the hands: while the hijack is in its jack or hold phase both go to the driver's
## grips (traffic's jack_grips: car to_id's driver at the wheel), the weight coming on over the
## swing's second half; the hero leans in to reach. In the drop they are let go (release).
static func hold(ctx: FpContext, traffic: FpFeature, hj: RefCounted) -> void:
	if hj.phase != "jack" and hj.phase != "hold":
		return
	var feet := ctx.player.position
	var g: Dictionary = traffic.call("jack_grips", hj.to_id, feet, feet.y + HOLD.REACH_TOP)
	if not (g.get("collar", Vector3(NAN, NAN, NAN)) as Vector3).is_finite():
		return
	if not (g["arm"] as Vector3).is_finite():
		g["arm"] = g["collar"]
	var k := 1.0 if hj.phase == "hold" else smoothstep(0.5 * hj.SWING_S, hj.SWING_S, hj.t)
	var lean := lerpf(0.0, LEAN_IN, k)
	HOLD.grip(ctx, g, k, ctx.player.yaw, lean, 0.0)


## The hands let go (the hijack is over, or ends half way).
static func release(ctx: FpContext) -> void:
	var zero := {"collar": Vector3.ZERO, "arm": Vector3.ZERO}
	HOLD.grip(ctx, zero, 0.0, ctx.player.yaw, 0.0, 0.25)
