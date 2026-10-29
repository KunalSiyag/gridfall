extends FpFeature
## City sound on foot (slice I). Creates the Music, SFX, Ambience and UI buses the first time the
## hero goes on foot and keeps them for the rest of the session: a bus is never removed while the
## game runs, so no player can be left pointing at a bus that is gone (on the web build a sample
## on a missing bus throws in the mixer). Puts the AudioDirector's music under the street (set_fp)
## and runs three parts: positional emitters
## (engines, horns, sirens, construction, fire, fountains, plants, the river, passers-by's steps,
## the player's car crashing, the street props it knocks over and its doors, people hit in the
## street, the hero's swings, rolls and the blows they take (a blow's thump panning toward where
## it came from in first person, hit_direction), dogs barking, growling, whining and
## yelping, pigeons, cats, and the hero's kicks and swings landing on them), the area beds (with
## rain from G1's weather) and the hero's footsteps (splashing on wet paving), plus the chat blip
## and alert stingers. Pausing muffles the music (the only thing still playing); talking to someone
## ducks the beds.

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
## The health a blow on the hero takes (hero_hurt) to sound at full level, by cause.
const HERO_HIT_FULL := {"punch": 12.0, "car": 60.0, "bite": 7.5}
## How far off the hero's head (m) a punch's thump pans toward where the blow came from
## (hero_hit_dir; hit_direction, first person) — about a fist's reach.
const DIR_THUMP_M := 0.9
## The pitch of each swing's whoosh (hero_action).
const SWING_PITCH := {
	"jab": 1.1,
	"cross": 0.95,
	"hook": 0.85,
	"kick": 0.75,
	"shove": 0.8,
	"swing": 0.7,
	"counter": 0.85,
	"throw": 0.75,
	"slam": 0.7,
}
## The sound of a weapon's blow (weapon_hit) by its kind, and how much quieter on a street prop.
const WEAPON_SOUNDS := {"bat": "bat_hit", "pipe": "pipe_hit", "bottle": "bottle_smash"}
const WEAPON_PROP_DB := -4.0

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
## The way the blow behind the next hero_hurt came from (hero_hit_dir): a screen angle — 0 ahead,
## +PI/2 from the right — pending until that hurt's thump reads it (health emits the two
## back to back, the direction first).
var _hit_dir := 0.0
var _hit_dir_pending := false
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
var _falls: Array = []  # [due on _now, feet, dB] of bodies hitting the ground
var _rng := RandomNumberGenerator.new()
var _links: Array = []  # [Signal, Callable]
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
	emitters.prof = self
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
		_link(bus.hero_slammed, _on_hero_slammed)
		_link(bus.weapon_hit, _on_weapon_hit)
		_link(bus.hero_hurt, _on_hero_hurt)
		_link(bus.hero_hit_dir, _on_hero_hit_dir)
		_link(bus.animal_called, _on_animal_called)
		_link(bus.animal_hit, _on_animal_hit)
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
	# The buses stay: every player is stopped or routed back to an orbit bus, and a kept bus
	# can never resolve to index -1 for a sample the mixer is still finishing (the web crash).


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
		if (
			not is_equal_approx(p.unit_size, WS.AUDIO_UNIT_SIZE)
			or p.doppler_tracking != AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		):
			bad.append("emitter %s unit_size %.2f" % [p.name, p.unit_size])
	if ctx.audio != null and not ctx.audio.is_fp():
		bad.append("director not on foot")
	var detail := (
		"beds=%d (%s) emitters=%d/%d sources=%d steps=%s banks=%d"
		% [
			beds,
			ambience.loudest(),
			emitters.count_assigned(),
			players.size(),
			emitters.sources().size(),
			"signal" if not footsteps.polling else "poll",
			emitters.bank_count()
		]
	)
	if not bad.is_empty():
		detail = ", ".join(bad) + " | " + detail
	return {"ok": bad.is_empty(), "detail": detail}


## Largest per-frame microsecond cost of each step section since the last reset (fp_bench reads
## it and resets between measures).
var section_us_max := {}


func reset_section_stats() -> void:
	section_us_max.clear()


func _section(name: String, t0: int) -> int:
	var now := Time.get_ticks_usec()
	var us := now - t0
	if us > int(section_us_max.get(name, -1)):
		section_us_max[name] = us
	return now


