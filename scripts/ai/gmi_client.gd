class_name GmiClient
extends Node
## Async GMI Cloud chat client with JSON extraction, a recorded replay cache, and
## heuristic fallback. Every call is logged with its source (live / cache / heuristic).

signal call_logged(record: Dictionary)
## A live_json call that never left the process (offline, circuit open, no free slot): it is not in
## the log, but the ModelLedger counts it so a model that is being skipped shows as such.
signal call_skipped(record: Dictionary)
## The circuit breakers' aggregate moved to state ("closed" / "open" / "half_open"): one group
## opening while another is already open does not repeat it.
signal breaker_changed(state: String)

const CHAT_URL := "https://api.gmi-serving.com/v1/chat/completions"
## The model list the readiness check reads (GET, once per key; see GmiPreflight).
const MODELS_URL := "https://api.gmi-serving.com/v1/models"
const PREFLIGHT_TIMEOUT_S := 12.0
## The model list is read for its ids only: a body past this is cut off by the HTTPRequest and
## the check fails. The real list is about 31 KB (74 models, checked 2026-11-12), so this is only
## headroom, not the fix for any past failure.
const PREFLIGHT_MAX_BODY := 8 << 20
## Retries after the first attempt, for transient failures only (see is_retryable()).
const MAX_RETRIES := 2
const BACKOFF_BASE_MS := 500
const BACKOFF_CAP_MS := 4000
## Live outcomes kept for the failure-ratio alert.
const LIVE_WINDOW := 20
## Fewest live outcomes in the window before live_failure_ratio() reports anything. The street
## badge turns red ("Reconnecting") above 0.5, and one failed call out of one is 1.0: a single
## stray timeout, one 401 or the first call after boot must not say the link is down. Three is
## the least that lets "most of them failed" mean something while an outage still shows within
## a few calls. The ops alert (data/alert_rules.json, gmi_live_failures, min_calls 6) waits for
## more on purpose: it interrupts the player, the badge only informs.
const LIVE_BADGE_MIN_OUTCOMES := 3
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
	# Kimi K3 always thinks and answers HTTP 400 to thinking: disabled; it wants low, high or max.
	"moonshotai/": {"reasoning_effort": "low"},
	"Qwen/": {"enable_thinking": false},
	"x-ai/": {"reasoning_effort": "low"},
	"zai-org/": {"thinking": {"type": "disabled"}},
}
## Sampling temperature of every call, unless the model refused it (temperature_of).
const TEMPERATURE := 0.7
## Roles whose live calls are a side question, not the city's own business (the "Ask the five"
## panel): they leave the breaker, the live_outcomes window and the live_ok/live_fail counts alone,
## so five parallel questions that meet a 429 cannot turn the whole city to replay.
const ISOLATED_ROLES := ["arena"]
## The key test (test_key): a tiny prompt, KEY_TEST_TOKENS tokens, one attempt, and a timeout
## generous enough for a cold model without leaving the player staring at "Testing".
const KEY_TEST_SYSTEM := "Reply with the single word ok."
const KEY_TEST_USER := "ping"
const KEY_TEST_TOKENS := 8
const KEY_TEST_TIMEOUT_S := 12.0

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
	"retries": 0, "breaker_open": 0, "breaker_skip": 0, "side_retries": 0}
