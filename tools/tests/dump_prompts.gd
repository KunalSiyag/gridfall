extends SceneTree

func _init() -> void:
	var sim: Node = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	var client: Node = (load("res://scripts/ai/gmi_client.gd") as GDScript).new()
	var brain: Node = (load("res://scripts/ai/city_brain.gd") as GDScript).new()
	get_root().add_child(sim)
	get_root().add_child(client)
	get_root().add_child(brain)
	await process_frame
	sim.set_speed(0)
	client.set_live(false)
	brain.setup(sim, client)
	sim.apply_action(0, {"type": "build", "building": "coal_plant", "x": 9, "y": 9})
	sim.apply_action(0, {"type": "road", "x": 2, "y": 5, "x2": 9, "y2": 5})
	sim.apply_action(0, {"type": "zone", "zone": "R", "x": 2, "y": 6, "w": 6, "h": 2})
	for t in range(8):
		sim.step_tick()
	var out := []
	for mi in range(5):
		out.append({"model": D.MAYORS[mi]["model"], "system": brain._mayor_system_prompt(mi), "user": brain._mayor_user_prompt(mi, sim.day)})
	var f := FileAccess.open("/tmp/gf_prompts.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	print("DUMPED ", (out[0]["system"] as String).length() + (out[0]["user"] as String).length(), " chars")
	quit(0)

const D := preload("res://scripts/sim/sim_defs.gd")
