class_name GmiClient
extends Node
## Async GMI Cloud chat client with JSON extraction, a recorded replay cache, and
## heuristic fallback. Every call is logged with its source (live / cache / heuristic).

signal call_logged(record: Dictionary)

const CHAT_URL := "https://api.gmi-serving.com/v1/chat/completions"
const REPLAY_CACHE_PATH := "res://data/gmi_replay_cache.json"
const SESSION_CACHE_PATH := "user://gmi_session_cache.json"
const MAX_LOG := 300
## Hybrid reasoning models spend the whole token budget thinking unless told not to.
## Keys are model-id prefixes; values are merged into the request body.
const MODEL_EXTRAS := {
	"deepseek-ai/": {"thinking": {"type": "disabled"}},
	"moonshotai/": {"thinking": {"type": "disabled"}},
	"Qwen/": {"enable_thinking": false},
	"x-ai/": {"reasoning_effort": "low"},
	"zai-org/": {"thinking": {"type": "disabled"}},
}

var api_key: String = ""
var live_enabled: bool = true
var record_mode: bool = false
var replay_cache: Dictionary = {}
var session_cache: Dictionary = {}
var log_records: Array[Dictionary] = []
var stats: Dictionary = {"live_ok": 0, "live_fail": 0, "cache": 0, "heuristic": 0, "latency_ms_sum": 0, "in_flight": 0}
var _seq: int = 0


func _ready() -> void:
	api_key = _resolve_api_key()
	live_enabled = not api_key.is_empty() and OS.get_environment("GRIDFALL_OFFLINE") != "1"
	record_mode = OS.get_environment("GRIDFALL_RECORD") == "1"
	_load_replay_cache()


func has_key() -> bool:
	return not api_key.is_empty()


func set_live(enabled: bool) -> void:
	live_enabled = enabled and has_key()


