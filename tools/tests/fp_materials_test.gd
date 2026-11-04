extends SceneTree
## The ground and paved surfaces read as different materials (materials unit G2). Pins what the eye
## relies on and a regression would lose quietly: the shaders parse and carry the uniforms the view
## writes (headless Godot parses a shader's uniform list, so a syntax error shows as an empty list),
## each paved surface kind is one shared material of the street shader with its own look, grass,
## asphalt, pavement and earth keep their roughness constants (no scanned roughness maps), wet
## weather reaches every surface, the imported ground materials get anisotropic filtering, and the
## shore stones are deterministic, on the shore, and bounded.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const SM := preload("res://scripts/world/surface_materials.gd")
const SHORE := preload("res://scripts/world/shore.gd")
const GROUND := "res://shaders/ground_detail.gdshader"
const ROAD := "res://shaders/road_fp.gdshader"

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_shaders()
	_check_constants()
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "ticks": 30, "player": true})
	var view := ctx.view
	view.set_fp_mode(true)
	_check_surfaces(view)
	_check_ground(view)
	_check_wetness(view)
	_check_rocks(ctx.sim, view)
	K.finish(self, "FP_MATERIALS_TEST", fails)


## A numeric shader parameter, NAN when it is unset or not a number (so a missing one fails its
## check instead of raising a script error that the PASS line would hide).
func _param(m: ShaderMaterial, pname: String) -> float:
	var v: Variant = m.get_shader_parameter(pname)
	return float(v) if v is float or v is int else NAN


func _uniforms(path: String) -> Array[String]:
	var out: Array[String] = []
	var sh := load(path) as Shader
	if sh != null:
		for u: Dictionary in sh.get_shader_uniform_list():
			out.append(str(u["name"]))
	return out


## Both shaders parse (a syntax error leaves the list empty) with the uniforms CityView writes and
## without the roughness maps they no longer sample.
func _check_shaders() -> void:
	var road := _uniforms(ROAD)
	var ground := _uniforms(GROUND)
	for name: String in [
		"albedo_tex", "normal_tex", "noise_tex", "surface", "base_y", "lane_axis", "wetness", "rain"
	]:
		K.check(fails, road.has(name), "road_fp.gdshader declares %s" % name)
	for name: String in [
		"grass_albedo",
		"grass_normal",
		"dirt_albedo",
		"dirt_normal",
		"noise_tex",
		"metre",
		"wetness",
		"track"
	]:
		K.check(fails, ground.has(name), "ground_detail.gdshader declares %s" % name)
	for name: String in road + ground:
		K.check(
			fails,
			not name.ends_with("_rough") and name != "rough_tex",
			"no roughness map uniform (%s)" % name
		)
	K.check(
		fails,
		(
			load(ROAD).get_mode() == Shader.MODE_SPATIAL
			and load(GROUND).get_mode() == Shader.MODE_SPATIAL
		),
		"both are spatial shaders"
	)


func _check_constants() -> void:
	K.check(fails, is_equal_approx(SM.roughness_of("grass"), 0.9), "grass roughness 0.9")
	K.check(fails, is_equal_approx(SM.roughness_of("asphalt"), 0.78), "asphalt roughness 0.78")
	K.check(fails, is_equal_approx(SM.roughness_of("sidewalk"), 0.84), "pavement roughness 0.84")
	K.check(fails, is_equal_approx(SM.roughness_of("dirt"), 0.94), "earth roughness 0.94")
	K.check(
		fails, is_equal_approx(SM.roughness_of("something else"), 1.0), "any other name keeps 1.0"
	)
	K.check(
		fails,
		SM.roughness_of("grass") > SM.roughness_of("asphalt"),
		"grass is rougher than asphalt"
	)
	K.check(
		fails, SM.roughness_of("dirt") > SM.roughness_of("grass"), "earth is rougher than grass"
	)
	var m := StandardMaterial3D.new()
	m.resource_name = "Sidewalk"
	SM.sharpen(m)
	K.check(
		fails,
		m.texture_filter == BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC,
		"an imported sidewalk is filtered anisotropically"
	)
	var w := StandardMaterial3D.new()
	w.resource_name = "Brick_Red"
	var before := w.texture_filter
	SM.sharpen(w)
	K.check(fails, w.texture_filter == before, "a wall keeps its filter")


