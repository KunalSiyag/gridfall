extends RefCounted
## The seated hero against the cabin, for drive_feature.gd. The drive clip is a chair-height pose
## (soles half a metre under the hips, the head upright), while a car's floor sits under the seat
## and its roof little above the head: without this module the hero's legs go through the
## floorpan and the head through the roof. The car's model carries the driver markers
## (asset_paths.gd): Pedal_L / Pedal_R at the ankle targets on the footwell floor, Wheel_L /
## Wheel_R on the steering rim and Cab_Roof on the headliner above the seat. This module reads
## them from the car's full model, seats the hero's feet and hands on them through the rig's limb
## IK (hero_limbs.gd's order: left hand, right hand, left foot, right foot; the hero's left is the
## car's +X) and works out how far the hips sink into the cushion so the top of the head clears
## the roof line (drive_feature.gd reads `sink` back for the driver view and the climb out).

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")

## The top of the head rides this multiple of the hips-to-head-bone distance above the hips
## (the skull and hair counted over the head bone).
const SKULL_HAIR := 1.40
## The hips sink at most this far into the seat cushion (u).
const MAX_SINK := 0.17 * WS.M
## How fast the hips settle to their sunk seat height (halflife, s).
const HL_SINK := 0.2
## The limb IK poles in the car's frame (+Z forward): knees forward and up, elbows out and down.
const KNEE_POLE := Vector3(0.0, 0.35, 0.55) * WS.M
const ELBOW_POLE := Vector3(0.20, -0.28, 0.0) * WS.M

## How far the hips sit below the seat marker so the head clears the roof (car frame, u).
var sink: float = 0.0
## The driver contact markers in the car's frame ({name: point}), read once per car.
var _pts: Dictionary = {}
## The last IK goal per limb ([target, pole]), so the limbs ease out from where they reached.
var _goals: Array = []


## Exponential damper (SpringMath.damp's maths, after D. Holden "Spring-It-On" — the player
## folder is slice A's, which drive cannot import): half the gap closes every halflife seconds.
static func _damp(x: float, goal: float, halflife: float, dt: float) -> float:
	return lerpf(x, goal, 1.0 - pow(2.0, -dt / maxf(halflife, 1e-5)))


## A new car (or none): forget the last car's markers and sink.
func reset() -> void:
	_pts = {}
	sink = 0.0


## Lets the limbs go back to their clips, easing out from the last goals they held.
func off(rig: Variant) -> void:
	if rig == null:
		_goals = []
		return
	var i := 0
	for g: Array in _goals:
		if not g.is_empty():
			rig.call("reach", i, g[0], g[1], 0.0)
		i += 1
	_goals = []


## One step while the hero sits in the car at pos (centre, ground height) turned yaw, its seat
## marker seat (car frame) and full-model node node: the feet and hands onto the car's own
## markers, and the hips' sink worked out against the roof. Nothing to do before the drive pose
## is live (the climb in ends in it) or when the model carries no markers.
func step(
	rig: RefCounted,
	traffic: FpFeature,
	car_id: int,
	pos: Vector3,
	yaw: float,
	seat: Vector3,
	dt: float
) -> void:
	if str(rig.call("state")) != "drive":
		off(rig)
		return
	var pts := _points(traffic, car_id, seat)
	if not pts.has_all(["Pedal_L", "Pedal_R"]):
		off(rig)
		return
	var car := Transform3D(Basis(Vector3.UP, yaw), pos)
	# The hips sink until the top of the head clears the roof line (the marker sits on it).
	if dt > 0.0 and pts.has("Cab_Roof"):
		var hips: Vector3 = rig.call("bone_world", "Hips")
		var head: Vector3 = rig.call("bone_world", "Head")
		if not is_nan(hips.x) and not is_nan(head.x):
			var top := hips.y + (head.y - hips.y) * SKULL_HAIR
			var roof := pos.y + (pts["Cab_Roof"] as Vector3).y
			# The hips measured already sit `sink` down, so the overlap left adds to it.
			sink = _damp(sink, clampf(sink + top - roof, 0.0, MAX_SINK), HL_SINK, dt)
	_reach(rig, 0, pts, "Wheel_L", car, ELBOW_POLE)
	_reach(rig, 1, pts, "Wheel_R", car, Vector3(-ELBOW_POLE.x, ELBOW_POLE.y, ELBOW_POLE.z))
	_reach(rig, 2, pts, "Pedal_L", car, KNEE_POLE)
	_reach(rig, 3, pts, "Pedal_R", car, KNEE_POLE)


## The driver contact markers in the car's frame, read from the car's full model against its
## seat marker (so the live node pose cannot skew them) and cached on the node; {} when the model
## has none. The car's roster entry and its full-model node are reached through the traffic
## feature (the roster is the drive feature's own slice).
func _points(traffic: FpFeature, car_id: int, seat: Vector3) -> Dictionary:
	if traffic == null or car_id < 0 or not _pts.is_empty():
		return _pts
	var vh: Variant = traffic.get("vehicles")
	if not (vh is Object):
		return _pts
	var c: Variant = (vh as Object).get("by_id").get(car_id)
	var node: Node3D = null
	if c != null:
		node = (c as Object).get("node") as Node3D
	if node == null:
		return _pts
	if node.has_meta("drive_pts"):
		_pts = node.get_meta("drive_pts")
		return _pts
	var seat_node := node.find_child("Seat_Driver", true, false) as Node3D
	if seat_node == null:
		node.set_meta("drive_pts", {})
		return _pts
	var node_basis := node.global_transform.basis.inverse()
	var base := seat_node.global_position
	for n: String in AP.DRIVER_MARKERS:
		var m := node.find_child(n, true, false) as Node3D
		if m != null:
			_pts[n] = seat + node_basis * (m.global_position - base)
	node.set_meta("drive_pts", _pts)
	return _pts


## Puts limb i on the car-frame point `name` (world target, pole in the car's frame).
func _reach(
	rig: RefCounted, i: int, pts: Dictionary, name: String, car: Transform3D, pole: Vector3
) -> void:
	if not pts.has(name):
		return
	var t: Vector3 = car * (pts[name] as Vector3)
	var p := t + car.basis * pole
	rig.call("reach", i, t, p, 1.0)
	while _goals.size() <= i:
		_goals.append([])
	_goals[i] = [t, p]
