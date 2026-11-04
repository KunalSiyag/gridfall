class_name ModelLedger
extends RefCounted
## What each model has done in this city: calls, how many answered live, failed, fell back to a
## recorded answer or to the scripted planner, how long they took to answer, which errors they
## got, which repairs their replies needed, how many tokens they used and, for the mayors, how
## many of their orders the city accepted. It is the one place the street league, the orbit Arena
## tab and the "Services & minds" page read; nothing here draws.
##
## It is fed by two things only: GmiClient.call_logged / call_skipped (attach) for the calls, and
## CityBrain.mayor_decided (note_turn) for the orders. It lives in memory, owned by the brain
## (brain.ledger), and a save keeps a bounded copy (to_dict). Flag model_ledger turns it all off.
##
## Reading the numbers honestly:
## - "time to answer" is the call's latency_ms, which covers retries, back-off and waiting behind
##   the other calls in flight: it is how long the city waited, not how fast the model is.
## - A mayor answers once a game day, so its p50 and p95 rest on a handful of calls: rows carry
##   n_live, and p95 is only reported from P95_MIN_CALLS live answers on (-1 before).
## - replay and fallback count answers that did not come live (a recorded answer, the scripted
##   planner after a failed or skipped call); a call whose live attempt failed and was then
##   replayed counts in both live_fail and replay.
## - Accept% is the share of a mayor's orders the sim carried out, counted from this ledger's start
##   (a save from before the ledger starts at zero). It covers live and replayed turns, because the
##   sim validates every order whoever wrote it; the scripted planner's orders (a failed or skipped
##   call) are not counted, they are not the model's. A replayed day may also carry up to two orders
##   the replay top-up borrowed from the planner (CityBrain._replay_top_up).

const D := preload("res://scripts/sim/sim_defs.gd")
## Events kept for a timeline; a save keeps the newest SAVED_EVENTS of them.
const MAX_EVENTS := 400
const SAVED_EVENTS := 40
## Live answer times kept per model (the newest), for p50 and p95.
const LAT_KEEP := 50
## Outcomes kept for the health light.
const RECENT_KEEP := 8
const MAX_MODELS := 48
const MAX_ERROR_CLASSES := 12
## Live answers a p95 needs before it means anything.
const P95_MIN_CALLS := 5
## A p95 time to answer slower than this (ms) makes the light amber.
const SLOW_MS := 30000
const SAVE_VERSION := 1
## Outcome codes in a stat's "recent": answered live clean, answered live with a repair or a retry,
## failed.
const OUT_OK := 0
const OUT_WARN := 1
const OUT_FAIL := 2
## Errors that mean the call never went out (not a failed attempt).
const SKIPS := ["offline", "circuit open", "no free slot"]
const ROLE_NAMES := {
	"residents": "Residents",
	"chatter": "Chat",
	"talk": "Talk",
}

## Bumped on every note: a view compares it with the one it drew to know it is stale.
var revision: int = 0
## model id -> stat dict (see _new_stat); "mayor:<id>" -> the same for one mayor's own calls.
var models: Dictionary = {}
var agents: Dictionary = {}
## model id -> stat dict of what the model did OUTSIDE the mayors' chairs (the support agents, the
## residents, the chat voices). A model can sit in a chair and hold a service job (one of the
## resident minds is a mayor's model): its service row must not carry the mayor's answers.
var svc: Dictionary = {}
## One per mayor index: {"live", "replay", "fallback", "offline" (turns by where the answer
## came from), "ok", "rejected" (orders), "mix" (order type -> count)}.
var turns: Array[Dictionary] = []
var events: Array[Dictionary] = []
var _client: GmiClient = null
static var _date_re: RegEx


func _init() -> void:
	_reset_turns()


## True unless the model_ledger flag is off.
static func enabled() -> bool:
	return FeatureFlags.enabled("model_ledger", true)


