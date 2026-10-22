extends FpFeature
## Global chat and face-to-face conversations (slice C). Normalises every city source (residents,
## mayors, the Gazette, the council, incidents, openings, arrivals, deals, people hit in the
## street) into the ChatFeed drip queue, runs ChatterMinds rounds about real events once a
## minute, answers the player's chat lines, and opens the talk dialogue on talk_requested. Owns
## the chat panel (chat_slot) and the talk card (overlay). Budgets (D12) are enforced here on the
## feed clock: one round per 60 s unpaused, one player-reply call per coalesced burst (6 per
## minute), one talk call per line and one inspect_tile per 20 s. While the player is being
## answered the drip holds everyday lines and the panel shows who is typing; a status card says
## when live replies fail or come back. While nobody lives in the city yet, the rival mayors argue
## in the chat once a minute and answer the player (live only); a player line nobody can answer
## gets a status card saying the mayors are busy.

const D := preload("res://scripts/sim/sim_defs.gd")
const T := preload("res://scripts/fp/chat/chat_text.gd")
const PANEL := preload("res://scripts/fp/ui/chat_panel.gd")
const TALK := preload("res://scripts/fp/chat/talk_dialog.gd")
const STREET := preload("res://scripts/fp/chat/street_lines.gd")

const ROUND_MS := 60000
const PLAYER_DEBOUNCE_MS := 3000
const PLAYER_COALESCE_MS := 10000
const PLAYER_CALLS_PER_MIN := 6
const REPLY_FIRST_MS := 600
const REPLY_GAP_MS := 1100
const OPENING_GAP_MS := 30000
const INSPECT_GAP_MS := 20000
const STATUS_DOWN := "Live replies are slow right now. Neighbours answer from what they know."
const STATUS_DOWN_EMPTY := "Live replies are slow right now."
const STATUS_UP := "Live replies are back."
## The answer to a player line nobody can answer: no residents yet, and the mayors offline or
## their live call failed.
const STATUS_BUSY := "The mayors are busy fighting right now. Chat later."
const SAVE_MESSAGES := 80
const TOPICS_MAX := 10
const EVENT_TITLE := {
	"fire": "Fire", "blackout": "Blackout", "sewage_burst": "Sewage main burst", "gridlock": "Gridlock",
	"smog": "Toxic smog", "earthquake": "Earthquake", "flood": "River flood", "tornado": "Tornado",
	"water_main": "Water main break", "power_line": "Downed power line", "car_crash": "Car crash",
}
## "Ask someone here": who answers, by tile_report kind (lower case; services by label words).
const SPEAKER_ROLES := {
	"residential": "Resident", "commercial": "Shopkeeper", "industrial": "Foreman", "road": "Driver",
	"river": "Fisherman", "forest": "Park ranger", "rubble": "Site worker", "empty": "Surveyor",
	"fire": "Firefighter", "police": "Officer", "hospital": "Nurse", "clinic": "Nurse", "school": "Teacher",
	"university": "Lecturer", "park": "Park keeper", "power": "Plant operator", "plant": "Plant operator",
	"farm": "Technician", "pump": "Water engineer", "water": "Water engineer", "sewage": "Plant operator",
	"hall": "Clerk", "station": "Station attendant", "stadium": "Groundskeeper", "airport": "Ground crew",
	"landfill": "Yard worker", "recycling": "Yard worker",
}
## Openers for the offline "Ask someone here" voice, by role.
const ASK_OPENERS := {
	"Resident": "I live here at %s.", "Shopkeeper": "I run the counter here at %s.", "Foreman": "I keep the line moving at %s.",
	"Driver": "I'm stuck on %s, like always.", "Fisherman": "Been fishing off %s since dawn.", "Park ranger": "I look after the trees out here by %s.",
	"Site worker": "We're clearing what's left at %s.", "Surveyor": "Just measuring up this lot at %s.", "Site foreman": "I run the crew building at %s.",
}
const ASK_FINE := {
	"Resident": "Quiet street, decent neighbours. Can't complain.", "Shopkeeper": "Business is steady. People come by most days.",
	"Foreman": "Orders are in and the machines are humming. Good week.", "Driver": "Traffic's moving today, for once.",
	"Site foreman": "We're on schedule. Mostly.", "Fisherman": "Water's calm. Not biting much, though.",
}

var feed: ChatFeed
var minds: ChatterMinds
var panel: PANEL
var talk: TALK
var street_lines: STREET
## The pinned Gazette: {"headline", "editorial", "stories": [{"title", "body"}], "day"} or {}.
var pinned: Dictionary = {}
## Chatter topics, newest first.
var topics: Array[Dictionary] = []
var paused: bool = false
var _round_accum: int = 0
var _last_now: int = 0
var _gen: int = 0
var _player_pending: Array[String] = []
var _player_first_ms: int = -1
var _player_last_ms: int = -1
var _player_last_seq: int = -1
var _player_calls: Array[int] = []
var _last_opening_ms: int = -1000000
var _last_inspect_ms: int = -1000000
var _inspect_req: Vector2i = Vector2i(-99999, -99999)
var _operator_day: int = -1
var _decree_day: int = -1
var _taxes: Array[int] = []
var _links: Array[Array] = []
var _coord_re := RegEx.create_from_string("\\((-?\\d+),\\s*(-?\\d+)\\)")
var _district_ref_re := RegEx.create_from_string("\\b(?:D|[Dd]istrict\\s*)([0-4])\\b")


