extends FpFeature
## AI activity (integration feature "activity"): the city's AI decisions, visible from the street.
## Every mayor's turn, council ruling, Chaos Director pick, grid order and Gazette front page lands
## as a card in the feed (top right) that names who decided and the model they run on, whether
## the answer came live, from a replay, a fallback or the offline planner, what they did and why,
## and where. A decision with a place also raises a light beacon there (tagged when the hero is
## near) and pings the compass and minimap in the agent's colour. In street mode the mayors take
## their turns spread over the day (CityBrain.stagger_mayors), so decisions keep landing while you
## walk. J cycles the feed (full, brief, hidden); G routes the GPS to the newest decision with a
## place.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const W := preload("res://scripts/fp/activity/activity_words.gd")
const FEED := preload("res://scripts/fp/activity/activity_feed.gd")
const BEACONS := preload("res://scripts/fp/activity/activity_beacons.gd")
const TAGS := preload("res://scripts/fp/activity/activity_tags.gd")
## Where the council sits when no City Hall tile is found (CitySim.new_city builds it here).
const CITY_HALL := Vector2i(15, 14)
## Decisions kept for the save; the feed shows the newest FEED.MAX_CARDS.
const KEEP := 12
const REFRESH := 0.25
## Within this many tiles the place line reads "here" instead of a distance.
const HERE := 0.75
## Height of the chat ticker strip at the bottom of chat_slot (the last lines while it is closed).
const TICKER_H := 240.0
const SAVED_TEXT := [
	"key", "agent", "who", "model", "source", "headline", "short", "detail", "extra"
]

var feed: FEED
var beacons: BEACONS
var tags: TAGS
## Oldest first: {"key" ("mayor:<mi>" or the support role), "agent" ("<mi>" or the role), "who",
## "model", "source" (live|cache|heuristic), "failed" (a live call was tried and failed),
## "headline", "short" (its first phrase), "detail" (why), "extra" (votes or a refusal),
## "color": Color, "tile": Vector2i (D.NO_TILE without a place), "placed": bool, "day",
## "clock" (feature seconds when it landed; -1 once restored from a save)}.
var items: Array[Dictionary] = []
var _clock: float = 0.0
## Mayors waiting on their model right now, in the order they started.
var _thinking: Array[int] = []
var _links: Array[Array] = []
var _stagger_was: bool = false
var _t: float = 0.0


func feature_id() -> String:
	return "activity"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	if ctx.hud != null:
		var center := ctx.hud.slot("center")
		tags = TAGS.new()
		tags.setup()
		center.add_child(tags)
		center.move_child(tags, 0)
		feed = FEED.new()
		feed.setup()
		center.add_child(feed)
	beacons = BEACONS.new()
	beacons.name = "Beacons"
	add_child(beacons)
	if ctx.brain != null:
		_stagger_was = ctx.brain.stagger_mayors
		ctx.brain.stagger_mayors = true
		_link(ctx.brain.mayor_thinking, _on_mayor_thinking)
		_link(ctx.brain.mayor_decided, _on_mayor_decided)
		_link(ctx.brain.council_ruled, _on_council_ruled)
		_link(ctx.brain.chaos_decided, _on_chaos_decided)
		_link(ctx.brain.operator_decided, _on_operator_decided)
		_link(ctx.brain.news_published, _on_news_published)
	if ctx.bus != null:
		_link(ctx.bus.modal_changed, _sync_visibility)
	_refresh()


func teardown() -> void:
	for l: Array in _links:
		var sig: Signal = l[0]
		var src := sig.get_object()
		if src != null and is_instance_valid(src) and sig.is_connected(l[1]):
			sig.disconnect(l[1])
	_links.clear()
	if ctx != null and ctx.brain != null and is_instance_valid(ctx.brain):
		ctx.brain.stagger_mayors = _stagger_was
	for n: Node in [feed, tags, beacons]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	feed = null
	tags = null
	beacons = null


func to_dict() -> Dictionary:
	var mode := feed.mode if feed != null else "full"
	if items.is_empty() and mode == "full":
		return {}
	var out: Array = []
	for it: Dictionary in items:
		var e := it.duplicate()
		var t: Vector2i = it["tile"]
		e["tile"] = [t.x, t.y]
		e["color"] = (it["color"] as Color).to_html(false)
		e.erase("clock")
		out.append(e)
	return {"items": out, "mode": mode}


func from_dict(d: Dictionary) -> void:
	items.clear()
	_thinking.clear()
	if feed != null:
		feed.clear()
		feed.set_mode(str(d.get("mode", "full")))
	if beacons != null:
		beacons.clear()
	var saved: Variant = d.get("items", [])
	if typeof(saved) == TYPE_ARRAY:
		for v: Variant in (saved as Array).slice(-KEEP):
			if typeof(v) == TYPE_DICTIONARY:
				_add(_restored(v as Dictionary), false)
	_refresh()


