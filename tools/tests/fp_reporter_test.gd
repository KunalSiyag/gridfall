extends SceneTree
## The Gazette's stringer (integration feature "reporter"; docs/fp/ARCHITECTURE.md, Reporter): the
## desk's rules (which AI decisions make a lead and how they read, quotes and bylines, the story's
## text, points and press ranks, what a photo frames, the mayors' league); leads from a mayor's
## turn, a council ruling and the Chaos Director; the card; taking a lead and its waypoint; the
## scene; quotes from the "Ask someone here" card and from a resident in the talk dialog (a local
## voice); the press camera (viewfinder, shutter, trigger); filing (points, ranks, the Gazette's
## chat line, the resident's memory, the player's own waypoint); leads and stories going cold; K
## and L; the league (table, press card, Chase); the save round trip; the photo tour's staging;
## teardown. Third person on a grown city with the HUD widgets and the chat. The sim's clock is
## stopped: the feature's own runs only through the test's _process calls.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const DESK := preload("res://scripts/fp/reporter/reporter_desk.gd")
const REPORTER := preload("res://scripts/fp/reporter/reporter_feature.gd")
const DT := 1.0 / 60.0
const QUOTE := "It is about time somebody did something about this corner."
const SHARP := "Sharp shot. It runs with the story."

var fails: Array[String] = []
var ctx: FpContext
var f: REPORTER
var chat: FpFeature
var talk: Control
## Every toast's text and every story_filed dict.
var toasts: Array[String] = []
var filed: Array[Dictionary] = []
## The fixture: a resident who lives in a mayor's district, their home tile and that district.
var neighbour: Dictionary = {}
var home := Vector2i.ZERO
var district: int = -1
var _coords := RegEx.create_from_string("\\(\\s*-?\\d+\\s*,\\s*-?\\d+\\s*\\)")


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	ctx.sim.set_process(false)
	K.make_feature(ctx, "hud_widgets")
	chat = K.make_feature(ctx, "chat")
	f = K.make_feature(ctx, "reporter") as REPORTER
	K.check(fails, f != null and chat != null, "the reporter and chat features are registered")
	if f == null or chat == null:
		K.finish(self, "FP_REPORTER_TEST", fails)
		return
	f.set_process(false)
	talk = chat.get("talk")
	ctx.bus.toast.connect(func(t: String, _kind: String) -> void: toasts.append(t))
	ctx.bus.story_filed.connect(func(s: Dictionary) -> void: filed.append(s))
	_check_inputs()
	_check_desk_leads()
	_check_desk_words()
	_check_desk_scores()
	_check_standings()
	_pick_neighbour()
	if not neighbour.is_empty():
		_check_leads()
		_check_card()
		_check_take()
		_check_scene()
		_check_quotes()
		_check_photo()
		_check_shutter_input()
		_check_file()
		_check_cold()
		_check_keys()
		_check_league_keys()
		_check_league()
		_check_save()
		await _check_photo_tour()
		_check_teardown()
	K.finish(self, "FP_REPORTER_TEST", fails)


# ------------------------------------------------------------------ the desk


func _check_inputs() -> void:
	var st := f.self_test()
	var detail := str(st.get("detail", ""))
	K.check(fails, bool(st.get("ok", false)), "self_test: inputs and UI in place (%s)" % detail)
	K.check(fails, detail == "0 leads, 0 filed, Stringer", "a stringer with nothing on to start")
	var keys := [str(_keys("press_story")), str(_keys("press_league"))]
	var keys_ok := keys == [str([KEY_K]), str([KEY_L])]
	K.check(fails, keys_ok, "K takes a lead and files it, L opens the league (%s)" % str(keys))
	var clash: Array[String] = []
	for a: StringName in InputMap.get_actions():
		if str(a).begins_with("ui_") or REPORTER.INPUTS.has(str(a)):
			continue
		var ks := _keys(a)
		if ks.has(KEY_K) or ks.has(KEY_L):
			clash.append(str(a))
	K.check(fails, clash.is_empty(), "no other action takes K or L (%s)" % str(clash))


func _check_desk_leads() -> void:
	var at := Vector2i(3, 7)
	var police := {"type": "build", "building": "police", "x": 3, "y": 7}
	var hospital := {"type": "build", "building": "hospital", "x": 3, "y": 7}
	var turn := {
		"focus": at, "actions": [{"ok": false, "action": hospital}, {"ok": true, "action": police}]
	}
	var lead := DESK.mayor_lead(1, turn)
	var want := {
		"agent": "1", "headline": "Viktor Han ordered a Police Station", "tile": at, "district": 1
	}
	K.check(fails, lead == want, "a mayor's lead: the first order carried out (%s)" % str(lead))
	var none := [
		DESK.mayor_lead(1, {"actions": turn["actions"]}),
		DESK.mayor_lead(7, turn),
		DESK.mayor_lead(1, {"focus": Vector2i(500, 500)}),
	]
	K.check(fails, none == [{}, {}, {}], "none without a focus, a real mayor or a place on the map")
	var tax := {"ok": true, "action": {"type": "tax", "rate": 9}}
	var vague := str(DESK.mayor_lead(0, {"focus": at, "actions": [tax]}).get("headline", ""))
	K.check(
		fails, vague == "Ada Okafor made a decision here", "an order without a place (%s)" % vague
	)
	var hall := Vector2i(15, 14)
	var passed := DESK.council_lead({"enacted": ["recycling"]}, hall)
	var ruling := {"agent": "council", "headline": "The council passed the Recycling Program"}
	ruling.merge({"tile": hall, "district": -1})
	K.check(fails, passed == ruling, "a council ruling is a lead at City Hall (%s)" % str(passed))
	var repeal := DESK.council_lead({"enacted": ["bogus"], "repealed": ["curfew"]}, hall)
	var rep := str(repeal.get("headline", ""))
	K.check(fails, rep == "The council repealed the Youth Curfew", "a repeal too (%s)" % rep)
	var idle := DESK.council_lead({"enacted": [], "repealed": []}, hall)
	K.check(fails, idle.is_empty(), "a ruling that changes nothing is none")
	var fire := DESK.chaos_lead({"trigger": true, "type": "fire", "x": 4, "y": 9})
	var strike := {"agent": "chaos", "headline": "Building Fire reported", "tile": Vector2i(4, 9)}
	strike["district"] = -1
	K.check(
		fails, fire == strike, "a Chaos Director strike is a lead where it struck (%s)" % str(fire)
	)
	var calm := DESK.chaos_lead({"trigger": false, "type": "fire", "x": 4, "y": 9})
	var nowhere := DESK.chaos_lead({"trigger": true, "type": "smog"})
	K.check(
		fails, calm.is_empty() and nowhere.is_empty(), "a calm day or a strike with no place: none"
	)


