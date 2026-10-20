extends FpFeature
## The player's building crews (integration feature "crews"). Every order placed from the phone
## (CitySim.apply_player_order) goes to one of D.CREWS crews, which builds it in real time: two
## to five minutes for a building at game speed 1, while later orders wait for a free crew. The
## crew is on site to see (CrewRig): a foreman by the gate, builders at work in the middle, a
## hauler carrying crates, dust while they work and a board over the gate with the crew, the
## order, the stage and the time left. A crew that takes an order while you play walks in through
## the gate, and a road crew moves along the road as the work goes on. The crew card under the top
## bar lists the orders with their stage, progress and countdown, and the ones still waiting. E on
## a worker gets a word about the job; a toast says when an order is done.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const BODIES := preload("res://scripts/fp/crews/crew_bodies.gd")
const SPOTS := preload("res://scripts/fp/crews/crew_spots.gd")
const RIG := preload("res://scripts/fp/crews/crew_rig.gd")
const CARD := preload("res://scripts/fp/crews/crew_card.gd")
const REFRESH := 0.25
## A crew that takes an order waits this long for its site to be drawn before it is placed anyway
## (on foot CityView holds a rebuild in front of the camera back for up to 5 s).
const PLACE_WAIT := 6.0
## Within this distance the card reads "here" instead of a distance.
const HERE := 0.75
const DIRS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
## Anything the interaction ray meets this much before a worker hides the worker.
const OCCLUDE := 0.3 * WS.M
## What a worker says on E: {stage}, {Stage} (capitalised), {label}, {left}.
const SAYINGS := {
	"foreman":
	[
		"We're {stage} on the {label}. Ready in {left}.",
		"Right on schedule: the {label} opens in {left}.",
		"{Stage} today. Hard hats past the gate, please.",
	],
	"builder":
	[
		"{Stage}. Should be done in {left}.",
		"Busy {stage} here. {left} to go.",
		"Mind your step, we're {stage}.",
	],
	"hauler":
	[
		"Another load for the {label}.",
		"These crates won't carry themselves. {left} to go.",
		"Keep clear of the pile, please.",
	],
}
## The photo shot: the camera stands on the sidewalk this far out from the middle of a lot whose
## hoarding gate faces a road and looks in through the gate, at an order PHOTO_DONE of the way.
const PHOTO_BACK := 0.62
const PHOTO_DONE := 0.5
const PHOTO_BUILDINGS := ["police", "fire_station", "school", "park"]

var bodies: BODIES
var card: CARD
## Order id -> CrewRig, for every order a crew is on.
var rigs: Dictionary = {}
## Rigs waiting for their site to be drawn: order id -> {"arrive": bool, "t": seconds left}.
var _unplaced: Dictionary = {}
## Rigs to lay out again on the next frame: their site was redrawn, or the crew moved on.
var _dirty: Dictionary = {}
## Orders seen waiting for a crew (their start gets a toast).
var _queued: Dictionary = {}
var _tipped: bool = false
var _said: int = 0
var _t: float = 0.0
## The photo shot's {"lot": Vector2i, "mi": district}, {} without one.
var _photo: Dictionary = {}


func feature_id() -> String:
	return "crews"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	bodies = BODIES.new()
	if bodies.load_roster():
		bodies.start()
	if ctx.hud != null:
		card = CARD.new()
		card.setup()
		card.visible = false
		ctx.hud.slot("center").add_child(card)
	if ctx.sim != null:
		link_signal(ctx.sim.crew_job_started, _on_started)
		link_signal(ctx.sim.crew_job_finished, _on_finished)
	if ctx.view != null:
		link_signal(ctx.view.tile_built, _on_tile_built)
	if ctx.bus != null:
		link_signal(ctx.bus.interact_requested, _on_interact)
		link_signal(ctx.bus.modal_changed, _sync_visibility)


## Boot, load or New City: the crews of the city as it is now, already at work.
func on_world_rebuilt() -> void:
	_clear_rigs()
	_queued.clear()
	_refresh()


func teardown() -> void:
	unlink_signals()
	_clear_rigs()
	if bodies != null:
		bodies.finish_loads()
		bodies.clear()
	if card != null and is_instance_valid(card):
		card.queue_free()
	card = null


func _notification(what: int) -> void:
	# Quitting frees the tree without teardown, and released bodies are out of the tree.
	if what == NOTIFICATION_PREDELETE and bodies != null:
		bodies.clear()


func to_dict() -> Dictionary:
	return {"tipped": true} if _tipped else {}


func from_dict(d: Dictionary) -> void:
	_tipped = bool(d.get("tipped", false))


