extends SceneTree
## How the on-foot tree stream spreads its work (CityView._stream_trees). fp_tree_stream_test.gd
## proves WHAT is planted; this proves WHEN and how much per frame, because the stream exists to
## cut cost and a teleport or an aerial toggle must not turn into a hitch. Checks: a pass runs
## only after a hysteresis step of camera travel, and a chunk past the window by less than a step
## stays planted (no churn at the window's edge); a pass spends its budget past the near ring
## (one chunk at least, TREE_STREAM_CAP at most, the ring itself always in full; the budget's unit
## and default are pinned) and frees only TREE_FREE_CAP chunks, farthest first; the chunks that
## stay keep their nodes (a walk, a vis_mult change, a mode switch); a pass scans the window's box
## only, an idle frame or a complete aerial coverage scans nothing, and the passes of one fill
## share the scan the first made; aerial coverage fills and empties over many passes; the pre-draw
## net plants a late jump's near ring, also while aerial coverage is still filling, carries a pass
## on while the tree is paused (a quality change from the pause menu) and is timed for fp_bench; a
## camera under a moved parent streams at its global spot; chunks without trees are planted too;
## orbit is left alone. The one windowed-only check reads the layers' buffers back against the
## spots they were planted from.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const G := preload("res://tools/tests/fp_tree_geom.gd")
## A pass budget no pass spends (ms): whole passes, so the checks do not depend on the clock.
const UNMETERED := 1.0e9
const STEP := CityView.TREE_STREAM_HYSTERESIS

var fails: Array[String] = []
var holder: Node3D
var sim: CitySim
var cam: Camera3D
var view: CityView
var web := 0.55


func _init() -> void:
	K.watchdog(self, "FP_TREE_COST_TEST")
	await process_frame
	_fixture()
	await _check_settled()
	_check_trigger()
	_check_band()
	_check_budget()
	await _check_scans()
	_check_aerial_spread()
	_check_churn()
	await _check_frame_loop()
	await _check_pre_draw()
	_check_predraw_timing()
	await _check_parented_camera()
	await _check_empty_chunks()
	await _check_mode_settled()
	await _check_orbit()
	await _check_buffer_content()
	K.finish(self, "FP_TREE_COST_TEST", fails)


# ------------------------------------------------------------------ fixture and helpers


## A grown city, a street camera at the spawn and a CityView on foot at the web tier's vis_mult.
func _fixture() -> void:
	web = Q.vis_mult("low", true)
	holder = Node3D.new()
	holder.name = "TreeCostKit"
	get_root().add_child(holder)
	var made := K.make_sim(holder, 7)
	sim = made["sim"]
	K.grow(sim, made["people"], 40)
	sim.set_speed(0)
	cam = Camera3D.new()
	cam.name = "CostCamera"
	holder.add_child(cam)
	cam.position = _eye(G.SPAWN)
	view = CityView.new()
	view.name = "CityView"
	holder.add_child(view)
	view.fp_mode = true
	view.vis_mult = web
	view.tree_stream_budget_ms = UNMETERED
	view.setup(sim, cam)


func _eye(p: Vector2) -> Vector3:
	return Vector3(p.x, 1.6, p.y)


## How many planted chunks are in neither `before` nor `skip`.
func _fresh_since(before: Array[Vector3i], skip: Array[Vector3i] = []) -> int:
	var n := 0
	for c in G.planted(view):
		n += 0 if before.has(c) or skip.has(c) else 1
	return n


## Runs stream passes until one leaves nothing to do; returns their number.
func _drain() -> int:
	var n := 0
	while not view._tree_stream_done and n < 400:
		view._stream_trees()
		n += 1
	return n


## Camera to p, then passes until the pool has settled on it.
func _go(p: Vector2) -> void:
	cam.position = _eye(p)
	view._stream_trees()
	_drain()


## Chunk -> the instance ids of its layers.
func _ids() -> Dictionary:
	var out := {}
	for c: Vector3i in view._tree_chunks.keys():
		out[c] = (view._tree_chunks[c] as Array).map(
			func(n: Node) -> int: return n.get_instance_id()
		)
	return out


