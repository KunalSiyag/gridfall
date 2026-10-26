class_name GmiClient
extends Node
## Async GMI Cloud chat client with JSON extraction, a recorded replay cache, and
## heuristic fallback. Every call is logged with its source (live / cache / heuristic).

signal call_logged(record: Dictionary)
## The circuit breaker moved to state ("closed" / "open" / "half_open").
signal breaker_changed(state: String)

const CHAT_URL := "https://api.gmi-serving.com/v1/chat/completions"
## Retries after the first attempt, for transient failures only (see is_retryable()).
const MAX_RETRIES := 2
const BACKOFF_BASE_MS := 500
const BACKOFF_CAP_MS := 4000
## Live outcomes kept for the failure-ratio alert.
const LIVE_WINDOW := 20
## Network results worth another attempt; TLS, redirect, body-size and file errors are not.
const RETRY_RESULTS := [HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE,
	HTTPRequest.RESULT_CONNECTION_ERROR, HTTPRequest.RESULT_NO_RESPONSE, HTTPRequest.RESULT_REQUEST_FAILED,
	HTTPRequest.RESULT_TIMEOUT]
const RETRY_HTTP := [408, 429, 500, 502, 503, 504]
const REPLAY_CACHE_PATH := "res://data/gmi_replay_cache.json"
const SESSION_CACHE_PATH := "user://gmi_session_cache.json"
## Browser localStorage names for the player's own key (web build); written only after the player
## ticks "Remember on this device", read back at boot. Never a log target (Redact owns the key).
const WEB_KEY_STORE := "gridfall.gmi_key"
const WEB_KEY_CONSENT := "gridfall.gmi_key.remember"
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
## Sampling temperature of every call, unless the model refused it (temperature_of).
const TEMPERATURE := 0.7

var api_key: String = ""
## A key the player typed in the settings (web build or any platform); "" while the boot key
## (GMI_API_KEY or ~/.factory/settings.json) is the one in use.
var player_key: String = ""
var live_enabled: bool = true
var record_mode: bool = false
var replay_cache: Dictionary = {}
var session_cache: Dictionary = {}
var log_records: Array[Dictionary] = []
var stats: Dictionary = {"live_ok": 0, "live_fail": 0, "cache": 0, "heuristic": 0, "latency_ms_sum": 0, "in_flight": 0,
	"retries": 0, "breaker_open": 0, "breaker_skip": 0}
## Opens after 4 consecutive service failures; while open, chat_json goes straight to the cache or
## heuristic and live_json fails fast with "circuit open".
var breaker := CircuitBreaker.new(4, 30000)
## The last LIVE_WINDOW live outcomes (true = ok), oldest first.
var live_outcomes: Array[bool] = []
## Models that refused TEMPERATURE (an HTTP 400 naming the temperature) and get 1.0 instead.
var temperature_of: Dictionary = {}
var _last_failure: String = ""
var _seq: int = 0
var _hdr_request_id: String = ""
var _hdr_trace_id: String = ""


func _init() -> void:
	breaker.state_changed.connect(_on_breaker_changed)


func _ready() -> void:
	api_key = _resolve_api_key()
	if WebSupport.is_web() and has_remembered_key():
		player_key = WebSupport.store_get(WEB_KEY_STORE)
		if not player_key.is_empty():
			api_key = player_key
	Redact.add_secret(api_key)
	_refresh_live()
	record_mode = OS.get_environment("GRIDFALL_RECORD") == "1"
	_load_replay_cache()


func has_key() -> bool:
	return not api_key.is_empty()


## Recomputes live_enabled from the key in use, GRIDFALL_OFFLINE and the gmi_live flag.
func _refresh_live() -> void:
	var offline := OS.get_environment("GRIDFALL_OFFLINE") == "1"
	live_enabled = not api_key.is_empty() and not offline and FeatureFlags.enabled("gmi_live")