func self_test() -> Dictionary:
	if ctx.hud != null and card == null:
		return {"ok": false, "detail": "crew card missing"}
	var who := (
		"%d trades bodies" % bodies.kinds.size() if bodies.ok else "stand-ins (%s)" % bodies.why
	)
	return {"ok": true, "detail": "%s, %d crews at work" % [who, rigs.size()]}


## The worker nearest along the ray that nothing hides: {"kind": "crew", "id": "<order>:<k>",
## "tile", "pos" (its chest), "dist", "label", "data": {"job", "worker", "role"}}, or {}.
func pick(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var best := {}
	var by: RIG = null
	for rig: RIG in rigs.values():
		var hit := rig.pick(origin, dir, max_dist)
		if not hit.is_empty() and (best.is_empty() or float(hit["t"]) < float(best["t"])):
			best = hit
			by = rig
	if by == null or _hidden(origin, dir, float(best["t"])):
		return {}
	var k := int(best["k"])
	var role := by.workers[k].role
	var who := "a builder" if role == "builder" else "the " + role
	return {
		"kind": "crew",
		"id": "%d:%d" % [by.job_id, k],
		"tile": by.tile,
		"pos": best["pos"],
		"dist": float(best["t"]),
		"label": "Talk to %s, crew %d" % [who, by.crew + 1],
		"data": {"job": by.job_id, "worker": k, "role": role},
	}


## One shot through the gate of a site a crew works on ("crews"); photo_prepare places the order.
func photo_shots() -> Array:
	_photo = _photo_lot()
	if _photo.is_empty():
		return []
	var t: Vector2i = _photo["lot"]
	var side := SPOTS.gate_side(ctx.directory, D.idx(t.x, t.y))
	var c := Vector3(t.x, 0.0, t.y)
	var pos := c + Vector3(side.x, 0.0, side.y) * PHOTO_BACK
	pos.y = ctx.collision.ground_height(pos)
	var look := c - pos
	var shot := {"name": "crews", "pos": pos, "yaw": rad_to_deg(atan2(-look.x, -look.z))}
	shot.merge(
		{"pitch": -4.0, "hour": 10.5, "prepare": "photo_prepare", "restore": "photo_restore"}
	)
	return [shot]


## Photo tour: a phone order on the shot's lot, PHOTO_DONE of the way, its site drawn and its crew
## already at their places.
func photo_prepare() -> void:
	if _photo.is_empty():
		return
	bodies.blocking = true
	var t: Vector2i = _photo["lot"]
	for key: String in PHOTO_BUILDINGS:
		var a := {"type": "build", "building": key, "x": t.x, "y": t.y}
		var res := ctx.sim.apply_player_order(int(_photo["mi"]), a)
		if res.has("job"):
			ctx.sim.advance_crews(float(res["job"]["total"]) * PHOTO_DONE)
			break
	if ctx.view != null:
		ctx.view.flush_rebuild_queue()
	for u: Dictionary in _unplaced.values():
		u["arrive"] = false
	_place_waiting(PLACE_WAIT)
	_refresh()


func photo_restore() -> void:
	bodies.blocking = false


func _process(delta: float) -> void:
	if ctx == null or ctx.sim == null:
		return
	_place_waiting(delta)
	_t -= delta
	if _t <= 0.0:
		_refresh()
	var me := ctx.player_position()
	for rig: RIG in rigs.values():
		if not rig.spots.is_empty():
			rig.step(delta, me)


# ------------------------------------------------------------------ sim signals


func _on_started(job: Dictionary) -> void:
	var id := int(job["id"])
	var waited := _queued.has(id)
	_queued.erase(id)
	_rig_for(job, true)
	if waited:
		_toast("Crew %d is on the %s now." % [int(job["crew"]) + 1, job["label"]], "info")
	# After the phone's own toast for the order that started it.
	_tip.call_deferred()
	_refresh()


func _on_finished(job: Dictionary) -> void:
	var id := int(job["id"])
	_queued.erase(id)
	_drop(id)
	var cancelled := bool(job.get("cancelled", false))
	if cancelled:
		_toast("Order cancelled: %s." % job["label"], "info")
	elif int(job["crew"]) >= 0:
		var c := int(job["crew"]) + 1
		_toast("%s is finished, built by crew %d." % [job["label"], c], "success")
	Analytics.track("crew_done", {"cancelled": cancelled, "seconds": roundi(float(job["total"]))})
	_refresh()


## A redrawn site (a new stage) moves its machines and parts: the crew is laid out again once the
## collision boxes follow (CollisionWorld hears tile_built after the features).
func _on_tile_built(i: int, _holder: Node3D) -> void:
	if ctx.view.in_setup:
		return
	for rig: RIG in rigs.values():
		if rig.tile == i:
			_dirty[rig.job_id] = true


func _on_interact(t: Dictionary) -> void:
	if str(t.get("kind", "")) != "crew":
		return
	var data: Dictionary = t.get("data", {})
	var rig: RIG = rigs.get(int(data.get("job", -1)))
	var k := int(data.get("worker", -1))
	if rig == null or k < 0 or k >= rig.workers.size():
		return
	rig.greet(k, ctx.player.eye_position() if ctx.player != null else ctx.player_position())
	var role := rig.workers[k].role
	var line := _saying(rig, role)
	_toast("%s, crew %d: “%s”" % [role.capitalize(), rig.crew + 1, line], "chat")
	Analytics.track("crew_talk", {"role": role})


# ------------------------------------------------------------------ rigs


## The rig for job once a crew is on it (arrive: it walks in once its site is drawn), or null.
func _rig_for(job: Dictionary, arrive: bool) -> RIG:
	var id := int(job["id"])
	if rigs.has(id):
		return rigs[id]
	var tile := _work_tile(job)
	if tile < 0 or int(job["crew"]) < 0:
		return null
	var rig: RIG = RIG.new()
	rig.setup(bodies, job, tile)
	add_child(rig)
	rigs[id] = rig
	var drawn := ctx.view == null or not ctx.view.site_boxes(tile).is_empty()
	_unplaced[id] = {"arrive": arrive, "t": 0.0 if drawn or not arrive else PLACE_WAIT}
	return rig


## Lays out the rigs whose site is drawn (or that waited PLACE_WAIT for it) and the dirty ones.
func _place_waiting(delta: float) -> void:
	for id: int in _unplaced.keys():
		var u: Dictionary = _unplaced[id]
		u["t"] = float(u["t"]) - delta
		if float(u["t"]) <= 0.0:
			_dirty[id] = true
	if _dirty.is_empty() or ctx.collision == null:
		return
	var ids: Array = _dirty.keys()
	_dirty.clear()
	for id: int in ids:
		var rig: RIG = rigs.get(id)
		if rig != null:
			var u: Dictionary = _unplaced.get(id, {})
			rig.place(ctx, bool(u.get("arrive", false)))
			_unplaced.erase(id)


func _drop(id: int) -> void:
	var rig: RIG = rigs.get(id)
	rigs.erase(id)
	_unplaced.erase(id)
	_dirty.erase(id)
	if rig != null and is_instance_valid(rig):
		rig.release()
		rig.queue_free()


func _clear_rigs() -> void:
	for id: int in rigs.keys():
		_drop(id)


## The tile the crew works on: the order's only site, or along a road the one its progress has
## reached.
static func _work_tile(job: Dictionary) -> int:
	var tiles: Array = job.get("tiles", [])
	if tiles.is_empty():
		return -1
	var f := clampf(float(job["done"]) / maxf(float(job["total"]), 0.01), 0.0, 1.0)
	return int(tiles[mini(int(f * tiles.size()), tiles.size() - 1)])


# ------------------------------------------------------------------ card and boards


## The card, the boards and the rigs from the sim's crew orders (rigs also come and go here, for
## orders that started or ended while nothing listened, such as a load).
func _refresh() -> void:
	_t = REFRESH
	if ctx.sim == null:
		return
	var when := ctx.sim.crew_schedule()
	var working: Array[Dictionary] = []
	var waiting: Array[Dictionary] = []
	for job: Dictionary in ctx.sim.crew_jobs:
		if int(job["crew"]) < 0:
			_queued[int(job["id"])] = true
			waiting.append(_row(job, when))
		else:
			_update_rig(job)
			working.append(_row(job, when))
	var live := {}
	for r: Dictionary in working:
		live[int(r["id"])] = true
	for id: int in rigs.keys():
		if not live.has(id):
			_drop(id)
	working.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["crew"] < b["crew"])
	working.append_array(waiting)
	if card != null:
		card.show_jobs(working, ctx.sim.crews_free(), D.CREWS)
	_sync_visibility()