func _check_desk_words() -> void:
	var orders := [
		{"type": "build", "building": "airport"},
		{"type": "zone", "zone": "c"},
		{"type": "zone", "zone": "Industrial"},
		{"type": "road"},
		{"type": "bulldoze"},
		{"type": "emergency"},
		{"type": "annex"},
		{"type": "ordinance"},
	]
	var deeds := orders.map(func(a: Dictionary) -> String: return DESK.deed(a))
	var want := [
		"ordered an Airport",
		"zoned new shops",
		"zoned new industry",
		"laid a new road",
		"cleared a block",
		"sent in emergency crews",
		"annexed new land",
		"made a decision here",
	]
	K.check(fails, deeds == want, "each kind of order reads plainly (%s)" % str(deeds))
	var agents := ["1", "chaos", "council", "9"]
	var colors := agents.map(func(a: String) -> Color: return DESK.color_of(a))
	var hexes := [Color("#00F0FF"), Color("#FF7A59"), Color("#C9B6FF"), Color("#FFD27F")]
	K.check(fails, colors == hexes, "a lead wears the deciding agent's colour, else the Gazette's")
	var long := DESK.clip("We waited years for this and nobody asked us first. ".repeat(5))
	var cut := long.length() <= DESK.QUOTE_CHARS and long.ends_with("…") and not long.contains(" …")
	K.check(
		fails, cut, "a long reply is cut at a word, with an ellipsis (%d chars)" % long.length()
	)
	var clean := DESK.clip("  Ask DeepSeek-V4 about it.\nReally.  ")
	K.check(
		fails, clean == "Ask Viktor Han about it. Really.", "de-branded, on one line (%s)" % clean
	)
	var speakers := ["Shopkeeper", "officer", "Police officer", "Mara Ellis", " "]
	var bylines := speakers.map(func(s: String) -> String: return DESK.passerby(s))
	var want_by := [
		"a shopkeeper", "an officer", "a police officer", "Mara Ellis", "someone nearby"
	]
	K.check(fails, bylines == want_by, "a passer-by's byline (%s)" % str(bylines))
	var s := {"place": "214 Maple Street", "headline": "Viktor Han ordered a Police Station"}
	var texts := [DESK.story_text(s)]
	s.merge({"quote": "About time.", "by": "Ana Ruiz"})
	texts.append(DESK.story_text(s))
	s.merge({"quote": "What a mess!", "by": ""}, true)
	texts.append(DESK.story_text(s))
	var lede := "From 214 Maple Street: Viktor Han ordered a Police Station."
	var runs := [
		lede, lede + " “About time,” says Ana Ruiz.", lede + " “What a mess!” says someone nearby."
	]
	K.check(fails, texts == runs, "the story as the Gazette runs it (%s)" % str(texts))


func _check_desk_scores() -> void:
	var pts := [
		DESK.points_for(false, false, false),
		DESK.points_for(true, false, false),
		DESK.points_for(false, true, true),
		DESK.points_for(true, true, true),
	]
	var pts_msg := "100 a story, +50 a scoop, +25 a local voice, +25 a sharp shot (%s)"
	K.check(fails, pts == [100, 150, 150, 200], pts_msg % str(pts))
	var words := [
		DESK.bonus_words({"scoop": true, "sharp": true}), DESK.bonus_words({"local": false})
	]
	K.check(fails, words == ["scoop, sharp shot", ""], "the bonuses in words (%s)" % str(words))
	var ranks: Array[String] = []
	for p: int in [0, 299, 300, 999, 1000, 2500, 9000]:
		var r := DESK.rank_of(p)
		ranks.append("%s/%d" % [r["name"], int(r["next"])])
	var want := [
		"Stringer/300",
		"Stringer/300",
		"Reporter/1000",
		"Reporter/1000",
		"Senior reporter/2500",
		"Star reporter/-1",
		"Star reporter/-1",
	]
	K.check(
		fails, str(ranks) == str(want), "press ranks and the points to the next (%s)" % str(ranks)
	)
	var view := Vector2(1000, 600)
	var inside := [DESK.framed(Vector2(500, 300), view), DESK.framed(Vector2(200, 120), view)]
	var outside := [DESK.framed(Vector2(100, 300), view), DESK.framed(Vector2(500, 560), view)]
	var framing := inside == [true, true] and outside == [false, false]
	K.check(fails, framing, "a photo frames what sits in the middle 65% of the view")


