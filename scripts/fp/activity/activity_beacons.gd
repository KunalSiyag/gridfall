extends Node3D
## World beacons for the AI activity layer: one per agent key ("mayor:1", "council", "chaos"), a
## tall light column in the agent's colour over the tile its latest decision touched, with a ring
## on the ground that pulses while the decision is new and dims once it is old. Visual only: no
## collision, hidden in photo mode by the feature.

const WS := preload("res://scripts/fp/world_scale.gd")

const BEAM_H := 110.0 * WS.M
const BEAM_R := 0.9 * WS.M
const RING_R := 7.0 * WS.M
const RING_W := 0.6 * WS.M
## Seconds a beacon pulses as new, and after which it settles to its dim strength.
const FRESH := 30.0
const STALE := 480.0
const BEAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec4 tint : source_color = vec4(0.0, 0.9, 1.0, 1.0);
uniform float strength = 0.6;
uniform float height = 5.5;
varying float h;
void vertex() {
	h = clamp(VERTEX.y / height + 0.5, 0.0, 1.0);
}
void fragment() {
	float core = abs(dot(NORMAL, VIEW));
	float fade = (1.0 - h) * (1.0 - h);
	ALBEDO = tint.rgb * strength * fade * (0.35 + 0.65 * core);
	ALPHA = clamp(strength * fade, 0.0, 1.0);
}
"""

static var _shader: Shader

## key -> {"node": Node3D, "beam": ShaderMaterial, "ring": StandardMaterial3D,
## "ring_node": MeshInstance3D, "age": float, "color": Color, "pos": Vector3}
var _beacons: Dictionary = {}


## Puts the beacon for key at pos (feet on the ground) in col; fresh restarts its pulse.
func place(key: String, pos: Vector3, col: Color, fresh: bool = true) -> void:
	var b: Dictionary = _beacons.get(key, {})
	if b.is_empty():
		b = _make(col)
		_beacons[key] = b
		add_child(b["node"])
	(b["node"] as Node3D).position = pos
	b["pos"] = pos
	b["color"] = col
	(b["beam"] as ShaderMaterial).set_shader_parameter("tint", col)
	b["age"] = 0.0 if fresh else STALE
	_style(b)


func remove(key: String) -> void:
	if _beacons.has(key):
		(_beacons[key]["node"] as Node).queue_free()
		_beacons.erase(key)


func clear() -> void:
	for key: String in _beacons.keys():
		remove(key)


func has_beacon(key: String) -> bool:
	return _beacons.has(key)


func position_of(key: String) -> Vector3:
	return _beacons[key]["pos"] if _beacons.has(key) else Vector3.ZERO


func keys() -> Array:
	return _beacons.keys()


## 0..1: how new the beacon is (1 just placed, 0 once FRESH has passed).
func freshness(key: String) -> float:
	if not _beacons.has(key):
		return 0.0
	return 1.0 - clampf(float(_beacons[key]["age"]) / FRESH, 0.0, 1.0)


func _process(delta: float) -> void:
	for key: String in _beacons:
		var b: Dictionary = _beacons[key]
		if float(b["age"]) >= STALE:
			continue
		b["age"] = float(b["age"]) + delta
		_style(b)


func _style(b: Dictionary) -> void:
	var age := float(b["age"])
	var fresh := 1.0 - clampf(age / FRESH, 0.0, 1.0)
	var settle := 1.0 - smoothstep(FRESH, STALE, age)
	var pulse := 0.5 + 0.5 * sin(age * 5.0)
	var strength := lerpf(0.32, 0.6, settle) + 0.35 * fresh * pulse
	(b["beam"] as ShaderMaterial).set_shader_parameter("strength", strength)
	var col: Color = b["color"]
	var ring: StandardMaterial3D = b["ring"]
	ring.albedo_color = Color(col.r, col.g, col.b, clampf(0.35 + 0.5 * fresh * pulse, 0.0, 1.0))
	var s := 1.0 + 0.25 * fresh * pulse
	(b["ring_node"] as Node3D).scale = Vector3(s, 1.0, s)


func _make(col: Color) -> Dictionary:
	var root := Node3D.new()
	root.name = "Beacon"
	if _shader == null:
		_shader = Shader.new()
		_shader.code = BEAM_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("tint", col)
	mat.set_shader_parameter("height", BEAM_H)
	var cyl := CylinderMesh.new()
	cyl.top_radius = BEAM_R * 0.6
	cyl.bottom_radius = BEAM_R
	cyl.height = BEAM_H
	cyl.radial_segments = 12
	cyl.rings = 1
	cyl.cap_top = false
	cyl.cap_bottom = false
	var beam := MeshInstance3D.new()
	beam.name = "Beam"
	beam.mesh = cyl
	beam.material_override = mat
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.position.y = BEAM_H * 0.5
	root.add_child(beam)
	var torus := TorusMesh.new()
	torus.inner_radius = RING_R - RING_W
	torus.outer_radius = RING_R
	torus.rings = 48
	torus.ring_segments = 6
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	rm.albedo_color = col
	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	ring.mesh = torus
	ring.material_override = rm
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position.y = 0.15 * WS.M
	ring.scale = Vector3(1.0, 0.15, 1.0)
	root.add_child(ring)
	return {
		"node": root,
		"beam": mat,
		"ring": rm,
		"ring_node": ring,
		"age": 0.0,
		"color": col,
		"pos": Vector3.ZERO,
	}
