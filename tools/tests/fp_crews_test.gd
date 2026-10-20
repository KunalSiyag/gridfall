extends SceneTree
## The player's crews on foot (integration feature "crews"): a phone order puts its crew on site,
## walking in through the gate to a foreman's spot by the gate, two builders in the middle and a
## hauler carrying crates from a pile, nobody inside the hoarding, a machine or the frame. A board
## over the gate and the crew card name the crew, the order, the stage and the time left, and list
## the orders still waiting. E on a worker gets a word about the job, the crew follows its site
## through the stages, a road crew moves along the road, and a finished or cancelled order clears
## its crew with a toast. Survives a world rebuild, a photo shot and teardown, and frees the bodies
## it keeps off the street when it is freed without teardown (quitting).

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const SPOTS := preload("res://scripts/fp/crews/crew_spots.gd")
const GRID := preload("res://scripts/fp/crews/crew_grid.gd")
const DT := 1.0 / 30.0
## The hoarding's inner face, from the tile centre.
const INSIDE := 0.47

var fails: Array[String] = []
var toasts: Array[String] = []
var ctx: FpContext
var f: FpFeature
var mi: int = 0
## Order ids and their tiles: police (crew 1), school (crew 2), park (waits, then crew 1).
var police: Dictionary = {}
var school: Dictionary = {}
var park: Dictionary = {}
var used: Array[int] = []


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true})
	ctx.sim.construction_mode = "staged"
	ctx.sim.start()
	ctx.sim.set_speed(0)
	for m: Dictionary in ctx.sim.mayors:
		m["treasury"] = 60000
	ctx.bus.toast.connect(func(t: String, _k: String) -> void: toasts.append(t))
	ctx.player.set_process(false)
	f = K.make_feature(ctx, "crews")
	K.check(fails, f != null and f.feature_id() == "crews", "the crews feature is registered")
	if f == null:
		K.finish(self, "FP_CREWS_TEST", fails)
		return
	f.set_process(false)
	f.bodies.blocking = true
	K.check(
		fails,
		f.bodies.ok or not f.bodies.why.is_empty(),
		"the trades roster loads (%d bodies) or says why not" % f.bodies.kinds.size()
	)
	var lot: Dictionary = f.call("_photo_lot")
	K.check(fails, not lot.is_empty(), "fixture: an open lot whose gate faces a road")
	if lot.is_empty():
		K.finish(self, "FP_CREWS_TEST", fails)
		return
	mi = int(lot["mi"])
	await _check_arrival(lot["lot"])
	_check_hauler()
	_check_talk()
	_check_queue()
	_check_stages()
	_check_finish()
	_check_cancel()
	_check_road()
	_check_rebuild()
	_check_photo()
	_check_teardown()
	_check_quit()
	K.finish(self, "FP_CREWS_TEST", fails)


# ------------------------------------------------------------------ helpers


func _step(secs: float) -> void:
	for _k in range(ceili(secs / DT)):
		f._process(DT)


func _order(key: String, t: Vector2i) -> Dictionary:
	var res := ctx.sim.apply_player_order(
		mi, {"type": "build", "building": key, "x": t.x, "y": t.y}
	)
	var j: Dictionary = res.get("job", {})
	if not j.is_empty():
		used.append(D.idx(int(res["x"]), int(res["y"])))
	return j


## Another open lot in the district, away from the ones already ordered.
func _free_lot() -> Vector2i:
	for lot: Array in ctx.sim.open_lots(mi, 400):
		var t := Vector2i(int(lot[0]), int(lot[1]))
		var clear := true
		for i: int in used:
			clear = clear and maxi(absi(D.tx(i) - t.x), absi(D.ty(i) - t.y)) > 1
		if clear:
			return t
	return D.NO_TILE


func _rig(j: Dictionary) -> Node3D:
	return f.rigs.get(int(j.get("id", -1)), null)


func _tile(j: Dictionary) -> int:
	return int((j.get("tiles", [-1]) as Array)[0])


func _toasted(part: String) -> bool:
	for t: String in toasts:
		if t.contains(part):
			return true
	return false


## Every worker at its place on the site stands where a person fits (on the ground, a slab, a
## floor or a scaffold board), on the ground only inside the hoarding of a fenced site.
func _all_fit(rig: Node3D, fenced: bool) -> bool:
	var c := Vector3(D.tx(rig.tile), 0.0, D.ty(rig.tile))
	for w: Variant in rig.workers:
		if w.state in ["off", "wait", "walk"]:
			continue
		if not SPOTS.stands(rig.spots, w.pos):
			return false
		var inside := absf(w.pos.x - c.x) < INSIDE and absf(w.pos.z - c.z) < INSIDE
		if fenced and not inside and w.pos.y < c.y + GRID.CLIMB:
			return false
	return true