## How many chunks of `before` (chunk -> ids) are planted again with other nodes.
func _recreated(before: Dictionary) -> int:
	var n := 0
	for c: Vector3i in before.keys():
		if view._tree_chunks.has(c):
			var now: Array = (view._tree_chunks[c] as Array).map(
				func(k: Node) -> int: return k.get_instance_id()
			)
			n += 0 if now == before[c] else 1
	return n


# ------------------------------------------------------------------ passes and the window's edge


## setup() plants the window and marks the forest tiles it rebuilt dirty (the plant already read
## them): the frames after it replant no chunk.
func _check_settled() -> void:
	_drain()
	var before := _ids()
	await process_frame
	await process_frame
	var churn := _recreated(before)
	var msg := "the frames after setup recreate no chunk (%d of %d)" % [churn, before.size()]
	K.check(fails, churn == 0 and not before.is_empty(), msg)


## A pass runs only once the camera moved a hysteresis step from the last one.
func _check_trigger() -> void:
	_go(G.SPAWN)
	var at: Vector2 = view._tree_stream_at
	var n: int = view._tree_chunks.size()
	cam.position = _eye(G.SPAWN + Vector2(STEP * 0.75, 0.0))
	view._stream_trees()
	K.check(fails, view._tree_stream_at == at, "a camera step under the hysteresis runs no pass")
	cam.position = _eye(G.SPAWN + Vector2(STEP * 1.25, 0.0))
	view._stream_trees()
	K.check(fails, view._tree_stream_at != at, "a step past it runs one")
	_go(G.SPAWN)
	var msg := "and the pool stays the size of the window"
	K.check(fails, absi(view._tree_chunks.size() - n) < 12, msg)


## After a pass the chunks past the window by less than a hysteresis step stay planted (a camera
## wobbling on the window's edge must not plant and free the same chunks again and again); only
## those past window + step go.
func _check_band() -> void:
	_go(G.SPAWN)
	var win := G.window(web)
	var p2 := G.SPAWN
	var band: Array[Vector3i] = []
	var beyond: Array[Vector3i] = []
	for travel in [STEP * 1.25, STEP * 2.0, STEP * 2.5, STEP * 3.0]:
		p2 = G.SPAWN + Vector2(travel, 0.0)
		band.clear()
		beyond.clear()
		for c in G.planted(view):
			var d := G.dist(c, p2)
			if d > win + 0.05 and d <= win + STEP - 0.05:
				band.append(c)
			elif d > win + STEP + 0.05:
				beyond.append(c)
		if not band.is_empty() and not beyond.is_empty():
			break
	K.check(
		fails,
		not band.is_empty() and not beyond.is_empty(),
		"fixture: %d chunks in the band, %d past it" % [band.size(), beyond.size()]
	)
	cam.position = _eye(p2)
	view._stream_trees()
	_drain()
	var kept := 0
	for c in band:
		kept += 1 if view._tree_chunks.has(c) else 0
	var left := 0
	for c in beyond:
		left += 1 if view._tree_chunks.has(c) else 0
	K.check(
		fails,
		kept == band.size(),
		"the band stays planted after a pass (%d of %d)" % [kept, band.size()]
	)
	K.check(fails, left == 0, "the chunks past window + step are freed (%d left)" % left)
	_go(G.SPAWN)


# ------------------------------------------------------------------ budget and caps


