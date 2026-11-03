extends SceneTree
## The player's key path to GMI, without a network (every transport is a fake). Web-safe headers:
## the browser build sends only Authorization and Content-Type, because GMI's CORS preflight
## (measured 2026-11-03) allows no User-Agent, X-Request-ID or X-Trace-ID, while desktop keeps all
## five byte for byte. GmiClient.test_key(): one tiny call that says ok, rejected, rate_limited,
## blocked or error, ignores an open breaker and leaves no trace in the breaker, stats, caches or
## log. The key never reaches a status, a result, a console line or a log record, at any length of
## it (a 300-character key, fragments as short as eight characters). The key panel itself is in
## fp_keyflow_panel_test.gd. Most checks put a fake in place of _post, but the
## "wire" checks keep the real _post and replace only GmiClient._round_trip (the HTTPRequest), so
## what _post would put on the wire (its headers, the cut and scrub of an error body) is read
## from the recording instead of assumed.

const K := preload("res://tools/tests/fp_kit.gd")
const KIT := preload("res://tools/tests/fp_keyflow_kit.gd")
const PANEL := preload("res://scripts/fp/ui/gmi_key_panel.gd")
## What api.gmi-serving.com answered to a key-free preflight on 2026-11-03 (lower case).
const MEASURED_ALLOW := ["content-type", "authorization", "x-requested-with", "x-gmi-request-id"]
const FIVE := ["authorization", "content-type", "user-agent", "x-request-id", "x-trace-id"]

var fails: Array[String] = []


## A GmiClient with the real _post and a scripted, recorded network: only the HTTPRequest round
## trip (_round_trip) is replaced. `answer` is what the network says; every call it is handed is
## kept in `trips` with the headers and body exactly as _post built them.
class WireNet:
	extends GmiClient
	var trips: Array[Dictionary] = []
	var answer: Dictionary = {}

	func _round_trip(headers: PackedStringArray, body: String, timeout_s: float) -> Dictionary:
		trips.append({"headers": headers, "body": body, "timeout": timeout_s})
		return answer.duplicate()


## Everything the engine prints while it is installed (OS.add_logger): the console lines themselves,
## not the functions that build them.
class ConsoleTap:
	extends Logger
	var lines: Array[String] = []

	func _log_message(message: String, _error: bool) -> void:
		lines.append(message.strip_edges())

	## The GMI_TEST / GMI_FAIL lines printed so far.
	func gmi_lines() -> Array[String]:
		var out: Array[String] = []
		for l in lines:
			if l.begins_with("GMI_"):
				out.append(l)
		return out


## A WireNet whose build says it is the browser export (see GmiClient._detect_web).
class BrowserWireNet:
	extends WireNet

	func _detect_web() -> bool:
		return true


func _init() -> void:
	K.watchdog(self, "FP_KEYFLOW_TEST")
	await process_frame
	# The gate (and a bare run) set GRIDFALL_OFFLINE=1, which refuses a key test by design. Every
	# transport here is a fake, so the switch is lifted; _check_offline puts it back to prove it.
	var had_offline := OS.get_environment("GRIDFALL_OFFLINE")
	OS.unset_environment("GRIDFALL_OFFLINE")
	_check_headers()
	_check_flag()
	_check_classify()
	await _check_test_key()
	await _check_bypass()
	await _check_secrecy()
	await _check_wire()
	await _check_offline()
	if had_offline.is_empty():
		OS.unset_environment("GRIDFALL_OFFLINE")
	else:
		OS.set_environment("GRIDFALL_OFFLINE", had_offline)
	FeatureFlags.set_override("gmi_web_safe_headers", true)
	FeatureFlags.set_override("gmi_live", true)
	K.finish(self, "FP_KEYFLOW_TEST", fails)


func _names(headers: PackedStringArray) -> Array[String]:
	var out: Array[String] = []
	for h in headers:
		out.append(h.get_slice(":", 0).to_lower())
	return out


func _client(key: String = "") -> KIT.FakeKeyNet:
	return KIT.client(get_root(), key)


# ------------------------------------------------------------------ headers