func _states(rig: Node3D) -> String:
	var out := PackedStringArray()
	for w: Variant in rig.workers:
		out.append("%s:%s" % [w.role, w.state])
	return ", ".join(out)


# ------------------------------------------------------------------ checks


func _check_arrival(t: Vector2i) -> void:
	var side := SPOTS.gate_side(ctx.directory, D.idx(t.x, t.y))
	var stand := Vector3(t.x, 0.0, t.y) + Vector3(side.x, 0.0, side.y) * 0.62
	stand.y = ctx.collision.ground_height(stand)
	ctx.player.teleport(stand, rad_to_deg(atan2(side.x, side.y)))
	police = _order("police", t)
	K.check(fails, int(police.get("crew", -1)) == 0, "crew 1 takes the police station")
	var i := _tile(police)
	K.check(fails, not ctx.view.site_boxes(i).is_empty(), "fixture: the site is drawn at once")
	var rig := _rig(police)
	K.check(fails, rig != null, "the order's crew is on its site")
	if rig == null:
		return
	_step(DT)
	var out: Vector3 = rig.spots.get("out", SPOTS.NONE)
	var at_gate := true
	for w: Variant in rig.workers:
		at_gate = at_gate and SPOTS.found(w.pos) and w.pos.distance_to(out) < 0.15
	K.check(
		fails,
		rig.workers.size() == 4 and at_gate and SPOTS.found(out),
		"a foreman, two builders and a hauler come in from outside the gate (%s)" % _states(rig)
	)
	var stagger := (rig.workers[3].state as String) == "wait"
	K.check(fails, stagger, "they step off one after another")
	_step(14.0)
	var placed := true
	for w: Variant in rig.workers:
		placed = placed and w.state in ["work", "take", "put", "walk", "talk"]
	K.check(fails, placed, "every worker reached the site (%s)" % _states(rig))
	var foreman: Variant = rig.workers[0]
	K.check(
		fails,
		foreman.state == "work" and foreman.pos.distance_to(rig.spots["gate"]) < 0.01,
		"the foreman keeps watch by the gate"
	)
	var builders := 0
	for w: Variant in rig.workers:
		var at_spot: bool = SPOTS.found(w.spot) and w.pos.distance_to(w.spot) < 0.01
		builders += 1 if w.role == "builder" and w.state == "work" and at_spot else 0
	K.check(fails, builders == 2, "both builders are at work in the middle")
	K.check(fails, _all_fit(rig, true), "nobody stands in the hoarding, a machine or a slab")
	K.check(fails, rig.working() == 4, "every worker has a body (%d)" % rig.working())
	var board: String = rig.board.text
	K.check(
		fails,
		board.contains("Crew 1") and board.contains("Police Station") and board.contains("left"),
		"the board names the crew, the order and the time left (%s)" % board.replace("\n", " / ")
	)
	f.call("_refresh")
	var row: String = f.card.row_text(int(police["id"]))
	K.check(
		fails,
		f.card.visible and row.contains("Crew 1") and row.contains(D.STAGE_LABELS["clearing"]),
		"the crew card lists the order and what the crew does (%s)" % row
	)
	await process_frame
	K.check(fails, _toasted("Your crew is on site"), "a one-time tip says where to find the crew")
	K.check(fails, bool(f.to_dict().get("tipped", false)), "the tip is saved")


func _check_hauler() -> void:
	var rig := _rig(police)
	if rig == null:
		return
	var hauler: Variant = rig.workers[3]
	if not SPOTS.found(rig.spots.get("drop", SPOTS.NONE)):
		print("  skip the hauler: no clear way from the pile to the work on this site")
		return
	var carried := false
	var shown := true
	var put_down := false
	for _k in range(ceili(30.0 / DT)):
		f._process(DT)
		carried = carried or hauler.carrying
		put_down = put_down or (carried and not hauler.carrying)
		if hauler.body != null and hauler.body.crate != null:
			shown = shown and hauler.body.crate.visible == hauler.carrying
	K.check(
		fails, carried and put_down, "the hauler carries crates from the pile and sets them down"
	)
	K.check(fails, shown, "the crate shows only while it is carried")
	K.check(fails, _all_fit(rig, true), "the hauler's way stays clear of the site's parts")


