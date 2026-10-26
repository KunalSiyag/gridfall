class_name GmiImageClient
extends Node
## Async poster image client for GMI's hy-image-v3.5-preview (slice D). request() returns a cache
## key at once; the texture arrives later through image_ready, always emitted deferred. Lookup
## order: memory LRU, user://posters/<key>.webp, the pre-baked set (exact key), the live queue
## (budgeted, breaker-guarded, never in GRIDFALL_OFFLINE), then the pre-baked pool of the kind and
## a procedural gradient. While a live image is on the way the request also gets a provisional
## texture (meta.provisional). Every wait reads `clock` and advances in tick(), so tests run on
## virtual time. Image processing runs on one background thread (poster_worker.gd). The API key
## never appears in any printed, stored or saved string.

signal image_ready(key: String, tex: Texture2D, meta: Dictionary)
signal image_failed(key: String, reason: String)

const QUEUE_URL := "https://console.gmicloud.ai/api/v1/ie/requestqueue/apikey/requests"
const MODEL := "hy-image-v3.5-preview"
const STYLE_VERSION := "fp1"
const CACHE_DIR := "user://posters/"
const INDEX_PATH := "user://posters/index.json"
const MANIFEST_PATH := "res://assets/posters/manifest.json"
const PREBAKED_DIR := "res://assets/posters/"
const ART := preload("res://scripts/fp/posters/poster_art.gd")
const WORKER := preload("res://scripts/fp/posters/poster_worker.gd")
const WebSupport := preload("res://scripts/ops/web_support.gd")
## Resident textures in the memory cache.
const LRU_SIZE := 32
## D12 budgets.
const DAY_CAP := 6
const SESSION_CAP := 30
const MAX_IN_FLIGHT := 2
const BREAKER_FAILS := 3
## Kept files in user://posters before the oldest are deleted.
const DISK_CAP := 400
const DOWNLOAD_LIMIT := 12 * 1024 * 1024
const POST_TIMEOUT_S := 120.0
const POLL_TIMEOUT_S := 30.0
const DOWNLOAD_TIMEOUT_S := 90.0
## Cache, disk and pre-baked serves handled per tick (each is one small load or a worker start).
const SERVES_PER_TICK := 3

## (method: String, url: String, headers: PackedStringArray, body: String, to_file: String)
## -> {"code": int, "body": PackedByteArray}. May be a coroutine. Default: one HTTPRequest per call.
var transport: Callable
## Test hook: honour the live path under GRIDFALL_OFFLINE=1, but only while `transport` is not the
## default HTTPRequest transport (an injected fake). The env check stays for the default transport.
var allow_live_with_injected_transport: bool = false
## Virtual clock in milliseconds; default Time.get_ticks_msec. Every wait below reads it.
var clock: Callable
## () -> Vector3: the player's feet, which orders the live queue (ctx.player_position).
var player_pos: Callable
var poll_s: float = 3.0
var submit_spacing_s: float = 6.0
var backoff_s: Array = [5.0, 30.0]     # first and maximum 429 back-off
var deadline_s: float = 180.0
var stats: Dictionary = {"live_submits": 0, "live_ok": 0, "live_fail": 0, "cache_hits": 0, "prebaked": 0, "procedural": 0}
## The last failure, at most 140 characters of the server's body, scrubbed of the key.
var last_error: String = ""
var live_today: int = 0
var live_session: int = 0
## Transport calls made (tests), and real HTTPRequests the default transport started.
var transport_calls: int = 0
var http_requests: int = 0
## Highest number of live jobs in flight at once (tests).
var peak_in_flight: int = 0

var _client: GmiClient
var _day_fn: Callable
var _default_transport: Callable
var _lru: Dictionary = {}
var _lru_order: Array[String] = []
var _serves: Array[Dictionary] = []
var _queue: Array[Dictionary] = []
var _active: Array[Dictionary] = []
var _worker := WORKER.new()
var _manifest_loaded: bool = false
var _by_key: Dictionary = {}
var _pools: Dictionary = {}
var _families: Dictionary = {}
var _entries: Dictionary = {}
var _prebaked_tex: Dictionary = {}
var _index: Dictionary = {}
var _fails: int = 0
var _breaker_day: int = -1
var _last_submit_ms: float = -1.0e12
var _budget_day: int = -1000000
var _closed: bool = false
static var _norm_re: RegEx


