extends FpFeature
## The Gazette's stringer (integration feature "reporter"; docs/fp/ARCHITECTURE.md, Reporter). An
## AI decision with a place is a lead (ReporterDesk): a mayor's order, a council ruling, a Chaos
## Director strike. K takes the newest on assignment and sets a waypoint to the scene. There the
## story needs a quote: a reply someone gives the hero face to face, or the answer to "Ask
## someone here" (bus.talk_replied). It may also carry a photo: in photo mode (P) a click with the
## scene inside the viewfinder's marks is a sharp shot. K files it: the Gazette runs it in the
## chat (bus.story_filed) and it earns points towards the press ranks, more for a scoop (filed
## within a third of a day), a local voice (someone who lives in the district) and a sharp shot.
## L opens the mayors' league: the five mayors ranked, the press card, the open leads (chase
## another) and the latest stories. A lead goes cold after a day.

const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const DESK := preload("res://scripts/fp/reporter/reporter_desk.gd")
const CARD := preload("res://scripts/fp/reporter/reporter_card.gd")
const FINDER := preload("res://scripts/fp/reporter/reporter_viewfinder.gd")
const LEAGUE := preload("res://scripts/fp/reporter/reporter_league.gd")
const MODAL := &"league"
const INPUTS: Array[String] = ["press_story", "press_league"]
const MAX_LEADS := 4
const KEEP_STORIES := 5
## A lead goes cold LEAD_DAYS after it happened; a story filed within SCOOP_DAYS is a scoop (sim
## days).
const LEAD_DAYS := 1.0
const SCOOP_DAYS := 1.0 / 3.0
## The scene: within SCENE tiles of the lead's tile. A press photo holds a point SUBJECT_Y above
## the tile's ground, from within PHOTO_RANGE (u).
const SCENE := 3.0
const SUBJECT_Y := 0.15
const PHOTO_RANGE := 4.0
## A reply shorter than this is no quote ("Hm.").
const QUOTE_MIN := 12
const REFRESH := 0.5
## Where a council ruling happens when the city has no City Hall.
const HALL_AT := Vector2i(15, 14)
const NO_POINT := Vector3(NAN, NAN, NAN)
## Photo tour: frames to wait for the tour's teleport before staging, and the staged answer.
const PHOTO_FRAMES := 8
const PHOTO_SPEAKER := "Shopkeeper"
const PHOTO_QUOTE := "Nobody asked us first, but honestly, it's about time."

## Open leads, newest first: ReporterDesk leads with "at" (sim days) and "place".
var leads: Array[Dictionary] = []
## The lead on assignment with its "quote", "by", "quote_id" (the resident's id, "" for a
## passer-by), "local", "sharp", "seen" (the hero reached the scene) and "wp" (the waypoint set
## for it); {} for none.
var story: Dictionary = {}
var points: int = 0
var filed: int = 0
## The latest filed stories, newest first: {"text", "points", "bonus", "day"}.
var stories: Array[Dictionary] = []
var league_open: bool = false
var card: CARD
var finder: FINDER
var league: LEAGUE
var _tipped: bool = false
## The hero's feet when photo mode opened: the camera flies off, the scene is judged from here.
var _anchor: Vector3 = NO_POINT
## The strike trigger is past its dead zone (the shutter fires once per pull).
var _trigger: bool = false
var _t: float = 0.0
## The photo tour's lead, {} without one.
var _photo: Dictionary = {}


func feature_id() -> String:
	return "reporter"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	if ctx.hud != null:
		_build_ui()
	if ctx.brain != null:
		link_signal(ctx.brain.mayor_decided, _on_mayor)
		link_signal(ctx.brain.council_ruled, _on_council)
		link_signal(ctx.brain.chaos_decided, _on_chaos)
	if ctx.bus != null:
		link_signal(ctx.bus.talk_replied, _on_reply)
		link_signal(ctx.bus.modal_changed, _on_modal)
		link_signal(ctx.bus.pause_changed, _on_pause)
	if ctx.player != null:
		link_signal(ctx.player.photo_mode_changed, _on_photo)