func _resolve_api_key() -> String:
	var env_key := OS.get_environment("GMI_API_KEY").strip_edges()
	if not env_key.is_empty():
		return env_key
	var settings_path := OS.get_environment("HOME").path_join(".factory/settings.json")
	if not FileAccess.file_exists(settings_path):
		return ""
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(settings_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	for item: Variant in (parsed as Dictionary).get("customModels", []):
		if typeof(item) == TYPE_DICTIONARY and str((item as Dictionary).get("baseUrl", "")).contains("gmi-serving.com"):
			var k := str((item as Dictionary).get("apiKey", "")).strip_edges()
			if not k.is_empty():
				return k
	return ""


func _load_replay_cache() -> void:
	if not FileAccess.file_exists(REPLAY_CACHE_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(REPLAY_CACHE_PATH))
	if typeof(parsed) == TYPE_DICTIONARY:
		replay_cache = parsed as Dictionary


## Returns {ok, data, source, latency_ms, model, error, raw}. Never fails: falls back to the
## replay cache (same role/agent, nearest day) and then to the heuristic callable.
func chat_json(role: String, agent_id: String, model: String, system_prompt: String, user_prompt: String,
		day: int, max_tokens: int, timeout_s: float, heuristic: Callable) -> Dictionary:
	_seq += 1
	var key := "%s|%s" % [role, agent_id]
	var result := {"ok": false, "data": {}, "source": "", "latency_ms": 0, "model": model, "error": "", "raw": "", "role": role, "agent": agent_id, "day": day, "seq": _seq}
	if live_enabled:
		stats["in_flight"] = int(stats["in_flight"]) + 1
		var t0 := Time.get_ticks_msec()
		var live := await _post(model, system_prompt, user_prompt, max_tokens, timeout_s)
		stats["in_flight"] = int(stats["in_flight"]) - 1
		result["latency_ms"] = Time.get_ticks_msec() - t0
		result["raw"] = str(live.get("raw", "")).left(600)
		if bool(live.get("ok", false)):
			result["ok"] = true
			result["data"] = live["data"]
			result["source"] = "live"
			stats["live_ok"] = int(stats["live_ok"]) + 1
			stats["latency_ms_sum"] = int(stats["latency_ms_sum"]) + int(result["latency_ms"])
			_remember(key, day, live["data"])
			_log(result)
			return result
		result["error"] = str(live.get("error", "unknown error"))
		stats["live_fail"] = int(stats["live_fail"]) + 1
	var cached := _cache_lookup(key, day)
	if not cached.is_empty():
		result["ok"] = true
		result["data"] = cached
		result["source"] = "cache"
		stats["cache"] = int(stats["cache"]) + 1
		_log(result)
		return result
	result["data"] = heuristic.call() if heuristic.is_valid() else {}
	result["ok"] = true
	result["source"] = "heuristic"
	stats["heuristic"] = int(stats["heuristic"]) + 1
	_log(result)
	return result


## Live-only call for callers that cache per item themselves (resident batches). Never
## touches the role-level cache; on failure returns ok=false so the caller can fall back.
func live_json(role: String, agent_id: String, model: String, system_prompt: String, user_prompt: String,
		day: int, max_tokens: int, timeout_s: float) -> Dictionary:
	_seq += 1
	var result := {"ok": false, "data": {}, "source": "", "latency_ms": 0, "model": model, "error": "", "raw": "", "role": role, "agent": agent_id, "day": day, "seq": _seq}
	if not live_enabled:
		result["error"] = "offline"
		return result
	stats["in_flight"] = int(stats["in_flight"]) + 1
	var t0 := Time.get_ticks_msec()
	var live := await _post(model, system_prompt, user_prompt, max_tokens, timeout_s)
	stats["in_flight"] = int(stats["in_flight"]) - 1
	result["latency_ms"] = Time.get_ticks_msec() - t0
	result["raw"] = str(live.get("raw", "")).left(600)
	if bool(live.get("ok", false)):
		result["ok"] = true
		result["data"] = live["data"]
		result["source"] = "live"
		stats["live_ok"] = int(stats["live_ok"]) + 1
		stats["latency_ms_sum"] = int(stats["latency_ms_sum"]) + int(result["latency_ms"])
	else:
		result["error"] = str(live.get("error", "unknown error"))
		result["source"] = "failed"
		stats["live_fail"] = int(stats["live_fail"]) + 1
	_log(result)
	return result


func remember(key: String, day: int, data: Dictionary) -> void:
	_remember(key, day, data)


func lookup(key: String, day: int) -> Dictionary:
	return _cache_lookup(key, day)


func count_source(source: String, n: int = 1) -> void:
	if stats.has(source):
		stats[source] = int(stats[source]) + n

func _post(model: String, system_prompt: String, user_prompt: String, max_tokens: int, timeout_s: float) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout_s
	add_child(http)
	var headers := PackedStringArray([
		"Authorization: Bearer " + api_key,
		"Content-Type: application/json",
		"User-Agent: GridFall/2.0 (Godot)",
	])
	var payload := {
		"model": model,
		"messages": [
			{"role": "system", "content": system_prompt},
			{"role": "user", "content": user_prompt},
		],
		"temperature": 0.7,
		"max_tokens": max_tokens,
	}
	for prefix: String in MODEL_EXTRAS:
		if model.begins_with(prefix):
			payload.merge(MODEL_EXTRAS[prefix], true)
	var body := JSON.stringify(payload)
	var err := http.request(CHAT_URL, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "request error %d" % err}
	var res: Array = await http.request_completed
	http.queue_free()
	var result_code: int = res[0]
	var http_code: int = res[1]
	var raw_body: PackedByteArray = res[3]
	var text := raw_body.get_string_from_utf8()
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "network result %d" % result_code}
	if http_code != 200:
		return {"ok": false, "error": "HTTP %d %s" % [http_code, text.left(140)]}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": "bad response body"}
	var choices: Array = (parsed as Dictionary).get("choices", [])
	if choices.is_empty():
		return {"ok": false, "error": "no choices"}
	var msg: Dictionary = (choices[0] as Dictionary).get("message", {})
	var content: String = str(msg.get("content", "")) if msg.get("content") != null else ""
	if content.strip_edges().is_empty() and msg.get("reasoning_content") != null:
		content = str(msg.get("reasoning_content", ""))
	var data := extract_json(content)
	if data.is_empty():
		data = salvage_array(content)
	if data.is_empty():
		return {"ok": false, "error": "no JSON in reply", "raw": content}
	return {"ok": true, "data": data, "raw": content}


## Recovers the complete objects of a truncated {"key":[{...},{...},{... reply.
static func salvage_array(content: String) -> Dictionary:
	var lb := content.find("[")
	if lb < 0:
		return {}
	var q2 := content.rfind("\"", lb)
	var q1 := content.rfind("\"", q2 - 1) if q2 > 0 else -1
	if q1 < 0:
		return {}
	var key := content.substr(q1 + 1, q2 - q1 - 1)
	var items: Array = []
	var depth := 0
	var in_str := false
	var esc := false
	var start := -1
	for i in range(lb + 1, content.length()):
		var ch := content[i]
		if in_str:
			if esc:
				esc = false
			elif ch == "\\":
				esc = true
			elif ch == "\"":
				in_str = false
			continue
		if ch == "\"":
			in_str = true
		elif ch == "{":
			if depth == 0:
				start = i
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0 and start >= 0:
				var parsed: Variant = JSON.parse_string(content.substr(start, i - start + 1))
				if typeof(parsed) == TYPE_DICTIONARY:
					items.append(parsed)
				start = -1
		elif ch == "]" and depth == 0:
			break
	return {key: items} if not items.is_empty() else {}

