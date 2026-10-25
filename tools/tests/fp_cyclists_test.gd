extends SceneTree
## Cyclists (the cyclists flag, traffic's occupants.gd and ambient.gd, residents.gd trip_mode):
## the bicycle model's cranks turn as it rolls, a rider pedals it with each foot on its pedal
## through the turn and casts a shadow; residents who keep a bicycle ride it to work when it is not
## far; part of the ambient traffic is cyclists, and with the flag off none is. Time runs through
## the traffic feature's step(1/30) and sync_visuals.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const PPL := preload("res://scripts/fp/traffic/people.gd")
const AMB := preload("res://scripts/fp/traffic/ambient.gd")
const OCC := preload("res://scripts/fp/traffic/occupants.gd")
const RD := preload("res://scripts/fp/traffic/render.gd")
const DT := 1.0 / 30.0
## bicycle.glb units per metre, and the pedals from the cranks' axle (vehicles2.py bicycle()).
const GLB_M := 0.05
const PEDAL := Vector3(0.11, 0.17, 0.0)
## How far a foot's toes may be from its pedal (m; a short rider's leg at the bottom of the
## stroke points the toes down at it).
const TOE_TOL := 0.04

var fails: Array[String] = []
var ctx: FpContext
var f: FpFeature


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true})
	f = K.make_feature(ctx, "traffic")
	K.check(fails, f != null, "the traffic feature is registered")
	if f != null:
		f.set("auto_step", false)
		var pp: PPL = f.get("people")
		if pp != null:
			pp.blocking = true
		_check_model()
		_check_commute()
		_check_ambient()
		_check_rider()
	K.finish(self, "FP_CYCLISTS_TEST", fails)


## bicycle.glb: two wheels and the cranks as their own nodes, and a saddle point.
func _check_model() -> void:
	var ps := AP.load_scene(AP.BICYCLE)
	K.check(fails, ps != null, "bicycle.glb loads")
	if ps == null:
		return
	var n := ps.instantiate() as Node3D
	var have: Array[String] = []
	for nm: String in AP.BIKE_WHEEL_NODES + [AP.CRANK_NODE, OCC.SEAT_NODE]:
		if n.find_child(nm, true, false) != null:
			have.append(nm)
	K.check(
		fails,
		have.size() == 4,
		"bicycle.glb has its wheels, cranks and saddle point (%s)" % str(have)
	)
	n.free()


## residents.gd: a quarter or so keep a bicycle, the same ones every time; they ride it to work
## up to BIKE_TILES road tiles and drive farther, and nobody does with bike_share 0.
func _check_commute() -> void:
	var res: Residents = ctx.residents
	var keep := 0
	var again := 0
	var rider: Dictionary = {}
	for r: Dictionary in res.people:
		if res.keeps_bike(r):
			keep += 1
			again += 1 if res.keeps_bike(r) else 0
			if rider.is_empty():
				rider = r
	var n := res.people.size()
	var share := float(keep) / maxf(float(n), 1.0)
	K.check(
		fails,
		n >= 10 and share > 0.1 and share < 0.7 and again == keep,
		"residents: %d of %d keep a bicycle, the same ones again" % [keep, n]
	)
	if rider.is_empty():
		return
	var plan: Dictionary = rider.get("plan", {})
	var was: Variant = plan.get("commute", null)
	plan["commute"] = "car"
	rider["plan"] = plan
	var near := res.trip_mode(rider, 8, "work")
	var far := res.trip_mode(rider, Residents.BIKE_TILES + 5, "work")
	var errand := res.trip_mode(rider, 4, "shop")
	res.bike_share = 0.0
	var off := res.trip_mode(rider, 8, "work")
	res.bike_share = Residents.BIKE_SHARE
	if was == null:
		plan.erase("commute")
	else:
		plan["commute"] = was
	var got := "%s/%s/%s/%s" % [near, far, errand, off]
	K.check(
		fails,
		got == "bike/car/walk/car",
		"residents: bike to work near, car far, walk an errand, car with nobody riding (%s)" % got
	)


## ambient.gd: with the flag on about BIKE_CHANCE of the spawns are cyclists at bicycle speed on
## the bicycle model; with it off none.
func _check_ambient() -> void:
	var amb: AMB = f.get("ambient")
	K.check(
		fails,
		is_equal_approx(amb.bike_chance, AMB.BIKE_CHANCE),
		"ambient: cyclists on with the flag (%.2f)" % amb.bike_chance
	)
	var counts := _spawn_counts(amb, 1.0)
	K.check(
		fails,
		counts.x > 0 and counts.y == counts.x,
		"ambient: every spawn a cyclist at chance 1 (%d of %d)" % [counts.y, counts.x]
	)
	var bm: int = f.call("bike_model")
	var bad := 0
	for c: VH.Car in _vh().cars:
		if c.role == "ambient" and c.kind == "bike" and not c.parked:
			if c.model != bm or c.v0 < 3.0 * WS.M or c.v0 > 5.0 * WS.M or c.v > c.v0 + 1e-4:
				bad += 1
	K.check(fails, bad == 0, "ambient: cyclists ride the bicycle at 3-5 m/s (%d off)" % bad)
	counts = _spawn_counts(amb, 0.0)
	K.check(
		fails,
		counts.x > 0 and counts.y == 0,
		"ambient: no cyclists at chance 0 (%d of %d)" % [counts.y, counts.x]
	)
	FeatureFlags.set_override("cyclists", false)
	f.call("on_world_rebuilt")
	K.check(fails, amb.bike_chance == 0.0, "ambient: no cyclists with the flag off")
	FeatureFlags.set_override("cyclists", true)
	f.call("on_world_rebuilt")


