extends SceneTree
## Slice B acceptance (docs/fp/slices/B-hud.md): no branding, chips, the minimap image and its
## incremental repaint, heading-up rotation, pings and the banner, toasts, the pause menu and
## settings, the street label, the third-person prompt anchoring and first-person crosshair, the
## minimap wheel, the place card (no LLM call), the full map and waypoint, and reload. Prints
## FP_HUD_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const MinimapModel := preload("res://scripts/fp/ui/minimap_model.gd")
const MinimapView := preload("res://scripts/fp/ui/minimap_view.gd")
## A GmiClient that counts every call (B must make none).
const STUB_CLIENT := """extends GmiClient
var calls: int = 0
func chat_json(role: String, agent_id: String, model: String, system_prompt: String, user_prompt: String, day: int, max_tokens: int, timeout_s: float, heuristic: Callable) -> Dictionary:
	calls += 1
	return await super(role, agent_id, model, system_prompt, user_prompt, day, max_tokens, timeout_s, heuristic)
func live_json(role: String, agent_id: String, model: String, system_prompt: String, user_prompt: String, day: int, max_tokens: int, timeout_s: float) -> Dictionary:
	calls += 1
	return await super(role, agent_id, model, system_prompt, user_prompt, day, max_tokens, timeout_s)
"""
## E's traffic feature stand-in: two cars and a walker near p, and one visible resident.
const STUB_TRAFFIC := """extends FpFeature
var agent_calls: int = 0
func feature_id() -> String:
	return "traffic"
func agents_near(p: Vector3, _r: float) -> Array:
	agent_calls += 1
	return [
		{"id": 1, "pos": p + Vector3(2, 0, 0), "vel": Vector3(0, 0, -0.5), "speed": 0.5, "kind": "car", "driver_id": "", "heading": 0.0},
		{"id": 2, "pos": p + Vector3(-3, 0, 1), "vel": Vector3.ZERO, "speed": 0.0, "kind": "bus", "driver_id": "", "heading": 1.57},
		{"id": 3, "pos": p + Vector3(0, 0, 2), "vel": Vector3.ZERO, "speed": 0.0, "kind": "pedestrian", "driver_id": "", "heading": 0.0},
	]
func visible_near(p: Vector3, _r: float) -> Array:
	return [{"id": "r1", "pos": p + Vector3(1, 0, 1)}]
"""
## Main stand-in for the pause menu: save and load notify once each, like main.gd.
const STUB_MAIN := """extends Node3D
var bus: GameBus
var saves: int = 0
var loads: int = 0
func save_game() -> void:
	saves += 1
	bus.toast.emit("City saved (Day 1)", "success")
func load_game() -> bool:
	loads += 1
	bus.toast.emit("City loaded", "success")
	return true
func exit_fp() -> void:
	pass
"""

var fails: Array = []


func _init() -> void:
	await process_frame
	var client: GmiClient = _script(STUB_CLIENT).new()
	client.name = "StubClient"
	client.live_enabled = false
	var ctx := K.make_ctx(get_root(), {"grow": true, "client": client})
	var f := K.make_feature(ctx, "hud_widgets")
	K.check(fails, f != null and f.get("model") != null, "hud_widgets feature is set up with a model")
	await _frames(3)
	var hud := ctx.hud
	_check_fixtures(ctx)
	_check_branding(ctx)
	_check_chips(ctx)
	_check_minimap_image(ctx, f)
	await _check_rotation(ctx)
	await _check_street(ctx)
	_check_pings(ctx)
	await _check_toasts(ctx)
	await _check_wheel_first(ctx)
	await _check_agents(ctx)
	await _check_card(ctx, client)
	await _check_map(ctx, f)
	_check_compass_labels()
	_check_caption(ctx)
	await _check_reload(ctx)
	await _check_pause(ctx)
	var st: Dictionary = f.self_test()
	K.check(fails, bool(st.get("ok", false)), "hud_widgets self_test (%s)" % st.get("detail", ""))
	_perf(ctx, f)
	await _check_third_person()
	K.check(fails, hud != null, "hud survives")
	K.finish(self, "FP_HUD_TEST", fails)


func _check_fixtures(ctx: FpContext) -> void:
	K.check(fails, int(ctx.sim.stats.get("population", 0)) > 0 and ctx.residents.people.size() >= 5, "grown city has people (%d pop, %d residents)" % [int(ctx.sim.stats.get("population", 0)), ctx.residents.people.size()])
	K.check(fails, _find(ctx, func(i: int) -> bool: return ctx.sim.kind[i] == D.ROAD) >= 0, "a road tile exists")
	K.check(fails, _find_c_lot(ctx) >= 0, "a C lot at level >= 1 exists")


