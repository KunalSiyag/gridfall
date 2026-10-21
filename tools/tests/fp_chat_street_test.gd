extends SceneTree
## People hit in the street, in the chat (street_lines.gd): the one hit and one who saw it speak,
## by cause; a softer blow inside the gap stays quiet but a harder one posts; a crew posts a City
## Alert card; a witness of someone with no record says "someone"; and the chat feature hears
## person_hit on the game bus. Time only moves through ChatFeed.pump().

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const T := preload("res://scripts/fp/chat/chat_text.gd")
const STREET := preload("res://scripts/fp/chat/street_lines.gd")
const STEP := 0.25
const WHERE := "Test Street"

var fails: Array[String] = []
var ctx: FpContext
var feed: ChatFeed
var lines: STREET
var ida := ""
var idb := ""
var at := Vector3.ZERO


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"grow": true})
	var people: Array = ctx.residents.people
	K.check(fails, people.size() >= 2, "fixture: at least two residents (%d)" % people.size())
	if people.size() < 2:
		K.finish(self, "FP_CHAT_STREET_TEST", fails)
		return
	ida = str(people[0]["id"])
	idb = str(people[1]["id"])
	at = Vector3(D.tx(int(people[0]["home"])), 0.0, D.ty(int(people[0]["home"])))
	feed = ChatFeed.new()
	get_root().add_child(feed)
	feed.setup(ctx)
	feed.set_process(false)
	lines = STREET.new()
	lines.setup(ctx, feed)
	_check_punches()
	_check_car()
	_check_unnamed()
	_check_bus()
	K.finish(self, "FP_CHAT_STREET_TEST", fails)


func _pump(f: ChatFeed, seconds: float) -> void:
	for _k in range(int(round(seconds / STEP))):
		f.pump(STEP)


func _hit(victim: String, witness: String, down: bool, crew: String) -> Dictionary:
	return {
		"walker": 1,
		"resident_id": victim,
		"name": "",
		"down": down,
		"street": WHERE,
		"strength": 0.5,
		"witnesses": [witness] if not witness.is_empty() else [],
		"crew": crew,
	}