## The budget: past the near ring (always planted in full) a pass plants chunks until it is spent,
## one at least, TREE_STREAM_CAP at most. At zero that is exactly one chunk a pass; unmetered it
## is the cap; the ring is whole either way. The unit is pinned from both sides: the ring alone
## takes far longer than 0.1 ms, so a pass at 0.1 ms plants one chunk past it (a budget read as
## seconds would plant a cap), and 500 ms is never spent, so a pass plants a cap (a budget read
## as microseconds would plant one). The default stays a few ms, the rebuild queue's own.
func _check_budget() -> void:
	var cap := CityView.TREE_STREAM_CAP
	var approved := "the caps stay the approved ones: plant %d (16 at most), free %d (not more)"
	K.check(
		fails, cap <= 16 and CityView.TREE_FREE_CAP <= cap, approved % [cap, CityView.TREE_FREE_CAP]
	)
	var probe := CityView.new()
	var dflt := probe.tree_stream_budget_ms
	probe.free()
	K.check(
		fails,
		dflt >= 1.0 and dflt <= 4.0,
		"the default budget is a few ms, as the rebuild queue's (%.1f ms)" % dflt
	)
	for budget: float in [0.0, 0.1, 500.0, UNMETERED]:
		view.tree_stream_budget_ms = budget
		_go(G.SPAWN)
		var ring := G.within(G.LANDING, G.ring(web))
		var before := G.planted(view)
		cam.position = _eye(G.LANDING)
		view._stream_trees()
		var fresh := _fresh_since(before, ring)
		var want := 1 if budget < 1.0 else cap
		var label := "budget %s ms" % str(budget)
		K.check(
			fails,
			G.has_all(view, ring),
			"%s: the near ring (%d chunks) is whole" % [label, ring.size()]
		)
		K.check(
			fails,
			fresh == want,
			"%s: %d chunks past the ring in the first pass (%d)" % [label, want, fresh]
		)
		# Later passes plant no ring, and a chunk without trees is planted in a few us, so a
		# small clock budget can plant several: only the two exact ones are checked here.
		var steady := true
		if budget == 0.0 or budget == UNMETERED:
			for _k in range(4 if budget == 0.0 else 2):
				before = G.planted(view)
				view._stream_trees()
				steady = steady and _fresh_since(before) == want
			K.check(fails, steady, "%s: and in every pass after it" % label)
		_drain()
		var window := G.within(G.LANDING, G.window(web))
		K.check(fails, G.has_all(view, window), "%s: the window fills in the end" % label)
	view.tree_stream_budget_ms = UNMETERED
	_go(G.SPAWN)


## The cost counter (CityView._tree_scanned): an idle frame, a walk step under the hysteresis and a
## wandering camera over a complete aerial coverage scan nothing; a pass that has to look scans the
## window's box, not the 729 cells of the map; and the passes that carry a fill on work off the
## lists the first one made (they would scan the same box again, a pass each frame).
func _check_scans() -> void:
	_go(G.SPAWN)
	await process_frame
	var n0: int = view._tree_scanned
	for _k in range(30):
		await process_frame
	K.check(fails, view._tree_scanned == n0, "30 idle frames scan nothing")
	cam.position = _eye(G.SPAWN + Vector2(STEP * 0.5, 0.0))
	for _k in range(3):
		await process_frame
	K.check(fails, view._tree_scanned == n0, "a step under the hysteresis scans nothing")
	view.set_aerial(true)
	_drain()
	n0 = view._tree_scanned
	for p: Vector2 in [G.SPAWN + Vector2(30.0, 0.0), G.CORNER, G.LANDING, G.SPAWN]:
		cam.position = _eye(p)
		view._stream_trees()
		await process_frame
	var msg := "aerial coverage complete (%d chunks): a wandering camera scans nothing"
	K.check(fails, view._tree_scanned == n0 and view._tree_chunks.size() == G.FULL, msg % G.FULL)
	view.set_aerial(false)
	_drain()
	_go(G.SPAWN)
	view.tree_stream_budget_ms = 0.0
	n0 = view._tree_scanned
	var planted: int = view._tree_chunks.size()
	cam.position = _eye(G.LANDING)
	view._stream_trees()
	var first: int = view._tree_scanned - n0
	var box := ceili(2.0 * G.window(web) / CityView.TREE_CHUNK_FP) + 2
	msg = "a pass that looks scans the window's box and the planted chunks (%d, at most %d)"
	K.check(fails, first > 0 and first <= box * box + planted, msg % [first, box * box + planted])
	var held := G.planted(view)
	for _k in range(8):
		view._stream_trees()
	msg = "the 8 passes that carry the fill on scan nothing more (%d) and plant 8 chunks (%d)"
	var fresh := _fresh_since(held)
	K.check(
		fails,
		view._tree_scanned - n0 == first and fresh == 8,
		msg % [view._tree_scanned - n0 - first, fresh]
	)
	view.tree_stream_budget_ms = UNMETERED
	_go(G.SPAWN)


