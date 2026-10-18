extends SceneTree
## CityDirectory (docs/fp/S0-foundation.md §14): deterministic street, address, business and
## landmark names on the grown kit city; seed sensitivity; frontage rules; no model branding.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const FORBIDDEN := ["Argon", "DeepSeek", "Kimi", "Qwen", "Grok", "GMI", "Okafor", "Han", "Kimura", "Quintero", "Granger"]

var fails: Array[String] = []


func _init() -> void:
	var s := K.make_sim(get_root(), 7)
	var sim: CitySim = s["sim"]
	K.grow(sim, s["people"], 40)
	var dir := CityDirectory.new()
	dir.setup(sim)
	var dir2 := CityDirectory.new()
	dir2.setup(sim)
	var outputs: Array[String] = []

	# Two directories on one seed agree on every road tile.
	var agree := true
	var roads := 0
	for i in sim.active:
		if sim.kind[i] != D.ROAD:
			continue
		roads += 1
		var a := dir.street_name(i)
		agree = agree and not a.is_empty() and a == dir2.street_name(i) and dir.intersection_name(i) == dir2.intersection_name(i)
		outputs.append(a)
		outputs.append(dir.intersection_name(i))
		outputs.append(dir.place_label(i))
	K.check(fails, roads > 0 and agree, "two directories agree on all %d road tiles" % roads)

	# A different seed renames at least one street.
	var seed0 := sim.city_seed
	sim.city_seed = seed0 + 1
	var other := CityDirectory.new()
	other.setup(sim)
	sim.city_seed = seed0
	var differs := false
	for i in sim.active:
		if sim.kind[i] == D.ROAD and other.street_name(i) != dir.street_name(i):
			differs = true
			break
	K.check(fails, differs, "a different seed changes at least one street name")

	# Core rows and columns are unique.
	var rows := {}
	var cols := {}
	for k in range(D.CORE):
		rows[dir.call("_ew_name", k)] = true
		cols[dir.call("_ns_name", k)] = true
	K.check(fails, rows.size() == D.CORE and cols.size() == D.CORE, "core rows and columns have distinct names (%d, %d)" % [rows.size(), cols.size()])
	K.check(fails, str(dir.call("_ew_name", 5)).ends_with(" Street") and not str(dir.call("_ew_name", 5)).begins_with("North"), "core streets carry no band qualifier")
	K.check(fails, str(dir.call("_ew_name", D.Y0)).begins_with("North ") and str(dir.call("_ns_name", D.X0 + D.W - 1)).begins_with("East "), "outer bands get North / East qualifiers")

	# Lots: business names, addresses, frontage.
	var addr_re := RegEx.create_from_string("^\\d+ .+ (Street|Avenue)$")
	var biz := 0
	var biz_ok := true
	var lots := 0
	var addr_ok := true
	var front_ok := true
	var yaw_ok := true
	var planned_ok := true
	for i in sim.active:
		var k := sim.kind[i]
		if (k == D.ZONE_C or k == D.ZONE_I) and sim.level[i] > 0:
			biz += 1
			var b := dir.business_name(i)
			biz_ok = biz_ok and not b.is_empty() and not dir.business_kind(i).is_empty()
			planned_ok = planned_ok and dir.planned_name(i, k, sim.level[i]) == b
			outputs.append(b)
		if k == D.ROAD or not _has_road_neighbour(sim, i):
			continue
		lots += 1
		var ad := dir.address(i)
		addr_ok = addr_ok and addr_re.search(ad) != null
		var f := dir.frontage(i)
		front_ok = front_ok and f >= 0 and sim.kind[f] == D.ROAD and absi(D.tx(f) - D.tx(i)) + absi(D.ty(f) - D.ty(i)) == 1
		yaw_ok = yaw_ok and dir.frontage_yaw(i) in [0.0, 90.0, 180.0, -90.0]
		outputs.append(ad)
		outputs.append(dir.place_label(i))
		outputs.append(dir.street_at(Vector3(D.tx(i), 0, D.ty(i))))
	K.check(fails, biz > 0 and biz_ok, "every one of %d C/I lots has a business name and kind" % biz)
	K.check(fails, planned_ok, "planned_name matches the name a finished lot gets")
	K.check(fails, lots > 0 and addr_ok, "every one of %d lots by a road has a street address" % lots)
	K.check(fails, front_ok, "frontage() is always a 4-neighbour road")
	K.check(fails, yaw_ok, "frontage_yaw is one of 0, 90, 180, -90")

	var hall := -1
	for i in sim.active:
		if sim.kind[i] == D.HALL:
			hall = i
	K.check(fails, hall >= 0 and dir.landmark_name(hall) == "GridFall City Hall", "City Hall is GridFall City Hall")
	var hall_front := dir.frontage(hall)
	K.check(fails, hall_front == D.idx(15, 15) and is_equal_approx(dir.frontage_yaw(hall), 0.0), "City Hall fronts the road to its south")
	# Names for services and planned buildings, for the branding scan.
	for k: int in [D.POLICE, D.FIRE, D.HOSPITAL, D.SCHOOL, D.PARK, D.COAL, D.STADIUM, D.TRAIN, D.LANDFILL]:
		var nm := dir.planned_name(hall, k, 1)
		K.check(fails, not nm.is_empty(), "planned_name names a %s (%s)" % [D.KIND_NAMES[k], nm])
		outputs.append(nm)
	for l in range(1, 4):
		outputs.append(dir.planned_name(hall, D.ZONE_C, l))
		outputs.append(dir.planned_name(hall, D.ZONE_I, l))
		outputs.append(dir.planned_name(hall, D.ZONE_R, l))
	K.check(fails, dir.planned_name(hall, D.ROAD, 0).is_empty() and dir.planned_name(hall, D.ZONE_R, 1).is_empty(), "roads and R1 houses have no planned name")
	for d in range(D.MAYORS.size()):
		outputs.append(dir.district_name(D.idx(5 + d, 5 + d)))
	outputs.append(dir.street_at(Vector3(15.2, 0, 14.6)))

	var bad: Array[String] = []
	for o: String in outputs:
		for w: String in FORBIDDEN:
			if o.contains(w):
				bad.append(o)
	K.check(fails, bad.is_empty(), "no directory output carries a model brand or mayor surname (%d outputs) %s" % [outputs.size(), str(bad.slice(0, 5))])

	var t0 := Time.get_ticks_usec()
	var n := 0
	while n < 1000:
		for i in sim.active:
			dir.place_label(i)
			n += 1
			if n >= 1000:
				break
	print("PERF 1000 place_label calls: %.1f ms (budget 50, report only)" % ((Time.get_ticks_usec() - t0) / 1000.0))
	print("SAMPLE street=%s | cross=%s | address=%s | hall=%s" % [dir.street_name(D.idx(15, 15)), dir.intersection_name(D.idx(10, 10)), dir.address(D.idx(3, 6)), dir.place_label(hall)])
	K.finish(self, "FP_DIRECTORY_TEST", fails)


func _has_road_neighbour(sim: CitySim, i: int) -> bool:
	for dv: Vector2i in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]:
		var x := D.tx(i) + dv.x
		var y := D.ty(i) + dv.y
		if D.in_bounds(x, y) and sim.kind[D.idx(x, y)] == D.ROAD:
			return true
	return false
