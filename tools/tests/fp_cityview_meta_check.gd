extends SceneTree
## Driven by fp_cityview_meta_test.gd, not by the gate (no _test suffix): runs
## CityView.building_aabb on holders whose building metas are missing or wrong-shaped (a lot
## mid-rebuild keeps building_path while building_xform is gone), each of which must fall back
## to the empty AABB, and prints a token. The suite greps this run's captured output; get_meta
## prints an engine ERROR for a missing key (core/object/object.cpp), which the unguarded read
## in building_aabb made for every such holder.


func _initialize() -> void:
	var view := CityView.new()
	root.add_child(view)
	var holder := Node3D.new()
	root.add_child(holder)
	(holder as Node3D).position = Vector3(2.0, 0.0, 3.0)
	(view as CityView)._tile_nodes[0] = holder
	# Path meta but no xform (mid-rebuild): empty bounds, no engine ERROR.
	holder.set_meta("building_path", "res://models/real/props/bench.glb")
	var a: AABB = (view as CityView).building_aabb(0)
	var ok := a.size == Vector3.ZERO
	# Wrong-typed xform: the typeof guard's path.
	holder.set_meta("building_xform", 5)
	var b: AABB = (view as CityView).building_aabb(0)
	ok = ok and b.size == Vector3.ZERO
	# Real xform: the model's bounds come back, moved by the holder.
	holder.set_meta("building_xform", Transform3D.IDENTITY)
	var c: AABB = (view as CityView).building_aabb(0)
	ok = ok and c.size != Vector3.ZERO and c.position.x > 1.0
	# No holder at all: empty bounds.
	ok = ok and (view as CityView).building_aabb(99).size == Vector3.ZERO
	holder.free()
	view.free()
	print("FP_CITYVIEW_META_CHECK: %s" % ("DONE" if ok else "BAD"))
	quit(0 if ok else 1)