## A key the player typed in the settings ("bring your own key"): replaces the boot key in memory
## and is registered with the redactor so it can never reach a log. The key stays in this session
## only (remember_player_key() is what, on the web and only after the player ticks Remember, saves
## it on their own device). An empty key puts the boot key back in use. Returns has_key().
func set_player_key(key: String) -> bool:
	player_key = key.strip_edges()
	api_key = player_key if not player_key.is_empty() else _resolve_api_key()
	if not api_key.is_empty():
		Redact.add_secret(api_key)
	_refresh_live()
	return has_key()


## Saves this key on the player's own device (web build, after they tick Remember): written
## straight to the browser's localStorage, never through Godot's files or logs. No-op elsewhere.
func remember_player_key(key: String) -> void:
	WebSupport.store_set(WEB_KEY_CONSENT, "1")
	WebSupport.store_set(WEB_KEY_STORE, key.strip_edges())


## True when this device holds a remembered key the player asked for (web build only).
func has_remembered_key() -> bool:
	var consent := WebSupport.store_get(WEB_KEY_CONSENT) == "1"
	return consent and not WebSupport.store_get(WEB_KEY_STORE).is_empty()


## Drops the Remember tick and the stored key from this device (web build only). The key set with
## set_player_key stays in memory until cleared or the page closes.
func forget_remembered_key() -> void:
	WebSupport.store_erase(WEB_KEY_CONSENT)
	WebSupport.store_erase(WEB_KEY_STORE)


func set_live(enabled: bool) -> void:
	live_enabled = enabled and has_key() and FeatureFlags.enabled("gmi_live")


## "closed", "open" or "half_open" (an open breaker past its cool-down reads half_open).
func breaker_state() -> String:
	return breaker.peek_state()


## Share of failed live calls among the last LIVE_WINDOW (0 when none).
func live_failure_ratio() -> float:
	if live_outcomes.is_empty():
		return 0.0
	var bad := 0
	for ok: bool in live_outcomes:
		if not ok:
			bad += 1
	return float(bad) / float(live_outcomes.size())


## True for failures another attempt may fix: transient network results, 408, 429 and 500/502/503/504.
static func is_retryable(result_code: int, http_code: int) -> bool:
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return result_code in RETRY_RESULTS
	return http_code in RETRY_HTTP


## True when the failure says the service (not the request or the reply) is unhealthy; these
## count toward opening the breaker.
static func is_service_failure(result_code: int, http_code: int) -> bool:
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return true
	return http_code == 408 or http_code == 429 or http_code >= 500


## Delay before retry number attempt (0-based): exponential from BACKOFF_BASE_MS, capped at
## BACKOFF_CAP_MS, with "equal jitter" (jitter01 in 0..1 picks a point in the upper half).
static func backoff_ms(attempt: int, jitter01: float) -> int:
	var ceiling := mini(BACKOFF_CAP_MS, BACKOFF_BASE_MS << clampi(attempt, 0, 16))
	return int(float(ceiling) * (0.5 + 0.5 * clampf(jitter01, 0.0, 1.0)))


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
	var key := "%s|%s" % [role, agent_id]
	var result := _new_result(role, agent_id, model, day)
	if live_enabled and not _breaker_allows():
		result["error"] = "circuit open"
	elif live_enabled:
		stats["in_flight"] = int(stats["in_flight"]) + 1
		var t0 := Time.get_ticks_msec()
		var live := await _post_with_retry(model, system_prompt, user_prompt, max_tokens, timeout_s, result)
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
		_report_failure(result)
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
	var result := _new_result(role, agent_id, model, day)
	if not live_enabled:
		result["error"] = "offline"
		return result
	if not _breaker_allows():
		result["error"] = "circuit open"
		result["source"] = "failed"
		return result
	stats["in_flight"] = int(stats["in_flight"]) + 1
	var t0 := Time.get_ticks_msec()
	var live := await _post_with_retry(model, system_prompt, user_prompt, max_tokens, timeout_s, result)
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
		_report_failure(result)
	_log(result)
	return result


