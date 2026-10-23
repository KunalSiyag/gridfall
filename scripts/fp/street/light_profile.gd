extends RefCounted
## First-person light profile (slice G1): shadow distance and cascades, SSAO and SSIL radii, depth
## fog, volumetric fog, screen-space reflections and the sky's radiance update, in world units for
## street level. Static:
## apply(env, sun, "fp", preset) snapshots every key it owns on the first first-person apply, and
## apply(env, sun, "orbit", preset) restores exactly those values (Main.exit_fp relies on it). Keys
## SkyDirector rewrites every frame (sun energy, colour, ambient, fog colour, exposure) are never
## touched here.

const WS := preload("res://scripts/fp/world_scale.gd")
const QUALITY := "res://scripts/fp/render/quality.gd"
const ENV_KEYS := [
	"ssao_radius", "ssao_intensity", "ssil_enabled", "ssil_radius", "ssil_intensity",
	"fog_mode", "fog_density", "fog_depth_begin", "fog_depth_end", "fog_depth_curve",
	"fog_aerial_perspective", "fog_sky_affect",
	"volumetric_fog_enabled", "volumetric_fog_length", "volumetric_fog_density",
	"volumetric_fog_detail_spread", "volumetric_fog_anisotropy", "volumetric_fog_temporal_reprojection_enabled",
	"ssr_enabled", "ssr_max_steps", "ssr_fade_in", "ssr_fade_out", "ssr_depth_tolerance",
]
const SUN_KEYS := [
	"directional_shadow_mode", "directional_shadow_max_distance", "directional_shadow_split_1",
	"directional_shadow_split_2", "directional_shadow_split_3", "directional_shadow_blend_splits",
	"shadow_bias", "shadow_normal_bias",
]
const SKY_KEYS := ["process_mode", "radiance_size"]
const SNAP := &"g1_orbit_profile"
## Per preset: shadow distance, PSSM splits, blend, SSAO intensity, SSIL (radius 0 = off) and
## intensity, volumetric fog, sky radiance size.
const PRESETS := {
	"low": {"shadow": 8.0, "splits": [0.1, 0.3, 0.6], "mode": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS, "blend": false, "ao": 1.0, "il": 0.0, "il_i": 0.0, "vol": false, "radiance": Sky.RADIANCE_SIZE_64},
	# Medium uses 2 cascades (the near one to 29 m): with 4 cascades and blending, a street view drew
	# 950 shadow draw calls against 500 for the orbit profile, every building caught in every split.
	"medium": {"shadow": WS.SHADOW_MAX_DIST, "splits": [0.12, 0.3, 0.6], "mode": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS, "blend": false, "ao": 1.2, "il": WS.SSIL_RADIUS, "il_i": 0.6, "vol": false, "radiance": Sky.RADIANCE_SIZE_256},
	"high": {"shadow": 16.0, "splits": [0.05, 0.14, 0.38], "mode": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS, "blend": true, "ao": 1.3, "il": WS.SSIL_RADIUS, "il_i": 0.7, "vol": true, "radiance": Sky.RADIANCE_SIZE_256},
}
## Screen-space reflections per preset: ray-march steps (0 = never) and whether they stay on with
## the streets dry; otherwise they come on once the streets are WET_SSR wet (puddles and glossy
## asphalt, the paint of the cars), where they show. SSR_DEPTH is how thick (u) the march takes an
## object in front of the ray to be: a lamp post, not a whole house.
const SSR := {"low": [0, false], "medium": [32, false], "high": [56, true]}
const WET_SSR := 0.15
const SSR_DEPTH := 1.5 * WS.M
## Camera far plane per preset until G2's quality.gd provides camera_far().
const FAR_FALLBACK := {"low": 45.0, "medium": WS.CAMERA_FAR, "high": 75.0}