func feature_id() -> String:
	return "chat"


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	feed = ChatFeed.new()
	feed.name = "Feed"
	add_child(feed)
	feed.setup(ctx)
	street_lines = STREET.new()
	street_lines.setup(ctx, feed)
	minds = ChatterMinds.new()
	minds.name = "ChatterMinds"
	add_child(minds)
	minds.setup(ctx.sim, ctx.residents, ctx.client, ctx.brain, ctx.directory)
	minds.recent_of = _recent_of
	minds.live_changed.connect(_on_live_changed)
	feed.shown.connect(_on_shown)
	feed.changed.connect(_on_changed)
	feed.pumped.connect(_on_pumped)
	if ctx.hud != null:
		panel = PANEL.new()
		ctx.hud.slot("chat_slot").add_child(panel)
		panel.setup(ctx, feed)
		panel.submitted.connect(player_say)
		talk = TALK.new()
		ctx.hud.slot("overlay").add_child(talk)
		talk.setup(ctx, feed, minds)
		talk.post_line = _post_public_line
	if ctx.residents != null:
		_link(ctx.residents.resident_said, _on_said)
		_link(ctx.residents.resident_arrived, _on_arrived)
		_link(ctx.residents.resident_departed, _on_departed)
	if ctx.brain != null:
		_link(ctx.brain.mayor_decided, _on_mayor)
		_link(ctx.brain.news_published, _on_news)
		_link(ctx.brain.council_ruled, _on_council)
		_link(ctx.brain.chaos_decided, _on_chaos)
		_link(ctx.brain.operator_decided, _on_operator)
		_link(ctx.brain.citizens_spoke, _on_citizens)
		_link(ctx.brain.inspector_answered, _on_inspector)
	if ctx.sim != null:
		_link(ctx.sim.city_log, _on_city_log)
		_link(ctx.sim.event_started, _on_event_started)
		_link(ctx.sim.event_ended, _on_event_ended)
		_link(ctx.sim.site_finished, _on_site_finished)
	if ctx.bus != null:
		_link(ctx.bus.talk_requested, _on_talk_requested)
		_link(ctx.bus.card_action, _on_card_action)
		_link(ctx.bus.player_tile_changed, _on_player_tile_changed)
		_link(ctx.bus.pause_changed, _on_pause_changed)
		_link(ctx.bus.world_ready, _on_world_ready)
		_link(ctx.bus.person_hit, street_lines.on_person_hit)
		_link(ctx.bus.story_filed, _on_story)
	_snapshot_taxes()


func on_world_rebuilt() -> void:
	if pinned.is_empty():
		_pin_last_paper()
	_snapshot_taxes()
	_refresh_district()


func to_dict() -> Dictionary:
	var out: Array = []
	for m: Dictionary in feed.messages.slice(-SAVE_MESSAGES):
		var c := m.duplicate(true)
		c.erase("t_ms")
		out.append(c)
	return {"messages": out, "seq": feed.seq, "pinned": pinned.duplicate(true), "unread": panel.unread if panel != null else 0}


func from_dict(d: Dictionary) -> void:
	_close_ui()
	_gen += 1
	topics.clear()
	_player_pending.clear()
	_player_first_ms = -1
	_round_accum = 0
	feed.clear()
	feed.hold_low = false
	minds.reset()
	if panel != null:
		panel.clear_rows()
	pinned = {}
	if d.is_empty():
		_pin_last_paper()
		return
	var msgs: Array = []
	var raw: Variant = d.get("messages", [])
	if typeof(raw) == TYPE_ARRAY:
		for v: Variant in raw:
			if typeof(v) == TYPE_DICTIONARY:
				msgs.append(_cast_msg(v))
	feed.restore(msgs, int(d.get("seq", 0)))
	var pd: Variant = d.get("pinned", {})
	pinned = _paper(pd) if typeof(pd) == TYPE_DICTIONARY else {}
	if panel != null:
		panel.rebuild(feed.messages, int(d.get("unread", 0)))
		panel.set_pinned(pinned)
	_refresh_district()


func teardown() -> void:
	_close_ui()
	_gen += 1
	for l: Array in _links:
		var sig: Signal = l[0]
		if sig.is_connected(l[1]):
			sig.disconnect(l[1])
	_links.clear()
	if panel != null:
		panel.queue_free()
		panel = null
	if talk != null:
		talk.queue_free()
		talk = null


func self_test() -> Dictionary:
	var in_slot := panel != null and ctx.hud != null and panel.get_parent() == ctx.hud.slot("chat_slot")
	return {
		"ok": in_slot and feed.seq > 0,
		"detail": "panel=%s shown=%d queued=%d rounds=%d heuristic=%d" % [in_slot, feed.seq, feed.queue.size(), int(minds.stats["rounds"]), int(minds.stats["heuristic"])],
	}


func photo_shots() -> Array:
	if panel == null or ctx.mode == null:
		return []
	var sp: Dictionary = ctx.mode.spawn_point()
	return [
		{"name": "chat_open", "pos": sp["pos"], "yaw": float(sp["yaw"]), "pitch": 0.0, "hour": 10.5, "prepare": "tour_open_chat", "restore": "tour_close"},
		{"name": "chat_reply", "pos": sp["pos"], "yaw": float(sp["yaw"]), "pitch": 0.0,
			"hour": 10.5, "prepare": "tour_ask_mayor", "restore": "tour_close"},
		{"name": "chat_talk", "pos": sp["pos"], "yaw": float(sp["yaw"]), "pitch": 0.0, "hour": 10.5, "prepare": "tour_open_talk", "restore": "tour_close"},
	]


