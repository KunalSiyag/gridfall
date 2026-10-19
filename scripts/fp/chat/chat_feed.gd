class_name ChatFeed
extends Node
## The global chat's message store and drip queue (slice C §1). Every source is normalised to the
## S0 chat message dict and released one message every 1.5-3.0 s by priority, so a burst of 100
## plan lines never floods the panel. The feed keeps its own clock: now_ms advances only through
## pump(), which _process calls, so pause freezes it and tests are deterministic.

const T := preload("res://scripts/fp/chat/chat_text.gd")
## Release priority per message kind (higher first): player > mayor and press > alerts and
## incidents > react > chatter > say > letters and logs.
const PRIORITY := {
	"player": 7, "post": 6, "headline": 6, "ruling": 6, "alert": 5, "incident": 5, "notice": 5,
	"react": 4, "opened": 4, "chatter": 3, "say": 2, "people": 1, "letter": 1, "log": 1,
}
const RING := 120
const QUEUE_MAX := 60
const DEDUPE_ROWS := 40
const DEDUPE_MS := 120000
const AUTHOR_MS := 45000
const RELEASE_MIN_MS := 1500
const RELEASE_MAX_MS := 3000
## Queued lines at or below "chatter" priority older than this are dropped unshown (stale gossip).
const STALE_MS := 240000
## Roles the per-author rate limit applies to.
const LIMITED_ROLES := ["resident", "mayor"]
const INTERNAL := ["_prio", "_qid", "_q_ms", "_due", "_reply_qid", "_exempt", "_norm"]

## A message left the queue and is now in the chat (the panel appends a row).
signal shown(msg: Dictionary)
## A shown message changed in place (the Breaking card replacing its incident card).
signal changed(msg: Dictionary)
## pump() advanced the clock; the chat feature runs every timed rule from here.
signal pumped(now_ms: int)
## Everything was cleared (load, New City).
signal cleared()

var ctx: FpContext
## The feed clock in milliseconds; advanced only by pump().
var now_ms: int = 0
## Last assigned message seq (shown messages are numbered 1, 2, 3 ...).
var seq: int = 0
## The last RING shown messages, oldest first.
var messages: Array[Dictionary] = []
## normalise() keys of messages, index for index (dedupe without re-normalising).
var _norms: Array[String] = []
## Waiting entries (message dicts with internal _ keys).
var queue: Array[Dictionary] = []
var _fast: Array[Dictionary] = []
var _next_release_ms: int = 0
var _qid: int = 0
var _qid_seq: Dictionary = {}
var _author_last: Dictionary = {}
var _rng := RandomNumberGenerator.new()


## Stores ctx and seeds the release jitter from the city seed.
func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	reseed()


## Re-seeds the release jitter (sim.city_seed) so two runs on one seed release identically.
func reseed() -> void:
	_rng.seed = (ctx.sim.city_seed if ctx != null and ctx.sim != null else 7) * 7177 + 31


func _process(delta: float) -> void:
	pump(delta)


## A new message dict (S0 §9). text goes through the display filter; refs hold String/int only.
func make(author_id: String, author: String, role: String, district: int, text: String, kind: String, reply_to: int = -1, refs: Dictionary = {}) -> Dictionary:
	var dir: CityDirectory = ctx.directory if ctx != null else null
	return {
		"seq": 0, "author_id": author_id, "author": T.display(author, dir), "role": role, "district": district,
		"text": T.display(text, dir), "kind": kind, "day": ctx.sim.day if ctx != null and ctx.sim != null else 0,
		"clock": ctx.sky.clock_text() if ctx != null and ctx.sky != null else "", "t_ms": 0,
		"reply_to": reply_to, "refs": refs,
	}


