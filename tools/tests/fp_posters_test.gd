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
	if DirAccess.dir_exists_absolute("user://posters"):
		for f in DirAccess.get_files_at("user://posters"):
			DirAccess.remove_absolute("user://posters/" + f)
	await _test_client()
	await _test_feature()
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
	check(fake.posts().size() == 6, "at most 6 live submits per game day (%d) %s %s" % [fake.posts().size(), str(ic.stats), ic.last_error])
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


# ------------------------------------------------------------------ the feature on a grown city

const REAL_BILLBOARD := "res://models/real/props/billboard.glb"


func _test_feature() -> void:
	print("-- poster feature")
	var t0 := Time.get_ticks_msec()
	var ctx := KIT.make_ctx(root, {"view": true, "grow": true})
	var sim := ctx.sim
	var dir := ctx.directory
	var c_lot := -1
	for i in sim.active:
		if sim.kind[i] == D.ZONE_C and sim.level[i] > 0 and not dir.business_name(i).is_empty():
			c_lot = i
			break
	check(c_lot >= 0, "fixture: a C lot with a business_name")
	check(ctx.view.bus_stops.size() >= 1, "fixture: a view.bus_stops entry")
	if c_lot < 0 or ctx.view.bus_stops.is_empty():
		return
	var f: FpFeature = KIT.make_feature(ctx, "posters")
	check(f != null and f.get("image_client") != null, "posters feature is set up")
	if f == null:
		return
	print("  (city and feature ready in %d ms, %d slots)" % [Time.get_ticks_msec() - t0, (f.get("slots") as Dictionary).size()])
	# A billboard on the first C lot, announced through tile_built.
	var holder := ctx.view.tile_holder(c_lot)
	var bb := (load(REAL_BILLBOARD) as PackedScene).instantiate() as Node3D
	bb.position = Vector3(0.4, 0.0, -0.4)
	bb.rotation.y = PI * 0.5
	holder.add_child(bb)
	ctx.view.tile_built.emit(c_lot, holder)
	var quads := bb.find_children("Poster*", "MeshInstance3D", true, false)
	check(not quads.is_empty() and str(quads[0].get_meta("fp_owner", "")) == "posters", "the test billboard gets a Poster quad tagged fp_owner")
	var slots: Dictionary = f.get("slots")
	var assigned: Dictionary = f.get("assigned")
	var bb_id := ""
	for id: String in slots.keys():
		if int(slots[id]["tile"]) == c_lot and str(slots[id]["carrier"]) == "billboard" and (slots[id]["faces"][0]["mesh"] as Node).get_parent() == bb:
			bb_id = id
	check(not bb_id.is_empty(), "the test billboard is a slot (%s)" % bb_id)
	# More billboards on C lots until one is a campaign slot (an even slot hash), so the district
	# check below never passes on an empty set.
	var extra := 0
	for i in sim.active:
		if _campaign_billboards(ctx, f) > 0 or extra >= 6:
			break
		if sim.kind[i] != D.ZONE_C or sim.level[i] <= 0 or sim.district[i] < 0 or i == c_lot:
			continue
		var h2 := ctx.view.tile_holder(i)
		var b2 := (load(REAL_BILLBOARD) as PackedScene).instantiate() as Node3D
		b2.position = Vector3(-0.4, 0.0, 0.4)
		h2.add_child(b2)
		ctx.view.tile_built.emit(i, h2)
		extra += 1
	check(_campaign_billboards(ctx, f) > 0, "fixture: at least one campaign billboard (%d extra billboards)" % extra)
	await _test_director(ctx, f, c_lot)
	_test_walls(ctx, f)
	await _test_hoarding(ctx, f)
	_test_save(ctx, f)
	_test_pick_and_viewer(ctx, f, bb_id)
	await _test_setup_gate(ctx, f)
	await _test_composites(ctx, f)
	f.teardown()
	var left := 0
	for i in sim.active:
		var h := ctx.view.tile_holder(i)
		if h == null:
			continue
		for n in h.find_children("*", "", true, false):
			if str(n.get_meta("fp_owner", "")) == "posters":
				left += 1
	check(left == 0, "teardown() leaves no fp_owner == posters node under any holder (%d)" % left)
	print("  (feature section %d ms)" % (Time.get_ticks_msec() - t0))


func _campaign_billboards(_ctx: FpContext, f: FpFeature) -> int:
	var n := 0
	var slots: Dictionary = f.get("slots")
	var assigned: Dictionary = f.get("assigned")
	for id: String in assigned.keys():
		if str(slots[id]["carrier"]) == "billboard" and str(assigned[id]["family"]) == "campaign":
			n += 1
	return n