func _process(delta: float) -> void:
	step(delta)


## One frame of every part (tests call it with a fixed dt after set_process(false)).
func step(dt: float) -> void:
	_now += dt
	emitters.night = ambience.night
	var t := Time.get_ticks_usec()
	while not _falls.is_empty() and float(_falls[0][0]) <= _now:
		var fall: Array = _falls.pop_front()
		emitters.shot("hit", fall[1], "body_fall", float(fall[2]), _rng.randf_range(0.92, 1.04))
	t = _section("falls", t)
	emitters.step(dt)
	t = _section("emitters", t)
	ambience.step(dt)
	t = _section("ambience", t)
	footsteps.poll(dt)
	t = _section("footsteps", t)
	if duck_db != _duck_target:
		duck_db = move_toward(duck_db, _duck_target, DUCK_RATE_DB * dt)
		_set_bus_db(BANK.BUS_AMBIENCE, _sfx_db + duck_db)
	if sfx_reverb != null:
		var wet := lerpf(REVERB_WET_OPEN, REVERB_WET_URBAN, ambience.urban)
		sfx_reverb.wet = lerpf(sfx_reverb.wet, wet, minf(dt * 0.5, 1.0))
	_section("duck_reverb", t)


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
	(
		_muffle
		. tween_property(
			music_filter,
			"cutoff_hz",
			MUSIC_CUTOFF_PAUSED if paused else MUSIC_CUTOFF_OPEN,
			MUFFLE_S
		)
		. set_trans(Tween.TRANS_SINE)
		. set_ease(Tween.EASE_OUT)
	)


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


## A weapon's blow (weapon_hit): the wood's knock, the pipe's ring or the bottle breaking, at the
## chest of whoever it hit (lower and quieter on a street prop or an animal).
func _on_weapon_hit(at: Vector3, kind: String, what: String, _broke: bool) -> void:
	if not WEAPON_SOUNDS.has(kind):
		return
	var person := what == "person"
	var p := at + Vector3(0.0, (1.2 if person else 0.4) * WS.M, 0.0)
	var trim := 0.0 if person else WEAPON_PROP_DB
	emitters.shot("hit", p, str(WEAPON_SOUNDS[kind]), trim, _rng.randf_range(0.95, 1.05))


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
		_queue_fall(BANK.BODY_FALL_S, at, BANK.BODY_FALL_DB)


## Someone the hero holds slammed into something (hero_slammed): a heavy thump at the contact;
## a prop that goes over sounds for itself (prop_knocked).
func _on_hero_slammed(at: Vector3, _what: String, _over: bool) -> void:
	var pitch := BANK.SLAM_PITCH * _rng.randf_range(0.94, 1.06)
	emitters.shot("hit", at, "punch_hit", BANK.SLAM_DB, pitch)


## The blow behind the next hero_hurt came from angle on the screen (hero_hit_dir; hit_direction,
## first person): remembered for that hurt's thump, nothing played here.
func _on_hero_hit_dir(angle: float) -> void:
	_hit_dir = angle
	_hit_dir_pending = true


## The hero hurt (hero_hurt) by a punch, a car or a dog: the thump at their chest by the health it
## took (full level at HERO_HIT_FULL), a car's lower and louder, a bite's jaws snapping at the knee;
## knocked down, they land BANK.BODY_FALL_S later. A crash sounds as the car's (car_impact) and a
## fall as the landing. In first person the thump pans a fist's reach toward where the blow came
## from (hero_hit_dir; hit_direction).
func _on_hero_hurt(amount: float, cause: String, _health: float, down: bool) -> void:
	# The pending direction is this hurt's (health emits it just before); read and clear it
	# whatever the cause, so a cause without a thump never leaves a stale one behind.
	var dir_ok := _hit_dir_pending
	_hit_dir_pending = false
	if not HERO_HIT_FULL.has(cause):
		return
	var car := cause == "car"
	var at := ctx.player_position()
	var trim := _impact_db(amount / float(HERO_HIT_FULL[cause])) + (BANK.HIT_CAR_DB if car else 0.0)
	var pitch := _rng.randf_range(0.72, 0.8) if car else _rng.randf_range(0.92, 1.08)
	if cause == "bite":
		emitters.shot("dog", at + Vector3(0.0, BANK.SNAP_Y * WS.M, 0.0), "dog_snap", trim, pitch)
	else:
		var pos := at + Vector3(0.0, 1.3 * WS.M, 0.0)
		var p := ctx.player
		if dir_ok and not car and p != null:
			# The body's right is (cos, -sin) of its yaw and it faces (-sin, -cos).
			var r3 := Vector3(cos(p.yaw), 0.0, -sin(p.yaw))
			var f3 := Vector3(-sin(p.yaw), 0.0, -cos(p.yaw))
			pos += (r3 * sin(_hit_dir) + f3 * cos(_hit_dir)) * DIR_THUMP_M * WS.M
		emitters.shot("hit", pos, "punch_hit", trim, pitch)
	if down:
		_queue_fall(BANK.BODY_FALL_S, at, BANK.BODY_FALL_DB)


