extends FpFeature
## City sound on foot (slice I). Owns the Music, SFX, Ambience and UI buses while on foot, puts
## the AudioDirector's music under the street (set_fp), and runs three parts: positional emitters
## (engines, horns, sirens, construction, fire, fountains, plants, the river, passers-by's steps,
## the player's car crashing, the street props it knocks over and its doors, people hit in the
## street and the hero's swings),
## the area beds (with rain from G1's weather) and the hero's footsteps (splashing on wet paving),
## plus the chat blip and alert stingers. Pausing muffles the music (the only thing still
## playing); talking to someone ducks the beds.

const WS := preload("res://scripts/fp/world_scale.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")
const EMITTERS := preload("res://scripts/fp/audio/emitters.gd")
const AMBIENCE := preload("res://scripts/fp/audio/ambience.gd")
const FOOTSTEPS := preload("res://scripts/fp/audio/footsteps.gd")

const BUSES: Array[StringName] = [BANK.BUS_MUSIC, BANK.BUS_SFX, BANK.BUS_AMBIENCE, BANK.BUS_UI]
const MUSIC_CUTOFF_OPEN := 20000.0
const MUSIC_CUTOFF_PAUSED := 800.0
const MUFFLE_S := 0.25
const TALK_DUCK_DB := -6.0
const DUCK_RATE_DB := 12.0
const BLIP_GAP := 1.5
## The chat drips a line every 1.5-3 s, so ordinary lines share one quiet blip per this many s.
const CHATTER_GAP := 30.0
## System cards that blip softly; mayor and press posts blip softly with their role's pitch.
const SOFT_CARD_KINDS: Array[String] = ["alert", "incident"]
const POST_KINDS: Array[String] = ["post", "headline", "ruling"]
const STINGER_GAP := 4.0
## Street reflections on the SFX bus: wet level from open land to a dense downtown street.
const REVERB_WET_OPEN := 0.05
const REVERB_WET_URBAN := 0.15
const BLIP_PITCH := {"mayor": 0.94, "press": 1.06, "council": 0.9}

var emitters: EMITTERS
var ambience: AMBIENCE
var footsteps: FOOTSTEPS
var music_filter: AudioEffectLowPassFilter
var sfx_reverb: AudioEffectReverb
var blips_played: int = 0
## The last blip's tier: "reply", "card", "post" or "chatter" (tests).
var last_blip: String = ""
var stingers_played: int = 0
var duck_db: float = 0.0
var _created_buses: Array[StringName] = []
var _effects: Array = []               # [bus name, AudioEffect] added by this feature
var _ui: Array[AudioStreamPlayer] = []
var _ui_next: int = 0
var _now: float = 0.0
var _last_blip: float = -INF
var _last_chatter: float = -INF
var _player_seq: int = -1
var _last_stinger: float = -INF
var _duck_target: float = 0.0
var _sfx_db: float = 0.0
var _talking: Dictionary = {}
var _last_knock: float = -INF
var _falls: Array = []                 # [due on _now, feet] of people knocked down
var _rng := RandomNumberGenerator.new()
var _links: Array = []                 # [Signal, Callable]
var _muffle: Tween


func feature_id() -> String:
	return "audio"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	_rng.seed = 4421
	BANK.preload_all()
	_make_buses()
	emitters = EMITTERS.new()
	emitters.name = "Emitters"
	add_child(emitters)
	emitters.setup(ctx)
	ambience = AMBIENCE.new()
	ambience.name = "Ambience"
	add_child(ambience)
	ambience.setup(ctx)
	footsteps = FOOTSTEPS.new()
	footsteps.name = "Footsteps"
	add_child(footsteps)
	footsteps.setup(ctx)
	for k in range(2):
		var p := AudioStreamPlayer.new()
		p.name = "Ui%d" % k
		p.bus = BANK.BUS_UI
		add_child(p)
		_ui.append(p)
	_apply_settings(ctx.settings)
	if ctx.audio != null:
		ctx.audio.set_fp(true)
	var bus := ctx.bus
	if bus != null:
		_link(bus.chat_posted, _on_chat_posted)
		_link(bus.ping, _on_ping)
		_link(bus.toast, _on_toast)
		_link(bus.pause_changed, _on_pause_changed)
		_link(bus.settings_changed, _apply_settings)
		_link(bus.conversation_changed, _on_conversation_changed)
		_link(bus.player_tile_changed, _on_player_tile_changed)
		_link(bus.time_scale_changed, _on_time_scale_changed)
		_link(bus.car_impact, _on_car_impact)
		_link(bus.prop_knocked, _on_prop_knocked)
		_link(bus.car_door, _on_car_door)
		_link(bus.person_hit, _on_person_hit)
		_link(bus.hero_action, _on_hero_action)
	if ctx.sim != null:
		_link(ctx.sim.event_started, emitters.on_event)
		_link(ctx.sim.event_ended, emitters.on_event_ended)
		_link(ctx.sim.site_started, _on_site_started)
		_link(ctx.sim.site_finished, _on_site_finished)
	if ctx.view != null:
		_link(ctx.view.tile_built, _on_tile_built)
		_link(ctx.view.tile_cleared, emitters.clear_tile)
	if ctx.mode != null:
		emitters.time_scale = ctx.mode.time_scale
	_start_beds()


