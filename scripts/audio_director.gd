class_name GridFallAudioDirector
extends Node
## Dynamic ACE-Step 1.5 soundtrack crossfader & crisis SFX director.
## Crossfades between gridfall_nominal.wav (96 BPM) and gridfall_blackout_crisis.wav (122 BPM)
## based on real-time city blackout intensity.

const NOMINAL_TRACK_PATH := "res://sounds/music/gridfall_nominal.wav"
const CRISIS_TRACK_PATH := "res://sounds/music/gridfall_blackout_crisis.wav"
const SFX_TICK_PATH := "res://sounds/placement-a.ogg"
const SFX_ALERT_PATH := "res://sounds/gridlock_alert.wav"
const SFX_RECOVERY_PATH := "res://sounds/upgrade_chime.wav"

var _nominal_player: AudioStreamPlayer
var _crisis_player: AudioStreamPlayer
var _sfx_player: AudioStreamPlayer
var _target_blackout: float = 0.0
var _current_mix: float = 0.0
var muted: bool = false


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

	if ResourceLoader.exists(NOMINAL_TRACK_PATH):
		var s_nom := load(NOMINAL_TRACK_PATH) as AudioStreamWAV
		if s_nom != null:
			s_nom.loop_mode = AudioStreamWAV.LOOP_FORWARD
			s_nom.loop_end = int(s_nom.get_length() * s_nom.mix_rate)
			_nominal_player.stream = s_nom

	if ResourceLoader.exists(CRISIS_TRACK_PATH):
		var s_cri := load(CRISIS_TRACK_PATH) as AudioStreamWAV
		if s_cri != null:
			s_cri.loop_mode = AudioStreamWAV.LOOP_FORWARD
			s_cri.loop_end = int(s_cri.get_length() * s_cri.mix_rate)
			_crisis_player.stream = s_cri

	_apply_volumes()
	if _nominal_player.stream != null:
		_nominal_player.play()
	if _crisis_player.stream != null:
		_crisis_player.play()


func _process(delta: float) -> void:
	_current_mix = lerpf(_current_mix, _target_blackout, minf(delta * 2.5, 1.0))
	_apply_volumes()


func set_blackout_intensity(intensity: float, phase: String = "") -> void:
	var prev := _target_blackout
	_target_blackout = clampf(intensity, 0.0, 1.0)
	if not muted:
		if _target_blackout >= 0.5 and prev < 0.5:
			play_sfx(SFX_ALERT_PATH, -5.0)
		elif phase == "RECOVERY_SURGE" or phase == "STABILIZED":
			play_sfx(SFX_RECOVERY_PATH, -6.0)
		else:
			play_sfx(SFX_TICK_PATH, -10.0)


func toggle_mute() -> bool:
	muted = not muted
	_apply_volumes()
	return muted


func get_active_stem_label() -> String:
	if muted:
		return "ACE-Step 1.5: MUTED"
	if _current_mix >= 0.45:
		return "ACE-Step 1.5: BLACKOUT CRISIS (122 BPM · %d%% Mix)" % int(round(_current_mix * 100.0))
	return "ACE-Step 1.5: NOMINAL GRID (96 BPM · %d%% Calm)" % int(round((1.0 - _current_mix) * 100.0))


func play_sfx(path: String, volume_db: float = -6.0) -> void:
	if muted or _sfx_player == null:
		return
	if ResourceLoader.exists(path):
		var stream := load(path) as AudioStream
		if stream != null:
			_sfx_player.stream = stream
			_sfx_player.volume_db = volume_db
			_sfx_player.play()


func _exit_tree() -> void:
	for p in [_nominal_player, _crisis_player, _sfx_player]:
		if p != null:
			p.stop()
			p.stream = null


func _apply_volumes() -> void:
	if _nominal_player == null or _crisis_player == null:
		return
	if muted:
		_nominal_player.volume_db = -80.0
		_crisis_player.volume_db = -80.0
		return
	var nom_gain := clampf(1.0 - _current_mix * 0.85, 0.05, 1.0)
	var cri_gain := clampf(0.04 + _current_mix * 0.96, 0.02, 1.0)
	_nominal_player.volume_db = linear_to_db(nom_gain) - 4.0
	_crisis_player.volume_db = linear_to_db(cri_gain) - 3.0
