extends SceneTree
## The chat's live paths when the usual answer is missing (scripts/fp/chat, ChatterMinds). In a
## city nobody lives in yet the rival mayors answer the player's lines, the one a line names
## first, and argue among themselves once a minute (live only); a player line nobody can answer,
## offline or when the live call fails, gets the "busy fighting" status card. Once people live
## there, a talk reply still out after 8 s gets the resident's busy line and the late reply still
## shows. A counting fake client; time moves only through ChatFeed.pump(), never the wall clock.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const CHAT := preload("res://scripts/fp/chat/chat_feature.gd")
const STEP := 0.25
const TALK_REPLY := "Honestly? Night shifts are brutal, but my patients keep me going."

var fails: Array[String] = []
var ctx: FpContext
var chat: FpFeature
var fake: FakeClient


## Answers every chatter call with one line per card, plus one from a stranger that the chat must
## drop, and every talk call with TALK_REPLY. fail makes every live call fail; while hold_talk is
## set, talk calls wait for release. The transport always fails (no network in tests).
class FakeClient:
	extends GmiClient
	signal release
	var calls: Array[Dictionary] = []
	var fail: bool = false
	var hold_talk: bool = false

	func live_json(
		role: String,
		agent_id: String,
		model: String,
		system_prompt: String,
		user_prompt: String,
		day: int,
		max_tokens: int,
		timeout_s: float
	) -> Dictionary:
		var rec := {"role": role, "agent": agent_id, "system": system_prompt, "user": user_prompt}
		rec.merge({"day": day, "max_tokens": max_tokens, "timeout": timeout_s})
		calls.append(rec)
		var res := {"ok": false, "data": {}, "source": "failed", "model": model, "error": ""}
		if not live_enabled:
			res["error"] = "offline"
			return res
		if fail:
			res["error"] = "HTTP 500 the fake is down"
			return res
		if role == "talk" and hold_talk:
			await release
		res.merge({"ok": true, "source": "live", "data": _answer(role, user_prompt)}, true)
		return res

	func _post(
		_model: String,
		_system_prompt: String,
		_user_prompt: String,
		_max_tokens: int,
		_timeout_s: float
	) -> Dictionary:
		return {"ok": false, "error": "fake client: no network"}

	func _answer(role: String, user_prompt: String) -> Dictionary:
		if role == "talk":
			return {"reply": TALK_REPLY, "mood_delta": 0.6, "memory": "a chat", "emote": "laugh"}
		var lines: Array = [{"id": "r_nobody", "reply_to": null, "text": "I do not live here."}]
		var u: Variant = JSON.parse_string(user_prompt)
		var cards: Array = (u as Dictionary).get("participants", []) if u is Dictionary else []
		for c: Variant in cards:
			var card: Dictionary = c
			var text := "Call %d: %s says parks come first." % [calls.size(), card.get("name", "")]
			lines.append({"id": str(card.get("id", "")), "reply_to": null, "text": text})
		return {"lines": lines}


func _init() -> void:
	await process_frame
	fake = FakeClient.new()
	fake.name = "FakeClient"
	fake.live_enabled = true
	ctx = K.make_ctx(get_root(), {"client": fake})
	var empty := not ctx.residents.is_active()
	K.check(fails, empty, "fixture: nobody lives in the city (%d)" % ctx.residents.people.size())
	chat = K.make_feature(ctx, "chat")
	K.check(fails, chat != null, "fixture: the chat feature")
	if chat == null or not empty:
		K.finish(self, "FP_CHAT_LIVE_TEST", fails)
		return
	_check_panel()
	_check_answer()
	_check_named()
	_check_rounds()
	_check_failed()
	_check_offline()
	await _check_slow_talk()
	K.finish(self, "FP_CHAT_LIVE_TEST", fails)


# ---------------------------------------------------------------- helpers


func _feed() -> ChatFeed:
	return chat.get("feed")


