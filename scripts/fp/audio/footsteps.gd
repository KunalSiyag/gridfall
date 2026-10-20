extends Node
## The hero's footsteps (slice I). With FpPlayer's `stepped(surface, pos)` signal (A fires it on
## the gait's foot contacts) every emission plays exactly one step and nothing polls, so the
## sound lands with the visible stride. Without it, a step plays every stride of horizontal travel
## (0.7 m at a walk, longer when running). Left and right feet alternate between their own
## variant sets; steps are non-positional (the listener sits behind the hero in third person, so
## a positional step would sound like someone else's feet). On soaked paving (G1's weather) a
## splash layer plays over each step, scaled by how wet the streets are.

const WS := preload("res://scripts/fp/world_scale.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")

## Polling fallback: stride in metres at a walk, its growth per m/s above WALK, and its cap.
const STRIDE_M := 0.7
const STRIDE_PER_MPS := 0.25
const STRIDE_MAX_M := 1.5
## Horizontal moves longer than this in one poll are teleports, not steps.
const TELEPORT_M := 2.0
## Left-foot variants are the odd numbers, right-foot ones the even numbers.
const LEFT_VARIANTS: Array[int] = [1, 3, 5]
const RIGHT_VARIANTS: Array[int] = [2, 4, 6]
## Surfaces that hold a film of water when wet, and the wetness below which no splash plays.
const PAVED: Array[String] = ["asphalt", "sidewalk", "lot", "bridge"]
const SPLASH_MIN_WET := 0.2
## Landings faster than this (m/s down, FpPlayer's heavy landing) add the other foot, louder.
const HEAVY_LAND_MPS := 4.0
const HEAVY_LAND_DB := 3.0

var ctx: FpContext
var steps_played: int = 0
var heavy_lands: int = 0
var splashes_played: int = 0
## The last steps' stream names, newest last (tests).
var history: Array[String] = []
var polling: bool = true
var enabled: bool = true
var _feet: Array[AudioStreamPlayer] = []
var _splash: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()
var _left: bool = true
var _last_variant: Dictionary = {true: 0, false: 0}
var _bound: Node3D
var _last_pos: Vector3 = Vector3(NAN, NAN, NAN)
var _travel: float = 0.0
var _last_surface: String = "sidewalk"


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	_rng.seed = 4242
	for side in ["Left", "Right"]:
		var p := AudioStreamPlayer.new()
		p.name = "Foot" + side
		p.bus = BANK.BUS_SFX
		add_child(p)
		_feet.append(p)
	_splash = AudioStreamPlayer.new()
	_splash.name = "Splash"
	_splash.bus = BANK.BUS_SFX
	add_child(_splash)
	bind(ctx.player)


## Follows player p: its stepped signal when it has one, else polling.
func bind(p: Node3D) -> void:
	unbind()
	_bound = p
	_last_pos = Vector3(NAN, NAN, NAN)
	_travel = 0.0
	if p != null and p.has_signal("stepped"):
		p.connect("stepped", _on_stepped)
		polling = false
		if p.has_signal("landed"):
			p.connect("landed", _on_landed)
	else:
		polling = p != null


func unbind() -> void:
	if _bound != null and is_instance_valid(_bound):
		for c: Callable in [_on_stepped, _on_landed]:
			var sig := "stepped" if c == _on_stepped else "landed"
			if _bound.has_signal(sig) and _bound.is_connected(sig, c):
				_bound.disconnect(sig, c)
	_bound = null


## The polling fallback; does nothing while the player has the stepped signal.
func poll(_dt: float) -> void:
	if not enabled or not polling or _bound == null or not is_instance_valid(_bound):
		return
	var pos := _bound.position
	if _flag("photo_mode", false) or not _flag("grounded", true):
		_last_pos = pos
		return
	if is_nan(_last_pos.x):
		_last_pos = pos
		return
	var d := Vector2(pos.x - _last_pos.x, pos.z - _last_pos.z).length()
	_last_pos = pos
	if d > TELEPORT_M * WS.M:
		_travel = 0.0
		return
	_travel += d
	var stride := stride_length(_speed_mps()) * WS.M
	while _travel >= stride:
		_travel -= stride
		play(ctx.collision.surface_at(pos) if ctx.collision != null else "sidewalk")


