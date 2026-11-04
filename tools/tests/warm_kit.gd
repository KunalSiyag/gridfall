extends RefCounted
## Fixtures the warm-up tests share (fp_warmup_test, fp_warmup_variants_test): a tiny scene with
## known recipes, a fake Main that stands in for the real one, and the warm-up's tuning file.
## Static only.

const TUNING := "user://warmup_tuning.json"


class FakeMain:
	extends Node3D
	var cam: Camera3D
	var fp: Variant = null
	var sun_light: DirectionalLight3D

	func active_camera() -> Camera3D:
		return cam


static func clear_tuning() -> void:
	if FileAccess.file_exists(TUNING):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TUNING))


static func write_tuning(d: Dictionary) -> void:
	var f := FileAccess.open(TUNING, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()


## kind 0: opaque lit; 1: alpha blended; 2: unshaded (three shader families, so three recipes).
static func mat(color: Color, kind: int = 0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if kind == 1:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	elif kind == 2:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


static func mesh_inst(mesh: Mesh, pos: Vector3, mat: Material = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	if mat != null:
		mi.material_override = mat
	return mi


## A scene with known recipes: a shared material on a small and a big box (one recipe, the small
## mesh wins), the same material on a MultiMesh (its own recipe), a second material, a skinned mesh
## and an empty node (no recipe).
static func scene() -> Dictionary:
	var root := Node3D.new()
	var red := mat(Color.RED)
	var blue := mat(Color.BLUE, 1)
	var small := BoxMesh.new()
	small.size = Vector3.ONE
	small.material = red
	var big := SphereMesh.new()
	big.material = red
	var a := mesh_inst(small, Vector3(10, 0, 0))
	var b := mesh_inst(big, Vector3(2, 0, 0))
	var c := mesh_inst(BoxMesh.new(), Vector3(30, 0, 0), blue)
	var skinned := mesh_inst(BoxMesh.new(), Vector3.ZERO, mat(Color.GREEN, 2))
	skinned.skin = Skin.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = small
	mm.instance_count = 3
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.position = Vector3(5, 0, 0)
	for n: Node in [a, b, c, skinned, mmi, Node3D.new(), MeshInstance3D.new()]:
		root.add_child(n)
	return {
		"root": root,
		"a": a,
		"b": b,
		"c": c,
		"mmi": mmi,
		"red": red,
		"blue": blue,
		"small": small,
		"big": big
	}


static func fake_main(root: Node, with_cam: bool = true) -> FakeMain:
	var m := FakeMain.new()
	m.name = "FakeMain"
	root.add_child(m)
	var s := scene()
	m.add_child(s["root"] as Node)
	if with_cam:
		m.cam = Camera3D.new()
		m.add_child(m.cam)
	return m