func self_test() -> Dictionary:
	if feed == null or beacons == null:
		return {"ok": false, "detail": "activity feed or beacons missing"}
	var staggered := ctx.brain != null and ctx.brain.stagger_mayors
	var detail := "%d decisions, staggered turns %s" % [items.size(), "on" if staggered else "off"]
	return {"ok": staggered or ctx.brain == null, "detail": detail}


# ------------------------------------------------------------------ player actions


## J: full -> brief -> hidden -> full. Returns the new mode ("" without a HUD).
func cycle_feed() -> String:
	if feed == null:
		return ""
	var m := feed.cycle_mode()
	_refresh()
	Analytics.track("ai_feed_mode", {"mode": m})
	return m


## G: routes the GPS to the newest decision with a place. False when there is none or no map.
func route_to_newest() -> bool:
	var it := newest_placed()
	if it.is_empty() or ctx.hud == null:
		_toast("No AI decision has a place on the map yet.", "info")
		return false
	var t: Vector2i = it["tile"]
	ctx.hud.set_waypoint(_goal(t))
	if ctx.hud.waypoint() == null:
		return false
	_toast("Route set: %s, %s" % [str(it["short"]), _place_name(t)], "info")
	Analytics.track("ai_route", {"agent": str(it["agent"])})
	return true


## The newest decision with a place, or {}.
func newest_placed() -> Dictionary:
	for k in range(items.size() - 1, -1, -1):
		if bool(items[k]["placed"]):
			return items[k]
	return {}


## The open card's place line: "Maple Street · 240 m NE", or the mayor's district ("Citywide"
## for the support agents) for a decision without a place.
func where_of(it: Dictionary) -> String:
	if not bool(it.get("placed", false)):
		var agent := str(it.get("agent", ""))
		if agent.is_valid_int() and int(agent) >= 0 and int(agent) < D.MAYORS.size():
			return str(D.MAYORS[int(agent)]["district"])
		return "Citywide"
	var t: Vector2i = it["tile"]
	var me := ctx.player_position()
	var at := Vector3(t.x, 0.0, t.y)
	var d := Vector2(at.x - me.x, at.z - me.z).length()
	if d < HERE:
		return "%s · here" % _place_name(t)
	return "%s · %s %s" % [_place_name(t), S.distance(d), W.direction(me, at)]


func _unhandled_input(event: InputEvent) -> void:
	if ctx == null or event.is_echo() or ctx.is_modal():
		return
	if event.is_action_pressed("ai_feed"):
		cycle_feed()
	elif event.is_action_pressed("site_waypoint") and not (event is InputEventJoypadButton):
		# The pad's Y also opens the map on foot; only the G key routes.
		route_to_newest()
	else:
		return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_clock += delta
	_t -= delta
	if _t <= 0.0:
		_refresh()
	_sync_visibility()


## The feed hides under menus and cards but not the chat input, the tags under both, and the
## beacons in photo mode. Also runs on bus.modal_changed: the pause menu stops _process.
func _sync_visibility(_modal := false) -> void:
	var covered := _covered()
	if feed != null:
		feed.visible = not covered
	if beacons != null:
		beacons.visible = ctx.player == null or not ctx.player.photo_mode
	_update_tags(covered)


# ------------------------------------------------------------------ brain signals


func _on_mayor_thinking(mi: int) -> void:
	if not _thinking.has(mi):
		_thinking.append(mi)
	_refresh_line()


func _on_mayor_decided(mi: int, entry: Dictionary) -> void:
	_thinking.erase(mi)
	if mi < 0 or mi >= D.MAYORS.size():
		return
	var col := Color(str(D.MAYORS[mi]["color"]))
	var it := _item("mayor:%d" % mi, str(mi), D.mayor_display(mi), W.mayor_model(mi), col, entry)
	var applied: Array = (
		entry.get("actions", []) if typeof(entry.get("actions")) == TYPE_ARRAY else []
	)
	it["failed"] = not str(entry.get("error", "")).is_empty()
	it["headline"] = W.summarize(applied)
	var why := str(entry.get("thought", ""))
	it["detail"] = W.detail(why if not why.strip_edges().is_empty() else str(entry.get("post", "")))
	var extra := W.politics(entry)
	var refusal := W.first_refusal(applied)
	if extra.is_empty() and not refusal.is_empty():
		extra = W.detail("Refused: " + refusal)
	it["extra"] = extra
	_place(it, W.tile_of(entry.get("focus", D.NO_TILE)))
	_add(it)


