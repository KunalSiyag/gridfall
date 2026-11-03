class_name ArenaAsk
extends RefCounted
## "Ask the five": the overseer asks one question and the five mayors' models answer it in
## parallel, each from the same city state it would plan a normal turn from (CityBrain's own
## mayor prompts) with the question appended as "OVERSEER QUESTION". The answers are only SHOWN:
## apply_action is never called, nothing lands in a mayor's log, thoughts or posts, the proposals
## and day feed stay as they were, and the sim is read, never written (ai_ask_all_test.gd
## compares sim.to_dict() before and after).
##
## The calls go through GmiClient.live_json under the isolated role "arena" (GmiClient.
## ISOLATED_ROLES): no role cache, session cache, replay cache or save is written, and the breaker
## and live_outcomes are left alone, so five parallel questions that meet a 429 cannot turn the
## city to replay. Without a key, offline, or with the breaker open, each column is that mayor's
## last RECORDED turn nearest today (source "recorded": it did not hear the question) or, with
## none, the scripted planner (source "offline"). A mayor whose live call failed shows the same
## fallback plus the (scrubbed) error.
##
## Budget like the chat's decree: one ask per COOLDOWN_MS and PER_DAY asks per game day; a refused
## ask returns {"ok": false, "code", "reason"} (the reason is a sentence for the player). The
## budget (and the count of calls still in flight) lives on the GmiClient, which outlives the city,
## so New City and Load do not reset it. A call still unanswered after `timeout_s` lands as a
## failed column (fallback plus "timed out"); its late reply is ignored.
##
## Each answer is a result: {mi, who, model (badge), thought, post, proposal, actions (proposed,
## copied, with any non-numeric number dropped), flags ([{i, code, text}]), extra_actions,
## elapsed_s, finish_rank (1 = first LIVE answer; 0 for a recorded or offline column, which did
## not race), source ("live" | "recorded" | "offline"), error}.

signal started(run: Dictionary)
signal answered(result: Dictionary)
signal finished(run: Dictionary)

const D := preload("res://scripts/sim/sim_defs.gd")
const ROLE := "arena"
const COOLDOWN_MS := 60000
const PER_DAY := 5
const MAX_QUESTION := 300
const MAX_TOKENS := 1500
## One call's time budget in seconds; the panel's bar fills against it (see timeout_s).
const TIMEOUT_S := 45.0
## Longest thought and post kept, in characters (a longer text ends in an ellipsis).
const THOUGHT_MAX := 260
const POST_MAX := 200
## The numbers an order may carry; a model's null, list or word there is dropped, not trusted.
const NUMBER_KEYS := ["x", "y", "x2", "y2", "w", "h", "amount", "r", "c", "i"]
## The key of the GmiClient meta that holds the budget ledger (see _ledger).
const LEDGER_META := "arena_budget"
const MODES := ["own", "neutral"]
## The one persona line every mayor gets in neutral mode, in place of their own.
const NEUTRAL_PERSONA := (
	"You are a mayor of GridFall with no personal style: weigh the situation plainly"
	+ " and do what the city needs."
)
const QUESTION_HEAD := "OVERSEER QUESTION"
const QUESTION_NOTE := (
	"This is a what-if: nothing you answer is carried out. Reply in the same JSON format:"
	+ " put the orders you would give in actions and say why in thought."
)
const REFUSALS := {
	"empty": "Type a question for the five mayors.",
	"off": "Asking the five is switched off.",
	"no_city": "There is no city to ask about yet.",
	"busy": "The five are still answering.",
	"cooldown": "Give them a minute: ask again in {s} s.",
	"daily": "That is {n} questions for today: ask again tomorrow.",
}
const FLAG_TEXT := {
	"outside": "outside the district",
	"unaffordable": "the treasury cannot cover it",
	"unknown": "not an order the city knows",
	"no_plot": "no plot to annex there",
	"beyond_limit": "past the daily order limit",
	"bad_grant": "grant to nobody",
}

## The CityBrain (typed Node: it extends the class that builds this one).
var brain: Node
## The newest run (open or finished); {} before the first ask.
var run: Dictionary = {}
## Milliseconds clock; a test swaps it.
var clock: Callable = Time.get_ticks_msec
## Seconds a call may take before its column lands as failed; a test shortens it.
var timeout_s: float = TIMEOUT_S

