extends SceneTree
## Runtime ops (scripts/ops): circuit breaker, retry classification and backoff, log scrubbing,
## trace and request ids, GmiClient offline fallback and breaker wiring, feature flags, analytics
## and error tracking (no-op when off, JSON lines when on), alert rule evaluation.

const K := preload("res://tools/tests/fp_kit.gd")
const REGISTRY := preload("res://scripts/fp/fp_features.gd")

var fails: Array[String] = []
var _scratch: String = ""


## A GmiClient whose transport takes `frames` frames to answer and counts how many calls are out at
## once (the in-flight cap checks).
class SlowNet extends GmiClient:
	var frames: int = 6
	## While true no call answers (a test holds the slots full).
	var hold: bool = false
	var active: int = 0
	var peak: int = 0
	var started: Array[String] = []

	func _post(_model: String, _system_prompt: String, _user_prompt: String, _max_tokens: int, _timeout_s: float) -> Dictionary:
		active += 1
		peak = maxi(peak, active)
		started.append(str(_hdr_request_id))
		for _k in range(frames):
			await get_tree().process_frame
		while hold:
			await get_tree().process_frame
		active -= 1
		return {"ok": true, "data": {"say": "ok"}, "raw": "{}", "http": 200}


## A GmiClient whose transport fails on demand and records the request id it was handed.
class FakeNet extends GmiClient:
	var posts: int = 0
	var seen_ids: Array[String] = []
	var seen_traces: Array[String] = []
	var reply: Dictionary = {"ok": false, "error": "HTTP 503 down", "retryable": false, "service_fail": true}
	## Replies handed out first, one per post, before reply repeats.
	var queued: Array[Dictionary] = []

	func _post(_model: String, _system_prompt: String, _user_prompt: String, _max_tokens: int, _timeout_s: float) -> Dictionary:
		posts += 1
		seen_ids.append(_hdr_request_id)
		seen_traces.append(_hdr_trace_id)
		if not queued.is_empty():
			return queued.pop_front()
		return reply.duplicate()


func _init() -> void:
	await process_frame
	_scratch = "user://ops_test_" + Trace.new_id()
	OpsSink.dir = _scratch
	_check_breaker()
	_check_retry_rules()
	_check_redact()
	_check_trace()
	await _check_client_offline()
	await _check_client_breaker()
	await _check_breaker_groups()
	await _check_inflight_cap()
	await _check_client_temperature()
	await _check_client_reasoning()
	_check_flags()
	_check_analytics()
	_check_error_tracker()
	await _check_alerts()
	_cleanup()
	K.finish(self, "FP_OPS_TEST", fails)


func _check_breaker() -> void:
	var b := CircuitBreaker.new(3, 1000)
	var moves: Array[String] = []
	b.state_changed.connect(func(from: String, to: String) -> void: moves.append("%s>%s" % [from, to]))
	K.check(fails, b.state == "closed" and b.allow(0), "breaker starts closed and lets calls through")
	b.record_failure(10)
	b.record_failure(20)
	K.check(fails, b.state == "closed" and b.allow(30), "two failures (threshold 3) keep it closed")
	b.record_success()
	b.record_failure(40)
	b.record_failure(50)
	K.check(fails, b.state == "closed", "a success resets the consecutive count")
	b.record_failure(60)
	K.check(fails, b.state == "open" and b.open_count == 1, "the third consecutive failure opens it")
	K.check(fails, not b.allow(500) and b.peek_state(500) == "open" and b.retry_in_ms(500) == 560, "open refuses calls during the cool-down")
	K.check(fails, b.peek_state(1100) == "half_open", "peek reads half_open once the cool-down is over")
	K.check(fails, b.allow(1100) and b.state == "half_open", "after the cool-down one probe goes through (half_open)")
	K.check(fails, not b.allow(1110), "a second call during the probe is refused")
	b.record_failure(1200)
	K.check(fails, b.state == "open" and b.opened_at_ms == 1200 and b.open_count == 2, "a failed probe re-opens it")
	K.check(fails, b.allow(2300) and b.state == "half_open", "the next cool-down allows another probe")
	b.record_success()
	K.check(fails, b.state == "closed" and b.failures == 0 and b.allow(2400), "a successful probe closes it")
	K.check(fails, moves == ["closed>open", "open>half_open", "half_open>open", "open>half_open", "half_open>closed"], "state_changed reports every transition (%s)" % str(moves))