func _check_headers() -> void:
	var desk := GmiClient.request_headers("K3Y", "rid1", "tid1", false)
	var want := PackedStringArray(
		[
			"Authorization: Bearer K3Y",
			"Content-Type: application/json",
			"User-Agent: GridFall/2.0 (Godot)",
			"X-Request-ID: rid1",
			"X-Trace-ID: tid1",
		]
	)
	K.check(fails, desk == want, "desktop sends the five headers, byte for byte (%s)" % [desk])
	var bare := GmiClient.request_headers("K3Y", "", "", false)
	K.check(
		fails,
		bare.size() == 3 and _names(bare) == ["authorization", "content-type", "user-agent"],
		"desktop leaves out the two ids when a call has none"
	)
	var web := GmiClient.request_headers("K3Y", "rid1", "tid1", true)
	K.check(
		fails,
		web == PackedStringArray(["Authorization: Bearer K3Y", "Content-Type: application/json"]),
		"web sends only Authorization and Content-Type (%s)" % [web]
	)
	var dropped: Array[String] = []
	for n in _names(desk):
		if not _names(web).has(n):
			dropped.append(n)
	dropped.sort()
	K.check(
		fails,
		dropped == ["user-agent", "x-request-id", "x-trace-id"],
		"web drops exactly User-Agent, X-Request-ID and X-Trace-ID (%s)" % [dropped]
	)
	var allowed := true
	for n in _names(web):
		allowed = allowed and MEASURED_ALLOW.has(n)
	K.check(fails, allowed, "every web header is on the measured preflight allow-list")
	K.check(fails, not _names(desk).has("x-gmi-request-id"), "no x-gmi-request-id is invented")
	var check_script := FileAccess.get_file_as_string("res://tools/demo_check.sh")
	var asked := RegEx.create_from_string('WEB_REQUEST_HEADERS="([^"]*)"').search(check_script)
	K.check(
		fails,
		asked != null and Array(asked.get_string(1).split(",")) == _names(web),
		"tools/demo_check.sh preflights exactly the headers the web client sends"
	)
	var src := FileAccess.get_file_as_string("res://scripts/ai/gmi_client.gd")
	K.check(
		fails,
		src.count('"User-Agent: ') == 1 and src.count('"X-Request-ID: ') == 1,
		"only request_headers() builds the wire headers (nothing in _post adds one back)"
	)
	var c := _client("hdrkey_0123456789")
	var a := c._wire_headers("r", "t")
	c.web_build = true
	var b := c._wire_headers("r", "t")
	K.check(
		fails,
		_names(a) == FIVE and _names(b) == ["authorization", "content-type"],
		(
			"_post's header set follows the build: desktop five, web two (%s, %s)"
			% [_names(a), _names(b)]
		)
	)
	FeatureFlags.set_override("gmi_web_safe_headers", false)
	K.check(
		fails,
		_names(c._wire_headers("r", "t")) == FIVE,
		"with gmi_web_safe_headers off the web build sends all five again"
	)
	FeatureFlags.set_override("gmi_web_safe_headers", true)
	c.free()


func _check_flag() -> void:
	var spec := FeatureFlags.describe()
	var flag: Dictionary = spec.get("gmi_web_safe_headers", {})
	K.check(
		fails,
		bool(flag.get("default", false)) and str(flag.get("description", "")).contains("Web"),
		"gmi_web_safe_headers exists, defaults on and says it is for the web build"
	)
	FeatureFlags.set_override("gmi_web_safe_headers", true)
	K.check(
		fails,
		GmiClient.web_headers_active(true) and not GmiClient.web_headers_active(false),
		"the web-safe set is used on the web build only"
	)
	FeatureFlags.set_override("gmi_web_safe_headers", false)
	K.check(fails, not GmiClient.web_headers_active(true), "and the flag switches it off")
	FeatureFlags.set_override("gmi_web_safe_headers", true)


# ------------------------------------------------------------------ test_key


