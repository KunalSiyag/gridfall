extends SceneTree
## PackLoader (scripts/ops): the manifest drives which pack an asset needs, the local cache path
## carries the pack's own content hash, and a stale cache file is dropped rather than mounted.
## Desktop has no manifest, so every call is a no-op there.

const K := preload("res://tools/tests/fp_kit.gd")
const PackLoader := preload("res://scripts/ops/pack_loader.gd")

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_desktop_noop()
	_check_manifest()
	_check_cache_path()
	_check_stale_cache()
	_check_cached_mount()
	_check_failed_mount()
	_check_download_validation()
	_check_manifest_validation()
	_check_request_next()
	_check_cancel_active()
	await _check_reset_active_request()
	_check_promote_and_mount()
	if fails.is_empty():
		print("PACK_LOADER_TEST: PASS")
	else:
		print("PACK_LOADER_TEST: FAIL ", fails)
	quit(0 if fails.is_empty() else 1)


func _check_desktop_noop() -> void:
	var loader := PackLoader.new()
	var zone := "res://models/real/zones/r1/a.glb"
	K.check(fails, not loader.load_manifest(), "no manifest in a desktop tree: inactive")
	K.check(fails, not loader.active(), "an inactive loader streams nothing")
	K.check(fails, loader.progress() == 1.0, "an inactive loader reports full progress")
	K.check(fails, loader.pack_of(zone) == "", "no pack without a manifest")
	K.check(fails, loader.needed_for(zone) == "", "nothing needed without a manifest")
	K.check(fails, not loader.request("zones"), "no manifest: request fails quietly")


## A loader pointed at a scratch manifest, so the manifest logic runs headless.
func _with_manifest(manifest: Dictionary) -> PackLoader:
	var loader := PackLoader.new()
	var path := "user://pack_loader_manifest.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest))
	file.close()
	# load_manifest reads res://, so exercise the same parsing through the public shape.
	loader.set("_manifest", manifest)
	return loader


func _check_manifest() -> void:
	var zone := "res://models/real/zones/r1/a.glb"
	var midlod := "res://models/real/midlod/t.res"
	var manifest := {
		"boot": "boot",
		"rules":
		[
			["models/real/zones/", "zones"],
			["models/real/midlod/", "midlod"],
			["env/", "sky"],
			["models/characters/bodies/", "people"]
		],
		"packs":
		{
			"zones": {"file": "releases/abc/packs/zones-11.pck", "bytes": 100},
			"sky": {"file": "releases/abc/packs/sky-22.pck", "bytes": 200},
		},
	}
	var loader := _with_manifest(manifest)
	K.check(fails, loader.active(), "a manifest makes the loader active")
	K.check(fails, loader.pack_of(zone) == "zones", "a zone asset maps to zones")
	K.check(fails, loader.pack_of(midlod) == "midlod", "a midlod asset maps to midlod")
	K.check(fails, loader.pack_of("res://env/sky.hdr") == "sky", "an HDRI maps to sky")
	K.check(fails, loader.pack_of("res://scripts/main.gd") == "", "a boot asset needs no pack")
	K.check(fails, loader.needed_for("res://env/sky.hdr") == "sky", "an unmounted pack is needed")
	K.check(fails, loader.needed_for("res://scripts/main.gd") == "", "a boot asset is never needed")
	K.check(fails, loader.request("zones"), "a known pack can be queued")
	K.check(fails, loader.pending("zones"), "a queued pack reads as pending")
	K.check(fails, not loader.request("nope"), "an unknown pack is refused")
	K.check(fails, loader.progress() == 0.0, "no pack mounted yet")
	loader.set("_mounted", {"sky": true})
	K.check(fails, loader.progress() == 0.5, "half the packs mounted")
	K.check(
		fails, loader.needed_for("res://env/sky.hdr") == "", "a mounted pack is no longer needed"
	)


func _check_cache_path() -> void:
	var loader := _with_manifest(
		{
			"packs": {"zones": {"file": "releases/abc/packs/zones-11.pck", "bytes": 100}},
		}
	)
	K.check(
		fails,
		loader.cache_path("zones") == "user://packs/zones-11.pck",
		"the cache file carries the pack's own hash: " + loader.cache_path("zones")
	)


