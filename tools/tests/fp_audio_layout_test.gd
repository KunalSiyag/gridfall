extends SceneTree
## Web audio (unit A1): the four buses come from the project's default bus layout, so the audio
## feature never calls AudioServer.add_bus at runtime (on the web build that call leaves the Master
## output disconnected from the AudioContext and the whole game plays silently), plus the loader
## veil rules for the long beds and stems and the AUDIOSEC section log.

const K := preload("res://tools/tests/fp_kit.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")
const AMB := preload("res://scripts/fp/audio/ambience.gd")
const DIRECTOR := "res://scripts/audio_director.gd"
const LAYOUT := "res://default_bus_layout.tres"

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_layout_is_default()
	var count_before := AudioServer.bus_count
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "audio": true})
	var f: FpFeature = K.make_feature(ctx, "audio")
	f.set_process(false)
	_check_no_runtime_bus(f, count_before)
	_check_reentry_adopts(ctx, count_before)
	_check_beds_one_per_step(ctx)
	_check_beds_hold_during_boot(ctx)
	await _check_stems_after_veil()
	_check_section_log(f)
	K.finish(self, "FP_AUDIO_LAYOUT_TEST", fails)


## A fresh process, no feature yet: the project setting names the layout and the buses are there.
func _check_layout_is_default() -> void:
	var named := str(ProjectSettings.get_setting("audio/buses/default_bus_layout", ""))
	K.check(fails, named == LAYOUT, "project.godot names %s (%s)" % [LAYOUT, named])
	var layout := load(LAYOUT) as AudioBusLayout
	K.check(fails, layout != null, "the layout resource loads")
	for b: StringName in [BANK.BUS_MUSIC, BANK.BUS_SFX, BANK.BUS_AMBIENCE, BANK.BUS_UI]:
		var i := AudioServer.get_bus_index(b)
		K.check(
			fails,
			i > 0 and AudioServer.get_bus_send(i) == &"Master",
			"bus %s exists before any feature, sends to Master" % b
		)
	var mi := AudioServer.get_bus_index(BANK.BUS_MUSIC)
	var si := AudioServer.get_bus_index(BANK.BUS_SFX)
	K.check(fails, _count(mi, AudioEffectLowPassFilter) == 1, "layout: one low-pass on Music")
	K.check(
		fails,
		_count(si, AudioEffectReverb) == 1 and _count(si, AudioEffectHardLimiter) == 1,
		"layout: one reverb and one limiter on SFX"
	)
	for b: int in [mi, si]:
		for k in range(AudioServer.get_bus_effect_count(b)):
			K.check(
				fails,
				AudioServer.is_bus_effect_enabled(b, k),
				"layout: effect %d on %s is enabled" % [k, AudioServer.get_bus_name(b)]
			)
	for k in range(AudioServer.get_bus_effect_count(si)):
		var rv := AudioServer.get_bus_effect(si, k) as AudioEffectReverb
		if rv != null:
			K.check(fails, rv.wet > 0.0, "layout: the SFX reverb is wet (%.2f)" % rv.wet)


func _count(bus: int, what: Variant) -> int:
	var n := 0
	for k in range(AudioServer.get_bus_effect_count(bus)):
		if is_instance_of(AudioServer.get_bus_effect(bus, k), what):
			n += 1
	return n


## Setting the feature up adds no bus and no effect: it adopts the layout's.
func _check_no_runtime_bus(f: FpFeature, count_before: int) -> void:
	K.check(
		fails,
		AudioServer.bus_count == count_before,
		"setup adds no bus (%d -> %d)" % [count_before, AudioServer.bus_count]
	)
	var si := AudioServer.get_bus_index(BANK.BUS_SFX)
	var mi := AudioServer.get_bus_index(BANK.BUS_MUSIC)
	K.check(
		fails,
		(
			_count(mi, AudioEffectLowPassFilter) == 1
			and _count(si, AudioEffectReverb) == 1
			and _count(si, AudioEffectHardLimiter) == 1
		),
		"setup adds no second effect"
	)
	var lp: AudioEffectLowPassFilter = f.get("music_filter")
	var rv: AudioEffectReverb = f.get("sfx_reverb")
	K.check(
		fails,
		lp == AudioServer.get_bus_effect(mi, 0) and rv == AudioServer.get_bus_effect(si, 0),
		"the feature holds the layout's own effects"
	)
	K.check(
		fails,
		(
			is_equal_approx(rv.room_size, 0.5)
			and is_equal_approx(rv.hipass, 0.25)
			and is_equal_approx(rv.predelay_msec, 25.0)
		),
		"the reverb keeps its street settings"
	)


## A second feature instance (entering first person again) still adds nothing.
func _check_reentry_adopts(ctx: FpContext, count_before: int) -> void:
	var f2 := load("res://scripts/fp/audio/audio_feature.gd").new() as FpFeature
	f2.name = "audio_again"
	f2.set_process(false)
	ctx.world_root.get_parent().get_node("Features").add_child(f2)
	f2.setup(ctx)
	K.check(fails, AudioServer.bus_count == count_before, "a second setup adds no bus")
	var si := AudioServer.get_bus_index(BANK.BUS_SFX)
	K.check(
		fails,
		_count(si, AudioEffectReverb) == 1 and _count(si, AudioEffectHardLimiter) == 1,
		"a second setup stacks no effect"
	)
	f2.teardown()
	f2.queue_free()


