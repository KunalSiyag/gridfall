extends SceneTree
## The game's two VRAM-compression guards (the S3TC compress sites). Image.compress(COMPRESS_S3TC)
## must only run where a real RenderingDevice exists: on Compatibility GL and headless there is
## none, and the first S3TC compress spins Betsy up on the worker thread behind a half-initialised
## RenderingDevice singleton that the main thread's viewport configure then dereferences (engine
## bug, GL SIGSEGV). Headless (the gate) asserts the fallback path: no compress attempt, the image
## lands RGB8 with mipmaps, and the submit counting is untouched. Where a device exists (a windowed
## Forward+ run) the compressed form is the expected outcome. Covers both sites: the image client's
## processed images (gmi_image_client.gd) and the posters composites (poster_worker.gd, whose
## compress flag its caller decides on the main thread). Offline; a stub transport stands in for
## the network. Also covers the download's threaded mode (HTTPRequest.use_threads), which must stay
## off on the web export. Prints AI_IMAGE_CLIENT_TEST: PASS|FAIL.

const KIT := preload("res://tools/tests/fp_kit.gd")
const POSTER_WORKER := preload("res://scripts/fp/posters/poster_worker.gd")
const WebSupport := preload("res://scripts/ops/web_support.gd")
const FAKE_KEY := "TESTKEY123"
const MEDIA_URL := "https://storage.googleapis.com/gmi-test/out.png"

var fails: Array = []
var _ms: float = 0.0
var _day: int = 1
var _carrier: GmiClient


## Stub transport: one reply for every call; every call is recorded in `seen`.
class Stub:
	extends RefCounted
	var seen: Array[Dictionary] = []
	var reply: Callable

	func send(
		method: String, url: String, _h: PackedStringArray, _b: String, _t: String
	) -> Dictionary:
		seen.append({"method": method, "url": url})
		if reply.is_valid():
			return reply.call(method, url)
		return {"code": 500, "body": PackedByteArray()}


func _init() -> void:
	await process_frame
	if DirAccess.dir_exists_absolute("user://posters"):
		for f: String in DirAccess.get_files_at("user://posters"):
			DirAccess.remove_absolute("user://posters/" + f)
	await _test_compress_guard()
	_test_composite_guard()
	_test_http_threads_guard()
	_finish()


func check(ok: bool, what: String) -> void:
	KIT.check(fails, ok, what)


func _finish() -> void:
	var webp := 0
	if DirAccess.dir_exists_absolute("user://posters"):
		for f: String in DirAccess.get_files_at("user://posters"):
			if f.ends_with(".webp"):
				webp += 1
	check(webp == 1, "one processed image cached to user://posters (%d)" % webp)
	KIT.finish(self, "AI_IMAGE_CLIENT_TEST", fails)


## A stub reply that completes every job: submit and poll succeed with a media url, the media
## download is a small PNG.
static func _reply(method: String, url: String) -> Dictionary:
	if url == MEDIA_URL and method != "POST":
		var img := Image.create(48, 20, false, Image.FORMAT_RGB8)
		img.fill(Color(0.2, 0.5, 0.8))
		return {"code": 200, "body": img.save_png_to_buffer()}
	var ok := {"status": "success", "outcome": {"media_urls": [{"url": MEDIA_URL}]}}
	return {"code": 200, "body": JSON.stringify(ok).to_utf8_buffer()}


## A live image client on the stub transport, with virtual time and no submit spacing.
func _client(stub: Stub) -> GmiImageClient:
	var c: GmiClient = (load("res://scripts/ai/gmi_client.gd") as GDScript).new()
	root.add_child(c)
	c.api_key = FAKE_KEY
	c.live_enabled = true
	_carrier = c
	var ic := GmiImageClient.new()
	root.add_child(ic)
	ic.setup(c, func() -> int: return _day)
	ic.clock = func() -> float: return _ms
	ic.transport = stub.send
	ic.allow_live_with_injected_transport = true
	ic.poll_s = 0.05
	ic.submit_spacing_s = 0.0
	ic.backoff_s = [0.1, 0.4]
	ic.deadline_s = 30.0
	return ic


## Advances virtual time in 40 ms steps, ticking and yielding frames, until until() or a wall cap.
func _spin(ic: GmiImageClient, until: Callable, cap_ms: int = 3000) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < cap_ms:
		_ms += 40.0
		ic.tick(0.04)
		await process_frame
		if until.call():
			return true
	return false