## One shared material per paved surface kind, each the street shader with its own `surface`.
func _check_surfaces(view: CityView) -> void:
	var seen: Dictionary = {}
	for kind: int in SM.KINDS:
		var a := view.surface_material(kind)
		K.check(
			fails,
			a != null and a == view.surface_material(kind),
			"surface %d is one shared material" % kind
		)
		if a == null:
			continue
		K.check(
			fails,
			is_equal_approx(_param(a, "surface"), float(kind)),
			"surface %d carries its kind" % kind
		)
		K.check(
			fails,
			a.shader == view.road_fp_material().shader,
			"surface %d is the street shader (one program set)" % kind
		)
		K.check(fails, not seen.has(a), "surface %d is its own material" % kind)
		seen[a] = true
	var paving := view.surface_material(SM.PAVEMENT)
	if paving != null:
		K.check(
			fails,
			paving.get_shader_parameter("albedo_tex") != null,
			"the pavement has the paver texture"
		)
		K.check(
			fails,
			is_equal_approx(_param(paving, "repeat_m"), 3.0),
			"the pavement repeats every 3 m"
		)
	var kerb := view.surface_material(SM.KERB)
	if kerb != null:
		K.check(
			fails,
			is_equal_approx(_param(kerb, "base_y"), WS.ASPHALT_TOP),
			"the kerb knows the road's height"
		)
	var lot := view.road_fp_material_for(SM.PLAIN_AXIS)
	K.check(
		fails,
		lot != null and is_equal_approx(_param(lot, "lane_axis"), 7.0),
		"lots get asphalt with no lanes"
	)
	K.check(fails, view.apron_material() is ShaderMaterial, "the aprons are the pavement shader")
	# dress() swaps by resource name and leaves anything else alone.
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	mi.mesh = box
	K.check(fails, SM.dress(mi, 0, "Sidewalk", view), "dress takes a Sidewalk surface")
	K.check(
		fails,
		mi.get_surface_override_material(0) == view.surface_material(SM.PAVEMENT),
		"Sidewalk is the pavement"
	)
	K.check(
		fails,
		(
			SM.dress(mi, 0, "Curb", view)
			and mi.get_surface_override_material(0) == view.surface_material(SM.KERB)
		),
		"Curb is the kerb"
	)
	K.check(
		fails,
		(
			SM.dress(mi, 0, "Concrete_Floor", view)
			and mi.get_surface_override_material(0) == view.surface_material(SM.CONCRETE)
		),
		"Concrete_Floor is concrete"
	)
	K.check(
		fails,
		(
			SM.dress(mi, 0, "Paint_White", view)
			and mi.get_surface_override_material(0) == view.surface_material(SM.PAINT)
		),
		"Paint_White is paint"
	)
	K.check(
		fails,
		(
			SM.dress(mi, 0, "Asphalt", view, 2)
			and mi.get_surface_override_material(0) == view.road_fp_material_for(2)
		),
		"Asphalt takes the lane layout"
	)
	mi.set_surface_override_material(0, null)
	K.check(
		fails,
		not SM.dress(mi, 0, "Brick_Red", view) and mi.get_surface_override_material(0) == null,
		"a wall is left alone"
	)
	mi.free()


## Grass is matte with no roughness map, earth rougher, and the plain materials use the constants.
func _check_ground(view: CityView) -> void:
	var lawn := view.lawn_material()
	K.check(fails, lawn != null, "fixture: the lawn material")
	if lawn != null:
		K.check(
			fails,
			lawn.get_shader_parameter("noise_tex") != null,
			"the lawn reads the noise texture"
		)
		K.check(fails, is_equal_approx(_param(lawn, "metre"), WS.M), "the lawn knows the metre")
	for pair: Array in [["grass", 0.9], ["dirt", 0.94], ["asphalt", 0.78], ["sidewalk", 0.84]]:
		var m := view._pbr(str(pair[0]), Color.GRAY, 1.0)
		K.check(
			fails,
			m.roughness_texture == null and is_equal_approx(m.roughness, float(pair[1])),
			"%s is a constant roughness %.2f" % [pair[0], pair[1]]
		)


## Rain darkens and glosses every paved surface.
func _check_wetness(view: CityView) -> void:
	view.set_wetness(0.8)
	for kind: int in SM.KINDS:
		var a := view.surface_material(kind)
		if a != null:
			K.check(
				fails,
				is_equal_approx(_param(a, "wetness"), 0.8),
				"surface %d follows wetness" % kind
			)
	# A material made while it is wet starts wet.
	var late := view.surface_material(SM.PAINT)
	K.check(
		fails,
		late != null and is_equal_approx(_param(late, "wetness"), 0.8),
		"a surface made in the rain is wet"
	)
	view.set_wetness(0.0)
	for kind: int in SM.KINDS:
		var a := view.surface_material(kind)
		if a != null:
			K.check(fails, is_equal_approx(_param(a, "wetness"), 0.0), "surface %d dries" % kind)