## Starts listening to client's calls (and stops listening to the previous client's). reset true
## also forgets what was counted: a new city starts its own ledger.
func attach(client: GmiClient, reset: bool = false) -> void:
	if reset:
		clear()
	if _client != null and is_instance_valid(_client):
		if _client.call_logged.is_connected(note_call):
			_client.call_logged.disconnect(note_call)
		if _client.call_skipped.is_connected(note_call):
			_client.call_skipped.disconnect(note_call)
	_client = client
	if client == null or not enabled():
		return
	client.call_logged.connect(note_call)
	client.call_skipped.connect(note_call)


## Forgets every count.
func clear() -> void:
	models.clear()
	agents.clear()
	svc.clear()
	events.clear()
	_reset_turns()
	revision += 1


# ------------------------------------------------------------------ feeding


## One call (a GmiClient log record, slim or not): role, agent, model, source, latency_ms,
## attempts, error, tokens_in, tokens_out, finish_reason, repairs. A record without a model is
## ignored, and so is one of an isolated role (GmiClient.ISOLATED_ROLES: Ask the five): those calls
## promise to leave the breaker, the caches and the saves alone, and five parallel what-if answers
## would also skew the mayors' speed.
func note_call(rec: Dictionary) -> void:
	var model := str(rec.get("model", ""))
	if model.is_empty() or not enabled() or str(rec.get("role", "")) in GmiClient.ISOLATED_ROLES:
		return
	if not models.has(model) and models.size() >= MAX_MODELS:
		return
	_apply(_stat(models, model), rec)
	if str(rec.get("role", "")) == "mayor":
		_apply(_stat(agents, "mayor:" + str(rec.get("agent", ""))), rec)
	elif svc.has(model) or svc.size() < MAX_MODELS:
		_apply(_stat(svc, model), rec)
	var err := error_class(str(rec.get("error", "")))
	_push(
		{
			"kind": "call",
			"model": model,
			"role": str(rec.get("role", "")),
			"agent": str(rec.get("agent", "")),
			"day": int(rec.get("day", 0)),
			"source": str(rec.get("source", "")),
			"ms": int(rec.get("latency_ms", 0)),
			"err": err,
			"repairs": _strings(rec.get("repairs", []))
		}
	)
	revision += 1


## One mayor's decided turn (the entry CityBrain.mayor_decided carries): where the answer came from
## and how the city took the orders.
func note_turn(mi: int, entry: Dictionary) -> void:
	if mi < 0 or mi >= turns.size() or not enabled():
		return
	var t := turns[mi]
	var source := str(entry.get("source", ""))
	var failed := not str(entry.get("error", "")).is_empty()
	match source:
		"live":
			t["live"] = int(t["live"]) + 1
		"cache":
			t["replay"] = int(t["replay"]) + 1
		_:
			t["fallback" if failed else "offline"] = int(t["fallback" if failed else "offline"]) + 1
	var acts: Array = entry.get("actions", []) if typeof(entry.get("actions")) == TYPE_ARRAY else []
	if source != "live" and source != "cache":
		# The scripted planner's orders are not the model's: a mayor whose model never answers must
		# not be credited with them.
		acts = []
	for v: Variant in acts:
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var a: Dictionary = v
		if bool(a.get("ok", false)):
			t["ok"] = int(t["ok"]) + 1
		else:
			t["rejected"] = int(t["rejected"]) + 1
		var act: Variant = a.get("action", {})
		var kind := (
			str((act as Dictionary).get("type", "?")) if typeof(act) == TYPE_DICTIONARY else "?"
		)
		var mix: Dictionary = t["mix"]
		if mix.has(kind) or mix.size() < 24:
			mix[kind] = int(mix.get(kind, 0)) + 1
	_push(
		{
			"kind": "turn",
			"model": str(entry.get("model", "")),
			"role": "mayor",
			"agent": str(D.MAYORS[mi]["id"]),
			"day": int(entry.get("day", 0)),
			"source": source,
			"ms": int(entry.get("latency_ms", 0)),
			"err": error_class(str(entry.get("error", ""))),
			"repairs": [],
			"ok": int(t["ok"]),
			"rejected": int(t["rejected"])
		}
	)
	revision += 1


