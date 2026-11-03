extends SceneTree
## On-foot tree streaming (CityView._stream_trees): the old plant kept all 729 chunks of the 27 x 27
## grid (~8.7k MultiMeshInstance3D) in the tree from boot, now only the chunks that can draw exist.
## Checks: the pool stays bounded by the window at every preset (web tier included); the window
## covers the far edge + range margin + chunk half-diagonal + hysteresis, so a far tree's pop is
## always its range, never a missing chunk (walked against the real layer AABB centres, and the
## bound against the lone-tile layouts that push it); a teleport never leaves the near ring bare;
## a chunk streamed back in is the chunk a full plant makes (after a rebuild too, reading sim.kind
## as it is then); near and far layers keep one centre; aerial plants every chunk and the pool
## shrinks back; vis_mult or a new camera re-streams; orbit keeps its 25 chunks; nothing leaks.
## How the work is spread over frames (budget, caps, pre-draw net) is fp_tree_cost_test.gd's; what
## the pool holds against oracles outside the plant code (tree counts, random poses, the map's
## edges, where the aerial fill starts) is fp_tree_pool_test.gd's.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const G := preload("res://tools/tests/fp_tree_geom.gd")
## A pass budget no pass spends (ms): whole passes, so the checks do not depend on the clock.
const UNMETERED := 1.0e9
## Preset name -> web tier on (the "web" row is web Low: vis_mult 0.55, the default tier).
const PRESETS := {"web": true, "low": false, "medium": false, "high": false}

var fails: Array[String] = []
var view: CityView
var sim: CitySim
var cam: Camera3D
var holder: Node3D
var keys: Array[Vector3i] = []
var active := {}
## Chunk -> its layers' visibility points ([Vector2, is_far]), cached (v-independent).
var vis_points := {}
## Layer buffers read back by _buffer_hash (none under the headless dummy renderer).
var buffers_seen := 0


func _init() -> void:
	K.watchdog(self, "FP_TREE_STREAM_TEST")
	await process_frame
	_fixture()
	var grid := "the FP tree grid is the test's %d chunks (%d)" % [G.FULL, keys.size()]
	K.check(fails, keys == G.grid() and keys.size() == G.FULL, grid)
	_check_radii()
	await _check_boot()
	await _check_presets()
	_check_reach_bound()
	_check_lone_tiles()
	await _check_walk()
	_check_approach()
	await _check_teleport()
	await _check_replant()
	await _check_cleared()
	await _check_layers()
	await _check_aerial()
	await _check_mode_switch()
	await _check_reference()
	K.finish(self, "FP_TREE_STREAM_TEST", fails)


# ------------------------------------------------------------------ fixture and helpers


## A grown city, a street camera at the spawn and a CityView on foot at the web tier's vis_mult.
func _fixture() -> void:
	holder = Node3D.new()
	holder.name = "TreeStreamKit"
	get_root().add_child(holder)
	var made := K.make_sim(holder, 7)
	sim = made["sim"]
	K.grow(sim, made["people"], 40)
	sim.set_speed(0)
	for i in sim.active:
		active[i] = true
	cam = Camera3D.new()
	cam.name = "StreamCamera"
	holder.add_child(cam)
	cam.position = _eye(G.SPAWN)
	view = _new_view(cam, Q.vis_mult("low", true), false)
	var hi := view._tree_chunk_of(
		D.X0 + D.W + CityView.TREE_RING - 1, D.Y0 + D.H + CityView.TREE_RING - 1, 1
	)
	for cy in range(hi.y + 1):
		for cx in range(hi.x + 1):
			keys.append(Vector3i(cx, cy, 1))


func _new_view(camera: Camera3D, vis: float, aerial: bool) -> CityView:
	var v := CityView.new()
	v.name = "CityView"
	holder.add_child(v)
	v.fp_mode = true
	v.aerial_trees = aerial
	v.vis_mult = vis
	v.tree_stream_budget_ms = UNMETERED
	v.setup(sim, camera)
	return v


func _eye(p: Vector2) -> Vector3:
	return Vector3(p.x, 1.6, p.y)


func _info(msg: String) -> void:
	print("  info " + msg)


## True when every planted chunk is in a.
func _only_in(a: Array[Vector3i]) -> bool:
	for c: Vector3i in view._tree_chunks.keys():
		if not a.has(c):
			return false
	return true


## Moves the camera and runs stream passes, one per frame, until a pass leaves nothing to do.
## Returns the number of passes.
func _go(p: Vector2) -> int:
	cam.position = _eye(p)
	view._stream_trees()
	return 1 + _finish()