func _check_branding(ctx: FpContext) -> void:
	# A branded incident label and toast must reach the screen de-branded.
	ctx.sim.events.append({"id": 9001, "type": "fire", "label": "DeepSeek-V4 fire", "x": 5, "y": 5})
	ctx.sim.stats_updated.emit()
	ctx.bus.toast.emit("Kimi-K3 approved a road", "info")
	var texts := S.owned_texts(ctx.hud)
	var bad := PackedStringArray()
	for t in texts:
		if S.branded(t):
			bad.append(t)
	K.check(fails, texts.size() > 20 and bad.is_empty(), "no branding in %d B texts %s" % [texts.size(), str(bad)])
	K.check(fails, ctx.hud.chips.chip("alerts").visible and ctx.hud.chips.text_of("alerts") == str(ctx.sim.events.size()), "alerts chip shows the incident count (%s)" % ctx.hud.chips.text_of("alerts"))
	ctx.sim.events.pop_back()
	ctx.sim.stats_updated.emit()


func _check_chips(ctx: FpContext) -> void:
	K.check(fails, S.fmt(1168) == "1,168" and S.money(3222) == "$3.2k" and S.money(-3222) == "−$3,222" and S.money(950) == "$950" and S.money(1240000) == "$1.2M", "compact formats (%s, %s, %s)" % [S.fmt(1168), S.money(3222), S.money(-3222)])
	K.check(fails, S.distance(45.0 * WS.M) == "45 m" and S.distance(1200.0 * WS.M) == "1.2 km", "distances in metres (%s, %s)" % [S.distance(45.0 * WS.M), S.distance(1200.0 * WS.M)])
	var chips := ctx.hud.chips
	var pop := int(ctx.sim.stats.get("population", 0))
	K.check(fails, chips.text_of("pop") == S.fmt(pop) and (pop < 1000 or chips.text_of("pop").contains(",")), "population chip %s == %d with separators" % [chips.text_of("pop"), pop])
	K.check(fails, ctx.residents.is_active(), "residents are active")
	var mood := float(ctx.residents.sentiment.get("mood", 0.0)) * 10.0
	K.check(fails, chips.text_of("mood") == "%.1f" % snappedf(mood, 0.1), "mood chip %s == round(sentiment.mood*10, 1) = %.1f" % [chips.text_of("mood"), mood])
	var day_text := _visible_text(ctx.hud.slot("top_bar"))
	K.check(fails, day_text.contains("Day %d" % ctx.sim.day), "top bar shows Day %d (%s)" % [ctx.sim.day, day_text])
	var st := ctx.sim.stats
	var keep_need: Variant = st.get("power_need", 0.0)
	var keep_unp: Variant = st.get("unpowered", 0)
	st["unpowered"] = 0
	st["power_need"] = float(st.get("power_cap", 0.0)) * 0.5
	ctx.sim.stats_updated.emit()
	var ok_state := chips.state_of("power")
	st["power_need"] = float(st.get("power_cap", 0.0)) + 1.0
	ctx.sim.stats_updated.emit()
	var red: Color = (chips.chip("power").find_child("Value", true, false) as Label).get_theme_color("font_color")
	K.check(fails, ok_state != "fail" and chips.state_of("power") == "fail" and red.is_equal_approx(S.RED), "power chip turns red over capacity (%s -> %s)" % [ok_state, chips.state_of("power")])
	st["power_need"] = keep_need
	st["unpowered"] = keep_unp
	ctx.sim.stats_updated.emit()