func _init() -> void:
	_default_transport = _http_transport
	transport = _default_transport
	clock = func() -> float: return float(Time.get_ticks_msec())
	player_pos = func() -> Vector3: return Vector3.ZERO


## client supplies api_key and live_enabled (read only); day_fn returns the current game day
## (sim.day), which drives the per-day cap and the breaker reset.
func setup(client: GmiClient, day_fn: Callable) -> void:
	_client = client
	_day_fn = day_fn
	_closed = false
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	if FileAccess.file_exists(INDEX_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(INDEX_PATH))
		if typeof(parsed) == TYPE_DICTIONARY:
			_index = parsed
	_budget_day = _day()


func _process(delta: float) -> void:
	tick(delta)


func _exit_tree() -> void:
	close()


## Stops every job (pending results are dropped) and joins the processing thread.
func close() -> void:
	_closed = true
	_worker.stop()
	_queue.clear()
	_active.clear()
	_serves.clear()


## Cache key of a prompt: sha256(MODEL|size|STYLE_VERSION|normalized prompt), 32 hex characters.
## Normalized: trimmed, lower case, runs of whitespace collapsed to one space.
static func key_for(prompt: String, size: String) -> String:
	if _norm_re == null:
		_norm_re = RegEx.create_from_string("\\s+")
	var norm := _norm_re.sub(prompt.strip_edges().to_lower(), " ", true)
	return ("%s|%s|%s|%s" % [MODEL, size, STYLE_VERSION, norm]).sha256_text().left(32)


## Returns the cache key immediately. The texture arrives through image_ready, which (like
## image_failed) is ALWAYS emitted with call_deferred, never inside request(). pos (world) orders
## the live queue by distance to the player; Vector3.INF means "no position". An empty prompt never
## goes live (a key restored from a save whose prompt is unknown).
func request(kind: String, prompt: String, size: String = "1536x640", priority: int = 0, pos: Vector3 = Vector3.INF) -> String:
	var key := key_for(prompt, size)
	var meta := {"kind": kind, "size": size}
	var t: Texture2D = _lru_get(key)
	if t != null:
		stats["cache_hits"] = int(stats["cache_hits"]) + 1
		meta["source"] = "memory"
		_emit_ready(key, t, meta)
		return key
	_serves.append({"key": key, "kind": kind, "prompt": prompt, "size": size, "priority": priority, "pos": pos, "meta": meta})
	return key


## Like request(), for a key whose prompt is unknown: cache, disk, pre-baked or fallback, never live.
func request_key(key: String, kind: String, size: String) -> String:
	var meta := {"kind": kind, "size": size}
	var t: Texture2D = _lru_get(key)
	if t != null:
		stats["cache_hits"] = int(stats["cache_hits"]) + 1
		meta["source"] = "memory"
		_emit_ready(key, t, meta)
		return key
	_serves.append({"key": key, "kind": kind, "prompt": "", "size": size, "priority": 0, "pos": Vector3.INF, "meta": meta})
	return key


## Memory LRU or the user:// file (decoded on this thread), else null.
func get_cached(key: String) -> Texture2D:
	var t: Texture2D = _lru_get(key)
	if t != null:
		return t
	var path := _disk_path(key)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	img.generate_mipmaps()
	t = ImageTexture.create_from_image(img)
	_lru_put(key, t)
	return t


## Live images still allowed today (also bounded by the session cap and what is queued).
func budget_left_today() -> int:
	_roll_day()
	return maxi(0, mini(DAY_CAP - live_today, SESSION_CAP - live_session) - _queue.size())


## Live jobs submitted and not finished.
func in_flight() -> int:
	return _active.size()


## Live jobs waiting for a submit slot.
func queued() -> int:
	return _queue.size()


## True while the failure breaker blocks the live path.
func breaker_open() -> bool:
	_roll_day()
	return _fails >= BREAKER_FAILS


