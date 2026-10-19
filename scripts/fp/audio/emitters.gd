extends Node3D
## Positional city sound (slice I): logical sources (engines, horns, sirens, construction, fire,
## fountains, power plants, river banks, passers-by's footsteps) share a pool of at most
## MAX_PLAYERS AudioStreamPlayer3D.
## Every refresh scores the sources by their estimated level at the listener and gives the players
## to the loudest; the farthest or quietest lose theirs first. Doppler is computed by hand (the
## built-in effect works in world units against 343 u/s and is inaudible at 1 u = 20 m).
## A grown city registers hundreds of static sources (every park's fountain, every site), so the
## per-frame work touches only the sources holding a player, the refresh only the volatile ones
## (agents, one-shots, sirens, river) and the static ones near the listener.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")
const FS := preload("res://scripts/fp/audio/footsteps.gd")

const MAX_PLAYERS := 24
## Per type: max_distance (u), volume_db at unit_size (10 m), the near cap above that (max_db =
## db + near) and the stream played by default.
const TYPES := {
	"engine": {"max": 6.0, "db": -6.0, "near": 9.0, "stream": "engine_run"},
	"horn": {"max": 10.0, "db": -6.0, "near": 8.0, "stream": "horn_short"},
	"siren": {"max": 25.0, "db": 6.0, "near": -8.0, "stream": "siren_two_tone"},
	"construction": {"max": 8.0, "db": 2.0, "near": 4.0, "stream": "construction_loop"},
	"fire": {"max": 6.0, "db": 0.0, "near": 6.0, "stream": "fire_crackle"},
	"fountain": {"max": 3.0, "db": -8.0, "near": 6.0, "stream": "fountain_loop"},
	"plant": {"max": 6.0, "db": -2.0, "near": 6.0, "stream": "plant_hum"},
	"river": {"max": 6.0, "db": -5.0, "near": 6.0, "stream": "river_loop"},
	"step": {"max": 0.5, "db": -24.0, "near": 6.0, "stream": "footstep_sidewalk_1"},
}
## Residents on foot (E's "pedestrian" agents): positional footsteps for the WALKER_MAX nearest
## walkers within WALKER_RADIUS of the hero, one per stride of their travel (E has no foot-contact
## signal yet). Faster "pedestrians" are E's bikes and stay silent.
const WALKER_RADIUS := 6.0 * WS.M
const WALKER_MAX := 4
const WALKER_MIN_MPS := 0.4
const WALKER_MAX_MPS := 2.6
## Engines: how many cars and how far (u); horn rules.
const ENGINE_CARS := 8
const ENGINE_RADIUS := 3.0
## Horns: a car stalled longer than HORN_STALL_S may honk; the urge grows until HORN_STALL_FULL_S
## (a red light rarely gets a horn, a jam often does) and with the congestion of its tile.
const HORN_STALL_S := 4.0
const HORN_STALL_FULL_S := 24.0
const HORN_RATE := 0.05          # honks per second per stalled car at full urge in a jam
const HORN_GAP := 6.0            # at most one horn per this many seconds, city-wide ...
const HORN_GAP_MAX := 14.0       # ... the gap after each horn is drawn from HORN_GAP..HORN_GAP_MAX
const HORN_CAR_REST := 20.0      # the same car does not honk again for this long
## Incident sirens without a visible crew: play at the event for this long after it starts.
const EVENT_SIREN_S := 35.0
## Incidents that send a crew with sirens (utility repairs do not).
const SIREN_EVENTS := ["fire", "tornado", "earthquake", "flood", "gridlock", "blackout", "sewage_burst", "smog", "car_crash"]
const REFRESH := 0.125           # s between source scores / assignments
const SIREN_REFRESH := 2.0       # s between wide siren scans (only while an incident is live)
const RIVER_SOURCES := 3
const SPEED_OF_SOUND := 343.0
const DOPPLER_MIN := 0.7
const DOPPLER_MAX := 1.4
## Distance filter: Godot dulls a source above the cutoff as its gain falls (air absorption).
const FILTER_DB := -10.0
const FILTER_HZ := 5000.0
## A source that gets a player fades in from this far below its level (no pop when it steals one),
## at FADE_IN_RATE dB/s; levels fall at FADE_RATE dB/s and a dying source at DIE_RATE.
const FADE_IN_DB := 18.0
const FADE_IN_RATE := 36.0
const FADE_RATE := 12.0
const DIE_RATE := 60.0


