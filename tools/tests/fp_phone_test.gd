extends SceneTree
## Phone Build app (integration feature "phone"): the preview rules, ordering roads, zones,
## buildings and bulldozing for the mayor who owns the land (paid from that district), refusals
## (another district, unclaimed land, debt), aiming, the phone UI, keys, driving and menus.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const RULES := preload("res://scripts/fp/phone/build_rules.gd")

var fails: Array[String] = []
var ctx: FpContext
var ph: FpFeature
var toasts: Array[String] = []


func _init() -> void:
	await process_frame
	_check_rules()
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true})
	ph = K.make_feature(ctx, "phone")
	K.check(fails, ph != null and ph.feature_id() == "phone", "the phone feature is registered")
	if ph == null:
		K.finish(self, "FP_PHONE_TEST", fails)
		return
	ph.set_process(false)
	ctx.bus.toast.connect(func(t: String, _k: String) -> void: toasts.append(t))
	var st: Dictionary = ph.self_test()
	K.check(fails, bool(st.get("ok", false)), "self_test: %s" % st.get("detail", ""))
	_check_open()
	_check_road()
	_check_other_district()
	_check_refusals()
	_check_zone_build_bulldoze()
	_check_aim()
	_check_keys()
	_check_blocked()
	await _check_teardown()
	K.finish(self, "FP_PHONE_TEST", fails)


# ------------------------------------------------------------------ helpers


func _sim() -> CitySim:
	return ctx.sim


## The first n free tiles in a row (along x) inside district mi, or [] when there is none.
func _free_row(mi: int, n: int, skip: Array = []) -> Array[Vector2i]:
	var s := _sim()
	for i in range(s.kind.size()):
		var x := D.tx(i)
		var y := D.ty(i)
		var row: Array[Vector2i] = []
		for k in range(n):
			if _free(mi, x + k, y) and not skip.has(Vector2i(x + k, y)):
				row.append(Vector2i(x + k, y))
		if row.size() == n:
			return row
	return []


func _free(mi: int, x: int, y: int) -> bool:
	if not D.in_bounds(x, y):
		return false
	var i := D.idx(x, y)
	var s := _sim()
	return s.district[i] == mi and s.kind[i] == D.EMPTY and s.terrain[i] != D.WATER


func _money(mi: int) -> int:
	return int(_sim().mayors[mi]["treasury"])


## Places tool at a (and b for two-point tools) and checks that the preview matched the result
## and that district mi paid exactly the cost.
func _order(tool: String, mi: int, a: Vector2i, b: Vector2i, what: String) -> Dictionary:
	ph.call("set_tool", tool)
	var before := _money(mi)
	if RULES.TWO_POINT.has(tool):
		ph.call("place_at", a)
	ph.call("refresh_at", b)
	var pv: Dictionary = (ph.get("preview") as Dictionary).duplicate()
	var res: Dictionary = ph.call("place_at", b)
	var paid := before - _money(mi)
	K.check(
		fails,
		bool(res.get("ok", false)) and bool(pv.get("ok", false)) and int(pv["mi"]) == mi,
		"%s: placed for district %d (%s)" % [what, mi, res.get("reason", "")]
	)
	K.check(
		fails,
		paid == int(res.get("cost", -1)) and paid == int(pv.get("cost", -2)) and paid > 0,
		(
			"%s: the owner paid what the phone quoted ($%d, quoted $%d)"
			% [what, paid, pv.get("cost", 0)]
		)
	)
	return res


# ------------------------------------------------------------------ checks


func _check_rules() -> void:
	var p := RULES.road_path(Vector2i(2, 3), Vector2i(4, 1))
	K.check(
		fails,
		p == [Vector2i(2, 3), Vector2i(3, 3), Vector2i(4, 3), Vector2i(4, 2), Vector2i(4, 1)],
		"rules: roads run along x, then along y, like CitySim (%s)" % str(p)
	)
	var long := RULES.road_path(Vector2i(0, 0), Vector2i(40, 0))
	K.check(fails, long.size() == D.MAX_ROAD_LEN, "rules: a road is capped at MAX_ROAD_LEN tiles")
	K.check(
		fails, RULES.BUILDINGS.size() == D.BUILDINGS.size(), "rules: every building is on the list"
	)