## Boot, load or New City: the old city's leads and story are gone.
func on_world_rebuilt() -> void:
	_drop_all()


func to_dict() -> Dictionary:
	if points == 0 and filed == 0 and not _tipped:
		return {}
	return {"points": points, "filed": filed, "stories": stories.duplicate(true), "tipped": _tipped}


func from_dict(d: Dictionary) -> void:
	points = maxi(0, int(d.get("points", 0)))
	filed = maxi(0, int(d.get("filed", 0)))
	_tipped = bool(d.get("tipped", false))
	stories.clear()
	var raw: Variant = d.get("stories", [])
	var list: Array = raw if typeof(raw) == TYPE_ARRAY else []
	for v: Variant in list:
		if typeof(v) == TYPE_DICTIONARY and stories.size() < KEEP_STORIES:
			stories.append(_kept(v))
	_drop_all()


func teardown() -> void:
	close_league()
	unlink_signals()
	for n: Control in [card, finder, league]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	card = null
	finder = null
	league = null


func self_test() -> Dictionary:
	var missing := INPUTS.filter(func(a: String) -> bool: return not InputMap.has_action(a))
	if not missing.is_empty():
		return {"ok": false, "detail": "missing inputs %s" % str(missing)}
	if ctx.hud != null and (card == null or finder == null or league == null):
		return {"ok": false, "detail": "reporter UI missing"}
	var rank := str(DESK.rank_of(points)["name"])
	return {"ok": true, "detail": "%d leads, %d filed, %s" % [leads.size(), filed, rank]}


## Takes open lead k (0: the newest) on assignment, dropping any story already on it, and sets a
## waypoint to its scene. False when there is no such lead.
func take_lead(k: int = 0) -> bool:
	if k < 0 or k >= leads.size():
		if leads.is_empty():
			_toast("No leads yet. Every decision a mayor makes somewhere brings one.", "info")
		return false
	_clear_story()
	story = leads[k].duplicate()
	leads.remove_at(k)
	story.merge({"quote": "", "by": "", "quote_id": "", "local": false, "sharp": false})
	story["seen"] = at_scene()
	var stand := _stand(story)
	story["wp"] = stand["pos"]
	if ctx.hud != null and not bool(story["seen"]):
		ctx.hud.set_waypoint(stand["pos"])
	_toast("On assignment: %s. Get a quote at %s." % [story["headline"], story["place"]], "info")
	Analytics.track("lead_taken", {"agent": str(story["agent"]), "open": leads.size()})
	_refresh()
	return true


## K: takes the newest lead, or files the story on assignment once it has its quote (else says what
## it still needs).
func press_story() -> void:
	if story.is_empty():
		take_lead()
	elif not str(story["quote"]).is_empty():
		file_story()
	elif bool(story["seen"]):
		_toast("Not filed yet: talk to someone here for a quote. L lists the other leads.", "info")
	else:
		var t := "Not filed yet: get to %s for a quote. L lists the other leads." % story["place"]
		_toast(t, "info")


## Files the story on assignment once it has its quote: points towards the press ranks, the
## Gazette's chat line (bus.story_filed) and a memory for the resident quoted. Returns the story
## as filed (bus.story_filed's dict), {} when there is nothing to file.
func file_story() -> Dictionary:
	if story.is_empty() or str(story.get("quote", "")).is_empty():
		return {}
	var s := story
	_clear_story()
	var t: Vector2i = s["tile"]
	var scoop := _now() - float(s["at"]) <= SCOOP_DAYS
	var out := {"agent": s["agent"], "headline": s["headline"], "place": s["place"]}
	out.merge({"quote": s["quote"], "by": s["by"], "tile": D.idx(t.x, t.y)})
	out.merge({"district": int(s["district"]), "day": ctx.sim.day if ctx.sim != null else 0})
	out.merge({"scoop": scoop, "local": bool(s["local"]), "sharp": bool(s["sharp"])})
	out["points"] = DESK.points_for(scoop, bool(s["local"]), bool(s["sharp"]))
	out["text"] = DESK.story_text(out)
	var was := str(DESK.rank_of(points)["name"])
	points += int(out["points"])
	filed += 1
	stories.push_front(_kept(out))
	if stories.size() > KEEP_STORIES:
		stories.resize(KEEP_STORIES)
	_credit(s)
	_announce(out, was)
	if ctx.bus != null:
		ctx.bus.story_filed.emit(out)
	var tags := {"points": out["points"], "scoop": scoop, "local": out["local"]}
	tags["sharp"] = out["sharp"]
	Analytics.track("story_filed", tags)
	_refresh()
	return out


