class_name OpsSink
extends RefCounted
## Local JSON-lines files for the opt-in ops features (errors, analytics, alerts). Each record is
## scrubbed (Redact) before it is written; a file past max_bytes rotates to <name>.1.jsonl, so a
## stream never takes more than about twice its cap. Thread-safe (the error tracker writes from
## whatever thread raised the error).

const MAX_BYTES := 1_000_000
## Output directory; tests point it at a scratch folder.
static var dir: String = "user://ops"
static var _mutex: Mutex = Mutex.new()


static func path_of(file_name: String) -> String:
	return dir.path_join(file_name)


## Appends rec as one scrubbed JSON line to dir/file_name. False when the file cannot be written.
static func append(file_name: String, rec: Dictionary, max_bytes: int = MAX_BYTES) -> bool:
	var line := Redact.scrub(JSON.stringify(rec))
	_mutex.lock()
	var ok := _append_locked(path_of(file_name), line, max_bytes)
	_mutex.unlock()
	return ok


## Every parsed record of dir/file_name (the live file only), oldest first.
static func read_all(file_name: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var path := path_of(file_name)
	if not FileAccess.file_exists(path):
		return out
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var parsed: Variant = JSON.parse_string(line)
		if typeof(parsed) == TYPE_DICTIONARY:
			out.append(parsed)
	return out


static func _append_locked(path: String, line: String, max_bytes: int) -> bool:
	var abs_dir := ProjectSettings.globalize_path(path.get_base_dir())
	if not DirAccess.dir_exists_absolute(abs_dir) and DirAccess.make_dir_recursive_absolute(abs_dir) != OK:
		return false
	var f: FileAccess = null
	if FileAccess.file_exists(path):
		f = FileAccess.open(path, FileAccess.READ_WRITE)
		if f != null and f.get_length() + line.length() > max_bytes:
			f.close()
			f = null
			var rotated := path.get_basename() + ".1." + path.get_extension()
			var abs_rot := ProjectSettings.globalize_path(rotated)
			if FileAccess.file_exists(rotated):
				DirAccess.remove_absolute(abs_rot)
			DirAccess.rename_absolute(ProjectSettings.globalize_path(path), abs_rot)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.seek_end()
	f.store_line(line)
	f.close()
	return true
