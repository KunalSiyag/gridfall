extends SceneTree
## The look-polish pass (unit D3, flag look_polish): wet surfaces, the lawn, the shore stones and the
## door camera. Pins what a loaded material or a placement carries: both street shaders declare the
## `polish` uniform and parse, the flag writes it (0 only when the flag is off, nothing when on, so
## the shader's default 1 stands), the shore has more stones with it than without and the same city
## gives the same stones, a stone clustered beside another is smaller and near it, the stones are
## built again when the props pack arrives late, and the door camera for a tall body looks from higher
## and further off the door than for a low one.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const SHORE := preload("res://scripts/world/shore.gd")
const GROUND := "res://shaders/ground_detail.gdshader"
const ROAD := "res://shaders/road_fp.gdshader"
const DOORCAM := preload("res://scripts/fp/drive/door_camera.gd")

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_shaders()
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "ticks": 30, "player": true})
	var view := ctx.view
	view.set_fp_mode(true)
	_check_flag(ctx, view)
	_check_stones(ctx.sim)
	_check_retry(ctx.sim, view)
	_check_door_camera()
	FeatureFlags.set_override("look_polish", true)
	K.finish(self, "FP_LOOK_POLISH_TEST", fails)


func _uniforms(path: String) -> Array[String]:
	var out: Array[String] = []
	var sh := load(path) as Shader
	if sh != null:
		for u: Dictionary in sh.get_shader_uniform_list():
			out.append(str(u["name"]))
	return out


func _check_shaders() -> void:
	K.check(fails, _uniforms(ROAD).has("polish"), "road_fp.gdshader declares polish and parses")
	K.check(fails, _uniforms(GROUND).has("polish"), "ground_detail.gdshader declares polish")


## The flag is read when the base materials are made: on leaves the shader's default 1 alone, off
## writes 0 on the ground material (and the lawn, lot, bank and track copies of it), the road
## material and every variant and surface made from it.
func _check_flag(ctx: FpContext, view: CityView) -> void:
	FeatureFlags.set_override("look_polish", true)
	var on_ground := view._ground_shader_material()
	K.check(
		fails,
		on_ground.get_shader_parameter("polish") == null,
		"flag on: the ground shader keeps its own default polish"
	)
	var road_on := view.road_fp_material()
	K.check(
		fails,
		road_on != null and road_on.get_shader_parameter("polish") == null,
		"flag on: the road shader keeps its own default polish"
	)
	FeatureFlags.set_override("look_polish", false)
	var off_ground := view._ground_shader_material()
	K.check(
		fails,
		is_equal_approx(float(off_ground.get_shader_parameter("polish")), 0.0),
		"flag off: the ground shader's polish is 0"
	)
	var view2 := K.make_view(get_root(), ctx.sim)
	view2.set_fp_mode(true)
	var road_off := view2.road_fp_material()
	var paint := view2.surface_material(2)
	var axis := view2.road_fp_material_for(1)
	K.check(
		fails,
		road_off != null and is_equal_approx(float(road_off.get_shader_parameter("polish")), 0.0),
		"flag off: the road material's polish is 0"
	)
	K.check(
		fails,
		paint != null and is_equal_approx(float(paint.get_shader_parameter("polish")), 0.0),
		"flag off: a kerb material made from it is at 0"
	)
	K.check(
		fails,
		axis != null and is_equal_approx(float(axis.get_shader_parameter("polish")), 0.0),
		"flag off: a lane variant is at 0"
	)
	var lawn := view2.lawn_material()
	K.check(
		fails,
		lawn != null and is_equal_approx(float(lawn.get_shader_parameter("polish")), 0.0),
		"flag off: the lawn copy is at 0"
	)
	view2.queue_free()
	FeatureFlags.set_override("look_polish", true)