## A pre-baked or procedural texture for kind, picked deterministically by key (never live, never
## null). meta gets "source" and, for a pre-baked pick, "file".
func fallback_texture(kind: String, key: String, meta: Dictionary = {}) -> Texture2D:
	_load_manifest()
	var files := _pool_files(kind)
	if not files.is_empty():
		var f: String = files[absi(key.hash()) % files.size()]
		var t := _prebaked(f)
		if t != null:
			meta["source"] = "prebaked"
			meta["file"] = f
			return t
	meta["source"] = "procedural"
	return ART.procedural(kind, key)


## The pre-baked files that serve kind (its pool, else its family), sorted.
func pool_files(kind: String) -> Array:
	_load_manifest()
	return _pool_files(kind).duplicate()


## Advances polling, back-off and submit spacing; _process calls tick(delta), tests call it directly.
func tick(_dt: float) -> void:
	if _closed:
		return
	_roll_day()
	_drain_workers()
	var n := 0
	while not _serves.is_empty() and n < SERVES_PER_TICK:
		_serve(_serves.pop_front())
		n += 1
	if _active.is_empty() and _queue.is_empty():
		return
	var now := _now()
	for job: Dictionary in _active.duplicate():
		if str(job["state"]) != "poll_wait":
			continue
		if now - float(job["t_submit"]) >= deadline_s * 1000.0:
			_fail(job, "timeout after %d s" % int(deadline_s))
		elif now >= float(job["due"]):
			_poll(job)
	if _breaker_open_now() or not _live_allowed():
		for job: Dictionary in _queue:
			_emit_fallback(job, false)
		_queue.clear()
		return
	while not _queue.is_empty() and _active.size() < MAX_IN_FLIGHT and now - _last_submit_ms >= submit_spacing_s * 1000.0:
		if live_today >= DAY_CAP or live_session >= SESSION_CAP:
			for job: Dictionary in _queue:
				_emit_fallback(job, false)
			_queue.clear()
			break
		_sort_queue()
		var job: Dictionary = _queue.pop_front()
		if float(job.get("not_before", 0.0)) > now:
			_queue.push_front(job)
			break
		_submit(job)


# ------------------------------------------------------------------ serving

func _serve(s: Dictionary) -> void:
	var key := str(s["key"])
	var meta: Dictionary = s["meta"]
	var t: Texture2D = _lru_get(key)
	if t != null:
		stats["cache_hits"] = int(stats["cache_hits"]) + 1
		meta["source"] = "memory"
		_emit_ready(key, t, meta)
		return
	if FileAccess.file_exists(_disk_path(key)):
		_start_worker({"mode": "disk", "key": key, "path": _disk_path(key), "meta": meta})
		return
	_load_manifest()
	if _by_key.has(key):
		t = _prebaked(str(_by_key[key]))
		if t != null:
			stats["prebaked"] = int(stats["prebaked"]) + 1
			meta["source"] = "prebaked"
			meta["file"] = _by_key[key]
			_emit_ready(key, t, meta)
			return
	if not str(s["prompt"]).is_empty() and _live_allowed() and not _breaker_open_now() and _budget_ok():
		for j: Dictionary in _queue + _active:
			if str(j["key"]) == key:
				_emit_fallback(s, true)
				return
		_queue.append({"key": key, "kind": s["kind"], "prompt": s["prompt"], "size": s["size"], "priority": int(s["priority"]),
			"pos": s["pos"], "meta": meta, "state": "queued", "seq": stats["live_submits"] + _queue.size()})
		_emit_fallback(s, true)
		return
	_emit_fallback(s, false)


## Serves the pre-baked pool or procedural art for a job or serve entry.
func _emit_fallback(s: Dictionary, provisional: bool) -> void:
	var key := str(s["key"])
	var meta: Dictionary = (s["meta"] as Dictionary).duplicate()
	var t := fallback_texture(str(s["kind"]), key, meta)
	meta["provisional"] = provisional
	var src := str(meta["source"])
	stats[src] = int(stats.get(src, 0)) + 1
	_emit_ready(key, t, meta)


