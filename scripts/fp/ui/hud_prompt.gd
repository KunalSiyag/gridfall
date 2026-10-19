extends Control
## Interact prompt and crosshair (slice B), in the "center" slot. Third person (D13): no crosshair,
## and the prompt chip ("E  Talk to Priya Gupta, nurse") floats over the target, unprojected every
## frame from target.pos (+0.25 m over a resident's head), clamped inside the 24 px safe margin,
## smoothed with a 0.05 s halflife and hidden behind the camera. First person: a small centre dot
## that grows on a target, with the chip under it. Hidden in photo mode, under any modal and during
## a conversation; fades in over 0.12 s and out over 0.08 s.

const S := preload("res://scripts/fp/ui/hud_style.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")

const SAFE := 24.0
## How far past the screen edge an anchor may be before the prompt hides instead of clamping.
const OFFSCREEN_PX := 64.0
const SMOOTH_HALFLIFE := 0.05
const FADE_IN := 0.12
const FADE_OUT := 0.08
const RESIDENT_LIFT := 0.25 * WS.M
const BELOW_CROSSHAIR := 34.0
const DOT := 4.0
const DOT_TARGET := 6.0

var ctx: FpContext
## The current target dict ({} when none).
var target: Dictionary = {}
var _chip: PanelContainer
var _label: Label
var _cross: Control
var _alpha: float = 0.0
var _pos: Vector2 = Vector2.ZERO
var _snap: bool = true
var _in_conversation: bool = false
var _dot: float = DOT
var _mode: String = ""


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	name = "Prompt"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cross = Control.new()
	_cross.name = "Crosshair"
	_cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cross.size = Vector2(16, 16)
	_cross.draw.connect(_draw_cross)
	add_child(_cross)
	_chip = PanelContainer.new()
	_chip.name = "Chip"
	_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip.add_theme_stylebox_override("panel", S.box(Color(0.04, 0.05, 0.08, 0.55), 8, 8, 5))
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 9)
	_chip.add_child(h)
	var key := S.key_cap("E", 13)
	key.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(key)
	_label = S.label("", 16, S.TEXT, S.bold(), 2)
	_label.name = "Text"
	h.add_child(_label)
	_chip.modulate.a = 0.0
	_chip.visible = false
	add_child(_chip)
	if ctx.bus != null:
		ctx.bus.interact_target_changed.connect(set_target)
		ctx.bus.settings_changed.connect(func(_s: Dictionary) -> void: _snap = true)
		ctx.bus.conversation_changed.connect(_on_conversation)
		ctx.bus.modal_changed.connect(func(_a: bool) -> void: _snap = true)
	_mode = _camera_mode()


## Shows the prompt for target ({} hides it). The chip snaps to a new target, then smooths.
func set_target(t: Dictionary) -> void:
	var was := str(target.get("id", "")) + str(target.get("kind", ""))
	target = t
	if t.is_empty():
		return
	# Sentence case: E labels ambient targets "a commuter", "a pedestrian".
	var label := D.debrand(str(t.get("label", "")))
	label = label.substr(0, 1).to_upper() + label.substr(1)
	if _label.text != label:
		_label.text = label
		_chip.reset_size()
	if was != str(t.get("id", "")) + str(t.get("kind", "")) or _alpha <= 0.01:
		_snap = true


## The prompt's text ("Talk to Priya Gupta, nurse").
func prompt_text() -> String:
	return _label.text


## True while the crosshair is drawn (first person only).
func crosshair_visible() -> bool:
	return _cross.visible


## True while the prompt chip is showing (alpha above zero).
func prompt_visible() -> bool:
	return _chip.visible and _chip.modulate.a > 0.0


## Centre of the prompt chip in the slot's coordinates.
func prompt_center() -> Vector2:
	return _chip.position + _chip.size * 0.5


## The world point the third-person prompt is anchored to (target.pos, lifted over a resident's head).
func anchor_of(t: Dictionary) -> Vector3:
	var p: Vector3 = t.get("pos", Vector3.ZERO)
	return p + Vector3.UP * (RESIDENT_LIFT if str(t.get("kind", "")) == "resident" else 0.0)


func _process(delta: float) -> void:
	if ctx == null:
		return
	var mode := _camera_mode()
	if mode != _mode:
		_mode = mode
		_snap = true
	var first := mode == "first"
	var blocked := ctx.is_modal() or _in_conversation or (ctx.player != null and ctx.player.photo_mode)
	var view := size if size.x > 0.0 and size.y > 0.0 else get_viewport_rect().size
	var centre := (view * 0.5).round()
	# Crosshair: first person only.
	_cross.visible = first and not blocked
	if _cross.visible:
		var want := DOT_TARGET if not target.is_empty() else DOT
		var nd := lerpf(_dot, want, S.damp(0.04, delta))
		if absf(nd - _dot) > 0.01:
			_dot = nd
			_cross.queue_redraw()
		_cross.position = centre - _cross.size * 0.5
	# Prompt.
	var show := not target.is_empty() and not blocked and not _label.text.is_empty()
	var goal := Vector2.ZERO
	if show:
		if first:
			goal = centre + Vector2(0.0, BELOW_CROSSHAIR)
		else:
			var r := _third_person_point(view)
			if is_nan(r.x):
				show = false
			else:
				goal = r
	var rate := delta / (FADE_IN if show else FADE_OUT)
	_alpha = clampf(_alpha + (rate if show else -rate), 0.0, 1.0)
	if show:
		if _snap or _alpha <= rate + 1e-4:
			_pos = goal
			_snap = false
		else:
			_pos = _pos.lerp(goal, S.damp(SMOOTH_HALFLIFE, delta))
	_chip.visible = _alpha > 0.0
	_chip.modulate.a = _alpha
	if _chip.visible:
		var sz := _chip.get_combined_minimum_size()
		if _chip.size != sz:
			_chip.size = sz
		_chip.position = (_pos - sz * 0.5).round()


## The chip centre for the third-person rule, or Vector2(NAN, NAN) when it must hide (behind the
## camera, or the anchor further off screen than the clamp allows).
func _third_person_point(view: Vector2) -> Vector2:
	var cam := ctx.player.camera if ctx.player != null else null
	if cam == null or not cam.is_inside_tree():
		return Vector2(NAN, NAN)
	var a := anchor_of(target)
	if cam.is_position_behind(a):
		return Vector2(NAN, NAN)
	var p := cam.unproject_position(a)
	var screen := Rect2(Vector2.ZERO, view)
	if not screen.grow(OFFSCREEN_PX).has_point(p):
		return Vector2(NAN, NAN)
	var half := _chip.get_combined_minimum_size() * 0.5
	var lo := Vector2(SAFE, SAFE) + half
	var hi := view - Vector2(SAFE, SAFE) - half
	return Vector2(clampf(p.x, lo.x, maxf(lo.x, hi.x)), clampf(p.y, lo.y, maxf(lo.y, hi.y)))


func _camera_mode() -> String:
	return str(ctx.settings.get("camera_mode", "third")) if ctx != null else "third"


func _on_conversation(_id: String, active: bool) -> void:
	_in_conversation = active


func _draw_cross() -> void:
	var c := _cross.size * 0.5
	_cross.draw_circle(c, _dot * 0.5 + 1.0, Color(0, 0, 0, 0.35), true, -1.0, true)
	_cross.draw_circle(c, _dot * 0.5, Color(1, 1, 1, 0.88), true, -1.0, true)
