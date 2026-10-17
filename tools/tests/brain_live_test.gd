extends SceneTree
## Live brain test: two in-game days of real GMI calls; prints each agent's output and source.

func _wait_idle(brain: Node, max_s: float) -> void:
	var t0 := Time.get_ticks_msec()
	await process_frame
	while brain.pending_calls() > 0 and Time.get_ticks_msec() - t0 < int(max_s * 1000.0):
		await process_frame


func _init() -> void:
	var sim: Node = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	var client: Node = (load("res://scripts/ai/gmi_client.gd") as GDScript).new()
	var brain: Node = (load("res://scripts/ai/city_brain.gd") as GDScript).new()
	get_root().add_child(sim)
	get_root().add_child(client)
	get_root().add_child(brain)
	await process_frame
	sim.set_speed(0)
	brain.setup(sim, client)
	brain.mayor_decided.connect(func(mi: int, e: Dictionary) -> void:
		var oks := 0
		var lines: Array[String] = []
		for a: Dictionary in e["actions"]:
			if a["ok"]:
				oks += 1
			lines.append(("  + " if a["ok"] else "  x ") + JSON.stringify(a["action"]) + " -> " + str(a["reason"]))
		print("MAYOR %s day %d [%s %dms] ok=%d/%d err=%s\n  thought: %s\n  post: %s\n%s" % [e["model"], e["day"], e["source"], e["latency_ms"], oks, (e["actions"] as Array).size(), e["error"], e["thought"], e["post"], "\n".join(lines)])
	)
	brain.citizens_spoke.connect(func(v: Array) -> void: print("CITIZENS ", JSON.stringify(v).left(700)))
	brain.news_published.connect(func(p: Dictionary) -> void: print("NEWS ", JSON.stringify(p).left(600)))
	brain.chaos_decided.connect(func(c: Dictionary) -> void: print("CHAOS ", JSON.stringify(c)))
	brain.operator_decided.connect(func(c: Dictionary) -> void: print("OPERATOR ", JSON.stringify(c)))
	brain.council_ruled.connect(func(c: Dictionary) -> void: print("COUNCIL ", JSON.stringify(c)))
	print("LIVE=", client.live_enabled, " key=", client.has_key())
	sim.start()
	await _wait_idle(brain, 90.0)
	for t in range(4):
		sim.step_tick()
	await _wait_idle(brain, 90.0)
	print("DAY ", sim.day, " pop ", sim.stats["population"], " stats ", JSON.stringify(client.stats))
	for r: Dictionary in client.log_records:
		print("LOG %s/%s %s %dms %s" % [r["role"], r["agent"], r["source"], r["latency_ms"], str(r["error"]).left(160)])
	quit(0)
