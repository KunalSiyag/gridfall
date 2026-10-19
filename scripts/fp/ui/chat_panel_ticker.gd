extends Control
## One line of the collapsed chat ticker (slice C §2): the author (or the card title) in its colour
## and the text after it, at most two lines, drawn with a dark outline and no background so it
## reads over the street. One Control per line; the panel fades it out by modulate.

const S := preload("res://scripts/fp/ui/chat_panel_style.gd")

const SIZE := 15
const OUTLINE := 6
const OUTLINE_COL := Color(0.02, 0.03, 0.05, 0.92)

var _name: TextLine
var _name_col: Color = Color.WHITE
var _text: TextParagraph
var _text_col: Color = Color.WHITE
var _indent: float = 0.0


## head: the author or card title ("" for none); width: the line width in pixels.
func setup(head: String, head_col: Color, text: String, text_col: Color, width: float) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_col = head_col
	_text_col = text_col
	_indent = 0.0
	if not head.is_empty():
		_name = S.text_line(head, S.display_font(), SIZE)
		_indent = _name.get_size().x + 7.0
	_text = S.text_para(text, S.body_font(), SIZE, maxf(60.0, width - _indent))
	_text.max_lines_visible = 2
	_text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var h := _text.get_size().y
	if _name != null:
		h = maxf(h, _name.get_size().y)
	custom_minimum_size = Vector2(width, ceilf(h) + 2.0)


func _draw() -> void:
	var ci := get_canvas_item()
	var y := 1.0
	if _name != null:
		_name.draw_outline(ci, Vector2(0, y), OUTLINE, OUTLINE_COL)
	_text.draw_outline(ci, Vector2(_indent, y), OUTLINE, OUTLINE_COL)
	if _name != null:
		_name.draw(ci, Vector2(0, y), _name_col)
	_text.draw(ci, Vector2(_indent, y), _text_col)
