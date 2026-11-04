extends SceneTree
## The long-session soak (not in tools/gate.sh: it takes minutes; the nightly workflow runs it). It
## boots the real Main in first person, offline, then swaps in a client whose network is a script
## (support/soak_live_client.gd) so every live path runs and the session cache fills as it would
## with a key, and plays 40 game days at 8x. After each day it prints the node count, static
## memory, object and orphan counts, the cache's size and the size of the save the game would
## write, and at the end asserts the caps a long session must stay under: the node count and the
## static memory stop growing, the saved cache keeps at most GmiCache.SAVE_KEEP_DAYS days per key,
## the save stays under a size cap and flat after the first days, the breakers stay closed, the
## live paths were really exercised and the error count stays small. Environment:
## GRIDFALL_SOAK_DAYS (default 40, at least 8), GRIDFALL_SOAK_SECS (wall-clock cap, default 1500).
## Prints FP_SOAK: PASS|FAIL <reasons>.
##
##   godot --headless --path . -s tools/tests/fp_soak.gd

const D := preload("res://scripts/sim/sim_defs.gd")
const FAKE := preload("res://tools/tests/support/soak_live_client.gd")
const ERRORS := preload("res://tools/tests/support/soak_error_count.gd")
const SAVE := "user://fp_soak_save.json"
## Caps. Nodes and memory are measured against day WARM, after the city has grown into its first
## steady state; the numbers are generous on purpose: this catches growth without bound, not noise.
const WARM := 6
const NODE_GROWTH := 1.5
const NODE_SLACK := 800
const MEMORY_GROWTH := 1.6
## Script errors allowed (none), and how often one site may repeat (headless engine noise is a few
## per site; a per-frame bug is thousands).
const SCRIPT_ERROR_CAP := 0
const SITE_REPEAT_CAP := 60
const SAVE_CAP := 3000000
const SAVE_FLAT := 1.35
const DAY_ROW := (
	"FP_SOAK day=%d nodes=%d static_mb=%.1f objects=%d orphans=%d cache_keys=%d cache_entries=%d "
	+ "saved_cache_entries=%d save_bytes=%d live_ok=%d pop=%d wall_s=%.0f"
)

var fails: Array[String] = []
var rows: Array[Dictionary] = []
var errors: Logger = ERRORS.new()


func _init() -> void:
	OS.add_logger(errors)
	await process_frame
	OS.set_environment("GRIDFALL_VIEW", "fp")
	OS.set_environment("GRIDFALL_OFFLINE", "1")
	OS.set_environment("GRIDFALL_NEW_CITY", "1")
	var days := maxi(
		8,
		(
			int(OS.get_environment("GRIDFALL_SOAK_DAYS"))
			if OS.has_environment("GRIDFALL_SOAK_DAYS")
			else 40
		)
	)
	var cap_s := (
		float(OS.get_environment("GRIDFALL_SOAK_SECS"))
		if OS.has_environment("GRIDFALL_SOAK_SECS")
		else 1500.0
	)
	change_scene_to_packed(load("res://scenes/main.tscn") as PackedScene)
	for _k in range(8):
		await process_frame
	var main: Node = current_scene
	if main == null or main.get("fp") == null:
		_finish(["Main did not boot in first person"])
		return
	var client: GmiClient = main.client
	client.set_script(FAKE)
	client._load_replay_cache()
	client.live_enabled = true
	client.mayor_plan = func(mi: int) -> Dictionary: return main.brain._heuristic_mayor(mi)
	main.autosave_enabled = false
	var sim: CitySim = main.sim
	sim.set_day_seconds(D.BASE_DAY_SECONDS)
	sim.set_speed(8)
	var t0 := Time.get_ticks_msec()
	var last_day := 0
	while sim.day <= days and float(Time.get_ticks_msec() - t0) / 1000.0 < cap_s:
		await process_frame
		if sim.day != last_day and sim.tick_in_day >= 1 and not sim.job_pending():
			last_day = sim.day
			rows.append(_measure(main, client, t0))
	sim.set_speed(0)
	print(
		(
			"FP_SOAK: reached day %d of %d in %.0f s"
			% [sim.day, days, float(Time.get_ticks_msec() - t0) / 1000.0]
		)
	)
	_assert_caps(client, days)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE))
	_finish(fails)


## One row: the process's counts, the cache and the save the game would write now.
func _measure(main: Node, client: GmiClient, t0: int) -> Dictionary:
	var err: Error = main._write_save(SAVE, "soak")
	var bytes := 0
	var saved_entries := 0
	if err == OK:
		var f := FileAccess.open(SAVE, FileAccess.READ)
		bytes = f.get_length()
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			saved_entries = GmiCache.entry_count(
				((parsed as Dictionary).get("client", {}) as Dictionary).get("session_cache", {})
			)
	var row := {
		"day": int(main.sim.day),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"static_mb": float(OS.get_static_memory_usage()) / 1048576.0,
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"cache_keys": client.session_cache.size(),
		"cache_entries": GmiCache.entry_count(client.session_cache),
		"saved_entries": saved_entries,
		"save_bytes": bytes,
		"live_ok": int(client.stats["live_ok"]),
		"pop": int(main.sim.stats.get("population", 0)),
	}
	print(
		(
			DAY_ROW
			% [
				row["day"],
				row["nodes"],
				row["static_mb"],
				row["objects"],
				row["orphans"],
				row["cache_keys"],
				row["cache_entries"],
				row["saved_entries"],
				row["save_bytes"],
				row["live_ok"],
				row["pop"],
				float(Time.get_ticks_msec() - t0) / 1000.0
			]
		)
	)
	return row


