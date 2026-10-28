extends SceneTree
## WebPackStream (scripts/ops): the background-pack policy for the split web build. A fake
## loader answers synchronously and a fake msec clock drives the retry/watchdog timings, so no
## test here touches the network or sleeps.

const K := preload("res://tools/tests/fp_kit.gd")
const PackLoader := preload("res://scripts/ops/pack_loader.gd")
const WebPackStream := preload("res://scripts/ops/web_pack_stream.gd")

var fails: Array[String] = []


## Answers each pack per plan ("ok" arrives, "fail" fails, "hang" never finishes) and records
## the start order, without any HTTPRequest.
class FakeLoader:
	extends PackLoader
	var plan := {}
	var starts: Array[String] = []
	var pump_calls := 0

	func pump(host: Node) -> bool:
		pump_calls += 1
		return super.pump(host)

	func _start(_host: Node, pack: String) -> void:
		starts.append(pack)
		_loading[pack] = true
		_active = pack
		match str(plan.get(pack, "ok")):
			"ok":
				_mounted[pack] = true
				_finish(pack, true)
			"fail":
				_finish(pack, false, "fake")
			"hang":
				pass


func _init() -> void:
	await process_frame
	_test_activation_matrix()
	await _test_default_order_and_completion()
	await _test_demand_reprioritisation()
	await _test_retries_and_suppression()
	await _test_timeout_watchdog()
	await _test_flag_off_inert()
	FeatureFlags.set_override("web_split_packs", false)
	if fails.is_empty():
		print("WEB_PACK_STREAM_TEST: PASS")
	else:
		print("WEB_PACK_STREAM_TEST: FAIL ", fails)
	quit(0 if fails.is_empty() else 1)


func _manifest(packs: Array) -> Dictionary:
	var entries := {}
	for pack: String in packs:
		entries[pack] = {"file": "packs/%s-1.pck" % pack, "bytes": 1}
	return {
		"packs": entries,
		"rules":
		[
			["models/real/midlod/", "midlod"],
			["models/real/vehicles/", "traffic"],
			["env/", "sky"],
		],
	}


func _make(packs: Array, clock: Array, plan: Dictionary = {}) -> WebPackStream:
	var loader := FakeLoader.new()
	loader.plan = plan
	loader.set("_manifest", _manifest(packs))
	loader.set("_manifest_state", "ok")
	var stream := WebPackStream.new()
	stream.force_platform = "web"
	stream.setup(loader, func() -> int: return clock[0])
	get_root().add_child(stream)
	return stream


func _loader_of(stream: WebPackStream) -> FakeLoader:
	return stream.get("_loader") as FakeLoader


## activate() maps platform/flag/manifest state to one unambiguous answer.
func _test_activation_matrix() -> void:
	FeatureFlags.set_override("web_split_packs", true)
	var clock := [0]
	var on := _make(["midlod"], clock)
	K.check(fails, on.activate() == WebPackStream.ACTIVATE_OK, "flag+web+manifest: streaming")
	K.check(fails, on.activate() == WebPackStream.ACTIVATE_OK, "activate is idempotent")
	K.check(fails, on.snapshot()["packs"] == {"midlod": "queued"}, "activation queues the packs")
	on.queue_free()

	var desktop := _make(["midlod"], clock)
	desktop.force_platform = "desktop"
	K.check(fails, desktop.activate() == WebPackStream.ACTIVATE_NOT_WEB, "desktop never streams")
	desktop.queue_free()

	var unsplit := _make(["midlod"], clock)
	unsplit.get("_loader").set("_manifest", {})
	unsplit.get("_loader").set("_manifest_state", "none")
	K.check(
		fails, unsplit.activate() == WebPackStream.ACTIVATE_UNSPLIT, "no manifest: unsplit build"
	)
	unsplit.queue_free()

	var broken := _make(["midlod"], clock)
	broken.get("_loader").set("_manifest_state", "invalid")
	K.check(
		fails, broken.activate() == WebPackStream.ACTIVATE_BAD_MANIFEST, "bad manifest is an error"
	)
	broken.queue_free()

	FeatureFlags.set_override("web_split_packs", false)
	var flagged_off := _make(["midlod"], clock)
	K.check(
		fails,
		flagged_off.activate() == WebPackStream.ACTIVATE_FLAG_OFF,
		"flag off on a split build is the configuration error"
	)
	K.check(fails, flagged_off.loader_active(), "the build itself is still recognisably split")
	flagged_off.queue_free()
	FeatureFlags.set_override("web_split_packs", true)