## True when resident id's letter to their mayor on day goes public in the chat (about a third
## of them, deterministic: the spec's hash(id + str(day)) % 3 == 0, with the hash mixed).
static func letter_public(id: String, day: int) -> bool:
	return T.mix(id + str(day)) % 3 == 0


## True while the talk dialogue's free-text LineEdit has focus (the player is typing a line).
func is_typing() -> bool:
	return talk != null and talk.is_typing()


## The player's chat line: posted at once, queued as a topic, answered by 2-4 residents through
## one coalesced reply call. "/mayor <text>" also goes to every mayor (once a game day).
func player_say(text: String) -> void:
	var t := text.strip_edges().left(PANEL.INPUT_MAX)
	if t.is_empty():
		return
	var body := t
	if t.to_lower().begins_with("/mayor ") or t.to_lower() == "/mayor":
		body = t.substr(6).strip_edges()
		if body.is_empty():
			return
		t = ("To the mayors: " + body) if _send_decree(body) else body
	var d := _player_district()
	var shown := feed.post_now(feed.make("player", "You", "player", d, t, "player"))
	_player_last_seq = int(shown["seq"])
	_push_topic({"kind": "player", "text": T.display(body, ctx.directory), "district": d})
	# The "To the mayors: " prefix stays in the reply text, so the district's mayor answers it.
	_player_pending.append(t)
	if _player_first_ms < 0:
		_player_first_ms = feed.now_ms
	_player_last_ms = feed.now_ms
	Analytics.track("chat_message", {"chars": body.length(), "to_mayors": t.begins_with("To the mayors: "), "district": d})


## Tour hook: opens the chat drawer.
func tour_open_chat() -> void:
	if panel != null:
		panel.open()


## Tour hook: opens the drawer and asks the mayor of the player's district (or Ada Okafor) about
## their day, then runs the feed clock past the first answer while the next speaker is typing.
func tour_ask_mayor() -> void:
	if panel == null:
		return
	panel.open()
	var mi := maxi(_player_district(), 0)
	player_say("Mayor %s, what did you do today?" % D.mayor_display(mi).get_slice(" ", 1))
	var until := feed.now_ms + PLAYER_DEBOUNCE_MS + REPLY_FIRST_MS + int(REPLY_GAP_MS * 0.5)
	while feed.now_ms < until:
		feed.pump(0.25)


## Tour hook: talks to the resident nearest the player once the tour has placed the player.
func tour_open_talk() -> void:
	_tour_talk.call_deferred()


## Tour hook: closes the drawer and any conversation.
func tour_close() -> void:
	_close_ui()


# ---------------------------------------------------------------- timed rules

func _on_pumped(now: int) -> void:
	var dt := maxi(0, now - _last_now)
	_last_now = now
	var live_mode := not paused and not (ctx.mode != null and ctx.mode.paused)
	var talkers := ctx.residents != null and ctx.residents.is_active()
	if live_mode and (talkers or minds.live()):
		_round_accum += dt
		if _round_accum >= ROUND_MS:
			_round_accum = mini(_round_accum - ROUND_MS, ROUND_MS)
			if not minds.busy("round"):
				_run_round(not talkers)
	if live_mode:
		_pump_player(now)
	var answering := _answering(now)
	feed.hold_low = answering
	if talk != null:
		talk.on_pump(now)
	if panel != null:
		panel.set_typing(answering, _typing_names())
		panel.on_pump(now)


## One chatter round: residents on the next topic, or (mayors_only) the rival mayors arguing
## while nobody lives in the city yet. Their lines skip the per-author limit, so a mayor can
## answer back within the round.
func _run_round(mayors_only: bool = false) -> void:
	var gen := _gen
	var recent := feed.messages.slice(-8)
	var lines: Array = []
	if mayors_only:
		lines = await minds.run_mayors_round(recent)
	else:
		lines = await minds.run_round(_next_topic(), recent)
	if gen != _gen:
		return
	var qids: Array[int] = []
	for v: Variant in lines:
		var ln: Dictionary = v
		var opts := {"exempt": mayors_only}
		var ri := int(ln.get("reply_idx", -1))
		if ri >= 0 and ri < qids.size() and qids[ri] >= 0:
			opts["reply_qid"] = qids[ri]
		qids.append(feed.enqueue(_line_msg(ln), opts))


func _pump_player(now: int) -> void:
	if _player_pending.is_empty() or minds.busy("player"):
		return
	var due := mini(_player_last_ms + PLAYER_DEBOUNCE_MS, _player_first_ms + PLAYER_COALESCE_MS)
	if now < due:
		return
	while not _player_calls.is_empty() and now - _player_calls[0] >= 60000:
		_player_calls.pop_front()
	if _player_calls.size() >= PLAYER_CALLS_PER_MIN:
		return
	_player_calls.append(now)
	var text := "\n".join(PackedStringArray(_player_pending))
	_player_pending.clear()
	_player_first_ms = -1
	_reply_player(text, _player_last_seq, _player_district())


