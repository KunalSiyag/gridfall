extends SceneTree
## midlod.fresh() must classify bakes without engine ERRORs: an untagged (legacy/stale) bake is
## stale, a correctly tagged bake is fresh, and wrong tags are stale. Godot 4.7 prints an ERROR
## for get_meta on a missing key, so fresh() probes with has_meta; this test guards that.

const Midlod := preload("res://scripts/fp/render/midlod.gd")

var _fail := 0


func _check(ok: bool, name: String) -> void:
	if ok:
		print("PASS ", name)
	else:
		_fail += 1
		print("FAIL ", name)


func _mesh(extend: float = 1.0) -> ArrayMesh:
	var m := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT * extend, Vector3.UP])
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


func _init() -> void:
	var src := _mesh(1.0)

	var untagged := _mesh(1.0)
	_check(not Midlod.fresh(untagged, src), "untagged bake is stale (no engine ERROR above)")

	var good := _mesh(1.0)
	good.set_meta("src_surfaces", 1)
	good.set_meta("src_aabb", src.get_aabb())
	_check(Midlod.fresh(good, src), "tagged bake is fresh")

	var wrong_box := _mesh(1.0)
	wrong_box.set_meta("src_surfaces", 1)
	wrong_box.set_meta("src_aabb", _mesh(2.0).get_aabb())
	_check(not Midlod.fresh(wrong_box, src), "bounds mismatch is stale")

	var wrong_surfaces := _mesh(1.0)
	wrong_surfaces.set_meta("src_surfaces", 7)
	wrong_surfaces.set_meta("src_aabb", src.get_aabb())
	_check(not Midlod.fresh(wrong_surfaces, src), "surface-count mismatch is stale")

	var partial := _mesh(1.0)
	partial.set_meta("src_aabb", src.get_aabb())
	_check(not Midlod.fresh(partial, src), "missing src_surfaces is stale (no engine ERROR above)")

	_check(
		Midlod.load_baked(src, "res://models/real/midlod/none.glb") == null, "no bake loads null"
	)

	if _fail == 0:
		print("FP_MIDLOD_TEST: PASS")
		quit(0)
	else:
		print("FP_MIDLOD_TEST: FAIL (", _fail, ")")
		quit(1)
