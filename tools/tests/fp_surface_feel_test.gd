extends SceneTree
## Surface feel (unit G1, flag surface_feel): every ground class the hero walks on feels and sounds
## like itself. The table (surface_feel.gd) pins each class's footstep set, level, pitch, speed and
## dust; the live city classifies a point (asphalt, sidewalk, lot, grass, sand on a river's
## shore and its dry shelf, water, bridge, gravel, dirt, trail); footsteps play each class's
## recorded set at its
## own level and pitch (a class without recordings borrows the nearest, told apart by level and
## pitch); the hero's top speed on each is the table's factor (pavement full speed, sand slowest);
## a sprinting step on dry sand, dirt, gravel or a trail raises a puff of dust and on nothing else;
## and with the flag off every surface sounds, runs and looks as before.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const SF := preload("res://scripts/fp/world/surface_feel.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")
const FS := preload("res://scripts/fp/audio/footsteps.gd")
const DT := 1.0 / 60.0
const M := WS.M
const CLASSES := [
	"asphalt", "sidewalk", "lot", "grass", "sand", "dirt", "gravel", "trail", "bridge", "water"
]

var fails: Array[String] = []
## class -> {"pos": a point of it, "dir": a clear line along it}, filled by _find_all.
var spots := {}


## A stand-in streetscape feature whose weather says how wet the streets are.
class Wet:
	extends FpFeature
	var weather := WetWeather.new()

	func feature_id() -> String:
		return "streetscape"


class WetWeather:
	extends RefCounted
	var wet: float = 0.0


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("surface_feel", true)
	_check_table()
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	_make_tracks(ctx)
	_find_all(ctx)
	_check_classes(ctx)
	var audio := K.make_feature(ctx, "audio")
	K.check(fails, audio != null, "fixture: the audio feature sets up")
	if audio != null:
		_check_footsteps(ctx, audio)
	_check_speed(ctx)
	_check_dust(ctx)
	_check_flag_off(ctx, audio)
	K.finish(self, "FP_SURFACE_FEEL_TEST", fails)


# ------------------------------------------------------------------ the table


func _check_table() -> void:
	K.check(
		fails,
		(
			SF.TABLE.size() == CLASSES.size()
			and CLASSES.all(func(c: String) -> bool: return SF.TABLE.has(c))
		),
		"the table has the ten classes"
	)
	var triples := {}
	var sets_ok := true
	for c: String in CLASSES:
		var row: Dictionary = SF.TABLE[c]
		sets_ok = (
			sets_ok
			and str(row["set"]) in BANK.SURFACES
			and BANK.stream(BANK.step_name(str(row["set"]), 1)) != null
		)
		triples["%s|%s|%s" % [row["set"], row["gain"], row["pitch"]]] = true
	K.check(fails, sets_ok, "every class plays a recorded step set (nothing new is shipped)")
	K.check(
		fails,
		triples.size() == CLASSES.size(),
		"no two classes sound the same (set, level, pitch): %d distinct" % triples.size()
	)
	var paved := ["asphalt", "sidewalk", "lot", "bridge", "water"]
	var full := paved.all(func(c: String) -> bool: return SF.speed(c) == 1.0)
	K.check(
		fails, full, "pavement, slabs, the bridge and water (the wade has its own) are full speed"
	)
	var slow := ["grass", "sand", "dirt", "gravel", "trail"]
	K.check(
		fails,
		slow.all(func(c: String) -> bool: return SF.speed(c) < 1.0 and SF.speed(c) >= 0.9),
		"grass, sand, dirt, gravel and trail are a few per cent slower (0.90 to 1)"
	)
	K.check(
		fails,
		(
			SF.speed("sand") < SF.speed("dirt")
			and SF.speed("sand") < SF.speed("grass")
			and SF.speed("sand") == 0.93
		),
		"sand is the softest: %.2f" % SF.speed("sand")
	)
	K.check(
		fails,
		(
			SF.dust("sand") == 1.0
			and SF.dust("dirt") > 0.0
			and SF.dust("gravel") > 0.0
			and SF.dust("trail") > 0.0
		),
		"sand, dirt, gravel and trail raise dust"
	)
	K.check(
		fails,
		paved.all(func(c: String) -> bool: return SF.dust(c) == 0.0) and SF.dust("grass") == 0.0,
		"pavement, grass, the bridge and water raise none"
	)
	K.check(
		fails,
		(
			SF.row("nonsense") == SF.TABLE[SF.FALLBACK]
			and SF.speed("nonsense") == 1.0
			and SF.dust("nonsense") == 0.0
		),
		"an unknown name is the sidewalk's"
	)
	K.check(
		fails,
		(
			SF.TABLE["sand"]["pitch"] < SF.TABLE["dirt"]["pitch"]
			and SF.TABLE["gravel"]["pitch"] > SF.TABLE["dirt"]["pitch"]
			and SF.TABLE["grass"]["gain"] < SF.TABLE["asphalt"]["gain"]
		),
		"sand is lower than dirt, gravel higher, grass softer than asphalt"
	)


