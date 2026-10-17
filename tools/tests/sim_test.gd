extends SceneTree
## Headless rules test: scripted mayors build a town; asserts growth, utilities, budgets, save/load.

func _init() -> void:
	var Sim: GDScript = load("res://scripts/sim/city_sim.gd")
	var sim: Node = Sim.new()
	get_root().add_child(sim)
	sim.new_city(7)
	var acts := [
		{"type": "build", "building": "coal_plant", "x": 9, "y": 9},
		{"type": "build", "building": "water_pump", "x": 9, "y": 7},
		{"type": "road", "x": 2, "y": 5, "x2": 9, "y2": 5},
		{"type": "zone", "zone": "R", "x": 2, "y": 6, "w": 6, "h": 3},
		{"type": "zone", "zone": "C", "x": 2, "y": 3, "w": 6, "h": 2},
		{"type": "zone", "zone": "I", "x": 11, "y": 2, "w": 1, "h": 1},
		{"type": "build", "building": "sewage_plant", "x": 9, "y": 3},
		{"type": "build", "building": "nonsense", "x": 1, "y": 1},
	]
	for a in acts:
		print("ACT ", a["type"], " -> ", sim.apply_action(0, a))
	print("ACT grok zone ", sim.apply_action(4, {"type": "zone", "zone": "I", "x": 22, "y": 22, "w": 5, "h": 5}))
	print("ACT grok coal ", sim.apply_action(4, {"type": "build", "building": "coal_plant", "x": 22, "y": 20}))
	print("ACT grok road ", sim.apply_action(4, {"type": "road", "x": 22, "y": 27, "x2": 26, "y2": 27}))
	for d in range(40):
		for t in range(4):
			sim.step_tick()
	print("DAY ", sim.day, " pop=", sim.stats["population"], " jobs=", sim.stats["jobs"], " dem=", sim.demand)
	print("power ", sim.stats["power_used"], "/", sim.stats["power_cap"], " water ", sim.stats["water_used"], "/", sim.stats["water_cap"], " sewage ", sim.stats["sewage_ratio"])
	print("happy ", sim.stats["happiness"], " poll ", sim.stats["pollution"], " traffic ", sim.stats["traffic"])
	for m in sim.mayors:
		print("MAYOR ", m["name"], " $", m["treasury"], " pop ", m["pop"], " inc ", m["last_income"], " up ", m["last_upkeep"])
	print(sim.district_ascii(0))
	print(sim.open_lots(0))
	var ev: Dictionary = sim.trigger_disaster("earthquake", 5, 6, "test")
	print("QUAKE tiles=", (ev["tiles"] as Array).size())
	sim.trigger_disaster("blackout", 9, 9, "test")
	sim.step_tick()
	print("after blackout power cap ", sim.stats["power_cap"], " unpowered ", sim.stats["unpowered"])
	var saved: Dictionary = sim.to_dict()
	var json := JSON.stringify(saved)
	var sim2: Node = Sim.new()
	get_root().add_child(sim2)
	var ok: bool = sim2.from_dict(JSON.parse_string(json))
	print("LOAD ok=", ok, " pop match=", sim2.stats["population"] == sim.stats["population"], " day=", sim2.day)
	print("SUMMARY ", sim.city_summary())
	print("CITIZENS ", sim.sample_citizens(2))
	var pass_ok: bool = int(sim.stats["population"]) > 100 and ok
	print("SIM_TEST: ", "PASS" if pass_ok else "FAIL")
	quit(0 if pass_ok else 1)