func _update_rig(job: Dictionary) -> void:
	var rig := _rig_for(job, false)
	if rig == null:
		return
	var tile := _work_tile(job)
	if tile >= 0 and tile != rig.tile:
		rig.tile = tile
		_dirty[rig.job_id] = true
	var s: Dictionary = ctx.sim.sites.get(rig.tile, {})
	rig.stage = ctx.sim.site_stage_name(s) if not s.is_empty() else ""
	var title := "Crew %d · %s" % [rig.crew + 1, job["label"]]
	rig.set_board(title, "%s · %s left" % [_stage_label(rig.stage), _left(job)])


## A card row for job (CrewCard.show_jobs); when (CitySim.crew_schedule) dates a waiting order.
func _row(job: Dictionary, when: Dictionary) -> Dictionary:
	var id := int(job["id"])
	var tile := _work_tile(job)
	var r := {"id": id, "crew": int(job["crew"]), "label": job["label"], "stage": "", "step": ""}
	r["fraction"] = clampf(float(job["done"]) / maxf(float(job["total"]), 0.01), 0.0, 1.0)
	r["where"] = _where(tile)
	if int(job["crew"]) < 0:
		r["left"] = S.countdown((when.get(id, Vector2.ZERO) as Vector2).x, ctx.sim.speed)
		return r
	r["left"] = _left(job)
	var s: Dictionary = ctx.sim.sites.get(tile, {})
	if not s.is_empty():
		r["stage"] = _stage_label(ctx.sim.site_stage_name(s))
		r["step"] = "stage %d of %d" % [int(s["stage"]) + 1, (s["stages"] as Array).size()]
	return r


