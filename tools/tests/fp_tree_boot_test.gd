extends SceneTree
## On-foot tree streaming through the real boot paths (CityView; the window itself is
## fp_tree_stream_test.gd's). Main runs setup() while vis_mult still has its default 1.0 and the
## street feature sets the web tier's 0.55 afterwards; entering the street swaps the orbit camera
## for the hero's; the props pack rebuilds the tree kits after boot on a split web build; a headless
## run has no camera at all; a node processed after CityView can jump the camera. Each leaves the
## pool exactly on its window (the camera's, or the map's middle without one), every layer ranged
## for the current vis_mult, no node stray, and the old Trees root freed.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const Q := preload("res://scripts/fp/render/quality.gd")
const SPAWN := Vector2(15.5, 13.5)
const CORNER := Vector2(100.0, 100.0)
const MIDDLE := Vector2(16.0, 16.0)
## A dense wood of this world (seed 7), far from the spawn and from any tile that draws.
const WOOD := Vector2(47.5, -48.5)

var fails: Array[String] = []
var holder: Node3D
var sim: CitySim


func _init() -> void:
	K.watchdog(self, "FP_TREE_BOOT_TEST")
	await process_frame
	holder = Node3D.new()
	holder.name = "TreeBootKit"
	get_root().add_child(holder)
	sim = K.make_sim(holder, 7)["sim"]
	sim.set_speed(0)
	K.check(fails, Vector2(D.X0 + D.W * 0.5, D.Y0 + D.H * 0.5) == MIDDLE, "the map's middle")
	await _check_boot_order()
	await _check_enter_street()
	await _check_kit_refresh()
	await _check_no_camera()
	await _check_late_teleport()
	await _check_jump_frame_drawn()
	K.finish(self, "FP_TREE_BOOT_TEST", fails)


## A CityView set up on the sim as Main does it: fp_mode first, vis_mult at its default 1.0.
func _make(camera: Camera3D, fp: bool) -> CityView:
	var v := CityView.new()
	holder.add_child(v)
	v.fp_mode = fp
	v.tree_stream_budget_ms = 1.0e9
	v.setup(sim, camera)
	return v


func _camera(p: Vector2) -> Camera3D:
	var c := Camera3D.new()
	holder.add_child(c)
	c.position = Vector3(p.x, 1.6, p.y)
	return c


## Runs stream passes until one leaves nothing to do.
func _drain(v: CityView) -> void:
	var n := 0
	while not v._tree_stream_done and n < 200:
		v._stream_trees()
		n += 1


## Chunks inside radius r of p (v's window by default) that are not planted (x), and planted chunks
## past r plus a hysteresis step (y): both 0 when the pool sits on the window.
func _strays(v: CityView, p: Vector2, r: float = -1.0) -> Vector2i:
	var win: float = v._tree_window() if r < 0.0 else r
	var hi := v._tree_chunk_of(
		D.X0 + D.W + CityView.TREE_RING - 1, D.Y0 + D.H + CityView.TREE_RING - 1, 1
	)
	var out := Vector2i.ZERO
	for cy in range(hi.y + 1):
		for cx in range(hi.x + 1):
			var c := Vector3i(cx, cy, 1)
			var d: float = v._tree_chunk_dist(c, p)
			out.x += int(d <= win and not v._tree_chunks.has(c))
			out.y += int(d > win + CityView.TREE_STREAM_HYSTERESIS and v._tree_chunks.has(c))
	return out


## Layers whose range is not the one vis_mult m gives: full trees to 12 m, stand-ins 12 m to 50 m.
func _off_range(v: CityView, m: float) -> int:
	var bad := 0
	for layers: Array in v._tree_chunks.values():
		for n: MultiMeshInstance3D in layers:
			var ok := is_equal_approx(n.visibility_range_end, CityView.TREE_NEAR_FP * m)
			if n.visibility_range_begin > 0.0:
				ok = is_equal_approx(n.visibility_range_begin, CityView.TREE_NEAR_FP * m)
				ok = ok and is_equal_approx(n.visibility_range_end, CityView.TREE_FAR_FP * m)
			bad += 0 if ok else 1
	return bad


