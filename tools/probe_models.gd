extends SceneTree
## Prints the world-space bounds of every GLB under models/real so view scales can be checked.

func _aabb(n: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	var t := xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out = t * (n as MeshInstance3D).mesh.get_aabb()
		first = false
	for c in n.get_children():
		var b := _aabb(c, t)
		if b.size == Vector3.ZERO:
			continue
		out = b if first else out.merge(b)
		first = false
	return out


func _init() -> void:
	var dirs := ["res://models/real/buildings/"]
	for z in ["r1", "r2", "r3", "c1", "c2", "c3", "i1", "i2", "i3"]:
		dirs.append("res://models/real/zones/%s/" % z)
	for sub in ["roads", "vehicles", "people", "props", "machines"]:
		dirs.append("res://models/real/%s/" % sub)
	for d: String in dirs:
		var dir := DirAccess.open(d)
		if dir == null:
			continue
		for f in dir.get_files():
			if not f.ends_with(".glb"):
				continue
			var s := load(d + f) as PackedScene
			if s == null:
				print("%s%s: LOAD FAILED" % [d, f])
				continue
			var n := s.instantiate()
			var b := _aabb(n, Transform3D())
			print("%s%s: pos=%s size=%s" % [d.trim_prefix("res://models/real/"), f, str(b.position.snapped(Vector3.ONE * 0.01)), str(b.size.snapped(Vector3.ONE * 0.01))])
			n.free()
	quit(0)
