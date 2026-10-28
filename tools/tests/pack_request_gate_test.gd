extends SceneTree
## Split-web request gate (Phase B step 3): a scene whose background pack is still downloading
## is demanded through WebPackStream.request_path and never poisons CityView's scene cache with
## a permanent null. When the pack arrives, exactly the waiting paths are retried; genuine
## misses (no pack claims the path) and stream-less desktop runs keep the old behavior.

const K := preload("res://tools/tests/fp_kit.gd")
const Midlod := preload("res://scripts/fp/render/midlod.gd")
# Preload, not the global name: the class cache is not guaranteed fresh in test worktrees.
const WebPackStream := preload("res://scripts/ops/web_pack_stream.gd")

var fails: Array[String] = []


class FakeStream:
	extends WebPackStream
	var routes := {}  # path prefix -> pack
	var mounted_packs := {}  # pack -> true
	var demands: Array[String] = []

	func request_path(path: String) -> String:
		for prefix: String in routes:
			if path.begins_with(prefix):
				var pack: String = routes[prefix]
				if mounted_packs.has(pack):
					return ""
				if not demands.has(pack):
					demands.append(pack)
				return pack
		return ""

	func arrive(pack: String) -> void:
		mounted_packs[pack] = true
		pack_ready.emit(pack)


func _fixture_scene() -> String:
	var path := "user://gf_gate_fixture.tscn"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[gd_scene format=3]\n\n[node name=\"Fixture\" type=\"Node3D\"]\n")
	f.close()
	return path


func _mesh(surfaces: int) -> ArrayMesh:
	var m := ArrayMesh.new()
	for i in surfaces:
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = PackedVector3Array(
			[Vector3.ZERO, Vector3.RIGHT * (i + 1), Vector3.UP]
		)
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


func _init() -> void:
	var fixture := _fixture_scene()
	var stream := FakeStream.new()
	stream.routes = {"user://gf_gate_fixture": "traffic", "res://models/real/midlod/": "midlod"}

	var view := CityView.new()
	get_root().add_child(view)
	view.pack_stream = stream

	# A pending pack: demand once, return null, cache nothing.
	K.check(fails, view._scene(fixture) == null, "pending pack: _scene returns null")
	K.check(fails, not view._scenes.has(fixture), "pending pack: no null cache entry")
	K.check(fails, view._pack_waiting.get("traffic", []) == [fixture], "pending pack: path waits")
	K.check(fails, stream.demands == ["traffic"], "pending pack: pack demanded once")
	K.check(fails, view._scene(fixture) == null, "pending pack: second miss stays uncached")
	K.check(
		fails, view._pack_waiting["traffic"].size() == 1, "pending pack: wait recorded once"
	)

	# _warm_one yields (false) instead of caching a miss.
	K.check(fails, view._warm_one(fixture) == false, "pending pack: _warm_one yields")
	K.check(fails, not view._scenes.has(fixture), "pending pack: _warm_one caches nothing")

	# A null entry planted before the gate existed is dropped on arrival.
	view._scenes[fixture] = null
	stream.arrive("traffic")
	K.check(fails, view._pack_waiting.is_empty(), "arrival: waiting set cleared")
	K.check(fails, not view._scenes.has(fixture), "arrival: stale null entry dropped")
	var ps: PackedScene = view._scene(fixture)
	K.check(fails, ps != null, "arrival: the scene now loads")
	K.check(fails, view._scenes[fixture] == ps, "arrival: loaded scene is cached")

	# Genuine miss (no pack claims the path): the old completed-null behavior is kept.
	var missing := "user://gf_gate_missing.tscn"
	K.check(fails, view._scene(missing) == null, "genuine miss returns null")
	K.check(
		fails, view._scenes.has(missing) and view._scenes[missing] == null,
		"genuine miss caches null (terminates)"
	)

	# No stream (desktop/unsplit): identical old behavior, no demands.
	var plain := CityView.new()
	get_root().add_child(plain)
	K.check(fails, plain._scene(missing) == null, "no stream: miss returns null")
	K.check(fails, plain._scenes.has(missing), "no stream: old null caching")
	plain.queue_free()

	# Teardown with a pack still pending is safe.
	var stuck := CityView.new()
	get_root().add_child(stuck)
	var waiting_stream := FakeStream.new()
	waiting_stream.routes = {"user://gf_gate_fixture": "sky"}
	stuck.pack_stream = waiting_stream
	stuck._scene(fixture)
	K.check(fails, stuck._pack_waiting.has("sky"), "teardown: pack still pending")
	stuck.queue_free()

	# midlod: a baked-twin miss demands the midlod pack, then merges at runtime; the completed
	# twin is never evicted and no second demand is made.
	var ml: RefCounted = Midlod.new()
	ml.threaded = false
	var mid_stream := FakeStream.new()
	mid_stream.routes = {"res://models/real/midlod/": "midlod"}
	ml.pack_stream = mid_stream
	var src := _mesh(3)
	var twin: ArrayMesh = ml.mesh_for(src, "res://models/real/zones/r1/house.glb")
	K.check(fails, mid_stream.demands == ["midlod"], "midlod: pack demanded on baked miss")
	K.check(fails, twin != null, "midlod: runtime fallback still produces a twin")
	mid_stream.arrive("midlod")
	K.check(fails, ml.mesh_for(src, "x") == twin, "midlod: completed twin survives arrival")
	K.check(fails, mid_stream.demands == ["midlod"], "midlod: no repeat demand after arrival")

	view.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(fixture))
	if fails.is_empty():
		print("PACK_REQUEST_GATE_TEST: PASS")
		quit(0)
	else:
		print("PACK_REQUEST_GATE_TEST: FAIL (", fails.size(), ")")
		quit(1)
