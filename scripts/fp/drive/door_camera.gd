extends RefCounted
## The camera beside the driver's door for the climb in and out (car_entry.gd): it looks at a point
## just outside the door from the front quarter on the driver's side, so that it sees the hero's
## front and the driver's, not the hero's back (from behind the door the hero's body hid the pull),
## and from the rear quarter when the front has too little room; pulled in front of walls. During
## the pull it pushes in slowly (PUSH of the distance) and eases out again as the hero lets go. Car
## frame: +Z forward, +X the driver's side.

const WS := preload("res://scripts/fp/world_scale.gd")

## The view's direction from the focus in the car's frame (z toward the front; mirrored for the rear
## quarter), its distance, the least room it settles for before trying the rear, the sphere it keeps
## off walls with and how much of the distance the push-in takes off.
const DIR := Vector3(0.55, 0.6, 0.7)
const DIST := 2.7 * WS.M
## A tall body (an SUV, a van: from TALL_FROM to TALL_FULL m high) has an open door panel that
## covers about half the frame from the front quarter for the first 0.3 to 0.4 s of the grab. The
## camera for it is raised and moved further to the front (DIR_TALL is added to DIR in step with
## the height, DIST_TALL to the distance) and aimed TALL_IN m further in over the door, so that it
## looks down past the panel's top edge at the seat. It must not give up fp_jack_grip_test's 5
## degrees between the driver and the hero's body: raising it alone, or moving it out sideways,
## brings the hero's head in line with the collar (van 4.6 to 4.9 degrees); moving it forward
## takes the hero's body aside (5.3 degrees without the polish, 5.7 with this). Flag look_polish.
const TALL_FROM := 1.5
const TALL_FULL := 2.0
const DIR_TALL := Vector3(0.0, 0.45, 0.5)
const DIST_TALL := 0.3 * WS.M
const TALL_IN := 0.15 * WS.M
const MIN := 1.6 * WS.M
const RADIUS := 0.25 * WS.M
const PUSH := 0.25


## The frame of the door camera for the car at xf (+Z forward) with door points pts, body side
## `side` and height `height`: {"focus", "dir", "dist"}; the camera's view of it is at().
static func frame(
	ctx: FpContext, xf: Transform3D, pts: Dictionary, side: float, height: float
) -> Dictionary:
	var hinge: Vector3 = pts["hinge"]
	var rear: Vector3 = pts["rear"]
	var seat: Vector3 = pts["seat"]
	var mid := (hinge.z + rear.z) * 0.5 if not pts.has("doorless") else seat.z
	var tall := 0.0
	if FeatureFlags.enabled("look_polish", true):
		tall = smoothstep(TALL_FROM * WS.M, TALL_FULL * WS.M, height)
	var focus := (
		xf
		* Vector3(
			side + 0.3 * WS.M - TALL_IN * tall, minf(height * 0.55, 1.1 * WS.M), mid - 0.2 * WS.M
		)
	)
	var best := {"focus": focus, "dir": Vector3.UP, "dist": 0.3 * WS.M}
	var bd := -INF
	var want := DIST + DIST_TALL * tall
	for s: float in [1.0, -1.0]:
		var d := DIR + DIR_TALL * tall
		var dir := (xf.basis * Vector3(d.x, d.y, d.z * s)).normalized()
		var dist := want
		if ctx != null and ctx.collision != null:
			var hit := ctx.collision.sweep_sphere(focus, dir, want, RADIUS)
			dist = minf(want, hit - RADIUS)
		if dist > bd + 0.05 * WS.M:
			bd = dist
			best = {"focus": focus, "dir": dir, "dist": maxf(dist, 0.3 * WS.M)}
		if bd >= MIN:
			break
	return best


## The camera of frame f pushed in by push (0 .. 1) of PUSH of its distance, looking at its focus.
static func at(f: Dictionary, push: float) -> Transform3D:
	var focus: Vector3 = f["focus"]
	var eye: Vector3 = focus + (f["dir"] as Vector3) * float(f["dist"]) * (1.0 - PUSH * push)
	return Transform3D(Basis.looking_at(focus - eye, Vector3.UP), eye)
