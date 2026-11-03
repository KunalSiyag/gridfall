extends RefCounted
## The skinned vertices of a drawn body (a people_kit body), for the carjack tests that measure the
## body itself and not its bones: every STRIDE-th vertex of its meshes, posed as it is drawn now
## (the skin's bind poses on the skeleton's bones), in the frame asked for. The mesh data is read
## once per mesh.

const STRIDE := 6

var _meshes: Dictionary = {}


## Every STRIDE-th vertex of body b's meshes in the frame inv (the world to the frame wanted, the
## identity for the world's), divided by scale (the world's units per metre for metres).
func points(
	b: Object, inv: Transform3D = Transform3D.IDENTITY, scale: float = 1.0
) -> PackedVector3Array:
	var sk: Skeleton3D = b.get("skel")
	var out := PackedVector3Array()
	var sk_xf := inv * sk.global_transform
	for g: Variant in b.get("meshes"):
		var mi := g as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var data := _mesh_data(mi)
		var vs: PackedVector3Array = data[0]
		var bones: PackedInt32Array = data[1]
		var weights: PackedFloat32Array = data[2]
		var per: int = data[3]
		var skin: Skin = mi.skin
		var mats: Array[Transform3D] = []
		for i in range(skin.get_bind_count()):
			var bone := skin.get_bind_bone(i)
			if bone < 0:
				bone = sk.find_bone(skin.get_bind_name(i))
			mats.append(
				(
					sk.get_bone_global_pose(bone) * skin.get_bind_pose(i)
					if bone >= 0
					else Transform3D()
				)
			)
		for i in range(vs.size()):
			var acc := Vector3.ZERO
			for j in range(per):
				var w := weights[i * per + j]
				if w > 0.0:
					acc += w * (mats[bones[i * per + j]] * vs[i])
			out.append(sk_xf * acc / scale)
	return out


## The followed vertices of mesh instance mi's mesh, their bone indices and weights (per of each),
## read once: [vertices, bones, weights, per].
func _mesh_data(mi: MeshInstance3D) -> Array:
	var key := mi.mesh.get_instance_id()
	if _meshes.has(key):
		return _meshes[key]
	var vs := PackedVector3Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var per := 4
	for s in range(mi.mesh.get_surface_count()):
		var arr := mi.mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bo: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var we: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		per = bo.size() / maxi(v.size(), 1)
		for i in range(0, v.size(), STRIDE):
			vs.append(v[i])
			for j in range(per):
				bones.append(bo[i * per + j])
				weights.append(we[i * per + j])
	var out := [vs, bones, weights, per]
	_meshes[key] = out
	return out
