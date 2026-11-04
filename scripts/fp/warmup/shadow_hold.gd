class_name WarmShadowHold
extends RefCounted
## Holds the sun and the fog in another state for the frames of one warm-up state, then puts them
## back. Each state is a different shader program per material:
## - "noshadow": the sun without shadows lights a surface in the base pass instead of in the extra
##   sun-shadow pass. It is what the Tab overview draws (the aerial view turns the shadow off) and
##   what dusk and dawn draw while the sun is too weak for one (SkyDirector).
## - "orbit": four shadow splits and exponential fog, as the Planner view has them (the street has
##   two splits and depth fog): the programs the Planner's first frames used to link in one stall.
## SkyDirector and the street profile write these every tick, so the hold writes them again just
## before each frame is drawn. stop() puts the values back.

var sun: DirectionalLight3D
var env: Environment
var kind: String = "noshadow"
var _on: bool = false
var _was_shadow: bool = false
var _was_mode: int = 0
var _was_fog: int = 0


func start(
	p_sun: DirectionalLight3D, p_env: Environment = null, p_kind: String = "noshadow"
) -> void:
	if p_sun == null or _on:
		return
	sun = p_sun
	env = p_env
	kind = p_kind
	_was_shadow = sun.shadow_enabled
	_was_mode = int(sun.directional_shadow_mode)
	if env != null:
		_was_fog = int(env.fog_mode)
	_on = true
	_apply()
	RenderingServer.frame_pre_draw.connect(_apply)


func stop() -> void:
	if not _on:
		return
	_on = false
	if RenderingServer.frame_pre_draw.is_connected(_apply):
		RenderingServer.frame_pre_draw.disconnect(_apply)
	if is_instance_valid(sun):
		sun.shadow_enabled = _was_shadow
		sun.directional_shadow_mode = _was_mode as DirectionalLight3D.ShadowMode
	if env != null:
		env.fog_mode = _was_fog as Environment.FogMode


func is_holding() -> bool:
	return _on


func _apply() -> void:
	if not is_instance_valid(sun):
		return
	if kind == "orbit":
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		if env != null:
			env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	else:
		sun.shadow_enabled = false