func _on_council_ruled(r: Dictionary) -> void:
	var it := _agent_item("council", r)
	it["headline"] = W.council_words(r)
	it["detail"] = W.detail(str(r.get("statement", "")))
	_place(it, _city_hall())
	_add(it)


func _on_chaos_decided(d: Dictionary) -> void:
	var it := _agent_item("chaos", d)
	it["headline"] = W.chaos_words(d)
	var why := str(d.get("reason", ""))
	it["detail"] = W.detail(
		why if not why.strip_edges().is_empty() else str(d.get("narration", ""))
	)
	if bool(d.get("trigger", false)) and d.has("x"):
		_place(it, Vector2i(int(d["x"]), int(d.get("y", 0))))
	# The disaster pings the map itself (event:<type>); a second marker would only clutter it.
	_add(it, true, false)


func _on_operator_decided(d: Dictionary) -> void:
	var it := _agent_item("operator", d)
	it["headline"] = W.operator_words(d)
	var why := str(d.get("note", ""))
	it["detail"] = W.detail(why if not why.strip_edges().is_empty() else str(d.get("advice", "")))
	_add(it)


func _on_news_published(p: Dictionary) -> void:
	var it := _agent_item("news", p)
	it["headline"] = "Front page: " + W.detail(str(p.get("headline", "")))
	it["detail"] = W.detail(str(p.get("editorial", "")))
	_add(it)


# ------------------------------------------------------------------ items


func _item(
	key: String, agent: String, who: String, model: String, col: Color, d: Dictionary
) -> Dictionary:
	var day := int(d.get("day", ctx.sim.day if ctx.sim != null else 0))
	return {
		"key": key,
		"agent": agent,
		"who": who,
		"model": model,
		"color": col,
		"source": str(d.get("source", "")),
		"failed": false,
		"headline": "",
		"short": "",
		"detail": "",
		"extra": "",
		"tile": D.NO_TILE,
		"placed": false,
		"day": day,
		"clock": _clock,
	}


func _agent_item(role: String, d: Dictionary) -> Dictionary:
	var a: Dictionary = D.SUPPORT_AGENTS[role]
	var col := Color(str(a["color"]))
	return _item(role, role, str(a["name"]), W.model_label(str(a["model"])), col, d)


func _place(it: Dictionary, t: Vector2i) -> void:
	var ok := t != D.NO_TILE and D.in_bounds(t.x, t.y)
	it["tile"] = t if ok else D.NO_TILE
	it["placed"] = ok


## Adds a decision: the feed card, the beacon over its place and (fresh, ping) a map ping.
func _add(it: Dictionary, fresh: bool = true, ping: bool = true) -> void:
	it["short"] = str(it["headline"]).get_slice(" · ", 0).get_slice(" (", 0)
	items.append(it)
	while items.size() > KEEP:
		items.pop_front()
	if feed != null:
		feed.add_item(it, fresh)
	if bool(it["placed"]):
		var pos := _ground(it["tile"])
		if beacons != null:
			beacons.place(str(it["key"]), pos, it["color"], fresh)
		if fresh and ping and ctx.bus != null:
			ctx.bus.ping.emit(Vector3(pos.x, 0.0, pos.z), "ai:" + str(it["agent"]))
	_refresh()


## A saved item back, its text de-branded again (saves are files anyone can edit).
func _restored(e: Dictionary) -> Dictionary:
	var it := {}
	for k: String in SAVED_TEXT:
		it[k] = str(e.get(k, ""))
	for k: String in ["who", "headline", "short", "detail", "extra"]:
		it[k] = D.debrand(str(it[k]))
	it["failed"] = bool(e.get("failed", false))
	it["day"] = int(e.get("day", 0))
	it["color"] = Color.from_string(str(e.get("color", "")), S.ACCENT)
	it["clock"] = -1.0
	_place(it, W.tile_of(e.get("tile", null)))
	return it


# ------------------------------------------------------------------ view


func _refresh() -> void:
	_t = REFRESH
	if feed == null:
		return
	feed.set_state(_live_state())
	_refresh_line()
	feed.refresh(where_of, _clock)


## "live", "down" (live calls are failing, fallbacks answer) or "offline".
func _live_state() -> String:
	var c := ctx.client
	if c == null or not c.live_enabled:
		return "offline"
	if c.breaker_state() != "closed" or c.live_failure_ratio() > 0.5:
		return "down"
	return "live"


