extends RefCounted
## The weapons the hero can pick up (the melee feature): what each one is and its mesh, built here
## from a lathe profile, so no model files are needed. A weapon's mesh runs along +Y from the grip
## (the origin, where the fist closes) to its tip.

const WS := preload("res://scripts/fp/world_scale.gd")
## kind -> {"label", "strength" (0..1, the blow), "reach" (m past a fist's), "breaks" (on the
## first blow that lands)}. A bat's blow makes people reel (the third in a row puts them down), a
## pipe's and a bottle's knock them down.
const KINDS := {
	"bat": {"label": "baseball bat", "strength": 0.62, "reach": 0.5, "breaks": false},
	"pipe": {"label": "steel pipe", "strength": 0.75, "reach": 0.45, "breaks": false},
	"bottle": {"label": "bottle", "strength": 0.8, "reach": 0.1, "breaks": true},
}
## Lathe profiles: [height along the weapon (m), radius (m)] from the grip end to the tip.
const PROFILES := {
	"bat":
	[
		[-0.1, 0.0],
		[-0.1, 0.022],
		[-0.085, 0.024],
		[-0.075, 0.014],
		[0.2, 0.015],
		[0.38, 0.022],
		[0.55, 0.031],
		[0.72, 0.034],
		[0.735, 0.033],
		[0.74, 0.0],
	],
	"pipe": [[-0.08, 0.0], [-0.08, 0.017], [0.67, 0.017], [0.67, 0.0]],
	"bottle":
	[
		[-0.03, 0.0],
		[-0.03, 0.013],
		[-0.02, 0.011],
		[0.05, 0.012],
		[0.1, 0.03],
		[0.13, 0.036],
		[0.27, 0.036],
		[0.275, 0.03],
		[0.275, 0.0],
	],
}
const SIDES := 12


## The mesh of kind (one surface, its material set).
static func mesh(kind: String) -> ArrayMesh:
	var prof: Array = PROFILES[kind]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in range(prof.size() - 1):
		var a: Array = prof[k]
		var b: Array = prof[k + 1]
		for s in range(SIDES):
			var t0 := TAU * s / SIDES
			var t1 := TAU * (s + 1) / SIDES
			var p00 := _ring(a, t0)
			var p01 := _ring(a, t1)
			var p10 := _ring(b, t0)
			var p11 := _ring(b, t1)
			for p: Vector3 in [p00, p10, p11, p00, p11, p01]:
				st.add_vertex(p * WS.M)
	st.generate_normals()
	var m := st.commit()
	m.surface_set_material(0, material(kind))
	return m


static func _ring(pt: Array, t: float) -> Vector3:
	var r := float(pt[1])
	return Vector3(cos(t) * r, float(pt[0]), sin(t) * r)


static func material(kind: String) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	match kind:
		"bat":
			mat.albedo_color = Color(0.62, 0.45, 0.28)
			mat.roughness = 0.55
		"pipe":
			mat.albedo_color = Color(0.52, 0.53, 0.55)
			mat.metallic = 0.85
			mat.roughness = 0.4
		_:
			mat.albedo_color = Color(0.16, 0.42, 0.2, 0.8)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.roughness = 0.08
			mat.metallic_specular = 0.9
	return mat