func _check_minimap_image(ctx: FpContext, f: FpFeature) -> void:
	var m: MinimapModel = f.get("model")
	var sim := ctx.sim
	K.check(fails, m.image.get_width() == 192 and m.image.get_height() == 192 and m.texture.get_size() == Vector2(192, 192), "minimap image is 192x192")
	var road := _find(ctx, func(i: int) -> bool: return sim.kind[i] == D.ROAD and sim.terrain[i] != D.WATER)
	K.check(fails, road >= 0 and _pixel(m, road).is_equal_approx(_q(MinimapModel.COL_ROAD)), "road pixel has the road colour")
	var water := -1
	for i in range(D.W * D.H):
		if sim.terrain[i] == D.WATER and sim.kind[i] != D.ROAD:
			water = i
			break
	K.check(fails, water >= 0 and _pixel(m, water).is_equal_approx(_q(MinimapModel.COL_WATER)), "water pixel has the water colour")
	var c2 := _find(ctx, func(i: int) -> bool: return sim.kind[i] == D.ZONE_C and sim.level[i] == 2)
	var forced := false
	var c_keep := 0
	if c2 < 0:
		c2 = _find_c_lot(ctx)
		c_keep = sim.level[c2]
		sim.level[c2] = 2
		forced = true
		m.repaint(PackedInt32Array([c2]))
	K.check(fails, c2 >= 0 and _pixel(m, c2).is_equal_approx(_q(MinimapModel.ZONE_COLORS[D.ZONE_C])), "C level-2 pixel has the C colour%s" % (" (level forced)" if forced else ""))
	if forced:
		sim.level[c2] = c_keep
		m.repaint(PackedInt32Array([c2]))
	# One tile changes kind: tiles_changed repaints exactly that pixel.
	var e := _find(ctx, func(i: int) -> bool: return sim.kind[i] == D.EMPTY and sim.terrain[i] != D.WATER)
	var before := _pixel(m, e)
	var keep := sim.kind[e]
	m.reset_counters()
	sim.kind[e] = D.PARK
	sim.tiles_changed.emit(PackedInt32Array([e]))
	K.check(fails, m.repainted_count == 1 and _pixel(m, e).is_equal_approx(_q(MinimapModel.COL_PARK)) and not before.is_equal_approx(_pixel(m, e)), "tiles_changed([i]) repaints only that pixel (%d)" % m.repainted_count)
	sim.kind[e] = keep
	sim.tiles_changed.emit(PackedInt32Array([e]))
	var hazed := 0
	var clear := 0
	for py in range(m.survey.get_height()):
		for px in range(m.survey.get_width()):
			if m.survey.get_pixel(px, py).r > 0.5:
				clear += 1
			else:
				hazed += 1
	K.check(fails, hazed > 0 and clear > 0, "survey haze marks %d unsurveyed and %d surveyed plots" % [hazed, clear])
	var view := ctx.hud.minimap
	var pad := MinimapView.PAD
	K.check(fails, view.map_rect().visible and view.map_rect().texture == m.texture and is_equal_approx(MinimapView.DIAM, 200.0) and view.map_rect().size == Vector2(200 + 2 * pad, 200 + 2 * pad), "minimap shows the model texture in a 200 px circle (rect %s)" % str(view.map_rect().size))
	var top_left := view.map_rect().position + Vector2(pad, pad) + hud_slot_origin(ctx)
	K.check(fails, top_left.x >= 24.0 - 0.01, "the minimap circle keeps the 24 px safe margin (x %.1f)" % top_left.x)


func _check_rotation(ctx: FpContext) -> void:
	var p := ctx.player
	var mm := ctx.hud.minimap
	p.teleport(p.position, 90.0)
	await _frames(2)
	var c := mm.center_in_slot()
	var w := mm.world_to_slot(p.position + Vector3(-5, 0, 0))
	K.check(fails, absf(w.x - c.x) < 1.0 and w.y - c.y < 0.0, "facing west, the tile 5 west is drawn above the centre (d = %s)" % str(w - c))
	p.teleport(p.position, 0.0)
	await _frames(2)
	c = mm.center_in_slot()
	w = mm.world_to_slot(p.position + Vector3(0, 0, -5))
	K.check(fails, absf(w.x - c.x) < 1.0 and w.y - c.y < 0.0, "facing north, the tile 5 north is drawn above the centre (d = %s)" % str(w - c))
	var e := mm.world_to_slot(p.position + Vector3(5, 0, 0))
	K.check(fails, e.x > c.x + 1.0 and absf(e.y - c.y) < 1.0, "facing north, east is to the right")


func _check_street(ctx: FpContext) -> void:
	var road := _find(ctx, func(i: int) -> bool: return ctx.sim.kind[i] == D.ROAD and ctx.sim.terrain[i] != D.WATER)
	ctx.player.teleport(Vector3(D.tx(road), 0, D.ty(road)), 0.0)
	await _frames(1)
	var want := D.debrand(ctx.directory.street_at(ctx.player.position))
	K.check(fails, not want.is_empty() and ctx.hud.minimap.street_text() == want, "street label shows %s (%s)" % [want, ctx.hud.minimap.street_text()])


func _check_pings(ctx: FpContext) -> void:
	var n0 := ctx.hud.pings.size()
	ctx.bus.ping.emit(Vector3(16, 0, 14), "event:fire")
	var banner := ctx.hud.toasts.banner_text()
	var label := ctx.directory.place_label(D.idx(16, 14))
	var coords := RegEx.create_from_string("\\(\\s*-?\\d+\\s*,\\s*-?\\d+\\s*\\)")
	K.check(fails, ctx.hud.pings.size() == n0 + 1, "an event ping adds one marker")
	K.check(fails, not banner.is_empty() and banner.contains(label) and coords.search(banner) == null, "the banner names a place (%s)" % banner)


