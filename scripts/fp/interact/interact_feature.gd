extends FpFeature
## Interaction with residents, buildings, posters and cars (slice A deliverables 3 and 6.7). Ten
## times a second it casts the view ray: in first person from the eye, in third person from the
## camera through the screen centre, starting at the point on that line closest to the head (so
## nothing between the camera and the hero is ever picked). Candidates are every feature's
## pick(), residents it finds itself when no traffic feature does, and buildings (the full
## building bounds, so a set-back house still answers from the sidewalk). The nearest within range
## of the head wins; interact_target_changed fires when the target changes. E emits
## interact_requested, and talk_requested for a resident.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const TICK := 0.1
## A resident A finds itself must be inside this cone of the screen centre.
const RESIDENT_CONE := deg_to_rad(8.0)
## Third-person fallback when the ray finds nothing: residents within TALK_RANGE inside this
## cone of the camera's horizontal forward, scored 0.7 angle + 0.3 distance, switching only after
## HYSTERESIS s.
const FALLBACK_CONE := deg_to_rad(35.0)
const HYSTERESIS := 0.2
## Head height of a legacy avatar above the ground.
const HEAD_H := 1.6 * WS.M
const INSIDE := ["home", "work", "shopping", "working late"]

## The current target ({} when none), as last emitted (pos and dist refresh every tick).
var target: Dictionary = {}
## Evaluations so far (tests).
var evaluations: int = 0
var _t: float = 0.0
var _key: String = ""
var _modal_frame: int = -1
var _fallback_key: String = ""
var _fallback_t: float = 0.0
var _driving: bool = false


func feature_id() -> String:
	return "interact"


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	if ctx.bus != null:
		ctx.bus.modal_changed.connect(_on_modal_changed)
		ctx.bus.world_ready.connect(_on_world_ready)
		ctx.bus.drive_changed.connect(_on_drive_changed)
	if ctx.player != null:
		ctx.player.photo_mode_changed.connect(_on_photo_mode_changed)


func teardown() -> void:
	if ctx == null:
		return
	if ctx.bus != null:
		if ctx.bus.modal_changed.is_connected(_on_modal_changed):
			ctx.bus.modal_changed.disconnect(_on_modal_changed)
		if ctx.bus.world_ready.is_connected(_on_world_ready):
			ctx.bus.world_ready.disconnect(_on_world_ready)
		if ctx.bus.drive_changed.is_connected(_on_drive_changed):
			ctx.bus.drive_changed.disconnect(_on_drive_changed)
	if ctx.player != null and is_instance_valid(ctx.player) and ctx.player.photo_mode_changed.is_connected(_on_photo_mode_changed):
		ctx.player.photo_mode_changed.disconnect(_on_photo_mode_changed)


func on_world_rebuilt() -> void:
	_set_target({})


func from_dict(_d: Dictionary) -> void:
	_set_target({})


## Re-evaluates the target now (also run every TICK s). Returns it.
func evaluate() -> Dictionary:
	evaluations += 1
	var p := ctx.player if ctx != null else null
	if p == null or ctx.is_modal() or p.photo_mode or _driving or p.carried:
		_set_target({})
		return target
	var ray := view_ray()
	var t := targets_along(ray["origin"], ray["dir"])
	if t.is_empty() and p.camera_mode == "third":
		t = _fallback(ray["dir"])
	else:
		_fallback_key = ""
	_set_target(t)
	return target


## The interaction ray {"origin", "dir"}: the eye and the view in first person; in third person
## the camera's centre ray from its point closest to the head.
func view_ray() -> Dictionary:
	var p := ctx.player
	var head := p.eye_position()
	var dir := p.view_dir()
	if p.camera_mode != "third":
		return {"origin": head, "dir": dir}
	var cam := p.view_position()
	return {"origin": cam + dir * maxf(0.0, (head - cam).dot(dir)), "dir": dir}