func _check_standings() -> void:
	var rows := DESK.standings(ctx.sim, ctx.residents)
	var n := rows.size()
	K.check(fails, n == D.MAYORS.size(), "the league ranks all five mayors (%d)" % n)
	var named := 0
	var scored := 0
	var ordered := 0
	var biggest: Dictionary = {}
	for k in range(n):
		var r: Dictionary = rows[k]
		var mi := int(r["mi"])
		var who := [str(r["who"]), str(r["model"]), str(r["district"])]
		var real := [D.mayor_display(mi), str(D.MAYORS[mi]["name"]), str(D.MAYORS[mi]["district"])]
		named += int(who == real)
		scored += int(_within(float(r["score"]), 100.0) and _within(float(r["approval"]), 10.0))
		ordered += int(k == 0 or int(rows[k - 1]["score"]) >= int(r["score"]))
		if biggest.is_empty() or int(r["pop"]) > int(biggest["pop"]):
			biggest = r
	K.check(fails, named == n, "each row names the mayor, the model they run on and their district")
	K.check(fails, scored == n, "approval out of 10, a score out of 100")
	var scores := rows.map(func(r: Dictionary) -> int: return int(r["score"]))
	K.check(fails, ordered == n, "best first (%s)" % str(scores))
	var top := biggest.is_empty() or int(biggest["pop"]) == 0 or int(biggest["score"]) >= 25
	K.check(
		fails, top, "the most people earn the full 25 for people (%s)" % str(biggest.get("score"))
	)
	K.check(fails, DESK.standings(null, null).is_empty(), "no city, no league")


## The fixture: a resident who lives in one of the mayors' districts.
func _pick_neighbour() -> void:
	for r: Dictionary in ctx.residents.people:
		var h := int(r["home"])
		var d := int(ctx.sim.district[h])
		if d >= 0 and d < D.MAYORS.size():
			neighbour = r
			home = Vector2i(D.tx(h), D.ty(h))
			district = d
			break
	var msg := "fixture: a resident lives in a mayor's district (%d people)"
	K.check(fails, not neighbour.is_empty(), msg % ctx.residents.people.size())


# ------------------------------------------------------------------ leads and the story


func _check_leads() -> void:
	K.check(fails, f.leads.is_empty() and not f.card.visible, "no lead yet, no card")
	toasts.clear()
	f.press_story()
	var none := f.story.is_empty() and _count(toasts, "No leads yet") == 1
	K.check(fails, none, "K with no lead says how leads come (%s)" % str(toasts))
	toasts.clear()
	ctx.brain.council_ruled.emit({"enacted": ["recycling"], "repealed": [], "statement": ""})
	var hall_i := ctx.sim.kind.find(D.HALL)
	var hall := Vector2i(D.tx(hall_i), D.ty(hall_i)) if hall_i >= 0 else REPORTER.HALL_AT
	var first: Dictionary = f.leads[0] if f.leads.size() == 1 else {}
	var at_hall: bool = first.get("tile") == hall and str(first.get("agent", "")) == "council"
	K.check(
		fails, at_hall, "a council ruling brings a lead at City Hall (%s)" % str(first.get("tile"))
	)
	var hall_d := int(ctx.sim.district[D.idx(hall.x, hall.y)])
	var in_d := int(first.get("district", -9)) == hall_d
	K.check(fails, in_d, "in the district City Hall stands in (%d)" % hall_d)
	var tip := _count(toasts, "A lead for the Gazette") == 1 and _count(toasts, "Press K") == 1
	K.check(fails, tip, "the first lead comes with a tip: press K (%s)" % str(toasts))
	var c := home + Vector2i(2, 0)
	ctx.brain.chaos_decided.emit({"trigger": true, "type": "fire", "x": c.x, "y": c.y})
	var chaos_d := int(ctx.sim.district[D.idx(c.x, c.y)])
	var struck := int(f.leads[0]["district"]) == chaos_d
	K.check(fails, struck, "a strike takes its tile's district (%d)" % chaos_d)
	var n := f.leads.size()
	ctx.brain.chaos_decided.emit({"trigger": false})
	ctx.brain.council_ruled.emit({"enacted": [], "repealed": []})
	ctx.brain.mayor_decided.emit(district, {"focus": D.NO_TILE, "actions": []})
	var same := f.leads.size() == n
	K.check(fails, same, "a calm day, an empty ruling or a turn without a place bring none")
	var o1 := (district + 1) % D.MAYORS.size()
	var o2 := (district + 2) % D.MAYORS.size()
	_mayor(o1, home + Vector2i(0, 2), {"type": "zone", "zone": "C", "x": home.x, "y": home.y + 2})
	_mayor(o2, home + Vector2i(-2, 0), {"type": "road", "x": home.x - 2, "y": home.y})
	_mayor(district, home, {"type": "build", "building": "police", "x": home.x, "y": home.y})
	var heads := f.leads.map(func(l: Dictionary) -> String: return str(l["headline"]))
	var want := [
		"%s ordered a Police Station" % D.mayor_display(district),
		"%s laid a new road" % D.mayor_display(o2),
		"%s zoned new shops" % D.mayor_display(o1),
		"Building Fire reported",
	]
	K.check(fails, heads == want, "at most four open leads, newest first (%s)" % str(heads))
	var lead: Dictionary = f.leads[0]
	var place := D.debrand(ctx.directory.place_label(D.idx(home.x, home.y)))
	var named := str(lead["place"]) == place and _coords.search(place) == null
	K.check(fails, named, "a lead names its place, never coordinates (%s)" % place)
	var dated := int(lead["district"]) == district and absf(float(lead["at"]) - _now()) < 1e-6
	K.check(fails, dated, "with the deciding mayor's district and when it happened")
	K.check(fails, _count(toasts, "A lead for the Gazette") == 1, "the tip comes once")


func _check_card() -> void:
	K.check(fails, f.card.visible, "a lead brings up the card")
	var t := f.card.card_text()
	var parts := ["New lead", "Stringer · 0", str(f.leads[0]["headline"]), "scoop "]
	parts.append("K Take lead · L: 3 more")
	K.check(
		fails, _has_all(t, parts), "the card: the newest lead, the scoop clock, the key (%s)" % t
	)
	ctx.push_modal(&"test")
	var covered := not f.card.visible
	ctx.pop_modal(&"test")
	K.check(fails, covered and f.card.visible, "a modal covers it, then it comes back")