func _check_open() -> void:
	K.check(fails, ph.call("open_phone") == true and bool(ph.get("open")), "open_phone() opens")
	var ui: Variant = ph.get("phone")
	K.check(fails, ui != null and (ui as Node).call("is_shown"), "the phone slides in")
	var row := _free_row(0, 1)
	ph.call("refresh_at", row[0])
	var st: Dictionary = (ui as Node).call("state") if ui != null else {}
	K.check(
		fails,
		(
			str(st.get("district", "")) == str(D.MAYORS[0]["district"])
			and str(st.get("mayor", "")).contains(str(_sim().mayors[0]["name"]))
			and int(st.get("treasury", -1)) == _money(0)
		),
		"the phone shows who you build for: %s" % str(st)
	)
	var ghost: Variant = ph.get("ghost")
	K.check(
		fails,
		ghost != null and (ghost as Node3D).visible and int((ghost as Node).get("count")) == 1,
		"the ghost marks the aimed tile"
	)


func _check_road() -> void:
	var row := _free_row(0, 3)
	K.check(fails, row.size() == 3, "fixture: 3 free tiles in a row in district 0")
	if row.size() < 3:
		return
	ph.call("set_tool", "road")
	var first: Dictionary = ph.call("place_at", row[0])
	K.check(
		fails,
		bool(first.get("pending", false)) and ph.get("anchor") == row[0],
		"the first road click sets the start"
	)
	ph.call("refresh_at", row[2])
	var pv: Dictionary = ph.get("preview")
	K.check(
		fails,
		(pv["tiles"] as Array).size() == 3 and int(pv["cost"]) == 3 * D.ROAD_COST,
		"the preview covers the 3 tiles for $%d (%s)" % [3 * D.ROAD_COST, str(pv)]
	)
	ph.call("cancel")
	K.check(
		fails,
		ph.get("anchor") == D.NO_TILE and bool(ph.get("open")),
		"cancel drops the start, phone stays"
	)
	_order("road", 0, row[0], row[2], "road")
	var i := D.idx(row[1].x, row[1].y)
	var s := _sim()
	K.check(
		fails,
		s.kind[i] == D.ROAD or (s.sites.has(i) and int(s.sites[i]["target_kind"]) == D.ROAD),
		"the road is built or under construction"
	)
	K.check(fails, ph.get("anchor") == D.NO_TILE, "placing clears the start")


func _check_other_district() -> void:
	var mi := 2
	var row := _free_row(mi, 2)
	K.check(fails, row.size() == 2, "fixture: free land in district %d" % mi)
	if row.size() < 2:
		return
	var mine := _money(0)
	_order("road", mi, row[0], row[1], "road in another district")
	K.check(fails, _money(0) == mine, "district 0 paid nothing for district %d's road" % mi)


func _check_refusals() -> void:
	var s := _sim()
	toasts.clear()
	# A road from district 0 into another district stops at the line, like the sim's own rule.
	var a := Vector2i(-1, -1)
	var b := Vector2i(-1, -1)
	for i in range(s.kind.size()):
		var x := D.tx(i)
		var y := D.ty(i)
		if _free(0, x, y) and D.in_bounds(x + 1, y):
			var j := D.idx(x + 1, y)
			if s.district[j] >= 1 and s.kind[j] == D.EMPTY and s.terrain[j] != D.WATER:
				a = Vector2i(x, y)
				b = Vector2i(x + 1, y)
				break
	if a.x != -1:
		ph.call("set_tool", "road")
		ph.call("place_at", a)
		var before := _money(0)
		var res: Dictionary = ph.call("place_at", b)
		K.check(
			fails,
			not bool(res.get("ok", true)) and _money(0) == before,
			"a road into another district is refused (%s)" % str(res.get("reason", ""))
		)
		ph.call("cancel")
	var wild := Vector2i(-99, -99)
	for i in range(s.kind.size()):
		if s.district[i] < 0 and s.terrain[i] != D.WATER:
			wild = Vector2i(D.tx(i), D.ty(i))
			break
	K.check(fails, wild.x != -99, "fixture: unclaimed land")
	ph.call("set_tool", "build")
	var r2: Dictionary = ph.call("place_at", wild)
	K.check(
		fails,
		not bool(r2.get("ok", true)) and str(r2.get("reason", "")).contains("Unclaimed"),
		"unclaimed land is refused: no mayor to build for (%s)" % str(r2.get("reason", ""))
	)
	K.check(fails, not toasts.is_empty(), "a refusal says why in a toast")
	var spot := _free_row(1, 1)
	var keep := _money(1)
	s.mayors[1]["treasury"] = RULES.DEBT_FLOOR
	ph.set("building", "stadium")
	var r3: Dictionary = ph.call("place_at", spot[0])
	K.check(
		fails,
		not bool(r3.get("ok", true)) and _money(1) == RULES.DEBT_FLOOR,
		"a district that cannot afford it is refused (%s)" % str(r3.get("reason", ""))
	)
	s.mayors[1]["treasury"] = keep