## True while the hero is at the scene of the story on assignment (in photo mode: stood there when
## the camera came up).
func at_scene() -> bool:
	if story.is_empty():
		return false
	var feet := ctx.player_position()
	if ctx.player != null and ctx.player.photo_mode and not is_nan(_anchor.x):
		feet = _anchor
	var t: Vector2i = story["tile"]
	return Vector2(feet.x - t.x, feet.z - t.y).length() <= SCENE


## True when the camera holds the scene of the story on assignment inside the viewfinder's marks
## (ReporterDesk.framed), from within PHOTO_RANGE.
func scene_framed() -> bool:
	var cam: Camera3D = ctx.player.camera if ctx.player != null else null
	if story.is_empty() or cam == null or not cam.is_inside_tree():
		return false
	var at := _subject(story)
	if cam.global_position.distance_to(at) > PHOTO_RANGE or cam.is_position_behind(at):
		return false
	return DESK.framed(cam.unproject_position(at), cam.get_viewport().get_visible_rect().size)


## The shutter (a click in photo mode on an assignment): a sharp shot when the hero stands at the
## scene and the camera holds it inside the marks. True for a sharp shot.
func snap() -> bool:
	if story.is_empty() or ctx.player == null or not ctx.player.photo_mode:
		return false
	var near := at_scene()
	var sharp := near and scene_framed()
	var note := "Missed it: hold the scene inside the marks."
	if sharp:
		var again := bool(story["sharp"])
		note = "Another sharp one." if again else "Sharp shot. It runs with the story."
		story["sharp"] = true
	elif not near:
		note = "Too far from the scene for a press photo."
	if finder != null:
		finder.flash()
		finder.note(note, sharp)
	Analytics.track("press_photo", {"sharp": sharp})
	_refresh()
	return sharp


## Opens the mayors' league (L). False when it may not open now: no HUD, a modal open, paused, in
## photo mode or talking.
func open_league() -> bool:
	if league_open or league == null or ctx.player == null or ctx.is_modal():
		return false
	if (ctx.mode != null and ctx.mode.paused) or ctx.player.photo_mode:
		return false
	if ctx.player.in_conversation():
		return false
	league_open = true
	ctx.push_modal(MODAL)
	_fill_league()
	league.visible = true
	Analytics.track("league_open", {"leads": leads.size(), "filed": filed})
	_sync()
	return true


func close_league() -> void:
	if not league_open:
		return
	league_open = false
	if ctx != null:
		ctx.pop_modal(MODAL)
	if league != null:
		league.visible = false
	_sync()


func _process(delta: float) -> void:
	if ctx == null or ctx.sim == null:
		return
	_t -= delta
	if _t <= 0.0:
		_refresh()
	if finder != null and finder.visible:
		_aim()


## K, L and in photo mode the shutter come as events. K and L wait while a modal is open (the
## league itself closes on L or Esc); the shutter fires only on an assignment.
func _unhandled_input(event: InputEvent) -> void:
	if ctx == null or ctx.player == null:
		return
	var used := false
	if _shutter(event):
		used = ctx.player.photo_mode and not story.is_empty() and _live()
		if used:
			snap()
	elif event.is_echo():
		return
	elif league_open:
		used = event.is_action_pressed("press_league") or event.is_action_pressed("pause_menu")
		if used:
			close_league()
	elif event.is_action_pressed("press_league"):
		used = open_league()
	elif event.is_action_pressed("press_story") and _may_press():
		press_story()
		used = true
	if used and is_inside_tree():
		get_viewport().set_input_as_handled()