func _left(job: Dictionary) -> String:
	return S.countdown(float(job["total"]) - float(job["done"]), ctx.sim.speed)


static func _stage_label(stage: String) -> String:
	if stage.is_empty():
		return "getting started"
	return str(D.STAGE_LABELS.get(stage, stage.replace("_", " ")))


## "240 m NE" from the player to tile i, "here" on it.
func _where(i: int) -> String:
	if i < 0:
		return ""
	var me := ctx.player_position()
	var d := Vector2(D.tx(i) - me.x, D.ty(i) - me.z)
	if d.length() < HERE:
		return "here"
	var bearing := atan2(d.x, -d.y)
	return "%s %s" % [S.distance(d.length()), DIRS[posmod(roundi(bearing / (PI / 4.0)), 8)]]


## The card shows while there are orders and nothing covers the street (the chat drawer, a menu,
## the map or the overview); the boards hide in photo mode. Also runs on bus.modal_changed: the
## pause menu stops _process.
func _sync_visibility(_modal := false) -> void:
	if card != null:
		var any := card.row_count() > 0 or not card.waiting_text().is_empty()
		card.visible = any and not ctx.is_modal()
	var boards := ctx.player == null or not ctx.player.photo_mode
	for rig: RIG in rigs.values():
		rig.board.visible = boards


# ------------------------------------------------------------------ words


func _saying(rig: RIG, role: String) -> String:
	var job := _job(rig.job_id)
	var lines: Array = SAYINGS.get(role, SAYINGS["builder"])
	var stage := _stage_label(rig.stage)
	var words := {
		"stage": stage,
		"Stage": stage.substr(0, 1).to_upper() + stage.substr(1),
		"label": str(job.get("label", "site")).get_slice(",", 0),
		"left": _left(job) if not job.is_empty() else "no time",
	}
	_said += 1
	return str(lines[_said % lines.size()]).format(words)


func _job(id: int) -> Dictionary:
	for j: Dictionary in ctx.sim.crew_jobs:
		if int(j["id"]) == id:
			return j
	return {}


func _tip() -> void:
	if _tipped or ctx == null:
		return
	_tipped = true
	_toast(
		"Your crew is on site: go and watch them build, or press E by a worker for news.", "system"
	)


## True when a wall, a machine or the frame stands between origin and a worker t along dir.
func _hidden(origin: Vector3, dir: Vector3, t: float) -> bool:
	if ctx.collision == null:
		return false
	var hit := ctx.collision.raycast(origin, dir, t, false)
	return bool(hit["hit"]) and float(hit["dist"]) < t - OCCLUDE


# ------------------------------------------------------------------ photo


## The open lot nearest the player whose hoarding gate faces a road with sidewalk to stand on:
## {"lot": Vector2i, "mi": its district}, or {}.
func _photo_lot() -> Dictionary:
	if ctx == null or ctx.sim == null or ctx.collision == null or not ctx.sim.staged():
		return {}
	var me := ctx.player_position()
	var best := {}
	var best_d := INF
	for mi in range(D.MAYORS.size()):
		for lot: Array in ctx.sim.open_lots(mi, 400):
			var t := Vector2i(int(lot[0]), int(lot[1]))
			var d := Vector2(t.x - me.x, t.y - me.z).length()
			if d < best_d and _photo_ok(t):
				best = {"lot": t, "mi": mi}
				best_d = d
	return best


func _photo_ok(t: Vector2i) -> bool:
	var side := SPOTS.gate_side(ctx.directory, D.idx(t.x, t.y))
	var n := t + side
	if not D.in_bounds(n.x, n.y) or ctx.sim.kind[D.idx(n.x, n.y)] != D.ROAD:
		return false
	var pos := Vector3(t.x, 0.0, t.y) + Vector3(side.x, 0.0, side.y) * PHOTO_BACK
	return SPOTS.fits(ctx.collision, pos)


func _toast(t: String, kind: String) -> void:
	if ctx.bus != null:
		ctx.bus.toast.emit(t, kind)
