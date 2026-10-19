class_name ErrorTracker
extends Logger
## Contextual error tracking, registered with OS.add_logger(). Always counts errors and warnings in
## memory (OpsAlerts reads errors_in_last()); with file output on (GRIDFALL_ERROR_LOG=1 or the
## "error_tracking" flag) it also appends one JSON line per error to user://ops/errors.jsonl:
## fingerprint, scrubbed message, source location, build, session, game context, the last
## breadcrumbs and the script backtrace. Godot may call a Logger from any thread, so everything
## here goes through _mutex and nothing touches the scene tree; the main thread feeds context with
## set_context().

const FILE := "errors.jsonl"
const MAX_BREADCRUMBS := 20
## Further repeats of one fingerprint are only counted, so a per-frame error cannot fill the disk.
const MAX_PER_FINGERPRINT := 25
const MAX_TIMES := 256
const TYPE_NAMES := ["error", "warning", "script", "shader"]

static var _mutex: Mutex = Mutex.new()
static var _instance: ErrorTracker = null
static var _file_on: bool = false
static var _build: String = ""
static var _context: Dictionary = {}
static var _crumbs: Array[String] = []
static var _error_ms: Array[int] = []
static var _seen: Dictionary = {}
static var _counts: Dictionary = {"error": 0, "warning": 0}
## Thread ids currently inside capture(), so an error raised while writing is not re-captured.
static var _busy: Dictionary = {}


## Registers the logger once (main thread). file_output defaults to file_wanted().
static func install(file_output: bool = file_wanted()) -> void:
	_mutex.lock()
	_file_on = file_output
	_build = _build_string()
	var fresh := _instance == null
	if fresh:
		_instance = ErrorTracker.new()
	_mutex.unlock()
	if fresh:
		OS.add_logger(_instance)


static func uninstall() -> void:
	_mutex.lock()
	var inst := _instance
	_instance = null
	_mutex.unlock()
	if inst != null:
		OS.remove_logger(inst)


static func installed() -> bool:
	return _instance != null


## GRIDFALL_ERROR_LOG=1 or the "error_tracking" flag.
static func file_wanted() -> bool:
	return OS.get_environment("GRIDFALL_ERROR_LOG") == "1" or FeatureFlags.enabled("error_tracking", false)


static func set_file_output(on: bool) -> void:
	_mutex.lock()
	_file_on = on
	if _build.is_empty():
		_build = _build_string()
	_mutex.unlock()


## True when errors are written to disk.
static func recording() -> bool:
	return _file_on


## Records a short "what just happened" line attached to the next errors (kept only while recording).
static func breadcrumb(text: String) -> void:
	if not _file_on:
		return
	_mutex.lock()
	_crumbs.append("%s %s" % [Time.get_time_string_from_system(), text.left(160)])
	while _crumbs.size() > MAX_BREADCRUMBS:
		_crumbs.pop_front()
	_mutex.unlock()


## Merges patch (view mode, sim day and tick, ...) into the context attached to each error.
static func set_context(patch: Dictionary) -> void:
	_mutex.lock()
	_context.merge(patch, true)
	_mutex.unlock()


## Errors (not warnings) captured in the last window_ms.
static func errors_in_last(window_ms: int, now_ms: int = -1) -> int:
	var now := now_ms if now_ms >= 0 else Time.get_ticks_msec()
	var n := 0
	_mutex.lock()
	for t: int in _error_ms:
		if now - t <= window_ms:
			n += 1
	_mutex.unlock()
	return n


## {"error": n, "warning": n} since start (or reset()).
static func counts() -> Dictionary:
	_mutex.lock()
	var c := _counts.duplicate()
	_mutex.unlock()
	return c


## Clears counters, breadcrumbs, context and the per-fingerprint caps (tests).
static func reset() -> void:
	_mutex.lock()
	_crumbs.clear()
	_error_ms.clear()
	_seen.clear()
	_context.clear()
	_counts = {"error": 0, "warning": 0}
	_mutex.unlock()


## Stable 16-hex id of an error site: file, line and the error code text.
static func fingerprint(file: String, line: int, code: String) -> String:
	return ("%s:%d:%s" % [file, line, code]).sha256_text().left(16)


## Counts one error and, when recording, writes it. Returns the written record ({} when only
## counted). _log_error forwards here; tests call it directly.
static func capture(function: String, file: String, line: int, code: String, rationale: String,
		error_type: int, backtraces: Array = []) -> Dictionary:
	var tid := OS.get_thread_caller_id()
	var kind: String = TYPE_NAMES[error_type] if error_type >= 0 and error_type < TYPE_NAMES.size() else "error"
	var is_warning := error_type == ERROR_TYPE_WARNING
	_mutex.lock()
	if _busy.has(tid):
		_mutex.unlock()
		return {}
	var now := Time.get_ticks_msec()
	if is_warning:
		_counts["warning"] = int(_counts["warning"]) + 1
	else:
		_counts["error"] = int(_counts["error"]) + 1
		_error_ms.append(now)
		if _error_ms.size() > MAX_TIMES:
			_error_ms.pop_front()
	var fp := fingerprint(file, line, code)
	var seen := int(_seen.get(fp, 0)) + 1
	_seen[fp] = seen
	if not _file_on or seen > MAX_PER_FINGERPRINT:
		_mutex.unlock()
		return {}
	_busy[tid] = true
	var rec := {
		"fingerprint": fp,
		"type": kind,
		"message": Redact.scrub(("%s %s" % [code, rationale]).strip_edges()).left(1000),
		"function": function,
		"file": file,
		"line": line,
		"ts": Time.get_unix_time_from_system(),
		"time": Time.get_datetime_string_from_system(true),
		"ticks_ms": now,
		"occurrence": seen,
		"build": _build,
		"session": Trace.session_id(),
		"trace_id": Trace.current(),
		"context": _context.duplicate(true),
		"breadcrumbs": _crumbs.duplicate(),
		"backtrace": _backtrace_text(backtraces),
	}
	_mutex.unlock()
	OpsSink.append(FILE, rec)
	_mutex.lock()
	_busy.erase(tid)
	_mutex.unlock()
	return rec


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	capture(function, file, line, code, rationale, error_type, script_backtraces)


static func _backtrace_text(backtraces: Array) -> String:
	var parts: PackedStringArray = []
	for bt: Variant in backtraces:
		if bt is ScriptBacktrace and not (bt as ScriptBacktrace).is_empty():
			parts.append((bt as ScriptBacktrace).format(0, 2))
	return Redact.scrub("\n".join(parts)).left(4000)


static func _build_string() -> String:
	var v := str(ProjectSettings.get_setting("application/config/version", ""))
	return "%s godot-%s %s" % [v if not v.is_empty() else "dev", Engine.get_version_info().get("string", ""), OS.get_name()]