## The nearest target along a ray: features' pick(), A's own residents (no traffic feature) and
## buildings, each within its range of the player's head ({} when none).
func targets_along(origin: Vector3, dir: Vector3) -> Dictionary:
	var head := ctx.player.eye_position() if ctx.player != null else origin
	var reach := WS.INTERACT_RANGE + head.distance_to(origin)
	var cands: Array[Dictionary] = []
	var ids := {}
	for f: Variant in ctx.features.values():
		if f == self or not is_instance_valid(f):
			continue
		var t: Dictionary = (f as FpFeature).pick(origin, dir, reach)
		if t.is_empty():
			continue
		t = _normalise(t)
		cands.append(t)
		if str(t.get("kind", "")) == "resident":
			ids[str(t.get("id", ""))] = true
	var traffic := ctx.feature("traffic")
	if traffic == null or not traffic.has_method("visible_near"):
		for t: Dictionary in _own_residents(origin, dir, head):
			if not ids.has(str(t["id"])):
				cands.append(t)
	var hit := ctx.collision.raycast(origin, dir, reach, false)
	if bool(hit["hit"]) and str(hit["kind"]) == "building":
		cands.append(_building_target(int(hit["tile"]), hit["pos"]))
	var best := {}
	var best_d := INF
	for t: Dictionary in cands:
		var pos: Vector3 = t.get("pos", origin)
		var range_m := WS.TALK_RANGE if str(t.get("kind", "")) == "resident" else WS.INTERACT_RANGE
		# Residents and cars measure to their anchor; buildings and posters to the hit point.
		var dh := head.distance_to(pos)
		if dh > range_m + 1e-6:
			continue
		t["dist"] = dh
		if dh < best_d:
			best_d = dh
			best = t
	return best


func _process(delta: float) -> void:
	if ctx == null or ctx.player == null:
		return
	_t += delta
	_fallback_t += delta
	if _t >= TICK:
		_t = fmod(_t, TICK)
		evaluate()


func _unhandled_input(event: InputEvent) -> void:
	if ctx == null or ctx.player == null:
		return
	if not event.is_action_pressed("interact") or event.is_echo():
		return
	# The card or viewer that just closed on E consumed this same press.
	if ctx.is_modal() or ctx.player.photo_mode or Engine.get_process_frames() == _modal_frame:
		return
	if target.is_empty():
		evaluate()
	if target.is_empty():
		return
	var t := target.duplicate()
	ctx.bus.interact_requested.emit(t)
	if str(t.get("kind", "")) == "resident":
		ctx.bus.talk_requested.emit(str(t.get("id", "")))
	ctx.player.face_point(t.get("pos", ctx.player.position))
	if is_inside_tree():
		get_viewport().set_input_as_handled()


## FP smoke: a forward ray from the spawn pose (it faces City Hall) yields a building target.
func self_test() -> Dictionary:
	if ctx == null or ctx.mode == null or ctx.collision == null:
		return {"ok": false, "detail": "no context"}
	var sp: Dictionary = ctx.mode.spawn_point()
	var yaw := deg_to_rad(float(sp["yaw"]))
	var origin := (sp["pos"] as Vector3) + Vector3.UP * WS.EYE
	var hit := ctx.collision.raycast(origin, Vector3(-sin(yaw), 0.0, -cos(yaw)), WS.INTERACT_RANGE, false)
	if not bool(hit["hit"]) or str(hit["kind"]) != "building":
		return {"ok": false, "detail": "no building ahead of the spawn pose (%s)" % str(hit)}
	var t := _building_target(int(hit["tile"]), hit["pos"])
	return {"ok": not str(t["label"]).is_empty(), "detail": "building %s: %s" % [t["id"], t["label"]]}


