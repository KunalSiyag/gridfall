extends SceneTree
## AI activity (integration feature "activity"). Every mayor turn, council ruling, Chaos Director
## pick, grid order and Gazette front page lands as a feed card: who decided, the model badge,
## where the answer came from, what and why, and where. A decision with a place raises a beacon and
## pings the map in the agent's colour without a toast. J cycles the feed, G routes to the newest
## decision with a place. On foot the mayors' turns are spread over the day. Modals hide the feed;
## save, load and teardown.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const W := preload("res://scripts/fp/activity/activity_words.gd")
const MT := preload("res://scripts/ai/mayor_turns.gd")
const DT := 1.0 / 60.0
## Brand names and system words that owned feed text must never show (badges are exempt).
const LEAK_RE := "(?i)(Argon|DeepSeek|Kimi|Qwen|Grok|GMI|gemini|MiniMax|latency|cache|heuristic)"

var fails: Array[String] = []
var decided: Array[int] = []


func _init() -> void:
	await process_frame
	var ctx := K.make_ctx(get_root(), {"grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	K.make_feature(ctx, "hud_widgets")
	var f: FpFeature = K.make_feature(ctx, "activity")
	K.check(fails, f != null and f.feature_id() == "activity", "the activity feature is registered")
	if f == null:
		K.finish(self, "FP_ACTIVITY_TEST", fails)
		return
	f.set_process(false)
	ctx.brain.mayor_decided.connect(func(mi: int, _e: Dictionary) -> void: decided.append(mi))
	_check_words()
	_check_setup(ctx, f)
	_check_turns(ctx, f)
	_check_mayor_card(ctx, f)
	_check_support(ctx, f)
	_check_branding(f)
	_check_modes(ctx, f)
	_check_route(ctx, f)
	_check_tags(ctx, f)
	_check_cover(ctx, f)
	_check_live_state(ctx, f)
	_check_save(ctx, f)
	_check_teardown(ctx, f)
	K.finish(self, "FP_ACTIVITY_TEST", fails)


func _check_words() -> void:
	var a := W.model_label("openai/gpt-6-luna")
	var b := W.model_label("deepseek-ai/DeepSeek-V4-Flash-0731")
	K.check(
		fails,
		a == "gpt-6-luna" and b == "DeepSeek-V4-Flash",
		"model ids as badges (%s, %s)" % [a, b]
	)
	var mm := W.mayor_model(1) == str(D.MAYORS[1]["name"]) and W.mayor_model(9).is_empty()
	K.check(fails, mm, "a mayor's badge is the model it runs on")
	var tags := [
		W.source_tag("live"),
		W.source_tag("cache"),
		W.source_tag("heuristic"),
		W.source_tag("heuristic", true),
		W.source_tag("cache", true),
	]
	var want := ["LIVE", "REPLAY", "OFFLINE", "FALLBACK", "FALLBACK"]
	K.check(fails, tags == want, "answers read LIVE, REPLAY, OFFLINE or FALLBACK (%s)" % str(tags))
	var applied := [
		{"action": {"type": "zone", "zone": "R", "x": 3, "y": 3, "w": 3, "h": 2}, "ok": true},
		{"action": {"type": "build", "building": "fire_station", "x": 4, "y": 4}, "ok": true},
		{"action": {"type": "road", "x": 1, "y": 1, "x2": 6, "y2": 1}, "ok": true},
		{"action": {"type": "road", "x": 1, "y": 1, "x2": 1}, "ok": false, "reason": "no money"},
	]
	var s := W.summarize(applied)
	var said := "Zoned 6 homes · Ordered a Fire Station · +1 more (1 refused)"
	K.check(fails, s == said, "a turn reads as plain words (%s)" % s)
	var held := W.summarize([]) == "Held off this turn"
	K.check(fails, held and W.first_refusal(applied) == "no money", "an empty turn holds off")
	var ages := [W.ago(10.0, 3), W.ago(250.0, 3), W.ago(7300.0, 3), W.ago(-1.0, 7)]
	K.check(fails, ages == ["now", "4 min", "2 h", "Day 7"], "card ages (%s)" % str(ages))
	var ne := W.direction(Vector3.ZERO, Vector3(5, 0, -5))
	var so := W.direction(Vector3.ZERO, Vector3(0, 0, 4))
	K.check(fails, ne == "NE" and so == "S", "compass directions, north is -Z (%s, %s)" % [ne, so])
	var tiles := [
		W.tile_of(Vector2i(3, 4)), W.tile_of("(5, 6)"), W.tile_of([7, 8]), W.tile_of(null)
	]
	var tiles_ok := tiles == [Vector2i(3, 4), Vector2i(5, 6), Vector2i(7, 8), D.NO_TILE]
	K.check(fails, tiles_ok, "focus tiles survive a JSON save (%s)" % str(tiles))
	var long := W.detail("DeepSeek-V4 says " + "very ".repeat(60) + "much")
	var clipped := long.length() <= W.DETAIL_CHARS and long.ends_with("…")
	K.check(fails, clipped and not long.contains("DeepSeek"), "free text is de-branded and clipped")
	var pol := W.politics({"proposal": "curfew", "votes": {"clean_air_act": "no", "curfew": "yes"}})
	var pol_want := "Proposed the Youth Curfew ordinance · Voted no on Clean Air Act"
	K.check(fails, pol == pol_want, "proposals and votes (%s)" % pol)


func _check_setup(ctx: FpContext, f: FpFeature) -> void:
	var feed: Control = f.get("feed")
	K.check(
		fails,
		feed != null and feed.get_parent() == ctx.hud.slot("center"),
		"the feed is on the HUD"
	)
	K.check(fails, ctx.brain.stagger_mayors, "on foot the mayors' turns are staggered")
	var st := f.self_test()
	K.check(fails, bool(st.get("ok", false)), "self_test ok (%s)" % str(st.get("detail", "")))
	var j := false
	var clash: Array[String] = []
	for a: StringName in InputMap.get_actions():
		for e: InputEvent in InputMap.action_get_events(a):
			if not (e is InputEventKey and (e as InputEventKey).physical_keycode == KEY_J):
				continue
			if a == &"ai_feed":
				j = true
			else:
				clash.append(str(a))
	K.check(fails, j and clash.is_empty(), "J is ai_feed's alone (others: %s)" % str(clash))


func _check_turns(ctx: FpContext, f: FpFeature) -> void:
	var o := MT.order(3)
	var sorted := o.duplicate()
	sorted.sort()
	K.check(
		fails, o[0] == 3 and sorted == [0, 1, 2, 3, 4], "turn order rotates daily (%s)" % str(o)
	)
	var spread := MT.at(0) > 0.0 and MT.at(1) > MT.at(0) and MT.at(4) < MT.SPAN
	K.check(fails, spread, "the turns are spread over the day")
	var brain := ctx.brain
	_next_day(ctx)
	var day := ctx.sim.day
	var order := MT.order(day)
	K.check(
		fails, brain.turns.due == order, "a new day queues five turns (%s)" % str(brain.turns.due)
	)
	var feed: Control = f.get("feed")
	f.call("_refresh")
	var line := str(feed.call("line_text"))
	var next_ok := line.begins_with("Next up: " + D.mayor_display(order[0]))
	K.check(fails, next_ok, "the feed says who goes next (%s)" % line)
	var n0 := decided.size()
	brain._process(0.0)
	K.check(fails, decided.size() == n0, "nobody decides at dawn")
	ctx.sim.step_tick()
	brain._process(0.0)
	var first_ok := decided.size() == n0 + 1 and decided[-1] == order[0]
	K.check(fails, first_ok, "the first mayor decides a quarter into the day")
	var items: Array = f.get("items")
	var newest: Dictionary = items[-1] if not items.is_empty() else {}
	var card_ok := str(newest.get("agent", "")) == str(order[0])
	K.check(fails, card_ok, "and lands in the feed (%s)" % str(newest.get("headline", "")))
	K.check(fails, brain.turns.due.size() == 4, "four turns still wait")
	_next_day(ctx)
	var all_in := decided.size() - n0 == 5 and decided.slice(n0) == order
	K.check(fails, all_in, "every mayor decides before the day ends (%s)" % str(decided.slice(n0)))
	brain.stagger_mayors = false
	brain.call("_day_gate")
	var n1 := decided.size()
	_next_day(ctx)
	var dawn := decided.size() - n1 == 5 and brain.turns.due.is_empty()
	K.check(fails, dawn, "without the stagger (orbit) all five decide at dawn")
	brain.stagger_mayors = true


func _check_mayor_card(ctx: FpContext, f: FpFeature) -> void:
	var feed: Control = f.get("feed")
	var beacons: Node3D = f.get("beacons")
	var mi := 2
	var t := _lot_tile(ctx)
	f.call("_on_mayor_thinking", mi)
	var line := str(feed.call("line_text"))
	var who_now := "%s is deciding…" % D.mayor_display(mi)
	K.check(fails, line == who_now, "the feed shows who is deciding (%s)" % line)
	ctx.hud.toasts.clear()
	ctx.hud.pings.clear()
	var acts := [
		{"action": {"type": "zone", "zone": "R", "x": t.x, "y": t.y, "w": 3, "h": 2}, "ok": true},
		{"action": {"type": "road", "x": 1, "y": 1, "x2": 3}, "ok": false, "reason": "no money"},
	]
	var entry := {
		"day": ctx.sim.day,
		"thought": "DeepSeek-V4 wants homes by the river.",
		"post": "",
		"actions": acts,
		"source": "live",
		"error": "",
		"focus": t,
		"proposal": "curfew",
		"votes": {"clean_air_act": "no"},
	}
	f.call("_on_mayor_decided", mi, entry)
	var card: Control = feed.call("open_card")
	var head := _text(card, "Headline")
	K.check(
		fails, head == "Zoned 6 homes (1 refused)", "the newest card says what they did (%s)" % head
	)
	var who := _text(card, "Who")
	var model := _badge(card, "Model")
	var named := who == D.mayor_display(mi) and model == str(D.MAYORS[mi]["name"])
	K.check(fails, named, "it names the mayor and their model (%s, %s)" % [who, model])
	K.check(fails, _badge(card, "Source") == "LIVE", "and that the answer came live")
	var detail := _text(card, "Detail")
	var why_ok := detail.contains("homes by the river") and not detail.contains("DeepSeek")
	K.check(fails, why_ok, "why, de-branded (%s)" % detail)
	var pol := _text(card, "Politics")
	K.check(fails, pol.begins_with("Proposed the Youth Curfew"), "and their politics (%s)" % pol)
	var where := _text(card, "Where")
	var routed := (card.find_child("Route", true, false) as Control).visible
	K.check(fails, not where.is_empty() and routed, "where, with the G hint (%s)" % where)
	var key := "mayor:%d" % mi
	var fresh := (
		bool(beacons.call("has_beacon", key)) and float(beacons.call("freshness", key)) > 0.9
	)
	K.check(fails, fresh, "a fresh beacon rises over the place")
	var bp: Vector3 = beacons.call("position_of", key)
	K.check(fails, Vector2(bp.x - t.x, bp.z - t.y).length() < 0.01, "at the focus tile")
	var reason := str(ctx.hud.pings[-1]["reason"]) if not ctx.hud.pings.is_empty() else ""
	K.check(fails, reason == "ai:%d" % mi, "it pings the minimap and compass (%s)" % reason)
	var tint := S.ping_color(reason).is_equal_approx(Color(str(D.MAYORS[mi]["color"])))
	K.check(fails, tint, "in the mayor's colour")
	var council := Color(str(D.SUPPORT_AGENTS["council"]["color"]))
	var others := S.ping_color("ai:council").is_equal_approx(council)
	K.check(
		fails, others and S.ping_color("event:fire") == S.RED, "agents in theirs, incidents red"
	)
	var quiet := ctx.hud.toasts.texts().is_empty() and ctx.hud.toasts.banner_text().is_empty()
	K.check(fails, quiet, "an AI ping raises no toast (the feed already says it)")
	line = str(feed.call("line_text"))
	K.check(fails, not line.contains("deciding"), "the deciding line clears (%s)" % line)
	ctx.hud.pings.clear()
	var held := {
		"day": ctx.sim.day,
		"thought": "",
		"post": "Patience.",
		"actions": [],
		"source": "heuristic",
		"error": "HTTP 503",
		"focus": D.NO_TILE,
	}
	f.call("_on_mayor_decided", 1, held)
	card = feed.call("open_card")
	var fb := (
		_badge(card, "Source") == "FALLBACK" and _text(card, "Headline") == "Held off this turn"
	)
	K.check(fails, fb, "a failed live call reads FALLBACK")
	var district := _text(card, "Where") == str(D.MAYORS[1]["district"])
	var no_hint := not (card.find_child("Route", true, false) as Control).visible
	K.check(fails, district and no_hint, "a turn without a place names the district, no G hint")
	K.check(fails, ctx.hud.pings.is_empty(), "and pings nothing")
	K.check(fails, _text(card, "Detail").contains("Patience."), "the post stands in for no thought")


func _check_support(ctx: FpContext, f: FpFeature) -> void:
	var feed: Control = f.get("feed")
	var day := ctx.sim.day
	ctx.hud.pings.clear()
	var ruling := {
		"enacted": ["curfew"],
		"repealed": ["clean_air_act"],
		"source": "cache",
		"day": day,
		"statement": "Qwen and Grok voted no.",
	}
	f.call("_on_council_ruled", ruling)
	var card: Control = feed.call("open_card")
	var speaker := _text(card, "Who") == "Council Speaker" and _badge(card, "Model") == "gpt-6-luna"
	K.check(
		fails, speaker, "the council card names the speaker and model (%s)" % _badge(card, "Model")
	)
	var head := _text(card, "Headline")
	var head_ok := head == "Passed Youth Curfew · Repealed Clean Air Act"
	K.check(fails, head_ok, "what the council did (%s)" % head)
	var hall := ctx.sim.kind.find(D.HALL)
	var it: Dictionary = (f.get("items") as Array)[-1]
	var at_hall := hall < 0 or (it["tile"] as Vector2i) == Vector2i(D.tx(hall), D.ty(hall))
	K.check(fails, at_hall and bool(it["placed"]), "the council sits at City Hall")
	var replay := _badge(card, "Source") == "REPLAY" and not _text(card, "Detail").contains("Qwen")
	K.check(fails, replay, "a replayed ruling, de-branded")
	var pinged := not ctx.hud.pings.is_empty() and str(ctx.hud.pings[-1]["reason"]) == "ai:council"
	K.check(fails, pinged, "the council pings City Hall")
	ctx.hud.pings.clear()
	var pick := {
		"trigger": true,
		"type": "fire",
		"x": 6,
		"y": 7,
		"reason": "Old wiring downtown.",
		"source": "heuristic",
		"day": day,
	}
	f.call("_on_chaos_decided", pick)
	card = feed.call("open_card")
	head = _text(card, "Headline")
	var chaos_ok := head == "Set off a building fire" and _badge(card, "Source") == "OFFLINE"
	K.check(fails, chaos_ok, "the Chaos Director's pick, from the offline planner (%s)" % head)
	var beacon := bool((f.get("beacons") as Node).call("has_beacon", "chaos"))
	K.check(fails, beacon and ctx.hud.pings.is_empty(), "a beacon, but the incident pings the map")
	f.call("_on_chaos_decided", {"trigger": false, "narration": "A calm day.", "source": "cache"})
	head = _text(feed.call("open_card"), "Headline")
	K.check(fails, head == "Kept the city calm", "a calm pick (%s)" % head)
	var order := {"priority": [3, 0, 1, 2, 4], "advice": "Build a plant.", "source": "heuristic"}
	f.call("_on_operator_decided", order)
	head = _text(feed.call("open_card"), "Headline")
	K.check(fails, head == "Power goes first to " + str(D.MAYORS[3]["district"]), "the grid order")
	var paper := {
		"headline": "Kimi-K3 opens the bridge", "editorial": "About time.", "source": "cache"
	}
	f.call("_on_news_published", paper)
	head = _text(feed.call("open_card"), "Headline")
	var gazette := head.begins_with("Front page: ") and not head.contains("Kimi")
	K.check(fails, gazette, "the Gazette's front page, de-branded (%s)" % head)
	var kept := int(feed.call("card_count")) == 4 and (f.get("items") as Array).size() == 12
	K.check(fails, kept, "the feed keeps four cards and the feature twelve decisions")


func _check_branding(f: FpFeature) -> void:
	var feed: Control = f.get("feed")
	var texts := S.owned_texts(feed)
	var re := RegEx.create_from_string(LEAK_RE)
	var bad := PackedStringArray()
	for t in texts:
		if re.search(t) != null:
			bad.append(t)
	var msg := "no brand or system words in %d feed texts %s" % [texts.size(), str(bad)]
	K.check(fails, texts.size() > 10 and bad.is_empty(), msg)
	var badges := 0
	for n in feed.find_children("*", "Label", true, false):
		if n.has_meta(S.BADGE_META) and not n.has_meta(S.OWNER_META):
			badges += 1
	K.check(fails, badges >= 8, "model and source tags are badges (%d)" % badges)


func _check_modes(ctx: FpContext, f: FpFeature) -> void:
	var feed: Control = f.get("feed")
	var tags: Control = f.get("tags")
	var full := str(feed.get("mode")) == "full" and _shown(feed) == 4
	K.check(fails, full, "full: four cards")
	f._unhandled_input(_key(KEY_J))
	var brief := str(feed.get("mode")) == "brief" and _shown(feed) == 1
	K.check(fails, brief, "J: brief, the newest card only")
	f._unhandled_input(_key(KEY_J))
	f._process(DT)
	var hidden := str(feed.get("mode")) == "hidden" and _shown(feed) == 0
	var bare := not tags.visible and str(feed.call("line_text")).is_empty()
	K.check(fails, hidden and bare, "J again: hidden, the header only")
	f._unhandled_input(_key(KEY_J))
	K.check(fails, str(feed.get("mode")) == "full", "J again: full")
	ctx.push_modal(&"test")
	f._unhandled_input(_key(KEY_J))
	K.check(fails, str(feed.get("mode")) == "full", "J does nothing under a modal")
	ctx.pop_modal(&"test")


func _check_route(ctx: FpContext, f: FpFeature) -> void:
	ctx.hud.clear_waypoint()
	var newest: Dictionary = f.call("newest_placed")
	K.check(fails, str(newest.get("key", "")) == "chaos", "the newest decision with a place")
	f._unhandled_input(_pad(JOY_BUTTON_Y))
	K.check(fails, ctx.hud.waypoint() == null, "the pad's Y does not route (it opens the map)")
	ctx.push_modal(&"test")
	f._unhandled_input(_key(KEY_G))
	K.check(fails, ctx.hud.waypoint() == null, "G does nothing under a modal")
	ctx.pop_modal(&"test")
	ctx.hud.toasts.clear()
	f._unhandled_input(_key(KEY_G))
	var wp: Variant = ctx.hud.waypoint()
	var t: Vector2i = newest["tile"]
	var near := (
		wp != null and Vector2((wp as Vector3).x - t.x, (wp as Vector3).z - t.y).length() < 1.6
	)
	K.check(fails, near, "G routes the GPS there (%s)" % str(wp))
	var said := ctx.hud.toasts.texts()
	var last := said[said.size() - 1] if not said.is_empty() else ""
	K.check(
		fails, last.begins_with("Route set: Set off a building fire"), "and says so (%s)" % last
	)
	ctx.hud.clear_waypoint()


func _check_tags(ctx: FpContext, f: FpFeature) -> void:
	var beacons: Node3D = f.get("beacons")
	var tags: Control = f.get("tags")
	var key := "mayor:2"
	var at: Vector3 = beacons.call("position_of", key)
	K.check(fails, _stand_facing(ctx, at), "fixture: a road a few tiles from the beacon")
	f._process(DT)
	var shown: Array = tags.call("shown")
	K.check(
		fails, shown.has(key), "a tag names the decision over a beacon in view (%s)" % str(shown)
	)
	var far := {"key": "far", "pos": at, "who": "x", "what": "y", "color": Color.WHITE}
	tags.call("show_tags", [far], ctx.player.camera, at + Vector3(0.0, 0.0, 40.0))
	K.check(fails, (tags.call("shown") as Array).is_empty(), "no tag from 40 tiles away")
	var cam: Camera3D = ctx.player.camera
	var me := ctx.player.position
	var ahead := -cam.global_basis.z
	ahead = Vector3(ahead.x, 0.0, ahead.z).normalized()
	var close := {
		"key": "close", "pos": me + ahead * 0.6, "who": "x", "what": "y", "color": Color.WHITE
	}
	tags.call("show_tags", [close], cam, me)
	K.check(
		fails,
		(tags.call("shown") as Array) == ["close"],
		"a beacon 12 m ahead keeps its tag on screen, low enough to read"
	)
	var everywhere: Array[Rect2] = [Rect2(-1.0e5, -1.0e5, 2.0e5, 2.0e5)]
	tags.call("show_tags", [close], cam, me, everywhere)
	K.check(
		fails,
		(tags.call("shown") as Array).is_empty(),
		"a tag that would cover a HUD area is left out, not pushed to the edge"
	)
	var clear: Array = f.call("_keep_clear")
	var feed_rect: Rect2 = (f.get("feed") as Control).call("column_rect")
	K.check(
		fails, clear.has(feed_rect) and clear.size() == 4, "tags keep clear of the feed and HUD"
	)


func _check_cover(ctx: FpContext, f: FpFeature) -> void:
	var feed: Control = f.get("feed")
	var beacons: Node3D = f.get("beacons")
	ctx.push_modal(&"pause")
	K.check(fails, not feed.visible, "the pause menu hides the feed at once (it stops _process)")
	f._process(DT)
	K.check(fails, not feed.visible, "a menu or card hides the feed")
	ctx.pop_modal(&"pause")
	K.check(fails, feed.visible, "and closing it brings the feed back")
	ctx.push_modal(&"chat")
	f._process(DT)
	var tags: Control = f.get("tags")
	K.check(fails, feed.visible, "the chat input leaves it up")
	K.check(fails, not tags.visible, "the open chat drawer hides the beacon tags")
	ctx.pop_modal(&"chat")
	ctx.player.set_photo_mode(true)
	f._process(DT)
	K.check(fails, not beacons.visible, "photo mode hides the beacons")
	ctx.player.set_photo_mode(false)
	f._process(DT)
	K.check(fails, beacons.visible and feed.visible, "and they come back")


func _check_live_state(ctx: FpContext, f: FpFeature) -> void:
	var feed: Control = f.get("feed")
	var c := ctx.client
	f.call("_refresh")
	K.check(fails, str(feed.call("state")) == "offline", "offline play says Offline")
	c.live_enabled = true
	f.call("_refresh")
	K.check(fails, str(feed.call("state")) == "live", "live calls say Live")
	for _k in range(6):
		c.live_outcomes.append(false)
	f.call("_refresh")
	var down := str(feed.call("state"))
	K.check(fails, down == "down", "failing live calls say Reconnecting (%s)" % down)
	c.live_outcomes.clear()
	c.live_enabled = false
	f.call("_refresh")


func _check_save(ctx: FpContext, f: FpFeature) -> void:
	var feed: Control = f.get("feed")
	var beacons: Node3D = f.get("beacons")
	feed.call("set_mode", "brief")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(f.to_dict()))
	var n := (f.get("items") as Array).size()
	var heads: PackedStringArray = feed.call("headlines")
	((saved["items"] as Array)[-1] as Dictionary)["detail"] = "Grok-4.5 was here"
	ctx.hud.pings.clear()
	f.from_dict(saved)
	var items: Array = f.get("items")
	var back := items.size() == n and str(feed.get("mode")) == "brief"
	K.check(fails, back, "a load restores %d decisions and the feed mode" % n)
	K.check(fails, feed.call("headlines") == heads, "the same cards come back (%s)" % str(heads))
	var lit := (
		bool(beacons.call("has_beacon", "mayor:2")) and bool(beacons.call("has_beacon", "chaos"))
	)
	K.check(fails, lit and ctx.hud.pings.is_empty(), "and the beacons, without new pings")
	K.check(
		fails, not str(items[-1]["detail"]).contains("Grok"), "saved text is de-branded on load"
	)
	var ago := _text(feed.call("open_card"), "Ago")
	K.check(fails, ago.begins_with("Day "), "restored cards date by day (%s)" % ago)
	var tile: Vector2i = (f.call("newest_placed") as Dictionary).get("tile", D.NO_TILE)
	K.check(fails, tile == Vector2i(6, 7), "places survive the save (%s)" % str(tile))
	feed.call("set_mode", "full")
	var brain := ctx.brain
	brain.turns.start(ctx.sim.day, true)
	brain.turns.take_due(1.0, true)
	var due := brain.turns.due.duplicate()
	brain.from_dict(JSON.parse_string(JSON.stringify(brain.to_dict())))
	var kept := brain.turns.due == due and brain.turns.day == ctx.sim.day
	K.check(fails, kept, "the brain's save keeps the waiting turns (%s)" % str(brain.turns.due))
	brain.turns.clear()
	var mt := MT.new()
	mt.from_dict({"due": [1, 1, 7, -2, "x", 3.0], "day": 4})
	var clean := mt.due == [1, 3] and mt.day == 4
	K.check(fails, clean, "a saved queue drops unknown and repeated mayors (%s)" % str(mt.due))
	f.from_dict({})
	var empty := (f.get("items") as Array).is_empty() and int(feed.call("card_count")) == 0
	K.check(fails, empty and (beacons.call("keys") as Array).is_empty(), "an empty save clears it")
	ctx.hud.toasts.clear()
	K.check(fails, f.call("route_to_newest") == false, "G without a decision on the map")
	var told := ctx.hud.toasts.texts()
	K.check(
		fails, told.size() == 1 and told[0].begins_with("No AI decision"), "says so (%s)" % told
	)
	K.check(fails, f.to_dict().is_empty(), "and there is nothing to save")


func _check_teardown(ctx: FpContext, f: FpFeature) -> void:
	f.teardown()
	var gone := f.get("feed") == null and f.get("beacons") == null and f.get("tags") == null
	K.check(
		fails, gone and not ctx.brain.stagger_mayors, "teardown removes it and ends the stagger"
	)
	var linked := ctx.brain.mayor_decided.is_connected(Callable(f, "_on_mayor_decided"))
	K.check(fails, not linked, "and lets go of the brain's signals")


# ------------------------------------------------------------------ helpers


## Steps the sim to the start of the next day.
func _next_day(ctx: FpContext) -> void:
	var d := ctx.sim.day
	var guard := 0
	while ctx.sim.day == d and guard < 4 * D.GROWTH_TICKS_PER_DAY:
		ctx.sim.step_tick()
		guard += 1


## A built home's tile in the grown city.
func _lot_tile(ctx: FpContext) -> Vector2i:
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] == D.ZONE_R:
			return Vector2i(D.tx(i), D.ty(i))
	return Vector2i(4, 7)