func _check_classify() -> void:
	var cases := [
		[{"ok": true, "data": {"a": 1}, "http": 200}, "ok", 200],
		[{"ok": false, "error": "no JSON in reply", "http": 200}, "ok", 200],
		[{"ok": false, "error": "HTTP 401 nope", "http": 401}, "rejected", 401],
		[{"ok": false, "error": "HTTP 403 nope"}, "rejected", 403],
		[{"ok": false, "error": "HTTP 429 slow", "http": 429}, "rate_limited", 429],
		[{"ok": false, "error": "network result 2", "http": 0, "result": 2}, "blocked", 0],
		[{"ok": false, "error": "network result 13"}, "blocked", 0],
		[{"ok": false, "error": "HTTP 500 boom", "http": 500}, "error", 500],
		[{"ok": false, "error": "HTTP 404 no model", "http": 404}, "error", 404],
		[{"ok": false, "error": "request error 31", "http": 0}, "error", 0],
		[{}, "error", 0],
	]
	var bad: Array[String] = []
	for c: Array in cases:
		var v := GmiClient.classify_key_reply(c[0])
		if str(v["status"]) != str(c[1]) or int(v["http"]) != int(c[2]):
			bad.append("%s -> %s" % [c[0], v])
	K.check(
		fails, bad.is_empty(), "replies map to ok/rejected/rate_limited/blocked/error %s" % [bad]
	)
	var models := ["a/Big-Pro", "b/Mid-Flash", "c/Tiny-flash-lite", "d/Other"]
	K.check(
		fails,
		(
			GmiClient.key_test_model(models) == "c/Tiny-flash-lite"
			and GmiClient.key_test_model(["a/Big-Pro", "b/Mid-Flash"]) == "b/Mid-Flash"
			and GmiClient.key_test_model(["x", "y"]) == "x"
		),
		"the test model is the cheapest-looking one: lite, then flash, then the first"
	)
	var cfg := GmiClient.key_test_model(ResidentMinds.MODELS)
	K.check(fails, ResidentMinds.MODELS.has(cfg), "and it is a model the game is configured with")


func _check_test_key() -> void:
	var c := _client("tk_0123456789abcdef")
	var table := [
		[{"ok": true, "data": {"ok": 1}, "http": 200}, "ok", 200],
		[{"ok": false, "error": "no JSON in reply", "http": 200, "service_fail": false}, "ok", 200],
		[{"ok": false, "error": "HTTP 401 x", "http": 401, "retryable": false}, "rejected", 401],
		[{"ok": false, "error": "HTTP 403 x", "http": 403, "retryable": false}, "rejected", 403],
		[{"ok": false, "error": "HTTP 429 x", "http": 429, "retryable": true}, "rate_limited", 429],
		[{"ok": false, "error": "network result 2", "http": 0, "retryable": true}, "blocked", 0],
		[{"ok": false, "error": "HTTP 503 x", "http": 503, "retryable": true}, "error", 503],
	]
	for row: Array in table:
		c.reply = row[0]
		c.posts = 0
		var r: Dictionary = await c.test_key()
		var good: bool = str(r["status"]) == str(row[1]) and int(r["http"]) == int(row[2])
		K.check(
			fails,
			good and c.posts == 1 and float(r["seconds"]) >= 0.0,
			(
				"test_key says %s for HTTP %s, in one call even when retryable (%s)"
				% [row[1], row[2], r]
			)
		)
	var last: Dictionary = c.seen[-1]
	K.check(
		fails,
		(
			int(last["max_tokens"]) == 8
			and str(last["model"]) == GmiClient.key_test_model(ResidentMinds.MODELS)
		),
		"the call asks for 8 tokens from the cheapest configured model (%s)" % [last]
	)
	K.check(
		fails,
		not str(last["rid"]).is_empty() and str(last["tid"]) == Trace.current(),
		"it hands _post a request id and the trace id like any other call"
	)
	K.check(
		fails,
		float(last["timeout"]) > 0.0 and float(last["timeout"]) <= 15.0,
		"with a short timeout (%s s)" % [last["timeout"]]
	)
	var keyless := _client()
	keyless.api_key = ""
	var none: Dictionary = await keyless.test_key()
	K.check(
		fails,
		str(none["status"]) == "error" and keyless.posts == 0,
		"without a key nothing is sent and the status is error"
	)
	FeatureFlags.set_override("gmi_live", false)
	c.posts = 0
	var killed: Dictionary = await c.test_key()
	K.check(
		fails,
		str(killed["status"]) == "error" and c.posts == 0,
		"the gmi_live kill switch stops the test too"
	)
	FeatureFlags.set_override("gmi_live", true)
	keyless.free()
	c.free()


