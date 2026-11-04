class_name SurfaceMaterials
extends RefCounted
## The street-level paved surfaces besides the carriageway (materials unit G2): pavement slabs, kerb
## stone, poured concrete and lane paint are all shaders/road_fp.gdshader with a different `surface`
## value, so the browser links one program set for every paved surface (a new shader costs boot
## time) and no mesh needs an instance uniform (Compatibility has 4096 slots for those). CityView
## owns the base asphalt material (road_fp_material) and one instance of this; material() hands out
## one shared copy of it per surface kind, and CityView.set_wetness() darkens and glosses them all.
##
## Also the one place that says how rough the plain ground classes are. The scanned roughness maps
## (grass, dirt, asphalt, sidewalk) were near flat (std 0.008 to 0.021 over the image; means 0.69
## grass, 0.94 dirt, 0.77 asphalt, 0.86 sidewalk) and cost 0.7 MB each on the web, so the materials
## take a constant instead (matching the shaders'). Grass moves from about 0.69 to 0.9 on purpose.

## The surface kinds, as shaders/road_fp.gdshader's `surface` uniform (0 is the asphalt itself).
const PAVEMENT := 1
const KERB := 2
const CONCRETE := 3
const PAINT := 4
const KINDS := [PAVEMENT, KERB, CONCRETE, PAINT]
const TEX := "res://textures/real/"
## Roughness by ground class (the texture-name key of CityView._pbr): bare earth the roughest, then
## grass; paving and asphalt are smoother.
const ROUGHNESS := {"grass": 0.9, "dirt": 0.94, "asphalt": 0.78, "sidewalk": 0.84}
## Imported model materials (resource-name prefixes) that lie flat on the ground and are seen at a
## grazing angle: they get anisotropic filtering (the GLBs import with plain trilinear, which blurs
## a pavement a few metres away to its average).
const GROUND_PREFIXES := [
	"Sidewalk",
	"Curb",
	"Asphalt",
	"Dirt",
	"Grass",
	"Gravel",
	"Concrete_Floor",
	"Court",
	"Track",
	"Turf"
]

## Model material name -> surface kind, for dress().
const BY_NAME := {
	"Sidewalk": PAVEMENT, "Curb": KERB, "Concrete_Floor": CONCRETE, "Paint_White": PAINT
}
## road_fp's lane_axis for asphalt with no lanes and no junction oil (lots, car parks).
const PLAIN_AXIS := 7

var _variants: Dictionary = {}


## The roughness of ground class `name` (CityView._pbr's key); 1.0 for any other.
static func roughness_of(name: String) -> float:
	return float(ROUGHNESS.get(name, 1.0))


## Anisotropic filtering for a flat ground material of an imported model (by resource name).
static func sharpen(m: BaseMaterial3D) -> void:
	for p: String in GROUND_PREFIXES:
		if m.resource_name.begins_with(p):
			m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
			return


## Puts the street shader's version of a model's paved surface on surface s of mi, by the material's
## resource name (Sidewalk, Curb, Concrete_Floor, Paint_White, and Asphalt or Asphalt_Dark with the
## lane layout axis); false when the name is none of them or the shader is missing.
static func dress(
	mi: MeshInstance3D, s: int, nm: String, view: CityView, axis: int = PLAIN_AXIS
) -> bool:
	var mat: Material = null
	if BY_NAME.has(nm):
		mat = view.surface_material(int(BY_NAME[nm]))
	elif nm == "Asphalt" or nm == "Asphalt_Dark":
		mat = view.road_fp_material_for(axis)
	if mat == null:
		return false
	mi.set_surface_override_material(s, mat)
	return true


## The shared material for surface kind (PAVEMENT .. PAINT): a copy of base, the road shader
## material, with that kind set. Null when base is. `wetness` is what it starts with.
func material(kind: int, base: ShaderMaterial, wetness: float) -> ShaderMaterial:
	if base == null:
		return null
	if not _variants.has(kind):
		var sm := base.duplicate() as ShaderMaterial
		sm.set_shader_parameter("surface", float(kind))
		sm.set_shader_parameter("tint", Color(1.0, 1.0, 1.0))
		if kind == PAVEMENT:
			# The paver scan: three 1 m blocks across a repeat, so a repeat is 3 m.
			sm.set_shader_parameter("repeat_m", 3.0)
			for pair: Array in [
				["albedo_tex", "sidewalk_albedo.jpg"], ["normal_tex", "sidewalk_normal.jpg"]
			]:
				if ResourceLoader.exists(TEX + str(pair[1])):
					sm.set_shader_parameter(str(pair[0]), load(TEX + str(pair[1])))
		sm.set_shader_parameter("wetness", wetness)
		_variants[kind] = sm
	return _variants[kind]


## Every material handed out so far (set_wetness writes them all).
func materials() -> Array:
	return _variants.values()


## Forgets the materials (a world set up again builds its own).
func clear() -> void:
	_variants.clear()