## Puts the hero on a road 4 to 12 tiles from at, facing it. False when there is no such road.
func _stand_facing(ctx: FpContext, at: Vector3) -> bool:
	var best := -1
	var best_gap := INF
	for i: int in range(ctx.sim.kind.size()):
		if ctx.sim.kind[i] != D.ROAD:
			continue
		var d := Vector2(D.tx(i) - at.x, D.ty(i) - at.z).length()
		if d >= 4.0 and d <= 12.0 and absf(d - 6.0) < best_gap:
			best = i
			best_gap = absf(d - 6.0)
	if best < 0:
		return false
	var pos := Vector3(D.tx(best), 0.0, D.ty(best))
	var dir := Vector2(at.x - pos.x, at.z - pos.z).normalized()
	ctx.player.teleport(pos, rad_to_deg(atan2(-dir.x, -dir.y)))
	for _k in range(40):
		ctx.player.update_view(DT)
	return true


## Cards the feed shows now.
func _shown(feed: Control) -> int:
	return (feed.call("headlines") as PackedStringArray).size()


func _text(root: Node, n: String) -> String:
	if root == null:
		return ""
	var l := root.find_child(n, true, false) as Label
	return l.text if l != null else ""


## The text of the badge named n under root, "" when it is missing or not a badge.
func _badge(root: Node, n: String) -> String:
	if root == null:
		return ""
	var p := root.find_child(n, true, false)
	if p == null or p.get_child_count() == 0:
		return ""
	var l := p.get_child(0) as Label
	return l.text if l != null and l.has_meta(S.BADGE_META) else ""


func _key(k: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = k
	e.pressed = true
	return e


func _pad(button: JoyButton) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.pressed = true
	return e