func _check_toasts(ctx: FpContext) -> void:
	var t := ctx.hud.toasts
	t.clear()
	for s: String in ["Alpha arrived", "Bravo left", "Bravo left", "Charlie paid", "Delta built"]:
		ctx.bus.toast.emit(s, "info")
	await _frames(2)
	var shown := t.texts()
	var bravo := 0
	for s in shown:
		if s.contains("Bravo"):
			bravo += 1
	K.check(fails, shown.size() <= 3 and shown.size() >= 2, "5 toasts in one frame show at most 3 (%s)" % str(shown))
	t.clear()
	ctx.bus.toast.emit("Same thing", "info")
	ctx.bus.toast.emit("Same thing", "info")
	shown = t.texts()
	K.check(fails, shown.size() == 1 and shown[0].contains("×2") and bravo <= 1, "identical consecutive toasts collapse (%s)" % str(shown))
	t.clear()


func _check_wheel_first(ctx: FpContext) -> void:
	var mm := ctx.hud.minimap
	K.check(fails, is_equal_approx(mm.ppt, 3.5), "minimap starts at 3.5 px per tile")
	_wheel(true)
	await _frames(1)
	K.check(fails, is_equal_approx(mm.ppt, 6.0), "first person: the wheel steps the minimap 3.5 -> 6 (%.1f)" % mm.ppt)
	_wheel(false)
	await _frames(1)
	K.check(fails, is_equal_approx(mm.ppt, 3.5), "first person: wheel down steps back to 3.5 (%.1f)" % mm.ppt)


func _check_agents(ctx: FpContext) -> void:
	var real: FpFeature = ctx.features.get("traffic", null)
	var stub: FpFeature = _script(STUB_TRAFFIC).new()
	ctx.features["traffic"] = stub
	var mm := ctx.hud.minimap
	mm._collect_markers()
	mm._collect_people()
	var draws0 := mm.marker_draws
	mm._overlay.queue_redraw()
	await _frames(2)
	K.check(fails, mm._agents.size() == 3 and mm._people.size() == 1 and int(stub.get("agent_calls")) >= 1, "E's agents_near and visible_near feed the minimap (%d agents, %d people)" % [mm._agents.size(), mm._people.size()])
	K.check(fails, mm.marker_draws > draws0, "the minimap draws the agents (%d draws)" % (mm.marker_draws - draws0))
	var car_dir: Vector2 = mm._agents[0]["dir"]
	K.check(fails, car_dir.is_equal_approx(Vector2(0, -1)), "a car blip points along its velocity (%s)" % str(car_dir))
	if real != null:
		ctx.features["traffic"] = real
	else:
		ctx.features.erase("traffic")
	stub.free()
	mm._collect_markers()
	mm._collect_people()


func _check_card(ctx: FpContext, client: GmiClient) -> void:
	var i := _find_c_lot(ctx)
	var calls0 := int(client.get("calls"))
	var card := ctx.hud.card
	ctx.bus.interact_requested.emit({"kind": "building", "id": str(i), "tile": i, "pos": Vector3(D.tx(i), 0.3, D.ty(i)), "dist": 0.1, "label": "Look", "data": {}})
	await _frames(1)
	var texts := card.texts()
	var biz := ctx.directory.business_name(i)
	var addr := ctx.directory.address(i)
	K.check(fails, card.is_open() and ctx.has_modal(&"card"), "a building interact opens the card and pushes &card")
	K.check(fails, not biz.is_empty() and " ".join(texts).contains(biz) and (addr.is_empty() or " ".join(texts).contains(addr)), "the card shows %s, %s" % [biz, addr])
	var asks: Array = []
	var cb := func(a: String, tile: int) -> void: asks.append([a, tile])
	ctx.bus.card_action.connect(cb)
	K.check(fails, card.ask_button != null, "the building card has an Ask button")
	if card.ask_button != null:
		card.ask_button.pressed.emit()
	await _frames(1)
	K.check(fails, asks == [["ask_here", i]] and not card.is_open() and not ctx.has_modal(&"card"), "Ask emits card_action(ask_here, %d) once and closes (%s)" % [i, str(asks)])
	ctx.bus.card_action.disconnect(cb)
	ctx.bus.interact_requested.emit({"kind": "vehicle", "id": "v1", "tile": -1, "pos": Vector3.ZERO, "label": "Priya Gupta, nurse", "data": {"driver_id": "r1", "state": "driving to work", "mood": 0.7}})
	await _frames(1)
	K.check(fails, card.is_open() and " ".join(card.texts()).contains("Priya Gupta") and " ".join(card.texts()).contains("Mood 7/10"), "a vehicle card shows the driver and mood (%s)" % " | ".join(card.texts()))
	_action("interact")
	await _frames(1)
	K.check(fails, not card.is_open() and not ctx.has_modal(&"card") and not ctx.is_modal(), "an interact press closes the card and pops &card")
	# E's driverless car: mood "" and no destination.
	ctx.bus.interact_requested.emit({"kind": "vehicle", "id": "v2", "tile": -1, "pos": Vector3.ZERO, "label": "a commuter", "data": {"driver_id": "", "state": "driving", "dest_label": "", "mood": ""}})
	await _frames(1)
	K.check(fails, card.is_open() and " ".join(card.texts()).contains("A commuter") and not " ".join(card.texts()).contains("Mood"), "a driverless vehicle card shows no mood (%s)" % " | ".join(card.texts()))
	card.close()
	ctx.bus.interact_requested.emit({"kind": "resident", "id": "r1", "tile": -1, "pos": Vector3.ZERO, "label": "Talk", "data": {}})
	await _frames(1)
	K.check(fails, not card.is_open(), "a resident target never opens B's card")
	K.check(fails, int(client.get("calls")) == calls0, "no LLM call from the card (%d)" % (int(client.get("calls")) - calls0))