# ------------------------------------------------------------------ reading


## One row per model that made a call, busiest first: {"model", "label", "roles" (role -> calls),
## "calls", "live_ok", "live_fail", "replay", "fallback", "offline", "retries", "n_live",
## "last_ms", "mean_ms", "p50_ms", "p95_ms" (-1 when there is nothing to say), "errors" (class ->
## count), "repairs" (calls that needed one), "repair_kinds", "truncated" (cut off at max_tokens),
## "tokens_in", "tokens_out", "token_calls", "health"}. Orders and their accepted share are per
## mayor (mayor_rows): a model is not an order-giver.
func snapshot() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for model: String in models.keys():
		var row := _row(models[model])
		row["model"] = model
		row["label"] = short_name(model)
		rows.append(row)
	rows.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["calls"]) != int(b["calls"]):
				return int(a["calls"]) > int(b["calls"])
			return str(a["model"]) < str(b["model"])
	)
	return rows


## The five mayors in order: {"mi", "id", "who" (the person), "model" (the brand), "model_id",
## "label", "color"} plus the row fields of snapshot() for that mayor's own calls, "turns_live",
## "turns_replay", "turns_fallback", "turns_offline", "orders_ok", "orders_rejected", "accept_pct"
## (-1 before any order), "mix" (order type -> count) and "health".
func mayor_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for mi in range(D.MAYORS.size()):
		var m: Dictionary = D.MAYORS[mi]
		var row := _row(agents.get("mayor:" + str(m["id"]), _new_stat()))
		row["mi"] = mi
		row["id"] = str(m["id"])
		row["who"] = str(m["display"])
		row["model"] = str(m["name"])
		row["model_id"] = str(m["model"])
		row["label"] = short_name(str(m["model"]))
		row["color"] = str(m["color"])
		var t := turns[mi]
		row["turns_live"] = int(t["live"])
		row["turns_replay"] = int(t["replay"])
		row["turns_fallback"] = int(t["fallback"])
		row["turns_offline"] = int(t["offline"])
		row["orders_ok"] = int(t["ok"])
		row["orders_rejected"] = int(t["rejected"])
		row["accept_pct"] = _pct(int(t["ok"]), int(t["ok"]) + int(t["rejected"]))
		row["mix"] = (t["mix"] as Dictionary).duplicate()
		rows.append(row)
	return rows


## One row per model the city uses outside the mayors' chairs (the support agents, the resident
## minds, the chat voices), known ones first even before they have made a call: {"model",
## "label", "kinds" (names of the jobs it has or is meant to have), "mix" ("Gazette 4 · Chat 9"),
## "calls" (outside the mayors), "live_ok", "live_fail", "replay", "fallback", "offline", "p50_ms",
## "health"}. A model is one row however many jobs it has.
func services() -> Array[Dictionary]:
	var by_model := {}
	for entry: Dictionary in roster():
		var row: Dictionary = by_model.get(
			str(entry["model"]), {"model": str(entry["model"]), "names": []}
		)
		if not (row["names"] as Array).has(entry["name"]):
			(row["names"] as Array).append(entry["name"])
		by_model[str(entry["model"])] = row
	for model: String in svc.keys():
		if not by_model.has(model):
			by_model[model] = {"model": model, "names": []}
	var rows: Array[Dictionary] = []
	for model: String in by_model.keys():
		var st: Dictionary = svc.get(model, _new_stat())
		var out := _row(st)
		var roles: Dictionary = st["roles"]
		var parts: Array[String] = []
		var names: Array = (by_model[model] as Dictionary)["names"]
		for role: String in roles.keys():
			var nm := role_name(role)
			parts.append("%s %d" % [nm, int(roles[role])])
			if not names.has(nm):
				names.append(nm)
		out["model"] = model
		out["label"] = short_name(model)
		out["kinds"] = names
		out["mix"] = (
			" · ".join(PackedStringArray(parts))
			if not parts.is_empty()
			else ", ".join(PackedStringArray(names))
		)
		rows.append(out)
	rows.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["calls"]) != int(b["calls"]):
				return int(a["calls"]) > int(b["calls"])
			return str(a["model"]) < str(b["model"])
	)
	return rows


