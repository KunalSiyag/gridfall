extends SceneTree
## Runtime ops (scripts/ops): circuit breaker, retry classification and backoff, log scrubbing,
## trace and request ids, GmiClient offline fallback and breaker wiring, feature flags, analytics
## and error tracking (no-op when off, JSON lines when on), alert rule evaluation.

const K := preload("res://tools/tests/fp_kit.gd")
const REGISTRY := preload("res://scripts/fp/fp_features.gd")

var fails: Array[String] = []
var _scratch: String = ""


## A GmiClient whose transport fails on demand and records the request id it was handed.
class FakeNet extends GmiClient:
	var posts: int = 0
	var seen_ids: Array[String] = []
	var seen_traces: Array[String] = []
	var reply: Dictionary = {"ok": false, "error": "HTTP 503 down", "retryable": false, "service_fail": true}

	func _post(_model: String, _system_prompt: String, _user_prompt: String, _max_tokens: int, _timeout_s: float) -> Dictionary:
		posts += 1
		seen_ids.append(_hdr_request_id)
		seen_traces.append(_hdr_trace_id)
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
	K.check(fails, not bool(l5["ok"]) and str(l5["error"]) == "circuit open" and c.posts == 4, "while open live_json fails fast with 'circuit open'")
	K.check(fails, int(c.stats["breaker_skip"]) == 2 and c.live_failure_ratio() == 1.0, "skips are counted; live outcomes feed the failure ratio")
	c.breaker.reset()
	c.reply = {"ok": false, "error": "no JSON in reply", "service_fail": false}
	for _k in range(5):
		await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 3.0)
	K.check(fails, c.breaker_state() == "closed", "bad replies (service up) do not open the breaker")
	c.reply = {"ok": false, "error": "network result 13", "retryable": true, "service_fail": true}
	var before := c.posts
	var t0 := Time.get_ticks_msec()
	var r6: Dictionary = await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 10.0)
	var took := Time.get_ticks_msec() - t0
	K.check(fails, c.posts - before == 3 and int(r6["attempts"]) == 3 and int(c.stats["retries"]) == 2, "a transient failure is retried twice (%d attempts)" % (c.posts - before))
	K.check(fails, took >= 500 and took < 4000, "with backoff between attempts (%d ms)" % took)
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
