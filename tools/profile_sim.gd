extends SceneTree
## Times each simulation phase on a grown world so slow per-tile passes are easy to spot, then runs
## the same ticks sliced (CitySim.sliced, 4 ms pumps) and prints the pump statistics and the
## slowest step kinds.

func _init() -> void:
	var Sim: GDScript = load("res://scripts/sim/city_sim.gd")
	var sim: Node = Sim.new()
	get_root().add_child(sim)
	sim.set_process(false)
	sim.new_city(7)
	for d in range(12):
		for t in range(4):
			sim.step_tick()
	print("active tiles=", sim.active.size())
	for phase in ["_compute_road_dist", "_compute_utilities", "_compute_coverage", "_compute_traffic", "_compute_pollution", "_compute_crime_land_happiness", "_compute_demand", "_compute_stats", "_grow_zones", "_update_fires", "_flush_changes"]:
		var t0 := Time.get_ticks_usec()
		for k in range(5):
			if phase == "_flush_changes":
				sim.call(phase, false)
			else:
				sim.call(phase)
		print("%-32s %.1f ms" % [phase, float(Time.get_ticks_usec() - t0) / 5000.0])
	var t1 := Time.get_ticks_usec()
	for k in range(4):
		sim.step_tick()
	print("step_tick %.1f ms" % (float(Time.get_ticks_usec() - t1) / 4000.0))
	sim.set("sliced", true)
	sim.call("reset_slice_stats")
	var committed := 0
	while committed < 4:
		if not sim.call("job_pending"):
			sim.call("begin_tick")
		if sim.call("pump", 4.0):
			committed += 1
	while sim.call("job_pending"):
		sim.call("pump", 4.0)
	var st: Dictionary = sim.call("slice_stats")
	print("sliced: %d pumps for 4 ticks, max %.2f ms, p95 %.2f ms, max units %d/%d" % [int(st["pumps"]), float(st["max_ms"]), float(st["p95_ms"]), int(st["max_units"]), int(st["units_limit"])])
	var prof: Dictionary = sim.call("slice_profile")
	var keys := prof.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return float(prof[a][1]) > float(prof[b][1]))
	for k: String in keys.slice(0, 6):
		var v: Array = prof[k]
		print("  step %-20s n=%d max %.2f ms total %.1f ms" % [k, int(v[0]), float(v[1]), float(v[3])])
	quit(0)