func _finish() -> int:
	return _drain(view)


## Runs stream passes on v until one leaves nothing to do; returns their number.
func _drain(v: CityView) -> int:
	var n := 0
	while not v._tree_stream_done and n < 400:
		v._stream_trees()
		n += 1
	return n


## MultiMeshInstance3D nodes under the Trees root that are not queued for deletion.
func _mmis(v: CityView) -> int:
	var n := 0
	for k in v._trees_root.get_children():
		if k is MultiMeshInstance3D and not k.is_queued_for_deletion():
			n += 1
	return n


func _layer_total(v: CityView) -> int:
	var n := 0
	for layers: Array in v._tree_chunks.values():
		n += layers.size()
	return n


## Every MMI under Trees belongs to a planted chunk and nothing else hangs there.
func _tidy(v: CityView) -> bool:
	return _mmis(v) == _layer_total(v) and v._trees_root.get_child_count() == _mmis(v)


## The Trees root and every node under it, to prove them freed after a rebuild or a mode switch.
func _hold(v: CityView) -> Array:
	var out: Array = [v._trees_root]
	out.append_array(v._trees_root.get_children())
	return out


func _freed(held: Array) -> int:
	var n := 0
	for o in held:
		n += 0 if is_instance_valid(o) else 1
	return n


func _nodes(n: Node) -> int:
	var c := 1
	for k in n.get_children():
		c += _nodes(k)
	return c


## SHA-256 of the instance data a layer holds (every transform and colour as the renderer keeps it),
## "" when the renderer keeps none: the headless dummy server stores no instance data, so only a
## windowed run of this test compares the buffers themselves (buffers_seen counts them).
func _buffer_hash(n: MultiMeshInstance3D) -> String:
	var buf := n.multimesh.buffer
	if buf.is_empty():
		return ""
	buffers_seen += 1
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.to_byte_array())
	return ctx.finish().hex_encode()


## What a planted chunk is, as data: per layer the count, centre, ranges and buffer. With
## no_far_end the far layers' ends (and margins) are left out: aerial coverage lifts them.
func _fingerprint(v: CityView, c: Vector3i, no_far_end: bool = false) -> Array:
	var out: Array = []
	for n: MultiMeshInstance3D in v._tree_chunks.get(c, []):
		var row: Array = [n.multimesh.instance_count, n.multimesh.use_colors, n.position]
		row.append_array([n.visibility_range_begin, n.visibility_range_begin_margin, n.cast_shadow])
		row.append(_buffer_hash(n))
		if not (no_far_end and n.visibility_range_begin > 0.0):
			row.append_array([n.visibility_range_end, n.visibility_range_end_margin])
		out.append(row)
	return out


func _forest_tiles(c: Vector3i, active_only: bool) -> Array[int]:
	var out: Array[int] = []
	for i in G.tiles(c):
		if sim.kind[i] == D.FOREST and (not active_only or active.has(i)):
			out.append(i)
	return out


## The chunk nearest the spawn with at least `need` forest tiles the view tracks (active ones).
func _forest_chunk(need: int) -> Vector3i:
	var best := Vector3i(-1, -1, 1)
	for c in keys:
		if (
			_forest_tiles(c, true).size() >= need
			and (best.x < 0 or G.dist(c, G.SPAWN) < G.dist(best, G.SPAWN))
		):
			best = c
	return best


func _far_layers(c: Vector3i) -> Array[MultiMeshInstance3D]:
	var out: Array[MultiMeshInstance3D] = []
	for n: MultiMeshInstance3D in view._tree_chunks.get(c, []):
		if n.visibility_range_begin > 0.0:
			out.append(n)
	return out


## True when every far layer of chunk c carries exactly n trees (the far layers carry them all).
func _far_counts(c: Vector3i, n: int) -> bool:
	var far := _far_layers(c)
	var ok := not far.is_empty()
	for layer in far:
		ok = ok and layer.multimesh.instance_count == n
	return ok


