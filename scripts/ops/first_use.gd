class_name FirstUse
extends RefCounted
## First-use marks and stopwatches for the web build: the game half of the hitch-attribution kit
## (docs/runbooks/web-probe-kit.md). Off unless this is the web build AND the web_first_use_marks
## flag is on (default off), so a shipped build carries a few untaken branches and nothing else.
## Everything stays in the player's own browser: one console line per event,
##   FIRSTUSE {"tag":"play:rain.ogg","n":1,"ms":2.31,"len":30.0}
## and a User Timing mark "gf:<tag>" whose detail is the same record. tools/web_fps_probe.js reads
## both next to its WebGL census, which says which mark linked a shader or uploaded a texture.
## Tags are fixed literals, stream file names or, for a stream that has no path (the looping
## duplicate of the residential bed), its class and length: never player or model text.

## Records logged per tag; a repeat past this is counted and not logged.
const MAX_PER_TAG := 3
## Kinds that log more: a save every game day matters at day 10, not only the first three.
const CAPS := {"save": 100}
## Prefix of the User Timing marks.
const PREFIX := "gf:"
## Records kept in lines.
const MAX_LINES := 400

## Tests set this to run the web path on the desktop (JavaScriptBridge is then a no-op).
static var force: bool = false
## Every record logged so far as JSON text, oldest first (tests read it).
static var lines: Array[String] = []
static var _on: int = -1
static var _seen: Dictionary = {}


## True on the web build with the web_first_use_marks flag on; decided once per process.
static func active() -> bool:
	if _on < 0:
		var web := force or WebSupport.is_web()
		_on = 1 if web and FeatureFlags.enabled("web_first_use_marks", false) else 0
	return _on == 1


## Forgets the decision and every count (tests).
static func reset() -> void:
	_on = -1
	_seen.clear()
	lines.clear()


## A point event: the thing is on screen for the first time (or again). Logs the first
## MAX_PER_TAG of a tag.
static func mark(tag: String) -> void:
	if not active():
		return
	var n := int(_seen.get("m:" + tag, 0)) + 1
	_seen["m:" + tag] = n
	if n <= MAX_PER_TAG:
		_emit({"tag": tag, "n": n})


## Starts a stopwatch on kind and what (a name, or a Resource: its file name, or class and length
## for a stream that has no path). Returns the stamp for end(), or -1 when nothing needs timing:
## off, or timed often enough already. A stream's first play() is the reading that matters, so the
## cap leaves the later ones out.
static func begin(kind: String, what: Variant = "") -> int:
	if not active():
		return -1
	if int(_seen.get("t:" + _tag(kind, what), 0)) >= int(CAPS.get(kind, MAX_PER_TAG)):
		return -1
	return Time.get_ticks_usec()


## Stops the stopwatch begin() started: logs the elapsed milliseconds (and the length in seconds
## when what is an AudioStream, so a reading can be put per second of audio). start_us -1 is a
## no-op.
static func end(kind: String, what: Variant, start_us: int) -> void:
	if start_us < 0:
		return
	var ms := float(Time.get_ticks_usec() - start_us) / 1000.0
	var tag := _tag(kind, what)
	var n := int(_seen.get("t:" + tag, 0)) + 1
	_seen["t:" + tag] = n
	var rec := {"tag": tag, "n": n, "ms": snappedf(ms, 0.001)}
	if what is AudioStream:
		rec["len"] = snappedf((what as AudioStream).get_length(), 0.001)
	_emit(rec)


## The console line of a record.
static func line_of(rec: Dictionary) -> String:
	return "FIRSTUSE " + _json(rec)


## The JavaScript that records rec as the User Timing mark gf:<tag>, rec being its detail.
static func mark_js(rec: Dictionary) -> String:
	return (
		"try{performance.mark(%s,{detail:%s})}catch(e){}"
		% [JSON.stringify(PREFIX + str(rec["tag"])), _json(rec)]
	)


## rec as JSON in its own key order (tag first), which reads better in a console than the default
## alphabetical one.
static func _json(rec: Dictionary) -> String:
	return JSON.stringify(rec, "", false)


static func _tag(kind: String, what: Variant) -> String:
	var named := ""
	if what is Resource:
		named = (what as Resource).resource_path.get_file()
		if named.is_empty() and what is AudioStream:
			var kind_of := (what as AudioStream).get_class().trim_prefix("AudioStream")
			named = "%s@%.2fs" % [kind_of, (what as AudioStream).get_length()]
	elif what != null:
		named = str(what)
	return kind if named.is_empty() else kind + ":" + named


static func _emit(rec: Dictionary) -> void:
	print(line_of(rec))
	JavaScriptBridge.eval(mark_js(rec), true)
	if lines.size() < MAX_LINES:
		lines.append(_json(rec))