# ------------------------------------------------------------------ the live city


## Grades three straight road tiles gravel, dirt and trail.
func _make_tracks(ctx: FpContext) -> void:
	var sim := ctx.sim
	var grades := [D.GRADE_GRAVEL, D.GRADE_DIRT, D.GRADE_TRAIL]
	var k := 0
	for i in sim.active:
		if k >= 3 or sim.kind[i] != D.ROAD or sim.terrain[i] == D.WATER:
			continue
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		if m != RoadTopology.NS and m != RoadTopology.EW:
			continue
		if (
			k > 0
			and (absi(D.tx(i) - D.tx(_first_track)) < 3 and absi(D.ty(i) - D.ty(_first_track)) < 3)
		):
			continue
		if k == 0:
			_first_track = i
		sim.level[i] = grades[k]
		k += 1


var _first_track := -1


func _surface(ctx: FpContext, p: Vector3) -> String:
	return ctx.collision.surface_at(p)


func _class(ctx: FpContext, p: Vector3) -> String:
	return SF.feel_at(ctx.collision, _surface(ctx, p), p)


## A point and a clear straight line of 0.2 tile along one class, for each class the city has.
func _find_all(ctx: FpContext) -> void:
	var col := ctx.collision
	var sim := ctx.sim
	var wanted := CLASSES.duplicate()
	wanted.erase("water")
	for x in range(-46, 47):
		for y in range(-46, 47):
			if wanted.is_empty():
				break
			if not D.in_bounds(x, y):
				continue
			var i := D.idx(x, y)
			if sim.kind[i] == D.FOREST and sim.terrain[i] != D.WATER:
				continue
			for ox in [-0.4, -0.2, 0.0, 0.2, 0.4]:
				for oz in [-0.4, -0.2, 0.0, 0.2, 0.4]:
					var p := Vector3(x + ox, 0.0, y + oz)
					var c := _class(ctx, p)
					if not wanted.has(c) or spots.has(c):
						continue
					for dir: Vector3 in [
						Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, 0, -1)
					]:
						if _line_ok(ctx, p, dir, c):
							var q := p
							q.y = col.walk_height(p)
							spots[c] = {"pos": q, "dir": dir}
							break
	_find_sand(ctx)
	print("  note classes found in the city: %s" % str(spots.keys()))


## The shore band is 1.5 m wide: a straight 4 m of it along a bank, found from the water's edge.
func _find_sand(ctx: FpContext) -> void:
	var sim := ctx.sim
	var dirs: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for x in range(-46, 47):
		for y in range(-46, 47):
			if spots.has("sand"):
				return
			if not D.in_bounds(x, y) or sim.terrain[D.idx(x, y)] != D.WATER:
				continue
			for dv: Vector2i in dirs:
				var lx := x + dv.x
				var ly := y + dv.y
				if not D.in_bounds(lx, ly) or sim.terrain[D.idx(lx, ly)] == D.WATER:
					continue
				var out := Vector3(dv.x, 0.0, dv.y)
				var along := Vector3(-out.z, 0.0, out.x)
				for off: float in [-0.3, -0.15, 0.0, 0.15, 0.3]:
					var p := Vector3(x, 0.0, y) + out * 0.5 + out * 0.03 + along * off
					if _class(ctx, p) == "sand" and _line_ok(ctx, p, along, "sand"):
						p.y = ctx.collision.walk_height(p)
						spots["sand"] = {"pos": p, "dir": along}
						return