## Aerial coverage plants the whole map and drops it again over many passes, never one: at most
## TREE_STREAM_CAP planted and TREE_FREE_CAP freed a pass, the farthest chunks freed first.
func _check_aerial_spread() -> void:
	var cap := CityView.TREE_STREAM_CAP
	var n0: int = view._tree_chunks.size()
	view.set_aerial(true)
	var worst: int = view._tree_chunks.size() - n0
	var passes := 1
	while not view._tree_stream_done and passes < 400:
		var before: int = view._tree_chunks.size()
		view._stream_trees()
		worst = maxi(worst, view._tree_chunks.size() - before)
		passes += 1
	K.check(
		fails, worst <= cap, "aerial: no pass plants more than the cap (%d, cap %d)" % [worst, cap]
	)
	var least := ceili(float(G.FULL - n0) / cap)
	K.check(
		fails,
		passes >= least,
		"aerial: the map fills over %d passes, not fewer than %d" % [passes, least]
	)
	K.check(
		fails,
		view._tree_chunks.size() == G.FULL,
		"aerial: all %d chunks" % view._tree_chunks.size()
	)
	var free_cap := CityView.TREE_FREE_CAP
	var win := G.window(web) + STEP
	var stay := G.within(G.SPAWN, win).size()
	var before := G.planted(view)
	view.set_aerial(false)
	var most := 0
	var order := true
	passes = 1
	while passes < 400:
		var freed := before.filter(func(c: Vector3i) -> bool: return not view._tree_chunks.has(c))
		var far := before.filter(
			func(c: Vector3i) -> bool: return view._tree_chunks.has(c) and G.dist(c, G.SPAWN) > win
		)
		most = maxi(most, freed.size())
		for f in freed:
			for k in far:
				order = order and G.dist(f, G.SPAWN) >= G.dist(k, G.SPAWN) - G.EPS
		if view._tree_stream_done:
			break
		before = G.planted(view)
		view._stream_trees()
		passes += 1
	var msg := "aerial off: %d passes, none frees more than %d chunks (%d)"
	K.check(
		fails,
		most <= free_cap and passes >= ceili(float(G.FULL - stay) / free_cap),
		msg % [passes, free_cap, most]
	)
	K.check(fails, order, "aerial off: a pass frees the farthest chunks first")
	K.check(
		fails, G.has_all(view, G.within(G.SPAWN, G.window(web))), "aerial off: the window is whole"
	)
	K.check(
		fails,
		view._tree_chunks.size() <= stay,
		"aerial off: back on the window (%d chunks)" % view._tree_chunks.size()
	)
	_go(G.SPAWN)


## A pass keeps the nodes of the chunks that stay: a walk step and a vis_mult change replant
## nothing that is in the window before and after.
func _check_churn() -> void:
	_go(G.SPAWN)
	var before := _ids()
	cam.position = _eye(G.SPAWN + Vector2(STEP * 1.25, 0.0))
	view._stream_trees()
	_drain()
	var kept := 0
	for c: Vector3i in before.keys():
		kept += 1 if view._tree_chunks.has(c) else 0
	var msg := "a step past the hysteresis keeps most of the pool (%d chunks), recreates %d"
	var churn := _recreated(before)
	K.check(fails, kept > 20 and churn == 0, msg % [kept, churn])
	_go(G.SPAWN)
	before = _ids()
	view.vis_mult = Q.vis_mult("low", false)
	_drain()
	var grown: int = view._tree_chunks.size()
	churn = _recreated(before)
	var same := "vis_mult %.2f to %.2f: the pool grows to %d chunks, %d of %d recreated"
	K.check(
		fails,
		grown > before.size() and churn == 0,
		same % [web, view.vis_mult, grown, churn, before.size()]
	)
	view.vis_mult = web
	_drain()
	_go(G.SPAWN)


# ------------------------------------------------------------------ frames