func _snapshot(c: GmiClient) -> Dictionary:
	return {
		"state": c.breaker.state,
		"failures": c.breaker.failures,
		"opened": c.breaker.open_count,
		"stats": c.stats.duplicate(),
		"outcomes": c.live_outcomes.duplicate(),
		"log": c.log_records.size(),
		"session": c.session_cache.duplicate(true),
		"replay": c.replay_cache.duplicate(true),
		"seq": c._seq,
	}


func _check_bypass() -> void:
	var c := _client("bp_0123456789abcdef")
	c.live_enabled = true
	c.replay_cache = {"mayor|argon": [{"day": 1, "data": {"thought": "x"}}]}
	c.reply = {
		"ok": false, "error": "HTTP 503 down", "http": 503, "retryable": false, "service_fail": true
	}
	for _i in range(4):
		await c.live_json("chatter", "round", "m", "s", "u", 1, 50, 3.0)
	K.check(fails, c.breaker_state() == "open", "setup: four service failures open the breaker")
	var before := _snapshot(c)
	var posts := c.posts
	c.reply = {"ok": false, "error": "no JSON in reply", "http": 200, "service_fail": false}
	var ok: Dictionary = await c.test_key()
	K.check(
		fails,
		str(ok["status"]) == "ok" and c.posts == posts + 1,
		"an open breaker does not stop the key test (it went out)"
	)
	K.check(
		fails,
		_snapshot(c) == before,
		"a passing test leaves the breaker, stats, caches and log alone"
	)
	c.reply = {
		"ok": false, "error": "HTTP 503 down", "http": 503, "retryable": true, "service_fail": true
	}
	for _i in range(5):
		await c.test_key()
	K.check(
		fails,
		_snapshot(c) == before and c.breaker_state() == "open",
		"failed tests do not count: no failure recorded, no live_fail, nothing logged or cached"
	)
	c.breaker.reset()
	var base_fail := int(c.stats["live_fail"])
	for _i in range(6):
		await c.test_key()
	K.check(
		fails,
		(
			c.breaker_state() == "closed"
			and c.live_outcomes.size() == 4
			and int(c.stats["live_fail"]) == base_fail
		),
		"six failed tests on a closed breaker never open it"
	)
	c.live_enabled = false
	c.reply = {"ok": true, "data": {"ok": 1}, "http": 200}
	var off: Dictionary = await c.test_key()
	K.check(fails, str(off["status"]) == "ok", "the Live toggle being off does not stop the test")
	c.free()


# ------------------------------------------------------------------ secrecy