func _line_ok(ctx: FpContext, p: Vector3, dir: Vector3, c: String) -> bool:
	var col := ctx.collision
	for k in range(0, 13):
		var q := p + dir * (0.02 * k)
		var g := col.walk_height(q)
		if (
			is_nan(g)
			or col.is_blocked(Vector3(q.x, g, q.z), WS.PLAYER_RADIUS * 1.6)
			or _class(ctx, q) != c
		):
			return false
	return true


## The dry shelf of a bank (water shallower than 3 cm) is sand; deeper is water.
func _check_shelf(ctx: FpContext, water: int) -> void:
	var col := ctx.collision
	var sim := ctx.sim
	var found_shelf := false
	var found_deep := false
	for dx in range(-8, 9):
		for dz in range(-8, 9):
			var p := Vector3(D.tx(water) + 0.06 * dx, 0.0, D.ty(water) + 0.06 * dz)
			if (
				sim.terrain[D.idx(roundi(p.x), roundi(p.z))] != D.WATER
				or sim.kind[D.idx(roundi(p.x), roundi(p.z))] == D.ROAD
			):
				continue
			var depth := col.water_depth(p)
			var c := _class(ctx, p)
			if depth < SF.SHELF_M * M and c == "sand":
				found_shelf = true
			if depth >= SF.SHELF_M * M and c == "water":
				found_deep = true
			if (c == "sand") != (depth < SF.SHELF_M * M):
				K.check(fails, false, "water %.3f m deep is %s" % [depth / M, c])
	K.check(
		fails,
		found_shelf and found_deep,
		"a river bank has a sand shelf and deeper water (%s, %s)" % [found_shelf, found_deep]
	)


func _check_classes(ctx: FpContext) -> void:
	for c: String in ["asphalt", "sidewalk", "grass", "sand", "gravel", "dirt", "trail"]:
		K.check(
			fails,
			spots.has(c),
			"a clear 4 m of %s exists to walk (%s)" % [c, str(spots.get(c, {}).get("pos", "none"))]
		)
	# Lot, bridge and water: classified, walked or not.
	var col := ctx.collision
	var sim := ctx.sim
	var lot := -1
	var bridge := -1
	var water := -1
	for i in sim.active:
		if (
			lot < 0
			and D.is_zone(sim.kind[i])
			and sim.level[i] > 0
			and col.surface_at(Vector3(D.tx(i), 0, D.ty(i))) == "lot"
		):
			lot = i
		if bridge < 0 and RoadTopology.is_bridge(sim, i):
			bridge = i
		if water < 0 and sim.terrain[i] == D.WATER and sim.kind[i] != D.ROAD:
			water = i
	K.check(
		fails,
		lot >= 0 and _class(ctx, Vector3(D.tx(lot), 0, D.ty(lot))) == "lot",
		"a built lot is lot"
	)
	K.check(
		fails,
		bridge >= 0 and _class(ctx, Vector3(D.tx(bridge), 0, D.ty(bridge))) == "bridge",
		"a bridge is bridge"
	)
	K.check(
		fails,
		water >= 0 and _class(ctx, Vector3(D.tx(water), 0, D.ty(water))) == "water",
		"the middle of the river is water"
	)
	if water >= 0:
		_check_shelf(ctx, water)
	# Grass next to water is sand, grass away from it is grass.
	var sand: Dictionary = spots.get("sand", {})
	var grass: Dictionary = spots.get("grass", {})
	K.check(
		fails,
		(
			not sand.is_empty()
			and SF.near_water(sim, sand["pos"])
			and not grass.is_empty()
			and not SF.near_water(sim, grass["pos"])
		),
		"sand is the shore band, grass is not"
	)


# ------------------------------------------------------------------ footsteps


