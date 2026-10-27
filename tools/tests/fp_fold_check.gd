extends SceneTree
## Driven by fp_traffic_test.gd's fold-rig check, not by the gate (the name has no _test suffix):
## folds a bare node the way a pooled non-backhoe body is folded on release, and prints a token.
## The suite greps this run's captured output; the old get_meta explicit-default read in
## render.gd's _fold_rig printed an engine ERROR for the missing key here.

const RD := preload("res://scripts/fp/traffic/render.gd")


func _initialize() -> void:
	var node := Node3D.new()
	root.add_child(node)
	var r := RD.new()
	# A plain pooled body: no rig meta at all.
	r.call("_fold_rig", node)
	# A node whose rig meta is not a rig: the typeof guard's path.
	node.set_meta("backhoe_arm_rig", 5)
	r.call("_fold_rig", node)
	node.remove_meta("backhoe_arm_rig")
	node.free()
	print("FP_FOLD_CHECK: DONE")
	quit(0)
