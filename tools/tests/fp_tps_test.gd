extends SceneTree
## Slice A third person (docs/fp/slices/A-player.md, fp_tps_test items 1-13): the camera contract,
## the teleport snap, the arm never inside a building, the ground lift, recentering, frame-rate
## independence, the speed gate, the body turning to its travel, interaction from the camera ray,
## the V toggle, the conversation two-shot (on a test emission of conversation_changed), the rig's
## cost, HC's animated hero (stage A2) and the placeholder fallback. Runs in third person on a
## grown city.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const DT := 1.0 / 60.0
const M := WS.M
## A heel is down once its ankle is this close to its standing height (m).
const HEEL_DOWN := 0.005

var fails: Array[String] = []


## A stand-in for E's traffic feature: a resident head for the two-shot.
class FakeTraffic extends FpFeature:
	var head: Vector3 = Vector3.ZERO

	func feature_id() -> String:
		return "traffic"

	func anchor_of(_id: String) -> Vector3:
		return head


## A pickable that answers any ray passing within 0.3 m of `at` (a resident in the way).
class FakePick extends FpFeature:
	var at: Vector3 = Vector3(NAN, NAN, NAN)

	func feature_id() -> String:
		return "fake_pick"

	func pick(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
		if is_nan(at.x):
			return {}
		var t := (at - origin).dot(dir)
		if t < 0.0 or t > max_dist or (origin + dir * t).distance_to(at) > 0.3 * WS.M:
			return {}
		return {"kind": "resident", "id": "fake", "tile": -1, "pos": at, "dist": t, "label": "Talk to Fake", "data": {}}


func _init() -> void:
	await process_frame
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	var p := ctx.player
	K.check(fails, p.camera_mode == "third", "fixture: the kit player is in third person")
	p.set_process(false)
	_check_contract(ctx)
	_check_snap(ctx)
	_check_wall(ctx)
	_check_ground(ctx)
	_check_recenter(ctx)
	_check_fps(ctx)
	_check_speed(ctx)
	_check_body_yaw(ctx)
	_check_interaction(ctx)
	await _check_toggle(ctx)
	_check_conversation(ctx)
	_check_cost(ctx)
	await _check_avatar(ctx)
	K.finish(self, "FP_TPS_TEST", fails)


## 1. The one current camera, top_level in third person; the head stays the head.
func _check_contract(ctx: FpContext) -> void:
	var p := ctx.player
	p.update_view(DT)
	K.check(fails, get_root().get_viewport().get_camera_3d() == p.camera and p.camera.top_level, "1. the camera is current, player.camera and top_level")
	K.check(fails, p.eye_position().distance_to(p.position + Vector3.UP * WS.EYE) < 1e-6, "1. eye_position() is the head (feet + EYE)")


## 2. Teleport snaps the rig: the next frame is behind the body at the default arm.
func _check_snap(ctx: FpContext) -> void:
	var p := ctx.player
	var s := _street(ctx)
	K.check(fails, not s.is_empty(), "fixture: a long straight street")
	if s.is_empty():
		return
	p.teleport(s["pos"], s["yaw"])
	p.update_view(DT)
	var cam := p.camera.global_position
	var pivot := p.position + Vector3.UP * (1.55 * M)
	var to := Vector3(pivot.x - cam.x, 0.0, pivot.z - cam.z).normalized()
	var dot := to.dot(p.body_forward())
	K.check(fails, dot > 0.95 and absf(p.rig.current_arm() - 3.2 * M) <= 0.05 * M, "2. after teleport the camera is behind (dot %.3f) at a %.2f m arm" % [dot, p.rig.current_arm() / M])
	var far: Vector3 = s["pos"] + (s["run"] as Vector3) * (100.0 * M)
	p.teleport(far, s["yaw"])
	p.update_view(DT)
	var d := p.camera.global_position.distance_to(p.eye_position())
	K.check(fails, d <= 3.3 * M, "2. after a 100 m teleport the camera is %.2f m from the head on the next frame" % (d / M))


## 3. With the back 1 m from a building, a full turn of the view never puts the camera inside a
## box, and the arm comes back out after the release time.
func _check_wall(ctx: FpContext) -> void:
	var p := ctx.player
	var col := ctx.collision
	var spot := _wall_spot(ctx)
	K.check(fails, not spot.is_empty(), "fixture: a building wall with 1 m of clear ground in front")
	if spot.is_empty():
		return
	p.teleport(spot["pos"], spot["yaw"])
	p.update_view(DT)
	var inside := 0
	var min_arm := INF
	for k in range(240):
		p.look(TAU / 240.0, 0.0)
		p.update_view(DT)
		min_arm = minf(min_arm, p.rig.current_arm())
		if col.is_blocked(p.camera.global_position, 0.2 * M):
			inside += 1
	K.check(fails, inside == 0 and min_arm < 2.0 * M, "3. a 360-degree sweep 1 m from a wall: camera in a box on %d of 240 frames (arm down to %.2f m)" % [inside, min_arm / M])
	# Face the wall (the camera swings away from it) and wait out the hold and the ease.
	p.teleport(spot["pos"], spot["yaw"])
	for k in range(30):
		p.update_view(DT)
	var short := p.rig.current_arm()
	for k in range(60):
		p.look(PI / 60.0, 0.0)
		p.update_view(DT)
	for k in range(90):
		p.update_view(DT)
	K.check(fails, short < 1.0 * M and absf(p.rig.current_arm() - p.rig.free_arm()) < 0.05 * M, "3. facing the wall the arm recovers to %.2f m (free %.2f m; %.2f m with the wall behind)" % [p.rig.current_arm() / M, p.rig.free_arm() / M, short / M])


## 4. Looking up hard lifts the camera off the ground.
func _check_ground(ctx: FpContext) -> void:
	var p := ctx.player
	var s := _street(ctx)
	p.teleport(s["pos"], s["yaw"])
	p.look(0.0, deg_to_rad(80.0))
	for k in range(30):
		p.update_view(DT)
	var cam := p.camera.global_position
	var g := ctx.collision.ground_height(cam)
	K.check(fails, is_equal_approx(p.cam_pitch, deg_to_rad(50.0)) and cam.y >= g + 0.2 * M - 1e-4, "4. at pitch +50 deg the camera is %.3f m above the ground (>= 0.20)" % ((cam.y - g) / M))


## 5. Running with the view 90 degrees off swings it behind within 2.6 s; at 180 nothing moves.
func _check_recenter(ctx: FpContext) -> void:
	var p := ctx.player
	var s := _street(ctx)
	var run: Vector3 = s["run"]
	for off: float in [90.0, 180.0]:
		p.teleport((s["pos"] as Vector3) - run * 0.45, s["yaw"])
		p.cam_yaw = wrapf(p.yaw + deg_to_rad(off), -PI, PI)
		p.rig.notify_look()
		# A second of standing still: no recentering while idle, and the look delay runs out.
		var d0 := wrapf(p.cam_yaw - p.yaw, -PI, PI)
		for k in range(60):
			p.simulate(Vector2.ZERO, false, DT)
			p.update_view(DT)
		var idle_ok := absf(wrapf(p.cam_yaw - p.yaw, -PI, PI) - d0) < 1e-4
		var cy0 := p.cam_yaw
		var t_behind := -1.0
		for k in range(int(3.0 / DT)):
			# Keep running along the street whatever the view does.
			var w := _wish_for(p, run)
			p.simulate(w, true, DT)
			p.update_view(DT)
			if t_behind < 0.0 and absf(wrapf(p.cam_yaw - p.yaw, -PI, PI)) < deg_to_rad(10.0):
				t_behind = float(k + 1) * DT
		if off < 180.0:
			K.check(fails, idle_ok and t_behind > 0.0 and t_behind <= 2.6, "5. running 90 deg off: behind within 10 deg after %.2f s (<= 2.6), none while idle" % t_behind)
		else:
			K.check(fails, absf(wrapf(p.cam_yaw - cy0, -PI, PI)) < 1e-4, "5. running toward the camera never swings it (moved %.4f deg)" % rad_to_deg(wrapf(p.cam_yaw - cy0, -PI, PI)))


## 6. The same 2 s of input at 30 and at 144 fps ends with the camera within 2 cm.
func _check_fps(ctx: FpContext) -> void:
	var p := ctx.player
	var s := _street(ctx)
	var ends: Array[Vector3] = []
	for fps: float in [30.0, 144.0]:
		p.teleport((s["pos"] as Vector3) - (s["run"] as Vector3) * 0.3, s["yaw"])
		p.rig.notify_look()
		var dt := 1.0 / fps
		var n := int(round(2.0 * fps))
		for k in range(n):
			var t := float(k) * dt
			var w := Vector2(0.0, 1.0) if t < 1.0 else Vector2(0.7, 0.7)
			p.simulate(w, t >= 0.5, dt)
			p.update_view(dt)
		ends.append(p.camera.global_position)
	var d := ends[0].distance_to(ends[1])
	K.check(fails, d <= 0.02 * M, "6. 30 vs 144 fps: the camera ends %.2f cm apart (<= 2)" % (d / M * 100.0))


## 7. A 3 s walk covers 90-100 % of WALK * 3; running is faster.
func _check_speed(ctx: FpContext) -> void:
	var p := ctx.player
	var s := _street(ctx)
	var start: Vector3 = (s["pos"] as Vector3) - (s["run"] as Vector3) * 0.45
	p.teleport(start, s["yaw"])
	for k in range(180):
		p.simulate(Vector2(0, 1), false, DT)
		p.update_view(DT)
	var walked := Vector2(p.position.x - start.x, p.position.z - start.z).length()
	p.teleport(start, s["yaw"])
	for k in range(180):
		p.simulate(Vector2(0, 1), true, DT)
		p.update_view(DT)
	var ran := Vector2(p.position.x - start.x, p.position.z - start.z).length()
	var f := walked / (WS.WALK * 3.0)
	K.check(fails, f >= 0.9 and f <= 1.0 and ran > walked * 1.5, "7. a 3 s walk covers %.1f %% of WALK*3; a run %.2f m" % [f * 100.0, ran / M])


## 8. With the view still, a sideways wish turns the body to the travel within 0.5 s.
func _check_body_yaw(ctx: FpContext) -> void:
	var p := ctx.player
	var s := _street(ctx)
	p.teleport(s["pos"], 0.0)
	p.rig.notify_look()
	for k in range(30):
		p.simulate(Vector2(1, 0), false, DT)
		p.update_view(DT)
	var err := absf(wrapf(p.yaw - deg_to_rad(-90.0), -PI, PI))
	K.check(fails, err < deg_to_rad(5.0) and absf(p.cam_yaw) < 1e-4, "8. the body faces +X travel (%.2f deg off), the view stays (%.4f deg)" % [rad_to_deg(err), rad_to_deg(p.cam_yaw)])


## 9. Interaction ray: a pickable between the camera and the hero is never picked; a building in
## front is.
func _check_interaction(ctx: FpContext) -> void:
	var p := ctx.player
	var feat := K.make_feature(ctx, "interact")
	var fake := FakePick.new()
	fake.name = "fake_pick"
	ctx.world_root.get_parent().get_node("Features").add_child(fake)
	ctx.features["fake_pick"] = fake
	fake.setup(ctx)
	var b := _facing_building(ctx)
	K.check(fails, not b.is_empty(), "fixture: a building with a frontage")
	if b.is_empty() or feat == null:
		return
	p.teleport(b["pos"], b["yaw"], -5.0)
	p.update_view(DT)
	var cam := p.view_position()
	fake.at = cam.lerp(p.eye_position(), 0.5)
	# Keep the fake on the camera's centre ray.
	var dir := p.view_dir()
	fake.at = cam + dir * (fake.at - cam).dot(dir)
	var t: Dictionary = feat.call("evaluate")
	K.check(fails, str(t.get("kind", "")) == "building" and int(t.get("tile", -1)) == int(b["tile"]) and not str(t.get("label", "")).is_empty(), "9. the building in front is the target, the pickable behind the hero is not (%s)" % str(t.get("label", t)))
	fake.at = Vector3(NAN, NAN, NAN)
	ctx.features.erase("fake_pick")
	fake.queue_free()


## 10. V blends to first person in 0.35 s (camera at the eye, not top_level, the "fov" setting)
## and back; never while modal; the settings log records the choice.
func _check_toggle(ctx: FpContext) -> void:
	var p := ctx.player
	var s := _street(ctx)
	p.teleport(s["pos"], s["yaw"])
	p.input_enabled = true
	p.set_process(true)
	var logged := ctx.mode.settings_log.size()
	_press("view_toggle")
	await create_timer(0.5).timeout
	var at_eye := p.camera.global_position.distance_to(p.eye_position())
	K.check(fails, p.camera_mode == "first" and at_eye <= 1e-4 and not p.camera.top_level and is_equal_approx(p.camera.fov, float(ctx.settings["fov"])), "10. V: first person at the eye (%.6f off), top_level %s, fov %.1f" % [at_eye, p.camera.top_level, p.camera.fov])
	var rec := false
	for k in range(logged, ctx.mode.settings_log.size()):
		rec = rec or str(ctx.mode.settings_log[k].get("camera_mode", "")) == "first"
	K.check(fails, rec and str(ctx.settings["camera_mode"]) == "first", "10. the settings log records camera_mode first")
	K.check(fails, p.avatar.is_inside_tree() and not p.avatar.is_body_visible() and _shadow_only(p.avatar), "10. first person: the body only casts its shadow")
	ctx.push_modal(&"test")
	_press("view_toggle")
	await process_frame
	ctx.pop_modal(&"test")
	K.check(fails, p.camera_mode == "first", "10. no toggle while a modal is pushed")
	await process_frame
	_press("view_toggle")
	await create_timer(0.5).timeout
	var arm := p.camera.global_position.distance_to(p.rig.pivot())
	K.check(fails, p.camera_mode == "third" and p.camera.top_level and arm > 2.5 * M, "10. V again: back on the arm (%.2f m from the pivot)" % (arm / M))
	p.input_enabled = false
	p.set_process(false)


## 11. The conversation two-shot frames both heads from the camera's side, then hands the view
## back with cam_yaw matching it.
func _check_conversation(ctx: FpContext) -> void:
	var p := ctx.player
	var s := _street(ctx)
	p.teleport(s["pos"], s["yaw"])
	p.update_view(DT)
	var traffic := FakeTraffic.new()
	traffic.name = "fake_traffic"
	var old_traffic: Variant = ctx.features.get("traffic")
	ctx.world_root.get_parent().get_node("Features").add_child(traffic)
	ctx.features["traffic"] = traffic
	# A resident 1.4 m ahead and 0.5 m to the left, facing the player.
	var fwd := p.body_forward()
	var left := Vector3(fwd.z, 0.0, -fwd.x)
	traffic.head = p.eye_position() + fwd * (1.4 * M) + left * (0.5 * M) - Vector3.UP * (0.05 * M)
	var head := p.eye_position()
	var u := Vector3(traffic.head.x - head.x, 0.0, traffic.head.z - head.z).normalized()
	var s0 := Vector3(-u.z, 0.0, u.x)
	var side0 := signf((p.camera.global_position - head).dot(s0))
	ctx.bus.conversation_changed.emit("r_test", true)
	for k in range(37):
		p.simulate(Vector2.ZERO, false, DT)
		p.update_view(DT)
	var cam := p.camera
	var both := cam.is_position_in_frustum(p.eye_position()) and cam.is_position_in_frustum(traffic.head)
	var side1 := signf((cam.global_position - p.eye_position()).dot(s0))
	var vh := cam.get_viewport().get_visible_rect().size.y
	var upper := cam.unproject_position(p.eye_position()).y < 0.6 * vh and cam.unproject_position(traffic.head).y < 0.6 * vh
	K.check(fails, p.in_conversation() and both and side1 == side0 and is_equal_approx(cam.fov, 45.0), "11. after 0.6 s both heads are in frame (%s), same side (%d -> %d), fov %.0f" % [both, int(side0), int(side1), cam.fov])
	K.check(fails, upper, "11. both heads sit in the upper 60 percent of the frame (y %.0f and %.0f of %.0f)" % [cam.unproject_position(p.eye_position()).y, cam.unproject_position(traffic.head).y, vh])
	for k in range(60):
		p.update_view(DT)
	var to_npc := traffic.head - p.position
	var face_err := absf(wrapf(atan2(-to_npc.x, -to_npc.z) - p.yaw, -PI, PI))
	K.check(fails, face_err < deg_to_rad(5.0), "11. the hero turned to face the resident (%.1f deg off)" % rad_to_deg(face_err))
	ctx.bus.conversation_changed.emit("r_test", false)
	var yaw_at_exit := p.cam_yaw
	for k in range(30):
		p.update_view(DT)
	var view := -cam.global_transform.basis.z
	var view_yaw := atan2(-view.x, -view.z)
	K.check(fails, not p.in_conversation() and absf(wrapf(p.cam_yaw - view_yaw, -PI, PI)) < deg_to_rad(1.0) and absf(wrapf(yaw_at_exit - p.cam_yaw, -PI, PI)) < deg_to_rad(1.0), "11. on exit cam_yaw matches the final view (%.2f deg)" % rad_to_deg(wrapf(p.cam_yaw - view_yaw, -PI, PI)))
	ctx.features.erase("traffic")
	if old_traffic != null:
		ctx.features["traffic"] = old_traffic
	traffic.queue_free()


## 12. rig.update averages under 100 us over 600 frames on a built-up street.
func _check_cost(ctx: FpContext) -> void:
	var p := ctx.player
	var s := _street(ctx)
	p.teleport((s["pos"] as Vector3) - (s["run"] as Vector3) * 0.4, s["yaw"])
	var total := 0.0
	var sweeps := 0
	var frame_us := 0.0
	for k in range(600):
		var t0 := Time.get_ticks_usec()
		p.look(0.004, 0.0)
		p.simulate(Vector2(0.3, 1.0) if k < 300 else Vector2(-0.3, -1.0), k % 200 < 100, DT)
		p.update_view(DT)
		frame_us += float(Time.get_ticks_usec() - t0)
		total += p.rig.update_us
		sweeps += p.rig.sweeps
	var avg := total / 600.0
	K.check(fails, avg < 100.0, "12. rig.update averages %.1f us (< 100), %.1f sweeps per frame" % [avg, float(sweeps) / 600.0])
	var feat := ctx.feature("interact")
	var it := 0.0
	if feat != null:
		var t1 := Time.get_ticks_usec()
		for k in range(60):
			feat.call("evaluate")
		it = float(Time.get_ticks_usec() - t1) / 60.0
	K.check(fails, frame_us / 600.0 + it / 6.0 < 500.0 and it < 200.0, "12. a player frame costs %.0f us and an interact tick %.0f us (frame + tick/6 < 500, tick < 200)" % [frame_us / 600.0, it])


## 13. The hero is drawn in third person (shadow-only in first person: item 10) and leans into a
## running turn. With HC's files: the animated hero (13a); then, with the hero's files pointed at
## missing paths, the A1 placeholder fallback (13b).
func _check_avatar(ctx: FpContext) -> void:
	var p := ctx.player
	var s := _street(ctx)
	p.teleport(s["pos"], s["yaw"])
	p.update_view(DT)
	K.check(fails, p.avatar != null and p.avatar.is_body_visible() and not _shadow_only(p.avatar), "13. third person shows the hero")
	# Leaning into a turn: running in a circle rolls the body toward the centre.
	for k in range(90):
		p.simulate(Vector2(0.6, 0.8), true, DT)
		p.look(-0.03, 0.0)
		p.update_view(DT)
	var lean: Vector2 = p.avatar.lean()
	K.check(fails, absf(lean.x) > deg_to_rad(1.0) and absf(lean.x) <= deg_to_rad(8.0) + 1e-6, "13. the body leans into a running turn (%.1f deg roll)" % rad_to_deg(lean.x))
	if not ResourceLoader.exists(AP.HERO_M) or not ResourceLoader.exists(AP.CHAR_LIB_M):
		print("  note 13. HC's hero (AP.HERO_M) is missing: only the placeholder is checked")
	else:
		await _check_hero(ctx, s)
	var av := p.avatar
	var saved: Dictionary = av.hero_paths
	av.hero_paths = {"m": ["res://models/characters/bodies/missing.glb", AP.CHAR_LIB_M], "f": ["res://models/characters/bodies/missing.glb", AP.CHAR_LIB_F]}
	av.hero = ""
	av.set_hero("m")
	K.check(fails, av.placeholder and not av.is_animated(), "13b. with the hero's files missing the placeholder stands in")
	_check_puppet(ctx, s)
	av.hero_paths = saved
	av.hero = ""
	av.set_hero(str(ctx.settings.get("hero", "m")))


## 13a (A2). HC's hero: loaded with its library and scaled to 1.75 m, facing the player's forward,
## arms down (no T-pose) with the feet on the ground; walking and running keep the planted foot
## still (the TimeScale matches the stride: within [0.9, 1.1] at WALK) and footsteps fall on
## each heel strike; crouch, jump / land and talk switch the state machine; the head looks where
## the camera looks within its limits; hero "f" swaps the body; gestures play; the tree is cheap.
func _check_hero(ctx: FpContext, s: Dictionary) -> void:
	var p := ctx.player
	var av := p.avatar
	p.teleport(s["pos"], s["yaw"])
	p.update_view(DT)
	K.check(fails, av.is_animated() and av.rig != null, "13a. HC's hero is the body")
	if av.rig == null:
		return
	var rig: RefCounted = av.rig
	var tree: AnimationTree = rig.get("tree")
	var body: Node3D = rig.get("body")
	var rest_h := 1.7951
	K.check(fails, body.scene_file_path == AP.HERO_M and tree.has_animation_library("") and tree.get_animation_library("") == load(AP.CHAR_LIB_M) and str(tree.root_motion_track) == AP.CHAR_ROOT_MOTION_TRACK, "13a. %s with lib_m as the default library and the Root motion track" % body.scene_file_path.get_file())
	var root_scale := (body.get_parent() as Node3D).scale.x
	K.check(fails, absf(root_scale - M * 1.75 / rest_h) < 0.002 * M, "13a. CharacterRoot scale %.4f = WS.M * 1.75 / rest_height_m" % root_scale)
	var fwd := p.body_forward()
	var face := body.global_transform.basis.z.normalized()
	K.check(fails, face.dot(fwd) > 0.995, "13a. the body faces the player's forward (dot %.4f)" % face.dot(fwd))
	_run(p, Vector2.ZERO, false, 30)
	var hand_drop := minf(rig.call("bone_world", "LeftUpperArm").y - rig.call("bone_world", "LeftHand").y, rig.call("bone_world", "RightUpperArm").y - rig.call("bone_world", "RightHand").y) / M
	var low_idle: float = rig.call("feet_low", p.position.y) / M
	K.check(fails, hand_drop > 0.4 and str(rig.call("state")) == "loco", "13a. idle: arms hang %.2f m below the shoulders (no T-pose)" % hand_drop)
	K.check(fails, low_idle > -0.01 and low_idle < 0.03, "13a. idle: the feet are on the ground (lowest foot bone %.1f cm up)" % (low_idle * 100.0))
	# Walking: TimeScale, the planted foot, the feet on the ground and the footsteps.
	var walk := _gait(p, false, 240)
	K.check(fails, float(walk["ts"]) >= 0.9 and float(walk["ts"]) <= 1.1, "13a. walking at WALK the locomotion TimeScale is %.3f (0.9..1.1)" % float(walk["ts"]))
	K.check(fails, float(walk["slide"]) < 0.08, "13a. walking: the planted foot slides %.1f %% of the ground speed (< 8)" % (float(walk["slide"]) * 100.0))
	K.check(fails, float(walk["low_min"]) > -0.02 and float(walk["low_max"]) < 0.04, "13a. walking: the lowest foot stays at the ground (%.1f..%.1f cm)" % [float(walk["low_min"]) * 100.0, float(walk["low_max"]) * 100.0])
	K.check(fails, bool(walk["alternate"]) and int(walk["steps"]) >= 4 and absf(float(walk["steps"]) - float(walk["expect"])) <= 1.5, "13a. walking: %d footsteps alternate feet (%.1f expected from the stride)" % [int(walk["steps"]), float(walk["expect"])])
	K.check(fails, int(walk["late"]) == 0, "13a. walking: every footstep is within 1 frame of its heel strike (%d off, worst %d frames)" % [int(walk["late"]), int(walk["worst"])])
	var run := _gait(p, true, 150)
	K.check(fails, float(run["ts"]) >= 0.85 and float(run["ts"]) <= 1.15 and float(run["slide"]) < 0.1, "13a. running: TimeScale %.3f, the planted foot slides %.1f %% (< 10)" % [float(run["ts"]), float(run["slide"]) * 100.0])
	K.check(fails, float(run["low_min"]) > -0.02 and bool(run["alternate"]) and int(run["late"]) == 0, "13a. running: no foot below the ground (%.1f cm), %d alternating footsteps on the heel strikes (worst %d frames)" % [float(run["low_min"]) * 100.0, int(run["steps"]), int(run["worst"])])
	_run(p, Vector2.ZERO, false, 60)
	# Crouch.
	for k in range(40):
		p.simulate(Vector2.ZERO, false, DT, true)
		p.update_view(DT)
	var hips_c: float = (rig.call("bone_world", "Hips").y - p.position.y) / M
	var low_c: float = rig.call("feet_low", p.position.y) / M
	K.check(fails, str(rig.call("state")) == "crouch" and hips_c < 0.6 and absf(low_c) < 0.01, "13a. crouching: state %s, hips at %.2f m, the lowest sole %.1f cm from the ground" % [rig.call("state"), hips_c, low_c * 100.0])
	_run(p, Vector2.ZERO, false, 40)
	# Jump and land.
	p.simulate(Vector2.ZERO, false, DT, false, true)
	p.update_view(DT)
	var air_states := {}
	var tuck := 0.0
	for k in range(60):
		p.simulate(Vector2.ZERO, false, DT, false, k < 5)
		p.update_view(DT)
		air_states[str(rig.call("state"))] = true
		if not p.grounded:
			tuck = maxf(tuck, (rig.call("feet_low", p.position.y)) / M)
	var landed_state := str(rig.call("state"))
	_run(p, Vector2.ZERO, false, 90)
	K.check(fails, air_states.has("jump") and tuck > 0.15 and (landed_state == "land" or air_states.has("land")) and str(rig.call("state")) == "loco", "13a. a jump plays jump_start (feet tucked %.2f m up), lands (%s) and returns to locomotion (%s)" % [tuck, landed_state, rig.call("state")])
	# Talk.
	var traffic := FakeTraffic.new()
	traffic.name = "fake_traffic_13"
	var old_traffic: Variant = ctx.features.get("traffic")
	ctx.world_root.get_parent().get_node("Features").add_child(traffic)
	ctx.features["traffic"] = traffic
	traffic.head = p.eye_position() + p.body_forward() * (1.4 * M)
	ctx.bus.conversation_changed.emit("r_test13", true)
	_run(p, Vector2.ZERO, false, 30)
	var talk_state := str(rig.call("state"))
	ctx.bus.conversation_changed.emit("r_test13", false)
	_run(p, Vector2.ZERO, false, 30)
	K.check(fails, talk_state == "talk" and str(rig.call("state")) == "loco", "13a. a conversation plays talk (%s), then locomotion again (%s)" % [talk_state, rig.call("state")])
	ctx.features.erase("traffic")
	if old_traffic != null:
		ctx.features["traffic"] = old_traffic
	traffic.queue_free()
	# Gesture one-shot.
	av.play_gesture("wave")
	_run(p, Vector2.ZERO, false, 3)
	var waving: bool = rig.call("gesture_active")
	_run(p, Vector2.ZERO, false, 240)
	K.check(fails, waving and not rig.call("gesture_active"), "13a. a wave gesture plays once over the idle")
	# Sit: sit_down then the sit loop; standing up returns to locomotion.
	rig.call("sit", true)
	_run(p, Vector2.ZERO, false, 30)
	var sit0 := str(rig.call("state"))
	_run(p, Vector2.ZERO, false, 200)
	var sit1 := str(rig.call("state"))
	var hips_s: float = (rig.call("bone_world", "Hips").y - p.position.y) / M
	rig.call("sit", false)
	_run(p, Vector2.ZERO, false, 30)
	var sit2 := str(rig.call("state"))
	_run(p, Vector2.ZERO, false, 200)
	K.check(fails, sit0 == "sit_down" and sit1 == "sit" and hips_s < 0.6 and sit2 == "stand_up" and str(rig.call("state")) == "loco", "13a. sitting: %s -> %s (hips %.2f m) -> %s -> %s" % [sit0, sit1, hips_s, sit2, rig.call("state")])
	# Head look (the look-at modifiers run in the skeleton's frame update: real frames).
	p.teleport(s["pos"], s["yaw"])
	p.rig.assist_target = Vector3(NAN, NAN, NAN)
	p.look(deg_to_rad(50.0), 0.0)
	await _frames(p, 40)
	var hf: Vector3 = rig.get("head_forward")
	var bf := p.body_forward()
	var side_yaw := rad_to_deg(atan2(bf.cross(hf).y, bf.dot(hf)))
	var side_w: float = rig.get("look_weight")
	p.look(deg_to_rad(110.0), 0.0)
	await _frames(p, 40)
	var back_w: float = rig.get("look_weight")
	p.look(deg_to_rad(-160.0), 0.0)
	await _frames(p, 40)
	var again_w: float = rig.get("look_weight")
	K.check(fails, side_w > 0.99 and side_yaw > 30.0 and side_yaw < 60.0, "13a. the head turns %.0f deg toward a view 50 deg left (influence %.2f)" % [side_yaw, side_w])
	K.check(fails, back_w < 0.01 and again_w > 0.99, "13a. a view behind fades the head look out (%.2f) and a view ahead brings it back (%.2f)" % [back_w, again_w])
	# First person keeps animating (the shadow walks): footsteps still fire.
	p.set_camera_mode("first", false)
	var fp_steps := [0]
	var count := func(_surface: String, _pos: Vector3) -> void:
		fp_steps[0] += 1
	p.stepped.connect(count)
	_run(p, Vector2(0, 1), false, 90)
	p.stepped.disconnect(count)
	K.check(fails, int(fp_steps[0]) >= 2 and _shadow_only(av), "13a. first person: the hero only casts its shadow and still steps (%d footsteps)" % int(fp_steps[0]))
	p.set_camera_mode("third", false)
	# Hero "f".
	ctx.mode.apply_settings({"hero": "f"}, false)
	var fbody: Node3D = av.rig.get("body") if av.rig != null else null
	var f_ok := fbody != null and fbody.scene_file_path == AP.HERO_F and (av.rig.get("tree") as AnimationTree).get_animation_library("") == load(AP.CHAR_LIB_F)
	_run(p, Vector2.ZERO, false, 60)
	var f_low: float = av.rig.call("feet_low", p.position.y) / M if av.rig != null else -1.0
	K.check(fails, f_ok and f_low > -0.01 and f_low < 0.03, "13a. settings hero f loads %s with lib_f, feet on the ground (%.1f cm)" % [fbody.scene_file_path.get_file() if fbody != null else "nothing", f_low * 100.0])
	ctx.mode.apply_settings({"hero": "m"}, false)
	rig = av.rig
	# Cost of the hero's tree and look update per frame.
	var t0 := Time.get_ticks_usec()
	for k in range(300):
		av.update_motion(DT, WS.WALK, 0.0, 0.0, 0.0)
	var us := float(Time.get_ticks_usec() - t0) / 300.0
	K.check(fails, us < 400.0, "13a. the hero's animation update costs %.0f us per frame (budget 100 us on the reference machine; < 400 here)" % us)


## Walks (or runs) along the view for n frames at DT and measures the gait: the mean TimeScale,
## the planted foot's slide as a fraction of the ground speed, the lowest foot's range (metres),
## and the footsteps (count, alternation, frames from the nearest heel strike of that foot).
func _gait(p: FpPlayer, sprint: bool, n: int) -> Dictionary:
	var rig: RefCounted = p.avatar.rig
	var steps: Array[Dictionary] = []
	var frame := [0]
	var on_step := func(_surface: String, pos: Vector3) -> void:
		if frame[0] >= 45:
			steps.append({"f": frame[0], "pos": pos})
	p.stepped.connect(on_step)
	var ts := 0.0
	var ts_n := 0
	var slide := 0.0
	var travel := 0.0
	var low_min := INF
	var low_max := -INF
	var prev_toe: Array[Vector3] = []
	var prev_planted: Array[bool] = [false, false]
	var ankles: Array = [[], []]   # per frame from 45, above the ground
	var start := p.position
	for k in range(n):
		frame[0] = k
		var before := p.position
		p.simulate(Vector2(0.0, 1.0), sprint, DT)
		p.update_view(DT)
		if k < 45:
			prev_toe.clear()
			start = p.position
			continue
		ts += float(rig.get("time_scale"))
		ts_n += 1
		var toes: Array[Vector3] = [rig.call("bone_world", "LeftToes"), rig.call("bone_world", "RightToes")]
		var ground := p.position.y
		var low: float = rig.call("feet_low", ground)
		low_min = minf(low_min, low / M)
		low_max = maxf(low_max, low / M)
		var lo := 0 if toes[0].y < toes[1].y else 1
		for f in range(2):
			var planted := f == lo and toes[f].y - ground < 0.05 * M
			if planted and prev_planted[f] and prev_toe.size() == 2:
				slide += Vector2(toes[f].x - prev_toe[f].x, toes[f].z - prev_toe[f].z).length()
				travel += Vector2(p.position.x - before.x, p.position.z - before.z).length()
			prev_planted[f] = planted
			(ankles[f] as Array).append(rig.call("bone_world", "LeftFoot" if f == 0 else "RightFoot").y - ground)
		prev_toe = toes
	p.stepped.disconnect(on_step)
	# Heel strikes: each ankle coming within HEEL_DOWN of its lowest height after the swing.
	var heel: Array = [[], []]
	for f in range(2):
		var h: Array = ankles[f]
		var lo := INF
		for v in h:
			lo = minf(lo, v)
		for i in range(1, h.size()):
			if h[i - 1] > lo + HEEL_DOWN * M and h[i] <= lo + HEEL_DOWN * M:
				(heel[f] as Array).append(45 + i)
	var dist := Vector2(p.position.x - start.x, p.position.z - start.z).length() / M
	var alternate := steps.size() >= 2
	var late := 0
	var worst := 0
	var right := Vector3(cos(p.yaw), 0.0, -sin(p.yaw))
	var counted := 0
	for i in range(steps.size()):
		var e: Dictionary = steps[i]
		var side_left := ((e["pos"] as Vector3) - p.position).dot(right) < 0.0
		if i > 0:
			var prev_left := (((steps[i - 1] as Dictionary)["pos"] as Vector3) - p.position).dot(right) < 0.0
			alternate = alternate and side_left != prev_left
		if int(e["f"]) < 50 or int(e["f"]) > n - 5:
			continue
		counted += 1
		var best := 99
		for h: int in heel[0 if side_left else 1]:
			best = mini(best, absi(h - int(e["f"])))
		worst = maxi(worst, best)
		if best > 1:
			late += 1
	var expect := 2.0 * dist / float(rig.call("stride", p.speed() / M))
	return {"ts": ts / maxf(1.0, float(ts_n)), "slide": slide / maxf(travel, 1e-6), "low_min": low_min, "low_max": low_max, "steps": steps.size(), "alternate": alternate, "late": late, "worst": worst, "expect": expect, "dist": dist, "counted": counted, "heels": heel}


## n frames of simulate + update_view at DT with a fixed wish.
func _run(p: FpPlayer, wish: Vector2, sprint: bool, n: int) -> void:
	for k in range(n):
		p.simulate(wish, sprint, DT)
		p.update_view(DT)


## n real frames, each driving the player by DT (the skeleton's modifiers run in the frame).
func _frames(p: FpPlayer, n: int) -> void:
	for k in range(n):
		p.simulate(Vector2.ZERO, false, DT)
		p.update_view(DT)
		await process_frame


## 13 (A1 placeholder). The legacy person is re-rigged as a jointed puppet: walking swings the legs
## with the stance foot on the ground, footsteps fall on the heel strikes and alternate feet,
## standing returns to the neutral pose, crouching lowers the pelvis with the feet down, and a
## jump tucks the legs.
func _check_puppet(ctx: FpContext, s: Dictionary) -> void:
	var p := ctx.player
	var av := p.avatar
	K.check(fails, av.puppet != null, "13. the placeholder is re-rigged as a jointed puppet")
	if av.puppet == null:
		return
	p.teleport(s["pos"], s["yaw"])
	p.update_view(DT)
	var steps: Array[float] = []
	var on_step := func(_surface: String, pos: Vector3) -> void:
		steps.append((pos - p.position).dot(Vector3(-cos(p.yaw), 0.0, sin(p.yaw))))
	p.stepped.connect(on_step)
	var start := p.position
	var hip_lo := INF
	var hip_hi := -INF
	var drift := 0.0
	for k in range(150):
		p.simulate(Vector2(0.0, 1.0), false, DT)
		p.update_view(DT)
		if k >= 60:
			var h: float = (av.joints["hip"] as Array)[0]
			hip_lo = minf(hip_lo, h)
			hip_hi = maxf(hip_hi, h)
			var m: Dictionary = av.pose_metrics()
			drift = maxf(drift, absf(float(m["ankle_low"]) - float(m["ankle_rest"])))
	p.stepped.disconnect(on_step)
	K.check(fails, hip_lo < deg_to_rad(-10.0) and hip_hi > deg_to_rad(18.0), "13. walking swings the legs (left hip %.0f..%.0f deg)" % [rad_to_deg(hip_lo), rad_to_deg(hip_hi)])
	K.check(fails, drift < 0.01 * M, "13. walking keeps the stance foot on the ground (%.1f cm off)" % (drift / M * 100.0))
	var dist := Vector2(p.position.x - start.x, p.position.z - start.z).length() / M
	var alternate := steps.size() >= 2
	for k in range(1, steps.size()):
		alternate = alternate and signf(steps[k]) != signf(steps[k - 1]) and absf(steps[k]) > 0.05 * M
	var expect := dist / (FpPlayer.STEP_BASE + FpPlayer.STEP_PER_MPS * WS.WALK / M)
	K.check(fails, alternate and absf(float(steps.size()) - expect) <= 1.5, "13. %d footsteps over %.2f m alternate feet (about %.1f expected)" % [steps.size(), dist, expect])
	for k in range(90):
		p.simulate(Vector2.ZERO, false, DT)
		p.update_view(DT)
	# Idle breathing swings the arms by at most BREATH_DEG.
	var neutral := 0.0
	for j: String in ["hip", "shoulder"]:
		for a: float in av.joints[j]:
			neutral = maxf(neutral, absf(a) - (deg_to_rad(av.BREATH_DEG) if j == "shoulder" else 0.0))
	var pel: Vector3 = av.pose_metrics()["pelvis"]
	K.check(fails, neutral < deg_to_rad(1.0) and pel.length() < 0.01 * M, "13. standing returns to the neutral pose (%.2f deg beyond breathing, pelvis %.1f cm)" % [rad_to_deg(neutral), pel.length() / M * 100.0])
	# Head look: the hero looks where the camera looks, within its limits.
	p.rig.assist_target = Vector3(NAN, NAN, NAN)
	p.look(deg_to_rad(50.0), 0.0)
	for k in range(30):
		p.update_view(DT)
	var side_look: Vector2 = av.head_look
	p.look(deg_to_rad(110.0), 0.0)
	for k in range(60):
		p.update_view(DT)
	var back_look: Vector2 = av.head_look
	K.check(fails, side_look.x > deg_to_rad(35.0) and side_look.x < deg_to_rad(60.0) and back_look.length() < deg_to_rad(2.0), "13. the head turns %.0f deg toward a view 50 deg left and back to neutral for a view behind (%.1f deg)" % [rad_to_deg(side_look.x), rad_to_deg(back_look.length())])
	p.look(deg_to_rad(-160.0), 0.0)
	for k in range(40):
		p.simulate(Vector2.ZERO, false, DT, true)
		p.update_view(DT)
	var cm: Dictionary = av.pose_metrics()
	K.check(fails, (cm["pelvis"] as Vector3).y < -0.3 * M and absf(float(cm["ankle_low"]) - float(cm["ankle_rest"])) < 0.01 * M, "13. crouching lowers the pelvis %.0f cm with the feet on the ground" % (-(cm["pelvis"] as Vector3).y / M * 100.0))
	for k in range(40):
		p.simulate(Vector2.ZERO, false, DT)
		p.update_view(DT)
	p.simulate(Vector2.ZERO, false, DT, false, true)
	p.update_view(DT)
	for k in range(12):
		p.simulate(Vector2.ZERO, false, DT, false, true)
		p.update_view(DT)
	var jm: Dictionary = av.pose_metrics()
	var knee_hi := maxf((av.joints["knee"] as Array)[0], (av.joints["knee"] as Array)[1])
	K.check(fails, not p.grounded and knee_hi > deg_to_rad(30.0) and float(jm["ankle_low"]) - float(jm["ankle_rest"]) > 0.03 * M, "13. a jump tucks the legs (knee %.0f deg, feet %.0f cm up)" % [rad_to_deg(knee_hi), (float(jm["ankle_low"]) - float(jm["ankle_rest"])) / M * 100.0])
	for k in range(90):
		p.simulate(Vector2.ZERO, false, DT)
		p.update_view(DT)


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _shadow_only(avatar: Node3D) -> bool:
	var any := false
	for g: Node in avatar.find_children("*", "GeometryInstance3D", true, false):
		any = true
		if (g as GeometryInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			return false
	return any


## The camera-relative wish that runs along world direction run.
func _wish_for(p: FpPlayer, run: Vector3) -> Vector2:
	var fwd := Vector3(-sin(p.cam_yaw), 0.0, -cos(p.cam_yaw))
	var right := Vector3(cos(p.cam_yaw), 0.0, -sin(p.cam_yaw))
	return Vector2(run.dot(right), run.dot(fwd))


## The middle of a straight road with road two tiles on both ends, on its sidewalk, facing along
## it: {"pos", "yaw" (deg), "run"}.
func _street(ctx: FpContext) -> Dictionary:
	var sim := ctx.sim
	for i in sim.active:
		if sim.kind[i] != D.ROAD or sim.terrain[i] == D.WATER:
			continue
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		if m != RoadTopology.NS and m != RoadTopology.EW:
			continue
		var run := RoadTopology.run_dir(m)
		var ok := true
		for k: int in [-2, -1, 0, 1, 2]:
			var x := D.tx(i) + int(run.x) * k
			var y := D.ty(i) + int(run.z) * k
			ok = ok and D.in_bounds(x, y) and sim.kind[D.idx(x, y)] == D.ROAD
		if not ok:
			continue
		# A clear sidewalk line (no lamp posts, shelters or props) over the five tiles.
		var mid := RoadTopology.sidewalk_point(sim, i, 1)
		for k in range(-50, 51):
			var q := mid + run * (float(k) * 0.03)
			ok = ok and not ctx.collision.is_blocked(Vector3(q.x, ctx.collision.walk_height(q), q.z), WS.PLAYER_RADIUS * 1.5)
		if not ok:
			continue
		var pos := RoadTopology.sidewalk_point(sim, i, 1)
		pos.y = ctx.collision.walk_height(pos)
		return {"pos": pos, "yaw": rad_to_deg(atan2(-run.x, -run.z)), "run": run}
	return {}


## A building lot with a frontage: on its sidewalk facing it. {"pos", "yaw", "tile"}.
func _facing_building(ctx: FpContext) -> Dictionary:
	var sim := ctx.sim
	for i in sim.active:
		if not D.is_zone(sim.kind[i]) or sim.level[i] <= 0 or sim.sites.has(i):
			continue
		var f := ctx.directory.frontage(i)
		if f < 0 or ctx.view.building_aabb(i).size.x <= 0.0:
			continue
		var dir := Vector3(D.tx(i) - D.tx(f), 0, D.ty(i) - D.ty(f))
		var pos := Vector3(D.tx(f), 0, D.ty(f)) + dir * WS.SIDEWALK_CENTER
		pos.y = ctx.collision.walk_height(pos)
		return {"pos": pos, "yaw": rad_to_deg(atan2(-dir.x, -dir.z)), "tile": i}
	return {}


## A point 1 m in front of a building body face, clear of props and water within 6 m, facing
## away from the building. {"pos", "yaw"}.
func _wall_spot(ctx: FpContext) -> Dictionary:
	var sim := ctx.sim
	var col := ctx.collision
	for i in sim.active:
		if not D.is_zone(sim.kind[i]) or sim.level[i] <= 0 or sim.sites.has(i):
			continue
		for b: AABB in col.body_boxes(i):
			if b.size.y < 2.5 * M:
				continue
			var c := b.get_center()
			for n: Vector3 in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
				var face := (b.end.x if n.x > 0.0 else b.position.x) if n.x != 0.0 else (b.end.z if n.z > 0.0 else b.position.z)
				var pos := Vector3(face + n.x * (1.0 * M), 0.0, c.z) if n.x != 0.0 else Vector3(c.x, 0.0, face + n.z * (1.0 * M))
				var g := col.walk_height(pos)
				if is_nan(g):
					continue
				pos.y = g
				if col.is_blocked(pos, WS.PLAYER_RADIUS) or not _clear(col, pos, 4.5 * M, b):
					continue
				return {"pos": pos, "yaw": rad_to_deg(atan2(-n.x, -n.z))}
	return {}


## No prop cylinder, water or box within r of p, except the building behind (`own`).
func _clear(col: CollisionWorld, p: Vector3, r: float, own: AABB) -> bool:
	for b: AABB in col.boxes_near(p, r):
		if b != own:
			return false
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var x := roundi(p.x) + dx
			var y := roundi(p.z) + dz
			if not D.in_bounds(x, y):
				continue
			var cy := col.cylinders(D.idx(x, y))
			for k in range(0, cy.size(), 4):
				if Vector2(cy[k] - p.x, cy[k + 1] - p.z).length() < r:
					return false
	for k in range(16):
		var a := TAU * float(k) / 16.0
		if is_nan(col.ground_height(p + Vector3(cos(a), 0.0, sin(a)) * r)):
			return false
	return true