func _check_retry_rules() -> void:
	var ok := GmiClient.is_retryable(HTTPRequest.RESULT_TIMEOUT, 0) and GmiClient.is_retryable(HTTPRequest.RESULT_CANT_CONNECT, 0) \
		and GmiClient.is_retryable(HTTPRequest.RESULT_CONNECTION_ERROR, 0) and GmiClient.is_retryable(HTTPRequest.RESULT_NO_RESPONSE, 0)
	K.check(fails, ok, "timeouts and connection failures are retryable")
	K.check(fails, not GmiClient.is_retryable(HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR, 0) and not GmiClient.is_retryable(HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, 0), "TLS and body-size failures are not")
	var codes_yes := [408, 429, 500, 502, 503, 504]
	var codes_no := [200, 400, 401, 403, 404, 422, 501]
	var all_yes := true
	for c: int in codes_yes:
		all_yes = all_yes and GmiClient.is_retryable(HTTPRequest.RESULT_SUCCESS, c)
	var any_no := false
	for c: int in codes_no:
		any_no = any_no or GmiClient.is_retryable(HTTPRequest.RESULT_SUCCESS, c)
	K.check(fails, all_yes and not any_no, "HTTP 408/429/5xx-gateway retry; other 4xx and 501 do not")
	K.check(fails, GmiClient.is_service_failure(HTTPRequest.RESULT_SUCCESS, 503) and GmiClient.is_service_failure(HTTPRequest.RESULT_TIMEOUT, 0) \
		and not GmiClient.is_service_failure(HTTPRequest.RESULT_SUCCESS, 400) and not GmiClient.is_service_failure(HTTPRequest.RESULT_SUCCESS, 401), "only network, 408, 429 and 5xx count against the breaker")
	K.check(fails, GmiClient.backoff_ms(0, 0.0) == 250 and GmiClient.backoff_ms(0, 1.0) == 500 and GmiClient.backoff_ms(1, 1.0) == 1000 and GmiClient.backoff_ms(6, 1.0) == 4000,
		"backoff doubles from 500 ms with jitter in the upper half, capped at 4 s")
	K.check(fails, GmiClient._retry_after_ms(PackedStringArray(["Content-Type: x", "Retry-After: 2"])) == 2000 and GmiClient._retry_after_ms(PackedStringArray(["Retry-After: 120"])) == 8000,
		"Retry-After seconds are honoured, capped at 8 s")


func _check_redact() -> void:
	var s := Redact.scrub("Authorization: Bearer abcDEF123456.xyz-789")
	K.check(fails, not s.contains("abcDEF123456") and s.contains("[REDACTED]"), "a bearer token is masked (%s)" % s)
	s = Redact.scrub("key sk-live0123456789abcdef in the reply")
	K.check(fails, not s.contains("sk-live0123") and s.ends_with("in the reply"), "an sk- API key is masked (%s)" % s)
	s = Redact.scrub("{\"api_key\":\"hunter2hunter2\",\"x\":1}")
	K.check(fails, not s.contains("hunter2") and s.contains("\"x\":1"), "a JSON api_key value is masked (%s)" % s)
	s = Redact.scrub("mail jane.doe+gf@example.co.uk now")
	K.check(fails, s == "mail [EMAIL] now", "an e-mail address is masked (%s)" % s)
	s = Redact.scrub("token=Zx9Qw8Er7Ty6Ui5Op4As3Df2Gh1Jk0")
	K.check(fails, not s.contains("Zx9Qw8"), "a key=value token is masked")
	s = Redact.scrub("id a1B2c3D4e5F6g7H8i9J0k1L2m3N4 end")
	K.check(fails, s == "id [REDACTED] end", "a long random token is masked (%s)" % s)
	s = Redact.scrub("value is SECRETVALUE42xyz here", PackedStringArray(["SECRETVALUE42xyz"]))
	K.check(fails, s == "value is [REDACTED] here", "an explicitly passed secret is masked")
	var plain := "Day 12: mayor (Qwen/Qwen3-235B-A22B-Instruct-2507-FP8) zoned 6 tiles at res://scripts/fp/overview/overview_feature.gd:281, max_tokens=1500"
	K.check(fails, Redact.scrub(plain) == plain, "ordinary log text, model ids and paths are left alone")


func _check_trace() -> void:
	var ids := {}
	var fmt := true
	for _k in range(200):
		var id := Trace.new_id()
		ids[id] = true
		fmt = fmt and Trace.is_id(id) and id == id.to_lower()
	K.check(fails, ids.size() == 200 and fmt, "trace ids are unique 16-char lowercase hex")
	var t := Trace.begin("day 3")
	K.check(fails, Trace.current() == t and Trace.current_label() == "day 3", "begin() sets the current trace")
	Trace.end()
	K.check(fails, Trace.current().is_empty(), "end() clears it")
	K.check(fails, Trace.is_id(Trace.session_id()) and Trace.session_id() == Trace.session_id(), "one session id per process")


func _check_client_offline() -> void:
	var c: GmiClient = (load("res://scripts/ai/gmi_client.gd") as GDScript).new()
	c.name = "OfflineClient"
	get_root().add_child(c)
	K.check(fails, not c.live_enabled, "fixture: the client is offline (GRIDFALL_OFFLINE=1)")
	var tr := Trace.begin("test round")
	var res: Dictionary = await c.chat_json("mayor", "nobody_zz", "m", "sys", "user", 1, 100, 5.0, func() -> Dictionary: return {"thought": "plan"})
	Trace.end()
	K.check(fails, bool(res["ok"]) and str(res["source"]) in ["cache", "heuristic"], "offline chat_json still answers from cache or heuristic (%s)" % res["source"])
	K.check(fails, Trace.is_id(str(res.get("request_id", ""))) and str(res.get("trace_id", "")) == tr, "the result carries a request_id and the round's trace_id")
	var last: Dictionary = c.log_records.back() if not c.log_records.is_empty() else {}
	K.check(fails, str(last.get("request_id", "")) == str(res["request_id"]) and str(last.get("trace_id", "")) == tr, "the log record carries both ids")
	var res2: Dictionary = await c.chat_json("mayor", "nobody_zz", "m", "sys", "user", 1, 100, 5.0, func() -> Dictionary: return {})
	K.check(fails, str(res2["request_id"]) != str(res["request_id"]) and str(res2["trace_id"]).is_empty(), "each call gets a fresh request id; no trace outside a round")
	var lj: Dictionary = await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 3.0)
	K.check(fails, not bool(lj["ok"]) and str(lj["error"]) == "offline", "offline live_json still fails fast")
	c.queue_free()