static func extract_json(content: String) -> Dictionary:
	var cleaned := content
	var think := RegEx.create_from_string("(?s)<think>.*?</think>")
	cleaned = think.sub(cleaned, "", true)
	cleaned = cleaned.replace("```json", "").replace("```", "")
	var start := cleaned.find("{")
	var stop := cleaned.rfind("}")
	if start < 0 or stop <= start:
		return {}
	var candidate := cleaned.substr(start, stop - start + 1)
	var parsed: Variant = JSON.parse_string(candidate)
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed as Dictionary
	var trailing := RegEx.create_from_string(",\\s*([}\\]])")
	parsed = JSON.parse_string(trailing.sub(candidate, "$1", true))
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed as Dictionary
	return {}


func _remember(key: String, day: int, data: Dictionary) -> void:
	if not session_cache.has(key):
		session_cache[key] = []
	(session_cache[key] as Array).append({"day": day, "data": data})


func _cache_lookup(key: String, day: int) -> Dictionary:
	for source: Dictionary in [session_cache, replay_cache]:
		if not source.has(key):
			continue
		var entries: Array = source[key]
		if entries.is_empty():
			continue
		var best: Dictionary = entries[0]
		var best_d := 1 << 30
		for e: Variant in entries:
			var ed: Dictionary = e
			var dd := absi(int(ed.get("day", 0)) - day)
			if dd < best_d:
				best_d = dd
				best = ed
		return best.get("data", {})
	return {}


## Writes the recorded live responses so offline runs can replay real model output. Outside record
## mode the session file keeps each key's last 3 days (a pruned copy: session_cache itself stays
## whole, lookups read it) and is not rewritten when nothing was added since the last flush (the
## brain flushes at every day end). Record mode writes exactly as before.
func flush_cache() -> void:
	if not record_mode:
		var entries := 0
		for key: String in session_cache.keys():
			entries += (session_cache[key] as Array).size()
		var sig := [session_cache.size(), entries]
		if has_meta("flush_sig") and get_meta("flush_sig") == sig and is_same(get_meta("flush_of"), session_cache):
			return
		var pruned := {}
		for key: String in session_cache.keys():
			var days: Array = []
			for e: Variant in session_cache[key]:
				var dd := int((e as Dictionary).get("day", 0))
				if not days.has(dd):
					days.append(dd)
			days.sort()
			var recent: Array = days.slice(maxi(0, days.size() - 3))
			var keep: Array = []
			for e: Variant in session_cache[key]:
				if recent.has(int((e as Dictionary).get("day", 0))):
					keep.append(e)
			pruned[key] = keep
		var pf := FileAccess.open(SESSION_CACHE_PATH, FileAccess.WRITE)
		if pf != null:
			pf.store_string(JSON.stringify(pruned))
			pf.close()
			set_meta("flush_sig", sig)
			set_meta("flush_of", session_cache)
		return
	var f := FileAccess.open(SESSION_CACHE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(session_cache))
		f.close()
	if record_mode:
		var merged := replay_cache.duplicate(true)
		for key: String in session_cache.keys():
			merged[key] = session_cache[key]
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://data"))
		var rf := FileAccess.open(REPLAY_CACHE_PATH, FileAccess.WRITE)
		if rf != null:
			rf.store_string(JSON.stringify(merged, "  "))
			rf.close()


func avg_latency_ms() -> int:
	var n := int(stats["live_ok"])
	return int(stats["latency_ms_sum"]) / n if n > 0 else 0


func _log(rec: Dictionary) -> void:
	var slim := rec.duplicate()
	slim.erase("data")
	slim["summary"] = _summarize(rec.get("data", {}))
	log_records.append(slim)
	if log_records.size() > MAX_LOG:
		log_records.pop_front()
	call_logged.emit(slim)


func _summarize(data: Dictionary) -> String:
	for k in ["thought", "headline", "statement", "says", "reason", "note"]:
		if data.has(k):
			return str(data[k]).left(140)
	if data.has("voices"):
		return "%d citizen voices" % (data["voices"] as Array).size()
	if typeof(data.get("residents")) == TYPE_ARRAY:
		return "%d resident plans" % (data["residents"] as Array).size()
	if typeof(data.get("responses")) == TYPE_ARRAY:
		return "%d resident reactions" % (data["responses"] as Array).size()
	return JSON.stringify(data).left(140)


func to_dict() -> Dictionary:
	return {"session_cache": session_cache, "stats": stats.duplicate()}


func from_dict(d: Dictionary) -> void:
	session_cache = d.get("session_cache", {})
	var s: Dictionary = d.get("stats", {})
	for k in s.keys():
		stats[k] = s[k]
	stats["in_flight"] = 0
