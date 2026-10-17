extends SceneTree
func _bb(n: Node, xf: Transform3D, acc: Array) -> void:
	var t := xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var a: AABB = t * (n as MeshInstance3D).mesh.get_aabb()
		acc[0] = a if acc[0] == null else (acc[0] as AABB).merge(a)
	for c in n.get_children():
		_bb(c, t, acc)
func _init() -> void:
	for p in ["res://models/vehicles/plane.glb", "res://models/real/vehicles/plane.glb", "res://models/vehicles/boat_tug.glb", "res://models/real/vehicles/boat_tug.glb", "res://models/vehicles/helicopter.glb", "res://models/real/vehicles/helicopter.glb", "res://models/vehicles/firetruck.glb", "res://models/real/vehicles/firetruck.glb"]:
		if not ResourceLoader.exists(p):
			print(p, " missing")
			continue
		var n: Node = (load(p) as PackedScene).instantiate()
		var acc: Array = [null]
		_bb(n, Transform3D.IDENTITY, acc)
		print(p, " size=", (acc[0] as AABB).size, " pos=", (acc[0] as AABB).position)
		n.free()
	quit()