func _check_client_breaker() -> void:
	var c := FakeNet.new()
	c.name = "FakeNet"
	get_root().add_child(c)
	c.live_enabled = true
	var states: Array[String] = []
	c.breaker_changed.connect(func(s: String) -> void: states.append(s))
	var tr := Trace.begin("breaker round")
	var r1: Dictionary = await c.chat_json("mayor", "nobody_zz", "m", "sys", "user", 1, 100, 10.0, func() -> Dictionary: return {"thought": "h"})
	Trace.end()
	K.check(fails, c.posts == 1 and c.seen_ids[0] == str(r1["request_id"]) and c.seen_traces[0] == tr, "the transport gets the call's request id and trace id (X-Request-ID / X-Trace-ID)")
	K.check(fails, str(r1["source"]) in ["cache", "heuristic"] and str(r1["error"]).begins_with("HTTP 503"), "a failed live call falls back")
	for _k in range(3):
		await c.chat_json("mayor", "nobody_zz", "m", "sys", "user", 1, 100, 10.0, func() -> Dictionary: return {})
	K.check(fails, c.breaker_state() == "open" and states == ["open"] and int(c.stats["breaker_open"]) == 1, "four service failures open the breaker (%s)" % c.breaker_state())
	var r5: Dictionary = await c.chat_json("mayor", "nobody_zz", "m", "sys", "user", 1, 100, 10.0, func() -> Dictionary: return {"thought": "h"})
	K.check(fails, c.posts == 4 and str(r5["error"]) == "circuit open" and bool(r5["ok"]) and str(r5["source"]) in ["cache", "heuristic"], "while open chat_json skips the network and falls back")
	var l5: Dictionary = await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 3.0)
	K.check(fails, c.posts == 5 and str(l5["error"]).begins_with("HTTP 503"), "the mayors' open breaker does not stop the street chatter: its own breaker is closed")
	var m5: Dictionary = await c.live_json("mayor", "nobody_zz", "m", "s", "u", 1, 50, 3.0)
	K.check(fails, not bool(m5["ok"]) and str(m5["error"]) == "circuit open" and c.posts == 5, "while open live_json for the same group fails fast with 'circuit open'")
	K.check(fails, int(c.stats["breaker_skip"]) == 2 and c.live_failure_ratio() == 1.0, "skips are counted; live outcomes feed the failure ratio")
	c.breakers.reset()
	c.reply = {"ok": false, "error": "no JSON in reply", "service_fail": false}
	for _k in range(5):
		await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 3.0)
	K.check(fails, c.breaker_state() == "closed", "bad replies (service up) do not open the breaker")
	c.reply = {"ok": false, "error": "network result 13", "retryable": true, "service_fail": true}
	var before := c.posts
	var waits: Array[int] = []
	# Record what the retry loop asks the sleeper for instead of waiting on real timers:
	# SceneTree timers burn frame deltas, so on a loaded runner one stalled frame can end the
	# wait long before its wall-clock delay and the old took >= 250 check flaked (saw 12 ms).
	# The jitter stream is seeded so the expected delays replay exactly, draw for draw.
	c._jitter.seed = 97531
	c.sleep_ms = func(ms: int) -> void: waits.append(ms)
	var r6: Dictionary = await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 10.0)
	c.sleep_ms = Callable()
	K.check(fails, c.posts - before == 3 and int(r6["attempts"]) == 3 and int(c.stats["retries"]) == 2, "a transient failure is retried twice (%d attempts)" % (c.posts - before))
	var replay := RandomNumberGenerator.new()
	replay.seed = 97531
	var expected := [
		GmiClient.backoff_ms(0, replay.randf()),
		GmiClient.backoff_ms(1, replay.randf()),
	]
	K.check(
		fails,
		waits == expected,
		"with backoff between attempts: exactly %s ms (asked %s)" % [expected, waits]
	)
	K.check(fails, c.seen_ids[c.seen_ids.size() - 1] == str(r6["request_id"]) and c.seen_ids[c.seen_ids.size() - 3] == str(r6["request_id"]), "retries reuse the call's request id")
	c.reply = {"ok": false, "error": "HTTP 400 bad", "retryable": false, "service_fail": false}
	before = c.posts
	await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 10.0)
	K.check(fails, c.posts - before == 1, "a 4xx is not retried")
	c.reply = {"ok": false, "error": "HTTP 429 slow down", "retryable": true, "service_fail": true, "retry_after_ms": 0}
	before = c.posts
	var r8: Dictionary = await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 0.5)
	K.check(fails, c.posts - before == 1 and int(r8["attempts"]) == 1, "a retry that would overrun the 2 x timeout budget is skipped (%d attempts)" % (c.posts - before))
	c.queue_free()


## One breaker per group of roles (GmiBreakers): a group that fails opens alone, the others go on,
## and breaker_state() is the aggregate the alerts and the street badge read.
func _check_breaker_groups() -> void:
	K.check(fails, GmiBreakers.group_of("mayor") == "mayor" and GmiBreakers.group_of("residents") == "residents", "mayors and residents have their own groups")
	var supports := ["news", "council", "chaos", "citizens", "operator", "inspector"]
	var all_support := true
	for role: String in supports:
		all_support = all_support and GmiBreakers.group_of(role) == "support"
	K.check(fails, all_support, "the six support agents share the support group")
	K.check(fails, GmiBreakers.group_of("chatter") == GmiBreakers.DEFAULT_GROUP and GmiBreakers.group_of("talk") == GmiBreakers.DEFAULT_GROUP and GmiBreakers.group_of("something_new") == GmiBreakers.DEFAULT_GROUP, "chatter, talk and any new role land in the default group")
	var c := FakeNet.new()
	c.name = "FakeNetGroups"
	get_root().add_child(c)
	c.live_enabled = true
	K.check(fails, c.breakers.breaker_for("chatter") == c.breaker and c.breakers.breaker_for("mayor") != c.breaker and c.breakers.breaker_for("residents") != c.breakers.breaker_for("mayor"), "the client's breaker is the default group's; the others are separate")
	var states: Array[String] = []
	c.breaker_changed.connect(func(s: String) -> void: states.append(s))
	await _residents_storm(c, states)
	await _group_counts(c, states)
	_check_aggregate_states()
	c.queue_free()


