extends MeshInstance3D
## The leads from owners' hands to their dogs' collars: one camera-facing ribbon each, sagging with
## the slack, redrawn every frame into a single ImmediateMesh (draw()).

const WS := preload("res://scripts/fp/world_scale.gd")
const SEGMENTS := 10
## Ribbon width (m), widened to about a pixel (WIDTH_PER_UNIT of the camera distance) so a far
## lead does not flicker.
const WIDTH := 0.012
const WIDTH_PER_UNIT := 0.0013
## The lowest point of a slack lead stays this far (m) above the ground under it.
const CLEAR := 0.04
const COLOR := Color(0.36, 0.07, 0.06)

## Leads drawn by the last draw().
var count: int = 0
var _im := ImmediateMesh.new()
var _mat := StandardMaterial3D.new()


func _init() -> void:
	name = "Leads"
	mesh = _im
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat.albedo_color = COLOR
	_mat.roughness = 0.75
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED


## Draws leads, each [hand, collar, length (u), ground y], as seen from cam (world points).
func draw(leads: Array, cam: Vector3) -> void:
	_im.clear_surfaces()
	count = leads.size()
	if leads.is_empty():
		return
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _mat)
	for l: Array in leads:
		_ribbon(l[0], l[1], float(l[2]), float(l[3]), cam)
	_im.surface_end()


## One lead from a to b: a parabola as deep as a rope of length would hang over the chord.
func _ribbon(a: Vector3, b: Vector3, length: float, ground: float, cam: Vector3) -> void:
	var chord := a.distance_to(b)
	var slack := maxf(length - chord, 0.0)
	var sag := sqrt(3.0 * chord * slack / 8.0) if chord > 1e-6 else slack * 0.5
	sag = clampf(sag, 0.0, maxf((a.y + b.y) * 0.5 - ground - CLEAR * WS.M, 0.0))
	var pts := PackedVector3Array()
	for k in range(SEGMENTS + 1):
		var u := float(k) / SEGMENTS
		pts.append(a.lerp(b, u) - Vector3(0.0, 4.0 * sag * u * (1.0 - u), 0.0))
	var sides := PackedVector3Array()
	var views := PackedVector3Array()
	for k in range(SEGMENTS + 1):
		var t := pts[mini(k + 1, SEGMENTS)] - pts[maxi(k - 1, 0)]
		var v := cam - pts[k]
		var half := maxf(WIDTH * WS.M, v.length() * WIDTH_PER_UNIT) * 0.5
		var s := t.cross(v)
		sides.append(s.normalized() * half if s.length_squared() > 1e-20 else Vector3.ZERO)
		views.append(v.normalized())
	for k in range(SEGMENTS):
		var quad := [[k, -1.0], [k, 1.0], [k + 1, 1.0], [k, -1.0], [k + 1, 1.0], [k + 1, -1.0]]
		for q: Array in quad:
			var i := int(q[0])
			_im.surface_set_normal(views[i])
			_im.surface_add_vertex(pts[i] + sides[i] * float(q[1]))
