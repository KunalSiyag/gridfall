extends Node
## Area ambience (slice I): looping 2D beds on the Ambience bus (traffic hum, park birds, river,
## the quiet residential bed, night insects and rain), weighted by what lies around the player and
## by the weather, and cross-faded over CROSSFADE_S. At most MAX_PLAYING beds play at once: a bed
## whose weight falls under MIN_WEIGHT stops, and the weakest bed yields when another would start.

const D := preload("res://scripts/sim/sim_defs.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")

const BED_NAMES: Array[String] = ["traffic_hum", "park_birds", "river", "residential_quiet", "night_insects", "rain"]
const MAX_PLAYING := 4
const MIN_WEIGHT := 0.02
const CROSSFADE_S := 3.0
const RECOMPUTE_S := 2.0
## Neighbourhood radius in tiles (water counts within WATER_R).
const AREA_R := 4
const WATER_R := 3
## Rain bed level while it rains (G1's streetscape weather); birds and insects shelter meanwhile.
const RAIN_WEIGHT := 0.85

var ctx: FpContext
## bed -> target weight 0..1 and current smoothed level 0..1.
var weights: Dictionary = {}
var levels: Dictionary = {}
var players: Dictionary = {}           # bed -> AudioStreamPlayer
## 0 (open land, parks) .. 1 (dense commercial streets); drives the SFX bus reverb.
var urban: float = 0.0
var night: float = 0.0
## 1 while it rains, else 0 (G1's weather state; 0 without the streetscape feature).
var rain: float = 0.0
var enabled: bool = true
## Most beds ever playing at once (tests).
var max_seen_playing: int = 0
var _t: float = 0.0
var _rng := RandomNumberGenerator.new()


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	_rng.seed = 3301
	for b in BED_NAMES:
		var p := AudioStreamPlayer.new()
		p.name = "Bed_" + b
		p.bus = BANK.BUS_AMBIENCE
		p.stream = BANK.bed_stream(b)
		p.volume_db = -80.0
		add_child(p)
		players[b] = p
		weights[b] = 0.0
		levels[b] = 0.0


## Recomputes the bed weights now (player_tile_changed, world rebuilt, every RECOMPUTE_S).
func recompute() -> void:
	_t = 0.0
	var sim := ctx.sim if ctx != null else null
	if sim == null:
		return
	var p := ctx.player_position()
	var cx := roundi(p.x)
	var cy := roundi(p.z)
	night = clampf(float(ctx.sky.night), 0.0, 1.0) if ctx.sky != null else 0.0
	rain = 1.0 if weather_state() == "rain" else 0.0
	var total := 0.0
	var green := 0.0
	var ci := 0.0
	var res := 0.0
	var road := 0.0
	var jam := 0.0
	var water := 0.0
	var r2 := float(AREA_R * AREA_R) + 0.5
	for dy in range(-AREA_R, AREA_R + 1):
		for dx in range(-AREA_R, AREA_R + 1):
			var dd := float(dx * dx + dy * dy)
			if dd > r2:
				continue
			var x := cx + dx
			var y := cy + dy
			var w := 1.0 - sqrt(dd) / (AREA_R + 1.0)
			total += w
			if not D.in_bounds(x, y):
				green += w
				continue
			var i := D.idx(x, y)
			var k := sim.kind[i]
			if sim.terrain[i] == D.WATER and k != D.ROAD:
				var d := Vector2(p.x - x, p.z - y).length()
				if d <= WATER_R + 0.5:
					water = maxf(water, 1.0 - maxf(d - 0.5, 0.0) / (WATER_R + 0.5))
				continue
			if k == D.ROAD:
				road += w
				jam += w * sim.traffic[i]
			elif k == D.PARK or k == D.FOREST or k == D.EMPTY:
				green += w * (1.0 if k != D.EMPTY else 0.6)
			elif (k == D.ZONE_C or k == D.ZONE_I) and sim.level[i] > 0:
				ci += w * (1.0 + 0.25 * mini(sim.level[i], 3))
			elif k == D.ZONE_R and sim.level[i] > 0:
				res += w
			elif D.is_service(k) or k == D.SITE:
				ci += w * 0.5
	var f_green := green / total
	var f_ci := ci / total
	var f_res := res / total
	var f_road := road / total
	var f_jam := jam / maxf(road, 0.001)
	urban = clampf(f_ci * 1.6 + f_road * 0.8, 0.0, 1.0)
	var traffic := clampf(0.05 + 0.35 * f_road + 1.1 * f_ci + 0.6 * f_jam * minf(f_road * 3.0, 1.0), 0.0, 0.9)
	traffic *= lerpf(1.0, 0.55, night)
	weights["traffic_hum"] = traffic
	weights["park_birds"] = clampf(1.5 * f_green - 0.1, 0.0, 1.0) * lerpf(1.0, 0.2, night) * (1.0 - 0.85 * rain)
	weights["river"] = clampf(1.2 * water, 0.0, 1.0)
	weights["residential_quiet"] = clampf(1.6 * f_res + 0.1 * f_green, 0.0, 1.0) * (1.0 - 0.6 * traffic) * lerpf(1.0, 0.65, night) * (1.0 - 0.5 * rain)
	weights["night_insects"] = night * clampf(1.3 * (f_res + f_green) + 0.1, 0.0, 1.0) * (1.0 - 0.7 * traffic) * (1.0 - 0.9 * rain)
	weights["rain"] = RAIN_WEIGHT * rain