## Whether event fires the shutter: the strike button going down, or its trigger crossing the dead
## zone (every motion event past it reads as pressed, so _trigger holds the trigger's state).
func _shutter(event: InputEvent) -> bool:
	if event is InputEventJoypadMotion:
		var held := event.is_action_pressed("act_strike")
		var fired := held and not _trigger
		if event.is_action("act_strike"):
			_trigger = held
		return fired
	return event.is_action_pressed("act_strike") and not event.is_echo()


## Player input counts while it is enabled and, in a window, the mouse is captured (the click that
## captures it takes no photo).
func _live() -> bool:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	return ctx.player.input_enabled and (captured or DisplayServer.get_name() == "headless")


## K counts on foot or at the wheel, with nothing modal open, not paused and not in photo mode.
func _may_press() -> bool:
	if ctx.is_modal() or (ctx.mode != null and ctx.mode.paused):
		return false
	return not ctx.player.photo_mode


# ------------------------------------------------------------------ leads


func _on_mayor(mi: int, entry: Dictionary) -> void:
	_add(DESK.mayor_lead(mi, entry))


func _on_council(r: Dictionary) -> void:
	_add(DESK.council_lead(r, _hall()))


func _on_chaos(d: Dictionary) -> void:
	_add(DESK.chaos_lead(d))


## A new lead, newest first; the first one ever comes with a tip.
func _add(lead: Dictionary) -> void:
	if lead.is_empty() or ctx.sim == null:
		return
	leads.push_front(_dated(lead))
	if leads.size() > MAX_LEADS:
		leads.resize(MAX_LEADS)
	if not _tipped:
		_tipped = true
		_toast("A lead for the Gazette: %s. Press K to chase it." % lead["headline"], "info")
	_refresh()


## Dates and places a lead; a council or Chaos Director lead takes its tile's district.
func _dated(lead: Dictionary) -> Dictionary:
	var t: Vector2i = lead["tile"]
	var i := D.idx(t.x, t.y)
	if int(lead["district"]) < 0 and ctx.sim != null and i < ctx.sim.district.size():
		lead["district"] = ctx.sim.district[i]
	lead["at"] = _now()
	lead["place"] = _place(i)
	return lead


## A reply face to face at the scene is the story's quote, unless the story already has a local
## voice and this one is not.
func _on_reply(resident_id: String, speaker: String, reply: String) -> void:
	if story.is_empty() or not at_scene():
		return
	var q := DESK.clip(reply)
	if q.length() < QUOTE_MIN:
		return
	var local := false
	var by := DESK.passerby(speaker)
	if not resident_id.is_empty():
		by = speaker if not speaker.strip_edges().is_empty() else by
		local = _lives_in(resident_id, int(story["district"]))
	if bool(story["local"]) and not local:
		return
	var first := str(story["quote"]).is_empty()
	story.merge({"quote": q, "by": by, "quote_id": resident_id, "local": local, "seen": true}, true)
	if first:
		_toast("Quote noted from %s. Press K to file, or take a photo first (P)." % by, "success")
	_refresh()


func _lives_in(resident_id: String, district: int) -> bool:
	var r: Dictionary = ctx.residents.find(resident_id) if ctx.residents != null else {}
	if r.is_empty() or ctx.sim == null:
		return false
	var home := int(r.get("home", -1))
	return home >= 0 and home < ctx.sim.district.size() and ctx.sim.district[home] == district