## A residents storm: four failed batches open the residents' breaker and nobody else's.
func _residents_storm(c: FakeNet, states: Array[String]) -> void:
	for _k in range(4):
		await c.live_json("residents", "plans", "m", "s", "u", 1, 50, 10.0)
	K.check(fails, c.breakers.breaker_for("residents").state == "open" and c.breakers.breaker_for("mayor").state == "closed" and c.breakers.breaker_for("chatter").state == "closed" and c.breakers.breaker_for("news").state == "closed", "four residents failures open only the residents' breaker")
	K.check(fails, c.breaker_state() == "open" and states == ["open"] and int(c.stats["breaker_open"]) == 1, "the aggregate reads open and said so once (%s)" % str(states))
	K.check(fails, c.breakers.tripped() == PackedStringArray(["residents"]) and c.breakers.states()["residents"] == "open", "tripped() names the group")
	var posts := c.posts
	var blocked: Dictionary = await c.live_json("residents", "plans", "m", "s", "u", 1, 50, 10.0)
	K.check(fails, str(blocked["error"]) == "circuit open" and c.posts == posts, "the residents are refused while their breaker is open")
	c.reply = {"ok": true, "data": {"thought": "plan"}, "raw": "{}", "http": 200}
	var turn: Dictionary = await c.chat_json("mayor", "argon", "m", "s", "u", 1, 50, 10.0, func() -> Dictionary: return {"thought": "h"})
	K.check(fails, str(turn["source"]) == "live" and c.posts == posts + 1, "a mayor's turn still goes out and comes back live while the residents' breaker is open")
	var agent: Dictionary = await c.chat_json("news", "gazette", "m", "s", "u", 1, 50, 10.0, func() -> Dictionary: return {"headline": "h"})
	K.check(fails, str(agent["source"]) == "live", "and so does a support agent's")
	K.check(fails, c.breaker_state() == "open", "the aggregate stays open while any group is")


## Each group counts its own consecutive failures: a mayor's success does not reset the residents'.
func _group_counts(c: FakeNet, states: Array[String]) -> void:
	c.breakers.reset()
	states.clear()
	c.reply = {"ok": false, "error": "HTTP 503 down", "retryable": false, "service_fail": true}
	for _k in range(3):
		await c.live_json("residents", "plans", "m", "s", "u", 1, 50, 10.0)
	c.reply = {"ok": true, "data": {"thought": "plan"}, "raw": "{}", "http": 200}
	await c.chat_json("mayor", "argon", "m", "s", "u", 1, 50, 10.0, func() -> Dictionary: return {})
	K.check(fails, c.breakers.breaker_for("residents").failures == 3 and c.breaker_state() == "closed", "another group's success does not reset a group's failure count")
	c.reply = {"ok": false, "error": "HTTP 503 down", "retryable": false, "service_fail": true}
	await c.live_json("residents", "plans", "m", "s", "u", 1, 50, 10.0)
	K.check(fails, c.breakers.breaker_for("residents").state == "open", "its own fourth failure opens it")
	# A second group opening does not repeat the aggregate's "open"; the count of opens counts both.
	states.clear()
	for _k in range(4):
		await c.chat_json("news", "gazette", "m", "s", "u", 1, 50, 10.0, func() -> Dictionary: return {})
	K.check(fails, c.breakers.breaker_for("news").state == "open" and states.is_empty() and int(c.stats["breaker_open"]) == 3, "a second group opening leaves the aggregate's signal alone but is counted (%s, %d)" % [str(states), int(c.stats["breaker_open"])])


## An open group past its cool-down reads half_open; the aggregate prefers open.
func _check_aggregate_states() -> void:
	var b := CircuitBreaker.new(1, 1000)
	var set := GmiBreakers.new(b)
	set.group("residents").record_failure(100)
	K.check(fails, set.state(500) == "open" and set.state(1200) == "half_open", "the aggregate reads open, then half_open after the cool-down")
	b.record_failure(100)
	K.check(fails, set.state(1200) == "half_open" and set.state(500) == "open", "any group open wins over half_open")
	set.reset()
	K.check(fails, set.state() == "closed" and set.tripped().is_empty(), "reset() closes every group")


## The in-flight cap (flag gmi_inflight_cap, off by default): the background roles wait for a slot,
## the mayors and support agents never do and make the background halve its share.
func _check_inflight_cap() -> void:
	K.check(fails, not FeatureFlags.enabled("gmi_inflight_cap"), "the cap ships off")
	_check_admission_counts()
	FeatureFlags.set_override("gmi_inflight_cap", true)
	var c := SlowNet.new()
	c.name = "SlowNet"
	get_root().add_child(c)
	c.live_enabled = true
	await _cap_limits_background(c)
	await _cap_mayors_first(c)
	await _cap_gives_up(c)
	await _cap_keeps_probe(c)
	FeatureFlags.set_override("gmi_inflight_cap", false)
	await _cap_off(c)
	c.queue_free()