func _check_map(ctx: FpContext, f: FpFeature) -> void:
	var map := ctx.hud.map
	_action("map_toggle")
	await _frames(1)
	K.check(fails, map.is_open() and ctx.has_modal(&"map"), "M opens the map and pushes &map")
	var pings: Array = []
	var cb := func(p: Vector3, r: String) -> void: pings.append([p, r])
	ctx.bus.ping.connect(cb)
	var target := map.world_to_screen(Vector2(ctx.player.position.x + 4.0, ctx.player.position.z - 3.0))
	map.click_at(target)
	var wp: Variant = ctx.hud.waypoint()
	K.check(fails, pings.size() == 1 and str(pings[0][1]) == "player" and wp != null and Vector2((wp as Vector3).x, (wp as Vector3).z).distance_to(Vector2(ctx.player.position.x + 4.0, ctx.player.position.z - 3.0)) < 0.05, "a map click emits ping(world, player) and stores the waypoint")
	ctx.bus.ping.disconnect(cb)
	var hw := map.hover_at(target)
	K.check(fails, hw.size() == 2 and hw[0] == "Waypoint" and hw[1].contains("click to clear"), "hovering the waypoint offers to clear it (%s)" % " / ".join(hw))
	var lot := _find_c_lot(ctx)
	var hl := map.hover_at(map.world_to_screen(Vector2(D.tx(lot), D.ty(lot))))
	var want := D.debrand(ctx.directory.place_label(lot))
	K.check(fails, map.hover_tile == lot and hl.size() == 2 and hl[0].to_lower() == want.to_lower() and hl[1].ends_with(" m away"), "hovering a lot names it (%s)" % " / ".join(hl))
	var saved: Dictionary = f.to_dict()
	K.check(fails, saved.has("waypoint") and (saved["waypoint"] as Array).size() == 2, "the waypoint is saved (%s)" % str(saved))
	map.zoom_at(Vector2(800, 450), 1.5)
	K.check(fails, map.ppt > 9.0, "zoom changes the scale (%.1f)" % map.ppt)
	_action("pause_menu")
	await _frames(1)
	K.check(fails, not map.is_open() and not ctx.is_modal(), "Esc closes the map and pops &map")
	ctx.hud.compass._collect()
	var has_wp := false
	for m: Dictionary in ctx.hud.compass.markers:
		has_wp = has_wp or str(m["kind"]) == "waypoint"
	K.check(fails, has_wp, "the compass shows the waypoint")
	# GPS: a waypoint on a far road tile routes along roads, corner to corner.
	var me := ctx.player.position
	var far := -1
	var best := 0.0
	for i in ctx.sim.active:
		if ctx.sim.kind[i] == D.ROAD:
			var dd := Vector2(D.tx(i) - me.x, D.ty(i) - me.z).length()
			if dd > best:
				best = dd
				far = i
	var t0 := Time.get_ticks_usec()
	f.call("set_waypoint", Vector3(D.tx(far), 0, D.ty(far)))
	var route_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var rt: PackedVector2Array = ctx.hud.route()
	var on_roads := rt.size() >= 3
	for k in range(1, rt.size() - 1):
		var tx := roundi(rt[k].x)
		var ty := roundi(rt[k].y)
		on_roads = on_roads and is_equal_approx(rt[k].x, tx) and is_equal_approx(rt[k].y, ty) and ctx.sim.kind[D.idx(tx, ty)] == D.ROAD
		if k >= 2:
			on_roads = on_roads and (is_equal_approx(rt[k].x, rt[k - 1].x) or is_equal_approx(rt[k].y, rt[k - 1].y))
	K.check(fails, on_roads and rt[0].distance_to(Vector2(me.x, me.z)) < 0.01 and rt[rt.size() - 1].distance_to(Vector2(D.tx(far), D.ty(far))) < 0.01, "the GPS route runs along roads to a waypoint %.0f tiles away (%d points, %.2f ms)" % [best, rt.size(), route_ms])
	f.call("clear_waypoint")
	K.check(fails, ctx.hud.route().is_empty(), "clearing the waypoint clears the route")
	f.from_dict({"waypoint": [3.0, 4.0]})
	K.check(fails, ctx.hud.waypoint() != null and is_equal_approx((ctx.hud.waypoint() as Vector3).x, 3.0), "from_dict restores the waypoint")
	f.from_dict({})
	K.check(fails, ctx.hud.waypoint() == null, "from_dict({}) clears the waypoint")


