class_name GmiReadiness
extends RefCounted
## "Which of the 14 models does this key reach?" Pure helpers for GmiClient.preflight.run(): the
## list of model ids the game is configured to call (mayors, support agents, the resident and
## chatter pools), the ids a GET /v1/models reply names, their comparison, and the sentence the key
## panel shows. Nothing here touches the network or a node, so tools/tests/fp_gmi_ready_test.gd
## runs it with canned replies.
##
## What a missing model means: a mayor or a support agent whose model is missing plays from the
## recorded days or the scripted planner ("will use the offline planner"). A model of the resident
## or chatter pool is skipped: those callers rotate to another model after a few failures.

const D := preload("res://scripts/sim/sim_defs.gd")


## Every distinct model id the game calls, in a stable order, each with who uses it:
## [{"id", "users": [{"kind": "mayor" | "agent" | "pool", "name"}]}].
static func configured() -> Array[Dictionary]:
	var by_id := {}
	var order: Array[String] = []
	for m: Dictionary in D.MAYORS:
		_add(by_id, order, str(m["model"]), "mayor", str(m["display"]))
	for role: String in D.SUPPORT_AGENTS:
		var a: Dictionary = D.SUPPORT_AGENTS[role]
		_add(by_id, order, str(a["model"]), "agent", str(a["name"]))
	for id: String in ResidentMinds.MODELS:
		_add(by_id, order, id, "pool", "resident minds")
	for id: String in ChatterMinds.MODEL_NAMES:
		_add(by_id, order, id, "pool", "street chatter")
	var out: Array[Dictionary] = []
	for id: String in order:
		out.append({"id": id, "users": by_id[id]})
	return out


## How many distinct models the game calls (14 today).
static func total() -> int:
	return configured().size()


## The model ids a GET /v1/models reply names: the "id" (or the string itself) of each entry of its
## "data" or "models" list, or of a bare list. [] when the text is not such a reply.
static func ids_from_body(text: String) -> Array[String]:
	var out: Array[String] = []
	var json := JSON.new()
	if json.parse(text) != OK:
		return out
	var list: Variant = json.data
	if typeof(list) == TYPE_DICTIONARY:
		var d: Dictionary = list
		list = d.get("data", d.get("models", []))
	if typeof(list) != TYPE_ARRAY:
		return out
	for e: Variant in list as Array:
		var id := ""
		if typeof(e) == TYPE_STRING:
			id = e as String
		elif typeof(e) == TYPE_DICTIONARY:
			id = str((e as Dictionary).get("id", ""))
		if not id.strip_edges().is_empty():
			out.append(id.strip_edges())
	return out


## Compares the ids a reply named with the configured ones: {"total", "available", "missing" (ids),
## "offline" (names of the mayors and agents that will use the offline planner), "skipped" (how
## many missing models belong only to the resident and chatter pools), "listed" (ids in the
## reply)}. Ids match without regard to case.
static func compare(listed: Array) -> Dictionary:
	var have := {}
	for id: Variant in listed:
		have[str(id).to_lower()] = true
	var cfg := configured()
	var missing: Array[String] = []
	var offline: Array[String] = []
	var skipped := 0
	for entry: Dictionary in cfg:
		if have.has(str(entry["id"]).to_lower()):
			continue
		missing.append(str(entry["id"]))
		var city_user := false
		for u: Dictionary in entry["users"]:
			if str(u["kind"]) == "pool":
				continue
			city_user = true
			if not offline.has(str(u["name"])):
				offline.append(str(u["name"]))
		if not city_user:
			skipped += 1
	return {
		"total": cfg.size(),
		"available": cfg.size() - missing.size(),
		"missing": missing,
		"offline": offline,
		"skipped": skipped,
		"listed": listed.size(),
	}


## The report for what GmiClient._models_trip returned ({"start_error": int}, or {"result", "http",
## "headers", "body"}): compare()'s result plus "ok" true, or {"ok": false, "error": a few words}.
## Never any text of the reply (an error body can echo the key). timeout_s is only worded.
static func from_trip(trip: Dictionary, timeout_s: float) -> Dictionary:
	if trip.has("start_error"):
		return {"ok": false, "error": "the request could not start"}
	var result_code := int(trip.get("result", HTTPRequest.RESULT_CANT_CONNECT))
	var http := int(trip.get("http", 0))
	if result_code != HTTPRequest.RESULT_SUCCESS:
		if result_code == HTTPRequest.RESULT_TIMEOUT:
			return {"ok": false, "error": "no answer in %.0f s" % timeout_s}
		return {"ok": false, "error": "blocked by the browser or offline"}
	if http != 200:
		return {"ok": false, "error": "HTTP %d" % http, "http": http}
	var body: PackedByteArray = trip.get("body", PackedByteArray())
	var ids := ids_from_body(body.get_string_from_utf8())
	if ids.is_empty():
		return {"ok": false, "error": "the reply is not a model list"}
	var report := compare(ids)
	if int(report["available"]) == 0:
		report["ok"] = false
		report["error"] = "it names none of the %d models" % int(report["total"])
		return report
	report["ok"] = true
	return report


## The sentence for a finished check. report is compare()'s result with "ok" and, when the check
## failed, "error" (a few words). "" for an empty report.
static func line(report: Dictionary) -> String:
	if report.is_empty():
		return ""
	if not bool(report.get("ok", false)):
		return (
			"Could not check the model list (%s). The Test button checks the key."
			% str(report.get("error", "no answer"))
		)
	var total_n := int(report["total"])
	var have_n := int(report["available"])
	if have_n >= total_n:
		return "All %d models available." % total_n
	var text := "%d of %d models available" % [have_n, total_n]
	var offline: Array = report.get("offline", [])
	var parts: Array[String] = []
	if not offline.is_empty():
		parts.append("%s will use the offline planner" % _join(offline))
	var skipped := int(report.get("skipped", 0))
	if skipped > 0:
		parts.append(
			"%d resident or chat model%s will be skipped" % [skipped, "" if skipped == 1 else "s"]
		)
	if not parts.is_empty():
		text += "; " + "; ".join(PackedStringArray(parts))
	return text + "."


## "A", "A and B", "A, B and C".
static func _join(names: Array) -> String:
	var items := PackedStringArray()
	for n: Variant in names:
		items.append(str(n))
	if items.size() <= 1:
		return "".join(items)
	return "%s and %s" % [", ".join(items.slice(0, items.size() - 1)), items[items.size() - 1]]


static func _add(
	by_id: Dictionary, order: Array[String], id: String, kind: String, who: String
) -> void:
	if not by_id.has(id):
		by_id[id] = []
		order.append(id)
	var users: Array = by_id[id]
	for u: Dictionary in users:
		if str(u["name"]) == who and str(u["kind"]) == kind:
			return
	users.append({"kind": kind, "name": who})