## A cached pack whose size no longer matches its manifest entry must be dropped, not mounted.
func _check_stale_cache() -> void:
	var manifest := {
		"base": "http://127.0.0.1:1",
		"packs": {"zones": {"file": "releases/abc/packs/zones-11.pck", "bytes": 100}}
	}
	var loader := _with_manifest(manifest)
	var path := loader.cache_path("zones")
	DirAccess.make_dir_recursive_absolute(PackLoader.CACHE_DIR)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(PackedByteArray([1, 2, 3]))
	file.close()
	K.check(fails, FileAccess.file_exists(path), "a short cache file exists before the check")
	# The guard: wrong size means delete and re-fetch, so pump() must not treat it as usable.
	var host := Node.new()
	get_root().add_child(host)
	K.check(fails, loader.request("zones"), "the pack is queued for the guard to act on")
	loader.pump(host)
	K.check(fails, not FileAccess.file_exists(path), "a size-mismatched cache file is deleted")
	loader.reset()
	host.queue_free()


func _fixture_loader(name: String, size: int) -> PackLoader:
	return _with_manifest({"packs": {name: {"file": "packs/" + name + ".pck", "bytes": size}}})


## Mounting a valid cache never creates an HTTPRequest, so cleanup must accept null.
func _check_cached_mount() -> void:
	var loader := _fixture_loader("cache-regression", 0)
	var path := loader.cache_path("cache-regression")
	var source := "user://pack_loader_probe.txt"
	var file := FileAccess.open(source, FileAccess.WRITE)
	file.store_string("cached pack regression")
	file.close()
	var packer := PCKPacker.new()
	K.check(fails, packer.pck_start(path) == OK, "create the cached PCK fixture")
	K.check(
		fails,
		packer.add_file("res://pack_loader_cache_probe.txt", source) == OK,
		"add the cached PCK fixture resource"
	)
	K.check(fails, packer.flush() == OK, "finish the cached PCK fixture")
	loader._manifest["packs"]["cache-regression"]["bytes"] = (
		FileAccess.get_file_as_bytes(path).size()
	)
	var arrivals: Array[String] = []
	loader.pack_arrived.connect(func(pack: String) -> void: arrivals.append(pack))
	var host := Node.new()
	get_root().add_child(host)
	loader.request("cache-regression")
	K.check(fails, not loader.pump(host), "cache mount finishes without network work")
	K.check(fails, loader.mounted("cache-regression"), "cached pack mounts")
	K.check(fails, arrivals == ["cache-regression"], "cached mount emits arrival once")
	K.check(fails, host.get_child_count() == 0, "cache mount creates no HTTPRequest")
	K.check(
		fails,
		(
			FileAccess.get_file_as_string("res://pack_loader_cache_probe.txt")
			== "cached pack regression"
		),
		"cached resource is available after mount"
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(source))
	host.queue_free()


## A failed mount reports failure, releases pending state, and remains retryable.
func _check_failed_mount() -> void:
	var loader := _fixture_loader("bad-mount-regression", 3)
	var path := loader.cache_path("bad-mount-regression")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(PackedByteArray([1, 2, 3]))
	file.close()
	var failures: Array = []
	loader.pack_failed.connect(
		func(pack: String, reason: String) -> void: failures.append([pack, reason])
	)
	var host := Node.new()
	get_root().add_child(host)
	loader.request("bad-mount-regression")
	loader.pump(host)
	K.check(
		fails, failures == [["bad-mount-regression", "mount"]], "mount failure emits one failure"
	)
	K.check(fails, not loader.pending("bad-mount-regression"), "failed pack is no longer pending")
	K.check(fails, not FileAccess.file_exists(path), "failed mount deletes corrupt cached bytes")
	K.check(fails, loader.request("bad-mount-regression"), "failed pack can be requested again")
	loader.reset()
	host.queue_free()