func _check_take() -> void:
	ctx.player.teleport(_away(home, 8), 0.0)
	toasts.clear()
	var bad := not f.take_lead(9) and f.story.is_empty() and toasts.is_empty()
	K.check(fails, bad, "no such lead: nothing taken, nothing said (%s)" % str(toasts))
	var lead: Dictionary = f.leads[0].duplicate()
	var taken := f.take_lead(0)
	var on := str(f.story.get("headline", "")) == str(lead["headline"])
	K.check(
		fails, taken and on and f.leads.size() == 3, "take_lead(0) puts the newest on assignment"
	)
	var fresh := not bool(f.story["seen"]) and str(f.story["quote"]).is_empty()
	K.check(fails, fresh, "far from the scene, with no quote yet")
	var wp: Variant = ctx.hud.waypoint()
	var to_tile := wp is Vector3 and _flat(wp, Vector3(home.x, 0.0, home.y)) < 0.01
	K.check(fails, to_tile, "a waypoint leads to the scene (%s)" % str(wp))
	var told := "On assignment: %s. Get a quote at %s." % [lead["headline"], lead["place"]]
	K.check(fails, _count(toasts, told) == 1, "a toast says what and where (%s)" % str(toasts))
	var t := f.card.card_text()
	var steps := ["On assignment", "[ ] Get to the scene", "[ ] A quote from someone there"]
	steps.append("[ ] Photo (optional): P, then click")
	var card_ok := _has_all(t, steps) and not t.contains("· K ")
	K.check(fails, card_ok, "the card: on assignment, what it needs, no key yet (%s)" % t)
	toasts.clear()
	f.press_story()
	var go := _count(toasts, "get to %s for a quote" % lead["place"]) == 1
	K.check(fails, f.filed == 0 and go, "K far from the scene says where to go (%s)" % str(toasts))
	K.check(fails, f.file_story().is_empty(), "nothing to file without a quote")


func _check_scene() -> void:
	toasts.clear()
	ctx.bus.talk_replied.emit("", "Shopkeeper", QUOTE)
	K.check(fails, str(f.story["quote"]).is_empty(), "a reply far from the scene is no quote")
	_stand_by(home)
	f._process(REPORTER.REFRESH + 0.01)
	K.check(
		fails, bool(f.story["seen"]) and f.at_scene(), "1.5 tiles from it the hero is at the scene"
	)
	K.check(fails, _count(toasts, "You are at the scene") == 1, "and is told so (%s)" % str(toasts))
	var t := f.card.card_text()
	K.check(
		fails, _has_all(t, ["[x] At the scene", "at the scene"]), "the card ticks it off (%s)" % t
	)
	toasts.clear()
	f.press_story()
	var ask := _count(toasts, "talk to someone here for a quote") == 1
	K.check(
		fails, f.filed == 0 and ask, "K there without a quote: talk to someone (%s)" % str(toasts)
	)


func _check_quotes() -> void:
	var place := str(f.story["place"])
	toasts.clear()
	ctx.bus.talk_replied.emit("", "Shopkeeper", "Hm.")
	K.check(fails, str(f.story["quote"]).is_empty(), "a reply too short to quote is none")
	talk.call("open_ask", place)
	talk.call("set_ask_answer", "Shopkeeper", place, QUOTE)
	talk.call("end")
	var asked := [str(f.story["quote"]), str(f.story["by"]), bool(f.story["local"])]
	var asked_ok := asked == [QUOTE, "a shopkeeper", false]
	K.check(fails, asked_ok, "the ask card's answer is the quote (%s)" % str(asked))
	K.check(fails, _count(toasts, "Quote noted from a shopkeeper") == 1, "a toast notes it")
	ctx.bus.talk_replied.emit("r_nobody", "Sam Doe", "Nobody round here saw this one coming.")
	var other := [str(f.story["by"]), bool(f.story["local"]), _count(toasts, "Quote noted")]
	var other_ok := other == ["Sam Doe", false, 1]
	K.check(fails, other_ok, "someone else's newer reply replaces it, quietly (%s)" % str(other))
	var id := str(neighbour["id"])
	ctx.bus.talk_requested.emit(id)
	talk.call("say", "What do you think of the mayor?")
	if bool(talk.get("waiting")):
		_pump(9.0)
	var reply := str(talk.call("shown_text"))
	talk.call("end")
	var by := str(f.story["by"])
	var voice := [
		str(f.story["quote_id"]) == id, bool(f.story["local"]), by == str(neighbour["name"])
	]
	var voice_msg := "the neighbour's reply in the talk dialog is a local voice (%s: %s)"
	K.check(fails, voice == [true, true, true], voice_msg % [by, f.story["quote"]])
	K.check(fails, str(f.story["quote"]) == DESK.clip(reply), "quoted as said (%s)" % reply)
	ctx.bus.talk_replied.emit("", "Officer", "Another passer-by with a view on all of this.")
	var kept := str(f.story["quote_id"]) == id
	K.check(fails, kept, "a passer-by after a local voice does not replace it")
	var t := f.card.card_text()
	var ready := [
		"Ready to file", "“%s”" % f.story["quote"], "[x] Quote from " + by, "K File story"
	]
	var ready_ok := _has_all(t, ready) and not t.contains("At the scene")
	K.check(fails, ready_ok, "the card: ready to file, the quote, K files, no scene row (%s)" % t)