func _assert_caps(client: GmiClient, days: int) -> void:
	_expect(rows.size() >= days - 2, "the soak measured %d of %d days" % [rows.size(), days])
	if rows.size() < WARM + 2:
		return
	var warm: Dictionary = rows[WARM - 1]
	var last: Dictionary = rows[rows.size() - 1]
	var peak_nodes := 0
	var peak_mb := 0.0
	var peak_save := 0
	for r: Dictionary in rows.slice(WARM - 1):
		peak_nodes = maxi(peak_nodes, int(r["nodes"]))
		peak_mb = maxf(peak_mb, float(r["static_mb"]))
		peak_save = maxi(peak_save, int(r["save_bytes"]))
	var node_cap := int(float(warm["nodes"]) * NODE_GROWTH) + NODE_SLACK
	_expect(
		peak_nodes <= node_cap,
		(
			"nodes stay under %d after day %d (peak %d, day %d had %d)"
			% [node_cap, WARM, peak_nodes, WARM, int(warm["nodes"])]
		)
	)
	var mb_cap := float(warm["static_mb"]) * MEMORY_GROWTH
	_expect(
		peak_mb <= mb_cap,
		(
			"static memory stays under %.0f MB after day %d (peak %.0f, day %d had %.0f)"
			% [mb_cap, WARM, peak_mb, WARM, float(warm["static_mb"])]
		)
	)
	_expect(
		peak_save <= SAVE_CAP, "the save stays under %d bytes (peak %d)" % [SAVE_CAP, peak_save]
	)
	var flat_from: Dictionary = rows[mini(rows.size() - 1, 12)]
	_expect(
		float(last["save_bytes"]) <= float(flat_from["save_bytes"]) * SAVE_FLAT,
		(
			"the save stops growing: day %d %d bytes, day %d %d bytes"
			% [
				int(flat_from["day"]),
				int(flat_from["save_bytes"]),
				int(last["day"]),
				int(last["save_bytes"])
			]
		)
	)
	var per_key_cap := GmiCache.SAVE_KEEP_DAYS * 8
	_expect(
		int(last["saved_entries"]) <= int(last["cache_keys"]) * per_key_cap,
		(
			"the saved cache keeps a few days per key (%d entries for %d keys)"
			% [int(last["saved_entries"]), int(last["cache_keys"])]
		)
	)
	_expect(
		int(last["cache_entries"]) > int(last["saved_entries"]),
		(
			"fixture: the session cache really filled (%d entries in memory, %d saved)"
			% [int(last["cache_entries"]), int(last["saved_entries"])]
		)
	)
	_expect(
		int(last["live_ok"]) >= days * 5,
		"the live paths ran (%d live calls in %d days)" % [int(last["live_ok"]), days]
	)
	_expect(
		client.breaker_state() == "closed" and client.live_outcomes.count(false) == 0,
		"no call failed and no breaker opened"
	)
	var served: Dictionary = client.get("served")
	_expect(
		int(served.get("mayor", 0)) >= (days - 2) * 5 and int(served.get("residents", 0)) > 0,
		"mayor and resident calls were served (%s)" % str(served)
	)
	# A bug that raises every frame (a bus whose stop index outlives its line did, 7 000 times in 14
	# days) shows as a script error or one site repeating; the engine's own headless noise does not.
	var worst: Array = errors.worst_site()
	_expect(
		int(errors.kinds["script"]) <= SCRIPT_ERROR_CAP,
		"no script errors (%d; first: %s)" % [int(errors.kinds["script"]), errors.first_script]
	)
	_expect(
		int(worst[1]) <= SITE_REPEAT_CAP,
		(
			"no error site repeats more than %d times (%s %d; all %s)"
			% [SITE_REPEAT_CAP, worst[0], worst[1], str(errors.kinds)]
		)
	)
	print(
		(
			"FP_SOAK: peaks nodes=%d static_mb=%.1f save_bytes=%d; day %d vs day %d"
			% [peak_nodes, peak_mb, peak_save, WARM, int(last["day"])]
		)
	)


func _expect(ok: bool, what: String) -> void:
	print(("FP_SOAK:   ok   " if ok else "FP_SOAK:   FAIL ") + what)
	if not ok:
		fails.append(what)


func _finish(reasons: Array) -> void:
	OS.remove_logger(errors)
	print("FP_SOAK: " + ("PASS" if reasons.is_empty() else "FAIL " + str(reasons)))
	quit(0 if reasons.is_empty() else 1)
