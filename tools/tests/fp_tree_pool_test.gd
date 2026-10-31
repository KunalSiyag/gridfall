extends SceneTree
## What the on-foot tree pool holds, against oracles outside CityView's own plant code (the proofs
## in fp_tree_stream_test.gd compare a streamed chunk with a full plant, which runs that code on
## both sides): the trees of a chunk against sim.kind, counted per tile; the pool on the window at
## seeded random poses; only chunks of the grid at and beyond the edges of the map, and a stream
## that finishes there; and where aerial coverage starts to fill - at the spot the camera looks at,
## not the one beneath it, with the ring planted around it.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const G := preload("res://tools/tests/fp_tree_geom.gd")
## A pass budget no pass spends (ms): whole passes, so the checks do not depend on the clock.
const UNMETERED := 1.0e9
## A dense wood of this world (seed 7), far from the spawn.
const WOOD := Vector2(47.5, -48.5)

var fails: Array[String] = []
var holder: Node3D
var sim: CitySim
var cam: Camera3D
var view: CityView
var web := 0.55


func _init() -> void:
	K.watchdog(self, "FP_TREE_POOL_TEST")
	await process_frame
	_fixture()
	await _check_counts()
	_check_extremes()
	_check_random_poses()
	_check_aerial_focus()
	K.finish(self, "FP_TREE_POOL_TEST", fails)


# ------------------------------------------------------------------ fixture and helpers


## A grown city, a street camera at the spawn and a CityView on foot at the web tier's vis_mult.
func _fixture() -> void:
	web = Q.vis_mult("low", true)
	holder = Node3D.new()
	holder.name = "TreePoolKit"
	get_root().add_child(holder)
	var made := K.make_sim(holder, 7)
	sim = made["sim"]
	K.grow(sim, made["people"], 40)
	sim.set_speed(0)
	cam = Camera3D.new()
	cam.name = "PoolCamera"
	holder.add_child(cam)
	cam.position = _eye(G.SPAWN)
	view = _new_view(web, false)


func _new_view(vis: float, aerial: bool) -> CityView:
	var v := CityView.new()
	v.name = "CityView"
	holder.add_child(v)
	v.fp_mode = true
	v.aerial_trees = aerial
	v.vis_mult = vis
	v.tree_stream_budget_ms = UNMETERED
	v.setup(sim, cam)
	return v


func _eye(p: Vector2) -> Vector3:
	return Vector3(p.x, 1.6, p.y)


## Runs stream passes on v until one leaves nothing to do.
func _drain(v: CityView) -> void:
	var n := 0
	while not v._tree_stream_done and n < 400:
		v._stream_trees()
		n += 1


## Camera to p, then passes until the pool has settled on it.
func _go(p: Vector2) -> void:
	cam.position = _eye(p)
	view._stream_trees()
	_drain(view)


## True when every planted chunk is in a.
func _only_in(a: Array[Vector3i]) -> bool:
	for c: Vector3i in view._tree_chunks.keys():
		if not a.has(c):
			return false
	return true


# ------------------------------------------------------------------ the trees of a chunk


## The trees of a chunk against sim.kind itself: inside the map every forest tile carries four trees
## and any other tile none, and the far layers carry them all. Counted over the pool at three spots
## (a dense wood among them) and over a full plant of the whole map.
func _check_counts() -> void:
	var inside := 0
	var wrong := 0
	for p: Vector2 in [G.SPAWN, WOOD, G.LANDING]:
		_go(p)
		await process_frame
		var got := _count_errors(view)
		inside += got.x
		wrong += got.y
	var msg := "%d chunks of the pool inside the map: four trees per forest tile only (%d off)"
	K.check(fails, inside > 100 and wrong == 0, msg % [inside, wrong])
	var full := _new_view(web, true)
	_drain(full)
	await process_frame
	var r := _count_errors(full)
	msg = "the full plant's %d chunks inside the map: the trees sim.kind says (%d off)"
	K.check(fails, full._tree_chunks.size() == G.FULL and r.x > 400 and r.y == 0, msg % [r.x, r.y])
	full.queue_free()
	_go(G.SPAWN)


## (chunks fully inside the map that v holds, how many of them hold other trees than sim.kind says).
func _count_errors(v: CityView) -> Vector2i:
	var out := Vector2i.ZERO
	for c: Vector3i in v._tree_chunks.keys():
		var tiles := G.tiles(c)
		if tiles.size() < CityView.TREE_CHUNK_FP * CityView.TREE_CHUNK_FP:
			continue
		var trees := 0
		for i in tiles:
			trees += 4 if sim.kind[i] == D.FOREST else 0
		var layers: Array = v._tree_chunks[c]
		var ok := layers.is_empty() if trees == 0 else _far_counts(layers, trees)
		out += Vector2i(1, 0 if ok else 1)
	return out


## True when the layers have far layers and every one carries exactly n trees.
func _far_counts(layers: Array, n: int) -> bool:
	var far := 0
	for l: MultiMeshInstance3D in layers:
		if l.visibility_range_begin > 0.0:
			far += 1
			if l.multimesh.instance_count != n:
				return false
	return far > 0


# ------------------------------------------------------------------ the pool and the window