## One logical sound source; holds a pool player only while it is among the loudest.
class Src extends RefCounted:
	var key: String = ""
	var type: String = ""
	var pos: Vector3 = Vector3.ZERO
	var vel: Vector3 = Vector3.ZERO       # u/s, for doppler and extrapolation
	var stream: AudioStream
	var db: float = 0.0                   # type level + trim
	var gain_db: float = 0.0              # smoothed dynamic gain (speed, night, fades)
	var gain_target: float = 0.0
	var pitch_base: float = 1.0
	var pitch: float = 1.0
	var doppler: bool = false
	var dynamic: bool = false             # refreshed from agents; dropped when not seen
	var seen: bool = true
	var one_shot: bool = false
	var expire_at: float = INF            # emitter clock time it fades out (one-shots, timed sirens)
	var volatile: bool = false            # dynamic, one-shot, siren or river: not in the static set
	var dying: bool = false
	var started: bool = false             # a one-shot played once already
	var player: AudioStreamPlayer3D
	var score: float = -INF
	var dist: float = INF
	var tag: int = -1                     # tile or event id


var ctx: FpContext
## Agents provider for tests: Callable(p: Vector3, r: float) -> Array of E's agent dicts.
var agents_provider: Callable = Callable()
var time_scale: int = 1
var enabled: bool = true
var horns_played: int = 0
var walker_steps: int = 0
## 0 day .. 1 night (SkyDirector.night); construction falls quiet at night.
var night: float = 0.0

var _sources: Dictionary = {}          # key -> Src
var _volatile: Dictionary = {}         # key -> Src, the volatile subset of _sources
var _assigned: Dictionary = {}         # Src -> true while it holds a player
var _players: Array[AudioStreamPlayer3D] = []
var _free: Array[AudioStreamPlayer3D] = []
var _rng := RandomNumberGenerator.new()
var _t_refresh: float = 0.0
var _t_siren: float = 0.0
var _force: bool = true
var _force_wide: bool = true
var _next_horn: float = -INF          # no horn before this time (the city-wide gap)
var _honked: Dictionary = {}           # agent id -> time of its last horn
var _now: float = 0.0
var _horn_seq: int = 0
var _banks: Dictionary = {}            # Vector2i chunk -> PackedVector3Array of bank points
var _static_near: Array[Src] = []
var _static_dirty: bool = true
var _static_at: Vector3 = Vector3(INF, INF, INF)
var _crew_sirens: Dictionary = {}      # siren source keys refreshed by the wide scan
var _fresh_ogg: int = 0                # Ogg playbacks started this refresh
var _river_at: Vector3 = Vector3(INF, INF, INF)
## Walkers heard stepping: agent id -> {"pos", "vel", "travel" (u since the last step), "left"}.
var _walkers: Dictionary = {}
var _step_seq: int = 0


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	_rng.seed = 7151


## Registers or updates a source. opts: stream (name), vel, pitch, trim_db, ttl, doppler, dynamic,
## one_shot, tag. Returns the Src.
func request(key: String, type: String, pos: Vector3, opts: Dictionary = {}) -> Src:
	var s: Src = _sources.get(key, null)
	var spec: Dictionary = TYPES[type]
	if s == null:
		s = Src.new()
		s.key = key
		s.type = type
		s.pos = pos
		s.dynamic = bool(opts.get("dynamic", false))
		s.volatile = s.dynamic or bool(opts.get("one_shot", false)) or type == "siren" or type == "river"
		_sources[key] = s
		if s.volatile:
			_volatile[key] = s
		else:
			_static_dirty = true
		s.stream = BANK.stream(str(opts.get("stream", spec["stream"])))
		s.gain_db = float(opts.get("gain", 0.0))
		s.pitch = float(opts.get("pitch", 1.0))
	else:
		if opts.has("stream"):
			var ns := BANK.stream(str(opts["stream"]))
			if ns != s.stream:
				s.stream = ns
				if s.player != null:
					_restart(s)
		if s.dynamic and pos.distance_to(s.pos) < 0.1:
			s.pos = s.pos.lerp(pos, 0.6)
		else:
			s.pos = pos
	s.dying = false
	s.seen = true
	s.db = float(spec["db"]) + float(opts.get("trim_db", 0.0))
	s.vel = opts.get("vel", Vector3.ZERO)
	s.pitch_base = float(opts.get("pitch", s.pitch_base))
	s.doppler = bool(opts.get("doppler", false))
	s.one_shot = bool(opts.get("one_shot", s.one_shot))
	s.tag = int(opts.get("tag", s.tag))
	if opts.has("ttl"):
		s.expire_at = _now + float(opts["ttl"])
	if opts.has("gain"):
		s.gain_target = float(opts["gain"])
	return s


## Fades a source out and forgets it (at once when it holds no player).
func release(key: String) -> void:
	var s: Src = _sources.get(key, null)
	if s == null:
		return
	if s.player == null:
		_erase(key)
		return
	s.dying = true
	s.gain_target = -60.0