## The default group's breaker (the street chatter, the talk and any role not named in
## GmiBreakers.GROUPS): it opens after 4 consecutive service failures; while open, chat_json goes
## straight to the cache or heuristic and live_json fails fast with "circuit open". The mayors, the
## support agents and the residents each have their own in `breakers` (see breakers.breaker_for),
## so a failing group cannot open the circuit for the others; breaker_state() is the aggregate.
var breaker := CircuitBreaker.new(4, 30000)
var breakers := GmiBreakers.new(breaker)
## Live calls out now, the mayors first (flag gmi_inflight_cap; see GmiAdmission).
var admission := GmiAdmission.new()
## The readiness check of the key in use (one GET of the model list per key, GmiPreflight). It
## starts by itself when a key is set, but only where the game runs (preflight.enabled, which Main
## sets): a test client never reaches for the network.
var preflight := GmiPreflight.new()
## The last LIVE_WINDOW live outcomes (true = ok), oldest first.
var live_outcomes: Array[bool] = []
## Models that refused TEMPERATURE (an HTTP 400 naming the temperature) and get 1.0 instead.
var temperature_of: Dictionary = {}
var _last_failure: String = ""
var _last_aggregate: String = CircuitBreaker.CLOSED
var _seq: int = 0
## Retry-backoff jitter. Its own generator on purpose: jitter should vary between processes, but a
## draw must never come from the shared global RNG stream, whose state the sim's boot determinism
## relies on (see CitySim.rng_for).
var _jitter := RandomNumberGenerator.new()
var _hdr_request_id: String = ""
var _hdr_trace_id: String = ""
## True in the browser export (_detect_web). An instance variable (not a call in _post) so a test
## can stand in for the web build; nothing else sets it.
var web_build: bool = _detect_web()
## Test-only hook for the retry backoff's sleep, in milliseconds. Empty in the game, where the
## retry loop waits on a SceneTree timer; a test assigns a recorder so the backoff contract is
## checked exactly instead of through frame-timer timing (a SceneTree timer burns frame deltas,
## so on a loaded runner one stalled frame can end the wait long before its wall-clock delay).
## Not wired to any flag or environment switch: nothing outside a test ever sets it.
var sleep_ms := Callable()


func _init() -> void:
	breakers.changed.connect(_on_breaker_changed)


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


## Whether this is the browser export: what web_build starts as. A test subclass overrides it to stand
## in for the export (headless cannot be one); nothing in the game does.
func _detect_web() -> bool:
	return WebSupport.is_web()


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
	preflight.key_changed(self)
	return has_key()


## Saves this key on the player's own device (web build, after they tick Remember): written
## straight to the browser's localStorage, never through Godot's files or logs. No-op elsewhere.
func remember_player_key(key: String) -> void:
	WebSupport.store_set(WEB_KEY_CONSENT, "1")
	WebSupport.store_set(WEB_KEY_STORE, key.strip_edges())


## True when this device holds a remembered key the player asked for (web build only). With key
## given, true only when the saved copy is that very key (a copy of another key does not count).
func has_remembered_key(key: String = "") -> bool:
	var consent := WebSupport.store_get(WEB_KEY_CONSENT) == "1"
	var saved := WebSupport.store_get(WEB_KEY_STORE)
	return consent and not saved.is_empty() and (key.is_empty() or saved == key)


## Drops the Remember tick and the stored key from this device (web build only). The key set with
## set_player_key stays in memory until cleared or the page closes.
func forget_remembered_key() -> void:
	WebSupport.store_erase(WEB_KEY_CONSENT)
	WebSupport.store_erase(WEB_KEY_STORE)


func set_live(enabled: bool) -> void:
	live_enabled = enabled and has_key() and FeatureFlags.enabled("gmi_live")


## The aggregate of the breakers: "open" when any group's is open, else "half_open" when one is
## probing (an open breaker past its cool-down reads half_open), else "closed". The alerts and the
## alerts read this one (the street badge and Ask the five read breakers.mayor_state()).
func breaker_state() -> String:
	return breakers.state()


## Share of failed live calls among the last LIVE_WINDOW. 0 while fewer than
## LIVE_BADGE_MIN_OUTCOMES calls have been seen: too few to call it a trend.
func live_failure_ratio() -> float:
	if live_outcomes.size() < LIVE_BADGE_MIN_OUTCOMES:
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


