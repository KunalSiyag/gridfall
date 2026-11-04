class_name BootClock
extends RefCounted
## Boot stage stopwatch. mark(stage) closes a stage: it records Time.get_ticks_usec() and, in the
## browser, a performance.mark("gf:<stage>") for the DevTools timeline. finish() waits for the
## first interactive frame plus VEIL_FRAMES rendered ones, prints one `GF_BOOT {json}` line and
## `GRIDFALL: boot complete` (the console only, nothing leaves the machine), then tells the loader
## page to lift its veil (WebSupport.boot_done()). Harnesses wait for the boot-complete line.
## Off the web every call is a no-op unless GRIDFALL_BOOT_CLOCK=1 (tests, desktop captures), and
## once the boot has completed they are no-ops again, so marks inside code that runs on every
## rebuild cost nothing later in a session. A stage marked again gets #2, #3 (a continued city
## restores every feature a second time), so the report's names are unique.

const ENV := "GRIDFALL_BOOT_CLOCK"
## Frames rendered after the first interactive one before the veil lifts, so whatever one-off work
## the first frames do (shader compiles and links, first uploads) happens behind the loader. The
## report marks each of them (frame_2, frame_3, veil_frames) to show whether three are enough.
const VEIL_FRAMES := 3
const COMPLETE_LINE := "GRIDFALL: boot complete"
const REPORT_PREFIX := "GF_BOOT "
const REPORT_VERSION := 1
## Marks kept at most (a boot makes about 115). A boot that stops before finish() (an error that
## aborts Main._ready) would otherwise keep recording FpMode's later rebuilds for the session.
const MAX_MARKS := 512

## -1 not decided yet, 0 off, 1 on.
static var _state := -1
static var _done := false
static var _finishing := false
static var _names := PackedStringArray()
static var _stamps := PackedInt64Array()
## Stage name -> how many times it was marked, for the stages marked more than once.
static var _repeats := {}
static var _page_start := -1.0
static var _page_end := -1.0
## False when the first page clock read failed (off the web, or a page whose Content-Security-Policy
## forbids eval): the later marks then make no browser calls instead of one console error each.
static var _page_ok := false


## Whether marks are being recorded: the web build, or GRIDFALL_BOOT_CLOCK=1; false once finished.
static func enabled() -> bool:
	if _state < 0:
		_state = 1 if WebSupport.is_web() or OS.get_environment(ENV) == "1" else 0
	return _state == 1 and not _done


## True once finish() has printed the report.
static func completed() -> bool:
	return _done


## Records that the stage called stage just ended.
static func mark(stage: String) -> void:
	if not enabled() or _names.size() >= MAX_MARKS:
		return
	if _names.is_empty():
		_page_start = WebSupport.perf_now()
		_page_ok = _page_start >= 0.0
	var label := _unique(stage)
	_names.append(label)
	_stamps.append(Time.get_ticks_usec())
	if _page_ok:
		WebSupport.perf_mark("gf:" + label)


## stage, or stage#2, stage#3 ... when an earlier mark already has that name.
static func _unique(stage: String) -> String:
	if not _names.has(stage):
		return stage
	var count := int(_repeats.get(stage, 1)) + 1
	_repeats[stage] = count
	return "%s#%d" % [stage, count]


## mark("<stage>:<id>"), for the per-feature loops; the name is only built when marks are on.
static func mark_for(stage: String, id: String) -> void:
	if enabled():
		mark(stage + ":" + id)


## The stage names recorded so far, in order.
static func names() -> PackedStringArray:
	return _names


## Call once at the end of the main scene's _ready. Marks "ready_end", then follows the frames after
## it: "pre_draw" (the first frame's draw begins: the rest of that main-loop iteration lies between
## ready_end and here), "first_frame" (that draw is done, so the draw's own cost is the step from
## pre_draw), "frame_2" and "frame_3", and "veil_frames" (VEIL_FRAMES frames after the first one).
## Then it reports. A headless run draws nothing, so it counts process frames and has no pre_draw.
## before_veil, when valid, is awaited right after the first frame, still behind the veil (Main
## passes the shader warm-up, ShaderWarmup.run, which marks warmup_begin and warmup_end).
static func finish(tree: SceneTree, before_veil: Callable = Callable()) -> void:
	if not enabled() or _finishing:
		return
	_finishing = true
	mark("ready_end")
	var headless := DisplayServer.get_name() == "headless"
	for i in range(1 + VEIL_FRAMES):
		if headless:
			await tree.process_frame
		else:
			if i == 0:
				await RenderingServer.frame_pre_draw
				mark("pre_draw")
			await RenderingServer.frame_post_draw
		if i == 0:
			mark("first_frame")
			if before_veil.is_valid():
				await before_veil.call()
		elif i < VEIL_FRAMES:
			mark("frame_%d" % (i + 1))
	mark("veil_frames")
	_page_end = WebSupport.perf_now() if _page_ok else -1.0
	_done = true
	print(report_line())
	print(COMPLETE_LINE)
	WebSupport.boot_done()


## The report as a dictionary: format version, build facts, the engine's uptime at the first mark
## (what Main.setup and the first scene load cost before _ready), the page clock (performance.now(),
## -1 off the web) at the first mark and at the end, ms from the first mark to the last, and every
## mark as [stage, ms since the first mark]. The delta from one mark to the next is the cost of
## the stage the later one names.
static func report() -> Dictionary:
	var first := _stamps[0] if not _stamps.is_empty() else 0
	var marks: Array = []
	for i in _names.size():
		marks.append([_names[i], snappedf(float(_stamps[i] - first) / 1000.0, 0.1)])
	var last := _stamps[-1] if not _stamps.is_empty() else 0
	return {
		"v": REPORT_VERSION,
		"web": WebSupport.is_web(),
		"threads": WebSupport.threads_supported(),
		"engine_ms": snappedf(float(first) / 1000.0, 0.1),
		"page_start_ms": snappedf(_page_start, 0.1),
		"page_end_ms": snappedf(_page_end, 0.1),
		"total_ms": snappedf(float(last - first) / 1000.0, 0.1),
		"marks": marks,
	}


## The one console line finish() prints: REPORT_PREFIX plus report() as JSON, keys in the order
## report() builds them.
static func report_line() -> String:
	return REPORT_PREFIX + JSON.stringify(report(), "", false)


## Forgets every mark and re-reads GRIDFALL_BOOT_CLOCK (tests).
static func reset() -> void:
	_state = -1
	_done = false
	_finishing = false
	_names = PackedStringArray()
	_stamps = PackedInt64Array()
	_repeats = {}
	_page_start = -1.0
	_page_end = -1.0
	_page_ok = false