func remember(key: String, day: int, data: Dictionary) -> void:
	_remember(key, day, data)


func lookup(key: String, day: int) -> Dictionary:
	return _cache_lookup(key, day)


func count_source(source: String, n: int = 1) -> void:
	if stats.has(source):
		stats[source] = int(stats[source]) + n


## A fresh result dict with this call's seq, request_id and the current trace id.
func _new_result(role: String, agent_id: String, model: String, day: int) -> Dictionary:
	_seq += 1
	return {"ok": false, "data": {}, "source": "", "latency_ms": 0, "model": model, "error": "", "raw": "", "role": role,
		"agent": agent_id, "day": day, "seq": _seq, "request_id": Trace.new_id(), "trace_id": Trace.current(), "attempts": 0}


func _breaker_allows() -> bool:
	if breaker.allow():
		return true
	stats["breaker_skip"] = int(stats["breaker_skip"]) + 1
	return false


## _post with up to MAX_RETRIES retries for transient failures (exponential backoff with jitter,
## honouring Retry-After), all within a budget of 2 x timeout_s. Reports the outcome to the
## breaker and live_outcomes; sets result["attempts"].
func _post_with_retry(model: String, system_prompt: String, user_prompt: String, max_tokens: int, timeout_s: float,
		result: Dictionary) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 2000.0)
	var attempt := 0
	var live: Dictionary = {}
	while true:
		var left_s := float(deadline - Time.get_ticks_msec()) / 1000.0
		# _post reads these before its first await; overrides in tests keep the 5-argument signature.
		_hdr_request_id = str(result.get("request_id", ""))
		_hdr_trace_id = str(result.get("trace_id", ""))
		live = await _post(model, system_prompt, user_prompt, max_tokens, clampf(left_s, 1.0, timeout_s))
		attempt += 1
		if _learn_temperature(model, live):
			continue
		if bool(live.get("ok", false)) or not bool(live.get("retryable", false)) or attempt > MAX_RETRIES or not is_inside_tree():
			break
		var wait_ms := maxi(backoff_ms(attempt - 1, randf()), int(live.get("retry_after_ms", 0)))
		if Time.get_ticks_msec() + wait_ms + 1000 >= deadline:
			break
		stats["retries"] = int(stats["retries"]) + 1
		await get_tree().create_timer(float(wait_ms) / 1000.0, true, false, true).timeout
	result["attempts"] = attempt
	var ok := bool(live.get("ok", false))
	if ok or not bool(live.get("service_fail", true)):
		breaker.record_success()
	else:
		breaker.record_failure()
	live_outcomes.append(ok)
	if live_outcomes.size() > LIVE_WINDOW:
		live_outcomes.pop_front()
	return live


## True when live is an HTTP 400 refusing the temperature of a model that still had
## TEMPERATURE (Kimi-K3 takes only 1): the model gets 1.0 from now on, and the call one more try.
func _learn_temperature(model: String, live: Dictionary) -> bool:
	var err := str(live.get("error", "")).to_lower()
	if temperature_of.has(model) or not err.begins_with("http 400"):
		return false
	if not err.contains("temperature"):
		return false
	temperature_of[model] = 1.0
	return true


## Prints one scrubbed line for a failed live call (role, agent, model and error, never the
## prompt), so a run from the editor shows why replies fell back. A repeat of the last line is
## not printed again.
func _report_failure(result: Dictionary) -> void:
	var line := "GMI_FAIL %s/%s on %s: %s" % [
		result["role"], result["agent"], result["model"], str(result["error"]).left(160)
	]
	line = Redact.scrub(line, PackedStringArray([api_key]))
	if line == _last_failure:
		return
	_last_failure = line
	print(line)


func _on_breaker_changed(_from: String, to: String) -> void:
	if to == CircuitBreaker.OPEN:
		stats["breaker_open"] = int(stats["breaker_open"]) + 1
	ErrorTracker.breadcrumb("gmi breaker " + to)
	breaker_changed.emit(to)