## The HTTP headers of one chat request. Desktop sends all five. In a browser every header beyond
## Authorization and Content-Type is a non-safelisted header the preflight must allow, and GMI's
## CORS answer (measured 2026-11-03: OPTIONS /v1/chat/completions allows Content-Type,
## Authorization, X-Requested-With and x-gmi-request-id) does not list User-Agent, X-Request-ID or
## X-Trace-ID, so with them the browser blocks every live call before it leaves. web = true
## therefore sends only what the preflight allows and needs. The request and trace ids still
## label the call in the local GMI Log and trace; the web build just cannot put them on the wire.
static func request_headers(
	key: String, request_id: String, trace_id: String, web: bool
) -> PackedStringArray:
	var headers := PackedStringArray(
		["Authorization: Bearer " + key, "Content-Type: application/json"]
	)
	if web:
		return headers
	headers.append("User-Agent: GridFall/2.0 (Godot)")
	if not request_id.is_empty():
		headers.append("X-Request-ID: " + request_id)
	if not trace_id.is_empty():
		headers.append("X-Trace-ID: " + trace_id)
	return headers


## True when requests must use the web-safe header set: the browser build with the
## gmi_web_safe_headers flag on (turn it off if GMI's CORS list ever admits the tracing headers).
static func web_headers_active(is_web: bool) -> bool:
	return is_web and FeatureFlags.enabled("gmi_web_safe_headers")


## The headers a request puts on the wire (request_headers for this build and flag). web_safe true
## forces the two-header set whatever the build: the model-list check sends only Authorization and
## Content-Type everywhere.
func _wire_headers(
	request_id: String, trace_id: String, web_safe: bool = false
) -> PackedStringArray:
	return request_headers(api_key, request_id, trace_id, web_safe or web_headers_active(web_build))


## The model the key test asks: among models, the one that looks cheapest by its name (a "lite" id,
## then a "flash" id, then the first). Offline, names are all there is: no price list is read.
static func key_test_model(models: Array) -> String:
	var best := ""
	var best_rank := 99
	for m: Variant in models:
		var id := str(m)
		var low := id.to_lower()
		var rank := 0 if low.contains("lite") else (1 if low.contains("flash") else 2)
		if rank < best_rank:
			best = id
			best_rank = rank
	return best


## The key test's verdict for a _post reply: {"status": "ok" | "rejected" | "rate_limited" |
## "blocked" | "error", "http": int, "timed_out": bool}. ok is HTTP 200 whatever the body (the key
## was accepted; the model need not have produced JSON), rejected 401/403, rate_limited 429,
## blocked a network-level failure with no HTTP answer (in a browser a CORS block and being
## offline look the same) and error anything else (other HTTP codes, a request that could not be
## built). timed_out marks the blocked case where the wait ran out instead of the connection
## failing: a slow or stalled answer is not a CORS block and the panel says so.
static func classify_key_reply(live: Dictionary) -> Dictionary:
	var err := str(live.get("error", ""))
	var http := int(live.get("http", 0))
	if http == 0 and err.begins_with("HTTP "):
		http = int(err.get_slice(" ", 1))
	var result := int(live.get("result", 0))
	if result == 0 and err.begins_with("network result "):
		result = int(err.get_slice(" ", 2))
	var status := "error"
	if bool(live.get("ok", false)) or http == 200:
		status = "ok"
		http = 200
	elif http == 401 or http == 403:
		status = "rejected"
	elif http == 429:
		status = "rate_limited"
	elif http == 0 and result != 0:
		status = "blocked"
	var timed_out := status == "blocked" and result == HTTPRequest.RESULT_TIMEOUT
	return {"status": status, "http": http, "timed_out": timed_out}


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
	if live_enabled and not _breaker_allows(role):
		result["error"] = "circuit open"
	elif live_enabled:
		var live := await _call_live(
			model, system_prompt, user_prompt, max_tokens, timeout_s, result
		)
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
		return _skipped(result)
	var isolated := role in ISOLATED_ROLES
	if not isolated and breakers.breaker_for(role).peek_state() == CircuitBreaker.OPEN:
		_count_skip()
		result["error"] = "circuit open"
		result["source"] = "failed"
		return _skipped(result)
	# The slot is waited for BEFORE the breaker is asked: a half-open breaker hands out its single
	# probe to whoever asks first, and a call that then gave up waiting would never report it, so
	# the group would stay half-open for good.
	if not await _wait_for_slot(role, timeout_s):
		result["error"] = "no free slot"
		result["source"] = "failed"
		return _skipped(result)
	if not isolated and not _breaker_allows(role):
		result["error"] = "circuit open"
		result["source"] = "failed"
		return _skipped(result)
	var live := await _call_live(model, system_prompt, user_prompt, max_tokens, timeout_s, result)
	if bool(live.get("ok", false)):
		result["ok"] = true
		result["data"] = live["data"]
		result["source"] = "live"
		if not isolated:
			stats["live_ok"] = int(stats["live_ok"]) + 1
			stats["latency_ms_sum"] = int(stats["latency_ms_sum"]) + int(result["latency_ms"])
	else:
		result["error"] = str(live.get("error", "unknown error"))
		result["source"] = "failed"
		if not isolated:
			stats["live_fail"] = int(stats["live_fail"]) + 1
			_report_failure(result)
	_log(result)
	return result