## Every node under the Trees root is a layer of a planted chunk, and nothing else hangs there.
func _tidy(v: CityView) -> bool:
	var layers := 0
	for l: Array in v._tree_chunks.values():
		layers += l.size()
	return v._trees_root.get_child_count() == layers


func _hold(v: CityView) -> Array:
	var out: Array = [v._trees_root]
	out.append_array(v._trees_root.get_children())
	return out


func _freed(held: Array) -> int:
	var n := 0
	for o: Variant in held:
		n += 0 if is_instance_valid(o) else 1
	return n


## The pool, ranges and nodes of v as one verdict: on the window of p at vis_mult m.
func _verdict(label: String, v: CityView, p: Vector2, m: float) -> void:
	var s := _strays(v, p)
	var planted: int = v._tree_chunks.size()
	K.check(
		fails, s == Vector2i.ZERO, "%s: %d chunks on the window (%s off it)" % [label, planted, s]
	)
	K.check(
		fails, _off_range(v, m) == 0, "%s: every layer is ranged for vis_mult %.2f" % [label, m]
	)
	K.check(fails, _tidy(v), "%s: every node under Trees is a planted layer" % label)


## setup() plants for the default vis_mult 1.0; the street feature then sets the web tier's 0.55:
## the planted layers take the new ranges and the pool shrinks onto the smaller window.
func _check_boot_order() -> void:
	var web := Q.vis_mult("low", true)
	var v := _make(_camera(SPAWN), true)
	await process_frame
	_drain(v)
	_verdict("setup at the default 1.0", v, SPAWN, 1.0)
	v.vis_mult = web
	_drain(v)
	await process_frame
	_verdict("then the web tier's %.2f" % web, v, SPAWN, web)
	v.queue_free()


## Tab from the orbit view: set_fp_mode(true) plants around the orbit camera, then Main swaps in
## the hero's camera and the pool follows it; the orbit camera's corner of the map is let go.
func _check_enter_street() -> void:
	var web := Q.vis_mult("low", true)
	var orbit := _camera(CORNER)
	var v := _make(orbit, false)
	v.vis_mult = web
	var held := _hold(v)
	v.set_fp_mode(true)
	_drain(v)
	await process_frame
	_verdict("street entered over the orbit camera", v, CORNER, web)
	K.check(fails, _freed(held) == held.size(), "the %d orbit nodes are freed" % (held.size() - 1))
	v.set_camera(_camera(SPAWN))
	var bare: int = _strays(v, SPAWN, v._tree_ring()).x
	K.check(fails, bare == 0, "the swap plants the hero's near ring at once (%d missing)" % bare)
	_drain(v)
	await process_frame
	_verdict("the hero's camera swapped in", v, SPAWN, web)
	v.queue_free()
	orbit.queue_free()


## The props pack arrived: the kits and every planted chunk are rebuilt for the window only (the
## old plant made all 729 again), the old Trees root is freed.
func _check_kit_refresh() -> void:
	var web := Q.vis_mult("low", true)
	var v := _make(_camera(SPAWN), true)
	v.vis_mult = web
	_drain(v)
	await process_frame
	var before: int = v._tree_chunks.size()
	var held := _hold(v)
	v._refresh_tree_kits()
	_drain(v)
	await process_frame
	_verdict("after the kits were rebuilt", v, SPAWN, web)
	var gone := "the old Trees root and its %d nodes are freed" % (held.size() - 1)
	K.check(fails, _freed(held) == held.size(), gone)
	K.check(fails, v._tree_chunks.size() == before, "the same %d chunks come back" % before)
	v.queue_free()