func _check_admission_counts() -> void:
	var adm := GmiAdmission.new()
	K.check(fails, GmiAdmission.is_priority("mayor") and GmiAdmission.is_priority("news") and GmiAdmission.is_priority("arena") and not GmiAdmission.is_priority("residents") and not GmiAdmission.is_priority("chatter"), "mayors, support agents and the ask panel are priority; residents and chatter are not")
	K.check(fails, adm.slots() == GmiAdmission.BACKGROUND_MAX and adm.can_enter("mayor"), "background slots with nobody out")
	adm.enter("mayor")
	K.check(fails, adm.slots() == GmiAdmission.BACKGROUND_MAX >> 1, "a priority call out halves the background's slots")
	adm.leave("mayor")
	adm.leave("mayor")
	K.check(fails, adm.priority() == 0 and adm.background() == 0 and adm.slots() == GmiAdmission.BACKGROUND_MAX, "leave() never goes below zero")
	for _k in range(GmiAdmission.BACKGROUND_MAX):
		adm.enter("residents")
	K.check(fails, not adm.can_enter("residents") and adm.can_enter("mayor"), "full background slots refuse the background and never the mayors")


## Waits until `want` results have come in (or a frame budget runs out).
func _until(results: Array, want: int) -> void:
	var guard := 0
	while results.size() < want and guard < 600:
		await process_frame
		guard += 1


func _cap_limits_background(c: SlowNet) -> void:
	var results: Array = []
	for k in range(14):
		_spawn_live(c, "residents", "batch%d" % k, results, 10.0)
	await _until(results, 14)
	var okays := results.filter(func(r: Dictionary) -> bool: return bool(r["ok"]))
	K.check(fails, okays.size() == 14 and c.peak <= GmiAdmission.BACKGROUND_MAX and c.peak > 1, "14 resident calls all finish with at most %d out at once (peak %d)" % [GmiAdmission.BACKGROUND_MAX, c.peak])
	K.check(fails, c.admission.background() == 0 and int(c.stats["in_flight"]) == 0, "every slot is given back")


## A mayor starts at once while the background is full, and the background then gets half the slots.
func _cap_mayors_first(c: SlowNet) -> void:
	var results: Array = []
	for k in range(8):
		_spawn_live(c, "residents", "m%d" % k, results, 10.0)
	await process_frame
	var before := c.started.size()
	_spawn_chat(c, "mayor", "argon", results)
	await process_frame
	K.check(fails, c.started.size() == before + 1 and c.admission.priority() == 1, "a mayor's call goes out at once while six background calls are out")
	await _until(results, 9)
	var turn: Dictionary = results.filter(func(r: Dictionary) -> bool: return str(r["role"]) == "mayor").front()
	K.check(fails, results.size() == 9 and str(turn["source"]) == "live", "and finishes live")


## A call that waits longer than its own timeout gives up and says why, without touching a breaker.
func _cap_gives_up(c: SlowNet) -> void:
	var results: Array = []
	c.hold = true
	for k in range(GmiAdmission.BACKGROUND_MAX):
		_spawn_live(c, "residents", "long%d" % k, results, 10.0)
	await process_frame
	var failed_before := int(c.stats["live_fail"])
	var late: Dictionary = await c.live_json("residents", "plans", "m", "s", "u", 1, 50, 0.05)
	K.check(fails, not bool(late["ok"]) and str(late["error"]) == "no free slot" and str(late["source"]) == "failed", "a call that outwaits its timeout fails as 'no free slot'")
	K.check(fails, int(c.stats["live_fail"]) == failed_before and c.breaker_state() == "closed", "pacing is not a service failure: no live_fail, no breaker")
	c.hold = false
	await _until(results, GmiAdmission.BACKGROUND_MAX)


## A half-open breaker hands out one probe. A call that takes it but then gives up waiting for a slot
## must not strand it: the group would stay half-open and refuse every later call for good.
func _cap_keeps_probe(c: SlowNet) -> void:
	var group := c.breakers.group("residents")
	group.cooldown_ms = 50
	for _k in range(group.failure_threshold):
		group.record_failure()
	var results: Array = []
	c.hold = true
	for k in range(GmiAdmission.BACKGROUND_MAX):
		_spawn_live(c, "chatter", "probe%d" % k, results, 10.0)
	await process_frame
	var guard := 0
	while group.peek_state() != CircuitBreaker.HALF_OPEN and guard < 300:
		await process_frame
		guard += 1
	var late: Dictionary = await c.live_json("residents", "plans", "m", "s", "u", 1, 50, 0.05)
	K.check(fails, str(late["error"]) == "no free slot", "past its cool-down the residents call outwaits the full slots (%s)" % str(late["error"]))
	K.check(fails, group.peek_state() == CircuitBreaker.HALF_OPEN and group.allow(), "and the half-open probe was not taken: the next call can still probe")
	group.record_failure()
	c.hold = false
	await _until(results, GmiAdmission.BACKGROUND_MAX)
	await _wait_half_open(group)
	var back: Dictionary = await c.live_json("residents", "plans", "m", "s", "u", 1, 50, 5.0)
	K.check(fails, bool(back["ok"]) and group.state == CircuitBreaker.CLOSED, "with a slot free the probe goes out and its success closes the group")
	group.cooldown_ms = c.breaker.cooldown_ms


func _wait_half_open(group: CircuitBreaker) -> void:
	var guard := 0
	while group.peek_state() != CircuitBreaker.HALF_OPEN and guard < 300:
		await process_frame
		guard += 1