func has_source(key: String) -> bool:
	return _sources.has(key) and not (_sources[key] as Src).dying


func source(key: String) -> Src:
	return _sources.get(key, null)


func sources() -> Array:
	return _sources.values()


## Every pool player created so far (never more than MAX_PLAYERS).
func players() -> Array[AudioStreamPlayer3D]:
	return _players


## Sources that hold a player right now.
func assigned() -> Array[Src]:
	var out: Array[Src] = []
	for s: Src in _assigned.keys():
		out.append(s)
	return out


func count_assigned(type: String = "") -> int:
	var n := 0
	for s: Src in _assigned.keys():
		if type.is_empty() or s.type == type:
			n += 1
	return n


## Drops every source and stops every player (load, New City, teardown).
func clear() -> void:
	for s: Src in _sources.values():
		_unassign(s, true)
	_sources.clear()
	_volatile.clear()
	_assigned.clear()
	for pl in _players:
		pl.stop()
		pl.stream = null
		pl.stream_paused = false
	_crew_sirens.clear()
	_honked.clear()
	_walkers.clear()
	_static_near.clear()
	_static_dirty = true


func force_refresh() -> void:
	_force = true


# ------------------------------------------------------------------ the world's static sources

## Registers every source that exists right now: construction sites, burning tiles, parks
## (fountains), coal plants and live incidents (initial scan after boot, load or New City).
func full_scan() -> void:
	var sim := ctx.sim
	if sim == null:
		return
	for key: String in _sources.keys():
		if not (_sources[key] as Src).volatile or key.begins_with("evs:"):
			_erase(key)
	for i: Variant in sim.sites.keys():
		add_site(int(i))
	for i in sim.active:
		var k := sim.kind[i]
		if sim.burning[i] > 0 or k == D.PARK or k == D.COAL:
			scan_tile(i)
	for ev: Dictionary in sim.events:
		on_event(ev, true)
	_static_dirty = true
	_force = true


## Construction loop at site tile i.
func add_site(i: int) -> void:
	request("site:%d" % i, "construction", _tile_pos(i) + Vector3(0.12, 0.05, -0.1), {"tag": i})


func remove_site(i: int) -> void:
	release("site:%d" % i)


## Fire, fountain and plant sources of tile i from its current state.
func scan_tile(i: int, holder: Node3D = null) -> void:
	var sim := ctx.sim
	var k := sim.kind[i]
	if sim.burning[i] > 0:
		request("fire:%d" % i, "fire", _tile_pos(i) + Vector3(0, 0.08, 0), {"tag": i})
	elif _sources.has("fire:%d" % i):
		release("fire:%d" % i)
	if k == D.PARK:
		if not has_source("foun:%d" % i):
			request("foun:%d" % i, "fountain", _fountain_pos(i, holder), {"tag": i})
	elif _sources.has("foun:%d" % i):
		release("foun:%d" % i)
	if k == D.COAL:
		if not has_source("plant:%d" % i):
			request("plant:%d" % i, "plant", _tile_pos(i) + Vector3(0, 0.15, 0), {"tag": i})
	elif _sources.has("plant:%d" % i):
		release("plant:%d" % i)
	if sim.sites.has(i):
		if not has_source("site:%d" % i):
			add_site(i)
	elif _sources.has("site:%d" % i):
		release("site:%d" % i)


func clear_tile(i: int) -> void:
	for p in ["fire:", "foun:", "plant:"]:
		if _sources.has(p + str(i)):
			release(p + str(i))


## An incident started (or exists at load): a siren at the scene until crews carry it, or for
## EVENT_SIREN_S when no crew shows up.
func on_event(ev: Dictionary, from_scan: bool = false) -> void:
	if not str(ev.get("type", "")) in SIREN_EVENTS:
		return
	var key := "evs:%d" % int(ev["id"])
	if has_source(key):
		return
	request(key, "siren", Vector3(int(ev["x"]), 0.1, int(ev["y"])), {"ttl": EVENT_SIREN_S if not from_scan else EVENT_SIREN_S * 0.5, "tag": int(ev["id"])})
	_force = true
	_force_wide = true


func on_event_ended(ev: Dictionary) -> void:
	release("evs:%d" % int(ev.get("id", -1)))
	_force = true