## An animal calling (animal_called) at its head: a dog's bark (one of BANK.BARK_VARIANTS), growl,
## whine or yelp at BANK.DOG_DB, pitched by its size (BANK.DOG_PITCH_M); a pigeon's coo (one of
## BANK.COO_VARIANTS), a lone bird's flap or a flock's take-off at BANK.PIGEON_DB; a cat's meow
## (one of BANK.MEOW_VARIANTS), purr, hiss, chatter or yowl at BANK.CAT_DB, pitched by its size.
func _on_animal_called(at: Vector3, call: String, size: float) -> void:
	if BANK.CAT_DB.has(call):
		var c := "cat_%s" % call
		if call == "meow":
			c = "cat_meow_%d" % _rng.randi_range(1, BANK.MEOW_VARIANTS)
		var voice := sqrt(BANK.CAT_PITCH_M / maxf(size, 0.05))
		voice *= 1.0 + _rng.randf_range(-BANK.CAT_PITCH, BANK.CAT_PITCH)
		emitters.shot("cat", at, c, float(BANK.CAT_DB[call]), voice)
		return
	if BANK.PIGEON_DB.has(call):
		var p := "pigeon_%s" % call
		if call == "coo":
			p = "pigeon_coo_%d" % _rng.randi_range(1, BANK.COO_VARIANTS)
		var pitch := 1.0 + _rng.randf_range(-BANK.PIGEON_PITCH, BANK.PIGEON_PITCH)
		emitters.shot("bird", at, p, float(BANK.PIGEON_DB[call]), pitch)
		return
	if not BANK.DOG_DB.has(call):
		return
	var s := "dog_%s" % call
	if call == "bark":
		s = "dog_bark_%d" % _rng.randi_range(1, BANK.BARK_VARIANTS)
	var pitch := sqrt(BANK.DOG_PITCH_M / maxf(size, 0.1)) * _rng.randf_range(0.96, 1.04)
	emitters.shot("dog", at, s, float(BANK.DOG_DB[call]), pitch)


## A blow of the hero's on an animal (animal_hit): a lighter, higher thump at its body by the
## blow's strength (BANK.ANIMAL_HIT_DB, BANK.ANIMAL_HIT_PITCH); the animal's cry is its own call.
func _on_animal_hit(at: Vector3, kind: String, strength: float) -> void:
	var trim := _impact_db(strength / BANK.HIT_FULL) + BANK.ANIMAL_HIT_DB
	var pitch := BANK.ANIMAL_HIT_PITCH * (2.0 if kind == "pigeon" else 1.0)
	pitch *= _rng.randf_range(0.94, 1.06)
	var p := at + Vector3(0.0, BANK.ANIMAL_HIT_Y * WS.M, 0.0)
	emitters.shot("hit", p, "punch_hit", trim, pitch)


## A body_fall at at, delay seconds from now at db, in the queue by when it is due.
func _queue_fall(delay: float, at: Vector3, db: float) -> void:
	var due := _now + delay
	var i := _falls.size()
	while i > 0 and float(_falls[i - 1][0]) > due:
		i -= 1
	_falls.insert(i, [due, at, db])


## The stream for the hero's own horn action (the class_audio flag; drive names the action by
## the ride): each class's short press and held long lean, and a real bell for the bicycle —
## the bell used to borrow the car horn. Without the flag every horn is the car's.
const HERO_HORNS := {
	"horn": "horn_short",
	"horn_long": "horn_long",
	"horn_truck": "horn_truck_short",
	"horn_truck_long": "horn_truck_long",
	"horn_scooter": "horn_scooter_short",
	"horn_scooter_long": "horn_scooter_long",
	"bell": "bell_bicycle",
}


