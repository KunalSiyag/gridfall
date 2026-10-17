extends SceneTree
## Live GMI check for resident minds: grows a small town offline, then asks the real models for
## one day of resident plans and one incident reaction, and prints what they decided.

func _initialize() -> void:
	_run()


func _run() -> void:
	var sim: CitySim = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	get_root().add_child(sim)
	sim.new_city(11)
	var client: GmiClient = (load("res://scripts/ai/gmi_client.gd") as GDScript).new()
	get_root().add_child(client)
	await process_frame
	var people: Residents = (load("res://scripts/sim/residents.gd") as GDScript).new()
	get_root().add_child(people)
	var minds: ResidentMinds = (load("res://scripts/ai/resident_minds.gd") as GDScript).new()
	get_root().add_child(minds)
	people.setup(sim)
	minds.setup(sim, people, client, null)
	for a: Dictionary in [
		{"type": "build", "building": "coal_plant", "x": 9, "y": 9}, {"type": "build", "building": "water_pump", "x": 9, "y": 7},
		{"type": "road", "x": 2, "y": 5, "x2": 9, "y2": 5}, {"type": "zone", "zone": "R", "x": 2, "y": 6, "w": 6, "h": 3},
		{"type": "zone", "zone": "C", "x": 2, "y": 3, "w": 6, "h": 2}, {"type": "build", "building": "fire_station", "x": 1, "y": 9},
		{"type": "zone", "zone": "I", "x": 11, "y": 2, "w": 4, "h": 4}, {"type": "road", "x": 11, "y": 6, "x2": 15, "y2": 6},
	]:
		sim.apply_action(0, a)
	sim.set_speed(0)
	var key_ok := client.has_key()
	client.live_enabled = false
	sim.start()
	for _d in range(8):
		for _t in range(4):
			sim.step_tick()
	var n := mini(people.people.size(), int(OS.get_environment("LIVE_RESIDENTS")) if OS.has_environment("LIVE_RESIDENTS") else 30)
	while people.people.size() > n:
		people.people.pop_back()
	print("LIVE: key=%s residents=%d day=%d" % [key_ok, people.people.size(), sim.day])
	client.live_enabled = key_ok
	var t0 := Time.get_ticks_msec()
	minds.plan_day(sim.day)
	while minds.pending() > 0 and Time.get_ticks_msec() - t0 < 90000:
		await process_frame
	print("LIVE: plans in %d ms stats=%s" % [Time.get_ticks_msec() - t0, JSON.stringify(minds.stats)])
	print("LIVE: models=%s" % JSON.stringify(minds.model_stats))
	for r in people.people.slice(0, 6):
		print("LIVE: %s, %d, %s [%s via %s] mood=%.1f intent=%s plan=%s\n      thought: %s\n      says: %s | to mayor: %s" % [r["name"], int(r["age"]), r["job_title"], r["source"], r["model"], float(r["mood"]), r["intent"], JSON.stringify(r["plan"]), r["thought"], r["say"], r["message"]])
	var target := int(people.people[0]["home"])
	var ev := sim.trigger_disaster("fire", SimDefs.tx(target), SimDefs.ty(target), "test", "a kitchen fire")
	t0 = Time.get_ticks_msec()
	while minds.pending() > 0 and Time.get_ticks_msec() - t0 < 60000:
		await process_frame
	print("LIVE: reaction in %d ms reports=%d" % [Time.get_ticks_msec() - t0, int(ev["reports"])])
	for r in people.people:
		if str(r["reaction"]) != "":
			print("LIVE:   %s (%s) -> %s [%s] \"%s\" | %s" % [r["name"], r["job_title"], r["reaction"], r["source"], r["say"], r.get("reaction_thought", "")])
	for rec in client.log_records:
		if str(rec.get("source", "")) == "failed":
			print("LIVE: failed %s %s" % [rec.get("model", ""), str(rec.get("error", "")).left(160)])
	quit(0)