## River bank points (water tiles touching land), thinned to one per 3x3 cell, bucketed by chunk.
func rebuild_banks() -> void:
	_banks.clear()
	_river_at = Vector3(INF, INF, INF)
	var sim := ctx.sim
	if sim == null:
		return
	var taken := {}
	for y in range(D.Y0, D.Y0 + D.H):
		for x in range(D.X0, D.X0 + D.W):
			var i := D.idx(x, y)
			if sim.terrain[i] != D.WATER or sim.kind[i] == D.ROAD:
				continue
			var land := Vector2i.ZERO
			for dv: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx := x + dv.x
				var ny := y + dv.y
				if D.in_bounds(nx, ny) and sim.terrain[D.idx(nx, ny)] != D.WATER:
					land += dv
			if land == Vector2i.ZERO:
				continue
			var cell := Vector2i(floori(x / 3.0), floori(y / 3.0))
			if taken.has(cell):
				continue
			taken[cell] = true
			var p := Vector3(x + land.x * 0.3, WS.WATER_Y, y + land.y * 0.3)
			var ch := Vector2i(floori(x / 16.0), floori(y / 16.0))
			if not _banks.has(ch):
				_banks[ch] = PackedVector3Array()
			var arr: PackedVector3Array = _banks[ch]
			arr.append(p)
			_banks[ch] = arr
	_static_dirty = true


func bank_count() -> int:
	var n := 0
	for arr: PackedVector3Array in _banks.values():
		n += arr.size()
	return n


# ------------------------------------------------------------------ frame update

## One frame: refreshes agents and scores every REFRESH s, then moves, pitches and fades the
## sources that hold players. Tests call it directly with a fixed dt.
func step(dt: float) -> void:
	_now += dt
	if not enabled:
		return
	var lis := listener()
	_t_refresh += dt
	_t_siren += dt
	if _force or _t_refresh >= REFRESH:
		var wide := _force_wide or _t_siren >= SIREN_REFRESH
		_t_refresh = 0.0
		if wide:
			_t_siren = 0.0
		_force = false
		_force_wide = false
		_refresh(lis, wide)
	if not _walkers.is_empty():
		_step_walkers(dt)
	var lv := _listener_vel()
	var k_pitch := 1.0 - exp(-dt * 10.0)
	for s: Src in _assigned.keys():
		if _now >= s.expire_at and not s.dying:
			s.dying = true
			s.gain_target = -60.0
		var rate := DIE_RATE if s.dying else (FADE_IN_RATE if s.gain_db < s.gain_target else FADE_RATE)
		s.gain_db = move_toward(s.gain_db, s.gain_target, rate * dt)
		if s.dynamic and s.vel != Vector3.ZERO:
			s.pos += s.vel * dt
		if s.doppler:
			s.pitch = lerpf(s.pitch, s.pitch_base * doppler_factor(s.pos, s.vel, lis, lv), k_pitch)
		else:
			s.pitch = lerpf(s.pitch, s.pitch_base, k_pitch)
		if (s.dying and s.gain_db <= -50.0) or (s.one_shot and s.started and not s.player.playing):
			_erase(s.key)
			continue
		var pl := s.player
		pl.position = s.pos
		pl.pitch_scale = clampf(s.pitch, 0.25, 4.0)
		pl.volume_db = s.db + s.gain_db
		pl.max_db = s.db + float(TYPES[s.type]["near"])


## The listener: the current camera (behind the hero in third person), else the player's feet.
func listener() -> Vector3:
	if is_inside_tree():
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			return cam.global_position
	return ctx.player_position() if ctx != null else Vector3.ZERO


## pitch factor = 343 / (343 + v), v the source's receding speed in m/s relative to the listener,
## clamped to DOPPLER_MIN..DOPPLER_MAX.
static func doppler_factor(src: Vector3, src_vel: Vector3, lis: Vector3, lis_vel: Vector3) -> float:
	var dir := src - lis
	if dir.length_squared() < 1e-10:
		return 1.0
	var recede := (src_vel - lis_vel).dot(dir.normalized()) / WS.M
	return clampf(SPEED_OF_SOUND / maxf(SPEED_OF_SOUND + recede, 1.0), DOPPLER_MIN, DOPPLER_MAX)


## Engine pitch for a speed in u/s: 0.8 near standstill to 1.4 at about 95 km/h (1.1 at 50 km/h).
static func engine_pitch(speed: float) -> float:
	var m := speed / WS.M
	return 0.8 + 0.6 * clampf((m - 2.0) / 24.0, 0.0, 1.0)


## Estimated level (dB) of s at distance d: volume + inverse-distance gain (capped at max_db) and
## the linear fade to zero at max_distance, as AudioStreamPlayer3D computes them.
static func estimate_db(type: String, db: float, d: float) -> float:
	var spec: Dictionary = TYPES[type]
	var mx := float(spec["max"])
	if d >= mx:
		return -INF
	var att := linear_to_db(WS.AUDIO_UNIT_SIZE / maxf(d, 0.001))
	return minf(db + att, db + float(spec["near"])) + linear_to_db(maxf(1.0 - d / mx, 1e-4))


# ------------------------------------------------------------------ internals