## No camera (headless), then one that is not in the tree, then none again: the window sits on the
## middle of the map and nothing reads the camera's transform.
func _check_no_camera() -> void:
	var web := Q.vis_mult("low", true)
	var v := _make(null, true)
	v.vis_mult = web
	_drain(v)
	await process_frame
	_verdict("no camera", v, MIDDLE, web)
	var loose := Camera3D.new()
	loose.position = Vector3(CORNER.x, 1.6, CORNER.y)
	v.set_camera(loose)
	_drain(v)
	await process_frame
	_verdict("a camera outside the tree", v, MIDDLE, web)
	v.set_camera(_camera(CORNER))
	_drain(v)
	await process_frame
	_verdict("a camera in the tree", v, CORNER, web)
	v.set_camera(null)
	_drain(v)
	await process_frame
	_verdict("no camera again", v, MIDDLE, web)
	loose.free()
	v.queue_free()


## A node processed after CityView jumps the camera in its own _process (the respawn does): this
## frame's pass has run, so the pre-draw pass plants the near ring before the frame shows; a
## walking step plants nothing, and a pass that left fill-in behind is not run twice a frame.
func _check_late_teleport() -> void:
	var web := Q.vis_mult("low", true)
	var camera := _camera(SPAWN)
	var v := _make(camera, true)
	v.vis_mult = web
	_drain(v)
	await process_frame
	var wired := RenderingServer.frame_pre_draw.is_connected(v._on_pre_draw)
	K.check(fails, wired, "the pre-draw pass is connected to the render server")
	var at: Vector2 = v._tree_stream_at
	camera.position = Vector3(SPAWN.x + 2.0, 1.6, SPAWN.y)
	v._on_pre_draw()
	K.check(fails, v._tree_stream_at == at, "a walking step runs no pass before the draw")
	camera.position = Vector3(CORNER.x, 1.6, CORNER.y)
	v._on_pre_draw()
	var bare: int = _strays(v, CORNER, v._tree_ring()).x
	K.check(fails, bare == 0, "a jump after _process: the near ring is planted before the draw")
	var pool := v._tree_chunks.keys()
	v._on_pre_draw()
	K.check(fails, v._tree_chunks.keys() == pool, "no jump: the fill-in stays _process's")
	v.queue_free()


## A node processed after the view (it is added after it) that moves the camera in its own _process.
class LateMover:
	extends Node
	var camera: Camera3D
	var target := Vector3.ZERO
	var armed := false

	func _process(_dt: float) -> void:
		if armed:
			camera.position = target
			armed = false


## The mean luminance of the picture the viewport drew last.
func _drawn() -> float:
	var img := get_root().get_viewport().get_texture().get_image()
	var sum := 0.0
	var n := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			sum += img.get_pixel(x, y).get_luminance()
			n += 1
	return sum / float(n)


## What the late jump shows, in a windowed run (the headless server draws nothing): only the near
## ring is in sight (far plane 10 u, trees only, a white sky), and the picture of the jump frame
## itself must show its trees as the settled picture does, not the bare ground the frame before had.
func _check_jump_frame_drawn() -> void:
	if DisplayServer.get_name() == "headless":
		print("  info the jump frame's picture is checked in windowed runs only: skipped")
		return
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.WHITE
	var camera := _camera(SPAWN)
	camera.far = 10.0
	camera.environment = env
	camera.make_current()
	var v := _make(camera, true)
	v.vis_mult = Q.vis_mult("low", true)
	for c in v.get_children():
		if c is Node3D and c != v._trees_root:
			(c as Node3D).visible = false
	var mover := LateMover.new()
	mover.camera = camera
	holder.add_child(mover)
	for _i in range(30):
		await process_frame
	await RenderingServer.frame_post_draw
	var bare := _drawn()
	mover.target = Vector3(WOOD.x, 1.6, WOOD.y)
	mover.armed = true
	await RenderingServer.frame_post_draw
	var jump := _drawn()
	for _i in range(30):
		await process_frame
	await RenderingServer.frame_post_draw
	var settled := _drawn()
	var shown := "bare %.3f, jump frame %.3f, settled %.3f" % [bare, jump, settled]
	K.check(fails, absf(bare - settled) > 0.1, "the wood shows in the settled picture (%s)" % shown)
	K.check(fails, absf(jump - settled) < 0.03, "the jump frame already draws it (%s)" % shown)
	v.queue_free()
	mover.queue_free()