## One live call with its bookkeeping: counted as in flight (stats, admission) while it is out, and
## result gets its latency_ms and raw. Returns what _post_with_retry returned.
func _call_live(
	model: String, system_prompt: String, user_prompt: String, max_tokens: int, timeout_s: float,
	result: Dictionary
) -> Dictionary:
	var role := str(result["role"])
	stats["in_flight"] = int(stats["in_flight"]) + 1
	admission.enter(role)
	var t0 := Time.get_ticks_msec()
	var live := await _post_with_retry(model, system_prompt, user_prompt, max_tokens, timeout_s, result)
	admission.leave(role)
	stats["in_flight"] = int(stats["in_flight"]) - 1
	result["latency_ms"] = Time.get_ticks_msec() - t0
	result["raw"] = str(live.get("raw", "")).left(600)
	for k: String in ["tokens_in", "tokens_out", "finish_reason", "repairs"]:
		if live.has(k):
			result[k] = live[k]
	return live


## result of a live_json call that did not go out, announced to the ledger (call_skipped); it is
## not logged. Returns result.
func _skipped(result: Dictionary) -> Dictionary:
	call_skipped.emit(result.duplicate())
	return result


## Why a key test cannot go out right now: "" when it can, else "no_key", "offline"
## (GRIDFALL_OFFLINE=1, whose whole meaning is that nothing calls GMI: the same switch
## _refresh_live honours) or "switched_off" (the gmi_live kill switch).
func test_refusal() -> String:
	if not has_key():
		return "no_key"
	if OS.get_environment("GRIDFALL_OFFLINE") == "1":
		return "offline"
	if not FeatureFlags.enabled("gmi_live"):
		return "switched_off"
	return ""


## One tiny live call that says whether the key in use works: KEY_TEST_TOKENS tokens to the model
## key_test_model() picks from ResidentMinds.MODELS, through the same _post (so the same headers).
## It is the player's own explicit request, so it deliberately ignores the Live toggle and an open
## breaker, and it leaves no trace in the game: not the breaker, live_outcomes, stats, the log,
## session_cache or the replay cache. Refused (see test_refusal) without a key, under
## GRIDFALL_OFFLINE=1 or with the gmi_live kill switch off: nothing is sent and "refused" says
## why. Returns {"status": "ok" | "rejected" | "rate_limited" | "blocked" | "error", "seconds":
## float, "http": int, "timed_out": bool, "refused": String} (see classify_key_reply); the key
## never appears in it.
func test_key() -> Dictionary:
	var out := {"status": "error", "seconds": 0.0, "http": 0, "timed_out": false, "refused": ""}
	out["refused"] = test_refusal()
	if not str(out["refused"]).is_empty():
		return out
	# _post reads these before its first await, as _post_with_retry does.
	_hdr_request_id = Trace.new_id()
	_hdr_trace_id = Trace.current()
	var t0 := Time.get_ticks_msec()
	var live := await _post(
		key_test_model(ResidentMinds.MODELS), KEY_TEST_SYSTEM, KEY_TEST_USER, KEY_TEST_TOKENS,
		KEY_TEST_TIMEOUT_S
	)
	out["seconds"] = float(Time.get_ticks_msec() - t0) / 1000.0
	out.merge(classify_key_reply(live), true)
	print(_key_test_line(out))
	return out