func on_world_rebuilt() -> void:
	emitters.rebuild_banks()
	emitters.full_scan()
	footsteps.bind(ctx.player)
	_start_beds()


func to_dict() -> Dictionary:
	return {}


## Volumes live in the settings; a load re-registers the world's sources (initial scan).
func from_dict(_d: Dictionary) -> void:
	emitters.full_scan()
	_falls.clear()
	_talking.clear()
	_duck_target = 0.0
	_player_seq = -1
	_start_beds()


func teardown() -> void:
	for l: Array in _links:
		var sig: Signal = l[0]
		var c: Callable = l[1]
		if sig.get_object() != null and is_instance_valid(sig.get_object()) and sig.is_connected(c):
			sig.disconnect(c)
	_links.clear()
	if _muffle != null:
		_muffle.kill()
		_muffle = null
	if ctx != null and ctx.audio != null and is_instance_valid(ctx.audio):
		ctx.audio.set_fp(false)
	_falls.clear()
	if emitters != null:
		emitters.clear()
	if ambience != null:
		ambience.stop_all()
	if footsteps != null:
		footsteps.unbind()
	for p in _ui:
		p.stop()
	_remove_buses()


## Buses exist, beds are playing (at most AMBIENCE.MAX_PLAYING) and every emitter uses
## WS.AUDIO_UNIT_SIZE.
func self_test() -> Dictionary:
	var bad: Array[String] = []
	for b in BUSES:
		if AudioServer.get_bus_index(b) < 0:
			bad.append("bus %s missing" % b)
	var beds := ambience.playing_count() if ambience != null else 0
	if beds < 1 or beds > AMBIENCE.MAX_PLAYING:
		bad.append("%d beds playing" % beds)
	for b in AMBIENCE.BED_NAMES:
		var p: AudioStreamPlayer = ambience.players[b]
		if p.playing and p.bus != BANK.BUS_AMBIENCE:
			bad.append("bed %s on bus %s" % [b, p.bus])
	var players := emitters.players() if emitters != null else []
	for p: AudioStreamPlayer3D in players:
		if not is_equal_approx(p.unit_size, WS.AUDIO_UNIT_SIZE) or p.doppler_tracking != AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED:
			bad.append("emitter %s unit_size %.2f" % [p.name, p.unit_size])
	if ctx.audio != null and not ctx.audio.is_fp():
		bad.append("director not on foot")
	var detail := "beds=%d (%s) emitters=%d/%d sources=%d steps=%s banks=%d" % [beds, ambience.loudest(),
		emitters.count_assigned(), players.size(), emitters.sources().size(), "signal" if not footsteps.polling else "poll", emitters.bank_count()]
	if not bad.is_empty():
		detail = ", ".join(bad) + " | " + detail
	return {"ok": bad.is_empty(), "detail": detail}


func _process(delta: float) -> void:
	step(delta)


## One frame of every part (tests call it with a fixed dt after set_process(false)).
func step(dt: float) -> void:
	_now += dt
	emitters.night = ambience.night
	while not _falls.is_empty() and float(_falls[0][0]) <= _now:
		var fall: Array = _falls.pop_front()
		emitters.shot("hit", fall[1], "body_fall", BANK.BODY_FALL_DB, _rng.randf_range(0.92, 1.04))
	emitters.step(dt)
	ambience.step(dt)
	footsteps.poll(dt)
	if duck_db != _duck_target:
		duck_db = move_toward(duck_db, _duck_target, DUCK_RATE_DB * dt)
		_set_bus_db(BANK.BUS_AMBIENCE, _sfx_db + duck_db)
	if sfx_reverb != null:
		var wet := lerpf(REVERB_WET_OPEN, REVERB_WET_URBAN, ambience.urban)
		sfx_reverb.wet = lerpf(sfx_reverb.wet, wet, minf(dt * 0.5, 1.0))


## Plays a UI cue on the UI bus (chat blip, stinger).
func play_ui(stream_name: String, volume_db: float, pitch: float = 1.0) -> void:
	var s := BANK.stream(stream_name)
	if s == null:
		return
	var p := _ui[_ui_next]
	_ui_next = (_ui_next + 1) % _ui.size()
	p.stream = s
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()


func _start_beds() -> void:
	ambience.recompute()
	ambience.step(0.0)


