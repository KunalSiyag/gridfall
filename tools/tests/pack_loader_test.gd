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
	if fails.is_empty():
		print("PACK_LOADER_TEST: PASS")
	else:
		print("PACK_LOADER_TEST: FAIL ", fails)
	quit(0 if fails.is_empty() else 1)


func _check_desktop_noop() -> void:
	var loader := PackLoader.new()
	K.check(fails, not loader.load_manifest(), "no manifest in a desktop tree: inactive")
	K.check(fails, not loader.active(), "an inactive loader streams nothing")
	K.check(fails, loader.progress() == 1.0, "an inactive loader reports full progress")
	K.check(fails, loader.pack_of("res://models/real/zones/r1/a.glb") == "", "no pack without a manifest")
	K.check(fails, loader.needed_for("res://models/real/zones/r1/a.glb") == "", "nothing needed without a manifest")
	K.check(fails, not loader.request("zones"), "requesting a pack without a manifest fails quietly")


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
	var manifest := {
		"boot": "boot",
		"rules": [["models/real/zones/", "zones"], ["models/real/midlod/", "midlod"],
			["env/", "sky"], ["models/characters/bodies/", "people"]],
		"packs": {
			"zones": {"file": "releases/abc/packs/zones-11.pck", "bytes": 100},
			"sky": {"file": "releases/abc/packs/sky-22.pck", "bytes": 200},
		},
	}
	var loader := _with_manifest(manifest)
	K.check(fails, loader.active(), "a manifest makes the loader active")
	K.check(fails, loader.pack_of("res://models/real/zones/r1/a.glb") == "zones", "zone asset maps to zones")
	K.check(fails, loader.pack_of("res://models/real/midlod/t.res") == "midlod", "midlod asset maps to midlod")
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
	K.check(fails, loader.needed_for("res://env/sky.hdr") == "", "a mounted pack is no longer needed")


func _check_cache_path() -> void:
	var loader := _with_manifest({
		"packs": {"zones": {"file": "releases/abc/packs/zones-11.pck", "bytes": 100}},
	})
	K.check(fails, loader.cache_path("zones") == "user://packs/zones-11.pck",
		"the cache file carries the pack's own hash: " + loader.cache_path("zones"))


## A cached pack whose size no longer matches its manifest entry must be dropped, not mounted.
func _check_stale_cache() -> void:
	var manifest := {"packs": {"zones": {"file": "releases/abc/packs/zones-11.pck", "bytes": 100}}}
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