func _check_photo() -> void:
	var p := ctx.player
	var finder := f.finder
	K.check(
		fails, not f.snap() and not finder.visible, "no shutter or viewfinder out of photo mode"
	)
	p.set_photo_mode(true)
	K.check(fails, finder.visible, "photo mode on an assignment brings up the viewfinder")
	_aim_at(_subject(home))
	f._process(DT)
	var framed := [f.scene_framed(), finder.framed, finder.hint_text()]
	var framed_msg := "the scene inside the marks turns them green (%s)"
	K.check(fails, framed == [true, true, "Click to take the shot"], framed_msg % str(framed))
	var sharp := f.snap()
	K.check(fails, sharp and bool(f.story["sharp"]), "the shutter takes a sharp shot")
	K.check(fails, finder.note_text() == SHARP, "and says so (%s)" % finder.note_text())
	p.cam_yaw = wrapf(p.cam_yaw + PI, -PI, PI)
	p.update_view(0.0)
	f._process(DT)
	var away := [f.scene_framed(), finder.framed, finder.hint_text()]
	var away_msg := "looking away the marks stay white (%s)"
	K.check(fails, away == [false, false, "Hold the scene inside the marks"], away_msg % str(away))
	var missed := not f.snap() and bool(f.story["sharp"])
	var miss_note := finder.note_text() == "Missed it: hold the scene inside the marks."
	K.check(fails, missed and miss_note, "a miss keeps the sharp shot (%s)" % finder.note_text())
	p.teleport(_away(home, 8), 0.0)
	K.check(fails, not p.photo_mode and not finder.visible, "a teleport ends photo mode")
	p.set_photo_mode(true)
	var far := not f.snap() and finder.note_text() == "Too far from the scene for a press photo."
	f._process(DT)
	var far_hint := finder.hint_text() == "Too far from the scene for a press photo"
	K.check(
		fails, far and far_hint, "too far from the scene, no press photo (%s)" % finder.hint_text()
	)
	p.set_photo_mode(false)
	_stand_by(home)


func _check_shutter_input() -> void:
	var p := ctx.player
	p.set_photo_mode(true)
	_aim_at(_subject(home))
	f.story["sharp"] = false
	_send(K.action_event("act_strike"))
	var input_off := not bool(f.story["sharp"])
	p.input_enabled = true
	_send(K.action_event("act_strike"))
	var clicked := bool(f.story["sharp"]) and f.finder.note_text() == SHARP
	_send(K.action_event("act_strike"))
	var again := f.finder.note_text() == "Another sharp one."
	var click_msg := "a click takes the shot (not with input off) and a second says so (%s)"
	var clicks := [input_off, clicked, again]
	K.check(fails, clicks == [true, true, true], click_msg % str(clicks))
	var shots := 0
	for v: float in [0.9, 1.0, 0.1, 0.8]:
		f.story["sharp"] = false
		_send(K.trigger_event(v))
		shots += int(bool(f.story["sharp"]))
	K.check(fails, shots == 2, "the right trigger fires once per pull (%d)" % shots)
	p.set_photo_mode(false)
	f.story["sharp"] = false
	_send(K.action_event("act_strike"))
	K.check(fails, not bool(f.story["sharp"]), "out of photo mode a click takes nothing")
	f.story["sharp"] = true
	p.input_enabled = false


func _check_file() -> void:
	var s: Dictionary = f.story.duplicate()
	var mine := _away(home, 5)
	ctx.hud.set_waypoint(mine)
	toasts.clear()
	filed.clear()
	f.press_story()
	K.check(fails, filed.size() == 1 and f.story.is_empty(), "K files the story")
	var out: Dictionary = filed[0] if not filed.is_empty() else {}
	var text := str(out.get("text", ""))
	var lede := "From %s: %s." % [s["place"], s["headline"]]
	var reads := text.begins_with(lede) and text.ends_with("says %s." % neighbour["name"])
	K.check(fails, reads, "it reads: where, what happened, the quote, who said it (%s)" % text)
	var bonus := [int(out.get("points", 0)), out.get("scoop"), out.get("local"), out.get("sharp")]
	var bonus_msg := "a scoop with a local voice and a sharp shot earns 200 (%s)"
	K.check(fails, bonus == [200, true, true, true], bonus_msg % str(bonus))
	var refs := [int(out.get("tile", -1)), int(out.get("district", -9)), int(out.get("day", -1))]
	var refs_ok := refs == [D.idx(home.x, home.y), district, ctx.sim.day]
	K.check(
		fails, refs_ok, "story_filed carries the tile, the district and the day (%s)" % str(refs)
	)
	K.check(fails, f.points == 200 and f.filed == 1, "the press card counts it (%d)" % f.points)
	var kept: Dictionary = f.stories[0] if not f.stories.is_empty() else {}
	var listed := [str(kept.get("bonus", "")), str(kept.get("text", "")) == text]
	K.check(fails, listed == ["scoop, local voice, sharp shot", true], "the latest stories keep it")
	var scored := _count(toasts, "Story filed: +200 (scoop, local voice, sharp shot)") == 1
	var no_rank := _count(toasts, "Promoted") == 0
	K.check(fails, scored and no_rank, "a toast scores it; 200 is no promotion (%s)" % str(toasts))
	var wp: Variant = ctx.hud.waypoint()
	K.check(fails, wp is Vector3 and _flat(wp, mine) < 0.01, "the player's own waypoint stays")
	var mem: Array = neighbour.get("memory", [])
	var last := str(mem[-1]) if not mem.is_empty() else ""
	var quoted := last.ends_with("was quoted in the Gazette: " + str(s["headline"]))
	K.check(fails, quoted, "the neighbour remembers being quoted (%s)" % last)
	var line := _gazette_line(str(s["headline"]))
	var refs_line: Dictionary = line.get("refs", {})
	var shown := [
		str(line.get("role", "")), str(line.get("kind", "")), int(refs_line.get("tile", -1))
	]
	var shown_ok := shown == ["press", "headline", D.idx(home.x, home.y)]
	K.check(fails, shown_ok, "the Gazette runs it in the chat (%s)" % str(line.get("text", "")))
	K.check(fails, f.file_story().is_empty() and filed.size() == 1, "nothing left to file")
	ctx.hud.clear_waypoint()