## A new chat line, while the panel is collapsed: the full blip for a reply to the player's own
## line, a soft one for alert and incident cards and for mayor and press posts, and one quiet blip
## per CHATTER_GAP for everything else (C drips a line every 1.5-3 s). At most one per BLIP_GAP.
func _on_chat_posted(msg: Dictionary) -> void:
	var role := str(msg.get("role", "resident"))
	if role == "player":
		_player_seq = int(msg.get("seq", -1))
		return
	if _chat_open() or _now - _last_blip < BLIP_GAP:
		return
	var kind := str(msg.get("kind", ""))
	var reply := int(msg.get("reply_to", -1))
	var tier := "chatter"
	if reply >= 0 and reply == _player_seq:
		tier = "reply"
	elif role == "system" and kind in SOFT_CARD_KINDS:
		tier = "card"
	elif kind in POST_KINDS:
		tier = "post"
	elif _now - _last_chatter < CHATTER_GAP:
		return
	_last_blip = _now
	if tier == "chatter":
		_last_chatter = _now
	blips_played += 1
	last_blip = tier
	match tier:
		"reply":
			play_ui("chat_blip", BANK.BLIP_DB)
		"card":
			play_ui("chat_blip_soft", BANK.BLIP_SOFT_DB)
		"post":
			play_ui("chat_blip_soft", BANK.BLIP_SOFT_DB, float(BLIP_PITCH.get(role, 1.0)))
		_:
			play_ui("chat_blip_soft", BANK.BLIP_CHATTER_DB)


func _on_ping(_p: Vector3, reason: String) -> void:
	if reason.begins_with("event:"):
		_stinger()


func _on_toast(_text: String, kind: String) -> void:
	if kind == "alert":
		_stinger()


func _stinger() -> void:
	if _now - _last_stinger < STINGER_GAP:
		return
	_last_stinger = _now
	stingers_played += 1
	play_ui("alert_stinger", BANK.STINGER_DB)


## True while C's chat panel is expanded (its own rows show the new line, so no blip).
func _chat_open() -> bool:
	var chat := ctx.feature("chat")
	if chat == null:
		return false
	var panel: Variant = chat.get("panel")
	if not (panel is Object) or not is_instance_valid(panel):
		return false
	var open: Variant = (panel as Object).get("is_open")
	return typeof(open) == TYPE_BOOL and bool(open)


func _on_pause_changed(paused: bool) -> void:
	if music_filter == null:
		return
	if _muffle != null:
		_muffle.kill()
	_muffle = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_muffle.tween_property(music_filter, "cutoff_hz", MUSIC_CUTOFF_PAUSED if paused else MUSIC_CUTOFF_OPEN, MUFFLE_S) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _on_conversation_changed(resident_id: String, active: bool) -> void:
	if active:
		_talking[resident_id] = true
	else:
		_talking.erase(resident_id)
	_duck_target = TALK_DUCK_DB if not _talking.is_empty() else 0.0


func _on_player_tile_changed(_x: int, _y: int) -> void:
	ambience.recompute()


func _on_time_scale_changed(s: int) -> void:
	emitters.time_scale = s


## The player's car hit a wall or a car (car_impact): a crash at the contact from BANK.CRASH_MPS
## of closing speed, a bump below, louder the harder it closes.
func _on_car_impact(at: Vector3, speed: float, _what: String) -> void:
	var mps := speed / WS.M
	var heavy := mps >= BANK.CRASH_MPS
	var full := BANK.CRASH_FULL_MPS if heavy else BANK.CRASH_MPS
	var s := "crash_heavy" if heavy else "crash_light"
	emitters.shot("crash", at, s, _impact_db(mps / full), _rng.randf_range(0.92, 1.05))


## A street prop knocked over or hit again (prop_knocked): its kind's clatter at the hit, at most
## one per BANK.KNOCK_GAP.
func _on_prop_knocked(at: Vector3, kind: String, speed: float) -> void:
	if _now - _last_knock < BANK.KNOCK_GAP:
		return
	_last_knock = _now
	var s := str(BANK.KNOCK_STREAMS.get(kind, BANK.KNOCK_DEFAULT))
	var trim := _impact_db(speed / WS.M / BANK.KNOCK_FULL_MPS)
	emitters.shot("knock", at, s, trim, _rng.randf_range(0.94, 1.06))


## The player's car door opening (its handle and latch, BANK.DOOR_OPEN_DB under the slam) or
## slamming shut (car_door), at the door.
func _on_car_door(at: Vector3, open: bool) -> void:
	var s := "car_door_open" if open else "car_door_close"
	var trim := BANK.DOOR_OPEN_DB if open else 0.0
	emitters.shot("door", at, s, trim, _rng.randf_range(0.96, 1.04))


## The level trim (dB) of a hit at share k of its full-level speed.
static func _impact_db(k: float) -> float:
	return linear_to_db(clampf(k, BANK.IMPACT_MIN_GAIN, 1.0))