var _seq: int = 0
## The budget when there is no client to keep it on.
var _local_ledger: Dictionary = {}


func _init(p_brain: Node = null) -> void:
	brain = p_brain


## Whether a run is still waiting for an answer.
func busy() -> bool:
	return (
		not run.is_empty()
		and not bool(run.get("done", false))
		and not bool(run.get("stale", false))
	)


## Seconds since the run began (the bar's clock); 0 with no run.
func elapsed_s(r: Dictionary = {}) -> float:
	var rr := r if not r.is_empty() else run
	if rr.is_empty():
		return 0.0
	return maxf(0.0, float(_now() - int(rr["t0_ms"])) / 1000.0)


## Asks all five mayors question (persona_mode "own" or "neutral"). Returns {"ok": true, "run": id}
## at once (answers arrive through `answered`, then `finished`), or {"ok": false, "code", "reason"}
## when the budget, the flag or the city says no.
func ask(question: String, persona_mode: String = "own") -> Dictionary:
	var q := question.strip_edges().left(MAX_QUESTION)
	var refusal := _refusal(q)
	if not refusal.is_empty():
		return refusal
	var day: int = brain.sim.day
	var now := _now()
	var ledger := _ledger()
	var day_asks: Dictionary = ledger["day_asks"]
	ledger["asked"] = true
	ledger["last_ms"] = now
	day_asks[day] = int(day_asks.get(day, 0)) + 1
	_seq += 1
	var mode := persona_mode if persona_mode in MODES else "own"
	var live := live_possible()
	var slots: Array[Dictionary] = []
	slots.resize(D.MAYORS.size())
	slots.fill({})
	run = {
		"id": _seq,
		"question": q,
		"persona_mode": mode,
		"day": day,
		"t0_ms": now,
		"gen": brain._generation,
		"live": live,
		"results": slots,
		"held": [true, true, true, true, true] if live else [false, false, false, false, false],
		"order": [],
		"landed": 0,
		"live_landed": 0,
		"done": false,
		"stale": false,
	}
	var mine := run
	var prompts: Array[Dictionary] = []
	for mi in range(D.MAYORS.size()):
		prompts.append(prompts_for(mi, q, mode, day))
	if live:
		ledger["inflight"] = int(ledger["inflight"]) + D.MAYORS.size()
	started.emit(mine)
	for mi in range(D.MAYORS.size()):
		_run_one(mi, mine, prompts[mi])
	if live and not bool(mine["done"]):
		_watch(mine)
	return {"ok": true, "run": _seq}


## The refusal for asking q now (see _refuse), or {} when the ask may go out.
func _refusal(q: String) -> Dictionary:
	var code := ""
	var secs := 0
	var ledger := _ledger()
	var left_ms := COOLDOWN_MS - (_now() - int(ledger["last_ms"]))
	if q.is_empty():
		code = "empty"
	elif not FeatureFlags.enabled("arena_ask"):
		code = "off"
	elif brain == null or brain.sim == null:
		code = "no_city"
	elif busy() or int(ledger["inflight"]) > 0:
		code = "busy"
	elif bool(ledger["asked"]) and left_ms > 0:
		code = "cooldown"
		secs = ceili(float(left_ms) / 1000.0)
	elif int((ledger["day_asks"] as Dictionary).get(int(brain.sim.day), 0)) >= PER_DAY:
		code = "daily"
	if code.is_empty():
		return {}
	var reason := str(REFUSALS[code]).replace("{s}", str(secs)).replace("{n}", str(PER_DAY))
	return _refuse(code, reason, secs)


## True when a question can go out live: a client with a key, live on and the breaker not open.
func live_possible() -> bool:
	var c: GmiClient = brain.client if brain != null else null
	return c != null and c.live_enabled and c.breaker_state() != CircuitBreaker.OPEN


