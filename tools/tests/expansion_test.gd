extends SceneTree
## Headless expansion test: annexation rules and prices, building on annexed land, territory
## save/load (including 96x96 saves moved into the bigger world), frontier survey, and per-tick
## cost on the full 192x192 world.

func _init() -> void:
	var D := SimDefs
	var Sim: GDScript = load("res://scripts/sim/city_sim.gd")
	var sim: Node = Sim.new()
	get_root().add_child(sim)
	sim.new_city(7)
	var ok := true
	ok = ok and D.W == 192 and D.H == 192 and D.in_bounds(-80, -80) and D.in_bounds(111, 111) and not D.in_bounds(112, 0)
	# Surveyors map two plots out from claimed land; the frontier beyond stays hazy.
	var surveyed_start := [sim.is_surveyed(-8, 5), sim.is_surveyed(-40, 5), sim.is_surveyed(-60, 5)]
	print("SURVEY start (-8,5) (-40,5) (-60,5) = ", surveyed_start, " plots=", sim.surveyed_plots().size())
	ok = ok and surveyed_start == [true, false, false]
	var plots: Array = sim.annexable_plots(0)
	print("ARGON plots=", plots.map(func(p: Dictionary) -> String: return "(%d,%d)" % [p["x"], p["y"]]))
	ok = ok and plots.size() == 2
	var far: Dictionary = sim.apply_action(0, {"type": "annex", "x": 40, "y": 40})
	var owned: Dictionary = sim.apply_action(0, {"type": "annex", "x": 5, "y": 5})
	print("REJECT far=", far, " owned=", owned)
	ok = ok and not bool(far["ok"]) and not bool(owned["ok"])
	var before := int(sim.mayors[0]["treasury"])
	var res: Dictionary = sim.apply_action(0, {"type": "annex", "x": -8, "y": 5})
	print("ANNEX ", res, " cost=", before - int(sim.mayors[0]["treasury"]), " next=", sim.annex_cost(0), " rect=", sim.district_rect(0))
	ok = ok and bool(res["ok"]) and before - int(sim.mayors[0]["treasury"]) == D.ANNEX_BASE_COST
	ok = ok and sim.district[D.idx(-8, 5)] == 0 and sim.district[D.idx(-16, 15)] == 0 and sim.district[D.idx(-17, 5)] == -1
	ok = ok and sim.annex_cost(0) == D.ANNEX_BASE_COST + D.ANNEX_STEP_COST
	ok = ok and sim.district_rect(0) == Rect2i(-16, 0, 32, 16)
	var again: Dictionary = sim.apply_action(1, {"type": "annex", "x": -8, "y": 5})
	ok = ok and not bool(again["ok"])
	print("SURVEY after annex (-40,5)=", sim.is_surveyed(-40, 5), " (-60,5)=", sim.is_surveyed(-60, 5))
	ok = ok and sim.is_surveyed(-40, 5) and not sim.is_surveyed(-60, 5)
	var t_a := Time.get_ticks_usec()
	for _k in range(20):
		sim.annexable_plots(0)
	print("annexable_plots ms=%.2f" % (float(Time.get_ticks_usec() - t_a) / 1000.0 / 20.0))
	var acts := [
		{"type": "road", "x": -12, "y": 10, "x2": -1, "y2": 10},
		{"type": "build", "building": "coal_plant", "x": -3, "y": 9},
		{"type": "build", "building": "water_pump", "x": -5, "y": 9},
		{"type": "road", "x": -12, "y": 4, "x2": -12, "y2": 9},
		{"type": "zone", "zone": "R", "x": -11, "y": 11, "w": 6, "h": 2},
		{"type": "zone", "zone": "C", "x": -11, "y": 8, "w": 4, "h": 2},
	]
	var probe := D.idx(-3, 9)
	print("PROBE (-3,9) kind=", sim.kind[probe], " terrain=", sim.terrain[probe], " district=", sim.district[probe], " road_dist=", sim.road_dist[probe])
	var road_ok := false
	for a in acts:
		var r: Dictionary = sim.apply_action(0, a)
		print("ACT ", a["type"], " ", a.get("building", a.get("zone", "")), " -> ", r)
		if a["type"] == "road":
			road_ok = road_ok or bool(r["ok"])
	ok = ok and road_ok
	var t0 := Time.get_ticks_usec()
	var ticks := 0
	for d in range(20):
		for t in range(4):
			sim.step_tick()
			ticks += 1
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(ticks)
	var dev := 0
	for y in range(0, 16):
		for x in range(-16, 0):
			var i := D.idx(x, y)
			if D.is_zone(sim.kind[i]) and sim.level[i] > 0:
				dev += 1
	print("GROWTH annexed developed=", dev, " pop=", sim.stats["population"], " tick_ms=%.1f" % ms)
	ok = ok and dev > 0
	var sim2: Node = Sim.new()
	get_root().add_child(sim2)
	var loaded: bool = sim2.from_dict(JSON.parse_string(JSON.stringify(sim.to_dict())))
	print("LOAD ok=", loaded, " owner=", sim2.district[D.idx(-8, 5)], " plots=", sim2.annexable_plots(0).size(), "/", sim.annexable_plots(0).size())
	ok = ok and loaded and sim2.district[D.idx(-8, 5)] == 0 and sim2.annexable_plots(0).size() == sim.annexable_plots(0).size()
	var old_save: Dictionary = sim.to_dict()
	old_save["version"] = 1
	ok = ok and not bool(sim2.from_dict(old_save))
	# A version 2 save from the 96x96 world lands in the same place in the bigger world.
	var legacy: Dictionary = sim.to_dict()
	legacy["version"] = 2
	legacy.erase("world")
	var lw: Dictionary = D.LEGACY_WORLD
	for key in ["kind", "level", "terrain", "burning", "district"]:
		var full: Array = legacy[key]
		var small: Array = []
		for y in range(int(lw["y0"]), int(lw["y0"]) + int(lw["h"])):
			for x in range(int(lw["x0"]), int(lw["x0"]) + int(lw["w"])):
				small.append(full[D.idx(x, y)])
		legacy[key] = small
	var sim3: Node = Sim.new()
	get_root().add_child(sim3)
	var migrated: bool = sim3.from_dict(JSON.parse_string(JSON.stringify(legacy)))
	var same_tiles := true
	for y in range(-32, 64):
		for x in range(-32, 64):
			var i := D.idx(x, y)
			same_tiles = same_tiles and sim3.kind[i] == sim.kind[i] and sim3.district[i] == sim.district[i]
	var old_i := 37 * 96 + 40
	print("LEGACY ok=", migrated, " same_tiles=", same_tiles, " pop=", sim3.stats.get("population", 0), "/", sim.stats.get("population", 0), " remap(", old_i, ")=", sim3.remap_index(old_i), " want ", D.idx(8, 5))
	ok = ok and migrated and same_tiles and sim3.remap_index(old_i) == D.idx(8, 5) and sim3.district[D.idx(-8, 5)] == 0
	print("EXPANSION_TEST: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
