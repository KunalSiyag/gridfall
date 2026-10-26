extends RefCounted
## Drivers seated in the moving vehicles nearest the camera. Only while a vehicle draws its full
## model: those have see-through glass, a cabin and a Seat_Driver marker at the driver's hip
## point (tools/blender/realcity/vehicles2.py); the merged far LODs have opaque glass. A driver is
## the car's resident (people.dress picks the same avatar and stature the resident walks with) or
## an ambient body from the city seed, posed once in the sit loop with its mixers off, so a
## seated body costs its draws and nothing per frame beyond its transform. A bicycle's rider
## pedals instead (the ride loop, casting a shadow), on every bicycle drawn in full (a bicycle's
## far LOD carries a rough rider of its own).

const WS := preload("res://scripts/fp/world_scale.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const PPL := preload("res://scripts/fp/traffic/people.gd")
const KIT := preload("res://scripts/fp/traffic/people_kit.gd")
const CAP := 12
const RANGE := 30.0 * WS.M
## Riders: their own cap, out to where render.gd stops drawing the full bicycle (NEAR).
const BIKE_CAP := 10
const BIKE_RANGE := 40.0 * WS.M
const SEAT_NODE := "Seat_Driver"
## The driver's contact markers in the full model (vehicles2.py): the feet on the footwell floor
## and the hands on the rim, as for the player (drive/seat_pose.gd). A model without them keeps
## the plain sit pose.
const DRIVER_MARKERS := ["Pedal_L", "Pedal_R", "Wheel_L", "Wheel_R", "Cab_Roof"]
## The top of the head rides this multiple of the hips-to-head-bone distance above the hips (the
## skull and hair over the head bone), as in seat_pose.gd.
const SKULL_HAIR := 1.40
## The hips sink at most this far into the seat cushion (u), as in seat_pose.gd.
const MAX_SINK := 0.17 * WS.M
## The sit loop is held at this time (s): hands on the lap, head level.
const SIT: StringName = &"sit"
const SIT_AT := 1.0
## One turn of a bicycle's cranks; held each frame at the turn render.gd gave the cranks
## (crank_th on the node), so the feet stay on the pedals.
const RIDE: StringName = &"ride"
## The pedals from the cranks' axle and the wrists from the saddle (m, +Z forward; vehicles2.py
## bicycle(), as in procedural_clips.gd's ride clip).
const PEDAL_X := 0.11
const CRANK_R := 0.17
const WRIST := Vector3(0.26, 0.06, 0.54)
const LIMBS := ["UpperLeg", "LowerLeg", "Foot", "Toes", "UpperArm", "LowerArm", "Hand"]
## Walker ids seed ambient dressing; drivers use their own range so they do not copy a walker.
const PROXY_ID := 1 << 24

var people: PPL
## car id -> [the Walker proxy holding the body, its Hips in CharacterRoot space, riding(, the
## saddle point, the limb bones)]
var _by_car: Dictionary = {}
var seated: int = 0
## How many of the seated are riding bicycles.
var riding: int = 0


func setup(p_people: PPL) -> void:
	people = p_people
	_by_car.clear()
	seated = 0
	riding = 0


## Seats a driver in each of the CAP nearest moving vehicles within RANGE (a rider on each of the
## BIKE_CAP nearest bicycles within BIKE_RANGE) that show their full model, and releases the
## rest. Call between people.begin and people.finish, after render.draw_car.
func sync(cars: Array, cam: Vector3, residents: Variant) -> void:
	var cands: Array = []
	for c: VH.Car in cars:
		if c.dead or c.parked or c.far or c.role == VH.PLAYER:
			continue
		if c.node == null or not c.node.visible:
			continue
		var d := cam.distance_to(c.pos)
		if d > (BIKE_RANGE if c.kind == "bike" else RANGE):
			continue
		var seat: Variant = seat_point(c.node)
		if seat != null:
			cands.append([d, c, seat])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var keep := {}
	var left := {false: CAP, true: BIKE_CAP}
	for cand: Array in cands:
		var c: VH.Car = cand[1]
		var bike := c.kind == "bike"
		if int(left[bike]) <= 0:
			continue
		left[bike] = int(left[bike]) - 1
		var e: Array = _by_car.get(c.id, [])
		if e.is_empty():
			e = _seat_driver(c, residents)
			if e.is_empty():
				continue
			_by_car[c.id] = e
		_place(e, c, cand[2])
		if e[2]:
			_pedal(e, c, float(c.node.get_meta("crank_th", 0.0)))
		keep[c.id] = true
	riding = 0
	for id: int in _by_car.keys():
		if not keep.has(id):
			people.release((_by_car[id] as Array)[0])
			_by_car.erase(id)
		elif (_by_car[id] as Array)[2]:
			riding += 1
	seated = _by_car.size()


## Releases every seated body.
func clear() -> void:
	if people != null:
		for e: Array in _by_car.values():
			people.release(e[0])
	_by_car.clear()
	seated = 0
	riding = 0


## The seated body in car id (null when it has no driver drawn).
func body_of(id: int) -> PPL.Body:
	var e: Array = _by_car.get(id, [])
	return (e[0] as WK.Walker).body if not e.is_empty() else null


## The driver drawn in car id (the stand-in walker carrying its avatar and stature), or null.
func driver_of(id: int) -> WK.Walker:
	var e: Array = _by_car.get(id, [])
	return e[0] if not e.is_empty() else null


## True when the body drawn in car id is pedalling a bicycle.
func is_riding(id: int) -> bool:
	var e: Array = _by_car.get(id, [])
	return not e.is_empty() and bool(e[2])


func _seat_driver(c: VH.Car, residents: Variant) -> Array:
	var w := WK.Walker.new()
	w.id = PROXY_ID + c.id
	w.resident_id = c.driver_id
	people.dress(w, residents)
	if w.av < 0 or not people.seat(w):
		return []
	var ride: bool = c.kind == "bike" and w.body.ap.has_animation(RIDE)
	var e := [w, _pose_seated(w.body, ride), ride]
	if ride:
		e.append_array([seat_point(c.node), _limbs(w.body.skel)])
		return e
	# A car driver gets the player's treatment (drive/seat_pose.gd): hands on the rim, feet on the
	# footwell floor and the hips sunk until the head clears the roof line, so their feet do not
	# hang through the floorpan the chair-height sit clip leaves them at. The sink is measured on
	# the first place (below), the body being static.
	var pts := driver_points(c.node)
	if pts.has("Pedal_L") and pts.has("Wheel_L"):
		e.append_array([pts, _limbs(w.body.skel), -1.0])
	return e


## Holds b still in the sit pose (mixers off, no shadow: the car casts one), or at the start of
## the ride loop with its shadow on; returns its Hips in CharacterRoot space.
static func _pose_seated(b: PPL.Body, ride: bool = false) -> Vector3:
	b.tree.active = false
	b.ap.active = true
	b.ap.stop()
	b.ap.speed_scale = 1.0
	b.ap.play(RIDE if ride else SIT)
	b.ap.seek(0.0 if ride else SIT_AT, true)
	b.ap.advance(0.0)
	b.ap.active = false
	b.shadow = 1 if ride else 0
	var cast := (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if ride
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	for gi: GeometryInstance3D in b.meshes:
		gi.cast_shadow = cast
	if b.box != null:
		b.box.visible = false
	var hips := b.skel.find_bone("Hips")
	if hips < 0:
		return Vector3.ZERO
	var skel_xf := b.root.global_transform.affine_inverse() * b.skel.global_transform
	return skel_xf * KIT.pose(b.skel, hips).origin


## Poses rider e th radians into the turn of c's cranks (0: left pedal at the top): the ride clip
## at that point, then each leg bent so its toes are on its pedal and each arm so its wrist is on
## its grip, as the bodies differ from the one the clip was posed on.
func _pedal(e: Array, c: VH.Car, th: float) -> void:
	var b: PPL.Body = (e[0] as WK.Walker).body
	b.ap.active = true
	b.ap.seek(fposmod(th / TAU, 1.0) * b.ap.get_animation(RIDE).length, true)
	b.ap.active = false
	var crank := c.node.get_meta("crank") as Node3D if c.node.has_meta("crank") else null
	if crank == null or e.size() < 4:
		return
	var sk := b.skel
	var to_sk := sk.global_transform.affine_inverse()
	var basis := c.node.global_transform.basis.orthonormalized()
	var axle := crank.global_position
	var seat := c.node.global_transform * (e[3] as Vector3)
	var bones: PackedInt32Array = e[4]
	for k in range(2):
		var sx := 1.0 - 2.0 * k
		var ang := th + PI * k
		var pedal := Vector3(sx * PEDAL_X, CRANK_R * cos(ang), CRANK_R * sin(ang))
		var leg := bones.slice(k * 7, k * 7 + 4)
		_reach(sk, leg, to_sk * (axle + basis * pedal * WS.M))
		var wrist := Vector3(sx * WRIST.x, WRIST.y, WRIST.z)
		_reach(sk, bones.slice(k * 7 + 4, k * 7 + 7), to_sk * (seat + basis * wrist * WS.M))


## The rider's limb bones: per side (left, right) upper leg, lower leg, foot, toes, upper arm,
## lower arm, hand; empty when one is missing.
static func _limbs(sk: Skeleton3D) -> PackedInt32Array:
	var out := PackedInt32Array()
	for side: String in ["Left", "Right"]:
		for part: String in LIMBS:
			var i := sk.find_bone(side + part)
			if i < 0:
				return PackedInt32Array()
			out.append(i)
	return out


## Bends the chain [upper, lower, end(, tip)] (skeleton space) so the tip (else the end) reaches
## goal, the middle joint bending the way it already does and the end keeping its turn; a limb
## too short for it (a short rider's leg at the bottom of the stroke) straightens and points the
## tip at goal.
static func _reach(sk: Skeleton3D, chain: PackedInt32Array, goal: Vector3) -> void:
	var a := sk.get_bone_global_pose(chain[0]).origin
	var b := sk.get_bone_global_pose(chain[1]).origin
	var end := sk.get_bone_global_pose(chain[2])
	var c := end.origin
	var target := goal
	if chain.size() > 3:
		target += c - sk.get_bone_global_pose(chain[3]).origin
	var keep := end.basis.get_rotation_quaternion()
	var l1 := a.distance_to(b)
	var l2 := b.distance_to(c)
	var to := target - a
	var d := clampf(to.length(), absf(l1 - l2) + 1e-4, l1 + l2 - 1e-4)
	var dir := to.normalized()
	var pole := b - a
	var side := (pole - dir * dir.dot(pole)).normalized()
	var ang := acos(clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0))
	var mid := a + (dir * cos(ang) + side * sin(ang)) * l1
	_turn(sk, chain[0], Quaternion((b - a).normalized(), (mid - a).normalized()))
	b = sk.get_bone_global_pose(chain[1]).origin
	c = sk.get_bone_global_pose(chain[2]).origin
	_turn(sk, chain[1], Quaternion((c - b).normalized(), (a + dir * d - b).normalized()))
	var parent := (
		sk.get_bone_global_pose(sk.get_bone_parent(chain[2])).basis.get_rotation_quaternion()
	)
	sk.set_bone_pose_rotation(chain[2], (parent.inverse() * keep).normalized())
	if chain.size() > 3 and to.length() > l1 + l2:
		c = sk.get_bone_global_pose(chain[2]).origin
		var tip := sk.get_bone_global_pose(chain[3]).origin
		_turn(sk, chain[2], Quaternion((tip - c).normalized(), (goal - c).normalized()))


## Turns bone i by q in skeleton space about its own head.
static func _turn(sk: Skeleton3D, i: int, q: Quaternion) -> void:
	var p := sk.get_bone_parent(i)
	var gp := sk.get_bone_global_pose(p).basis.get_rotation_quaternion() if p >= 0 else Quaternion()
	var g := gp * sk.get_bone_pose_rotation(i)
	sk.set_bone_pose_rotation(i, (gp.inverse() * q * g).normalized())


## The seat marker's position in the full model's space, cached on the node (null without one).
func seat_point(node: Node3D) -> Variant:
	if node.has_meta("seat_pos"):
		return node.get_meta("seat_pos")
	var pos: Variant = null
	var s := node.find_child(SEAT_NODE, true, false) as Node3D
	if s != null:
		pos = node.global_transform.affine_inverse() * s.global_position
	node.set_meta("seat_pos", pos)
	return pos


## The driver's contact markers in the full model's own space (Pedal_L/R on the footwell floor,
## Wheel_L/R on the rim, Cab_Roof above the seat), cached on the node; {} without them (the model
## keeps the plain sit pose). Absolute, not relative to the seat, so the car's transform takes
## them to the world.
static func driver_points(node: Node3D) -> Dictionary:
	if node.has_meta("driver_pts"):
		return node.get_meta("driver_pts")
	var out := {}
	var inv := node.global_transform.affine_inverse()
	for n: String in DRIVER_MARKERS:
		var m := node.find_child(n, true, false) as Node3D
		if m != null:
			out[n] = inv * m.global_position
	node.set_meta("driver_pts", out)
	return out


## How far the driver's hips must sink for the top of the head to clear the roof line (world u),
## measured on the body as it now stands (the sit pose is static, so this is worked out once).
static func _measure_sink(b: PPL.Body, c: VH.Car, pts: Dictionary) -> float:
	if not pts.has("Cab_Roof"):
		return 0.0
	var sk := b.skel
	var hips := sk.find_bone("Hips")
	var head := sk.find_bone("Head")
	if hips < 0 or head < 0:
		return 0.0
	var h := sk.global_transform * KIT.pose(sk, hips).origin
	var hd := sk.global_transform * KIT.pose(sk, head).origin
	if is_nan(h.x) or is_nan(hd.x):
		return 0.0
	var top := h.y + (hd.y - h.y) * SKULL_HAIR
	var roof := (c.node.global_transform * (pts["Cab_Roof"] as Vector3)).y
	return clampf(top - roof, 0.0, MAX_SINK)


## The driver's hands on the rim and feet on the footwell floor, bent to the car's own markers as
## the bodies differ from the one the sit clip was posed on (the bike's _pedal, held still).
func _driver_limbs(e: Array, c: VH.Car) -> void:
	var b: PPL.Body = (e[0] as WK.Walker).body
	var pts: Dictionary = e[3]
	var bones: PackedInt32Array = e[4]
	if bones.size() < 14:
		return
	var sk := b.skel
	var to_sk := sk.global_transform.affine_inverse()
	var car := c.node.global_transform
	for k in range(2):
		var foot := "Pedal_L" if k == 0 else "Pedal_R"
		var hand := "Wheel_L" if k == 0 else "Wheel_R"
		if pts.has(foot):
			_reach(sk, bones.slice(k * 7, k * 7 + 4), to_sk * (car * (pts[foot] as Vector3)))
		if pts.has(hand):
			_reach(sk, bones.slice(k * 7 + 4, k * 7 + 7), to_sk * (car * (pts[hand] as Vector3)))


## Puts the driver's hips on the seat, facing the way the vehicle drives (bodies and models face
## +Z). A car driver (e[5], with e[3]/e[4] the markers and limb bones) also has the hips sunk for
## the roof line and the limbs bent onto the markers.
func _place(e: Array, c: VH.Car, seat: Vector3) -> void:
	var w: WK.Walker = e[0]
	var b: PPL.Body = w.body
	var s := people.scale_of(w)
	var basis := Basis(Vector3.UP, c.yaw + c.vis_yaw)
	var hip := c.node.global_transform * seat
	var sink := float(e[5]) if e.size() >= 6 and float(e[5]) > 0.0 else 0.0
	var xf := Transform3D(
		basis * s, hip - basis * ((e[1] as Vector3) * s) - Vector3(0.0, sink, 0.0)
	)
	b.root.global_transform = xf
	if e.size() >= 6 and not bool(e[2]):
		if float(e[5]) < 0.0:
			sink = _measure_sink(b, c, e[3] as Dictionary)
			e[5] = sink
			xf.origin -= Vector3(0.0, sink, 0.0)
			b.root.global_transform = xf
		_driver_limbs(e, c)
