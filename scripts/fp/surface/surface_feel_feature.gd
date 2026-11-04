extends FpFeature
## The dust a sprint kicks up (feature "surface_feel", the flag of the same name; the footsteps'
## level and pitch are footsteps.gd's and the speed factor is FpPlayer's, both from
## scripts/fp/world/surface_feel.gd). A running or sprinting foot that comes down on dry sand, a
## dirt track, gravel or a worn trail throws up a small, soft puff of that ground's colour from
## the foot; paving, grass, bridges and wet ground raise none. Two emitters share one material
## (unshaded, billboarded, tinted per puff), so a puff costs a restart and no new shader program;
## on the Low preset (the web's tier) it is a third of the particles. Nothing is saved, and
## nothing runs while the hero stands or walks: the work is one signal handler per footfall.

const WS := preload("res://scripts/fp/world_scale.gd")
const SF := preload("res://scripts/fp/world/surface_feel.gd")

## Puff particles on the desktop tiers and on Low, the size of one (u), its launch speed (u/s),
## its life (s) and how high it rises (the gravity pulls it back softly).
const PUFF := 9
const PUFF_LOW := 3
const SIZE := 0.012
const SPEED := 0.05
const LIFE := 0.6
## The tint of a puff by ground class (alpha is the puff's strength at full dust share).
const TINTS := {
	"sand": Color(0.82, 0.74, 0.56, 0.5),
	"dirt": Color(0.5, 0.42, 0.33, 0.45),
	"gravel": Color(0.62, 0.58, 0.52, 0.4),
	"trail": Color(0.46, 0.4, 0.28, 0.35),
}
## Wet ground (the streets' wetness, 0..1) from here on stays down.
const WET_MAX := 0.35
## The puff's alpha texture: a radial falloff (alpha at the centre, how far out it is half, nothing
## at the rim) and its side in pixels, so a puff is a soft round smudge and not a flat square.
const SOFT_SIDE := 32
const SOFT_STOPS := [0.0, 0.45, 1.0]
const SOFT_ALPHAS := [1.0, 0.45, 0.0]

## Puffs raised (tests) and the class of the last one.
var puffs: int = 0
var last_class: String = ""
var _emitters: Array[CPUParticles3D] = []
var _next: int = 0


func feature_id() -> String:
	return "surface_feel"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	var low := _low()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = soft_texture()
	for k in range(2):
		_emitters.append(_build("Dust%d" % k, PUFF_LOW if low else PUFF, mat))
	if ctx.player != null:
		link_signal(ctx.player.stepped, _on_stepped)


func teardown() -> void:
	unlink_signals()


## The puff's soft round alpha (white, a radial gradient: SOFT_ALPHAS at SOFT_STOPS, nothing from
## the quad's inscribed circle out), tinted per puff by the material's vertex colour.
static func soft_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(SOFT_STOPS)
	var cols := PackedColorArray()
	for a: float in SOFT_ALPHAS:
		cols.append(Color(1.0, 1.0, 1.0, a))
	g.colors = cols
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = SOFT_SIDE
	t.height = SOFT_SIDE
	return t


## True at the Low preset, the web's tier.
func _low() -> bool:
	var opt := ctx.feature("render_opt") if ctx != null else null
	var preset: Variant = opt.get("preset") if opt != null else "medium"
	return str(preset) == "low"


func _build(n: String, amount: int, mat: Material) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = n
	p.amount = amount
	p.lifetime = LIFE
	p.one_shot = true
	p.explosiveness = 0.9
	p.emitting = false
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = SPEED * 0.4
	p.initial_velocity_max = SPEED
	p.gravity = Vector3(0.0, -WS.GRAVITY * 0.05, 0.0)
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.5
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2(SIZE, SIZE)
	quad.material = mat
	p.mesh = quad
	add_child(p)
	return p


## A foot came down at pos on `surface`: a puff when the hero runs on dry dust ground.
func _on_stepped(surface: String, pos: Vector3) -> void:
	if ctx.player == null or ctx.collision == null or not FeatureFlags.enabled("surface_feel"):
		return
	if not ctx.player.grounded or ctx.player.speed() / WS.M < SF.DUST_MIN_MPS:
		return
	var c := SF.feel_at(ctx.collision, surface, pos)
	if SF.dust(c) <= 0.0 or SF.street_wet(ctx) >= WET_MAX:
		return
	puff(pos, c)


## A puff of class c's ground at pos, its strength by the class's dust share. True when raised.
func puff(pos: Vector3, c: String) -> bool:
	if _emitters.is_empty() or not TINTS.has(c):
		return false
	var e := _emitters[_next]
	_next = (_next + 1) % _emitters.size()
	var tint: Color = TINTS[c]
	tint.a *= SF.dust(c)
	e.color = tint
	e.position = pos + Vector3(0.0, 0.004, 0.0)
	e.restart()
	puffs += 1
	last_class = c
	return true
