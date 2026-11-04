class_name WebSupport
extends RefCounted
## Platform glue for the web build. Desktop answers the thread questions with a plain yes and the
## browser store stays empty, so every guard here is a no-op there (gate quick is unchanged).
## The store is a thin localStorage bridge: values never pass through Godot logs, and the only
## thing the game ever stores is the player's own GMI API key, after they tick "Remember" (see
## GmiClient.remember_player_key()).


## True when real threads can start (desktop platforms and the
## threaded web build). A no-threads web build answers false,
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


## Adds "label" to the page's User Timing timeline (DevTools, performance.getEntriesByType("mark")).
## No-op off the web. The expression returns nothing, so no JavaScriptObject wrapper is built.
static func perf_mark(label: String) -> void:
	_eval("void performance.mark(%s)" % JSON.stringify(label))


## performance.now() in ms (the page's clock, not the engine's); -1 off the web or when the
## browser errors (a page whose Content-Security-Policy forbids eval: BootClock then stops asking).
static func perf_now() -> float:
	var v: Variant = _eval("performance.now()")
	return float(v) if v != null else -1.0


## Tells the loader page the game is interactive so it can lift its boot veil (BootClock.finish):
## window.gfBootDone(). It goes through the bridge's object interface, not eval, so a page whose
## Content-Security-Policy forbids eval (no 'unsafe-eval') still gets the call instead of keeping
## the veil for the whole page timeout. A page without the hook leaves nothing behind (its own
## timeout releases the veil, 30 s after startGame() resolved), and so does a hook that throws.
## No-op off the web.
static func boot_done() -> void:
	if not is_web():
		return
	var window: Variant = JavaScriptBridge.get_interface("window")
	if window != null and window.gfBootDone != null:
		window.gfBootDone()


## Shows text in the loader's status line while the game prepares behind the veil
## (window.gfBootStatus, set by the export's loader page; "" puts the page's own wording back). Same
## route as boot_done(): the bridge's object interface, no eval. No-op off the web, and on a page
## without the hook.
static func boot_status(text: String) -> void:
	if not is_web():
		return
	var window: Variant = JavaScriptBridge.get_interface("window")
	if window != null and window.gfBootStatus != null:
		window.gfBootStatus(text)


## True while the loader's veil is still up (window.gfVeilUp, defined by the export's loader page).
## Off the web and on a page without the hook it is true: nothing says the veil is gone.
static func veil_up() -> bool:
	if not is_web():
		return true
	var window: Variant = JavaScriptBridge.get_interface("window")
	if window == null or window.gfVeilUp == null:
		return true
	return bool(window.gfVeilUp())


## Evaluates js in the browser and returns its value; null off the web or when the browser errors.
static func _eval(js: String) -> Variant:
	if not is_web():
		return null
	return JavaScriptBridge.eval(js, true)