## The hero's swing (hero_action): a whoosh at their shoulder, a jab's higher, a hook's and a
## kick's lower, a shove's lower and softer; a landing roll's shoulder thuds on the ground
## BANK.ROLL_THUD_S later. The hero's horn or bicycle bell (drive's night_driving flag) sounds at
## the car through the street's own horn source, in the same pool, volumes and ducking as every
## other horn in town. Emotes and the other parkour moves make no sound here.
## The bank stream a hero horn action plays, or "" when action is not a horn.
static func _hero_horn_stream(action: String) -> String:
	if not HERO_HORNS.has(action):
		return ""
	if not FeatureFlags.enabled("class_audio"):
		return "horn_long" if action == "horn_long" else "horn_short"
	return str(HERO_HORNS[action])


func _on_hero_action(action: String, at: Vector3) -> void:
	if action == "roll":
		_queue_fall(BANK.ROLL_THUD_S, at, BANK.BODY_FALL_DB + BANK.ROLL_DB)
		return
	var horn_stream := _hero_horn_stream(action)
	if not horn_stream.is_empty():
		emitters.horn(at, horn_stream)
		return
	if not SWING_PITCH.has(action):
		return
	var shove := action == "shove"
	var trim := BANK.WHOOSH_DB + (BANK.SHOVE_DB if shove else 0.0)
	var pitch := float(SWING_PITCH[action])
	var p := at + Vector3(0.0, 1.4 * WS.M, 0.0)
	emitters.shot("hit", p, "punch_whoosh", trim, pitch * _rng.randf_range(0.96, 1.04))


func _on_site_started(site: Dictionary) -> void:
	emitters.add_site(int(site["i"]))


func _on_site_finished(site: Dictionary) -> void:
	emitters.remove_site(int(site["i"]))


func _on_tile_built(i: int, holder: Node3D) -> void:
	if ctx.view.in_setup:
		return
	var t := Time.get_ticks_usec()
	emitters.scan_tile(i, holder)
	_section("tile_built", t)


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
	# A fresh instance of this feature is created on every entry, while the buses and their
	# effects are kept: adopt what is already on the bus (reset to the open values), create only
	# what is missing. Never stack a second filter or reverb.
	music_filter = (
		_bus_effect(BANK.BUS_MUSIC, AudioEffectLowPassFilter) as AudioEffectLowPassFilter
	)
	if music_filter == null:
		music_filter = AudioEffectLowPassFilter.new()
		_add_effect(BANK.BUS_MUSIC, music_filter)
	music_filter.cutoff_hz = MUSIC_CUTOFF_OPEN
	sfx_reverb = _bus_effect(BANK.BUS_SFX, AudioEffectReverb) as AudioEffectReverb
	if sfx_reverb == null:
		sfx_reverb = AudioEffectReverb.new()
		_add_effect(BANK.BUS_SFX, sfx_reverb)
	sfx_reverb.room_size = 0.5
	sfx_reverb.damping = 0.6
	sfx_reverb.spread = 0.9
	sfx_reverb.hipass = 0.25
	sfx_reverb.predelay_msec = 25.0
	sfx_reverb.predelay_feedback = 0.2
	sfx_reverb.dry = 1.0
	sfx_reverb.wet = REVERB_WET_OPEN
	if _bus_effect(BANK.BUS_SFX, AudioEffectHardLimiter) == null:
		var lim := AudioEffectHardLimiter.new()
		lim.ceiling_db = -1.0
		_add_effect(BANK.BUS_SFX, lim)


## The first effect of the given class already on the bus, or null.
func _bus_effect(bus_name: StringName, what: Variant) -> AudioEffect:
	var i := AudioServer.get_bus_index(bus_name)
	if i < 0:
		return null
	for k in range(AudioServer.get_bus_effect_count(i)):
		var e := AudioServer.get_bus_effect(i, k)
		if is_instance_of(e, what):
			return e
	return null


func _add_effect(bus_name: StringName, e: AudioEffect) -> void:
	var i := AudioServer.get_bus_index(bus_name)
	if i < 0:
		return
	AudioServer.add_bus_effect(i, e)
