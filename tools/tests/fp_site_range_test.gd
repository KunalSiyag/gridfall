extends SceneTree
## Construction-site parts carry visibility ranges on foot (FAR for parts, CRANE_FAR for the big
## ones). On the web tier those ranges must scale by the quality preset's vis_mult like the props
## around them — the day-10 census counted ~590 site draws in one street view, most beyond the
## prop range. Desktop keeps the absolute ranges; orbit keeps drawing everything.

const CK := preload("res://scripts/world/construction_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")

var _fail := 0


func _check(ok: bool, name: String) -> void:
	if ok:
		print("PASS ", name)
	else:
		_fail += 1
		print("FAIL ", name)


func _site(fp: bool, vis: float) -> Node3D:
	var view := CityView.new()
	root.add_child(view)
	view.fp_mode = fp
	view.vis_mult = vis
	var kit := CK.new(view)
	var holder := Node3D.new()
	root.add_child(holder)
	var s := {"type": "build", "plan": "build", "target_kind": D.ZONE_C}
	return kit.build_site(
		holder, s, "frame", 0.2, {"h": 7, "height": 1.2, "foot": Vector2(0.7, 0.7)}
	)


func _ends(site: Node3D) -> Array[float]:
	var out: Array[float] = []
	for n in site.find_children("*", "GeometryInstance3D", true, false):
		out.append((n as GeometryInstance3D).visibility_range_end)
	return out


func _any(ends: Array[float], want: float) -> bool:
	for e in ends:
		if is_equal_approx(e, want):
			return true
	return false


func _initialize() -> void:
	var web := _ends(_site(true, 0.55))
	_check(web.size() > 20, "the frame stage builds a full site (%d parts)" % web.size())
	_check(_any(web, CK.FAR * 0.55), "web parts range at the scaled prop distance")
	_check(_any(web, CK.CRANE_FAR * 0.55), "the crane carries the scaled far range")
	_check(
		not _any(web, CK.FAR) and not _any(web, CK.CRANE_FAR), "no web part keeps a desktop range"
	)
	var desk := _ends(_site(true, 1.0))
	_check(_any(desk, CK.FAR) and _any(desk, CK.CRANE_FAR), "desktop keeps the absolute ranges")
	var orbit := _ends(_site(false, 0.55))
	var unranged := 0
	for e in orbit:
		if e != 0.0:
			unranged += 1
	_check(unranged == 0, "orbit draws every site part (%d ranged)" % unranged)
	if _fail == 0:
		print("FP_SITE_RANGE_TEST: PASS")
		quit(0)
	else:
		print("FP_SITE_RANGE_TEST: FAIL (", _fail, ")")
		quit(1)