func _test_director(ctx: FpContext, f: FpFeature, c_lot: int) -> void:
	var sim := ctx.sim
	var slots: Dictionary = f.get("slots")
	var assigned: Dictionary = f.get("assigned")
	var mayors := {}
	for id: String in slots.keys():
		if str(slots[id]["carrier"]) == "billboard":
			var d := sim.district[int(slots[id]["tile"])]
			if d >= 0:
				mayors[d] = true
	check(not mayors.is_empty(), "fixture: billboards in at least one mayor's district")
	for mi: int in mayors.keys():
		f.on_mayor_decided(mi, {"post": "Grok-4.5 thinks DeepSeek-V4 is wrong: we will build a brighter, greener city for every family here", "mood": "determined"})
	var camp := 0
	var wrong := 0
	var branded := 0
	for id: String in assigned.keys():
		var a: Dictionary = assigned[id]
		if str(a["family"]) != "campaign" or str(slots[id]["carrier"]) != "billboard":
			continue
		camp += 1
		if int(a["overlay"]["mayor"]) != sim.district[int(slots[id]["tile"])]:
			wrong += 1
		var txt := JSON.stringify(a["overlay"])
		for w in ["Grok", "DeepSeek", "Argon", "Kimi", "Qwen"]:
			if txt.contains(w):
				branded += 1
	check(camp > 0 and wrong == 0, "every campaign billboard (%d) sits in its mayor's district" % camp)
	check(branded == 0, "campaign overlays are de-branded")
	var mi0: int = mayors.keys()[0]
	var slogan := str(f.get("director").campaigns[mi0]["overlay"]["slogan"])
	check(slogan.length() <= 61 and slogan.begins_with("Duke Granger thinks Viktor Han"), "the slogan is the de-branded post, at most 60 characters: " + slogan)
	f.on_news({"headline": "Kimi-K3 opens the new river bridge to cheers", "day": sim.day, "stories": [{"title": "Traffic eases on Maple Street", "body": "..."}]})
	var shelters := 0
	var gz := 0
	for id: String in slots.keys():
		if str(slots[id]["carrier"]) != "shelter":
			continue
		shelters += 1
		var a: Dictionary = assigned.get(id, {})
		if str(a.get("family", "")) == "gazette" and str(a["overlay"]["headline"]) == "Mei Kimura opens the new river bridge to cheers":
			gz += 1
	check(shelters > 0 and gz == shelters, "shelters show the de-branded Gazette (%d of %d)" % [gz, shelters])
	# Ads: the tile's business name and the AD_POOL pool.
	var ads := 0
	var bad_ads: Array[String] = []
	var DIR := load("res://scripts/fp/posters/poster_director.gd")
	for id: String in assigned.keys():
		var a: Dictionary = assigned[id]
		var i := int(slots[id]["tile"])
		if str(a["family"]) != "ad" or sim.kind[i] != D.ZONE_C or ctx.directory.business_name(i).is_empty():
			continue
		ads += 1
		var want_pool := str(DIR.AD_POOL.get(ctx.directory.business_kind(i), "ad_default"))
		if str(a["overlay"]["name"]) != ctx.directory.business_name(i) or str(a["kind"]) != want_pool:
			bad_ads.append("%s %s/%s" % [id, a["overlay"]["name"], a["kind"]])
	check(ads > 0 and bad_ads.is_empty(), "ads (%d) name their tile's business and follow AD_POOL %s" % [ads, str(bad_ads)])
	var unmapped := -1
	for i in sim.active:
		if sim.kind[i] == D.ZONE_I and sim.level[i] > 0 and not DIR.AD_POOL.has(ctx.directory.business_kind(i)):
			unmapped = i
			break
	if unmapped >= 0:
		check(str(f.get("director").ad_for(unmapped)["kind"]) == "ad_default", "an unmapped business kind gets ad_default")
	else:
		check(str(f.get("director").ad_for(-1)["kind"]) == "ad_default", "no business gets ad_default")
	# Textures arrive (pre-baked, offline) and the quads show them.
	var ready := func() -> bool:
		for id: String in assigned.keys():
			var mi: MeshInstance3D = slots[id]["faces"][0]["mesh"]
			if is_instance_valid(mi) and mi.material_override == null:
				return false
		return true
	var ic: GmiImageClient = f.get("image_client")
	var t0 := Time.get_ticks_msec()
	while not ready.call() and Time.get_ticks_msec() - t0 < 3000:
		await process_frame
	check(ready.call(), "every assigned poster face has a material within 3 s")
	check(ic.transport_calls == 0 and ic.http_requests == 0, "offline: the feature made 0 transport calls")
	check(int(ic.stats["prebaked"]) > 0, "offline art comes from the pre-baked set (%s)" % str(ic.stats))


