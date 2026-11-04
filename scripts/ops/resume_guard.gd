class_name ResumeGuard
extends Node
## Web only: tells the game when the browser tab is hidden or shown again (the page's
## visibilitychange event). A tab left in the background is how most web sessions end: the page is
## closed from there, and a closed tab never reaches the quit autosave. The guard emits `hidden`
## once when the tab goes to the background (Main autosaves then, under the morning autosave's
## minimum gap) and `shown` when it comes back. The frame after a long hidden spell is the other
## half of the problem; Pacing.frame_dt bounds what the world integrates from it.
##
## Desktop builds have no such event: _ready installs nothing there. on_visibility() is the one
## entry point (the browser callback calls it), so a test can drive both states.

signal hidden
signal shown

## Ignore a second hidden event this soon after the last one (a flickering tab).
const MIN_REPEAT_MS := 2000

var is_hidden: bool = false
var _last_hidden_ms: int = -MIN_REPEAT_MS
var _callback: JavaScriptObject = null


func _ready() -> void:
	if not WebSupport.is_web():
		return
	var document: Variant = JavaScriptBridge.get_interface("document")
	if document == null:
		return
	_callback = JavaScriptBridge.create_callback(_on_js_event)
	document.addEventListener("visibilitychange", _callback)


## The page's visibility is now state ("hidden" or "visible"). Emits hidden / shown on a change.
func on_visibility(state: String, now_ms: int = -1) -> void:
	var now := now_ms if now_ms >= 0 else Time.get_ticks_msec()
	if state == "hidden":
		if is_hidden or now - _last_hidden_ms < MIN_REPEAT_MS:
			return
		is_hidden = true
		_last_hidden_ms = now
		hidden.emit()
	elif is_hidden:
		is_hidden = false
		shown.emit()


func _on_js_event(_args: Array) -> void:
	var document: Variant = JavaScriptBridge.get_interface("document")
	if document != null:
		on_visibility(str(document.visibilityState))