func _pump(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		_feed().pump(STEP)
		t += STEP


func _rows_since(seq0: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m: Dictionary in _feed().messages:
		if int(m["seq"]) > seq0:
			out.append(m)
	return out


func _mayor_rows(rows: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m: Dictionary in rows:
		if str(m["role"]) == "mayor":
			out.append(m)
	return out


func _calls_of(agent: String, from: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for k in range(from, fake.calls.size()):
		if str(fake.calls[k]["agent"]) == agent:
			out.append(fake.calls[k])
	return out


func _count_talk() -> int:
	var n := 0
	for c: Dictionary in fake.calls:
		if str(c["role"]) == "talk":
			n += 1
	return n


func _texts(rows: Array[Dictionary]) -> Array[String]:
	var out: Array[String] = []
	for m: Dictionary in rows:
		out.append("%s: %s" % [m["author"], m["text"]])
	return out


# ---------------------------------------------------------------- nobody lives here yet


## mayor_panel: n distinct mayors, the lead first.
func _check_panel() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var ok := true
	for lead in range(-1, D.MAYORS.size()):
		var p := ChatterMinds.mayor_panel(lead, 3, rng)
		var distinct := {}
		for k: int in p:
			distinct[k] = true
		ok = ok and p.size() == 3 and distinct.size() == 3 and (lead < 0 or p[0] == lead)
	K.check(fails, ok, "panel: three distinct mayors, the lead first")


## A line to the chat gets the mayors' answer from one live call with the mayors' prompt: the
## mayor of the player's district first, then a rival, both replying to the player's line.
func _check_answer() -> void:
	var seq0 := _feed().seq
	var n0 := fake.calls.size()
	chat.call("player_say", "Hello? Is anyone out there?")
	_pump(8.0)
	var rows := _rows_since(seq0)
	var answered := _calls_of("player", n0)
	K.check(fails, fake.calls.size() - n0 == 1 and answered.size() == 1, "answer: one live call")
	if not answered.is_empty():
		var prompt_ok := str(answered[0]["system"]) == ChatterMinds.MAYORS_PLAYER_SYSTEM
		K.check(fails, prompt_ok, "answer: the call carries the mayors' prompt")
	var mayors := _mayor_rows(rows)
	var d: int = chat.call("_player_district")
	var lead := str(D.MAYORS[d]["display"]) if d >= 0 and d < D.MAYORS.size() else ""
	var first_ok := mayors.size() >= 2 and (lead.is_empty() or str(mayors[0]["author"]) == lead)
	K.check(fails, first_ok, "answer: %s first, then a rival %s" % [lead, str(_texts(mayors))])
	var parent := int(rows[0]["seq"]) if not rows.is_empty() else -1
	var threaded := not mayors.is_empty()
	for m: Dictionary in mayors:
		threaded = threaded and int(m["reply_to"]) == parent
	K.check(fails, threaded, "answer: every mayor replies to the player's line")
	var stranger := false
	for m: Dictionary in rows:
		stranger = stranger or str(m["text"]).contains("I do not live here")
	K.check(fails, not stranger, "answer: a line from someone not in the call is dropped")


## A line naming a mayor gets that mayor's answer first, whatever district the player is in.
func _check_named() -> void:
	var d: int = chat.call("_player_district")
	var k := (maxi(d, 0) + 2) % D.MAYORS.size()
	var display := str(D.MAYORS[k]["display"])
	var last := display.get_slice(" ", 1)
	var seq0 := _feed().seq
	chat.call("player_say", "Mayor %s, what are you building first?" % last)
	_pump(8.0)
	var mayors := _mayor_rows(_rows_since(seq0))
	var ok := not mayors.is_empty() and str(mayors[0]["author"]) == display
	K.check(fails, ok, "named: Mayor %s answers first %s" % [last, str(_texts(mayors))])


## With nobody to chat, the mayors argue once a minute of play: one live call with the round
## prompt, 2-3 mayors in the chat, none while paused.
func _check_rounds() -> void:
	var n0 := fake.calls.size()
	var seq0 := _feed().seq
	_pump(75.0)
	var rounds := _calls_of("mayors", n0)
	K.check(fails, rounds.size() == 1, "rounds: one mayors' round in 75 s (%d)" % rounds.size())
	if not rounds.is_empty():
		var prompt_ok := str(rounds[0]["system"]) == ChatterMinds.MAYORS_SYSTEM
		K.check(fails, prompt_ok, "rounds: the call carries the mayors' round prompt")
	var authors := {}
	var rows := _mayor_rows(_rows_since(seq0))
	for m: Dictionary in rows:
		authors[str(m["author"])] = true
	var ok := authors.size() >= 2 and rows.size() <= ChatterMinds.MAYOR_ROUND_LINES
	K.check(fails, ok, "rounds: %d mayors argue %s" % [authors.size(), str(_texts(rows))])
	var n1 := fake.calls.size()
	_pump(300.0)
	var more := _calls_of("mayors", n1).size()
	K.check(fails, more >= 4 and more <= 6, "rounds: about one a minute (%d in 5 min)" % more)
	ctx.bus.pause_changed.emit(true)
	var n2 := fake.calls.size()
	_pump(130.0)
	K.check(fails, fake.calls.size() == n2, "rounds: none while paused")
	ctx.bus.pause_changed.emit(false)


## A failed live call gets nobody's made-up answer: the chat says the mayors are busy fighting,
## and a second failure in a row says live replies are slow (no neighbours to answer instead).
func _check_failed() -> void:
	fake.fail = true
	var seq0 := _feed().seq
	var n0 := fake.calls.size()
	chat.call("player_say", "Why is nothing built yet?")
	_pump(6.0)
	var rows := _rows_since(seq0)
	var busy := rows.size() == 2 and str(rows[1]["text"]) == CHAT.STATUS_BUSY
	busy = busy and str(rows[1]["kind"]) == "status" and fake.calls.size() - n0 == 1
	K.check(fails, busy, "failed: one call, then the mayors are busy %s" % str(_texts(rows)))
	seq0 = _feed().seq
	chat.call("player_say", "Hello again?")
	_pump(8.0)
	var texts: Array[String] = []
	for m: Dictionary in _rows_since(seq0):
		texts.append(str(m["text"]))
	var down := texts.has(CHAT.STATUS_BUSY) and texts.has(CHAT.STATUS_DOWN_EMPTY)
	K.check(fails, down, "failed: two in a row also say live replies are slow %s" % str(texts))
	fake.fail = false


## Offline nobody can answer either: no call, the busy card, and no mayors' rounds.
func _check_offline() -> void:
	fake.live_enabled = false
	var seq0 := _feed().seq
	var n0 := fake.calls.size()
	chat.call("player_say", "Anyone there?")
	_pump(6.0)
	var rows := _rows_since(seq0)
	var busy := rows.size() == 2 and str(rows[1]["text"]) == CHAT.STATUS_BUSY
	K.check(fails, busy, "offline: the mayors are busy %s" % str(_texts(rows)))
	_pump(130.0)
	var made := fake.calls.size() - n0
	K.check(fails, made == 0, "offline: no live call and no mayors' round (%d)" % made)
	fake.live_enabled = true


# ---------------------------------------------------------------- face to face


## Once people live here, a slow live talk reply: the card waits, a line typed meanwhile stays in
## the box, the resident's busy line shows after 8 s of feed time (no quote, no mood change), and
## the late reply still shows. A third line while 2 calls are out is busy without a call.
func _check_slow_talk() -> void:
	K.grow(ctx.sim, ctx.residents)
	var grown := ctx.residents.is_active()
	K.check(fails, grown, "talk fixture: the city grew (%d)" % ctx.residents.people.size())
	if not grown:
		return
	var talk: Control = chat.get("talk")
	var minds: ChatterMinds = chat.get("minds")
	var r: Dictionary = ctx.residents.people[0]
	var id := str(r["id"])
	var heard: Array[String] = []
	var probe := func(rid: String, _who: String, _reply: String) -> void: heard.append(rid)
	ctx.bus.talk_replied.connect(probe)
	ctx.bus.talk_requested.emit(id)
	var c0 := _count_talk()
	var mood0 := float(r["mood"])
	fake.hold_talk = true
	talk.call("say", "How's the commute these days?")
	K.check(fails, bool(talk.get("waiting")), "talk: the card waits for the live reply")
	var inp: LineEdit = talk.get("input")
	inp.text = "Still there?"
	inp.text_submitted.emit("Still there?")
	var kept := inp.text == "Still there?" and _count_talk() - c0 == 1
	K.check(fails, kept, "talk: a line typed while waiting stays in the box, no second call")
	_pump(8.5)
	var busy := str(talk.call("shown_text"))
	var said_busy := ChatterMinds.TALK_BUSY.has(busy) and not bool(talk.get("waiting"))
	K.check(fails, said_busy, "talk: after 8 s the resident is busy ('%s')" % busy)
	var still := heard.is_empty() and is_equal_approx(float(r["mood"]), mood0)
	K.check(fails, still, "talk: the busy line is no quote and moves no mood")
	fake.hold_talk = false
	fake.release.emit()
	var late := str(talk.call("shown_text"))
	K.check(fails, late == TALK_REPLY, "talk: the late reply still shows ('%s')" % late)
	var quoted := heard.size() == 1 and heard[0] == id
	K.check(fails, quoted, "talk: the late reply is the one quote (%s)" % str(heard))
	fake.hold_talk = true
	var c1 := _count_talk()
	minds.talk(r, [], "first")
	minds.talk(r, [], "second")
	var third: Dictionary = await minds.talk(r, [], "third")
	var made := _count_talk() - c1
	var capped := str(third.get("source", "")) == "busy" and made == ChatterMinds.TALK_PARALLEL
	K.check(fails, capped, "talk: a third line while 2 are out is busy, no call (%d)" % made)
	fake.hold_talk = false
	fake.release.emit()
	ctx.bus.talk_replied.disconnect(probe)
	talk.call("end")
	var mem: Array = r.get("memory", [])
	var remembered := not mem.is_empty() and str(mem[-1]).contains("talked with a visitor")
	K.check(fails, remembered, "talk: the answered conversation is remembered")