## The radius of the stream window per preset, and Skyline's condition: it must exceed the far
## layers' far edge (50 u x vis_mult) plus the hysteresis (and the range margin and the chunk's
## half-diagonal). A bare view reads it: the radius needs no world.
func _check_radii() -> void:
	var probe := CityView.new()
	probe.fp_mode = true
	for p: String in PRESETS.keys():
		var v := Q.vis_mult(_preset_of(p), bool(PRESETS[p]))
		probe.vis_mult = v
		var win: float = probe._tree_window()
		var ring: float = probe._tree_ring()
		var far_edge := CityView.TREE_FAR_FP * v
		var need := far_edge + CityView.TREE_STREAM_HYSTERESIS + CityView.TREE_MARGIN_FP + 6.1
		K.check(
			fails,
			win >= need,
			"%s: window %.2f u covers far edge %.1f u + margins" % [p, win, far_edge]
		)
		K.check(
			fails,
			absf(win - G.window(v)) < 0.01 and absf(ring - G.ring(v)) < 0.01,
			"%s: window and ring follow the documented radius" % p
		)
		K.check(fails, ring < win, "%s: the near ring (%.2f u) lies inside the window" % [p, ring])
		_info("stream radius %s (vis_mult %.2f): window %.2f u, ring %.2f u" % [p, v, win, ring])
	probe.aerial_trees = true
	K.check(fails, probe._tree_window() < 0.0, "aerial coverage wants every chunk (no radius)")
	probe.free()


func _check_boot() -> void:
	var web := Q.vis_mult("low", true)
	var first: int = view._tree_chunks.size()
	var ring_ok := G.has_all(view, G.within(G.SPAWN, G.ring(web)))
	await process_frame
	K.check(fails, ring_ok, "boot: the near ring is planted by setup itself")
	K.check(
		fails,
		first <= G.within(G.SPAWN, G.ring(web)).size() + CityView.TREE_STREAM_CAP,
		"boot: the first pass plants the ring and one cap of fill-in (%d chunks)" % first
	)
	var passes := _finish()
	await process_frame
	var want := G.within(G.SPAWN, G.window(web))
	var got := G.planted(view)
	K.check(
		fails,
		got.size() == want.size() and G.has_all(view, want),
		"web boot: exactly the window's %d chunks (%d more passes)" % [want.size(), passes]
	)
	K.check(
		fails, _tidy(view), "web boot: %d MMIs, all in planted chunks, none stray" % _mmis(view)
	)
	_info("web boot: %d chunks, %d MMIs, %d nodes" % [got.size(), _mmis(view), _nodes(view)])


## The preset a row stands for: "web" is the default web tier, web Low (web tiers are per preset).
func _preset_of(row: String) -> String:
	return "low" if row == "web" else row


## Every preset: the planted set is the window (a superset up to the hysteresis step after a
## shrink), the MMI count follows it, and a vis_mult change re-streams a camera standing still.
func _check_presets() -> void:
	var at: Vector2 = view._tree_stream_at
	var sizes := {}
	for p: String in ["low", "medium", "high", "web"]:
		var v := Q.vis_mult(_preset_of(p), bool(PRESETS[p]))
		view.vis_mult = v
		_finish()
		await process_frame
		var lo := G.within(G.SPAWN, G.window(v))
		var hi := G.within(G.SPAWN, G.window(v) + CityView.TREE_STREAM_HYSTERESIS)
		sizes[p] = view._tree_chunks.size()
		var msg := "%s (%.2f): %d chunks planted, window %d, with the step %d"
		K.check(
			fails,
			G.has_all(view, lo) and _only_in(hi),
			msg % [p, v, sizes[p], lo.size(), hi.size()]
		)
		K.check(fails, _tidy(view), "%s: %d MMIs, none stray" % [p, _mmis(view)])
		_info("%s: %d chunks, %d MMIs, window %.1f u" % [p, sizes[p], _mmis(view), G.window(v)])
	var grows: bool = sizes["web"] < sizes["low"] and sizes["low"] < sizes["medium"]
	K.check(fails, grows and sizes["medium"] < sizes["high"], "the pool grows with vis_mult")
	K.check(fails, view._tree_stream_at == at, "the camera never moved: vis_mult alone re-streamed")


# ------------------------------------------------------------------ the window really covers


## Walks the camera in steps under the hysteresis: whenever a layer could still draw (the centre of
## its AABB within its end + range margin of the camera), its chunk is planted.
func _check_walk() -> void:
	for web in [true, false]:
		var v := Q.vis_mult("low", web)
		view.vis_mult = v
		var bare := 0
		for dir: float in [1.0, -1.0]:
			var step := Vector2(0.4, 0.25) * dir
			var p := Vector2(-60.0, -50.0) if dir > 0.0 else Vector2(100.0, 50.0)
			_go(p)
			for _k in range(400):
				p += step
				cam.position = _eye(p)
				view._stream_trees()
				bare += _bare(p, v)
		var msg := "walked 2 x 400 steps at vis_mult %.2f: nothing that can draw is missing (%d)"
		K.check(fails, bare == 0, msg % [v, bare])


