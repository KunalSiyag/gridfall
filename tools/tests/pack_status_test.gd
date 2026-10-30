extends SceneTree
## Pack status line (Phase B step 4): invisible on unsplit builds and once every pack is
## mounted; counts while packs download; a failure shows Retry, which re-queues the failed
## packs; a HUD built after the failure (mode switch) resynchronises from the snapshot.

const K := preload("res://tools/tests/fp_kit.gd")
const WebPackStream := preload("res://scripts/ops/web_pack_stream.gd")
const PackStatus := preload("res://scripts/ui/pack_status.gd")

var fails: Array[String] = []


class FakeStream:
	extends WebPackStream
	var snap := {"packs": {}, "active": "", "mounted": 0, "total": 0, "complete": true}
	var retries := 0

	func snapshot() -> Dictionary:
		return snap

	func retry_failed() -> void:
		retries += 1

	func push(s: Dictionary) -> void:
		snap = s
		state_changed.emit(s)


func _init() -> void:
	var stream := FakeStream.new()
	var ps: PackStatus = PackStatus.new()
	get_root().add_child(ps)
	ps.setup(stream)

	# Unsplit build / everything mounted: invisible (the normal case).
	K.check(fails, not ps.visible, "complete stream: hidden")

	# Downloading: shown with a count, no Retry.
	(
		stream
		. push(
			{
				"packs": {"midlod": "mounted", "sky": "downloading"},
				"active": "sky",
				"mounted": 2,
				"total": 8,
				"complete": false,
			}
		)
	)
	K.check(fails, ps.visible, "downloading: shown")
	K.check(fails, ps.status_text() == "Loading city detail · 2/8 packs", "downloading: count text")
	K.check(fails, not ps.has_retry(), "downloading: no retry")

	# Failed: message and Retry; pressing it re-queues the failed packs.
	stream.push(
		{"packs": {"audio": "failed"}, "active": "", "mounted": 7, "total": 8, "complete": true}
	)
	K.check(fails, ps.visible, "failed: shown")
	K.check(fails, ps.status_text() == "Some city detail is unavailable", "failed: message")
	K.check(fails, ps.has_retry(), "failed: retry shown")
	ps.press_retry()
	K.check(fails, stream.retries == 1, "failed: retry re-queues")

	# Retry running, then all mounted: back to counting, then hidden.
	(
		stream
		. push(
			{
				"packs": {"audio": "downloading"},
				"active": "audio",
				"mounted": 7,
				"total": 8,
				"complete": false,
			}
		)
	)
	K.check(fails, ps.visible and not ps.has_retry(), "retrying: counts, no button")
	stream.push(
		{"packs": {"audio": "mounted"}, "active": "", "mounted": 8, "total": 8, "complete": true}
	)
	K.check(fails, not ps.visible, "all mounted: hidden")

	# Mode switch resync: a HUD built after a failure shows it immediately.
	stream.snap = {
		"packs": {"audio": "failed"}, "active": "", "mounted": 7, "total": 8, "complete": true
	}
	var late: PackStatus = PackStatus.new()
	get_root().add_child(late)
	late.setup(stream)
	K.check(fails, late.visible, "resync: failure visible on a late HUD")
	K.check(fails, late.status_text() == "Some city detail is unavailable", "resync: message")
	late.free()

	K.finish(self, "PACK_STATUS_TEST", fails)