func _check_zone_build_bulldoze() -> void:
	var row := _free_row(1, 2)
	var row2 := _free_row(1, 2, row)
	if row.size() < 2 or row2.size() < 2:
		K.check(fails, false, "fixture: free land in district 1")
		return
	_order("zone_r", 1, row[0], row[1], "zone homes")
	var s := _sim()
	K.check(fails, s.kind[D.idx(row[1].x, row[1].y)] == D.ZONE_R, "the tiles are zoned for homes")
	ph.set("building", "park")
	_order("build", 1, row2[0], row2[0], "build a park")
	ph.call("cycle_building", 1)
	K.check(fails, str(ph.get("building")) == RULES.BUILDINGS[1], "the wheel steps the list")
	ph.call("cycle_building", -2)
	K.check(fails, str(ph.get("building")) == RULES.BUILDINGS[-1], "and wraps around")
	_order("bulldoze", 1, row[0], row[0], "bulldoze a zoned lot")


func _check_aim() -> void:
	var p := ctx.player
	var row := _free_row(0, 1)
	p.teleport(Vector3(row[0].x, 0.0, row[0].y), 0.0)
	p.update_view(1.0 / 60.0)
	var t: Vector2i = ph.call("aim_tile")
	var feet := Vector2(p.position.x, p.position.z)
	var d := Vector2(t.x, t.y) - feet
	var fwd := Vector2(p.forward().x, p.forward().z)
	K.check(
		fails,
		d.length() > 1.2 and d.length() < 2.8 and d.dot(fwd) > 0.0,
		"looking straight ahead aims about 2 tiles ahead (%s, %.1f tiles)" % [t, d.length()]
	)
	var up: float = ph.call("aim_distance", deg_to_rad(30.0))
	var down: float = ph.call("aim_distance", deg_to_rad(-60.0))
	K.check(
		fails,
		is_equal_approx(up, 6.0) and is_equal_approx(down, 0.6),
		"looking up reaches 6 tiles, looking down the next tile (%.1f, %.1f)" % [up, down]
	)


func _check_keys() -> void:
	var has_b := false
	for e in InputMap.action_get_events("phone_toggle"):
		if e is InputEventKey and (e as InputEventKey).physical_keycode == KEY_B:
			has_b = true
	K.check(fails, has_b, "phone_toggle is bound to B")
	var k := InputEventKey.new()
	k.physical_keycode = KEY_3
	k.pressed = true
	ph.call("_input", k)
	K.check(fails, str(ph.get("tool")) == "zone_c", "key 3 picks the third tool (shops)")


func _check_blocked() -> void:
	ctx.bus.drive_changed.emit(true)
	K.check(fails, not bool(ph.get("open")), "getting into a car puts the phone away")
	K.check(fails, ph.call("open_phone") == false, "no phone while driving")
	ctx.bus.drive_changed.emit(false)
	ctx.push_modal(&"test")
	K.check(fails, ph.call("open_phone") == false, "no phone over a menu")
	ctx.pop_modal(&"test")
	K.check(fails, ph.call("open_phone") == true, "it opens again on foot")
	ph.call("cancel")
	K.check(fails, not bool(ph.get("open")), "cancel with no start closes the phone")


func _check_teardown() -> void:
	var ui: Variant = ph.get("phone")
	ph.teardown()
	await process_frame
	K.check(fails, ui == null or not is_instance_valid(ui), "teardown frees the phone UI")
