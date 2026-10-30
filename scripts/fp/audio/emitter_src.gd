extends RefCounted
## One logical sound source (see emitters.gd): a registered emitter that may hold a pooled
## AudioStreamPlayer3D while it is among the loudest at the listener.

var key: String = ""
var type: String = ""
var pos: Vector3 = Vector3.ZERO
var vel: Vector3 = Vector3.ZERO  # u/s, for doppler and extrapolation
var stream: AudioStream
var db: float = 0.0  # type level + trim
var gain_db: float = 0.0  # smoothed dynamic gain (speed, night, fades)
var gain_target: float = 0.0
var pitch_base: float = 1.0
var pitch: float = 1.0
var doppler: bool = false
var dynamic: bool = false  # refreshed from agents; dropped when not seen
var seen: bool = true
var one_shot: bool = false
var expire_at: float = INF  # emitter clock time it fades out (one-shots, timed sirens)
var volatile: bool = false  # dynamic, one-shot, siren or river: not in the static set
var dying: bool = false
var started: bool = false  # a one-shot played once already
var player: AudioStreamPlayer3D
var score: float = -INF
var dist: float = INF
var w_vol: float = INF  # last volume_db written to the player (INF = unknown)
var w_pitch: float = INF  # last pitch_scale written
var w_db: float = INF  # db when max_db was last written
var tag: int = -1  # tile or event id
