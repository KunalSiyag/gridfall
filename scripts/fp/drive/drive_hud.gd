extends Control
## The drive feature's HUD: the get-in / get-out key chip above the minimap line and a speedometer
## (km/h and the gear) at the bottom centre while driving, clear of the corner captions.

const S := preload("res://scripts/fp/ui/hud_style.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const CHIP_FROM_BOTTOM := 190.0
## The arm-key row sits this far above the chip's line (the chip's own height and a gap).
const RIG_FROM_BOTTOM := 38.0
const SPEEDO_FROM_BOTTOM := 20.0
const FADE := 0.12

var _chip: PanelContainer
var _chip_label: Label
var _rig: PanelContainer
var _speedo: PanelContainer
var _speed: Label
var _gear: Label
var _alpha: float = 0.0
var _want: bool = false


func setup() -> void:
	name = "DriveHud"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_chip = PanelContainer.new()
	_chip.name = "DriveChip"
	_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip.add_theme_stylebox_override("panel", S.box(Color(0.04, 0.05, 0.08, 0.6), S.RADIUS, 10, 6))
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 9)
	_chip.add_child(h)
	var key := S.key_cap("F", 13)
	key.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(key)
	_chip_label = S.label("", 16, S.TEXT, S.bold(), 2)
	_chip_label.name = "Text"
	h.add_child(_chip_label)
	_chip.visible = false
	add_child(_chip)
	_build_rig()
	_build_speedo()


## The backhoe's arm keys, a quiet row above the chip while the hero is at its wheel.
func _build_rig() -> void:
	_rig = PanelContainer.new()
	_rig.name = "RigKeys"
	_rig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rig.add_theme_stylebox_override("panel", S.box(Color(0.04, 0.05, 0.08, 0.6), S.RADIUS, 10, 6))
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 9)
	_rig.add_child(h)
	for part: Array in [["Y", "U", "arm"], ["I", "O", "bucket"]]:
		if h.get_child_count() > 0:
			var gap := Control.new()
			gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			gap.custom_minimum_size = Vector2(12.0, 0.0)
			h.add_child(gap)
		for k: String in [part[0], part[1]]:
			var cap := S.key_cap(k, 13)
			cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			h.add_child(cap)
		var lab := S.label(str(part[2]), 16, S.TEXT, S.bold(), 2)
		lab.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(lab)
	_rig.visible = false
	add_child(_rig)


func _build_speedo() -> void:
	_speedo = S.panel(S.PANEL_BG, S.RADIUS_PANEL, 16, 8)
	_speedo.name = "Speedometer"
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", -4)
	_speedo.add_child(v)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	_speed = S.plain("0", 40, S.WHITE, S.display())
	_speed.name = "Speed"
	_speed.custom_minimum_size = Vector2(84, 0)
	_speed.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_speed)
	_gear = S.plain("N", 22, S.ACCENT, S.bold())
	_gear.name = "Gear"
	_gear.size_flags_vertical = Control.SIZE_SHRINK_END
	row.add_child(_gear)
	var unit := S.plain("KM/H", 12, S.TEXT_DIM, S.caps())
	unit.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(unit)
	_speedo.visible = false
	add_child(_speedo)


## Shows the key chip with text ("" hides it).
func set_prompt(text: String) -> void:
	_want = not text.is_empty()
	if _want and _chip_label.text != text:
		_chip_label.text = text
		_chip.reset_size()


## The chip text while it shows, else "".
func prompt_text() -> String:
	return _chip_label.text if _want else ""


## The backhoe's arm-key row, above the chip while the hero is at its wheel ("" hides it).
func set_rig(show: bool) -> void:
	_rig.visible = show


## True while the arm-key row shows.
func rig_shown() -> bool:
	return _rig.visible


## Speedometer for a signed speed in u/s (hidden when show is false).
func set_speed(show: bool, v: float) -> void:
	_speedo.visible = show
	if not show:
		return
	var kmh := roundi(absf(v) / WS.M * 3.6)
	_speed.text = str(kmh)
	_gear.text = "R" if v < -0.3 * WS.M else ("N" if kmh == 0 else "D")


func speed_text() -> String:
	return _speed.text if _speedo.visible else ""


func _process(delta: float) -> void:
	var rate := delta / FADE
	_alpha = clampf(_alpha + (rate if _want else -rate), 0.0, 1.0)
	_chip.visible = _alpha > 0.0
	_chip.modulate.a = _alpha
	if _chip.visible:
		var view := size if size.x > 0.0 else get_viewport_rect().size
		var sz := _chip.get_combined_minimum_size()
		_chip.size = sz
		_chip.position = (Vector2(view.x * 0.5, view.y - CHIP_FROM_BOTTOM) - sz * 0.5).round()
	if _rig.visible:
		var view := size if size.x > 0.0 else get_viewport_rect().size
		var sz := _rig.get_combined_minimum_size()
		_rig.size = sz
		_rig.position = (
			(Vector2(view.x * 0.5, view.y - CHIP_FROM_BOTTOM - RIG_FROM_BOTTOM) - sz * 0.5).round()
		)
	if _speedo.visible:
		var view := size if size.x > 0.0 else get_viewport_rect().size
		var sz := _speedo.get_combined_minimum_size()
		_speedo.position = (
			Vector2((view.x - sz.x) * 0.5, view.y - sz.y - SPEEDO_FROM_BOTTOM).round()
		)