func _cap_off(c: SlowNet) -> void:
	var results: Array = []
	c.peak = 0
	for k in range(14):
		_spawn_live(c, "residents", "free%d" % k, results, 10.0)
	await _until(results, 14)
	K.check(fails, c.peak == 14, "with the flag off all 14 go out at once (peak %d)" % c.peak)


func _spawn_live(c: GmiClient, role: String, agent: String, results: Array, timeout_s: float) -> void:
	var r: Dictionary = await c.live_json(role, agent, "m", "s", "u", 1, 50, timeout_s)
	r["role"] = role
	results.append(r)


func _spawn_chat(c: GmiClient, role: String, agent: String, results: Array) -> void:
	var r: Dictionary = await c.chat_json(role, agent, "m", "s", "u", 1, 50, 10.0, func() -> Dictionary: return {})
	results.append(r)


## A model that refuses the temperature (an HTTP 400 naming it) gets 1.0 and one more try at
## once; from then on its calls go out with 1.0 and are not tried twice.
func _check_client_temperature() -> void:
	var c := FakeNet.new()
	c.name = "FakeNetTemperature"
	get_root().add_child(c)
	c.live_enabled = true
	var kimi := "moonshotai/kimi-k3"
	var body := c.request_body(kimi, "s", "u", 50)
	var t0 := float(body["temperature"])
	var plain: bool = is_equal_approx(t0, GmiClient.TEMPERATURE) and str(body.get("reasoning_effort", "")) == "low"
	K.check(fails, plain, "request body: the default temperature and the model's extras")
	var refusal := 'HTTP 400 {"error":"invalid temperature: only 1 is allowed for this model"}'
	c.reply = {"ok": false, "error": refusal, "retryable": false, "service_fail": false}
	var res: Dictionary = await c.live_json("chatter", "round", kimi, "s", "u", 1, 50, 5.0)
	var again := c.posts == 2 and int(res["attempts"]) == 2
	K.check(fails, again, "a refused temperature is tried once more at once (%d posts)" % c.posts)
	var t1 := float(c.request_body(kimi, "s", "u", 50)["temperature"])
	K.check(fails, is_equal_approx(t1, 1.0), "the model gets temperature 1 from then on")
	await c.live_json("chatter", "round", kimi, "s", "u", 1, 50, 5.0)
	K.check(fails, c.posts == 3, "a model already on 1 is not tried twice (%d posts)" % c.posts)
	var t2 := float(c.request_body("x-ai/grok-4.5", "s", "u", 50)["temperature"])
	K.check(fails, is_equal_approx(t2, GmiClient.TEMPERATURE), "other models keep the default")
	var bad := "HTTP 400 bad max_tokens"
	c.reply = {"ok": false, "error": bad, "retryable": false, "service_fail": false}
	var before := c.posts
	await c.live_json("chatter", "round", "x-ai/grok-4.5", "s", "u", 1, 50, 5.0)
	K.check(fails, c.posts - before == 1, "another 400 is not retried")
	c.queue_free()


## A model whose reasoning switch is refused (an HTTP 400 naming thinking) moves to the next known
## form at once, each form is tried once, and the others keep their MODEL_EXTRAS.
func _check_client_reasoning() -> void:
	var c := FakeNet.new()
	c.name = "FakeNetReasoning"
	get_root().add_child(c)
	c.live_enabled = true
	var model := "deepseek-ai/DeepSeek-V4-Flash-0731"
	var first := c.request_body(model, "s", "u", 50)
	K.check(fails, first.has("thinking") and not first.has("reasoning_effort"), "reasoning: the table form goes out first")
	var refusal := 'HTTP 400 {"error":"thinking: disabled is not supported"}'
	c.reply = {"ok": false, "error": refusal, "retryable": false, "service_fail": false}
	var res: Dictionary = await c.live_json("chatter", "round", model, "s", "u", 1, 50, 5.0)
	var forms := GmiClient.REASONING_FORMS.size()
	K.check(fails, c.posts == forms and int(res["attempts"]) == forms, "reasoning: every form is tried once (%d posts)" % c.posts)
	var after := c.request_body(model, "s", "u", 50)
	K.check(fails, not after.has("thinking") and not after.has("reasoning_effort") and not after.has("enable_thinking"), "reasoning: with every form refused nothing extra is sent")
	var kimi := "moonshotai/kimi-k3"
	var kimi_refusal := {"ok": false, "error": 'HTTP 400 {"error":"reasoning_effort not allowed"}', "retryable": false, "service_fail": false}
	c.queued = [kimi_refusal, {"ok": true, "data": {"say": "ok"}, "raw": "{}", "http": 200}]
	var before := c.posts
	await c.live_json("chatter", "round", kimi, "s", "u", 1, 50, 5.0)
	var moved := c.request_body(kimi, "s", "u", 50)
	K.check(fails, c.posts - before == 2 and moved.has("thinking"), "reasoning: a refused form is replaced by the next one")
	K.check(fails, str(c.request_body("x-ai/grok-4.5", "s", "u", 50).get("reasoning_effort", "")) == "low", "reasoning: other models keep their own form")
	c.reply = {"ok": false, "error": "HTTP 400 bad max_tokens", "retryable": false, "service_fail": false}
	before = c.posts
	await c.live_json("chatter", "round", "x-ai/grok-4.5", "s", "u", 1, 50, 5.0)
	K.check(fails, c.posts - before == 1, "reasoning: a 400 that does not name it is not retried")
	c.queue_free()