func _test_walls(ctx: FpContext, f: FpFeature) -> void:
	var sim := ctx.sim
	var surf: RefCounted = f.get("surfaces")
	# Every zone lot that can carry a wall poster (ignoring the 1-in-3 pick), plus the feature's own.
	var checked := 0
	var bad: Array[String] = []
	var tmp: Array[Dictionary] = []
	for i in sim.active:
		var k := sim.kind[i]
		if not (k == D.ZONE_R or k == D.ZONE_C or k == D.ZONE_I) or sim.level[i] <= 0:
			continue
		var h := ctx.view.tile_holder(i)
		if h == null:
			continue
		var s: Dictionary = surf.call("_wall_slot", i, h)
		if not s.is_empty():
			tmp.append(s)
	var slots: Dictionary = f.get("slots")
	for s: Dictionary in tmp + slots.values().filter(func(x: Dictionary) -> bool: return str(x["carrier"]) == "wall"):
		checked += 1
		var i := int(s["tile"])
		var sp: Dictionary = s["spot"]
		var n: Vector3 = sp["normal"]
		var pos: Vector3 = s["pos"]
		var off := (pos - (sp["plane_point"] as Vector3)).dot(n)
		var ab := ctx.view.building_aabb(i)
		var ab_face := (ab.get_center() + n * (absf(n.x) * ab.size.x + absf(n.z) * ab.size.z) * 0.5)
		var to_ab := (ab_face - pos).dot(n)
		var face: Dictionary = s["faces"][0]
		var inside := true
		for sx: float in [-1.0, 1.0]:
			for sy: float in [-1.0, 1.0]:
				var c: Vector3 = face["center"] + (face["right"] as Vector3) * (face["half"] as Vector2).x * sx + (face["up"] as Vector3) * (face["half"] as Vector2).y * sy
				if absf(c.x - D.tx(i)) > 0.5 or absf(c.z - D.ty(i)) > 0.5 or c.y < 0.0:
					inside = false
		if off < 0.0 or off > 0.005 or to_ab < 0.005 or not inside:
			bad.append("%s off=%.4f to_aabb=%.4f inside=%s" % [s["id"], off, to_ab, inside])
	for s: Dictionary in tmp:
		for nd: Variant in s["nodes"]:
			if is_instance_valid(nd):
				(nd as Node).free()
	check(checked > 0, "fixture: at least one wall poster to check (%d)" % checked)
	check(bad.is_empty(), "every wall poster lies within 0.005 of its wall face, never on the building_aabb face, inside the tile %s" % str(bad))


