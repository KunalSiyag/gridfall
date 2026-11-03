extends SceneTree
## The wading hero's sound (unit A3, hero_wade): a step on surface "water" is a footstep_splash,
## never a sidewalk step; deeper water is louder and lower; the first splashing step after dry
## ground adds a heavier second layer; the bank's dry shelf is wet mud (dirt); the river bed comes
## up while wading; the sound list names every asset once.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")
const FS := preload("res://scripts/fp/audio/footsteps.gd")
const AMB := preload("res://scripts/fp/audio/ambience.gd")

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "audio": true})
	var f: FpFeature = K.make_feature(ctx, "audio")
	f.set_process(false)
	_check_bank()
	_check_steps(ctx, f)
	_check_ambience(ctx, f)
	K.finish(self, "FP_WADE_AUDIO_TEST", fails)


func _check_bank() -> void:
	K.check(
		fails,
		"water" in BANK.SURFACES and BANK.step_surface("water") == "water",
		"water is a step surface"
	)
	K.check(
		fails,
		(
			BANK.step_name("water", 1) == "footstep_splash_1"
			and BANK.step_name("water", 5) == "footstep_splash_1"
			and BANK.step_name("water", 6) == "footstep_splash_2"
			and BANK.step_name("asphalt", 3) == "footstep_asphalt_3"
		),
		"water's steps are the footstep_splash set (odd left, even right); the rest is unchanged"
	)
	var seen := {}
	for n in BANK.all_names():
		seen[n] = int(seen.get(n, 0)) + 1
	K.check(fails, seen.values().max() == 1, "the asset list names every sound once")
	K.check(fails, seen.has("footstep_splash_4"), "and keeps the splash set")


func _feet(fs: FS) -> AudioStreamPlayer:
	return fs._feet[1] if fs._left else fs._feet[0]


func _check_steps(ctx: FpContext, f: FpFeature) -> void:
	var fs: FS = f.get("footsteps")
	var p := ctx.player
	fs.play("water")
	var last := str(fs.history.back())
	K.check(
		fails,
		last.begins_with("footstep_splash_") and not last.begins_with("footstep_sidewalk"),
		"a step on water plays a splash, not a sidewalk step (%s)" % last
	)
	var wet := Vector3(NAN, 0, NAN)
	for i in ctx.sim.active:
		if ctx.sim.terrain[i] == D.WATER and ctx.sim.kind[i] != D.ROAD:
			wet = Vector3(D.tx(i), 0, D.ty(i))
			break
	K.check(
		fails,
		not is_nan(wet.x) and ctx.collision.water_depth(wet) > 0.5 * WS.M,
		"fixture: open water"
	)
	fs.play_wade(0.0)
	last = str(fs.history.back())
	K.check(
		fails, last.begins_with("footstep_dirt_"), "the dry shelf of a bank is wet mud (%s)" % last
	)
	var sp0 := fs.splashes_played
	fs.play_wade(0.15)
	var shallow := _feet(fs)
	var shallow_db := shallow.volume_db
	var shallow_pitch := shallow.pitch_scale
	K.check(
		fails,
		fs.splashes_played == sp0 + 1,
		"the first step in the water adds the entry splash layer (%d)" % (fs.splashes_played - sp0)
	)
	fs.play_wade(0.15)
	K.check(fails, fs.splashes_played == sp0 + 1, "the second step in the water does not")
	fs.play_wade(0.75)
	var deep := _feet(fs)
	K.check(
		fails,
		deep.volume_db > shallow_db + 1.0,
		"deeper water is louder (%.1f dB against %.1f dB)" % [deep.volume_db, shallow_db]
	)
	K.check(
		fails,
		deep.pitch_scale < shallow_pitch,
		"deeper water is lower (%.2f against %.2f)" % [deep.pitch_scale, shallow_pitch]
	)
	fs.play_wade(0.0)
	fs.play_wade(0.15)
	K.check(fails, fs.splashes_played == sp0 + 2, "stepping out and in again splashes once more")
	var n := fs.steps_played
	p.emit_signal("stepped", "water", wet)
	last = str(fs.history.back())
	K.check(
		fails,
		fs.steps_played == n + 1 and last.begins_with("footstep_splash_"),
		"the player's stepped(water) plays a splash (%s)" % last
	)


func _check_ambience(ctx: FpContext, f: FpFeature) -> void:
	var amb: AMB = f.get("ambience")
	var p := ctx.player
	p.wade_depth = 0.0
	K.check(
		fails,
		amb._wade_boost_db("river") == 0.0 and amb._wade_boost_db("rain") == 0.0,
		"no river boost on land"
	)
	p.wade_depth = 0.5 * WS.M
	K.check(
		fails,
		(
			is_equal_approx(amb._wade_boost_db("river"), BANK.WADE_RIVER_DB)
			and amb._wade_boost_db("rain") == 0.0
		),
		"the river bed is %.0f dB louder at half a metre of water" % BANK.WADE_RIVER_DB
	)
	p.wade_depth = 0.0