## The frame loop alone keeps the window on the camera, at the default budget (the clock, not a
## count, decides how many chunks a frame plants): the frame after a jump has the near ring, the
## next few the window, and the pool left behind is freed after that.
func _check_frame_loop() -> void:
	var probe := CityView.new()
	view.tree_stream_budget_ms = probe.tree_stream_budget_ms
	probe.free()
	_go(G.SPAWN)
	cam.position = _eye(G.CORNER)
	await process_frame
	var ring := G.within(G.CORNER, G.ring(web))
	K.check(fails, G.has_all(view, ring), "a frame after a jump: _process planted the near ring")
	var window := G.within(G.CORNER, G.window(web))
	var frames := 0
	var capped := true
	while not G.has_all(view, window) and frames < 200:
		var before := G.planted(view)
		await process_frame
		capped = capped and _fresh_since(before) <= CityView.TREE_STREAM_CAP
		frames += 1
	K.check(
		fails,
		G.has_all(view, window) and capped,
		"%d frames fill the window, at most a cap a frame" % frames
	)
	while not view._tree_stream_done and frames < 400:
		await process_frame
		frames += 1
	K.check(
		fails,
		view._tree_stream_done,
		"and the pool left behind is freed (%d frames in all)" % frames
	)
	view.tree_stream_budget_ms = UNMETERED
	_go(G.SPAWN)


## The pre-draw net (the render server calls _on_pre_draw before each draw; the headless server
## never does, so the checks call it where it would run): a jump after _process has its near ring
## in the frame that shows it, also while aerial coverage is still filling; no second pass in a
## frame that ran one; and a pass left unfinished carries on while the tree is paused.
func _check_pre_draw() -> void:
	view.set_aerial(true)
	K.check(fails, not view._tree_stream_done, "fixture: the aerial fill-in is under way")
	cam.position = _eye(G.CORNER)
	view._on_pre_draw()
	var ring := G.within(G.CORNER, G.ring(web))
	K.check(
		fails,
		G.has_all(view, ring),
		"aerial fill-in, a jump after _process: the ring is planted before the draw"
	)
	var n: int = view._tree_chunks.size()
	view._on_pre_draw()
	K.check(fails, view._tree_chunks.size() == n, "no second pass in a frame that already ran one")
	await process_frame
	n = view._tree_chunks.size()
	view._on_pre_draw()
	K.check(
		fails, view._tree_chunks.size() > n, "a frame without a pass carries the unfinished one on"
	)
	view.set_aerial(false)
	_go(G.SPAWN)
	await _paused_quality_change()


## The pre-draw pass is a hitch of its own (a late jump plants the near ring there, several ms), and
## it runs outside the _process section the bench times: it is timed as "trees_predraw" in
## section_us_max (fp_bench's hitch rows list every key). A frame with nothing to do records none.
func _check_predraw_timing() -> void:
	_go(G.SPAWN)
	view.reset_section_stats()
	view._on_pre_draw()
	var idle := not view.section_us_max.has("trees_predraw")
	K.check(fails, idle, "an idle pre-draw pass records nothing")
	cam.position = _eye(G.CORNER)
	view._on_pre_draw()
	var us := int(view.section_us_max.get("trees_predraw", 0))
	K.check(fails, us > 0, "a pre-draw pass that plants is timed as trees_predraw (%d us)" % us)
	_go(G.SPAWN)


## The pause menu's quality row applies while the tree is paused: CityView._process does not run,
## so the pass the setter started is finished by the pre-draw net, one pass a frame.
func _paused_quality_change() -> void:
	var high := Q.vis_mult("high", false)
	# A windowed run has the render server call the net itself; here only the checks do.
	var wired := RenderingServer.frame_pre_draw.is_connected(view._on_pre_draw)
	if wired:
		RenderingServer.frame_pre_draw.disconnect(view._on_pre_draw)
	paused = true
	view.vis_mult = high
	var window := G.within(G.SPAWN, G.window(high))
	var stalled: int = view._tree_chunks.size()
	for _k in range(3):
		await process_frame
	K.check(
		fails,
		view._tree_chunks.size() == stalled and not G.has_all(view, window),
		"paused: _process plants nothing"
	)
	var frames := 0
	while not view._tree_stream_done and frames < 100:
		await process_frame
		view._on_pre_draw()
		frames += 1
	paused = false
	if wired:
		RenderingServer.frame_pre_draw.connect(view._on_pre_draw)
	var msg := "paused: the pre-draw net finishes the new window (%d chunks) in %d frames"
	K.check(
		fails, G.has_all(view, window) and view._tree_stream_done, msg % [window.size(), frames]
	)
	view.vis_mult = web
	_drain()
	_go(G.SPAWN)


