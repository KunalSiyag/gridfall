extends Control
## The health feature's full-screen layer in the overlay slot (under the pause menu): a red
## vignette that flashes with each hurt and stays, pulsing, while health is low, the direction
## marker's arc toward where a blow came from (hit_direction, first person — hit_wedge.gd), and
## the knock-out's fade to black with its caption.

const S := preload("res://scripts/fp/ui/hud_style.gd")
const WEDGE := preload("res://scripts/fp/health/hit_wedge.gd")
## The vignette stays once this share of health is lost, up to LOW_MAX strong with none left.
const LOW_FROM := 0.6
const LOW_MAX := 0.6
const PULSE_HZ := 1.2
## A hurt flashes the vignette FLASH_K times the share of the bar it cost (at most full),
## fading with this half-life (s).
const FLASH_K := 4.0
const HL_FLASH := 0.25

var vignette: TextureRect
var wedge: Control
var black: ColorRect
var caption: Label
var _flash: float = 0.0
var _t: float = 0.0


func setup() -> void:
	name = "HealthScreen"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vignette = TextureRect.new()
	vignette.name = "Vignette"
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vignette.stretch_mode = TextureRect.STRETCH_SCALE
	vignette.texture = _vignette_texture()
	vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(vignette)
	wedge = WEDGE.new()
	wedge.name = "Wedge"
	add_child(wedge)
	black = ColorRect.new()
	black.name = "Black"
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	black.color = Color(0.0, 0.0, 0.0)
	black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(black)
	caption = S.caps_label("Knocked out", 30, S.TEXT, 3)
	caption.name = "Caption"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.grow_horizontal = Control.GROW_DIRECTION_BOTH
	caption.grow_vertical = Control.GROW_DIRECTION_BOTH
	caption.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	add_child(caption)
	set_state(0.0, 0.0, 0.0, 0.0)


## A hurt that cost share k of the full bar.
func flash(k: float) -> void:
	_flash = clampf(maxf(_flash, k * FLASH_K), 0.0, 1.0)


## A blow from angle a round the view (0 dead ahead, +PI/2 from the right) flashes the direction
## marker (hit_direction; health_feature asks in first person only).
func flash_from(a: float) -> void:
	wedge.call("flash", a)


## lost: the share of health lost (0..1); dark: the knock-out's black (0..1); words: its
## caption (0..1); dt: seconds since the last call.
func set_state(lost: float, dark: float, words: float, dt: float) -> void:
	_t += dt
	_flash *= 1.0 - S.damp(HL_FLASH, dt)
	var low := clampf((lost - LOW_FROM) / (1.0 - LOW_FROM), 0.0, 1.0)
	var pulse := 0.8 + 0.2 * sin(_t * TAU * PULSE_HZ)
	vignette.modulate.a = maxf(_flash, low * LOW_MAX * pulse)
	vignette.visible = vignette.modulate.a > 0.004
	wedge.call("fade", dt)
	black.modulate.a = dark
	black.visible = dark > 0.0
	caption.modulate.a = words
	caption.visible = words > 0.0


## Clear in the middle, deep red at the edges (stretched to the screen).
static func _vignette_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	var edge := S.RED.darkened(0.35)
	g.colors = PackedColorArray([Color(edge, 0.0), Color(edge, 0.0), Color(edge, 0.9)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 128
	t.height = 128
	return t