func _check_secrecy() -> void:
	var key := KIT.long_key()
	K.check(fails, key.length() == 300, "setup: a 300-character key")
	K.check(
		fails,
		(
			KIT.leaks("GMI_TEST ok " + key.left(KIT.FRAGMENT), key)
			and KIT.leaks(key.substr(150, KIT.FRAGMENT) + " tail", key)
			and KIT.leaks("x" + key.right(KIT.FRAGMENT), key)
			and not KIT.leaks("GMI_TEST rejected http=401 in 0.3 s", key)
			and not KIT.leaks(key.left(KIT.FRAGMENT - 1), key)
		),
		"setup: the leak oracle sees an 8-character piece of the key at the start, middle or end"
	)
	var c := _client(key)
	K.check(fails, c.api_key == key and c.player_key == key, "the client holds the whole key")
	c.reply = {
		"ok": false,
		"error": 'HTTP 401 {"error":"bad key %s"}' % key,
		"http": 401,
		"retryable": false,
		"service_fail": false,
	}
	var r: Dictionary = await c.test_key()
	K.check(
		fails,
		str(r["status"]) == "rejected" and not KIT.leaks(JSON.stringify(r), key),
		"the result of a rejected test (error text echoing the key) never holds the key"
	)
	var line := c._key_test_line(r)
	K.check(
		fails,
		line.begins_with("GMI_TEST rejected http=401") and not KIT.leaks(line, key),
		"the console line says status, code and seconds only (%s)" % line
	)
	var tap := ConsoleTap.new()
	OS.add_logger(tap)
	await c.test_key()
	OS.remove_logger(tap)
	var printed := tap.gmi_lines()
	K.check(
		fails,
		(
			printed.size() == 1
			and printed[0].begins_with("GMI_TEST rejected http=401")
			and not KIT.leaks(printed[0], key)
		),
		(
			"what the key test really prints to the console is that one line, without the key (%s)"
			% [printed]
		)
	)
	var letters := KIT.long_key(true)
	var c2 := _client(letters)
	var fail_line := c2._failure_line(
		{"role": "mayor", "agent": "argon", "model": "m", "error": "HTTP 401 echoed " + letters}
	)
	K.check(
		fails,
		fail_line.begins_with("GMI_FAIL mayor/argon") and not KIT.leaks(fail_line, letters),
		"the GMI_FAIL line scrubs a long key before it cuts the error (no fragment is left)"
	)
	# _report_failure prints _failure_line and nothing else, once per distinct line.
	var echo := {
		"role": "mayor",
		"agent": "argon",
		"model": "m",
		"error": "HTTP 401 " + letters + " " + letters
	}
	var tap2 := ConsoleTap.new()
	OS.add_logger(tap2)
	c2._report_failure(echo)
	c2._report_failure(echo)
	OS.remove_logger(tap2)
	var shown := tap2.gmi_lines()
	K.check(
		fails,
		(
			shown.size() == 1
			and shown[0] == c2._failure_line(echo)
			and shown[0].begins_with("GMI_FAIL mayor/argon on m: HTTP 401")
			and not KIT.leaks(shown[0], letters)
		),
		(
			"_report_failure prints the scrubbed GMI_FAIL line once, with no part of the key (%s)"
			% [shown]
		)
	)
	c2.live_enabled = true
	c2.reply = {
		"ok": false, "error": "HTTP 401 echoed " + letters, "http": 401, "service_fail": false
	}
	await c2.chat_json("mayor", "argon", "m", "s", "u", 1, 50, 3.0, func() -> Dictionary: return {})
	var logged := JSON.stringify(c2.log_records)
	K.check(
		fails,
		c2.log_records.size() == 1 and not KIT.leaks(logged, letters),
		"the GMI Log record of a failed call holds no part of the key"
	)
	var hdr := GmiClient.request_headers(key, "r", "t", true)
	K.check(
		fails,
		not KIT.leaks(Redact.scrub("sent: " + "\n".join(hdr)), key),
		"the redactor masks the key even inside a dumped Authorization header"
	)
	c.free()
	c2.free()


# ------------------------------------------------------------ the real _post on a recorded wire


func _wire_client(key: String, web: bool) -> WireNet:
	var c := WireNet.new()
	c.name = "WireNet"
	get_root().add_child(c)
	c.set_player_key(key)
	c.web_build = web
	return c


func _chat_reply(content: String) -> Dictionary:
	var body := JSON.stringify({"choices": [{"message": {"content": content}}]})
	return {"result": 0, "http": 200, "headers": PackedStringArray(), "body": body.to_utf8_buffer()}


func _error_reply(http: int, text: String, headers: PackedStringArray = []) -> Dictionary:
	return {"result": 0, "http": http, "headers": headers, "body": text.to_utf8_buffer()}