func _check_flags() -> void:
	var p := FeatureFlags.parse_overrides(" overview=0, analytics=1,bogus=maybe,chat ,!posters,=1,audio=off")
	K.check(fails, p == {"overview": false, "analytics": true, "chat": true, "posters": false, "audio": false}, "GRIDFALL_FLAGS parsing (%s)" % str(p))
	K.check(fails, FeatureFlags.parse_overrides("").is_empty(), "an empty spec overrides nothing")
	FeatureFlags.load_layers("", false)
	var spec := FeatureFlags.describe()
	var described := true
	for k: String in spec.keys():
		described = described and not str((spec[k] as Dictionary).get("description", "")).is_empty()
	K.check(fails, spec.size() >= 10 and described, "every flag in data/feature_flags.json has a description (%d flags)" % spec.size())
	var reg_ok := true
	for e: Dictionary in REGISTRY.FEATURES:
		reg_ok = reg_ok and spec.has(str(e["id"])) and FeatureFlags.enabled(str(e["id"]))
	K.check(fails, reg_ok, "every first-person feature has a flag, on by default")
	K.check(fails, not FeatureFlags.enabled("analytics") and not FeatureFlags.enabled("error_tracking") and FeatureFlags.enabled("ops_alerts") and FeatureFlags.enabled("gmi_live"),
		"defaults: analytics and error tracking off, alerts and live GMI on")
	K.check(fails, FeatureFlags.enabled("no_such_flag_zz") and not FeatureFlags.enabled("no_such_flag_zz", false), "unknown flags use the caller's default")
	FeatureFlags.load_layers("overview=0,analytics=1", false)
	K.check(fails, not FeatureFlags.enabled("overview") and FeatureFlags.enabled("analytics") and FeatureFlags.enabled("chat"), "env overrides win over the defaults")
	var user_path := _scratch.path_join("flags.json")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_scratch))
	var f := FileAccess.open(user_path, FileAccess.WRITE)
	f.store_string("{\"traffic\": false, \"chat\": 0, \"audio\": \"on\", \"junk\": [1]}")
	f.close()
	K.check(fails, FeatureFlags.read_user(user_path) == {"traffic": false, "chat": false, "audio": true}, "user override file parsing")
	FeatureFlags.reload()


func _check_analytics() -> void:
	var path := OpsSink.path_of(Analytics.FILE)
	Analytics.configure(false)
	Analytics.track("session_start", {"view": "fp"})
	K.check(fails, not FileAccess.file_exists(path), "analytics off: track() writes nothing")
	Analytics.configure(true)
	Analytics.track("session_start", {"view": "fp", "contact": "someone@example.com"})
	Analytics.track("overview_open", {"sites": 3})
	var recs := OpsSink.read_all(Analytics.FILE)
	K.check(fails, recs.size() == 2 and str(recs[0]["event"]) == "session_start" and str(recs[1]["event"]) == "overview_open", "analytics on: one JSON line per event")
	if recs.size() == 2:
		K.check(fails, str(recs[0]["session"]) == Trace.session_id() and int(recs[1]["seq"]) > int(recs[0]["seq"]) and int((recs[1]["props"] as Dictionary)["sites"]) == 3, "records carry session, seq and props")
		K.check(fails, str((recs[0]["props"] as Dictionary)["contact"]) == "[EMAIL]", "analytics records are scrubbed")
	Analytics.configure(false)
	var rot := "rot.jsonl"
	for k in range(30):
		OpsSink.append(rot, {"k": k, "pad": "x".repeat(40)}, 600)
	var live_n := OpsSink.read_all(rot).size()
	K.check(fails, FileAccess.file_exists(OpsSink.path_of("rot.1.jsonl")) and live_n > 0 and live_n < 30, "files rotate to .1.jsonl past their cap (%d lines kept live)" % live_n)


func _check_error_tracker() -> void:
	var path := OpsSink.path_of(ErrorTracker.FILE)
	ErrorTracker.reset()
	ErrorTracker.set_file_output(false)
	ErrorTracker.breadcrumb("ignored while off")
	var r0 := ErrorTracker.capture("f", "res://a.gd", 3, "boom", "", Logger.ERROR_TYPE_SCRIPT)
	K.check(fails, r0.is_empty() and not FileAccess.file_exists(path), "error tracking off: nothing is written")
	K.check(fails, ErrorTracker.errors_in_last(60000) == 1 and int(ErrorTracker.counts()["error"]) == 1, "but errors are still counted in memory")
	ErrorTracker.set_file_output(true)
	ErrorTracker.breadcrumb("overview_open")
	ErrorTracker.set_context({"view_mode": "fp", "day": 3, "tick": 2})
	var code := "Invalid call with Bearer abcdef0123456789xyz"
	var rec := ErrorTracker.capture("_process", "res://scripts/x.gd", 42, code, "user me@example.com", Logger.ERROR_TYPE_ERROR)
	var recs := OpsSink.read_all(ErrorTracker.FILE)
	K.check(fails, recs.size() == 1 and str(rec.get("fingerprint", "")) == ErrorTracker.fingerprint("res://scripts/x.gd", 42, code), "error tracking on: one record with a stable fingerprint")
	if recs.size() == 1:
		var e: Dictionary = recs[0]
		K.check(fails, not str(e["message"]).contains("abcdef0123456789") and not str(e["message"]).contains("me@example.com"), "the message is scrubbed (%s)" % e["message"])
		K.check(fails, int((e["context"] as Dictionary)["day"]) == 3 and str((e["context"] as Dictionary)["view_mode"]) == "fp", "context: view mode and sim day")
		K.check(fails, (e["breadcrumbs"] as Array).size() == 1 and str((e["breadcrumbs"] as Array)[0]).ends_with("overview_open"), "breadcrumbs ride along")
		K.check(fails, not str(e["build"]).is_empty() and str(e["session"]) == Trace.session_id() and str(e["type"]) == "error" and int(e["line"]) == 42, "build, session, type and location are recorded")
	for _k in range(40):
		ErrorTracker.capture("_process", "res://scripts/y.gd", 7, "spam", "", Logger.ERROR_TYPE_ERROR)
	var spam := 0
	for e: Dictionary in OpsSink.read_all(ErrorTracker.FILE):
		if str(e["file"]) == "res://scripts/y.gd":
			spam += 1
	K.check(fails, spam == ErrorTracker.MAX_PER_FINGERPRINT and ErrorTracker.errors_in_last(60000) == 42, "repeats past %d per fingerprint are only counted (%d written)" % [ErrorTracker.MAX_PER_FINGERPRINT, spam])
	ErrorTracker.install(true)
	push_warning("ops test warning password=opensesame123")
	ErrorTracker.uninstall()
	var warn := {}
	for e: Dictionary in OpsSink.read_all(ErrorTracker.FILE):
		if str(e["type"]) == "warning":
			warn = e
	K.check(fails, not warn.is_empty() and not str(warn["message"]).contains("opensesame") and int(ErrorTracker.counts()["warning"]) == 1, "as a registered Logger it captures engine warnings (%s)" % str(warn.get("message", "none")))
	K.check(fails, not ErrorTracker.installed(), "uninstall() removes the logger")