## The system and user prompt mayor mi would get for question: their normal turn prompts, the
## question appended, and in neutral mode one shared persona line in place of their own.
func prompts_for(mi: int, question: String, mode: String, day: int) -> Dictionary:
	var system: String = brain._mayor_system_prompt(mi)
	if mode == "neutral":
		var own := "%s\n" % D.MAYORS[mi]["persona"]
		if system.begins_with(own):
			system = system.trim_prefix(own)
		system = NEUTRAL_PERSONA + "\n" + system
	var user: String = brain._mayor_user_prompt(mi, day)
	user += "\n\n%s: %s\n%s" % [QUESTION_HEAD, question, QUESTION_NOTE]
	return {"system": system, "user": user}


## Plausibility flags for a mayor's proposed actions, read off the sim without changing it:
## [{"i": index, "code": key of FLAG_TEXT, "text": words}]. Costs run in order against the
## district's treasury the way the sim spends them (an order it cannot afford costs nothing).
static func plausibility(sim: CitySim, mi: int, actions: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if sim == null or mi < 0 or mi >= sim.mayors.size():
		return out
	var rect := sim.district_rect(mi)
	var left := int(sim.mayors[mi]["treasury"])
	for i in range(actions.size()):
		if typeof(actions[i]) != TYPE_DICTIONARY:
			continue
		var chk := _check_action(sim, mi, rect, actions[i])
		var codes: Array = chk["codes"]
		var cost := int(chk["cost"])
		if i >= D.MAX_ACTIONS_PER_DAY:
			codes.append("beyond_limit")
		elif cost > 0:
			if left - cost >= -2000:
				left -= cost
			else:
				codes.append("unaffordable")
		for c: String in codes:
			out.append({"i": i, "code": c, "text": FLAG_TEXT[c]})
	return out


## What one proposed order costs and which codes of FLAG_TEXT it already earns: {"cost", "codes"}.
static func _check_action(sim: CitySim, mi: int, rect: Rect2i, a: Dictionary) -> Dictionary:
	var at := Vector2i(_num(a, "x", -99999), _num(a, "y", -99999))
	var cost := 0
	var codes: Array[String] = []
	# The tiles an order touches at its corners; every one must lie in the district.
	var corners: Array[Vector2i] = [at]
	match str(a.get("type", "")).to_lower():
		"road":
			var to := Vector2i(_num(a, "x2", at.x), _num(a, "y2", at.y))
			var tiles := mini(absi(to.x - at.x) + absi(to.y - at.y) + 1, D.MAX_ROAD_LEN)
			cost = tiles * int(D.grade_info(maxi(D.grade_of(str(a.get("grade", ""))), 0))["cost"])
			corners.append(to)
		"zone":
			var w := clampi(_num(a, "w", 1), 1, D.MAX_ZONE_SIDE)
			var h := clampi(_num(a, "h", 1), 1, D.MAX_ZONE_SIDE)
			cost = w * h * D.ZONE_COST
			corners.append(at + Vector2i(w - 1, h - 1))
		"build":
			var b: Dictionary = D.BUILDINGS.get(str(a.get("building", "")).to_lower(), {})
			cost = int(b.get("cost", 0))
			if b.is_empty():
				codes.append("unknown")
		"bulldoze":
			var bw := clampi(_num(a, "w", 1), 1, 3)
			cost = bw * clampi(_num(a, "h", 1), 1, 3) * D.BULLDOZE_COST
		"emergency":
			cost = D.EMERGENCY_COST
		"annex":
			cost = _plot_cost(sim, mi, at)
			corners.clear()
			if cost < 0:
				cost = 0
				codes.append("no_plot")
		"grant":
			var recipient := D.mayor_index(str(a.get("to", "")))
			cost = maxi(0, _num(a, "amount", 0))
			corners.clear()
			if recipient < 0 or recipient == mi or cost <= 0:
				codes.append("bad_grant")
		"set_tax", "tax":
			corners.clear()
		_:
			corners.clear()
			codes.append("unknown")
	for c in corners:
		if not rect.has_point(c):
			codes.append("outside")
			break
	return {"cost": cost, "codes": codes}


## The integer a model put under key of an order, or fallback when it is missing or not a number
## (null, a list, a word): a model's loose JSON must not stop the checks of its other orders.
static func _num(a: Dictionary, key: String, fallback: int) -> int:
	var v: Variant = a.get(key, fallback)
	match typeof(v):
		TYPE_INT:
			return int(v)
		TYPE_FLOAT:
			return int(v) if is_finite(v) else fallback
		TYPE_STRING:
			var t := (v as String).strip_edges()
			return (
				int(t) if t.is_valid_int() else (int(float(t)) if t.is_valid_float() else fallback)
			)
	return fallback


## A copy of an order whose number fields hold numbers: a null, list or word under one of
## NUMBER_KEYS is dropped (so the order reads as missing that number, as plausibility() does).
static func clean_action(a: Dictionary) -> Dictionary:
	var out := a.duplicate(true)
	for k: String in NUMBER_KEYS:
		if not out.has(k):
			continue
		var v: Variant = out[k]
		var ok := typeof(v) == TYPE_INT or (typeof(v) == TYPE_FLOAT and is_finite(v))
		if typeof(v) == TYPE_STRING:
			ok = (v as String).strip_edges().is_valid_float()
		if not ok:
			out.erase(k)
	return out


## The text cut to at most n characters, ending in an ellipsis when something was cut.
static func clip(text: String, n: int) -> String:
	if text.length() <= n:
		return text
	return text.left(n - 1).strip_edges(false, true) + "…"


## The price of the annexable plot containing tile at, or -1 when no plot there can be annexed.
static func _plot_cost(sim: CitySim, mi: int, at: Vector2i) -> int:
	for p: Dictionary in sim.annexable_plots(mi):
		var px := int(p["x"])
		var py := int(p["y"])
		if at.x >= px and at.x < px + 16 and at.y >= py and at.y < py + 16:
			return int(p["cost"])
	return -1


## "1st", "2nd" ... for a finish rank ("" for 0 or less).
static func ordinal(n: int) -> String:
	if n <= 0:
		return ""
	var suffix := "th"
	if n % 100 < 11 or n % 100 > 13:
		suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
	return "%d%s" % [n, suffix]


func _run_one(mi: int, mine: Dictionary, prompt: Dictionary) -> void:
	var m: Dictionary = D.MAYORS[mi]
	var data: Dictionary = {}
	var source := "offline"
	var err := ""
	if bool(mine["live"]):
		var res: Dictionary = await brain.client.live_json(
			ROLE,
			str(m["id"]),
			str(m["model"]),
			str(prompt["system"]),
			str(prompt["user"]),
			int(mine["day"]),
			MAX_TOKENS,
			timeout_s
		)
		_release(mine, mi)
		if not ((mine["results"] as Array)[mi] as Dictionary).is_empty():
			return  # the time budget already landed this column as failed
		if (
			bool(res.get("ok", false))
			and typeof(res.get("data")) == TYPE_DICTIONARY
			and not (res["data"] as Dictionary).is_empty()
		):
			data = res["data"]
			source = "live"
		else:
			err = _clean_error(str(res.get("error", "")))
			if err.is_empty():
				err = "no answer"
	if bool(mine["stale"]) or brain == null or int(mine["gen"]) != brain._generation:
		mine["stale"] = true
		return
	if source != "live":
		var fb := _fallback(mi, int(mine["day"]))
		data = fb["data"]
		source = str(fb["source"])
	_land(mi, mine, data, source, err)


## Gives back the budget slot of mayor mi's call (once): it answered, failed or timed out.
func _release(mine: Dictionary, mi: int) -> void:
	var held: Array = mine["held"]
	if bool(held[mi]):
		held[mi] = false
		var ledger := _ledger()
		ledger["inflight"] = maxi(0, int(ledger["inflight"]) - 1)


## Waits out the time budget, then lands every column still waiting as a failed one.
func _watch(mine: Dictionary) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	await tree.create_timer(timeout_s, true, false, true).timeout
	var current: bool = (
		brain != null
		and int(mine["gen"]) == brain._generation
		and not bool(mine["stale"])
		and not bool(mine["done"])
	)
	for mi in range(D.MAYORS.size()):
		if not ((mine["results"] as Array)[mi] as Dictionary).is_empty():
			continue
		_release(mine, mi)
		if not current:
			mine["stale"] = true
			continue
		var fb := _fallback(mi, int(mine["day"]))
		_land(mi, mine, fb["data"], str(fb["source"]), "timed out after %d s" % ceili(timeout_s))


## The mayor's last recorded turn nearest today from the replay cache (a session's own live turns
## are not a recording), else the scripted planner's.
func _fallback(mi: int, day: int) -> Dictionary:
	var key := "mayor|%s" % str(D.MAYORS[mi]["id"])
	var rec := _recorded(key, day)
	if not rec.is_empty():
		return {"data": rec, "source": "recorded"}
	return {"data": brain._heuristic_mayor(mi), "source": "offline"}


## The replay-cache entry of key nearest day, {} when there is none.
func _recorded(key: String, day: int) -> Dictionary:
	var c: GmiClient = brain.client
	if c == null or not c.replay_cache.has(key):
		return {}
	var best: Dictionary = {}
	var best_d := 1 << 30
	for e: Variant in c.replay_cache[key] as Array:
		if typeof(e) != TYPE_DICTIONARY or typeof((e as Dictionary).get("data")) != TYPE_DICTIONARY:
			continue
		var dd := absi(int((e as Dictionary).get("day", 0)) - day)
		if dd < best_d:
			best_d = dd
			best = (e as Dictionary)["data"]
	return best


func _land(mi: int, mine: Dictionary, data: Dictionary, source: String, err: String) -> void:
	var m: Dictionary = D.MAYORS[mi]
	var raw: Variant = data.get("actions", [])
	var acts: Array = []
	if typeof(raw) == TYPE_ARRAY:
		for v: Variant in raw as Array:
			if typeof(v) == TYPE_DICTIONARY:
				acts.append(clean_action(v))
	var extra := maxi(0, acts.size() - D.MAX_ACTIONS_PER_DAY)
	acts = acts.slice(0, D.MAX_ACTIONS_PER_DAY)
	var prop := str(data.get("propose_ordinance", "")).strip_edges().to_lower()
	mine["landed"] = int(mine["landed"]) + 1
	var rank := 0
	if source == "live":
		mine["live_landed"] = int(mine["live_landed"]) + 1
		rank = int(mine["live_landed"])
	var result := {
		"mi": mi,
		"who": str(m["display"]),
		"model": str(m["name"]),
		"thought": clip(D.debrand(str(data.get("thought", ""))), THOUGHT_MAX),
		"post": clip(D.debrand(str(data.get("public_post", ""))), POST_MAX),
		"proposal": str(D.ORDINANCES[prop]["label"]) if D.ORDINANCES.has(prop) else "",
		"actions": acts,
		"flags": plausibility(brain.sim, mi, acts),
		"extra_actions": extra,
		"elapsed_s": elapsed_s(mine),
		"finish_rank": rank,
		"source": source,
		"error": err,
	}
	(mine["results"] as Array)[mi] = result
	(mine["order"] as Array).append(mi)
	answered.emit(result)
	if int(mine["landed"]) >= D.MAYORS.size():
		mine["done"] = true
		finished.emit(mine)


## The budget ledger {asked, last_ms, day_asks, inflight}: kept on the GmiClient (the key's session,
## which outlives a city) so New City and Load cannot reset the cooldown, the daily count or the
## calls still in flight.
func _ledger() -> Dictionary:
	var holder: Object = brain.client if brain != null and brain.client != null else null
	if holder == null:
		if _local_ledger.is_empty():
			_local_ledger = _new_ledger()
		return _local_ledger
	if not holder.has_meta(LEDGER_META):
		holder.set_meta(LEDGER_META, _new_ledger())
	return holder.get_meta(LEDGER_META)


static func _new_ledger() -> Dictionary:
	return {"asked": false, "last_ms": 0, "day_asks": {}, "inflight": 0}


## An error line for the screen: scrubbed of keys and cut short.
func _clean_error(e: String) -> String:
	var secrets := PackedStringArray()
	if brain != null and brain.client != null:
		secrets.append(brain.client.api_key)
		secrets.append(brain.client.player_key)
	return Redact.scrub(e, secrets).left(120)


func _refuse(code: String, reason: String, retry_s: int = 0) -> Dictionary:
	return {"ok": false, "code": code, "reason": reason, "retry_in_s": retry_s}


func _now() -> int:
	return int(clock.call())