## One live job end to end on the stub transport; the landed image's format is what the guard
## decided. Without a RenderingDevice the guard must be off (no S3TC attempt, RGB8 + mipmaps);
## with one, the image is expected to leave RGB8 behind.
func _test_compress_guard() -> void:
	var vram: bool = GmiImageClient.wants_vram_compress()
	if not vram:
		check(
			RenderingServer.get_rendering_device() == null,
			"no RenderingDevice, so wants_vram_compress() is false (the GL crash guard)"
		)
	var stub := Stub.new()
	stub.reply = _reply
	var ic := _client(stub)
	var got: Array = []
	ic.image_ready.connect(
		func(_k: String, t: Texture2D, m: Dictionary) -> void: got.append({"tex": t, "meta": m})
	)
	ic.request("campaign_argon", "compress guard prompt", "1536x640", 1, Vector3(2, 0, 2))
	check(got.is_empty(), "nothing lands inside request()")
	var live := func() -> bool:
		return got.any(
			func(g: Dictionary) -> bool: return str(g["meta"].get("source", "")) == "live"
		)
	var ok: bool = await _spin(ic, live)
	check(ok, "the guard run still delivers a live image_ready")
	var lv: Array = got.filter(
		func(g: Dictionary) -> bool: return str(g["meta"].get("source", "")) == "live"
	)
	if not lv.is_empty():
		check(
			int(ic.stats["live_ok"]) == 1, "the guard changes no submit counting (one live success)"
		)
		var posts := (
			stub.seen.filter(func(c: Dictionary) -> bool: return str(c["method"]) == "POST").size()
		)
		check(posts == 1, "one transport POST was counted")
		var img: Image = (lv[0]["tex"] as Texture2D).get_image()
		if vram:
			check(
				img != null and img.get_format() != Image.FORMAT_RGB8,
				"a RenderingDevice compresses the image away from RGB8"
			)
		else:
			check(
				img != null and img.get_format() == Image.FORMAT_RGB8,
				"no RenderingDevice: the image stays RGB8 (no S3TC compress attempt)"
			)
			check(
				img != null and img.has_mipmaps(),
				"no RenderingDevice: the image still carries mipmaps"
			)
	ic.queue_free()
	_carrier.queue_free()


## The second compress site: PosterWorker.finish_image (the composites), which runs on the posters
## worker thread. Its input carries the compress flag the caller decided on the main thread; a
## missing flag must never compress (that is the crash path on GL).
func _test_composite_guard() -> void:
	var vram: bool = GmiImageClient.wants_vram_compress()
	var img := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.4, 0.4, 0.4, 1.0))
	var input := {"id": "guard", "image": img, "compress": GmiImageClient.wants_vram_compress()}
	POSTER_WORKER.finish_image(input)
	var out: Image = input["image"]
	check(bool(input.get("ok", false)), "finish_image completes the composite")
	if vram:
		check(
			out != null and out.get_format() != Image.FORMAT_RGB8,
			"a RenderingDevice compresses the composite away from RGB8"
		)
	else:
		check(
			out != null and out.get_format() == Image.FORMAT_RGB8,
			"no RenderingDevice: the composite stays RGB8 (no S3TC compress attempt)"
		)
		check(
			out != null and out.has_mipmaps(),
			"no RenderingDevice: the composite still carries mipmaps"
		)
	# A caller that forgot the flag: the default never compresses, on any device.
	var img2 := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	img2.fill(Color(0.6, 0.6, 0.6, 1.0))
	var input2 := {"id": "no-flag", "image": img2}
	POSTER_WORKER.finish_image(input2)
	var out2: Image = input2["image"]
	check(
		bool(input2.get("ok", false)) and out2 != null and out2.get_format() == Image.FORMAT_RGB8,
		"a composite whose caller passed no compress flag never compresses (RGB8 on any device)"
	)


## The download's threaded mode. HTTPRequest.use_threads is documented as unavailable on the web
## (it freezes the browser), so it must stay off there even on a threaded web build; the pure form
## the live call uses lets a headless run exercise the web branch.
func _test_http_threads_guard() -> void:
	check(
		not GmiImageClient.http_threads_for(true, true),
		"a threaded web build never sets HTTPRequest.use_threads (browser freeze)"
	)
	check(
		not GmiImageClient.http_threads_for(false, false),
		"a build without threads never sets HTTPRequest.use_threads"
	)
	check(
		GmiImageClient.http_threads_for(true, false),
		"desktop with threads keeps the threaded streaming download"
	)
	var live: bool = WebSupport.threads_supported() and not WebSupport.is_web()
	check(
		GmiImageClient.wants_http_threads() == live,
		"wants_http_threads() matches the live feature detect"
	)