func _emit_ready(key: String, t: Texture2D, meta: Dictionary) -> void:
	image_ready.emit.call_deferred(key, t, meta)


func _budget_ok() -> bool:
	return live_today + _queue.size() < DAY_CAP and live_session + _queue.size() < SESSION_CAP


func _live_allowed() -> bool:
	if _client == null or not _client.live_enabled or _client.api_key.is_empty():
		return false
	if OS.get_environment("GRIDFALL_OFFLINE") == "1":
		return allow_live_with_injected_transport and transport.is_valid() and transport != _default_transport
	return true


func _breaker_open_now() -> bool:
	return _fails >= BREAKER_FAILS


func _roll_day() -> void:
	var d := _day()
	if d != _budget_day:
		if d > _budget_day:
			live_today = 0
			if _fails >= BREAKER_FAILS and d > _breaker_day:
				_fails = 0
		_budget_day = d


func _day() -> int:
	return int(_day_fn.call()) if _day_fn.is_valid() else 0


func _now() -> float:
	return float(clock.call())


func _sort_queue() -> void:
	var here: Vector3 = player_pos.call() if player_pos.is_valid() else Vector3.ZERO
	_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["priority"]) != int(b["priority"]):
			return int(a["priority"]) > int(b["priority"])
		var pa: Vector3 = a["pos"]
		var pb: Vector3 = b["pos"]
		var da := INF if not pa.is_finite() else pa.distance_squared_to(here)
		var db := INF if not pb.is_finite() else pb.distance_squared_to(here)
		if da != db:
			return da < db
		return int(a["seq"]) < int(b["seq"]))


# ------------------------------------------------------------------ live flow

func _auth_headers() -> PackedStringArray:
	return PackedStringArray(["Authorization: Bearer " + _client.api_key, "Content-Type: application/json"])


func _call(method: String, url: String, headers: PackedStringArray, body: String, to_file: String) -> Dictionary:
	transport_calls += 1
	var r: Variant = await transport.call(method, url, headers, body, to_file)
	return r if typeof(r) == TYPE_DICTIONARY else {"code": 0, "body": PackedByteArray()}


func _submit(job: Dictionary) -> void:
	var now := _now()
	_last_submit_ms = now
	job["state"] = "submitting"
	job["t_submit"] = now
	_active.append(job)
	peak_in_flight = maxi(peak_in_flight, _active.size())
	var body := JSON.stringify({"model": MODEL, "payload": {"prompt": job["prompt"], "size": job["size"]}})
	var r := await _call("POST", QUEUE_URL, _auth_headers(), body, "")
	if _closed or not _active.has(job):
		return
	var code := int(r.get("code", 0))
	if code == 429:
		# Not counted against the budget: back to the queue after a back-off.
		_active.erase(job)
		job["state"] = "queued"
		job["not_before"] = _now() + float(backoff_s[0]) * 1000.0
		_queue.push_front(job)
		return
	if code < 200 or code >= 300:
		_fail(job, "submit HTTP %d: %s" % [code, _body_text(r)])
		return
	live_today += 1
	live_session += 1
	stats["live_submits"] = int(stats["live_submits"]) + 1
	var data := _json(r)
	if str(data.get("status", "")) == "success":
		_got_outcome(job, data)
		return
	var rid := str(data.get("request_id", ""))
	if rid.is_empty():
		_fail(job, "no request_id: %s" % _body_text(r))
		return
	job["request_id"] = rid
	job["state"] = "poll_wait"
	job["due"] = _now() + poll_s * 1000.0


func _poll(job: Dictionary) -> void:
	job["state"] = "polling"
	var r := await _call("GET", QUEUE_URL + "/" + str(job["request_id"]), _auth_headers(), "", "")
	if _closed or not _active.has(job):
		return
	var code := int(r.get("code", 0))
	var now := _now()
	if code == 429:
		var b := float(job.get("backoff", 0.0))
		b = float(backoff_s[0]) if b <= 0.0 else minf(b * 2.0, float(backoff_s[1]))
		job["backoff"] = b
		job["state"] = "poll_wait"
		job["due"] = now + (poll_s + b) * 1000.0
		return
	if code >= 200 and code < 300:
		var data := _json(r)
		var status := str(data.get("status", ""))
		if status == "success":
			_got_outcome(job, data)
			return
		if status == "failed" or status == "error":
			_fail(job, "status %s: %s" % [status, _body_text(r)])
			return
	job["state"] = "poll_wait"
	job["due"] = now + poll_s * 1000.0


