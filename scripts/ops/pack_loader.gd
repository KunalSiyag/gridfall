class_name PackLoader
extends RefCounted
## Streams the web build's background packs: the boot pack is the engine's own `.pck`, and the
## others land later under `user://packs/`, each mounted with `ProjectSettings.load_resource_pack`.
##
## The engine loads the boot pack before any script runs, so the manifest that says which pack
## holds an asset rides inside it (`res://web_manifest.json`). A pack is cached in the browser's
## IDBFS under a name that carries its own content hash, so a repeat visit reuses it without a
## byte on the wire; a cached file whose size no longer matches its manifest entry is deleted and
## fetched again rather than failing the load.
##
## Desktop builds have no manifest and every method here is a no-op, so nothing changes there.

const MANIFEST_PATH := "res://web_manifest.json"
const CACHE_DIR := "user://packs"

## Emitted once a pack is mounted and its resources are available.
signal pack_arrived(pack: String)
## Emitted after a failed attempt, with a reason code; the pack can be requested again.
signal pack_failed(pack: String, reason: String)

var _manifest: Dictionary = {}
var _mounted: Dictionary = {}
var _loading: Dictionary = {}
var _pending: Array[String] = []
var _http: HTTPRequest = null
var _active: String = ""
var _target: String = ""


## Reads the manifest the export wrote into the boot pack; false when this build is unsplit.
func load_manifest() -> bool:
	if not FileAccess.file_exists(MANIFEST_PATH):
		return false
	var text := FileAccess.get_file_as_string(MANIFEST_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("PackLoader: web_manifest.json is not an object")
		return false
	_manifest = parsed
	return not _manifest.get("packs", {}).is_empty()


## True when the export shipped a split pack set (and so the runtime should stream it).
func active() -> bool:
	return not _manifest.is_empty()


## The pack that holds the asset at a res:// path, or "" when it rides in the boot pack.
func pack_of(path: String) -> String:
	var relative := path.trim_prefix("res://")
	var best := ""
	var found := ""
	for rule: Array in _manifest.get("rules", []):
		var prefix := str(rule[0])
		if relative.begins_with(prefix) and prefix.length() > best.length():
			best = prefix
			found = str(rule[1])
	return found


## True once the pack is mounted and its assets can be loaded.
func mounted(pack: String) -> bool:
	return _mounted.has(pack)


## True while the pack is on its way (queued, downloading or mounting).
func pending(pack: String) -> bool:
	return _loading.has(pack) or _pending.has(pack)


## The pack a path needs, or "" when it is already available (in the boot pack or mounted).
func needed_for(path: String) -> String:
	var pack := pack_of(path)
	if pack.is_empty() or _mounted.has(pack):
		return ""
	return pack


## Queues a pack (once). Call pump() to advance; returns false when the pack does not exist.
func request(pack: String) -> bool:
	if pack.is_empty() or _mounted.has(pack) or _loading.has(pack) or _pending.has(pack):
		return _mounted.has(pack)
	if not _manifest.get("packs", {}).has(pack):
		push_warning("PackLoader: no such pack: " + pack)
		return false
	_pending.append(pack)
	return true


## Local cache path for a pack: its own content hash keeps a stale file from ever being reused.
func cache_path(pack: String) -> String:
	var entry: Dictionary = _manifest.get("packs", {}).get(pack, {})
	var file := str(entry.get("file", ""))
	var base := file.get_file().get_basename()
	return CACHE_DIR.path_join(base + ".pck")


## Advances the queue on a node (one download at a time). Returns true while work remains.
func pump(host: Node) -> bool:
	if _active.is_empty() and not _pending.is_empty():
		_start(host, _pending.pop_front())
	return not _active.is_empty() or not _pending.is_empty()


## Fraction of the background packs that are in (0..1); 1 when there is nothing to fetch.
func progress() -> float:
	var total := float(_manifest.get("packs", {}).size())
	if total <= 0.0:
		return 1.0
	return float(_mounted.size()) / total


## Drops the in-memory state (tests, and a scene reload).
func reset() -> void:
	_clear_request()
	_manifest = {}
	_mounted = {}
	_loading = {}
	_pending = []
	_active = ""
	_target = ""


func _start(host: Node, pack: String) -> void:
	_loading[pack] = true
	_active = pack
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var path := cache_path(pack)
	var entry: Dictionary = _manifest["packs"][pack]
	# A cached file whose size no longer matches is stale: drop it and fetch again.
	if FileAccess.file_exists(path) and _size_of(path) != int(entry.get("bytes", -1)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if FileAccess.file_exists(path):
		_mount(pack, path)
		return
	_target = path
	_http = HTTPRequest.new()
	_http.name = "PackRequest"
	host.add_child(_http)
	_http.request_completed.connect(_on_download)
	var url := _url_for(str(entry.get("file", "")))
	if _http.request(url) != OK:
		push_warning("PackLoader: could not start the download for " + pack)
		_finish(pack, false, "request")


func _on_download(
	result: int, code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	var pack := _active
	if pack.is_empty():
		return
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_warning("PackLoader: download failed for %s (HTTP %d)" % [pack, code])
		_finish(pack, false, "download")
		return
	var expected := int(_manifest["packs"][pack].get("bytes", -1))
	if body.is_empty() or body.size() != expected:
		push_warning("PackLoader: download size mismatch for " + pack)
		_finish(pack, false, "size")
		return
	var file := FileAccess.open(_target, FileAccess.WRITE)
	if file == null:
		push_warning("PackLoader: cannot write " + _target)
		_finish(pack, false, "write")
		return
	file.store_buffer(body)
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		_finish(pack, false, "write")
		return
	_mount(pack, _target)


func _mount(pack: String, path: String) -> void:
	if not ProjectSettings.load_resource_pack(path, true):
		push_warning("PackLoader: could not mount " + path)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		_finish(pack, false, "mount")
		return
	_mounted[pack] = true
	_finish(pack, true)


func _finish(pack: String, ok: bool, reason: String = "") -> void:
	if not ok and not _target.is_empty() and FileAccess.file_exists(_target):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_target))
	_loading.erase(pack)
	_active = ""
	_target = ""
	_clear_request()
	if ok:
		pack_arrived.emit(pack)
	else:
		pack_failed.emit(pack, reason)


func _clear_request() -> void:
	if _http == null:
		return
	if _http.request_completed.is_connected(_on_download):
		_http.request_completed.disconnect(_on_download)
	_http.cancel_request()
	if _http.get_parent() != null:
		_http.get_parent().remove_child(_http)
	_http.queue_free()
	_http = null


func _url_for(file: String) -> String:
	var base := str(_manifest.get("base", ""))
	if base.is_empty():
		# Same directory as the loader page: the release prefix is in the manifest's file paths.
		return file
	return base.trim_suffix("/") + "/" + file


func _size_of(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var size := file.get_length()
	file.close()
	return size
