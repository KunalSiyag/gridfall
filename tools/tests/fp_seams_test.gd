extends SceneTree
## S0 seams in legacy files (docs/fp/S0-foundation.md §15): CitySim day length, tick_seconds,
## set_day_seconds, set_tick_phase and skip_to_next_day; Residents resident_said / trip_started and
## de-branded resident text; mayor display names, D.debrand and de-branded brain prompts; CityView
## world_rebuilt / tile_built / tile_cleared / in_setup, building_aabb, site_boxes / site_bounds
## (the construction kit's `colliders`), set_fp_mode hiding (bubbles and quake shake included); and
## the 18 FP input actions.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const ACTIONS := [
	"move_forward", "move_back", "move_left", "move_right", "sprint", "crouch", "jump", "interact",
	"chat_open", "map_toggle", "pause_menu", "time_faster", "time_slower", "time_skip", "photo_mode",
	"hud_toggle", "quick_save", "quick_load",
]
const BRANDS := ["Argon", "DeepSeek", "Kimi", "Qwen", "Grok"]
## Site groups the kit shows or removes one by one with progress; it marks none of them as solid.
const PROGRESS_GROUPS := [&"Trees", &"Stumps", &"Rebar", &"Debris", &"Planting"]

var fails: Array[String] = []


func _init() -> void:
	# The root joins the tree after the first frame; nodes need get_tree() (pause, tweens).
	await process_frame
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "player": false, "hud": false})
	var sim := ctx.sim
	var people := ctx.residents
	var view := ctx.view
	_check_time(sim)
	_check_names(sim)
	_check_debrand()
	_check_brain(sim, people, ctx.brain)
	_check_residents(sim, people)
	_check_view(sim, view)
	for a: String in ACTIONS:
		K.check(fails, InputMap.has_action(a), "input action %s exists" % a)
	K.finish(self, "FP_SEAMS_TEST", fails)


func _check_time(sim: CitySim) -> void:
	K.check(fails, is_equal_approx(sim.day_seconds, 12.0) and is_equal_approx(sim.tick_seconds(), 3.0), "default day is 12 s, tick 3 s")
	var saved_accum: float = sim.get("_time_accum")
	var tick0 := sim.tick_in_day
	sim.tick_in_day = 0
	sim.set("_time_accum", 1.5)
	var p12 := sim.day_progress()
	sim.day_seconds = WS.FP_DAY_SECONDS
	K.check(fails, is_equal_approx(sim.tick_seconds(), 300.0), "FP day gives a 300 s tick")
	sim.set("_time_accum", 150.0)
	var p1200 := sim.day_progress()
	K.check(fails, is_equal_approx(p12, 0.125) and is_equal_approx(p1200, 0.125), "day_progress scales with day_seconds (%.3f, %.3f)" % [p12, p1200])
	K.check(fails, is_equal_approx(sim.tick_phase(), 0.5), "tick_phase scales with day_seconds")
	sim.day_seconds = D.BASE_DAY_SECONDS
	# set_day_seconds keeps the time of day: no pending 300 s tick drained against a 3 s tick.
	sim.tick_in_day = 2
	sim.set("_time_accum", 1.5)
	var before := sim.day_progress()
	sim.set_day_seconds(WS.FP_DAY_SECONDS)
	K.check(fails, is_equal_approx(sim.day_progress(), before) and is_equal_approx(float(sim.get("_time_accum")), 150.0), "set_day_seconds(1200) keeps day_progress (%.4f vs %.4f)" % [sim.day_progress(), before])
	sim.set("_time_accum", 240.0)
	sim.set_day_seconds(D.BASE_DAY_SECONDS)
	K.check(fails, is_equal_approx(float(sim.get("_time_accum")), 2.4) and is_equal_approx(sim.tick_phase(), 0.8), "set_day_seconds(12) rescales a pending FP tick to under one orbit tick")
	sim.set_tick_phase(0.25)
	var q := sim.tick_phase()
	sim.set_tick_phase(3.0)
	K.check(fails, is_equal_approx(q, 0.25) and is_equal_approx(sim.tick_phase(), 1.0), "set_tick_phase sets and clamps the phase")
	sim.set("_time_accum", saved_accum)
	sim.tick_in_day = tick0
	if sim.tick_in_day == 0:
		sim.step_tick()
	var day0 := sim.day
	var ok := sim.skip_to_next_day()
	K.check(fails, ok and sim.tick_in_day == 0 and sim.day == day0 + 1 and sim.day_progress() < 0.01, "skip_to_next_day lands on the next dawn (day %d -> %d, tick %d)" % [day0, sim.day, sim.tick_in_day])