func _reply_player(text: String, parent: int, district: int) -> void:
	var gen := _gen
	var lines: Array = await minds.reply_to_player(text, district, feed.messages.slice(-8))
	if gen != _gen:
		return
	if lines.is_empty():
		feed.post_now(feed.make("system", "Chat", "system", -1, STATUS_BUSY, "status"))
		return
	var delay := REPLY_FIRST_MS
	for v: Variant in lines:
		var ln: Dictionary = v
		var msg := _line_msg(ln)
		msg["reply_to"] = parent
		feed.enqueue(msg, {"skip": true, "exempt": true, "force": true, "delay_ms": delay})
		delay += REPLY_GAP_MS + T.h(str(ln.get("id", ""))) % 700


## True while the player is being answered: their line waits for its reply call (at most
## PLAYER_COALESCE_MS), the call is out, or the replies wait in the fast lane.
func _answering(now: int) -> bool:
	var waiting := not _player_pending.is_empty() and now - _player_first_ms <= PLAYER_COALESCE_MS
	return waiting or minds.busy("player") or feed.fast_count() > 0


## Who the typing row names: the fast lane's authors, soonest first (residents by full name, as
## many share a first name; mayors as "Mayor <last name>").
func _typing_names() -> Array[String]:
	var out: Array[String] = []
	for a: Dictionary in feed.fast_authors():
		var n := str(a["author"])
		var nm := ("Mayor " + n.get_slice(" ", 1)) if str(a["role"]) == "mayor" else n
		if not out.has(nm):
			out.append(nm)
	return out


# ---------------------------------------------------------------- topics

func _push_topic(t: Dictionary) -> void:
	topics.push_front(t)
	while topics.size() > TOPICS_MAX:
		topics.pop_back()


func _next_topic() -> Dictionary:
	while not topics.is_empty():
		var t: Dictionary = topics.pop_front()
		if str(t.get("kind", "")) == "incident" and not _event_active(int(t.get("event_id", -1))):
			continue
		return t
	match minds.round_index % 3:
		0:
			var u := _unanswered_topic()
			if not u.is_empty():
				return u
		1:
			var c := _complaint_topic()
			if not c.is_empty():
				return c
	return {"kind": "ambient", "district": _player_district()}


func _unanswered_topic() -> Dictionary:
	var replied := {}
	for m: Dictionary in feed.messages:
		replied[int(m.get("reply_to", -1))] = true
	var k := feed.messages.size() - 1
	var seen := 0
	while k >= 0 and seen < 20:
		var m: Dictionary = feed.messages[k]
		k -= 1
		seen += 1
		if str(m["role"]) != "resident" or str(m["kind"]) not in ["say", "react", "chatter"] or replied.has(int(m["seq"])):
			continue
		var r := ctx.residents.find(str(m["author_id"]))
		if r.is_empty():
			continue
		return {"kind": "unanswered", "seq": int(m["seq"]), "author": str(m["author"]), "author_id": str(m["author_id"]), "text": str(m["text"]), "tile": int(r["home"])}
	return {}


func _complaint_topic() -> Dictionary:
	var best_d := -1
	var best_c := ""
	var best_n := 0
	var pd := _player_district()
	for d in range(D.MAYORS.size()):
		var dm := ctx.residents.district_mood(d)
		var cs: Dictionary = dm.get("complaints", {})
		for c: String in cs.keys():
			var n := int(cs[c]) * (2 if d == pd else 1)
			if n > best_n:
				best_n = n
				best_c = c
				best_d = d
	if best_d < 0:
		return {}
	return {"kind": "complaint", "complaint": best_c, "district": best_d}


# ---------------------------------------------------------------- sources

func _on_said(id: String, text: String, kind: String) -> void:
	var r := ctx.residents.find(id)
	if r.is_empty():
		return
	var refs := {}
	var t := text
	match kind:
		"react":
			var ev_id := _event_near(r)
			if ev_id >= 0:
				refs["event_id"] = ev_id
		"letter":
			if not letter_public(id, ctx.sim.day):
				return
			var md := D.mayor_display(ctx.sim.district[int(r["home"])])
			if md.is_empty():
				return
			t = "To Mayor %s: %s" % [md, text]
		"say":
			pass
		_:
			return
	feed.enqueue(_resident_msg(r, t, kind, refs))


func _on_arrived(r: Dictionary) -> void:
	var home := int(r["home"])
	var job := str(r.get("job_title", "newcomer"))
	var street := ctx.directory.street_at(Vector3(D.tx(home), 0.0, D.ty(home))) if ctx.directory != null else ""
	var art := "an" if job.left(1).to_lower() in ["a", "e", "i", "o", "u"] else "a"
	var text := "%s, %s %s, moved in%s." % [str(r["name"]), art, job, (" on " + street) if not street.is_empty() else ""]
	feed.enqueue(feed.make("system", "Neighbours", "system", ctx.sim.district[home], text, "people", -1, {"tile": home, "phase": "arrived"}))


func _on_departed(r: Dictionary, reason: String) -> void:
	var home := int(r.get("home", -1))
	var why := T.clip(reason.strip_edges().trim_suffix("."), 90)
	var text := "%s moved away%s." % [str(r.get("name", "Someone")), (": " + why) if not why.is_empty() else ""]
	var d := ctx.sim.district[home] if home >= 0 and home < ctx.sim.district.size() else -1
	feed.enqueue(feed.make("system", "Neighbours", "system", d, text, "people", -1, {"tile": home, "phase": "left"}))


