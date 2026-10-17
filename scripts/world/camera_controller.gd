class_name GridFallCamera
extends Node3D
## Isometric camera rig for GridFall: WASD pan, mouse wheel zoom, drag pan, middle/right rotate.

const WORLD_CENTER := Vector3(15.5, 0.0, 13.5)
const MIN_ZOOM := 7.0
const MAX_ZOOM := 150.0
const DEFAULT_ZOOM := 62.0
const MIN_COORD := -32.0
const MAX_COORD := 63.0
const PAN_SPEED := 14.0

var target_position: Vector3 = WORLD_CENTER
var target_rotation: Vector3 = Vector3.ZERO
var zoom: float = DEFAULT_ZOOM
var dragging: bool = false
var rotating: bool = false
var _drag_origin: Vector2 = Vector2.ZERO
var _pan_anchor: Vector3 = Vector3.ZERO

@onready var camera: Camera3D = $Camera


func _ready() -> void:
	target_rotation = rotation_degrees
	target_position = WORLD_CENTER
	position = target_position


func focus_world_point(world_pos: Vector3, target_zoom: float = 24.0) -> void:
	target_position = Vector3(
		clampf(world_pos.x, MIN_COORD + 1.0, MAX_COORD - 1.0),
		0.0,
		clampf(world_pos.z, MIN_COORD + 1.0, MAX_COORD - 1.0)
	)
	zoom = clampf(target_zoom, MIN_ZOOM, MAX_ZOOM)


func reset_view() -> void:
	target_position = WORLD_CENTER
	zoom = DEFAULT_ZOOM


func _process(delta: float) -> void:
	position = position.lerp(target_position, minf(delta * 8.0, 1.0))
	rotation_degrees = rotation_degrees.lerp(target_rotation, minf(delta * 6.0, 1.0))
	if camera != null:
		camera.position = camera.position.lerp(Vector3(0.0, 0.0, zoom), minf(delta * 8.0, 1.0))
	_handle_keyboard(delta)


func _handle_keyboard(delta: float) -> void:
	var input := Vector3.ZERO
	input.x = Input.get_axis("camera_left", "camera_right")
	input.z = Input.get_axis("camera_forward", "camera_back")
	if input != Vector3.ZERO:
		input = input.rotated(Vector3.UP, rotation.y).normalized()
		target_position += input * PAN_SPEED * delta
		target_position.x = clampf(target_position.x, MIN_COORD, MAX_COORD)
		target_position.z = clampf(target_position.z, MIN_COORD, MAX_COORD)
	if Input.is_action_just_pressed("camera_center"):
		reset_view()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			if mb.button_index == MOUSE_BUTTON_LEFT:
				dragging = false
			elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
				rotating = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			zoom = maxf(MIN_ZOOM, zoom * 0.9)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			zoom = minf(MAX_ZOOM, zoom * 1.1)
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			dragging = true
			_drag_origin = mb.position
			_pan_anchor = target_position
		elif (mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE) and mb.pressed:
			rotating = true
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if rotating:
			target_rotation.y -= mm.relative.x * 0.22
		elif dragging:
			var right := global_transform.basis.x
			right.y = 0.0
			right = right.normalized()
			var forward := global_transform.basis.z
			forward.y = 0.0
			forward = forward.normalized()
			var scale_factor := zoom / 900.0
			var delta_drag := mm.position - _drag_origin
			target_position = _pan_anchor - right * delta_drag.x * scale_factor - forward * delta_drag.y * scale_factor
			target_position.x = clampf(target_position.x, MIN_COORD, MAX_COORD)
			target_position.z = clampf(target_position.z, MIN_COORD, MAX_COORD)
