extends SceneTree
## Drift detector for scripts/fp/world_scale.gd: derived values are consistent, and the road and
## metre constants still equal the Blender authoring values in tools/blender/realcity (roads.py
## ZA / ZS / HW / ZM and core.py M). Slice H must keep this passing.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const SLICES := ["A", "B", "C", "D", "E", "F", "G1", "G2", "H", "I"]

var fails: Array[String] = []


func _init() -> void:
	K.check(fails, is_equal_approx(WS.M * WS.TILE_M, 1.0), "M * TILE_M == 1")
	K.check(fails, is_equal_approx(WS.EYE, 1.65 * WS.M), "EYE == 1.65 m")
	K.check(fails, is_equal_approx(WS.CURB_RISE, WS.SIDEWALK_TOP - WS.ASPHALT_TOP), "CURB_RISE == SIDEWALK_TOP - ASPHALT_TOP")
	K.check(fails, is_equal_approx(WS.LANE_OFFSET, WS.ROAD_HALF / 2.0), "LANE_OFFSET == ROAD_HALF / 2")
	K.check(fails, absf(WS.VEHICLE_SCALE * 1.2 - 1.0) < 1e-6, "VEHICLE_SCALE undoes the 1.2x vehicle authoring")
	K.check(fails, WS.TIME_SCALES == [1, 2, 4, 8], "TIME_SCALES are 1, 2, 4, 8")
	K.check(fails, is_equal_approx(WS.FP_DAY_SECONDS, 1200.0), "FP day is 20 minutes")

	var roads := FileAccess.get_file_as_string("res://tools/blender/realcity/roads.py")
	var core := FileAccess.get_file_as_string("res://tools/blender/realcity/core.py")
	K.check(fails, not roads.is_empty() and not core.is_empty(), "roads.py and core.py are readable")
	var za := _num(roads, "ZA")
	var zs := _num(roads, "ZS")
	var hw := _num(roads, "HW")
	print("roads.py ZA=%s ZS=%s HW=%s" % [za, zs, hw])
	K.check(fails, not is_nan(za) and absf(za - WS.ASPHALT_TOP) < 1e-9, "ASPHALT_TOP == roads.py ZA")
	K.check(fails, not is_nan(zs) and absf(zs - WS.SIDEWALK_TOP) < 1e-9, "SIDEWALK_TOP == roads.py ZS")
	K.check(fails, not is_nan(hw) and absf(hw - WS.ROAD_HALF) < 1e-9, "ROAD_HALF == roads.py HW")
	var zm := RegEx.create_from_string("(?m)^ZM\\s*=\\s*ZA\\s*\\+\\s*([0-9.eE+-]+)").search(roads)
	K.check(fails, zm != null and absf((WS.MARKING_TOP - WS.ASPHALT_TOP) - zm.get_string(1).to_float()) < 1e-9, "MARKING_TOP - ASPHALT_TOP == roads.py ZM - ZA")
	var mm := RegEx.create_from_string("(?m)^M\\s*=\\s*([0-9.]+)\\s*/\\s*([0-9.]+)").search(core)
	K.check(fails, mm != null and absf(mm.get_string(1).to_float() / mm.get_string(2).to_float() - WS.M) < 1e-12, "M == core.py M")

	# Every slice owns one marked section at the end of the file, in order (S0 §4.3).
	var src := FileAccess.get_file_as_string("res://scripts/fp/world_scale.gd")
	var at := 0
	for s: String in SLICES:
		var open_at := src.find("# --- %s " % s, at)
		var close_at := src.find("# end %s\n" % s, open_at)
		K.check(fails, open_at > at and close_at > open_at, "section for slice %s is present and in order" % s)
		at = maxi(at, close_at)
	K.finish(self, "FP_WORLD_SCALE_TEST", fails)


## The float assigned to `name` at the start of a line ("ZA = 0.003  # ..."), or NAN.
func _num(src: String, name: String) -> float:
	var m := RegEx.create_from_string("(?m)^%s\\s*=\\s*([0-9.eE+-]+)\\s*(#.*)?$" % name).search(src)
	return m.get_string(1).to_float() if m != null else NAN