## The models the city is meant to run outside the mayors: [{"model", "name"}] for the six support
## agents, the resident minds and the chat voices.
static func roster() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for key: String in D.SUPPORT_AGENTS.keys():
		var a: Dictionary = D.SUPPORT_AGENTS[key]
		out.append({"model": str(a["model"]), "name": str(a["name"])})
	for m: Variant in ResidentMinds.MODELS:
		out.append({"model": str(m), "name": "Residents"})
	for m: Variant in ChatterMinds.MODEL_NAMES:
		out.append({"model": str(m), "name": "Chat"})
	return out


## The newest events, oldest first (at most n).
func recent_events(n: int = 60) -> Array[Dictionary]:
	return events.slice(maxi(events.size() - n, 0))


## A job's name as a viewer reads it: a support agent's own name, else ROLE_NAMES, else the role.
static func role_name(role: String) -> String:
	if D.SUPPORT_AGENTS.has(role):
		return str(D.SUPPORT_AGENTS[role]["name"])
	return str(ROLE_NAMES.get(role, role.capitalize()))


## The model id without its vendor and a trailing date stamp ("deepseek-ai/DeepSeek-V4-Flash-0731"
## -> "DeepSeek-V4-Flash").
static func short_name(model_id: String) -> String:
	if _date_re == null:
		_date_re = RegEx.create_from_string("-\\d{4}$")
	var s := model_id.get_slice("/", model_id.get_slice_count("/") - 1)
	return _date_re.sub(s, "")


## The kind of failure an error text is: an HTTP code ("429"), "network", "no JSON", "bad reply",
## "skipped" (the call never went out) or "other"; "" for no error.
static func error_class(err: String) -> String:
	if err.is_empty():
		return ""
	if err in SKIPS:
		return "skipped"
	if err.begins_with("HTTP "):
		var code := err.get_slice(" ", 1)
		return code if code.is_valid_int() else "other"
	if err.begins_with("network result") or err.begins_with("request error"):
		return "network"
	if err.begins_with("no JSON"):
		return "no JSON"
	if err.begins_with("no choices") or err.begins_with("bad response"):
		return "bad reply"
	return "other"


## The p-th percentile (0..100, nearest rank) of values; -1 when there are none.
static func percentile(values: Array, p: float) -> int:
	if values.is_empty():
		return -1
	var sorted := values.duplicate()
	sorted.sort()
	var rank := int(ceil(p / 100.0 * float(sorted.size()))) - 1
	return int(sorted[clampi(rank, 0, sorted.size() - 1)])


## "11.2 s" for a time in ms; "-" for none.
static func seconds_text(ms: int) -> String:
	return "-" if ms < 0 else "%.1f s" % (float(ms) / 1000.0)


## The health word for a stat dict: "idle" (no call yet), "grey" (nothing but replay and scripted
## answers: no live call to judge), "red" (the last two live calls failed), "amber" (a recent
## failure, repair or retry, or a p95 slower than SLOW_MS over at least P95_MIN_CALLS answers), else
## "green".
static func health_of(st: Dictionary) -> String:
	if int(st.get("calls", 0)) == 0:
		return "idle"
	if int(st.get("live_ok", 0)) + int(st.get("live_fail", 0)) == 0:
		return "grey"
	var recent: Array = st.get("recent", [])
	var n := recent.size()
	if n >= 2 and int(recent[n - 1]) == OUT_FAIL and int(recent[n - 2]) == OUT_FAIL:
		return "red"
	for code: Variant in recent.slice(maxi(n - 5, 0)):
		if int(code) != OUT_OK:
			return "amber"
	var lat: Array = st.get("lat", [])
	# One slow answer is not a pattern: like the rows, a p95 needs P95_MIN_CALLS answers.
	if lat.size() >= P95_MIN_CALLS and percentile(lat, 95.0) > SLOW_MS:
		return "amber"
	return "green"