## Queues msg for the drip. opts: "skip" (bool: the fast lane for replies to the player, released
## after "delay_ms"), "exempt" (bool: no per-author limit), "reply_qid" (int: hold until that
## queue entry is shown, then reply to its seq). Returns the queue id, or -1 when dropped (empty,
## a duplicate, or replaced into an existing entry of the same author).
func enqueue(msg: Dictionary, opts: Dictionary = {}) -> int:
	var text := str(msg.get("text", "")).strip_edges()
	if text.is_empty():
		return -1
	var norm := T.normalise(text)
	if is_duplicate(norm):
		return -1
	var e := msg.duplicate()
	_qid += 1
	e["_qid"] = _qid
	e["_prio"] = int(PRIORITY.get(str(e.get("kind", "")), 1))
	e["_q_ms"] = now_ms
	e["_reply_qid"] = int(opts.get("reply_qid", -1))
	e["_exempt"] = bool(opts.get("exempt", false))
	e["_norm"] = norm
	if bool(opts.get("skip", false)):
		e["_due"] = now_ms + int(opts.get("delay_ms", 0))
		_fast.append(e)
		return _qid
	# The newest daily "say" of an author replaces their queued one (a status, not a thread).
	if str(e["kind"]) == "say":
		for q: Dictionary in queue:
			if str(q["author_id"]) == str(e["author_id"]) and str(q["kind"]) == "say":
				q["text"] = e["text"]
				q["_norm"] = norm
				return -1
	queue.append(e)
	while queue.size() > QUEUE_MAX:
		_drop_lowest()
	return _qid


## Shows msg at once (player lines), bypassing the queue. Returns the shown dict (with its seq).
func post_now(msg: Dictionary) -> Dictionary:
	var e := msg.duplicate()
	e["_norm"] = T.normalise(str(e.get("text", "")))
	return _show(e)


## True when norm (a normalise() key) matches a queued entry or one of the last DEDUPE_ROWS shown
## messages from the last DEDUPE_MS.
func is_duplicate(norm: String) -> bool:
	if norm.is_empty():
		return true
	for q: Dictionary in queue:
		if str(q["_norm"]) == norm:
			return true
	for q: Dictionary in _fast:
		if str(q["_norm"]) == norm:
			return true
	var k := messages.size() - 1
	var seen := 0
	while k >= 0 and seen < DEDUPE_ROWS:
		if now_ms - int(messages[k]["t_ms"]) > DEDUPE_MS:
			break
		if _norms[k] == norm:
			return true
		k -= 1
		seen += 1
	return false


## Advances the clock by dt seconds: releases due fast-lane entries, then drips the queue (one
## message every RELEASE_MIN_MS..RELEASE_MAX_MS), then emits pumped(now_ms).
func pump(dt_seconds: float) -> void:
	now_ms += maxi(0, int(round(dt_seconds * 1000.0)))
	var k := 0
	while k < _fast.size():
		if int(_fast[k]["_due"]) <= now_ms:
			_show(_fast.pop_at(k))
		else:
			k += 1
	if queue.is_empty():
		_next_release_ms = maxi(_next_release_ms, now_ms)
	else:
		var guard := 0
		while now_ms >= _next_release_ms and guard < 16:
			guard += 1
			var e := _pick()
			if e.is_empty():
				break
			_show(e)
			# A release that waited on rate limits restarts the cadence from now (no catch-up burst).
			var base := _next_release_ms if now_ms - _next_release_ms < RELEASE_MIN_MS else now_ms
			_next_release_ms = base + _rng.randi_range(RELEASE_MIN_MS, RELEASE_MAX_MS)
	pumped.emit(now_ms)


## The queued entry (not yet shown) whose fields match every pair in where, or {}.
func find_queued(where: Dictionary) -> Dictionary:
	for list: Array[Dictionary] in [queue, _fast]:
		for q: Dictionary in list:
			if _matches(q, where):
				return q
	return {}


## The newest shown message whose fields match every pair in where (refs keys as "refs.<k>"), or {}.
func find_shown(where: Dictionary) -> Dictionary:
	for k in range(messages.size() - 1, -1, -1):
		if _matches(messages[k], where):
			return messages[k]
	return {}


## Replaces fields of a shown message in place and emits changed(msg).
func update_shown(msg: Dictionary, fields: Dictionary) -> void:
	for key: Variant in fields.keys():
		msg[key] = fields[key]
	var k := messages.find(msg)
	if k >= 0:
		_norms[k] = T.normalise(str(msg.get("text", "")))
	changed.emit(msg)


## Replaces fields of a queued entry in place (keeps its place in the queue); "kind" also
## updates its priority.
func update_queued(entry: Dictionary, fields: Dictionary) -> void:
	for key: Variant in fields.keys():
		entry[key] = fields[key]
	if fields.has("kind"):
		entry["_prio"] = int(PRIORITY.get(str(entry["kind"]), 1))
	if fields.has("text"):
		entry["_norm"] = T.normalise(str(entry["text"]))


## The shown message with this seq, or {}.
func by_seq(s: int) -> Dictionary:
	for k in range(messages.size() - 1, -1, -1):
		if int(messages[k]["seq"]) == s:
			return messages[k]
	return {}