func _refresh(lis: Vector3, wide: bool) -> void:
	_update_agents(lis, wide)
	_update_rivers(lis)
	if _static_dirty or lis.distance_to(_static_at) > 0.5:
		_collect_static(lis)
	var cand: Array[Src] = []
	var crew_heard := false
	# Volatile housekeeping: agents not seen again fade out; silent sources that expired, died or
	# already played their one shot are dropped now (an audible one finishes in step()).
	for s: Src in _volatile.values():
		if s.dynamic and not s.seen and not s.dying:
			s.dying = true
			s.gain_target = -60.0
		if s.player == null:
			if s.dying or _now >= s.expire_at or (s.one_shot and s.started):
				_erase(s.key)
				continue
			s.gain_db = s.gain_target
		if s.type == "siren" and s.key.begins_with("sir:") and s.player != null:
			crew_heard = true
	for s: Src in _volatile.values():
		if s.type == "siren" and s.key.begins_with("evs:") and not s.dying:
			s.gain_target = -40.0 if crew_heard else 0.0
	_apply_night()
	var pool: Array = _static_near.duplicate()
	pool.append_array(_volatile.values())
	var seen := {}
	for s: Src in pool:
		if seen.has(s) or _sources.get(s.key) != s:
			continue
		seen[s] = true
		if s.stream == null or (s.one_shot and s.started):
			if s.player != null:
				cand.append(s)
				s.score = INF
			continue
		s.dist = s.pos.distance_to(lis)
		var est := estimate_db(s.type, s.db + s.gain_target, s.dist)
		if est == -INF:
			continue
		# A horn wins a player from a loop; a passer-by's step only takes a spare one.
		s.score = est + (3.0 if s.player != null else 0.0) + (12.0 if s.one_shot and s.type != "step" else 0.0)
		cand.append(s)
	cand.sort_custom(func(a: Src, b: Src) -> bool: return a.score > b.score)
	var keep := {}
	for k in range(mini(MAX_PLAYERS, cand.size())):
		keep[cand[k]] = true
	for s: Src in _assigned.keys():
		if not keep.has(s):
			_unassign(s)
			if s.one_shot or s.dying:
				_erase(s.key)
	_fresh_ogg = 0
	for s: Src in keep.keys():
		if s.player == null:
			_assign(s)
	# Dynamic sources must be seen again by the next refresh or they fade out.
	for s: Src in _volatile.values():
		if s.dynamic:
			s.seen = false


func _collect_static(lis: Vector3) -> void:
	_static_near.clear()
	_static_at = lis
	_static_dirty = false
	for s: Src in _sources.values():
		if s.volatile or _sources.get(s.key) != s:
			continue
		if s.type == "fire" and s.tag >= 0 and ctx.sim != null and ctx.sim.burning[s.tag] == 0 and not s.dying:
			release(s.key)
		if _sources.get(s.key) == s and s.pos.distance_to(lis) <= float(TYPES[s.type]["max"]) + 1.0:
			_static_near.append(s)
	_apply_night()


func _apply_night() -> void:
	for s: Src in _static_near:
		if s.type == "construction" and not s.dying:
			s.gain_target = -16.0 * clampf(night, 0.0, 1.0)


func _update_rivers(lis: Vector3) -> void:
	if _banks.is_empty() or (lis.distance_to(_river_at) < 0.15 and not _static_dirty):
		return
	_river_at = lis
	var cx := floori(lis.x / 16.0)
	var cz := floori(lis.z / 16.0)
	var best: Array = []
	var mx: float = TYPES["river"]["max"]
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var arr: PackedVector3Array = _banks.get(Vector2i(cx + dx, cz + dz), PackedVector3Array())
			for p: Vector3 in arr:
				var d := p.distance_to(lis)
				if d < mx:
					best.append([d, p])
	best.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var want := {}
	for k in range(mini(RIVER_SOURCES, best.size())):
		var p: Vector3 = best[k][1]
		var key := "river:%d:%d" % [roundi(p.x * 10.0), roundi(p.z * 10.0)]
		want[key] = true
		if not has_source(key):
			request(key, "river", p)
	for s: Src in _volatile.values():
		if s.type == "river" and not want.has(s.key) and not s.dying:
			release(s.key)