## G1's weather state ("clear", "overcast", "rain"), read by name from the streetscape feature;
## "" when that feature is absent.
func weather_state() -> String:
	var street := ctx.feature("streetscape") if ctx != null else null
	if street == null:
		return ""
	var w: Variant = street.get("weather")
	if not (w is Object) or not is_instance_valid(w):
		return ""
	var st: Variant = (w as Object).get("state")
	return str(st) if typeof(st) == TYPE_STRING else ""


## One frame: recompute every RECOMPUTE_S, move the levels toward the weights (a full fade takes
## CROSSFADE_S), start and stop beds under the MAX_PLAYING cap.
func step(dt: float) -> void:
	if not enabled:
		return
	_t += dt
	if _t >= RECOMPUTE_S:
		recompute()
	var rate := dt / CROSSFADE_S
	for b in BED_NAMES:
		var p: AudioStreamPlayer = players[b]
		var w: float = weights[b]
		var lv: float = levels[b]
		if not p.playing:
			if w >= MIN_WEIGHT and p.stream != null and _make_room(b):
				lv = 0.0
				p.play(_rng.randf() * maxf(p.stream.get_length() - 0.5, 0.0))
			else:
				levels[b] = 0.0
				continue
		lv = move_toward(lv, w, rate)
		levels[b] = lv
		if w < MIN_WEIGHT and lv < MIN_WEIGHT:
			p.stop()
			levels[b] = 0.0
			continue
		p.volume_db = float(BANK.BEDS[b][1]) + linear_to_db(maxf(lv, 0.001))
	max_seen_playing = maxi(max_seen_playing, playing_count())


func playing_count() -> int:
	var n := 0
	for b in BED_NAMES:
		if (players[b] as AudioStreamPlayer).playing:
			n += 1
	return n


## The bed with the largest current level.
func loudest() -> String:
	var best := ""
	var bl := -1.0
	for b in BED_NAMES:
		if float(levels[b]) > bl:
			bl = float(levels[b])
			best = b
	return best


func stop_all() -> void:
	for b in BED_NAMES:
		(players[b] as AudioStreamPlayer).stop()
		levels[b] = 0.0


## True when bed b may start: fewer than MAX_PLAYING play, or the weakest playing bed has a lower
## weight than b and is stopped to make room.
func _make_room(b: String) -> bool:
	if playing_count() < MAX_PLAYING:
		return true
	var weakest := ""
	var ww := INF
	for o in BED_NAMES:
		if o != b and (players[o] as AudioStreamPlayer).playing and float(weights[o]) < ww:
			ww = float(weights[o])
			weakest = o
	if weakest.is_empty() or ww >= float(weights[b]):
		return false
	(players[weakest] as AudioStreamPlayer).stop()
	levels[weakest] = 0.0
	return true