func _check_footsteps(ctx: FpContext, audio: FpFeature) -> void:
	var fs: FS = audio.get("footsteps")
	K.check(fails, fs != null, "the footsteps exist")
	if fs == null:
		return
	ctx.player.velocity = Vector3.ZERO
	var base := BANK.STEP_DB
	for c: String in CLASSES:
		var row: Dictionary = SF.TABLE[c]
		var db_lo := 999.0
		var db_hi := -999.0
		var pitch_lo := 99.0
		var pitch_hi := 0.0
		var sets := {}
		for k in range(24):
			fs.play_feel(c)
			var last := str(fs.history.back())
			sets[last.rsplit("_", true, 1)[0]] = true
			db_lo = minf(db_lo, fs.last_db)
			db_hi = maxf(db_hi, fs.last_db)
			pitch_lo = minf(pitch_lo, fs.last_pitch)
			pitch_hi = maxf(pitch_hi, fs.last_pitch)
		var want_set := (
			"footstep_splash" if str(row["set"]) == "water" else "footstep_%s" % row["set"]
		)
		var gain: float = base + float(row["gain"])
		var spread: float = BANK.STEP_PITCH_SPREAD
		K.check(
			fails,
			sets.size() == 1 and sets.has(want_set),
			"footsteps: %s plays the %s set (%s)" % [c, row["set"], str(sets.keys())]
		)
		K.check(
			fails,
			db_lo >= gain - 1.6 and db_hi <= gain + 1.1,
			"footsteps: %s is %.1f dB (%.1f .. %.1f)" % [c, gain, db_lo, db_hi]
		)
		K.check(
			fails,
			(
				pitch_lo >= float(row["pitch"]) * (1.0 - spread) - 1e-4
				and pitch_hi <= float(row["pitch"]) * (1.0 + spread) + 1e-4
			),
			"footsteps: %s is pitch %.2f (%.2f .. %.2f)" % [c, row["pitch"], pitch_lo, pitch_hi]
		)
		K.check(fails, fs.last_class == c, "footsteps: %s is reported as %s" % [c, fs.last_class])
	# The signal path classifies by the foot's own point: grass on the shore is sand.
	var sand: Dictionary = spots.get("sand", {})
	if not sand.is_empty():
		ctx.player.stepped.emit("grass", sand["pos"])
		K.check(
			fails,
			fs.last_class == "sand" and str(fs.history.back()).begins_with("footstep_dirt_"),
			(
				"a step on the shore band is a sand step (%s, %s)"
				% [fs.last_class, str(fs.history.back())]
			)
		)
	var gravel: Dictionary = spots.get("gravel", {})
	if not gravel.is_empty():
		ctx.player.stepped.emit(_surface(ctx, gravel["pos"]), gravel["pos"])
		K.check(
			fails,
			fs.last_class == "gravel" and fs.last_pitch > 1.0,
			(
				"a step on a gravel road is a gravel step (%s, pitch %.2f)"
				% [fs.last_class, fs.last_pitch]
			)
		)
	var asphalt: Dictionary = spots.get("asphalt", {})
	if not asphalt.is_empty():
		ctx.player.stepped.emit("asphalt", asphalt["pos"])
		K.check(
			fails,
			(
				fs.last_class == "asphalt"
				and absf(fs.last_pitch - 1.0) <= BANK.STEP_PITCH_SPREAD + 1e-4
			),
			"a step on asphalt keeps pitch 1 (%.2f)" % fs.last_pitch
		)
	# The wade's dry shelf is sand.
	fs.play_wade(0.0)
	K.check(
		fails,
		fs.last_class == "sand",
		"a step on the shelf of a bank is a sand step (%s)" % fs.last_class
	)


# ------------------------------------------------------------------ speed


## The hero's walking pace on each class: WALK times the class's factor, pavement at full speed.
func _check_speed(ctx: FpContext) -> void:
	var p := ctx.player
	p.set_camera_mode("third", false)
	var measured := {}
	for c: String in ["asphalt", "sidewalk", "grass", "sand", "gravel", "dirt", "trail"]:
		if not spots.has(c):
			continue
		var spot: Dictionary = spots[c]
		var dir: Vector3 = spot["dir"]
		p.teleport(spot["pos"], rad_to_deg(atan2(-dir.x, -dir.z)))
		p.feel_k = 1.0
		for k in range(100):
			p.simulate(Vector2(0, 1), false, DT)
			p.update_view(DT)
			if p.feel_class != c and k > 20:
				break
		var pace: float = p.speed() / M
		var want: float = WS.WALK / M * SF.speed(c)
		measured[c] = pace
		K.check(
			fails,
			p.feel_class == c and absf(pace / want - 1.0) < 0.04,
			"%s: the hero walks at %.3f m/s (class %s, %.3f wanted)" % [c, pace, p.feel_class, want]
		)
	if measured.has("asphalt") and measured.has("sand"):
		K.check(
			fails,
			(
				measured["sand"] < measured["asphalt"] * 0.96
				and measured["sand"] > measured["asphalt"] * 0.9
			),
			(
				"sand is a few per cent slower than asphalt (%.3f vs %.3f)"
				% [measured["sand"], measured["asphalt"]]
			)
		)
	# The factor eases: crossing a surface edge does not jolt.
	p.feel_k = 1.0
	if spots.has("sand"):
		var spot: Dictionary = spots["sand"]
		p.teleport(spot["pos"], 0.0)
		var worst := 0.0
		var last := p.feel_k
		for k in range(60):
			p.simulate(Vector2.ZERO, false, DT)
			worst = maxf(worst, absf(p.feel_k - last))
			last = p.feel_k
		K.check(
			fails, worst < 0.02, "the speed factor eases onto sand, at most %.3f a frame" % worst
		)