## Engines, horns and crew sirens from E's agents (or the test provider, or CityLife's legacy
## road vehicles while E is absent).
func _update_agents(lis: Vector3, wide: bool) -> void:
	var traffic := _traffic()
	var e_mode := agents_provider.is_valid() or traffic != null
	var near: Array = _agents(lis, ENGINE_RADIUS, traffic) if e_mode else _life_agents(lis)
	var cars: Array = []
	for a: Dictionary in near:
		var kind := str(a.get("kind", "car"))
		if kind == "pedestrian":
			continue
		var d := (a["pos"] as Vector3).distance_to(lis)
		if d <= ENGINE_RADIUS:
			cars.append([d, a])
	cars.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0]))
	for k in range(mini(ENGINE_CARS, cars.size())):
		var a: Dictionary = cars[k][1]
		_engine(a, e_mode)
	if e_mode:
		_horns(near, lis)
		_update_walkers(near)
	else:
		_walkers.clear()
	var live := ctx.sim != null and not ctx.sim.events.is_empty()
	if wide:
		_crew_sirens.clear()
		var far: Array = []
		if live:
			far = _agents(lis, float(TYPES["siren"]["max"]), traffic) if e_mode else _life_crews(lis)
		for a: Dictionary in far:
			var siren: bool = a.get("siren", str(a.get("kind", "")) == "emergency")
			if not siren:
				continue
			var spd := float(a.get("speed", (a.get("vel", Vector3.ZERO) as Vector3).length()))
			if spd < 1.0 * WS.M and not a.has("life"):
				continue
			var key := "sir:%s" % str(a["id"])
			_crew_sirens[key] = true
			request(key, "siren", a["pos"], {"vel": a.get("vel", Vector3.ZERO), "doppler": e_mode, "dynamic": true})
	else:
		for key: String in _crew_sirens.keys():
			var s: Src = _sources.get(key, null)
			if s != null:
				s.seen = true


func _engine(a: Dictionary, e_mode: bool) -> void:
	var kind := str(a.get("kind", "car"))
	var heavy := kind in ["bus", "truck", "garbage_truck", "emergency"]
	var key := "eng:%s" % str(a["id"])
	var speed := float(a.get("speed", 0.0))
	var opts := {"vel": a.get("vel", Vector3.ZERO), "dynamic": true, "doppler": e_mode}
	if not e_mode:
		# CityLife's legacy vehicles report no speed: idle pitch and volume, no doppler.
		opts["pitch"] = 0.85 * (0.75 if heavy else 1.0)
		opts["gain"] = -5.0
		opts["trim_db"] = 3.0 if heavy else 0.0
		request(key, "engine", a["pos"], opts)
		return
	var m := speed / WS.M
	var idle := m < 0.6
	var s: Src = _sources.get(key, null)
	if s != null and s.stream == BANK.stream("engine_idle") and m < 1.5:
		idle = true
	opts["stream"] = "engine_idle" if idle else "engine_run"
	opts["pitch"] = (1.0 if idle else engine_pitch(speed)) * (0.74 if heavy else 1.0)
	opts["gain"] = -2.0 if idle else lerpf(-9.0, 0.0, clampf(m / 12.0, 0.0, 1.0))
	opts["trim_db"] = 4.0 if heavy else 0.0
	request(key, "engine", a["pos"], opts)


func _horns(near: Array, lis: Vector3) -> void:
	if time_scale >= 4 or _now < _next_horn:
		return
	for a: Dictionary in near:
		if not a.has("stalled_s") or str(a.get("kind", "")) in ["pedestrian", "emergency"]:
			continue
		var stalled := float(a["stalled_s"])
		if stalled <= HORN_STALL_S:
			continue
		var id := str(a.get("id", ""))
		if _now - float(_honked.get(id, -INF)) < HORN_CAR_REST:
			continue
		var p: Vector3 = a["pos"]
		if p.distance_to(lis) > float(TYPES["horn"]["max"]):
			continue
		var urge := clampf((stalled - HORN_STALL_S) / (HORN_STALL_FULL_S - HORN_STALL_S), 0.0, 1.0)
		var rate := HORN_RATE * urge * (0.35 + 0.65 * _congestion(p))
		if _rng.randf() >= 1.0 - exp(-rate * REFRESH):
			continue
		_next_horn = _now + _rng.randf_range(HORN_GAP, HORN_GAP_MAX)
		_honked[id] = _now
		if _honked.size() > 64:
			for k: String in _honked.keys():
				if _now - float(_honked[k]) >= HORN_CAR_REST:
					_honked.erase(k)
		# A long lean on the horn is likelier the longer the jam has lasted.
		horn(p, "horn_long" if _rng.randf() < 0.15 + 0.25 * urge else "horn_short", float(a.get("speed", 0.0)))
		return


## The sim's congestion 0..1 on the tile under p (0 without a sim).
func _congestion(p: Vector3) -> float:
	var sim := ctx.sim if ctx != null else null
	var x := roundi(p.x)
	var y := roundi(p.z)
	if sim == null or not D.in_bounds(x, y):
		return 0.0
	return clampf(float(sim.traffic[D.idx(x, y)]), 0.0, 1.0)


