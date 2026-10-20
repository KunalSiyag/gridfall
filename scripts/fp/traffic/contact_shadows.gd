extends RefCounted
## Contact shadows: a soft dark patch on the ground under every drawn vehicle and person, all in
## one MultiMesh draw. The sun's shadow maps reach only some of them (full and mid-LOD vehicles to
## render.SHADOW_DIST, people bodies to people.T1_NEAR, nothing after dark or under cloud), and
## without darkening where a body meets the road, a parked car or a walker seems to hover.

const WS := preload("res://scripts/fp/world_scale.gd")
## Height above the surface: clear of depth fighting with the road, too thin to see from the side.
const LIFT := 0.0015
## Blob footprint against the body: vehicles a little wider and longer than their box, people a
## disc of PERSON_D.
const CAR_PAD := Vector2(1.18, 1.08)
const PERSON_D := 0.7 * WS.M
## Darkness at the centre of the patch (0..1) and the patch's shape exponent (2 is an ellipse,
## larger is squarer: car bodies cover a rounded rectangle, feet an ellipse).
const CAR_DARK := 0.62
const PERSON_DARK := 0.42
const CAR_SHAPE := 5.0
const PERSON_SHAPE := 2.0
## Range, with a fade over the last FADE (vehicles beyond CAR_RANGE are a few pixels tall).
const CAR_RANGE := 6.0
const FADE := 0.6
const FLOATS := 16
const SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
// Instance colour: r shape exponent / 10, a darkness at the centre.

void fragment() {
	vec2 p = abs(UV * 2.0 - 1.0);
	float n = max(COLOR.r * 10.0, 1.0);
	float d = pow(pow(p.x, n) + pow(p.y, n), 1.0 / n);
	float a = 1.0 - smoothstep(0.25, 1.0, d);
	ALBEDO = vec3(0.0);
	ALPHA = a * a * COLOR.a;
}
"""

var mmi: MultiMeshInstance3D = null
var count: int = 0
var _buf := PackedFloat32Array()
var _cap: int = 0


func setup(root: Node3D) -> void:
	var quad := PlaneMesh.new()
	quad.size = Vector2.ONE
	var sh := Shader.new()
	sh.code = SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = 0
	mmi = MultiMeshInstance3D.new()
	mmi.name = "ContactShadows"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-200, -10, -200), Vector3(400, 40, 400))
	mmi.visible = false
	root.add_child(mmi)


func begin() -> void:
	count = 0


## A vehicle of half width hw and length l at ground point p, heading yaw, d from the camera.
func car(p: Vector3, yaw: float, hw: float, l: float, d: float) -> void:
	var op := clampf((CAR_RANGE - d) / FADE, 0.0, 1.0)
	if op > 0.0:
		_add(p, yaw, Vector2(2.0 * hw * CAR_PAD.x, l * CAR_PAD.y), CAR_SHAPE, CAR_DARK * op)


## A person standing at ground point p; opacity follows the body's own fade (0..1).
func person(p: Vector3, opacity: float) -> void:
	if opacity > 0.0:
		_add(p, 0.0, Vector2(PERSON_D, PERSON_D), PERSON_SHAPE, PERSON_DARK * opacity)


func _add(p: Vector3, yaw: float, size: Vector2, shape: float, dark: float) -> void:
	if count >= _cap:
		_cap = maxi(64, _cap * 2)
		_buf.resize(_cap * FLOATS)
	var b := Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(size.x, 1.0, size.y))
	var o := count * FLOATS
	# MultiMesh buffer layout: the basis rows with the origin as a fourth column, then the colour.
	_buf[o] = b.x.x
	_buf[o + 1] = b.y.x
	_buf[o + 2] = b.z.x
	_buf[o + 3] = p.x
	_buf[o + 4] = b.x.y
	_buf[o + 5] = b.y.y
	_buf[o + 6] = b.z.y
	_buf[o + 7] = p.y + LIFT
	_buf[o + 8] = b.x.z
	_buf[o + 9] = b.y.z
	_buf[o + 10] = b.z.z
	_buf[o + 11] = p.z
	_buf[o + 12] = shape / 10.0
	_buf[o + 13] = 0.0
	_buf[o + 14] = 0.0
	_buf[o + 15] = dark
	count += 1


## Uploads this frame's patches (one buffer write).
func finish() -> void:
	if mmi == null:
		return
	var mm := mmi.multimesh
	if count == 0:
		mmi.visible = false
		mm.visible_instance_count = 0
		return
	if mm.instance_count != _cap:
		mm.instance_count = _cap
	mm.buffer = _buf
	mm.visible_instance_count = count
	mmi.visible = true


## Patch k's centre (tests).
func origin(k: int) -> Vector3:
	var o := k * FLOATS
	return Vector3(_buf[o + 3], _buf[o + 7], _buf[o + 11])


func clear() -> void:
	if mmi != null and is_instance_valid(mmi):
		mmi.queue_free()
	mmi = null
	count = 0
