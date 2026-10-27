extends SceneTree
## Instance-uniform budget. The Compatibility renderer (the web build) keeps every instance uniform
## in one 4096-slot buffer, and each mesh drawn with a shader that declares one takes a slot whether
## or not anything sets it; past 4096 the engine refuses the allocation and then crashes. A grown
## street-level city draws thousands of ground, lawn, road and site meshes, so those shaders must
## not declare any: per-tile and per-coat values live in shared material variants instead
## (CityView.track_material_for, CityView.road_fp_material_for, cat_bodies.material_for).
## Checks: no shader the city draws in bulk declares an instance uniform; no script sets one; a
## grown city with dirt tracks and a cat stays under BUDGET users; the variants are shared, carry
## their values and follow wetness, rain and the orbit/street switch.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const CB := preload("res://scripts/fp/animals/cat_bodies.gd")
## Well under Compatibility's 4096 slots, leaving room for cities far larger than the test's.
const BUDGET := 512
const BULK_SHADERS := [
	"res://shaders/ground_detail.gdshader",
	"res://shaders/road_fp.gdshader",
	"res://scripts/fp/animals/cat_coat.gdshader",
]
## The parameters these shaders used to take per instance.
const OLD_NAMES := [
	&"lane_axis", &"track_mask", &"track_grade", &"base", &"stripe", &"patch_col", &"look"
]
const SCAN_DIRS := ["res://shaders/", "res://scripts/"]

var fails: Array[String] = []
var _declares: Dictionary = {}


func _init() -> void:
	await process_frame
	_check_sources()
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "ticks": 60, "player": true})
	var sim := ctx.sim
	var view := ctx.view
	var tracks := _lay_tracks(sim)
	view.set_fp_mode(true)
	if view.has_method("flush_rebuild_queue"):
		view.call("flush_rebuild_queue")
	view.rebuild_all(false)
	var cat := _stage_cat()
	_check_budget(tracks)
	_check_variants(view)
	_check_cat(cat)
	K.finish(self, "FP_INSTANCE_UNIFORMS_TEST", fails)


## No bulk shader declares an instance uniform, and no script sets one.
func _check_sources() -> void:
	for path: String in BULK_SHADERS:
		var sh := load(path) as Shader
		K.check(
			fails,
			sh != null and not _declares_instance(sh),
			"%s declares no instance uniform" % path
		)
	var setters: Array[String] = []
	for dir: String in SCAN_DIRS:
		_scan(dir, setters)
	K.check(
		fails, setters.is_empty(), "no script sets an instance shader parameter (%s)" % str(setters)
	)


func _scan(dir: String, setters: Array[String]) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for sub in da.get_directories():
		_scan(dir.path_join(sub), setters)
	for f in da.get_files():
		if not f.ends_with(".gd"):
			continue
		var path := dir.path_join(f)
		if FileAccess.get_file_as_string(path).contains("set_instance_shader_parameter("):
			setters.append(path)


## A column of one-tile dirt tracks beside the founding road (instant), so the city draws track
## quads of several masks and grades. Returns how many the sim accepted.
func _lay_tracks(sim: CitySim) -> int:
	sim.construction_mode = "instant"
	sim.mayors[0]["treasury"] = 200000
	var laid := 0
	for y in range(13, 19):
		for grade: String in ["gravel", "track"]:
			var x := 4 if grade == "gravel" else 6
			var r := sim.apply_action(
				0, {"type": "road", "x": x, "y": y, "x2": x, "y2": y, "grade": grade}
			)
			if bool(r.get("ok", false)):
				laid += 1
	return laid


func _stage_cat() -> Node3D:
	var cb := CB.new()
	cb.blocking = true
	var holder := Node3D.new()
	holder.name = "BudgetCat"
	get_root().add_child(holder)
	var b := cb.make("cat", 0.25, holder)
	if b == null or b.root == null:
		return null
	CB.dress(b, "calico")
	CB.dress(b, "tuxedo")
	return b.root


