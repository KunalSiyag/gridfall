extends SceneTree
## Deterministic, windowed combat proof on a populated street. Run with GRIDFALL_OFFLINE=1,
## GRIDFALL_NEW_CITY=1 and an isolated XDG_DATA_HOME. Images go to --output=<absolute directory>.
## This uses the real feature clocks and renderer; only the camera and fixtures are staged.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const DT := 1.0 / 60.0

var ctx: FpContext
var traffic: FpFeature
var actions: FpFeature
var brawl: FpFeature
var health: FpFeature
var start := Vector3.ZERO
var yaw: float = 0.0
var output: String = "/tmp/gf-r3-impact-proof"
var failed: bool = false
## The staged camera's look-at height and rise (m); the cue shots frame head height.
var _cam_center := 0.9
var _cam_rise := 0.7


## Reads --output=<absolute directory> (the default stays) and makes sure it exists.
func _shots_dir() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output = arg.trim_prefix("--output=")
	DirAccess.make_dir_recursive_absolute(output)


func _init() -> void:
	await process_frame
	_shots_dir()
	ctx = K.make_ctx(
		get_root(), {"view": true, "render": true, "grow": true, "camera_mode": "third"}
	)
	ctx.player.set_process(false)
	ctx.player.input_enabled = true
	ctx.sim.set_process(false)
	ctx.sky.set_process(false)
	ctx.hud.visible = false
	traffic = K.make_feature(ctx, "traffic")
	actions = K.make_feature(ctx, "actions")
	brawl = K.make_feature(ctx, "brawl")
	# People fight back only with the health feature (traffic's _hero_open).
	health = K.make_feature(ctx, "health")
	for feature: FpFeature in [traffic, actions, brawl, health]:
		feature.set_process(false)
	traffic.set("auto_step", false)
	traffic.set("ambient_enabled", false)
	(traffic.get("people") as RefCounted).set("blocking", true)
	start = ctx.player.position
	yaw = rad_to_deg(ctx.player.yaw)
	await _grapple()
	await _guard()
	await _shove()
	await _direction("left", PI * 0.5)
	await _direction("right", -PI * 0.5)
	await _direction("behind", PI)
	await _kick()
	await _step_in()
	await _cue()
	print("COMBAT_PROOF: %s (%s)" % ["FAIL" if failed else "PASS", output])
	quit(1 if failed else 0)


func _reset(gap: float = 0.85) -> WK.Walker:
	brawl.call("release")
	actions.call("cancel")
	K.quiet_walkers(traffic)
	ctx.player.teleport(start, yaw)
	return K.person_ahead(ctx, traffic, gap)


## Manually advances the same clocks as the integration tests, allowing exact contact frames.
func _advance(frames: int) -> void:
	for _k in frames:
		traffic.call("step", DT)
		actions.call("tick", DT)
		brawl.call("tick", DT)
		health.call("tick", DT)
		ctx.player.simulate(Vector2.ZERO, false, DT)
		ctx.player.update_view(DT)
		_frame_camera()
		traffic.call("sync_visuals", DT)
		await process_frame


func _frame_camera() -> void:
	var p := ctx.player
	var fwd := p.body_forward()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	var center := p.position + fwd * 0.45 * WS.M + Vector3.UP * _cam_center * WS.M
	p.camera.fov = 42.0
	p.camera.position = (
		center + right * 3.9 * WS.M + fwd * 1.4 * WS.M + Vector3.UP * _cam_rise * WS.M
	)
	p.camera.look_at(center)
	p.camera.make_current()


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_root().get_texture().get_image()
	var result := image.save_png(output.path_join(name + ".png"))
	failed = failed or result != OK
	print("COMBAT_PROOF: %s %s" % [name, error_string(result)])