func _on_mayor(mi: int, entry: Dictionary) -> void:
	var post := str(entry.get("post", "")).strip_edges()
	if not post.is_empty() and mi >= 0 and mi < D.MAYORS.size():
		feed.enqueue(feed.make("mayor:%d" % mi, str(D.MAYORS[mi]["display"]), "mayor", mi, post, "post"))
	if mi >= 0 and mi < _taxes.size() and mi < ctx.sim.mayors.size():
		var now_tax := int(ctx.sim.mayors[mi]["tax_r"])
		if now_tax != _taxes[mi]:
			_push_topic({"kind": "taxes", "district": mi, "up": now_tax > _taxes[mi]})
			_taxes[mi] = now_tax


func _on_news(paper: Dictionary) -> void:
	pinned = _paper(paper)
	if panel != null:
		panel.set_pinned(pinned)
	var hl := str(pinned.get("headline", ""))
	if hl.is_empty():
		return
	feed.enqueue(feed.make("press", "GridFall Gazette", "press", -1, hl, "headline", -1, {"day": int(pinned.get("day", 0))}))
	_push_topic({"kind": "headline", "headline": hl})


func _on_council(r: Dictionary) -> void:
	var parts: Array[String] = []
	var first := ""
	var enacted := true
	for key: String in ["enacted", "repealed"]:
		var labels: Array[String] = []
		var arr: Variant = r.get(key, [])
		if typeof(arr) != TYPE_ARRAY:
			continue
		for k: Variant in arr:
			var o: Dictionary = D.ORDINANCES.get(str(k), {})
			if not o.is_empty():
				labels.append(str(o["label"]))
		if not labels.is_empty():
			parts.append("%s: %s." % ["Passed" if key == "enacted" else "Repealed", ", ".join(PackedStringArray(labels))])
			if first.is_empty():
				first = labels[0]
				enacted = key == "enacted"
	var st := T.clip(str(r.get("statement", "")).strip_edges(), 180)
	if not st.is_empty():
		parts.append(st)
	if parts.is_empty():
		return
	feed.enqueue(feed.make("council", "City Council", "council", -1, " ".join(PackedStringArray(parts)), "ruling"))
	if not first.is_empty():
		_push_topic({"kind": "ordinance", "label": first, "enacted": enacted})


func _on_chaos(d: Dictionary) -> void:
	if not bool(d.get("trigger", false)):
		return
	var x := int(d.get("x", -9999))
	var y := int(d.get("y", -9999))
	var tile := D.idx(x, y) if D.in_bounds(x, y) else -1
	var ev := _event_at(x, y)
	var narration := T.display(str(d.get("narration", "")), ctx.directory)
	if narration.is_empty() or narration.to_lower().begins_with("trouble strikes"):
		var title: String = EVENT_TITLE.get(str(ev.get("type", "")), "Trouble")
		narration = "%s at %s" % [title, ctx.directory.place_label(tile) if tile >= 0 else "the edge of town"]
	var text := "Breaking: " + narration
	var fields := {"author_id": "system", "author": "Breaking", "role": "system", "kind": "alert", "text": text}
	var where := {"kind": "incident", "refs.x": x, "refs.y": y, "refs.phase": "started"}
	var queued := feed.find_queued(where)
	if not queued.is_empty():
		feed.update_queued(queued, fields)
		return
	var shown := feed.find_shown(where)
	if not shown.is_empty():
		feed.update_shown(shown, fields)
		return
	var refs := {"x": x, "y": y, "phase": "started"}
	if not ev.is_empty():
		refs["event_id"] = int(ev["id"])
		refs["type"] = str(ev["type"])
	if tile >= 0:
		refs["tile"] = tile
	feed.enqueue(feed.make("system", "Breaking", "system", ctx.sim.district[tile] if tile >= 0 else -1, text, "alert", -1, refs))


func _on_operator(d: Dictionary) -> void:
	if ctx.sim.day == _operator_day:
		return
	var note := str(d.get("note", "")).strip_edges()
	if note.is_empty():
		note = str(d.get("advice", "")).strip_edges()
	var pr: Variant = d.get("priority", [])
	var first := ""
	if typeof(pr) == TYPE_ARRAY and not (pr as Array).is_empty():
		var k := int((pr as Array)[0])
		if k >= 0 and k < D.MAYORS.size():
			first = str(D.MAYORS[k]["district"])
	if note.is_empty() and first.is_empty():
		return
	_operator_day = ctx.sim.day
	var m := _district_ref_re.search(note)
	while m != null:
		var rep_name := str(D.MAYORS[m.get_string(1).to_int()]["district"])
		note = note.substr(0, m.get_start()) + rep_name + note.substr(m.get_end())
		m = _district_ref_re.search(note, m.get_start() + rep_name.length())
	var text := ("%s keeps power first today. " % first if not first.is_empty() else "") + note
	feed.enqueue(feed.make("system", "Grid Operator", "system", -1, text, "notice"))


func _on_citizens(voices: Array) -> void:
	if ctx.residents != null and ctx.residents.is_active():
		return
	for v: Variant in voices:
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var vd: Dictionary = v
		var th := str(vd.get("thought", "")).strip_edges()
		if th.is_empty():
			continue
		feed.enqueue(feed.make("v:" + str(vd.get("id", "")), str(vd.get("name", "A resident")), "resident", int(vd.get("district", -1)), th, "say"))


