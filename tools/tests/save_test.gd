extends SceneTree
## SaveSlot: atomic writes (tmp then rename), the previous save kept as .bak, and reads that fall
## back to the backup when the slot is missing or damaged, or when the caller refuses the file
## (a well-formed save the game would not load must not hide the good backup behind it).

const K := preload("res://tools/tests/fp_kit.gd")
const PATH := "user://save_test_slot.json"

var fails: Array[String] = []


func _init() -> void:
	_clean()
	K.check(
		fails,
		SaveSlot.read(PATH).is_empty() and not SaveSlot.exists(PATH),
		"no slot: read() is empty, exists() false"
	)
	K.check(fails, SaveSlot.write(PATH, {"sim": {"day": 1}}) == OK, "first write")
	K.check(
		fails,
		(
			_day(SaveSlot.read(PATH)) == 1
			and not FileAccess.file_exists(PATH + ".tmp")
			and not FileAccess.file_exists(SaveSlot.backup_path(PATH))
		),
		"first write: the slot reads back, no tmp or backup left"
	)
	K.check(fails, SaveSlot.write(PATH, {"sim": {"day": 2}}) == OK, "second write")
	var bak: Variant = JSON.parse_string(FileAccess.get_file_as_string(SaveSlot.backup_path(PATH)))
	K.check(
		fails,
		_day(SaveSlot.read(PATH)) == 2 and typeof(bak) == TYPE_DICTIONARY and _day(bak) == 1,
		"second write: the slot holds day 2, the backup day 1"
	)
	# A save cut short (crash or full disk while writing) leaves a truncated file.
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string('{"sim": {"day": 3, "ki')
	f.close()
	K.check(fails, _day(SaveSlot.read(PATH)) == 1, "a truncated slot falls back to the backup")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	K.check(
		fails,
		SaveSlot.exists(PATH) and _day(SaveSlot.read(PATH)) == 1,
		"a missing slot (crash between the renames) falls back to the backup"
	)
	K.check(
		fails,
		SaveSlot.write(PATH, {"sim": {"day": 4}}) == OK and _day(SaveSlot.read(PATH)) == 4,
		"writing again after that restores the slot"
	)
	var g := FileAccess.open(PATH, FileAccess.WRITE)
	g.store_string("[1, 2]")
	g.close()
	K.check(
		fails,
		_day(SaveSlot.read(PATH)) == 1,
		"valid JSON without a sim section is not a save (the backup still is)"
	)
	_check_accept()
	K.check(
		fails,
		SaveSlot.write("user://no_such_dir/slot.json", {"sim": {}}) != OK,
		"a write that cannot open its file reports the error"
	)
	_clean()
	K.finish(self, "SAVE_TEST", fails)


## read(path, accept): a file accept refuses is skipped like an unreadable one, so the backup is
## offered; with no accept, or one that takes everything, nothing changes.
func _check_accept() -> void:
	_clean()
	SaveSlot.write(PATH, {"sim": {"day": 6}})
	SaveSlot.write(PATH, {"sim": {"day": 7}})
	var old_enough := func(d: Dictionary) -> bool: return _day(d) <= 6
	var any := func(_d: Dictionary) -> bool: return true
	var none := func(_d: Dictionary) -> bool: return false
	K.check(fails, _day(SaveSlot.read(PATH)) == 7, "accept: without one the slot is read as before")
	K.check(
		fails,
		_day(SaveSlot.read(PATH, any)) == 7,
		"accept: one that takes everything reads the slot"
	)
	K.check(
		fails,
		_day(SaveSlot.read(PATH, old_enough)) == 6,
		"accept: a slot it refuses (day 7) falls back to the backup (day 6)"
	)
	K.check(
		fails,
		SaveSlot.read(PATH, none).is_empty() and SaveSlot.exists(PATH),
		"accept: when it refuses the slot and the backup there is no save, though the files exist"
	)
	_clean()


static func _day(d: Variant) -> int:
	if typeof(d) != TYPE_DICTIONARY:
		return -1
	return int(((d as Dictionary).get("sim", {}) as Dictionary).get("day", -1))


func _clean() -> void:
	for p: String in [PATH, PATH + ".tmp", SaveSlot.backup_path(PATH)]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