## How many chunks with a layer that could draw at p (the camera within the layer's end + margin of
## the centre of its AABB) are not planted.
func _bare(p: Vector2, v: float) -> int:
	var n := 0
	var far := CityView.TREE_FAR_FP * v + CityView.TREE_MARGIN_FP
	for c in keys:
		if G.dist(c, p) > far + CityView.TREE_CHUNK_REACH + 1.0 or view._tree_chunks.has(c):
			continue
		for pt: Array in _layer_points(c):
			var end := CityView.TREE_FAR_FP if pt[1] else CityView.TREE_NEAR_FP
			if p.distance_to(pt[0]) <= end * v + CityView.TREE_MARGIN_FP:
				n += 1
				break
	return n


## Where the engine measures each layer of chunk c from - the centre of its AABB, the union of
## its instances' mesh bounds - as [Vector2, is_far] per layer. The near layers are the kits' parts,
## the far layers carry all trees.
func _layer_points(c: Vector3i) -> Array:
	if not vis_points.has(c):
		vis_points[c] = _layer_points_now(c)
	return vis_points[c]


## _layer_points for the world as it is now (sim.kind may have been changed since it was cached).
func _layer_points_now(c: Vector3i) -> Array:
	var by_kit: Array = view._tree_chunk_spots(c)
	var every: Array = []
	for spots: Array in by_kit:
		every.append_array(spots)
	var out: Array = []
	if not every.is_empty():
		for ki in range(view._tree_kits.size()):
			if (by_kit[ki] as Array).is_empty():
				continue
			for part: Dictionary in view._tree_kits[ki]:
				out.append([_aabb_centre(part, by_kit[ki]), false])
		for part: Dictionary in view._far_tree_parts:
			out.append([_aabb_centre(part, every), true])
	return out


func _aabb_centre(part: Dictionary, spots: Array) -> Vector2:
	var xf: Transform3D = part["xform"]
	var mesh_box := (part["mesh"] as Mesh).get_aabb()
	var box := AABB()
	for k in range(spots.size()):
		var t: Transform3D = spots[k]
		var b := (Transform3D(t.basis, t.origin) * xf) * mesh_box
		box = b if k == 0 else box.merge(b)
	var mid := box.get_center()
	return Vector2(mid.x, mid.z)


## The stream window assumes a layer's AABB centre lies within TREE_CHUNK_REACH of its chunk's
## middle. Checked over every layer of every chunk of this world with the real tree meshes: a new
## tree model with a wide or lopsided bound would show up here.
func _check_reach_bound() -> void:
	var worst := 0.0
	var layers := 0
	for c in keys:
		for pt: Array in _layer_points(c):
			worst = maxf(worst, G.mid(c).distance_to(pt[0]))
			layers += 1
	var msg := "all %d layers have their AABB centre within %.2f u of the chunk middle (worst %.2f)"
	K.check(
		fails, worst <= CityView.TREE_CHUNK_REACH, msg % [layers, CityView.TREE_CHUNK_REACH, worst]
	)


## The same bound for layouts this city does not have but a grown one can: a chunk whose only forest
## tile is one of its corners has its layers' AABB on that tile, as far off the chunk's middle as it
## goes. Every tile of a sample of interior chunks is the lone forest tile in turn (sim.kind is put
## back after).
func _check_lone_tiles() -> void:
	var worst := 0.0
	var layouts := 0
	for c in keys:
		var tiles := G.tiles(c)
		if (
			tiles.size() < CityView.TREE_CHUNK_FP * CityView.TREE_CHUNK_FP
			or c.x % 6 != 3
			or c.y % 6 != 3
		):
			continue
		var kinds: Array = tiles.map(func(i: int) -> int: return sim.kind[i])
		for i in tiles:
			sim.kind[i] = D.EMPTY
		for i in tiles:
			sim.kind[i] = D.FOREST
			for pt: Array in _layer_points_now(c):
				worst = maxf(worst, G.mid(c).distance_to(pt[0]))
			sim.kind[i] = D.EMPTY
			layouts += 1
		for k in range(tiles.size()):
			sim.kind[tiles[k]] = kinds[k]
	var msg := "%d lone-tile layouts: AABB centre within %.2f u of the middle (worst %.2f)"
	K.check(
		fails,
		layouts > 0 and worst <= CityView.TREE_CHUNK_REACH,
		msg % [layouts, CityView.TREE_CHUNK_REACH, worst]
	)