func _check_wire() -> void:
	# --- _post puts the build's header set on the wire (the line the CORS fix rests on).
	var c := _wire_client("wire_0123456789abcdef", false)
	c.answer = _chat_reply('{"ok": 1}')
	c._hdr_request_id = "rid1"
	c._hdr_trace_id = "tid1"
	var r: Dictionary = await c._post("m", "s", "u", 8, 5.0)
	K.check(
		fails,
		bool(r["ok"]) and c.trips.size() == 1,
		"setup: the real _post ran over the recorded wire"
	)
	var desk: Array[String] = _names(c.trips[0]["headers"])
	K.check(
		fails,
		desk == FIVE and c.trips[0]["headers"].has("X-Request-ID: rid1"),
		"desktop: _post sends the five headers, ids included (%s)" % [desk]
	)
	K.check(
		fails,
		c._hdr_request_id == "" and c._hdr_trace_id == "",
		"_post consumes the request and trace id it was handed"
	)
	c.web_build = true
	c._hdr_request_id = "rid2"
	c._hdr_trace_id = "tid2"
	await c._post("m", "s", "u", 8, 5.0)
	var web: Array[String] = _names(c.trips[1]["headers"])
	K.check(
		fails,
		web == ["authorization", "content-type"],
		"web: _post sends Authorization and Content-Type and nothing else (%s)" % [web]
	)
	K.check(
		fails,
		(
			not "\n".join(c.trips[1]["headers"]).contains("rid2")
			and c.trips[1]["headers"][0] == "Authorization: Bearer " + c.api_key
		),
		"web: the ids never reach the wire and the bearer key is the client's"
	)
	FeatureFlags.set_override("gmi_web_safe_headers", false)
	c._hdr_request_id = "rid3"
	c._hdr_trace_id = "tid3"
	await c._post("m", "s", "u", 8, 5.0)
	K.check(
		fails,
		_names(c.trips[2]["headers"]) == FIVE,
		"web with gmi_web_safe_headers off: _post sends all five again"
	)
	FeatureFlags.set_override("gmi_web_safe_headers", true)
	# --- the production path (live_json) and the key test both go through that same _post.
	c.live_enabled = true
	await c.live_json("mayor", "argon", "m", "s", "u", 1, 50, 3.0)
	K.check(
		fails,
		_names(c.trips[-1]["headers"]) == ["authorization", "content-type"],
		"web: a live_json call is sent with the two headers too"
	)
	c.answer = _error_reply(401, "nope")
	var t: Dictionary = await c.test_key()
	var sent: Dictionary = JSON.parse_string(c.trips[-1]["body"])
	K.check(
		fails,
		(
			_names(c.trips[-1]["headers"]) == ["authorization", "content-type"]
			and int(sent["max_tokens"]) == 8
			and str(sent["model"]) == GmiClient.key_test_model(ResidentMinds.MODELS)
			and float(c.trips[-1]["timeout"]) <= 15.0
			and str(t["status"]) == "rejected"
		),
		"web: the key test goes out through the same _post: two headers, 8 tokens, the test model"
	)
	# --- Retry-After survives the round trip; a request that cannot start is a service failure.
	c.answer = _error_reply(429, "slow down", PackedStringArray(["Retry-After: 3"]))
	var slow: Dictionary = await c._post("m", "s", "u", 8, 5.0)
	K.check(
		fails,
		int(slow["retry_after_ms"]) == 3000 and int(slow["http"]) == 429,
		"_post reads Retry-After from the round trip's headers (%s)" % [slow.get("retry_after_ms")]
	)
	c.answer = {"start_error": 31}
	var dead: Dictionary = await c._post("m", "s", "u", 8, 5.0)
	K.check(
		fails,
		(
			str(dead["error"]) == "request error 31"
			and bool(dead["service_fail"])
			and int(dead["http"]) == 0
		),
		"a request that cannot start is 'request error 31', a service failure with no HTTP code"
	)
	# --- a stalled answer is a timeout, not a block.
	c.answer = {
		"result": HTTPRequest.RESULT_TIMEOUT,
		"http": 0,
		"headers": PackedStringArray(),
		"body": PackedByteArray()
	}
	var late: Dictionary = await c.test_key()
	c.answer = {
		"result": HTTPRequest.RESULT_CANT_CONNECT,
		"http": 0,
		"headers": PackedStringArray(),
		"body": PackedByteArray()
	}
	var cut: Dictionary = await c.test_key()
	K.check(
		fails,
		(
			str(late["status"]) == "blocked"
			and bool(late["timed_out"])
			and str(cut["status"]) == "blocked"
			and not bool(cut["timed_out"])
		),
		"a timeout is blocked with timed_out; a refused connection is blocked without it"
	)
	c.answer = _error_reply(400, '{"error":"temperature not supported"}')
	var bad: Dictionary = await c.test_key()
	K.check(
		fails,
		str(bad["status"]) == "error" and int(bad["http"]) == 400,
		"an HTTP 400 is an error that keeps its code (%s)" % [bad]
	)
	c.free()
	# --- the real _post scrubs an echoed key BEFORE it cuts the body to 140 characters.
	var key := KIT.long_key()
	var c2 := _wire_client(key, true)
	# 18 + 80 characters of body, then the key: a plain cut at 140 keeps its first 42 characters.
	c2.answer = _error_reply(401, '{"error":"bad key ' + "x".repeat(80) + key + '"}')
	var echoed: Dictionary = await c2._post("m", "s", "u", 8, 5.0)
	K.check(
		fails,
		str(echoed["error"]).begins_with("HTTP 401") and not KIT.leaks(str(echoed["error"]), key),
		(
			"an error body echoing the key leaves no fragment after the 140-char cut (%s)"
			% [echoed["error"]]
		)
	)
	var viewed: Dictionary = await c2.test_key()
	K.check(
		fails,
		(
			not KIT.leaks(JSON.stringify(viewed), key)
			and not KIT.leaks(c2._key_test_line(viewed), key)
		),
		"and neither the test result nor its console line carries it"
	)
	c2.free()
	await _check_web_default()