## Keeps the WALKER_MAX nearest residents walking within WALKER_RADIUS of the hero, each with its
## own stride phase while it stays in the set.
func _update_walkers(near: Array) -> void:
	var hero := ctx.player_position() if ctx != null else Vector3.ZERO
	var picks: Array = []
	for a: Dictionary in near:
		if str(a.get("kind", "")) != "pedestrian":
			continue
		var p: Vector3 = a["pos"]
		var d := Vector2(p.x - hero.x, p.z - hero.z).length()
		if d > WALKER_RADIUS:
			continue
		var v: Vector3 = a.get("vel", Vector3.ZERO)
		var mps := float(a.get("speed", Vector2(v.x, v.z).length())) / WS.M
		if mps < WALKER_MIN_MPS or mps > WALKER_MAX_MPS:
			continue
		picks.append([d, a])
	picks.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0]))
	var keep := {}
	for k in range(mini(WALKER_MAX, picks.size())):
		var a: Dictionary = picks[k][1]
		var id := str(a["id"])
		keep[id] = true
		var w: Dictionary = _walkers.get(id, {})
		if w.is_empty():
			w = {"travel": _rng.randf() * FS.STRIDE_M * WS.M, "left": _rng.randf() < 0.5}
			_walkers[id] = w
		w["pos"] = a["pos"]
		w["vel"] = a.get("vel", Vector3.ZERO)
	for id: String in _walkers.keys():
		if not keep.has(id):
			_walkers.erase(id)


## Moves the heard walkers on and sounds a step each time one covers a stride.
func _step_walkers(dt: float) -> void:
	for w: Dictionary in _walkers.values():
		var v: Vector3 = w["vel"]
		var flat := Vector2(v.x, v.z).length()
		w["pos"] = (w["pos"] as Vector3) + v * dt
		var travel := float(w["travel"]) + flat * dt
		var stride := FS.stride_length(flat / WS.M) * WS.M
		if travel >= stride:
			travel = fmod(travel, stride)
			_walker_step(w)
		w["travel"] = travel


## One positional step of walker w on the surface under it; skipped when every player is busy.
func _walker_step(w: Dictionary) -> void:
	if _players.size() >= MAX_PLAYERS and _free.is_empty():
		return
	var p: Vector3 = w["pos"]
	var surf := ctx.collision.surface_at(p) if ctx != null and ctx.collision != null else "sidewalk"
	if not surf in BANK.SURFACES:
		surf = "sidewalk"
	var left: bool = w["left"]
	w["left"] = not left
	var pool: Array[int] = FS.LEFT_VARIANTS if left else FS.RIGHT_VARIANTS
	_step_seq += 1
	walker_steps += 1
	var s := request("wstep:%d" % _step_seq, "step", p, {"stream": BANK.step_name(surf, pool[_rng.randi() % pool.size()]),
		"one_shot": true, "pitch": _rng.randf_range(0.92, 1.08), "trim_db": _rng.randf_range(-3.0, 0.0), "ttl": 1.0})
	_assign(s)


## A one-shot horn at p (tests call it directly).
func horn(p: Vector3, stream_name: String = "horn_short", _speed: float = 0.0) -> Src:
	_horn_seq += 1
	horns_played += 1
	_force = true
	return request("horn:%d" % _horn_seq, "horn", p, {"stream": stream_name, "one_shot": true,
		"pitch": _rng.randf_range(0.96, 1.04), "trim_db": _rng.randf_range(-2.0, 1.0), "ttl": 2.5})


func _traffic() -> FpFeature:
	var f := ctx.feature("traffic") if ctx != null else null
	return f if f != null and f.has_method("agents_near") else null


func _agents(lis: Vector3, r: float, traffic: FpFeature) -> Array:
	if agents_provider.is_valid():
		return agents_provider.call(lis, r)
	return traffic.call("agents_near", lis, r) if traffic != null else []


## CityLife's road vehicles near lis (buses, trucks, crews) while E is absent.
func _life_agents(lis: Vector3) -> Array:
	var out: Array = []
	var life: Node = ctx.view.life if ctx.view != null else null
	if life == null:
		return out
	for list_name in ["_buses", "_trucks", "_crews"]:
		var list: Variant = life.get(list_name)
		if typeof(list) != TYPE_ARRAY:
			continue
		for a: Dictionary in list:
			var n: Node3D = a.get("node", null)
			if n == null or not is_instance_valid(n) or not n.is_inside_tree():
				continue
			var p := n.global_position
			if p.distance_to(lis) <= ENGINE_RADIUS:
				out.append({"id": "life%d" % n.get_instance_id(), "pos": p, "kind": "bus" if list_name == "_buses" else "truck"})
	return out


