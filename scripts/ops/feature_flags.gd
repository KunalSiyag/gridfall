class_name FeatureFlags
extends RefCounted
## Feature flags. Defaults and descriptions live in res://data/feature_flags.json; overrides come
## from user://feature_flags.json ({"name": bool}, skipped when GRIDFALL_FLAGS_IGNORE_USER=1) and
## then from GRIDFALL_FLAGS ("overview=0,analytics=1"). First-person features are flagged by their
## registry id (FpMode skips a disabled one); unknown names fall back to the caller's default.

const DEFAULTS_PATH := "res://data/feature_flags.json"
const USER_PATH := "user://feature_flags.json"
const TRUE_WORDS := ["1", "true", "on", "yes"]
const FALSE_WORDS := ["0", "false", "off", "no"]

static var _values: Dictionary = {}
static var _loaded: bool = false


## Whether flag is on. default is used for a name no layer defines.
static func enabled(flag: String, default: bool = true) -> bool:
	if not _loaded:
		reload()
	return bool(_values.get(flag, default))


## Re-reads every layer from the environment and disk.
static func reload() -> void:
	load_layers(OS.get_environment("GRIDFALL_FLAGS"), OS.get_environment("GRIDFALL_FLAGS_IGNORE_USER") != "1")


## Builds the flag table from the JSON defaults, the user file (when use_user) and env_spec.
static func load_layers(env_spec: String, use_user: bool) -> void:
	_values = defaults()
	if use_user:
		_values.merge(read_user(USER_PATH), true)
	_values.merge(parse_overrides(env_spec), true)
	_loaded = true


## Sets one flag for this process (tests, debug consoles).
static func set_override(flag: String, on: bool) -> void:
	if not _loaded:
		reload()
	_values[flag] = on


## {name: default} from res://data/feature_flags.json.
static func defaults() -> Dictionary:
	var out := {}
	var spec := describe()
	for k: String in spec.keys():
		out[k] = bool((spec[k] as Dictionary).get("default", true))
	return out


## {name: {"default": bool, "description": String}} from res://data/feature_flags.json.
static func describe() -> Dictionary:
	if not FileAccess.file_exists(DEFAULTS_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DEFAULTS_PATH))
	if typeof(parsed) != TYPE_DICTIONARY or typeof((parsed as Dictionary).get("flags")) != TYPE_DICTIONARY:
		return {}
	var out := {}
	var flags: Dictionary = (parsed as Dictionary)["flags"]
	for k: String in flags.keys():
		if typeof(flags[k]) == TYPE_DICTIONARY:
			out[k] = flags[k]
	return out


## The current value of every known flag.
static func snapshot() -> Dictionary:
	if not _loaded:
		reload()
	return _values.duplicate()


## {name: bool} from a user override file: {"name": bool|0|1} or {"flags": {...}}.
static func read_user(path: String) -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(path):
		return out
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return out
	var d: Dictionary = parsed
	if typeof(d.get("flags")) == TYPE_DICTIONARY:
		d = d["flags"]
	for k: Variant in d.keys():
		var v: Variant = d[k]
		if typeof(v) == TYPE_BOOL:
			out[str(k)] = v
		elif typeof(v) in [TYPE_INT, TYPE_FLOAT]:
			out[str(k)] = float(v) != 0.0
		elif typeof(v) == TYPE_STRING and _word(str(v)) >= 0:
			out[str(k)] = _word(str(v)) == 1
	return out


## Parses "a=0,b=1,c,!d" into {"a": false, "b": true, "c": true, "d": false}; bad items are skipped.
static func parse_overrides(spec: String) -> Dictionary:
	var out := {}
	for raw: String in spec.split(",", false):
		var item := raw.strip_edges()
		if item.is_empty():
			continue
		var eq := item.find("=")
		if eq < 0:
			if item.begins_with("!") or item.begins_with("-"):
				var n := item.substr(1).strip_edges()
				if not n.is_empty():
					out[n] = false
			else:
				out[item] = true
			continue
		var key := item.left(eq).strip_edges()
		var w := _word(item.substr(eq + 1))
		if key.is_empty() or w < 0:
			continue
		out[key] = w == 1
	return out


## 1 for a true word, 0 for a false word, -1 otherwise.
static func _word(s: String) -> int:
	var v := s.strip_edges().to_lower()
	if v in TRUE_WORDS:
		return 1
	if v in FALSE_WORDS:
		return 0
	return -1