func _test_hoarding(ctx: FpContext, f: FpFeature) -> void:
	var sim := ctx.sim
	var dirr: RefCounted = f.get("director")
	# Director: a zone site's "Coming soon" uses planned_name.
	var c_lot := -1
	for i in sim.active:
		if sim.kind[i] == D.ZONE_C and sim.level[i] == 0 and ctx.directory.frontage(i) >= 0:
			c_lot = i
			break
	if c_lot < 0:
		for i in sim.active:
			if sim.kind[i] == D.ZONE_C and ctx.directory.frontage(i) >= 0:
				c_lot = i
				break
	var had: Dictionary = sim.sites.get(c_lot, {})
	sim.sites[c_lot] = {"type": "zone", "plan": "zone_new", "target_kind": D.ZONE_C, "target_level": 1, "owner": 1, "label": "Shops"}
	var hz: Dictionary = dirr.hoarding(c_lot)
	var want := ctx.directory.planned_name(c_lot, D.ZONE_C, 1)
	check(not want.is_empty() and not hz.is_empty() and str(hz["overlay"]["name"]) == want, "a C site's hoarding uses planned_name (%s)" % want)
	check(not hz.is_empty() and str(hz["overlay"]["builder"]) == "Built by Viktor Han's contractors", "the hoarding credits the mayor's contractors")
	if had.is_empty():
		sim.sites.erase(c_lot)
	else:
		sim.sites[c_lot] = had
	# A staged police build: the surfaces put a banner on the frontage fence, the director names it.
	var mode := sim.construction_mode
	sim.construction_mode = "staged"
	sim.mayors[0]["treasury"] = int(sim.mayors[0]["treasury"]) + 20000
	var site := -1
	for lot: Variant in sim.open_lots(0, 20):
		var i := D.idx(int(lot[0]), int(lot[1]))
		if ctx.directory.frontage(i) >= 0:
			var r: Dictionary = sim.apply_action(0, {"type": "build", "building": "police", "x": int(lot[0]), "y": int(lot[1])})
			if bool(r.get("ok", false)) and sim.sites.has(i):
				site = i
				break
	sim.construction_mode = mode
	check(site >= 0, "fixture: a staged police site with a frontage")
	if site < 0:
		return
	var slots: Dictionary = f.get("slots")
	var assigned: Dictionary = f.get("assigned")
	var t0 := Time.get_ticks_msec()
	while not slots.has("%d:hoarding:0" % site) and Time.get_ticks_msec() - t0 < 2000:
		await process_frame
	var id := "%d:hoarding:0" % site
	check(slots.has(id), "the site's frontage fence carries a hoarding poster")
	if slots.has(id):
		var a: Dictionary = assigned.get(id, {})
		var name := ctx.directory.planned_name(site, D.POLICE, 0)
		check(not a.is_empty() and str(a["overlay"]["name"]) == name and not name.is_empty(), "the police hoarding reads Coming soon: %s" % name)
		var face: Dictionary = slots[id]["faces"][0]
		var dv := ctx.directory.frontage(site)
		var out := Vector3(D.tx(dv) - D.tx(site), 0, D.ty(dv) - D.ty(site))
		var depth := ((face["center"] as Vector3) - Vector3(D.tx(site), 0, D.ty(site))).dot(out)
		check(depth > 0.47 and depth < 0.48, "the hoarding poster sits just outside the fence at 0.47 (%.4f), not a panel at 0.44" % depth)


func _plain(v: Variant) -> Variant:
	if typeof(v) == TYPE_FLOAT and is_equal_approx(float(v), round(float(v))):
		return int(v)
	if typeof(v) == TYPE_DICTIONARY:
		var out := {}
		for k: Variant in (v as Dictionary).keys():
			out[str(k)] = _plain(v[k])
		return out
	return v


func _test_save(ctx: FpContext, f: FpFeature) -> void:
	var assigned: Dictionary = f.get("assigned")
	var before := {}
	for id: String in assigned.keys():
		before[id] = JSON.stringify(_plain({"key": assigned[id]["key"], "kind": assigned[id]["kind"], "overlay": assigned[id]["overlay"]}))
	var d: Variant = JSON.parse_string(JSON.stringify(f.to_dict()))
	check(typeof(d) == TYPE_DICTIONARY and (d as Dictionary).has("slots") and (d as Dictionary).has("campaign_day"), "to_dict has slots and campaign_day")
	# Change the world's state, then restore: every slot keeps its key, kind and overlay text.
	f.on_news({"headline": "A different front page", "day": ctx.sim.day + 1})
	f.from_dict(d)
	var lost: Array[String] = []
	for id: String in before.keys():
		var a: Dictionary = assigned.get(id, {})
		var now := JSON.stringify(_plain({"key": a.get("key", ""), "kind": a.get("kind", ""), "overlay": a.get("overlay", {})}))
		if now != before[id]:
			lost.append(id)
	check(not before.is_empty() and lost.is_empty(), "to_dict -> JSON -> from_dict keeps every slot's key, kind and overlay %s" % str(lost.slice(0, 3)))
	var dd: Dictionary = d
	check(typeof(dd["live_today"]) == TYPE_FLOAT and f.get("image_client").live_today == int(dd["live_today"]), "live counters come back as ints")
	# A fresh city with a paper already printed seeds the Gazette without any signal.
	ctx.brain.last_paper = {"headline": "Qwen-3.8 balances the budget again", "day": ctx.sim.day, "stories": []}
	f.from_dict({})
	var slots: Dictionary = f.get("slots")
	var seeded := 0
	var shel := 0
	for id: String in slots.keys():
		if str(slots[id]["carrier"]) == "shelter":
			shel += 1
			if str(assigned.get(id, {}).get("overlay", {}).get("headline", "")) == "Rosa Quintero balances the budget again":
				seeded += 1
	check(shel > 0 and seeded == shel, "from_dict({}) seeds the Gazette from brain.last_paper (%d of %d)" % [seeded, shel])