## CityLife's crews driving to a live incident while E is absent.
func _life_crews(lis: Vector3) -> Array:
	var out: Array = []
	var life: Node = ctx.view.life if ctx.view != null else null
	if life == null or ctx.sim == null:
		return out
	var live := {}
	for ev: Dictionary in ctx.sim.events:
		live[int(ev["id"])] = true
	var crews: Variant = life.get("_crews")
	if typeof(crews) != TYPE_ARRAY:
		return out
	for a: Dictionary in crews:
		var n: Node3D = a.get("node", null)
		if n == null or not is_instance_valid(n) or not n.is_inside_tree() or not live.has(int(a.get("event_id", -1))):
			continue
		if (a.get("path", []) as Array).is_empty() and a.get("to") == a.get("target"):
			continue    # arrived: lights on, siren off
		var p := n.global_position
		if p.distance_to(lis) <= float(TYPES["siren"]["max"]):
			out.append({"id": "life%d" % n.get_instance_id(), "pos": p, "kind": "emergency", "siren": true, "life": true})
	return out


func _listener_vel() -> Vector3:
	if ctx != null and ctx.player != null and is_instance_valid(ctx.player):
		return ctx.player.velocity
	return Vector3.ZERO


## Gives s a player: a released one still holding s's stream resumes where it paused (no new
## playback); else a new one while fewer than MAX_PLAYERS exist; else the oldest released one.
## At most one Ogg playback starts per refresh (each costs ~0.4 ms); the rest wait a refresh.
## A loop fades in over FADE_IN_DB, so taking a player never pops.
func _assign(s: Src) -> void:
	var pl: AudioStreamPlayer3D = null
	for k in range(_free.size() - 1, -1, -1):
		if _free[k].stream == s.stream and s.stream != null and not s.one_shot:
			pl = _free[k]
			_free.remove_at(k)
			_bind(s, pl)
			pl.stream_paused = false
			if not pl.playing:
				pl.play(_rng.randf() * maxf(s.stream.get_length() - 0.1, 0.0))
			return
	if s.stream is AudioStreamOggVorbis:
		if _fresh_ogg >= 1:
			return
		_fresh_ogg += 1
	if _players.size() < MAX_PLAYERS:
		pl = AudioStreamPlayer3D.new()
		pl.name = "Emitter%d" % _players.size()
		pl.unit_size = WS.AUDIO_UNIT_SIZE
		pl.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		pl.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		pl.bus = BANK.BUS_SFX
		pl.attenuation_filter_db = FILTER_DB
		pl.attenuation_filter_cutoff_hz = FILTER_HZ
		add_child(pl)
		_players.append(pl)
	elif not _free.is_empty():
		pl = _free.pop_front()
	if pl == null:
		return
	_bind(s, pl)
	pl.stream = s.stream
	_restart(s)


## Hands player pl to s and sets it to s's place, pitch and (faded-in) level.
func _bind(s: Src, pl: AudioStreamPlayer3D) -> void:
	s.player = pl
	_assigned[s] = true
	if not s.one_shot and not s.dying:
		s.gain_db = s.gain_target - FADE_IN_DB
	pl.max_distance = float(TYPES[s.type]["max"])
	pl.position = s.pos
	pl.pitch_scale = clampf(s.pitch, 0.25, 4.0)
	pl.volume_db = s.db + s.gain_db
	pl.max_db = s.db + float(TYPES[s.type]["near"])


func _restart(s: Src) -> void:
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
func _unassign(s: Src, full_stop: bool = false) -> void:
	var pl := s.player
	_assigned.erase(s)
	if pl == null:
		return
	s.player = null
	pl.volume_db = -80.0
	if s.one_shot or full_stop:
		pl.stop()
		pl.stream = null
	else:
		pl.stream_paused = true
	_free.append(pl)


## Forgets source key: frees its player and drops it from every set.
func _erase(key: String) -> void:
	var s: Src = _sources.get(key, null)
	if s == null:
		return
	_unassign(s)
	_sources.erase(key)
	_volatile.erase(key)
	if not s.volatile:
		_static_dirty = true


func _tile_pos(i: int) -> Vector3:
	return Vector3(D.tx(i), 0.0, D.ty(i))


## The park model's fountain basin when the holder has one, else the tile centre.
func _fountain_pos(i: int, holder: Node3D) -> Vector3:
	var h := holder
	if h == null and ctx.view != null:
		h = ctx.view.tile_holder(i)
	if h != null and is_instance_valid(h) and h.is_inside_tree():
		var basin := h.find_child("basin", true, false) as Node3D
		if basin != null:
			return basin.global_position + Vector3(0, 0.03, 0)
	return _tile_pos(i) + Vector3(0, 0.03, 0)