func _check_compass_labels() -> void:
	var C := preload("res://scripts/fp/ui/hud_compass.gd")
	var spans: Array[Vector2] = [Vector2(377.0, 417.0)]
	var x := C._label_x(444.0, 36.0, spans)
	K.check(fails, not is_nan(x) and x >= 417.0 + C.LABEL_GAP - 0.01 and x + 36.0 <= C.WIDTH + 0.01, "a compass distance at the strip's end slides clear of its neighbour (%.1f)" % x)
	K.check(fails, is_nan(C._label_x(400.0, 36.0, spans)), "a distance that cannot stay under its marker is left out")
	K.check(fails, is_equal_approx(C._label_x(200.0, 36.0, spans), 182.0), "a free distance is centred under its marker")


func _check_caption(ctx: FpContext) -> void:
	var cap := ctx.hud.caption
	var sim := ctx.sim
	var a := _find(ctx, func(i: int) -> bool: return sim.district[i] >= 0 and sim.terrain[i] != D.WATER)
	var da := sim.district[a] if a >= 0 else -1
	var b := _find(ctx, func(i: int) -> bool: return sim.district[i] >= 0 and sim.district[i] != da and sim.terrain[i] != D.WATER)
	K.check(fails, a >= 0 and b >= 0, "two districts to walk between")
	if a < 0 or b < 0:
		return
	var keep := ctx.player.position
	ctx.player.teleport(Vector3(D.tx(a), 0, D.ty(a)), 0.0)
	cap.arrive()
	cap._process(0.5)
	K.check(fails, cap.caption_text() == str(D.MAYORS[da]["district"]), "arriving shows the district caption (%s)" % cap.caption_text())
	cap._process(10.0)
	ctx.player.teleport(Vector3(D.tx(b), 0, D.ty(b)), 0.0)
	cap.check()
	cap._process(0.5)
	var db := sim.district[b]
	var sub := (cap.find_child("Mayor", true, false) as Label).text
	K.check(fails, cap.caption_text() == str(D.MAYORS[db]["district"]) and sub == "Mayor " + D.mayor_display(db) and not S.branded(sub), "entering another district captions it with its mayor (%s, %s)" % [cap.caption_text(), sub])
	cap._process(10.0)
	ctx.player.teleport(Vector3(D.tx(a), 0, D.ty(a)), 0.0)
	cap.check()
	cap._process(0.5)
	K.check(fails, cap.caption_text().is_empty() and cap.district == da, "walking back within the cooldown shows no caption again")
	ctx.player.teleport(keep, 0.0)
	cap.check()


func _check_reload(ctx: FpContext) -> void:
	var map := ctx.hud.map
	K.check(fails, map.open(), "the map opens")
	var i := _find_c_lot(ctx)
	ctx.bus.interact_requested.emit({"kind": "building", "id": str(i), "tile": i, "pos": Vector3(D.tx(i), 0.3, D.ty(i)), "label": "Look", "data": {}})
	await _frames(1)
	K.check(fails, map.is_open() and ctx.hud.card.is_open() and ctx.modal_count() == 2, "map and card open together")
	ctx.bus.world_ready.emit()
	await _frames(1)
	K.check(fails, not map.is_open() and not ctx.hud.card.is_open() and not ctx.is_modal(), "world_ready closes both and leaves nothing modal")