## Someone hit in the street (person_hit): the blow's thump at their chest by its strength (a
## shove's duller, a car's lower and louder); someone knocked down lands BANK.BODY_FALL_S later.
func _on_person_hit(at: Vector3, cause: String, info: Dictionary) -> void:
	var car := cause == "car"
	var trim := _impact_db(float(info.get("strength", 0.5)) / BANK.HIT_FULL)
	var pitch := _rng.randf_range(0.92, 1.08) * (0.85 if cause == "shove" else 1.0)
	if car:
		trim += BANK.HIT_CAR_DB
		pitch = _rng.randf_range(0.72, 0.8)
	emitters.shot("hit", at + Vector3(0.0, 1.3 * WS.M, 0.0), "punch_hit", trim, pitch)
	if bool(info.get("down", false)):
		_falls.append([_now + BANK.BODY_FALL_S, at])


## The hero's swing (hero_action): a whoosh at their shoulder, a jab's higher, a shove's lower and
## softer. Emotes make no sound here.
func _on_hero_action(action: String, at: Vector3) -> void:
	if action not in ["jab", "cross", "shove"]:
		return
	var shove := action == "shove"
	var trim := BANK.WHOOSH_DB + (BANK.SHOVE_DB if shove else 0.0)
	var pitch := 0.8 if shove else (1.1 if action == "jab" else 0.95)
	var p := at + Vector3(0.0, 1.4 * WS.M, 0.0)
	emitters.shot("hit", p, "punch_whoosh", trim, pitch * _rng.randf_range(0.96, 1.04))


func _on_site_started(site: Dictionary) -> void:
	emitters.add_site(int(site["i"]))


func _on_site_finished(site: Dictionary) -> void:
	emitters.remove_site(int(site["i"]))


func _on_tile_built(i: int, holder: Node3D) -> void:
	if ctx.view.in_setup:
		return
	emitters.scan_tile(i, holder)


func _apply_settings(s: Dictionary) -> void:
	_sfx_db = float(s.get("sfx_volume_db", 0.0))
	_set_bus_db(BANK.BUS_MUSIC, float(s.get("music_volume_db", 0.0)))
	_set_bus_db(BANK.BUS_SFX, _sfx_db)
	_set_bus_db(BANK.BUS_AMBIENCE, _sfx_db + duck_db)


func _set_bus_db(bus_name: StringName, v: float) -> void:
	var i := AudioServer.get_bus_index(bus_name)
	if i >= 0:
		AudioServer.set_bus_volume_db(i, v)


func _link(sig: Signal, c: Callable) -> void:
	if not sig.is_connected(c):
		sig.connect(c)
		_links.append([sig, c])


func _make_buses() -> void:
	for b in BUSES:
		if AudioServer.get_bus_index(b) >= 0:
			continue
		AudioServer.add_bus()
		var i := AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, b)
		AudioServer.set_bus_send(i, &"Master")
		_created_buses.append(b)
	music_filter = AudioEffectLowPassFilter.new()
	music_filter.cutoff_hz = MUSIC_CUTOFF_OPEN
	_add_effect(BANK.BUS_MUSIC, music_filter)
	sfx_reverb = AudioEffectReverb.new()
	sfx_reverb.room_size = 0.5
	sfx_reverb.damping = 0.6
	sfx_reverb.spread = 0.9
	sfx_reverb.hipass = 0.25
	sfx_reverb.predelay_msec = 25.0
	sfx_reverb.predelay_feedback = 0.2
	sfx_reverb.dry = 1.0
	sfx_reverb.wet = REVERB_WET_OPEN
	_add_effect(BANK.BUS_SFX, sfx_reverb)
	var lim := AudioEffectHardLimiter.new()
	lim.ceiling_db = -1.0
	_add_effect(BANK.BUS_SFX, lim)


func _add_effect(bus_name: StringName, e: AudioEffect) -> void:
	var i := AudioServer.get_bus_index(bus_name)
	if i < 0:
		return
	AudioServer.add_bus_effect(i, e)
	_effects.append([bus_name, e])


func _remove_buses() -> void:
	for pair: Array in _effects:
		var i := AudioServer.get_bus_index(pair[0])
		if i < 0:
			continue
		for k in range(AudioServer.get_bus_effect_count(i) - 1, -1, -1):
			if AudioServer.get_bus_effect(i, k) == pair[1]:
				AudioServer.remove_bus_effect(i, k)
	_effects.clear()
	var idx: Array[int] = []
	for b in _created_buses:
		var i := AudioServer.get_bus_index(b)
		if i > 0:
			idx.append(i)
	idx.sort()
	idx.reverse()
	for i in idx:
		AudioServer.remove_bus(i)
	_created_buses.clear()
	music_filter = null
	sfx_reverb = null
