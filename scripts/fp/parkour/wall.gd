extends RefCounted
## Where the hero can hang on a wall (the parkour feature's wall climb; climb.gd moves the body
## on it). A wall is the face of the CollisionWorld boxes (axis-aligned) that a jump press meets,
## too tall to climb onto at once. Its frame is {"u": the unit xz axis into the face, "side": the
## unit xz axis along it (to the right of a body facing it), "face": where the face is along u}; a
## spot on it is (a, y), a along side and y the height of the feet. A body hangs R off the face
## with wall behind its hands and feet, HALF either side, and room for it in front of the wall.
## Lengths are world units.

const WS := preload("res://scripts/fp/world_scale.gd")
const MOVES := preload("res://scripts/fp/parkour/moves.gd")

const R := WS.PLAYER_RADIUS
## The hands and the feet at rest on a body hanging with its feet at (0, 0): (along the face, up,
## out from it); left hand, right hand, left foot, right foot.
const REST := [
	Vector3(-0.25, 1.68, 0.04) * WS.M,
	Vector3(0.25, 1.68, 0.04) * WS.M,
	Vector3(-0.17, 0.38, 0.14) * WS.M,
	Vector3(0.17, 0.38, 0.14) * WS.M,
]
## Where the elbows and the knees bend toward, the same way: elbows out and back off the wall,
## knees out and into it.
const POLES := [
	Vector3(-0.6, 1.0, 0.6) * WS.M,
	Vector3(0.6, 1.0, 0.6) * WS.M,
	Vector3(-0.5, 0.6, -0.2) * WS.M,
	Vector3(0.5, 0.6, -0.2) * WS.M,
]
## The wall stands behind the body HALF either side of it, from LOW (the feet's holds) to HIGH
## (the chest) above its feet, looking IN behind the face.
const HALF := 0.5 * WS.M
const LOW := 0.3 * WS.M
const HIGH := 1.2 * WS.M
const IN := 0.05 * WS.M
## The feet hang at most GRIP under the top (the hands on its edge), and a leap onto a wall takes
## them GRAB_RISE above the ground.
const GRIP := 1.55 * WS.M
const GRAB_RISE := 0.5 * WS.M
## The body's room in front of the wall: a column ROOM_R round and ROOM_H tall (to the hands).
const ROOM_R := 0.9 * R
const ROOM_H := 2.0 * WS.M
## Boxes within NEAR of the body are looked at, and up to STACK of them stacked behind a face.
const NEAR := 3.0 * WS.M
const STACK := 8


## The wall a jump press with the feet at pos meets heading along dir (xz) at speed (u/s): its
## frame with the spot the body leaps to ("a", "y") and how high the wall stands there ("top"), or
## {} (no wall there, one low enough to climb onto, or no room to hang on it).
static func grab(col: CollisionWorld, pos: Vector3, dir: Vector3, speed: float) -> Dictionary:
	var d := Vector2(dir.x, dir.z)
	if col == null or d.length_squared() < 1e-12:
		return {}
	var face := MOVES.find_face(col, pos, d.normalized(), MOVES.REACH + MOVES.REACH_T * speed)
	if face.is_empty():
		return {}
	var u: Vector2 = face["u"]
	var side := Vector2(-u.y, u.x)
	var o := Vector2(pos.x, pos.z)
	var w := {"u": u, "side": side, "face": o.dot(u) + float(face["face"])}
	var a := o.dot(side)
	var boxes := col.boxes_near(pos, NEAR)
	var top := top_at(boxes, w, a, pos.y + LOW)
	if is_nan(top) or top <= pos.y + MOVES.CLIMB_MAX:
		return {}
	var y := minf(pos.y + GRAB_RISE, top - GRIP)
	if not hang_ok(col, boxes, w, a, y):
		return {}
	w["a"] = a
	w["y"] = y
	w["top"] = top
	return w


## True when a body can hang at (a, y) on the wall w: wall behind it HALF either side from LOW to
## HIGH, and room for it in front of the wall over dry ground. boxes are the boxes near it.
static func hang_ok(
	col: CollisionWorld, boxes: Array[AABB], w: Dictionary, a: float, y: float
) -> bool:
	for da: float in [-HALF, HALF]:
		for h: float in [LOW, HIGH]:
			if is_nan(_top_of(boxes, point(w, a + da, y + h, -IN))):
				return false
	return not col.body_blocked(point(w, a, y, R), ROOM_R, ROOM_H)


## How high the wall w stands at a (along it) from height y up: the top of the boxes stacked just
## behind the face there, NAN with no wall at y.
static func top_at(boxes: Array[AABB], w: Dictionary, a: float, y: float) -> float:
	var top := NAN
	var p := point(w, a, y, -IN)
	for _k in range(STACK):
		var t := _top_of(boxes, p)
		if is_nan(t):
			break
		top = t
		p.y = t + 1e-5
	return top


## The ground under a body hanging at (a, y) on the wall w: what its feet would come down on, NAN
## over water.
static func ground_at(col: CollisionWorld, w: Dictionary, a: float, y: float) -> float:
	return col.support_height(point(w, a, y, R), ROOM_R, y, 0.0)


## The world point at (a, y) on the wall w, out off its face (negative: behind it).
static func point(w: Dictionary, a: float, y: float, out: float) -> Vector3:
	var u: Vector2 = w["u"]
	var side: Vector2 = w["side"]
	var xz := side * a + u * (float(w["face"]) - out)
	return Vector3(xz.x, y, xz.y)


## The body yaw (radians) facing the wall w.
static func yaw(w: Dictionary) -> float:
	var u: Vector2 = w["u"]
	return atan2(-u.x, -u.y)


## The highest top of the boxes p is inside, NAN outside them all.
static func _top_of(boxes: Array[AABB], p: Vector3) -> float:
	var top := NAN
	for b: AABB in boxes:
		if p.y < b.position.y or p.y >= b.end.y or (not is_nan(top) and b.end.y <= top):
			continue
		if p.x > b.position.x and p.x < b.end.x and p.z > b.position.z and p.z < b.end.z:
			top = b.end.y
	return top