## Every REFRESH: leads and the story go cold, the scene is reached, and the card, the league and
## what shows follow.
func _refresh() -> void:
	_t = REFRESH
	if ctx == null or ctx.sim == null:
		return
	var now := _now()
	for k in range(leads.size() - 1, -1, -1):
		if now - float(leads[k]["at"]) > LEAD_DAYS:
			leads.remove_at(k)
	if not story.is_empty() and now - float(story["at"]) > LEAD_DAYS:
		_toast("The story went cold: %s." % story["headline"], "info")
		_clear_story()
	if not story.is_empty() and not bool(story["seen"]) and at_scene():
		story["seen"] = true
		_toast("You are at the scene. Talk to someone here for a quote.", "info")
	if card != null:
		card.show_state(_card_state())
	if league_open:
		_fill_league()
	_sync()


## Drops the story on assignment and the waypoint set for it, while it is still the one on the map.
func _clear_story() -> void:
	if not story.is_empty() and ctx.hud != null:
		var wp: Variant = ctx.hud.waypoint()
		var mine: Vector3 = story.get("wp", NO_POINT)
		if wp is Vector3 and Vector2(wp.x - mine.x, wp.z - mine.z).length() < 0.01:
			ctx.hud.clear_waypoint()
	story = {}


func _drop_all() -> void:
	close_league()
	leads.clear()
	_clear_story()
	_refresh()


## The resident quoted remembers it.
func _credit(s: Dictionary) -> void:
	var id := str(s.get("quote_id", ""))
	if id.is_empty() or ctx.residents == null:
		return
	var r := ctx.residents.find(id)
	if not r.is_empty():
		ctx.residents.remember(r, "was quoted in the Gazette: %s" % s["headline"])


func _announce(out: Dictionary, was: String) -> void:
	var bonus := DESK.bonus_words(out)
	var extra := " (%s)" % bonus if not bonus.is_empty() else ""
	_toast("Story filed: +%d%s. The Gazette runs it now." % [int(out["points"]), extra], "success")
	var now := str(DESK.rank_of(points)["name"])
	if now != was:
		_toast("Promoted: you are a %s now." % now.to_lower(), "success")


# ------------------------------------------------------------------ card, viewfinder, league


func _build_ui() -> void:
	card = CARD.new()
	card.setup()
	card.visible = false
	ctx.hud.slot("center").add_child(card)
	finder = FINDER.new()
	finder.setup()
	ctx.hud.slot("overlay").add_child(finder)
	league = LEAGUE.new()
	league.setup()
	league.visible = false
	league.chase_requested.connect(_on_chase)
	ctx.hud.slot("overlay").add_child(league)


## What the card shows: the story on assignment, else the newest lead; {} with neither.
func _card_state() -> Dictionary:
	var lead: Dictionary = story
	if lead.is_empty() and not leads.is_empty():
		lead = leads[0]
	if lead.is_empty():
		return {}
	var rank := DESK.rank_of(points)
	var st := {"rank": "%s · %s" % [rank["name"], S.fmt(points)], "headline": lead["headline"]}
	st["color"] = DESK.color_of(str(lead["agent"]))
	st["where"] = _where(lead)
	if story.is_empty():
		var more := leads.size() - 1
		st["kicker"] = "New lead"
		st["hint"] = "Take lead" + (" · L: %d more" % more if more > 0 else "")
		return st
	var quoted := not str(story["quote"]).is_empty()
	st["kicker"] = "Ready to file" if quoted else "On assignment"
	st["quote"] = "“%s”" % story["quote"] if quoted else ""
	st["steps"] = _steps()
	st["hint"] = "File story" if quoted else ""
	return st


## The story's checklist for the card: [text, done] pairs. Once quoted the scene row goes (a
## quote is only taken there), which keeps the card clear of the AI feed above it.
func _steps() -> Array:
	var seen := bool(story["seen"])
	var quoted := not str(story["quote"]).is_empty()
	var sharp := bool(story["sharp"])
	var out := [] if quoted else [["At the scene" if seen else "Get to the scene", seen]]
	out.append(["Quote from %s" % story["by"] if quoted else "A quote from someone there", quoted])
	out.append(["Sharp photo" if sharp else "Photo (optional): P, then click", sharp])
	return out


