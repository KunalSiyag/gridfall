extends Logger
## Counts the errors the engine reports during the soak, by kind and by site. The headless dummy
## renderer raises a burst of C++ "Parameter ... is null" errors whenever a pedestrian model loads
## (they come and go with the content, not with the game's logic), so the soak does not cap the
## total: it fails on any script error and on any one site repeating, which is what a real bug
## (a bus whose stop index outlived its line raised one error per frame) looks like.

## Errors by kind: {"script": n, "engine": n, "shader": n}.
var kinds: Dictionary = {"script": 0, "engine": 0, "shader": 0}
## Errors by site ("file:line"): {site: count}.
var sites: Dictionary = {}
## The first script error's text, for the failure line.
var first_script: String = ""


func _log_error(
	_function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	_editor_notify: bool,
	error_type: int,
	_backtraces: Array[ScriptBacktrace]
) -> void:
	if error_type == ERROR_TYPE_WARNING:
		return
	var kind := "engine"
	if error_type == ERROR_TYPE_SCRIPT:
		kind = "script"
		if first_script.is_empty():
			first_script = ("%s:%d %s %s" % [file, line, code, rationale]).strip_edges().left(200)
	elif error_type == ERROR_TYPE_SHADER:
		kind = "shader"
	kinds[kind] = int(kinds[kind]) + 1
	var site := "%s:%d" % [file, line]
	sites[site] = int(sites.get(site, 0)) + 1


## The most any one site repeated, and which.
func worst_site() -> Array:
	var worst := ""
	var most := 0
	for site: String in sites:
		if int(sites[site]) > most:
			most = int(sites[site])
			worst = site
	return [worst, most]