## Manifest packs stream in the default order, unknown manifest packs last; arrivals report.
func _test_default_order_and_completion() -> void:
	var clock := [0]
	var stream := _make(["audio", "sky", "zzz", "midlod"], clock)
	var loader := _loader_of(stream)
	var ready: Array[String] = []
	var changes: Array = []
	stream.pack_ready.connect(func(pack: String) -> void: ready.append(pack))
	stream.state_changed.connect(func(snap: Dictionary) -> void: changes.append(snap))
	stream.activate()
	for _frame in range(8):
		await process_frame
	K.check(
		fails,
		loader.starts == ["midlod", "sky", "audio", "zzz"],
		"default order, unknown packs last: " + str(loader.starts)
	)
	K.check(fails, ready == loader.starts, "pack_ready follows the arrivals")
	var snap: Dictionary = stream.snapshot()
	K.check(fails, snap["complete"] and snap["mounted"] == 4 and snap["total"] == 4, "all done")
	K.check(fails, stream.mounted("midlod"), "mounted() reports arrival")
	K.check(fails, changes.size() >= 5, "state_changed follows the transitions")
	stream.queue_free()


## A consumer's miss moves the needed pack to the front, behind midlod's first request only.
func _test_demand_reprioritisation() -> void:
	var clock := [0]
	var stream := _make(["midlod", "sky", "traffic"], clock)
	var loader := _loader_of(stream)
	stream.activate()
	K.check(
		fails,
		stream.request_path("res://models/real/vehicles/van.glb") == "traffic",
		"a vehicle miss demands traffic"
	)
	K.check(fails, stream.request_path("res://env/sky.hdr") == "sky", "a sky miss demands sky")
	K.check(
		fails, stream.request_path("res://scripts/main.gd") == "", "a boot asset demands nothing"
	)
	for _frame in range(6):
		await process_frame
	K.check(
		fails,
		loader.starts == ["midlod", "traffic", "sky"],
		"demand jumps the queue but midlod leads: " + str(loader.starts)
	)
	stream.queue_free()


## Failure means backoff retries (2s, 8s), then 'failed'; demand cannot restart it; the HUD can.
func _test_retries_and_suppression() -> void:
	var clock := [0]
	var stream := _make(["midlod", "sky", "audio"], clock, {"sky": "fail"})
	var loader := _loader_of(stream)
	var failed: Array = []
	stream.pack_ready.connect(func(_p: String) -> void: pass)
	loader.pack_failed.connect(
		func(pack: String, reason: String) -> void: failed.append([pack, reason])
	)
	stream.activate()
	for _frame in range(4):
		await process_frame
	K.check(
		fails,
		loader.starts == ["midlod", "sky", "audio"],
		"a failed pack steps aside for the queue: " + str(loader.starts)
	)
	K.check(fails, stream.snapshot()["packs"]["sky"] == "retry_wait", "sky waits to retry")
	clock[0] += 1999
	await process_frame
	K.check(fails, loader.starts.count("sky") == 1, "no retry before the backoff elapses")
	clock[0] += 1
	await process_frame
	K.check(fails, loader.starts.count("sky") == 2, "first retry after 2s")
	clock[0] += 8000
	await process_frame
	K.check(fails, loader.starts.count("sky") == 3, "second retry after 8s")
	await process_frame
	K.check(fails, stream.snapshot()["packs"]["sky"] == "failed", "the budget is spent: failed")
	K.check(
		fails,
		failed == [["sky", "fake"], ["sky", "fake"], ["sky", "fake"]],
		"each attempt reported once"
	)
	var before := loader.starts.size()
	K.check(
		fails,
		stream.request_path("res://env/sky.hdr") == "sky" and loader.starts.size() == before,
		"a demand does not resurrect a failed pack"
	)
	loader.plan["sky"] = "ok"
	stream.retry_failed()
	await process_frame
	K.check(fails, loader.starts.count("sky") == 4, "the HUD retry runs one fresh cycle")
	K.check(fails, stream.snapshot()["packs"]["sky"] == "mounted", "the retried pack arrives")
	stream.queue_free()


## A transfer stuck past 60s is cancelled, reported, and retried like any failure.
func _test_timeout_watchdog() -> void:
	var clock := [0]
	var stream := _make(["midlod", "traffic"], clock, {"traffic": "hang"})
	var loader := _loader_of(stream)
	var failed: Array = []
	loader.pack_failed.connect(
		func(pack: String, reason: String) -> void: failed.append([pack, reason])
	)
	stream.activate()
	await process_frame
	await process_frame
	K.check(fails, loader.starts == ["midlod", "traffic"], "the hanging pack is underway")
	clock[0] += 59000
	await process_frame
	K.check(fails, failed.is_empty(), "no watchdog before 60s")
	clock[0] += 2000
	await process_frame
	K.check(fails, failed == [["traffic", "timeout"]], "the watchdog cancels at 60s")
	K.check(fails, stream.snapshot()["packs"]["traffic"] == "retry_wait", "a timeout retries")
	stream.queue_free()


## Flag off on a split build: no pumps, no demands, no work at all.
func _test_flag_off_inert() -> void:
	FeatureFlags.set_override("web_split_packs", false)
	var clock := [0]
	var stream := _make(["midlod", "sky"], clock)
	var loader := _loader_of(stream)
	stream.activate()
	for _frame in range(3):
		await process_frame
	K.check(fails, loader.pump_calls == 0, "flag off: the pump never runs")
	K.check(fails, stream.request_path("res://env/sky.hdr") == "", "flag off: no demands register")
	stream.queue_free()