func _ambience(ctx: FpContext) -> Node:
	var amb := AMB.new()
	amb.name = "AmbCheck"
	root.add_child(amb)
	amb.setup(ctx)
	# Every bed wants to play.
	for b in AMB.BED_NAMES:
		amb.weights[b] = 1.0
	return amb


## Without the web boot running a step starts at most one bed (the first play() of a long stream
## decodes and registers all of it).
func _check_beds_one_per_step(ctx: FpContext) -> void:
	BootClock._state = 0
	var amb := _ambience(ctx)
	amb.set("_t", -100.0)  # no recompute: keep the weights above
	var seen: Array[int] = []
	for _k in range(4):
		amb.step(1.0 / 60.0)
		seen.append(amb.playing_count())
	K.check(fails, seen == [1, 2, 3, 4], "beds start one per step: %s" % str(seen))
	amb.stop_all()
	amb.queue_free()


## While the web boot is behind the loader veil nothing starts; HOLD_MAX_S of it lets the beds go.
func _check_beds_hold_during_boot(ctx: FpContext) -> void:
	BootClock._state = 1
	BootClock._done = false
	var amb := _ambience(ctx)
	amb.set("_t", -100.0)
	for _k in range(30):
		amb.step(0.1)
	K.check(
		fails,
		amb.playing_count() == 0,
		"no bed starts during the boot (%d playing after 3 s)" % amb.playing_count()
	)
	BootClock._done = true  # the veil lifted
	amb.step(0.1)
	K.check(
		fails,
		amb.playing_count() == 1,
		"after the veil the first bed starts (%d)" % amb.playing_count()
	)
	amb.stop_all()
	amb.queue_free()
	# A boot that never finishes: the hold ends by itself.
	BootClock._done = false
	var amb2 := _ambience(ctx)
	amb2.set("_t", -100.0)
	for _k in range(int(AMB.HOLD_MAX_S / 0.5) + 2):
		amb2.step(0.5)
	K.check(
		fails,
		amb2.playing_count() >= 1,
		"a boot that never finishes does not keep the city silent (%d)" % amb2.playing_count()
	)
	amb2.stop_all()
	amb2.queue_free()
	BootClock._state = 0
	BootClock._done = false


func _check_stems_after_veil() -> void:
	BootClock._state = 1
	BootClock._done = false
	var d := load(DIRECTOR).new() as Node
	root.add_child(d)
	await process_frame
	var nom: AudioStreamPlayer = d.get("_nominal_player")
	var cri: AudioStreamPlayer = d.get("_crisis_player")
	K.check(
		fails,
		nom.stream != null and not nom.playing and not cri.playing,
		"stems: nothing plays while the boot runs"
	)
	BootClock._done = true
	d._process(0.016)
	var first := int(nom.playing) + int(cri.playing)
	d._process(0.016)
	var second := int(nom.playing) + int(cri.playing)
	d._process(0.016)
	K.check(
		fails,
		first == 1 and second == 2 and not bool(d.get("_stems_pending")),
		"stems start one per frame after the veil (%d then %d)" % [first, second]
	)
	d.queue_free()
	BootClock._state = 0
	BootClock._done = false
	# Off the web (no boot clock) the stems start in _ready, as before.
	var d2 := load(DIRECTOR).new() as Node
	root.add_child(d2)
	await process_frame
	K.check(
		fails,
		(
			(d2.get("_nominal_player") as AudioStreamPlayer).playing
			and (d2.get("_crisis_player") as AudioStreamPlayer).playing
		),
		"stems: both start in _ready without a boot clock"
	)
	d2.queue_free()


func _check_section_log(f: FpFeature) -> void:
	FirstUse.reset()
	FirstUse.force = true
	FirstUse._on = 1
	var logged: Array = f.get("sections_logged")
	logged.clear()
	for _k in range(int(f.SECTION_LOG_S * 60.0) + 5):
		f.call("step", 1.0 / 60.0)
	var line := str(logged[0]) if not logged.is_empty() else ""
	var parsed: Variant = (
		JSON.parse_string(line.trim_prefix("AUDIOSEC ")) if line.begins_with("AUDIOSEC ") else null
	)
	var ms: Dictionary = parsed["ms"] if parsed is Dictionary and parsed.has("ms") else {}
	K.check(
		fails,
		(
			logged.size() >= 1
			and ms.has("emitters")
			and ms.has("ambience")
			and ms.has("footsteps")
			and ms.has("falls")
		),
		"AUDIOSEC line carries every section: %s" % line
	)
	FirstUse.force = false
	FirstUse.reset()
	var before := logged.size()
	for _k in range(int(f.SECTION_LOG_S * 60.0) + 5):
		f.call("step", 1.0 / 60.0)
	K.check(fails, logged.size() == before, "AUDIOSEC stays silent off the web")