func _check_cold() -> void:
	var n := f.leads.size()
	f.leads[n - 1]["at"] = _now() - REPORTER.LEAD_DAYS - 0.1
	f._refresh()
	var gone := f.leads.size() == n - 1
	K.check(
		fails, gone, "a lead goes cold a day after it happened (%d -> %d)" % [n, f.leads.size()]
	)
	ctx.player.teleport(_away(home, 8), 0.0)
	f.take_lead(0)
	var head := str(f.story["headline"])
	f.story["at"] = _now() - REPORTER.LEAD_DAYS - 0.1
	toasts.clear()
	f._refresh()
	var cold := f.story.is_empty() and _count(toasts, "The story went cold: " + head) == 1
	K.check(fails, cold, "so does the story on assignment (%s)" % str(toasts))
	K.check(fails, ctx.hud.waypoint() == null, "taking its waypoint with it")
	f.take_lead(0)
	var t: Vector2i = f.story["tile"]
	f.story["at"] = _now() - REPORTER.SCOOP_DAYS - 0.05
	_stand_by(t)
	f._process(REPORTER.REFRESH + 0.01)
	var card := f.card.card_text()
	K.check(fails, not card.contains("scoop "), "after a third of a day the scoop clock is gone")
	toasts.clear()
	ctx.bus.talk_replied.emit(
		"", "Bus driver", "They never tell us anything until the diggers come."
	)
	var by := str(f.story["by"])
	f.press_story()
	var out: Dictionary = filed[-1] if not filed.is_empty() else {}
	var late := int(out.get("points", 0)) == 100 and not bool(out.get("scoop", true))
	K.check(fails, late, "filed later it is no scoop: 100 points (%s)" % str(out.get("points")))
	var promoted := _count(toasts, "Promoted: you are a reporter now.") == 1
	K.check(fails, f.points == 300 and promoted, "300 points: promoted (%s)" % str(toasts))
	var own_wp := ctx.hud.waypoint() == null
	K.check(fails, by == "a bus driver" and own_wp, "filing clears the story's own waypoint")
	var detail := str(f.self_test()["detail"])
	K.check(fails, detail == "0 leads, 2 filed, Reporter", "self_test counts it (%s)" % detail)


# ------------------------------------------------------------------ keys and the league


func _check_keys() -> void:
	var p := ctx.player
	p.teleport(_away(home, 8), 0.0)
	_mayor(district, home, {"type": "build", "building": "school", "x": home.x, "y": home.y})
	_mayor(district, home, {"type": "build", "building": "park", "x": home.x, "y": home.y})
	ctx.push_modal(&"test")
	_send(K.action_event("press_story"))
	var modal := f.story.is_empty()
	ctx.pop_modal(&"test")
	ctx.mode.paused = true
	_send(K.action_event("press_story"))
	var paused := f.story.is_empty()
	ctx.mode.paused = false
	p.set_photo_mode(true)
	_send(K.action_event("press_story"))
	var photo := f.story.is_empty()
	p.set_photo_mode(false)
	_send(K.key_event(KEY_K, true))
	var echo := f.story.is_empty()
	var waits := [modal, paused, photo, echo]
	var waits_msg := "K waits under a modal, paused and in photo mode; an echo does nothing (%s)"
	K.check(fails, waits == [true, true, true, true], waits_msg % str(waits))
	_send(K.key_event(KEY_K))
	var head := "%s ordered a Park" % D.mayor_display(district)
	var took := str(f.story.get("headline", "")) == head and f.leads.size() == 1
	K.check(fails, took, "K takes the newest lead")
	toasts.clear()
	_send(K.key_event(KEY_K))
	var needs := str(f.story.get("headline", "")) == head and _count(toasts, "Not filed yet") == 1
	K.check(fails, needs, "K again before the quote says what the story needs")


func _check_league_keys() -> void:
	var p := ctx.player
	_send(K.key_event(KEY_L))
	var opened := [f.league_open, ctx.has_modal(REPORTER.MODAL), f.league.visible, f.card.visible]
	K.check(
		fails,
		opened == [true, true, true, false],
		"L opens the league over the card (%s)" % str(opened)
	)
	var head := str(f.story["headline"])
	toasts.clear()
	_send(K.action_event("press_story"))
	K.check(
		fails, str(f.story["headline"]) == head and toasts.is_empty(), "K does nothing meanwhile"
	)
	_send(K.key_event(KEY_L))
	var closed := [f.league_open, ctx.has_modal(REPORTER.MODAL), f.league.visible, f.card.visible]
	K.check(fails, closed == [false, false, false, true], "L closes it again (%s)" % str(closed))
	_send(K.action_event("press_league"))
	_send(K.action_event("pause_menu"))
	K.check(fails, not f.league_open and not ctx.is_modal(), "so does Esc")
	ctx.push_modal(&"test")
	var over_modal := f.open_league()
	ctx.pop_modal(&"test")
	ctx.mode.paused = true
	var while_paused := f.open_league()
	ctx.mode.paused = false
	p.set_photo_mode(true)
	var in_photo := f.open_league()
	p.set_photo_mode(false)
	p.set("_conv_on", true)
	var talking := f.open_league()
	p.set("_conv_on", false)
	var blocked := [over_modal, while_paused, in_photo, talking]
	var blocked_msg := "it stays shut over a modal, paused, in photo mode or talking (%s)"
	K.check(fails, blocked == [false, false, false, false], blocked_msg % str(blocked))
	var once := f.open_league() and not f.open_league() and ctx.modal_count() == 1
	ctx.bus.pause_changed.emit(true)
	var shut := not f.league_open and not ctx.is_modal()
	ctx.bus.pause_changed.emit(false)
	K.check(fails, once and shut, "it opens once, and pausing closes it")


