extends RefCounted
## Fixtures shared by fp_keyflow_test.gd and fp_keyflow_panel_test.gd (the player's key path to
## GMI): a GmiClient whose transport is a script, a 300-character key and the leak oracle.

## The shortest piece of a key that leaks() counts as a leak.
const FRAGMENT := 8


## A GmiClient whose transport answers from a script and records every call it is handed.
class FakeKeyNet:
	extends GmiClient
	var posts: int = 0
	var seen: Array[Dictionary] = []
	var reply: Dictionary = {}
	var delay_frames: int = 0
	var remembered: Array[String] = []
	## The copy this device "keeps" (the browser store, which a desktop run has no copy of).
	var saved := ""

	func remember_player_key(key: String) -> void:
		remembered.append(key)

	func has_remembered_key(key: String = "") -> bool:
		return not saved.is_empty() and (key.is_empty() or saved == key)

	func _post(
		model: String, _system: String, _user: String, max_tokens: int, timeout_s: float
	) -> Dictionary:
		posts += 1
		(
			seen
			. append(
				{
					"model": model,
					"max_tokens": max_tokens,
					"timeout": timeout_s,
					"rid": _hdr_request_id,
					"tid": _hdr_trace_id,
				}
			)
		)
		for _i in range(delay_frames):
			await get_tree().process_frame
		return reply.duplicate()


## A key that is long (300 characters, md5 text after "gmi_") or, with letters_only, a run of
## letters that no md5 text can contain.
static func long_key(letters_only: bool = false) -> String:
	if letters_only:
		return "gmi_" + "qrstuvwxyz".repeat(30)
	var key := "gmi_"
	var i := 0
	while key.length() < 300:
		key += ("keyflow%d" % i).md5_text()
		i += 1
	return key.left(300)


## True when text holds the key or any run of FRAGMENT characters of it, wherever in the key the run
## starts: a bad cut, a debugging print or a half-masked echo leaks a prefix or a middle, not the
## whole key. Eight characters is far more than any chance match in a status or log line.
static func leaks(text: String, key: String) -> bool:
	if text.contains(key):
		return true
	for i in range(key.length() - FRAGMENT + 1):
		if text.contains(key.substr(i, FRAGMENT)):
			return true
	return false


## A FakeKeyNet under root, with key (when not empty) as the player's key.
static func client(root: Node, key: String = "") -> FakeKeyNet:
	var c := FakeKeyNet.new()
	c.name = "FakeKeyNet"
	root.add_child(c)
	if not key.is_empty():
		c.set_player_key(key)
	return c