func _got_outcome(job: Dictionary, data: Dictionary) -> void:
	var url := _media_url(data.get("outcome", {}))
	if url.is_empty():
		_fail(job, "no media url in outcome")
		return
	_download(job, url)


## outcome.media_urls[0].url; also outcome.urls[0] and outcome.artifacts[0].url.
static func _media_url(outcome: Variant) -> String:
	if typeof(outcome) != TYPE_DICTIONARY:
		return ""
	var o: Dictionary = outcome
	for field: String in ["media_urls", "urls", "artifacts"]:
		var arr: Variant = o.get(field, [])
		if typeof(arr) != TYPE_ARRAY or (arr as Array).is_empty():
			continue
		var first: Variant = (arr as Array)[0]
		if typeof(first) == TYPE_DICTIONARY and str((first as Dictionary).get("url", "")).begins_with("http"):
			return str((first as Dictionary)["url"])
		if typeof(first) == TYPE_STRING and str(first).begins_with("http"):
			return str(first)
	return ""


func _download(job: Dictionary, url: String) -> void:
	job["state"] = "downloading"
	var tmp := CACHE_DIR + "tmp_%s.bin" % job["key"]
	# The media host is public storage: never send the Authorization header there.
	var r := await _call("GET", url, PackedStringArray(), "", tmp)
	if _closed or not _active.has(job):
		DirAccess.remove_absolute(tmp)
		return
	var code := int(r.get("code", 0))
	var bytes: PackedByteArray = r.get("body", PackedByteArray())
	if bytes.is_empty() and FileAccess.file_exists(tmp):
		bytes = FileAccess.get_file_as_bytes(tmp)
	DirAccess.remove_absolute(tmp)
	if code < 200 or code >= 300 or bytes.is_empty():
		_fail(job, "download HTTP %d" % code)
		return
	if bytes.size() > DOWNLOAD_LIMIT:
		_fail(job, "download too large (%d bytes)" % bytes.size())
		return
	job["state"] = "processing"
	_start_worker({"mode": "live", "key": job["key"], "bytes": bytes, "path": _disk_path(str(job["key"])),
		"size": job["size"], "long_edge": long_edge(str(job["kind"]), str(job["size"])), "meta": job["meta"], "job": job})


func _fail(job: Dictionary, reason: String) -> void:
	_active.erase(job)
	stats["live_fail"] = int(stats["live_fail"]) + 1
	_fails += 1
	if _fails >= BREAKER_FAILS:
		_breaker_day = _day()
	last_error = _scrub(reason).left(140)
	image_failed.emit.call_deferred(str(job["key"]), last_error)
	_emit_fallback(job, false)


func _scrub(s: String) -> String:
	if _client != null and not _client.api_key.is_empty():
		s = s.replace(_client.api_key, "***")
	return s


func _body_text(r: Dictionary) -> String:
	var b: PackedByteArray = r.get("body", PackedByteArray())
	return _scrub(b.slice(0, 400).get_string_from_utf8()).left(140)


func _json(r: Dictionary) -> Dictionary:
	var b: PackedByteArray = r.get("body", PackedByteArray())
	var parsed: Variant = JSON.parse_string(b.get_string_from_utf8())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## Long edge in pixels for a processed image: 1024 for wide (billboard, hoarding) art and the
## Gazette, 512 for portrait ads, walls and notices.
static func long_edge(kind: String, size: String) -> int:
	var wh := size.split("x")
	var wide := wh.size() == 2 and int(wh[0]) > int(wh[1])
	return 1024 if wide or ART.family(kind) == "gazette" else 512


# ------------------------------------------------------------------ processing