func _grapple() -> void:
	_reset()
	failed = not bool(brawl.call("grab")) or failed
	await _advance(36)
	await _shot("grip_a")
	await _advance(24)
	await _shot("grip_b")
	actions.call("strike", "shove")
	for _k in 60:
		await _advance(1)
		if int(brawl.get("held_id")) == -1:
			break
	await _advance(10)
	await _shot("throw_release")
	await _advance(16)
	await _shot("throw_air")


func _guard() -> void:
	_reset()
	actions.call("set_guard", true)
	await _advance(40)
	await _shot("guard")


func _shove() -> void:
	_reset(0.75)
	await _advance(20)
	actions.call("strike", "shove")
	await _advance(9)
	await _shot("shove_contact")
	await _advance(5)
	await _shot("shove_followthrough")


func _direction(label: String, offset: float) -> void:
	var w := _reset()
	w.yaw += offset
	w.stand_yaw = w.yaw
	await _advance(20)
	actions.call("strike")
	for _k in 40:
		await _advance(1)
		if bool(actions.get("_landed")):
			break
	await _advance(6)
	await _shot("stagger_" + label)


func _kick() -> void:
	_reset(1.0)
	await _advance(20)
	actions.call("strike", "kick")
	await _advance(7)
	await _shot("kick_chamber")
	await _advance(7)
	await _shot("kick_extend")
	await _advance(9)
	await _shot("kick_recoil")


## A jab at someone just inside the punch's reach: the step-in carries the hero to the blow.
func _step_in() -> void:
	_reset(1.15)
	await _advance(20)
	await _shot("step_in_start")
	actions.call("strike")
	await _advance(6)
	await _shot("step_in_mid")
	await _advance(8)
	await _shot("step_in_lands")


## A fighter's punch at the hero, with the counter cue growing through its held-back wind-up
## and fading once it has landed (the HUD shows for these shots only).
func _cue() -> void:
	var w := _reset(0.95)
	var react: RefCounted = traffic.get("reactions")
	react.set("fight_odds", {"punch": 1.0, "shove": 1.0})
	react.set("fight_temper", {w.id: 0})  # plain (fight_tempers): the shots ride the jab's timing
	var push: Vector3 = ctx.player.body_forward() * WS.M
	traffic.call("hit_walker", w.id, ctx.player.position, push, 0.45, "punch")
	ctx.hud.visible = true
	# Frame head height so the cue riding above the attacker's head shows in frame.
	_cam_center = 1.45
	_cam_rise = 0.35
	var punched := false
	for _k in 240:
		await _advance(1)
		if w.react in [&"punch_jab", &"punch_cross"] and bool(react.call("fighting", w)):
			punched = true
			break
	if not punched:
		print("COMBAT_PROOF: cue fixture never threw a punch")
		failed = true
	await _shot("cue_open")
	# The cue must ride the attacker's head: every tick of the wind-up the mark sits within
	# 40 px of the walker's projected head bone (the drawn body, not the network anchor).
	var cue: Control = brawl.get("cue")
	var people: RefCounted = traffic.get("people")
	var worst := 0.0
	for k in 14:
		await _advance(1)
		var head: Vector3 = people.call("head_of", w, w.pos + w.vis_off)
		if k == 0:
			print(
				(
					"CUE DEBUG: id=%d by_id=%s\n  pos=%s vis_off=%s\n  head=%s cue_at=%s"
					% [
						w.id,
						str(traffic.call("walkers_by_id", [w.id])),
						str(w.pos),
						str(w.vis_off),
						str(head),
						str(brawl.get("cue_at")),
					]
				)
			)
		var want: Vector2 = ctx.player.camera.unproject_position(head)
		var got := Vector2(cue.position + cue.size * 0.5)
		worst = maxf(worst, got.distance_to(want))
		if k == 9:
			await _shot("cue_grown")
	await _shot("cue_fade")
	if worst > 40.0:
		print("COMBAT_PROOF: cue %.0f px off the attacker's head" % worst)
		failed = true
	ctx.hud.visible = false
	_cam_center = 0.9
	_cam_rise = 0.7