# ------------------------------------------------------------------ inputs of the window


## The hero's camera is a child of a moving body: the window follows its global spot.
func _check_parented_camera() -> void:
	var rig := Node3D.new()
	rig.position = Vector3(G.LANDING.x, 0.0, G.LANDING.y)
	holder.add_child(rig)
	var hero := Camera3D.new()
	rig.add_child(hero)
	hero.position = Vector3(0.0, 1.6, 0.0)
	view.set_camera(hero)
	var msg := "a camera under a moved parent: the near ring is planted at its global spot"
	K.check(fails, G.has_all(view, G.within(G.LANDING, G.ring(web))), msg)
	_drain()
	rig.position = Vector3(G.CORNER.x, 0.0, G.CORNER.y)
	view._stream_trees()
	K.check(
		fails,
		G.has_all(view, G.within(G.CORNER, G.ring(web))),
		"and the ring follows the parent when it moves"
	)
	view.set_camera(cam)
	rig.queue_free()
	_go(G.SPAWN)
	await process_frame


## A chunk whose last forest tile is cleared is planted empty, not left out: out of the pool it
## would be spotted again by every pass. Cleared inside the window it replants empty next frame;
## cleared outside it, it streams in empty. The forest comes back after.
func _check_empty_chunks() -> void:
	var c := _forest_chunk()
	K.check(fails, c.x >= 0, "a chunk with forest tiles in the web window exists (%s)" % str(c))
	if c.x < 0:
		return
	var kinds := {}
	for i in G.tiles(c):
		kinds[i] = sim.kind[i]
		if sim.kind[i] == D.FOREST:
			sim.kind[i] = D.EMPTY
	view._dirty_tree_chunks[c] = true
	await process_frame
	await process_frame
	var planted: Array = view._tree_chunks.get(c, [])
	var msg := "cleared in the window: planted again, with no layer (%d)" % planted.size()
	K.check(fails, view._tree_chunks.has(c) and planted.is_empty(), msg)
	_go(G.CORNER)
	K.check(fails, not view._tree_chunks.has(c), "out of the window it is freed")
	_go(G.SPAWN)
	K.check(
		fails,
		view._tree_chunks.has(c) and (view._tree_chunks[c] as Array).is_empty(),
		"streamed in it is empty and registered"
	)
	for i: int in kinds.keys():
		sim.kind[i] = kinds[i]
	view._dirty_tree_chunks[c] = true
	await process_frame
	await process_frame
	K.check(
		fails,
		not (view._tree_chunks[c] as Array).is_empty(),
		"the forest is back after it is restored"
	)


## The chunk of the web window with the most forest tiles (nearest the spawn on a tie).
func _forest_chunk() -> Vector3i:
	var best := Vector3i(-1, -1, 1)
	var most := 0
	for c in G.within(G.SPAWN, G.window(web)):
		var n := 0
		for i in G.tiles(c):
			n += 1 if sim.kind[i] == D.FOREST else 0
		if n > most:
			best = c
			most = n
	return best


## Switching mode plants the pool once. The world is rebuilt first (rebuild_all marks every forest
## chunk dirty, as it does in setup()) and the plant after it clears those marks, so a frame later
## nothing is replanted: leaving the street (the orbit chunks) and entering it again (the window).
func _check_mode_settled() -> void:
	view.set_fp_mode(false)
	var orbit := _ids()
	await process_frame
	await process_frame
	var churn := _recreated(orbit)
	var msg := "leaving the street: the frames after recreate no orbit chunk (%d of %d)"
	K.check(fails, churn == 0 and orbit.size() == 25, msg % [churn, orbit.size()])
	cam.position = _eye(G.SPAWN)
	view.set_fp_mode(true)
	_drain()
	var street := _ids()
	await process_frame
	await process_frame
	churn = _recreated(street)
	msg = "entering the street: the frames after recreate no chunk (%d of %d)"
	K.check(fails, churn == 0 and not street.is_empty(), msg % [churn, street.size()])