func _check_pause(ctx: FpContext) -> void:
	var main: Node3D = _script(STUB_MAIN).new()
	main.set("bus", ctx.bus)
	get_root().add_child(main)
	ctx.main = main
	var menu := ctx.hud.pause_menu
	ctx.mode.set_paused(true)
	await _frames(1)
	K.check(fails, menu.is_open() and ctx.modal_count() == 1 and ctx.has_modal(&"pause"), "set_paused(true) shows the menu; B pushes no modal of its own")
	menu.open_settings("Display")
	var slider: HSlider = menu.controls["fov"]
	var n0 := ctx.mode.settings_log.size()
	slider.value = 80.0
	var last: Dictionary = ctx.mode.settings_log.back() if ctx.mode.settings_log.size() > n0 else {}
	K.check(fails, ctx.mode.settings_log.size() == n0 + 1 and is_equal_approx(float(last.get("fov", 0.0)), 80.0), "a settings slider appends its patch to settings_log (%s)" % str(last))
	menu.open_settings("Camera")
	var view: Array = menu.controls["camera_mode"]
	(view[0] as Button).pressed.emit()
	K.check(fails, str(ctx.settings.get("camera_mode", "")) == "third", "the Camera group writes camera_mode")
	var dist: HSlider = menu.controls["tps_distance_m"]
	K.check(fails, is_equal_approx(dist.min_value, 1.6) and is_equal_approx(dist.max_value, 5.0), "camera distance spans 1.6-5.0 m")
	ctx.mode.apply_settings({"camera_mode": "first"})
	_action("pause_menu")
	await _frames(1)
	K.check(fails, menu.is_open() and not menu.settings_open() and ctx.mode.paused, "Esc leaves the settings page first")
	var toasts: Array = []
	var cb := func(t: String, _k: String) -> void: toasts.append(t)
	ctx.bus.toast.connect(cb)
	menu.button("Save").pressed.emit()
	K.check(fails, toasts.size() == 1 and int(main.get("saves")) == 1, "Save makes exactly one toast (%s)" % str(toasts))
	toasts.clear()
	menu.button("Load").pressed.emit()
	K.check(fails, toasts.size() == 1 and int(main.get("loads")) == 1, "Load makes exactly one toast (%s)" % str(toasts))
	ctx.bus.toast.disconnect(cb)
	await _frames(1)
	K.check(fails, not ctx.mode.paused and not menu.is_open() and not ctx.is_modal(), "a successful load resumes")
	ctx.mode.set_paused(true)
	await _frames(1)
	_action("pause_menu")
	await _frames(1)
	K.check(fails, not ctx.mode.paused and not menu.is_open() and not paused, "Esc on the menu resumes")
	ctx.main = null
	main.queue_free()


func _check_third_person() -> void:
	var ctx := K.make_ctx(get_root(), {"camera_mode": "third"})
	await _frames(1)
	var hud := ctx.hud
	var pr := hud.prompt
	var cam := ctx.player.camera
	cam.top_level = true
	var eye := ctx.player.position + Vector3(0, 0.3, 0)
	cam.global_transform = Transform3D(Basis(), eye)
	var tgt := {"kind": "resident", "id": "r1", "tile": -1, "pos": eye + Vector3(0.03, -0.02, -0.4), "dist": 0.4, "label": "Talk to Priya Gupta, nurse", "data": {}}
	ctx.bus.interact_target_changed.emit(tgt)
	pr._process(0.2)
	var want := cam.unproject_position(pr.anchor_of(tgt))
	var got := pr.prompt_center()
	var sz := hud.slot("center").size
	K.check(fails, sz.is_equal_approx(hud.get_viewport().get_visible_rect().size), "the center slot spans the visible rect (%s)" % str(sz))
	K.check(fails, pr.prompt_visible() and got.distance_to(want) < 2.0, "third person: the prompt sits over the target (%s vs %s)" % [str(got), str(want)])
	K.check(fails, not pr.crosshair_visible(), "third person: no crosshair")
	# Lift: a resident's anchor is 0.25 m over the head.
	K.check(fails, is_equal_approx(pr.anchor_of(tgt).y - (tgt["pos"] as Vector3).y, 0.25 * WS.M), "residents lift the anchor by 0.25 m")
	var behind := tgt.duplicate()
	behind["pos"] = eye + Vector3(0, 0, 0.4)
	ctx.bus.interact_target_changed.emit(behind)
	pr._process(0.2)
	K.check(fails, not pr.prompt_visible(), "third person: the prompt hides behind the camera")
	ctx.bus.interact_target_changed.emit(tgt)
	pr._process(0.2)
	K.check(fails, pr.prompt_visible(), "the prompt comes back in front")
	# The wheel is A's zoom in third person: the minimap keeps its scale.
	_wheel(true)
	await _frames(1)
	K.check(fails, is_equal_approx(hud.minimap.ppt, 3.5), "third person: the wheel leaves the minimap scale (%.1f)" % hud.minimap.ppt)
	ctx.mode.apply_settings({"camera_mode": "first"})
	pr._process(0.016)
	var centre := (sz * 0.5).round()
	got = pr.prompt_center()
	K.check(fails, pr.crosshair_visible() and absf(got.x - centre.x) < 2.0 and got.y > centre.y + 10.0, "first person: crosshair, prompt under the centre (%s vs %s)" % [str(got), str(centre)])
	_wheel(true)
	await _frames(1)
	K.check(fails, is_equal_approx(hud.minimap.ppt, 6.0), "first person: the wheel steps 3.5 -> 6 (%.1f)" % hud.minimap.ppt)
	ctx.push_modal(&"test")
	pr._process(0.2)
	K.check(fails, not pr.prompt_visible() and not pr.crosshair_visible(), "a modal hides the prompt and crosshair")
	ctx.pop_modal(&"test")


