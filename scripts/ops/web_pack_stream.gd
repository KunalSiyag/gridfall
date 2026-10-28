class_name WebPackStream
extends Node
## Background-pack streaming policy for the split web build (ops layer). Owns the one
## PackLoader pump, the download order, bounded retries and the status snapshot the HUD shows.
##
## Created by Main on every platform but inert unless activate() succeeds: streaming needs the
## web_split_packs flag AND the web platform AND a validated manifest. A split build with the
## flag off is a configuration error (the boot pack cannot conjure the missing packs); roll a
## split release back by replacing it with the unsplit one, never by disabling the flag.
##
## Downloads continue while the pause menu stops the world (PROCESS_MODE_ALWAYS); mounting the
## arrived packs refreshes geometry only through the normal render processing of the consumers.

signal pack_ready(pack: String)
signal state_changed(snapshot: Dictionary)

## Default background order: midlod first (it ends runtime gather stalls), then the decorative
## packs. Packs absent from the manifest are skipped; unknown manifest packs queue last.
const DEFAULT_ORDER: Array[String] = [
	"midlod", "sky", "traffic", "people", "props", "wildlife", "posters", "audio"
]
## Automatic retry backoff after the first attempt: two retries, after 2 and 8 seconds.
const RETRY_DELAYS_S: Array[float] = [2.0, 8.0]
## One download attempt may take at most this long before the watchdog cancels it.
const REQUEST_TIMEOUT_S := 60.0

## activate() results.
enum {
	ACTIVATE_OK,  ## streaming live
	ACTIVATE_NOT_WEB,  ## desktop/native: nothing to do, not an error
	ACTIVATE_UNSPLIT,  ## no manifest in this build: nothing to do, not an error
	ACTIVATE_FLAG_OFF,  ## web_split_packs off; an error only when the build IS split
	ACTIVATE_BAD_MANIFEST,  ## a manifest was embedded but failed validation
}

## Test seam: "web" makes the platform check pass off the web; never set in game code.
var force_platform := ""

var _loader: PackLoader = null
var _clock: Callable = Callable()  # msec; tests inject a fake
var _queue: Array[String] = []
var _states := {}  # pack -> "queued" | "downloading" | "mounted" | "retry_wait" | "failed"
var _attempts := {}  # pack -> attempts used (initial + retries)
var _retry_at := {}  # pack -> deadline msec
var _demanded: Array[String] = []  # demand order; keeps later demands behind earlier ones
var _active_pack := ""
var _active_since := 0
var _midlod_started := false
var _activated := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


## Inject the loader and (tests only) a fake msec clock. Call before activate().
func setup(loader: PackLoader, clock: Callable = Callable()) -> void:
	_loader = loader
	_clock = clock
	_loader.pack_arrived.connect(_on_arrived)
	_loader.pack_failed.connect(_on_failed)


## True when the embedded manifest is valid, whatever the flag says (a split build).
func loader_active() -> bool:
	return _loader != null and _loader.active()


## Starts streaming when the flag, the platform and the manifest all allow it. See ACTIVATE_*.
func activate() -> int:
	if _activated:
		return ACTIVATE_OK
	if _loader == null:
		setup(PackLoader.new())
		# No manifest file: unsplit build, handled below by manifest_status().
		_loader.load_manifest()
	if not _platform_is_web():
		return ACTIVATE_NOT_WEB
	match _loader.manifest_status():
		"invalid":
			return ACTIVATE_BAD_MANIFEST
		"none":
			return ACTIVATE_UNSPLIT
	if not FeatureFlags.enabled("web_split_packs", false):
		return ACTIVATE_FLAG_OFF
	_activated = true
	var known := _loader.pack_names()
	for pack: String in DEFAULT_ORDER:
		if known.has(pack):
			_enqueue(pack)
	for pack: String in known:
		if not DEFAULT_ORDER.has(pack):
			_enqueue(pack)
	set_process(true)
	_emit_state()
	return ACTIVATE_OK


