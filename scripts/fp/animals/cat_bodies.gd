extends "res://scripts/fp/animals/dog_bodies.gd"
## The cats' bodies: Quaternius' Cat (AP.CAT, built by tools/blender/make_cat.py), loaded, pooled
## and scaled as the dogs' bodies are (dog_bodies.gd), with a CatRig on the skeleton for the tail
## and the head and the coat shader (cat_coat.gdshader) on the body; dress() gives a body its coat.

const DB := preload("res://scripts/fp/animals/dog_bodies.gd")
const CAT_RIG := preload("res://scripts/fp/animals/cat_rig.gd")
const COAT_SHADER := preload("res://scripts/fp/animals/cat_coat.gdshader")

## The cat's scene and height at the shoulder (m); the shoulder stands CAT_UNITS model units high.
const CATS := {"cat": {"path": AP.CAT, "shoulder_m": 0.25}}
const CAT_UNITS := 2.6
## Model units per second the paws cover at clip rate 1.
const GAITS := {&"Stalk": 0.667, &"Walk": 1.822, &"Trot": 4.889, &"Run": 9.6}
## The coats: [base, stripe, patch colour, look (x how strong the tabby's stripes are, y how far
## the white spreads, z how much of the coat is patched, w the eyes from green 0 to amber 1)].
const COATS := {
	"brown tabby":
	[Color(0.43, 0.32, 0.21), Color(0.09, 0.07, 0.05), Color.BLACK, Vector4(1.0, 0.0, 0.0, 0.7)],
	"silver tabby":
	[Color(0.66, 0.66, 0.64), Color(0.08, 0.08, 0.08), Color.BLACK, Vector4(1.0, 0.0, 0.0, 0.2)],
	"ginger":
	[Color(0.86, 0.48, 0.2), Color(0.6, 0.27, 0.08), Color.BLACK, Vector4(0.8, 0.14, 0.0, 0.9)],
	"black": [Color(0.035, 0.032, 0.03), Color.BLACK, Color.BLACK, Vector4(0.0, 0.0, 0.0, 1.0)],
	"tuxedo": [Color(0.035, 0.032, 0.03), Color.BLACK, Color.BLACK, Vector4(0.0, 0.42, 0.0, 0.4)],
	"grey":
	[Color(0.4, 0.42, 0.45), Color(0.3, 0.31, 0.34), Color.BLACK, Vector4(0.3, 0.0, 0.0, 0.8)],
	"calico":
	[
		Color(0.85, 0.5, 0.22),
		Color(0.6, 0.3, 0.1),
		Color(0.05, 0.045, 0.04),
		Vector4(0, 0.6, 0.5, 0.8)
	],
	"tortoiseshell":
	[Color(0.07, 0.05, 0.04), Color.BLACK, Color(0.62, 0.32, 0.12), Vector4(0, 0.0, 0.45, 0.9)],
	"white": [Color(0.9, 0.89, 0.86), Color.BLACK, Color.BLACK, Vector4(0.0, 1.2, 0.0, 0.3)],
}

static var _mat: ShaderMaterial = null


func _init() -> void:
	breeds = CATS
	shoulder_units = CAT_UNITS
	label = "Cat"


## The coat material every cat shares (each cat's colours are instance uniforms).
static func material() -> ShaderMaterial:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = COAT_SHADER
	return _mat


## Gives b coat (a COATS key; a stand-in keeps its box).
static func dress(b: DB.Body, coat: String) -> void:
	var c: Array = COATS.get(coat, COATS["brown tabby"])
	for n: Node in b.root.find_children("*", "GeometryInstance3D", true, false):
		var g := n as GeometryInstance3D
		if g.material_override != material():
			continue
		g.set_instance_shader_parameter(&"base", c[0])
		g.set_instance_shader_parameter(&"stripe", c[1])
		g.set_instance_shader_parameter(&"patch_col", c[2])
		g.set_instance_shader_parameter(&"look", c[3])


## Ground speed (u/s) b covers playing gait clip at rate 1.
static func clip_speed(b: DB.Body, clip: StringName) -> float:
	return float(GAITS.get(clip, GAITS[&"Walk"])) * b.unit


func _bind(b: DB.Body, scene: Node3D) -> void:
	b.collar = b.skel.find_bone("Neck")
	b.head = b.skel.find_bone("Head")
	var rig := CAT_RIG.new()
	rig.name = "CatRig"
	b.skel.add_child(rig)
	rig.bind(b.skel, scene, CAT_RIG.CAT_TAIL, "Neck")
	b.rig = rig
	for n: Node in scene.find_children("*", "MeshInstance3D", true, false):
		(n as MeshInstance3D).material_override = material()
