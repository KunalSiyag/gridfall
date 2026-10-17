extends SceneTree
## Headless test for AI residents (offline: cached/heuristic minds). Asserts residents arrive with
## jobs and plans, drive traffic and taxes, fix incidents by working on them, leave when they
## decide to, and survive save/load.

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails.append(what)


func _init() -> void:
	var sim: CitySim = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	get_root().add_child(sim)
	sim.new_city(7)
	var client: GmiClient = (load("res://scripts/ai/gmi_client.gd") as GDScript).new()
	get_root().add_child(client)
	client.live_enabled = false
	var people: Residents = (load("res://scripts/sim/residents.gd") as GDScript).new()
	get_root().add_child(people)
	var minds: ResidentMinds = (load("res://scripts/ai/resident_minds.gd") as GDScript).new()
	get_root().add_child(minds)
	people.setup(sim)
	minds.setup(sim, people, client, null)
	for a: Dictionary in [
		{"type": "build", "building": "coal_plant", "x": 9, "y": 9},
		{"type": "build", "building": "water_pump", "x": 9, "y": 7},
		{"type": "road", "x": 2, "y": 5, "x2": 9, "y2": 5},
		{"type": "zone", "zone": "R", "x": 2, "y": 6, "w": 6, "h": 3},
		{"type": "zone", "zone": "C", "x": 2, "y": 3, "w": 6, "h": 2},
		{"type": "build", "building": "sewage_plant", "x": 9, "y": 3},
		{"type": "build", "building": "fire_station", "x": 1, "y": 9},
		{"type": "zone", "zone": "I", "x": 11, "y": 2, "w": 4, "h": 4},
		{"type": "road", "x": 11, "y": 6, "x2": 15, "y2": 6},
	]:
		sim.apply_action(0, a)
	sim.start()
	for _d in range(20):
		for _t in range(4):
			sim.step_tick()
	print("DAY %d pop=%d residents=%d share=%.1f sentiment=%s" % [sim.day, int(sim.stats["population"]), people.people.size(), people.share, JSON.stringify(people.sentiment)])
	check(people.is_active() and sim.work_based(), "residents are active and the sim is work based")
	check(people.people.size() >= 5, "residents moved in (%d)" % people.people.size())
	var planned := 0
	var housed := 0
	var employed := 0
	for r in people.people:
		if not (r["plan"] as Dictionary).is_empty():
			planned += 1
		if sim.kind[int(r["home"])] == SimDefs.ZONE_R and sim.level[int(r["home"])] > 0:
			housed += 1
		if int(r["work"]) >= 0:
			employed += 1
	check(planned == people.people.size(), "every resident has a plan for today")
	check(housed == people.people.size(), "every resident lives in a developed home")
	check(employed > 0, "some residents have jobs (%d)" % employed)
	var trips := 0.0
	for v in people.trip_load:
		trips += v
	check(trips > 0.0, "traffic comes from residents' trips (%.1f)" % trips)
	var r0: Dictionary = people.people[0]
	print("SAMPLE ", JSON.stringify(people.card(r0)).left(600))

	# Wages are paid at midday and become the district tax base.
	sim.step_tick()
	sim.step_tick()
	var wages := 0.0
	for m: Variant in people.district_money():
		wages += float((m as Dictionary)["wages"])
	check(wages > 0.0, "residents earned taxable wages today (%.1f)" % wages)
	while sim.tick_in_day != 0:
		sim.step_tick()

	# Nothing fixes itself: with nobody reacting, an incident stays broken.
	sim.event_started.disconnect(minds._on_event_started)
	var pump := -1
	for i in range(SimDefs.W * SimDefs.H):
		if sim.kind[i] == SimDefs.PUMP:
			pump = i
	var ev := sim.trigger_disaster("water_main", SimDefs.tx(pump), SimDefs.ty(pump), "test")
	for r in people.people:
		(r["plan"] as Dictionary)["evening"] = "home"
	sim.step_tick()
	sim.step_tick()
	check(sim.events.has(ev) and float(ev["progress"]) == 0.0, "an unattended water main stays broken")
	check(sim.disabled_until.has(pump), "the broken pump is out of service")
	var res := sim.apply_action(0, {"type": "emergency", "x": int(ev["x"]), "y": int(ev["y"])})
	check(bool(res["ok"]) and float(ev["progress"]) > 0.0, "paid crews add repair work (%s)" % str(res))
	sim.event_started.connect(minds._on_event_started)

	# A fire draws reactions; residents walk over and their work puts it out.
	var target := -1
	for r in people.people:
		target = int(r["home"])
	var fire := sim.trigger_disaster("fire", SimDefs.tx(target), SimDefs.ty(target), "test")
	var helpers_now := 0
	for r in people.people:
		if int(r["helping"]) == int(fire["id"]):
			helpers_now += 1
	print("FIRE reports=%d helpers_now=%d" % [int(fire["reports"]), helpers_now])
	check(helpers_now > 0 or int(fire["reports"]) > 0, "residents reacted to the fire")
	var ticks := 0
	while sim.events.has(fire) and ticks < 24:
		sim.step_tick()
		ticks += 1
	var resident_named := false
	for h: String in (fire["helpers"] as Dictionary).keys():
		if h.contains("("):
			resident_named = true
	print("FIRE ticks=%d progress=%d/%d helpers=%s" % [ticks, int(fire["progress"]), int(fire["work"]), JSON.stringify((fire["helpers"] as Dictionary).keys())])
	check(not sim.events.has(fire) and resident_named, "residents put out the fire")

	# A resident who decides to leave is gone after the night, and their home empties a little.
	while sim.tick_in_day != 3:
		sim.step_tick()
	var leaver: Dictionary = people.people[people.people.size() - 1]
	people.apply_plan(leaver, {"intent": "leaving", "mood": 1, "mood_reason": "test says goodbye"}, "test", "")
	var before := people.people.size()
	sim.step_tick()
	check(not people.people.has(leaver) and people.departed.size() > 0, "a resident who chose to leave moved out (%d -> %d)" % [before, people.people.size()])

	# Save/load keeps everyone.
	var saved := JSON.stringify(people.to_dict())
	var n := people.people.size()
	var name0 := str(people.people[0]["name"])
	people.from_dict(JSON.parse_string(saved))
	check(people.people.size() == n and str(people.people[0]["name"]) == name0, "residents survive save/load")
	print("MINDS ", JSON.stringify(minds.stats))
	print("RESIDENTS_TEST: ", "PASS" if fails.is_empty() else "FAIL " + str(fails))
	quit(0 if fails.is_empty() else 1)