## The console line for a key test: status, HTTP code and seconds only, never the key or any reply
## text (an error body can echo the key), and scrubbed anyway.
func _key_test_line(verdict: Dictionary) -> String:
	var line := "GMI_TEST %s http=%d in %.1f s" % [
		verdict["status"], int(verdict["http"]), float(verdict["seconds"])
	]
	return Redact.scrub(line, PackedStringArray([api_key]))


## The one place the model list request leaves the process: an HTTPRequest GET to MODELS_URL with
## exactly these headers. Split out so a test can stand in for the network. Returns what
## _round_trip returns ({"start_error": int}, or {"result", "http", "headers", "body"}).
func _models_trip(headers: PackedStringArray, timeout_s: float) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout_s
	http.body_size_limit = PREFLIGHT_MAX_BODY
	add_child(http)
	var err := http.request(MODELS_URL, headers, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return {"start_error": err}
	var res: Array = await http.request_completed
	http.queue_free()
	return {"result": res[0], "http": res[1], "headers": res[2], "body": res[3]}


func remember(key: String, day: int, data: Dictionary) -> void:
	_remember(key, day, data)


func lookup(key: String, day: int) -> Dictionary:
	return _cache_lookup(key, day)


func count_source(source: String, n: int = 1) -> void:
	if stats.has(source):
		stats[source] = int(stats[source]) + n


## The number of the last call this client started (every record carries its own, "seq"): the
## ledger uses it to tell the calls of a city that has been replaced from the new city's.
func last_seq() -> int:
	return _seq


## A fresh result dict with this call's seq, request_id and the current trace id.
func _new_result(role: String, agent_id: String, model: String, day: int) -> Dictionary:
	_seq += 1
	return {"ok": false, "data": {}, "source": "", "latency_ms": 0, "model": model, "error": "", "raw": "", "role": role,
		"agent": agent_id, "day": day, "seq": _seq, "request_id": Trace.new_id(), "trace_id": Trace.current(), "attempts": 0}


func _breaker_allows(role: String) -> bool:
	if breakers.breaker_for(role).allow():
		return true
	_count_skip()
	return false


func _count_skip() -> void:
	stats["breaker_skip"] = int(stats["breaker_skip"]) + 1


## Waits for a free in-flight slot when the cap is on (flag gmi_inflight_cap) and the role is a
## background one: true when the call may go out, false when the wait outlasted timeout_s (the
## caller treats that as a failed call). Priority roles and a switched-off cap never wait.
func _wait_for_slot(role: String, timeout_s: float) -> bool:
	if admission.can_enter(role) or not FeatureFlags.enabled("gmi_inflight_cap", false):
		return true
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not admission.can_enter(role):
		if Time.get_ticks_msec() >= deadline or not is_inside_tree():
			return false
		await get_tree().process_frame
	return true


## _post with up to MAX_RETRIES retries for transient failures (exponential backoff with jitter,
## honouring Retry-After), all within a budget of 2 x timeout_s. Reports the outcome to the role's
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
		var wait_ms := maxi(backoff_ms(attempt - 1, _jitter.randf()), int(live.get("retry_after_ms", 0)))
		if Time.get_ticks_msec() + wait_ms + 1000 >= deadline:
			break
		# An isolated role's retries are its own: the city's retry count stays the city's.
		var side := str(result.get("role", "")) in ISOLATED_ROLES
		var retry_stat := "side_retries" if side else "retries"
		stats[retry_stat] = int(stats[retry_stat]) + 1
		if sleep_ms.is_valid():
			await sleep_ms.call(wait_ms)
		else:
			await get_tree().create_timer(float(wait_ms) / 1000.0, true, false, true).timeout
	result["attempts"] = attempt
	var ok := bool(live.get("ok", false))
	if str(result.get("role", "")) in ISOLATED_ROLES:
		return live
	var group_breaker := breakers.breaker_for(str(result.get("role", "")))
	if ok or not bool(live.get("service_fail", true)):
		group_breaker.record_success()
	else:
		group_breaker.record_failure()
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
	var line := _failure_line(result)
	if line == _last_failure:
		return
	_last_failure = line
	print(line)


## The scrubbed GMI_FAIL line of a failed live call. The error is scrubbed before it is cut to 160
## characters: cut first, an echoed long key would leave a fragment that no secret matches.
func _failure_line(result: Dictionary) -> String:
	var secrets := PackedStringArray([api_key])
	var err := Redact.scrub(str(result["error"]), secrets).left(160)
	var line := "GMI_FAIL %s/%s on %s: %s" % [result["role"], result["agent"], result["model"], err]
	return Redact.scrub(line, secrets)


func _on_breaker_changed(group: String, _from: String, to: String) -> void:
	if to == CircuitBreaker.OPEN:
		stats["breaker_open"] = int(stats["breaker_open"]) + 1
	ErrorTracker.breadcrumb("gmi breaker %s %s" % [group, to])
	var aggregate := breakers.state()
	if aggregate != _last_aggregate:
		_last_aggregate = aggregate
		breaker_changed.emit(aggregate)


func _post(model: String, system_prompt: String, user_prompt: String, max_tokens: int, timeout_s: float) -> Dictionary:
	var request_id := _hdr_request_id
	var trace_id := _hdr_trace_id
	_hdr_request_id = ""
	_hdr_trace_id = ""
	var headers := _wire_headers(request_id, trace_id)
	var body := JSON.stringify(request_body(model, system_prompt, user_prompt, max_tokens))
	var trip: Dictionary = await _round_trip(headers, body, timeout_s)
	if trip.has("start_error"):
		return {"ok": false, "error": "request error %d" % int(trip["start_error"]),
			"retryable": false, "service_fail": true, "http": 0}
	var result_code: int = trip["result"]
	var http_code: int = trip["http"]
	var raw_body: PackedByteArray = trip["body"]
	var text := raw_body.get_string_from_utf8()
	if result_code != HTTPRequest.RESULT_SUCCESS or http_code != 200:
		var fail := {"ok": false, "retryable": is_retryable(result_code, http_code),
			"service_fail": is_service_failure(result_code, http_code),
			"http": http_code if result_code == HTTPRequest.RESULT_SUCCESS else 0,
			"result": result_code}
		if result_code != HTTPRequest.RESULT_SUCCESS:
			fail["error"] = "network result %d" % result_code
		else:
			# Scrubbed before the cut to 140 characters, so an echoed key leaves no fragment.
			var echoed := Redact.scrub(text, PackedStringArray([api_key])).left(140)
			fail["error"] = "HTTP %d %s" % [http_code, echoed]
			fail["retry_after_ms"] = _retry_after_ms(trip["headers"])
		return fail
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": "bad response body", "service_fail": false, "http": 200}
	# The reply read into its object, repairs and usage (GmiReply); an HTTP 200 whose body holds no
	# answer is not the service's fault, so it never counts toward the breaker.
	var reply := GmiReply.read(parsed as Dictionary)
	var meta := {"tokens_in": reply["tokens_in"], "tokens_out": reply["tokens_out"],
		"finish_reason": reply["finish_reason"]}
	if str(reply["error"]) == "no choices":
		return {"ok": false, "error": "no choices", "service_fail": false, "http": 200}
	var data: Dictionary = reply["data"]
	if data.is_empty():
		meta.merge({"ok": false, "error": "no JSON in reply", "raw": reply["raw"], "service_fail": false,
			"http": 200})
		return meta
	meta.merge({"ok": true, "data": data, "raw": reply["raw"], "http": 200, "repairs": reply["repairs"]})
	return meta


## The one place a chat request leaves the process: an HTTPRequest to CHAT_URL with exactly these
## headers and body. Split out of _post so a test can stand in for the network, see what _post
## puts on the wire and hand back a canned reply. Returns {"start_error": int} when the request
## could not be started, else {"result": int, "http": int, "headers": PackedStringArray,
## "body": PackedByteArray}: what HTTPRequest.request_completed carries.
func _round_trip(headers: PackedStringArray, body: String, timeout_s: float) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout_s
	add_child(http)
	var err := http.request(CHAT_URL, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {"start_error": err}
	var res: Array = await http.request_completed
	http.queue_free()
	return {"result": res[0], "http": res[1], "headers": res[2], "body": res[3]}


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


## Recovers the complete objects of a truncated {"key":[{...},{...},{... reply (GmiParse).
static func salvage_array(content: String) -> Dictionary:
	return GmiParse.salvage_array(content)


## The JSON object in a model's reply: the largest valid one, whatever surrounds it (GmiParse).
static func extract_json(content: String) -> Dictionary:
	return GmiParse.extract_json(content)


func _remember(key: String, day: int, data: Dictionary) -> void:
	if not session_cache.has(key):
		session_cache[key] = []
	(session_cache[key] as Array).append({"day": day, "data": data})


## The cached answer for key on day: this session's nearest entry, else the replay cache's nearest
## one, but only up to the last day recorded for its key (flag replay_horizon, see GmiCache): a
## day-14 city must not replay day 12 forever, the scripted planner takes over instead.
func _cache_lookup(key: String, day: int) -> Dictionary:
	return GmiCache.lookup(
		session_cache, replay_cache, key, day, FeatureFlags.enabled("replay_horizon", true)
	)


## Writes the recorded live responses so offline runs can replay real model output. Outside record
## mode the session file keeps each key's last 3 days (a pruned copy: session_cache itself stays
## whole, lookups read it) and is not rewritten when nothing was added since the last flush (the
## brain flushes at every day end). Record mode writes exactly as before.
func flush_cache() -> void:
	if not record_mode:
		if session_cache.is_empty():
			return
		var sig := [session_cache.size(), GmiCache.entry_count(session_cache)]
		if has_meta("flush_sig") and get_meta("flush_sig") == sig and is_same(get_meta("flush_of"), session_cache):
			return
		var pruned := GmiCache.pruned(session_cache)
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


func _summarize(data_v: Variant) -> String:
	if typeof(data_v) != TYPE_DICTIONARY:
		return JSON.stringify(data_v).left(140)
	var data: Dictionary = data_v
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


## The client's part of a save. The saved session cache keeps each key's last GmiCache.
## SAVE_KEEP_DAYS days (a lookup reads the nearest day, so older entries are never the answer once
## newer ones exist) and, while recording, everything: the in-memory cache is never pruned. The
## brain saves the same dictionary under its own "client" key.
func to_dict() -> Dictionary:
	var cache := session_cache if record_mode else GmiCache.pruned(session_cache)
	return {"session_cache": cache, "stats": stats.duplicate()}


func from_dict(d: Dictionary) -> void:
	session_cache = d.get("session_cache", {})
	var s: Dictionary = d.get("stats", {})
	for k in s.keys():
		stats[k] = s[k]
	stats["in_flight"] = 0