## "214 Maple Street · 240 m · scoop 4:10": where, how far, and while it lasts the scoop clock.
func _where(lead: Dictionary) -> String:
	var t: Vector2i = lead["tile"]
	var me := ctx.player_position()
	var d := Vector2(t.x - me.x, t.y - me.z).length()
	var parts := PackedStringArray([str(lead["place"])])
	parts.append("at the scene" if d <= SCENE else S.distance(d))
	var left := SCOOP_DAYS - (_now() - float(lead["at"]))
	if left > 0.0:
		parts.append("scoop " + S.countdown(left * ctx.sim.day_seconds, ctx.sim.speed))
	return " · ".join(parts)


## The card shows while there is a lead or a story and nothing covers its corner (a modal, the
## phone); the viewfinder in photo mode on an assignment. Also runs on bus.modal_changed and when
## photo mode changes.
func _sync() -> void:
	if card != null:
		var phone := ctx.feature("phone")
		var covered := ctx.is_modal() or (phone != null and bool(phone.get("open")))
		card.visible = not (story.is_empty() and leads.is_empty()) and not covered
	if finder != null:
		finder.visible = ctx.player != null and ctx.player.photo_mode and not story.is_empty()
		if finder.visible:
			_aim()


## The viewfinder follows the camera: green marks while the scene sits inside them.
func _aim() -> void:
	var near := at_scene()
	var framed := near and scene_framed()
	var hint := "Click to take the shot"
	if not near:
		hint = "Too far from the scene for a press photo"
	elif not framed:
		hint = "Hold the scene inside the marks"
	finder.show_state("Press photo · %s" % story["headline"], hint, framed)


func _fill_league() -> void:
	var rank := DESK.rank_of(points)
	var press := "%s · %s points · %d filed" % [rank["name"], S.fmt(points), filed]
	if int(rank["next"]) > 0:
		press += " · %s at %s" % [_next_rank(), S.fmt(int(rank["next"]))]
	var open: Array[String] = []
	for l: Dictionary in leads:
		open.append("%s · %s" % [l["headline"], l["place"]])
	var day := "Day %d" % ctx.sim.day
	if ctx.sky != null:
		day += " · " + ctx.sky.clock_text()
	var desk := {"day": day, "press": press, "leads": open, "stories": stories}
	desk["assignment"] = str(story.get("headline", ""))
	league.show_league(DESK.standings(ctx.sim, ctx.residents), desk)


## The name of the rank after the player's.
func _next_rank() -> String:
	return str(DESK.rank_of(int(DESK.rank_of(points)["next"]))["name"])


func _on_chase(k: int) -> void:
	close_league()
	take_lead(k)


func _on_photo(on: bool) -> void:
	_anchor = ctx.player.position if on else NO_POINT
	_trigger = false
	_sync()


func _on_modal(_active: bool) -> void:
	_sync()


func _on_pause(p: bool) -> void:
	if p:
		close_league()


# ------------------------------------------------------------------ places


## Sim time in days (day 3 at noon is 3.5).
func _now() -> float:
	return float(ctx.sim.day) + ctx.sim.day_progress() if ctx.sim != null else 0.0


func _hall() -> Vector2i:
	var i := ctx.sim.kind.find(D.HALL) if ctx.sim != null else -1
	return Vector2i(D.tx(i), D.ty(i)) if i >= 0 else HALL_AT


## The tile's place label ("214 Maple Street"), never coordinates.
func _place(i: int) -> String:
	var label := ctx.directory.place_label(i) if ctx.directory != null else ""
	return D.debrand(label) if not label.is_empty() else "the frontier"


## Where to stand to see the lead's tile: the overview feature's stand point (the far sidewalk
## across its street), else the tile itself. {"pos", "yaw"}.
func _stand(lead: Dictionary) -> Dictionary:
	var t: Vector2i = lead["tile"]
	var ov := ctx.feature("overview")
	if ov != null:
		return ov.call("stand_point", D.idx(t.x, t.y))
	return {"pos": Vector3(t.x, 0.0, t.y), "yaw": 0.0}


