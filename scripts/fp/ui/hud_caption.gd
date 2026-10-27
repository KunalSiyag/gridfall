extends Control
## District caption (slice B), bottom right of the "center" slot: on arrival and whenever the
## player walks into another district, its name in the display face with its mayor under it,
## sliding in over 0.4 s, held for 4 s and faded out. Water and bridges never change it, and a
## district shown in the last COOLDOWN seconds is not shown again (no flicker along a border).
## Hidden under modals, during a conversation and in photo mode.

const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")

const SAFE := 24.0
const FADE_IN := 0.4
const HOLD := 4.0
const FADE_OUT := 0.9
const SLIDE_PX := 14.0
const COOLDOWN := 45.0

var ctx: FpContext
## The district the player is in (-1 unclaimed, -2 not read yet).
var district: int = -2
var _box: VBoxContainer
var _title: Label
var _sub: Label
var _rule: ColorRect
var _age: float = INF
var _clock: float = 0.0
## District -> _clock when its caption last showed.
var _shown_at: Dictionary = {}
var _in_conversation: bool = false
var _has_render_target: bool = false


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	name = "Caption"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_box = VBoxContainer.new()
	_box.name = "Box"
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.alignment = BoxContainer.ALIGNMENT_END
	_box.add_theme_constant_override("separation", 2)
	_box.anchor_left = 1.0
	_box.anchor_right = 1.0
	_box.anchor_top = 1.0
	_box.anchor_bottom = 1.0
	_box.offset_left = -SAFE - 560.0
	_box.offset_right = -SAFE
	_box.offset_top = -SAFE - 90.0
	_box.offset_bottom = -SAFE
	add_child(_box)
	_title = S.label("", 30, S.WHITE, S.display(), 0)
	_title.name = "District"
	_title.uppercase = true
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	_title.add_theme_constant_override("shadow_offset_y", 2)
	_title.add_theme_constant_override("shadow_outline_size", 6)
	_box.add_child(_title)
	_rule = ColorRect.new()
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rule.color = S.ACCENT
	_rule.custom_minimum_size = Vector2(56, 2)
	_rule.size_flags_horizontal = Control.SIZE_SHRINK_END
	_box.add_child(_rule)
	_sub = S.caps_label("", 13, S.TEXT, 3)
	_sub.name = "Mayor"
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_box.add_child(_sub)
	_box.modulate.a = 0.0
	_box.visible = false
	if ctx.bus != null:
		ctx.bus.player_tile_changed.connect(func(_x: int, _y: int) -> void: check())
		ctx.bus.world_ready.connect(arrive)
		ctx.bus.conversation_changed.connect(
			func(_id: String, on: bool) -> void: _in_conversation = on
		)
	arrive.call_deferred()


## Shows the caption for the player's district now (spawn, load, New City), cooldown or not.
func arrive() -> void:
	district = -2
	_shown_at.clear()
	check()


## Reads the player's district and shows its caption when it changed (and is off cooldown).
func check() -> void:
	if ctx == null or ctx.sim == null or ctx.player == null:
		return
	var t := ctx.player_tile()
	if t < 0 or t >= ctx.sim.district.size():
		return
	if ctx.sim.terrain[t] == D.WATER:
		return
	var d := ctx.sim.district[t]
	if d == district:
		return
	district = d
	if _shown_at.has(d) and _clock - float(_shown_at[d]) < COOLDOWN:
		return
	show_district(d)


## Shows the caption for district d (-1: unclaimed land).
func show_district(d: int) -> void:
	_shown_at[d] = _clock
	if d >= 0 and d < D.MAYORS.size():
		_title.text = D.debrand(str(D.MAYORS[d]["district"]))
		var who := D.mayor_display(d)
		_sub.text = D.debrand("Mayor " + who) if not who.is_empty() else ""
	else:
		_title.text = "The Frontier"
		_sub.text = "Unclaimed land"
	_age = 0.0


## The caption text while it shows ("" otherwise).
func caption_text() -> String:
	return _title.text if _box.visible and _box.modulate.a > 0.0 else ""


## Whether the district caption can be drawn into a viewport with a render target.
static func can_draw(display_server: String, has_viewport_texture: bool) -> bool:
	return display_server != "headless" and has_viewport_texture


## FontVariation labels need a glyph-atlas texture when they become visible. Resolve the viewport
## target once it is ready, but never ask the headless dummy renderer to create that texture.
func _render_target_ready() -> bool:
	if _has_render_target:
		return true
	var display_server := DisplayServer.get_name()
	if display_server == "headless":
		return can_draw(display_server, false)
	var viewport := get_viewport()
	if viewport == null:
		return false
	_has_render_target = can_draw(display_server, viewport.get_texture() != null)
	return _has_render_target


func _process(delta: float) -> void:
	_clock += delta
	if _age == INF:
		return
	_age += delta
	var life := FADE_IN + HOLD + FADE_OUT
	if _age >= life:
		_age = INF
		_box.visible = false
		return
	var blocked := (
		ctx.is_modal() or _in_conversation or (ctx.player != null and ctx.player.photo_mode)
	)
	if not _render_target_ready():
		_box.visible = false
		return
	var k_in := clampf(_age / FADE_IN, 0.0, 1.0)
	var k_out := clampf((life - _age) / FADE_OUT, 0.0, 1.0)
	var ease_in := 1.0 - (1.0 - k_in) * (1.0 - k_in) * (1.0 - k_in)
	_box.visible = not blocked
	_box.modulate.a = ease_in * k_out
	_box.offset_left = -SAFE - 560.0 + SLIDE_PX * (1.0 - ease_in)
	_box.offset_right = -SAFE + SLIDE_PX * (1.0 - ease_in)
	_rule.custom_minimum_size.x = 56.0 * ease_in
