extends SceneTree
## Splits a warm traffic frame into its legs and times each, so the web-budget cuts aim at the
## right one: the round-4 budget names traffic_feature the #1 street node (9.5-12.9 ms/frame,
## 25.7 ms hitches) and tile_built -> _on_tile_built at 150.1 ms across 275 calls during a city
## build. Not a test: prints a CSV table and exits 0. Headless native numbers, not wasm — the
## leg RATIOS are the signal.
##
## Run: godot --headless --path . -s tools/traffic_perf_probe.gd

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DT := 1.0 / 60.0
const WARM := 90
const FRAMES := 240
const TILE_SAMPLES := 40

var _f: FpFeature
var _ctx: RefCounted
var _cam := Vector3.ZERO


func _init() -> void:
	await process_frame
	var fails: Array[String] = []
	_ctx = K.render_street_ctx(get_root(), fails)
	_f = K.make_feature(_ctx, "traffic")
	if _f == null:
		print("TRAFFIC_PERF_PROBE: the traffic feature did not come up")
		quit(1)
		return
	_f.set("ambient_enabled", true)
	_f.set("auto_step", false)
	_warm()
	_cam = _f.call("_camera_pos")
	var veh: RefCounted = _f.get("vehicles")
	var wk: RefCounted = _f.get("walkers")
	print("# warm street: %d cars, %d walkers" % [veh.cars.size(), wk.walkers.size()])
	print("leg,avg_ms,p95_ms,max_ms")
	_row("step", _bench(func() -> void: _f.call("step", DT), FRAMES))
	_row("sync_visuals", _bench(func() -> void: _f.call("sync_visuals", DT), FRAMES))
	_sync_legs(veh)
	_row("_maintain (2 Hz)", _bench(func() -> void: _f.call("_maintain", false), 30))
	_tile_leg()
	quit(0)


## Reaches a steady ambient population before measuring.
func _warm() -> void:
	for i in WARM:
		_f.call("step", DT)
		_f.call("sync_visuals", DT)
		if i % 15 == 14:
			await process_frame


## The draw-side legs sync_visuals fans out to, each bracketed the way the feature calls it.
func _sync_legs(veh: RefCounted) -> void:
	var render: RefCounted = _f.get("render")
	var people: RefCounted = _f.get("people")
	var occ: RefCounted = _f.get("occupants")
	var draw := func() -> void:
		render.call("begin", DT)
		_f.call("_draw_moving", _cam)
		render.call("finish")
	_row("render.begin+_draw_moving+finish", _bench(draw, FRAMES))
	var walkers := func() -> void: _f.call("_draw_walkers", DT, _cam, people.get("ok"))
	_row("_draw_walkers", _bench(walkers, FRAMES))
	var contact := func() -> void: _f.call("_draw_contact", _cam, people.get("ok"))
	_row("_draw_contact", _bench(contact, FRAMES))
	var jun: RefCounted = _f.get("junctions")
	var lamps := func() -> void: jun.call("update_lamps", _ctx.player_position(), WS.VIS_PROP + 1.0)
	_row("junctions.update_lamps", _bench(lamps, FRAMES))
	var eye: Vector3 = _ctx.player_position() + Vector3(0, WS.EYE, 0)
	var cam_obj: Variant = _f.call("_camera")
	var sandwich := func() -> void:
		people.call("begin", DT, DT, cam_obj, _cam, eye)
		occ.call("sync", veh.cars, _cam, _ctx.residents)
		people.call("finish")
	_row("people.begin+occupants.sync+finish", _bench(sandwich, FRAMES))


## The tile_built handler's core on a spread of road tiles (what a growth tick pays per tile).
func _tile_leg() -> void:
	var lanes: RefCounted = _f.get("lanes")
	_tile_sublegs(_f.get("peds"), _f.get("junctions"), _f.get("walkers"), lanes)
	var keys: Array = lanes.tiles.keys()
	var i := 0
	while i < keys.size() and i < TILE_SAMPLES:
		var t0 := Time.get_ticks_usec()
		_f.call("_tile_changed", keys[i])
		print("_tile_changed,%.3f,,  # tile %d" % [(Time.get_ticks_usec() - t0) / 1000.0, keys[i]])
		i += maxi(1, keys.size() / TILE_SAMPLES)
	if keys.is_empty():
		print("_tile_changed,n/a,,  # no road tiles")


## One representative road tile's _tile_changed fan-out, leg by leg.
func _tile_sublegs(peds: RefCounted, jun: RefCounted, wk: RefCounted, lanes: RefCounted) -> void:
	var keys: Array = lanes.tiles.keys()
	if keys.is_empty():
		return
	var ti: int = keys[keys.size() / 2]
	var around := func() -> void: lanes.call("rebuild_around", ti)
	_row("tile: lanes.rebuild_around", _bench(around, 8))
	var pd := func() -> void: peds.call("rebuild_around", ti)
	_row("tile: peds.rebuild_around", _bench(pd, 8))
	var props := func() -> void:
		jun.call("build_props", ti)
		for n: int in lanes.call("neighbours", ti):
			jun.call("build_props", n)
	_row("tile: junctions.build_props x5", _bench(props, 8))
	var posts := func() -> void: wk.call("rebuild_posts", _ctx.sim)
	_row("tile: walkers.rebuild_posts", _bench(posts, 8))


func _bench(leg: Callable, n: int) -> Dictionary:
	var us: Array = []
	us.resize(n)
	for i in n:
		var t0 := Time.get_ticks_usec()
		leg.call()
		us[i] = Time.get_ticks_usec() - t0
	us.sort()
	var sum := 0
	for v: int in us:
		sum += v
	return {"avg": sum / float(n), "p95": us[int(n * 0.95)], "max": us[n - 1]}


func _row(label: String, r: Dictionary) -> void:
	print("%s,%.3f,%.3f,%.3f" % [label, r["avg"] / 1000.0, r["p95"] / 1000.0, r["max"] / 1000.0])
