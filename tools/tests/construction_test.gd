extends SceneTree
## Headless test for staged construction: service, road, bridge and demolition sites move through
## their stages and finish on contractor work alone; zone growth goes through sites; residents
## with construction skills join sites and speed them up; open sites survive save/load; and
## "instant" mode still builds at once.

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails.append(what)


func ticks_until(sim: CitySim, pred: Callable, max_ticks: int) -> int:
	for t in range(max_ticks):
		if pred.call():
			return t
		sim.step_tick()
	return -1 if not pred.call() else max_ticks


func _init() -> void:
	var D := SimDefs
	var sim: CitySim = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	get_root().add_child(sim)
	sim.new_city(7)
	sim.construction_mode = "staged"
	sim.start()

	# A police station goes clearing -> excavation -> foundation -> frame -> finishing.
	var lot: Array = sim.open_lots(0, 10)[0]
	var res := sim.apply_action(0, {"type": "build", "building": "police", "x": int(lot[0]), "y": int(lot[1])})
	var pi := D.idx(int(res.get("x", -99)), int(res.get("y", -99)))
	print("BUILD ", res)
	check(bool(res["ok"]) and bool(res.get("site", false)), "build order opens a site")
	check(sim.kind[pi] == D.SITE and sim.sites.has(pi), "the tile is a construction site, not a police station yet")
	check(sim.tile_char(pi) == "+", "the map shows + for the site")
	var stages_seen: Dictionary = {}
	var t := 0
	while sim.sites.has(pi) and t < 40:
		stages_seen[sim.site_stage_name(sim.sites[pi])] = true
		sim.step_tick()
		t += 1
	print("POLICE finished after %d ticks, stages %s" % [t, stages_seen.keys()])
	check(sim.kind[pi] == D.POLICE and sim.level[pi] == 1, "the police station opens when the site finishes")
	check(stages_seen.size() == 5, "all five stages were worked through")
	var expect := maxi(D.build_ticks("police"), 5)
	check(t >= expect - 1 and t <= expect + 1, "contractors alone take about build_ticks (%d vs %d)" % [t, expect])

	# The planner does not order the same building twice while its site is open.
	var lot2: Array = sim.open_lots(0, 10)[0]
	sim.apply_action(0, {"type": "build", "building": "hospital", "x": int(lot2[0]), "y": int(lot2[1])})
	var open_hospital := false
	for s: Dictionary in sim.sites.values():
		open_hospital = open_hospital or int(s["target_kind"]) == D.HOSPITAL
	check(open_hospital, "hospital site is open")
	check(str(sim.district_summary(0)["under_construction"]).contains("Hospital"), "district summary lists the open site for the mayor")

	# Roads: a land road is paved after ~2 ticks.
	var ry := -1
	for y in range(1, 15):
		var clear := true
		for x in range(1, 6):
			var k := sim.kind[D.idx(x, y)]
			clear = clear and (k == D.EMPTY or k == D.FOREST) and sim.terrain[D.idx(x, y)] == D.LAND
		if clear:
			ry = y
			break
	check(ry >= 0, "found open land for a road")
	var rr := sim.apply_action(0, {"type": "road", "x": 1, "y": ry, "x2": 5, "y2": ry})
	print("ROAD ", rr)
	check(bool(rr["ok"]) and sim.kind[D.idx(3, ry)] == D.SITE, "road order opens road sites")
	var again := sim.apply_action(0, {"type": "road", "x": 1, "y": ry, "x2": 5, "y2": ry})
	check(not bool(again["ok"]), "re-ordering a road under construction is a no-op")
	var road_t := ticks_until(sim, func() -> bool: return sim.kind[D.idx(3, ry)] == D.ROAD, 6)
	check(road_t >= 2 and road_t <= 4, "road opens after %d ticks" % road_t)

	# Bridges: find a water tile in some district next to its land.
	var bridge := -1
	var owner := -1
	for i in range(D.W * D.H):
		if sim.terrain[i] == D.WATER and sim.district[i] >= 0 and sim.kind[i] == D.EMPTY:
			bridge = i
			owner = sim.district[i]
			break
	if bridge >= 0:
		var br := sim.apply_action(owner, {"type": "road", "x": D.tx(bridge), "y": D.ty(bridge)})
		check(bool(br["ok"]) and str(sim.sites[bridge]["plan"]) == "bridge", "a road over water is built as a bridge (%s)" % str(br))
		var bt := ticks_until(sim, func() -> bool: return sim.kind[bridge] == D.ROAD, 10)
		check(bt >= 4 and bt <= 6, "the bridge takes longer (%d ticks)" % bt)
	else:
		check(false, "found a river tile for a bridge")

	# Demolition: knocking down the police station takes a crew, then the lot is empty.
	var dr := sim.apply_action(0, {"type": "bulldoze", "x": D.tx(pi), "y": D.ty(pi)})
	print("DEMOLISH ", dr)
	check(bool(dr["ok"]) and sim.kind[pi] == D.SITE and str(sim.sites[pi]["plan"]) == "demolish", "bulldozing a building sends a demolition crew")
	var dd := sim.apply_action(0, {"type": "bulldoze", "x": D.tx(pi), "y": D.ty(pi)})
	check(sim.sites.has(pi) and not bool(dd["ok"]), "bulldozing again does not skip the demolition (%s)" % str(dd))
	var dt := ticks_until(sim, func() -> bool: return sim.kind[pi] == D.EMPTY, 10)
	check(dt >= 2, "demolition and hauling take %d ticks" % dt)

	# Zone growth goes through developer sites.
	var acts := [
		{"type": "build", "building": "coal_plant", "x": 9, "y": 9},
		{"type": "build", "building": "water_pump", "x": 9, "y": 7},
		{"type": "road", "x": 2, "y": 5, "x2": 9, "y2": 5},
		{"type": "zone", "zone": "R", "x": 2, "y": 6, "w": 6, "h": 3},
	]
	for a: Dictionary in acts:
		sim.apply_action(0, a)
	var zone_site_seen := false
	for _k in range(40):
		sim.step_tick()
		for s: Dictionary in sim.sites.values():
			zone_site_seen = zone_site_seen or str(s["type"]) == "zone"
	var dev := 0
	for i in sim.active:
		if sim.kind[i] == D.ZONE_R and sim.level[i] > 0:
			dev += 1
	check(zone_site_seen, "zoned lots were developed through construction sites")
	check(dev > 0, "homes were finished (%d)" % dev)

	# Save/load keeps open sites and their stage.
	var lot3: Array = sim.open_lots(0, 10)[0]
	var r3 := sim.apply_action(0, {"type": "build", "building": "school", "x": int(lot3[0]), "y": int(lot3[1])})
	var si := D.idx(int(r3["x"]), int(r3["y"]))
	sim.step_tick()
	sim.step_tick()
	var stage_before := int(sim.sites[si]["stage"])
	var saved: Variant = JSON.parse_string(JSON.stringify(sim.to_dict()))
	var sim2: CitySim = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	get_root().add_child(sim2)
	check(sim2.from_dict(saved as Dictionary), "save loads")
	check(sim2.sites.has(si) and int(sim2.sites[si]["stage"]) == stage_before and sim2.kind[si] == D.SITE, "an open site survives save/load at stage %d" % stage_before)

	# Residents: construction workers join sites and add work.
	var people: Residents = (load("res://scripts/sim/residents.gd") as GDScript).new()
	get_root().add_child(people)
	people.setup(sim)
	for _d in range(6):
		for _k in range(4):
			sim.step_tick()
	var builders := 0
	for r in people.people:
		if (r["skills"] as Array).has("construction"):
			builders += 1
	var lot4: Array = sim.open_lots(0, 10)[0]
	sim.mayors[0]["treasury"] = 20000
	var r4 := sim.apply_action(0, {"type": "build", "building": "stadium", "x": int(lot4[0]), "y": int(lot4[1])})
	var st := D.idx(int(r4.get("x", -99)), int(r4.get("y", -99)))
	var stadium_t := 0
	var crew: Dictionary = {}
	while sim.sites.has(st) and stadium_t < 80:
		crew = (sim.sites[st]["crew"] as Dictionary).duplicate()
		sim.step_tick()
		stadium_t += 1
	var resident_crew := 0
	for who: String in crew.keys():
		if not who.ends_with("contractors"):
			resident_crew += 1
	print("RESIDENTS %d (builders %d); stadium finished in %d ticks (contractors alone %d); crew %s" % [people.people.size(), builders, stadium_t, D.build_ticks("stadium"), crew.keys().slice(0, 6)])
	check(sim.staged(), "staged construction is on")
	if builders > 0:
		check(resident_crew > 0, "residents worked on the stadium site (%d)" % resident_crew)
		check(stadium_t < D.build_ticks("stadium"), "resident builders finished it faster than contractors alone")
	var remembered := false
	for r in people.people:
		for m: Variant in r["memory"]:
			remembered = remembered or str(m).contains("build")
	check(remembered or builders == 0, "builders remember the site they worked on")

	# Instant mode keeps the old behaviour.
	sim.construction_mode = "instant"
	var lot5: Array = sim.open_lots(0, 10)[0]
	var r5 := sim.apply_action(0, {"type": "build", "building": "park", "x": int(lot5[0]), "y": int(lot5[1])})
	check(sim.kind[D.idx(int(r5["x"]), int(r5["y"]))] == D.PARK, "instant mode builds at once")

	print("CONSTRUCTION_TEST: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	quit(0 if fails.is_empty() else 1)