## The point a press photo of the lead must hold: SUBJECT_Y over the middle of its tile.
func _subject(lead: Dictionary) -> Vector3:
	var t: Vector2i = lead["tile"]
	var at := Vector3(t.x, 0.0, t.y)
	var g := ctx.collision.ground_height(at) if ctx.collision != null else NAN
	at.y = (0.0 if is_nan(g) else g) + SUBJECT_Y
	return at


func _toast(t: String, kind: String) -> void:
	if ctx.bus != null:
		ctx.bus.toast.emit(t, kind)


## A filed story as the press card keeps it: {"text", "points", "bonus", "day"}.
static func _kept(s: Dictionary) -> Dictionary:
	var out := {"text": str(s.get("text", "")), "points": int(s.get("points", 0))}
	out["bonus"] = str(s.get("bonus", DESK.bonus_words(s)))
	out["day"] = int(s.get("day", 0))
	return out


# ------------------------------------------------------------------ photo tour


## Three shots of a lead: its scene with the card on assignment, the press camera there with a
## sharp shot taken, and the league over the street at the spawn once the story is filed.
func photo_shots() -> Array:
	_photo = _photo_lead()
	if _photo.is_empty() or ctx.mode == null:
		return []
	var stand := _stand(_photo)
	var at := {"pos": stand["pos"], "yaw": float(stand["yaw"]), "pitch": -3.0, "hour": 10.5}
	var shots := []
	for e: Array in [["reporter_story", "_photo_story"], ["reporter_photo", "_photo_camera"]]:
		var s := at.duplicate()
		s.merge({"name": e[0], "prepare": e[1], "restore": "_photo_restore"})
		shots.append(s)
	var sp: Dictionary = ctx.mode.spawn_point()
	var lg := {"name": "reporter_league", "pos": sp["pos"], "yaw": float(sp["yaw"]), "pitch": 0.0}
	lg.merge({"hour": 10.5, "prepare": "_photo_league", "restore": "_photo_restore"})
	shots.append(lg)
	return shots


func _photo_story() -> void:
	_stage.call_deferred(false)


func _photo_camera() -> void:
	_stage.call_deferred(true)


func _photo_league() -> void:
	file_story()
	open_league()


func _photo_restore() -> void:
	close_league()
	if ctx.player != null and ctx.player.photo_mode:
		ctx.player.set_photo_mode(false)


## Once the tour has put the hero at the scene: the tour's lead on assignment with a passer-by's
## quote and, with camera, the press camera up and a sharp shot taken.
func _stage(camera: bool) -> void:
	for _k in range(PHOTO_FRAMES):
		await get_tree().process_frame
	if _photo.is_empty() or ctx == null or ctx.player == null:
		return
	if str(story.get("headline", "")) != str(_photo["headline"]):
		leads.push_front(_photo.duplicate())
		take_lead(0)
	_on_reply("", PHOTO_SPEAKER, PHOTO_QUOTE)
	if camera:
		ctx.player.set_photo_mode(true)
		_look_at(_subject(story))
		snap()
	_refresh()


## Turns the photo camera to hold point in the middle of the view.
func _look_at(point: Vector3) -> void:
	var p := ctx.player
	var d := point - p.camera.global_position if p.camera != null else Vector3.ZERO
	if d.length_squared() < 1e-8:
		return
	d = d.normalized()
	p.cam_yaw = atan2(-d.x, -d.z)
	p.cam_pitch = asin(clampf(d.y, -1.0, 1.0))
	p.update_view(0.0)


## The newest lead, else a council ruling at City Hall.
func _photo_lead() -> Dictionary:
	if ctx == null or ctx.sim == null:
		return {}
	if not leads.is_empty():
		return leads[0].duplicate()
	var lead := DESK.council_lead({"enacted": [D.ORDINANCES.keys()[0]]}, _hall())
	return _dated(lead) if not lead.is_empty() else {}