# ------------------------------------------------------------------ save


## A bounded copy for a save: every stat (their lists are capped), the five mayors' turn counts
## and the newest SAVED_EVENTS events (without their wall-clock stamp). A day of play adds
## nothing: it only moves the same numbers.
func to_dict() -> Dictionary:
	var m := {}
	for k: String in models.keys():
		m[k] = _compact(models[k])
	var a := {}
	for k: String in agents.keys():
		a[k] = _compact(agents[k])
	var sv := {}
	for k: String in svc.keys():
		sv[k] = _compact(svc[k])
	var t: Array = []
	for e: Dictionary in turns:
		t.append(e.duplicate(true))
	var ev: Array = []
	for e: Dictionary in events.slice(maxi(events.size() - SAVED_EVENTS, 0)):
		var kept := e.duplicate(true)
		# The wall clock stays out of a save: a save is a function of the game, so two runs of
		# one seed save the same bytes (sim_determinism_test, sim_tick_budget_test).
		kept.erase("at")
		ev.append(kept)
	return {"v": SAVE_VERSION, "models": m, "agents": a, "svc": sv, "turns": t, "events": ev}


## Loads what to_dict wrote. Anything missing or of the wrong type is skipped: a save is a file
## anyone can edit.
func from_dict(d: Dictionary) -> void:
	clear()
	if d.is_empty():
		return
	_load_stats(models, d.get("models"), MAX_MODELS)
	_load_stats(agents, d.get("agents"), D.MAYORS.size())
	_load_stats(svc, d.get("svc"), MAX_MODELS)
	var t: Variant = d.get("turns")
	if typeof(t) == TYPE_ARRAY:
		for i in range(mini((t as Array).size(), turns.size())):
			if typeof((t as Array)[i]) == TYPE_DICTIONARY:
				_load_turn(turns[i], (t as Array)[i])
	var ev: Variant = d.get("events")
	if typeof(ev) == TYPE_ARRAY:
		for e: Variant in (ev as Array).slice(-SAVED_EVENTS):
			if typeof(e) == TYPE_DICTIONARY:
				events.append(_clean_event(e))
	revision += 1


# ------------------------------------------------------------------ internals


func _reset_turns() -> void:
	turns.clear()
	for _i in range(D.MAYORS.size()):
		turns.append(
			{"live": 0, "replay": 0, "fallback": 0, "offline": 0, "ok": 0, "rejected": 0, "mix": {}}
		)


func _new_stat() -> Dictionary:
	return {
		"calls": 0,
		"live_ok": 0,
		"live_fail": 0,
		"replay": 0,
		"fallback": 0,
		"offline": 0,
		"retries": 0,
		"lat": [],
		"lat_sum": 0,
		"errors": {},
		"repairs": 0,
		"repair_kinds": {},
		"truncated": 0,
		"tokens_in": 0,
		"tokens_out": 0,
		"token_calls": 0,
		"roles": {},
		"recent": [],
		"last_ms": -1
	}


func _stat(table: Dictionary, key: String) -> Dictionary:
	if not table.has(key):
		table[key] = _new_stat()
	return table[key]


## Counts one call record into a stat dict.
func _apply(st: Dictionary, rec: Dictionary) -> void:
	st["calls"] = int(st["calls"]) + 1
	var role := str(rec.get("role", "?"))
	var roles: Dictionary = st["roles"]
	if roles.has(role) or roles.size() < 12:
		roles[role] = int(roles.get(role, 0)) + 1
	var source := str(rec.get("source", ""))
	var err := str(rec.get("error", ""))
	var attempts := int(rec.get("attempts", 0))
	if attempts > 1:
		st["retries"] = int(st["retries"]) + attempts - 1
	if source == "live":
		_count_live(st, rec, attempts)
	elif not err.is_empty() and not err in SKIPS:
		st["live_fail"] = int(st["live_fail"]) + 1
		_count_error(st, err)
		# A reply that came back but held no answer (cut off, reasoning only) still cost tokens.
		_count_usage(st, rec)
		_remember_outcome(st, OUT_FAIL)
	match source:
		"cache":
			st["replay"] = int(st["replay"]) + 1
		"heuristic":
			var key := "fallback" if not err.is_empty() else "offline"
			st[key] = int(st[key]) + 1
		"failed", "":
			# live_json: it failed, or it never went out (offline, circuit open, no free slot).
			var key2 := "offline" if err == "offline" else "fallback"
			st[key2] = int(st[key2]) + 1