func _check_talk() -> void:
	var rig := _rig(police)
	if rig == null:
		return
	var foreman: Variant = rig.workers[0]
	var eye := ctx.player.eye_position()
	var dir: Vector3 = (foreman.pos + Vector3.UP * 1.3 * WS.M - eye).normalized()
	var t: Dictionary = f.pick(eye, dir, WS.INTERACT_RANGE * 2.0)
	K.check(
		fails,
		(
			str(t.get("kind", "")) == "crew"
			and str(t.get("label", "")) == "Talk to the foreman, crew 1"
		),
		"the foreman answers the interaction ray through the gate (%s)" % str(t.get("label", ""))
	)
	var ia: FpFeature = K.make_feature(ctx, "interact")
	ia.set_process(false)
	var best: Dictionary = ia.call("targets_along", eye, dir)
	K.check(fails, str(best.get("kind", "")) == "crew", "E's target is the worker, not the site")
	ctx.bus.interact_requested.emit(t)
	K.check(fails, foreman.state == "talk", "the foreman stops to talk")
	K.check(fails, _toasted("Foreman, crew 1: “"), "and says how the job goes")
	_step(5.0)
	K.check(fails, foreman.state == "work", "then goes back to work")
	var away := eye + Vector3(-dir.x, 0.0, -dir.z).normalized() * 0.2
	K.check(fails, f.pick(away, -dir, 0.05).is_empty(), "a ray that misses the crew picks nothing")
	ia.teardown()
	ctx.features.erase("interact")
	ia.queue_free()


func _check_queue() -> void:
	school = _order("school", _free_lot())
	park = _order("park", _free_lot())
	K.check(
		fails,
		int(school.get("crew", -1)) == 1 and int(park.get("crew", 0)) == -1,
		"crew 2 takes the school, the park waits"
	)
	f.call("_refresh")
	var wait: String = f.card.waiting_text()
	K.check(
		fails,
		wait.contains("Park") and wait.contains("starts in") and f.card.free_text() == "all busy",
		"the card lists the waiting order and when it starts (%s)" % wait
	)
	K.check(fails, f.rigs.size() == 2, "only orders with a crew have one on site")
	ctx.push_modal(&"crews_test")
	K.check(fails, not f.card.visible, "the card hides under a menu or the chat")
	ctx.pop_modal(&"crews_test")
	K.check(fails, f.card.visible, "and comes back")


func _check_stages() -> void:
	var rig := _rig(police)
	if rig == null:
		return
	ctx.sim.advance_crews(float(police["total"]) * 0.5 - float(police["done"]))
	_step(0.3)
	var line: String = rig.board.text
	K.check(
		fails,
		rig.stage == "foundation" and line.contains(D.STAGE_LABELS["foundation"]),
		"the crew follows its site to the foundations (%s)" % line.replace("\n", " / ")
	)
	K.check(
		fails,
		absf(f.card.row_fraction(int(police["id"])) - 0.5) < 0.02,
		"the card's bar shows half the work done"
	)
	_step(8.0)
	K.check(fails, _all_fit(rig, true), "the redrawn site's new parts are kept clear too")
	# The finished police station fills its lot: the facade is finished from the scaffold.
	ctx.sim.advance_crews(float(police["total"]) * 0.9 - float(police["done"]))
	ctx.view.flush_rebuild_queue()
	_step(0.3)
	var up := 0
	for w: Variant in rig.workers:
		var on_board: bool = w.state == "work" and w.pos.y > GRID.CLIMB
		up += 1 if w.role == "builder" and on_board else 0
	K.check(
		fails,
		rig.stage == "finishing" and up == 2,
		"finishing the facade, the builders work from the scaffold (%s)" % _states(rig)
	)
	K.check(fails, _all_fit(rig, true), "on its boards, clear of the building and the hoarding")


func _check_finish() -> void:
	toasts.clear()
	ctx.sim.advance_crews(float(police["total"]) - float(police["done"]) + 0.05)
	K.check(fails, ctx.sim.kind[_tile(police)] == D.POLICE, "fixture: the police station opens")
	K.check(fails, _rig(police) == null, "its crew leaves the site")
	K.check(
		fails,
		_toasted("Police Station is finished, built by crew 1"),
		"a toast says the order is done"
	)
	K.check(
		fails,
		int(park.get("crew", -1)) == 0 and _rig(park) != null and _toasted("Crew 1 is on the Park"),
		"crew 1 moves on to the waiting park, with a toast"
	)


func _check_cancel() -> void:
	toasts.clear()
	var i := _tile(park)
	ctx.sim.apply_player_order(mi, {"type": "bulldoze", "x": D.tx(i), "y": D.ty(i)})
	ctx.sim.advance_crews(0.0)
	K.check(
		fails,
		_rig(park) == null and _toasted("Order cancelled: Park"),
		"bulldozing a crew site sends the crew away"
	)