## Nothing but the default decides which build this is: a browser export sends the web set.
func _check_web_default() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/ai/gmi_client.gd")
	# Headless cannot be a browser, so a client built where _detect_web() says "web" stands in for
	# the export: nothing assigns web_build, yet its own default must send the two-header set.
	var browser := BrowserWireNet.new()
	browser.name = "BrowserWireNet"
	get_root().add_child(browser)
	browser.set_player_key("browser_0123456789abcdef")
	K.check(
		fails,
		browser.web_build,
		"a client in a web build starts with web_build on, by default and without being told"
	)
	browser.answer = _chat_reply('{"ok": 1}')
	browser._hdr_request_id = "rid9"
	browser._hdr_trace_id = "tid9"
	await browser._post("m", "s", "u", 8, 5.0)
	K.check(
		fails,
		_names(browser.trips[0]["headers"]) == ["authorization", "content-type"],
		(
			"and that default client's _post sends Authorization and Content-Type only (%s)"
			% [_names(browser.trips[0]["headers"])]
		)
	)
	browser.answer = _error_reply(401, "no")
	var browser_test: Dictionary = await browser.test_key()
	K.check(
		fails,
		(
			_names(browser.trips[-1]["headers"]) == ["authorization", "content-type"]
			and str(browser_test["status"]) == "rejected"
		),
		"and so does its key test"
	)
	browser.free()
	K.check(
		fails,
		(
			src.contains("var web_build: bool = _detect_web()")
			and src.contains("func _detect_web() -> bool:\n\treturn WebSupport.is_web()\n")
		),
		"web_build defaults to _detect_web(), which is WebSupport.is_web(): no switch to forget"
	)
	K.check(
		fails,
		(
			src.contains("var headers := _wire_headers(request_id, trace_id)")
			and src.count("request_headers(api_key") == 1
		),
		"_post builds its headers with _wire_headers, not with a hard-wired build"
	)
	var fresh := GmiClient.new()
	K.check(
		fails,
		fresh.web_build == WebSupport.is_web() and fresh.web_build == OS.has_feature("web"),
		"a plain client's web_build is what the engine says (off here: this is not a browser)"
	)
	fresh.free()


func _check_offline() -> void:
	var c := _client("off_0123456789abcdef")
	c.reply = {"ok": true, "data": {"ok": 1}, "http": 200}
	OS.set_environment("GRIDFALL_OFFLINE", "1")
	var r: Dictionary = await c.test_key()
	K.check(
		fails,
		(
			c.posts == 0
			and str(r["status"]) == "error"
			and str(r["refused"]) == "offline"
			and c.test_refusal() == "offline"
		),
		"GRIDFALL_OFFLINE=1 refuses the key test: nothing is sent (%s)" % [r]
	)
	K.check(
		fails,
		PANEL.test_line(r) == "The offline switch is on, so nothing calls GMI.",
		"and the panel says why in plain words (%s)" % PANEL.test_line(r)
	)
	OS.unset_environment("GRIDFALL_OFFLINE")
	var ok: Dictionary = await c.test_key()
	K.check(
		fails,
		(
			c.posts == 1
			and str(ok["status"]) == "ok"
			and str(ok["refused"]).is_empty()
			and c.test_refusal().is_empty()
		),
		"with the switch off again the same client's test goes out"
	)
	c.free()
