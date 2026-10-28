extends RefCounted
## First-person quality presets (slice G2): the knobs each preset sets, and the static helpers every
## slice reads without a feature lookup (vis_mult, max_street_lights, camera_far). The render_opt
## feature applies a preset at runtime; G1's light profile owns the Environment and Sun values.

const WS := preload("res://scripts/fp/world_scale.gd")
const NAMES := ["low", "medium", "high"]
const DEFAULT := "medium"
## Per preset: 3D scaling (FSR2 also brings its own temporal AA, so MSAA stays off), directional
## shadow atlas and filter, SSAO and SSIL quality and half size, the VIS_* multiplier, the
## first-person camera far plane, the mesh LOD threshold (pixels of error) and G1's street lights.
const PRESETS := {
	"low":
	{
		"scaling_mode": Viewport.SCALING_3D_MODE_FSR2,
		"scale": 0.59,
		"msaa": Viewport.MSAA_DISABLED,
		"atlas": 2048,
		"atlas_16": true,
		"soft": RenderingServer.SHADOW_QUALITY_HARD,
		"ssao": RenderingServer.ENV_SSAO_QUALITY_VERY_LOW,
		"ssao_half": true,
		"ssil": RenderingServer.ENV_SSIL_QUALITY_VERY_LOW,
		"ssil_half": true,
		"vis": 0.7,
		"far": 45.0,
		"lod": 2.0,
		"lights": 6,
	},
	"medium":
	{
		"scaling_mode": Viewport.SCALING_3D_MODE_FSR2,
		"scale": 0.77,
		"msaa": Viewport.MSAA_DISABLED,
		"atlas": 4096,
		"atlas_16": true,
		"soft": RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		"ssao": RenderingServer.ENV_SSAO_QUALITY_MEDIUM,
		"ssao_half": true,
		"ssil": RenderingServer.ENV_SSIL_QUALITY_LOW,
		"ssil_half": true,
		"vis": 1.0,
		"far": WS.CAMERA_FAR,
		"lod": 1.0,
		"lights": 12,
	},
	"high":
	{
		"scaling_mode": Viewport.SCALING_3D_MODE_FSR2,
		"scale": 0.9,
		"msaa": Viewport.MSAA_DISABLED,
		"atlas": 4096,
		"atlas_16": true,
		"soft": RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM,
		"ssao": RenderingServer.ENV_SSAO_QUALITY_HIGH,
		"ssao_half": false,
		"ssil": RenderingServer.ENV_SSIL_QUALITY_MEDIUM,
		"ssil_half": false,
		"vis": 1.3,
		"far": 75.0,
		"lod": 0.75,
		"lights": 16,
	},
}


## The preset name itself when known, else DEFAULT.
static func normalize(preset: String) -> String:
	return preset if PRESETS.has(preset) else DEFAULT


## Every knob of a preset (unknown names give the default preset), with the web tier's overlay
## merged on top when web_mode() is on. web forces the tier in tests.
static func knobs(preset: String, web: bool = false) -> Dictionary:
	var k: Dictionary = PRESETS[normalize(preset)].duplicate()
	if web_mode(web):
		k.merge(WEB, true)
	return k


## The Compatibility renderer (the web build) has no FSR2: on the desktop GL driver setting it
## crashes the engine as the first frame draws. It scales bilinearly instead, with no temporal pass
## to hide aliasing, so the scale stays near native and MSAA (its only 3D antialiasing) stands in
## for FSR2's TAA.
const COMPAT := {
	"low": {"scale": 0.77, "msaa": Viewport.MSAA_DISABLED},
	"medium": {"scale": 1.0, "msaa": Viewport.MSAA_2X},
	"high": {"scale": 1.0, "msaa": Viewport.MSAA_4X},
}