## Adversarial walks: straight at the far layers whose AABB centre lies farthest off their chunk's
## middle, from the side it leans to (so it comes into range soonest), at several phases of the pass
## cycle. Whenever such a layer could draw, its chunk is planted.
func _check_approach() -> void:
	var v := Q.vis_mult("low", true)
	view.vis_mult = v
	var reach := CityView.TREE_FAR_FP * v + CityView.TREE_MARGIN_FP
	var worst: Array = []
	for c in keys:
		for pt: Array in _layer_points(c):
			if pt[1]:
				worst.append([G.mid(c).distance_to(pt[0]), c, pt[0]])
	worst.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var bare := 0
	var walked := 0
	for e: Array in worst.slice(0, 10):
		var at: Vector2 = e[2]
		var lean := (at - G.mid(e[1])).normalized()
		for phase in range(8):
			var s := 55.0 + 0.5 * phase
			_go(at + lean * s)
			while s > 0.0:
				s -= 0.4
				var p := at + lean * s
				cam.position = _eye(p)
				view._stream_trees()
				walked += 1
				if p.distance_to(at) <= reach and not view._tree_chunks.has(e[1]):
					bare += 1
	var msg := "%d steps at the 10 most lopsided layers: nothing that can draw is missing (%d)"
	K.check(fails, bare == 0, msg % [walked, bare])
	_info("most lopsided far layer: AABB centre %.2f u off its chunk's middle" % worst[0][0])


## A jump across the map: the near ring is planted at once - at the larger presets it holds more
## chunks than a pass may fill in, so the cap must not apply to it - the stand-ins beyond it follow
## nearest first at most TREE_STREAM_CAP chunks a pass, and the chunks left behind are freed.
func _check_teleport() -> void:
	for p in ["web", "medium", "high"]:
		var v := Q.vis_mult(p, bool(PRESETS[p]))
		view.vis_mult = v
		_go(G.SPAWN)
		await process_frame
		var before := G.planted(view)
		cam.position = _eye(G.LANDING)
		view._stream_trees()
		var ring := G.within(G.LANDING, G.ring(v))
		var msg := "%s: frame 0 after a teleport, all %d near-ring chunks are planted"
		K.check(fails, G.has_all(view, ring), msg % [p, ring.size()])
		var fresh: Array[Vector3i] = []
		for c in G.planted(view):
			if not before.has(c) and not ring.has(c):
				fresh.append(c)
		var cap := CityView.TREE_STREAM_CAP
		K.check(
			fails,
			fresh.size() <= cap,
			"%s: the fill-in is capped (%d of %d)" % [p, fresh.size(), cap]
		)
		var waiting: Array[Vector3i] = []
		for c in G.within(G.LANDING, G.window(v)):
			if not view._tree_chunks.has(c):
				waiting.append(c)
		var order := "%s: the fill-in goes nearest first (%d chunks wait)" % [p, waiting.size()]
		K.check(fails, _nearest_first(fresh, waiting), order)
		var want := G.within(G.LANDING, G.window(v))
		var passes := 1
		while not G.has_all(view, want) and passes < 200:
			view._stream_trees()
			passes += 1
		_finish()
		await process_frame
		var fill := "%s: the window fills in %d passes (%d chunks, ring %d)"
		K.check(
			fails,
			G.has_all(view, want) and passes < 40,
			fill % [p, passes, want.size(), ring.size()]
		)
		var stale := 0
		for c in before:
			var out := G.dist(c, G.LANDING) > G.window(v) + CityView.TREE_STREAM_HYSTERESIS
			stale += 1 if out and view._tree_chunks.has(c) else 0
		K.check(fails, stale == 0, "%s: the chunks left behind are freed (%d left)" % [p, stale])
		if p != "web":
			K.check(
				fails,
				ring.size() > cap,
				"%s: the ring (%d) is wider than the cap" % [p, ring.size()]
			)
	view.vis_mult = Q.vis_mult("low", true)
	_go(G.SPAWN)


## True when no chunk of `fresh` lies farther from the landing than one of `waiting`.
func _nearest_first(fresh: Array[Vector3i], waiting: Array[Vector3i]) -> bool:
	for a in fresh:
		for b in waiting:
			if G.dist(a, G.LANDING) > G.dist(b, G.LANDING) + G.EPS:
				return false
	return true


