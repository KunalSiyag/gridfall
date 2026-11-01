extends SceneTree
## The SSAO switch that goes with the 3D scale. Compatibility's SSAO prints rows of dark horizontal
## lines on flat ground whenever the 3D view renders below native size (the web tier at every
## preset, desktop Compatibility Low), so the feature that owns the scale, render_opt, switches
## SSAO off there and gives the orbit value back on teardown. The street profile (streetscape) is
## not involved: either feature can be off (a flag) and the rule must still hold, with no SSAO
## lost where nothing is scaled.

const K := preload("res://tools/tests/fp_kit.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const LP := preload("res://scripts/fp/street/light_profile.gd")
const COMPAT := "gl_compatibility"
const FWD := "forward_plus"
const PRESETS := ["low", "medium", "high", "bogus"]

var fails: Array[String] = []


func _init() -> void:
	K.watchdog(self, "FP_SSAO_TEST")
	await process_frame
	var ctx := K.make_ctx(get_root(), {"render": true, "player": false, "hud": false})
	var env := ctx.env
	K.check(fails, env != null and env.ssao_enabled, "the orbit environment has SSAO on")
	if env == null:
		K.finish(self, "FP_SSAO_TEST", fails)
		return
	_check_rule(ctx)
	_check_orbit_off(ctx)
	await _check_street_profile(ctx)
	_check_bus_path(ctx)
	K.finish(self, "FP_SSAO_TEST", fails)


## What render_opt must leave an environment whose orbit SSAO is on: on Forward+ always, on
## Compatibility unless the preset renders scaled (the web tier, desktop Low). Spelled out here,
## not read back from Q.ssao_ok.
func _want(method: String, preset: String, web: bool) -> bool:
	return method != COMPAT or (not web and Q.normalize(preset) != "low")


## A fresh render_opt on ctx: setup() snapshots the Environment as it stands.
func _render_opt(ctx: FpContext) -> FpFeature:
	return K.make_feature(ctx, "render_opt")


## Takes the feature down the way FpMode does and frees it.
func _drop(ctx: FpContext, f: FpFeature) -> void:
	f.teardown()
	ctx.features.erase("render_opt")
	f.queue_free()


## render_opt alone (the street profile is not set up at all): every renderer, tier and preset
## follows the rule, SSAO is never on while Compatibility renders below native size and never off
## where it renders at native size, and teardown gives the orbit value and the native scale back.
func _check_rule(ctx: FpContext) -> void:
	var f := _render_opt(ctx)
	if f == null:
		K.check(fails, false, "render_opt sets up on the light context")
		return
	var follows := true
	var scaled_on := true
	var native_off := true
	var scale_agrees := true
	for method: String in [FWD, COMPAT]:
		for web: bool in [false, true]:
			for p: String in PRESETS:
				f.apply_preset(p, method, web)
				var scale := get_root().scaling_3d_scale
				var on := ctx.env.ssao_enabled
				var want_scale := float(Q.viewport_knobs(p, method, web)["scale"])
				scale_agrees = scale_agrees and is_equal_approx(scale, want_scale)
				follows = follows and on == _want(method, p, web)
				if method == COMPAT:
					scaled_on = scaled_on and not (scale < 1.0 and on)
					native_off = native_off and not (scale >= 1.0 and not on)
	K.check(fails, scale_agrees, "render_opt applies the 3D scale of each renderer and tier")
	K.check(
		fails, follows, "render_opt alone: SSAO follows the rule on every renderer, tier, preset"
	)
	K.check(fails, scaled_on, "Compatibility: SSAO is never on while the 3D view renders scaled")
	K.check(fails, native_off, "Compatibility: SSAO is never off while the 3D view renders native")
	f.apply_preset("high", COMPAT, true)
	K.check(fails, not ctx.env.ssao_enabled, "web tier High: SSAO off")
	_drop(ctx, f)
	K.check(fails, ctx.env.ssao_enabled, "teardown gives the orbit SSAO back")
	K.check(fails, is_equal_approx(get_root().scaling_3d_scale, 1.0), "teardown: native scale back")


## An orbit environment with SSAO off stays off whatever render_opt applies, and is given back off
## (the rule only ever switches SSAO off).
func _check_orbit_off(ctx: FpContext) -> void:
	ctx.env.ssao_enabled = false
	var f := _render_opt(ctx)
	var stays_off := true
	for method: String in [FWD, COMPAT]:
		for web: bool in [false, true]:
			for p: String in PRESETS:
				f.apply_preset(p, method, web)
				stays_off = stays_off and not ctx.env.ssao_enabled
	K.check(fails, stays_off, "orbit SSAO off: stays off at every renderer, tier and preset")
	_drop(ctx, f)
	K.check(fails, not ctx.env.ssao_enabled, "orbit SSAO off: teardown gives it back off")
	ctx.env.ssao_enabled = true


## The street profile never writes the SSAO switch (whatever the renderer), so streetscape alone
## leaves SSAO as it was, and with both features on, in either order of setup and teardown, the
## orbit value comes back.
func _check_street_profile(ctx: FpContext) -> void:
	var env := ctx.env
	var untouched := true
	for p: String in PRESETS:
		LP.apply(env, null, "fp", p)
		untouched = untouched and env.ssao_enabled
	LP.apply(env, null, "orbit", "medium")
	K.check(fails, untouched and env.ssao_enabled, "street profile alone leaves SSAO as it was")
	K.check(fails, not LP.ENV_KEYS.has("ssao_enabled"), "the street profile does not own SSAO")
	# The registry's order: streetscape first, render_opt second; teardown in reverse.
	LP.apply(env, null, "fp", "medium")
	var f := _render_opt(ctx)
	f.apply_preset("low", COMPAT, true)
	K.check(fails, not env.ssao_enabled, "both features on, web tier: SSAO off")
	_drop(ctx, f)
	K.check(fails, env.ssao_enabled, "both features on: render_opt teardown gives SSAO back")
	LP.apply(env, null, "orbit", "medium")
	K.check(fails, env.ssao_enabled, "both features on: the street profile's teardown keeps it")
	# The other order: the street profile comes down first, render_opt still holds the scale.
	LP.apply(env, null, "fp", "high")
	f = _render_opt(ctx)
	f.apply_preset("high", COMPAT, true)
	LP.apply(env, null, "orbit", "high")
	K.check(fails, not env.ssao_enabled, "street profile down first: SSAO stays off with the scale")
	_drop(ctx, f)
	K.check(fails, env.ssao_enabled, "street profile down first: render_opt gives SSAO back")
	await process_frame


## The real path: the quality menu emits quality_changed and render_opt applies the preset on the
## running renderer. On Compatibility (gate step fp_ssao_test_gl) SSAO must follow the scale the
## viewport really has; on Forward+ it stays on.
func _check_bus_path(ctx: FpContext) -> void:
	var f := _render_opt(ctx)
	var ok := true
	var seen := ""
	for p: String in ["low", "high", "medium", "low", "medium"]:
		ctx.bus.quality_changed.emit(p)
		var scaled := get_root().scaling_3d_scale < 1.0
		var on := ctx.env.ssao_enabled
		var want := (not scaled) if Q.is_compat() else true
		ok = ok and on == want
		seen += " %s:scale=%.2f,ssao=%s" % [p, get_root().scaling_3d_scale, on]
	K.check(
		fails,
		ok,
		(
			"quality menu on %s: SSAO follows the real scale (%s)"
			% [RenderingServer.get_current_rendering_method(), seen.strip_edges()]
		)
	)
	_drop(ctx, f)
	K.check(fails, ctx.env.ssao_enabled, "quality menu path: teardown gives the orbit SSAO back")
