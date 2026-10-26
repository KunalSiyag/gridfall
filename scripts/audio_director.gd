class_name GridFallAudioDirector
extends Node
## Dynamic ACE-Step 1.5 soundtrack crossfader & crisis SFX director.
## Crossfades between gridfall_nominal.wav (96 BPM) and gridfall_blackout_crisis.wav (122 BPM)
## based on real-time city blackout intensity. On foot (set_fp(true), called by slice I's audio
## feature) the stems play on the Music bus 8 dB lower and keep playing, muffled, while the tree is
## paused; UI cues move to the UI bus and the incident alert gives way to positional sirens.

## A play_sfx call actually played (tests count these instead of listening).
signal sfx_played(path: String, bus: String)

const NOMINAL_TRACK_PATH := "res://sounds/music/gridfall_nominal.wav"
const CRISIS_TRACK_PATH := "res://sounds/music/gridfall_blackout_crisis.wav"
const SFX_TICK_PATH := "res://sounds/placement-a.ogg"
const SFX_ALERT_PATH := "res://sounds/gridlock_alert.wav"
const SFX_RECOVERY_PATH := "res://sounds/upgrade_chime.wav"
const SFX_DAY_BELL_PATH := "res://sounds/day_bell.wav"
## Shortest gap between two blackout ticks, in seconds of director time.
const TICK_MIN_GAP := 10.0
## On foot: music offset under the street sound, the buses used and the UI cue trim.
const FP_MUSIC_OFFSET_DB := -8.0
const FP_MUSIC_BUS := &"Music"
const FP_UI_BUS := &"UI"
const FP_UI_TRIM_DB := -6.0

var _nominal_player: AudioStreamPlayer
var _crisis_player: AudioStreamPlayer
var _sfx_player: AudioStreamPlayer
var _target_blackout: float = 0.0
var _current_mix: float = 0.0
var muted: bool = false
var _fp: bool = false
var _orbit_bus: Dictionary = {}          # player -> bus name before set_fp(true)
var _orbit_process_mode: ProcessMode = PROCESS_MODE_INHERIT
var _streams: Dictionary = {}            # path -> AudioStream (null when missing)
var _clock: float = 0.0
var _last_tick: float = -INF
var _last_phase: String = ""


func _ready() -> void:
	_nominal_player = AudioStreamPlayer.new()
	_nominal_player.name = "NominalStemPlayer"
	add_child(_nominal_player)

	_crisis_player = AudioStreamPlayer.new()
	_crisis_player.name = "CrisisStemPlayer"
	add_child(_crisis_player)

	_sfx_player = AudioStreamPlayer.new()
	_sfx_player.name = "SfxPlayer"
	add_child(_sfx_player)

	_nominal_player.stream = _looping_track(NOMINAL_TRACK_PATH)
	_crisis_player.stream = _looping_track(CRISIS_TRACK_PATH)

	_apply_volumes()
	if _nominal_player.stream != null:
		_nominal_player.play()
	if _crisis_player.stream != null:
		_crisis_player.play()


func _process(delta: float) -> void:
	_clock += delta
	_current_mix = lerpf(_current_mix, _target_blackout, minf(delta * 2.5, 1.0))
	_apply_volumes()


## Crisis level for the music crossfade. The tick cue sounds only when phase changes, and at most
## once per TICK_MIN_GAP seconds (it used to sound on every call, i.e. every day start).
func set_blackout_intensity(intensity: float, phase: String = "") -> void:
	var prev := _target_blackout
	_target_blackout = clampf(intensity, 0.0, 1.0)
	var phase_changed := phase != _last_phase
	_last_phase = phase
	if muted:
		return
	if _target_blackout >= 0.5 and prev < 0.5:
		play_sfx(SFX_ALERT_PATH, -5.0)
	elif phase_changed and (phase == "RECOVERY_SURGE" or phase == "STABILIZED"):
		play_sfx(SFX_RECOVERY_PATH, -6.0)
	elif phase_changed and _clock - _last_tick >= TICK_MIN_GAP:
		_last_tick = _clock
		play_sfx(SFX_TICK_PATH, -10.0)