# ------------------------------------------------------------------ dust


func _check_dust(ctx: FpContext) -> void:
	var f := K.make_feature(ctx, "surface_feel")
	K.check(
		fails,
		f != null and f.feature_id() == "surface_feel",
		"the surface_feel feature is registered and sets up"
	)
	if f == null:
		return
	var p := ctx.player
	var sand: Dictionary = spots.get("sand", {})
	var asphalt: Dictionary = spots.get("asphalt", {})
	var grass: Dictionary = spots.get("grass", {})
	var dirt: Dictionary = spots.get("dirt", {})
	var run := Vector3(0, 0, -5.0 * M)
	p.grounded = true
	p.velocity = run
	var n0: int = f.puffs
	if not sand.is_empty():
		p.stepped.emit("grass", sand["pos"])
		K.check(
			fails,
			f.puffs == n0 + 1 and f.last_class == "sand",
			"a running step on sand raises a puff (%d, %s)" % [f.puffs - n0, f.last_class]
		)
	if not dirt.is_empty():
		p.stepped.emit(_surface(ctx, dirt["pos"]), dirt["pos"])
		K.check(
			fails,
			f.last_class == "dirt" and f.puffs == n0 + 2,
			"a running step on a dirt track raises a puff (%s)" % f.last_class
		)
	var n1: int = f.puffs
	if not asphalt.is_empty():
		p.stepped.emit("asphalt", asphalt["pos"])
	if not grass.is_empty():
		p.stepped.emit("grass", grass["pos"])
	p.stepped.emit("bridge", Vector3.ZERO)
	K.check(fails, f.puffs == n1, "asphalt, grass and a bridge raise no dust")
	p.velocity = Vector3(0, 0, -1.0 * M)
	if not sand.is_empty():
		p.stepped.emit("grass", sand["pos"])
	K.check(
		fails,
		f.puffs == n1,
		"a walking step on sand raises none (%.1f m/s is under %.1f)" % [1.0, SF.DUST_MIN_MPS]
	)
	p.velocity = run
	p.grounded = false
	if not sand.is_empty():
		p.stepped.emit("grass", sand["pos"])
	p.grounded = true
	K.check(fails, f.puffs == n1, "nor in the air")
	var wet := Wet.new()
	ctx.features["streetscape"] = wet
	wet.weather.wet = 0.8
	if not sand.is_empty():
		p.stepped.emit("grass", sand["pos"])
	K.check(fails, f.puffs == n1, "nor on wet ground")
	ctx.features.erase("streetscape")
	wet.free()
	_check_emitters(f, sand)


## The feature's two emitters: one-shot, small, one shared material, a soft pale tint; flag off,
## no dust.
func _check_emitters(f: FpFeature, sand: Dictionary) -> void:
	var p := f.ctx.player
	var n1: int = f.puffs
	var emitters: Array[CPUParticles3D] = []
	for ch in f.get_children():
		if ch is CPUParticles3D:
			emitters.append(ch)
	K.check(
		fails,
		(
			emitters.size() == 2
			and emitters.all(
				func(e: CPUParticles3D) -> bool: return e.one_shot and e.amount <= FeaturePuff.PUFF
			)
		),
		"two one-shot emitters of at most %d quads, one shared material" % FeaturePuff.PUFF
	)
	if emitters.size() == 2:
		K.check(
			fails,
			(
				(emitters[0].mesh as QuadMesh).material == (emitters[1].mesh as QuadMesh).material
				and emitters[0].mesh.material != null
			),
			"the puffs are drawn with one unshaded billboard material"
		)
		_check_soft_puff((emitters[0].mesh as QuadMesh).material as StandardMaterial3D)
	var low: bool = f.puff(Vector3.ZERO, "sand")
	var tinted: Color = emitters[0].color if emitters[0].emitting else emitters[1].color
	K.check(
		fails,
		low and tinted.a > 0.0 and tinted.a <= 0.5 + 1e-4,
		"a sand puff is a soft, pale %.2f alpha" % tinted.a
	)
	FeatureFlags.set_override("surface_feel", false)
	var n2: int = f.puffs
	p.stepped.emit("grass", sand["pos"] if not sand.is_empty() else Vector3.ZERO)
	K.check(fails, f.puffs == n2 and n2 > n1, "flag off: no dust")
	FeatureFlags.set_override("surface_feel", true)