func _check_names(sim: CitySim) -> void:
	var fresh: CitySim = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	get_root().add_child(fresh)
	fresh.new_city(7)
	var ok := fresh.mayors.size() == D.MAYORS.size()
	for i in range(fresh.mayors.size()):
		ok = ok and str(fresh.mayors[i]["name"]) == str(D.MAYORS[i]["display"])
	K.check(fails, ok, "new_city names every mayor by display name")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(sim.to_dict()))
	for i in range((saved["mayors"] as Array).size()):
		(saved["mayors"][i] as Dictionary)["name"] = str(D.MAYORS[i]["name"])
	var loaded: CitySim = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	get_root().add_child(loaded)
	var lok := loaded.from_dict(saved)
	for i in range(loaded.mayors.size()):
		lok = lok and str(loaded.mayors[i]["name"]) == str(D.MAYORS[i]["display"])
	K.check(fails, lok, "from_dict of a branded save restores display names")
	var owner := sim.owner_name(D.idx(5, 5))
	K.check(fails, owner == D.mayor_display(0), "owner_name(5,5) is a display name (%s)" % owner)
	K.check(fails, D.mayor_display(-1) == "" and D.mayor_display(99) == "", "mayor_display is empty out of range")
	fresh.queue_free()
	loaded.queue_free()


func _check_debrand() -> void:
	var cases := [
		["Argon-4", "Ada Okafor"],
		["DeepSeek-V4 says Grok's towers are ugly", "Viktor Han says Mayor Granger's towers are ugly"],
		["deepseek-ai/DeepSeek-V4-Flash-0731 replied", "Viktor Han replied"],
		["Qwen/Qwen3.8-Max and Qwen-3.8 agree", "Rosa Quintero and Rosa Quintero agree"],
		["Kimi-K3.1 and Grok-4.5-Flash met Kimi.", "Mei Kimura and Duke Granger met Mayor Kimura."],
		["Argon-4.", "Ada Okafor."],
		["Grokking the Argonaut", "Grokking the Argonaut"],
		["", ""],
	]
	for c: Array in cases:
		var got := D.debrand(str(c[0]))
		K.check(fails, got == str(c[1]), "debrand(%s) -> %s" % [c[0], got])


func _check_brain(sim: CitySim, people: Residents, brain: CityBrain) -> void:
	var r: Dictionary = {}
	for p: Dictionary in people.people:
		if sim.district[int(p["home"])] == 0:
			r = p
			break
	K.check(fails, not r.is_empty(), "a resident lives in district 0")
	if r.is_empty():
		return
	# An old save's branded letter, and vote keys that are the lowercase brand ids.
	people.messages.append({"id": r["id"], "name": r["name"], "job": r["job_title"], "mood": 5, "district": 0, "day": sim.day, "text": "DeepSeek, where do we dump trash?", "kind": "daily"})
	brain.proposals["clean_air_act"] = {"by": "Ada Okafor", "day": sim.day, "votes": {"argon": "yes", "grok": "no"}}
	var prompt: String = brain.call("_mayor_user_prompt", 0, sim.day)
	K.check(fails, prompt.contains("Mayor Han, where do we dump trash?") and prompt.contains("Ada Okafor") and not _branded(prompt) and not _has_ids(prompt), "the mayor prompt carries no brand words or mayor ids%s" % ("" if not _branded(prompt) and not _has_ids(prompt) else ": " + _brand_context(prompt)))
	var votes: Dictionary = brain.call("_votes_by_name", {"argon": "yes", "grok": "no"})
	K.check(fails, votes == {"Ada Okafor": "yes", "Duke Granger": "no"}, "votes are keyed by display name in prompts (%s)" % str(votes))
	# from_dict normalises an old save's branded state.
	var saved := brain.to_dict()
	saved["proposals"] = {"curfew": {"by": "Kimi-K3", "day": 1, "votes": {"kimi": "yes"}}}
	(saved["mayor_state"][0] as Dictionary)["post"] = "Qwen-3.8 is wrong"
	(saved["mayor_state"][0] as Dictionary)["thoughts"] = ["Day 1: Grok is loud"]
	saved["last_paper"] = {"headline": "Argon-4 wins", "stories": [{"title": "DeepSeek-V4 sulks", "body": "Kimi agrees"}], "editorial": "Grok-4.5 rules"}
	saved["last_council"] = {"statement": "Qwen and Grok voted no"}
	brain.from_dict(JSON.parse_string(JSON.stringify(saved)))
	var restored := JSON.stringify([brain.proposals, brain.mayor_state[0]["post"], brain.mayor_state[0]["thoughts"], brain.last_paper, brain.last_council])
	K.check(fails, not _branded(restored) and str(brain.proposals["curfew"]["by"]) == "Mei Kimura", "brain.from_dict de-brands restored text%s" % ("" if not _branded(restored) else ": " + _brand_context(restored)))
	brain.proposals.clear()
	people.messages.pop_back()