## A chunk that streams back in after a long teleport or a world rebuild (what a load does) is
## exactly the chunk it was: street chunks around the spawn, and the ring woods at the map corner.
func _check_replant() -> void:
	view.vis_mult = Q.vis_mult("low", true)
	var street := G.within(G.SPAWN, 20.0)
	var woods: Array[Vector3i] = [Vector3i(26, 26, 1), Vector3i(25, 24, 1), Vector3i(26, 22, 1)]
	await _roundtrip("street", G.SPAWN, G.CORNER, street)
	await _roundtrip("ring woods", G.CORNER, G.SPAWN, woods)
	var before := {}
	_go(G.SPAWN)
	await process_frame
	for c in street:
		before[c] = _fingerprint(view, c)
	var held := _hold(view)
	view.setup(sim, cam)
	_go(G.SPAWN)
	await process_frame
	var same := true
	for c in street:
		same = same and _fingerprint(view, c) == before[c]
	K.check(
		fails,
		same,
		"after a world rebuild (setup, as a load does) the %d chunks are identical" % street.size()
	)
	K.check(
		fails,
		_tidy(view) and _freed(held) == held.size(),
		"the rebuild freed the old Trees root and its %d nodes, none stray" % (held.size() - 1)
	)


## Plants `picks` at home, streams them out by going away, and back in: identical, bit for bit.
func _roundtrip(label: String, home: Vector2, away: Vector2, picks: Array[Vector3i]) -> void:
	_go(home)
	await process_frame
	var before := {}
	for c in picks:
		before[c] = _fingerprint(view, c)
	var trees := 0
	for c in picks:
		trees += (view._tree_chunks.get(c, []) as Array).size()
	_go(away)
	var out := 0
	for c in picks:
		out += 0 if view._tree_chunks.has(c) else 1
	_go(home)
	await process_frame
	var same := true
	for c in picks:
		same = same and _fingerprint(view, c) == before[c]
	K.check(
		fails,
		trees > 0 and out == picks.size(),
		"%s: %d chunks (%d layers) leave the pool" % [label, picks.size(), trees]
	)
	K.check(fails, same, "%s: after a long teleport away and back they are identical" % label)


## A chunk with forest tiles streams out, some of them are cleared for building while it is out, and
## it streams back in without them. The count is checked against sim.kind itself: four trees on
## every forest tile, on every far stand-in layer.
func _check_cleared() -> void:
	view.vis_mult = Q.vis_mult("low", true)
	var c := _forest_chunk(4)
	K.check(fails, c.x >= 0, "a chunk with forest tiles in the city exists (%s)" % str(c))
	if c.x < 0:
		return
	var home := G.mid(c)
	_go(home)
	await process_frame
	var forest := _forest_tiles(c, false)
	K.check(
		fails,
		_far_counts(c, forest.size() * 4),
		"planted: four trees per forest tile (%d tiles)" % forest.size()
	)
	_go(G.CORNER)
	K.check(
		fails, not view._tree_chunks.has(c), "the chunk is out of the pool while its tiles change"
	)
	var mine := _forest_tiles(c, true)
	for k in range(2):
		sim.kind[mine[k]] = D.EMPTY
		view._build_tile(mine[k], false)
	K.check(fails, view._dirty_tree_chunks.has(c), "the view marked the chunk dirty")
	await process_frame
	K.check(
		fails,
		not view._tree_chunks.has(c) and view._dirty_tree_chunks.is_empty(),
		"outside the window a dirty chunk is dropped, not planted"
	)
	var left := _forest_tiles(c, false)
	K.check(
		fails,
		left.size() == forest.size() - 2,
		"two tiles are cleared (%d forest tiles left)" % left.size()
	)
	_go(home)
	await process_frame
	K.check(
		fails,
		_far_counts(c, left.size() * 4),
		"streamed back in: trees on the %d forest tiles left only" % left.size()
	)
	sim.kind[mine[2]] = D.EMPTY
	view._build_tile(mine[2], false)
	await process_frame
	K.check(
		fails,
		_far_counts(c, (left.size() - 1) * 4),
		"inside the window the dirty mark replants it next frame"
	)
	_go(G.SPAWN)


# ------------------------------------------------------------------ layers


## Each chunk's layers share one centre; the full trees end where the stand-ins begin and they
## stand in for each other at every distance: one solid layer, or a cross-fade of the two, never a
## gap and never both solid. A chunk planted after a vis_mult change equals one re-ranged by it.
func _check_layers() -> void:
	for p: String in PRESETS.keys():
		var v := Q.vis_mult(p, bool(PRESETS[p]))
		view.vis_mult = v
		_go(G.SPAWN)
		await process_frame
		var facts := _layer_facts(v)
		K.check(fails, facts["shared"], "%s: every layer of every chunk sits at one centre" % p)
		K.check(
			fails,
			facts["ranged"],
			"%s: full trees to %.1f u, stand-ins %.1f to %.1f u" % [p, 12.0 * v, 12.0 * v, 50.0 * v]
		)
		K.check(
			fails,
			facts["complement"],
			"%s: near and far layers complement each other (%d chunks)" % [p, facts["chunks"]]
		)
		var c := _first_with_trees()
		var kept := _fingerprint(view, c)
		view._refresh_tree_chunk(c)
		K.check(
			fails,
			_fingerprint(view, c) == kept,
			"%s: re-ranged layers equal freshly planted ones" % p
		)
	view.vis_mult = Q.vis_mult("low", true)
	_go(G.SPAWN)