## Tile units from `at` to the nearest water side or corner of land tile `tile`.
func _water_distance(sim: CitySim, tile: Vector2i, at: Vector3) -> float:
	var flags := SHORE.water_flags(sim, tile.x, tile.y)
	var local := Vector2(at.x - tile.x, at.z - tile.y)
	var best := 9.0
	for k in range(8):
		if not flags[k]:
			continue
		var toward: Vector2 = ShoreRocks.TOWARD[k]
		var d := 0.5 - local.dot(toward) if k < 4 else local.distance_to(toward * 0.5)
		best = minf(best, d)
	return best


## Stones: the same city gives the same stones, every one stands on a shore tile within its band,
## and the count is bounded.
func _check_rocks(sim: CitySim, view: CityView) -> void:
	var a := ShoreRocks.placements(sim)
	var b := ShoreRocks.placements(sim)
	K.check(fails, a.size() == b.size(), "the stones are deterministic (chunks)")
	var total := 0
	var same := true
	var on_shore := true
	var mask := SHORE.mask(sim)
	var far_from_water := 0.0
	for key: Vector2i in a.keys():
		var xa: Array[Transform3D] = a[key]
		var xb: Array[Transform3D] = b[key]
		total += xa.size()
		for j in range(xa.size()):
			same = same and xa[j] == xb[j]
			var tile := Vector2i(roundi(xa[j].origin.x), roundi(xa[j].origin.z))
			if not D.in_bounds(tile.x, tile.y) or mask[D.idx(tile.x, tile.y)] == 0:
				on_shore = false
				continue
			far_from_water = maxf(far_from_water, _water_distance(sim, tile, xa[j].origin))
	K.check(fails, same, "the stones are deterministic (transforms)")
	K.check(fails, on_shore, "every stone lies on a land tile at the water")
	var shore_tiles := 0
	for v in mask:
		shore_tiles += int(v)
	K.check(
		fails,
		total <= shore_tiles * 2,
		"at most two stones to a shore tile (%d stones, %d tiles)" % [total, shore_tiles]
	)
	# The share is a design number, not a bound that holds by construction: some stones on a bank,
	# but on well under every tile (SHARE at 100 or at 1 both fail this).
	K.check(
		fails,
		shore_tiles > 20 and total >= shore_tiles / 5 and total <= shore_tiles * 9 / 10,
		(
			"between a fifth and nine tenths of a stone per shore tile (%d stones, %d tiles)"
			% [total, shore_tiles]
		)
	)
	K.check(
		fails,
		far_from_water <= 0.11,
		"every stone sits on the sand (%.3f tile from the water at most)" % far_from_water
	)
	var mesh := ShoreRocks.load_mesh()
	K.check(fails, mesh != null, "the shipped boulder loads")
	var node := ShoreRocks.build(sim, mesh)
	if total > 0:
		K.check(
			fails, node != null and node.get_child_count() == a.size(), "one multimesh per chunk"
		)
		if node != null:
			var mmi := node.get_child(0) as MultiMeshInstance3D
			K.check(
				fails,
				mmi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
				"stones cast no shadow"
			)
			K.check(
				fails,
				(
					mmi.visibility_range_end - ShoreRocks.REACH >= 60.0 * WS.M
					and mmi.visibility_range_end - ShoreRocks.REACH <= 150.0 * WS.M
				),
				(
					"a stone is drawn out to 60 to 150 m from its chunk's centre (%.2f u)"
					% (mmi.visibility_range_end - ShoreRocks.REACH)
				)
			)
			# Each chunk's node sits at its stones' centre (a visibility range is measured from the
			# node, so a chunk at the world's origin would be culled for being far away), and the
			# stones are within a chunk's reach of it. (A headless run stores no multimesh
			# transforms, so this reads the placements, not the instances.)
			var at_centre := true
			var near_centre := true
			for child in node.get_children():
				var ids := child.name.trim_prefix("Rocks_").split("_")
				var xfs: Array[Transform3D] = a[Vector2i(int(ids[0]), int(ids[1]))]
				var centre := ShoreRocks.centre_of(xfs)
				at_centre = at_centre and (child as Node3D).position.is_equal_approx(centre)
				for xf in xfs:
					near_centre = near_centre and xf.origin.distance_to(centre) < ShoreRocks.CHUNK
			K.check(fails, at_centre, "a chunk's node sits at the centre of its stones")
			K.check(fails, near_centre, "a chunk's stones are within a chunk of its centre")
			node.free()
	K.check(fails, ShoreRocks.build(sim, null) == null, "no mesh, no stones")
	var held := view.get("_rocks_node") as Node3D
	K.check(fails, held == null or held.visible, "the stones show on foot")
	view.set_fp_mode(false)
	K.check(fails, held == null or not held.visible, "and are hidden in the Planner")
	view.set_fp_mode(true)
