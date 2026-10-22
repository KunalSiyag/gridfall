extends Control
## The press camera's viewfinder (feature "reporter"), over the view in photo mode while a story is
## on assignment: corner marks round the middle of the view a press photo must hold the scene in
## (ReporterDesk.FRAME), green while it does, the story above the marks and what to do below them,
## the last shot's result under that, and a white flash for the shutter. The feature drives it
## through show_state(), note() and flash().

const S := preload("res://scripts/fp/ui/hud_style.gd")
const DESK := preload("res://scripts/fp/reporter/reporter_desk.gd")
## Corner mark arm length and line width, and the centre cross (px).
const ARM := 36.0
const LINE := 3.0
const CROSS := 8.0
## How long the shutter flash and a shot's note last (s).
const FLASH_S := 0.3
const NOTE_S := 2.5
const IDLE := Color(1, 1, 1, 0.8)
const MISS := Color("#FFB547")

## The scene sits inside the marks now.
var framed: bool = false
var _flash: float = 0.0
var _note_t: float = 0.0
var _title: Label
var _hint: Label
var _note: Label


func setup() -> void:
	name = "Viewfinder"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var edge := (1.0 - DESK.FRAME) * 0.5
	_title = _place(S.caps_label("", 14, S.WHITE, 3), "Title", edge, -34.0)
	_hint = _place(S.label("", 16, S.TEXT, S.bold()), "Hint", 1.0 - edge, 10.0)
	_note = _place(S.label("", 18, S.GOOD, S.bold()), "Note", 1.0 - edge, 36.0)
	_note.visible = false
	visible = false


## title: the story; hint: what to do now; in_frame: the scene sits inside the marks.
func show_state(title: String, hint: String, in_frame: bool) -> void:
	if _title.text != title:
		_title.text = title
	if _hint.text != hint:
		_hint.text = hint
	if framed != in_frame:
		framed = in_frame
		queue_redraw()


## Shows the result of a shot under the hint for NOTE_S seconds (green for a sharp one).
func note(t: String, sharp: bool) -> void:
	_note.text = t
	_note.add_theme_color_override("font_color", S.GOOD if sharp else MISS)
	_note.visible = true
	_note_t = NOTE_S


## The shot's result while it shows, else "".
func note_text() -> String:
	return _note.text if _note.visible else ""


## The hint line ("Click to take the shot").
func hint_text() -> String:
	return _hint.text


## The shutter: the view flashes white and fades over FLASH_S.
func flash() -> void:
	_flash = FLASH_S
	queue_redraw()


func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta)
		queue_redraw()
	if _note_t > 0.0:
		_note_t -= delta
		_note.visible = _note_t > 0.0


func _draw() -> void:
	var m := size * (1.0 - DESK.FRAME) * 0.5
	var r := Rect2(m, size - m * 2.0)
	var col := S.GOOD if framed else IDLE
	var corners := [
		r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)
	]
	for c: Vector2 in corners:
		var dx := ARM if c.x < size.x * 0.5 else -ARM
		var dy := ARM if c.y < size.y * 0.5 else -ARM
		var arms := PackedVector2Array([c + Vector2(0.0, dy), c, c + Vector2(dx, 0.0)])
		draw_polyline(arms, col, LINE, true)
	var mid := size * 0.5
	draw_line(mid - Vector2(CROSS, 0.0), mid + Vector2(CROSS, 0.0), col, 1.5, true)
	draw_line(mid - Vector2(0.0, CROSS), mid + Vector2(0.0, CROSS), col, 1.5, true)
	if _flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.85 * _flash / FLASH_S))


## A centred line of text across the view, its top offset px from anchor (a fraction of the height).
func _place(l: Label, node_name: String, anchor: float, offset: float) -> Label:
	l.name = node_name
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.anchor_top = anchor
	l.anchor_bottom = anchor
	l.offset_top = offset
	l.offset_bottom = offset + 24.0
	add_child(l)
	return l