func _on_city_log(line: String, category: String) -> void:
	if category != "deal" and not (category == "disaster" and line.contains("A fire destroyed a building at")):
		return
	var text := T.strip_day(line)
	var refs := {}
	var d := -1
	var m := _coord_re.search(text)
	if m != null and D.in_bounds(m.get_string(1).to_int(), m.get_string(2).to_int()):
		var tile := D.idx(m.get_string(1).to_int(), m.get_string(2).to_int())
		refs["tile"] = tile
		d = ctx.sim.district[tile]
	feed.enqueue(feed.make("system", "City", "system", d, text, "log", -1, refs))


func _on_event_started(ev: Dictionary) -> void:
	var x := int(ev["x"])
	var y := int(ev["y"])
	var tile := D.idx(x, y) if D.in_bounds(x, y) else -1
	var title: String = EVENT_TITLE.get(str(ev["type"]), str(ev.get("label", "Trouble")))
	var place := ctx.directory.place_label(tile) if tile >= 0 else "the edge of town"
	var refs := {"event_id": int(ev["id"]), "x": x, "y": y, "phase": "started", "type": str(ev["type"])}
	if tile >= 0:
		refs["tile"] = tile
	var d := ctx.sim.district[tile] if tile >= 0 else -1
	feed.enqueue(feed.make("system", "City Alert", "system", d, "%s at %s" % [title, place], "incident", -1, refs))
	_push_topic({"kind": "incident", "type": str(ev["type"]), "tile": tile, "district": d, "skills": ev.get("skills", []), "event_id": int(ev["id"])})


func _on_event_ended(ev: Dictionary) -> void:
	var x := int(ev["x"])
	var y := int(ev["y"])
	var tile := D.idx(x, y) if D.in_bounds(x, y) else -1
	var noun := str(ChatterMinds.EVENT_NOUN.get(str(ev["type"]), "trouble"))
	var place := ctx.directory.place_label(tile) if tile >= 0 else "the edge of town"
	var refs := {"event_id": int(ev["id"]), "x": x, "y": y, "phase": "ended", "type": str(ev["type"])}
	if tile >= 0:
		refs["tile"] = tile
	feed.enqueue(feed.make("system", "City Alert", "system", ctx.sim.district[tile] if tile >= 0 else -1, "Crews cleared the %s at %s." % [noun, place], "incident", -1, refs))


func _on_site_finished(s: Dictionary) -> void:
	var i := int(s.get("i", -1))
	if i < 0 or i >= ctx.sim.kind.size():
		return
	var place := ctx.directory.place_name(i)
	var eligible := str(s.get("type", "")) == "build"
	if not eligible and int(s.get("target_kind", -1)) in [D.ZONE_C, D.ZONE_I] and int(s.get("target_level", -1)) == 1:
		eligible = not place.is_empty()
	if not eligible:
		return
	if feed.now_ms - _last_opening_ms < OPENING_GAP_MS:
		return
	_last_opening_ms = feed.now_ms
	if place.is_empty():
		place = str(s.get("label", "a new building"))
	feed.enqueue(feed.make("system", "City", "system", ctx.sim.district[i], "Now open: " + place, "opened", -1, {"tile": i}))
	var what := ctx.directory.business_kind(i)
	_push_topic({"kind": "opening", "tile": i, "what": what if not what.is_empty() else str(s.get("label", "place")).to_lower(), "name_place": place})


func _on_inspector(rep: Dictionary) -> void:
	if bool(rep.get("pending", false)):
		return
	if int(rep.get("x", -99999)) != _inspect_req.x or int(rep.get("y", -99999)) != _inspect_req.y:
		return
	_inspect_req = Vector2i(-99999, -99999)
	var x := int(rep["x"])
	var y := int(rep["y"])
	var place := ctx.directory.place_label(D.idx(x, y)) if D.in_bounds(x, y) else ""
	var role := _speaker_role(rep)
	var says := ""
	if str(rep.get("source", "")) == "live":
		says = T.display(str(rep.get("says", "")), ctx.directory)
	if says.is_empty():
		says = _ask_voice(rep, role, place)
	if talk != null:
		talk.set_ask_answer(role, place, says)


# ---------------------------------------------------------------- bus

func _on_shown(msg: Dictionary) -> void:
	if panel != null:
		panel.append(msg)


## A status card when live replies stop working or come back (ChatterMinds.live_changed). With
## nobody living in the city there are no neighbours to answer instead.
func _on_live_changed(up: bool) -> void:
	var text := STATUS_UP if up else STATUS_DOWN
	if not up and not (ctx.residents != null and ctx.residents.is_active()):
		text = STATUS_DOWN_EMPTY
	feed.enqueue(feed.make("system", "Chat", "system", -1, text, "status"))


func _on_changed(msg: Dictionary) -> void:
	if panel != null:
		panel.replace(msg)


func _on_talk_requested(id: String) -> void:
	if talk == null or ctx.has_modal(&"pause"):
		return
	if talk.mode == "talk" and talk.active_id == id:
		return
	if panel != null and panel.is_open:
		panel.close()
	if not talk.open(id) and ctx.bus != null:
		ctx.bus.toast.emit("They've moved on.", "info")