func _first_with_trees() -> Vector3i:
	for c: Vector3i in view._tree_chunks.keys():
		if not (view._tree_chunks[c] as Array).is_empty():
			return c
	return Vector3i(-1, -1, 1)


func _layer_facts(v: float) -> Dictionary:
	var out := {"shared": true, "ranged": true, "complement": true, "chunks": 0}
	for c: Vector3i in view._tree_chunks.keys():
		var layers: Array = view._tree_chunks[c]
		if layers.is_empty():
			continue
		out["chunks"] += 1
		var origin: Vector3 = (layers[0] as MultiMeshInstance3D).position
		for n: MultiMeshInstance3D in layers:
			out["shared"] = out["shared"] and n.position.is_equal_approx(origin)
			out["ranged"] = out["ranged"] and _ranged(n, v)
		out["complement"] = out["complement"] and _complement(layers, 50.0 * v)
	return out


## One layer's ends: full trees from 0 to 12 x vis_mult, stand-ins from there to 50 x vis_mult.
func _ranged(n: MultiMeshInstance3D, v: float) -> bool:
	if n.visibility_range_begin > 0.0:
		return (
			absf(n.visibility_range_begin - 12.0 * v) < G.EPS
			and absf(n.visibility_range_end - 50.0 * v) < G.EPS
		)
	return absf(n.visibility_range_end - 12.0 * v) < G.EPS


## The engine's fade rule for FADE_SELF layers: the end fades over [end - margin, end + margin], the
## begin over [begin - margin, begin + margin]. Solid below the near end's fade, the stand-ins
## solid between the fades, the two alphas summing to one across the switch.
func _complement(layers: Array, far_end: float) -> bool:
	var near: MultiMeshInstance3D = null
	var far: MultiMeshInstance3D = null
	for n: MultiMeshInstance3D in layers:
		if n.visibility_range_begin > 0.0:
			far = n
		elif near == null:
			near = n
	if near == null or far == null:
		return false
	var d := 0.0
	while d <= far_end - CityView.TREE_MARGIN_FP:
		if absf(_alpha(near, d) + _alpha(far, d) - 1.0) > G.EPS:
			return false
		d += 0.25
	return true


func _alpha(n: MultiMeshInstance3D, d: float) -> float:
	var a := 1.0
	if n.visibility_range_end > 0.0:
		var m := n.visibility_range_end_margin
		a = minf(a, clampf((n.visibility_range_end + m - d) / (2.0 * m), 0.0, 1.0))
	if n.visibility_range_begin > 0.0:
		var m2 := n.visibility_range_begin_margin
		a = minf(a, clampf((d - (n.visibility_range_begin - m2)) / (2.0 * m2), 0.0, 1.0))
	return a


## Aerial: every chunk, nothing freed behind the camera, the far layers end at the horizon; off:
## the far ends come back and the pool shrinks onto the camera. The camera stands still throughout.
func _check_aerial() -> void:
	var v := Q.vis_mult("low", true)
	view.vis_mult = v
	_go(G.SPAWN)
	await process_frame
	var street := _mmis(view)
	view.set_aerial(true)
	var passes := 1 + _finish()
	await process_frame
	var all := view._tree_chunks.size()
	K.check(
		fails,
		all == G.FULL,
		"aerial: all %d chunks are planted (%d, %d passes)" % [G.FULL, all, passes]
	)
	K.check(
		fails,
		_mmis(view) > street * 6 and _tidy(view),
		"aerial: %d MMIs against %d on the street" % [_mmis(view), street]
	)
	K.check(fails, _far_ends_are(0.0), "aerial: every far layer draws to the horizon")
	_info("aerial plant: %d chunks, %d MMIs, %d passes" % [all, _mmis(view), passes])
	view.set_aerial(false)
	var shrunk := G.FULL - view._tree_chunks.size()
	K.check(
		fails,
		shrunk <= CityView.TREE_FREE_CAP,
		"off again: one pass frees %d chunks at most" % shrunk
	)
	passes = 1 + _finish()
	await process_frame
	var want := G.within(G.SPAWN, G.window(v))
	var stay := G.within(G.SPAWN, G.window(v) + CityView.TREE_STREAM_HYSTERESIS)
	K.check(
		fails,
		G.has_all(view, want) and _only_in(stay),
		(
			"off again: the pool is back on the window (%d chunks, %d passes)"
			% [view._tree_chunks.size(), passes]
		)
	)
	K.check(
		fails,
		_far_ends_are(CityView.TREE_FAR_FP * v),
		"off again: the far layers end at 50 x vis_mult"
	)
	K.check(fails, _tidy(view), "off again: no node is left over (%d MMIs)" % _mmis(view))