func _check_league() -> void:
	f.open_league()
	var lines := f.league.table_lines()
	var rows := DESK.standings(ctx.sim, ctx.residents)
	var same := 0
	for k in range(mini(lines.size(), rows.size())):
		same += int(lines[k] == _row_line(k, rows[k]))
	var first := lines[0] if not lines.is_empty() else ""
	var rows_msg := "a row per mayor: rank, name and model, district, numbers, score (%s)"
	K.check(fails, lines.size() == D.MAYORS.size() and same == lines.size(), rows_msg % first)
	K.check(fails, _badges(f.league) == D.MAYORS.size(), "each mayor wears their model's badge")
	var press: Label = f.league.get("_press")
	var card := "Reporter · 300 points · 2 filed · Senior reporter at 1,000"
	K.check(
		fails,
		press.text == card,
		"the press card: rank, points, stories, next rank (%s)" % press.text
	)
	var on: Label = f.league.get("_assignment")
	var on_ok := on.text == "On assignment: " + str(f.story["headline"])
	K.check(fails, on_ok, "and the story on assignment (%s)" % on.text)
	var listed := S.owned_texts(f.league.get("_stories"))
	var heads := [listed[0], listed[2]] if listed.size() == 4 else []
	var heads_ok := heads == ["+100", "+200 · scoop, local voice, sharp shot"]
	K.check(fails, heads_ok, "the latest stories, newest first, with points (%s)" % str(listed))
	var branded: Array[String] = []
	for n: Node in [f.league, f.card]:
		for t in S.owned_texts(n):
			if S.branded(t):
				branded.append(t)
	K.check(fails, branded.is_empty(), "no model names outside the badges (%s)" % str(branded))
	var chase := f.league.chase_buttons()
	var one := chase.size() == 1 and f.leads.size() == 1
	K.check(fails, one, "a Chase button per open lead (%d)" % chase.size())
	if chase.is_empty() or f.leads.is_empty():
		return
	var want := str(f.leads[0]["headline"])
	chase[0].pressed.emit()
	var chased := [f.league_open, ctx.has_modal(REPORTER.MODAL), str(f.story.get("headline", ""))]
	var chased_ok := chased == [false, false, want]
	K.check(fails, chased_ok, "Chase closes the league and takes that lead (%s)" % str(chased))


# ------------------------------------------------------------------ save, photo tour, teardown


func _check_save() -> void:
	var d := f.to_dict()
	var stories: Array = d.get("stories", [])
	var saved := [int(d.get("points", 0)), int(d.get("filed", 0)), stories.size(), d.get("tipped")]
	var saved_msg := "to_dict: points, stories filed, the latest stories, the tip (%s)"
	K.check(fails, saved == [300, 2, 2, true], saved_msg % str(saved))
	f.open_league()
	f.from_dict({})
	var fresh := [f.points, f.filed, f.stories.size(), f.to_dict().is_empty()]
	K.check(
		fails, fresh == [0, 0, 0, true], "a save with no press card starts afresh (%s)" % str(fresh)
	)
	var dropped := [
		f.leads.size(), f.story.is_empty(), f.league_open, ctx.has_modal(REPORTER.MODAL)
	]
	var dropped_ok := dropped == [0, true, false, false]
	K.check(fails, dropped_ok, "a load drops the leads and the story and closes the league")
	f.from_dict(JSON.parse_string(JSON.stringify(d)))
	var back := [f.points, f.filed, str(f.stories) == str(stories)]
	K.check(
		fails, back == [300, 2, true], "the round trip through JSON restores it (%s)" % str(back)
	)
	var junk := {"points": -5, "filed": "lots", "stories": [7, "x", {"text": "Old news."}]}
	f.from_dict(junk)
	var old := str(f.stories[0]["text"]) if f.stories.size() == 1 else ""
	var safe := [f.points, f.filed, old]
	K.check(fails, safe == [0, 0, "Old news."], "a damaged save is read safely (%s)" % str(safe))
	var many := []
	for k in range(9):
		many.append({"text": "Story %d." % k, "points": 100})
	f.from_dict({"stories": many})
	var keep := REPORTER.KEEP_STORIES
	K.check(fails, f.stories.size() == keep, "it keeps the latest %d stories" % keep)
	f.from_dict(d)
	_mayor(district, home, {"type": "road", "x": home.x, "y": home.y})
	f.take_lead(0)
	f.on_world_rebuilt()
	var rebuilt := [f.leads.size(), f.story.is_empty(), f.points]
	var rebuilt_msg := "a rebuilt world drops the leads and the story, not the press card (%s)"
	K.check(fails, rebuilt == [0, true, 300], rebuilt_msg % str(rebuilt))


