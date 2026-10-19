extends SceneTree
## Slice D acceptance test (docs/fp/slices/D-posters.md): the image client on a fake transport and
## virtual time (key, live flow, cache, breaker, budgets, queue order, offline determinism), then
## the poster feature on a grown kit city (carriers, director, wall posters, hoardings, save and
## load, setup gating, composites, pick, teardown). Offline; finishes in seconds of wall clock.

const KIT := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const FAKE_KEY := "TESTKEY123"
const MEDIA_URL := "https://storage.googleapis.com/gmi-test/out.png"

var fails: Array = []
var _ms: float = 0.0
var _day: int = 1


## Scripted HTTP stand-in: answers from a queue (or a default), records every call.
class FakeTransport:
	extends RefCounted
	var calls: Array[Dictionary] = []
	var replies: Array = []
	var default_reply: Callable

	func send(method: String, url: String, headers: PackedStringArray, body: String, to_file: String) -> Dictionary:
		calls.append({"method": method, "url": url, "headers": headers, "body": body, "to_file": to_file})
		if not replies.is_empty():
			return replies.pop_front()
		if default_reply.is_valid():
			return default_reply.call(method, url, body)
		return {"code": 500, "body": "no reply".to_utf8_buffer()}

	func posts() -> Array[Dictionary]:
		return calls.filter(func(c: Dictionary) -> bool: return str(c["method"]) == "POST")


func _init() -> void:
	await process_frame
	await _test_client()
	KIT.finish(self, "FP_POSTERS_TEST", fails)


func check(ok: bool, what: String) -> void:
	KIT.check(fails, ok, what)


# ------------------------------------------------------------------ helpers

static func _json_reply(code: int, d: Dictionary) -> Dictionary:
	return {"code": code, "body": JSON.stringify(d).to_utf8_buffer()}


static func _png_bytes(w: int, h: int) -> PackedByteArray:
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	img.fill(Color(0.2, 0.5, 0.8))
	img.fill_rect(Rect2i(0, 0, w / 2, h), Color(0.9, 0.3, 0.1))
	return img.save_png_to_buffer()


## A fake that completes every job: submit -> success with a media url, download -> a PNG.
static func _ok_reply(method: String, url: String, _body: String) -> Dictionary:
	if method == "POST":
		return _json_reply(200, {"request_id": "r", "status": "success", "outcome": {"media_urls": [{"url": MEDIA_URL}]}})
	if url == MEDIA_URL:
		return {"code": 200, "body": _png_bytes(48, 20)}
	return _json_reply(200, {"status": "success", "outcome": {"media_urls": [{"url": MEDIA_URL}]}})


func _gmi_client(live: bool) -> GmiClient:
	var c: GmiClient = (load("res://scripts/ai/gmi_client.gd") as GDScript).new()
	root.add_child(c)
	c.api_key = FAKE_KEY
	c.live_enabled = live
	return c


func _image_client(c: GmiClient, fake: FakeTransport) -> GmiImageClient:
	var ic := GmiImageClient.new()
	root.add_child(ic)
	ic.setup(c, func() -> int: return _day)
	ic.clock = func() -> float: return _ms
	if fake != null:
		ic.transport = fake.send
	ic.allow_live_with_injected_transport = true
	ic.poll_s = 0.05
	ic.submit_spacing_s = 0.0
	ic.backoff_s = [0.1, 0.4]
	ic.deadline_s = 30.0
	return ic