## Third-person shots for the photo tour (A 6.3): the street pose and a crossing, both from behind
## the hero at hour 10.5, and the hero walking and running down the street (stage A2).
func photo_shots() -> Array:
	var out: Array = []
	if ctx == null or ctx.sim == null or ctx.collision == null:
		return out
	var street := _street_pose()
	if not street.is_empty():
		var walk := street.duplicate()
		var run := street.duplicate()
		street.merge({"name": "tps_street", "hour": 10.5, "prepare": "photo_third_person", "restore": "photo_first_person"})
		out.append(street)
		walk.merge({"name": "tps_walk", "hour": 10.5, "prepare": "photo_walk", "restore": "photo_stop"})
		out.append(walk)
		run.merge({"name": "tps_run", "hour": 10.5, "prepare": "photo_run", "restore": "photo_stop"})
		out.append(run)
	var crossing := _crossing_pose()
	if not crossing.is_empty():
		crossing.merge({"name": "tps_crossing", "hour": 10.5, "prepare": "photo_third_person", "restore": "photo_first_person"})
		out.append(crossing)
	return out


## Photo tour hooks: third person for this run only (never saved), with a snapped rig.
func photo_third_person() -> void:
	ctx.mode.apply_settings({"camera_mode": "third"}, false)
	ctx.player.set_camera_mode("third", false)


func photo_first_person() -> void:
	ctx.mode.apply_settings({"camera_mode": "first"}, false)
	ctx.player.set_camera_mode("first", false)


## The hero walks (or runs) along its facing through the shot; photo_stop ends it.
func photo_walk() -> void:
	photo_third_person()
	ctx.player.autopilot = {"wish": Vector2(0.0, 1.0), "sprint": false}


func photo_run() -> void:
	photo_third_person()
	ctx.player.autopilot = {"wish": Vector2(0.0, 1.0), "sprint": true}


func photo_stop() -> void:
	ctx.player.autopilot = {}
	photo_first_person()


func _set_target(t: Dictionary) -> void:
	var key := "" if t.is_empty() else "%s:%s" % [str(t.get("kind", "")), str(t.get("id", ""))]
	target = t
	if ctx != null and ctx.player != null and ctx.player.rig != null:
		ctx.player.rig.assist_target = (t["pos"] as Vector3) if not t.is_empty() and ctx.player.camera_mode == "third" else Vector3(NAN, NAN, NAN)
	if key == _key:
		return
	_key = key
	if ctx != null and ctx.bus != null:
		ctx.bus.interact_target_changed.emit(t)


## A pedestrian with a driver is a named resident: talk to them (E already says so; defensive).
func _normalise(t: Dictionary) -> Dictionary:
	var out := t.duplicate()
	var data: Dictionary = out.get("data", {})
	if str(out.get("kind", "")) == "pedestrian" and not str(data.get("driver_id", "")).is_empty():
		var id := str(data["driver_id"])
		out["kind"] = "resident"
		out["id"] = id
		out["label"] = _resident_label(id)
	return out


func _resident_label(id: String) -> String:
	var r: Dictionary = ctx.residents.find(id) if ctx.residents != null else {}
	if r.is_empty():
		return "Talk"
	var job := str(r.get("job_title", ""))
	return "Talk to %s, %s" % [str(r.get("name", "")), job] if not job.is_empty() else "Talk to %s" % str(r.get("name", ""))


func _building_target(i: int, hit_pos: Vector3) -> Dictionary:
	var label := ""
	if ctx.directory != null:
		label = ctx.directory.place_label(i)
		var site: Dictionary = ctx.sim.sites.get(i, {})
		if not site.is_empty():
			var planned := ctx.directory.planned_name(i, int(site.get("target_kind", -1)), int(site.get("target_level", 0)))
			label = ("%s (under construction)" % planned) if not planned.is_empty() else "Construction site"
			var job := ctx.sim.crew_job_at(i)
			if not job.is_empty():
				var what := planned if not planned.is_empty() else "Construction site"
				label = "%s (%s)" % [what, _crew_note(job)]
	return {"kind": "building", "id": str(i), "tile": i, "pos": hit_pos, "dist": 0.0, "label": label, "data": {}}


## Who builds a player's order: "your crew 1 is on it", or "waiting for a free crew". No clock:
## the label only refreshes when the target changes (the site's board counts down).
func _crew_note(job: Dictionary) -> String:
	var c := int(job.get("crew", -1))
	return "your crew %d is on it" % (c + 1) if c >= 0 else "waiting for a free crew"


