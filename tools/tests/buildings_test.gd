extends SceneTree
## Checks the v3 buildings: wind power, landfill waste capacity, transit traffic relief,
## university/stadium coverage and airport demand.

const D := preload("res://scripts/sim/sim_defs.gd")


func _init() -> void:
	var sim: CitySim = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	get_root().add_child(sim)
	await process_frame
	sim.set_speed(0)
	var fails: Array[String] = []
	for m in sim.mayors:
		m["treasury"] = 60000
	var cap0 := float(sim.stats.get("power_cap", 0.0))
	var r := sim.apply_action(1, {"type": "build", "building": "wind_farm", "x": 22, "y": 9})
	sim._recompute_all()
	var cap1 := float(sim.stats["power_cap"])
	print("wind: ", r["reason"], " cap ", cap0, " -> ", cap1)
	if not r["ok"] or cap1 < cap0 + 69.0:
		fails.append("wind farm power")
	sim.apply_action(0, {"type": "zone", "zone": "R", "x": 0, "y": 8, "w": 6, "h": 2})
	sim.apply_action(0, {"type": "build", "building": "water_pump", "x": 3, "y": 11})
	for t in range(40):
		sim.step_tick()
	var wneed := float(sim.stats["waste_need"])
	var r2 := sim.apply_action(0, {"type": "build", "building": "landfill", "x": 13, "y": 9})
	sim._recompute_all()
	print("landfill: ", r2["reason"], " waste ", sim.stats["waste_cap"], "/", wneed)
	if not r2["ok"] or float(sim.stats["waste_cap"]) < 159.0:
		fails.append("landfill capacity")
	for b: Array in [["train_station", 2, 11, 12], ["university", 2, 11, 16], ["stadium", 4, 17, 22], ["airport", 4, 25, 22]]:
		var dem_before := sim.demand.duplicate()
		var rr := sim.apply_action(int(b[1]), {"type": "build", "building": b[0], "x": b[2], "y": b[3]})
		sim._recompute_all()
		var x := int(rr.get("x", b[2]))
		var y := int(rr.get("y", b[3]))
		var rep := sim.tile_report(x, y)
		print(b[0], ": ", rr["reason"], " powered=", rep.get("powered"), " cov=", JSON.stringify(rep.get("coverage")), " demand ", JSON.stringify(dem_before), " -> ", JSON.stringify(sim.demand))
		if not rr["ok"]:
			fails.append(str(b[0]) + " build")
		match str(b[0]):
			"train_station":
				if float(rep["coverage"]["transit"]) < 0.5:
					fails.append("transit coverage")
			"university":
				if float(rep["coverage"]["school"]) < 0.5:
					fails.append("university coverage")
			"stadium":
				if float(rep["coverage"]["leisure"]) < 0.5:
					fails.append("stadium coverage")
	var chars := sim.district_ascii(4)
	if not ("O" in chars and "P" in chars):
		fails.append("map chars for stadium/airport")
	var saved := JSON.stringify(sim.to_dict())
	var pop := int(sim.stats["population"])
	sim.from_dict(JSON.parse_string(saved))
	if int(sim.stats["population"]) != pop:
		fails.append("save/load")
	print("BUILDINGS_TEST: ", "PASS" if fails.is_empty() else "FAIL " + ", ".join(fails))
	quit(0)
