class_name GridFallEpisodePlayer
extends Node
## Loads and plays multi-model GMI Cloud crisis episodes (episodes/crisis_blackout_01.json).

signal episode_loaded(episode: Dictionary)
signal tick_changed(tick_index: int, tick_data: Dictionary, episode: Dictionary)
signal playback_state_changed(is_playing: bool, speed_multiplier: float)

const DEFAULT_EPISODE_PATH := "res://episodes/crisis_blackout_01.json"
const BASE_TICK_SECONDS := 4.5

var episode_data: Dictionary = {}
var current_tick_index: int = 0
var is_playing: bool = true
var speed_multiplier: float = 1.0
var _elapsed: float = 0.0


func load_episode(path: String = DEFAULT_EPISODE_PATH) -> bool:
	if not FileAccess.file_exists(path):
		push_error("GridFallEpisodePlayer: Episode file not found at " + path)
		return false
	var raw := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("GridFallEpisodePlayer: Invalid JSON in " + path)
		return false
	episode_data = parsed as Dictionary
	current_tick_index = 0
	_elapsed = 0.0
	episode_loaded.emit(episode_data)
	_emit_current_tick()
	return true


func _process(delta: float) -> void:
	if not is_playing:
		return
	var ticks: Array = episode_data.get("ticks", [])
	if ticks.is_empty():
		return
	_elapsed += delta * speed_multiplier
	if _elapsed >= BASE_TICK_SECONDS:
		_elapsed = 0.0
		step_next(true)


func toggle_play() -> bool:
	is_playing = not is_playing
	playback_state_changed.emit(is_playing, speed_multiplier)
	return is_playing


func cycle_speed() -> float:
	if is_equal_approx(speed_multiplier, 1.0):
		speed_multiplier = 2.0
	elif is_equal_approx(speed_multiplier, 2.0):
		speed_multiplier = 0.5
	else:
		speed_multiplier = 1.0
	playback_state_changed.emit(is_playing, speed_multiplier)
	return speed_multiplier


func step_next(loop_at_end: bool = true) -> void:
	var ticks: Array = episode_data.get("ticks", [])
	if ticks.is_empty():
		return
	_elapsed = 0.0
	if current_tick_index + 1 < ticks.size():
		current_tick_index += 1
	elif loop_at_end:
		current_tick_index = 0
	_emit_current_tick()


func step_prev() -> void:
	var ticks: Array = episode_data.get("ticks", [])
	if ticks.is_empty():
		return
	_elapsed = 0.0
	current_tick_index = maxi(0, current_tick_index - 1)
	_emit_current_tick()


func jump_to_tick(index: int) -> void:
	var ticks: Array = episode_data.get("ticks", [])
	if ticks.is_empty():
		return
	_elapsed = 0.0
	current_tick_index = clampi(index, 0, ticks.size() - 1)
	_emit_current_tick()


func get_tick_progress() -> float:
	return clampf(_elapsed / BASE_TICK_SECONDS, 0.0, 1.0)


func _emit_current_tick() -> void:
	var ticks: Array = episode_data.get("ticks", [])
	if current_tick_index >= 0 and current_tick_index < ticks.size():
		var td: Dictionary = ticks[current_tick_index]
		tick_changed.emit(current_tick_index, td, episode_data)
