extends SceneTree
## Driven by fp_prop_collision_test.gd's building-meta check, not by the gate (the name has no
## _test suffix): runs collision_world.gd's _building_shapes on holders whose building metas are
## missing or wrong-shaped (a half-dressed lot), each of which must fall back to the whole pick
## box, and prints a token. The suite greps this run's captured output; get_meta prints an
## engine ERROR for a missing key even when a default is given (core/object/object.cpp), which
## the explicit-default reads in _building_shapes make for every such holder here.


func _initialize() -> void:
	var cw := CollisionWorld.new()
	var holder := Node3D.new()
	root.add_child(holder)
	var pick := AABB(Vector3(-0.4, 0.0, -0.4), Vector3(0.8, 0.2, 0.8))
	var bodies: Array[AABB] = []
	var walls: Array[AABB] = []
	var cyls := PackedFloat32Array()
	# No metas at all: the whole-pick fallback.
	cw.call("_building_shapes", 0, holder, pick, bodies, walls, cyls)
	# A path without an xform: the same fallback.
	holder.set_meta("building_path", "res://models/real/props/bench.glb")
	cw.call("_building_shapes", 0, holder, pick, bodies, walls, cyls)
	# An xform of the wrong type: the typeof guard's path.
	holder.set_meta("building_xform", 5)
	cw.call("_building_shapes", 0, holder, pick, bodies, walls, cyls)
	# An empty path with a real xform: the empty-path guard's path.
	holder.set_meta("building_path", "")
	holder.set_meta("building_xform", Transform3D.IDENTITY)
	cw.call("_building_shapes", 0, holder, pick, bodies, walls, cyls)
	holder.free()
	cw.free()
	var ok := bodies.size() == 4 and walls.is_empty() and cyls.is_empty()
	for b: AABB in bodies:
		ok = ok and b == pick
	print("FP_BUILDING_META_CHECK: %s" % ("DONE" if ok else "BAD %s" % str(bodies)))
	quit(0 if ok else 1)
