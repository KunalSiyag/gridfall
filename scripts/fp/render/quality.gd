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
	"low": {
		"scaling_mode": Viewport.SCALING_3D_MODE_FSR2, "scale": 0.59, "msaa": Viewport.MSAA_DISABLED,
		"atlas": 2048, "atlas_16": true, "soft": RenderingServer.SHADOW_QUALITY_HARD,
		"ssao": RenderingServer.ENV_SSAO_QUALITY_VERY_LOW, "ssao_half": true,
		"ssil": RenderingServer.ENV_SSIL_QUALITY_VERY_LOW, "ssil_half": true,
		"vis": 0.7, "far": 45.0, "lod": 2.0, "lights": 6,
	},
	"medium": {
		"scaling_mode": Viewport.SCALING_3D_MODE_FSR2, "scale": 0.77, "msaa": Viewport.MSAA_DISABLED,
		"atlas": 4096, "atlas_16": true, "soft": RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		"ssao": RenderingServer.ENV_SSAO_QUALITY_MEDIUM, "ssao_half": true,
		"ssil": RenderingServer.ENV_SSIL_QUALITY_LOW, "ssil_half": true,
		"vis": 1.0, "far": WS.CAMERA_FAR, "lod": 1.0, "lights": 12,
	},
	"high": {
		"scaling_mode": Viewport.SCALING_3D_MODE_FSR2, "scale": 0.9, "msaa": Viewport.MSAA_DISABLED,
		"atlas": 4096, "atlas_16": true, "soft": RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM,
		"ssao": RenderingServer.ENV_SSAO_QUALITY_HIGH, "ssao_half": false,
		"ssil": RenderingServer.ENV_SSIL_QUALITY_MEDIUM, "ssil_half": false,
		"vis": 1.3, "far": 75.0, "lod": 0.75, "lights": 16,
	},
}


## The preset name itself when known, else DEFAULT.
static func normalize(preset: String) -> String:
	return preset if PRESETS.has(preset) else DEFAULT


## Every knob of a preset (unknown names give the default preset).
static func knobs(preset: String) -> Dictionary:
	return PRESETS[normalize(preset)]


## Multiplier on every WS.VIS_* range: 0.7 / 1.0 / 1.3.
static func vis_mult(preset: String) -> float:
	return float(knobs(preset)["vis"])


## Street lights G1 keeps lit around the player: 6 / 12 / 16.
static func max_street_lights(preset: String) -> int:
	return int(knobs(preset)["lights"])


## First-person camera far plane in world units: 45 / WS.CAMERA_FAR (60) / 75.
static func camera_far(preset: String) -> float:
	return float(knobs(preset)["far"])
