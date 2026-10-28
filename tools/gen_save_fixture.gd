extends SceneTree
## Regenerates a committed save fixture for save_versions_test (tools/tests/fixtures/GENERATE.md
## has the full recipe): builds the same small seed-7 city and writes the sim save section. Runs
## under any build that has new_city / apply_action / step_tick / to_dict / district_rect —
## including ba1636e, the last version-2 writer:
##   godot --headless --path <worktree> -s tools/gen_save_fixture.gd -- <out.json>
## The test block goes inside mayor 0's district (queried at runtime, either era).


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "user://gen_save_fixture.json"
	if args.size() >= 1:
		out = args[0]
	var sim: Node = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	get_root().add_child(sim)
	sim.new_city(7)
	var r0: Rect2i = sim.district_rect(0)
	var ox: int = r0.position.x + maxi(1, (r0.size.x - 10) / 2)
	var oy: int = r0.position.y + maxi(1, (r0.size.y - 6) / 2)
	var acts := [
		{"type": "road", "x": ox, "y": oy, "x2": ox + 8, "y2": oy},
		{"type": "road", "x": ox, "y": oy + 4, "x2": ox + 8, "y2": oy + 4},
		{"type": "road", "x": ox, "y": oy, "x2": ox, "y2": oy + 4},
		{"type": "road", "x": ox + 8, "y": oy, "x2": ox + 8, "y2": oy + 4},
		{"type": "zone", "x": ox + 2, "y": oy + 1, "zone": "r"},
		{"type": "zone", "x": ox + 3, "y": oy + 1, "zone": "r"},
		{"type": "zone", "x": ox + 4, "y": oy + 1, "zone": "c"},
		{"type": "zone", "x": ox + 2, "y": oy + 3, "zone": "r"},
		{"type": "zone", "x": ox + 3, "y": oy + 3, "zone": "i"},
		{"type": "build", "building": "solar_farm", "x": ox + 6, "y": oy + 2},
		{"type": "build", "building": "water_pump", "x": ox + 7, "y": oy + 2},
	]
	var ok_n := 0
	for a in acts:
		var r: Dictionary = sim.apply_action(0, a)
		if bool(r.get("ok", false)):
			ok_n += 1
		else:
			print("GEN_NOTE rejected %s: %s" % [str(a.get("type")), str(r.get("reason", ""))])
	for _k in range(40):
		sim.step_tick()
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(sim.to_dict()))
	f.close()
	var stats: Variant = sim.get("stats")
	var pop: Variant = "?" if stats == null else (stats as Dictionary).get("population", "?")
	var size := FileAccess.get_file_as_string(out).length()
	print(
		(
			"GEN_OK out=%s ok=%d/%d day=%d pop=%s bytes=%d"
			% [out, ok_n, acts.size(), int(sim.get("day")), str(pop), size]
		)
	)
	quit(0)