## The web tier's render knobs (flag web_quality), below Low: the browser build auto-selects
## Low (fp_mode's GpuMemory probe) and this overlay cheapens it further — the 2-core web box
## cannot feed Low's scaling, shadow atlas and ranges at a steady frame rate. Merged over the
## preset inside knobs() when web_mode() is on; desktop runs never see it.
const WEB := {
	"scale": 0.6,
	"atlas": 1024,
	"vis": 0.55,
	"far": 35.0,
	"lod": 2.5,
	"lights": 4,
}
## Density ceilings the web quality tier publishes for the traffic, crowd and animal owners to
## clamp their budgets to; each owner tunes its own number with before/after FPS evidence.
const WEB_DENSITY := {"traffic": 12, "crowd": 24, "animals": 6}

## Browser pacing: physics catch-up steps a frame may run, below the engine default of 8. The
## browser build pays 6-35 ms per physics step, so 8 catch-up steps after a slow frame add more
## work than the frame itself; at 2 the physics share of a hitch stays bounded and physics time
## dilates instead. Desktop keeps the engine default.
const WEB_MAX_PHYSICS_STEPS := 2


## True in the browser export.
static func is_web() -> bool:
	return OS.has_feature("web")


## Caps the physics catch-up steps per frame in the browser (main.gd calls it once at boot, so
## it covers the orbit and street modes alike); a slow frame then cannot add a multiple of the
## per-step physics cost while catching up. Desktop keeps the engine default. web forces the
## cap in tests.
static func cap_physics_steps(web: bool = false) -> void:
	if web or is_web():
		Engine.max_physics_steps_per_frame = WEB_MAX_PHYSICS_STEPS


## Set by park_physics_server; tests assert the web path parks and the desktop path does not.
static var physics_parked := false


## Parks the 3D physics server in the browser: the physics space is empty (CollisionWorld is
## analytic, nothing registers a body, area or shape, and no shipped script rides the physics
## frame), so GodotPhysics pays its ~5-7 ms per-step scaffolding on wasm to simulate nothing.
## Physics frames still tick for SceneTree timers; desktop keeps the server active. web forces
## the park in tests.
static func park_physics_server(web: bool = false) -> void:
	if web or is_web():
		PhysicsServer3D.set_active(false)
		physics_parked = true


## Web tier active: the web build with flag web_quality on. web forces it on in tests.
static func web_mode(web: bool = false) -> bool:
	return web or (is_web() and FeatureFlags.enabled("web_quality", true))


## Density ceilings for the web tier: {} off the web or with the flag off (owners keep their
## current budgets then). GRIDFALL_WEB_CAPS="traffic=8,crowd=16" overrides single values so
## profiling can bisect without a rebuild (desktop gl_compatibility runs); unknown keys are
## ignored.
static func density_caps(web: bool = false) -> Dictionary:
	if not web_mode(web):
		return {}
	var caps := WEB_DENSITY.duplicate()
	for pair in OS.get_environment("GRIDFALL_WEB_CAPS").split(",", false):
		var kv := pair.split("=", true, 1)
		if kv.size() == 2 and caps.has(kv[0]):
			caps[kv[0]] = kv[1].to_int()
	return caps


## True when the running renderer is Compatibility (the web build, or a desktop run with
## --rendering-method gl_compatibility). method overrides the running one (tests).
static func is_compat(method: String = "") -> bool:
	var m := method
	if m.is_empty():
		m = RenderingServer.get_current_rendering_method()
	return m == "gl_compatibility"


## The viewport's 3D scaling knobs for a preset on a renderer: the preset's own (FSR2) on
## Forward+, COMPAT's bilinear scale and MSAA on Compatibility.
static func viewport_knobs(preset: String, method: String = "", web: bool = false) -> Dictionary:
	var k := knobs(preset, web)
	var out := {"scaling_mode": int(k["scaling_mode"]), "scale": float(k["scale"])}
	out["msaa"] = int(k["msaa"])
	if is_compat(method):
		var c: Dictionary = COMPAT[normalize(preset)]
		out = {"scaling_mode": Viewport.SCALING_3D_MODE_BILINEAR, "scale": float(c["scale"])}
		out["msaa"] = int(c["msaa"])
	if web_mode(web):
		# The web tier scales below COMPAT Low; the bilinear pass has no TAA to hide aliasing,
		# but MSAA costs more than it earns at 0.6 scale on the 2-core web box.
		out["scale"] = float(WEB["scale"])
		out["msaa"] = Viewport.MSAA_DISABLED
	return out