## Stride (m) for a speed in m/s.
static func stride_length(speed_mps: float) -> float:
	return clampf(STRIDE_M + (speed_mps - 1.45) * STRIDE_PER_MPS, STRIDE_M, STRIDE_MAX_M)


## Plays one step on surface (CollisionWorld.surface_at names; unknown ones sound like sidewalk).
func play(surface: String, gain_db: float = 0.0) -> void:
	if not enabled:
		return
	var surf := surface if surface in BANK.SURFACES else "sidewalk"
	var left := _left
	_left = not _left
	var pool: Array[int] = LEFT_VARIANTS if left else RIGHT_VARIANTS
	var n := pool[_rng.randi() % pool.size()]
	if n == int(_last_variant[left]):
		n = pool[(pool.find(n) + 1 + _rng.randi() % (pool.size() - 1)) % pool.size()]
	_last_variant[left] = n
	var sname := BANK.step_name(surf, n)
	steps_played += 1
	history.append(sname)
	if history.size() > 32:
		history.pop_front()
	var s := BANK.stream(sname)
	if s == null:
		return
	var p: AudioStreamPlayer = _feet[0 if left else 1]
	var v := _speed_mps()
	var vol := BANK.STEP_DB + gain_db + _rng.randf_range(-1.5, 1.0)
	if v > (WS.WALK + WS.RUN) * 0.5 / WS.M:
		vol += BANK.STEP_RUN_DB
	if _flag("crouched", false):
		vol += BANK.STEP_CROUCH_DB
	p.stream = s
	p.volume_db = vol
	p.pitch_scale = 1.0 + _rng.randf_range(-BANK.STEP_PITCH_SPREAD, BANK.STEP_PITCH_SPREAD)
	p.play()
	var wet := wetness()
	if wet >= SPLASH_MIN_WET and surf in PAVED:
		var sp := BANK.stream("footstep_splash_%d" % (1 + _rng.randi() % BANK.SPLASH_VARIANTS))
		if sp != null:
			splashes_played += 1
			_splash.stream = sp
			_splash.volume_db = vol + BANK.SPLASH_DB + linear_to_db(wet)
			_splash.pitch_scale = p.pitch_scale
			_splash.play()


## How wet the streets are, 0..1: G1's streetscape weather, read by name; 0 without it.
func wetness() -> float:
	var street := ctx.feature("streetscape") if ctx != null else null
	if street == null:
		return 0.0
	var w: Variant = street.get("weather")
	if not (w is Object) or not is_instance_valid(w):
		return 0.0
	var v: Variant = (w as Object).get("wet")
	return clampf(float(v), 0.0, 1.0) if typeof(v) == TYPE_FLOAT else 0.0


## True when stream name n is a left-foot variant.
static func is_left_variant(n: String) -> bool:
	return int(n.get_slice("_", n.get_slice_count("_") - 1)) % 2 == 1


func _on_stepped(surface: String, _pos: Vector3) -> void:
	_last_surface = surface
	play(surface)


## The landing's own contact already played (stepped comes first); a heavy one lands on both feet.
func _on_landed(speed_mps: float) -> void:
	if speed_mps < HEAVY_LAND_MPS:
		return
	heavy_lands += 1
	play(_last_surface, HEAVY_LAND_DB)


## A bool property of the bound player, or fallback when it has none.
func _flag(prop: String, fallback: bool) -> bool:
	if _bound == null or not is_instance_valid(_bound):
		return fallback
	var v: Variant = _bound.get(prop)
	return bool(v) if typeof(v) == TYPE_BOOL else fallback


func _speed_mps() -> float:
	if _bound == null or not is_instance_valid(_bound):
		return 0.0
	var v: Variant = _bound.get("velocity")
	if typeof(v) != TYPE_VECTOR3:
		return 0.0
	var vv: Vector3 = v
	return Vector2(vv.x, vv.z).length() / WS.M