## The three shots the photo tour takes, run as the tour runs them: prepare, the teleport, frames.
func _check_photo_tour() -> void:
	var p := ctx.player
	ctx.brain.council_ruled.emit({"enacted": ["free_clinics"], "repealed": []})
	var shots := f.photo_shots()
	var names := shots.map(func(s: Dictionary) -> String: return str(s["name"]))
	var names_ok := names == ["reporter_story", "reporter_photo", "reporter_league"]
	K.check(fails, names_ok, "three tour shots (%s)" % str(names))
	var hooks := shots.all(
		func(s: Dictionary) -> bool:
			return f.has_method(s["prepare"]) and f.has_method(s["restore"])
	)
	K.check(fails, hooks, "each with a prepare and a restore")
	if shots.size() < 3:
		return
	await _tour_shot(shots[0])
	var staged := [str(f.story.get("headline", "")), str(f.story.get("by", "")), f.card.visible]
	var staged_ok := staged == ["The council passed the Free Clinics", "a shopkeeper", true]
	K.check(
		fails, staged_ok, "the story shot: on assignment, a shopkeeper quoted (%s)" % str(staged)
	)
	f.call(str(shots[0]["restore"]))
	await _tour_shot(shots[1])
	var note := f.finder.note_text()
	var camera := p.photo_mode and f.finder.visible and f.finder.framed and note == SHARP
	K.check(fails, camera, "the photo shot: the press camera up, a sharp shot taken (%s)" % note)
	f.call(str(shots[1]["restore"]))
	K.check(fails, not p.photo_mode, "restore puts the camera down")
	var n := f.filed
	await _tour_shot(shots[2])
	K.check(
		fails,
		f.filed == n + 1 and f.league_open,
		"the league shot: the story filed, the league open"
	)
	f.call(str(shots[2]["restore"]))
	K.check(fails, not f.league_open and not ctx.is_modal(), "restore closes it")


func _check_teardown() -> void:
	f.open_league()
	var n := f.leads.size()
	f.teardown()
	var gone := [ctx.has_modal(REPORTER.MODAL), f.card == null, f.finder == null, f.league == null]
	var gone_msg := "teardown closes the league and frees the UI (%s)"
	K.check(fails, gone == [false, true, true, true], gone_msg % str(gone))
	_mayor(district, home, {"type": "road", "x": home.x, "y": home.y})
	ctx.bus.talk_replied.emit("", "Shopkeeper", QUOTE)
	K.check(fails, f.leads.size() == n, "and stops listening")


# ------------------------------------------------------------------ helpers


func _mayor(mi: int, focus: Vector2i, action: Dictionary) -> void:
	var turn := {"focus": focus, "actions": [{"ok": true, "action": action}], "post": ""}
	ctx.brain.mayor_decided.emit(mi, turn)


## Sim time in days, as the feature reads it.
func _now() -> float:
	return float(ctx.sim.day) + ctx.sim.day_progress()


## A point n tiles east of tile t (west near the map's edge).
func _away(t: Vector2i, n: int) -> Vector3:
	var x := t.x + n if D.in_bounds(t.x + n, t.y) else t.x - n
	return Vector3(x, 0.0, t.y)


## Puts the hero 1.5 tiles south of tile t, facing it, and settles the camera.
func _stand_by(t: Vector2i) -> void:
	ctx.player.teleport(Vector3(t.x, 0.0, t.y + 1.5), 0.0)
	for _k in range(5):
		ctx.player.update_view(DT)


## The point a press photo of tile t must hold.
func _subject(t: Vector2i) -> Vector3:
	var at := Vector3(t.x, 0.0, t.y)
	var g := ctx.collision.ground_height(at)
	at.y = (0.0 if is_nan(g) else g) + REPORTER.SUBJECT_Y
	return at


## Turns the photo-mode camera to look straight at target.
func _aim_at(target: Vector3) -> void:
	var p := ctx.player
	var d := (target - p.camera.global_position).normalized()
	p.cam_yaw = atan2(-d.x, -d.z)
	p.cam_pitch = asin(clampf(d.y, -1.0, 1.0))
	p.update_view(0.0)


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _within(v: float, hi: float) -> bool:
	return v >= 0.0 and v <= hi


## A league row as table_lines() reads it.
func _row_line(k: int, r: Dictionary) -> String:
	var cells := [
		str(k + 1),
		"%s %s" % [r["who"], r["model"]],
		str(r["district"]),
		S.fmt(int(r["pop"])),
		S.fmt(int(r["jobs"])),
		"%.1f/10" % float(r["approval"]),
		S.money(int(r["funds"])),
		str(int(r["score"])),
	]
	return " · ".join(PackedStringArray(cells))


## Labels under n marked as a model's badge.
func _badges(n: Node) -> int:
	var c := int(n is Label and bool(n.get_meta(S.BADGE_META, false)))
	for k in n.get_children():
		c += _badges(k)
	return c


## The Gazette's chat line for the story with this headline, once the drip shows it ({} if never).
func _gazette_line(headline: String) -> Dictionary:
	var feed: ChatFeed = chat.get("feed")
	for _k in range(120):
		for m: Dictionary in feed.messages:
			if (
				str(m["author_id"]).begins_with("press:story:")
				and str(m["text"]).contains(headline)
			):
				return m
		feed.pump(0.25)
	return {}


func _pump(secs: float) -> void:
	var feed: ChatFeed = chat.get("feed")
	for _k in range(ceili(secs / 0.25)):
		feed.pump(0.25)


## Runs a photo-tour shot as the tour does: prepare, the teleport, then a few frames.
func _tour_shot(s: Dictionary) -> void:
	f.call(str(s["prepare"]))
	ctx.player.teleport(s["pos"], float(s.get("yaw", 0.0)), float(s.get("pitch", 0.0)))
	for _k in range(REPORTER.PHOTO_FRAMES + 4):
		await process_frame


func _has_all(t: String, parts: Array) -> bool:
	for s: Variant in parts:
		if not t.contains(str(s)):
			return false
	return true


## How many of list contain needle.
func _count(list: Array[String], needle: String) -> int:
	var n := 0
	for t: String in list:
		if t.contains(needle):
			n += 1
	return n


# ------------------------------------------------------------------ input


func _send(e: InputEvent) -> void:
	f._unhandled_input(e)


## Every key bound to action (its physical key where it has one).
func _keys(action: StringName) -> Array[int]:
	var out: Array[int] = []
	for e: InputEvent in InputMap.action_get_events(action):
		var k := e as InputEventKey
		if k != null:
			out.append(int(k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode))
	return out