## Advances virtual time in 50 ms steps, ticking and yielding frames, until done() or a wall cap.
func _pump(ic: GmiImageClient, done: Callable, wall_ms: int = 3000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < wall_ms:
		_ms += 50.0
		ic.tick(0.05)
		await process_frame
		if done.call():
			return true
	return false


# ------------------------------------------------------------------ image client

func _test_client() -> void:
	print("-- image client")
	check(GmiImageClient.key_for(" A  Cafe ", "1536x640") == GmiImageClient.key_for("a cafe", "1536x640"), "key normalises case and whitespace")
	var k := GmiImageClient.key_for("a cafe", "1536x640")
	check(k.length() == 32 and k.is_valid_hex_number(), "key is 32 hex characters")
	check(k != GmiImageClient.key_for("a cafe", "768x1152"), "key depends on the size")
	await _test_live_flow()
	await _test_default_transport_offline()
	await _test_breaker()
	await _test_budgets()
	await _test_queue_order()
	await _test_offline_determinism()


func _test_live_flow() -> void:
	var c := _gmi_client(true)
	var fake := FakeTransport.new()
	fake.replies = [
		_json_reply(200, {"request_id": "abc", "status": "queued"}),
		{"code": 429, "body": PackedByteArray()},
		_json_reply(200, {"request_id": "abc", "status": "processing"}),
		_json_reply(200, {"request_id": "abc", "status": "success", "outcome": {"media_urls": [{"url": MEDIA_URL}]}}),
		{"code": 200, "body": _png_bytes(64, 32)},
	]
	var ic := _image_client(c, fake)
	var got: Array[Dictionary] = []
	var state := {"returned": false}
	ic.image_ready.connect(func(key: String, tex: Texture2D, meta: Dictionary) -> void:
		got.append({"key": key, "tex": tex, "meta": meta, "after_return": state["returned"]}))
	var key := ic.request("campaign_argon", "test campaign prompt one", "1536x640", 1, Vector3(1, 0, 1))
	state["returned"] = true
	check(got.is_empty(), "image_ready is not emitted inside request()")
	var live := func() -> bool: return got.any(func(g: Dictionary) -> bool: return str(g["meta"].get("source", "")) == "live")
	var ok: bool = await _pump(ic, live)
	check(ok, "live flow (submit, 429, processing, success, download) delivers image_ready")
	check(got.all(func(g: Dictionary) -> bool: return g["after_return"]), "every image_ready arrives after request() returned")
	var lv: Array = got.filter(func(g: Dictionary) -> bool: return str(g["meta"].get("source", "")) == "live")
	if not lv.is_empty():
		var tex: Texture2D = lv[0]["tex"]
		check(str(lv[0]["key"]) == key, "live image_ready carries the request key")
		check(maxi(tex.get_width(), tex.get_height()) <= 1024, "live texture long edge <= 1024 (%dx%d)" % [tex.get_width(), tex.get_height()])
		var img := tex.get_image()
		check(img != null and img.has_mipmaps(), "live texture has mipmaps")
	check(FileAccess.file_exists("user://posters/%s.webp" % key), "user://posters/<key>.webp exists")
	var dl: Array = fake.calls.filter(func(cl: Dictionary) -> bool: return str(cl["url"]) == MEDIA_URL)
	check(dl.size() == 1, "one download call")
	if not dl.is_empty():
		var auth := false
		for hd: String in (dl[0]["headers"] as PackedStringArray):
			if hd.to_lower().begins_with("authorization"):
				auth = true
		check(not auth, "the download carries no Authorization header")
	var posts := fake.posts()
	check(posts.size() == 1 and (posts[0]["headers"] as PackedStringArray).has("Authorization: Bearer " + FAKE_KEY), "submit carries the bearer header")
	var polls: Array = fake.calls.filter(func(cl: Dictionary) -> bool: return str(cl["url"]).ends_with("/abc"))
	check(polls.size() == 3, "three polls (429, processing, success): %d" % polls.size())
	var idx := FileAccess.get_file_as_string("user://posters/index.json")
	check(idx.contains(key), "index.json records the key")
	for s: String in [JSON.stringify(ic.stats), idx, ic.last_error]:
		check(not s.contains(FAKE_KEY), "no recorded string contains the API key")
	check(int(ic.stats["live_ok"]) == 1 and int(ic.stats["live_submits"]) == 1, "stats count one live submit and success")
	# Cache: the same prompt again makes no transport call and is still deferred.
	var n_calls := fake.calls.size()
	var hits := int(ic.stats["cache_hits"])
	got.clear()
	state["returned"] = false
	ic.request("campaign_argon", "test campaign prompt one", "1536x640")
	state["returned"] = true
	check(got.is_empty(), "a cache hit is still deferred")
	await _pump(ic, func() -> bool: return not got.is_empty(), 500)
	check(fake.calls.size() == n_calls, "the same prompt again makes 0 transport calls")
	check(int(ic.stats["cache_hits"]) == hits + 1, "stats.cache_hits increments")
	check(not got.is_empty() and got[0]["after_return"], "cache hit image_ready fires after request() returned")
	ic.queue_free()
	c.queue_free()


func _test_default_transport_offline() -> void:
	var c := _gmi_client(true)
	var ic := _image_client(c, null)
	var got: Array = []
	ic.image_ready.connect(func(_k: String, _t: Texture2D, m: Dictionary) -> void: got.append(m))
	ic.request("gazette", "offline guard prompt", "768x1152")
	await _pump(ic, func() -> bool: return not got.is_empty(), 500)
	check(ic.http_requests == 0 and ic.transport_calls == 0, "default transport under GRIDFALL_OFFLINE=1 makes 0 network requests")
	check(not got.is_empty() and not got[0].get("provisional", true), "the offline request still gets a final texture")
	ic.queue_free()
	c.queue_free()


func _test_breaker() -> void:
	var c := _gmi_client(true)
	var fake := FakeTransport.new()
	fake.default_reply = func(_m: String, _u: String, _b: String) -> Dictionary: return {"code": 500, "body": "boom".to_utf8_buffer()}
	var ic := _image_client(c, fake)
	var failed: Array[String] = []
	ic.image_failed.connect(func(k: String, _r: String) -> void: failed.append(k))
	for k in range(3):
		ic.request("campaign_kimi", "breaker prompt %d" % k, "1536x640")
	await _pump(ic, func() -> bool: return failed.size() >= 3)
	check(failed.size() == 3, "three failures reported")
	check(ic.breaker_open(), "the breaker opens after 3 consecutive failures")
	var n_calls := fake.calls.size()
	var got: Array[Dictionary] = []
	ic.image_ready.connect(func(_k: String, _t: Texture2D, m: Dictionary) -> void: got.append(m))
	ic.request("campaign_kimi", "breaker prompt after", "1536x640")
	await _pump(ic, func() -> bool: return not got.is_empty(), 500)
	check(fake.calls.size() == n_calls, "an open breaker makes 0 transport calls")
	check(not got.is_empty() and str(got[-1].get("source", "")) in ["prebaked", "procedural"] and not got[-1].get("provisional", true), "an open breaker falls back")
	_day += 1
	check(not ic.breaker_open(), "a later game day closes the breaker")
	fake.default_reply = _ok_reply
	ic.request("campaign_kimi", "breaker prompt next day", "1536x640")
	await _pump(ic, func() -> bool: return fake.calls.size() > n_calls, 500)
	check(fake.calls.size() > n_calls, "after the reset the live path submits again")
	await _pump(ic, func() -> bool: return ic.in_flight() == 0, 1500)
	ic.queue_free()
	c.queue_free()


func _test_budgets() -> void:
	var c := _gmi_client(true)
	var fake := FakeTransport.new()
	fake.default_reply = _ok_reply
	var ic := _image_client(c, fake)
	var finals: Dictionary = {}
	ic.image_ready.connect(func(k: String, _t: Texture2D, m: Dictionary) -> void:
		if not m.get("provisional", false):
			finals[k] = m)
	var keys: Array[String] = []
	for k in range(7):
		keys.append(ic.request("gazette", "budget prompt day one %d" % k, "768x1152", 0))
	await _pump(ic, func() -> bool: return finals.size() >= 7)
	check(fake.posts().size() == 6, "at most 6 live submits per game day (%d)" % fake.posts().size())
	check(finals.has(keys[6]) and str(finals[keys[6]].get("source", "")) in ["prebaked", "procedural"], "the 7th request of the day is served from the pre-baked set or the procedural fallback")
	check(ic.peak_in_flight <= GmiImageClient.MAX_IN_FLIGHT, "never more than 2 jobs in flight (peak %d)" % ic.peak_in_flight)
	check(ic.budget_left_today() == 0, "budget_left_today() is 0 after 6")
	for d in range(4):
		_day += 1
		finals.clear()
		for k in range(6):
			ic.request("gazette", "budget prompt day %d n %d" % [d, k], "768x1152")
		await _pump(ic, func() -> bool: return finals.size() >= 6)
	check(ic.live_session == 30, "30 live submits over five days (%d)" % ic.live_session)
	_day += 1
	var before := fake.posts().size()
	finals.clear()
	var last := ic.request("gazette", "budget prompt past the session cap", "768x1152")
	await _pump(ic, func() -> bool: return finals.has(last), 800)
	check(fake.posts().size() == before, "after 30 per session no more live submits")
	check(finals.has(last) and str(finals[last].get("source", "")) != "live", "past the session cap the request falls back")
	ic.queue_free()
	c.queue_free()


func _test_queue_order() -> void:
	var c := _gmi_client(true)
	var fake := FakeTransport.new()
	fake.default_reply = _ok_reply
	var ic := _image_client(c, fake)
	ic.player_pos = func() -> Vector3: return Vector3.ZERO
	ic.submit_spacing_s = 0.2
	ic.request("ad_cafe", "queue order far prompt", "1536x640", 0, Vector3(20, 0, 0))
	ic.request("ad_cafe", "queue order near prompt", "1536x640", 0, Vector3(2, 0, 0))
	ic.request("ad_cafe", "queue order no position prompt", "1536x640", 0, Vector3.INF)
	await _pump(ic, func() -> bool: return fake.posts().size() >= 3)
	var order: Array = fake.posts().map(func(p: Dictionary) -> String: return str(p["body"]))
	check(order.size() == 3 and str(order[0]).contains("near") and str(order[1]).contains("far") and str(order[2]).contains("no position"), "equal priority submits nearest pos first, INF last")
	check(ic.peak_in_flight <= GmiImageClient.MAX_IN_FLIGHT, "queue run keeps <= 2 in flight")
	await _pump(ic, func() -> bool: return ic.in_flight() == 0, 1500)
	ic.queue_free()
	c.queue_free()


func _test_offline_determinism() -> void:
	var runs: Array = []
	for run in range(2):
		var c := _gmi_client(false)
		var fake := FakeTransport.new()
		var ic := _image_client(c, fake)
		var picks: Dictionary = {}
		ic.image_ready.connect(func(k: String, _t: Texture2D, m: Dictionary) -> void: picks[k] = "%s:%s" % [m.get("source", ""), m.get("file", "")])
		var kinds := ["campaign_argon", "campaign_grok", "ad_cafe", "ad_bank", "gazette_crews", "hoarding_tower", "notice_power", "placard"]
		for k: String in kinds:
			ic.request(k, "determinism prompt for " + k, "1536x640")
		await _pump(ic, func() -> bool: return picks.size() >= kinds.size())
		check(fake.calls.is_empty(), "offline run %d makes 0 transport calls" % run)
		runs.append(picks)
		ic.queue_free()
		c.queue_free()
	check(runs[0] == runs[1] and (runs[0] as Dictionary).size() == 8, "the same requests pick the same pre-baked files across two runs")
	var picks0: Dictionary = runs[0]
	var cafe := str(picks0.get(GmiImageClient.key_for("determinism prompt for ad_cafe", "1536x640"), ""))
	var crews := str(picks0.get(GmiImageClient.key_for("determinism prompt for gazette_crews", "1536x640"), ""))
	check(cafe == "prebaked:ad_cafe.webp" and crews == "prebaked:gazette_crews.webp", "kind pools resolve to their pre-baked files (%s, %s)" % [cafe, crews])
	var lib := GmiImageClient.new()
	check(lib.pool_files("hoarding_unknown").size() == 3 and lib.pool_files("placard").size() == 1, "an unknown pool falls back to its family")
	lib.free()