func _perf(ctx: FpContext, f: FpFeature) -> void:
	var m: MinimapModel = f.get("model")
	var t0 := Time.get_ticks_usec()
	m.full_repaint()
	var full_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var road := _find(ctx, func(i: int) -> bool: return ctx.sim.kind[i] == D.ROAD)
	t0 = Time.get_ticks_usec()
	for _k in range(20):
		m.repaint(PackedInt32Array([road]))
	var inc_ms := (Time.get_ticks_usec() - t0) / 20000.0
	var mm := ctx.hud.minimap
	t0 = Time.get_ticks_usec()
	for _k in range(20):
		mm._collect_markers()
		mm._collect_people()
	var mk_ms := (Time.get_ticks_usec() - t0) / 20000.0
	# Per-frame CPU of every always-on HUD widget at 60 fps (budget 1.0 ms in total).
	var hud := ctx.hud
	var n := 240
	t0 = Time.get_ticks_usec()
	for _k in range(n):
		hud._process(1.0 / 60.0)
		hud.chips._process(1.0 / 60.0)
		hud.compass._process(1.0 / 60.0)
		hud.toasts._process(1.0 / 60.0)
		hud.minimap._process(1.0 / 60.0)
		hud.prompt._process(1.0 / 60.0)
	var frame_ms := (Time.get_ticks_usec() - t0) / 1000.0 / n
	print("FP_HUD_TEST: perf full_repaint=%.2fms incremental=%.3fms markers=%.3fms hud_frame=%.3fms people=%d" % [full_ms, inc_ms, mk_ms, frame_ms, ctx.residents.people.size()])
	K.check(fails, full_ms < 30.0, "full repaint %.1f ms (budget 15 ms)" % full_ms)
	K.check(fails, frame_ms < 1.0, "HUD widgets cost %.3f ms per frame (budget 1.0 ms)" % frame_ms)


## Screen position of minimap_slot's origin at the 1600 x 900 base.
func hud_slot_origin(ctx: FpContext) -> Vector2:
	var r: Array = FpHud.SLOT_RECTS["minimap_slot"]
	return Vector2(float(r[4]), 0.0)


func _frames(n: int) -> void:
	for _k in range(n):
		await process_frame


func _action(a: String) -> void:
	var ev := InputEventAction.new()
	ev.action = a
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _wheel(up: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed = true
	ev.position = Vector2(4, 4)
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _script(src: String) -> GDScript:
	var gd := GDScript.new()
	gd.source_code = src
	gd.reload()
	return gd


func _find(ctx: FpContext, pred: Callable) -> int:
	for i in ctx.sim.active:
		if pred.call(i):
			return i
	return -1


func _find_c_lot(ctx: FpContext) -> int:
	return _find(ctx, func(i: int) -> bool: return ctx.sim.kind[i] == D.ZONE_C and ctx.sim.level[i] >= 1)


func _pixel(m: MinimapModel, i: int) -> Color:
	return m.image.get_pixel(i % D.W, i / D.W)


## A colour quantised to 8 bits, as the RGBA8 image stores it.
func _q(c: Color) -> Color:
	return Color8(c.r8, c.g8, c.b8, 255)


func _visible_text(n: Node) -> String:
	var parts := PackedStringArray()
	for c: Node in n.find_children("*", "Label", true, false):
		if (c as Control).is_visible_in_tree():
			parts.append((c as Label).text)
	return " | ".join(parts)