## The default stones: more than the first look's, deterministic, on the shore, at most two to a
## tile; a clustered second stone is smaller than the first and within CLUSTER of it.
func _check_stones(sim: CitySim) -> void:
	var on := ShoreRocks.placements(sim, true)
	var on2 := ShoreRocks.placements(sim, true)
	var off := ShoreRocks.placements(sim, false)
	var n_on := _count(on)
	var n_off := _count(off)
	K.check(fails, _count(on2) == n_on, "the polished stones are deterministic")
	K.check(
		fails,
		n_on > n_off,
		"more stones along the banks with the polish (%d, %d without)" % [n_on, n_off]
	)
	var mask := SHORE.mask(sim)
	var shore_tiles := 0
	for v in mask:
		shore_tiles += int(v)
	K.check(
		fails,
		n_on <= shore_tiles * 2 and n_on <= shore_tiles * 9 / 10 + shore_tiles / 4,
		"at most two stones to a shore tile (%d, %d tiles)" % [n_on, shore_tiles]
	)
	var on_shore := true
	var smaller := 0
	var pairs := 0
	for key: Vector2i in on.keys():
		var xs: Array[Transform3D] = on[key]
		for xf in xs:
			var tile := Vector2i(roundi(xf.origin.x), roundi(xf.origin.z))
			on_shore = (
				on_shore and D.in_bounds(tile.x, tile.y) and mask[D.idx(tile.x, tile.y)] != 0
			)
		# Stones of one tile are adjacent in the list: a second within CLUSTER of the one before.
		for j in range(1, xs.size()):
			var d := Vector2(xs[j].origin.x - xs[j - 1].origin.x, xs[j].origin.z - xs[j - 1].origin.z)
			if d.length() <= ShoreRocks.CLUSTER + 0.001:
				pairs += 1
				if xs[j].basis.get_scale().x < xs[j - 1].basis.get_scale().x:
					smaller += 1
	K.check(fails, on_shore, "every polished stone lies on a land tile at the water")
	K.check(fails, pairs > 0, "some stones come in clustered pairs (%d)" % pairs)
	K.check(
		fails, smaller * 10 >= pairs * 8, "a clustered stone is the smaller (%d of %d)" % [smaller, pairs]
	)


func _count(by_chunk: Dictionary) -> int:
	var n := 0
	for key: Vector2i in by_chunk.keys():
		n += (by_chunk[key] as Array).size()
	return n


## A split web build mounts the props pack after the first view: the stones are built then, once.
func _check_retry(sim: CitySim, view: CityView) -> void:
	var held := view.get("_rocks_node") as Node3D
	if is_instance_valid(held):
		held.free()
	view.set("_rocks_node", null)
	view._on_pack_ready("props")
	var again := view.get("_rocks_node") as Node3D
	K.check(fails, again != null, "the props pack arriving builds the stones again")
	K.check(fails, again != null and again.visible, "and they show on foot")
	view._on_pack_ready("props")
	K.check(
		fails,
		view.get("_rocks_node") == again,
		"a second arrival leaves the stones as they are (built once)"
	)
	view._on_pack_ready("traffic")
	K.check(fails, view.get("_rocks_node") == again, "another pack changes nothing")


## The door camera: a tall body (a van) is watched from higher and a little further off its door
## than a low one (a coupe), and any body still gets a frame that looks at the door.
func _check_door_camera() -> void:
	var pts := {
		"hinge": Vector3(0.9, 0.0, 0.7) * WS.M,
		"rear": Vector3(0.9, 0.0, -0.2) * WS.M,
		"seat": Vector3(0.4, 0.0, 0.2) * WS.M
	}
	var xf := Transform3D.IDENTITY
	var low := DOORCAM.frame(null, xf, pts, 0.9 * WS.M, 1.3 * WS.M)
	var tall := DOORCAM.frame(null, xf, pts, 0.9 * WS.M, 2.0 * WS.M)
	var cam_low := DOORCAM.at(low, 0.0)
	var cam_tall := DOORCAM.at(tall, 0.0)
	var rise_low := (cam_low.origin.y - (low["focus"] as Vector3).y) / WS.M
	var rise_tall := (cam_tall.origin.y - (tall["focus"] as Vector3).y) / WS.M
	K.check(
		fails,
		rise_tall > rise_low + 0.3,
		"a tall body is watched from higher over its door (%.2f m vs %.2f m)" % [rise_tall, rise_low]
	)
	var look_low := -cam_low.basis.z
	var to_low := ((low["focus"] as Vector3) - cam_low.origin).normalized()
	K.check(fails, look_low.dot(to_low) > 0.999, "the low-body camera looks at its focus")
	var to_tall := ((tall["focus"] as Vector3) - cam_tall.origin).normalized()
	K.check(fails, (-cam_tall.basis.z).dot(to_tall) > 0.999, "the tall-body camera looks at its focus")
