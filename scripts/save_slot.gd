class_name SaveSlot
extends RefCounted
## One saved city on disk, written so a crash or a full disk mid-save never costs the player their
## city: the new save goes to <path>.tmp first, the previous one moves to <path>.bak, and only then
## does the new file take the slot's name. read() falls back to the backup when the slot is missing
## or unreadable (a crash between the two renames, or a truncated file).


## Writes data as JSON to path. OK, or the error that stopped it (the slot is then unchanged).
static func write(path: String, data: Dictionary) -> Error:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(data))
	f.flush()
	var err := f.get_error()
	f.close()
	if err != OK:
		DirAccess.remove_absolute(_abs(tmp))
		return err
	if FileAccess.file_exists(path):
		var bak := backup_path(path)
		if FileAccess.file_exists(bak):
			DirAccess.remove_absolute(_abs(bak))
		err = DirAccess.rename_absolute(_abs(path), _abs(bak))
		if err != OK:
			return err
	return DirAccess.rename_absolute(_abs(tmp), _abs(path))


## The saved city at path (or its backup), or {} when neither holds one.
static func read(path: String) -> Dictionary:
	for p: String in [path, backup_path(path)]:
		if not FileAccess.file_exists(p):
			continue
		# JSON.parse(), not parse_string(): a damaged slot is expected here, not an engine error.
		var json := JSON.new()
		if json.parse(FileAccess.get_file_as_string(p)) != OK:
			continue
		var parsed: Variant = json.data
		if (
			typeof(parsed) == TYPE_DICTIONARY
			and typeof((parsed as Dictionary).get("sim")) == TYPE_DICTIONARY
		):
			return parsed
	return {}


static func exists(path: String) -> bool:
	return FileAccess.file_exists(path) or FileAccess.file_exists(backup_path(path))


static func backup_path(path: String) -> String:
	return path + ".bak"


static func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path)