func _test_pick_and_viewer(ctx: FpContext, f: FpFeature, bb_id: String) -> void:
	var slots: Dictionary = f.get("slots")
	if not slots.has(bb_id):
		check(false, "pick: the test billboard slot exists")
		return
	var face: Dictionary = slots[bb_id]["faces"][0]
	var c: Vector3 = face["center"]
	var n: Vector3 = face["normal"]
	var t: Dictionary = f.pick(c + n * 0.1 + Vector3(0, -0.02, 0), (-n + Vector3(0, 0.15, 0)).normalized(), WS.INTERACT_RANGE * 2.0)
	check(str(t.get("kind", "")) == "poster" and str(t.get("data", {}).get("slot", "")) == bb_id, "pick() along a ray into the billboard returns kind poster (%s)" % str(t.get("label", "")))
	check(str(t.get("label", "")).begins_with("Look at "), "the pick label reads Look at <title>")
	check(f.pick(c - n * 0.1, n, WS.INTERACT_RANGE * 2.0).is_empty(), "pick() from behind the poster returns nothing")
	check(f.pick(c + n * 0.5, -n, WS.INTERACT_RANGE).is_empty(), "pick() beyond max_dist returns nothing")
	# The viewer: interact_requested opens it, E closes it.
	ctx.bus.interact_requested.emit(t)
	check(f.call("viewer_open") and ctx.has_modal(&"poster") and ctx.hud.slot("overlay").get_child_count() > 0, "interact on a poster opens the full-screen viewer (modal poster)")
	var ev := InputEventAction.new()
	ev.action = "interact"
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	check(not f.call("viewer_open") and not ctx.has_modal(&"poster"), "E closes the viewer and pops its modal")
	var up := InputEventAction.new()
	up.action = "interact"
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	f.call("open_viewer", bb_id)
	ctx.bus.world_ready.emit()
	check(not f.call("viewer_open") and not ctx.has_modal(&"poster"), "world_ready closes the viewer")


func _test_setup_gate(ctx: FpContext, f: FpFeature) -> void:
	var surf: RefCounted = f.get("surfaces")
	var seen: Array[int] = []
	var probe := func(_i: int, _h: Node3D) -> void: seen.append(int(surf.get("scans")))
	var before := int(surf.get("scans"))
	ctx.view.tile_built.connect(probe)
	ctx.view.setup(ctx.sim, ctx.view.camera)
	ctx.view.tile_built.disconnect(probe)
	var during := seen.all(func(v: int) -> bool: return v == before)
	check(not seen.is_empty() and during, "tile_built during view.setup (in_setup) does no per-tile work (%d emissions)" % seen.size())
	f.on_world_rebuilt()
	check(int(surf.get("scans")) > before and not (f.get("slots") as Dictionary).is_empty(), "world_rebuilt's full pass rebuilds the slots (%d)" % (f.get("slots") as Dictionary).size())


func _test_composites(ctx: FpContext, f: FpFeature) -> void:
	var slots: Dictionary = f.get("slots")
	var assigned: Dictionary = f.get("assigned")
	var comps: Dictionary = f.get("composites")
	var base: Dictionary = f.get("base_tex")
	var all_in := func() -> bool: return assigned.values().all(func(a: Dictionary) -> bool: return base.has(str(a["key"])))
	var t0 := Time.get_ticks_msec()
	while not all_in.call() and Time.get_ticks_msec() - t0 < 3000:
		await process_frame
	check(all_in.call(), "every assigned key has its image")
	var any_id: String = assigned.keys()[0]
	var p: Vector3 = slots[any_id]["pos"]
	ctx.player.teleport(Vector3(p.x, 0, p.z), 0.0)
	f.update_composites()
	check(comps.size() > 0 and comps.size() <= 32, "composites exist near the player, at most 32 (%d)" % comps.size())
	var near_has := (f.get("_slot_comp") as Dictionary).has(any_id)
	check(near_has, "the slot at the player has a composite")
	ctx.player.teleport(Vector3(p.x + 1.3 * WS.VIS_PROP, 0, p.z + 1.3 * WS.VIS_PROP), 0.0, 0.0, false)
	f.update_composites()
	check(not (f.get("_slot_comp") as Dictionary).has(any_id), "moving the player beyond 1.25 * VIS_PROP releases its composite")
	var far := Vector3(-79, 0, -79)
	ctx.player.teleport(far, 0.0, 0.0, false)
	f.update_composites()
	check(comps.is_empty(), "far from every poster no composite is kept (%d)" % comps.size())
