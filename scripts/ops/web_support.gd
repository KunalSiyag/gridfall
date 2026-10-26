class_name WebSupport
extends RefCounted
## Platform glue for the web build. Desktop answers the thread questions with a plain yes and the
## browser store stays empty, so every guard here is a no-op there (gate quick is unchanged).
## The store is a thin localStorage bridge: values never pass through Godot logs, and the only
## thing the game ever stores is the player's own GMI API key, after they tick "Remember" (see
## GmiClient.remember_player_key()).


## True when real threads can start (desktop platforms). The no-threads web build answers false,
## so its callers load synchronously instead. GRIDFALL_NO_THREADS=1 forces it off for tests.
static func threads_supported() -> bool:
	if OS.get_environment("GRIDFALL_NO_THREADS") == "1":
		return false
	return OS.has_feature("threads")


## True in the browser export.
static func is_web() -> bool:
	return OS.has_feature("web")


## localStorage value under name ("" off the web, when missing, or when the browser blocks it).
static func store_get(name: String) -> String:
	var v: Variant = _eval("localStorage.getItem(%s) ?? ''" % JSON.stringify(name))
	return str(v) if v != null else ""


## Writes value under name (no-op off the web).
static func store_set(name: String, value: String) -> void:
	_eval("localStorage.setItem(%s, %s)" % [JSON.stringify(name), JSON.stringify(value)])


## Removes name from the store (no-op off the web).
static func store_erase(name: String) -> void:
	_eval("localStorage.removeItem(%s)" % JSON.stringify(name))


## Evaluates js in the browser and returns its value; null off the web or when the browser errors.
static func _eval(js: String) -> Variant:
	if not is_web():
		return null
	return JavaScriptBridge.eval(js, true)