func _branded(t: String) -> bool:
	for w: String in BRANDS:
		if RegEx.create_from_string("\\b%s\\b" % w).search(t) != null:
			return true
	return false


## Mayor ids (the lowercase brand words) as JSON keys or values.
func _has_ids(t: String) -> bool:
	for m: Dictionary in D.MAYORS:
		if t.contains("\"%s\"" % str(m["id"])):
			return true
	return false


func _brand_context(t: String) -> String:
	for w: String in BRANDS + ["\"argon\"", "\"deepseek\"", "\"kimi\"", "\"qwen\"", "\"grok\""]:
		var k := t.find(w)
		if k >= 0:
			return t.substr(maxi(0, k - 60), 140)
	return ""


func _check_residents(sim: CitySim, people: Residents) -> void:
	var said: Array = []
	var trips: Array = []
	people.resident_said.connect(func(id: String, text: String, kind: String) -> void: said.append([id, text, kind]))
	people.trip_started.connect(func(id: String, a: int, b: int, mode: String) -> void: trips.append([id, a, b, mode]))
	K.check(fails, people.people.size() >= 5, "the grown kit city has residents (%d)" % people.people.size())
	if people.people.is_empty():
		return
	var r: Dictionary = people.people[0]
	var rid := str(r["id"])
	people.apply_plan(r, {"say": "Hi"}, "test", "")
	K.check(fails, said.size() == 1 and said[0] == [rid, "Hi", "say"], "apply_plan emits resident_said(say)")
	said.clear()
	people.apply_plan(r, {"say": "   "}, "test", "")
	K.check(fails, said.is_empty(), "a blank say line emits nothing")
	people.respond(r, {"id": 9999, "label": "Test Fire", "x": 5, "y": 5}, {"say": "Run!", "action": "ignore"}, "test", "")
	K.check(fails, said.size() == 1 and said[0] == [rid, "Run!", "react"], "respond emits resident_said(react)")
	said.clear()
	people.call("_post_message", r, "Fix the roads", "daily")
	K.check(fails, said.size() == 1 and said[0] == [rid, "Fix the roads", "letter"], "_post_message emits resident_said(letter)")
	while people.messages.size() < 305:
		people.messages.append({"id": "pad", "text": "pad"})
	said.clear()
	people.call("_post_message", r, "Still here", "daily")
	K.check(fails, said.size() == 1 and str(said[0][2]) == "letter", "_post_message emits at 300+ messages too")
	# Resident LLM text is de-branded at the source (the replay cache carries brand names).
	said.clear()
	people.apply_plan(r, {"say": "Argon's doing right by us.", "thought": "Grok-4.5 talks a lot", "mood_reason": "Qwen fixed the pipes", "message_to_mayor": "DeepSeek, where do we dump trash?"}, "test", "")
	var texts: Array = said.map(func(e: Array) -> String: return str(e[1]))
	K.check(fails, said.size() == 2 and texts.has("Mayor Okafor's doing right by us.") and texts.has("Mayor Han, where do we dump trash?"), "apply_plan de-brands say and letters (%s)" % str(texts))
	K.check(fails, not _branded(str(r["thought"])) and not _branded(str(r["mood_reason"])) and not _branded(str(r["message"])), "apply_plan de-brands thought, mood_reason and message")
	said.clear()
	people.respond(r, {"id": 9999, "label": "Test Fire", "x": 5, "y": 5}, {"say": "Kimi will fix it", "thought": "Qwen-3.8 is slow", "action": "ignore"}, "test", "")
	K.check(fails, said.size() == 1 and str(said[0][1]) == "Mayor Kimura will fix it" and not _branded(str(r["thought"])), "respond de-brands say and thought (%s)" % str(said))
	# _go to a different tile emits trip_started with from == the old position.
	var walker: Dictionary = {}
	var target := -1
	for p: Dictionary in people.people:
		if int(p["work"]) >= 0 and int(p["at"]) != int(p["work"]) and not people.route_between(int(p["at"]), int(p["work"])).is_empty():
			walker = p
			target = int(p["work"])
			break
	K.check(fails, not walker.is_empty(), "a resident can commute to work")
	if walker.is_empty():
		return
	var from := int(walker["at"])
	trips.clear()
	people.call("_go", walker, target, "work")
	K.check(fails, trips.size() == 1 and int(trips[0][1]) == from and int(trips[0][2]) == target and str(trips[0][3]) in ["car", "bus", "bike", "walk"], "_go emits trip_started(%s)" % str(trips))
	trips.clear()
	people.call("_go", walker, int(walker["at"]), "work")
	K.check(fails, trips.is_empty(), "_go to the same tile emits no trip")
	# A stay-home commuter on a long non-work trip arrives as "walk".
	(walker["plan"] as Dictionary)["commute"] = "stay_home"
	var far := -1
	for i in sim.active:
		if sim.kind[i] != D.ROAD and i != int(walker["at"]) and people.route_between(int(walker["at"]), i).size() > 6:
			far = i
			break
	K.check(fails, far >= 0, "a destination more than 6 road tiles away exists")
	if far >= 0:
		trips.clear()
		people.call("_go", walker, far, "shopping")
		K.check(fails, trips.size() == 1 and str(trips[0][3]) == "walk" and str(walker["mode"]) == "stay_home", "stay_home trips are reported as walk (%s)" % str(trips))