func _post(model: String, system_prompt: String, user_prompt: String, max_tokens: int, timeout_s: float) -> Dictionary:
	var request_id := _hdr_request_id
	var trace_id := _hdr_trace_id
	_hdr_request_id = ""
	_hdr_trace_id = ""
	var http := HTTPRequest.new()
	http.timeout = timeout_s
	add_child(http)
	var headers := PackedStringArray([
		"Authorization: Bearer " + api_key,
		"Content-Type: application/json",
		"User-Agent: GridFall/2.0 (Godot)",
	])
	if not request_id.is_empty():
		headers.append("X-Request-ID: " + request_id)
	if not trace_id.is_empty():
		headers.append("X-Trace-ID: " + trace_id)
	var body := JSON.stringify(request_body(model, system_prompt, user_prompt, max_tokens))
	var err := http.request(CHAT_URL, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "request error %d" % err, "retryable": false, "service_fail": true}
	var res: Array = await http.request_completed
	http.queue_free()
	var result_code: int = res[0]
	var http_code: int = res[1]
	var raw_body: PackedByteArray = res[3]
	var text := raw_body.get_string_from_utf8()
	if result_code != HTTPRequest.RESULT_SUCCESS or http_code != 200:
		var fail := {"ok": false, "retryable": is_retryable(result_code, http_code), "service_fail": is_service_failure(result_code, http_code)}
		if result_code != HTTPRequest.RESULT_SUCCESS:
			fail["error"] = "network result %d" % result_code
		else:
			fail["error"] = "HTTP %d %s" % [http_code, text.left(140)]
			fail["retry_after_ms"] = _retry_after_ms(res[2])
		return fail
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": "bad response body", "service_fail": false}
	var choices: Array = (parsed as Dictionary).get("choices", [])
	if choices.is_empty():
		return {"ok": false, "error": "no choices", "service_fail": false}
	var msg: Dictionary = (choices[0] as Dictionary).get("message", {})
	var content: String = str(msg.get("content", "")) if msg.get("content") != null else ""
	if content.strip_edges().is_empty() and msg.get("reasoning_content") != null:
		content = str(msg.get("reasoning_content", ""))
	var data := extract_json(content)
	if data.is_empty():
		data = salvage_array(content)
	if data.is_empty():
		return {"ok": false, "error": "no JSON in reply", "raw": content, "service_fail": false}
	return {"ok": true, "data": data, "raw": content}


## The chat completion request for model: both prompts, its temperature (temperature_of, else
## TEMPERATURE), max_tokens and the model's MODEL_EXTRAS.
func request_body(
	model: String, system_prompt: String, user_prompt: String, max_tokens: int
) -> Dictionary:
	var payload := {
		"model": model,
		"messages": [
			{"role": "system", "content": system_prompt},
			{"role": "user", "content": user_prompt},
		],
		"temperature": float(temperature_of.get(model, TEMPERATURE)),
		"max_tokens": max_tokens,
	}
	for prefix: String in MODEL_EXTRAS:
		if model.begins_with(prefix):
			payload.merge(MODEL_EXTRAS[prefix], true)
	return payload


## Retry-After in ms from response headers (delta-seconds form only), capped at 2 x BACKOFF_CAP_MS; 0 if absent.
static func _retry_after_ms(headers: PackedStringArray) -> int:
	for h: String in headers:
		if h.to_lower().begins_with("retry-after:"):
			var v := h.substr(12).strip_edges()
			if v.is_valid_float():
				return clampi(int(float(v) * 1000.0), 0, BACKOFF_CAP_MS * 2)
	return 0


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
	# raw and error can echo request content; the key may have been set after _ready.
	var extra := PackedStringArray([api_key])
	for k: String in ["summary", "raw", "error"]:
		slim[k] = Redact.scrub(str(slim.get(k, "")), extra)
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