# ------------------------------------------------------------------ flag off


func _check_flag_off(ctx: FpContext, audio: FpFeature) -> void:
	FeatureFlags.set_override("surface_feel", false)
	var p := ctx.player
	if audio != null:
		var fs: FS = audio.get("footsteps")
		var sand: Dictionary = spots.get("sand", {})
		if not sand.is_empty():
			p.stepped.emit("grass", sand["pos"])
			K.check(
				fails,
				(
					fs.last_class == "grass"
					and str(fs.history.back()).begins_with("footstep_grass_")
					and fs.last_pitch > 0.9
					and fs.last_pitch < 1.1
				),
				"flag off: a step on the shore is a plain grass step (%s)" % fs.last_class
			)
		var gravel: Dictionary = spots.get("gravel", {})
		if not gravel.is_empty():
			p.stepped.emit(_surface(ctx, gravel["pos"]), gravel["pos"])
			K.check(
				fails,
				str(fs.history.back()).begins_with("footstep_dirt_") and fs.last_pitch < 1.1,
				"flag off: gravel borrows dirt at pitch 1 as before (%.2f)" % fs.last_pitch
			)
	var sand_spot: Dictionary = spots.get("sand", {})
	if not sand_spot.is_empty():
		var dir: Vector3 = sand_spot["dir"]
		p.teleport(sand_spot["pos"], rad_to_deg(atan2(-dir.x, -dir.z)))
		for k in range(100):
			p.simulate(Vector2(0, 1), false, DT)
			p.update_view(DT)
		K.check(
			fails,
			absf(p.speed() / WS.WALK - 1.0) < 0.03 and absf(p.feel_k - 1.0) < 0.01,
			"flag off: sand is full speed (%.3f of WALK)" % (p.speed() / WS.WALK)
		)
	FeatureFlags.set_override("surface_feel", true)


const FeaturePuff := preload("res://scripts/fp/surface/surface_feel_feature.gd")


## A puff is a soft round smudge, not a flat square: the material carries a radial alpha texture
## (a GradientTexture2D: the headless renderer cannot read its pixels back, so its gradient is
## sampled) that is opaque at the centre, falls off smoothly, and is clear from the quad's
## inscribed circle out, which takes in its edges and corners.
func _check_soft_puff(mat: StandardMaterial3D) -> void:
	var tex := mat.albedo_texture as GradientTexture2D if mat != null else null
	K.check(
		fails,
		tex != null and tex.gradient != null,
		"the puff material has a gradient alpha texture (no hard-edged squares)"
	)
	if tex == null or tex.gradient == null:
		return
	K.check(
		fails,
		(
			tex.fill == GradientTexture2D.FILL_RADIAL
			and tex.fill_from.is_equal_approx(Vector2(0.5, 0.5))
			and is_equal_approx(tex.fill_from.distance_to(tex.fill_to), 0.5)
		),
		"the alpha is radial from the quad's centre to the middle of its edges"
	)
	var g := tex.gradient
	var centre := g.sample(0.0).a
	var half := g.sample(0.5).a
	var rim := g.sample(1.0).a
	K.check(
		fails,
		centre > 0.9 and half > 0.2 and half < centre - 0.2 and rim < 0.01,
		"the puff falls off from the centre to clear (%.2f, %.2f, %.2f)" % [centre, half, rim]
	)
	var smooth := true
	var last := centre
	for k in range(21):
		var a := g.sample(float(k) / 20.0).a
		smooth = smooth and a <= last + 1e-4 and last - a < 0.2
		last = a
	K.check(fails, smooth, "the falloff is monotone and has no hard step")
