extends RefCounted
## The coach card's pure rules (feature "coach_card"): what the welcome card says, what the context
## hints say and when each shows. No nodes; the feature and the tests share it.

## Settings keys (FpMode.DEFAULT_SETTINGS): the welcome card is done for good once coach_seen is
## set; coach_hints lists the ladder hints already shown, comma separated.
const SEEN_KEY := "coach_seen"
const HINTS_KEY := "coach_hints"
## Real seconds the welcome card stays up if the player does nothing.
const CARD_SECONDS := 15.0
## Real seconds a ladder hint stays up.
const HINT_SECONDS := 6.0
## Seconds without any input at 1x before the speed hint.
const IDLE_SECONDS := 60.0
## A resident this near (metres) earns the talk hint.
const TALK_METRES := 3.0
## The welcome card: [key, what it does], in reading order.
const KEYS := [
	["WASD", "walk"],
	["Shift", "run"],
	["Tab", "city overview"],
	["J", "AI feed"],
	["E", "talk"],
	["Enter", "chat"],
	["Esc", "menu"],
]
## Actions that end the welcome card early: the three it names, and the other first things a
## player does (chat, the menu).
const DISMISS_ACTIONS := ["ai_feed", "overview_toggle", "interact", "chat_open", "pause_menu"]
## The ladder, each shown at most once: id -> parts, [kind ("key" or "text"), text] in order.
const HINTS := {
	"feed": [["key", "J"], ["text", "reads it"]],
	"talk": [["key", "E"], ["text", "to talk"]],
	"speed": [["key", "]"], ["text", "speeds time up"]],
	## What the overview offers on a first visit (Space only pauses in the Planner view itself).
	"tab": [["text", "Planner view button:"], ["text", "the full city builder"]],
}
const CAPTURE_TEXT := "Click to look around"
## Environment switches of the scripted runs (smokes, photo tours, benchmarks, the trailer): their
## screenshots and timings stay as recorded, so the coach shows nothing in them.
const TOOL_ENV := [
	"GRIDFALL_FP_SMOKE",
	"GRIDFALL_FP_PHOTO_DIR",
	"FPBENCH_DIR",
	"GRIDFALL_SMOKE_TEST",
	"GRIDFALL_PHOTO_DIR",
	"GRIDFALL_CINEMATIC",
]


## True in a scripted tool run (see TOOL_ENV).
static func tool_run() -> bool:
	for k: String in TOOL_ENV:
		if OS.has_environment(k):
			return true
	return false


## The welcome card as one line ("WASD walk - Shift run - ...").
static func card_text() -> String:
	var parts := PackedStringArray()
	for e: Array in KEYS:
		parts.append("%s %s" % [e[0], e[1]])
	return " - ".join(parts)


## A ladder hint as one line ("J reads it").
static func hint_text(id: String) -> String:
	var parts := PackedStringArray()
	for p: Array in HINTS.get(id, []):
		parts.append(str(p[1]))
	return " ".join(parts)


## Whether the "Click to look around" pill shows: the pointer is free, on a build with a pointer
## (not headless), with no pause or modal UI that wants it free.
static func should_show_capture_hint(
	mouse_mode: int, paused: bool, modal: bool, headless: bool
) -> bool:
	return not headless and not paused and not modal and mouse_mode != Input.MOUSE_MODE_CAPTURED


## The hints already shown, from the saved settings string.
static func shown_hints(csv: String) -> PackedStringArray:
	var out := PackedStringArray()
	for h: String in csv.split(",", false):
		out.append(h.strip_edges())
	return out


## csv with id added (once).
static func with_hint(csv: String, id: String) -> String:
	var l := shown_hints(csv)
	if not l.has(id):
		l.append(id)
	return ",".join(l)


## Whether event is a player's input (a key, button or pad press, or a mouse move), for the idle
## timer. Releases and echoes do not count.
static func is_player_input(event: InputEvent) -> bool:
	if event is InputEventMouseMotion:
		return (event as InputEventMouseMotion).relative != Vector2.ZERO
	if event is InputEventKey or event is InputEventMouseButton or event is InputEventJoypadButton:
		return event.is_pressed() and not event.is_echo()
	if event is InputEventJoypadMotion:
		return absf((event as InputEventJoypadMotion).axis_value) > 0.4
	return event is InputEventAction and event.is_pressed()