## Every GeometryInstance3D in the tree: those drawn with a shader declaring an instance uniform,
## or carrying one of the old per-instance values, take a Compatibility slot.
func _check_budget(tracks: int) -> void:
	var users := 0
	var meshes := 0
	var track_quads := 0
	for n in get_root().find_children("*", "GeometryInstance3D", true, false):
		var g := n as GeometryInstance3D
		meshes += 1
		if g.name == &"Track":
			track_quads += 1
		var uses := false
		for m: Material in _materials(g):
			if m is ShaderMaterial and _declares_instance((m as ShaderMaterial).shader):
				uses = true
		for nm: StringName in OLD_NAMES:
			uses = uses or g.get_instance_shader_parameter(nm) != null
		if uses:
			users += 1
	var msg := "fixture: %d track quads drawn (%d laid by the test)" % [track_quads, tracks]
	K.check(fails, tracks >= 1 and track_quads >= 6, msg)
	K.check(fails, meshes > 1000, "fixture: a grown street-level city (%d meshes)" % meshes)
	K.check(
		fails,
		users <= BUDGET,
		(
			"%d of %d meshes take an instance-uniform slot (budget %d of 4096)"
			% [users, meshes, BUDGET]
		)
	)


func _materials(g: GeometryInstance3D) -> Array[Material]:
	var out: Array[Material] = []
	if g.material_override != null:
		out.append(g.material_override)
	if g.material_overlay != null:
		out.append(g.material_overlay)
	var mi := g as MeshInstance3D
	if mi != null and mi.mesh != null:
		for s in range(mi.mesh.get_surface_count()):
			var m := mi.get_surface_override_material(s)
			if m == null:
				m = mi.mesh.surface_get_material(s)
			if m != null:
				out.append(m)
	return out


## The variants are shared per value, carry it, and follow wetness, rain and the view mode.
func _check_variants(view: CityView) -> void:
	var a := view.track_material_for(5, 2) as ShaderMaterial
	var b := view.track_material_for(5, 2) as ShaderMaterial
	var c := view.track_material_for(5, 1) as ShaderMaterial
	K.check(fails, a != null and a == b and a != c, "one shared track material per (mask, grade)")
	if a != null and c != null:
		var vals := [a.get_shader_parameter("track_mask"), a.get_shader_parameter("track_grade")]
		K.check(
			fails,
			vals == [5.0, 2.0] and float(c.get_shader_parameter("track_grade")) == 1.0,
			"track variants carry mask and grade (%s)" % str(vals)
		)
	var r3 := view.road_fp_material_for(3)
	K.check(
		fails,
		r3 != null and r3 == view.road_fp_material_for(3) and r3 != view.road_fp_material_for(1),
		"one shared asphalt material per lane axis"
	)
	if r3 == null or a == null:
		return
	K.check(
		fails,
		float(r3.get_shader_parameter("lane_axis")) == 3.0,
		"the asphalt variant carries its lane axis"
	)
	view.set_wetness(0.7)
	view.set_rain(1.0)
	var wet := is_equal_approx(float(a.get_shader_parameter("wetness")), 0.7)
	wet = wet and is_equal_approx(float(r3.get_shader_parameter("wetness")), 0.7)
	K.check(
		fails,
		wet and float(r3.get_shader_parameter("rain")) == 1.0,
		"variants follow wetness and rain"
	)
	view.set_wetness(0.0)
	view.set_rain(0.0)
	view.set_fp_mode(false)
	var cut := bool(a.get_shader_parameter("cut_grass"))
	view.set_fp_mode(true)
	K.check(
		fails,
		cut and not bool(a.get_shader_parameter("cut_grass")),
		"track variants cut the grass in orbit only"
	)


## A re-dressed (pooled) cat swaps to the new coat's shared material.
func _check_cat(cat: Node3D) -> void:
	K.check(fails, cat != null, "fixture: a cat body loads")
	if cat == null:
		return
	var coated := 0
	var right := true
	for n in cat.find_children("*", "GeometryInstance3D", true, false):
		var m := (n as GeometryInstance3D).material_override
		if m is ShaderMaterial and (m as ShaderMaterial).shader == CB.COAT_SHADER:
			coated += 1
			right = right and m == CB.material_for("tuxedo")
	var look: Variant = CB.material_for("tuxedo").get_shader_parameter(&"look")
	K.check(
		fails,
		coated > 0 and right and look == CB.COATS["tuxedo"][3],
		"a re-dressed cat wears its new coat's shared material (%d meshes)" % coated
	)
	K.check(
		fails,
		CB.material_for("no such coat") == CB.material_for("brown tabby"),
		"an unknown coat gives the brown tabby"
	)


func _declares_instance(sh: Shader) -> bool:
	if sh == null:
		return false
	var key := sh.resource_path if not sh.resource_path.is_empty() else str(sh.get_instance_id())
	if not _declares.has(key):
		var found := false
		for line in sh.code.split("\n"):
			var t := line.strip_edges()
			if t.begins_with("instance uniform"):
				found = true
		_declares[key] = found
	return _declares[key]
