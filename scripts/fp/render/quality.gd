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
## Density ceilings the web quality tier publishes for the traffic, crowd, animal and rain owners
## to clamp their budgets to; each owner tunes its own number with before/after evidence (FPS for
## the first three, streak pixels in screenshots for the rain emitter's particle count).
const WEB_DENSITY := {"traffic": 12, "crowd": 24, "animals": 6, "rain": 600}

## Browser pacing: physics catch-up steps a frame may run, below the engine default of 8. The
## browser build pays 6-35 ms per physics step, so 8 catch-up steps after a slow frame add more
## work than the frame itself; at 2 the physics share of a hitch stays bounded and physics time
## dilates instead. Desktop keeps the engine default.
const WEB_MAX_PHYSICS_STEPS := 2
## With flag web_real_time_pace (off by default; the pause menu and the planner HUD flip it on the
## web build) the cap is 4: the world keeps real time down to 15 fps and a frame's delta stays
## near 83 ms. The price is more sim turns, chat drips and live GMI calls per real minute.
const WEB_MAX_PHYSICS_STEPS_REAL_TIME := 4


## True in the browser export.
static func is_web() -> bool:
	return OS.has_feature("web")


## Caps the physics catch-up steps per frame in the browser (main.gd calls it once at boot, so
## it covers the orbit and street modes alike); a slow frame then cannot add a multiple of the
## per-step physics cost while catching up. Desktop keeps the engine default. web forces the
## cap in tests.
static func cap_physics_steps(web: bool = false) -> void:
	if web or is_web():
		Engine.max_physics_steps_per_frame = web_physics_steps()


## The browser's catch-up cap now: WEB_MAX_PHYSICS_STEPS, or the real-time one with the flag on.
static func web_physics_steps() -> int:
	return WEB_MAX_PHYSICS_STEPS_REAL_TIME if real_time_pace() else WEB_MAX_PHYSICS_STEPS


## Whether the player (or the flag file) asked for real-time pace on slow frames.
static func real_time_pace() -> bool:
	return FeatureFlags.enabled("web_real_time_pace", false)


## Turns real-time pace on or off now (the cap changes this frame), and with persist keeps the
## choice in the user flag file for the next boot. web forces the web path in tests.
static func set_real_time_pace(on: bool, web: bool = false, persist: bool = true) -> void:
	FeatureFlags.set_override("web_real_time_pace", on)
	if persist:
		FeatureFlags.save_user("web_real_time_pace", on)
	cap_physics_steps(web)


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


## Whether the Environment's SSAO may stay on under a preset. Observed on Compatibility (Godot
## 4.7.2): when the 3D view renders below native size, the plaza ground seen from the street shows
## rows of dark horizontal lines fixed to the screen, continuous on High and dashed on Low. Only
## that street view was measured: in the day city overview, SSAO on and off measured the same on a
## lawn and a road (faint rows showed on a dark lawn in one dawn-rain overview shot, with no shot
## with SSAO off to compare), so the overview loses its ambient occlusion with no measured gain.
## Measured on the web build on a real GPU (ANGLE, AMD), 2026-11-01, as the rms of a high-passed
## row profile of the plaza ground in 8-bit grey levels, in the street photo's left and right plaza
## boxes: 12.2 / 10.2 / 13.1 (left) and 14.2 / 10.4 / 12.8 (right) at Low / Medium / High at the
## web tier's 0.6 scale (rows about 5 px apart); 11.1 and 14.2 at Compatibility Low's 0.77 (about
## 4.3 px apart); against 0.7 to 1.6 (left) and 1.3 to 3.0 (right) with SSAO off (zeroing
## ssao_intensity does the same) or at native size (Medium and High, flag off). Why SSAO draws the
## rows is not established; the rule rests on those measurements. So on Compatibility SSAO stays
## off whenever the preset renders the 3D view below native size. render_opt applies it with the
## scale, so the two stand or fall together. The price: no ambient occlusion in the web build's
## first-person view at any preset, and none on desktop Compatibility Low (not measured on a
## desktop run; the 0.77 result is from the web build with the flag off); Forward+ and native-size
## Compatibility keep it. method and web override the running renderer and the web tier (tests).
static func ssao_ok(preset: String, method: String = "", web: bool = false) -> bool:
	if not is_compat(method):
		return true
	return float(viewport_knobs(preset, method, web)["scale"]) >= 1.0


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
## asks for the pass off (render_opt writes sun.shadow_enabled = false on entry): at the overview's
## 26 u altitude a sub-26 m frustum casts nothing anyway (measured: reach 24 == shadows off,
## draw-for-draw), and the pass is ~660 draws plus 1-2 ms of render CPU the 2-core web box cannot
## spare. Known gap: SkyDirector rewrites sun.shadow_enabled every frame (_apply, energy > 0.02,
## which holds at every hour), so the request is undone a frame later and the pass stays on; what
## keeps Low clean at the default overview altitude is its 8 u street reach, not the pass being
## off. Making the request real is a separate decision. Every nonzero cap sits clear of the
## street profile's 8/12/16 reaches, so render_opt's street-value snapshot never mistakes one for
## the other. The cascade splits stay fractions of the reach: the camera hangs over the roofs, so
## the nearest ground is far from the lens (split 1 is all a 2-split preset uses).
const AERIAL_SHADOW_SPLITS := [0.4, 0.6, 0.8]
## Aerial shadow reach per preset on Compatibility; 0 asks for the sun's shadow pass to be off while
## aerial (render_opt disables it and restores the street state on exit; SkyDirector turns it back
## on every frame, see AERIAL_SHADOW_SPLITS).
const COMPAT_AERIAL_SHADOW := {"low": 0.0, "medium": 48.0, "high": 64.0}