## [spawned, of them cyclists] from a synchronous fill of the ambient traffic at chance.
func _spawn_counts(amb: AMB, chance: float) -> Vector2i:
	_quiet()
	amb.bike_chance = chance
	f.set("ambient_enabled", true)
	amb.maintain(ctx.player_position(), Vector3(0, 0, -1), true)
	f.set("ambient_enabled", false)
	var n := 0
	var bikes := 0
	for c: VH.Car in _vh().cars:
		if c.role == "ambient" and not c.parked:
			n += 1
			bikes += 1 if c.kind == "bike" else 0
	amb.bike_chance = AMB.BIKE_CHANCE
	return Vector2i(n, bikes)


## A bicycle rolling past the camera: its wheels and cranks turn together, its rider pedals with
## each foot's toes on its pedal at every point of the turn and casts a shadow.
func _check_rider() -> void:
	var pp: PPL = f.get("people")
	if pp == null or not pp.ok:
		print("  note: no rigged people (rider not checked)")
		return
	_quiet()
	var l := _lane()
	if l == null:
		K.check(fails, false, "fixture: a straight lane for the bicycle")
		return
	var c := _vh().make("bike", "test", AMB.BIKE_DIMS)
	c.model = f.call("bike_model")
	c.v0 = 4.0 * WS.M
	_vh().place(c, l, 0.15)
	c.v = c.v0
	var side := Basis(Vector3.UP, c.yaw) * Vector3(9.0 * WS.M, 0, 3.0 * WS.M)
	ctx.player.teleport(c.pos + side, 0.0, 0.0, false)
	ctx.player.look_toward(c.pos + Vector3(0, 1.0 * WS.M, 0))
	var occ: OCC = f.get("occupants")
	ctx.sim.set_speed(1)
	var worst := 0.0
	var samples := 0
	var cranks := {}
	var spun := 0
	var bad_crank := 0
	var last_wheel := -1.0
	for k in range(24):
		f.step(DT)
		f.sync_visuals(DT)
		if c.node == null or not occ.is_riding(c.id):
			continue
		var crank := c.node.find_child(AP.CRANK_NODE, true, false) as Node3D
		var wheel := c.node.find_child("Wheel_F", true, false) as Node3D
		var th: float = c.node.get_meta("crank_th", 0.0)
		if absf(angle_difference(crank.rotation.x, th)) > 1e-3:
			bad_crank += 1
		if last_wheel >= 0.0 and not is_equal_approx(wheel.rotation.x, last_wheel):
			spun += 1
		last_wheel = wheel.rotation.x
		cranks[int(fposmod(th, TAU) / (TAU / 4.0))] = true
		var b := occ.body_of(c.id)
		for e: Array in [["Left", 1.0], ["Right", -1.0]]:
			var pedal := crank.global_transform * (PEDAL * Vector3(e[1], e[1], 1.0) * GLB_M)
			var toes := _bone(b, str(e[0]) + "Toes")
			worst = maxf(worst, toes.distance_to(pedal) / WS.M)
		samples += 1
	K.check(fails, samples >= 10, "rider: pedalling a bicycle drawn in full (%d frames)" % samples)
	K.check(
		fails,
		bad_crank == 0 and spun >= samples - 2,
		"rider: the cranks turn with the wheels (%d off, %d spins)" % [bad_crank, spun]
	)
	K.check(fails, cranks.size() >= 3, "rider: the cranks come round (%d quarters)" % cranks.size())
	K.check(
		fails,
		samples > 0 and worst < TOE_TOL,
		"rider: toes on the pedals all the way round (worst %.3f m)" % worst
	)
	var b := occ.body_of(c.id)
	if b != null:
		var shadow := b.meshes[0].cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		K.check(
			fails,
			shadow and b.ap.current_animation == String(OCC.RIDE),
			"rider: the ride clip, casting a shadow"
		)
	_vh().remove(c)
	f.sync_visuals(DT)
	K.check(fails, occ.riding == 0, "rider: released with the bicycle")


func _bone(b: PPL.Body, nm: String) -> Vector3:
	var sk := b.skel
	return (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(nm))).origin


## The first straight lane (by tile) at least a tile long, off any bridge.
func _lane() -> LG.Lane:
	var lg: LG = f.get("lanes")
	var keys: Array = lg.tiles.keys()
	keys.sort()
	for i: int in keys:
		var info: LG.TileInfo = lg.tiles[i]
		if info.bridge:
			continue
		for l: LG.Lane in info.lanes:
			if l.kind == LG.STRAIGHT and l.length >= 0.9:
				return l
	return null


## Removes moving vehicles and stops the ambient filler.
func _quiet() -> void:
	f.set("ambient_enabled", false)
	for c: VH.Car in _vh().cars.duplicate():
		if not c.parked:
			_vh().remove(c)
	f.get("trips").trips.clear()


func _vh() -> VH:
	return f.get("vehicles")
