extends SceneTree
## Times each simulation phase on a grown world so slow per-tile passes are easy to spot.

func _init() -> void:
	var Sim: GDScript = load("res://scripts/sim/city_sim.gd")
	var sim: Node = Sim.new()
	get_root().add_child(sim)
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
	quit(0)