func _check_road() -> void:
	var res := {}
	for k in range(D.W * D.H):
		var x := D.tx(k)
		var y := D.ty(k)
		var n := 0
		while n < 5 and _open(x + n, y):
			n += 1
		if n == 5:
			res = ctx.sim.apply_player_order(
				mi, {"type": "road", "x": x, "y": y, "x2": x + 4, "y2": y}
			)
			break
	var j: Dictionary = res.get("job", {})
	var rig := _rig(j)
	K.check(fails, rig != null and int(j["crew"]) == 0, "a road order gets crew 1")
	if rig == null:
		return
	var tiles: Array = j["tiles"]
	K.check(fails, rig.tile == int(tiles[0]), "the road crew starts at one end")
	ctx.sim.advance_crews(float(j["total"]) * 0.5 - float(j["done"]))
	_step(0.3)
	var middle: Vector3 = rig.spots.get("middle", SPOTS.NONE)
	var at := Vector3(D.tx(int(tiles[2])), 0.0, D.ty(int(tiles[2])))
	K.check(
		fails,
		rig.tile == int(tiles[2]) and SPOTS.found(middle) and middle.distance_to(at) < 0.01,
		"half way it works on the middle tile"
	)
	_step(6.0)
	K.check(fails, _all_fit(rig, false), "nobody stands in a road machine")


func _open(x: int, y: int) -> bool:
	if not D.in_bounds(x, y):
		return false
	var i := D.idx(x, y)
	return ctx.sim.district[i] == mi and ctx.sim.kind[i] == D.EMPTY and ctx.sim.terrain[i] == D.LAND


func _check_rebuild() -> void:
	var before: int = f.rigs.size()
	f.on_world_rebuilt()
	_step(DT)
	var settled := true
	var states := PackedStringArray()
	for rig: Variant in f.rigs.values():
		states.append(_states(rig))
		for w: Variant in rig.workers:
			settled = settled and w.state != "wait" and w.state != "walk"
	K.check(
		fails,
		f.rigs.size() == before and before >= 1 and settled,
		(
			"after a rebuild (load) the crews are back at work at once (%d before: %s)"
			% [before, "; ".join(states)]
		)
	)
	var st: Dictionary = f.self_test()
	K.check(fails, bool(st["ok"]), "self test: %s" % st["detail"])


func _check_photo() -> void:
	ctx.sim.advance_crews(1000.0)
	K.check(fails, f.rigs.is_empty() and ctx.sim.crew_jobs.is_empty(), "fixture: every order done")
	var shots: Array = f.photo_shots()
	K.check(fails, shots.size() == 1, "one photo shot through a site gate")
	if shots.is_empty():
		return
	var s: Dictionary = shots[0]
	K.check(
		fails,
		(
			s["name"] == "crews"
			and s["prepare"] == "photo_prepare"
			and s["restore"] == "photo_restore"
		),
		"the shot prepares and restores itself"
	)
	f.call(str(s["prepare"]))
	ctx.player.teleport(s["pos"], float(s["yaw"]))
	_step(DT)
	var rig: Node3D = f.rigs.values()[0] if f.rigs.size() == 1 else null
	var ready: bool = rig != null and rig.working() == 4
	for w: Variant in rig.workers if rig != null else []:
		ready = ready and w.state != "wait" and w.state != "walk"
	K.check(fails, ready, "the photo crew is at work as the shot is taken")
	f.call(str(s["restore"]))
	K.check(fails, not f.bodies.blocking, "restore lets bodies load in the background again")


func _check_teardown() -> void:
	f.teardown()
	K.check(
		fails,
		(
			f.rigs.is_empty()
			and f.card == null
			and not ctx.sim.crew_job_started.is_connected(f._on_started)
		),
		"teardown frees the crews and the card and disconnects"
	)


func _check_quit() -> void:
	var g: FpFeature = K.make_feature(ctx, "crews")
	if g == null:
		return
	g.set_process(false)
	g.bodies.blocking = true
	var b: Variant = g.bodies.make(0, 0.5, g)
	var body: Node3D = b.root if b != null else null
	g.bodies.release(b)
	g.bodies.finish_loads()
	var off_street := body != null and body.get_parent() == null
	g.free()
	K.check(
		fails,
		off_street and not is_instance_valid(body),
		"freeing the feature without teardown (quitting) frees the bodies it keeps off the street"
	)
