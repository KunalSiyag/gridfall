## Compact background-pack status line shared by the orbit and first-person
## HUDs. Stays invisible in the normal single-pack case; appears only while a
## split web build still has packs downloading (or after one failed), and
## hides again once every pack is mounted. "Retry" re-queues failed packs via
## WebPackStream.retry_failed(). Built only when the pack_status flag is on.
class_name PackStatus
extends PanelContainer

var _stream: WebPackStream = null
var _label: Label
var _retry: Button


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.16, 0.85)
	sb.border_color = Color(0.3, 0.42, 0.6, 0.6)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_label)
	_retry = Button.new()
	_retry.text = "Retry"
	_retry.focus_mode = Control.FOCUS_NONE
	_retry.visible = false
	_retry.mouse_filter = Control.MOUSE_FILTER_STOP
	_retry.custom_minimum_size = Vector2(56, 22)
	_retry.add_theme_font_size_override("font_size", 12)
	_retry.pressed.connect(_on_retry)
	row.add_child(_retry)


## Connects to the stream and renders its current snapshot (so a HUD opened
## after downloads started, e.g. entering first person, resynchronises).
func setup(stream: WebPackStream) -> void:
	_stream = stream
	if not _stream.state_changed.is_connected(_on_state):
		_stream.state_changed.connect(_on_state)
	_render(_stream.snapshot())


func _exit_tree() -> void:
	if _stream != null and _stream.state_changed.is_connected(_on_state):
		_stream.state_changed.disconnect(_on_state)


func _on_state(snap: Dictionary) -> void:
	_render(snap)


func _render(snap: Dictionary) -> void:
	var failed := 0
	for s: String in snap.get("packs", {}).values():
		if s == "failed":
			failed += 1
	if failed == 0 and bool(snap.get("complete", true)):
		visible = false
		return
	visible = true
	if failed > 0:
		_label.text = "Some city detail is unavailable"
	else:
		_label.text = (
			"Loading city detail · %d/%d packs"
			% [int(snap.get("mounted", 0)), int(snap.get("total", 0))]
		)
	_retry.visible = failed > 0


func _on_retry() -> void:
	if _stream != null:
		_stream.retry_failed()


## Current status text (tests).
func status_text() -> String:
	return _label.text


## Whether the Retry button is showing (tests).
func has_retry() -> bool:
	return _retry.visible


## Presses Retry (tests).
func press_retry() -> void:
	_retry.pressed.emit()