func _count_live(st: Dictionary, rec: Dictionary, attempts: int) -> void:
	var ms := maxi(int(rec.get("latency_ms", 0)), 0)
	st["live_ok"] = int(st["live_ok"]) + 1
	st["last_ms"] = ms
	st["lat_sum"] = int(st["lat_sum"]) + ms
	var lat: Array = st["lat"]
	lat.append(ms)
	while lat.size() > LAT_KEEP:
		lat.pop_front()
	var repairs := _strings(rec.get("repairs", []))
	if not repairs.is_empty():
		st["repairs"] = int(st["repairs"]) + 1
		var kinds: Dictionary = st["repair_kinds"]
		for r: String in repairs:
			kinds[r] = int(kinds.get(r, 0)) + 1
	_count_usage(st, rec)
	_remember_outcome(st, OUT_WARN if (not repairs.is_empty() or attempts > 1) else OUT_OK)


## What a reply that arrived says about its size: cut off at max_tokens, and the tokens it used.
func _count_usage(st: Dictionary, rec: Dictionary) -> void:
	if str(rec.get("finish_reason", "")) == "length":
		st["truncated"] = int(st["truncated"]) + 1
	var tin := int(rec.get("tokens_in", -1))
	var tout := int(rec.get("tokens_out", -1))
	if tin >= 0 or tout >= 0:
		st["tokens_in"] = int(st["tokens_in"]) + maxi(tin, 0)
		st["tokens_out"] = int(st["tokens_out"]) + maxi(tout, 0)
		st["token_calls"] = int(st["token_calls"]) + 1


func _count_error(st: Dictionary, err: String) -> void:
	var cls := error_class(err)
	var errors: Dictionary = st["errors"]
	if errors.has(cls) or errors.size() < MAX_ERROR_CLASSES:
		errors[cls] = int(errors.get(cls, 0)) + 1


func _remember_outcome(st: Dictionary, code: int) -> void:
	var recent: Array = st["recent"]
	recent.append(code)
	while recent.size() > RECENT_KEEP:
		recent.pop_front()


func _push(e: Dictionary) -> void:
	e["seq"] = (int(events[-1]["seq"]) + 1) if not events.is_empty() else 1
	e["at"] = Time.get_ticks_msec()
	events.append(e)
	while events.size() > MAX_EVENTS:
		events.pop_front()


## The row fields every table shares, derived from a stat dict.
func _row(st: Dictionary) -> Dictionary:
	var lat: Array = st["lat"]
	var n := lat.size()
	var live := int(st["live_ok"])
	return {
		"calls": int(st["calls"]),
		"live_ok": live,
		"live_fail": int(st["live_fail"]),
		"replay": int(st["replay"]),
		"fallback": int(st["fallback"]),
		"offline": int(st["offline"]),
		"retries": int(st["retries"]),
		"n_live": live,
		"last_ms": int(st["last_ms"]),
		"mean_ms": (int(st["lat_sum"]) / live) if live > 0 else -1,
		"p50_ms": percentile(lat, 50.0),
		"p95_ms": percentile(lat, 95.0) if n >= P95_MIN_CALLS else -1,
		"errors": (st["errors"] as Dictionary).duplicate(),
		"repairs": int(st["repairs"]),
		"repair_kinds": (st["repair_kinds"] as Dictionary).duplicate(),
		"truncated": int(st["truncated"]),
		"tokens_in": int(st["tokens_in"]),
		"tokens_out": int(st["tokens_out"]),
		"token_calls": int(st["token_calls"]),
		"roles": (st["roles"] as Dictionary).duplicate(),
		"health": health_of(st),
	}