static func aerial_shadow(preset: String, method: String = "") -> float:
	if is_compat(method):
		return float(COMPAT_AERIAL_SHADOW[normalize(preset)])
	return aerial_far(preset)


## The sun's shadow normal bias per preset while the camera is over the city or the overview is
## open. On Compatibility the street profile's 0.6 (tuned for 8 cm kerbs) is too small for the wide
## cascades that view needs: the road and sidewalk pieces cast shadows (the ground does not), so
## they shade themselves in coherent diagonal stripes. They show at Medium and High from the default
## overview altitude (Low's 8 u street reach sees no ground from there) and, zoomed in under
## AERIAL_OFF, at Low too, as strong on the roads as at Medium. Low and Medium (two cascades) take
## 3.0 and High (four, blended; finer texels, a guess not isolated) 2.0: the sweep below is the
## evidence, a single value over-corrects High.
## Measured on the web build on a real GPU (ANGLE, AMD) with a scratch metric that is not in the
## repo (robust rms of the road's and sidewalk's high-passed luminance, grey levels, default
## overview, sky hour pinned; the mask moves the absolute figures, so trust the order; clean floor
## about 0.15 to 0.3). Medium at hour 15.5: 0.6 reads 2.05 / 1.61 (road / sidewalk) and 3.0 reads
## 0.33 / 0.20; at hour 16.5: 1.35 / 1.10 and 0.53 / 0.48; an earlier sweep read 1.2 to 1.4 at 2.0
## and about 0.6 at 2.5. High at hour 15.5: 0.6 reads 0.93 / 1.03, 1.5 reads 0.27 / 0.18, 2.0 reads
## 0.22 / 0.15, 3.0 reads 0.18 / 0.16; at hour 16.5: 0.73 / 0.73, 0.40 / 0.35, 0.27 / 0.16 and 0.20
## / 0.15 (1.5 leaves a faint residue at the lower sun, so High takes 2.0). The depth bias (0.1) and
## 32-bit shadow depth changed nothing; a 4096 atlas cut it by a quarter, not enough. Roads and
## sidewalks set to cast nothing also clean it (0.37) without thinning any shadow, but that reaches
## the street view too and was not measured on foot.
## The price is shadow strength: the bias lifts the lookup off every surface, so soft shadows fade
## at their far ends. Share of the tree shadows' darkness on the lawn kept against 0.6, same pose:
## Medium at 3.0, 0.87 (hour 15.5) and 1.0 (hour 16.5); High at 3.0, 0.53 and 0.70, at 2.0, 0.68 and
## 0.80 (the 3.0 that cleans Medium washed the High tree shadows out). Thin casters lose theirs (the
## lamp pole's, seen at Low zoomed in, is gone at 3.0; it was faint at Medium); 8.0 washes tree
## shadows out at Medium too. Forward+ keeps the street value.
const COMPAT_AERIAL_NORMAL_BIAS := {"low": 3.0, "medium": 3.0, "high": 2.0}


## The sun's normal bias over the city: the preset's COMPAT_AERIAL_NORMAL_BIAS on Compatibility,
## the street profile's own (street) on any other renderer.
static func aerial_normal_bias(preset: String, street: float, method: String = "") -> float:
	if is_compat(method):
		return float(COMPAT_AERIAL_NORMAL_BIAS[normalize(preset)])
	return street


## The street fog end for a preset (light_profile.fog_end's rule, for restoring it on exit).
static func street_fog_end(preset: String) -> float:
	return minf(WS.FOG_DEPTH_END, 0.95 * camera_far(preset))