func _rows_since(f: ChatFeed, seq0: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m: Dictionary in f.messages:
		if int(m["seq"]) > seq0:
			out.append(m)
	return out


## Rows by author whose text is one of the templates in pool, filled with who (and WHERE).
func _said(rows: Array[Dictionary], author: String, pool: Array, who: String = "") -> int:
	var want: Array[String] = []
	for l: Variant in pool:
		want.append(T.display(str(l).format({"street": WHERE, "who": who}), ctx.directory))
	var n := 0
	for m in rows:
		if str(m["author_id"]) == author and str(m["text"]) in want:
			n += 1
	return n


## City Alert cards with this text (kind "incident", refs.type "street").
func _cards(rows: Array[Dictionary], text: String) -> int:
	var n := 0
	for m in rows:
		var street := str((m.get("refs", {}) as Dictionary).get("type", "")) == "street"
		if str(m["kind"]) == "incident" and street and str(m["text"]) == text:
			n += 1
	return n


func _first(id: String) -> String:
	return T.first_name(str(ctx.residents.find(id)["name"]))


## A punch (a speaks, b saw it), a shove 0.5 s later (quiet: softer, inside the gap), then a
## knock-down with the police called (posts: harder).
func _check_punches() -> void:
	var seq0 := feed.seq
	lines.on_person_hit(at, "punch", _hit(ida, idb, false, ""))
	_pump(feed, 0.5)
	lines.on_person_hit(at, "shove", _hit(idb, ida, false, ""))
	_pump(feed, 0.5)
	lines.on_person_hit(at, "punch", _hit(ida, idb, true, "police"))
	_pump(feed, 30.0)
	var rows := _rows_since(feed, seq0)
	var hit := _said(rows, ida, STREET.VICTIM["punch"]) == 1
	hit = hit and _said(rows, ida, STREET.VICTIM["down"]) == 1
	K.check(fails, hit, "punch: the one hit says so, then that they were knocked down")
	var saw := _said(rows, idb, STREET.WITNESS["punch"], _first(ida)) == 1
	saw = saw and _said(rows, idb, STREET.WITNESS["down"], _first(ida)) == 1
	K.check(fails, saw, "punch: the one who saw it says so twice, naming them")
	var quiet := _said(rows, idb, STREET.VICTIM["shove"])
	quiet += _said(rows, ida, STREET.WITNESS["shove"], _first(idb))
	K.check(
		fails, quiet == 0, "punch: a shove inside the gap after a punch posts nothing (%d)" % quiet
	)
	var police := _cards(rows, "Police called to %s after a visitor attacked people" % WHERE)
	K.check(fails, police == 1, "punch: the police call posts one City Alert card (%d)" % police)
	var card := {}
	for m in rows:
		if str(m["kind"]) == "incident":
			card = m
	var tile := D.idx(roundi(at.x), roundi(at.z))
	var placed := int((card.get("refs", {}) as Dictionary).get("tile", -1)) == tile
	placed = placed and int(card.get("district", -9)) == ctx.sim.district[tile]
	K.check(fails, placed, "punch: the card carries the tile and its district")


## Once the gap is over, a car knocks b down: b and a witness speak, an ambulance card posts.
func _check_car() -> void:
	_pump(feed, 9.0)
	var seq0 := feed.seq
	lines.on_person_hit(at, "car", _hit(idb, ida, true, "ambulance"))
	_pump(feed, 20.0)
	var rows := _rows_since(feed, seq0)
	var car := _said(rows, idb, STREET.VICTIM["car_down"]) == 1
	car = car and _said(rows, ida, STREET.WITNESS["car_down"], _first(idb)) == 1
	K.check(fails, car, "car: the one knocked down and a witness speak")
	var amb := _cards(rows, "Ambulance called to %s: a car hit someone" % WHERE)
	K.check(fails, amb == 1, "car: the ambulance posts one City Alert card (%d)" % amb)


## A walker with no resident record: only the witness speaks, of "someone"; with nobody named
## around, nothing posts.
func _check_unnamed() -> void:
	_pump(feed, 9.0)
	var seq0 := feed.seq
	lines.on_person_hit(at, "shove", _hit("", ida, false, ""))
	_pump(feed, 20.0)
	var rows := _rows_since(feed, seq0)
	var anon := _said(rows, ida, STREET.WITNESS["shove"], "someone")
	K.check(
		fails, anon == 1 and rows.size() == 1, "unnamed: one witness line, of someone (%d)" % anon
	)
	_pump(feed, 9.0)
	seq0 = feed.seq
	lines.on_person_hit(at, "punch", _hit("", "", false, ""))
	_pump(feed, 20.0)
	var none := _rows_since(feed, seq0).size()
	K.check(fails, none == 0, "unnamed: nobody named, no crew: nothing posts (%d)" % none)


## The chat feature hears person_hit on the bus and posts through its own feed.
func _check_bus() -> void:
	var chat := K.make_feature(ctx, "chat")
	K.check(
		fails, chat != null and chat.get("street_lines") != null, "bus: chat feature with lines"
	)
	if chat == null:
		return
	var f: ChatFeed = chat.get("feed")
	f.set_process(false)
	var seq0 := f.seq
	ctx.bus.person_hit.emit(at, "punch", _hit(ida, idb, false, ""))
	_pump(f, 20.0)
	var rows := _rows_since(f, seq0)
	var heard := _said(rows, ida, STREET.VICTIM["punch"]) == 1
	K.check(fails, heard, "bus: person_hit puts the one hit in the chat")
	chat.teardown()
	var n := ctx.bus.person_hit.get_connections().size()
	K.check(fails, n == 0, "bus: teardown lets go of person_hit (%d left)" % n)