func _on_card_action(action: String, tile: int) -> void:
	if action != "ask_here" or ctx.brain == null or tile < 0 or tile >= ctx.sim.kind.size():
		return
	if feed.now_ms - _last_inspect_ms < INSPECT_GAP_MS:
		if ctx.bus != null:
			ctx.bus.toast.emit("Give it a moment before asking around again.", "info")
		return
	_last_inspect_ms = feed.now_ms
	_inspect_req = Vector2i(D.tx(tile), D.ty(tile))
	if panel != null and panel.is_open:
		panel.close()
	if talk != null:
		talk.open_ask(ctx.directory.place_label(tile))
	ctx.brain.inspect_tile(D.tx(tile), D.ty(tile))


## The player's story for the Gazette (bus.story_filed), as a press line of its own: each story
## has its own author id, so a second one never replaces the first while it waits in the queue.
func _on_story(s: Dictionary) -> void:
	var text := str(s.get("text", ""))
	var refs := {"day": int(s.get("day", 0)), "tile": int(s.get("tile", -1))}
	var d := int(s.get("district", -1))
	var id := "press:story:%d" % hash(text)
	feed.enqueue(feed.make(id, "GridFall Gazette", "press", d, text, "headline", -1, refs))
	if not str(s.get("headline", "")).is_empty():
		_push_topic({"kind": "headline", "headline": str(s["headline"])})


func _on_player_tile_changed(_x: int, _y: int) -> void:
	_refresh_district()


func _on_pause_changed(p: bool) -> void:
	paused = p


func _on_world_ready() -> void:
	_close_ui()
	_refresh_district()


# ---------------------------------------------------------------- helpers

## Closes the chat input and any conversation (emitting conversation_changed(id, false)) and pops
## both modals (load, New City, teardown).
func _close_ui() -> void:
	if panel != null:
		panel.close()
	if talk != null:
		talk.end()
	if ctx != null:
		ctx.pop_modal(&"chat")
		ctx.pop_modal(&"talk")


func _tour_talk() -> void:
	if ctx.residents == null or ctx.residents.people.is_empty():
		return
	var p := ctx.player_position()
	var best := ""
	var bd := INF
	for r: Dictionary in ctx.residents.people:
		var at := int(r.get("at", r["home"]))
		var dd := Vector2(D.tx(at) - p.x, D.ty(at) - p.z).length()
		if dd < bd:
			bd = dd
			best = str(r["id"])
	if not best.is_empty() and ctx.bus != null:
		ctx.bus.talk_requested.emit(best)


func _post_public_line(r: Dictionary, text: String) -> void:
	feed.enqueue(_resident_msg(r, text, "chatter", {}))


func _resident_msg(r: Dictionary, text: String, kind: String, refs: Dictionary) -> Dictionary:
	var rf := refs.duplicate()
	rf["job"] = str(r.get("job_title", ""))
	return feed.make(str(r["id"]), str(r["name"]), "resident", ctx.sim.district[int(r["home"])], text, kind, -1, rf)


## A ChatterMinds line as a chat message (kind "chatter").
func _line_msg(ln: Dictionary) -> Dictionary:
	var refs := {}
	var id := str(ln.get("id", ""))
	if str(ln.get("role", "resident")) == "resident":
		var r := ctx.residents.find(id)
		if not r.is_empty():
			refs["job"] = str(r.get("job_title", ""))
	return feed.make(id, str(ln.get("author", "")), str(ln.get("role", "resident")), int(ln.get("district", -1)), str(ln.get("text", "")), "chatter", int(ln.get("reply_to", -1)), refs)


func _recent_of(id: String) -> Array:
	var out: Array = []
	for k in range(feed.messages.size() - 1, -1, -1):
		var m: Dictionary = feed.messages[k]
		if str(m["author_id"]) == id:
			out.push_front(str(m["text"]))
			if out.size() >= 3:
				break
	return out


func _event_near(r: Dictionary) -> int:
	var at := int(r.get("at", r["home"]))
	var best := -1
	var bd := 11
	for ev: Dictionary in ctx.sim.events:
		var d := absi(int(ev["x"]) - D.tx(at)) + absi(int(ev["y"]) - D.ty(at))
		if d < bd:
			bd = d
			best = int(ev["id"])
	if best < 0 and not ctx.sim.events.is_empty():
		best = int(ctx.sim.events[-1]["id"])
	return best


func _event_at(x: int, y: int) -> Dictionary:
	for k in range(ctx.sim.events.size() - 1, -1, -1):
		var ev: Dictionary = ctx.sim.events[k]
		if int(ev["x"]) == x and int(ev["y"]) == y:
			return ev
	return {}


func _event_active(id: int) -> bool:
	for ev: Dictionary in ctx.sim.events:
		if int(ev["id"]) == id:
			return true
	return false


func _player_district() -> int:
	var t := ctx.player_tile()
	return ctx.sim.district[t] if t >= 0 and t < ctx.sim.district.size() else -1


func _refresh_district() -> void:
	if panel != null:
		panel.set_player_district(_player_district())


func _snapshot_taxes() -> void:
	_taxes.clear()
	if ctx.sim == null:
		return
	for m: Dictionary in ctx.sim.mayors:
		_taxes.append(int(m.get("tax_r", 9)))


