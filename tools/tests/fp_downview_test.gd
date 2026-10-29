extends SceneTree
## The down view (down_view): knocked down in first person, the eye goes with the body — sinking
## flat through the fall, tipped a little up to the sky through the lie, back up with the get-up
## — and control still returns exactly when the get-up ends, never before. Third person reads the
## body's anim (the camera stays); with the flag off the eye stays at standing height.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []
var ctx: FpContext
var f: FpFeature


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true})
	f = K.make_feature(ctx, "health")
	f.set_process(false)
	_check_first_person()
	_check_flag_off()
	_check_third_person()
	K.finish(self, "FP_DOWNVIEW_TEST", fails)


## One frame: health's tick, then the player and its camera.
func _step(secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		f.call("tick", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)


## The eye's height above the feet (m).
func _eye_m() -> float:
	var p := ctx.player
	return (p.camera.global_transform.origin.y - p.position.y) / WS.M


## First person: the eye sinks flat through the fall and the lie, then rises with the get-up.
func _check_first_person() -> void:
	_step(0.3)
	var standing := _eye_m()
	ctx.player.input_enabled = true
	f.call("hurt", 25.0, "punch", Vector3(0.0, 0.0, -2.0 * WS.M), true)
	_step(1.2)  # past the fall (0.35 s or the rig's knockback), mid-lie
	K.check(
		fails,
		standing - _eye_m() > 0.8,
		(
			"first person: down, the eye sinks toward the ground (%.2f m over %.2f)"
			% [_eye_m(), standing]
		)
	)
	_knock_and_ride_late()
	_step(0.4)
	K.check(
		fails,
		absf(_eye_m() - standing) < 0.2,
		"and is back at standing height once up (%.2f)" % _eye_m()
	)


## The rest of the knock-down begun in _check_first_person, pinning the input timing.
func _knock_and_ride_late() -> void:
	var p := ctx.player
	var held := true
	var t := 0.0
	while bool(f.call("knocked")) and t < 9.0:
		held = held and not p.input_enabled
		_step(DT)
		t += DT
	K.check(fails, held and p.input_enabled, "control returns exactly as the get-up ends")


## With the flag off the view stays at standing height while the body lies.
func _check_flag_off() -> void:
	_step(0.2)
	var standing := _eye_m()
	FeatureFlags.set_override("down_view", false)
	ctx.player.input_enabled = true
	f.call("hurt", 25.0, "punch", Vector3(0.0, 0.0, -2.0 * WS.M), true)
	_step(1.2)
	K.check(
		fails,
		absf(_eye_m() - standing) < 0.2,
		"flag off: the eye stays at standing height while down (%.2f)" % _eye_m()
	)
	_knock_and_ride_late()
	FeatureFlags.set_override("down_view", true)


## Third person reads the body's anim; the camera does not sink.
func _check_third_person() -> void:
	ctx.player.set_camera_mode("third", false)
	_step(0.3)
	var before: float = ctx.player.camera.global_transform.origin.y
	f.call("hurt", 25.0, "punch", Vector3(0.0, 0.0, -2.0 * WS.M), true)
	_step(1.2)
	var drop: float = before - ctx.player.camera.global_transform.origin.y
	K.check(fails, absf(drop) < 0.15 * WS.M, "third person: the camera stays (%.2f)" % drop)
	_knock_and_ride_late()
	ctx.player.set_camera_mode("first", false)