## What orbit holds, as data: per chunk every layer's ends, margins, centre and count.
func _orbit_state() -> Dictionary:
	var out := {}
	for c: Vector3i in view._tree_chunks.keys():
		out[c] = (view._tree_chunks[c] as Array).map(
			func(n: MultiMeshInstance3D) -> Array:
				return [
					n.visibility_range_begin,
					n.visibility_range_end,
					n.visibility_range_begin_margin,
					n.visibility_range_end_margin,
					n.position,
					n.multimesh.instance_count
				]
		)
	return out


## Orbit streams nothing and ranges nothing: the camera, vis_mult and aerial coverage leave its 25
## chunks as they are.
func _check_orbit() -> void:
	view.set_fp_mode(false)
	await process_frame
	var before := _orbit_state()
	cam.position = _eye(G.CORNER)
	view.vis_mult = 0.7
	view._stream_trees()
	view.set_aerial(true)
	view.set_aerial(false)
	await process_frame
	K.check(
		fails,
		view._tree_chunks.size() == 25 and not before.is_empty(),
		"orbit: the 25 chunks of 48 tiles"
	)
	K.check(fails, _orbit_state() == before, "orbit: camera, vis_mult and aerial change no layer")
	view.vis_mult = web
	cam.position = _eye(G.SPAWN)
	view.set_fp_mode(true)
	_drain()
	await process_frame


# ------------------------------------------------------------------ buffers


## WINDOWED RUNS ONLY (the headless server keeps no instance data): the transforms a layer holds are
## the spots' own, relative to the layer's node, times the part's transform - the oracle is
## computed here from the spots, not by the code that wrote them, so a plant that displaced its
## trees (both the streamed and the full path alike) shows.
func _check_buffer_content() -> void:
	if DisplayServer.get_name() == "headless":
		print("  info layer buffers are checked in windowed runs only: skipped")
		return
	_go(G.SPAWN)
	var checked := 0
	var off := 0
	for c in G.within(G.SPAWN, G.ring(web)):
		var by_kit: Array = view._tree_chunk_spots(c)
		var every: Array = []
		for spots: Array in by_kit:
			every.append_array(spots)
		var layers: Array = view._tree_chunks.get(c, [])
		var at := 0
		for ki in range(view._tree_kits.size()):
			if (by_kit[ki] as Array).is_empty():
				continue
			for part: Dictionary in view._tree_kits[ki]:
				off += _layer_off(layers[at], by_kit[ki], part)
				at += 1
				checked += 1
		for part: Dictionary in view._far_tree_parts:
			if not every.is_empty():
				off += _layer_off(layers[at], every, part)
				at += 1
				checked += 1
	var msg := "%d layers read back: every instance sits where its spot and part put it (%d off)"
	K.check(fails, checked > 0 and off == 0, msg % [checked, off])


## How many instances of layer n are not at their spot's world transform times the part's. A row of
## the buffer starts with the instance's 12 transform floats, whatever follows (colour, custom).
func _layer_off(n: MultiMeshInstance3D, spots: Array, part: Dictionary) -> int:
	var buf := n.multimesh.buffer
	var count := maxi(spots.size(), 1)
	var stride := floori(float(buf.size()) / float(count))
	var off := 0
	if stride < 12 or buf.size() != stride * count:
		return count
	for k in range(spots.size()):
		var b := k * stride
		var rows := Basis(
			Vector3(buf[b], buf[b + 4], buf[b + 8]),
			Vector3(buf[b + 1], buf[b + 5], buf[b + 9]),
			Vector3(buf[b + 2], buf[b + 6], buf[b + 10])
		)
		var local := Transform3D(rows, Vector3(buf[b + 3], buf[b + 7], buf[b + 11]))
		var world := Transform3D(Basis(), n.position) * local
		var t: Transform3D = spots[k]
		var want := Transform3D(t.basis, t.origin) * (part["xform"] as Transform3D)
		var ok := (
			world.origin.distance_to(want.origin) < 1e-3 and world.basis.is_equal_approx(want.basis)
		)
		off += 0 if ok else 1
	return off