## Multiplier on every WS.VIS_* range: 0.7 / 1.0 / 1.3 (0.55 in the web tier).
static func vis_mult(preset: String, web: bool = false) -> float:
	return float(knobs(preset, web)["vis"])


## Street lights G1 keeps lit around the player: 6 / 12 / 16 (4 in the web tier).
static func max_street_lights(preset: String, web: bool = false) -> int:
	return int(knobs(preset, web)["lights"])


## First-person camera far plane in world units: 45 / WS.CAMERA_FAR (60) / 75 (35 in the web
## tier).
static func camera_far(preset: String, web: bool = false) -> float:
	return float(knobs(preset, web)["far"])


## How far the camera must see while it is over the city (the overview lifts it up to 32 u, and a
## photo fly can go higher): past every visible ground point at the lowest pitch, with margin. Low
## keeps the tightest plane that still covers the overview horizon (the low_vram budget): at the
## default pitch nothing lies past 80 at any city size, and only pitches under ~45 degrees over
## cities wider than ~90 tiles lose a far slice, where 110 would cost Low +1 to +9 ms of GPU.
const AERIAL_FAR := {"low": 80.0, "medium": 110.0, "high": 110.0}


## The far plane while the camera is aerial (render_opt's aerial coverage), never below the
## street-plane value.
static func aerial_far(preset: String) -> float:
	return maxf(camera_far(preset), float(AERIAL_FAR[normalize(preset)]))


## Depth-fog end while the camera is aerial, inside 95% of the aerial far plane (the same rule the
## street profile applies to its own plane: light_profile.fog_end).
static func aerial_fog_end(preset: String) -> float:
	return 0.95 * aerial_far(preset)


## Sun shadows while the camera is aerial reach as far as the aerial plane on Forward+, so the
## city keeps its shadows from the sky (the impostor chunks cast them then: one low-poly draw per
## chunk and cascade). On Compatibility every cascade redraws each shadowed mesh in the forward
## pass, and a full aerial reach there costs hundreds of draws, so its reach caps tighter. Low
## drops the pass entirely: at the overview's 26 u altitude a sub-26 m frustum casts nothing
## anyway (measured: reach 24 == shadows off, draw-for-draw), and the pass is ~660 draws plus
## 1-2 ms of render CPU the 2-core web box cannot spare. Every nonzero cap sits clear of the
## street profile's 8/12/16 reaches, so render_opt's street-value snapshot never mistakes one for
## the other. The cascade splits stay fractions of the reach: the camera hangs over the roofs, so
## the nearest ground is far from the lens (split 1 is all a 2-split preset uses).
const AERIAL_SHADOW_SPLITS := [0.4, 0.6, 0.8]
## Aerial shadow reach per preset on Compatibility; 0 means the sun's shadow pass is off while
## aerial (render_opt disables it and restores the street state on exit).
const COMPAT_AERIAL_SHADOW := {"low": 0.0, "medium": 48.0, "high": 64.0}


static func aerial_shadow(preset: String, method: String = "") -> float:
	if is_compat(method):
		return float(COMPAT_AERIAL_SHADOW[normalize(preset)])
	return aerial_far(preset)


## The street fog end for a preset (light_profile.fog_end's rule, for restoring it on exit).
static func street_fog_end(preset: String) -> float:
	return minf(WS.FOG_DEPTH_END, 0.95 * camera_far(preset))
