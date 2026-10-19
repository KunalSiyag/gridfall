extends SceneTree
## Slice A third person (docs/fp/slices/A-player.md, fp_tps_test items 1-13): the camera contract,
## the teleport snap, the arm never inside a building, the ground lift, recentering, frame-rate
## independence, the speed gate, the body turning to its travel, interaction from the camera ray,
## the V toggle, the conversation two-shot (on a test emission of conversation_changed), the rig's
## cost and the placeholder avatar. Runs in third person on a grown city.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const DT := 1.0 / 60.0
const M := WS.M

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
	_check_avatar(ctx)
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
	for k in range(600):
		p.look(0.004, 0.0)
		p.simulate(Vector2(0.3, 1.0) if k < 300 else Vector2(-0.3, -1.0), false, DT)
		p.update_view(DT)
		total += p.rig.update_us
		sweeps += p.rig.sweeps
	var avg := total / 600.0
	K.check(fails, avg < 100.0, "12. rig.update averages %.1f us (< 100), %.1f sweeps per frame" % [avg, float(sweeps) / 600.0])


## 13 (A1 part). The placeholder hero is drawn in third person, shadow-only in first person; HC's
## animated hero is stage A2.
func _check_avatar(ctx: FpContext) -> void:
	var p := ctx.player
	var s := _street(ctx)
	p.teleport(s["pos"], s["yaw"])
	p.update_view(DT)
	K.check(fails, p.avatar != null and p.avatar.is_body_visible() and not _shadow_only(p.avatar), "13. third person shows the hero")
	var hero_path: String = (AP as Script).get_script_constant_map().get("HERO_M", "")
	if hero_path.is_empty() or AP.load_scene(hero_path) == null:
		print("  note 13. HC's hero (AP.HERO_M) is not merged yet: the animated-avatar checks run in stage A2")
	# Leaning into a turn: running in a circle rolls the body toward the centre.
	for k in range(90):
		p.simulate(Vector2(0.6, 0.8), true, DT)
		p.look(-0.03, 0.0)
		p.update_view(DT)
	var lean: Vector2 = p.avatar.lean()
	K.check(fails, absf(lean.x) > deg_to_rad(1.0) and absf(lean.x) <= deg_to_rad(8.0) + 1e-6, "13. the body leans into a running turn (%.1f deg roll)" % rad_to_deg(lean.x))


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
