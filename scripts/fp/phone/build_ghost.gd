extends Node3D
## The Build app's marker in the world: on every tile the order would touch, a glowing floor slab
## and a faint column that reads from down the street, cyan when it can be placed and amber when
## not, and a ring on the first corner of a road or zone.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const OK_COLOR := Color(0.0, 0.88, 1.0)
const BAD_COLOR := Color(1.0, 0.71, 0.28)
const FLOOR_ALPHA := 0.45
const COLUMN_ALPHA := 0.16
const LIFT := 0.4 * WS.M
const COLUMN_H := 4.0 * WS.M
const MAX_TILES := 64

var _floor: MultiMeshInstance3D
var _column: MultiMeshInstance3D
var _floor_mat: StandardMaterial3D
var _column_mat: StandardMaterial3D
var _anchor: MeshInstance3D
var count: int = 0


func setup() -> void:
	name = "BuildGhost"
	_floor_mat = _material()
	_column_mat = _material()
	_floor = _layer(Vector3(0.94, 0.3 * WS.M, 0.94), _floor_mat)
	_column = _layer(Vector3(0.9, COLUMN_H, 0.9), _column_mat)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.36
	ring.outer_radius = 0.44
	ring.material = _material()
	(ring.material as StandardMaterial3D).albedo_color = Color(1, 1, 1, 0.9)
	_anchor = MeshInstance3D.new()
	_anchor.mesh = ring
	_anchor.scale = Vector3(1.0, 0.25, 1.0)
	_anchor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_anchor.visible = false
	add_child(_anchor)
	visible = false


func _material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _layer(size: Vector3, mat: StandardMaterial3D) -> MultiMeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	box.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = MAX_TILES
	mm.visible_instance_count = 0
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


## Marks tiles (Array of Vector2i); anchor is the first corner or D.NO_TILE.
func show_tiles(tiles: Array, ok: bool, anchor: Vector2i) -> void:
	visible = true
	var c := OK_COLOR if ok else BAD_COLOR
	_floor_mat.albedo_color = Color(c, FLOOR_ALPHA)
	_column_mat.albedo_color = Color(c, COLUMN_ALPHA)
	count = mini(tiles.size(), MAX_TILES)
	for k in range(count):
		var t: Vector2i = tiles[k]
		_floor.multimesh.set_instance_transform(k, Transform3D(Basis(), Vector3(t.x, LIFT, t.y)))
		_column.multimesh.set_instance_transform(
			k, Transform3D(Basis(), Vector3(t.x, LIFT + COLUMN_H * 0.5, t.y))
		)
	_floor.multimesh.visible_instance_count = count
	_column.multimesh.visible_instance_count = count
	_anchor.visible = anchor != D.NO_TILE
	if _anchor.visible:
		_anchor.position = Vector3(anchor.x, LIFT * 2.0, anchor.y)


func clear() -> void:
	visible = false
	count = 0
	_floor.multimesh.visible_instance_count = 0
	_column.multimesh.visible_instance_count = 0
	_anchor.visible = false