func _far_ends_are(end: float) -> bool:
	for c: Vector3i in view._tree_chunks.keys():
		for n in _far_layers(c):
			if absf(n.visibility_range_end - end) > G.EPS:
				return false
	return true


# ------------------------------------------------------------------ cameras and modes


## Orbit plants its 25 chunks of 48 tiles and streams nothing; going back on foot rebuilds the
## window; neither switch leaks a node or frees one twice.
func _check_mode_switch() -> void:
	var v := Q.vis_mult("low", true)
	var held := _hold(view)
	view.set_fp_mode(false)
	await process_frame
	K.check(
		fails,
		_freed(held) == held.size(),
		"orbit: the street Trees root and its %d nodes are freed" % (held.size() - 1)
	)
	var orbit := true
	var far_ok := true
	for c: Vector3i in view._tree_chunks.keys():
		orbit = orbit and c.z == 0
		for n: MultiMeshInstance3D in view._tree_chunks[c]:
			if n.visibility_range_begin > 0.0:
				far_ok = far_ok and absf(n.visibility_range_begin - CityView.TREE_NEAR) < G.EPS
				far_ok = far_ok and n.visibility_range_end == 0.0
	K.check(
		fails,
		orbit and view._tree_chunks.size() == 25,
		"orbit: the 25 chunks of 48 tiles (%d)" % view._tree_chunks.size()
	)
	K.check(
		fails, _tidy(view), "orbit: every MMI belongs to a chunk, none left over (%d)" % _mmis(view)
	)
	K.check(
		fails, far_ok, "orbit: the far layers begin at %.0f u and have no end" % CityView.TREE_NEAR
	)
	var snap := G.planted(view)
	cam.position = _eye(G.CORNER)
	view.vis_mult = 0.7
	view._stream_trees()
	view.set_aerial(true)
	view.set_aerial(false)
	await process_frame
	K.check(
		fails,
		G.planted(view) == snap and _tidy(view),
		"orbit: camera, vis_mult and aerial change nothing"
	)
	view.vis_mult = v
	cam.position = _eye(G.SPAWN)
	held = _hold(view)
	view.set_fp_mode(true)
	_finish()
	await process_frame
	K.check(fails, _freed(held) == held.size(), "back on foot: the orbit Trees root is freed")
	var street := true
	for c: Vector3i in view._tree_chunks.keys():
		street = street and c.z == 1
	K.check(
		fails,
		street and G.has_all(view, G.within(G.SPAWN, G.window(v))),
		"back on foot: the window, FP chunks only (%d)" % view._tree_chunks.size()
	)
	K.check(fails, _tidy(view), "back on foot: no node leaked (%d MMIs)" % _mmis(view))


## A second view planted from scratch under aerial coverage (the full plant, no streaming history)
## holds the same chunks as the streamed pool: the same spots, centres, counts, ranges and buffers
## but for the far ends the aerial coverage lifts; once it lets go, they match in those too.
func _check_reference() -> void:
	var v := Q.vis_mult("low", true)
	view.vis_mult = v
	_go(G.SPAWN)
	await process_frame
	var full := _new_view(cam, v, true)
	_drain(full)
	await process_frame
	K.check(
		fails, full._tree_chunks.size() == G.FULL, "the reference plant has all %d chunks" % G.FULL
	)
	var same := true
	var n := 0
	for c: Vector3i in view._tree_chunks.keys():
		n += 1
		same = same and _fingerprint(view, c, true) == _fingerprint(full, c, true)
	K.check(
		fails,
		same and n > 0,
		"the streamed pool's %d chunks equal the full plant's, chunk for chunk" % n
	)
	K.check(fails, _mmis(view) * 5 < _mmis(full), "%d MMIs against %d" % [_mmis(view), _mmis(full)])
	full.set_aerial(false)
	_drain(full)
	await process_frame
	same = true
	for c: Vector3i in view._tree_chunks.keys():
		same = same and _fingerprint(view, c) == _fingerprint(full, c)
	K.check(fails, same, "after aerial coverage ends: equal in the far ends and margins too")
	_info("%d layer buffers compared by SHA-256 (0: the renderer keeps none)" % buffers_seen)
	full.queue_free()
