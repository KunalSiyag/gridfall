extends FpFeature
## The hero wading (feature "hero_wade", the flag of the same name; its movement half lives in
## FpPlayer and CollisionWorld). Each foot that comes down in the water sends an expanding ring over
## the surface (CityView.water_ripple, drawn by shaders/water.gdshader) and, on the desktop tiers,
## a small spray of droplets (a CPUParticles3D of DROPS quads); a landing in the water throws a
## bigger ring. The sound is footsteps.gd's. Nothing here is saved, and nothing runs while the
## hero is on dry land: the work is one signal handler per footfall.

const WS := preload("res://scripts/fp/world_scale.gd")

## Water shallower than this (m) is a wet bank, not a splash.
const MIN_M := 0.03
## Droplets per spray, their size (u), launch speed (u/s) and life (s).
const DROPS := 12
const DROP_SIZE := 0.005
const DROP_SPEED := 0.07
const DROP_LIFE := 0.55

var _drops: CPUParticles3D
## Rings started (tests).
var rings: int = 0


func feature_id() -> String:
	return "hero_wade"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	if ctx.player != null:
		link_signal(ctx.player.stepped, _on_stepped)
		link_signal(ctx.player.landed, _on_landed)
	if _sprays():
		_build_drops()


func teardown() -> void:
	unlink_signals()


## Droplets are off at the Low preset, the web's tier: its frame budget has no room for them.
func _sprays() -> bool:
	var opt := ctx.feature("render_opt") if ctx != null else null
	var preset: Variant = opt.get("preset") if opt != null else "medium"
	return str(preset) != "low"


func _build_drops() -> void:
	_drops = CPUParticles3D.new()
	_drops.name = "Drops"
	_drops.amount = DROPS
	_drops.lifetime = DROP_LIFE
	_drops.one_shot = true
	_drops.explosiveness = 1.0
	_drops.emitting = false
	_drops.direction = Vector3.UP
	_drops.spread = 35.0
	_drops.initial_velocity_min = DROP_SPEED * 0.6
	_drops.initial_velocity_max = DROP_SPEED
	_drops.gravity = Vector3(0.0, -WS.GRAVITY, 0.0)
	_drops.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2(DROP_SIZE, DROP_SIZE)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.86, 0.93, 0.96, 0.7)
	quad.material = mat
	_drops.mesh = quad
	add_child(_drops)


## A foot came down: in water deeper than MIN_M it rings the surface and sprays.
func _on_stepped(surface: String, pos: Vector3) -> void:
	if surface == "water":
		_splash(pos, 0.0)


func _on_landed(speed_mps: float, _rolled: bool) -> void:
	if ctx.player != null and ctx.player.wade_depth > MIN_M * WS.M:
		_splash(ctx.player.position, clampf(speed_mps / 6.0, 0.0, 0.5))


## A ring at pos (amplitude by the water's depth, plus extra) and a spray, if the water is deep
## enough. True when it rang.
func _splash(pos: Vector3, extra: float) -> bool:
	if ctx.collision == null or ctx.view == null:
		return false
	var depth := ctx.collision.water_depth(pos)
	if depth < MIN_M * WS.M:
		return false
	ctx.view.water_ripple(pos, clampf(0.45 + 0.5 * depth / WS.WADE_MAX + extra, 0.0, 1.0))
	rings += 1
	if _drops != null and depth > 0.1 * WS.M:
		_drops.position = Vector3(pos.x, WS.WATER_Y, pos.z)
		_drops.restart()
	return true