static func _pct(part: int, whole: int) -> int:
	return roundi(100.0 * float(part) / float(whole)) if whole > 0 else -1


static func _strings(v: Variant) -> Array:
	var out: Array = []
	if typeof(v) == TYPE_ARRAY:
		for x: Variant in (v as Array).slice(0, 8):
			out.append(str(x).left(24))
	return out


func _compact(st: Dictionary) -> Dictionary:
	var out := st.duplicate(true)
	out["lat"] = (st["lat"] as Array).slice(-LAT_KEEP)
	out["recent"] = (st["recent"] as Array).slice(-RECENT_KEEP)
	return out


func _load_stats(into: Dictionary, src: Variant, cap: int) -> void:
	if typeof(src) != TYPE_DICTIONARY:
		return
	for k: Variant in (src as Dictionary).keys():
		if into.size() >= cap:
			return
		var v: Variant = (src as Dictionary)[k]
		if typeof(k) == TYPE_STRING and typeof(v) == TYPE_DICTIONARY:
			into[str(k).left(80)] = _clean_stat(v as Dictionary)


## A saved stat read back into a well-formed one: numbers are numbers, lists are bounded.
func _clean_stat(src: Dictionary) -> Dictionary:
	var st := _new_stat()
	for k: String in [
		"calls",
		"live_ok",
		"live_fail",
		"replay",
		"fallback",
		"offline",
		"retries",
		"lat_sum",
		"repairs",
		"truncated",
		"tokens_in",
		"tokens_out",
		"token_calls",
		"last_ms"
	]:
		st[k] = _num(src.get(k), -1 if k == "last_ms" else 0)
	for k: String in ["lat", "recent"]:
		var out: Array = []
		var v: Variant = src.get(k)
		if typeof(v) == TYPE_ARRAY:
			for x: Variant in (v as Array).slice(-(LAT_KEEP if k == "lat" else RECENT_KEEP)):
				out.append(_num(x, 0))
		st[k] = out
	for k: String in ["errors", "repair_kinds", "roles"]:
		var counts := {}
		var v: Variant = src.get(k)
		if typeof(v) == TYPE_DICTIONARY:
			for c: Variant in (v as Dictionary).keys():
				if counts.size() < 12:
					counts[str(c).left(24)] = _num((v as Dictionary)[c], 0)
		st[k] = counts
	return st


func _load_turn(into: Dictionary, src: Dictionary) -> void:
	for k: String in ["live", "replay", "fallback", "offline", "ok", "rejected"]:
		into[k] = _num(src.get(k), 0)
	var mix: Variant = src.get("mix")
	if typeof(mix) == TYPE_DICTIONARY:
		for c: Variant in (mix as Dictionary).keys():
			if (into["mix"] as Dictionary).size() < 24:
				(into["mix"] as Dictionary)[str(c).left(24)] = _num((mix as Dictionary)[c], 0)


func _clean_event(e: Variant) -> Dictionary:
	var src: Dictionary = e
	var out := {
		"kind": str(src.get("kind", "call")).left(8),
		"model": str(src.get("model", "")).left(80),
		"role": str(src.get("role", "")).left(16),
		"agent": str(src.get("agent", "")).left(24),
		"source": str(src.get("source", "")).left(12),
		"err": str(src.get("err", "")).left(12),
		"repairs": _strings(src.get("repairs", []))
	}
	for k: String in ["day", "ms", "seq", "at", "ok", "rejected"]:
		if src.has(k) or k in ["day", "ms", "seq", "at"]:
			out[k] = _num(src.get(k), 0)
	return out


static func _num(v: Variant, fallback: int) -> int:
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		var f := float(v)
		return int(clampf(f, -1.0, 1.0e9)) if is_finite(f) else fallback
	return fallback