func _start_worker(input: Dictionary) -> void:
	input["compress"] = OS.has_feature("s3tc")
	_worker.push(GmiImageClient._process_image, input)


## Processing thread: decode, crop to the requested aspect, resize, save WebP (live only), mipmaps and
## VRAM compression. Touches nothing but its own input dictionary.
static func _process_image(input: Dictionary) -> void:
	var img := Image.new()
	if str(input["mode"]) == "disk":
		img = Image.load_from_file(str(input["path"]))
		if img == null or img.is_empty():
			input["error"] = "unreadable cache file"
			return
	else:
		var bytes: PackedByteArray = input["bytes"]
		var err := ERR_FILE_UNRECOGNIZED
		match _sniff(bytes):
			"png":
				err = img.load_png_from_buffer(bytes)
			"jpg":
				err = img.load_jpg_from_buffer(bytes)
			"webp":
				err = img.load_webp_from_buffer(bytes)
		if err != OK or img.is_empty():
			input["error"] = "undecodable image (%s)" % _sniff(bytes)
			return
		var wh := str(input["size"]).split("x")
		if wh.size() == 2 and int(wh[0]) > 0 and int(wh[1]) > 0:
			_crop_to_aspect(img, float(wh[0]) / float(wh[1]))
		var le := int(input["long_edge"])
		var s := float(le) / float(maxi(img.get_width(), img.get_height()))
		if s < 1.0:
			img.resize(maxi(4, roundi(img.get_width() * s)), maxi(4, roundi(img.get_height() * s)), Image.INTERPOLATE_LANCZOS)
		img.convert(Image.FORMAT_RGB8)
		var werr := img.save_webp(str(input["path"]), true, 0.85)
		if werr != OK:
			input["error"] = "cannot write cache file"
			return
		var f := FileAccess.open(str(input["path"]), FileAccess.READ)
		input["bytes_saved"] = f.get_length() if f != null else 0
	# Block compression wants sizes that are multiples of 4.
	var w4 := maxi(4, img.get_width() - img.get_width() % 4)
	var h4 := maxi(4, img.get_height() - img.get_height() % 4)
	if w4 != img.get_width() or h4 != img.get_height():
		img.crop(w4, h4)
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	img.generate_mipmaps()
	if bool(input["compress"]):
		img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
	input["image"] = img


static func _sniff(b: PackedByteArray) -> String:
	if b.size() >= 8 and b[0] == 0x89 and b[1] == 0x50 and b[2] == 0x4E and b[3] == 0x47:
		return "png"
	if b.size() >= 3 and b[0] == 0xFF and b[1] == 0xD8 and b[2] == 0xFF:
		return "jpg"
	if b.size() >= 12 and b.slice(0, 4).get_string_from_ascii() == "RIFF" and b.slice(8, 12).get_string_from_ascii() == "WEBP":
		return "webp"
	return "unknown"


static func _crop_to_aspect(img: Image, aspect: float) -> void:
	var w := img.get_width()
	var h := img.get_height()
	if absf(float(w) / float(h) - aspect) < 0.01:
		return
	if float(w) / float(h) > aspect:
		var nw := roundi(h * aspect)
		var cut := img.get_region(Rect2i((w - nw) / 2, 0, nw, h))
		img.copy_from(cut)
	else:
		var nh := roundi(w / aspect)
		var cut2 := img.get_region(Rect2i(0, (h - nh) / 2, w, nh))
		img.copy_from(cut2)


func _drain_workers() -> void:
	for input: Dictionary in _worker.take_done():
		_finish_worker(input)


func _finish_worker(input: Dictionary) -> void:
	var key := str(input["key"])
	var meta: Dictionary = input["meta"]
	var live := str(input["mode"]) == "live"
	var job: Dictionary = input.get("job", {})
	if not input.has("image"):
		if live:
			_fail(job, str(input.get("error", "processing failed")))
		else:
			DirAccess.remove_absolute(str(input["path"]))
			_emit_fallback({"key": key, "kind": meta.get("kind", ""), "meta": meta}, false)
		return
	var tex := ImageTexture.create_from_image(input["image"])
	_lru_put(key, tex)
	if live:
		_active.erase(job)
		_fails = 0
		stats["live_ok"] = int(stats["live_ok"]) + 1
		meta["source"] = "live"
		_index[key] = {"kind": str(meta.get("kind", "")), "size": str(meta.get("size", "")), "day": _day(),
			"created_at": Time.get_datetime_string_from_system(true), "source": "live", "bytes": int(input.get("bytes_saved", 0))}
		_trim_disk()
		_save_index()
	else:
		stats["cache_hits"] = int(stats["cache_hits"]) + 1
		meta["source"] = "disk"
	meta["provisional"] = false
	_emit_ready(key, tex, meta)


