extends SceneTree
## The hit-direction thump (hit_direction, first person): hero_hit_dir pans the hurt's thump a
## fist's reach (audio_feature's DIR_THUMP_M) toward where the blow came from — right, left,
## behind — and with no marker it stays at the chest; a marker spent on a cause without a thump
## ("fall") never leaks into the next one. The arc, the angle and its gating (first person, the
## flag) are health's, pinned in fp_health_test.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const EM := preload("res://scripts/fp/audio/emitters.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "audio": true})
	var f: FpFeature = K.make_feature(ctx, "audio")
	f.set_process(false)
	var p := ctx.player
	# The thump's home is the chest (audio_feature's _on_hero_hurt); the body's right is (cos,
	# -sin) of its yaw and it faces (-sin, -cos).
	var base: Vector3 = p.position + Vector3(0.0, 1.3 * WS.M, 0.0)
	var r3 := Vector3(cos(p.yaw), 0.0, -sin(p.yaw))
	var f3 := Vector3(-sin(p.yaw), 0.0, -cos(p.yaw))
	var reach := 0.9 * WS.M  # audio_feature's DIR_THUMP_M
	var off := func(a: float) -> Vector3:
		var em: EM = f.get("emitters")
		var n: int = em.shots_played
		if not is_nan(a):
			ctx.bus.hero_hit_dir.emit(a)
		ctx.bus.hero_hurt.emit(12.0, "punch", 88.0, false)
		var s: EM.Src = null
		if em.shots_played == n + 1:
			s = em.source("shot:%d" % em.shots_played)
		f.call("step", DT)
		if s != null and s.type == "hit" and s.started:
			return s.pos - base
		return Vector3.INF
	var right: Vector3 = off.call(PI * 0.5)
	var left: Vector3 = off.call(-PI * 0.5)
	var behind: Vector3 = off.call(PI)
	var plain: Vector3 = off.call(NAN)
	K.check(
		fails,
		absf(right.dot(r3) - reach) < 0.05 and absf(right.dot(f3)) < 0.05,
		"a blow from the right pans the thump right (%.2f)" % right.dot(r3)
	)
	K.check(
		fails, absf(left.dot(r3) + reach) < 0.05, "and from the left, left (%.2f)" % left.dot(r3)
	)
	K.check(
		fails,
		absf(behind.dot(f3) + reach) < 0.05,
		"and from behind, behind (%.2f)" % behind.dot(f3)
	)
	K.check(
		fails,
		Vector2(plain.x, plain.z).length() < 0.01,
		"with no marker the thump stays at the chest"
	)
	ctx.bus.hero_hit_dir.emit(PI * 0.5)
	ctx.bus.hero_hurt.emit(12.0, "fall", 88.0, false)
	var after: Vector3 = off.call(NAN)
	K.check(
		fails,
		Vector2(after.x, after.z).length() < 0.01,
		"a marker on a thump-less cause is spent, not saved for the next one"
	)
	K.finish(self, "FP_HITDIR_TEST", fails)