## Even HTTP 200 is a failure when transport failed or the decoded body size is wrong.
func _check_download_validation() -> void:
	for sample: Array in [
		[HTTPRequest.RESULT_CONNECTION_ERROR, 200, PackedByteArray([1, 2, 3]), "download"],
		[HTTPRequest.RESULT_SUCCESS, 404, PackedByteArray([1, 2, 3]), "download"],
		[HTTPRequest.RESULT_SUCCESS, 200, PackedByteArray([1, 2]), "size"],
		[HTTPRequest.RESULT_SUCCESS, 200, PackedByteArray([1, 2, 3, 4]), "size"],
		[HTTPRequest.RESULT_SUCCESS, 200, PackedByteArray(), "size"],
	]:
		var loader := _fixture_loader("download-regression", 3)
		var path := loader.cache_path("download-regression")
		var file := FileAccess.open(path + ".part", FileAccess.WRITE)
		file.store_buffer(PackedByteArray([9]))
		file.close()
		loader._active = "download-regression"
		loader._loading = {"download-regression": true}
		loader._target = path
		var failures: Array = []
		var arrivals: Array = []
		loader.pack_failed.connect(
			func(pack: String, reason: String) -> void: failures.append([pack, reason])
		)
		loader.pack_arrived.connect(func(pack: String) -> void: arrivals.append(pack))
		loader._on_download(sample[0], sample[1], PackedStringArray(), sample[2])
		K.check(
			fails,
			failures == [["download-regression", sample[3]]],
			"download validation emits the failure reason: " + str(sample[3])
		)
		K.check(fails, arrivals.is_empty(), "invalid download does not emit arrival")
		K.check(
			fails,
			not FileAccess.file_exists(path + ".part"),
			"invalid download deletes the partial file"
		)
		K.check(fails, not FileAccess.file_exists(path), "a failed attempt never poses as cache")
		K.check(fails, not loader.pending("download-regression"), "invalid download clears pending")
		K.check(fails, not loader.mounted("download-regression"), "invalid download is not mounted")
		loader.reset()


## Reset cancels a real local request, detaches it, and cannot emit a late completion.
func _check_reset_active_request() -> void:
	var server := TCPServer.new()
	var listening := server.listen(0, "127.0.0.1")
	K.check(fails, listening == OK, "local reset fixture listens")
	if listening != OK:
		return
	var loader := _fixture_loader("reset-regression", 3)
	loader._manifest["base"] = "http://127.0.0.1:%d" % server.get_local_port()
	var host := Node.new()
	get_root().add_child(host)
	var completions: Array = []
	loader.pack_failed.connect(
		func(pack: String, _reason: String) -> void: completions.append(pack)
	)
	loader.pack_arrived.connect(func(pack: String) -> void: completions.append(pack))
	loader.request("reset-regression")
	loader.pump(host)
	var request := loader._http
	K.check(fails, request != null, "reset fixture starts an HTTPRequest")
	if request != null:
		for _frame in range(60):
			if server.is_connection_available():
				break
			await process_frame
		var connection := server.take_connection() if server.is_connection_available() else null
		K.check(fails, connection != null, "local request is active before reset")
		var weak_request: WeakRef = weakref(request)
		loader.reset()
		K.check(
			fails,
			request.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED,
			"reset cancels the active transport immediately"
		)
		K.check(fails, host.get_child_count() == 0, "reset detaches the request immediately")
		K.check(fails, loader._http == null, "reset drops the request reference")
		K.check(fails, not loader.active(), "reset clears the manifest")
		K.check(fails, not loader.pending("reset-regression"), "reset clears pending state")
		K.check(fails, not loader.pump(host), "reset leaves no queued work")
		await process_frame
		K.check(fails, weak_request.get_ref() == null, "reset frees the request")
		K.check(fails, completions.is_empty(), "cancelled request emits no late completion")
		if connection != null:
			connection.disconnect_from_host()
	server.stop()
	host.queue_free()


## load_manifest()'s deep validation, exercised through _validate() (the test cannot write
## res://) plus the manifest_status() transitions the coordinator branches on.
func _check_manifest_validation() -> void:
	var loader := PackLoader.new()
	K.check(fails, loader.manifest_status() == "none", "a fresh loader has no manifest")
	var good := {
		"packs": {"zones": {"file": "packs/zones-1.pck", "bytes": 100}},
		"rules": [["models/real/zones/", "zones"]],
	}
	K.check(fails, loader._validate(good), "a valid manifest passes")
	for sample: Dictionary in [
		{"packs": {}},  # no packs
		{"packs": {"zones": {"file": "packs/z-1.pck"}}},  # missing bytes
		{"packs": {"zones": {"file": "packs/z-1.pck", "bytes": 0}}},  # zero bytes
		{"packs": {"zones": {"file": "../z-1.pck", "bytes": 1}}},  # traversal
		{"packs": {"zones": {"file": "http://x/z-1.pck", "bytes": 1}}},  # scheme
		{"packs": {"zones": {"file": "/abs/z-1.pck", "bytes": 1}}},  # absolute
		{"packs": {"zones": {"file": "packs/z-1.txt", "bytes": 1}}},  # not a .pck
		{"packs": {"zones": {"file": "packs/z-1.pck", "bytes": 1}}, "rules": "nope"},
		{"packs": {"zones": {"file": "packs/z-1.pck", "bytes": 1}}, "rules": [["only-one"]]},
		{
			"packs": {"zones": {"file": "packs/z-1.pck", "bytes": 1}},
			"rules": [["models/", "nope"]],  # rule names an unknown pack
		},
		{"base": 5, "packs": {"zones": {"file": "packs/z-1.pck", "bytes": 1}}},  # non-string base
	]:
		K.check(fails, not loader._validate(sample), "rejects: " + JSON.stringify(sample))
	loader.set("_manifest", good)
	loader.set("_manifest_state", "ok")
	K.check(fails, loader.manifest_status() == "ok", "a validated manifest reports ok")
	K.check(fails, loader.active(), "an ok manifest makes the loader active")
	# load_manifest() leaves an empty manifest beside the "invalid" state; mirror that.
	loader.set("_manifest", {})
	loader.set("_manifest_state", "invalid")
	K.check(fails, not loader.active(), "an invalid manifest keeps the loader inert")
	K.check(fails, not loader.request("zones"), "an invalid manifest refuses requests")