func _check_alerts() -> void:
	var cfg := OpsAlerts.load_rules(OpsAlerts.RULES_PATH)
	var rules: Array = cfg.get("rules", [])
	K.check(fails, rules.size() == 5 and float(cfg.get("interval_s", 0)) > 0.0, "data/alert_rules.json loads (%d rules)" % rules.size())
	var calm_frames: Array = []
	for _k in range(200):
		calm_frames.append(16.6)
	var calm := {"frame_ms": calm_frames, "breaker_state": "closed", "live_outcomes": [true, true, false, true, true, true], "errors_last_minute": 1, "sim_stall_ratio": 1.2}
	K.check(fails, OpsAlerts.evaluate(rules, calm).is_empty(), "a healthy run fires nothing")
	var slow: Array = calm_frames.duplicate()
	for k in range(20):
		slow[k] = 80.0
	var bad := {"frame_ms": slow, "breaker_state": "open", "live_outcomes": [false, false, false, false, false, true, true], "errors_last_minute": 12, "sim_stall_ratio": 5.0}
	var ids: Array = OpsAlerts.evaluate(rules, bad).map(func(h: Dictionary) -> String: return str(h["id"]))
	ids.sort()
	K.check(fails, ids == ["error_burst", "frame_time_p95", "gmi_breaker_open", "gmi_live_failures", "sim_tick_stall"], "each rule fires on its bad input (%s)" % str(ids))
	K.check(fails, OpsAlerts.evaluate(rules, {"live_outcomes": [false, false, false]}).is_empty(), "the failure ratio needs min_calls outcomes")
	K.check(fails, OpsAlerts.evaluate(rules, {"frame_ms": [90.0, 90.0]}).is_empty(), "frame time needs min_samples")
	var vals: Array = []
	for k in range(1, 101):
		vals.append(float(k))
	K.check(fails, OpsAlerts.percentile(vals, 0.95) == 95.0 and OpsAlerts.percentile([], 0.95) == 0.0, "nearest-rank percentile")
	var rule := {"id": "x", "cooldown_s": 300}
	K.check(fails, OpsAlerts.due(rule, {}, 0) and not OpsAlerts.due(rule, {"x": 1000}, 200000) and OpsAlerts.due(rule, {"x": 1000}, 301000), "cool-down between repeats")
	var msg: String = (OpsAlerts.evaluate(rules, {"errors_last_minute": 12})[0] as Dictionary)["message"]
	K.check(fails, msg.begins_with("12"), "messages expand {value} (%s)" % msg)
	var ops := OpsAlerts.new()
	ops.name = "OpsAlerts"
	get_root().add_child(ops)
	K.check(fails, ErrorTracker.installed(), "OpsAlerts installs the error tracker")
	ErrorTracker.set_file_output(true)
	ops.rules = [{"id": "always", "kind": "errors_per_minute", "threshold": 0, "cooldown_s": 60, "message": "test alert"}]
	var first := ops.tick(10000)
	var again := ops.tick(20000)
	var later := ops.tick(80000)
	K.check(fails, first.size() == 1 and again.is_empty() and later.size() == 1 and ops.fired.size() == 2, "tick() fires through the cool-down")
	var stored := OpsSink.read_all(OpsAlerts.FILE)
	K.check(fails, stored.size() == 2 and str(stored[0]["id"]) == "always" and str(stored[0]["session"]) == Trace.session_id(), "alerts are recorded while error tracking is on")
	ops.queue_free()
	await process_frame
	K.check(fails, not ErrorTracker.installed(), "and removes it when it leaves the tree")
	ErrorTracker.set_file_output(false)


func _cleanup() -> void:
	var abs_dir := ProjectSettings.globalize_path(_scratch)
	var d := DirAccess.open(abs_dir)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(abs_dir.path_join(f))
	DirAccess.remove_absolute(abs_dir)
	OpsSink.dir = "user://ops"