func toggle_mute() -> bool:
	muted = not muted
	_apply_volumes()
	return muted


## On-foot routing (slice I). true: stems on the Music bus with FP_MUSIC_OFFSET_DB, UI cues on the
## UI bus, the incident alert suppressed, and the director runs while paused. false restores the
## orbit routing and process mode exactly.
func set_fp(on: bool) -> void:
	if on == _fp:
		return
	_fp = on
	var players: Array[AudioStreamPlayer] = [_nominal_player, _crisis_player, _sfx_player]
	if on:
		_orbit_process_mode = process_mode
		process_mode = PROCESS_MODE_ALWAYS
		_orbit_bus.clear()
		for p in players:
			if p != null:
				_orbit_bus[p] = p.bus
		for p in [_nominal_player, _crisis_player]:
			if p != null:
				p.bus = FP_MUSIC_BUS
		if _sfx_player != null:
			_sfx_player.bus = FP_UI_BUS
	else:
		process_mode = _orbit_process_mode
		for p in players:
			if p != null and _orbit_bus.has(p):
				p.bus = _orbit_bus[p]
		_orbit_bus.clear()
	_apply_volumes()


func is_fp() -> bool:
	return _fp


func get_active_stem_label() -> String:
	if muted:
		return "ACE-Step 1.5: MUTED"
	if _current_mix >= 0.45:
		return "ACE-Step 1.5: BLACKOUT CRISIS (122 BPM · %d%% Mix)" % int(round(_current_mix * 100.0))
	return "ACE-Step 1.5: NOMINAL GRID (96 BPM · %d%% Calm)" % int(round((1.0 - _current_mix) * 100.0))


func play_sfx(path: String, volume_db: float = -6.0) -> void:
	if muted or _sfx_player == null:
		return
	if _fp:
		if path == SFX_ALERT_PATH:
			return
		if path == SFX_DAY_BELL_PATH or path == SFX_TICK_PATH:
			volume_db += FP_UI_TRIM_DB
	var stream := _stream(path)
	if stream == null:
		return
	_sfx_player.stream = stream
	_sfx_player.volume_db = volume_db
	_sfx_player.play()
	sfx_played.emit(path, str(_sfx_player.bus))


func _exit_tree() -> void:
	for p in [_nominal_player, _crisis_player, _sfx_player]:
		if p != null:
			p.stop()
			p.stream = null


func _stream(path: String) -> AudioStream:
	path = web_audio_path(path, OS.has_feature("web"))
	if not _streams.has(path):
		_streams[path] = load(path) as AudioStream if ResourceLoader.exists(path) else null
	return _streams[path]


## Web exports convert WAV assets in an isolated staging project, never on desktop.
static func web_audio_path(path: String, web: bool) -> String:
	return path.trim_suffix(".wav") + ".ogg" if web and path.ends_with(".wav") else path


func _looping_track(path: String) -> AudioStream:
	var stream := _stream(path)
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = int(wav.get_length() * wav.mix_rate)
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	return stream


func _apply_volumes() -> void:
	if _nominal_player == null or _crisis_player == null:
		return
	if muted:
		_nominal_player.volume_db = -80.0
		_crisis_player.volume_db = -80.0
		return
	var off := FP_MUSIC_OFFSET_DB if _fp else 0.0
	var nom_gain := clampf(1.0 - _current_mix * 0.85, 0.05, 1.0)
	var cri_gain := clampf(0.04 + _current_mix * 0.96, 0.02, 1.0)
	_nominal_player.volume_db = linear_to_db(nom_gain) - 4.0 + off
	_crisis_player.volume_db = linear_to_db(cri_gain) - 3.0 + off