## A demanded pack jumps the queue without disturbing what is already moving.
func _check_request_next() -> void:
	var loader := _with_manifest(
		{
			"packs":
			{
				"a": {"file": "packs/a-1.pck", "bytes": 1},
				"b": {"file": "packs/b-1.pck", "bytes": 1},
				"c": {"file": "packs/c-1.pck", "bytes": 1},
			}
		}
	)
	K.check(fails, loader.request("a") and loader.request("b"), "two packs queue")
	K.check(fails, loader.request_next("c"), "a demanded pack queues ahead")
	K.check(
		fails, loader._pending == ["c", "a", "b"], "demand front-enqueues: " + str(loader._pending)
	)
	K.check(fails, not loader.request_next("c"), "an already-queued pack is not re-queued")
	loader.reset()


## The watchdog's escape hatch: cancel_active fails the active pack once, clears its state.
func _check_cancel_active() -> void:
	var loader := _fixture_loader("hang", 1)
	var failures: Array = []
	loader.pack_failed.connect(
		func(pack: String, reason: String) -> void: failures.append([pack, reason])
	)
	loader.cancel_active("timeout")
	K.check(fails, failures.is_empty(), "cancel with nothing active emits nothing")
	loader._active = "hang"
	loader._loading = {"hang": true}
	loader.cancel_active("timeout")
	K.check(fails, failures == [["hang", "timeout"]], "cancel_active emits the cancel reason")
	K.check(fails, loader.active_pack() == "", "cancel_active clears the active pack")
	K.check(fails, not loader.pending("hang"), "cancel_active clears pending state")
	loader.reset()


## The web path: bytes arrive, promote from .part, mount. A good cache must survive alongside.
func _check_promote_and_mount() -> void:
	var loader := _fixture_loader("promote-regression", 0)
	var path := loader.cache_path("promote-regression")
	var staging := "user://packs/promote-staging.pck"
	var source := "user://pack_loader_probe.txt"
	var file := FileAccess.open(source, FileAccess.WRITE)
	file.store_string("promoted pack regression")
	file.close()
	var packer := PCKPacker.new()
	K.check(fails, packer.pck_start(staging) == OK, "create the download fixture PCK")
	K.check(
		fails,
		packer.add_file("res://pack_loader_promote_probe.txt", source) == OK,
		"add the download fixture resource"
	)
	K.check(fails, packer.flush() == OK, "finish the download fixture PCK")
	var body := FileAccess.get_file_as_bytes(staging)
	loader._manifest["packs"]["promote-regression"]["bytes"] = body.size()
	var arrivals: Array[String] = []
	var failures: Array = []
	loader.pack_arrived.connect(func(pack: String) -> void: arrivals.append(pack))
	loader.pack_failed.connect(
		func(pack: String, reason: String) -> void: failures.append([pack, reason])
	)
	loader._active = "promote-regression"
	loader._loading = {"promote-regression": true}
	loader._target = path
	loader._on_download(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), body)
	K.check(fails, arrivals == ["promote-regression"], "a good download promotes and mounts")
	K.check(fails, failures.is_empty(), "a good download emits no failure")
	K.check(fails, not FileAccess.file_exists(path + ".part"), "no partial file survives a mount")
	K.check(fails, FileAccess.file_exists(path), "the promoted pack becomes the cache")
	K.check(fails, loader.mounted("promote-regression"), "the promoted pack is mounted")
	K.check(
		fails,
		(
			FileAccess.get_file_as_string("res://pack_loader_promote_probe.txt")
			== "promoted pack regression"
		),
		"the promoted pack's resource loads"
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(staging))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(source))
	loader.reset()
