extends RefCounted
## Drivers seated in the moving vehicles nearest the camera. Only while a vehicle draws its full
## model: those have see-through glass, a cabin and a Seat_Driver marker at the driver's hip
## point (tools/blender/realcity/vehicles2.py); the merged far LODs have opaque glass. A driver is
## the car's resident (people.dress picks the same avatar and stature the resident walks with) or
## an ambient body from the city seed, posed once in the sit loop with its mixers off, so a
## seated body costs its draws and nothing per frame beyond its transform.

const WS := preload("res://scripts/fp/world_scale.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const PPL := preload("res://scripts/fp/traffic/people.gd")
const KIT := preload("res://scripts/fp/traffic/people_kit.gd")
const CAP := 12
const RANGE := 30.0 * WS.M
const SEAT_NODE := "Seat_Driver"
## The sit loop is held at this time (s): hands on the lap, head level.
const SIT: StringName = &"sit"
const SIT_AT := 1.0
## Walker ids seed ambient dressing; drivers use their own range so they do not copy a walker.
const PROXY_ID := 1 << 24

var people: PPL
## car id -> [the Walker proxy holding the body, its Hips in CharacterRoot space]
var _by_car: Dictionary = {}
var seated: int = 0


func setup(p_people: PPL) -> void:
	people = p_people
	_by_car.clear()
	seated = 0


## Seats a driver in each of the CAP nearest moving vehicles within RANGE that show their full
## model, and releases the rest. Call between people.begin and people.finish.
func sync(cars: Array, cam: Vector3, residents: Variant) -> void:
	var cands: Array = []
	for c: VH.Car in cars:
		if c.dead or c.parked or c.far or c.node == null or not c.node.visible:
			continue
		var d := cam.distance_to(c.pos)
		if d > RANGE:
			continue
		var seat: Variant = _seat(c.node)
		if seat != null:
			cands.append([d, c, seat])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var keep := {}
	for k in range(mini(CAP, cands.size())):
		var c: VH.Car = cands[k][1]
		var e: Array = _by_car.get(c.id, [])
		if e.is_empty():
			e = _seat_driver(c, residents)
			if e.is_empty():
				continue
			_by_car[c.id] = e
		_place(e, c, cands[k][2])
		keep[c.id] = true
	for id: int in _by_car.keys():
		if not keep.has(id):
			people.release((_by_car[id] as Array)[0])
			_by_car.erase(id)
	seated = _by_car.size()


## Releases every seated body.
func clear() -> void:
	if people != null:
		for e: Array in _by_car.values():
			people.release(e[0])
	_by_car.clear()
	seated = 0


## The seated body in car id (null when it has no driver drawn).
func body_of(id: int) -> PPL.Body:
	var e: Array = _by_car.get(id, [])
	return (e[0] as WK.Walker).body if not e.is_empty() else null


func _seat_driver(c: VH.Car, residents: Variant) -> Array:
	var w := WK.Walker.new()
	w.id = PROXY_ID + c.id
	w.resident_id = c.driver_id
	people.dress(w, residents)
	if w.av < 0 or not people.seat(w):
		return []
	return [w, _pose_seated(w.body)]


## Holds b still in the sit pose (mixers off, no shadow: the car casts one); returns its Hips in
## CharacterRoot space.
static func _pose_seated(b: PPL.Body) -> Vector3:
	b.tree.active = false
	b.ap.active = true
	b.ap.stop()
	b.ap.speed_scale = 1.0
	b.ap.play(SIT)
	b.ap.seek(SIT_AT, true)
	b.ap.advance(0.0)
	b.ap.active = false
	b.shadow = 0
	for gi: GeometryInstance3D in b.meshes:
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if b.box != null:
		b.box.visible = false
	var hips := b.skel.find_bone("Hips")
	if hips < 0:
		return Vector3.ZERO
	var skel_xf := b.root.global_transform.affine_inverse() * b.skel.global_transform
	return skel_xf * KIT.pose(b.skel, hips).origin


## The seat marker's position in the full model's space, cached on the node (null without one).
func _seat(node: Node3D) -> Variant:
	if node.has_meta("seat_pos"):
		return node.get_meta("seat_pos")
	var pos: Variant = null
	var s := node.find_child(SEAT_NODE, true, false) as Node3D
	if s != null:
		pos = node.global_transform.affine_inverse() * s.global_position
	node.set_meta("seat_pos", pos)
	return pos


## Puts the driver's hips on the seat, facing the way the vehicle drives (bodies and models face
## +Z).
func _place(e: Array, c: VH.Car, seat: Vector3) -> void:
	var w: WK.Walker = e[0]
	var b: PPL.Body = w.body
	var s := people.scale_of(w)
	var basis := Basis(Vector3.UP, c.yaw + c.vis_yaw)
	var hip := c.node.global_transform * seat
	b.root.global_transform = Transform3D(basis * s, hip - basis * ((e[1] as Vector3) * s))
