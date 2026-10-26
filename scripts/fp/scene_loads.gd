extends RefCounted
## PackedScenes loaded on background threads (ResourceLoader's threaded loads), for the features
## that stream bodies in (the crews' workers, the dogs): request() starts a load, scene() hands
## the scene out once it is in, and finish() waits for the loads still in flight. Without real
## threads (the no-threads web build) request() loads on the caller's thread instead.

const WebSupport := preload("res://scripts/ops/web_support.gd")

var _loading: Dictionary = {}
var _loaded: Dictionary = {}


## Starts loading the scene at path on a background thread (once), or at once when there are none.
func request(path: String) -> void:
	if _loaded.has(path) or _loading.has(path):
		return
	if not WebSupport.threads_supported():
		_loaded[path] = ResourceLoader.load(path, "PackedScene")
		return
	if ResourceLoader.load_threaded_request(path, "PackedScene") == OK:
		_loading[path] = true
	else:
		_loaded[path] = null


## True while the scene at path is still on its way.
func pending(path: String) -> bool:
	return _loading.has(path)


## The scene at path once it is in; null while it loads (unless wait, which blocks until it is
## in) or when it failed. Asks for it first when nobody did.
func scene(path: String, wait: bool) -> PackedScene:
	if _loaded.has(path):
		return _loaded[path]
	request(path)
	if not _loading.has(path):
		return null
	var busy := (
		ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS
	)
	if busy and not wait:
		return null
	_loading.erase(path)
	_loaded[path] = ResourceLoader.load_threaded_get(path) as PackedScene
	return _loaded[path]


## Waits for the loads still in flight (quitting with one running aborts it noisily).
func finish() -> void:
	for path: String in _loading.keys():
		_loaded[path] = ResourceLoader.load_threaded_get(path) as PackedScene
	_loading.clear()
