extends SceneTree
## The traffic-light and sign GLBs must leave junctions._range_asset ranged: unranged, every
## lamp lens and sign face in the city drew at every distance (790 of 2732 draws on the day-10
## draw census). The range follows the quality preset's vis_mult (the web tier's 0.55), and a
## node the asset pre-ranges is left alone.

const JN := preload("res://scripts/fp/traffic/junctions.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const WS := preload("res://scripts/fp/world_scale.gd")

var _fail := 0


func _check(ok: bool, name: String) -> void:
	if ok:
		print("PASS ", name)
	else:
		_fail += 1
		print("FAIL ", name)


func _initialize() -> void:
	var jn: JN = JN.new()
	jn.vis_mult = 0.55
	var ps := AP.load_scene(AP.TRAFFIC_LIGHT)
	_check(ps != null, "traffic light asset loads")
	var inst := (ps as PackedScene).instantiate() as Node3D
	root.add_child(inst)
	var gis := inst.find_children("*", "GeometryInstance3D", true, false)
	_check(gis.size() > 0, "the asset has geometry")
	(gis[0] as GeometryInstance3D).visibility_range_end = 99.0
	jn._range_asset(inst)
	var want: float = WS.VIS_PROP * 0.55
	var unranged := 0
	var wrong := 0
	for g in gis:
		var gi := g as GeometryInstance3D
		if gi.visibility_range_end == 0.0:
			unranged += 1
		elif (
			absf(gi.visibility_range_end - want) > 0.01
			and absf(gi.visibility_range_end - 99.0) > 0.01
		):
			wrong += 1
	_check(unranged == 0, "every part ranged (%d unranged)" % unranged)
	_check(wrong == 0, "ranges follow the preset scale (%.2f, %d wrong)" % [want, wrong])
	_check(
		absf((gis[0] as GeometryInstance3D).visibility_range_end - 99.0) < 0.01,
		"a pre-ranged part keeps its own range"
	)
	_check(
		(
			(gis[1] as GeometryInstance3D).visibility_range_fade_mode
			== GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		),
		"parts fade out instead of popping"
	)
	inst.free()
	if _fail == 0:
		print("FP_JUNCTION_RANGE_TEST: PASS")
		quit(0)
	else:
		print("FP_JUNCTION_RANGE_TEST: FAIL (", _fail, ")")
		quit(1)