func _check_view(sim: CitySim, view: CityView) -> void:
	var counts := {"rebuilt": 0, "built": 0, "built_in_setup": 0, "rebuilt_in_setup": 0}
	var on_built := func(_i: int, _h: Node3D) -> void:
		counts["built"] += 1
		if view.in_setup:
			counts["built_in_setup"] += 1
	var on_rebuilt := func() -> void:
		counts["rebuilt"] += 1
		if view.in_setup:
			counts["rebuilt_in_setup"] += 1
	view.tile_built.connect(on_built)
	view.world_rebuilt.connect(on_rebuilt)
	view.setup(sim, view.camera)
	var holders: int = (view.get("_tile_nodes") as Dictionary).size()
	K.check(fails, counts["rebuilt"] == 1 and counts["rebuilt_in_setup"] == 0, "world_rebuilt fires once per setup, after in_setup clears")
	K.check(fails, counts["built"] == holders and counts["built_in_setup"] == holders and holders > 0, "tile_built fires once per holder inside setup (%d / %d)" % [counts["built"], holders])
	K.check(fails, not view.in_setup, "in_setup is false after setup")
	view.tile_built.disconnect(on_built)
	view.world_rebuilt.disconnect(on_rebuilt)
	# building_aabb: zone buildings sit on their own tile; roads have none.
	var zones := 0
	var zone_ok := true
	var road_ok := true
	for i in sim.active:
		var b := view.building_aabb(i)
		var x := D.tx(i)
		var y := D.ty(i)
		if D.is_zone(sim.kind[i]) and sim.level[i] > 0 and not sim.sites.has(i):
			zones += 1
			var inside := b.size.x > 0.0 and b.position.x >= x - 0.5 - 1e-4 and b.end.x <= x + 0.5 + 1e-4 and b.position.z >= y - 0.5 - 1e-4 and b.end.z <= y + 0.5 + 1e-4 and absf(b.position.y) < 0.02 and b.size.y > 0.05
			if not inside:
				zone_ok = false
				print("  bad building_aabb at (%d,%d): %s" % [x, y, b])
		elif sim.kind[i] == D.ROAD and b.size != Vector3.ZERO:
			road_ok = false
	K.check(fails, zones > 0 and zone_ok, "building_aabb of %d zone buildings is non-empty and inside the tile" % zones)
	K.check(fails, road_ok, "road tiles have no building_aabb")
	var holder := view.tile_holder(_first_zone(sim))
	K.check(fails, holder != null and str(holder.get_meta("building_path", "")).begins_with("res://"), "zone holders carry building_path meta")
	# site_boxes: the kit's blocking parts on every drawn site (build, road works, demolition), and
	# every drawn part a walker can bump into lies inside one of them; site_bounds is their merge.
	var mode := sim.construction_mode
	sim.construction_mode = "staged"
	sim.mayors[0]["treasury"] = int(sim.mayors[0]["treasury"]) + 20000
	var lots: Array = sim.open_lots(0, 10)
	if lots.size() >= 2:
		sim.apply_action(0, {"type": "build", "building": "police", "x": int(lots[0][0]), "y": int(lots[0][1])})
		sim.apply_action(0, {"type": "road", "x": int(lots[1][0]), "y": int(lots[1][1]), "x2": int(lots[1][0]), "y2": int(lots[1][1])})
	for i in sim.active:
		if D.is_zone(sim.kind[i]) and sim.level[i] > 0 and sim.district[i] == 0 and not sim.sites.has(i):
			sim.apply_action(0, {"type": "bulldoze", "x": D.tx(i), "y": D.ty(i)})
			break
	sim.step_tick()
	sim.construction_mode = mode
	var seen := {"build": 0, "road": 0, "demolition": 0}
	var bad: Array[String] = []
	var parts := 0
	for i: int in sim.sites.keys():
		var st: Dictionary = sim.sites[i]
		var t := str(st["type"])
		if t == "road":
			seen["road"] += 1
		elif t == "demolish":
			if str(st["plan"]) == "demolish" and sim.site_stage_name(st) == "demolition":
				seen["demolition"] += 1
		else:
			seen["build"] += 1
		var site_holder := view.tile_holder(i)
		var site: Node3D = site_holder.get_node_or_null("Site") as Node3D if site_holder != null else null
		var boxes := view.site_boxes(i)
		if site == null or boxes.is_empty():
			bad.append("%s site %d: Site node %s, %d boxes" % [t, i, site != null, boxes.size()])
			continue
		var merged := AABB()
		for b: AABB in boxes:
			merged = b if merged.size == Vector3.ZERO else merged.merge(b)
		if not view.site_bounds(i).is_equal_approx(merged):
			bad.append("%s site %d: site_bounds %s is not the merge %s" % [t, i, view.site_bounds(i), merged])
		# Bridge works stand in water, which nobody walks on.
		if sim.terrain[i] == D.WATER:
			continue
		var c := Vector3(D.tx(i), 0, D.ty(i))
		for a: AABB in _walker_parts(site):
			parts += 1
			if not _covered_xz(a, boxes):
				bad.append("%s/%s site %d: part x[%.3f,%.3f] z[%.3f,%.3f] in no box" % [t, sim.site_stage_name(st), i, a.position.x - c.x, a.end.x - c.x, a.position.z - c.z, a.end.z - c.z])
	var off := 0
	for i in sim.active:
		if not sim.sites.has(i) and (not view.site_boxes(i).is_empty() or view.site_bounds(i).size != Vector3.ZERO):
			off += 1
	K.check(fails, seen["build"] > 0 and seen["road"] > 0 and seen["demolition"] > 0 and parts > 0, "site fixtures: a build, a road and a demolition site (%s, %d parts)" % [str(seen), parts])
	K.check(fails, bad.is_empty() and off == 0, "site_boxes cover every drawn part a walker can bump into (%s, %d off-site)" % [str(bad.slice(0, 6)), off])
	# set_fp_mode hides the orbit layers and restores them.
	var changes: Array = []
	view.fp_mode_changed.connect(func(on: bool) -> void: changes.append(on))
	view.set("_shake", 1.2)
	view.set_fp_mode(true)
	K.check(fails, changes == [true], "set_fp_mode(true) emits fp_mode_changed once")
	K.check(fails, is_zero_approx(float(view.get("_shake"))), "entering FP drops a pending quake shake")
	K.check(fails, view.avatars != null and view.avatars.fp_hidden, "FP sets avatars.fp_hidden")
	K.check(fails, _bubble_shown(sim, view, "Testing the bubble one") == false, "FP hides resident speech bubbles")
	K.check(fails, _orbit_layers_visible(view) == 0, "FP hides labels, territory, icons, cursor and mayor bots")
	view.set_fp_mode(true)
	K.check(fails, changes == [true], "set_fp_mode(true) again emits nothing")
	view.set_overlay("power")
	var tiles_root: Node3D = view.get("_tiles_root")
	K.check(fails, tiles_root.visible and view.overlay_mode == "none", "set_overlay(power) is ignored in FP")
	sim.trigger_disaster("earthquake", 16, 16, "player", "seams test")
	K.check(fails, is_zero_approx(float(view.get("_shake"))), "a quake in FP queues no camera shake")
	view.set_fp_mode(false)
	K.check(fails, changes == [true, false], "set_fp_mode(false) emits fp_mode_changed(false)")
	K.check(fails, not view.avatars.fp_hidden and _bubble_shown(sim, view, "Testing the bubble two"), "orbit shows resident speech bubbles again")
	K.check(fails, _orbit_layers_visible(view) == 4 + D.MAYORS.size(), "orbit restores the hidden layers")
	# tile_cleared: a built tile cleared to empty land.
	var cleared: Array = []
	view.tile_cleared.connect(func(i: int) -> void: cleared.append(i))
	var z := _first_zone(sim)
	sim.kind[z] = D.EMPTY
	sim.level[z] = 0
	view.call("_on_tiles_changed", PackedInt32Array([z]))
	K.check(fails, cleared == [z] and view.tile_holder(z) == null, "tile_cleared fires when a built tile becomes empty land")