func _refresh_line() -> void:
	if feed == null:
		return
	if _thinking.is_empty():
		feed.set_line(_next_text(), false)
		return
	var first := D.mayor_display(_thinking[0])
	var n := _thinking.size()
	var t := (
		"%s is deciding…" % first if n == 1 else "%s and %d more are deciding…" % [first, n - 1]
	)
	feed.set_line(t, true)


## "Next up: Rosa Quintero in 3 min" for the next staggered mayor turn today, or "".
func _next_text() -> String:
	if ctx.brain == null or ctx.sim == null or not ctx.brain.stagger_mayors:
		return ""
	var nt := ctx.brain.turns.next_turn()
	if nt.is_empty():
		return ""
	var who := D.mayor_display(int(nt["mi"]))
	if ctx.sim.speed <= 0:
		return "Next up: %s" % who
	var left := (float(nt["at"]) - ctx.sim.day_progress()) * ctx.sim.day_seconds
	left /= float(ctx.sim.speed)
	if left < 60.0:
		return "Next up: %s, any moment" % who
	return "Next up: %s in %d min" % [who, roundi(left / 60.0)]


## True while a modal covers the street (pause, map, overview, a card, a talk); the chat input
## sits on the other side of the screen and leaves the feed up.
func _covered() -> bool:
	if not ctx.is_modal():
		return false
	return not (ctx.modal_count() == 1 and ctx.has_modal(&"chat"))


## Tags over the beacons near the hero: each beacon shows its newest decision with a place. The
## open chat drawer would sit under them, so they wait while the player types.
func _update_tags(covered: bool) -> void:
	if tags == null:
		return
	var typing := ctx.has_modal(&"chat")
	tags.visible = not covered and not typing and feed != null and feed.mode != "hidden"
	if not tags.visible or beacons == null or ctx.player == null:
		return
	var entries: Array = []
	var seen := {}
	for k in range(items.size() - 1, -1, -1):
		var it: Dictionary = items[k]
		var key := str(it["key"])
		if seen.has(key) or not bool(it["placed"]) or not beacons.has_beacon(key):
			continue
		seen[key] = true
		var e := {"key": key, "pos": beacons.position_of(key), "who": it["who"]}
		e["what"] = it["short"]
		e["color"] = it["color"]
		entries.append(e)
	tags.show_tags(entries, ctx.player.camera, ctx.player.position, _keep_clear())


## Screen areas the tags stay out of, in HUD coordinates: the band under the top bar and compass
## (down to where the feed starts), the feed, the minimap and the chat ticker above it.
func _keep_clear() -> Array[Rect2]:
	var out: Array[Rect2] = []
	if feed != null and feed.visible:
		out.append(feed.column_rect())
	if ctx.hud == null:
		return out
	var screen := ctx.hud.slot("center").get_global_rect()
	out.append(Rect2(screen.position, Vector2(screen.size.x, FEED.TOP)))
	out.append(ctx.hud.slot("minimap_slot").get_global_rect())
	var chat := ctx.hud.slot("chat_slot").get_global_rect()
	out.append(Rect2(chat.position.x, chat.end.y - TICKER_H, chat.size.x, TICKER_H))
	return out


# ------------------------------------------------------------------ places


## City Hall's tile, where the council sits.
func _city_hall() -> Vector2i:
	if ctx.sim != null:
		var i := ctx.sim.kind.find(D.HALL)
		if i >= 0:
			return Vector2i(D.tx(i), D.ty(i))
	return CITY_HALL


## A beacon's foot on tile t: the walkable surface there, street level over water.
func _ground(t: Vector2i) -> Vector3:
	var p := Vector3(t.x, WS.GROUND_Y, t.y)
	if ctx.collision != null:
		var g := ctx.collision.ground_height(p)
		if not is_nan(g):
			p.y = g
	return p


## Where the GPS should lead for tile t: its frontage road (a lot's centre is inside the
## building), else the tile itself.
func _goal(t: Vector2i) -> Vector3:
	if ctx.directory != null and D.in_bounds(t.x, t.y):
		var r := ctx.directory.frontage(D.idx(t.x, t.y))
		if r >= 0:
			return Vector3(D.tx(r), 0.0, D.ty(r))
	return Vector3(t.x, 0.0, t.y)


func _place_name(t: Vector2i) -> String:
	if ctx.directory == null or not D.in_bounds(t.x, t.y):
		return "the frontier"
	var s := D.debrand(ctx.directory.place_label(D.idx(t.x, t.y)))
	return s if not s.is_empty() else "the frontier"


func _toast(t: String, kind: String) -> void:
	if ctx.bus != null:
		ctx.bus.toast.emit(t, kind)


func _link(sig: Signal, c: Callable) -> void:
	if not sig.is_connected(c):
		sig.connect(c)
	_links.append([sig, c])