## True while entries wait in the queue or the fast lane.
func busy() -> bool:
	return not queue.is_empty() or not _fast.is_empty()


## Entries waiting in the fast lane (replies to the player).
func fast_count() -> int:
	return _fast.size()


## Drops every message and queued entry (load, New City). now_ms keeps running.
func clear() -> void:
	messages.clear()
	_norms.clear()
	queue.clear()
	_fast.clear()
	_qid_seq.clear()
	_author_last.clear()
	seq = 0
	_next_release_ms = now_ms
	reseed()
	cleared.emit()


## Restores shown messages from a save (already cast and filtered); t_ms becomes now ("now").
func restore(list: Array, p_seq: int) -> void:
	clear()
	for v: Variant in list:
		var m: Dictionary = v
		m["t_ms"] = now_ms
		messages.append(m)
		_norms.append(T.normalise(str(m.get("text", ""))))
	while messages.size() > RING:
		messages.pop_front()
		_norms.pop_front()
	seq = maxi(p_seq, int(messages[-1]["seq"]) if not messages.is_empty() else 0)


func _show(e: Dictionary) -> Dictionary:
	seq += 1
	var qid := int(e.get("_qid", -1))
	if qid >= 0:
		_qid_seq[qid] = seq
	var rq := int(e.get("_reply_qid", -1))
	if rq >= 0:
		e["reply_to"] = int(_qid_seq.get(rq, -1))
	var norm := str(e.get("_norm", ""))
	for key: String in INTERNAL:
		e.erase(key)
	e["seq"] = seq
	e["t_ms"] = now_ms
	if ctx != null and ctx.sim != null:
		e["day"] = ctx.sim.day
	if ctx != null and ctx.sky != null:
		e["clock"] = ctx.sky.clock_text()
	messages.append(e)
	_norms.append(norm if not norm.is_empty() else T.normalise(str(e.get("text", ""))))
	while messages.size() > RING:
		messages.pop_front()
		_norms.pop_front()
	if str(e["role"]) in LIMITED_ROLES:
		_author_last[str(e["author_id"])] = now_ms
	if _qid_seq.size() > 400:
		_qid_seq.clear()
	shown.emit(e)
	if ctx != null and ctx.bus != null:
		ctx.bus.chat_posted.emit(e)
	return e


## Next entry to release: highest priority, then oldest, skipping authors still inside their
## AUTHOR_MS window and replies whose parent is still queued; drops stale low-priority entries.
func _pick() -> Dictionary:
	var best := -1
	var k := 0
	while k < queue.size():
		var q: Dictionary = queue[k]
		if int(q["_prio"]) <= int(PRIORITY["chatter"]) and now_ms - int(q["_q_ms"]) > STALE_MS:
			queue.remove_at(k)
			continue
		k += 1
	for j in range(queue.size()):
		var q: Dictionary = queue[j]
		if not _eligible(q):
			continue
		if best < 0 or int(q["_prio"]) > int(queue[best]["_prio"]) or (int(q["_prio"]) == int(queue[best]["_prio"]) and int(q["_qid"]) < int(queue[best]["_qid"])):
			best = j
	return queue.pop_at(best) if best >= 0 else {}


func _eligible(q: Dictionary) -> bool:
	var rq := int(q["_reply_qid"])
	if rq >= 0 and not _qid_seq.has(rq):
		for o: Dictionary in queue:
			if int(o["_qid"]) == rq:
				return false
	if bool(q["_exempt"]) or str(q["role"]) not in LIMITED_ROLES:
		return true
	var last: Variant = _author_last.get(str(q["author_id"]))
	return last == null or now_ms - int(last) >= AUTHOR_MS


func _drop_lowest() -> void:
	var worst := 0
	for j in range(1, queue.size()):
		var a: Dictionary = queue[j]
		var b: Dictionary = queue[worst]
		if int(a["_prio"]) < int(b["_prio"]) or (int(a["_prio"]) == int(b["_prio"]) and int(a["_qid"]) < int(b["_qid"])):
			worst = j
	queue.remove_at(worst)


func _matches(m: Dictionary, where: Dictionary) -> bool:
	for key: String in where.keys():
		var v: Variant
		if key.begins_with("refs."):
			v = (m.get("refs", {}) as Dictionary).get(key.substr(5))
		else:
			v = m.get(key)
		if v == null or str(v) != str(where[key]):
			return false
	return true