## Named residents on foot near the ray when no traffic feature draws them: one pass over
## residents.people (indoor residents skipped, never ResidentAvatars.position_of), within
## TALK_RANGE of the head, inside RESIDENT_CONE, in line of sight.
func _own_residents(origin: Vector3, dir: Vector3, head: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in _visible_residents(head, WS.TALK_RANGE):
		var a: Vector3 = e["pos"]
		var to := a - origin
		if to.length() < 1e-6 or dir.angle_to(to) > RESIDENT_CONE:
			continue
		if not ctx.collision.line_of_sight(head, a):
			continue
		var id := str(e["id"])
		out.append({"kind": "resident", "id": id, "tile": ctx.collision.tile_at(a), "pos": a, "dist": head.distance_to(a), "label": _resident_label(id), "data": {}})
	return out


## [{"id", "pos" (head)}] for residents drawn outdoors within r of p (horizontal).
func _visible_residents(p: Vector3, r: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if ctx.residents == null or ctx.view == null or ctx.view.avatars == null:
		return out
	var avs: Variant = ctx.view.avatars.get("_avatars")
	if typeof(avs) != TYPE_DICTIONARY:
		return out
	var r2 := r * r
	for res: Dictionary in ctx.residents.people:
		var route: Array = res.get("route", [])
		var state := str(res.get("state", ""))
		if route.is_empty() and (state in INSIDE or state.begins_with("visiting")):
			continue
		var a: Variant = (avs as Dictionary).get(str(res.get("id", "")))
		if a == null:
			continue
		var root: Node3D = (a as Dictionary).get("root")
		if root == null or not is_instance_valid(root) or not root.visible:
			continue
		var q := root.position
		if Vector2(q.x - p.x, q.z - p.z).length_squared() > r2:
			continue
		var g := ctx.collision.ground_height(q)
		out.append({"id": str(res["id"]), "pos": Vector3(q.x, (g if not is_nan(g) else 0.0) + HEAD_H, q.z)})
	return out


## Third person, nothing on the ray: the best resident within TALK_RANGE inside FALLBACK_CONE of
## the camera's horizontal forward, switching only after HYSTERESIS s.
func _fallback(dir: Vector3) -> Dictionary:
	var head := ctx.player.eye_position()
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length_squared() < 1e-9:
		return {}
	flat = flat.normalized()
	var cands: Array[Dictionary] = []
	var traffic := ctx.feature("traffic")
	if traffic != null and traffic.has_method("visible_near"):
		for e: Variant in traffic.call("visible_near", ctx.player.position, WS.TALK_RANGE):
			if typeof(e) == TYPE_DICTIONARY and (e as Dictionary).has("id"):
				var d: Dictionary = e
				var pos: Vector3 = d.get("pos", Vector3.ZERO)
				if traffic.has_method("anchor_of"):
					var an: Variant = traffic.call("anchor_of", str(d["id"]))
					if typeof(an) == TYPE_VECTOR3:
						pos = an
				cands.append({"id": str(d["id"]), "pos": pos})
	else:
		cands = _visible_residents(head, WS.TALK_RANGE)
	var best := {}
	var best_s := INF
	for e: Dictionary in cands:
		var pos: Vector3 = e["pos"]
		var to := Vector3(pos.x - head.x, 0.0, pos.z - head.z)
		var dist := to.length()
		if dist < 1e-6 or dist > WS.TALK_RANGE:
			continue
		var ang := flat.angle_to(to)
		if ang > FALLBACK_CONE:
			continue
		var score := 0.7 * (ang / FALLBACK_CONE) + 0.3 * (dist / WS.TALK_RANGE)
		if score < best_s:
			best_s = score
			var id := str(e["id"])
			best = {"kind": "resident", "id": id, "tile": ctx.collision.tile_at(pos), "pos": pos, "dist": head.distance_to(pos), "label": _resident_label(id), "data": {}}
	var key := "" if best.is_empty() else "resident:" + str(best["id"])
	if key == _key or _key.is_empty():
		_fallback_key = key
		_fallback_t = 0.0
		return best
	if key != _fallback_key:
		_fallback_key = key
		_fallback_t = 0.0
	return best if _fallback_t >= HYSTERESIS else target


func _on_modal_changed(active: bool) -> void:
	if active:
		_set_target({})
	else:
		_modal_frame = Engine.get_process_frames()
		evaluate()


func _on_photo_mode_changed(on: bool) -> void:
	if on:
		_set_target({})
	else:
		evaluate()


func _on_world_ready() -> void:
	_set_target({})


## Nothing to interact with from behind the wheel.
func _on_drive_changed(active: bool) -> void:
	_driving = active
	evaluate()


## A straight sidewalk with a long run ahead and the most built-up sides (fp_shots' street rule),
## the hero facing along it.
func _street_pose() -> Dictionary:
	var sim := ctx.sim
	var best := -1
	var best_score := -1
	var best_dir := Vector2i(1, 0)
	for i in sim.active:
		if sim.kind[i] != D.ROAD or sim.terrain[i] == D.WATER:
			continue
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		if m != RoadTopology.NS and m != RoadTopology.EW:
			continue
		for dv: Vector2i in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
			if (dv.x != 0) != (m == RoadTopology.EW):
				continue
			var straight := 0
			var score := 0
			for k in range(1, 8):
				var ax := D.tx(i) + dv.x * k
				var ay := D.ty(i) + dv.y * k
				if D.in_bounds(ax, ay) and sim.kind[D.idx(ax, ay)] == D.ROAD:
					straight += 1
				for side: int in [-1, 1]:
					var sx := ax + dv.y * side
					var sy := ay + dv.x * side
					if D.in_bounds(sx, sy) and D.is_zone(sim.kind[D.idx(sx, sy)]):
						score += sim.level[D.idx(sx, sy)]
			if straight >= 5 and score > best_score:
				best_score = score
				best = i
				best_dir = dv
	if best < 0:
		return {}
	var fwd := Vector3(best_dir.x, 0, best_dir.y)
	var right := Vector3(-fwd.z, 0, fwd.x)
	return _pose(Vector3(D.tx(best), 0, D.ty(best)) + right * WS.SIDEWALK_CENTER - fwd * 0.1, fwd)


## The junction with the most development around it, the hero on the sidewalk before its corner,
## facing into the crossing.
func _crossing_pose() -> Dictionary:
	var sim := ctx.sim
	var best := -1
	var best_n := -1
	for i in sim.active:
		if sim.kind[i] != D.ROAD or sim.terrain[i] == D.WATER:
			continue
		if RoadTopology.arms(RoadTopology.mask(sim, D.tx(i), D.ty(i))).size() < 3:
			continue
		var n := 0
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var x := D.tx(i) + dx
				var y := D.ty(i) + dy
				if D.in_bounds(x, y) and ((D.is_zone(sim.kind[D.idx(x, y)]) and sim.level[D.idx(x, y)] > 0) or D.is_service(sim.kind[D.idx(x, y)])):
					n += 1
		if n > best_n:
			best_n = n
			best = i
	if best < 0:
		return {}
	var arms := RoadTopology.arms(RoadTopology.mask(sim, D.tx(best), D.ty(best)))
	var arm := Vector2(arms[0])
	# On the arm's tile, on its right-hand sidewalk, 0.75 tile out, looking at the junction.
	var into := Vector3(-arm.x, 0, -arm.y)
	var right := Vector3(-into.z, 0, into.x)
	var pos := Vector3(D.tx(best) + arm.x * 0.75, 0, D.ty(best) + arm.y * 0.75) + right * WS.SIDEWALK_CENTER
	return _pose(pos, into)


func _pose(pos: Vector3, look: Vector3) -> Dictionary:
	var g := ctx.collision.walk_height(pos)
	pos.y = g if not is_nan(g) else 0.0
	return {"pos": pos, "yaw": rad_to_deg(atan2(-look.x, -look.z)), "pitch": -10.0}