## Cameras at the map's corners and far outside it: the window reaches past the grid there, but only
## the grid's own chunks are ever planted (an index past the grid would alias into the next column
## of the sort key and the stream would never finish), and a camera far outside has nothing to
## stream: the pool empties and the stream is done.
func _check_extremes() -> void:
	view.vis_mult = Q.vis_mult("high", false)
	var spots: Array[Vector2] = [
		Vector2(-92.0, -92.0),
		Vector2(123.0, 123.0),
		Vector2(123.0, -92.0),
		Vector2(-92.0, 123.0),
		Vector2(5000.0, 5000.0),
		Vector2(-5000.0, -5000.0),
		Vector2(5000.0, -5000.0),
		Vector2(0.0, 5000.0),
		Vector2(-5000.0, 0.0),
	]
	var off_grid := 0
	var unfinished := 0
	var left_far := 0
	for p in spots:
		_go(p)
		for c: Vector3i in view._tree_chunks.keys():
			off_grid += 0 if G.grid().has(c) else 1
		unfinished += 0 if view._tree_stream_done else 1
		if p.length() >= 1000.0:
			left_far += view._tree_chunks.size()
	var msg := "%d camera spots at the edges and far outside: no chunk off the grid (%d)"
	K.check(fails, off_grid == 0, msg % [spots.size(), off_grid])
	K.check(fails, unfinished == 0, "and every stream finishes (%d unfinished)" % unfinished)
	K.check(fails, left_far == 0, "a camera far outside the map keeps no chunk (%d)" % left_far)
	view.vis_mult = web
	_go(G.SPAWN)


## Seeded random poses over the map and its ring, at the web tier and at Medium: after every jump
## and fill the pool is the window - every chunk within it planted, none past it by a hysteresis
## step - wherever the box that is scanned for missing chunks ends.
func _check_random_poses() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261031
	var off := 0
	var poses := 0
	for v: float in [web, Q.vis_mult("medium", false)]:
		view.vis_mult = v
		for _k in range(25):
			var p := Vector2(rng.randf_range(-96.0, 127.0), rng.randf_range(-96.0, 127.0))
			_go(p)
			poses += 1
			var lo := G.within(p, G.window(v))
			var hi := G.within(p, G.window(v) + CityView.TREE_STREAM_HYSTERESIS)
			off += 0 if G.has_all(view, lo) and _only_in(hi) else 1
	var msg := "%d random poses: the pool is the window after each (%d off)"
	K.check(fails, off == 0, msg % [poses, off])
	view.vis_mult = web
	_go(G.SPAWN)


# ------------------------------------------------------------------ where aerial coverage starts


## Aerial coverage opens the window to the whole map and fills it nearest first - from the spot the
## camera LOOKS at (its view ray meets the ground), not the one beneath it: pitched, the woods ahead
## come before those behind it, and the near ring is the one around that spot. A camera that sees
## no ground (level, or turned up) fills from the spot beneath it; a shallow one, whose ray meets
## the ground far out, from a spot held at half its far plane.
func _check_aerial_focus() -> void:
	var pivot := G.LANDING
	var nadir := pivot + Vector2(0.0, 34.64)
	_hang(nadir)
	cam.look_at(Vector3(pivot.x, 0.0, pivot.y), Vector3.UP)
	_check_fill_origin("pitched at the landing", pivot)
	_hang(nadir)
	_check_fill_origin("level", nadir)
	_hang(nadir)
	cam.rotation = Vector3(deg_to_rad(40.0), 0.0, 0.0)
	_check_fill_origin("turned up", nadir)
	_hang(nadir)
	cam.far = 80.0
	cam.rotation = Vector3(deg_to_rad(-5.0), 0.0, 0.0)
	var held := nadir + Vector2(0.0, -cos(deg_to_rad(5.0)) * cam.far * 0.5)
	_check_fill_origin("shallow, far plane 80", held)
	cam.far = 4000.0
	cam.rotation = Vector3.ZERO
	_go(G.SPAWN)


## The camera 20 u above p, level, over a settled street pool at the spawn.
func _hang(p: Vector2) -> void:
	_go(G.SPAWN)
	cam.rotation = Vector3.ZERO
	cam.position = Vector3(p.x, 20.0, p.y)


## Aerial coverage on for the camera as it hangs: the first pass (the ring and one cap of fill-in,
## whatever the clock) plants the chunks nearest `from`, the ring around it whole.
func _check_fill_origin(label: String, from: Vector2) -> void:
	var before := G.planted(view)
	view.set_aerial(true)
	var fresh: Array[Vector3i] = []
	for c in G.planted(view):
		if not before.has(c):
			fresh.append(c)
	var waiting: Array[Vector3i] = []
	for c in G.grid():
		if not view._tree_chunks.has(c):
			waiting.append(c)
	var order := fresh.size() > CityView.TREE_STREAM_CAP and _nearest_first(fresh, waiting, from)
	var msg := "aerial, camera %s: the fill starts at (%.0f, %.0f), nearest first (%d planted)"
	K.check(fails, order, msg % [label, from.x, from.y, fresh.size()])
	var ring := G.has_all(view, G.within(from, G.ring(web)))
	K.check(fails, ring, "aerial, camera %s: the near ring is planted around it" % label)
	view.set_aerial(false)
	_drain(view)


## True when no chunk of `fresh` lies farther from `from` than one of `waiting`.
func _nearest_first(fresh: Array[Vector3i], waiting: Array[Vector3i], from: Vector2) -> bool:
	for a in fresh:
		for b in waiting:
			if G.dist(a, from) > G.dist(b, from) + G.EPS:
				return false
	return true
