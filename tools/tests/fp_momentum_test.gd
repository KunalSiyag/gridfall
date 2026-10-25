extends SceneTree
## Momentum (the "momentum" flag, scripts/fp/player/player.gd): getting up to a run and pulling up
## from one take longer than a walk's, and a hard turn at a run sheds pace until the body faces the
## way; with the flag off the old brisk half-lives come back. Third person on a grown city.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const SM := preload("res://scripts/fp/player/spring_math.gd")
const PL := preload("res://scripts/fp/player/player.gd")
const DT := 1.0 / 60.0
const M := WS.M

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	# Shift tops out at a run here; the sprint free running builds past it is fp_freerun_test's.
	ctx.player.free_running = false
	K.check(fails, ctx.player.momentum, "the momentum flag is on by default")
	var s := K.sidewalk(ctx, 0.7)
	K.check(fails, not s.is_empty(), "fixture: a clear straight sidewalk")
	if not s.is_empty():
		_check_start(ctx, s)
		_check_stop(ctx, s)
	_check_turn_keep(ctx)
	K.finish(self, "FP_MOMENTUM_TEST", fails)


## 3 s from rest covers speed * 3 less the spring's lag (SM.stop_distance at the start half-life):
## a run starts on HL_SPEED_UP_RUN, a walk on HL_SPEED_UP; off, a run starts on HL_SPEED_UP too.
func _check_start(ctx: FpContext, s: Dictionary) -> void:
	var p := ctx.player
	for row: Array in [
		["walk", false, true, WS.WALK, PL.HL_SPEED_UP],
		["run", true, true, WS.RUN, PL.HL_SPEED_UP_RUN],
		["run, flag off", true, false, WS.RUN, PL.HL_SPEED_UP]
	]:
		p.momentum = row[2]
		var d := _run(p, s, row[1], 180, 0)
		var want: float = float(row[3]) * 3.0 - SM.stop_distance(float(row[3]), float(row[4]))
		K.check(
			fails,
			absf(d - want) <= want * 0.03,
			"%s: 3 s from rest covers %.2f m (want %.2f m)" % [row[0], d / M, want / M]
		)
	p.momentum = true


## Let go after 2 s of running: the body runs on a little less than SM.stop_distance(RUN,
## HL_SLOW_DOWN_RUN) before it stops (the half-life eases back to the walk's as it slows), and
## SM.stop_distance(RUN, HL_SLOW_DOWN) with the flag off; a walk pulls up as before.
func _check_stop(ctx: FpContext, s: Dictionary) -> void:
	var p := ctx.player
	var stops := {}
	for row: Array in [
		["run", true, true, WS.RUN, PL.HL_SLOW_DOWN_RUN],
		["run, flag off", true, false, WS.RUN, PL.HL_SLOW_DOWN],
		["walk", false, true, WS.WALK, PL.HL_SLOW_DOWN]
	]:
		p.momentum = row[2]
		var moving := _run(p, s, row[1], 120, 0)
		var total := _run(p, s, row[1], 120, 90, false)
		var d := total - moving
		var want := SM.stop_distance(float(row[3]), float(row[4]))
		stops[row[0]] = d
		K.check(
			fails,
			absf(d - want) <= want * 0.2 + 0.01 * M and p.speed() < 0.01 * M,
			"%s: lets go and stops in %.2f m (want about %.2f m)" % [row[0], d / M, want / M]
		)
	K.check(
		fails,
		float(stops["run"]) > float(stops["run, flag off"]) * 1.5,
		"a run carries on further with momentum than without"
	)
	p.momentum = true


## The turn loss: none facing the wish, at a walk, in first person or aiming; the pace above WALK
## falls to TURN_KEEP of it TURN_LOSS_FULL off the wish.
func _check_turn_keep(ctx: FpContext) -> void:
	var p := ctx.player
	p.yaw = 0.0
	var ahead := Vector2(0.0, -1.0)
	var at := func(deg: float, sp: float) -> float:
		return p.turn_keep(ahead.rotated(deg_to_rad(deg)) * sp)
	K.check(
		fails,
		is_equal_approx(at.call(0.0, WS.RUN), 1.0) and is_equal_approx(at.call(25.0, WS.RUN), 1.0),
		"facing the wish (or nearly) at a run keeps the pace"
	)
	var full: float = at.call(120.0, WS.RUN)
	var want := (WS.WALK + (WS.RUN - WS.WALK) * PL.TURN_KEEP) / WS.RUN
	K.check(
		fails,
		is_equal_approx(full, want),
		"120 deg off at a run keeps %.3f of the pace (want %.3f)" % [full, want]
	)
	var mid: float = at.call(70.0, WS.RUN)
	K.check(fails, mid < 1.0 and mid > full, "70 deg off loses some of it (%.3f)" % mid)
	K.check(
		fails, is_equal_approx(at.call(120.0, WS.WALK), 1.0), "a walk turns without losing pace"
	)
	p.aim_yaw = 0.5
	K.check(
		fails, is_equal_approx(at.call(120.0, WS.RUN), 1.0), "aiming (the guard) keeps the pace"
	)
	p.aim_yaw = NAN
	p.camera_mode = "first"
	K.check(fails, is_equal_approx(at.call(120.0, WS.RUN), 1.0), "first person keeps the pace")
	p.camera_mode = "third"
	K.check(
		fails,
		PL.run_pace(WS.WALK) == 0.0 and PL.run_pace(WS.RUN) == 1.0,
		"run_pace: 0 at a walk, 1 at a run"
	)


## Teleports to the sidewalk start (unless again is false), steps `go` frames of forward wish then
## `rest` frames of none, and returns the distance from the start.
func _run(
	p: FpPlayer, s: Dictionary, sprint: bool, go: int, rest: int, again: bool = true
) -> float:
	var start: Vector3 = s["pos"]
	if again:
		p.teleport(start, s["yaw"])
	for k in range(go if again else 0):
		p.simulate(Vector2(0, 1), sprint, DT)
		p.update_view(DT)
	for k in range(rest):
		p.simulate(Vector2.ZERO, sprint, DT)
		p.update_view(DT)
	return Vector2(p.position.x - start.x, p.position.z - start.z).length()
