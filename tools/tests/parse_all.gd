extends SceneTree
## Compiles every GDScript under res://scripts and res://tools; the cheapest gate against slices
## breaking each other's class_name references. Prints PARSE_ALL: PASS|FAIL and quits 0/1.


func _walk(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		if sub.begins_with(".") or sub == "__pycache__":
			continue
		_walk(dir.path_join(sub), out)


func _init() -> void:
	var files: Array = []
	_walk("res://scripts", files)
	_walk("res://tools", files)
	var bad: Array = []
	var t0 := Time.get_ticks_msec()
	# Reloading the running script with CACHE_MODE_IGNORE swaps the bytecode under the executing
	# _init (an internal VM error); it compiled already, since it is running.
	var me: String = (get_script() as Script).resource_path
	for p: String in files:
		if p == me:
			continue
		var s := ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
		if s == null or not s.can_instantiate():
			bad.append(p)
	if bad.is_empty():
		print("PARSE_ALL: PASS %d scripts in %d ms" % [files.size(), Time.get_ticks_msec() - t0])
	else:
		print("PARSE_ALL: FAIL %d failed: %s" % [bad.size(), str(bad)])
	quit(0 if bad.is_empty() else 1)
