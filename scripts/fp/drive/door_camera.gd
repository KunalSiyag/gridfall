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
	var focus := xf * Vector3(side + 0.3 * WS.M, minf(height * 0.55, 1.1 * WS.M), mid - 0.2 * WS.M)
	var best := {"focus": focus, "dir": Vector3.UP, "dist": 0.3 * WS.M}
	var bd := -INF
	for s: float in [1.0, -1.0]:
		var dir := (xf.basis * Vector3(DIR.x, DIR.y, DIR.z * s)).normalized()
		var dist := DIST
		if ctx.collision != null:
			var hit := ctx.collision.sweep_sphere(focus, dir, DIST, RADIUS)
			dist = minf(DIST, hit - RADIUS)
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