## The pack a path still needs, or "" when it is available. Demanding an unqueued pack moves it
## ahead of the queued optional packs, but never cancels the active transfer or leapfrogs
## midlod's first request; demands among themselves keep their arrival order. A failed pack
## stays failed (the retry budget is not resettable by consumers); the HUD uses retry_failed().
func request_path(path: String) -> String:
	if not _activated:
		return ""
	var pack := _loader.needed_for(path)
	if pack.is_empty() or _states.get(pack) == "mounted":
		return ""
	var at := 0
	if not _midlod_started and not _queue.is_empty() and _queue[0] == "midlod":
		at = 1
	match str(_states.get(pack, "")):
		"downloading", "retry_wait", "failed":
			return pack
		"queued":
			if _demanded.has(pack):
				return pack  # already demanded; keep its earned place
			var was := _queue.find(pack)
			if was >= 0:
				_queue.remove_at(was)
				_queue.insert(_demand_slot(at), pack)
				_demanded.append(pack)
				_emit_state()
			return pack
	_queue.insert(_demand_slot(at), pack)
	_states[pack] = "queued"
	_demanded.append(pack)
	_emit_state()
	return pack


## True once the pack's assets can be loaded.
func mounted(pack: String) -> bool:
	return _activated and _loader.mounted(pack)


## A point-in-time copy of the pack states for the HUD; safe to keep and diff.
func snapshot() -> Dictionary:
	var done := true
	var mounted_count := 0
	for pack: String in _states:
		if _states[pack] == "mounted":
			mounted_count += 1
		elif _states[pack] != "failed":
			done = false
	return {
		"packs": _states.duplicate(),
		"active": _active_pack,
		"mounted": mounted_count,
		"total": _states.size(),
		"complete": done,
	}


## The HUD's retry button: a fresh bounded cycle for failed packs only.
func retry_failed() -> void:
	if not _activated:
		return
	var again := false
	for pack: String in _states:
		if _states[pack] == "failed":
			_attempts[pack] = 0
			_states[pack] = "queued"
			_queue.push_front(pack)
			again = true
	if again:
		_emit_state()


func _process(_delta: float) -> void:
	if not _activated:
		return
	# Watchdog first: a stuck attempt frees the queue for the packs behind it.
	if not _active_pack.is_empty() and _now() - _active_since > int(REQUEST_TIMEOUT_S * 1000.0):
		_loader.cancel_active("timeout")
	for pack: String in _states:
		if _states[pack] == "retry_wait" and _now() >= int(_retry_at.get(pack, 0)):
			_states[pack] = "queued"
			_retry_at.erase(pack)
			_queue.append(pack)
			_emit_state()
	# Feed the loader one pack at a time, only when it is idle, so demands can still reorder
	# everything that has not started.
	if _loader.active_pack().is_empty() and not _queue.is_empty():
		_loader.request(_queue.pop_front())
	_loader.pump(self)
	var active: String = _loader.active_pack()
	if active != _active_pack:
		_active_pack = active
		_active_since = _now()
		if not _active_pack.is_empty():
			_states[_active_pack] = "downloading"
			_demanded.erase(_active_pack)
			if _active_pack == "midlod":
				_midlod_started = true


## Queue position for a newly demanded pack: after midlod's first request and after any
## earlier demands still waiting (demands keep their arrival order).
func _demand_slot(at: int) -> int:
	var slot := at
	for d: String in _demanded:
		if _queue.has(d):
			slot += 1
	return slot


func _enqueue(pack: String) -> void:
	_queue.append(pack)
	_states[pack] = "queued"
	_attempts[pack] = 0


func _on_arrived(pack: String) -> void:
	_states[pack] = "mounted"
	_attempts[pack] = 0
	_active_pack = ""
	pack_ready.emit(pack)
	_emit_state()


func _on_failed(pack: String, _reason: String) -> void:
	_active_pack = ""
	_attempts[pack] = int(_attempts.get(pack, 0)) + 1
	if _attempts[pack] <= RETRY_DELAYS_S.size():
		_states[pack] = "retry_wait"
		_retry_at[pack] = _now() + int(RETRY_DELAYS_S[_attempts[pack] - 1] * 1000.0)
	else:
		_states[pack] = "failed"  # moves aside; the rest of the queue keeps arriving
	_emit_state()


func _emit_state() -> void:
	state_changed.emit(snapshot())


func _now() -> int:
	if _clock.is_valid():
		return int(_clock.call())
	return Time.get_ticks_msec()


func _platform_is_web() -> bool:
	if not force_platform.is_empty():
		return force_platform == "web"
	return OS.has_feature("web")
