extends RefCounted
## The AudioStreamPlayer3D pool behind emitters.gd: at most MAX_PLAYERS players shared by every
## logical source (see emitter_src.gd). A released loop keeps its stream loaded and paused so the
## next source with the same stream resumes it; at most one Ogg playback starts per refresh (each
## costs ~0.4 ms). Split out of emitters.gd (pure move) to keep both files under the line cap.

const WS := preload("res://scripts/fp/world_scale.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")
const Src := preload("res://scripts/fp/audio/emitter_src.gd")

const MAX_PLAYERS := 24
## Distance filter: Godot dulls a source above the cutoff as its gain falls (air absorption).
const FILTER_DB := -10.0
const FILTER_HZ := 5000.0
## A source that gets a player fades in from this far below its level (no pop when it steals one).
const FADE_IN_DB := 18.0

var players: Array[AudioStreamPlayer3D] = []
var free: Array[AudioStreamPlayer3D] = []
var assigned: Dictionary = {}  # Src -> true while it holds a player
var fresh_ogg: int = 0  # Ogg playbacks started this refresh

var _host: Node3D
var _rng: RandomNumberGenerator
var _types: Dictionary


func _init(host: Node3D, rng: RandomNumberGenerator, types: Dictionary) -> void:
	_host = host
	_rng = rng
	_types = types


## Resets the per-refresh Ogg-start budget (called by emitters' refresh).
func begin_refresh() -> void:
	fresh_ogg = 0


## Stops every player and forgets every assignment (load, New City, teardown).
func stop_all() -> void:
	for s: Src in assigned.keys():
		unassign(s, true)
	assigned.clear()
	for pl in players:
		pl.stop()
		pl.stream = null
		pl.stream_paused = false


## Gives s a player: a released one still holding s's stream resumes where it paused (no new
## playback); else a new one while fewer than MAX_PLAYERS exist; else the oldest released one.
## A loop fades in over FADE_IN_DB, so taking a player never pops.
func assign(s: Src) -> void:
	var pl: AudioStreamPlayer3D = null
	for k in range(free.size() - 1, -1, -1):
		if free[k].stream == s.stream and s.stream != null and not s.one_shot:
			pl = free[k]
			free.remove_at(k)
			_bind(s, pl)
			pl.stream_paused = false
			if not pl.playing:
				pl.play(_rng.randf() * maxf(s.stream.get_length() - 0.1, 0.0))
			return
	if s.stream is AudioStreamOggVorbis:
		if fresh_ogg >= 1:
			return
		fresh_ogg += 1
	if players.size() < MAX_PLAYERS:
		pl = AudioStreamPlayer3D.new()
		pl.name = "Emitter%d" % players.size()
		pl.unit_size = WS.AUDIO_UNIT_SIZE
		pl.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		pl.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		pl.bus = BANK.BUS_SFX
		pl.attenuation_filter_db = FILTER_DB
		pl.attenuation_filter_cutoff_hz = FILTER_HZ
		_host.add_child(pl)
		players.append(pl)
	elif not free.is_empty():
		pl = free.pop_front()
	if pl == null:
		return
	_bind(s, pl)
	pl.stream = s.stream
	restart(s)


## Hands player pl to s and sets it to s's place, pitch and (faded-in) level.
func _bind(s: Src, pl: AudioStreamPlayer3D) -> void:
	s.player = pl
	assigned[s] = true
	if not s.one_shot and not s.dying:
		s.gain_db = s.gain_target - FADE_IN_DB
	pl.max_distance = float(_types[s.type]["max"])
	pl.position = s.pos
	pl.pitch_scale = clampf(s.pitch, 0.25, 4.0)
	pl.volume_db = s.db + s.gain_db
	pl.max_db = s.db + float(_types[s.type]["near"])
	s.w_vol = pl.volume_db
	s.w_pitch = pl.pitch_scale
	s.w_db = s.db


func restart(s: Src) -> void:
	var pl := s.player
	pl.stream_paused = false
	pl.stream = s.stream
	if s.stream == null:
		pl.stop()
		return
	if s.one_shot:
		s.started = true
		pl.play()
	else:
		pl.play(_rng.randf() * maxf(s.stream.get_length() - 0.1, 0.0))


## Takes s's player back. A looping stream stays loaded and paused, so the next source with the
## same stream resumes it without starting a new playback.
func unassign(s: Src, full_stop: bool = false) -> void:
	var pl := s.player
	assigned.erase(s)
	if pl == null:
		return
	s.player = null
	pl.volume_db = -80.0
	if s.one_shot or full_stop:
		pl.stop()
		pl.stream = null
	else:
		pl.stream_paused = true
	free.append(pl)
