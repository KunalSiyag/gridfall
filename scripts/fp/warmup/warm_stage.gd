class_name WarmStage
extends Node3D
## The warm-up's stage: a Node3D parked a few metres in front of the active camera that holds one
## tiny copy of each recipe (WarmCollector) for a frame. The copies draw in the real viewport, with
## the real sun, fog and environment, so the browser links exactly the shader programs the real
## instances will want later. Two throwaway lights (an omni and a spot, near-zero energy, no
## shadows) switch on or off to cover both lighting families: an instance near a lamp is drawn with
## the omni and spot loops in its shader, one far from every lamp without them, and each is its own
## program. Everything here is invisible behind the loader veil and freed afterwards.

## Metres in front of the camera, and the size every copy is shrunk to (its mesh keeps the shape).
const DEPTH := 3.0
const SCALE := 0.01
## Copies per row of the grid, and the gap between them (metres, before the camera looks at them).
const COLUMNS := 8
const GAP := 0.05
const LIGHT_ENERGY := 0.02

var omni: OmniLight3D
var spot: SpotLight3D
## Copies alive now.
var count: int = 0
var _copies: Array[Node3D] = []


func _init() -> void:
	name = "ShaderWarmupStage"
	omni = OmniLight3D.new()
	omni.name = "WarmOmni"
	omni.omni_range = 40.0
	omni.light_energy = LIGHT_ENERGY
	omni.shadow_enabled = false
	omni.visible = false
	add_child(omni)
	spot = SpotLight3D.new()
	spot.name = "WarmSpot"
	spot.spot_range = 40.0
	spot.spot_angle = 80.0
	# Behind the copies, looking the way the camera does, so every copy is inside the cone.
	spot.position = Vector3(0.0, 0.0, 2.0)
	spot.light_energy = LIGHT_ENERGY
	spot.shadow_enabled = false
	spot.visible = false
	add_child(spot)


## Parks the stage in front of camera cam (a child of it, so it follows the camera).
func attach(cam: Camera3D) -> void:
	cam.add_child(self)
	position = Vector3(0.0, 0.0, -DEPTH)


## true: the lamps are on (omni and spot loops in the shaders); false: no lamp reaches the copies.
func set_lit(on: bool) -> void:
	omni.visible = on
	spot.visible = on


## Adds a copy of every recipe in batch; they draw in the next frame. Returns how many were made.
func show_batch(batch: Array[Dictionary]) -> int:
	var made := 0
	for rec: Dictionary in batch:
		var copy := _copy_of(rec)
		if copy == null:
			continue
		var col := made % COLUMNS
		var row := int(made / COLUMNS)
		copy.position = Vector3(
			float(col) * (GAP + SCALE * 4.0) - 0.2, float(row) * (GAP + SCALE * 4.0) - 0.1, 0.0
		)
		add_child(copy)
		_copies.append(copy)
		made += 1
	count = _copies.size()
	return made


## Frees every copy (the lights stay).
func clear_batch() -> void:
	for c: Node3D in _copies:
		if is_instance_valid(c):
			c.free()
	_copies.clear()
	count = 0


func _copy_of(rec: Dictionary) -> Node3D:
	var mesh: Mesh = rec["mesh"]
	if mesh == null:
		return null
	var g: GeometryInstance3D
	if bool(rec["multi"]):
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = bool(rec["colors"])
		mm.use_custom_data = bool(rec["custom"])
		mm.mesh = mesh
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D.IDENTITY)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		g = mmi
	else:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var surfaces: Array = rec["surfaces"]
		for s in surfaces.size():
			if surfaces[s] != null:
				mi.set_surface_override_material(s, surfaces[s] as Material)
		g = mi
	g.material_override = rec["override"]
	g.material_overlay = rec["overlay"]
	g.cast_shadow = int(rec["shadow"]) as GeometryInstance3D.ShadowCastingSetting
	g.scale = Vector3.ONE * SCALE
	return g