## Visible orbit-only layers: labels, territory, power icons, water icons, plus each mayor root.
func _orbit_layers_visible(view: CityView) -> int:
	var n := 0
	for key: String in ["_labels_root", "_territory_root", "_power_icons", "_water_icons"]:
		var node: Node3D = view.get(key)
		if node != null and node.visible:
			n += 1
	for av: Dictionary in view.get("_avatars"):
		if (av["root"] as Node3D).visible:
			n += 1
	var cursor: Node3D = view.get("_cursor")
	if cursor != null and cursor.visible:
		n += 100
	return n


## Makes the first resident's avatar visible, gives them a new line, runs one avatar frame and
## returns whether the bubble shows.
func _bubble_shown(sim: CitySim, view: CityView, line: String) -> bool:
	var r: Dictionary = sim.people.people[0]
	var a: Dictionary = view.avatars.call("_avatar", r)
	(a["root"] as Node3D).visible = true
	r["say"] = line
	view.avatars.call("_process", 0.016)
	return (a["bubble"] as Label3D).visible


## World AABBs of the visible meshes under a Site node that a walker can bump into: at least
## STEP_HEIGHT tall and starting below head height. Machine arms ("Boom") and the progress groups
## are left out, as in ConstructionKit.solid().
func _walker_parts(site: Node3D) -> Array[AABB]:
	var out: Array[AABB] = []
	var stack: Array[Node] = [site]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null and mi.is_visible_in_tree():
			var a := mi.global_transform * mi.mesh.get_aabb()
			if a.size.y >= WS.STEP_HEIGHT and a.position.y < WS.PLAYER_HEIGHT:
				out.append(a)
		for ch in n.get_children():
			if ch.name != &"Boom" and not PROGRESS_GROUPS.has(ch.name):
				stack.append(ch)
	return out


## True when one of boxes contains a in x and z.
func _covered_xz(a: AABB, boxes: Array[AABB]) -> bool:
	for b: AABB in boxes:
		if a.position.x >= b.position.x - 1e-4 and a.end.x <= b.end.x + 1e-4 and a.position.z >= b.position.z - 1e-4 and a.end.z <= b.end.z + 1e-4:
			return true
	return false


func _first_zone(sim: CitySim) -> int:
	for i in sim.active:
		if D.is_zone(sim.kind[i]) and sim.level[i] > 0 and not sim.sites.has(i):
			return i
	return -1