## Sends body to every mayor (brain.send_decree), at most once per game day. False when refused.
func _send_decree(body: String) -> bool:
	if ctx.brain == null:
		return false
	if _decree_day == ctx.sim.day:
		if ctx.bus != null:
			ctx.bus.toast.emit("The mayors already heard from you today.", "info")
		return false
	_decree_day = ctx.sim.day
	ctx.brain.send_decree(body)
	if ctx.bus != null:
		ctx.bus.toast.emit("Your message is on every mayor's desk.", "success")
	return true


func _pin_last_paper() -> void:
	pinned = {}
	if ctx.brain != null and not ctx.brain.last_paper.is_empty():
		pinned = _paper(ctx.brain.last_paper)
	if panel != null:
		panel.set_pinned(pinned)


## A Gazette edition, filtered for display: {"headline", "editorial", "stories", "day"}.
func _paper(p: Dictionary) -> Dictionary:
	var hl := T.display(str(p.get("headline", "")), ctx.directory)
	if hl.is_empty():
		return {}
	var stories: Array = []
	var raw: Variant = p.get("stories", [])
	if typeof(raw) == TYPE_ARRAY:
		for s: Variant in raw:
			if typeof(s) == TYPE_DICTIONARY:
				var sd: Dictionary = s
				stories.append({"title": T.display(str(sd.get("title", "")), ctx.directory), "body": T.display(str(sd.get("body", "")), ctx.directory)})
	return {"headline": hl, "editorial": T.display(str(p.get("editorial", "")), ctx.directory), "stories": stories, "day": int(p.get("day", ctx.sim.day))}


## A saved message with JSON floats cast back to int and its text filtered again (old saves).
func _cast_msg(v: Dictionary) -> Dictionary:
	var refs := {}
	var rr: Variant = v.get("refs", {})
	if typeof(rr) == TYPE_DICTIONARY:
		for k: Variant in (rr as Dictionary).keys():
			var val: Variant = (rr as Dictionary)[k]
			if typeof(val) == TYPE_FLOAT and is_equal_approx(float(val), roundf(float(val))):
				refs[str(k)] = int(val)
			elif typeof(val) == TYPE_INT:
				refs[str(k)] = val
			else:
				refs[str(k)] = str(val)
	return {
		"seq": int(v.get("seq", 0)), "author_id": str(v.get("author_id", "")), "author": T.display(str(v.get("author", "")), ctx.directory),
		"role": str(v.get("role", "resident")), "district": int(v.get("district", -1)), "text": T.display(str(v.get("text", "")), ctx.directory),
		"kind": str(v.get("kind", "say")), "day": int(v.get("day", 0)), "clock": str(v.get("clock", "")), "t_ms": 0,
		"reply_to": int(v.get("reply_to", -1)), "refs": refs,
	}


func _speaker_role(rep: Dictionary) -> String:
	var sp := str(rep.get("speaker", "")).strip_edges()
	var report: Dictionary = rep.get("report", {}) if typeof(rep.get("report")) == TYPE_DICTIONARY else {}
	var kind := str(report.get("kind", "")).to_lower()
	if str(rep.get("source", "")) == "live" and not sp.is_empty() and sp.length() <= 32 and not sp.to_lower().contains("inspector") and not T.has_model_name(sp):
		return T.cap(T.display(sp, ctx.directory))
	var site: Variant = report.get("construction", {})
	if typeof(site) == TYPE_DICTIONARY and not (site as Dictionary).is_empty():
		return "Site foreman"
	if SPEAKER_ROLES.has(kind):
		return str(SPEAKER_ROLES[kind])
	for word: String in kind.split(" ", false):
		if SPEAKER_ROLES.has(word):
			return str(SPEAKER_ROLES[word])
	return "Staff member"


## The offline "Ask someone here" answer: first person, from the tile report (power, water, air,
## crime, road access), naming the district's mayor when something is wrong.
func _ask_voice(rep: Dictionary, role: String, place: String) -> String:
	var report: Dictionary = rep.get("report", {}) if typeof(rep.get("report")) == TYPE_DICTIONARY else {}
	var opener: String = str(ASK_OPENERS.get(role, "I work here at %s.")) % (place if not place.is_empty() else "this spot")
	var issues: Array[String] = []
	if bool(report.get("burning", false)):
		issues.append("the whole place is on fire")
	if not bool(report.get("powered", true)) and int(report.get("density", 1)) > 0:
		issues.append("we've had no power all day")
	if not bool(report.get("watered", true)) and int(report.get("density", 0)) > 0:
		issues.append("the taps are dry")
	if float(report.get("pollution", 0.0)) > 0.4:
		issues.append("the air tastes like smoke")
	if float(report.get("crime", 0.0)) > 0.3:
		issues.append("there have been break-ins on this block")
	if not bool(report.get("road_access", true)):
		issues.append("there's no proper road in")
	if issues.is_empty():
		return "%s %s" % [opener, ASK_FINE.get(role, "Things are fine around here, honestly.")]
	var joined := issues[0] if issues.size() == 1 else ", ".join(PackedStringArray(issues.slice(0, issues.size() - 1))) + " and " + issues[-1]
	var mayor := D.mayor_display(int(report.get("district_index", -1)))
	var tail := (" Somebody tell Mayor %s." % mayor.get_slice(" ", mayor.get_slice_count(" ") - 1)) if not mayor.is_empty() else ""
	return "%s Honestly? %s.%s" % [opener, T.cap(joined), tail]


func _link(sig: Signal, c: Callable) -> void:
	if not sig.is_connected(c):
		sig.connect(c)
	_links.append([sig, c])