func _save_index() -> void:
	var f := FileAccess.open(INDEX_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_index, "\t"))


func _trim_disk() -> void:
	if _index.size() <= DISK_CAP:
		return
	var keys := _index.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(_index[a].get("created_at", "")) < str(_index[b].get("created_at", "")))
	for k: Variant in keys.slice(0, _index.size() - DISK_CAP):
		DirAccess.remove_absolute(_disk_path(str(k)))
		_index.erase(k)


# ------------------------------------------------------------------ caches

func _disk_path(key: String) -> String:
	return CACHE_DIR + key + ".webp"


func _lru_get(key: String) -> Texture2D:
	if not _lru.has(key):
		return null
	_lru_order.erase(key)
	_lru_order.append(key)
	return _lru[key]


func _lru_put(key: String, t: Texture2D) -> void:
	if _lru.has(key):
		_lru_order.erase(key)
	_lru[key] = t
	_lru_order.append(key)
	while _lru_order.size() > LRU_SIZE:
		_lru.erase(_lru_order.pop_front())


func _load_manifest() -> void:
	if _manifest_loaded:
		return
	_manifest_loaded = true
	if not FileAccess.file_exists(MANIFEST_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var files: Array = (parsed as Dictionary).keys()
	files.sort()
	for f: Variant in files:
		var e: Variant = parsed[f]
		if typeof(e) != TYPE_DICTIONARY or not ResourceLoader.exists(PREBAKED_DIR + str(f)):
			continue
		var entry: Dictionary = e
		_entries[str(f)] = entry
		_by_key[key_for(str(entry.get("prompt", "")), str(entry.get("size", "")))] = str(f)
		var pool := str(entry.get("pool", ""))
		if not pool.is_empty():
			if not _pools.has(pool):
				_pools[pool] = []
			(_pools[pool] as Array).append(str(f))
		var fam := str(entry.get("kind", ""))
		if not _families.has(fam):
			_families[fam] = []
		(_families[fam] as Array).append(str(f))


func _pool_files(kind: String) -> Array:
	if _pools.has(kind):
		return _pools[kind]
	return _families.get(ART.family(kind), [])


func _prebaked(file: String) -> Texture2D:
	if not _prebaked_tex.has(file):
		_prebaked_tex[file] = load(PREBAKED_DIR + file) as Texture2D
	return _prebaked_tex[file]


# ------------------------------------------------------------------ default transport

## One HTTPRequest per call; downloads stream to to_file on a thread. Returns {"code", "body"}.
func _http_transport(method: String, url: String, headers: PackedStringArray, body: String, to_file: String) -> Dictionary:
	http_requests += 1
	var req := HTTPRequest.new()
	req.timeout = POST_TIMEOUT_S if method == "POST" else (DOWNLOAD_TIMEOUT_S if not to_file.is_empty() else POLL_TIMEOUT_S)
	if not to_file.is_empty():
		req.download_file = to_file
		req.body_size_limit = DOWNLOAD_LIMIT
		req.use_threads = WebSupport.threads_supported()
	add_child(req)
	var m := HTTPClient.METHOD_POST if method == "POST" else HTTPClient.METHOD_GET
	var err := req.request(url, headers, m, body)
	if err != OK:
		req.queue_free()
		return {"code": 0, "body": PackedByteArray()}
	var res: Array = await req.request_completed
	req.queue_free()
	var code := int(res[1]) if int(res[0]) == HTTPRequest.RESULT_SUCCESS else 0
	return {"code": code, "body": res[3]}