## Applies the street-level profile (mode "fp") for preset low|medium|high, or restores the orbit
## values snapshotted on the first fp apply (mode "orbit"). Either env or sun may be null.
static func apply(env: Environment, sun: DirectionalLight3D, mode: String, preset: String) -> void:
	if mode == "orbit":
		_restore(env, ENV_KEYS)
		_restore(sun, SUN_KEYS)
		if env != null and env.sky != null:
			_restore(env.sky, SKY_KEYS)
		return
	var p: Dictionary = PRESETS.get(preset, PRESETS["medium"])
	if env != null:
		_snapshot(env, ENV_KEYS)
		env.ssao_radius = WS.SSAO_RADIUS
		env.ssao_intensity = float(p["ao"])
		env.ssil_enabled = float(p["il"]) > 0.0
		if env.ssil_enabled:
			env.ssil_radius = float(p["il"])
			env.ssil_intensity = float(p["il_i"])
		env.fog_mode = Environment.FOG_MODE_DEPTH
		env.fog_density = 1.0
		env.fog_depth_begin = WS.FOG_DEPTH_BEGIN
		env.fog_depth_end = fog_end(preset)
		env.fog_depth_curve = 1.4
		env.fog_aerial_perspective = 0.35
		env.fog_sky_affect = 0.6
		env.volumetric_fog_enabled = bool(p["vol"])
		if env.volumetric_fog_enabled:
			env.volumetric_fog_length = 6.0
			env.volumetric_fog_density = 0.008
			env.volumetric_fog_detail_spread = 2.0
			env.volumetric_fog_anisotropy = 0.3
			env.volumetric_fog_temporal_reprojection_enabled = true
		var steps := int((SSR.get(preset, SSR["medium"]) as Array)[0])
		if steps > 0:
			env.ssr_max_steps = steps
			env.ssr_fade_in = 0.15
			env.ssr_fade_out = 2.0
			env.ssr_depth_tolerance = SSR_DEPTH
		env.ssr_enabled = reflections(preset, 0.0)
		if env.sky != null:
			_snapshot(env.sky, SKY_KEYS)
			env.sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
			env.sky.radiance_size = int(p["radiance"])
	if sun != null:
		_snapshot(sun, SUN_KEYS)
		sun.directional_shadow_mode = int(p["mode"])
		sun.directional_shadow_max_distance = float(p["shadow"])
		var s: Array = p["splits"]
		sun.directional_shadow_split_1 = float(s[0])
		sun.directional_shadow_split_2 = float(s[1])
		sun.directional_shadow_split_3 = float(s[2])
		sun.directional_shadow_blend_splits = bool(p["blend"])
		# Tuned for 8 cm street details: tight enough for kerbs and bollards, no acne on the ground.
		sun.shadow_bias = 0.02
		sun.shadow_normal_bias = 0.6


## Whether the preset reflects in screen space with the streets this wet (0..1).
static func reflections(preset: String, wet: float) -> bool:
	var s: Array = SSR.get(preset, SSR["medium"])
	return int(s[0]) > 0 and (bool(s[1]) or wet >= WET_SSR)


## The weather's hook: reflections on or off for how wet the streets are, once the street profile
## is applied (the orbit view keeps its own).
static func set_wet(env: Environment, preset: String, wet: float) -> void:
	if env == null or not env.has_meta(SNAP):
		return
	var on := reflections(preset, wet)
	if env.ssr_enabled != on:
		env.ssr_enabled = on


## Depth-fog end for a preset: WS.FOG_DEPTH_END, inside 95% of that preset's far plane.
static func fog_end(preset: String) -> float:
	return minf(WS.FOG_DEPTH_END, 0.95 * camera_far(preset))


## The preset's camera far plane: G2's quality.camera_far() when it exists, else FAR_FALLBACK.
static func camera_far(preset: String) -> float:
	var q := quality_script()
	if q != null and q.has_method("camera_far"):
		return float(q.call("camera_far", preset))
	return float(FAR_FALLBACK.get(preset, WS.CAMERA_FAR))


## G2's static quality helper (scripts/fp/render/quality.gd), or null until G2 lands.
static func quality_script() -> GDScript:
	if not ResourceLoader.exists(QUALITY):
		return null
	return load(QUALITY) as GDScript


## The orbit value of key on obj as snapshotted on the first fp apply, or null.
static func orbit_value(obj: Object, key: String) -> Variant:
	if obj == null or not obj.has_meta(SNAP):
		return null
	return (obj.get_meta(SNAP) as Dictionary).get(key)


static func _snapshot(obj: Object, keys: Array) -> void:
	if obj.has_meta(SNAP):
		return
	var d := {}
	for k: String in keys:
		d[k] = obj.get(k)
	obj.set_meta(SNAP, d)


static func _restore(obj: Object, keys: Array) -> void:
	if obj == null or not obj.has_meta(SNAP):
		return
	var d: Dictionary = obj.get_meta(SNAP)
	for k: String in keys:
		if d.has(k):
			obj.set(k, d[k])
	obj.remove_meta(SNAP)
